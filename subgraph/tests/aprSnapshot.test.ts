import {
  assert,
  beforeEach,
  clearStore,
  dataSourceMock,
  test,
} from 'matchstick-as/assembly/index';
import { Address, BigDecimal, BigInt, DataSourceContext } from '@graphprotocol/graph-ts';

import { AprSnapshot, LpAprHourlyBucket, TokenPricingSnapshot } from '../src/generated/schema';
import { refreshAprAfterLockChange, recordShareholderEthForApr } from '../src/utils/aprSnapshot';
import { loadOrCreateProtocol, PROTOCOL_ID, ZERO_ADDRESS } from '../src/utils/protocol';

const HOUR_SECONDS = BigInt.fromI32(3600);
const AS_OF_HOUR = BigInt.fromI32(86_400);
const BLOCK_TS = AS_OF_HOUR.plus(BigInt.fromI32(100));
const BLOCK_NUMBER = BigInt.fromI32(42_000);

// claimUsd = claimEthTwap30m × ethUsd = 0.01 (spec veAPR / LP APR vectors).
const CLAIM_ETH_TWAP = '0.000003333333333333';
const ETH_USD = '3000';

// 5_000 CLAIM × 0.01 USD/CLAIM = 50 USD rewards (LP APR vector numerator).
const REWARDS_CLAIM_WEI = BigInt.fromString('5000000000000000000000');

// 20_000_000 CLAIM locked (veAPR vector denominator).
const LOCKED_CLAIM_WEI = BigInt.fromString('20000000000000000000000000');

// 0.1 ETH shareholder flow (veAPR vector numerator).
const ETH_FLOW_WEI = BigInt.fromString('100000000000000000');

function mockSepoliaNetwork(): void {
  const ctx = new DataSourceContext();
  dataSourceMock.setReturnValues(
    '0x0000000000000000000000000000000000000001',
    'base-sepolia',
    ctx,
  );
}

function seedClaimToken(): Address {
  const claimToken = Address.fromString('0x1111111111111111111111111111111111111111');
  const protocol = loadOrCreateProtocol(BLOCK_NUMBER);
  protocol.claimToken = claimToken;
  protocol.save();
  return claimToken;
}

function seedPricing(lockedSupplyWei: BigInt | null): void {
  let pricing = TokenPricingSnapshot.load(PROTOCOL_ID);
  if (pricing == null) {
    pricing = new TokenPricingSnapshot(PROTOCOL_ID);
  }
  pricing.claimEthTwap30m = BigDecimal.fromString(CLAIM_ETH_TWAP);
  pricing.ethUsd = BigDecimal.fromString(ETH_USD);
  pricing.lockedSupplyWei = lockedSupplyWei;
  pricing.save();
}

function seedLpBucket(
  hourStart: BigInt,
  lpRewardsClaimWei: BigInt,
  lpTvlUsd: BigDecimal,
): void {
  const bucket = new LpAprHourlyBucket(hourStart.toString());
  bucket.hourStart = hourStart;
  bucket.lpRewardsClaimWei = lpRewardsClaimWei;
  bucket.shareholderEthWei = BigInt.zero();
  bucket.lpTvlUsd = lpTvlUsd;
  bucket.updatedAt = BLOCK_TS;
  bucket.save();
}

function seedShareholderBucket(hourStart: BigInt, shareholderEthWei: BigInt): void {
  const bucket = new LpAprHourlyBucket(hourStart.toString());
  bucket.hourStart = hourStart;
  bucket.lpRewardsClaimWei = BigInt.zero();
  bucket.shareholderEthWei = shareholderEthWei;
  bucket.updatedAt = BLOCK_TS;
  bucket.save();
}

beforeEach(() => {
  clearStore();
  dataSourceMock.resetValues();
  mockSepoliaNetwork();
  seedClaimToken();
});

test('refreshAprSnapshot LP APR matches spec test vector (1825 bps)', () => {
  seedPricing(null);

  const prevHour = AS_OF_HOUR.minus(HOUR_SECONDS);
  seedLpBucket(prevHour, REWARDS_CLAIM_WEI, BigDecimal.fromString('100000'));

  refreshAprAfterLockChange(BLOCK_NUMBER, BLOCK_TS);

  const snap = AprSnapshot.load(PROTOCOL_ID);
  assert.assertNotNull(snap);
  assert.bigIntEquals(snap!.lpAprBps24h!, BigInt.fromI32(1825));
  assert.bigDecimalEquals(snap!.lpAvgTvl24hUsd!, BigDecimal.fromString('100000'));
});

test('refreshAprSnapshot veAPR matches spec test vector (3650 bps)', () => {
  seedPricing(LOCKED_CLAIM_WEI);

  const prevHour = AS_OF_HOUR.minus(HOUR_SECONDS);
  seedShareholderBucket(prevHour, ETH_FLOW_WEI);

  recordShareholderEthForApr(BLOCK_NUMBER, BLOCK_TS, BigInt.zero());

  const snap = AprSnapshot.load(PROTOCOL_ID);
  assert.assertNotNull(snap);
  assert.bigIntEquals(snap!.veAprBps24h!, BigInt.fromI32(3650));
});

test('refreshAprSnapshot writes null LP APR when avg TVL bucket missing', () => {
  seedPricing(null);

  refreshAprAfterLockChange(BLOCK_NUMBER, BLOCK_TS);

  const snap = AprSnapshot.load(PROTOCOL_ID);
  assert.assertNotNull(snap);
  assert.assertNull(snap!.lpAprBps24h);
  assert.assertNull(snap!.lpAvgTvl24hUsd);
});

test('local network skips APR refresh', () => {
  dataSourceMock.resetValues();
  const ctx = new DataSourceContext();
  dataSourceMock.setReturnValues(
    '0x0000000000000000000000000000000000000001',
    'local',
    ctx,
  );

  seedPricing(LOCKED_CLAIM_WEI);
  const prevHour = AS_OF_HOUR.minus(HOUR_SECONDS);
  seedShareholderBucket(prevHour, ETH_FLOW_WEI);

  refreshAprAfterLockChange(BLOCK_NUMBER, BLOCK_TS);

  const snap = AprSnapshot.load(PROTOCOL_ID);
  // ensureInfoSurfaces creates an empty singleton; local guard must not populate bps.
  if (snap !== null) {
    assert.assertNull(snap.veAprBps24h);
    assert.assertNull(snap.lpAprBps24h);
  }
});
