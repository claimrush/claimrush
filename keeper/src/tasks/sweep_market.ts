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
  initMarketState,
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
import { scanMarketOffers, filterEligibleAutoFurnaceOffers } from './market_discovery.js';

interface OfferFailureRecord {
  count?: number;
  firstFailureAtMs?: number;
  lastFailureAtMs?: number;
  cooldownUntilMs?: number;
  lastErrorSig?: string | null;
  lastError?: string;
  lastTxHash?: string | null;
}

interface OfferFailures {
  [offerId: string]: OfferFailureRecord;
}

interface PreflightResult {
  ok: boolean;
  isRevert?: boolean;
  errorSig?: string | null;
  error?: string;
}

interface RecordFailureOpts {
  offerFailures: OfferFailures;
  offerIdStr: string;
  nowMs: number;
  err: string | unknown;
  errorSig?: string | null;
  config: KeeperConfig;
  txHash?: string | null;
}

interface SweepMarketOpts {
  config: KeeperConfig;
  manifest: DeploymentManifest;
  clients: ViemClients;
  log: (msg: string) => void;
}

function normalizeOfferFailures(v: unknown): OfferFailures {
  if (!v || typeof v !== 'object' || Array.isArray(v)) return {};
  const out: OfferFailures = {};
  for (const [k, rec] of Object.entries(v as Record<string, unknown>)) {
    const id = String(k);
    if (!rec || typeof rec !== 'object' || Array.isArray(rec)) continue;
    const next: OfferFailureRecord = { ...rec };
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

async function preflightExecuteAutoFurnace({
  publicClient,
  marketRouterAddress,
  // *current* state, but the actual tx is submitted in a later block. Between
  // preflight and execution:
  //   - The offer could be cancelled by the buyer
  //   - The bonus target could be met by another keeper/bot
  //   - Pool reserves could shift, changing the furnace quote
  //
  // A false-positive preflight wastes gas on a reverting tx. A false-negative
  // preflight skips a valid opportunity and puts it in backoff cooldown.
  // Suggested fix: treat preflight failures as ADVISORY only — do not apply
  // full backoff on preflight reverts (use a shorter cooldown).
  offerId,
  deadline,
  account,
}: {
  publicClient: PublicClient;
  marketRouterAddress: Address;
  offerId: bigint;
  deadline: bigint;
  account: PrivateKeyAccount;
}): Promise<PreflightResult> {
  try {
    await publicClient.simulateContract({
      address: marketRouterAddress,
      abi: MARKET_ROUTER_ABI,
      functionName: 'executeAutoFurnace',
      args: [offerId, deadline],
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

function getCooldownUntilMs(rec: OfferFailureRecord | undefined): number {
  return parseNonNegativeSafeInteger(rec?.cooldownUntilMs, { defaultValue: 0 }) ?? 0;
}

function isInCooldown(rec: OfferFailureRecord | undefined, nowMs: number): boolean {
  return getCooldownUntilMs(rec) > nowMs;
}

function formatUtc(ms: number): string {
  try {
    return new Date(ms).toISOString();
  } catch {
    return String(ms);
  }
}

function persistMarketState({
  statePath,
  state,
  offerFailures,
}: {
  statePath: string;
  state: Record<string, unknown> | null;
  offerFailures: OfferFailures;
}): Record<string, unknown> {
  const next = { ...(state ?? initMarketState()) };
  next.version = Math.max(2, parseNonNegativeSafeInteger(next.version, { defaultValue: 1 }) ?? 1);
  next.offerFailures = offerFailures ?? {};
  saveJsonAtomic(statePath, next);
  return next;
}

function recordAutoFurnaceFailure({
  offerFailures,
  offerIdStr,
  nowMs,
  err,
  errorSig,
  config,
  txHash,
}: RecordFailureOpts): OfferFailureRecord {
  const prev = offerFailures[offerIdStr] ?? {};
  const prevCount = parseNonNegativeSafeInteger(prev.count, { defaultValue: 0 }) ?? 0;
  const count = prevCount + 1;

  const delayMs = computeExponentialBackoffDelayMs({
    failureCount: count,
    initialMs: config.autoFurnaceBackoffInitialMs,
    multiplier: config.autoFurnaceBackoffMultiplier,
    maxMs: config.autoFurnaceBackoffMaxMs,
    jitterBps: config.autoFurnaceBackoffJitterBps,
  });

  const cooldownUntilMs = nowMs + delayMs;

  const rec: OfferFailureRecord = {
    count,
    firstFailureAtMs:
      parseNonNegativeSafeInteger(prev.firstFailureAtMs, { defaultValue: nowMs }) ?? nowMs,
    lastFailureAtMs: nowMs,
    cooldownUntilMs,
    lastErrorSig: errorSig ?? extractErrorSig(err),
    lastError: truncate(err, 1024),
    lastTxHash: txHash ?? prev.lastTxHash ?? null,
  };

  offerFailures[offerIdStr] = rec;
  return rec;
}

export async function runSweepMarket({
  config,
  manifest,
  clients,
  log,
}: SweepMarketOpts): Promise<void> {
  const chainId = parseChainIdStrict(manifest?.chainId) ?? 0;
  const statusInit = () => initStatusState({ deployment: config.deployment, chainId });

  const attemptAt = nowUtcIso();

  updateStatusFile({
    statusPath: config.statusPath,
    init: statusInit,
    patch: {
      lastAttemptAtUtc: attemptAt,
      lastAttemptByTask: { autoFurnace: attemptAt },
    },
  });

  const marketRouterAddress = getContractAddress(manifest, 'MarketRouter');
  requireNonZeroAddress(marketRouterAddress, 'MarketRouter');

  const { publicClient, walletClient, account } = clients;

  const block = await publicClient.getBlock();
  const clampedDeadlineSecs = BigInt(
    Math.min(Math.max(config.deadlineSecs, 30), config.liveRun ? MAX_LIVE_DEADLINE_SECS : 3600),
  );
  const deadline = block.timestamp + clampedDeadlineSecs;

  let startBlock = config.marketStartBlockOverride;
  if (startBlock == null) startBlock = getContractStartBlock(manifest, 'MarketRouter');

  // If no start block is known, default to a small lookback window so we don't miss
  // newly-created offers on the first keeper run.
  if (!startBlock || startBlock <= 0) {
    const latest = BigInt(block.number);
    const lookback = BigInt(config.marketScanChunkBlocks) * 2n;
    const from = latest > lookback ? latest - lookback + 1n : 1n;
    startBlock = parseNonNegativeSafeInteger(from, { defaultValue: 1 }) ?? 1;
    if (log)
      log(
        `market startBlock missing/invalid. defaulting to lookback start=${startBlock} (latest=${latest.toString()})`,
      );
  }

  const scan = await scanMarketOffers({
    publicClient,
    marketRouterAddress,
    statePath: config.marketStatePath,
    startBlock,
    chunkBlocks: config.marketScanChunkBlocks,
    log,
  });

  // Load persisted market state so we can apply per-offer backoff/cooldown.
  let marketState: Record<string, unknown>;
  const marketStateResult = loadJsonDetailed(config.marketStatePath);
  if (marketStateResult.kind === 'ok' && marketStateResult.value != null) {
    marketState = marketStateResult.value as Record<string, unknown>;
  } else if (marketStateResult.kind === 'error') {
    log(
      `WARN: market state file corrupt (${config.marketStatePath}): ${marketStateResult.error.message}; reinitializing`,
    );
    marketState = initMarketState() as unknown as Record<string, unknown>;
  } else {
    marketState = initMarketState() as unknown as Record<string, unknown>;
  }
  const offerFailures = normalizeOfferFailures(
    (marketState as Record<string, unknown>).offerFailures,
  );

  // Defensive prune (scan already prunes, but keep state tidy if older versions exist).
  const candSet = new Set(Array.isArray(scan?.candidates) ? scan.candidates.map(String) : []);
  for (const k of Object.keys(offerFailures)) {
    if (!candSet.has(k)) delete offerFailures[k];
  }

  const nowMs = Date.now();

  // Apply cooldown before eligibility checks so we can still attempt up to maxOffers.
  let candidateOfferIds = scan.candidates;
  const skippedCooldown: Array<{ offerId: string; failures: number; cooldownUntilMs: number }> = [];
  if (config.autoFurnaceBackoffEnabled) {
    candidateOfferIds = [];
    for (const idStr of scan.candidates) {
      const rec = offerFailures[idStr];
      if (rec && isInCooldown(rec, nowMs)) {
        skippedCooldown.push({
          offerId: idStr,
          failures: parseNonNegativeSafeInteger(rec.count, { defaultValue: 0 }) ?? 0,
          cooldownUntilMs: getCooldownUntilMs(rec),
        });
        continue;
      }
      candidateOfferIds.push(idStr);
    }

    if (skippedCooldown.length && log) {
      for (const s of skippedCooldown) {
        const remaining = Math.max(0, s.cooldownUntilMs - nowMs);
        log(
          `market backoff: skipping offerId=${s.offerId} (failures=${s.failures}, retryAt=${formatUtc(
            s.cooldownUntilMs,
          )}, in=${fmtMs(remaining)})`,
        );
      }
    }
  }

  const eligible = await filterEligibleAutoFurnaceOffers({
    publicClient,
    marketRouterAddress,
    candidateOfferIds,
    maxOffers: config.maxOffers,
    log,
  });

  if (!eligible.length) {
    // No-op sweep still counts as a successful run for monitoring.
    const successAt = nowUtcIso();
    updateStatusFile({
      statusPath: config.statusPath,
      init: statusInit,
      patch: {
        lastSuccessAtUtc: successAt,
        lastSuccessByTask: { autoFurnace: successAt },
        lastError: null,
        lastErrorByTask: { autoFurnace: null },
      },
    });

    if (skippedCooldown.length) {
      if (log)
        log(
          `market sweep: 0 eligible offers (cooldown active for ${skippedCooldown.length} offers)`,
        );
      return;
    }
    if (log) log('market sweep: no eligible offers');
    return;
  }

  if (log) log(`market sweep: eligible offers=${eligible.length}`);

  const results: Array<Record<string, unknown>> = [];

  for (const offerId of eligible) {
    const offerIdStr = offerId.toString();

    if (log) log(`market sweep: offerId=${offerIdStr}`);

    // Double-check cooldown at execution time (in case the file changed under us).
    const now2 = Date.now();
    if (
      config.autoFurnaceBackoffEnabled &&
      offerFailures[offerIdStr] &&
      isInCooldown(offerFailures[offerIdStr], now2)
    ) {
      const untilMs = getCooldownUntilMs(offerFailures[offerIdStr]);
      const remaining = Math.max(0, untilMs - now2);
      if (log)
        log(
          `market backoff: skipping offerId=${offerIdStr} (cooldown active, retryAt=${formatUtc(untilMs)}, in=${fmtMs(remaining)})`,
        );
      results.push({ offerId, skipped: true, reason: 'cooldown' });
      continue;
    }

    // Preflight: if the call would deterministically revert (ex: bonus target not met yet),
    // skip broadcasting and throttle the offer via backoff.
    if (config.autoFurnacePreflightEnabled) {
      const pre = await preflightExecuteAutoFurnace({
        publicClient,
        marketRouterAddress,
        offerId,
        deadline,
        account,
      });

      if (!pre.ok) {
        if (!pre.isRevert) {
          // Non-revert errors (RPC, timeouts, etc) should surface as task errors.
          throw new Error(`auto-furnace preflight failed for offerId=${offerIdStr}: ${pre.error}`);
        }

        let backoffRec: OfferFailureRecord | null = null;
        if (config.autoFurnaceBackoffEnabled) {
          const nowFail = Date.now();
          backoffRec = recordAutoFurnaceFailure({
            offerFailures,
            offerIdStr,
            nowMs: nowFail,
            err: pre.error,
            errorSig: pre.errorSig,
            config,
            txHash: null,
          });
          persistMarketState({
            statePath: config.marketStatePath,
            state: marketState,
            offerFailures,
          });

          if (log) {
            const remaining = Math.max(0, backoffRec.cooldownUntilMs! - nowFail);
            log(
              `market preflight: offerId=${offerIdStr} reverted (sig=${backoffRec.lastErrorSig ?? 'n/a'}). nextRetryAt=${formatUtc(
                backoffRec.cooldownUntilMs!,
              )}, in=${fmtMs(remaining)}`,
            );
          }
        } else if (log) {
          log(
            `market preflight: skipping offerId=${offerIdStr} (reverted; sig=${pre.errorSig ?? 'n/a'})`,
          );
        }

        results.push({
          offerId,
          skipped: true,
          reason: 'preflight',
          preflight: pre,
          backoff: backoffRec,
        });
        continue;
      }
    }

    if (config.dryRun) {
      results.push({ offerId, dryRun: true });
      continue;
    }

    // Freshness guard: if preflight was enabled and passed, re-simulate before
    // broadcasting. Pool reserves can shift between the initial eligibility check
    // and tx submission, causing the keeper to settle at a materially worse price.
    if (config.autoFurnacePreflightEnabled) {
      const recheck = await preflightExecuteAutoFurnace({
        publicClient,
        marketRouterAddress,
        offerId,
        deadline,
        account,
      });
      if (!recheck.ok && recheck.isRevert) {
        if (log)
          log(
            `market sweep: offerId=${offerIdStr} pre-broadcast recheck reverted (sig=${recheck.errorSig ?? 'n/a'}); skipping to avoid bad-price settlement`,
          );
        results.push({ offerId, skipped: true, reason: 'stale_recheck_revert' });
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
        functionName: 'executeAutoFurnace',
        args: [offerId, deadline],
        log,
        context: `MarketRouter.executeAutoFurnace offerId=${offerIdStr}`,
      });

      if (!tx.ok) {
        const skippedAt = nowUtcIso();
        updateStatusFile({
          statusPath: config.statusPath,
          init: statusInit,
          patch: {
            lastSkipAtUtc: skippedAt,
            lastSkipByTask: { autoFurnace: skippedAt },
            lastSkipReasonByTask: { autoFurnace: tx.reason },
          },
        });

        results.push({ offerId, skipped: true, reason: tx.reason });

        // Some skips are GLOBAL (nothing will succeed until conditions change).
        // Stop early to avoid spamming logs + status updates for every offer.
        const code = tx.code;
        const isGlobalSkip =
          code === 'paused' || code === 'dry_run' || code === 'pending_guard' || code === 'fee_cap';
        if (isGlobalSkip) {
          if (log) log(`market sweep: global tx skip (${code}); stopping early: ${tx.reason}`);
          break;
        }
        continue;
      }

      hash = tx.hash as `0x${string}`;
      const receipt = tx.receipt as any;

      // On success, clear any backoff state for this offer.
      if (config.autoFurnaceBackoffEnabled && offerFailures[offerIdStr]) {
        delete offerFailures[offerIdStr];
        persistMarketState({
          statePath: config.marketStatePath,
          state: marketState,
          offerFailures,
        });
      }

      const successAt = nowUtcIso();
      updateStatusFile({
        statusPath: config.statusPath,
        init: statusInit,
        patch: {
          lastSuccessAtUtc: successAt,
          lastSuccessByTask: { autoFurnace: successAt },

          lastTxHash: hash,
          lastTxHashByTask: { autoFurnace: hash },

          lastError: null,
          lastErrorByTask: { autoFurnace: null },
        },
      });

      results.push({ offerId, hash, receipt });
    } catch (e: unknown) {
      const errObj = e as { shortMessage?: string; message?: string };
      const err = String(errObj?.shortMessage ?? errObj?.message ?? e);
      const patch: Record<string, unknown> = {
        lastError: err,
        lastErrorByTask: { autoFurnace: err },
      };
      if (hash) {
        patch.lastTxHash = hash;
        patch.lastTxHashByTask = { autoFurnace: hash };
      }

      const cur = updateStatusFile({ statusPath: config.statusPath, init: statusInit, patch });

      const bumped = bumpRevertCount(cur, 'autoFurnace');
      updateStatusFile({ statusPath: config.statusPath, init: statusInit, patch: bumped });

      let backoffRec: OfferFailureRecord | null = null;
      if (config.autoFurnaceBackoffEnabled) {
        const nowFail = Date.now();
        backoffRec = recordAutoFurnaceFailure({
          offerFailures,
          offerIdStr,
          nowMs: nowFail,
          err,
          config,
          txHash: hash,
        });
        persistMarketState({
          statePath: config.marketStatePath,
          state: marketState,
          offerFailures,
        });

        if (log) {
          const remaining = Math.max(0, backoffRec.cooldownUntilMs! - nowFail);
          log(
            `market backoff: offerId=${offerIdStr} failureCount=${backoffRec.count}, nextRetryAt=${formatUtc(
              backoffRec.cooldownUntilMs!,
            )}, in=${fmtMs(remaining)}`,
          );
        }
      }

      await postAlert(config.alertWebhookUrl, {
        type: 'keeper_error',
        action: 'auto_furnace',
        deployment: config.deployment,
        offerId: offerIdStr,
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

      results.push({ offerId, hash, error: err, backoff: backoffRec });
    }
  }

  // If we ran without any tx submissions (dry-run / preflight / cooldown skips),
  // treat the sweep as a successful health signal.
  const anyReceipt = results.some((r) => !!r?.receipt);
  const anyError = results.some((r) => !!r?.error);
  if (!anyReceipt && !anyError) {
    const successAt = nowUtcIso();
    updateStatusFile({
      statusPath: config.statusPath,
      init: statusInit,
      patch: {
        lastSuccessAtUtc: successAt,
        lastSuccessByTask: { autoFurnace: successAt },
        lastError: null,
        lastErrorByTask: { autoFurnace: null },
      },
    });
  }

  return;
}
