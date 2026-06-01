import type { KeeperConfig } from '../shared/config.js';
import type { DeploymentManifest } from '../shared/deployments.js';
import type { ViemClients } from '../shared/clients.js';

import type { Address, PublicClient } from 'viem';
import type { PrivateKeyAccount } from 'viem/accounts';
import { parseAbiItem } from 'viem';

import { FURNACE_ABI, SHAREHOLDER_ROYALTIES_ABI, VE_CLAIM_NFT_ABI } from '../shared/abis.js';
import { postAlert } from '../shared/alert.js';
import { getLogsWithAutoSplit } from '../shared/rpc_logs.js';
import { sendContractTx } from '../shared/tx.js';
import {
  bumpRevertCount,
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
import { parseChainIdStrict } from '../shared/chainId.js';
import type { MorningCache } from '../shared/user_morning.js';
import { isInMorningWindow } from '../shared/user_morning.js';
import { parseNonNegativeSafeInteger } from '../shared/utils.js';

// Keeper-side floor for shareholder auto-compound. Intentionally higher than the
// onchain minAutoCompoundEth (0.0001 ETH default) to avoid wasting gas on dust.
// Can be lowered in the future once gas economics justify smaller compounds.
const MIN_AUTO_COMPOUND_REWARD_WEI = 1_000_000_000_000_000n; // 0.001 ETH
// Keeper-side per-user cadence floor is configurable via
// config.compoundShareholderMinCadenceSecs (defaults to the master settlement
// period). A user's own on-chain minCadenceSeconds still wins when larger.
// MAX_LOCK_DURATION removed: effectiveDuration is now computed on-chain.

/**
 * Effective per-user compound cadence in seconds: the larger of the keeper
 * floor and the user's own on-chain `minCadenceSeconds`. The user's choice
 * always wins when it is longer than the keeper floor.
 */
export function effectiveShareholderCadenceSeconds(
  keeperFloorSecs: number,
  userMinCadenceSeconds: number,
): number {
  return Math.max(keeperFloorSecs, userMinCadenceSeconds);
}
const CHAIN_REWIND_TOLERANCE = 64n;
// Always rescan a small overlap window to tolerate small L2 reorgs and RPC log edge cases.
const SCAN_OVERLAP_BLOCKS = CHAIN_REWIND_TOLERANCE;

// Simple per-user backoff for off-chain errors (quote failures, RPC flakiness, etc.)
const FAILURE_INITIAL_MS = 5 * 60 * 1000;
const FAILURE_MAX_MS = 24 * 60 * 60 * 1000;
const FAILURE_MULTIPLIER = 2;

const EVT_CONFIGURED = parseAbiItem(
  'event ShareholderAutoCompoundConfigured(address indexed user, bool enabled, uint256 tokenId, uint256 durationSeconds, uint32 minCadenceSeconds, uint256 minEthToCompound, uint32 maxSlippageBps)',
);
const EVT_PAUSED = parseAbiItem(
  'event ShareholderAutoCompoundPaused(address indexed user, uint256 tokenId, uint8 reasonCode)',
);
const EVT_EXECUTED_TOPIC = '0x5454e0c11691a1ab7cff14b2ea65dab5ebc5dee32feb75ce9fe00a09919eccc3';

function userTopic(user: string): string {
  return `0x${addrNorm(user).replace(/^0x/, '').padStart(64, '0')}`;
}

function receiptHasExecutedForUser(
  receipt: unknown,
  user: string,
  shareholderRoyaltiesAddress: string,
): boolean {
  const logs = (receipt as any)?.logs;
  if (!Array.isArray(logs) || logs.length === 0) return false;
  const wantedUserTopic = userTopic(user);
  const expectedAddress = addrNorm(shareholderRoyaltiesAddress);
  return logs.some((log: any) => {
    if (addrNorm(log?.address) !== expectedAddress) return false;
    const topics = Array.isArray(log?.topics) ? log.topics : [];
    if (topics.length < 2) return false;
    const t0 = String(topics[0] ?? '').toLowerCase();
    const t1 = String(topics[1] ?? '').toLowerCase();
    return t0 === EVT_EXECUTED_TOPIC && t1 === wantedUserTopic;
  });
}

interface CompoundShareholdersOpts {
  config: KeeperConfig;
  manifest: DeploymentManifest;
  clients: ViemClients;
  morningCache: MorningCache | null;
  log: (msg: string) => void;
}

interface FailureRecord {
  count: number;
  nextTryAtUtc: string;
  lastError: string;
}

interface CompoundState {
  version: number;
  lastScannedBlock: string;
  users: string[];
  cursor: number;
  failures: Record<string, FailureRecord>;
  /**
   * Users deferred by a latched global stop code (`paused`, `pending_guard`,
   * `fee_cap`, `dry_run`) on the per-user fallback path. Drained first by
   * the next `selectBatch` so a global stop cannot cause the round-robin
   * cursor to lap the deferred set without retrying it.
   */
  pendingDeferredUsers: string[];
}

interface EventItem {
  kind: 'cfg' | 'paused';
  l: { blockNumber?: bigint; logIndex?: number; args?: Record<string, unknown> };
}

function addrNorm(a: unknown): string {
  return String(a ?? '').toLowerCase();
}

function _addrEq(a: unknown, b: unknown): boolean {
  return addrNorm(a) === addrNorm(b);
}

function initState(): CompoundState {
  return {
    version: 1,
    lastScannedBlock: '0',
    users: [], // enabled && !paused (best effort via events)
    cursor: 0,
    failures: {},
    pendingDeferredUsers: [],
  };
}

function loadState(statePath: string, log?: (msg: string) => void): CompoundState {
  const result = loadJsonDetailed(statePath);
  if (result.kind === 'missing') return initState();
  if (result.kind === 'error') {
    if (log)
      log(
        `WARN: compound_shareholders state corrupt (${statePath}): ${result.error.message}; reinitializing`,
      );
    return initState();
  }
  const raw = result.value as Record<string, unknown> | null;
  if (!raw || typeof raw !== 'object') return initState();

  const out = initState();
  // Defensive: tolerate manual edits/corruption.
  const last = String(raw.lastScannedBlock ?? out.lastScannedBlock);
  try {
    BigInt(last);
    out.lastScannedBlock = last;
  } catch {
    out.lastScannedBlock = '0';
  }
  out.users = Array.isArray(raw.users) ? raw.users.filter(Boolean) : [];
  out.cursor = Number.isFinite(raw.cursor) ? (raw.cursor as number) : 0;
  out.failures =
    raw.failures && typeof raw.failures === 'object'
      ? (raw.failures as Record<string, FailureRecord>)
      : {};
  out.pendingDeferredUsers = Array.isArray(raw.pendingDeferredUsers)
    ? (raw.pendingDeferredUsers as unknown[]).filter(
        (x): x is string => typeof x === 'string' && !!x,
      )
    : [];
  return out;
}

function saveState(statePath: string, state: CompoundState): void {
  saveJsonAtomic(statePath, state);
}

function removeUser(
  users: string[],
  cursor: number,
  user: string,
): { users: string[]; cursor: number } {
  const u = addrNorm(user);
  const idx = users.findIndex((x) => addrNorm(x) === u);
  if (idx === -1) return { users, cursor };

  const nextUsers = users.slice(0, idx).concat(users.slice(idx + 1));
  let nextCursor = cursor;
  if (nextUsers.length === 0) nextCursor = 0;
  else if (idx < cursor) nextCursor = Math.max(0, cursor - 1);
  else if (cursor >= nextUsers.length) nextCursor = 0;

  return { users: nextUsers, cursor: nextCursor };
}

function addUser(users: string[], user: string): string[] {
  const u = addrNorm(user);
  if (users.some((x) => addrNorm(x) === u)) return users;
  return users.concat([user]);
}

function nextFailureDelayMs(count: number): number {
  const pow = Math.max(0, count - 1);
  let ms = FAILURE_INITIAL_MS * Math.pow(FAILURE_MULTIPLIER, pow);
  if (!Number.isFinite(ms)) ms = FAILURE_MAX_MS;
  return Math.min(ms, FAILURE_MAX_MS);
}

function markFailure(state: CompoundState, user: string, err: unknown): CompoundState {
  const key = addrNorm(user);
  const failures = { ...(state.failures ?? {}) };
  const prev = failures[key] ?? ({} as FailureRecord);
  const count = (parseNonNegativeSafeInteger(prev.count, { defaultValue: 0 }) ?? 0) + 1;
  const delayMs = nextFailureDelayMs(count);

  failures[key] = {
    count,
    nextTryAtUtc: new Date(Date.now() + delayMs).toISOString(),
    lastError: String(err ?? ''),
  };

  return { ...state, failures };
}

function clearFailure(state: CompoundState, user: string): CompoundState {
  const key = addrNorm(user);
  if (!state.failures?.[key]) return state;
  const failures = { ...state.failures };
  delete failures[key];
  return { ...state, failures };
}

function reDeferUsers(state: CompoundState, users: string[]): CompoundState {
  if (!users.length) return state;
  const existing = Array.isArray(state.pendingDeferredUsers) ? state.pendingDeferredUsers : [];
  const seen = new Set(existing.map((u) => addrNorm(u)));
  const merged = existing.slice();
  for (const u of users) {
    const norm = addrNorm(u);
    if (!norm || seen.has(norm)) continue;
    seen.add(norm);
    merged.push(u);
  }
  return { ...state, pendingDeferredUsers: merged };
}

function inFailureCooldown(state: CompoundState, user: string): boolean {
  const key = addrNorm(user);
  const f = state.failures?.[key];
  if (!f) return false;
  const t = Date.parse(String(f.nextTryAtUtc ?? ''));
  if (!Number.isFinite(t)) return false;
  return Date.now() < t;
}

function classifyFallbackErrorMessage(err: string): 'skip' | 'error' {
  const msg = err.toLowerCase();
  // Per-user fallback runs after a successful batch that emitted no executed events.
  // In practice this often means user state changed between scans or contract-side
  // guardrails rejected the immediate single-user attempt. Treat these as skips.
  if (msg.includes('reverted with the following signature')) return 'skip';
  if (msg.includes('cadence') || msg.includes('autocompound')) return 'skip';
  if (msg.includes('lock') && (msg.includes('expired') || msg.includes('listed'))) return 'skip';
  return 'error';
}

async function scanOptedInUsers({
  publicClient,
  shareholderRoyaltiesAddress,
  statePath,
  startBlock,
  chunkBlocks,
  log,
}: {
  publicClient: PublicClient;
  shareholderRoyaltiesAddress: Address;
  statePath: string;
  startBlock: number;
  chunkBlocks: number;
  log: (msg: string) => void;
}): Promise<{ state: CompoundState; scannedTo: bigint }> {
  let state = loadState(statePath, log);

  const latest: bigint = await publicClient.getBlockNumber();

  let lastScanned: bigint;
  try {
    lastScanned = BigInt(state.lastScannedBlock ?? '0');
  } catch {
    lastScanned = 0n;
    state = { ...state, lastScannedBlock: '0' };
  }
  if (lastScanned > latest + CHAIN_REWIND_TOLERANCE) {
    // Likely a local chain reset.
    if (log)
      log(
        `shareholder scan: chain rewind detected (last=${lastScanned} latest=${latest}). resetting state.`,
      );
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

  while (from <= latest) {
    const to = from + chunk - 1n > latest ? latest : from + chunk - 1n;

    const [cfgLogs, pausedLogs] = await Promise.all([
      getLogsWithAutoSplit({
        publicClient,
        request: {
          address: shareholderRoyaltiesAddress,
          event: EVT_CONFIGURED,
          fromBlock: from,
          toBlock: to,
        },
        log,
      }),
      getLogsWithAutoSplit({
        publicClient,
        request: {
          address: shareholderRoyaltiesAddress,
          event: EVT_PAUSED,
          fromBlock: from,
          toBlock: to,
        },
        log,
      }),
    ]);

    let users = state.users ?? [];
    let cursor = parseNonNegativeSafeInteger(state.cursor, { defaultValue: 0 }) ?? 0;
    const failures: Record<string, FailureRecord> =
      state.failures && typeof state.failures === 'object' ? { ...state.failures } : {};

    // Merge events and process in chronological order.
    // IMPORTANT: ShareholderAutoCompoundConfigured and ShareholderAutoCompoundPaused can interleave,
    // and ordering matters (users may re-enable after a pause).
    const merged: EventItem[] = [];
    for (const l of cfgLogs) merged.push({ kind: 'cfg', l });
    for (const l of pausedLogs) merged.push({ kind: 'paused', l });

    merged.sort((a, b) => {
      const ab = a?.l?.blockNumber ?? 0n;
      const bb = b?.l?.blockNumber ?? 0n;
      if (ab < bb) return -1;
      if (ab > bb) return 1;
      const ai = BigInt(a?.l?.logIndex ?? 0);
      const bi = BigInt(b?.l?.logIndex ?? 0);
      if (ai < bi) return -1;
      if (ai > bi) return 1;
      return 0;
    });

    for (const it of merged) {
      const l = it.l;
      const user = l?.args?.user as string | undefined;
      if (!user) continue;

      // If the user changed config onchain, clear any local backoff so we retry quickly.
      const fk = addrNorm(user);
      if (failures[fk]) delete failures[fk];

      if (it.kind === 'cfg') {
        const enabled = !!l?.args?.enabled;

        if (enabled) users = addUser(users, user);
        else {
          // Disabled.
          const rm = removeUser(users, cursor, user);
          users = rm.users;
          cursor = rm.cursor;
        }
      } else {
        const rm = removeUser(users, cursor, user);
        users = rm.users;
        cursor = rm.cursor;
      }
    }

    state = {
      ...state,
      users,
      cursor,
      failures,
      lastScannedBlock: to.toString(),
    };

    saveState(statePath, state);

    if (log && (cfgLogs.length || pausedLogs.length)) {
      log(
        `shareholder scan: blocks ${from.toString()}..${to.toString()} cfg=${cfgLogs.length} paused=${pausedLogs.length} users=${users.length}`,
      );
    }

    from = to + 1n;
  }

  return { state, scannedTo: latest };
}

async function selectBatch({
  publicClient,
  config,
  shareholderRoyaltiesAddress,
  veAddress,
  state,
  morningCache,
  globalMinAutoCompoundEth,
  log: _log,
}: {
  publicClient: PublicClient;
  config: KeeperConfig;
  shareholderRoyaltiesAddress: Address;
  veAddress: Address;
  state: CompoundState;
  morningCache: MorningCache | null;
  // B-5 (2026-04-17): governance-updatable on-chain dust floor
  // (`ShareholderRoyalties.minAutoCompoundEth`). Read once per run by the
  // caller and passed in so selection matches contract-side gating.
  globalMinAutoCompoundEth: bigint;
  log: (msg: string) => void;
}): Promise<{
  state: CompoundState;
  batch: { users: string[] };
  drainedFromDeferred: string[];
}> {
  const usersList0 = Array.isArray(state.users) ? state.users : [];
  if (!usersList0.length) return { state, batch: { users: [] }, drainedFromDeferred: [] };

  const block = await publicClient.getBlock();
  const nowTs: bigint = block.timestamp;

  const maxUsers = config.compoundMaxUsersShareholders;
  const lookahead = Math.min(config.compoundLookaheadUsers, usersList0.length);

  let nextState = state;

  // Normalize cursor to current list length.
  let cursor = parseNonNegativeSafeInteger(nextState.cursor, { defaultValue: 0 }) ?? 0;
  cursor = usersList0.length ? cursor % usersList0.length : 0;
  nextState = { ...nextState, cursor };

  const batchUsers: string[] = [];
  const batchAmounts: bigint[] = [];

  // Pre-filter users by local state before any RPC reads.
  const candidates: string[] = [];
  // Drain the deferred queue first: a prior tick latched a global stop
  // (`paused`, `pending_guard`, `fee_cap`, `dry_run`) on these users and
  // skipped them without retrying. Re-prioritize them ahead of the
  // round-robin so a long-lived stop cannot cause the cursor to lap the
  // deferred set without ever revisiting it.
  const seenCandidate = new Set<string>();
  const deferredQueue = Array.isArray(nextState.pendingDeferredUsers)
    ? nextState.pendingDeferredUsers.slice()
    : [];
  const usersListSet = new Set(
    (Array.isArray(nextState.users) ? nextState.users : []).map((u) => addrNorm(u)),
  );
  const deferredKept: string[] = [];
  // Capture the deferred-origin users chosen as candidates so the caller can
  // re-defer them on tail-shrink, dry-run, or batch-level skip; otherwise
  // those eligible users would lose priority and sit behind a full
  // round-robin cycle again.
  const drainedFromDeferred: string[] = [];
  for (const user of deferredQueue) {
    if (candidates.length >= lookahead) {
      deferredKept.push(user);
      continue;
    }
    const norm = addrNorm(user);
    if (!norm || !usersListSet.has(norm)) continue;
    if (inFailureCooldown(nextState, user)) {
      deferredKept.push(user);
      continue;
    }
    if (morningCache && !isInMorningWindow(morningCache, user, config.morningWindowHours)) {
      deferredKept.push(user);
      continue;
    }
    if (seenCandidate.has(norm)) continue;
    seenCandidate.add(norm);
    candidates.push(user);
    drainedFromDeferred.push(user);
  }
  // Persist the trimmed queue. The fallback path repopulates it on the next
  // tick if the stop is still latched; users that successfully compound this
  // tick are removed via `removeUser` further down or simply not re-added.
  nextState = { ...nextState, pendingDeferredUsers: deferredKept };

  for (let scanned = 0; scanned < lookahead && candidates.length < lookahead; scanned++) {
    const usersList = Array.isArray(nextState.users) ? nextState.users : [];
    if (!usersList.length) break;
    if (cursor >= usersList.length) cursor = 0;
    const user = usersList[cursor];
    cursor = usersList.length ? (cursor + 1) % usersList.length : 0;
    nextState = { ...nextState, cursor };
    if (!user) continue;
    const norm = addrNorm(user);
    if (seenCandidate.has(norm)) continue;
    if (inFailureCooldown(nextState, user)) continue;
    if (morningCache && !isInMorningWindow(morningCache, user, config.morningWindowHours)) continue;
    seenCandidate.add(norm);
    candidates.push(user);
  }

  if (candidates.length > 0) {
    // Initial batch-read of on-chain configs via multicall (1 RPC instead of N).
    const cfgContracts = candidates.map((user) => ({
      address: shareholderRoyaltiesAddress,
      abi: SHAREHOLDER_ROYALTIES_ABI,
      functionName: 'getAutoCompoundConfig' as const,
      args: [user as Address] as const,
    }));
    const cfgResults = await publicClient.multicall({ contracts: cfgContracts });

    // Track users to remove and users needing shareholder state.
    const needState: Array<{ user: string; tokenId: bigint; minEthToCompound: bigint }> = [];
    for (let i = 0; i < candidates.length; i++) {
      const user = candidates[i];
      const r = cfgResults[i];
      if (r.status === 'failure') {
        nextState = markFailure(nextState, user, 'multicall_read_failed');
        continue;
      }
      const cfg = r.result as any;
      const enabled = !!cfg?.[0];
      const paused = !!cfg?.[1];
      const tokenId: bigint = cfg?.[2] ?? 0n;
      const minCadenceSeconds = cfg?.[4] ?? 0;
      const minEthToCompound: bigint = cfg?.[5] ?? 0n;
      const lastCompoundTs = BigInt(cfg?.[7] ?? 0);

      if (!enabled || paused) {
        const ul = Array.isArray(nextState.users) ? nextState.users : [];
        const rm = removeUser(
          ul,
          parseNonNegativeSafeInteger(nextState.cursor, { defaultValue: 0 }) ?? 0,
          user,
        );
        nextState = { ...nextState, users: rm.users, cursor: rm.cursor };
        nextState = clearFailure(nextState, user);
        continue;
      }
      const effectiveCadenceSeconds = effectiveShareholderCadenceSeconds(
        config.compoundShareholderMinCadenceSecs,
        minCadenceSeconds,
      );
      if (effectiveCadenceSeconds > 0 && lastCompoundTs > 0n) {
        if (nowTs < lastCompoundTs + BigInt(effectiveCadenceSeconds)) continue;
      }
      needState.push({ user, tokenId, minEthToCompound });
    }

    if (needState.length > 0) {
      // Batch-read shareholder state + lock info via multicall (1 RPC instead of 2N).
      const phase2Contracts = needState.flatMap(({ user, tokenId }) => [
        {
          address: shareholderRoyaltiesAddress,
          abi: SHAREHOLDER_ROYALTIES_ABI,
          functionName: 'getShareholderState' as const,
          args: [user as Address] as const,
        },
        {
          address: veAddress,
          abi: VE_CLAIM_NFT_ABI,
          functionName: 'getLockInfo' as const,
          args: [tokenId] as const,
        },
      ]);
      const phase2Results = await publicClient.multicall({ contracts: phase2Contracts });

      for (let i = 0; i < needState.length && batchUsers.length < maxUsers; i++) {
        const { user, minEthToCompound } = needState[i];
        const stateR = phase2Results[i * 2];
        const lockR = phase2Results[i * 2 + 1];
        if (stateR.status === 'failure') {
          nextState = markFailure(nextState, user, 'multicall_state_failed');
          continue;
        }
        if (lockR.status === 'failure') {
          nextState = markFailure(nextState, user, 'multicall_lock_failed');
          continue;
        }
        const shareholderState = stateR.result as any;
        const claimableNow: bigint = shareholderState?.[0] ?? 0n;
        // B-5 (2026-04-17): match `_executeAutoCompoundCore` gating by taking the
        // max of per-user `cfg.minEthToCompound`, the governance-updatable global
        // `minAutoCompoundEth`, and the keeper's gas-econ floor
        // (`MIN_AUTO_COMPOUND_REWARD_WEI`).
        let effectiveMinEthToCompound = minEthToCompound;
        if (effectiveMinEthToCompound < globalMinAutoCompoundEth) {
          effectiveMinEthToCompound = globalMinAutoCompoundEth;
        }
        if (effectiveMinEthToCompound < MIN_AUTO_COMPOUND_REWARD_WEI) {
          effectiveMinEthToCompound = MIN_AUTO_COMPOUND_REWARD_WEI;
        }
        if (claimableNow === 0n || claimableNow < effectiveMinEthToCompound) continue;

        const lockInfo = lockR.result as any;
        const lockAmount: bigint = lockInfo?.[0] ?? 0n;
        const lockEnd: bigint = lockInfo?.[1] ?? 0n;
        const listed: boolean = !!lockInfo?.[3];

        if (lockAmount === 0n) {
          nextState = markFailure(nextState, user, 'lock_empty');
          continue;
        }
        if (listed) {
          nextState = markFailure(nextState, user, 'lock_listed_or_frozen');
          continue;
        }
        if (lockEnd <= nowTs) {
          nextState = markFailure(nextState, user, 'lock_expired');
          continue;
        }

        batchUsers.push(user);
        batchAmounts.push(claimableNow);
        nextState = clearFailure(nextState, user);
      }
    }
  }

  // Sort batch by smallest input first to reduce intra-tx state drift in Furnace + swap routing.
  // This keeps later users closer to the pre-tx quote environment.
  if (batchUsers.length > 1) {
    const idxs = batchUsers.map((_: string, i: number) => i);
    idxs.sort((i: number, j: number) => {
      const ai = batchAmounts[i] ?? 0n;
      const aj = batchAmounts[j] ?? 0n;
      if (ai === aj) {
        const ui = addrNorm(batchUsers[i]);
        const uj = addrNorm(batchUsers[j]);
        if (ui < uj) return -1;
        if (ui > uj) return 1;
        return 0;
      }
      return ai < aj ? -1 : 1;
    });

    const usersSorted = idxs.map((k: number) => batchUsers[k]);

    batchUsers.length = 0;
    batchUsers.push(...usersSorted);
  }

  // Filter `drainedFromDeferred` down to users that actually survived the
  // on-chain selection — only those need re-deferral on a downstream skip.
  const finalSet = new Set(batchUsers.map((u) => addrNorm(u)));
  const drainedSurviving = drainedFromDeferred.filter((u) => {
    const norm = addrNorm(u);
    return norm ? finalSet.has(norm) : false;
  });
  return {
    state: nextState,
    batch: { users: batchUsers },
    drainedFromDeferred: drainedSurviving,
  };
}

async function shrinkToGasLimit({
  publicClient,
  account,
  maxGas,
  shareholderRoyaltiesAddress,
  users,
}: {
  publicClient: PublicClient;
  account: PrivateKeyAccount;
  maxGas: number;
  shareholderRoyaltiesAddress: Address;
  users: string[];
}): Promise<{ users: string[]; gas: bigint }> {
  const maxGasBn = BigInt(maxGas);
  let n = users.length;
  if (!n) return { users: [], gas: 0n };

  while (n > 0) {
    const u = users.slice(0, n);

    try {
      const gas: bigint = await publicClient.estimateContractGas({
        address: shareholderRoyaltiesAddress,
        abi: SHAREHOLDER_ROYALTIES_ABI,
        functionName: 'compoundForMany',
        args: [u as readonly Address[], BigInt(u.length)],
        account,
      });

      if (gas <= maxGasBn) {
        return { users: u, gas };
      }
    } catch {
      // If estimation fails, fall back to smaller batches.
    }

    n = Math.floor(n / 2);
  }

  return { users: [], gas: 0n };
}

export async function runCompoundShareholders({
  config,
  manifest,
  clients,
  morningCache,
  log,
}: CompoundShareholdersOpts): Promise<void> {
  const chainId = parseChainIdStrict(manifest?.chainId) ?? 0;
  const statusInit = () => initStatusState({ deployment: config.deployment, chainId });

  const attemptAt = nowUtcIso();
  updateStatusFile({
    statusPath: config.statusPath,
    init: statusInit,
    patch: {
      lastAttemptAtUtc: attemptAt,
      lastAttemptByTask: { compoundShareholders: attemptAt },
    },
  });

  const shareholderRoyaltiesAddress = getContractAddress(manifest, 'ShareholderRoyalties');
  requireNonZeroAddress(shareholderRoyaltiesAddress, 'ShareholderRoyalties');

  const furnaceAddress = getContractAddress(manifest, 'Furnace');
  requireNonZeroAddress(furnaceAddress, 'Furnace');

  const veAddress = getContractAddress(manifest, 'VeClaimNFT');
  requireNonZeroAddress(veAddress, 'VeClaimNFT');

  const { publicClient, walletClient, account } = clients;

  // Determine scan start block.
  let startBlock: number | null =
    config.compoundShareholdersStartBlock ??
    getContractStartBlock(manifest, 'ShareholderRoyalties');
  if (!startBlock || startBlock <= 0) {
    const latest: bigint = await publicClient.getBlockNumber();
    const lookback = BigInt(config.compoundScanChunkBlocks) * 2n;
    startBlock =
      parseNonNegativeSafeInteger(latest > lookback ? latest - lookback : 0n, {
        defaultValue: 0,
      }) ?? 0;
  }

  // 1) Update worklist (event-sourced)
  const scan = await scanOptedInUsers({
    publicClient,
    shareholderRoyaltiesAddress,
    statePath: config.compoundShareholdersStatePath,
    startBlock,
    chunkBlocks: config.compoundScanChunkBlocks,
    log,
  });

  // If Furnace locking is paused, skip compounding to avoid per-user quote failures and wasted gas.
  let lockingPaused = false;
  try {
    lockingPaused = await publicClient.readContract({
      address: furnaceAddress,
      abi: FURNACE_ABI,
      functionName: 'lockingPaused',
    });
  } catch (e: unknown) {
    const errObj = e as { shortMessage?: string; message?: string };
    if (log)
      log(
        `compound-shareholders: failed to read Furnace.lockingPaused(): ${String(errObj?.shortMessage ?? errObj?.message ?? e)}`,
      );
  }

  if (lockingPaused) {
    if (log) log('compound-shareholders: Furnace.lockingPaused=true, skipping');
    const successAt = nowUtcIso();
    updateStatusFile({
      statusPath: config.statusPath,
      init: statusInit,
      patch: {
        lastSuccessAtUtc: successAt,
        lastSuccessByTask: { compoundShareholders: successAt },
        lastError: null,
        lastErrorByTask: { compoundShareholders: null },
      },
    });
    return;
  }

  // B-5 (2026-04-17): read the live governance dust floor once per run so
  // selection mirrors `_executeAutoCompoundCore`'s `max(cfg.minEthToCompound,
  // minAutoCompoundEth)` gate. Fail-closed to `MIN_AUTO_COMPOUND_REWARD_WEI`
  // (the keeper gas-econ floor) on read error — raising the floor is always
  // the safer drift direction than lowering it.
  let globalMinAutoCompoundEth: bigint = MIN_AUTO_COMPOUND_REWARD_WEI;
  try {
    const raw = await publicClient.readContract({
      address: shareholderRoyaltiesAddress,
      abi: SHAREHOLDER_ROYALTIES_ABI,
      functionName: 'minAutoCompoundEth',
    });
    globalMinAutoCompoundEth = BigInt(raw as any);
    if (log) {
      log(
        `compound-shareholders: live minAutoCompoundEth=${globalMinAutoCompoundEth.toString()} wei (keeper floor=${MIN_AUTO_COMPOUND_REWARD_WEI.toString()})`,
      );
    }
  } catch (e: unknown) {
    const errObj = e as { shortMessage?: string; message?: string };
    if (log) {
      log(
        `compound-shareholders: failed to read ShareholderRoyalties.minAutoCompoundEth() (fail-closed to keeper floor ${MIN_AUTO_COMPOUND_REWARD_WEI.toString()}): ${String(errObj?.shortMessage ?? errObj?.message ?? e)}`,
      );
    }
  }

  // 2) Select a batch (on-chain config + quoting)
  const sel = await selectBatch({
    publicClient,
    config,
    shareholderRoyaltiesAddress,
    veAddress,
    state: scan.state,
    morningCache,
    globalMinAutoCompoundEth,
    log,
  });

  // Persist cursor/failure updates even if we do a no-op.
  saveState(config.compoundShareholdersStatePath, sel.state);

  // 3) Gas-bounded shrink
  const shrunk = await shrinkToGasLimit({
    publicClient,
    account,
    maxGas: config.compoundMaxGas,
    shareholderRoyaltiesAddress,
    users: sel.batch.users,
  });

  const users = shrunk.users ?? [];

  // `shrinkToGasLimit` keeps a head prefix and drops the tail; any deferred
  // user that landed past that prefix must be re-deferred so the next tick
  // drains them ahead of the round-robin.
  const keptSet = new Set(users.map((u) => addrNorm(u)));
  const shrunkOutDeferred = sel.drainedFromDeferred.filter((u) => {
    const norm = addrNorm(u);
    return norm ? !keptSet.has(norm) : false;
  });
  if (shrunkOutDeferred.length) {
    sel.state = reDeferUsers(sel.state, shrunkOutDeferred);
    saveState(config.compoundShareholdersStatePath, sel.state);
    if (log) {
      log(
        `compound-shareholders: re-deferred ${shrunkOutDeferred.length} user(s) dropped by gas-bounded shrink`,
      );
    }
  }

  if (log) {
    log(
      `compound-shareholders: candidates=${sel.batch.users.length} selected=${users.length} gasCap=${config.compoundMaxGas}`,
    );
  }

  if (!users.length) {
    // The full prefix collapsed under the gas cap. Re-defer any
    // deferred-origin candidates that survived selection but were dropped
    // by `shrinkToGasLimit` so they keep priority on the next tick.
    if (sel.drainedFromDeferred.length) {
      sel.state = reDeferUsers(sel.state, sel.drainedFromDeferred);
      saveState(config.compoundShareholdersStatePath, sel.state);
    }
    const successAt = nowUtcIso();
    updateStatusFile({
      statusPath: config.statusPath,
      init: statusInit,
      patch: {
        lastSuccessAtUtc: successAt,
        lastSuccessByTask: { compoundShareholders: successAt },
        lastError: null,
        lastErrorByTask: { compoundShareholders: null },
      },
    });

    return;
  }

  if (config.dryRun) {
    if (log) log('dry-run: not submitting ShareholderRoyalties.compoundForMany');
    // Dry-run intentionally skips the on-chain send; re-defer any
    // deferred-origin users so they keep priority once dry-run is off.
    if (sel.drainedFromDeferred.length) {
      sel.state = reDeferUsers(sel.state, sel.drainedFromDeferred);
      saveState(config.compoundShareholdersStatePath, sel.state);
    }
    const successAt = nowUtcIso();
    updateStatusFile({
      statusPath: config.statusPath,
      init: statusInit,
      patch: {
        lastSuccessAtUtc: successAt,
        lastSuccessByTask: { compoundShareholders: successAt },
        lastError: null,
        lastErrorByTask: { compoundShareholders: null },
      },
    });
    return;
  }

  let hash: `0x${string}` | null = null;
  try {
    // Compound execution can branch into expensive Furnace paths based on live pool
    // conditions (swap + LP accounting + bonus computation + ve minting). The gas
    // estimator under-estimates because _lockEthRewardBestEffort catches inner
    // failures silently — eth_estimateGas returns the minimum for the outer call to
    // succeed, not for the inner Furnace lock to complete. Keep a conservative floor
    // high enough for the full Furnace path (~400-500K inner gas + 200K buffer +
    // ~200K overhead).
    const minCompoundGasLimit = BigInt(Math.min(config.compoundMaxGas, 1_200_000));
    const tx = await sendContractTx({
      config,
      publicClient,
      walletClient,
      account,
      address: shareholderRoyaltiesAddress,
      abi: SHAREHOLDER_ROYALTIES_ABI,
      functionName: 'compoundForMany',
      args: [users as readonly Address[], BigInt(users.length)],
      minGasLimit: minCompoundGasLimit,
      log,
      context: `ShareholderRoyalties.compoundForMany users=${users.length}`,
    });

    if (!tx.ok) {
      if (log) log(`tx skipped: ${tx.reason}`);

      // Skips are safety rails (paused, pending nonce guard, fee caps, etc).
      // Treat as a successful no-op so monitoring doesn't flag false failures.
      //
      // A batch-level skip applies to every user in `users` (the gate is
      // contract- or keeper-wide, not per-user), so re-defer the entire
      // selection. Without this, deferred-origin users that drained into
      // this tick would lose priority and sit behind a full round-robin
      // cycle the next time selectBatch runs. We also fold in the
      // shrunk-out tail because the latch is global.
      sel.state = reDeferUsers(sel.state, [...users, ...shrunkOutDeferred]);
      saveState(config.compoundShareholdersStatePath, sel.state);

      const skippedAt = nowUtcIso();
      updateStatusFile({
        statusPath: config.statusPath,
        init: statusInit,
        patch: {
          lastSuccessAtUtc: skippedAt,
          lastSuccessByTask: { compoundShareholders: skippedAt },

          lastSkipAtUtc: skippedAt,
          lastSkipByTask: { compoundShareholders: skippedAt },
          lastSkipReasonByTask: { compoundShareholders: tx.reason },

          lastError: null,
          lastErrorByTask: { compoundShareholders: null },
        },
      });
      return;
    }

    hash = tx.hash as `0x${string}`;
    const receipt = tx.receipt as any;
    const executedInBatch = users.filter((u) =>
      receiptHasExecutedForUser(receipt, u, shareholderRoyaltiesAddress),
    );

    // The batch path partially succeeds when a subset of users skip on-chain
    // (e.g. tighter slippage on some, stale checkpoint on others). The
    // residual users that did NOT carry an executed event must run through
    // the per-user fallback so the cursor cannot advance past them — leaving
    // them in the bin would skip the next-cycle retry without any
    // compounding having happened.
    const executedSet = new Set(executedInBatch.map((u) => u.toLowerCase()));
    const missingFromBatch = users.filter((u) => !executedSet.has(u.toLowerCase()));

    if (missingFromBatch.length) {
      if (log) {
        log(
          `compound-shareholders: ${missingFromBatch.length}/${users.length} user(s) absent from batch executed events; falling back to per-user compoundFor`,
        );
      }

      // Defer cursor advance: a global skip code (`paused`, `pending_guard`,
      // `fee_cap`, `dry_run`) means the contract or keeper-side rate-limit
      // is currently barring writes and applies to subsequent sends too. We
      // still attempt the remaining users so a transient per-user skip
      // (e.g. dust below `minEthToCompound` for a single account) does not
      // mask other users' eligibility, then fail-stop only when a true
      // global condition is observed.
      let globalStopCode: string | null = null;
      const latchedDeferrals: string[] = [];

      for (const user of missingFromBatch) {
        if (globalStopCode) {
          if (log) {
            log(
              `compound-shareholders: fallback skipping user=${user} due to prior global stop code=${globalStopCode}`,
            );
          }
          // Park the deferred user so the next selectBatch can drain them
          // ahead of the round-robin once the global stop clears.
          latchedDeferrals.push(user);
          continue;
        }

        try {
          const one = await sendContractTx({
            config,
            publicClient,
            walletClient,
            account,
            address: shareholderRoyaltiesAddress,
            abi: SHAREHOLDER_ROYALTIES_ABI,
            functionName: 'compoundFor',
            args: [user as Address],
            minGasLimit: minCompoundGasLimit,
            log,
            context: `ShareholderRoyalties.compoundFor user=${user}`,
          });

          if (one.ok) {
            const oneReceipt = one.receipt as any;
            if (receiptHasExecutedForUser(oneReceipt, user, shareholderRoyaltiesAddress)) {
              if (log) log(`compound-shareholders: fallback succeeded for user=${user}`);
            } else {
              if (log)
                log(`compound-shareholders: fallback tx had no executed event for user=${user}`);
              sel.state = markFailure(sel.state, user, 'fallback_no_executed_event');
              saveState(config.compoundShareholdersStatePath, sel.state);
            }
          } else {
            if (log) {
              log(`compound-shareholders: fallback skipped for user=${user} reason=${one.reason}`);
            }

            // Global skip codes are keeper-wide and survive across users.
            // Latch the stop code and short-circuit the remaining users
            // without consuming RPC; the next cycle will pick up where
            // this one stopped because the cursor is gated below on
            // observed completion. `gas_limit_cap` and `total_fee_cap`
            // are also keeper-wide safety rails — the per-tx and
            // per-cycle ceilings bind across users — so they latch the
            // loop the same way as `paused` / `pending_guard` / `fee_cap`.
            if (
              one.code === 'paused' ||
              one.code === 'dry_run' ||
              one.code === 'pending_guard' ||
              one.code === 'fee_cap' ||
              one.code === 'gas_limit_cap' ||
              one.code === 'total_fee_cap'
            ) {
              globalStopCode = one.code ?? 'global_skip';
              // The user that triggered the latch is itself deferred — the
              // global condition (paused contract, fee cap, etc.) prevented
              // their compound, not a per-user condition.
              latchedDeferrals.push(user);
              if (log) {
                log(
                  `compound-shareholders: fallback latched global stop code=${globalStopCode}; remaining users deferred`,
                );
              }
            }
          }
        } catch (e: unknown) {
          const errObj = e as { shortMessage?: string; message?: string };
          const err = String(errObj?.shortMessage ?? errObj?.message ?? e);
          const kind = classifyFallbackErrorMessage(err);
          if (log) {
            if (kind === 'skip') {
              log(`compound-shareholders: fallback skipped for user=${user} reason=${err}`);
            } else {
              log(`compound-shareholders: fallback failed for user=${user} error=${err}`);
            }
          }
          sel.state = markFailure(sel.state, user, e);
          saveState(config.compoundShareholdersStatePath, sel.state);
        }
      }

      if (latchedDeferrals.length) {
        // Merge into the persisted deferred queue, deduped against the
        // existing entries. The next selectBatch drains this list ahead
        // of the round-robin once the latched stop clears.
        const existing = Array.isArray(sel.state.pendingDeferredUsers)
          ? sel.state.pendingDeferredUsers
          : [];
        const seen = new Set(existing.map((u) => addrNorm(u)));
        const merged = existing.slice();
        for (const u of latchedDeferrals) {
          const norm = addrNorm(u);
          if (!norm || seen.has(norm)) continue;
          seen.add(norm);
          merged.push(u);
        }
        sel.state = { ...sel.state, pendingDeferredUsers: merged };
        saveState(config.compoundShareholdersStatePath, sel.state);
      }
    }

    const successAt = nowUtcIso();
    updateStatusFile({
      statusPath: config.statusPath,
      init: statusInit,
      patch: {
        lastSuccessAtUtc: successAt,
        lastSuccessByTask: { compoundShareholders: successAt },

        lastTxHash: hash,
        lastTxHashByTask: { compoundShareholders: hash },

        lastError: null,
        lastErrorByTask: { compoundShareholders: null },
      },
    });

    return;
  } catch (e: unknown) {
    const errObj = e as { shortMessage?: string; message?: string };
    const err = String(errObj?.shortMessage ?? errObj?.message ?? e);

    const patch: Record<string, unknown> = {
      lastError: err,
      lastErrorByTask: { compoundShareholders: err },
    };
    if (hash) {
      patch.lastTxHash = hash;
      patch.lastTxHashByTask = { compoundShareholders: hash };
    }

    const cur = updateStatusFile({ statusPath: config.statusPath, init: statusInit, patch });
    const bumped = bumpRevertCount(cur, 'compoundShareholders');
    updateStatusFile({ statusPath: config.statusPath, init: statusInit, patch: bumped });

    await postAlert(config.alertWebhookUrl, {
      type: 'keeper_error',
      action: 'compound_shareholders',
      deployment: config.deployment,
      timestampUtc: nowUtcIso(),
      error: err,
      txHash: hash,
    });

    throw e;
  }
}
