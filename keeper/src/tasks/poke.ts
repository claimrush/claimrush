import type { Address, PublicClient } from 'viem';
import { decodeEventLog, parseAbiItem } from 'viem';

import {
  MARKET_ROUTER_ABI,
  MAINTENANCE_HUB_ABI,
  SHAREHOLDER_ROYALTIES_ABI,
  FURNACE_ABI,
  VE_CLAIM_NFT_ABI,
} from '../shared/abis.js';
import { postAlert } from '../shared/alert.js';
import { getLogsWithAutoSplit } from '../shared/rpc_logs.js';
import { sendContractTx } from '../shared/tx.js';
import {
  bumpRevertCount,
  initStatusState,
  loadJson,
  nowUtcIso,
  saveJsonAtomic,
  updateStatusFile,
} from '../shared/state.js';
import {
  getContractAddress,
  getContractStartBlock,
  isZeroAddress,
  requireNonZeroAddress,
} from '../shared/deployments.js';
import { parseChainIdStrict } from '../shared/chainId.js';
import { parseNonNegativeSafeInteger } from '../shared/utils.js';
import { scanMarketOffers, filterEligibleAutoFurnaceOffers } from './market_discovery.js';
import { MAX_LIVE_DEADLINE_SECS, type KeeperConfig } from '../shared/config.js';
import type { DeploymentManifest } from '../shared/deployments.js';
import type { ViemClients } from '../shared/clients.js';

const EVT_TAKEOVER = parseAbiItem(
  'event Takeover(uint256 indexed reignId, address indexed previousKing, address indexed newKing, uint256 pricePaid, uint256 referencePrice, uint256 reignDuration)',
);

const POKED_EVENT_ABI = [
  parseAbiItem(
    'event Poked(address caller, bool checkpointOk, bool flushOk, uint256 offersAttempted, uint256 offersSucceeded, bool furnaceTickSucceeded, uint256 bountyWethForwarded)',
  ),
] as const;

const TAKEOVER_DECODE_ABI = [EVT_TAKEOVER] as const;

interface PokeState {
  lastSeenPendingShareholderETH: string;
  lastTakeoverScanBlock: number | null;
  lastLpTickPokeTs: number | null;
  /** Highest MineCore Takeover.reignId we have already reacted to (decimal string). */
  lastProcessedTakeoverReignId: string;
}

function loadPokeState(statePath: string): PokeState {
  const raw = loadJson(statePath, { fallback: null }) as PokeState | null;
  return {
    lastSeenPendingShareholderETH: raw?.lastSeenPendingShareholderETH ?? '0',
    lastTakeoverScanBlock: raw?.lastTakeoverScanBlock ?? null,
    lastLpTickPokeTs: raw?.lastLpTickPokeTs ?? null,
    lastProcessedTakeoverReignId: raw?.lastProcessedTakeoverReignId ?? '0',
  };
}

function savePokeState(statePath: string, state: PokeState): void {
  saveJsonAtomic(statePath, state);
}

function extractErrorSig(err: string | null | undefined): string | null {
  if (!err) return null;
  const m = String(err).match(/0x[0-9a-fA-F]{8}/);
  return m ? m[0].toLowerCase() : null;
}

function extractErrorSigFromAny(err: unknown): string | null {
  if (!err) return null;
  const data = (err as { data?: unknown })?.data;
  if (typeof data === 'string' && data.startsWith('0x') && data.length >= 10) {
    return data.slice(0, 10).toLowerCase();
  }
  const errObj = err as { shortMessage?: string; message?: string };
  const msg = String(errObj?.shortMessage ?? errObj?.message ?? err);
  return extractErrorSig(msg);
}

function isLikelyRevertError(err: unknown): boolean {
  const errObj = err as { shortMessage?: string; message?: string };
  const msg = String(errObj?.shortMessage ?? errObj?.message ?? err);
  if (extractErrorSigFromAny(err)) return true;
  return msg.includes('reverted') || msg.includes('execution reverted');
}

async function preflightExecuteAutoFurnace({
  publicClient,
  marketRouterAddress,
  maintenanceHubAddress,
  offerId,
  deadline,
}: {
  publicClient: PublicClient;
  marketRouterAddress: Address;
  maintenanceHubAddress: Address;
  offerId: bigint;
  deadline: bigint;
  // The keeper's PrivateKeyAccount is the live tx's `tx.from`, but the
  // *inner* call to `MarketRouter.executeAutoFurnace` runs with
  // `msg.sender == MaintenanceHub`. Earlier preflight simulated the
  // MarketRouter call with the keeper EOA as `msg.sender`, which
  // bypassed `MarketRouter`'s settlement-keeper allowlist gate (and any
  // other `msg.sender` check the contract applies). The simulation now
  // pins `account` to the MaintenanceHub address so the gas/revert
  // profile matches what the live `MaintenanceHub.poke` will see when
  // it inner-calls MarketRouter.
}): Promise<{
  ok: boolean;
  isRevert?: boolean;
  errorSig?: string | null;
  error?: string;
}> {
  try {
    await publicClient.simulateContract({
      address: marketRouterAddress,
      abi: MARKET_ROUTER_ABI,
      functionName: 'executeAutoFurnace',
      args: [offerId, deadline],
      account: maintenanceHubAddress,
    });
    return { ok: true };
  } catch (e: unknown) {
    const errObj = e as { shortMessage?: string; message?: string };
    const msg = String(errObj?.shortMessage ?? errObj?.message ?? e);
    return {
      ok: false,
      isRevert: isLikelyRevertError(e),
      errorSig: extractErrorSigFromAny(e),
      error: msg,
    };
  }
}

export async function runPokeOnce({
  config,
  manifest,
  clients,
  log,
}: {
  config: KeeperConfig;
  manifest: DeploymentManifest;
  clients: ViemClients;
  log: (msg: string) => void;
}): Promise<unknown> {
  const chainId = parseChainIdStrict(manifest?.chainId) ?? 0;
  const statusInit = () => initStatusState({ deployment: config.deployment, chainId });

  const attemptAt = nowUtcIso();
  updateStatusFile({
    statusPath: config.statusPath,
    init: statusInit,
    patch: {
      lastAttemptAtUtc: attemptAt,
      lastAttemptByTask: { poke: attemptAt },
    },
  });

  const maintenanceHubAddress = getContractAddress(manifest, 'MaintenanceHub');
  requireNonZeroAddress(maintenanceHubAddress, 'MaintenanceHub');
  const marketRouterAddress = getContractAddress(manifest, 'MarketRouter');

  const { publicClient, walletClient, account } = clients;

  const block = await publicClient.getBlock();
  const clampedDeadlineSecs = BigInt(
    Math.min(Math.max(config.deadlineSecs, 30), config.liveRun ? MAX_LIVE_DEADLINE_SECS : 3600),
  );
  const deadline = block.timestamp + clampedDeadlineSecs;

  // Market candidates -> eligible offers
  let offerIds: bigint[] = [];
  if (!isZeroAddress(marketRouterAddress)) {
    let startBlock = config.marketStartBlockOverride;
    if (startBlock == null) startBlock = getContractStartBlock(manifest, 'MarketRouter');

    // If the manifest is unset, use a small lookback window so we don't miss offers
    // that were created shortly before the keeper started.
    if (!startBlock || startBlock <= 0) {
      const lookback =
        (parseNonNegativeSafeInteger(config.marketScanChunkBlocks, { defaultValue: 0 }) ?? 0) * 2;
      const currentBlockNumber =
        parseNonNegativeSafeInteger(block.number, { defaultValue: 0 }) ?? 0;
      startBlock = Math.max(0, currentBlockNumber - lookback);
    }

    const scan = await scanMarketOffers({
      publicClient,
      marketRouterAddress,
      statePath: config.marketStatePath,
      startBlock,
      chunkBlocks: config.marketScanChunkBlocks,
      log,
    });

    const eligible = await filterEligibleAutoFurnaceOffers({
      publicClient,
      marketRouterAddress,
      candidateOfferIds: scan.candidates,
      maxOffers: config.maxOffers,
      log,
    });

    offerIds = eligible;
  }

  // Optional: only pass offers to MaintenanceHub that are likely to succeed right now.
  // This avoids burning gas inside poke on deterministic per-offer reverts (ex: bonus target not met yet).
  if (
    config.autoFurnacePreflightEnabled &&
    !isZeroAddress(marketRouterAddress) &&
    offerIds.length
  ) {
    const passed: bigint[] = [];
    let reverted = 0;

    for (const offerId of offerIds) {
      const idStr = offerId.toString();
      const pre = await preflightExecuteAutoFurnace({
        publicClient,
        marketRouterAddress,
        maintenanceHubAddress,
        offerId,
        deadline,
      });

      if (pre.ok) {
        passed.push(offerId);
        continue;
      }

      if (!pre.isRevert) {
        // RPC/network errors should bubble up rather than silently dropping all offers.
        throw new Error(`auto-furnace preflight failed for offerId=${idStr}: ${pre.error}`);
      }

      reverted += 1;
      if (log) log(`market preflight: skipping offerId=${idStr} (sig=${pre.errorSig ?? 'n/a'})`);
    }

    if (reverted && log)
      log(
        `market preflight: filtered ${reverted}/${offerIds.length} offers (passing=${passed.length})`,
      );
    offerIds = passed;
  }

  // ------------------------------------------------------------------
  // Skip-if-idle: avoid submitting a poke tx when there is no useful
  // work for MaintenanceHub to perform.  We issue cheap view calls
  // against three contracts and compare with persisted state.
  // ------------------------------------------------------------------
  const shareholderRoyaltiesAddress = getContractAddress(manifest, 'ShareholderRoyalties');
  const furnaceAddress = getContractAddress(manifest, 'Furnace');
  const veClaimNftAddress = getContractAddress(manifest, 'VeClaimNFT');
  const mineCoreAddress = getContractAddress(manifest, 'MineCore');

  const pokeState = loadPokeState(config.pokeStatePath);

  const hasOffers = offerIds.length > 0;
  let shouldPoke = hasOffers;
  const reasons: string[] = [];

  if (hasOffers) {
    reasons.push(`offers=${offerIds.length}`);
  }

  // Scan for *new* Takeover events (reign changes) from MineCore.
  // A takeover generates pendingShareholderETH that may need flushing.
  // We track lastProcessedTakeoverReignId so overlapping log windows do not
  // re-trigger a poke on the same reign forever (fixes "poke every minute").
  let takeoverScanMaxReign: bigint | undefined;
  let hasNewTakeover = false;
  // Block cursor advance is gated on (a) a clean scan (no RPC error) AND
  // (b) the post-tx `flushOk` flag. A failed scan leaves no proof the
  // window was covered, and a failed flush leaves the takeover-reign cursor
  // pinned to the prior reign — both must reach a steady state before the
  // block cursor moves so the next tick can replay the same window.
  let takeoverScanCleanRangeEnd: number | null = null;
  if (!isZeroAddress(mineCoreAddress)) {
    const scanFrom =
      pokeState.lastTakeoverScanBlock != null
        ? Math.max(0, pokeState.lastTakeoverScanBlock - 64)
        : Math.max(
            0,
            (parseNonNegativeSafeInteger(block.number, { defaultValue: 0 }) ?? 0) - 10_000,
          );

    try {
      // Chunk the scan client-side so providers with strict eth_getLogs
      // limits (Alchemy Sepolia free tier caps ranges at ~10 blocks) don't
      // force `getLogsWithAutoSplit` to bisect repeatedly after a downtime
      // backlog.  `getLogsWithAutoSplit` still catches any chunk that
      // exceeds the provider limit — this just keeps the common-case scan
      // within the provider's comfort zone.
      const chunkSize = BigInt(Math.max(1, config.pokeTakeoverScanChunkBlocks ?? 2000));
      const scanFromBn = BigInt(scanFrom);
      const scanToBn = block.number;
      const takeoverLogs: any[] = [];
      let cursor = scanFromBn;
      while (cursor <= scanToBn) {
        const to = cursor + chunkSize - 1n > scanToBn ? scanToBn : cursor + chunkSize - 1n;
        const chunk = await getLogsWithAutoSplit({
          publicClient,
          request: {
            address: mineCoreAddress,
            event: EVT_TAKEOVER,
            fromBlock: cursor,
            toBlock: to,
          },
          log,
        });
        if (chunk.length) takeoverLogs.push(...chunk);
        cursor = to + 1n;
      }
      const lastProcessed = BigInt(pokeState.lastProcessedTakeoverReignId || '0');
      let maxReign = 0n;
      let cleanScan = true;
      for (const entry of takeoverLogs) {
        try {
          const decoded = decodeEventLog({
            abi: TAKEOVER_DECODE_ABI,
            data: entry.data,
            topics: entry.topics,
          });
          if (decoded.eventName !== 'Takeover') continue;
          const rid = decoded.args.reignId as bigint;
          if (rid > maxReign) maxReign = rid;
          if (rid > lastProcessed) hasNewTakeover = true;
        } catch {
          // Malformed Takeover decode: the keeper cannot prove the reign-id
          // payload of this log, so the scanned range is no longer "covered".
          // Holding the clean-range marker keeps the next idle tick re-scanning
          // the same window so a transient RPC hiccup or ABI drift does not
          // retire the takeover cursor over an undecodable log.
          cleanScan = false;
          if (log) log('poke: malformed Takeover log, holding scan range for retry');
        }
      }
      takeoverScanMaxReign = maxReign;
      takeoverScanCleanRangeEnd = cleanScan
        ? (parseNonNegativeSafeInteger(block.number, { defaultValue: 0 }) ?? 0)
        : null;
      if (hasNewTakeover) {
        shouldPoke = true;
        reasons.push(
          `new takeover (reignId > ${lastProcessed.toString()}, logs=${takeoverLogs.length})`,
        );
      }
    } catch (e: unknown) {
      if (log) log(`poke: takeover scan failed, treating as stale: ${String(e)}`);
      // Note: hasNewTakeover intentionally not flipped here — `shouldPoke=true`
      // is what triggers the conservative poke; the takeover-reign cursor is
      // intentionally not bumped on scan failure (we don't have a proven reignId).
      shouldPoke = true;
      takeoverScanMaxReign = undefined;
      takeoverScanCleanRangeEnd = null;
      reasons.push('takeover scan error (conservative poke)');
    }
  }

  // L1-1 (2026-04-17): hoist the observed `pendingETH` out of the idle-check
  // branch so it is still visible after `sendContractTx` resolves. The cursor
  // (`lastSeenPendingShareholderETH`) is only advanced after a confirmed
  // receipt — see the post-send branch below.
  let observedPendingETH: bigint | null = null;

  if (!shouldPoke) {
    const [pendingETH, lpStream, globalLastTs] = await Promise.all([
      !isZeroAddress(shareholderRoyaltiesAddress)
        ? (publicClient.readContract({
            address: shareholderRoyaltiesAddress,
            abi: SHAREHOLDER_ROYALTIES_ABI,
            functionName: 'pendingShareholderETH',
          }) as Promise<bigint>)
        : Promise.resolve(0n),

      !isZeroAddress(furnaceAddress)
        ? (publicClient.readContract({
            address: furnaceAddress,
            abi: FURNACE_ABI,
            functionName: 'getLpStreamState',
          }) as Promise<readonly [bigint, bigint, bigint, bigint]>)
        : Promise.resolve([0n, 0n, 0n, 0n] as const),

      !isZeroAddress(veClaimNftAddress)
        ? (publicClient.readContract({
            address: veClaimNftAddress,
            abi: VE_CLAIM_NFT_ABI,
            functionName: 'globalLastTs',
          }) as Promise<bigint>)
        : Promise.resolve(0n),
    ]);

    observedPendingETH = pendingETH;

    const prevPendingETH = BigInt(pokeState.lastSeenPendingShareholderETH || '0');
    const pendingEthDelta = pendingETH > prevPendingETH ? pendingETH - prevPendingETH : 0n;
    const MIN_PENDING_ETH_DELTA = BigInt(config.pokeMinPendingEthDelta);

    const [, periodFinish, , remaining] = lpStream;
    const lpStreamActive = remaining > 0n && block.timestamp < periodFinish;

    const veStale =
      globalLastTs > 0n && block.timestamp - globalLastTs > BigInt(config.pokeStaleThresholdSecs);

    if (pendingEthDelta >= MIN_PENDING_ETH_DELTA) {
      shouldPoke = true;
      reasons.push(
        `pendingShareholderETH delta ${pendingEthDelta} >= ${MIN_PENDING_ETH_DELTA} (${prevPendingETH}→${pendingETH})`,
      );
    }

    // Time-gated LP stream tick: only poke for LP accrual if enough time
    // (`KEEPER_POKE_LP_TICK_INTERVAL_SECS`) has passed since the last poke.
    // This prevents an always-active LP stream from triggering a poke every
    // loop iteration.
    if (lpStreamActive) {
      const lastTickTs = pokeState.lastLpTickPokeTs ?? 0;
      const elapsed =
        (parseNonNegativeSafeInteger(block.timestamp, { defaultValue: 0 }) ?? 0) - lastTickTs;
      if (elapsed >= config.pokeLpTickIntervalSecs) {
        shouldPoke = true;
        reasons.push(
          `lpStream tick due (elapsed=${elapsed}s >= ${config.pokeLpTickIntervalSecs}s)`,
        );
      }
    }

    if (veStale) {
      shouldPoke = true;
      reasons.push(
        `veCheckpoint stale (age=${block.timestamp - globalLastTs}s > ${config.pokeStaleThresholdSecs}s)`,
      );
    }

    // L1-1 (2026-04-17): previously `lastSeenPendingShareholderETH` was persisted
    // BEFORE `sendContractTx`, so a reverted/dropped poke left behind a stale
    // cursor that made the next tick's delta look like zero and skip the retry.
    // We now only persist on either (a) the skip-if-idle path (no tx attempted)
    // or (b) after the tx confirms successfully (see the post-send branch below).
    if (!shouldPoke) {
      pokeState.lastSeenPendingShareholderETH = pendingETH.toString();
      // Idle path: no tx is sent, so there is no flush gate to wait on.
      // Advance the takeover-block cursor only if the scan completed
      // cleanly; a scan error already cleared the proof of coverage.
      if (takeoverScanCleanRangeEnd != null) {
        pokeState.lastTakeoverScanBlock = takeoverScanCleanRangeEnd;
      }
      savePokeState(config.pokeStatePath, pokeState);

      if (log)
        log(
          `poke skip-if-idle: no work detected (pendingETH=${pendingETH}, delta=${pendingEthDelta}, minDelta=${MIN_PENDING_ETH_DELTA}, lpRemaining=${remaining}, veAge=${globalLastTs > 0n ? block.timestamp - globalLastTs : 'n/a'}s)`,
        );

      const skippedAt = nowUtcIso();
      updateStatusFile({
        statusPath: config.statusPath,
        init: statusInit,
        patch: {
          lastSuccessAtUtc: skippedAt,
          lastSuccessByTask: { poke: skippedAt },
          lastSkipAtUtc: skippedAt,
          lastSkipByTask: { poke: skippedAt },
          lastSkipReasonByTask: { poke: 'idle' },
          lastError: null,
          lastErrorByTask: { poke: null },
        },
      });

      return { skipped: true, reason: 'idle' };
    }
  }

  if (log) {
    log(`poke: work detected — ${reasons.join('; ')}`);
  }

  const args = {
    offerIds,
    maxOffers: BigInt(config.maxOffers),
  };

  if (log) {
    log(`poke args: offers=${offerIds.length} maxOffers=${config.maxOffers}`);
  }

  if (config.dryRun) {
    if (log) log('dry-run: not submitting MaintenanceHub.poke');

    // Dry-run is a deliberate safety mode. Treat as a successful no-op for monitoring.
    const successAt = nowUtcIso();
    updateStatusFile({
      statusPath: config.statusPath,
      init: statusInit,
      patch: {
        lastSuccessAtUtc: successAt,
        lastSuccessByTask: { poke: successAt },
        lastError: null,
        lastErrorByTask: { poke: null },
      },
    });

    return { dryRun: true, args };
  }

  let hash: `0x${string}` | null = null;
  try {
    const tx = await sendContractTx({
      config,
      publicClient,
      walletClient,
      account,
      address: maintenanceHubAddress,
      abi: MAINTENANCE_HUB_ABI,
      functionName: 'poke',
      args: [args],
      minGasLimit: 500_000n,
      log,
      context: `MaintenanceHub.poke offers=${offerIds.length}`,
    });

    if (!tx.ok) {
      if (log) log(`tx skipped: ${tx.reason}`);

      // Skips are safety rails (paused, pending nonce guard, fee caps, etc).
      // Treat as a successful no-op so monitoring doesn't flag false failures.
      const skippedAt = nowUtcIso();
      updateStatusFile({
        statusPath: config.statusPath,
        init: statusInit,
        patch: {
          lastSuccessAtUtc: skippedAt,
          lastSuccessByTask: { poke: skippedAt },

          lastSkipAtUtc: skippedAt,
          lastSkipByTask: { poke: skippedAt },
          lastSkipReasonByTask: { poke: tx.reason },

          lastError: null,
          lastErrorByTask: { poke: null },
        },
      });

      return { skipped: true, reason: tx.reason, args };
    }

    hash = tx.hash as `0x${string}`;
    const receipt = tx.receipt as any;

    const successAt = nowUtcIso();
    updateStatusFile({
      statusPath: config.statusPath,
      init: statusInit,
      patch: {
        lastSuccessAtUtc: successAt,
        lastSuccessByTask: { poke: successAt },

        lastTxHash: hash,
        lastTxHashByTask: { poke: hash },

        lastError: null,
        lastErrorByTask: { poke: null },
      },
    });

    // Decode the `Poked(...)` log emitted by `MaintenanceHub.poke`. The
    // event reports per-stage success flags: `furnaceTickSucceeded` for
    // the `_furnaceTick()` call and `flushOk` for
    // `ShareholderRoyalties.flush()`. Cursor advance for each surface
    // gates on its own flag — a flushed-payouts retry cannot ride a
    // successful furnace tick, and a reverted flush must not retire
    // the takeover / pendingETH cursors that depend on the flush
    // having actually moved value out of `ShareholderRoyalties`.
    //
    // Default the flags to `false` and require a decoded `Poked` log
    // before the cursor advance code believes either stage succeeded. A
    // missing log, the wrong hub address, or an ABI drift would
    // otherwise silently retire every cursor while the keeper has no
    // proof the on-chain stages even ran.
    let furnaceTickOk = false;
    let flushOk = false;
    let pokedDecoded = false;
    try {
      const maintenanceHubAddressLower = maintenanceHubAddress.toLowerCase();
      for (const log of receipt.logs ?? []) {
        if (String(log?.address ?? '').toLowerCase() !== maintenanceHubAddressLower) continue;
        try {
          const decoded = decodeEventLog({
            abi: POKED_EVENT_ABI,
            data: log.data,
            topics: log.topics,
          });
          if (decoded.eventName === 'Poked') {
            furnaceTickOk = decoded.args.furnaceTickSucceeded;
            flushOk = decoded.args.flushOk;
            pokedDecoded = true;
            break;
          }
        } catch {
          // not a Poked log, skip
        }
      }
    } catch {
      // Receipt parsing failed entirely. Leave both flags `false` so the
      // cursor advance code holds every dependent surface for the next
      // idle tick to retry.
    }
    if (!pokedDecoded && log) {
      log(
        'poke: no Poked event decoded from receipt; holding furnaceTick / flush / takeover / pendingETH cursors for retry',
      );
    }

    let pokeStateDirty = false;
    if (furnaceTickOk) {
      pokeState.lastLpTickPokeTs =
        parseNonNegativeSafeInteger(block.timestamp, { defaultValue: 0 }) ?? 0;
      pokeStateDirty = true;
    }
    // The takeover-reign cursor is bound to the flush stage: a missed
    // flush leaves accrued ETH still owed to the prior reign's
    // shareholder, so retiring the cursor before flush succeeds would
    // skip the payout that very same reign required. Hold the cursor
    // when `flushOk === false` so the next idle tick replays the
    // unfinished side-effect.
    if (flushOk && takeoverScanMaxReign !== undefined) {
      const prev = BigInt(pokeState.lastProcessedTakeoverReignId || '0');
      if (takeoverScanMaxReign > prev) {
        pokeState.lastProcessedTakeoverReignId = takeoverScanMaxReign.toString();
        pokeStateDirty = true;
      }
    }
    // The `pendingETH` cursor records the watermark of accrued royalty
    // ETH that the keeper has already drained via flush. A failed
    // flush leaves the same delta visible on the next tick; advancing
    // the cursor here would erase that signal and the next idle tick
    // would skip the retry. Hold the cursor on `flushOk === false`.
    // `observedPendingETH` is null when `shouldPoke` was already true
    // before reading pendingETH (e.g. takeover forced the poke) — in
    // that case there is no cursor to touch.
    if (flushOk && observedPendingETH != null) {
      const nextSeen = observedPendingETH.toString();
      if (pokeState.lastSeenPendingShareholderETH !== nextSeen) {
        pokeState.lastSeenPendingShareholderETH = nextSeen;
        pokeStateDirty = true;
      }
    }
    // The takeover-block cursor records where the next scan resumes. Advance
    // it only when the scan completed cleanly AND the flush succeeded: a
    // failed flush leaves the per-reign cursor pinned to the prior reign,
    // and the next tick must be able to re-detect the same window so the
    // reign retirement and the flush retire together.
    if (flushOk && takeoverScanCleanRangeEnd != null) {
      if (pokeState.lastTakeoverScanBlock !== takeoverScanCleanRangeEnd) {
        pokeState.lastTakeoverScanBlock = takeoverScanCleanRangeEnd;
        pokeStateDirty = true;
      }
    }
    if (pokeStateDirty) savePokeState(config.pokeStatePath, pokeState);

    return { dryRun: false, hash, receipt };
  } catch (e: unknown) {
    const errObj = e as { shortMessage?: string; message?: string };
    const err = String(errObj?.shortMessage ?? errObj?.message ?? e);

    const patch: Record<string, unknown> = {
      lastError: err,
      lastErrorByTask: { poke: err },
    };
    if (hash) {
      patch.lastTxHash = hash;
      patch.lastTxHashByTask = { poke: hash };
    }

    const cur = updateStatusFile({
      statusPath: config.statusPath,
      init: statusInit,
      patch,
    });

    const bumped = bumpRevertCount(cur, 'poke');
    updateStatusFile({ statusPath: config.statusPath, init: statusInit, patch: bumped });

    await postAlert(config.alertWebhookUrl, {
      type: 'keeper_error',
      action: 'poke',
      deployment: config.deployment,
      timestampUtc: nowUtcIso(),
      error: err,
      txHash: hash,
    });

    throw e;
  }
}
