import {
  Address,
  BigInt,
  Bytes,
  dataSource,
  ethereum,
  store,
  Value,
} from '@graphprotocol/graph-ts';

import {
  AutoMaxBonusClaimed,
  BonusPaid,
  DelegationSessionUsed,
  EntryTokenRegistrySet,
  Furnace as FurnaceContract,
  MineCoreChanged,
  MineMarketChanged,
  FurnaceEnter,
  FurnaceMergeWithBonus,
  FurnaceQuoterSet,
  LockSoldToFurnace,
  LockingPausedChanged,
  LpOverflowDripPaid,
  LpRewardsNotifyFailed,
  LpRewardsVaultSet,
  LpStreamFunded,
  ReserveClamped,
  ReserveCredited,
  ShareholderRoyaltiesChanged,
} from '../generated/Furnace/Furnace';
import {
  FurnaceQuoter,
  FurnaceQuoter__getFurnaceStateResult,
} from '../generated/Furnace/FurnaceQuoter';
import { EntryTokenRegistry as EntryTokenRegistryTemplate } from '../generated/templates';

import {
  ActivityItem,
  AutoMaxBonusClaimedEvent,
  BonusPaidEvent,
  DailyFurnaceAgg,
  EntryTokenRegistry as EntryTokenRegistryEntity,
  FurnaceBonusSample,
  FurnaceBonusSnapshot,
  FurnaceEnterEvent,
  FurnaceMergeWithBonusEvent,
  FurnaceQuoterSetEvent,
  TxFurnaceEnter,
  FurnaceState,
  LpRewardsSample,
  LpOverflowDripPaidEvent,
  LockSoldToFurnaceEvent,
  MarketTradeEvent,
  LpRewardsNotifyFailedEvent,
  LpRewardsVaultSetEvent,
  LpStreamFundedEvent,
  PendingBonusPaid,
  PendingBonusPaidQueue,
  ReserveClampedEvent,
  ReserveCreditedEvent,
  VeLock,
} from '../generated/schema';

import { dayIdFromTimestamp, dayStartFromDayId, SECONDS_PER_DAY } from '../utils/day';
import { eventId } from '../utils/id';
import { saveActivityItem } from '../utils/activity';
import { recordDelegationSessionUsed } from '../utils/delegation';
import { loadOrCreateProtocol, setBytesIfZero, ZERO_ADDRESS } from '../utils/protocol';
import { snapshotEntryTokenRegistry } from '../utils/entryTokenRegistryInit';
import { blockSortKey } from '../utils/sortKey';
import { loadOrCreateUser } from '../utils/user';
import { currentVeWei } from '../utils/ve';

const ZERO = BigInt.fromI32(0);

// Furnace enter modes (docs/analytics/dune-integration-pack-v1.0.0.md)
const MODE_ENTER_WITH_TOKEN = 3;

// Bonus sampling (docs/analytics/subgraph-schema-v1.0.0.md)
const BUCKET_5M = 300;
const BUCKET_1H = 3600;
const WINDOW_24H = 86400;
const WINDOW_7D = 604800;
const WINDOW_30D = 2592000; // 30 * 86400

// Sentinel for DailyFurnaceAgg.quoteBonusMinBps before first sample is recorded.
// Use i32.MAX_VALUE so future bonus models that allow bps > 10000 still compare correctly.
const BONUS_BPS_SENTINEL: i32 = 2147483647;

// On-chain reference: src/lib/Constants.sol :: MAX_GROSS_BONUS_BPS = 12500. Mirrors
// the cap applied by `FurnaceQuoter._grossSpotBonusBps` and `FurnaceGuardHelper._grossSpotBonusBps`.
const MAX_GROSS_BONUS_BPS: i32 = 12500;
const BPS_DENOM: i32 = 10000;

/// Mirror `FurnaceQuoter._grossSpotBonusBps`:
/// `gross = userSpot + floor(userSpot * lpRate / BPS_DENOM)` clamped at
/// `MAX_GROSS_BONUS_BPS`. AssemblyScript i32 arithmetic suffices because
/// `userSpot, lpRate <= 10000` so the intermediate product is bounded by
/// 10000 * 10000 = 1e8, well within i32 range.
function computeGrossSpotBonusBps(userSpotBps: i32, lpTopupRateBps: i32): i32 {
  if (userSpotBps <= 0 || lpTopupRateBps < 0) return userSpotBps > 0 ? userSpotBps : 0;
  const lpTopupSpotBps: i32 = (userSpotBps * lpTopupRateBps) / BPS_DENOM;
  const gross: i32 = userSpotBps + lpTopupSpotBps;
  if (gross > MAX_GROSS_BONUS_BPS) return MAX_GROSS_BONUS_BPS;
  return gross;
}

function txFurnaceEnterIdByLog(txHash: Bytes, logIndex: BigInt): string {
  return txHash.toHexString() + '-' + logIndex.toString();
}

function loadOrCreateDay(dayId: string): DailyFurnaceAgg {
  let d = DailyFurnaceAgg.load(dayId);
  if (d == null) {
    d = new DailyFurnaceAgg(dayId);
    d.dayStartTimestamp = dayStartFromDayId(dayId);
    d.bonusPaidCount = 0;
    d.dripCount = 0;
    d.totalGrossBonus = ZERO;
    d.totalUserBonus = ZERO;
    d.totalLpTopup = ZERO;
    d.totalLpDrip = ZERO;
    d.totalLpFromFurnace = ZERO;
    d.sellCount = 0;
    d.totalSellLockAmount = ZERO;
    d.totalSellClaimOut = ZERO;
    d.totalSellLpReward = ZERO;
    d.totalSellReserveAdd = ZERO;
    d.reserveEnd = ZERO;
    d.quoteBonusMinBps = BONUS_BPS_SENTINEL;
    d.quoteBonusMaxBps = 0;
    d.save();
  }
  return d as DailyFurnaceAgg;
}

function pendingBonusPaidQueueId(txHash: Bytes, user: Bytes): string {
  return txHash.toHexString() + '-' + user.toHexString();
}

function pendingBonusPaidId(queueId: string, sequence: i32): string {
  return queueId + '-' + sequence.toString();
}

function loadOrCreatePendingBonusPaidQueue(id: string): PendingBonusPaidQueue {
  let q = PendingBonusPaidQueue.load(id);
  if (q == null) {
    q = new PendingBonusPaidQueue(id);
    q.head = 0;
    q.tail = 0;
  }
  return q as PendingBonusPaidQueue;
}

function recordPendingBonusPaid(event: BonusPaid): void {
  const queueId = pendingBonusPaidQueueId(event.transaction.hash, event.params.user);
  const queue = loadOrCreatePendingBonusPaidQueue(queueId);
  const sequence = queue.tail;
  queue.tail = queue.tail + 1;
  queue.save();

  const p = new PendingBonusPaid(pendingBonusPaidId(queueId, sequence));
  p.queueId = queueId;
  p.sequence = sequence;
  p.txHash = event.transaction.hash;
  p.user = event.params.user;
  p.timestamp = event.block.timestamp;
  p.blockNumber = event.block.number;
  p.userBonusClaim = event.params.userBonusClaim;
  p.reserveAfter = event.params.reserveAfter;
  p.save();
}

function settleDeliveredUserBonus(
  timestamp: BigInt,
  txHash: Bytes,
  user: Bytes,
  bonusClaim: BigInt,
): void {
  const dayId = dayIdFromTimestamp(timestamp);
  const daily = loadOrCreateDay(dayId);
  daily.totalUserBonus = daily.totalUserBonus.plus(bonusClaim);

  const queueId = pendingBonusPaidQueueId(txHash, user);
  const queue = PendingBonusPaidQueue.load(queueId);
  if (queue != null) {
    const pendingId = pendingBonusPaidId(queueId, queue.head);
    const pending = PendingBonusPaid.load(pendingId);
    if (pending != null) {
      let finalReserve = pending.reserveAfter;
      if (pending.userBonusClaim.gt(bonusClaim)) {
        finalReserve = finalReserve.plus(pending.userBonusClaim.minus(bonusClaim));
      }

      daily.reserveEnd = finalReserve;

      const state = loadOrCreateFurnaceState();
      state.updatedAt = timestamp;
      state.reserve = finalReserve;
      state.save();

      store.remove('PendingBonusPaid', pendingId);
    }

    queue.head = queue.head + 1;
    if (queue.head >= queue.tail) {
      store.remove('PendingBonusPaidQueue', queueId);
    } else {
      queue.save();
    }
  }

  daily.save();
}

function loadOrCreateFurnaceBonusSnapshot(): FurnaceBonusSnapshot {
  const id = '1';
  let s = FurnaceBonusSnapshot.load(id);
  if (s == null) {
    s = new FurnaceBonusSnapshot(id);
    s.updatedAt = ZERO;
    // Store dayStart timestamp (unix seconds) in a 32-bit int (safe through year 2038).
    s.lastDayId = 0;

    // Optional internal field added in v1.0.0: backfilled for older stores.
    s.last24hRecomputeBucketStart = ZERO;

    s.currentBps = 0;
    s.min24hBps = 0;
    s.max24hBps = 0;
    s.min7dBps = 0;
    s.max7dBps = 0;
    s.min30dBps = 0;
    s.max30dBps = 0;
    s.q33Bps = 0;
    s.q66Bps = 0;
    // Codegen treats optional Int as i32 with default 0.
    s.q95Bps = 0;
    s.save();
  } else {
    // Backfill new optional fields when reusing an existing store.
    if (s.get('last24hRecomputeBucketStart') == null) {
      s.last24hRecomputeBucketStart = ZERO;
      s.save();
    }
  }
  return s as FurnaceBonusSnapshot;
}

function bucketStart(ts: BigInt, bucketSeconds: i32): BigInt {
  const b = BigInt.fromI32(bucketSeconds);
  return ts.minus(ts.mod(b));
}

function dayIdI32(ts: BigInt): i32 {
  // Day index (unix_seconds / 86400). Fits in i32 until year ~5.8 million.
  return ts.div(BigInt.fromI32(SECONDS_PER_DAY)).toI32();
}

function bonusSampleId(bucketSeconds: i32, bucketStartTs: BigInt): string {
  return bucketSeconds.toString() + '-' + bucketStartTs.toString();
}

function computeQuantile(sorted: i32[], q: f64): i32 {
  if (sorted.length == 0) {
    return 0;
  }
  if (sorted.length == 1) {
    return sorted[0];
  }

  // Simple "nearest-rank" style index over [0, n-1].
  const n = sorted.length as f64;
  const idx = Math.floor((n - 1.0) * q) as i32;
  return sorted[idx];
}

function updateSnapshotFromLast24h(ts: BigInt, currentQuoteBps: i32): void {
  const snap = loadOrCreateFurnaceBonusSnapshot();

  const currentBucketStart = bucketStart(ts, BUCKET_5M);

  // Full recompute at most once per 5m bucket (tracked in the snapshot).
  const lastRecompute = snap.last24hRecomputeBucketStart;
  let needsFull = lastRecompute === null || !(lastRecompute as BigInt).equals(currentBucketStart);

  // Day boundary detection for 7d/30d aggregation.
  const currDayId = dayIdI32(ts);
  const isDayChange = snap.lastDayId != currDayId;

  // Always keep "live" fields fresh.
  snap.updatedAt = ts;
  snap.currentBps = currentQuoteBps;

  // Fast path: within the same 5m bucket, avoid scanning 24h of samples.
  if (!needsFull) {
    // 24h min/max can widen intra-bucket; shrinking is handled by the next full recompute.
    if (currentQuoteBps < snap.min24hBps) snap.min24hBps = currentQuoteBps;
    if (currentQuoteBps > snap.max24hBps) snap.max24hBps = currentQuoteBps;

    // 7d/30d: full recompute on day boundary, monotonic widen within a day.
    // IMPORTANT: 0 bps is a valid steady-state value. Do NOT treat (min==0 && max==0)
    // as an "uninitialized" sentinel, or we will recompute 30 days of DailyFurnaceAgg
    // on every indexed block when bonus stays 0.
    if (isDayChange) {
      refreshBonusSnapshot7d30d(snap, ts, currentQuoteBps);
      snap.lastDayId = currDayId;
    } else {
      if (currentQuoteBps < snap.min7dBps) snap.min7dBps = currentQuoteBps;
      if (currentQuoteBps > snap.max7dBps) snap.max7dBps = currentQuoteBps;
      if (currentQuoteBps < snap.min30dBps) snap.min30dBps = currentQuoteBps;
      if (currentQuoteBps > snap.max30dBps) snap.max30dBps = currentQuoteBps;
    }

    snap.save();
    return;
  }

  // Slow path: 24h full recompute from 5m samples.
  let minBucketStart = currentBucketStart.minus(BigInt.fromI32(WINDOW_24H));
  if (minBucketStart.lt(ZERO)) minBucketStart = ZERO;

  const values = new Array<i32>();
  let cursor = minBucketStart;
  const step = BigInt.fromI32(BUCKET_5M);
  while (cursor.le(currentBucketStart)) {
    const id = bonusSampleId(BUCKET_5M, cursor);
    const sample = FurnaceBonusSample.load(id);
    if (sample !== null && sample.bucketSeconds == BUCKET_5M) {
      values.push(sample.quoteUserBonusBps);
    }
    cursor = cursor.plus(step);
  }

  // Always include the live value so the 24h min/max reflects the current block.
  values.push(currentQuoteBps);

  // Numeric sort — use branch-based comparator to avoid i32 overflow on subtraction.
  values.sort((a: i32, b: i32): i32 => {
    if (a < b) return -1;
    if (a > b) return 1;
    return 0;
  });

  const n = values.length;
  const min = values[0];
  const max = values[n - 1];

  // q33 and q66 both map to index 0. Use computeQuantile() or f64 math.
  // ANALYSIS: The code uses `(((n - 1) as f64) * P / 100.0) as i32` which is
  // floor-based nearest-rank. For n=3: q33 -> floor(2*0.33)=0, q66 -> floor(2*0.66)=1.
  // This is actually correct for the nearest-rank method. The original comment's
  // claim that q33 and q66 both map to index 0 is INCORRECT for n=3.
  // However, the helper function computeQuantile() at line 166 uses Math.floor()
  // which has the same behavior, so there is no discrepancy.
  // VERIFIED: Quantile computation is correct for nearest-rank semantics.
  const q33Idx = ((((n - 1) as f64) * 33.0) / 100.0) as i32;
  const q66Idx = ((((n - 1) as f64) * 66.0) / 100.0) as i32;
  const q95Idx = ((((n - 1) as f64) * 95.0) / 100.0) as i32;

  snap.min24hBps = min;
  snap.max24hBps = max;
  snap.q33Bps = values[q33Idx];
  snap.q66Bps = values[q66Idx];
  snap.q95Bps = values[q95Idx];

  // Record the bucketStart that this recompute corresponds to.
  snap.last24hRecomputeBucketStart = currentBucketStart;

  // 7d/30d: recompute on day boundary, monotonic widen within a day.
  if (isDayChange) {
    refreshBonusSnapshot7d30d(snap, ts, currentQuoteBps);
    snap.lastDayId = currDayId;
  } else {
    if (currentQuoteBps < snap.min7dBps) snap.min7dBps = currentQuoteBps;
    if (currentQuoteBps > snap.max7dBps) snap.max7dBps = currentQuoteBps;
    if (currentQuoteBps < snap.min30dBps) snap.min30dBps = currentQuoteBps;
    if (currentQuoteBps > snap.max30dBps) snap.max30dBps = currentQuoteBps;
  }

  snap.save();
}

/**
 * Update today's DailyFurnaceAgg with the running min/max of the quote bonus.
 * Called every block from the block handler.
 */
function updateDailyBonusQuoteMinMax(ts: BigInt, quoteBps: i32, currentReserveEnd: BigInt): void {
  const dayId = dayIdFromTimestamp(ts);
  const day = loadOrCreateDay(dayId);

  let changed = false;
  // Initialize reserveEnd for this UTC day from onchain state (block handler).
  // Without this, days with no reserve-affecting events would keep reserveEnd=0.
  if (day.reserveEnd.equals(ZERO) && currentReserveEnd.gt(ZERO)) {
    day.reserveEnd = currentReserveEnd;
    changed = true;
  }

  if (quoteBps < day.quoteBonusMinBps) {
    day.quoteBonusMinBps = quoteBps;
    changed = true;
  }
  if (quoteBps > day.quoteBonusMaxBps) {
    day.quoteBonusMaxBps = quoteBps;
    changed = true;
  }
  if (changed) {
    day.save();
  }
}

/**
 * Recompute 7d and 30d min/max on the snapshot from DailyFurnaceAgg records.
 * Iterates backwards from today over N calendar days. Days without samples
 * (quoteBonusMinBps == BONUS_BPS_SENTINEL) are skipped.
 */
function refreshBonusSnapshot7d30d(
  snap: FurnaceBonusSnapshot,
  ts: BigInt,
  currentQuoteBps: i32,
): void {
  const todayDayId = ts.div(BigInt.fromI32(SECONDS_PER_DAY));
  const oneDay = BigInt.fromI32(1);

  let min7d: i32 = currentQuoteBps;
  let max7d: i32 = currentQuoteBps;
  let min30d: i32 = currentQuoteBps;
  let max30d: i32 = currentQuoteBps;

  // Walk backwards up to 30 days (includes today).
  let cursor = todayDayId;
  for (let i = 0; i < 30; i++) {
    const day = DailyFurnaceAgg.load(cursor.toString());

    if (day !== null && day.quoteBonusMinBps < BONUS_BPS_SENTINEL) {
      const dMin = day.quoteBonusMinBps;
      const dMax = day.quoteBonusMaxBps;

      if (dMin < min30d) min30d = dMin;
      if (dMax > max30d) max30d = dMax;

      if (i < 7) {
        if (dMin < min7d) min7d = dMin;
        if (dMax > max7d) max7d = dMax;
      }
    }

    cursor = cursor.minus(oneDay);
  }

  snap.min7dBps = min7d;
  snap.max7dBps = max7d;
  snap.min30dBps = min30d;
  snap.max30dBps = max30d;
}

function maybeCreateBonusSample(ts: BigInt, bucketSeconds: i32, quoteBps: i32): void {
  const bStart = bucketStart(ts, bucketSeconds);
  const id = bonusSampleId(bucketSeconds, bStart);

  if (FurnaceBonusSample.load(id) == null) {
    const s = new FurnaceBonusSample(id);
    s.bucketStart = bStart;
    s.bucketSeconds = bucketSeconds;
    s.quoteUserBonusBps = quoteBps;
    s.save();

    // Retention (best-effort): delete one bucket beyond the window.
    // If the subgraph goes offline for N buckets, N-1 stale samples persist forever.
    // Consider pruning a batch (e.g., 5 old samples) or adding a periodic sweep.
    //
    // UPDATE: The code now prunes up to 5 old 5m samples per creation (loop j=1..5).
    // This handles up to 25 minutes of downtime per sample creation. For longer
    // outages (>25 min), stale samples will accumulate but are harmless for
    // correctness — they just waste store space and will be outside the 24h window.
    //
    // For 1h samples, only 1 old sample is pruned per creation. Consider extending
    // this to prune 3-5 samples for better downtime resilience.
    if (bucketSeconds == BUCKET_5M) {
      for (let j = 1; j <= 5; j++) {
        const pruneStart = bStart.minus(BigInt.fromI32(WINDOW_24H + BUCKET_5M * j));
        if (pruneStart.ge(ZERO)) {
          store.remove('FurnaceBonusSample', bonusSampleId(BUCKET_5M, pruneStart));
        }
      }
    }

    if (bucketSeconds == BUCKET_1H) {
      const pruneStart = bStart.minus(BigInt.fromI32(WINDOW_7D + BUCKET_1H));
      if (pruneStart.ge(ZERO)) {
        store.remove('FurnaceBonusSample', bonusSampleId(BUCKET_1H, pruneStart));
      }
    }
  }
}

// -----------------
// LP rewards (24h rolling window)
// -----------------

function lpRewardsSampleId(bucketSeconds: i32, bucketStartTs: BigInt): string {
  return bucketSeconds.toString() + '-' + bucketStartTs.toString();
}

function loadOrCreateLpRewardsSample(ts: BigInt, bucketSeconds: i32): LpRewardsSample {
  const bStart = bucketStart(ts, bucketSeconds);
  const id = lpRewardsSampleId(bucketSeconds, bStart);

  let s = LpRewardsSample.load(id);
  if (s == null) {
    s = new LpRewardsSample(id);
    s.bucketStart = bStart;
    s.bucketSeconds = bucketSeconds;
    s.lpTopupClaim = ZERO;
    s.lpDripClaim = ZERO;
    s.lpSellRewardClaim = ZERO;
    s.lpRewardsClaim = ZERO;
    s.save();
  }
  return s as LpRewardsSample;
}

function addToLpRewardsSample1h(ts: BigInt, topup: BigInt, drip: BigInt, sellReward: BigInt): void {
  if (topup.equals(ZERO) && drip.equals(ZERO) && sellReward.equals(ZERO)) return;

  const s = loadOrCreateLpRewardsSample(ts, BUCKET_1H);

  if (topup.gt(ZERO)) s.lpTopupClaim = s.lpTopupClaim.plus(topup);
  if (drip.gt(ZERO)) s.lpDripClaim = s.lpDripClaim.plus(drip);
  if (sellReward.gt(ZERO)) s.lpSellRewardClaim = s.lpSellRewardClaim.plus(sellReward);

  s.lpRewardsClaim = s.lpRewardsClaim.plus(topup).plus(drip).plus(sellReward);
  s.save();
}

function refreshLpRewards24h(state: FurnaceState, ts: BigInt): void {
  const currentHourStart = bucketStart(ts, BUCKET_1H);
  const step = BigInt.fromI32(BUCKET_1H);
  let start = currentHourStart.minus(BigInt.fromI32(BUCKET_1H * 23));
  if (start.lt(ZERO)) start = ZERO;

  let total = ZERO;
  let topup = ZERO;
  let drip = ZERO;
  let sell = ZERO;

  let cursor = start;
  for (let i = 0; i < 24; i++) {
    const id = lpRewardsSampleId(BUCKET_1H, cursor);
    const s = LpRewardsSample.load(id);
    if (s !== null) {
      total = total.plus(s.lpRewardsClaim);
      topup = topup.plus(s.lpTopupClaim);
      drip = drip.plus(s.lpDripClaim);
      sell = sell.plus(s.lpSellRewardClaim);
    }
    cursor = cursor.plus(step);
  }

  state.lpRewardsClaim24h = total;
  state.lpRewardsTopupClaim24h = topup;
  state.lpRewardsDripClaim24h = drip;
  state.lpRewardsSellRewardClaim24h = sell;

  // Retention (best-effort): delete one bucket beyond the window.
  // UPDATE: Code now prunes up to 3 old 1h samples per refresh (loop j=1..3).
  // This handles up to 3 hours of downtime. For longer outages, stale LpRewardsSample
  // entities will accumulate. Since the 24h window only reads the last 24 samples,
  // stale samples outside the window are inert but waste store space.
  for (let j = 1; j <= 3; j++) {
    const pruneStart = currentHourStart.minus(BigInt.fromI32(WINDOW_24H + BUCKET_1H * j));
    if (pruneStart.ge(ZERO)) {
      store.remove('LpRewardsSample', lpRewardsSampleId(BUCKET_1H, pruneStart));
    }
  }
}

function loadOrCreateFurnaceState(): FurnaceState {
  let s = FurnaceState.load('current');
  if (s == null) {
    s = new FurnaceState('current');
    s.updatedAt = ZERO;
    s.reserve = ZERO;
    s.lpStreamRatePerSec = ZERO;
    s.lpStreamPeriodFinish = ZERO;
    s.lpRewardsClaim24h = ZERO;
    s.lpRewardsTopupClaim24h = ZERO;
    s.lpRewardsDripClaim24h = ZERO;
    s.lpRewardsSellRewardClaim24h = ZERO;
    s.save();
  } else {
    // Backfill new fields for safety when reusing an existing store.
    let didBackfill = false;
    if (s.get('lpStreamRatePerSec') == null) {
      s.lpStreamRatePerSec = ZERO;
      didBackfill = true;
    }
    if (s.get('lpStreamPeriodFinish') == null) {
      s.lpStreamPeriodFinish = ZERO;
      didBackfill = true;
    }
    if (s.get('lpRewardsClaim24h') == null) {
      s.lpRewardsClaim24h = ZERO;
      s.lpRewardsTopupClaim24h = ZERO;
      s.lpRewardsDripClaim24h = ZERO;
      s.lpRewardsSellRewardClaim24h = ZERO;
      didBackfill = true;
    }
    if (didBackfill) {
      s.save();
    }
  }
  return s as FurnaceState;
}

// -----------------
// Token-entry decode
// -----------------

// keccak256("enterWithToken(address,uint256,uint256,uint256,bool,uint256)") first 4 bytes.
const ENTER_WITH_TOKEN_SELECTOR = Bytes.fromHexString('0xbcbbebe1') as Bytes;
// keccak256("enterWithTokenFromCallerFor(address,address,uint256,uint256,uint256,bool,uint256)") first 4 bytes.
const ENTER_WITH_TOKEN_FROM_CALLER_FOR_SELECTOR = Bytes.fromHexString('0xa2602c01') as Bytes;

// MarketRouter.BonusTargetEscrowAutoFurnaceExecuted(uint256,address,uint256,uint256,uint256,uint256,uint256,uint256)
// Used to gate TxFurnaceEnter joins to only the txs that need them.
const AUTO_FURNACE_EXECUTED_SIG = Bytes.fromHexString(
  '0xde21b52f3f82be51e2ecdbc708355550523426c775cb6d6cdfce323ff323d9a4',
) as Bytes;

class TokenEntryDecoded {
  payer: Address;
  tokenIn: Address;
  amountIn: BigInt;

  constructor(payer: Address, tokenIn: Address, amountIn: BigInt) {
    this.payer = payer;
    this.tokenIn = tokenIn;
    this.amountIn = amountIn;
  }
}

/**
 * Receipt-based fallback for mode=3 FurnaceEnter events reached through an
 * internal call (Safe, smart account, helper, batch). Top-level calldata is the
 * outer call, so `decodeTokenEntry` returns null. The canonical entry pattern
 * inside `Furnace.enterWithToken` is `safeTransferFrom(payer, furnace, tokenIn,
 * amountIn)` BEFORE the internal swap-and-credit hops, so the LATEST ERC20
 * `Transfer(_, furnace, _)` log strictly preceding the FurnaceEnter event in
 * this receipt carries the entry token for THIS FurnaceEnter (latest, not
 * earliest, so a batched transaction with multiple FurnaceEnter calls
 * attributes each event to its own preceding entry transfer). CLAIM transfers
 * are skipped — they appear as the swap output, never as the entry token.
 */
function deriveTokenEntryFromReceipt(
  receipt: ethereum.TransactionReceipt | null,
  furnace: Address,
  furnaceEnterLogIndex: BigInt,
  claimToken: Bytes,
): TokenEntryDecoded | null {
  if (receipt == null) return null;

  const transferSig = Bytes.fromHexString(
    '0xddf252ad1be2c89b69c2b068fc378daa952ba7f163c4a11628f55a4df523b3ef',
  ) as Bytes;
  const logs = (receipt as ethereum.TransactionReceipt).logs;
  const claimHex = claimToken.toHexString();
  const furnaceHex = furnace.toHexString();
  const transferSigHex = transferSig.toHexString();

  // Walk the log array in reverse and return the first qualifying Transfer
  // strictly before `furnaceEnterLogIndex`. Reverse iteration is the simplest
  // way to pick the LATEST preceding entry transfer when a batched tx contains
  // multiple FurnaceEnter / Transfer pairs.
  for (let i = logs.length - 1; i >= 0; i--) {
    const log = logs[i];
    if (log.logIndex.ge(furnaceEnterLogIndex)) continue;
    if (log.topics.length < 3) continue;
    if (log.topics[0].toHexString() != transferSigHex) continue;
    if (log.address.toHexString() == claimHex) continue;

    const topicTo = Address.fromBytes(Bytes.fromUint8Array(log.topics[2].subarray(12)));
    if (topicTo.toHexString() != furnaceHex) continue;

    // Tolerate a malformed sibling Transfer log instead of bailing the whole
    // search: a batched tx that emits one bad-data Transfer plus several
    // well-formed ones must still resolve the token attribution from the
    // earlier valid log under reverse iteration.
    if (log.data.length < 32) continue;
    const valueDecoded = ethereum.decode('uint256', log.data);
    if (valueDecoded == null) continue;

    const topicFrom = Address.fromBytes(Bytes.fromUint8Array(log.topics[1].subarray(12)));
    return new TokenEntryDecoded(
      topicFrom,
      Address.fromBytes(log.address),
      (valueDecoded as ethereum.Value).toBigInt(),
    );
  }

  return null;
}

/**
 * Decode token-entry calldata for mode=3 FurnaceEnter events.
 *
 * Supported top-level transaction calls:
 * - enterWithToken(tokenIn, amountIn, targetTokenId, durationSeconds, createAutoMax, minVeOut)
 * - enterWithTokenFromCallerFor(user, tokenIn, amountIn, targetTokenId, durationSeconds, createAutoMax, minVeOut)
 *
 * Note: If FurnaceEnter(mode=3) is emitted from an internal call (tx.to != Furnace),
 * the subgraph cannot see the internal calldata selector and returns null. Callers
 * SHOULD fall back to `deriveTokenEntryFromReceipt` for that case.
 */
function decodeTokenEntry(
  input: Bytes,
  eventUser: Address,
  txFrom: Address,
): TokenEntryDecoded | null {
  if (input.length < 4) return null;

  const selector = Bytes.fromUint8Array(input.subarray(0, 4));
  const data = Bytes.fromUint8Array(input.subarray(4));
  const selHex = selector.toHexString();

  // enterWithToken(address tokenIn, uint256 amountIn, uint256 targetTokenId, uint256 durationSeconds, bool createAutoMax, uint256 minVeOut)
  if (selHex == ENTER_WITH_TOKEN_SELECTOR.toHexString()) {
    const decoded = ethereum.decode('(address,uint256,uint256,uint256,bool,uint256)', data);
    if (decoded == null) return null;

    const tup = (decoded as ethereum.Value).toTuple();
    const tokenIn = tup[0].toAddress();
    const amountIn = tup[1].toBigInt();

    // payer == user == msg.sender
    return new TokenEntryDecoded(eventUser, tokenIn, amountIn);
  }

  // enterWithTokenFromCallerFor(address user, address tokenIn, uint256 amountIn, uint256 targetTokenId, uint256 durationSeconds, bool createAutoMax, uint256 minVeOut)
  if (selHex == ENTER_WITH_TOKEN_FROM_CALLER_FOR_SELECTOR.toHexString()) {
    const decoded = ethereum.decode('(address,address,uint256,uint256,uint256,bool,uint256)', data);
    if (decoded == null) return null;

    const tup = (decoded as ethereum.Value).toTuple();
    const userFromCalldata = tup[0].toAddress();

    // Sanity check: ensure the calldata user matches the emitted event user.
    if (userFromCalldata.toHexString() != eventUser.toHexString()) {
      return null;
    }

    const tokenIn = tup[1].toAddress();
    const amountIn = tup[2].toBigInt();

    // payer == tx.from (msg.sender for top-level calls to Furnace)
    return new TokenEntryDecoded(txFrom, tokenIn, amountIn);
  }

  return null;
}

// True if the tx receipt contains a log with topic0 == sig.
// When `emitter` is known, also require the log to come from that contract.
function receiptHasTopic(
  receipt: ethereum.TransactionReceipt | null,
  sig: Bytes,
  emitter: Address,
): bool {
  if (receipt == null) return false;

  const requireEmitter = emitter.toHexString() != ZERO_ADDRESS.toHexString();
  const logs = (receipt as ethereum.TransactionReceipt).logs;
  for (let i = 0; i < logs.length; i++) {
    const log = logs[i];
    if (requireEmitter && log.address.toHexString() != emitter.toHexString()) continue;
    if (log.topics.length == 0) continue;
    if (log.topics[0].toHexString() == sig.toHexString()) return true;
  }
  return false;
}

// Sum ERC20 Transfer(token, from=payer, to=furnace) values as canonical observed amount.
function sumObservedTokenIn(
  receipt: ethereum.TransactionReceipt | null,
  token: Address,
  from: Address,
  to: Address,
): BigInt {
  if (receipt == null) return ZERO;

  // Transfer(address,address,uint256)
  const transferSig = Bytes.fromHexString(
    '0xddf252ad1be2c89b69c2b068fc378daa952ba7f163c4a11628f55a4df523b3ef',
  ) as Bytes;

  let total = ZERO;
  const logs = (receipt as ethereum.TransactionReceipt).logs;
  for (let i = 0; i < logs.length; i++) {
    const log = logs[i];

    if (log.address.toHexString() != token.toHexString()) continue;
    if (log.topics.length < 3) continue;
    if (log.topics[0].toHexString() != transferSig.toHexString()) continue;

    const topicFrom = Address.fromBytes(Bytes.fromUint8Array(log.topics[1].subarray(12)));
    const topicTo = Address.fromBytes(Bytes.fromUint8Array(log.topics[2].subarray(12)));

    if (topicFrom.toHexString() != from.toHexString()) continue;
    if (topicTo.toHexString() != to.toHexString()) continue;

    const decoded = ethereum.decode('uint256', log.data);
    if (decoded == null) continue;

    total = total.plus((decoded as ethereum.Value).toBigInt());
  }

  return total;
}

// -----------------
// Event handlers
// -----------------

// Skip block handler for early blocks. Anvil can return BlockOutOfRangeError when
// eth_call targets block 0/1 after the chain has grown (e.g. 100k blocks). The
// Furnace is deployed in the first few blocks of local deploys.
const FURNACE_BLOCK_HANDLER_MIN_BLOCK = 10;

// Anvil prunes historical block state, so eth_call at old blocks fails with
// BlockOutOfRangeError. Graph Node's try_ catches EVM reverts but NOT RPC
// errors, causing infinite retries. Guard all event-handler eth_calls on local.
function isLocalNetwork(): bool {
  return dataSource.network() == 'local';
}

// Ensure Protocol.furnace and the entryTokenRegistry alias are populated even when
// block handlers are disabled (e.g. local dev).
function touchFurnaceProtocol(addr: Address, blockNumber: BigInt): void {
  const protocol = loadOrCreateProtocol(blockNumber);

  let changed = false;

  // Furnace address is immutable per deployment; only fill when unknown (0x0).
  if (protocol.furnace.toHexString() == ZERO_ADDRESS.toHexString()) {
    protocol.furnace = addr;
    changed = true;
  }

  // Keep back-compat alias in sync whenever we know the furnace registry.
  if (protocol.furnaceEntryTokenRegistry !== null) {
    const fe = protocol.furnaceEntryTokenRegistry as Bytes;
    const current = protocol.entryTokenRegistry;
    if (current === null || current.toHexString() != fe.toHexString()) {
      protocol.entryTokenRegistry = fe;
      changed = true;
    }
  }

  if (changed) {
    protocol.save();
  }
}

function tryReadQuoterState(
  furnaceAddr: Address,
): ethereum.CallResult<FurnaceQuoter__getFurnaceStateResult> {
  const furnace = FurnaceContract.bind(furnaceAddr);
  const quoterResult = furnace.try_furnaceQuoter();
  if (quoterResult.reverted) {
    return new ethereum.CallResult<FurnaceQuoter__getFurnaceStateResult>();
  }
  const quoter = FurnaceQuoter.bind(quoterResult.value);
  return quoter.try_getFurnaceState();
}

export function handleFurnaceBlock(block: ethereum.Block): void {
  if (block.number.lt(BigInt.fromI32(FURNACE_BLOCK_HANDLER_MIN_BLOCK))) {
    return;
  }
  // BlockOutOfRangeError (RPC error, NOT EVM revert), causing infinite graph-node retries.
  // Guard all eth_call block-handler paths on local networks.
  // VERIFIED: The `if (isLocalNetwork()) return;` guard above correctly prevents
  // this. Additionally, FURNACE_BLOCK_HANDLER_MIN_BLOCK=10 avoids early-block
  // failures.
  // NOTE: The prod manifest (subgraph.prod.yaml) does NOT include blockHandlers
  // for the Furnace. Verify this is intentional — block handler is local/staging only.
  if (isLocalNetwork()) return;

  // Keep protocol core address filled (avoid writing Protocol every block).
  touchFurnaceProtocol(dataSource.address(), block.number);

  // Quote the current bonus bps from onchain state via the FurnaceQuoter.
  const stateResult = tryReadQuoterState(dataSource.address());
  if (stateResult.reverted) {
    return;
  }

  const reserve = stateResult.value.value0;
  const quoteUserBonusBps = stateResult.value.value4.toI32();

  // Create bucketed samples.
  maybeCreateBonusSample(block.timestamp, BUCKET_5M, quoteUserBonusBps);

  // 1h boundary hook: when the hourly bonus bucket is first observed, refresh the rolling LP window.
  const hourStart = bucketStart(block.timestamp, BUCKET_1H);
  const hourId = bonusSampleId(BUCKET_1H, hourStart);
  const hadHour = FurnaceBonusSample.load(hourId) != null;

  maybeCreateBonusSample(block.timestamp, BUCKET_1H, quoteUserBonusBps);

  if (!hadHour) {
    const state = loadOrCreateFurnaceState();
    refreshLpRewards24h(state, block.timestamp);
    state.save();
  }

  // Track per-day quote bonus min/max for 7d/30d aggregation.
  updateDailyBonusQuoteMinMax(block.timestamp, quoteUserBonusBps, reserve);

  // Update snapshot: 24h tiers from 5m samples + 7d/30d from daily aggs.
  updateSnapshotFromLast24h(block.timestamp, quoteUserBonusBps);
}

export function handleEntryTokenRegistrySet(event: EntryTokenRegistrySet): void {
  const protocol = loadOrCreateProtocol(event.block.number);
  protocol.furnace = setBytesIfZero(protocol.furnace, event.address);

  const prev = protocol.furnaceEntryTokenRegistry;
  protocol.furnaceEntryTokenRegistry = event.params.registry;
  // Back-compat alias: MUST equal furnaceEntryTokenRegistry.
  protocol.entryTokenRegistry = event.params.registry;
  protocol.save();

  // Start indexing the registry contract from this block forward.
  let shouldCreate = false;
  if (prev === null) {
    shouldCreate = true;
  } else {
    const prevHex = (prev as Bytes).toHexString();
    const nextHex = event.params.registry.toHexString();
    if (prevHex != nextHex) {
      shouldCreate = true;
    }
  }
  if (shouldCreate) {
    const registryId = event.params.registry.toHexString();

    // Prevent duplicate dynamic data sources when both MineCore and Furnace
    // wire the same EntryTokenRegistry address.
    let r = EntryTokenRegistryEntity.load(registryId);
    if (r == null) {
      r = new EntryTokenRegistryEntity(registryId);
      r.address = event.params.registry;
      r.updatedAt = event.block.timestamp;
      r.save();

      EntryTokenRegistryTemplate.create(event.params.registry);
    }

    // Snapshot current config via onchain reads (skipped on local networks).
    snapshotEntryTokenRegistry(event.params.registry, event.block.timestamp, event.block.number);
  }
}

export function handleLockingPausedChanged(event: LockingPausedChanged): void {
  const protocol = loadOrCreateProtocol(event.block.number);
  protocol.furnace = setBytesIfZero(protocol.furnace, event.address);
  protocol.lockingPaused = event.params.paused;
  protocol.save();
}

export function handleMineCoreChanged(event: MineCoreChanged): void {
  const protocol = loadOrCreateProtocol(event.block.number);
  protocol.furnace = setBytesIfZero(protocol.furnace, event.address);
  // Track the latest observed Furnace -> MineCore wiring.
  protocol.mineCore = event.params.newMineCore;
  protocol.save();
}

export function handleMineMarketChanged(event: MineMarketChanged): void {
  const protocol = loadOrCreateProtocol(event.block.number);
  protocol.furnace = setBytesIfZero(protocol.furnace, event.address);
  // MineMarket is the MarketRouter in v1.0.0 deployments.
  protocol.marketRouter = event.params.newMineMarket;
  protocol.save();
}

export function handleShareholderRoyaltiesChanged(event: ShareholderRoyaltiesChanged): void {
  const protocol = loadOrCreateProtocol(event.block.number);
  protocol.furnace = setBytesIfZero(protocol.furnace, event.address);
  // Track the latest observed Furnace -> ShareholderRoyalties wiring.
  protocol.shareholderRoyalties = event.params.newSR;
  protocol.save();
}

export function handleBonusPaid(event: BonusPaid): void {
  touchFurnaceProtocol(event.address, event.block.number);

  const id = eventId(event);

  const e = new BonusPaidEvent(id);
  e.timestamp = event.block.timestamp;
  e.blockNumber = event.block.number;
  e.txHash = event.transaction.hash;

  const bonusUser = loadOrCreateUser(event.params.user);
  e.user = bonusUser.id;
  e.principal = event.params.principal;
  e.principalEff = event.params.principalEff;
  e.grossBonusClaim = event.params.grossBonusClaim;
  e.userBonusClaim = event.params.userBonusClaim;
  e.lpTopupClaim = event.params.lpTopupClaim;
  e.userSpotBonusBps = event.params.userSpotBonusBps.toI32();
  e.lpTopupRateBps = event.params.lpTopupRateBps.toI32();
  e.grossSpotBonusBps = event.params.grossSpotBonusBps.toI32();
  e.quoteUserBonusBps = event.params.quoteUserBonusBps.toI32();
  e.quoteLpTopupBps = event.params.quoteLpTopupBps.toI32();
  e.lockDurationSec = event.params.lockDurationSec.toI32();
  e.reserveBefore = event.params.reserveBefore;
  e.reserveAfter = event.params.reserveAfter;
  e.virtualDepthBefore = event.params.virtualDepthBefore;
  e.virtualDepthAfter = event.params.virtualDepthAfter;

  e.save();

  // Bonus timing: sample + snapshot update (mirrors the block handler so that
  // timing data is available even when blockHandlers are disabled for local dev).
  const quoteBps = event.params.quoteUserBonusBps.toI32();
  maybeCreateBonusSample(event.block.timestamp, BUCKET_5M, quoteBps);
  maybeCreateBonusSample(event.block.timestamp, BUCKET_1H, quoteBps);
  updateDailyBonusQuoteMinMax(event.block.timestamp, quoteBps, event.params.reserveAfter);
  updateSnapshotFromLast24h(event.block.timestamp, quoteBps);

  // Daily rollup
  const dayId = dayIdFromTimestamp(event.block.timestamp);
  const daily = loadOrCreateDay(dayId);
  daily.bonusPaidCount = daily.bonusPaidCount + 1;
  daily.totalGrossBonus = daily.totalGrossBonus.plus(event.params.grossBonusClaim);
  daily.totalLpTopup = daily.totalLpTopup.plus(event.params.lpTopupClaim);
  daily.totalLpFromFurnace = daily.totalLpFromFurnace.plus(event.params.lpTopupClaim);
  daily.reserveEnd = event.params.reserveAfter;
  daily.save();

  // `BonusPaid` records the raw AMM split before sub-MIN_TOPUP user dust can
  // be refunded to reserve. Public daily user-bonus totals are settled from
  // the subsequent receipt event so dashboards use the delivered bonus.
  recordPendingBonusPaid(event);

  // Hourly LP rewards sample + rolling 24h totals.
  addToLpRewardsSample1h(event.block.timestamp, event.params.lpTopupClaim, ZERO, ZERO);

  // Latest state
  const state = loadOrCreateFurnaceState();
  state.updatedAt = event.block.timestamp;
  state.reserve = event.params.reserveAfter;
  state.userSpotBonusBps = event.params.userSpotBonusBps.toI32();
  state.grossSpotBonusBps = event.params.grossSpotBonusBps.toI32();
  state.lpTopupRateBps = event.params.lpTopupRateBps.toI32();
  refreshLpRewards24h(state, event.block.timestamp);
  state.save();
}

export function handleLpOverflowDripPaid(event: LpOverflowDripPaid): void {
  touchFurnaceProtocol(event.address, event.block.number);

  const id = eventId(event);

  const e = new LpOverflowDripPaidEvent(id);
  e.timestamp = event.block.timestamp;
  e.blockNumber = event.block.number;
  e.txHash = event.transaction.hash;

  e.dripAmount = event.params.dripAmount;
  e.reserveBefore = event.params.reserveBefore;
  e.reserveAfter = event.params.reserveAfter;
  e.alphaBps = event.params.alphaBps.toI32();
  e.gateBps = event.params.gateBps.toI32();
  e.capInflowPerDay = event.params.capInflowPerDay;
  e.capFixedPerDay = event.params.capFixedPerDay;
  e.reserveTarget = event.params.reserveTarget;
  e.excessBefore = event.params.excessBefore;

  e.save();

  // Daily rollup
  const dayId = dayIdFromTimestamp(event.block.timestamp);
  const daily = loadOrCreateDay(dayId);
  daily.dripCount = daily.dripCount + 1;
  daily.totalLpDrip = daily.totalLpDrip.plus(event.params.dripAmount);
  daily.totalLpFromFurnace = daily.totalLpFromFurnace.plus(event.params.dripAmount);
  daily.reserveEnd = event.params.reserveAfter;
  daily.save();

  // Hourly LP rewards sample + rolling 24h totals.
  addToLpRewardsSample1h(event.block.timestamp, ZERO, event.params.dripAmount, ZERO);

  // Latest state
  const state = loadOrCreateFurnaceState();
  state.updatedAt = event.block.timestamp;
  state.reserve = event.params.reserveAfter;
  state.capInflowPerDay = event.params.capInflowPerDay;
  refreshLpRewards24h(state, event.block.timestamp);
  state.save();

  // Bonus timing: read current bonus from the quoter post-drip and sample.
  // Skipped on local — Anvil prunes old block state, causing BlockOutOfRangeError.
  if (!isLocalNetwork()) {
    const stateResult = tryReadQuoterState(event.address);
    if (!stateResult.reverted) {
      const quoteBps = stateResult.value.value4.toI32();
      const userBps = stateResult.value.value2.toI32();
      const lpBps = stateResult.value.value3.toI32();
      state.grossSpotBonusBps = computeGrossSpotBonusBps(userBps, lpBps);
      state.userSpotBonusBps = userBps;
      state.lpTopupRateBps = lpBps;
      state.save();
      maybeCreateBonusSample(event.block.timestamp, BUCKET_5M, quoteBps);
      maybeCreateBonusSample(event.block.timestamp, BUCKET_1H, quoteBps);
      updateDailyBonusQuoteMinMax(event.block.timestamp, quoteBps, event.params.reserveAfter);
      updateSnapshotFromLast24h(event.block.timestamp, quoteBps);
    }
  }
}

export function handleLockSoldToFurnace(event: LockSoldToFurnace): void {
  touchFurnaceProtocol(event.address, event.block.number);

  const id = eventId(event);

  const seller = loadOrCreateUser(event.params.seller);
  const now = event.block.timestamp;

  const e = new LockSoldToFurnaceEvent(id);
  e.timestamp = event.block.timestamp;
  e.blockNumber = event.block.number;
  e.txHash = event.transaction.hash;

  e.seller = seller.id;
  e.tokenId = event.params.tokenId;
  e.lockAmountWei = event.params.lockAmount;
  e.claimOutWei = event.params.claimOut;
  e.spreadBps = event.params.spreadBps.toI32();
  e.cutWei = event.params.cut;
  e.lpSaleShareBps = event.params.lpSaleShareBps.toI32();
  e.lpRewardWei = event.params.lpReward;
  e.reserveAddWei = event.params.reserveAdd;
  e.bonusRefBpsUsed = event.params.bonusRefBpsUsed.toI32();

  e.save();

  // ---------------------------------------------------------------------------
  // Back-compat: MarketTradeEvent (UI + achievements)
  // ---------------------------------------------------------------------------
  // Downstream consumers query MarketTradeEvent as the
  // canonical "trade" surface for a lock.
  //
  // Strict mode: the only marketplace fill is a sellback into the Furnace.
  // We therefore derive MarketTradeEvent from the canonical sellback signal.
  const buyer = loadOrCreateUser(event.address);

  const trade = new MarketTradeEvent(id);
  trade.kind = 'BUY';
  trade.tokenId = event.params.tokenId;
  trade.seller = seller.id;
  trade.buyer = buyer.id;
  trade.offer = null;
  trade.priceInClaimWei = event.params.claimOut;
  trade.feeToFurnaceWei = event.params.cut;
  trade.lockAmountWei = event.params.lockAmount;
  if (event.params.lockAmount.equals(ZERO)) {
    trade.set('discountBps', Value.fromNull());
  } else if (event.params.claimOut.ge(event.params.lockAmount)) {
    // Premium (claimOut >= lockAmount): clamp to 0 for consistency with computeDiscountBps.
    trade.discountBps = 0;
  } else {
    // discountBps = floor((lockAmount - claimOut) * 10_000 / lockAmount)
    let rawBps = event.params.lockAmount
      .minus(event.params.claimOut)
      .times(BigInt.fromI32(10000))
      .div(event.params.lockAmount)
      .toI32();
    if (rawBps > 10000) rawBps = 10000;
    trade.discountBps = rawBps;
  }
  trade.timestamp = now;
  trade.txHash = event.transaction.hash;
  trade.save();

  // ---------------------------------------------------------------------------
  // Subgraph consistency fix (sellback burn)
  // ---------------------------------------------------------------------------
  // The sellback primitive burns the veCLAIM NFT via VeClaimNFT.furnaceBurnAndWithdraw.
  // That path emits a Transfer(to=0) but DOES NOT emit a LockUnlocked event.
  //
  // The VeClaimNFT Transfer handler covers the Furnace burn path, but we keep this
  // idempotent guard here as well to avoid "ghost locks" and transient custody
  // inflation if trigger ordering or historical indexing gaps cause the burn
  // transfer to be missed.
  //
  // LockSoldToFurnace is the canonical signal that the lock was burned.
  const lockId = event.params.tokenId.toString();
  const l = VeLock.load(lockId);
  if (l !== null) {
    // Guard: if the Transfer(to=0) handler already zeroed this lock (possible
    // when Transfer fires before LockSoldToFurnace in the same tx), skip
    // aggregate adjustments to avoid double-subtracting.
    const zeroUserId = loadOrCreateUser(ZERO_ADDRESS).id;
    if (!(l.amountWei.equals(ZERO) && l.owner == zeroUserId)) {
      // Reverse the transient custody transfer effects on the Furnace user.
      const furnaceUser = loadOrCreateUser(event.address);

      let lockVe = ZERO;
      if (l.currentVeWei === null) {
        lockVe = currentVeWei(l.amountWei, l.lockEnd, now, l.autoMax);
      } else {
        lockVe = l.currentVeWei as BigInt;
      }

      const furnaceLocked =
        furnaceUser.totalLockedClaimWei !== null
          ? (furnaceUser.totalLockedClaimWei as BigInt)
          : ZERO;
      if (furnaceLocked.ge(l.amountWei)) {
        furnaceUser.totalLockedClaimWei = furnaceLocked.minus(l.amountWei);
      } else {
        furnaceUser.totalLockedClaimWei = ZERO;
      }

      const furnaceVe =
        furnaceUser.veBalanceWei !== null ? (furnaceUser.veBalanceWei as BigInt) : ZERO;
      if (furnaceVe.ge(lockVe)) {
        furnaceUser.veBalanceWei = furnaceVe.minus(lockVe);
      } else {
        furnaceUser.veBalanceWei = ZERO;
      }
      furnaceUser.save();

      // Mark the lock as burned/empty and owned by 0x0.
      l.owner = zeroUserId;
      l.amountWei = ZERO;
      l.listed = false;
      l.updatedAt = now;
      l.currentVeWei = ZERO;
      l.save();
    }
  }

  // Daily rollup
  const dayId = dayIdFromTimestamp(now);
  const daily = loadOrCreateDay(dayId);
  daily.sellCount = daily.sellCount + 1;
  daily.totalSellLockAmount = daily.totalSellLockAmount.plus(event.params.lockAmount);
  daily.totalSellClaimOut = daily.totalSellClaimOut.plus(event.params.claimOut);
  daily.totalSellLpReward = daily.totalSellLpReward.plus(event.params.lpReward);
  daily.totalSellReserveAdd = daily.totalSellReserveAdd.plus(event.params.reserveAdd);
  daily.totalLpFromFurnace = daily.totalLpFromFurnace.plus(event.params.lpReward);

  // Hourly LP rewards sample + rolling 24h totals.
  addToLpRewardsSample1h(now, ZERO, ZERO, event.params.lpReward);

  // Latest state (reserve increases by reserveAdd on sellback).
  // NOTE: LockSoldToFurnace only emits reserveAdd (delta), not reserveAfter.
  // If indexing starts mid-history, the prior cached reserve may be unknown.
  // We therefore prefer an onchain read (when available) to set the canonical
  // reserve after the sellback.
  const state = loadOrCreateFurnaceState();
  state.updatedAt = now;
  let reserveEnd = state.reserve.plus(event.params.reserveAdd);
  state.reserve = reserveEnd;

  // Bonus timing: read current bonus + reserve from the quoter post-sellback and sample.
  // Skipped on local — Anvil prunes old block state, causing BlockOutOfRangeError.
  let quoteBps = 0;
  let haveQuote = false;
  if (!isLocalNetwork()) {
    const stateResult = tryReadQuoterState(event.address);
    if (!stateResult.reverted) {
      reserveEnd = stateResult.value.value0;
      state.reserve = reserveEnd;

      const userBps = stateResult.value.value2.toI32();
      const lpBps = stateResult.value.value3.toI32();
      state.grossSpotBonusBps = computeGrossSpotBonusBps(userBps, lpBps);
      state.userSpotBonusBps = userBps;
      state.lpTopupRateBps = lpBps;

      quoteBps = stateResult.value.value4.toI32();
      haveQuote = true;
    }
  }

  refreshLpRewards24h(state, now);
  state.save();

  daily.reserveEnd = reserveEnd;
  daily.save();

  if (haveQuote) {
    maybeCreateBonusSample(now, BUCKET_5M, quoteBps);
    maybeCreateBonusSample(now, BUCKET_1H, quoteBps);
    updateDailyBonusQuoteMinMax(now, quoteBps, reserveEnd);
    updateSnapshotFromLast24h(now, quoteBps);
  }

  // Activity feed normalization.
  const a = new ActivityItem(id);
  a.kind = 'FURNACE_SELLBACK';
  a.timestamp = now;
  a.txHash = event.transaction.hash;
  a.user = seller.id;
  a.otherUser = null;
  a.reignId = null;
  a.tokenId = event.params.tokenId;
  a.amountEthWei = null;
  a.amountClaimWei = event.params.claimOut;
  saveActivityItem(a);
}

export function handleFurnaceEnter(event: FurnaceEnter): void {
  const id = eventId(event);
  const protocol = loadOrCreateProtocol(event.block.number);
  protocol.furnace = setBytesIfZero(protocol.furnace, event.address);
  // Keep back-compat alias up to date when we learn the furnace registry address.
  if (protocol.furnaceEntryTokenRegistry !== null) {
    protocol.entryTokenRegistry = protocol.furnaceEntryTokenRegistry as Bytes;
  }
  protocol.save();

  const user = loadOrCreateUser(event.params.user);

  const e = new FurnaceEnterEvent(id);
  e.sortKey = blockSortKey(event.block.number, id);
  e.timestamp = event.block.timestamp;
  e.blockNumber = event.block.number;
  e.txHash = event.transaction.hash;

  e.user = user.id;
  e.mode = event.params.mode;
  e.ethInWei = event.params.ethIn;
  e.principalClaimWei = event.params.principalClaim;
  e.bonusClaimWei = event.params.bonusClaim;
  e.tokenId = event.params.tokenId;

  // mode=3 (ENTER_WITH_TOKEN): populate by decoding calldata (direct + delegated) + joining ERC20 Transfer logs.
  if (event.params.mode == MODE_ENTER_WITH_TOKEN) {
    const decoded = decodeTokenEntry(
      event.transaction.input,
      event.params.user,
      event.transaction.from,
    );
    if (decoded !== null) {
      const tokenIn = decoded.tokenIn;
      const amountInCalldata = decoded.amountIn;
      const payer = decoded.payer;

      const observed = sumObservedTokenIn(event.receipt, tokenIn, payer, event.address);
      // Prefer the observed transfer amount (fee-on-transfer tokens), but clamp to calldata
      // in case the tx includes unrelated extra transfers that would poison analytics.
      let canonical = amountInCalldata;
      if (observed.gt(ZERO)) {
        canonical = observed;
        if (amountInCalldata.gt(ZERO) && observed.gt(amountInCalldata)) {
          canonical = amountInCalldata;
        }
      }

      e.tokenIn = tokenIn;
      e.amountInWei = canonical;
    } else {
      // Internal-route fallback: tx.to is the outer caller (Safe / smart
      // account / helper / batch) so `event.transaction.input` is not the
      // `enterWithToken` calldata. Recover the entry token from the receipt's
      // latest Transfer-into-Furnace log strictly preceding this FurnaceEnter
      // (a batched tx with multiple FurnaceEnter calls attributes each event
      // to its own immediately-preceding entry transfer).
      const fromReceipt = deriveTokenEntryFromReceipt(
        event.receipt,
        event.address,
        event.logIndex,
        protocol.claimToken,
      );
      if (fromReceipt !== null) {
        e.tokenIn = fromReceipt.tokenIn;
        e.amountInWei = fromReceipt.amountIn;
      }
    }
  }

  e.save();

  // Internal join helper: store latest FurnaceEnter per (txHash,user) to enrich MarketRouter auto-furnace receipts.
  // Performance: only create join rows for transactions that actually include the MarketRouter auto-furnace receipt.
  // Harden against false positives by requiring the canonical MarketRouter emitter once that
  // address has been discovered; if not, fall back to topic-only matching for early blocks.
  let autoFurnaceEmitter = ZERO_ADDRESS;
  if (protocol.marketRouter.toHexString() != ZERO_ADDRESS.toHexString()) {
    autoFurnaceEmitter = Address.fromBytes(protocol.marketRouter);
  }
  if (receiptHasTopic(event.receipt, AUTO_FURNACE_EXECUTED_SIG, autoFurnaceEmitter)) {
    // Key by log identity (txHash + logIndex) so a batched helper / maintenance
    // transaction with multiple FurnaceEnter logs cannot have a later sibling
    // overwrite the earlier row's token id. The execution-side resolver looks
    // up by the matching `BonusTargetEscrowAutoFurnaceExecuted` log neighborhood
    // rather than by `(txHash, user)` alone.
    const txJoinId = txFurnaceEnterIdByLog(event.transaction.hash, event.logIndex);
    let jOpt = TxFurnaceEnter.load(txJoinId);
    if (jOpt == null) {
      const fresh = new TxFurnaceEnter(txJoinId);
      fresh.txHash = event.transaction.hash;
      fresh.user = user.id;
      fresh.setBigInt('logIndex', event.logIndex);
      fresh.tokenId = event.params.tokenId;
      fresh.principalClaimWei = event.params.principalClaim;
      fresh.bonusClaimWei = event.params.bonusClaim;
      fresh.timestamp = event.block.timestamp;
      fresh.blockNumber = event.block.number;
      fresh.save();
    } else {
      const existing = jOpt as TxFurnaceEnter;
      existing.setBigInt('logIndex', event.logIndex);
      existing.tokenId = event.params.tokenId;
      existing.principalClaimWei = event.params.principalClaim;
      existing.bonusClaimWei = event.params.bonusClaim;
      existing.timestamp = event.block.timestamp;
      existing.blockNumber = event.block.number;
      existing.save();
    }
  }

  // Update user aggregates used by leaderboards.
  user.furnaceEthInWei = user.furnaceEthInWei.plus(event.params.ethIn);
  user.furnacePrincipalClaimInWei = user.furnacePrincipalClaimInWei.plus(
    event.params.principalClaim,
  );
  user.save();

  settleDeliveredUserBonus(
    event.block.timestamp,
    event.transaction.hash,
    event.params.user,
    event.params.bonusClaim,
  );

  // Activity feed normalization. The "Eternal Lock" classification is
  // resolved CLIENT-SIDE by hydrating ShareholderAutoCompoundConfig +
  // VeLock.autoMax for each FURNACE_ENTER row, matching the canonical
  // predicate in `frontend/src/lib/useEternalLockPrefs.ts`. The subgraph
  // emits a plain FURNACE_ENTER row for every enter — the eternal label
  // is current-state, not historical.
  const a = new ActivityItem(id);
  a.kind = 'FURNACE_ENTER';
  a.timestamp = event.block.timestamp;
  a.txHash = event.transaction.hash;
  a.user = user.id;
  a.otherUser = null;
  a.reignId = null;
  a.tokenId = event.params.tokenId;
  a.amountEthWei = event.params.ethIn;
  a.amountClaimWei = event.params.principalClaim;
  saveActivityItem(a);
}

export function handleFurnaceMergeWithBonus(event: FurnaceMergeWithBonus): void {
  touchFurnaceProtocol(event.address, event.block.number);

  const id = eventId(event);
  const user = loadOrCreateUser(event.params.user);

  const e = new FurnaceMergeWithBonusEvent(id);
  e.timestamp = event.block.timestamp;
  e.blockNumber = event.block.number;
  e.txHash = event.transaction.hash;
  e.user = user.id;
  e.fromTokenId = event.params.fromTokenId;
  e.intoTokenId = event.params.intoTokenId;
  e.fromAmount = event.params.fromAmount;
  e.intoAmount = event.params.intoAmount;
  e.newPrincipal = event.params.newPrincipal;
  e.newEnd = event.params.newEnd;
  e.newAutoMax = event.params.newAutoMax;
  e.durationDelta = event.params.durationDelta;
  e.bonusClaimWei = event.params.bonusClaim;
  e.save();

  settleDeliveredUserBonus(
    event.block.timestamp,
    event.transaction.hash,
    event.params.user,
    event.params.bonusClaim,
  );
}

export function handleLpRewardsVaultSet(event: LpRewardsVaultSet): void {
  const id = eventId(event);
  const protocol = loadOrCreateProtocol(event.block.number);
  protocol.furnace = setBytesIfZero(protocol.furnace, event.address);

  // Canonical wiring source of truth for the LP rewards vault.
  protocol.lpStakingVault = event.params.newVault;

  // Keep back-compat alias in sync.
  if (protocol.furnaceEntryTokenRegistry !== null) {
    protocol.entryTokenRegistry = protocol.furnaceEntryTokenRegistry as Bytes;
  }
  protocol.save();

  const e = new LpRewardsVaultSetEvent(id);
  e.timestamp = event.block.timestamp;
  e.blockNumber = event.block.number;
  e.txHash = event.transaction.hash;
  e.oldVault = event.params.oldVault;
  e.newVault = event.params.newVault;
  e.save();
}

export function handleFurnaceQuoterSet(event: FurnaceQuoterSet): void {
  const id = eventId(event);

  const protocol = loadOrCreateProtocol(event.block.number);
  protocol.furnace = setBytesIfZero(protocol.furnace, event.address);
  // Keep the latest configured quoter (may be set/unset pre-freeze).
  protocol.furnaceQuoter = event.params.newQuoter;

  // Keep back-compat alias in sync.
  if (protocol.furnaceEntryTokenRegistry !== null) {
    protocol.entryTokenRegistry = protocol.furnaceEntryTokenRegistry as Bytes;
  }
  protocol.save();

  const e = new FurnaceQuoterSetEvent(id);
  e.timestamp = event.block.timestamp;
  e.blockNumber = event.block.number;
  e.txHash = event.transaction.hash;
  e.oldQuoter = event.params.oldQuoter;
  e.newQuoter = event.params.newQuoter;
  e.save();
}

export function handleLpRewardsNotifyFailed(event: LpRewardsNotifyFailed): void {
  const id = eventId(event);
  const protocol = loadOrCreateProtocol(event.block.number);
  protocol.furnace = setBytesIfZero(protocol.furnace, event.address);
  if (protocol.furnaceEntryTokenRegistry !== null) {
    protocol.entryTokenRegistry = protocol.furnaceEntryTokenRegistry as Bytes;
  }
  protocol.save();

  const e = new LpRewardsNotifyFailedEvent(id);
  e.timestamp = event.block.timestamp;
  e.blockNumber = event.block.number;
  e.txHash = event.transaction.hash;
  e.vault = event.params.vault;
  e.amountClaim = event.params.amountClaim;
  e.revertData = event.params.revertData;
  e.save();
}

export function handleLpStreamFunded(event: LpStreamFunded): void {
  const id = eventId(event);
  const protocol = loadOrCreateProtocol(event.block.number);
  protocol.furnace = setBytesIfZero(protocol.furnace, event.address);
  if (protocol.furnaceEntryTokenRegistry !== null) {
    protocol.entryTokenRegistry = protocol.furnaceEntryTokenRegistry as Bytes;
  }
  protocol.save();

  const e = new LpStreamFundedEvent(id);
  e.timestamp = event.block.timestamp;
  e.blockNumber = event.block.number;
  e.txHash = event.transaction.hash;
  e.amountFunded = event.params.amountFunded;
  e.newRatePerSec = event.params.newRatePerSec;
  e.newPeriodFinish = event.params.newPeriodFinish;
  e.save();

  const state = loadOrCreateFurnaceState();
  state.updatedAt = event.block.timestamp;
  state.lpStreamRatePerSec = event.params.newRatePerSec;
  state.lpStreamPeriodFinish = event.params.newPeriodFinish;
  state.save();
}

export function handleReserveClamped(event: ReserveClamped): void {
  const id = eventId(event);
  const protocol = loadOrCreateProtocol(event.block.number);
  protocol.furnace = setBytesIfZero(protocol.furnace, event.address);
  if (protocol.furnaceEntryTokenRegistry !== null) {
    protocol.entryTokenRegistry = protocol.furnaceEntryTokenRegistry as Bytes;
  }
  protocol.save();

  const caller = loadOrCreateUser(event.params.caller);

  const e = new ReserveClampedEvent(id);
  e.timestamp = event.block.timestamp;
  e.blockNumber = event.block.number;
  e.txHash = event.transaction.hash;
  e.caller = caller.id;
  e.oldReserve = event.params.oldReserve;
  e.newReserve = event.params.newReserve;
  e.claimBalance = event.params.claimBalance;
  e.lpStreamRemaining = event.params.lpStreamLiability;
  e.save();

  // Latest state
  const state = loadOrCreateFurnaceState();
  state.updatedAt = event.block.timestamp;
  state.reserve = event.params.newReserve;
  state.save();

  // Daily rollup: reserve changes must be reflected in end-of-day reserve.
  const dayId = dayIdFromTimestamp(event.block.timestamp);
  const daily = loadOrCreateDay(dayId);
  daily.reserveEnd = event.params.newReserve;
  daily.save();

  // Bonus timing: read current bonus from the quoter post-clamp and sample.
  // Skipped on local — Anvil prunes old block state, causing BlockOutOfRangeError.
  if (!isLocalNetwork()) {
    const stateResult = tryReadQuoterState(event.address);
    if (!stateResult.reverted) {
      const quoteBps = stateResult.value.value4.toI32();
      const userBps = stateResult.value.value2.toI32();
      const lpBps = stateResult.value.value3.toI32();
      state.grossSpotBonusBps = computeGrossSpotBonusBps(userBps, lpBps);
      state.userSpotBonusBps = userBps;
      state.lpTopupRateBps = lpBps;
      state.save();
      maybeCreateBonusSample(event.block.timestamp, BUCKET_5M, quoteBps);
      maybeCreateBonusSample(event.block.timestamp, BUCKET_1H, quoteBps);
      updateDailyBonusQuoteMinMax(event.block.timestamp, quoteBps, event.params.newReserve);
      updateSnapshotFromLast24h(event.block.timestamp, quoteBps);
    }
  }
}

export function handleReserveCredited(event: ReserveCredited): void {
  const id = eventId(event);
  const protocol = loadOrCreateProtocol(event.block.number);
  protocol.furnace = setBytesIfZero(protocol.furnace, event.address);
  if (protocol.furnaceEntryTokenRegistry !== null) {
    protocol.entryTokenRegistry = protocol.furnaceEntryTokenRegistry as Bytes;
  }
  protocol.save();

  const e = new ReserveCreditedEvent(id);
  e.timestamp = event.block.timestamp;
  e.blockNumber = event.block.number;
  e.txHash = event.transaction.hash;

  e.amount = event.params.amount;
  e.newReserve = event.params.newReserve;

  e.save();

  // Latest state
  const state = loadOrCreateFurnaceState();
  state.updatedAt = event.block.timestamp;
  state.reserve = event.params.newReserve;
  state.save();

  // Daily rollup: reserve changes must be reflected in end-of-day reserve.
  const dayId = dayIdFromTimestamp(event.block.timestamp);
  const daily = loadOrCreateDay(dayId);
  daily.reserveEnd = event.params.newReserve;
  daily.save();

  // Bonus timing: read current bonus from the quoter post-credit and sample.
  // Skipped on local — Anvil prunes old block state, causing BlockOutOfRangeError.
  if (!isLocalNetwork()) {
    const stateResult = tryReadQuoterState(event.address);
    if (!stateResult.reverted) {
      const quoteBps = stateResult.value.value4.toI32();
      const userBps = stateResult.value.value2.toI32();
      const lpBps = stateResult.value.value3.toI32();
      state.grossSpotBonusBps = computeGrossSpotBonusBps(userBps, lpBps);
      state.userSpotBonusBps = userBps;
      state.lpTopupRateBps = lpBps;
      state.save();
      maybeCreateBonusSample(event.block.timestamp, BUCKET_5M, quoteBps);
      maybeCreateBonusSample(event.block.timestamp, BUCKET_1H, quoteBps);
      updateDailyBonusQuoteMinMax(event.block.timestamp, quoteBps, event.params.newReserve);
      updateSnapshotFromLast24h(event.block.timestamp, quoteBps);
    }
  }
}

export function handleDelegationSessionUsed(event: DelegationSessionUsed): void {
  recordDelegationSessionUsed(
    event,
    event.params.user,
    event.params.delegate,
    event.params.actionType,
    event.params.permsUsed,
    event.params.refId,
    event.params.timestamp,
  );
}

export function handleAutoMaxBonusClaimed(event: AutoMaxBonusClaimed): void {
  touchFurnaceProtocol(event.address, event.block.number);

  const id = eventId(event);
  const user = loadOrCreateUser(event.params.user);

  const e = new AutoMaxBonusClaimedEvent(id);
  e.timestamp = event.block.timestamp;
  e.blockNumber = event.block.number;
  e.txHash = event.transaction.hash;
  e.user = user.id;
  e.tokenId = event.params.tokenId;
  e.bonusClaimWei = event.params.bonusClaim;
  e.save();

  settleDeliveredUserBonus(
    event.block.timestamp,
    event.transaction.hash,
    event.params.user,
    event.params.bonusClaim,
  );
}
