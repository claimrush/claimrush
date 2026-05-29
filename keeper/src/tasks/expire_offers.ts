import type { Address, PublicClient } from 'viem';
import type { PrivateKeyAccount } from 'viem/accounts';

import { MARKET_ROUTER_ABI } from '../shared/abis.js';
import { postAlert } from '../shared/alert.js';
import { sendContractTx } from '../shared/tx.js';
import {
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
import { fmtMs, parseNonNegativeSafeInteger, parseUintBigIntOrNull } from '../shared/utils.js';
import { scanMarketOffers } from './market_discovery.js';
import type { KeeperConfig } from '../shared/config.js';
import type { DeploymentManifest } from '../shared/deployments.js';
import type { ViemClients } from '../shared/clients.js';

// =============================================================================
// EXPIRE OFFERS TASK
// =============================================================================
//
// This task finds expired bonus target escrows and calls cancelExpiredBonusTargetEscrow()
// to refund remaining budget to buyers. This is a cleanup/maintenance task.
// =============================================================================

interface OfferFailureRecord {
  count: number;
  firstFailureAtMs: number;
  lastFailureAtMs: number;
  cooldownUntilMs: number;
  lastErrorSig?: string | null;
  lastError?: string | null;
  lastTxHash?: string | null;
}

function normalizeOfferFailures(v: unknown): Record<string, OfferFailureRecord> {
  if (!v || typeof v !== 'object' || Array.isArray(v)) return {};
  const out: Record<string, OfferFailureRecord> = {};
  for (const [k, rec] of Object.entries(v as Record<string, unknown>)) {
    const id = String(k);
    if (!rec || typeof rec !== 'object' || Array.isArray(rec)) continue;
    const next = { ...(rec as unknown as OfferFailureRecord) };
    if (next.count != null) next.count = parseNonNegativeSafeInteger(next.count) ?? 0;
    if (next.firstFailureAtMs != null) {
      next.firstFailureAtMs = parseNonNegativeSafeInteger(next.firstFailureAtMs) ?? 0;
    }
    if (next.lastFailureAtMs != null) {
      next.lastFailureAtMs = parseNonNegativeSafeInteger(next.lastFailureAtMs) ?? 0;
    }
    if (next.cooldownUntilMs != null) {
      next.cooldownUntilMs = parseNonNegativeSafeInteger(next.cooldownUntilMs) ?? 0;
    }
    out[id] = next;
  }
  return out;
}

function pruneExpireFailures(
  expireFailures: Record<string, OfferFailureRecord>,
  candidatesSet: Set<string>,
): Record<string, OfferFailureRecord> {
  if (!expireFailures || typeof expireFailures !== 'object') return {};
  const out: Record<string, OfferFailureRecord> = {};
  for (const [k, v] of Object.entries(expireFailures)) {
    const id = String(k);
    if (candidatesSet.has(id)) out[id] = v as OfferFailureRecord;
  }
  return out;
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

async function _preflightCancelExpiredOffer({
  publicClient,
  marketRouterAddress,
  offerId,
  account,
}: {
  publicClient: PublicClient;
  marketRouterAddress: Address;
  offerId: bigint;
  account: PrivateKeyAccount;
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
      functionName: 'cancelExpiredBonusTargetEscrow',
      args: [offerId],
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

interface ExpireState {
  version: number;
  expireFailures: Record<string, OfferFailureRecord>;
  [key: string]: unknown;
}

function persistExpireState({
  statePath,
  state,
  expireFailures,
}: {
  statePath: string;
  state: ExpireState | null;
  expireFailures: Record<string, OfferFailureRecord>;
}): ExpireState {
  const next: ExpireState = { ...(state ?? { version: 1, expireFailures: {} }) };
  next.version = Math.max(1, parseNonNegativeSafeInteger(next.version, { defaultValue: 1 }) ?? 1);
  next.expireFailures = expireFailures ?? {};
  saveJsonAtomic(statePath, next);
  return next;
}

function _recordExpireFailure({
  expireFailures,
  offerIdStr,
  nowMs,
  err,
  errorSig,
  config,
  txHash,
}: {
  expireFailures: Record<string, OfferFailureRecord>;
  offerIdStr: string;
  nowMs: number;
  err: string;
  errorSig?: string | null;
  config: KeeperConfig;
  txHash: string | null;
}): OfferFailureRecord {
  const prev = expireFailures[offerIdStr] ?? ({} as Partial<OfferFailureRecord>);
  const prevCount = parseNonNegativeSafeInteger(prev.count, { defaultValue: 0 }) ?? 0;
  const count = prevCount + 1;

  const delayMs = computeExponentialBackoffDelayMs({
    failureCount: count,
    initialMs: config.expireOffersBackoffInitialMs,
    multiplier: config.expireOffersBackoffMultiplier,
    maxMs: config.expireOffersBackoffMaxMs,
    jitterBps: config.expireOffersBackoffJitterBps,
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

  expireFailures[offerIdStr] = rec;
  return rec;
}

/**
 * Filter candidate offers to find expired ones that can be cancelled.
 */
async function filterExpiredOffers({
  publicClient,
  marketRouterAddress,
  candidateOfferIds,
  maxOffers,
  log,
}: {
  publicClient: PublicClient;
  marketRouterAddress: Address;
  candidateOfferIds: string[];
  maxOffers: number;
  log?: ((msg: string) => void) | null;
}): Promise<bigint[]> {
  if (!candidateOfferIds?.length) return [];

  const loggedInvalidIds = new Set<string>();
  const validIds: bigint[] = [];
  for (const idStr of candidateOfferIds) {
    const offerId = parseUintBigIntOrNull(idStr);
    if (offerId == null) {
      if (log && !loggedInvalidIds.has(idStr)) {
        loggedInvalidIds.add(idStr);
        log(
          `expire-offers: invalid offerId in candidates list: ${JSON.stringify(idStr)} (skipping)`,
        );
      }
      continue;
    }
    validIds.push(offerId);
  }
  if (!validIds.length) return [];

  const now: bigint = (await publicClient.getBlock()).timestamp;

  const contracts = validIds.map((offerId) => ({
    address: marketRouterAddress,
    abi: MARKET_ROUTER_ABI,
    functionName: 'offers' as const,
    args: [offerId] as const,
  }));

  const results = await publicClient.multicall({ contracts });

  const out: bigint[] = [];
  for (let i = 0; i < validIds.length && out.length < maxOffers; i++) {
    const r = results[i];
    if (r.status === 'failure') continue;
    const offer = r.result as any;
    const expiresAt: bigint = offer?.[7] ?? 0n;
    const active: boolean = offer?.[8] ?? false;
    if (!active) continue;
    if (expiresAt === 0n || now <= expiresAt) continue;
    out.push(validIds[i]);
  }

  if (log) log(`expire-offers: multicall ${validIds.length} offers → ${out.length} expired`);
  return out;
}

export async function runExpireOffers({
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
      lastAttemptByTask: { expireOffers: attemptAt },
    },
  });

  const marketRouterAddress = getContractAddress(manifest, 'MarketRouter');
  requireNonZeroAddress(marketRouterAddress, 'MarketRouter');

  const { publicClient, walletClient, account } = clients;

  const block = await publicClient.getBlock();

  let startBlock = config.marketStartBlockOverride;
  if (startBlock == null) startBlock = getContractStartBlock(manifest, 'MarketRouter');

  if (!startBlock || startBlock <= 0) {
    const latest = BigInt(block.number);
    const lookback = BigInt(config.marketScanChunkBlocks) * 2n;
    const from = latest > lookback ? latest - lookback + 1n : 1n;
    startBlock = parseNonNegativeSafeInteger(from, { defaultValue: 1 }) ?? 1;
    if (log)
      log(
        `expire-offers startBlock missing/invalid. defaulting to lookback start=${startBlock} (latest=${latest.toString()})`,
      );
  }

  // Reuse existing market scanning to get candidate offers
  const scan = await scanMarketOffers({
    publicClient,
    marketRouterAddress,
    statePath: config.marketStatePath,
    startBlock,
    chunkBlocks: config.marketScanChunkBlocks,
    log,
  });

  // Load expire-specific state for backoff
  const expireStatePath = config.expireOffersStatePath;
  let expireState: ExpireState;
  const expireStateResult = loadJsonDetailed(expireStatePath);
  if (expireStateResult.kind === 'ok' && expireStateResult.value != null) {
    expireState = expireStateResult.value as ExpireState;
  } else if (expireStateResult.kind === 'error') {
    log(
      `WARN: expire_offers state corrupt (${expireStatePath}): ${expireStateResult.error.message}; reinitializing`,
    );
    expireState = { version: 1, expireFailures: {} };
  } else {
    expireState = { version: 1, expireFailures: {} };
  }
  let expireFailures = normalizeOfferFailures(expireState.expireFailures);

  // Prune stale backoff records for offers that are no longer candidates.
  // Prevents unbounded growth of the expire_offers backoff file over long runtimes.
  const candidateSet = new Set<string>(scan.candidates.map(String));
  const beforeCount = Object.keys(expireFailures).length;
  const pruned = pruneExpireFailures(expireFailures, candidateSet);
  const afterCount = Object.keys(pruned).length;
  if (afterCount !== beforeCount) {
    expireFailures = pruned;
    persistExpireState({ statePath: expireStatePath, state: expireState, expireFailures });
    if (log)
      log(
        `expire-offers: pruned ${beforeCount - afterCount} stale backoff records (remaining=${afterCount})`,
      );
  }

  const nowMs = Date.now();

  // Apply cooldown
  let candidateOfferIds: string[] = scan.candidates;
  const skippedCooldown: Array<{ offerId: string; failures: number; cooldownUntilMs: number }> = [];
  if (config.expireOffersBackoffEnabled) {
    candidateOfferIds = [];
    for (const idStr of scan.candidates) {
      const rec = expireFailures[idStr];
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
          `expire-offers backoff: skipping offerId=${s.offerId} (failures=${s.failures}, retryAt=${formatUtc(
            s.cooldownUntilMs,
          )}, in=${fmtMs(remaining)})`,
        );
      }
    }
  }

  // Filter for expired offers
  const expired = await filterExpiredOffers({
    publicClient,
    marketRouterAddress,
    candidateOfferIds,
    maxOffers: config.maxExpireOffers,
    log,
  });

  if (!expired.length) {
    const successAt = nowUtcIso();
    updateStatusFile({
      statusPath: config.statusPath,
      init: statusInit,
      patch: {
        lastSuccessAtUtc: successAt,
        lastSuccessByTask: { expireOffers: successAt },
        lastError: null,
        lastErrorByTask: { expireOffers: null },
      },
    });

    if (skippedCooldown.length) {
      if (log)
        log(
          `expire-offers: 0 expired offers (cooldown active for ${skippedCooldown.length} offers)`,
        );
      return { expired: [], skippedCooldown };
    }
    if (log) log('expire-offers: no expired offers to cancel');
    return { expired: [] };
  }

  if (log) log(`expire-offers: expired offers=${expired.length}`);

  const results: Array<Record<string, unknown>> = [];

  // Filter out cooldown-blocked offers before batching.
  const batchOfferIds: bigint[] = [];
  for (const offerId of expired) {
    const offerIdStr = offerId.toString();
    const now2 = Date.now();
    if (
      config.expireOffersBackoffEnabled &&
      expireFailures[offerIdStr] &&
      isInCooldown(expireFailures[offerIdStr], now2)
    ) {
      const untilMs = getCooldownUntilMs(expireFailures[offerIdStr]);
      const remaining = Math.max(0, untilMs - now2);
      if (log)
        log(
          `expire-offers backoff: skipping offerId=${offerIdStr} (cooldown active, retryAt=${formatUtc(untilMs)}, in=${fmtMs(remaining)})`,
        );
      results.push({ offerId, skipped: true, reason: 'cooldown' });
      continue;
    }
    batchOfferIds.push(offerId);
  }

  if (batchOfferIds.length > 0 && !config.dryRun) {
    try {
      const tx = await sendContractTx({
        config,
        publicClient,
        walletClient,
        account,
        address: marketRouterAddress,
        abi: MARKET_ROUTER_ABI,
        functionName: 'cancelExpiredBonusTargetEscrowBatch',
        args: [batchOfferIds],
        log,
        context: `MarketRouter.cancelExpiredBonusTargetEscrowBatch offers=${batchOfferIds.length}`,
      });

      if (!tx.ok) {
        const skippedAt = nowUtcIso();
        updateStatusFile({
          statusPath: config.statusPath,
          init: statusInit,
          patch: {
            lastSkipAtUtc: skippedAt,
            lastSkipByTask: { expireOffers: skippedAt },
            lastSkipReasonByTask: { expireOffers: tx.reason },
          },
        });
        for (const offerId of batchOfferIds) {
          results.push({ offerId, skipped: true, reason: tx.reason });
        }
      } else {
        const hash = tx.hash as `0x${string}`;
        if (log) log(`expire-offers: batch cancelled ${batchOfferIds.length} offers tx=${hash}`);
        for (const offerId of batchOfferIds) {
          const offerIdStr = offerId.toString();
          if (config.expireOffersBackoffEnabled && expireFailures[offerIdStr]) {
            delete expireFailures[offerIdStr];
          }
          results.push({ offerId, hash });
        }
        persistExpireState({ statePath: expireStatePath, state: expireState, expireFailures });
      }
    } catch (e: unknown) {
      const errObj = e as { shortMessage?: string; message?: string };
      const errMsg = String(errObj?.shortMessage ?? errObj?.message ?? e);
      if (log) log(`expire-offers: batch failed: ${errMsg}`);
      await postAlert(config.alertWebhookUrl, {
        type: 'keeper_error',
        action: 'expire_offers',
        deployment: config.deployment,
        timestampUtc: nowUtcIso(),
        error: errMsg,
        offers: batchOfferIds.map(String),
      });
      for (const offerId of batchOfferIds) {
        results.push({ offerId, error: errMsg });
      }
    }
  } else if (config.dryRun) {
    for (const offerId of batchOfferIds) {
      results.push({ offerId, dryRun: true });
    }
  }

  // If no tx submissions, treat as successful health signal
  const anyHash = results.some((r) => !!r?.hash);
  const anyError = results.some((r) => !!r?.error);
  if (!anyHash && !anyError) {
    const successAt = nowUtcIso();
    updateStatusFile({
      statusPath: config.statusPath,
      init: statusInit,
      patch: {
        lastSuccessAtUtc: successAt,
        lastSuccessByTask: { expireOffers: successAt },
        lastError: null,
        lastErrorByTask: { expireOffers: null },
      },
    });
  }

  return { expired, results, skippedCooldown };
}
