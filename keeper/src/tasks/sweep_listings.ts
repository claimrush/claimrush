import { MAX_LIVE_DEADLINE_SECS, type KeeperConfig } from '../shared/config.js';
import type { DeploymentManifest } from '../shared/deployments.js';
import type { ViemClients } from '../shared/clients.js';
import type { Address, PublicClient } from 'viem';
import type { PrivateKeyAccount } from 'viem/accounts';

import { MARKET_ROUTER_ABI } from '../shared/abis.js';
import { postAlert } from '../shared/alert.js';
import { sendContractTx } from '../shared/tx.js';
import {
  bumpRevertCount,
  initListingsState,
  initStatusState,
  loadJsonDetailed,
  nowUtcIso,
  saveJsonAtomic,
  updateStatusFile,
} from '../shared/state.js';
import {
  getContractAddress,
  getContractStartBlock,
  requireNonZeroAddress,
} from '../shared/deployments.js';
import { computeExponentialBackoffDelayMs } from '../shared/backoff.js';
import { parseChainIdStrict } from '../shared/chainId.js';
import { fmtMs, parseNonNegativeSafeInteger } from '../shared/utils.js';
import { scanListings, filterEligibleListings } from './listing_discovery.js';

interface ListingFailureRecord {
  count?: number;
  firstFailureAtMs?: number;
  lastFailureAtMs?: number;
  cooldownUntilMs?: number;
  lastErrorSig?: string | null;
  lastError?: string;
  lastTxHash?: string | null;
}

interface ListingFailures {
  [tokenId: string]: ListingFailureRecord;
}

interface PreflightResult {
  ok: boolean;
  isRevert?: boolean;
  errorSig?: string | null;
  error?: string;
}

interface RecordListingFailureOpts {
  listingFailures: ListingFailures;
  tokenIdStr: string;
  nowMs: number;
  err: string | unknown;
  errorSig?: string | null;
  config: KeeperConfig;
  txHash?: string | null;
}

interface SweepListingsOpts {
  config: KeeperConfig;
  manifest: DeploymentManifest;
  clients: ViemClients;
  log: (msg: string) => void;
}

function normalizeListingFailures(v: unknown): ListingFailures {
  if (!v || typeof v !== 'object' || Array.isArray(v)) return {};
  const out: ListingFailures = {};
  for (const [k, rec] of Object.entries(v as Record<string, unknown>)) {
    const id = String(k);
    if (!rec || typeof rec !== 'object' || Array.isArray(rec)) continue;
    const next: ListingFailureRecord = { ...rec };
    if (next.count != null) next.count = parseNonNegativeSafeInteger(next.count) ?? undefined;
    if (next.firstFailureAtMs != null) {
      next.firstFailureAtMs = parseNonNegativeSafeInteger(next.firstFailureAtMs) ?? undefined;
    }
    if (next.lastFailureAtMs != null) {
      next.lastFailureAtMs = parseNonNegativeSafeInteger(next.lastFailureAtMs) ?? undefined;
    }
    if (next.cooldownUntilMs != null) {
      next.cooldownUntilMs = parseNonNegativeSafeInteger(next.cooldownUntilMs) ?? undefined;
    }
    out[id] = next;
  }
  return out;
}

function extractErrorSig(err: unknown): string | null {
  if (!err) return null;
  const m = String(err).match(/0x[0-9a-fA-F]{8}/);
  return m ? m[0].toLowerCase() : null;
}

function extractErrorSigFromAny(err: unknown): string | null {
  if (!err) return null;

  // Some clients expose raw revert data on `err.data`.
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

async function preflightSellListedLockToFurnace({
  publicClient,
  marketRouterAddress,
  tokenId,
  deadline,
  account,
}: {
  publicClient: PublicClient;
  marketRouterAddress: Address;
  tokenId: bigint;
  deadline: bigint;
  account: PrivateKeyAccount;
}): Promise<PreflightResult> {
  try {
    await publicClient.simulateContract({
      address: marketRouterAddress,
      abi: MARKET_ROUTER_ABI,
      functionName: 'sellListedLockToFurnace',
      args: [tokenId, deadline],
      account,
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

async function _preflightCancelExpiredListing({
  publicClient,
  marketRouterAddress,
  tokenId,
  account,
}: {
  publicClient: PublicClient;
  marketRouterAddress: Address;
  tokenId: bigint;
  account: PrivateKeyAccount;
}): Promise<PreflightResult> {
  try {
    await publicClient.simulateContract({
      address: marketRouterAddress,
      abi: MARKET_ROUTER_ABI,
      functionName: 'cancelExpiredListing',
      args: [tokenId],
      account,
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

function truncate(s: unknown, n: number): string {
  const str = String(s ?? '');
  if (str.length <= n) return str;
  return str.slice(0, Math.max(0, n - 1)) + '…';
}

function getCooldownUntilMs(rec: ListingFailureRecord | undefined): number {
  return parseNonNegativeSafeInteger(rec?.cooldownUntilMs, { defaultValue: 0 }) ?? 0;
}

function isInCooldown(rec: ListingFailureRecord | undefined, nowMs: number): boolean {
  return getCooldownUntilMs(rec) > nowMs;
}

function formatUtc(ms: number): string {
  try {
    return new Date(ms).toISOString();
  } catch {
    return String(ms);
  }
}

function persistListingsState({
  statePath,
  state,
  listingFailures,
}: {
  statePath: string;
  state: Record<string, unknown> | null;
  listingFailures: ListingFailures;
}): Record<string, unknown> {
  const next = { ...(state ?? initListingsState()) };
  next.version = Math.max(1, parseNonNegativeSafeInteger(next.version, { defaultValue: 1 }) ?? 1);
  next.listingFailures = listingFailures ?? {};
  saveJsonAtomic(statePath, next);
  return next;
}

function recordListingFailure({
  listingFailures,
  tokenIdStr,
  nowMs,
  err,
  errorSig,
  config,
  txHash,
}: RecordListingFailureOpts): ListingFailureRecord {
  const prev = listingFailures[tokenIdStr] ?? {};
  const prevCount = parseNonNegativeSafeInteger(prev.count, { defaultValue: 0 }) ?? 0;
  const count = prevCount + 1;

  const delayMs = computeExponentialBackoffDelayMs({
    failureCount: count,
    initialMs: config.listingsBackoffInitialMs,
    multiplier: config.listingsBackoffMultiplier,
    maxMs: config.listingsBackoffMaxMs,
    jitterBps: config.listingsBackoffJitterBps,
  });

  const cooldownUntilMs = nowMs + delayMs;

  const rec: ListingFailureRecord = {
    count,
    firstFailureAtMs:
      parseNonNegativeSafeInteger(prev.firstFailureAtMs, { defaultValue: nowMs }) ?? nowMs,
    lastFailureAtMs: nowMs,
    cooldownUntilMs,
    lastErrorSig: errorSig ?? extractErrorSig(err),
    lastError: truncate(err, 1024),
    lastTxHash: txHash ?? prev.lastTxHash ?? null,
  };

  listingFailures[tokenIdStr] = rec;
  return rec;
}

export async function runSweepListings({
  config,
  manifest,
  clients,
  log,
}: SweepListingsOpts): Promise<void> {
  const chainId = parseChainIdStrict(manifest?.chainId) ?? 0;
  const statusInit = () => initStatusState({ deployment: config.deployment, chainId });

  const attemptAt = nowUtcIso();

  updateStatusFile({
    statusPath: config.statusPath,
    init: statusInit,
    patch: {
      lastAttemptAtUtc: attemptAt,
      lastAttemptByTask: { sweepListings: attemptAt },
    },
  });

  const marketRouterAddress = getContractAddress(manifest, 'MarketRouter');
  requireNonZeroAddress(marketRouterAddress, 'MarketRouter');

  const furnaceAddress = getContractAddress(manifest, 'Furnace');
  requireNonZeroAddress(furnaceAddress, 'Furnace');

  const veAddress = getContractAddress(manifest, 'VeClaimNFT');
  requireNonZeroAddress(veAddress, 'VeClaimNFT');

  const { publicClient, walletClient, account } = clients;

  const block = await publicClient.getBlock();

  let startBlock = config.listingsStartBlockOverride;
  if (startBlock == null) startBlock = getContractStartBlock(manifest, 'MarketRouter');

  // If no start block is known, default to a small lookback window so we don't miss
  // newly-created listings on the first keeper run.
  if (!startBlock || startBlock <= 0) {
    const latest = BigInt(block.number);
    const lookback = BigInt(config.marketScanChunkBlocks) * 2n;
    const from = latest > lookback ? latest - lookback + 1n : 1n;
    startBlock = parseNonNegativeSafeInteger(from, { defaultValue: 1 }) ?? 1;
    if (log)
      log(
        `listings startBlock missing/invalid. defaulting to lookback start=${startBlock} (latest=${latest.toString()})`,
      );
  }

  const scan = await scanListings({
    publicClient,
    marketRouterAddress,
    statePath: config.listingsStatePath,
    startBlock,
    chunkBlocks: config.marketScanChunkBlocks,
    log,
  });

  // Load persisted listings state so we can apply per-listing backoff/cooldown.
  let listingsState: Record<string, unknown>;
  const listingsStateResult = loadJsonDetailed(config.listingsStatePath);
  if (listingsStateResult.kind === 'ok' && listingsStateResult.value != null) {
    listingsState = listingsStateResult.value as Record<string, unknown>;
  } else if (listingsStateResult.kind === 'error') {
    log(
      `WARN: listings state file corrupt (${config.listingsStatePath}): ${listingsStateResult.error.message}; reinitializing`,
    );
    listingsState = initListingsState() as unknown as Record<string, unknown>;
  } else {
    listingsState = initListingsState() as unknown as Record<string, unknown>;
  }
  const listingFailures = normalizeListingFailures(
    (listingsState as Record<string, unknown>).listingFailures,
  );

  // Defensive prune (scan already prunes, but keep state tidy if older versions exist).
  const candSet = new Set(Array.isArray(scan?.candidates) ? scan.candidates.map(String) : []);
  for (const k of Object.keys(listingFailures)) {
    if (!candSet.has(k)) delete listingFailures[k];
  }

  const nowMs = Date.now();

  // Apply cooldown before eligibility checks so we can still attempt up to maxListings.
  let candidateTokenIds = scan.candidates;
  const skippedCooldown: Array<{ tokenId: string; failures: number; cooldownUntilMs: number }> = [];
  if (config.listingsBackoffEnabled) {
    candidateTokenIds = [];
    for (const idStr of scan.candidates) {
      const rec = listingFailures[idStr];
      if (rec && isInCooldown(rec, nowMs)) {
        skippedCooldown.push({
          tokenId: idStr,
          failures: parseNonNegativeSafeInteger(rec.count, { defaultValue: 0 }) ?? 0,
          cooldownUntilMs: getCooldownUntilMs(rec),
        });
        continue;
      }
      candidateTokenIds.push(idStr);
    }

    if (skippedCooldown.length && log) {
      for (const s of skippedCooldown) {
        const remaining = Math.max(0, s.cooldownUntilMs - nowMs);
        log(
          `listings backoff: skipping tokenId=${s.tokenId} (failures=${s.failures}, retryAt=${formatUtc(
            s.cooldownUntilMs,
          )}, in=${fmtMs(remaining)})`,
        );
      }
    }
  }

  const { eligible: eligible0, expired: expired0 } = await filterEligibleListings({
    publicClient,
    marketRouterAddress,
    furnaceAddress,
    veAddress,
    candidateTokenIds,
    maxListings: config.maxListings,
    log,
  });

  // Identify expired listings even if they are currently in backoff/cooldown.
  // Those listings are excluded from candidateTokenIds above, so we check them explicitly.
  const expired: bigint[] = Array.isArray(expired0) ? [...expired0] : [];
  const eligible: bigint[] = Array.isArray(eligible0) ? [...eligible0] : [];

  if (skippedCooldown.length) {
    const nowSec = block.timestamp;
    for (const s of skippedCooldown) {
      const tokenId = BigInt(s.tokenId);
      try {
        const listing = await publicClient.readContract({
          address: marketRouterAddress,
          abi: MARKET_ROUTER_ABI,
          functionName: 'getListing',
          args: [tokenId],
        });

        // Listing tuple layout:
        // [0] seller, [1] minClaimOut, [2] listedAtTime, [3] expiresAtTime, [4] active
        const active = listing?.[4] ?? false;
        // but not validated against the ABI at build time. If the contract ABI
        // changes the tuple order (e.g., a new field inserted), these indices
        // silently break. Suggested fix: add a sanity check in sanity.ts (like
        // the existing MarketRouter tuple checks) for getListing outputs.
        const expiresAtTime = listing?.[3] ?? 0n;
        if (active && (expiresAtTime === 0n || nowSec > expiresAtTime)) {
          expired.push(tokenId);
        }
      } catch {
        // Best-effort: ignore and move on.
      }
    }
  }

  // De-duplicate expired, and ensure eligible does not contain any expired ids.
  const expiredSet = new Set<string>();
  const expiredUniq: bigint[] = [];
  for (const t of expired) {
    const k = t.toString();
    if (expiredSet.has(k)) continue;
    expiredSet.add(k);
    expiredUniq.push(t);
  }

  const eligibleFiltered = eligible.filter((t) => !expiredSet.has(t.toString()));

  if (!eligibleFiltered.length && !expiredUniq.length) {
    // No-op sweep still counts as a successful run for monitoring.
    const successAt = nowUtcIso();
    updateStatusFile({
      statusPath: config.statusPath,
      init: statusInit,
      patch: {
        lastSuccessAtUtc: successAt,
        lastSuccessByTask: { sweepListings: successAt },
        lastError: null,
        lastErrorByTask: { sweepListings: null },
      },
    });

    if (skippedCooldown.length) {
      if (log)
        log(
          `listings sweep: 0 eligible listings (cooldown active for ${skippedCooldown.length} listings)`,
        );
      return;
    }
    if (log) log('listings sweep: no eligible listings');
    return;
  }

  if (log) {
    if (expiredUniq.length) log(`listings sweep: expired listings=${expiredUniq.length}`);
    if (eligibleFiltered.length)
      log(`listings sweep: eligible listings=${eligibleFiltered.length}`);
  }

  const cancelResults: Array<Record<string, unknown>> = [];

  let abortAll = false;

  // Batch-cancel expired listings in a single tx (permissionless; callable even when tradingPaused).
  if (expiredUniq.length > 0 && !config.dryRun) {
    if (log) log(`listings cancelExpired: batch ${expiredUniq.length} expired listings`);
    try {
      const tx = await sendContractTx({
        config,
        publicClient,
        walletClient,
        account,
        address: marketRouterAddress,
        abi: MARKET_ROUTER_ABI,
        functionName: 'cancelExpiredListingBatch',
        args: [expiredUniq],
        log,
        context: `MarketRouter.cancelExpiredListingBatch listings=${expiredUniq.length}`,
      });

      if (!tx.ok) {
        const code = tx.code;
        const isGlobalSkip =
          code === 'paused' || code === 'dry_run' || code === 'pending_guard' || code === 'fee_cap';
        if (isGlobalSkip) {
          abortAll = true;
          if (log)
            log(`listings cancelExpired: global tx skip (${code}); stopping early: ${tx.reason}`);
        }
        for (const tokenId of expiredUniq) {
          cancelResults.push({ tokenId, skipped: true, reason: tx.reason });
        }
      } else {
        const hash = tx.hash as `0x${string}`;
        if (log)
          log(`listings cancelExpired: batch cancelled ${expiredUniq.length} listings tx=${hash}`);
        for (const tokenId of expiredUniq) {
          const tokenIdStr = tokenId.toString();
          if (config.listingsBackoffEnabled && listingFailures[tokenIdStr]) {
            delete listingFailures[tokenIdStr];
          }
          cancelResults.push({ tokenId, hash });
        }
        persistListingsState({
          statePath: config.listingsStatePath,
          state: listingsState,
          listingFailures,
        });
      }
    } catch (e: unknown) {
      const errObj2 = e as { shortMessage?: string; message?: string };
      const err = String(errObj2?.shortMessage ?? errObj2?.message ?? e);
      if (log) log(`listings cancelExpired: batch failed: ${err}`);
      await postAlert(config.alertWebhookUrl, {
        type: 'keeper_error',
        action: 'cancel_expired_listing',
        deployment: config.deployment,
        timestampUtc: nowUtcIso(),
        error: err,
        listings: expiredUniq.map(String),
      });
      for (const tokenId of expiredUniq) {
        cancelResults.push({ tokenId, error: err });
      }
    }
  } else if (config.dryRun && expiredUniq.length > 0) {
    for (const tokenId of expiredUniq) {
      cancelResults.push({ tokenId, dryRun: true });
    }
  }

  // Rebind eligible after filtering out expired.
  const eligibleFinal = eligibleFiltered;

  if (log && eligibleFinal.length) log(`listings sweep: eligible listings=${eligibleFinal.length}`);

  const results: Array<Record<string, unknown>> = [];

  if (abortAll) {
    if (log)
      log(
        'listings sweep: aborted after hitting a global safety rail; skipping eligible listing settles',
      );
  }

  for (const tokenId of eligibleFinal) {
    if (abortAll) break;
    const tokenIdStr = tokenId.toString();

    if (log) log(`listings sweep: tokenId=${tokenIdStr}`);

    // Double-check cooldown at execution time (in case the file changed under us).
    const now2 = Date.now();
    if (
      config.listingsBackoffEnabled &&
      listingFailures[tokenIdStr] &&
      isInCooldown(listingFailures[tokenIdStr], now2)
    ) {
      const untilMs = getCooldownUntilMs(listingFailures[tokenIdStr]);
      const remaining = Math.max(0, untilMs - now2);
      if (log)
        log(
          `listings backoff: skipping tokenId=${tokenIdStr} (cooldown active, retryAt=${formatUtc(untilMs)}, in=${fmtMs(remaining)})`,
        );
      results.push({ tokenId, skipped: true, reason: 'cooldown' });
      continue;
    }

    // Fetch a fresh block timestamp per-listing to avoid stale deadlines when
    // the loop takes a long time (many preflight checks, tx submissions, etc).
    let deadlineBlock: { timestamp: bigint };
    try {
      deadlineBlock = await publicClient.getBlock();
      if (deadlineBlock.timestamp === 0n) {
        deadlineBlock = block;
      }
    } catch {
      deadlineBlock = block;
    }
    const clampedDeadlineSecs = BigInt(
      Math.min(Math.max(config.deadlineSecs, 30), config.liveRun ? MAX_LIVE_DEADLINE_SECS : 3600),
    );
    const deadline = deadlineBlock.timestamp + clampedDeadlineSecs;

    // Preflight: if the call would deterministically revert (ex: quote < minClaimOut),
    // skip broadcasting and throttle the listing via backoff.
    if (config.listingsPreflightEnabled) {
      const pre = await preflightSellListedLockToFurnace({
        publicClient,
        marketRouterAddress,
        tokenId,
        deadline,
        account,
      });

      if (!pre.ok) {
        if (!pre.isRevert) {
          // Non-revert errors (RPC, timeouts, etc) should surface as task errors.
          throw new Error(`listing preflight failed for tokenId=${tokenIdStr}: ${pre.error}`);
        }

        let backoffRec: ListingFailureRecord | null = null;
        if (config.listingsBackoffEnabled) {
          const nowFail = Date.now();
          backoffRec = recordListingFailure({
            listingFailures,
            tokenIdStr,
            nowMs: nowFail,
            err: pre.error,
            errorSig: pre.errorSig,
            config,
            txHash: null,
          });
          persistListingsState({
            statePath: config.listingsStatePath,
            state: listingsState,
            listingFailures,
          });

          if (log) {
            const remaining = Math.max(0, backoffRec.cooldownUntilMs! - nowFail);
            log(
              `listings preflight: tokenId=${tokenIdStr} reverted (sig=${backoffRec.lastErrorSig ?? 'n/a'}). nextRetryAt=${formatUtc(
                backoffRec.cooldownUntilMs!,
              )}, in=${fmtMs(remaining)}`,
            );
          }
        } else if (log) {
          log(
            `listings preflight: skipping tokenId=${tokenIdStr} (reverted; sig=${pre.errorSig ?? 'n/a'})`,
          );
        }

        results.push({
          tokenId,
          skipped: true,
          reason: 'preflight',
          preflight: pre,
          backoff: backoffRec,
        });
        continue;
      }
    }

    if (config.dryRun) {
      results.push({ tokenId, dryRun: true });
      continue;
    }

    // Freshness guard: if preflight was enabled and passed, re-simulate before
    // broadcasting. Pool reserves can shift between the initial eligibility check
    // and tx submission, causing the keeper to settle at a materially worse price.
    if (config.listingsPreflightEnabled) {
      const recheck = await preflightSellListedLockToFurnace({
        publicClient,
        marketRouterAddress,
        tokenId,
        deadline,
        account,
      });
      if (!recheck.ok && recheck.isRevert) {
        if (log)
          log(
            `listings sweep: tokenId=${tokenIdStr} pre-broadcast recheck reverted (sig=${recheck.errorSig ?? 'n/a'}); skipping to avoid bad-price settlement`,
          );
        results.push({ tokenId, skipped: true, reason: 'stale_recheck_revert' });
        continue;
      }
    }

    let hash: `0x${string}` | null = null;
    try {
      const tx = await sendContractTx({
        config,
        publicClient,
        walletClient,
        account,
        address: marketRouterAddress,
        abi: MARKET_ROUTER_ABI,
        functionName: 'sellListedLockToFurnace',
        args: [tokenId, deadline],
        log,
        context: `MarketRouter.sellListedLockToFurnace tokenId=${tokenIdStr}`,
      });

      if (!tx.ok) {
        const skippedAt = nowUtcIso();
        updateStatusFile({
          statusPath: config.statusPath,
          init: statusInit,
          patch: {
            lastSkipAtUtc: skippedAt,
            lastSkipByTask: { sweepListings: skippedAt },
            lastSkipReasonByTask: { sweepListings: tx.reason },
          },
        });

        results.push({ tokenId, skipped: true, reason: tx.reason });

        const code = tx.code;
        const isGlobalSkip =
          code === 'paused' || code === 'dry_run' || code === 'pending_guard' || code === 'fee_cap';
        if (isGlobalSkip) {
          abortAll = true;
          if (log) log(`listings sweep: global tx skip (${code}); stopping early: ${tx.reason}`);
          break;
        }
        continue;
      }

      hash = tx.hash as `0x${string}`;
      const receipt = tx.receipt as any;

      // On success, clear any backoff state for this listing.
      if (config.listingsBackoffEnabled && listingFailures[tokenIdStr]) {
        delete listingFailures[tokenIdStr];
        persistListingsState({
          statePath: config.listingsStatePath,
          state: listingsState,
          listingFailures,
        });
      }

      const successAt = nowUtcIso();
      updateStatusFile({
        statusPath: config.statusPath,
        init: statusInit,
        patch: {
          lastSuccessAtUtc: successAt,
          lastSuccessByTask: { sweepListings: successAt },

          lastTxHash: hash,
          lastTxHashByTask: { sweepListings: hash },

          lastError: null,
          lastErrorByTask: { sweepListings: null },
        },
      });

      results.push({ tokenId, hash, receipt });
    } catch (e: unknown) {
      const errObj3 = e as { shortMessage?: string; message?: string };
      const err = String(errObj3?.shortMessage ?? errObj3?.message ?? e);
      const patch: Record<string, unknown> = {
        lastError: err,
        lastErrorByTask: { sweepListings: err },
      };
      if (hash) {
        patch.lastTxHash = hash;
        patch.lastTxHashByTask = { sweepListings: hash };
      }

      const cur = updateStatusFile({ statusPath: config.statusPath, init: statusInit, patch });

      const bumped = bumpRevertCount(cur, 'sweepListings');
      updateStatusFile({ statusPath: config.statusPath, init: statusInit, patch: bumped });

      let backoffRec: ListingFailureRecord | null = null;
      if (config.listingsBackoffEnabled) {
        const nowFail = Date.now();
        backoffRec = recordListingFailure({
          listingFailures,
          tokenIdStr,
          nowMs: nowFail,
          err,
          config,
          txHash: hash,
        });
        persistListingsState({
          statePath: config.listingsStatePath,
          state: listingsState,
          listingFailures,
        });

        if (log) {
          const remaining = Math.max(0, backoffRec.cooldownUntilMs! - nowFail);
          log(
            `listings backoff: tokenId=${tokenIdStr} failureCount=${backoffRec.count}, nextRetryAt=${formatUtc(
              backoffRec.cooldownUntilMs!,
            )}, in=${fmtMs(remaining)}`,
          );
        }
      }

      await postAlert(config.alertWebhookUrl, {
        type: 'keeper_error',
        action: 'sweep_listings',
        deployment: config.deployment,
        tokenId: tokenIdStr,
        timestampUtc: nowUtcIso(),
        error: err,
        txHash: hash,
        backoff: backoffRec
          ? {
              failureCount: backoffRec.count,
              cooldownUntilUtc: formatUtc(backoffRec.cooldownUntilMs!),
              lastErrorSig: backoffRec.lastErrorSig,
            }
          : null,
      });

      results.push({ tokenId, hash, error: err, backoff: backoffRec });
    }
  }

  // If we ran without any tx submissions (dry-run / preflight / cooldown skips),
  // treat the sweep as a successful health signal.
  const all = [...cancelResults, ...results];
  const anyReceipt = all.some((r) => !!r?.receipt);
  const anyError = all.some((r) => !!r?.error);
  if (!anyReceipt && !anyError) {
    const successAt = nowUtcIso();
    updateStatusFile({
      statusPath: config.statusPath,
      init: statusInit,
      patch: {
        lastSuccessAtUtc: successAt,
        lastSuccessByTask: { sweepListings: successAt },
        lastError: null,
        lastErrorByTask: { sweepListings: null },
      },
    });
  }

  return;
}
