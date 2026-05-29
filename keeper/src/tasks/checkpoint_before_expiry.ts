/**
 * Checkpoint-before-expiry keeper.
 *
 * Finds non-autoMax locks expiring in the next N hours and calls
 * ShareholderRoyalties.checkpointUser(owner) to pre-materialize rewards.
 *
 * After the historical-flush-aware ShareholderRoyalties fix, this task is no longer
 * required for reward correctness. It is now an optional UX / gas-smoothing helper
 * for users and indexers that prefer balances to be crystallized before expiry.
 */

import type { KeeperConfig } from '../shared/config.js';
import type { DeploymentManifest } from '../shared/deployments.js';
import type { ViemClients } from '../shared/clients.js';
import type { Address, PublicClient } from 'viem';

import { parseAbiItem } from 'viem';

import { SHAREHOLDER_ROYALTIES_ABI, VE_CLAIM_NFT_ABI } from '../shared/abis.js';
import { postAlert } from '../shared/alert.js';
import { sendContractTx } from '../shared/tx.js';
import { getLogsWithAutoSplit } from '../shared/rpc_logs.js';
import {
  initStatusState,
  loadJson,
  nowUtcIso,
  saveJsonAtomic,
  updateStatusFile,
} from '../shared/state.js';
import {
  getContractAddress,
  getContractStartBlock,
  requireNonZeroAddress,
} from '../shared/deployments.js';
import { parseChainIdStrict } from '../shared/chainId.js';
import { parseNonNegativeSafeInteger } from '../shared/utils.js';
import { EVT_AUTOMAX_SET, resolveLockInfoForEvent } from '../shared/lock_events.js';

const EVT_LOCK_CREATED = parseAbiItem(
  'event LockCreated(address indexed user, uint256 indexed tokenId, uint256 amount, uint256 lockEnd, bool autoMax)',
);
const EVT_LOCK_EXTENDED = parseAbiItem(
  'event LockExtended(address indexed user, uint256 indexed tokenId, uint256 oldEnd, uint256 newEnd)',
);
const EVT_LOCK_UNLOCKED = parseAbiItem(
  'event LockUnlocked(address indexed user, uint256 indexed tokenId, uint256 amountReturned)',
);
const EVT_LOCK_MERGED = parseAbiItem(
  'event LockMerged(address indexed user, uint256 indexed fromTokenId, uint256 indexed intoTokenId, uint256 amountMoved)',
);

const CHAIN_REWIND_TOLERANCE = 64n;
const SCAN_OVERLAP_BLOCKS = CHAIN_REWIND_TOLERANCE;
const DEFAULT_EXPIRY_WINDOW_SECS = 24 * 60 * 60; // 24h
const DEFAULT_MAX_USERS_PER_RUN = 50;

interface CheckpointOpts {
  config: KeeperConfig;
  manifest: DeploymentManifest;
  clients: ViemClients;
  log: (msg: string) => void;
}

interface LockRecord {
  lockEnd: string;
  autoMax: boolean;
}

interface CheckpointState {
  version: number;
  lastScannedBlock: string;
  locks: Record<string, LockRecord>;
  lastCheckpointedAt: Record<string, number>;
}

function addrNorm(a: unknown): string {
  return String(a ?? '').toLowerCase();
}

function initState(): CheckpointState {
  return {
    version: 1,
    lastScannedBlock: '0',
    locks: {},
    lastCheckpointedAt: {},
  };
}

function loadState(statePath: string): CheckpointState {
  const raw = loadJson(statePath, { fallback: null }) as Record<string, unknown> | null;
  if (!raw || typeof raw !== 'object') return initState();
  const out = initState();
  try {
    const last = String(raw.lastScannedBlock ?? '0');
    BigInt(last);
    out.lastScannedBlock = last;
  } catch {
    out.lastScannedBlock = '0';
  }
  if (raw.locks && typeof raw.locks === 'object' && !Array.isArray(raw.locks)) {
    out.locks = { ...raw.locks };
  }
  if (
    raw.lastCheckpointedAt &&
    typeof raw.lastCheckpointedAt === 'object' &&
    !Array.isArray(raw.lastCheckpointedAt)
  ) {
    const SEVEN_DAYS_MS = 7 * 24 * 60 * 60 * 1000;
    const nowMs = Date.now();
    const entries = raw.lastCheckpointedAt as Record<string, number>;
    for (const [owner, ts] of Object.entries(entries)) {
      if (typeof ts === 'number' && nowMs - ts < SEVEN_DAYS_MS) {
        out.lastCheckpointedAt[owner] = ts;
      }
    }
  }
  return out;
}

function saveState(statePath: string, state: CheckpointState): void {
  saveJsonAtomic(statePath, state);
}

async function scanLockEvents({
  publicClient,
  veAddress,
  statePath,
  startBlock,
  chunkBlocks,
  log,
}: {
  publicClient: PublicClient;
  veAddress: Address;
  statePath: string;
  startBlock: number;
  chunkBlocks: number;
  log: (msg: string) => void;
}): Promise<{ state: CheckpointState; scannedTo: bigint }> {
  let state = loadState(statePath);
  const latest: bigint = await publicClient.getBlockNumber();

  let lastScanned: bigint;
  try {
    lastScanned = BigInt(state.lastScannedBlock ?? '0');
  } catch {
    lastScanned = 0n;
  }
  if (lastScanned > latest + CHAIN_REWIND_TOLERANCE) {
    if (log) log(`checkpoint-before-expiry: chain rewind, resetting state`);
    state = initState();
    lastScanned = 0n;
  }

  const start = BigInt(Math.max(0, startBlock));
  const resumeFrom =
    lastScanned > 0n
      ? lastScanned + 1n > SCAN_OVERLAP_BLOCKS
        ? lastScanned + 1n - SCAN_OVERLAP_BLOCKS
        : 0n
      : start;
  const from0 = resumeFrom > start ? resumeFrom : start;
  if (from0 > latest) {
    return { state, scannedTo: latest };
  }

  // Floor of 1 (not 100): providers with strict eth_getLogs limits (e.g.
  // Alchemy free-tier on Base Sepolia caps ranges at 10 blocks) need the env
  // chunk to be honoured.  See automax_bonus.ts for details.
  const chunk = BigInt(
    Math.max(1, parseNonNegativeSafeInteger(chunkBlocks, { defaultValue: 1000 }) ?? 1000),
  );
  let from = from0;
  const locks: Record<string, LockRecord> = { ...(state.locks ?? {}) };

  while (from <= latest) {
    const to = from + chunk - 1n > latest ? latest : from + chunk - 1n;

    const [created, extended, unlocked, merged, automaxSet] = await Promise.all([
      getLogsWithAutoSplit({
        publicClient,
        request: {
          address: veAddress,
          event: EVT_LOCK_CREATED,
          fromBlock: from,
          toBlock: to,
        },
        log,
      }),
      getLogsWithAutoSplit({
        publicClient,
        request: {
          address: veAddress,
          event: EVT_LOCK_EXTENDED,
          fromBlock: from,
          toBlock: to,
        },
        log,
      }),
      getLogsWithAutoSplit({
        publicClient,
        request: {
          address: veAddress,
          event: EVT_LOCK_UNLOCKED,
          fromBlock: from,
          toBlock: to,
        },
        log,
      }),
      getLogsWithAutoSplit({
        publicClient,
        request: {
          address: veAddress,
          event: EVT_LOCK_MERGED,
          fromBlock: from,
          toBlock: to,
        },
        log,
      }),
      getLogsWithAutoSplit({
        publicClient,
        request: {
          address: veAddress,
          event: EVT_AUTOMAX_SET,
          fromBlock: from,
          toBlock: to,
        },
        log,
      }),
    ]);

    type LockEvtKind = 'created' | 'extended' | 'unlocked' | 'merged' | 'automax';
    type LockEvt = { kind: LockEvtKind; l: any };

    const events: LockEvt[] = [];
    for (const l of created) events.push({ kind: 'created', l });
    for (const l of extended) events.push({ kind: 'extended', l });
    for (const l of unlocked) events.push({ kind: 'unlocked', l });
    for (const l of merged) events.push({ kind: 'merged', l });
    for (const l of automaxSet) events.push({ kind: 'automax', l });

    // Apply in chain order (blockNumber, logIndex) so state stays consistent
    // when multiple event types appear in the same scan chunk.
    events.sort((a, b) => {
      const abn = (a.l as any)?.blockNumber != null ? BigInt((a.l as any).blockNumber) : 0n;
      const bbn = (b.l as any)?.blockNumber != null ? BigInt((b.l as any).blockNumber) : 0n;
      if (abn < bbn) return -1;
      if (abn > bbn) return 1;
      const ali = (a.l as any)?.logIndex != null ? BigInt((a.l as any).logIndex) : 0n;
      const bli = (b.l as any)?.logIndex != null ? BigInt((b.l as any).logIndex) : 0n;
      if (ali < bli) return -1;
      if (ali > bli) return 1;
      return 0;
    });

    for (const { kind, l } of events) {
      if (kind === 'created') {
        const tokenId = l.args?.tokenId?.toString();
        if (!tokenId) continue;
        locks[tokenId] = {
          lockEnd: String(l.args?.lockEnd ?? 0),
          autoMax: !!l.args?.autoMax,
        };
        continue;
      }

      if (kind === 'extended') {
        const tokenId = l.args?.tokenId?.toString();
        if (!tokenId) continue;
        const newEnd = l.args?.newEnd;
        if (locks[tokenId]) {
          locks[tokenId] = { ...locks[tokenId], lockEnd: String(newEnd ?? 0) };
        } else {
          // If we started scanning after creation, create a placeholder entry.
          // (Owner selection re-reads getLockInfo and will filter autoMax/empty locks.)
          locks[tokenId] = { lockEnd: String(newEnd ?? 0), autoMax: false };
        }
        continue;
      }

      if (kind === 'unlocked') {
        const tokenId = l.args?.tokenId?.toString();
        if (tokenId) delete locks[tokenId];
        continue;
      }

      if (kind === 'merged') {
        const fromId = l.args?.fromTokenId?.toString();
        const intoId = l.args?.intoTokenId?.toString();
        if (fromId) delete locks[fromId];

        if (!intoId) continue;

        // NOTE: LockMerged only emits amountMoved (no newEnd). Refresh the destination lock state
        // at the merge block so our local lockEnd/autoMax cache stays accurate.
        try {
          const info = await publicClient.readContract({
            address: veAddress,
            abi: VE_CLAIM_NFT_ABI,
            functionName: 'getLockInfo',
            args: [BigInt(intoId)],
            blockNumber: l.blockNumber,
          });
          const amount: bigint = info?.[0] ?? 0n;
          const lockEnd: bigint = info?.[1] ?? 0n;
          const autoMax: boolean = !!info?.[2];

          if (amount === 0n) {
            delete locks[intoId];
          } else {
            locks[intoId] = { lockEnd: lockEnd.toString(), autoMax };
          }
        } catch {
          // Best effort: if the read fails, keep existing cache entry.
        }
        continue;
      }

      if (kind === 'automax') {
        const tokenId = l.args?.tokenId?.toString();
        if (!tokenId) continue;
        const eventAutoMax = !!l.args?.autoMax;

        const resolved = await resolveLockInfoForEvent({
          publicClient,
          veAddress,
          tokenId: BigInt(tokenId),
          blockNumber: l.blockNumber ?? null,
        });

        if (resolved && resolved.amount === 0n) {
          delete locks[tokenId];
        } else if (resolved) {
          locks[tokenId] = { lockEnd: resolved.lockEnd.toString(), autoMax: resolved.autoMax };
        } else {
          locks[tokenId] = {
            lockEnd: locks[tokenId]?.lockEnd ?? '0',
            autoMax: eventAutoMax,
          };
        }
      }
    }

    state = { ...state, lastScannedBlock: to.toString(), locks };
    saveState(statePath, state);
    from = to + 1n;
  }

  return { state, scannedTo: latest };
}

async function selectOwnersToCheckpoint({
  publicClient,
  veAddress,
  state,
  nowTs,
  windowSecs,
  maxUsers,
  log: _log,
}: {
  publicClient: PublicClient;
  veAddress: Address;
  state: CheckpointState;
  nowTs: bigint;
  windowSecs: number;
  maxUsers: number;
  log: (msg: string) => void;
}): Promise<string[]> {
  const locks = state.locks ?? {};
  const now = BigInt(nowTs);
  const end = now + BigInt(windowSecs);
  const owners = new Set<string>();
  const tokenIds = Object.keys(locks);

  // Prioritize locks expiring soonest so we don't starve near-expiry users when maxUsers is low.
  const candidates: Array<{ tokenId: string; lockEnd: bigint }> = [];
  for (const tokenIdStr of tokenIds) {
    const rec = locks[tokenIdStr];
    if (!rec || rec.autoMax) continue;
    let lockEnd: bigint;
    try {
      lockEnd = BigInt(rec.lockEnd ?? 0);
    } catch {
      continue;
    }
    if (lockEnd <= now || lockEnd > end) continue;
    candidates.push({ tokenId: tokenIdStr, lockEnd });
  }

  candidates.sort((a, b) => (a.lockEnd < b.lockEnd ? -1 : a.lockEnd > b.lockEnd ? 1 : 0));

  for (const c of candidates) {
    if (owners.size >= maxUsers) break;
    const tokenIdStr = c.tokenId;

    try {
      const [owner, info] = await Promise.all([
        publicClient.readContract({
          address: veAddress,
          abi: VE_CLAIM_NFT_ABI,
          functionName: 'ownerOf',
          args: [BigInt(tokenIdStr)],
        }),
        publicClient.readContract({
          address: veAddress,
          abi: VE_CLAIM_NFT_ABI,
          functionName: 'getLockInfo',
          args: [BigInt(tokenIdStr)],
        }),
      ]);
      if (!owner || isZero(owner)) continue;
      const amount: bigint = info?.[0] ?? 0n;
      const currentEnd: bigint = info?.[1] ?? 0n;
      const autoMax: boolean = !!info?.[2];
      if (amount === 0n || autoMax) continue;
      if (currentEnd <= now || currentEnd > end) continue;
      owners.add(addrNorm(owner));
    } catch {
      // Lock may be burned or invalid; skip. Scan will drop it on next LockUnlocked.
    }
  }

  const COOLDOWN_MS = 172800 * 1000; // 48h
  const nowMs = Date.now();
  const filtered = [...owners].filter((owner) => {
    const lastTs = state.lastCheckpointedAt?.[owner] ?? 0;
    return nowMs - lastTs >= COOLDOWN_MS;
  });

  return filtered.slice(0, maxUsers);
}

function isZero(addr: unknown): boolean {
  return !addr || addrNorm(addr) === '0x0000000000000000000000000000000000000000';
}

export async function runCheckpointBeforeExpiry({
  config,
  manifest,
  clients,
  log,
}: CheckpointOpts): Promise<void> {
  const chainId = parseChainIdStrict(manifest?.chainId) ?? 0;
  const statusInit = () => initStatusState({ deployment: config.deployment, chainId });

  const attemptAt = nowUtcIso();
  updateStatusFile({
    statusPath: config.statusPath,
    init: statusInit,
    patch: {
      lastAttemptAtUtc: attemptAt,
      lastAttemptByTask: { checkpointBeforeExpiry: attemptAt },
    },
  });

  const veAddress = getContractAddress(manifest, 'VeClaimNFT');
  const srAddress = getContractAddress(manifest, 'ShareholderRoyalties');
  requireNonZeroAddress(veAddress, 'VeClaimNFT');
  requireNonZeroAddress(srAddress, 'ShareholderRoyalties');

  const { publicClient, walletClient, account } = clients;
  const statePath = config.checkpointBeforeExpiryStatePath;
  const startBlock: number =
    config.checkpointBeforeExpiryStartBlock ?? getContractStartBlock(manifest, 'VeClaimNFT');
  const chunkBlocks: number =
    config.checkpointBeforeExpiryScanChunkBlocks ?? config.compoundScanChunkBlocks ?? 2000;
  const windowSecs = config.checkpointBeforeExpiryWindowSecs ?? DEFAULT_EXPIRY_WINDOW_SECS;
  const maxUsers = config.checkpointBeforeExpiryMaxUsers ?? DEFAULT_MAX_USERS_PER_RUN;

  let scanStart = startBlock;
  if (!scanStart || scanStart <= 0) {
    const latest: bigint = await publicClient.getBlockNumber();
    scanStart = Math.max(
      0,
      (parseNonNegativeSafeInteger(latest, { defaultValue: 0 }) ?? 0) - 50000,
    );
  }

  const scan = await scanLockEvents({
    publicClient,
    veAddress,
    statePath,
    startBlock: scanStart,
    chunkBlocks,
    log,
  });

  const block = await publicClient.getBlock();
  const nowTs: bigint = block.timestamp;
  const owners = await selectOwnersToCheckpoint({
    publicClient,
    veAddress,
    state: scan.state,
    nowTs,
    windowSecs,
    maxUsers,
    log,
  });

  if (!owners.length) {
    const successAt = nowUtcIso();
    updateStatusFile({
      statusPath: config.statusPath,
      init: statusInit,
      patch: {
        lastSuccessAtUtc: successAt,
        lastSuccessByTask: { checkpointBeforeExpiry: successAt },
        lastError: null,
        lastErrorByTask: { checkpointBeforeExpiry: null },
      },
    });
    return;
  }

  if (log)
    log(
      `checkpoint-before-expiry: checkpointing ${owners.length} owners (locks expiring in ${windowSecs}s)`,
    );

  if (config.dryRun) {
    updateStatusFile({
      statusPath: config.statusPath,
      init: statusInit,
      patch: {
        lastSuccessAtUtc: attemptAt,
        lastSuccessByTask: { checkpointBeforeExpiry: attemptAt },
        lastError: null,
        lastErrorByTask: { checkpointBeforeExpiry: null },
      },
    });
    return;
  }

  let _successCount = 0;
  let lastError: string | null = null;
  let lastSkipReason: string | null = null;
  let lastSkipAtUtc: string | null = null;

  // Batch checkpoint all owners in a single transaction.
  try {
    const tx = await sendContractTx({
      config,
      publicClient,
      walletClient,
      account,
      address: srAddress,
      abi: SHAREHOLDER_ROYALTIES_ABI,
      functionName: 'checkpointUserBatch',
      args: [owners as Address[], BigInt(owners.length)],
      log,
      context: `ShareholderRoyalties.checkpointUserBatch users=${owners.length}`,
    });

    if (!tx.ok) {
      const _code = tx.code;
      lastSkipReason = `${tx.reason} (batch ${owners.length} users)`;
      lastSkipAtUtc = nowUtcIso();

      if (log) log(`checkpoint-before-expiry: batch tx skipped: ${tx.reason}`);
    } else {
      // L4-1 (2026-04-17): this else-branch runs only when `tx.ok === true`,
      // which — after the C-1 fix in `shared/tx.ts` — requires the receipt
      // status to be strictly `success`. Previously receipt.status null/unknown
      // would fall through and advance the 48h owner cooldown on an unconfirmed tx.
      const hash = tx.hash as `0x${string}`;
      _successCount = owners.length;
      const nowMs = Date.now();
      for (const owner of owners) {
        scan.state.lastCheckpointedAt[owner] = nowMs;
      }
      saveState(statePath, scan.state);
      if (log)
        log(`checkpoint-before-expiry: batch checkpointed ${owners.length} users tx=${hash}`);
    }
  } catch (e: unknown) {
    const errObj = e as { shortMessage?: string; message?: string };
    lastError = String(errObj?.shortMessage ?? errObj?.message ?? e);
    if (log) log(`checkpoint-before-expiry: batch failed: ${lastError}`);
    await postAlert(config.alertWebhookUrl, {
      type: 'keeper_error',
      action: 'checkpoint_before_expiry',
      deployment: config.deployment,
      timestampUtc: nowUtcIso(),
      error: lastError,
    });
  }

  const successAt = nowUtcIso();

  const patch: Record<string, unknown> = {
    lastSuccessAtUtc: successAt,
    lastSuccessByTask: { checkpointBeforeExpiry: successAt },
    lastError: lastError ?? null,
    lastErrorByTask: { checkpointBeforeExpiry: lastError ?? null },
  };

  if (lastSkipReason) {
    const t = lastSkipAtUtc ?? successAt;
    patch.lastSkipAtUtc = t;
    patch.lastSkipByTask = { checkpointBeforeExpiry: t };
    patch.lastSkipReasonByTask = { checkpointBeforeExpiry: lastSkipReason };

    // If we only skipped (no real error), ensure error fields are clear.
    if (!lastError) {
      patch.lastError = null;
      patch.lastErrorByTask = { checkpointBeforeExpiry: null };
    }
  }

  updateStatusFile({
    statusPath: config.statusPath,
    init: statusInit,
    patch: patch as any,
  });

  return;
}
