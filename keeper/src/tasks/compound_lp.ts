import type { KeeperConfig } from '../shared/config.js';
import type { DeploymentManifest } from '../shared/deployments.js';
import type { ViemClients } from '../shared/clients.js';
import type { Address, PublicClient } from 'viem';
import type { PrivateKeyAccount } from 'viem/accounts';

import { decodeEventLog, getEventSelector, parseAbiItem } from 'viem';

import { FURNACE_ABI, LP_STAKING_VAULT_ABI, VE_CLAIM_NFT_ABI } from '../shared/abis.js';
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

const _MAX_LOCK_DURATION = 365n * 24n * 60n * 60n; // 365 days
const CHAIN_REWIND_TOLERANCE = 64n;
// Always rescan a small overlap window to tolerate small L2 reorgs and RPC log edge cases.
const SCAN_OVERLAP_BLOCKS = CHAIN_REWIND_TOLERANCE;

// Simple per-user backoff for off-chain errors (quote failures, RPC flakiness, etc.)
const FAILURE_INITIAL_MS = 5 * 60 * 1000;
const FAILURE_MAX_MS = 24 * 60 * 60 * 1000;
const FAILURE_MULTIPLIER = 2;

const COMPOUND_COOLDOWN_MS = 7 * 24 * 60 * 60 * 1000; // 7 days between compounds per user

const EVT_CONFIGURED = parseAbiItem(
  'event AutoCompoundConfigured(address indexed user, bool enabled, uint256 tokenId, uint256 durationSeconds, uint32 maxSlippageBps, uint256 minRewardToCompound)',
);
const EVT_PAUSED = parseAbiItem(
  'event AutoCompoundPaused(address indexed user, uint256 tokenId, uint8 reasonCode)',
);
// Pinned to the canonical `Events.sol` shape so `LP_REWARDS_LOCKED_TOPIC`
// matches the selector the vault actually emits. The receipt-gating set
// derived from this topic drives the per-user 7-day cooldown — a stale
// signature here makes successful compounds invisible to the keeper and the
// cooldown never advances.
const EVT_REWARDS_LOCKED = parseAbiItem(
  'event LpRewardsLocked(address indexed user, uint256 amountClaim, uint256 principalClaim, uint256 bonusClaim, uint256 tokenId)',
);

interface CompoundLpOpts {
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
  lastCompounded: Record<string, string>;
}

interface EventItem {
  kind: 'cfg' | 'paused';
  l: { blockNumber?: bigint; logIndex?: number; args?: Record<string, unknown> };
}

function addrNorm(a: unknown): string {
  return String(a ?? '').toLowerCase();
}

function initState(): CompoundState {
  return {
    version: 1,
    lastScannedBlock: '0',
    users: [],
    cursor: 0,
    failures: {},
    lastCompounded: {},
  };
}

function loadState(statePath: string, log?: (msg: string) => void): CompoundState {
  const result = loadJsonDetailed(statePath);
  if (result.kind === 'missing') return initState();
  if (result.kind === 'error') {
    if (log)
      log(
        `WARN: compound_lp state corrupt (${statePath}): ${result.error.message}; reinitializing`,
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
  out.lastCompounded =
    raw.lastCompounded && typeof raw.lastCompounded === 'object'
      ? (raw.lastCompounded as Record<string, string>)
      : {};
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

function inCompoundCooldown(state: CompoundState, user: string): boolean {
  const key = addrNorm(user);
  const ts = state.lastCompounded?.[key];
  if (!ts) return false;
  const t = Date.parse(String(ts));
  if (!Number.isFinite(t)) return false;
  return Date.now() - t < COMPOUND_COOLDOWN_MS;
}

function markCompounded(state: CompoundState, users: string[]): CompoundState {
  const lastCompounded = { ...(state.lastCompounded ?? {}) };
  const now = new Date().toISOString();
  for (const u of users) {
    lastCompounded[addrNorm(u)] = now;
  }
  return { ...state, lastCompounded };
}

const LP_REWARDS_LOCKED_TOPIC = getEventSelector(
  EVT_REWARDS_LOCKED as unknown as Parameters<typeof getEventSelector>[0],
) as `0x${string}`;

// Walk a `compoundForMany` receipt and return the lower-case set of users for
// whom the vault actually emitted `LpRewardsLocked`. A silent no-op (Furnace
// quote unusable, no `LpRewardsLocked`, no pause) leaves the user out — the
// caller must skip the cooldown advance for that user so the next tick can
// retry instead of waiting out the 7-day per-user cooldown.
function parseLpRewardsLockedUsers(
  logs: Array<{ address?: string; topics?: string[]; data?: string }>,
  vaultAddr: Address,
): Set<`0x${string}`> {
  const out = new Set<`0x${string}`>();
  const target = String(vaultAddr).toLowerCase();
  for (const log of logs) {
    const addr = String(log?.address ?? '').toLowerCase();
    if (addr !== target) continue;
    const topics = log?.topics;
    if (!Array.isArray(topics) || topics.length === 0) continue;
    if (String(topics[0]).toLowerCase() !== LP_REWARDS_LOCKED_TOPIC.toLowerCase()) continue;
    try {
      const decoded = decodeEventLog({
        abi: LP_STAKING_VAULT_ABI as unknown as Parameters<typeof decodeEventLog>[0]['abi'],
        eventName: 'LpRewardsLocked',
        topics: topics as [signature: `0x${string}`, ...args: `0x${string}`[]],
        data: (log?.data ?? '0x') as `0x${string}`,
      });
      const user = (decoded.args as { user?: string })?.user;
      if (typeof user === 'string' && user.length === 42) {
        out.add(user.toLowerCase() as `0x${string}`);
      }
    } catch {
      // Ignore malformed log; receipt-gating defaults to "not compounded".
    }
  }
  return out;
}

function inFailureCooldown(state: CompoundState, user: string): boolean {
  const key = addrNorm(user);
  const f = state.failures?.[key];
  if (!f) return false;
  const t = Date.parse(String(f.nextTryAtUtc ?? ''));
  if (!Number.isFinite(t)) return false;
  return Date.now() < t;
}

async function scanOptedInUsers({
  publicClient,
  lpVaultAddress,
  statePath,
  startBlock,
  chunkBlocks,
  log,
}: {
  publicClient: PublicClient;
  lpVaultAddress: Address;
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
    if (log)
      log(
        `lp scan: chain rewind detected (last=${lastScanned} latest=${latest}). resetting state.`,
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
          address: lpVaultAddress,
          event: EVT_CONFIGURED,
          fromBlock: from,
          toBlock: to,
        },
        log,
      }),
      getLogsWithAutoSplit({
        publicClient,
        request: {
          address: lpVaultAddress,
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
    // IMPORTANT: AutoCompoundConfigured and AutoCompoundPaused can interleave,
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
        if (enabled) {
          users = addUser(users, user);
        } else {
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
        `lp scan: blocks ${from.toString()}..${to.toString()} cfg=${cfgLogs.length} paused=${pausedLogs.length} users=${users.length}`,
      );
    }

    from = to + 1n;
  }

  return { state, scannedTo: latest };
}

async function selectBatch({
  publicClient,
  config,
  lpVaultAddress,
  veAddress,
  state,
  morningCache,
  log: _log,
}: {
  publicClient: PublicClient;
  config: KeeperConfig;
  lpVaultAddress: Address;
  veAddress: Address;
  state: CompoundState;
  morningCache: MorningCache | null;
  log: (msg: string) => void;
}): Promise<{ state: CompoundState; batch: { users: string[] } }> {
  const usersList0 = Array.isArray(state.users) ? state.users : [];
  if (!usersList0.length) return { state, batch: { users: [] } };

  const block = await publicClient.getBlock();
  const nowTs: bigint = block.timestamp;

  const maxUsers = config.compoundMaxUsersLp;
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
  for (let scanned = 0; scanned < lookahead; scanned++) {
    const usersList = Array.isArray(nextState.users) ? nextState.users : [];
    if (!usersList.length) break;
    if (cursor >= usersList.length) cursor = 0;
    const user = usersList[cursor];
    cursor = usersList.length ? (cursor + 1) % usersList.length : 0;
    nextState = { ...nextState, cursor };
    if (!user) continue;
    if (inFailureCooldown(nextState, user)) continue;
    if (inCompoundCooldown(nextState, user)) continue;
    if (morningCache && !isInMorningWindow(morningCache, user, config.morningWindowHours)) continue;
    candidates.push(user);
  }

  if (candidates.length > 0) {
    // Initial batch-read of on-chain configs via multicall (1 RPC instead of N).
    const cfgContracts = candidates.map((user) => ({
      address: lpVaultAddress,
      abi: LP_STAKING_VAULT_ABI,
      functionName: 'getAutoCompoundConfig' as const,
      args: [user as Address] as const,
    }));
    const cfgResults = await publicClient.multicall({ contracts: cfgContracts });

    const needRewards: Array<{ user: string; tokenId: bigint }> = [];
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
      needRewards.push({ user, tokenId });
    }

    if (needRewards.length > 0) {
      // Batch-read earned + lockInfo via multicall (1 RPC instead of 2N).
      const phase2Contracts = needRewards.flatMap(({ user, tokenId }) => [
        {
          address: lpVaultAddress,
          abi: LP_STAKING_VAULT_ABI,
          functionName: 'earned' as const,
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

      for (let i = 0; i < needRewards.length && batchUsers.length < maxUsers; i++) {
        const { user } = needRewards[i];
        const earnedR = phase2Results[i * 2];
        const lockR = phase2Results[i * 2 + 1];

        if (earnedR.status === 'failure') {
          nextState = markFailure(nextState, user, 'multicall_earned_failed');
          continue;
        }
        const claimIn: bigint = (earnedR.result as bigint) ?? 0n;
        if (
          claimIn === 0n ||
          (config.compoundLpMinReward > 0n && claimIn < config.compoundLpMinReward)
        ) {
          continue;
        }

        if (lockR.status === 'failure') {
          nextState = markFailure(nextState, user, 'multicall_lock_failed');
          continue;
        }
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
        batchAmounts.push(claimIn);
        nextState = clearFailure(nextState, user);
      }
    }
  }

  // Sort batch by smallest input first to reduce intra-tx state drift in Furnace.
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

  return { state: nextState, batch: { users: batchUsers } };
}

async function shrinkToGasLimit({
  publicClient,
  account,
  maxGas,
  lpVaultAddress,
  users,
}: {
  publicClient: PublicClient;
  account: PrivateKeyAccount;
  maxGas: number;
  lpVaultAddress: Address;
  users: string[];
}): Promise<{ users: string[]; gas: bigint }> {
  const maxGasBn = BigInt(maxGas);
  let n = users.length;
  if (!n) return { users: [], gas: 0n };

  while (n > 0) {
    const u = users.slice(0, n);

    try {
      const gas: bigint = await publicClient.estimateContractGas({
        address: lpVaultAddress,
        abi: LP_STAKING_VAULT_ABI,
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

export async function runCompoundLp({
  config,
  manifest,
  clients,
  morningCache,
  log,
}: CompoundLpOpts): Promise<void> {
  const chainId = parseChainIdStrict(manifest?.chainId) ?? 0;
  const statusInit = () => initStatusState({ deployment: config.deployment, chainId });

  const attemptAt = nowUtcIso();
  updateStatusFile({
    statusPath: config.statusPath,
    init: statusInit,
    patch: {
      lastAttemptAtUtc: attemptAt,
      lastAttemptByTask: { compoundLp: attemptAt },
    },
  });

  const lpVaultAddress = getContractAddress(manifest, 'LpStakingVault7D');
  requireNonZeroAddress(lpVaultAddress, 'LpStakingVault7D');

  const furnaceAddress = getContractAddress(manifest, 'Furnace');
  requireNonZeroAddress(furnaceAddress, 'Furnace');

  const veAddress = getContractAddress(manifest, 'VeClaimNFT');
  requireNonZeroAddress(veAddress, 'VeClaimNFT');

  const { publicClient, walletClient, account } = clients;

  // Determine scan start block.
  let startBlock: number | null =
    config.compoundLpStartBlock ?? getContractStartBlock(manifest, 'LpStakingVault7D');
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
    lpVaultAddress,
    statePath: config.compoundLpStatePath,
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
        `compound-lp: failed to read Furnace.lockingPaused(): ${String(errObj?.shortMessage ?? errObj?.message ?? e)}`,
      );
  }

  if (lockingPaused) {
    if (log) log('compound-lp: Furnace.lockingPaused=true, skipping');
    const successAt = nowUtcIso();
    updateStatusFile({
      statusPath: config.statusPath,
      init: statusInit,
      patch: {
        lastSuccessAtUtc: successAt,
        lastSuccessByTask: { compoundLp: successAt },
        lastError: null,
        lastErrorByTask: { compoundLp: null },
      },
    });
    return;
  }

  // 2) Select a batch (on-chain config + quoting)
  const sel = await selectBatch({
    publicClient,
    config,
    lpVaultAddress,
    veAddress,
    state: scan.state,
    morningCache,
    log,
  });

  // Persist cursor/failure updates even if we do a no-op.
  saveState(config.compoundLpStatePath, sel.state);

  // 3) Gas-bounded shrink
  const shrunk = await shrinkToGasLimit({
    publicClient,
    account,
    maxGas: config.compoundMaxGas,
    lpVaultAddress,
    users: sel.batch.users,
  });

  const users = shrunk.users ?? [];

  if (log) {
    log(
      `compound-lp: candidates=${sel.batch.users.length} selected=${users.length} gasCap=${config.compoundMaxGas}`,
    );
  }

  if (!users.length) {
    const successAt = nowUtcIso();
    updateStatusFile({
      statusPath: config.statusPath,
      init: statusInit,
      patch: {
        lastSuccessAtUtc: successAt,
        lastSuccessByTask: { compoundLp: successAt },
        lastError: null,
        lastErrorByTask: { compoundLp: null },
      },
    });

    return;
  }

  if (config.dryRun) {
    if (log) log('dry-run: not submitting LpStakingVault7D.compoundForMany');
    const successAt = nowUtcIso();
    updateStatusFile({
      statusPath: config.statusPath,
      init: statusInit,
      patch: {
        lastSuccessAtUtc: successAt,
        lastSuccessByTask: { compoundLp: successAt },
        lastError: null,
        lastErrorByTask: { compoundLp: null },
      },
    });
    return;
  }

  let hash: `0x${string}` | null = null;
  try {
    const tx = await sendContractTx({
      config,
      publicClient,
      walletClient,
      account,
      address: lpVaultAddress,
      abi: LP_STAKING_VAULT_ABI,
      functionName: 'compoundForMany',
      args: [users as readonly Address[], BigInt(users.length)],
      log,
      context: `LpStakingVault7D.compoundForMany users=${users.length}`,
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
          lastSuccessByTask: { compoundLp: skippedAt },

          lastSkipAtUtc: skippedAt,
          lastSkipByTask: { compoundLp: skippedAt },
          lastSkipReasonByTask: { compoundLp: tx.reason },

          lastError: null,
          lastErrorByTask: { compoundLp: null },
        },
      });
      return;
    }

    hash = tx.hash as `0x${string}`;
    const receipt = tx.receipt as {
      logs?: Array<{ address?: string; topics?: string[]; data?: string }>;
    };

    // Receipt-gated cooldown: `compoundForMany` can silently no-op a user when
    // the Furnace quote is unusable (no `LpRewardsLocked` emitted, no pause
    // signal). Marking every submitted user as compounded would record a
    // 7-day cooldown for users whose reward never landed. Parse the receipt
    // and mark only users who actually emitted `LpRewardsLocked`. The rest
    // stay eligible for the next tick — pause signals are tracked separately
    // by the watcher.
    const compoundedUsersFromReceipt = parseLpRewardsLockedUsers(
      receipt?.logs ?? [],
      lpVaultAddress,
    );
    const usersLower = users.map((u) => u.toLowerCase() as `0x${string}`);
    const successUsers = usersLower.filter((u) => compoundedUsersFromReceipt.has(u));
    const skippedUsers = usersLower.filter((u) => !compoundedUsersFromReceipt.has(u));
    if (skippedUsers.length > 0 && log) {
      log(
        `compound_lp: receipt-gated success ${successUsers.length}/${users.length}; ` +
          `silent skips not cooled-down: ${skippedUsers.length}`,
      );
    }

    const stateAfterCompound = markCompounded(sel.state, successUsers);
    saveState(config.compoundLpStatePath, stateAfterCompound);

    const successAt = nowUtcIso();
    updateStatusFile({
      statusPath: config.statusPath,
      init: statusInit,
      patch: {
        lastSuccessAtUtc: successAt,
        lastSuccessByTask: { compoundLp: successAt },

        lastTxHash: hash,
        lastTxHashByTask: { compoundLp: hash },

        lastError: null,
        lastErrorByTask: { compoundLp: null },
      },
    });

    return;
  } catch (e: unknown) {
    const errObj = e as { shortMessage?: string; message?: string };
    const err = String(errObj?.shortMessage ?? errObj?.message ?? e);

    const patch: Record<string, unknown> = {
      lastError: err,
      lastErrorByTask: { compoundLp: err },
    };
    if (hash) {
      patch.lastTxHash = hash;
      patch.lastTxHashByTask = { compoundLp: hash };
    }

    const cur = updateStatusFile({ statusPath: config.statusPath, init: statusInit, patch });
    const bumped = bumpRevertCount(cur, 'compoundLp');
    updateStatusFile({ statusPath: config.statusPath, init: statusInit, patch: bumped });

    await postAlert(config.alertWebhookUrl, {
      type: 'keeper_error',
      action: 'compound_lp',
      deployment: config.deployment,
      timestampUtc: nowUtcIso(),
      error: err,
      txHash: hash,
    });

    throw e;
  }
}
