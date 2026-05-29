/**
 * AutoMax bonus keeper.
 *
 * Finds autoMax locks eligible for a weekly bonus claim and calls
 * Furnace.claimAutoMaxBonusBatch for each batch.
 *
 * Eligibility: autoMax === true, not expired, not listed, lockAmount > 0,
 * and either lastAutoMaxBonusClaim == 0 (needs init) or
 * now - lastAutoMaxBonusClaim >= 86400 (24h on-chain cooldown elapsed).
 *
 * The keeper enforces a 7-day per-owner cooldown off-chain: when any lock
 * for an owner is processed, all of that owner's eligible locks are included
 * and the owner is skipped for 7 days. The protocol caps each user at 32 locks.
 */

import type { KeeperConfig } from '../shared/config.js';
import type { DeploymentManifest } from '../shared/deployments.js';
import type { ViemClients } from '../shared/clients.js';
import type { Address, PublicClient } from 'viem';

import { parseAbiItem } from 'viem';

import { FURNACE_ABI, FURNACE_QUOTER_ABI, VE_CLAIM_NFT_ABI } from '../shared/abis.js';
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
import type { MorningCache } from '../shared/user_morning.js';
import { isInMorningWindow } from '../shared/user_morning.js';
import { parseNonNegativeSafeInteger } from '../shared/utils.js';
import { computeExponentialBackoffDelayMs } from '../shared/backoff.js';
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
const DEFAULT_MAX_LOCKS_PER_RUN = 5000;
const ONCHAIN_BATCH_CAP = 200;
const ONCHAIN_BONUS_COOLDOWN_SECS = 86_400n;
const OWNER_COOLDOWN_MS = 7 * 24 * 60 * 60 * 1000; // 7 days per owner off-chain

// Per-eth_call slice size for the batched `lastAutoMaxBonusClaimBatch` view.
// Sized conservatively so a single oversized request doesn't blow through
// provider eth_call gas limits; the keeper iterates offsets transparently.
const LAST_CLAIM_READ_CHUNK = 200;

// Max parallel per-token reads in the fallback path (no quoter, or batch view
// failed). Each chunk is awaited as a `Promise.all` group; failures are retried
// with shared exponential backoff before being treated as null.
const LAST_CLAIM_READ_CONCURRENCY = 25;
const LAST_CLAIM_READ_RETRIES = 3;
const LAST_CLAIM_READ_BACKOFF_INITIAL_MS = 150;
const LAST_CLAIM_READ_BACKOFF_MAX_MS = 1500;

interface AutomaxBonusOpts {
  config: KeeperConfig;
  manifest: DeploymentManifest;
  clients: ViemClients;
  morningCache: MorningCache | null;
  log: (msg: string) => void;
}

interface LockRecord {
  lockEnd: string;
  autoMax: boolean;
  owner?: string;
}

interface AutomaxBonusState {
  version: number;
  lastScannedBlock: string;
  locks: Record<string, LockRecord>;
  lastClaimedByOwner: Record<string, string>;
}

function initState(): AutomaxBonusState {
  return {
    version: 1,
    lastScannedBlock: '0',
    locks: {},
    lastClaimedByOwner: {},
  };
}

function loadState(statePath: string): AutomaxBonusState {
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
  out.lastClaimedByOwner =
    raw.lastClaimedByOwner &&
    typeof raw.lastClaimedByOwner === 'object' &&
    !Array.isArray(raw.lastClaimedByOwner)
      ? (raw.lastClaimedByOwner as Record<string, string>)
      : {};
  return out;
}

function saveState(statePath: string, state: AutomaxBonusState): void {
  saveJsonAtomic(statePath, state);
}

function isOwnerInCooldown(state: AutomaxBonusState, owner: string): boolean {
  const ts = state.lastClaimedByOwner?.[owner];
  if (!ts) return false;
  const t = Date.parse(String(ts));
  if (!Number.isFinite(t)) return false;
  return Date.now() - t < OWNER_COOLDOWN_MS;
}

function markOwnersClaimed(state: AutomaxBonusState, owners: Set<string>): AutomaxBonusState {
  const lastClaimedByOwner = { ...(state.lastClaimedByOwner ?? {}) };
  const now = new Date().toISOString();
  for (const owner of owners) {
    lastClaimedByOwner[owner] = now;
  }
  return { ...state, lastClaimedByOwner };
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
}): Promise<{ state: AutomaxBonusState; scannedTo: bigint }> {
  let state = loadState(statePath);
  const latest: bigint = await publicClient.getBlockNumber();

  let lastScanned: bigint;
  try {
    lastScanned = BigInt(state.lastScannedBlock ?? '0');
  } catch {
    lastScanned = 0n;
  }
  if (lastScanned > latest + CHAIN_REWIND_TOLERANCE) {
    if (log) log(`automax-bonus: chain rewind, resetting state`);
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

  // Floor of 1: providers with strict `eth_getLogs` block-range limits (e.g.
  // free-tier endpoints on some Base Sepolia providers) need the env-configured
  // chunk size to be honoured verbatim. `getLogsWithAutoSplit` still handles
  // oversized chunks transparently if the provider rejects a request.
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
          owner: l.args?.user?.toString()?.toLowerCase(),
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
          locks[tokenId] = {
            lockEnd: String(newEnd ?? 0),
            autoMax: false,
            owner: l.args?.user?.toString()?.toLowerCase(),
          };
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
            locks[intoId] = {
              lockEnd: lockEnd.toString(),
              autoMax,
              owner: l.args?.user?.toString()?.toLowerCase() ?? locks[intoId]?.owner,
            };
          }
        } catch {
          // Best effort: if the read fails, keep existing cache entry.
        }
        continue;
      }

      if (kind === 'automax') {
        const tokenId = l.args?.tokenId?.toString();
        if (!tokenId) continue;
        const owner = l.args?.user?.toString()?.toLowerCase() ?? locks[tokenId]?.owner;
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
          locks[tokenId] = {
            lockEnd: resolved.lockEnd.toString(),
            autoMax: resolved.autoMax,
            owner,
          };
        } else {
          locks[tokenId] = {
            lockEnd: locks[tokenId]?.lockEnd ?? '0',
            autoMax: eventAutoMax,
            owner,
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

const ELIGIBILITY_BATCH_SIZE = 500;

// Mirrors `Constants.MAX_AUTOMAX_BONUS_BATCH` on-chain. `quoteAutoMaxBonusBatch`
// reverts with `BatchTooLarge` above this; chunk client calls so candidate
// lists larger than the cap still get bonus comparisons instead of falling
// through to the no-filter fallback path.
const AUTOMAX_QUOTE_BATCH_SIZE = 200;

async function selectAutomaxCandidates({
  publicClient,
  furnaceAddress,
  quoterAddress,
  state,
  nowTs,
  maxLocks,
  morningCache,
  morningWindowHours,
  log,
}: {
  publicClient: PublicClient;
  furnaceAddress: Address;
  quoterAddress: Address | null;
  state: AutomaxBonusState;
  nowTs: bigint;
  maxLocks: number;
  morningCache: MorningCache | null;
  morningWindowHours: number;
  log: (msg: string) => void;
}): Promise<string[]> {
  const locks = state.locks ?? {};
  const now = BigInt(nowTs);
  const tokenIds = Object.keys(locks);

  // Group eligible locks by owner so all of a user's locks are processed together.
  // The off-chain owner cooldown does NOT prefilter the prefiltered list: a
  // first-touch lock (`lastAutoMaxBonusClaim == 0`) should bootstrap immediately
  // even if the owner had a recent claim on a different lock. The cooldown gate
  // runs as a post-filter below, after the on-chain eligibility batch reveals
  // which candidates are first-touch.
  const byOwner: Map<string, string[]> = new Map();
  const ownerInCooldown = new Map<string, boolean>();

  for (const tokenIdStr of tokenIds) {
    const rec = locks[tokenIdStr];
    if (!rec || !rec.autoMax) continue;
    let lockEnd: bigint;
    try {
      lockEnd = BigInt(rec.lockEnd ?? 0);
    } catch {
      continue;
    }
    if (lockEnd <= now) continue;

    const owner = rec.owner ?? '';
    if (!owner) continue;

    if (morningCache) {
      if (!isInMorningWindow(morningCache, owner, morningWindowHours)) continue;
    }

    if (!ownerInCooldown.has(owner)) {
      ownerInCooldown.set(owner, isOwnerInCooldown(state, owner));
    }

    const ownerLocks = byOwner.get(owner);
    if (ownerLocks) ownerLocks.push(tokenIdStr);
    else byOwner.set(owner, [tokenIdStr]);
  }

  // Flatten owner groups into a single prefiltered list (all locks per owner together).
  const prefiltered = flattenOwnerGroupsForPrefilter(byOwner, maxLocks);

  if (prefiltered.length === 0) return [];

  const ownerOf = (tokenIdStr: string): string => locks[tokenIdStr]?.owner ?? '';
  const applyCooldownPostFilter = async (
    candidates: string[],
    candidateLastClaim: Map<string, bigint>,
  ): Promise<string[]> => {
    const candidatesNeedingLastClaim = candidates.filter((id) => !candidateLastClaim.has(id));
    if (candidatesNeedingLastClaim.length > 0) {
      const fetched = await readLastAutoMaxBonusClaimBatch({
        publicClient,
        furnaceAddress,
        quoterAddress,
        tokenIds: candidatesNeedingLastClaim,
        log,
      });
      for (const [id, lc] of fetched) candidateLastClaim.set(id, lc);
    }

    let droppedByCooldown = 0;
    const out: string[] = [];
    for (const id of candidates) {
      const owner = ownerOf(id);
      const lc = candidateLastClaim.get(id);
      const isFirstTouch = lc === 0n;
      if (!isFirstTouch && owner && ownerInCooldown.get(owner)) {
        droppedByCooldown++;
        continue;
      }
      out.push(id);
    }
    if (droppedByCooldown > 0 && log) {
      log(
        `automax-bonus: skipped ${droppedByCooldown} locks (owner in weekly cooldown, not first-touch)`,
      );
    }
    return out;
  };

  // Use batch on-chain eligibility check when FurnaceQuoter is available.
  if (quoterAddress) {
    const candidates: string[] = [];
    for (
      let offset = 0;
      offset < prefiltered.length && candidates.length < maxLocks;
      offset += ELIGIBILITY_BATCH_SIZE
    ) {
      const chunk = prefiltered.slice(offset, offset + ELIGIBILITY_BATCH_SIZE);
      const ids = chunk.map((id) => BigInt(id));
      try {
        const eligible = (await publicClient.readContract({
          address: quoterAddress,
          abi: FURNACE_QUOTER_ABI,
          functionName: 'filterAutoMaxBonusEligible',
          args: [ids],
        })) as boolean[];
        for (let i = 0; i < chunk.length && candidates.length < maxLocks; i++) {
          if (eligible[i]) candidates.push(chunk[i]);
        }
      } catch (e: unknown) {
        const err = e as { shortMessage?: string; message?: string };
        log(
          `automax-bonus: batch eligibility call failed (chunk ${offset}..${offset + chunk.length}), falling back to per-lock: ${err?.shortMessage ?? err?.message}`,
        );
        const remainingCandidatesByLastClaim = new Map<string, bigint>();
        const fallbackCandidates = await selectAutomaxCandidatesFallback({
          publicClient,
          furnaceAddress,
          prefiltered: prefiltered.slice(offset),
          now,
          maxLocks: maxLocks - candidates.length,
          candidates,
          recordLastClaim: (id, lc) => remainingCandidatesByLastClaim.set(id, lc),
        });
        return applyCooldownPostFilter(fallbackCandidates, remainingCandidatesByLastClaim);
      }
    }
    if (log && prefiltered.length > 0)
      log(
        `automax-bonus: batch eligibility ${prefiltered.length} locks → ${candidates.length} eligible (${Math.ceil(prefiltered.length / ELIGIBILITY_BATCH_SIZE)} RPC calls)`,
      );
    return applyCooldownPostFilter(candidates, new Map());
  }

  // Fallback: per-lock RPC reads (when quoter is not deployed or address unknown).
  const lastClaimByCandidate = new Map<string, bigint>();
  const fallbackCandidates = await selectAutomaxCandidatesFallback({
    publicClient,
    furnaceAddress,
    prefiltered,
    now,
    maxLocks,
    candidates: [],
    recordLastClaim: (id, lc) => lastClaimByCandidate.set(id, lc),
  });
  return applyCooldownPostFilter(fallbackCandidates, lastClaimByCandidate);
}

async function selectAutomaxCandidatesFallback({
  publicClient,
  furnaceAddress,
  prefiltered,
  now,
  maxLocks,
  candidates,
  recordLastClaim,
}: {
  publicClient: PublicClient;
  furnaceAddress: Address;
  prefiltered: string[];
  now: bigint;
  maxLocks: number;
  candidates: string[];
  recordLastClaim?: (tokenId: string, lastClaim: bigint) => void;
}): Promise<string[]> {
  for (const tokenIdStr of prefiltered) {
    if (candidates.length >= maxLocks) break;
    try {
      const lastClaim = (await publicClient.readContract({
        address: furnaceAddress,
        abi: FURNACE_ABI,
        functionName: 'lastAutoMaxBonusClaim',
        args: [BigInt(tokenIdStr)],
      })) as bigint;
      const eligible = isAutoMaxLastClaimEligible(lastClaim, now);
      if (!eligible) continue;
      candidates.push(tokenIdStr);
      if (recordLastClaim) recordLastClaim(tokenIdStr, lastClaim);
    } catch {
      // Lock may be burned or invalid; skip.
    }
  }
  return candidates;
}

/**
 * Read `lastAutoMaxBonusClaim` for the supplied token ids in batched chunks,
 * preferring `FurnaceQuoter.lastAutoMaxBonusClaimBatch` when available and
 * falling back to per-token reads on chunk failure. Tokens whose read fails
 * (e.g. burned mid-tick) are omitted from the returned map; callers should
 * treat absence as "unknown lastClaim" and gate accordingly.
 */
async function readLastAutoMaxBonusClaimBatch(args: {
  publicClient: PublicClient;
  furnaceAddress: Address;
  quoterAddress: Address | null;
  tokenIds: string[];
  log: (msg: string) => void;
}): Promise<Map<string, bigint>> {
  const out = new Map<string, bigint>();
  const { publicClient, furnaceAddress, quoterAddress, tokenIds, log } = args;
  if (tokenIds.length === 0) return out;

  if (quoterAddress) {
    for (let offset = 0; offset < tokenIds.length; offset += LAST_CLAIM_READ_CHUNK) {
      const chunk = tokenIds.slice(offset, offset + LAST_CLAIM_READ_CHUNK);
      const ids = chunk.map((id) => BigInt(id));
      try {
        const lastClaims = (await publicClient.readContract({
          address: quoterAddress,
          abi: FURNACE_QUOTER_ABI,
          functionName: 'lastAutoMaxBonusClaimBatch',
          args: [ids],
        })) as bigint[];
        for (let i = 0; i < chunk.length; i++) {
          out.set(chunk[i], lastClaims[i] ?? 0n);
        }
      } catch (e: unknown) {
        const err = e as { shortMessage?: string; message?: string };
        log(
          `automax-bonus: lastAutoMaxBonusClaimBatch (post-filter) chunk ${offset}..${offset + chunk.length} failed; per-token fallback: ${err?.shortMessage ?? err?.message}`,
        );
        for (const tokenIdStr of chunk) {
          try {
            const lc = (await publicClient.readContract({
              address: furnaceAddress,
              abi: FURNACE_ABI,
              functionName: 'lastAutoMaxBonusClaim',
              args: [BigInt(tokenIdStr)],
            })) as bigint;
            out.set(tokenIdStr, lc);
          } catch {
            // skip; absence is treated as unknown by caller
          }
        }
      }
    }
    return out;
  }

  for (const tokenIdStr of tokenIds) {
    try {
      const lc = (await publicClient.readContract({
        address: furnaceAddress,
        abi: FURNACE_ABI,
        functionName: 'lastAutoMaxBonusClaim',
        args: [BigInt(tokenIdStr)],
      })) as bigint;
      out.set(tokenIdStr, lc);
    } catch {
      // skip
    }
  }
  return out;
}

/**
 * Flatten owner-keyed lock groups into a single ordered list bounded by
 * `maxLocks`. An oversized owner group (e.g. a single user with more locks
 * than the cap, or stale/reorged cache entries that inflate a group) must
 * not stall later owners: skip it and keep scanning. As a degenerate
 * fallback, slice the first oversized group when no smaller group fits
 * inside `maxLocks` so the keeper still makes progress on every tick.
 *
 * Iteration order matches the input map, which mirrors the insertion order
 * of `byOwner` from the caller; that order is itself derived from the
 * lock-state token-id traversal, so the function is deterministic given
 * fixed cache state.
 */
export function flattenOwnerGroupsForPrefilter(
  byOwner: Map<string, string[]>,
  maxLocks: number,
): string[] {
  const out: string[] = [];
  for (const [, ownerLocks] of byOwner) {
    const remaining = maxLocks - out.length;
    if (remaining <= 0) break;
    if (ownerLocks.length > remaining) {
      if (out.length === 0) {
        out.push(...ownerLocks.slice(0, remaining));
        break;
      }
      continue;
    }
    out.push(...ownerLocks);
  }
  return out;
}

export function isAutoMaxLastClaimEligible(lastClaim: bigint, now: bigint): boolean {
  return lastClaim === 0n || now - lastClaim >= ONCHAIN_BONUS_COOLDOWN_SECS;
}

/**
 * Single-token `lastAutoMaxBonusClaim` read with bounded exponential backoff.
 *
 * Used only in the fallback path when either no quoter is configured or the
 * batch view returned an error. Survives transient RPC blips (429s, 5xx,
 * connection drops) up to `LAST_CLAIM_READ_RETRIES` attempts; a sustained
 * failure returns `null` and the token is treated as unknown by the caller.
 */
export async function readAutoMaxLastClaimWithRetry({
  publicClient,
  furnaceAddress,
  tokenId,
  retries = LAST_CLAIM_READ_RETRIES,
  initialDelayMs = LAST_CLAIM_READ_BACKOFF_INITIAL_MS,
  maxDelayMs = LAST_CLAIM_READ_BACKOFF_MAX_MS,
  sleep = defaultSleep,
}: {
  publicClient: PublicClient;
  furnaceAddress: Address;
  tokenId: string;
  retries?: number;
  initialDelayMs?: number;
  maxDelayMs?: number;
  sleep?: (ms: number) => Promise<void>;
}): Promise<bigint | null> {
  for (let attempt = 0; attempt <= retries; attempt++) {
    try {
      return (await publicClient.readContract({
        address: furnaceAddress,
        abi: FURNACE_ABI,
        functionName: 'lastAutoMaxBonusClaim',
        args: [BigInt(tokenId)],
      })) as bigint;
    } catch {
      if (attempt >= retries) return null;
      const delay = computeExponentialBackoffDelayMs({
        failureCount: attempt + 1,
        initialMs: initialDelayMs,
        multiplier: 2,
        maxMs: maxDelayMs,
        jitterBps: 2_000,
      });
      if (delay > 0) await sleep(delay);
    }
  }
  return null;
}

function defaultSleep(ms: number): Promise<void> {
  return new Promise((resolve) => setTimeout(resolve, ms));
}

/**
 * Reads `lastAutoMaxBonusClaim` for many tokens.
 *
 * Preferred path: a single `FurnaceQuoter.lastAutoMaxBonusClaimBatch(uint256[])`
 * RPC call when `quoterAddress` is available. The contract slices the input in
 * `LAST_CLAIM_READ_CHUNK`-sized batches so a single oversized request can be
 * retried at smaller granularity without blowing through provider gas/eth_call
 * limits.
 *
 * Fallback path (no quoter, or batch read fails): chunked concurrent per-token
 * reads bounded by `LAST_CLAIM_READ_CONCURRENCY`. This path is rate-limit aware:
 * a chunk that fails wholesale is retried with reduced parallelism via the
 * shared backoff helper.
 */
async function collectAutoMaxLastClaims({
  publicClient,
  furnaceAddress,
  quoterAddress,
  candidates,
  log,
}: {
  publicClient: PublicClient;
  furnaceAddress: Address;
  quoterAddress: Address | null;
  candidates: string[];
  log?: (msg: string) => void;
}): Promise<Map<string, bigint>> {
  const claims = new Map<string, bigint>();
  if (candidates.length === 0) return claims;

  if (quoterAddress) {
    const okViaBatch = await collectAutoMaxLastClaimsViaBatchView({
      publicClient,
      quoterAddress,
      candidates,
      out: claims,
      log,
    });
    if (okViaBatch) return claims;
  }

  await collectAutoMaxLastClaimsViaPerToken({
    publicClient,
    furnaceAddress,
    candidates,
    out: claims,
  });
  return claims;
}

async function collectAutoMaxLastClaimsViaBatchView({
  publicClient,
  quoterAddress,
  candidates,
  out,
  log,
}: {
  publicClient: PublicClient;
  quoterAddress: Address;
  candidates: string[];
  out: Map<string, bigint>;
  log?: (msg: string) => void;
}): Promise<boolean> {
  for (let offset = 0; offset < candidates.length; offset += LAST_CLAIM_READ_CHUNK) {
    const chunk = candidates.slice(offset, offset + LAST_CLAIM_READ_CHUNK);
    const ids = chunk.map((id) => BigInt(id));
    try {
      const lastClaims = (await publicClient.readContract({
        address: quoterAddress,
        abi: FURNACE_QUOTER_ABI,
        functionName: 'lastAutoMaxBonusClaimBatch',
        args: [ids],
      })) as bigint[];
      for (let i = 0; i < chunk.length; i++) {
        out.set(chunk[i], lastClaims[i] ?? 0n);
      }
    } catch (e: unknown) {
      const err = e as { shortMessage?: string; message?: string };
      if (log) {
        log(
          `automax-bonus: lastAutoMaxBonusClaimBatch failed (chunk ${offset}..${offset + chunk.length}); falling back to per-token reads: ${err?.shortMessage ?? err?.message}`,
        );
      }
      return false;
    }
  }
  return true;
}

async function collectAutoMaxLastClaimsViaPerToken({
  publicClient,
  furnaceAddress,
  candidates,
  out,
}: {
  publicClient: PublicClient;
  furnaceAddress: Address;
  candidates: string[];
  out: Map<string, bigint>;
}): Promise<void> {
  for (let offset = 0; offset < candidates.length; offset += LAST_CLAIM_READ_CONCURRENCY) {
    const chunk = candidates.slice(offset, offset + LAST_CLAIM_READ_CONCURRENCY);
    await Promise.all(
      chunk.map(async (tokenId) => {
        const lastClaim = await readAutoMaxLastClaimWithRetry({
          publicClient,
          furnaceAddress,
          tokenId,
        });
        if (lastClaim !== null) out.set(tokenId, lastClaim);
      }),
    );
  }
}

async function collectFirstTouchTokenIds({
  publicClient,
  furnaceAddress,
  quoterAddress,
  candidates,
  log,
}: {
  publicClient: PublicClient;
  furnaceAddress: Address;
  quoterAddress: Address | null;
  candidates: string[];
  log?: (msg: string) => void;
}): Promise<Set<string>> {
  const claims = await collectAutoMaxLastClaims({
    publicClient,
    furnaceAddress,
    quoterAddress,
    candidates,
    log,
  });
  const firstTouch = new Set<string>();
  for (const [tokenId, lastClaim] of claims) {
    if (lastClaim === 0n) firstTouch.add(tokenId);
  }
  return firstTouch;
}

export async function filterAutomaxCandidatesByMinReward({
  publicClient,
  furnaceAddress,
  quoterAddress,
  candidates,
  minReward,
  log,
}: {
  publicClient: PublicClient;
  furnaceAddress: Address;
  quoterAddress: Address | null;
  candidates: string[];
  minReward: bigint;
  log: (msg: string) => void;
}): Promise<{ candidates: string[]; bootstrapTokenIds: Set<string> }> {
  if (candidates.length === 0) return { candidates, bootstrapTokenIds: new Set() };

  if (minReward <= 0n || !quoterAddress) {
    const bootstrapTokenIds = await collectFirstTouchTokenIds({
      publicClient,
      furnaceAddress,
      quoterAddress,
      candidates,
      log,
    });
    return { candidates, bootstrapTokenIds };
  }

  try {
    // Chunk at the on-chain `MAX_AUTOMAX_BONUS_BATCH` cap. A single oversized
    // call would revert with `BatchTooLarge`, fall into the catch path, and
    // proceed without the min-reward filter — wasting gas on dust/zero-bonus
    // locks the operator explicitly configured away.
    const bonuses: bigint[] = [];
    for (let off = 0; off < candidates.length; off += AUTOMAX_QUOTE_BATCH_SIZE) {
      const slice = candidates.slice(off, off + AUTOMAX_QUOTE_BATCH_SIZE);
      const ids = slice.map((id) => BigInt(id));
      const [chunkBonuses] = (await publicClient.readContract({
        address: quoterAddress,
        abi: FURNACE_QUOTER_ABI,
        functionName: 'quoteAutoMaxBonusBatch',
        args: [ids],
      })) as [bigint[], bigint];
      bonuses.push(...chunkBonuses);
    }

    const belowMinCandidates = candidates.filter((_, i) => (bonuses[i] ?? 0n) < minReward);
    const bootstrapTokenIds = await collectFirstTouchTokenIds({
      publicClient,
      furnaceAddress,
      quoterAddress,
      candidates: belowMinCandidates,
      log,
    });

    const filteredCandidates = candidates.filter(
      (id, i) => (bonuses[i] ?? 0n) >= minReward || bootstrapTokenIds.has(id),
    );
    const skipped = candidates.length - filteredCandidates.length;
    if (skipped > 0 && log) {
      const kept = bootstrapTokenIds.size;
      log(
        kept > 0
          ? `automax-bonus: skipped ${skipped}/${candidates.length} locks below minReward=${minReward} CLAIM wei; kept ${kept} first-touch bootstraps`
          : `automax-bonus: skipped ${skipped}/${candidates.length} locks below minReward=${minReward} CLAIM wei`,
      );
    }

    return { candidates: filteredCandidates, bootstrapTokenIds };
  } catch (e: unknown) {
    const err = e as { shortMessage?: string; message?: string };
    if (log)
      log(
        `automax-bonus: quoteAutoMaxBonusBatch failed, proceeding without filter: ${err?.shortMessage ?? err?.message}`,
      );
    const bootstrapTokenIds = await collectFirstTouchTokenIds({
      publicClient,
      furnaceAddress,
      quoterAddress,
      candidates,
      log,
    });
    return { candidates, bootstrapTokenIds };
  }
}

export function collectAutomaxCooldownOwners(
  batch: string[],
  lockOwnerMap: Map<string, string>,
  bootstrapTokenIds: Set<string>,
  lastClaimsBeforeTx: Map<string, bigint>,
  lastClaimsAfterTx: Map<string, bigint>,
): Set<string> {
  const owners = new Set<string>();
  for (const id of batch) {
    if (bootstrapTokenIds.has(id)) continue;
    const before = lastClaimsBeforeTx.get(id);
    const after = lastClaimsAfterTx.get(id);
    if (before == null || after == null || after <= before) continue;
    const owner = lockOwnerMap.get(id);
    if (owner) owners.add(owner);
  }
  return owners;
}

export function sortAutomaxCandidateTokenIds(candidates: string[]): string[] {
  return candidates.slice().sort((a, b) => {
    const ai = BigInt(a);
    const bi = BigInt(b);
    if (ai < bi) return -1;
    if (ai > bi) return 1;
    return 0;
  });
}

export async function runAutomaxBonusOnce({
  config,
  manifest,
  clients,
  morningCache,
  log,
}: AutomaxBonusOpts): Promise<void> {
  const chainId = parseChainIdStrict(manifest?.chainId) ?? 0;
  const statusInit = () => initStatusState({ deployment: config.deployment, chainId });

  const attemptAt = nowUtcIso();
  updateStatusFile({
    statusPath: config.statusPath,
    init: statusInit,
    patch: {
      lastAttemptAtUtc: attemptAt,
      lastAttemptByTask: { automaxBonus: attemptAt },
    },
  });

  const veAddress = getContractAddress(manifest, 'VeClaimNFT');
  const furnaceAddress = getContractAddress(manifest, 'Furnace');
  requireNonZeroAddress(veAddress, 'VeClaimNFT');
  requireNonZeroAddress(furnaceAddress, 'Furnace');

  const { publicClient, walletClient, account } = clients;

  // Resolve FurnaceQuoter address for batch eligibility checks.
  let quoterAddress: Address | null = null;
  try {
    const addr = (await publicClient.readContract({
      address: furnaceAddress,
      abi: FURNACE_ABI,
      functionName: 'furnaceQuoter',
    })) as Address;
    if (addr && addr !== '0x0000000000000000000000000000000000000000') {
      quoterAddress = addr;
    }
  } catch {
    // Quoter not available; fall back to per-lock reads.
  }

  const statePath = config.automaxBonusStatePath;
  const startBlock: number =
    config.automaxBonusStartBlock ?? getContractStartBlock(manifest, 'VeClaimNFT');
  const chunkBlocks: number =
    config.automaxBonusScanChunkBlocks ?? config.compoundScanChunkBlocks ?? 2000;
  const maxLocks = config.automaxBonusMaxLocks ?? DEFAULT_MAX_LOCKS_PER_RUN;

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
  const candidates = await selectAutomaxCandidates({
    publicClient,
    furnaceAddress,
    quoterAddress,
    state: scan.state,
    nowTs,
    maxLocks,
    morningCache,
    morningWindowHours: config.morningWindowHours,
    log,
  });

  const minReward = BigInt(config.automaxBonusMinReward);
  const rewardFilter = await filterAutomaxCandidatesByMinReward({
    publicClient,
    furnaceAddress,
    quoterAddress,
    candidates,
    minReward,
    log,
  });
  const filteredCandidates = sortAutomaxCandidateTokenIds(rewardFilter.candidates);
  const bootstrapTokenIds = rewardFilter.bootstrapTokenIds;

  if (!filteredCandidates.length) {
    const successAt = nowUtcIso();
    updateStatusFile({
      statusPath: config.statusPath,
      init: statusInit,
      patch: {
        lastSuccessAtUtc: successAt,
        lastSuccessByTask: { automaxBonus: successAt },
        lastError: null,
        lastErrorByTask: { automaxBonus: null },
      },
    });
    return;
  }

  // Resolve owners for claimed locks so we can record per-owner cooldowns.
  const lockOwnerMap: Map<string, string> = new Map();
  for (const tokenIdStr of filteredCandidates) {
    const rec = scan.state.locks?.[tokenIdStr];
    if (rec?.owner) lockOwnerMap.set(tokenIdStr, rec.owner);
  }

  if (log) log(`automax-bonus: claiming bonus for ${filteredCandidates.length} autoMax locks`);

  if (config.dryRun) {
    updateStatusFile({
      statusPath: config.statusPath,
      init: statusInit,
      patch: {
        lastSuccessAtUtc: attemptAt,
        lastSuccessByTask: { automaxBonus: attemptAt },
        lastError: null,
        lastErrorByTask: { automaxBonus: null },
      },
    });
    return;
  }

  const lastClaimsBeforeTx = await collectAutoMaxLastClaims({
    publicClient,
    furnaceAddress,
    quoterAddress,
    candidates: filteredCandidates,
    log,
  });
  for (const [tokenId, lastClaim] of lastClaimsBeforeTx) {
    if (lastClaim === 0n) bootstrapTokenIds.add(tokenId);
  }

  let _successCount = 0;
  let lastError: string | null = null;
  let lastSkipReason: string | null = null;
  let lastSkipAtUtc: string | null = null;
  const claimedOwners: Set<string> = new Set();

  // Chunk candidates into batches of ONCHAIN_BATCH_CAP and submit one tx per batch.
  for (let offset = 0; offset < filteredCandidates.length; offset += ONCHAIN_BATCH_CAP) {
    const batch = filteredCandidates.slice(offset, offset + ONCHAIN_BATCH_CAP);
    const batchIds = batch.map((id) => BigInt(id));
    const label = batch.length === 1 ? `tokenId=${batch[0]}` : `tokenIds=[${batch.join(',')}]`;

    try {
      const tx = await sendContractTx({
        config,
        publicClient,
        walletClient,
        account,
        address: furnaceAddress,
        abi: FURNACE_ABI,
        functionName: 'claimAutoMaxBonusBatch',
        args: [batchIds, BigInt(batch.length)],
        log,
        context: `Furnace.claimAutoMaxBonusBatch ${label}`,
      });

      if (!tx.ok) {
        const code = tx.code;
        lastSkipReason = `${tx.reason} (${label})`;
        lastSkipAtUtc = nowUtcIso();

        const isGlobalSkip =
          code === 'paused' || code === 'dry_run' || code === 'pending_guard' || code === 'fee_cap';

        if (isGlobalSkip) {
          if (log) log(`automax-bonus: batch skipped; stopping: ${tx.reason}`);
          break;
        }

        if (log) log(`automax-bonus: batch skipped (${label}): ${tx.reason}`);
        continue;
      }

      const hash = tx.hash as `0x${string}`;
      _successCount += batch.length;
      const lastClaimsAfterTx = await collectAutoMaxLastClaims({
        publicClient,
        furnaceAddress,
        quoterAddress,
        candidates: batch,
        log,
      });
      for (const owner of collectAutomaxCooldownOwners(
        batch,
        lockOwnerMap,
        bootstrapTokenIds,
        lastClaimsBeforeTx,
        lastClaimsAfterTx,
      )) {
        claimedOwners.add(owner);
      }
      if (log) log(`automax-bonus: batch claimed ${batch.length} locks tx=${hash}`);
    } catch (e: unknown) {
      const errObj = e as { shortMessage?: string; message?: string };
      lastError = String(errObj?.shortMessage ?? errObj?.message ?? e);
      if (log) log(`automax-bonus: batch failed (${label}): ${lastError}`);
      await postAlert(config.alertWebhookUrl, {
        type: 'keeper_error',
        action: 'automax_bonus',
        deployment: config.deployment,
        timestampUtc: nowUtcIso(),
        error: lastError,
        batch: batch,
      });
    }
  }

  // Record per-owner cooldown for successfully claimed owners.
  // L4-1 (2026-04-17): `claimedOwners` is only populated inside the `tx.ok === true`
  // branch above, which — after the C-1 fix in `shared/tx.ts` — requires the receipt
  // status to be strictly `success`. Revert / pending_guard / null-status paths never
  // populate `claimedOwners`, so the weekly cooldown is never advanced on an
  // unconfirmed claim.
  if (claimedOwners.size > 0) {
    const updatedState = markOwnersClaimed(scan.state, claimedOwners);
    saveState(statePath, updatedState);
    if (log) log(`automax-bonus: marked ${claimedOwners.size} owners with weekly cooldown`);
  }

  const successAt = nowUtcIso();

  const patch: Record<string, unknown> = {
    lastSuccessAtUtc: successAt,
    lastSuccessByTask: { automaxBonus: successAt },
    lastError: lastError ?? null,
    lastErrorByTask: { automaxBonus: lastError ?? null },
  };

  if (lastSkipReason) {
    const t = lastSkipAtUtc ?? successAt;
    patch.lastSkipAtUtc = t;
    patch.lastSkipByTask = { automaxBonus: t };
    patch.lastSkipReasonByTask = { automaxBonus: lastSkipReason };

    if (!lastError) {
      patch.lastError = null;
      patch.lastErrorByTask = { automaxBonus: null };
    }
  }

  updateStatusFile({
    statusPath: config.statusPath,
    init: statusInit,
    patch: patch as any,
  });

  return;
}
