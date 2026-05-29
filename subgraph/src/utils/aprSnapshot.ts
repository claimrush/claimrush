import { Address, BigDecimal, BigInt, Bytes, dataSource } from '@graphprotocol/graph-ts';

import { ClaimToken } from '../generated/VeClaimNFT/ClaimToken';
import { ClaimWethPool } from '../generated/VeClaimNFT/ClaimWethPool';
import { LpStakingVault7D } from '../generated/LpStakingVault7D/LpStakingVault7D';
import {
  AprSnapshot,
  EntryTokenRegistry,
  LpAprHourlyBucket,
  Protocol,
  TokenPricingSnapshot,
} from '../generated/schema';

import { PROTOCOL_ID, isZeroAddressBytes, loadOrCreateProtocol } from './protocol';

// Time constants — bucket arithmetic operates in unix seconds.
const HOUR_SECONDS = BigInt.fromI32(3600);
const HOURS_PER_DAY: i32 = 24;

// Spec constants (docs/spec/apr-calculation-spec-v1.0.0.md §Constants).
// Annualization basis × bps multiplier folded into a single BigDecimal so the
// hot path is one multiplication, one division. `aprBps = floor(BPS_ANNUALIZATION
// × rewardsUsd / avgTvlUsd)`.
const BPS_ANNUALIZATION = BigDecimal.fromString('3650000'); // 10_000 × 365

// 1e18 normalizer for native-decimal token amounts (CLAIM, WETH, LP — all 18d).
const ONE_E18_WEI = BigInt.fromString('1000000000000000000');
const ONE_E18_DECIMAL = ONE_E18_WEI.toBigDecimal();
const ZERO_BD = BigDecimal.zero();
const ZERO_BI = BigInt.zero();

/**
 * Floor a non-negative BigDecimal to a BigInt.
 *
 * `graph-ts` BigDecimal exposes `digits × 10^exp` directly; for non-negative
 * values the floor is digits when `exp ≥ 0` (after applying the exponent) or
 * `digits / 10^(-exp)` (integer division) when `exp < 0`. This matches the
 * spec's "round DOWN (floor)" rule for every APR division.
 */
function bigDecimalFloorToBigInt(d: BigDecimal): BigInt {
  if (d.exp.ge(ZERO_BI)) {
    const expI32 = d.exp.toI32();
    if (expI32 == 0) return d.digits;
    let mult = BigInt.fromI32(1);
    for (let i: i32 = 0; i < expI32; i++) {
      mult = mult.times(BigInt.fromI32(10));
    }
    return d.digits.times(mult);
  }
  const negExpI32 = ZERO_BI.minus(d.exp).toI32();
  let denom = BigInt.fromI32(1);
  for (let i: i32 = 0; i < negExpI32; i++) {
    denom = denom.times(BigInt.fromI32(10));
  }
  return d.digits.div(denom);
}

function hourStart(ts: BigInt): BigInt {
  return ts.div(HOUR_SECONDS).times(HOUR_SECONDS);
}

function loadOrCreateBucket(hour: BigInt, blockTimestamp: BigInt): LpAprHourlyBucket {
  const id = hour.toString();
  let b = LpAprHourlyBucket.load(id);
  if (b == null) {
    b = new LpAprHourlyBucket(id);
    b.hourStart = hour;
    b.lpRewardsClaimWei = ZERO_BI;
    b.shareholderEthWei = ZERO_BI;
    b.totalStakedLpWei = null;
    b.lpTvlUsd = null;
    b.totalLockedClaimUsd = null;
    b.claimUsd = null;
    b.ethUsd = null;
    b.updatedAt = blockTimestamp;
  }
  return b as LpAprHourlyBucket;
}

/**
 * Resolve the canonical CLAIM/WETH pool address from the Furnace registry the
 * protocol singleton points at. Returns null until the registry binds.
 */
function resolveCanonicalPool(protocol: Protocol): Address | null {
  const registryBytes = protocol.entryTokenRegistry;
  if (registryBytes === null || isZeroAddressBytes(registryBytes as Bytes)) return null;
  const registry = EntryTokenRegistry.load((registryBytes as Bytes).toHexString());
  if (registry == null) return null;
  const poolBytes = registry.wethClaimPool;
  if (poolBytes === null || isZeroAddressBytes(poolBytes as Bytes)) return null;
  return Address.fromBytes(poolBytes as Bytes);
}

class TvlSnapshot {
  totalStakedLpWei: BigInt;
  lpTvlUsd: BigDecimal;
  constructor(totalStakedLpWei: BigInt, lpTvlUsd: BigDecimal) {
    this.totalStakedLpWei = totalStakedLpWei;
    this.lpTvlUsd = lpTvlUsd;
  }
}

/**
 * Compute the LP TVL in USD at the current block.
 *
 * Spec: `tvlUsd = totalStakedLP × lpValueUsd` where
 *
 *   lpValueUsd = (reserveClaim × claimUsd + reserveWeth × ethUsd) / totalSupplyLP
 *
 * Reserves are read via Aerodrome v2 `getReserves()` when available, with a
 * pool-balance fallback for the Sepolia `TestnetSwapPool` (whose `reserve0` /
 * `reserve1` are `internal`). All three tokens (CLAIM, WETH, LP) are 18d, so
 * the wei → token normalization is the same 1e18 divisor everywhere.
 *
 * Returns null when any required input is missing — `getReserves` reverts and
 * the balance fallback returns zero, `totalSupply` reverts, the pricing
 * primitives are null, or the pool's tokens cannot be matched against the
 * canonical CLAIM address.
 */
function snapshotLpTvlUsd(
  vaultAddress: Address,
  poolAddress: Address,
  claimAddress: Address,
  claimUsd: BigDecimal,
  ethUsd: BigDecimal,
): TvlSnapshot | null {
  const vault = LpStakingVault7D.bind(vaultAddress);
  const totalStakedResult = vault.try_totalStaked();
  if (totalStakedResult.reverted) return null;
  const totalStakedLpWei = totalStakedResult.value;

  const pool = ClaimWethPool.bind(poolAddress);
  const totalSupplyResult = pool.try_totalSupply();
  if (totalSupplyResult.reverted) return null;
  const lpTotalSupplyWei = totalSupplyResult.value;
  if (lpTotalSupplyWei.equals(ZERO_BI)) return null;

  const token0Result = pool.try_token0();
  const token1Result = pool.try_token1();
  if (token0Result.reverted || token1Result.reverted) return null;
  const token0 = token0Result.value;
  const token1 = token1Result.value;

  // Identify which side is CLAIM. The other side is WETH.
  let claimIsToken0: bool = false;
  if (token0.equals(claimAddress)) {
    claimIsToken0 = true;
  } else if (token1.equals(claimAddress)) {
    claimIsToken0 = false;
  } else {
    return null;
  }

  // Reserve read — Aerodrome v2 publishes via getReserves(); the testnet pool
  // exposes reserves only indirectly through token balances.
  let reserve0: BigInt = ZERO_BI;
  let reserve1: BigInt = ZERO_BI;
  const reservesResult = pool.try_getReserves();
  if (!reservesResult.reverted) {
    reserve0 = reservesResult.value.value0;
    reserve1 = reservesResult.value.value1;
  } else {
    const token0Erc20 = ClaimToken.bind(token0);
    const token1Erc20 = ClaimToken.bind(token1);
    const bal0 = token0Erc20.try_balanceOf(poolAddress);
    const bal1 = token1Erc20.try_balanceOf(poolAddress);
    if (bal0.reverted || bal1.reverted) return null;
    reserve0 = bal0.value;
    reserve1 = bal1.value;
  }

  const reserveClaim = claimIsToken0 ? reserve0 : reserve1;
  const reserveWeth = claimIsToken0 ? reserve1 : reserve0;

  // lpValueUsd = (reserveClaim × claimUsd + reserveWeth × ethUsd) / totalSupplyLP
  // All amounts are 18d wei; expressing the math in BigDecimal keeps the
  // intermediate scaling implicit (no 1e18 multiplier juggling).
  const reserveClaimDec = reserveClaim.toBigDecimal();
  const reserveWethDec = reserveWeth.toBigDecimal();
  const lpTotalSupplyDec = lpTotalSupplyWei.toBigDecimal();

  const poolValueUsd = reserveClaimDec.times(claimUsd).plus(reserveWethDec.times(ethUsd));
  // `lpValueUsd` units: USD per LP wei (since lpTotalSupply is in wei).
  const lpValueUsdPerWei = poolValueUsd.div(lpTotalSupplyDec);
  const lpTvlUsd = totalStakedLpWei.toBigDecimal().times(lpValueUsdPerWei);

  return new TvlSnapshot(totalStakedLpWei, lpTvlUsd);
}

/**
 * Walk the 24 buckets that close the spec window `[asOfTs - 86_400, asOfTs)`,
 * summing the non-null `lpTvlUsd` snapshots into an arithmetic mean.
 *
 * Returns null when not a single bucket inside the window carries a TVL
 * snapshot — the spec gates APR display on `avgTvlUsd > 0`.
 */
function averageLpTvlOverLast24h(asOfHour: BigInt): BigDecimal | null {
  let sum = ZERO_BD;
  let count: i32 = 0;
  for (let i: i32 = 1; i <= HOURS_PER_DAY; i++) {
    const bh = asOfHour.minus(BigInt.fromI32(i).times(HOUR_SECONDS));
    const bucket = LpAprHourlyBucket.load(bh.toString());
    if (bucket == null) continue;
    const tvl = bucket.lpTvlUsd;
    if (tvl === null) continue;
    sum = sum.plus(tvl as BigDecimal);
    count++;
  }
  if (count == 0) return null;
  return sum.div(BigDecimal.fromString(count.toString()));
}

/**
 * Sum the flow buckets inside the spec window `[asOfTs - 86_400, asOfTs)`.
 * Used twice: once for LP rewards (CLAIM wei), once for shareholder ETH (wei).
 */
function sumFlowOverLast24h(asOfHour: BigInt, kind: i32): BigInt {
  let sum = ZERO_BI;
  for (let i: i32 = 1; i <= HOURS_PER_DAY; i++) {
    const bh = asOfHour.minus(BigInt.fromI32(i).times(HOUR_SECONDS));
    const bucket = LpAprHourlyBucket.load(bh.toString());
    if (bucket == null) continue;
    if (kind == 0) {
      sum = sum.plus(bucket.lpRewardsClaimWei);
    } else {
      sum = sum.plus(bucket.shareholderEthWei);
    }
  }
  return sum;
}

const FLOW_LP_REWARDS: i32 = 0;
const FLOW_SHAREHOLDER_ETH: i32 = 1;

/**
 * Compute `claimUsd = claimEthTwap30m × ethUsd` from the latest pricing
 * snapshot. Returns null when either input is null — every APR consumer
 * already treats null pricing as "APR unavailable".
 */
function readClaimUsd(snapshot: TokenPricingSnapshot): BigDecimal | null {
  const claimEth = snapshot.claimEthTwap30m;
  const ethUsd = snapshot.ethUsd;
  if (claimEth === null || ethUsd === null) return null;
  return (claimEth as BigDecimal).times(ethUsd as BigDecimal);
}

/**
 * Recompute the AprSnapshot singleton from the current bucket window. Called
 * after every flow/stock touch so the consumer sees the freshest values.
 */
function refreshAprSnapshot(asOfHour: BigInt, blockTimestamp: BigInt): void {
  const pricing = TokenPricingSnapshot.load(PROTOCOL_ID);
  if (pricing == null) return;

  let snap = AprSnapshot.load(PROTOCOL_ID);
  if (snap == null) {
    snap = new AprSnapshot(PROTOCOL_ID);
  }

  const claimUsd = readClaimUsd(pricing as TokenPricingSnapshot);
  const ethUsd = pricing.ethUsd;

  // -- LP APR --------------------------------------------------------------
  // Numerator: sum(lpRewardsClaimWei) × claimUsd / 1e18
  // Denominator: avg(lpTvlUsd) over the 24 buckets in window.
  const rewardsClaimWei = sumFlowOverLast24h(asOfHour, FLOW_LP_REWARDS);
  const avgTvlUsd = averageLpTvlOverLast24h(asOfHour);

  if (claimUsd !== null && avgTvlUsd !== null && (avgTvlUsd as BigDecimal).gt(ZERO_BD)) {
    const rewardsUsd = rewardsClaimWei
      .toBigDecimal()
      .div(ONE_E18_DECIMAL)
      .times(claimUsd as BigDecimal);
    const aprBpsDec = BPS_ANNUALIZATION.times(rewardsUsd).div(avgTvlUsd as BigDecimal);
    snap.lpAprBps24h = bigDecimalFloorToBigInt(aprBpsDec);
    snap.lpAvgTvl24hUsd = avgTvlUsd as BigDecimal;
  } else {
    snap.lpAprBps24h = null;
    snap.lpAvgTvl24hUsd = null;
  }

  // -- veAPR ---------------------------------------------------------------
  // Numerator: sum(shareholderEthWei) × ethUsd / 1e18
  // Denominator: totalLockedClaim × claimUsd (read from the singleton, which
  // tracks `ClaimToken.balanceOf(VeClaimNFT)` — the on-chain invariant pins
  // it to `VeClaimNFT.totalLockedClaim()`).
  const lockedSupplyWei = pricing.lockedSupplyWei;
  if (
    claimUsd !== null &&
    ethUsd !== null &&
    lockedSupplyWei !== null &&
    (lockedSupplyWei as BigInt).gt(ZERO_BI)
  ) {
    const ethWei = sumFlowOverLast24h(asOfHour, FLOW_SHAREHOLDER_ETH);
    const ethAllocatedUsd = ethWei
      .toBigDecimal()
      .div(ONE_E18_DECIMAL)
      .times(ethUsd as BigDecimal);
    const lockedClaimUsd = (lockedSupplyWei as BigInt)
      .toBigDecimal()
      .div(ONE_E18_DECIMAL)
      .times(claimUsd as BigDecimal);
    if (lockedClaimUsd.gt(ZERO_BD)) {
      const veAprBpsDec = BPS_ANNUALIZATION.times(ethAllocatedUsd).div(lockedClaimUsd);
      snap.veAprBps24h = bigDecimalFloorToBigInt(veAprBpsDec);
    } else {
      snap.veAprBps24h = null;
    }
  } else {
    snap.veAprBps24h = null;
  }

  snap.updatedAt = blockTimestamp;
  snap.save();
}

/**
 * Public entry point invoked by every `LpStakingVault7D` handler whose event
 * mutates flow (`LpRewardsNotified.amountClaim`) or stock (`LpStaked`,
 * `LpUnbondStarted` — both change `totalStaked()`). Writes the current-hour
 * bucket and then refreshes the AprSnapshot singleton in a single pass.
 *
 * `vaultAddress` is the LpStakingVault7D itself (i.e. `dataSource.address()`),
 * passed in so callers don't import `dataSource` separately.
 */
export function recordLpEventForApr(
  vaultAddress: Address,
  blockNumber: BigInt,
  blockTimestamp: BigInt,
  rewardsClaimWeiDelta: BigInt,
): void {
  // Anvil archive RPCs return BlockOutOfRangeError for retroactive eth_calls;
  // skip the snapshot path on local to avoid an infinite-retry loop.
  if (dataSource.network() == 'local') return;

  const protocol = loadOrCreateProtocol(blockNumber);
  if (isZeroAddressBytes(protocol.claimToken)) return;

  const hour = hourStart(blockTimestamp);
  const bucket = loadOrCreateBucket(hour, blockTimestamp);

  if (rewardsClaimWeiDelta.gt(ZERO_BI)) {
    bucket.lpRewardsClaimWei = bucket.lpRewardsClaimWei.plus(rewardsClaimWeiDelta);
  }

  const poolAddress = resolveCanonicalPool(protocol);
  const pricing = TokenPricingSnapshot.load(PROTOCOL_ID);
  if (poolAddress !== null && pricing != null) {
    const claimUsd = readClaimUsd(pricing as TokenPricingSnapshot);
    const ethUsd = pricing.ethUsd;
    if (claimUsd !== null && ethUsd !== null) {
      const tvl = snapshotLpTvlUsd(
        vaultAddress,
        poolAddress as Address,
        Address.fromBytes(protocol.claimToken as Bytes),
        claimUsd as BigDecimal,
        ethUsd as BigDecimal,
      );
      if (tvl !== null) {
        bucket.totalStakedLpWei = tvl.totalStakedLpWei;
        bucket.lpTvlUsd = tvl.lpTvlUsd;
        bucket.claimUsd = claimUsd as BigDecimal;
        bucket.ethUsd = ethUsd as BigDecimal;
      }
    }
  }

  bucket.updatedAt = blockTimestamp;
  bucket.save();

  refreshAprSnapshot(hour, blockTimestamp);
}

/**
 * Public entry point invoked by `handleShareholderTakeoverAllocation`. Writes
 * the current-hour shareholder flow bucket and snapshots
 * `totalLockedClaimUsd` from the pricing singleton, then refreshes the
 * AprSnapshot singleton. Does not eth_call the LP vault — TVL stays attached
 * to whichever LP event last touched the bucket.
 */
export function recordShareholderEthForApr(
  blockNumber: BigInt,
  blockTimestamp: BigInt,
  ethWeiDelta: BigInt,
): void {
  touchVeStockBucket(blockNumber, blockTimestamp, ethWeiDelta);
}

/**
 * Public entry point invoked by VeClaimNFT lock handlers after pricing has
 * been refreshed for the same block. A lock change moves `lockedSupplyWei`,
 * which is the veAPR denominator; without this call the AprSnapshot's
 * `veAprBps24h` (and the bucket's `totalLockedClaimUsd` stock) stays attached
 * to the value last observed at a shareholder allocation, drifting after
 * every Furnace/lock-flow event. No flow is added — only the stock snapshot
 * on the current-hour bucket and the singleton recompute.
 */
export function refreshAprAfterLockChange(
  blockNumber: BigInt,
  blockTimestamp: BigInt,
): void {
  touchVeStockBucket(blockNumber, blockTimestamp, ZERO_BI);
}

/**
 * Shared bucket-touch path for shareholder allocations and VeClaim lock
 * changes. Optionally accumulates an ETH wei flow delta (zero when called
 * from a lock handler), then refreshes the `totalLockedClaimUsd` stock from
 * the pricing singleton and triggers an AprSnapshot recompute.
 */
function touchVeStockBucket(
  blockNumber: BigInt,
  blockTimestamp: BigInt,
  ethWeiDelta: BigInt,
): void {
  if (dataSource.network() == 'local') return;

  const protocol = loadOrCreateProtocol(blockNumber);
  if (isZeroAddressBytes(protocol.claimToken)) return;

  const hour = hourStart(blockTimestamp);
  const bucket = loadOrCreateBucket(hour, blockTimestamp);

  if (ethWeiDelta.gt(ZERO_BI)) {
    bucket.shareholderEthWei = bucket.shareholderEthWei.plus(ethWeiDelta);
  }

  const pricing = TokenPricingSnapshot.load(PROTOCOL_ID);
  if (pricing != null) {
    const claimUsd = readClaimUsd(pricing as TokenPricingSnapshot);
    const ethUsd = pricing.ethUsd;
    const lockedSupplyWei = pricing.lockedSupplyWei;
    if (claimUsd !== null && lockedSupplyWei !== null) {
      bucket.totalLockedClaimUsd = (lockedSupplyWei as BigInt)
        .toBigDecimal()
        .div(ONE_E18_DECIMAL)
        .times(claimUsd as BigDecimal);
      bucket.claimUsd = claimUsd as BigDecimal;
      if (ethUsd !== null) bucket.ethUsd = ethUsd as BigDecimal;
    }
  }

  bucket.updatedAt = blockTimestamp;
  bucket.save();

  refreshAprSnapshot(hour, blockTimestamp);
}
