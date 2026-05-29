import { parseAbiItem, type Address, type PublicClient } from 'viem';

import { MARKET_ROUTER_ABI, FURNACE_ABI, VE_CLAIM_NFT_ABI } from '../shared/abis.js';
import { initListingsState, loadJson, saveJsonAtomic } from '../shared/state.js';
import { getLogsWithAutoSplit } from '../shared/rpc_logs.js';
import { parseUintBigIntOrNull } from '../shared/utils.js';

// =============================================================================
// LISTING DISCOVERY (STRICT MODE)
// =============================================================================
//
// In Strict Mode, Furnace is the ONLY buyer/sink for veNFT locks.
// Listings are limit-sell orders with a minClaimOut floor.
// Approved listing settlement uses allowlisted settlement-keeper or owner priority during grace, then becomes permissionless.
// Approval-revoked stale listings can still self-clear permissionlessly via sellListedLockToFurnace(tokenId).
//
// The keeper scans for LockListed events to find candidates and removes them
// on LockDelisted events (delist, sold, emergency).
// =============================================================================

const EVT_LOCK_LISTED = parseAbiItem(
  'event LockListed(uint256 indexed tokenId, address indexed seller, uint256 minClaimOut, uint256 listedAtTime, uint256 expiresAtTime)',
);
const EVT_LOCK_DELISTED = parseAbiItem(
  'event LockDelisted(uint256 indexed tokenId, address indexed seller, uint8 reason)',
);

const CHAIN_REWIND_TOLERANCE = 64n;
// Rescan a small overlap window each run to tolerate short reorgs / RPC hiccups.
const SCAN_OVERLAP_BLOCKS = 64n;

function uniqStrings(xs: string[]): string[] {
  const s = new Set(xs);
  return [...s];
}

function sortTokenIdsAsc(ids: string[]): string[] {
  const parsed: Array<{ id: string; n: bigint }> = [];
  for (const x of ids) {
    const id = String(x);
    const n = parseUintBigIntOrNull(id);
    if (n == null) continue;
    parsed.push({ id, n });
  }
  parsed.sort((a, b) => (a.n < b.n ? -1 : a.n > b.n ? 1 : 0));
  return parsed.map((p) => p.id);
}

function pruneListingFailures(
  listingFailures: Record<string, unknown>,
  candidatesSet: Set<string>,
): Record<string, unknown> {
  if (!listingFailures || typeof listingFailures !== 'object' || Array.isArray(listingFailures))
    return {};
  const out: Record<string, unknown> = {};
  for (const [k, v] of Object.entries(listingFailures)) {
    const id = String(k);
    if (candidatesSet.has(id)) out[id] = v;
  }
  return out;
}

/**
 * Scan blockchain for listing events and maintain candidate list.
 */
export async function scanListings({
  publicClient,
  marketRouterAddress,
  statePath,
  startBlock,
  chunkBlocks,
  log,
}: {
  publicClient: PublicClient;
  marketRouterAddress: Address;
  statePath: string;
  startBlock: number;
  chunkBlocks: number;
  log?: ((msg: string) => void) | null;
}): Promise<{
  latestBlock: bigint;
  fromBlock: bigint;
  toBlock: bigint;
  lastScannedBlock: bigint;
  candidates: string[];
}> {
  const latest: bigint = await publicClient.getBlockNumber();
  const loaded = loadJson(statePath, { fallback: null });
  let state = (loaded ?? initListingsState()) as Record<string, unknown>;

  let listingFailures: Record<string, unknown> = {};
  if (
    state &&
    typeof state.listingFailures === 'object' &&
    state.listingFailures !== null &&
    !Array.isArray(state.listingFailures)
  ) {
    listingFailures = state.listingFailures as Record<string, unknown>;
  }

  // Parse lastScannedBlock robustly (it may be stored as string or number).
  let lastScanned = 0n;
  try {
    if (state?.lastScannedBlock != null) {
      const v = state.lastScannedBlock;
      const n = typeof v === 'bigint' ? v : BigInt(v as string);
      if (n > 0n) lastScanned = n;
    }
  } catch {
    lastScanned = 0n;
  }

  const rawCandidates: string[] = Array.isArray(state?.candidates)
    ? state.candidates.map(String)
    : [];

  let candidates = new Set<string>(rawCandidates.filter((id) => parseUintBigIntOrNull(id) != null));
  if (rawCandidates.length && candidates.size !== rawCandidates.length && log) {
    log(
      `listings scan: dropped ${rawCandidates.length - candidates.size} invalid candidate tokenIds from state file`,
    );
  }

  // If the chain has rewound (e.g. local Anvil restart) we must reset scan state,
  // otherwise we'll think we're already "ahead" and never rescan new listings.
  if (lastScanned > latest) {
    const delta = lastScanned - latest;
    // Small deltas can happen if the node is briefly behind; don't wipe state for that.
    if (delta <= CHAIN_REWIND_TOLERANCE) {
      if (log)
        log(
          `listings scan: lastScannedBlock (${lastScanned.toString()}) is ahead of latest (${latest.toString()}) by ${delta.toString()} blocks; waiting for node`,
        );

      const from = lastScanned + 1n;
      return {
        latestBlock: latest,
        fromBlock: from,
        toBlock: latest,
        lastScannedBlock: lastScanned,
        candidates: sortTokenIdsAsc([...candidates]),
      };
    }

    if (log)
      log(
        `listings scan: detected chain rewind/reset (lastScannedBlock=${lastScanned.toString()} > latest=${latest.toString()}). resetting state`,
      );

    state = initListingsState() as unknown as Record<string, unknown>;
    candidates = new Set<string>();
    listingFailures = {};
    lastScanned = 0n;
    saveJsonAtomic(statePath, state);
  }

  const resumeFrom =
    lastScanned === 0n
      ? BigInt(startBlock)
      : lastScanned + 1n > SCAN_OVERLAP_BLOCKS
        ? lastScanned + 1n - SCAN_OVERLAP_BLOCKS
        : 0n;

  const from = resumeFrom < BigInt(startBlock) ? BigInt(startBlock) : resumeFrom;

  if (from > latest) {
    if (log)
      log(`listings scan: up to date (from=${from.toString()} > latest=${latest.toString()})`);
    return {
      latestBlock: latest,
      fromBlock: from,
      toBlock: latest,
      lastScannedBlock: lastScanned,
      candidates: sortTokenIdsAsc([...candidates]),
    };
  }

  const step = BigInt(chunkBlocks);
  let cursor = from;

  while (cursor <= latest) {
    const to = cursor + step - 1n <= latest ? cursor + step - 1n : latest;

    if (log) log(`listings scan: blocks ${cursor.toString()}..${to.toString()}`);

    // Fetch listing events.
    // IMPORTANT: process LockListed + LockDelisted in chronological order.
    // A token can be delisted and re-listed within the same scan window; if we
    // naively apply all delists after all lists we can end the chunk in the
    // wrong state.
    //
    // Merged into a single `eth_getLogs` call (phase 4e) to cut RPC cost
    // on the polling/safety-net path.  viem decodes each returned log
    // against whichever event in the `events` array matches its topic0.
    const listingLogs = await getLogsWithAutoSplit({
      publicClient,
      request: {
        address: marketRouterAddress,
        events: [EVT_LOCK_LISTED, EVT_LOCK_DELISTED],
        fromBlock: cursor,
        toBlock: to,
      },
      log,
    });

    type EventItem = { kind: 'listed' | 'delisted'; l: any };
    const merged: EventItem[] = [];
    for (const l of listingLogs as any[]) {
      const name = l?.eventName as string | undefined;
      if (name === 'LockListed') merged.push({ kind: 'listed', l });
      else if (name === 'LockDelisted') merged.push({ kind: 'delisted', l });
      else if (log) log(`listing scan: ignoring unrecognized event ${String(name)}`);
    }

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
      const id = l?.args?.tokenId;
      if (id == null) continue;
      const tokenId = String(id);
      if (it.kind === 'listed') candidates.add(tokenId);
      else candidates.delete(tokenId);
    }

    // Persist progress chunk-by-chunk.
    // IMPORTANT: preserve listingFailures (backoff state) across scans.
    listingFailures = pruneListingFailures(listingFailures, candidates);

    const nextState = {
      version: 1,
      lastScannedBlock: to.toString(),
      candidates: sortTokenIdsAsc(uniqStrings([...candidates])),
      listingFailures,
    };
    saveJsonAtomic(statePath, nextState);

    cursor = to + 1n;
  }

  return {
    latestBlock: latest,
    fromBlock: from,
    toBlock: latest,
    lastScannedBlock: latest,
    candidates: sortTokenIdsAsc([...candidates]),
  };
}

/**
 * Filter candidate listings to find:
 * - eligible settlement targets (fillable now)
 * - expired listings (permissionless cancelExpiredListing)
 *
 * A listing is eligible if:
 * - listing.active is true
 * - listing is not expired (now <= expiresAtTime)
 * - lock has not expired (lockEnd > now)
 * - Furnace quote >= listing.minClaimOut
 */
export async function filterEligibleListings({
  publicClient,
  marketRouterAddress,
  furnaceAddress,
  veAddress,
  candidateTokenIds,
  maxListings,
  log,
}: {
  publicClient: PublicClient;
  marketRouterAddress: Address;
  furnaceAddress: Address;
  veAddress: Address;
  candidateTokenIds: string[];
  maxListings: number;
  log?: ((msg: string) => void) | null;
}): Promise<{ eligible: bigint[]; expired: bigint[] }> {
  if (!candidateTokenIds?.length) return { eligible: [], expired: [] };

  const paused: boolean = await publicClient.readContract({
    address: marketRouterAddress,
    abi: MARKET_ROUTER_ABI,
    functionName: 'tradingPaused',
  });

  const now: bigint = (await publicClient.getBlock()).timestamp;

  // De-noise: track which warnings have been logged this run to avoid spam.
  // Key format: "${tokenId}:${reason}"
  const loggedWarnings = new Set<string>();
  const _logOnce = (tokenId: bigint, reason: string, msg: string): void => {
    const key = `${tokenId}:${reason}`;
    if (loggedWarnings.has(key)) return;
    loggedWarnings.add(key);
    if (log) log(msg);
  };

  const eligible: bigint[] = [];
  const expired: bigint[] = [];

  const loggedInvalidIds = new Set<string>();
  const validIds: bigint[] = [];
  for (const idStr of candidateTokenIds) {
    const tokenId = parseUintBigIntOrNull(idStr);
    if (tokenId == null) {
      if (log && !loggedInvalidIds.has(idStr)) {
        loggedInvalidIds.add(idStr);
        log(`listings: invalid tokenId in candidates list: ${JSON.stringify(idStr)} (skipping)`);
      }
      continue;
    }
    validIds.push(tokenId);
  }

  if (!validIds.length) return { eligible: [], expired: [] };

  // Initial batch-read of all listings via multicall (1 RPC instead of N).
  const listingContracts = validIds.map((tokenId) => ({
    address: marketRouterAddress,
    abi: MARKET_ROUTER_ABI,
    functionName: 'getListing' as const,
    args: [tokenId] as const,
  }));
  const listingResults = await publicClient.multicall({ contracts: listingContracts });

  // Collect non-expired, active listings that need lockInfo + quote.
  const needLockInfo: Array<{ tokenId: bigint; minClaimOut: bigint }> = [];
  for (let i = 0; i < validIds.length; i++) {
    const tokenId = validIds[i];
    const r = listingResults[i];
    if (r.status === 'failure') continue;
    const listing = r.result as any;
    const active: boolean = listing?.[4] ?? false;
    if (!active) continue;
    const expiresAtTime: bigint = listing?.[3] ?? 0n;
    // Exact-expiry alignment: `MarketRouter` rejects settlement at
    // `block.timestamp >= expiresAtTime` and admits `cancelExpiredListing`
    // at the same boundary. Treat `now == expiresAtTime` as expired here so
    // an exact-boundary listing is sent down the cancel path instead of
    // being preflighted as a doomed settle.
    if (expiresAtTime == 0n || now >= expiresAtTime) {
      if (expired.length < maxListings) expired.push(tokenId);
      continue;
    }
    if (paused) continue;
    needLockInfo.push({ tokenId, minClaimOut: listing?.[1] ?? 0n });
  }

  if (needLockInfo.length > 0) {
    // Batch-read lockInfo for surviving candidates (1 RPC instead of N).
    const lockContracts = needLockInfo.map(({ tokenId }) => ({
      address: veAddress,
      abi: VE_CLAIM_NFT_ABI,
      functionName: 'getLockInfo' as const,
      args: [tokenId] as const,
    }));
    const lockResults = await publicClient.multicall({ contracts: lockContracts });

    const needQuote: Array<{
      tokenId: bigint;
      minClaimOut: bigint;
      lockAmount: bigint;
      lockEnd: bigint;
      autoMax: boolean;
    }> = [];
    for (let i = 0; i < needLockInfo.length; i++) {
      const { tokenId, minClaimOut } = needLockInfo[i];
      const r = lockResults[i];
      if (r.status === 'failure') continue;
      const lockInfo = r.result as any;
      const lockAmount: bigint = lockInfo?.[0] ?? 0n;
      const lockEnd: bigint = lockInfo?.[1] ?? 0n;
      const autoMax: boolean = lockInfo?.[2] ?? false;
      if ((lockEnd !== 0n && now >= lockEnd) || lockAmount === 0n) continue;
      needQuote.push({ tokenId, minClaimOut, lockAmount, lockEnd, autoMax });
    }

    if (needQuote.length > 0) {
      // Batch-read furnace quotes in a single RPC instead of one call per lock.
      const quoteContracts = needQuote.map(({ lockAmount, lockEnd, autoMax }) => ({
        address: furnaceAddress,
        abi: FURNACE_ABI,
        functionName: 'quoteSellLockToFurnaceFromInfo' as const,
        args: [lockAmount, lockEnd, autoMax] as const,
      }));
      const quoteResults = await publicClient.multicall({ contracts: quoteContracts });

      for (let i = 0; i < needQuote.length && eligible.length < maxListings; i++) {
        const { tokenId, minClaimOut } = needQuote[i];
        const r = quoteResults[i];
        if (r.status === 'failure') continue;
        const quote = r.result as any;
        const quoteClaimOut: bigint = quote?.[0] ?? 0n;
        if (quoteClaimOut >= minClaimOut) {
          eligible.push(tokenId);
        }
      }
    }
  }

  if (log) {
    log(
      `listings: multicall ${validIds.length} listings → eligible=${eligible.length} expired=${expired.length}`,
    );
  }

  if (paused && log && expired.length) {
    log(`listings: tradingPaused=true; eligible=0; expired=${expired.length}`);
  }

  return { eligible, expired };
}
