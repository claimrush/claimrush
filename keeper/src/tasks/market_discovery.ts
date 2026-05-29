import { parseAbiItem, type Address, type PublicClient } from 'viem';

import { MARKET_ROUTER_ABI } from '../shared/abis.js';
import { initMarketState, loadJson, saveJsonAtomic } from '../shared/state.js';
import { getLogsWithAutoSplit } from '../shared/rpc_logs.js';
import { parseUintBigIntOrNull } from '../shared/utils.js';

// =============================================================================
// STRICT MODE (v1.0.0+)
// =============================================================================
//
// In Strict Mode, Furnace is the ONLY buyer/sink for veNFT locks:
// - All configured bonus-target offers are auto-furnace candidates.
// - There is no autoFurnaceEnabled boolean in events or storage checks.
// - BonusTargetConfig tuple layout: (targetBonusBps, slippageBps, configured)
//   - Index [0] = targetBonusBps
//   - Index [1] = slippageBps
//   - Index [2] = configured (bool)
//
// The keeper adds offers to candidates on BonusTargetEscrowConfigured events
// and removes them on terminal events (cancel, expired, auto-furnace executed).
// =============================================================================

const EVT_BONUS_CFG = parseAbiItem(
  'event BonusTargetEscrowConfigured(uint256 indexed offerId, address indexed buyer, uint256 targetBonusBps, uint256 slippageBps)',
);
const EVT_CANCEL = parseAbiItem(
  'event BonusTargetEscrowCancelled(uint256 indexed offerId, address indexed buyer, uint256 refundClaim)',
);
// NOTE: EVT_FILLED (BonusTargetEscrowExecuted) is retained for reference but is
// NOT independently terminal in Strict Mode. MarketRouter now emits it as the
// canonical analytics alias alongside BonusTargetEscrowAutoFurnaceExecuted.
const EVT_FILLED = parseAbiItem(
  'event BonusTargetEscrowExecuted(uint256 indexed offerId, address indexed buyer, uint256 claimIn, uint256 principalClaim, uint256 bonusClaim, uint256 veOut, uint256 routeTokenId, uint256 furnaceTokenId)',
);
const EVT_EXPIRED = parseAbiItem(
  'event BonusTargetEscrowExpired(uint256 indexed offerId, address indexed buyer, uint256 refundClaim)',
);
const EVT_AUTO_FURNACE = parseAbiItem(
  'event BonusTargetEscrowAutoFurnaceExecuted(uint256 indexed offerId, address indexed buyer, uint256 claimIn, uint256 principalClaim, uint256 bonusClaim, uint256 veOut, uint256 routeTokenId, uint256 furnaceTokenId)',
);

// Suppress unused variable warning — EVT_FILLED is retained for reference.
void EVT_FILLED;

const CHAIN_REWIND_TOLERANCE = 64n;
// Rescan a small overlap window each run to tolerate short reorgs / RPC hiccups.
const SCAN_OVERLAP_BLOCKS = 64n;

function uniqStrings(xs: string[]): string[] {
  const s = new Set(xs);
  return [...s];
}

function sortOfferIdsAsc(ids: string[]): string[] {
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

function pruneOfferFailures(
  offerFailures: Record<string, unknown>,
  candidatesSet: Set<string>,
): Record<string, unknown> {
  if (!offerFailures || typeof offerFailures !== 'object' || Array.isArray(offerFailures))
    return {};
  const out: Record<string, unknown> = {};
  for (const [k, v] of Object.entries(offerFailures)) {
    const id = String(k);
    if (candidatesSet.has(id)) out[id] = v;
  }
  return out;
}

export async function scanMarketOffers({
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
  let state = (loaded ?? initMarketState()) as Record<string, unknown>;

  let offerFailures: Record<string, unknown> = {};
  if (
    state &&
    typeof state.offerFailures === 'object' &&
    state.offerFailures !== null &&
    !Array.isArray(state.offerFailures)
  ) {
    offerFailures = state.offerFailures as Record<string, unknown>;
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
      `market scan: dropped ${rawCandidates.length - candidates.size} invalid candidate offerIds from state file`,
    );
  }

  // If the chain has rewound (e.g. local Anvil restart) we must reset scan state,
  // otherwise we'll think we're already "ahead" and never rescan new offers.
  if (lastScanned > latest) {
    const delta = lastScanned - latest;
    // Small deltas can happen if the node is briefly behind; don't wipe state for that.
    if (delta <= CHAIN_REWIND_TOLERANCE) {
      if (log)
        log(
          `market scan: lastScannedBlock (${lastScanned.toString()}) is ahead of latest (${latest.toString()}) by ${delta.toString()} blocks; waiting for node`,
        );

      const from = lastScanned + 1n;
      return {
        latestBlock: latest,
        fromBlock: from,
        toBlock: latest,
        lastScannedBlock: lastScanned,
        candidates: sortOfferIdsAsc([...candidates]),
      };
    }

    if (log)
      log(
        `market scan: detected chain rewind/reset (lastScannedBlock=${lastScanned.toString()} > latest=${latest.toString()}). resetting state`,
      );

    state = initMarketState() as unknown as Record<string, unknown>;
    candidates = new Set<string>();
    offerFailures = {};
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
    if (log) log(`market scan: up to date (from=${from.toString()} > latest=${latest.toString()})`);
    return {
      latestBlock: latest,
      fromBlock: from,
      toBlock: latest,
      lastScannedBlock: lastScanned,
      candidates: sortOfferIdsAsc([...candidates]),
    };
  }

  const step = BigInt(chunkBlocks);
  let cursor = from;

  while (cursor <= latest) {
    const to = cursor + step - 1n <= latest ? cursor + step - 1n : latest;

    if (log) log(`market scan: blocks ${cursor.toString()}..${to.toString()}`);

    // Merged fetch: ONE `eth_getLogs` call covering all four event types
    // we care about on MarketRouter, instead of four parallel calls.  This
    // cuts RPC cost by ~75% on the polling/safety-net path without
    // changing behaviour — viem emits a `topics: [[sel1, sel2, sel3, sel4]]`
    // request and decodes each returned log against whichever event in
    // the `events` array matches its topic0.  See phase 4e in the
    // adaptive-keeper plan for the motivation.
    const mergedLogs = await getLogsWithAutoSplit({
      publicClient,
      request: {
        address: marketRouterAddress,
        events: [EVT_BONUS_CFG, EVT_CANCEL, EVT_AUTO_FURNACE, EVT_EXPIRED],
        fromBlock: cursor,
        toBlock: to,
      },
      log,
    });

    type MarketEvtKind = 'cfg' | 'cancel' | 'auto' | 'expired';
    type MarketEvt = { kind: MarketEvtKind; l: any };

    // Dispatch each log to the correct kind based on the decoded event
    // name that viem stamps onto the log.  Unrecognized logs (an ABI
    // mismatch or a future-added event) are ignored with a brief log so
    // we don't silently swallow them.
    const events: MarketEvt[] = [];
    for (const l of mergedLogs as any[]) {
      const name = l?.eventName as string | undefined;
      if (name === 'BonusTargetEscrowConfigured') events.push({ kind: 'cfg', l });
      else if (name === 'BonusTargetEscrowCancelled') events.push({ kind: 'cancel', l });
      else if (name === 'BonusTargetEscrowAutoFurnaceExecuted') events.push({ kind: 'auto', l });
      else if (name === 'BonusTargetEscrowExpired') events.push({ kind: 'expired', l });
      else if (log) log(`market scan: ignoring unrecognized event ${String(name)}`);
    }

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
      const id = l?.args?.offerId != null ? String(l.args.offerId) : null;
      if (!id) continue;
      if (kind === 'cfg') candidates.add(id);
      else candidates.delete(id);
    }

    // Persist progress chunk-by-chunk.
    // IMPORTANT: preserve offerFailures (backoff state) across scans.
    offerFailures = pruneOfferFailures(offerFailures, candidates);

    const nextState = {
      version: 2,
      lastScannedBlock: to.toString(),
      candidates: sortOfferIdsAsc(uniqStrings([...candidates])),
      offerFailures,
    };
    saveJsonAtomic(statePath, nextState);

    cursor = to + 1n;
  }

  return {
    latestBlock: latest,
    fromBlock: from,
    toBlock: latest,
    lastScannedBlock: latest,
    candidates: sortOfferIdsAsc([...candidates]),
  };
}

/**
 * Filter candidate offers to find eligible auto-furnace execution targets.
 *
 * STRICT MODE (v1.0.0+) INVARIANTS:
 * - All configured bonus-target offers are auto-furnace candidates.
 * - BonusTargetConfig tuple: (targetBonusBps, slippageBps, configured)
 * - An offer is eligible if: active && !expired && configured && fundsRemaining > 0
 */
export async function filterEligibleAutoFurnaceOffers({
  publicClient,
  marketRouterAddress,
  candidateOfferIds,
  maxOffers,
  log,
}: {
  publicClient: PublicClient;
  marketRouterAddress: Address;
  candidateOfferIds: string[];
  maxOffers?: number;
  log?: ((msg: string) => void) | null;
}): Promise<bigint[]> {
  if (!candidateOfferIds?.length) return [];

  const paused: boolean = await publicClient.readContract({
    address: marketRouterAddress,
    abi: MARKET_ROUTER_ABI,
    functionName: 'tradingPaused',
  });
  if (paused) {
    if (log) log('market: tradingPaused=true, skipping auto-furnace offers');
    return [];
  }

  const now: bigint = (await publicClient.getBlock()).timestamp;

  // De-noise: track which warnings have been logged this run to avoid spam.
  // Key format: "${offerId}:${reason}"
  const loggedWarnings = new Set<string>();
  const _logOnce = (offerId: bigint, reason: string, msg: string): void => {
    const key = `${offerId}:${reason}`;
    if (loggedWarnings.has(key)) return;
    loggedWarnings.add(key);
    if (log) log(msg);
  };

  const cap = maxOffers ?? Infinity;
  const loggedInvalidIds = new Set<string>();
  const validIds: bigint[] = [];
  for (const idStr of candidateOfferIds) {
    const offerId = parseUintBigIntOrNull(idStr);
    if (offerId == null) {
      if (log && !loggedInvalidIds.has(idStr)) {
        loggedInvalidIds.add(idStr);
        log(`market: invalid offerId in candidates list: ${JSON.stringify(idStr)} (skipping)`);
      }
      continue;
    }
    validIds.push(offerId);
  }
  if (!validIds.length) return [];

  // Batch-read offers + bonusTargetConfigs via multicall (2 reads per offer → 1 RPC total).
  const contracts = validIds.flatMap((offerId) => [
    {
      address: marketRouterAddress,
      abi: MARKET_ROUTER_ABI,
      functionName: 'offers' as const,
      args: [offerId] as const,
    },
    {
      address: marketRouterAddress,
      abi: MARKET_ROUTER_ABI,
      functionName: 'bonusTargetConfigs' as const,
      args: [offerId] as const,
    },
  ]);

  const results = await publicClient.multicall({ contracts });

  const out: bigint[] = [];
  for (let i = 0; i < validIds.length && out.length < cap; i++) {
    const offerResult = results[i * 2];
    const cfgResult = results[i * 2 + 1];
    if (offerResult.status === 'failure' || cfgResult.status === 'failure') continue;

    const offer = offerResult.result as any;
    const cfg = cfgResult.result as any;
    const fundsRemaining: bigint = offer?.[5] ?? 0n;
    const active: boolean = offer?.[8] ?? false;
    const expiresAt: bigint = offer?.[7] ?? 0n;
    const configured: boolean = cfg?.[2] ?? false;

    // Exact-expiry alignment: `MarketRouter` rejects auto-furnace execution at
    // `block.timestamp >= expiresAt` and admits expiry cancellation at the
    // same boundary. Treat `now == expiresAt` as no-longer-eligible here so
    // the keeper does not select a doomed-to-revert offer for execution while
    // the cancellation path simultaneously picks it up.
    if (!active || (expiresAt !== 0n && now >= expiresAt) || !configured || fundsRemaining === 0n) {
      continue;
    }
    out.push(validIds[i]);
  }

  if (log) log(`market: multicall ${validIds.length} offers → ${out.length} eligible`);
  return out;
}
