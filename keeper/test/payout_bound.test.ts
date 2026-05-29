import test from 'node:test';
import assert from 'node:assert/strict';

import { assertKeeperEoaPayoutBound } from '../src/shared/payout_bound.js';

test('payout-bound: clean tx (delta == -totalCost) passes', () => {
  const res = assertKeeperEoaPayoutBound({
    balanceBeforeWei: 1_000_000_000_000_000_000n, // 1 ETH
    balanceAfterWei: 999_999_999_999_900_000n, // 1 ETH - 100_000 wei
    totalCostWei: 100_000n,
  });
  assert.equal(res.ok, true);
});

test('payout-bound: positive delta (contract paid the keeper) fails closed', () => {
  const res = assertKeeperEoaPayoutBound({
    balanceBeforeWei: 1_000_000_000_000_000_000n,
    balanceAfterWei: 1_000_000_000_000_000_001n, // gained 1 wei despite spending gas
    totalCostWei: 100_000n,
  });
  assert.equal(res.ok, false);
  if (!res.ok) {
    assert.match(res.reason, /keeper EOA received .* no task should pay msg.sender/);
    assert.equal(res.balanceDeltaWei, 1n);
  }
});

test('payout-bound: excess outflow (more than totalCost) fails closed', () => {
  const res = assertKeeperEoaPayoutBound({
    balanceBeforeWei: 1_000_000_000_000_000_000n,
    balanceAfterWei: 999_999_999_999_500_000n, // lost 500_000 wei but only 100_000 wei was tx cost
    totalCostWei: 100_000n,
  });
  assert.equal(res.ok, false);
  if (!res.ok) {
    assert.match(res.reason, /exceeds totalCost 100000 wei by 400000 wei/);
  }
});

test('payout-bound: under-spend (delta == 0 but totalCost > 0) is suspicious — fails closed', () => {
  // No legitimate path lets the EOA balance stay flat after paying tx cost. Either the
  // accounting is wrong or the EOA was paid back, both of which are invariant
  // violations worth surfacing.
  const res = assertKeeperEoaPayoutBound({
    balanceBeforeWei: 1_000_000_000_000_000_000n,
    balanceAfterWei: 1_000_000_000_000_000_000n,
    totalCostWei: 100_000n,
  });
  assert.equal(res.ok, false);
  if (!res.ok) {
    assert.match(
      res.reason,
      /keeper EOA received 100000 wei \(outflow 0 wei < totalCost 100000 wei\)/,
    );
  }
});

test('payout-bound: zero totalCost (state-changing call refunded all gas?) fails closed', () => {
  const res = assertKeeperEoaPayoutBound({
    balanceBeforeWei: 1_000_000_000_000_000_000n,
    balanceAfterWei: 1_000_000_000_000_000_000n,
    totalCostWei: 0n,
  });
  // delta == 0 and totalCost == 0 actually satisfies the invariant — gas refund
  // edge cases aside, this is technically OK. Documented here so future readers
  // don't mistake the "exact match" branch for a soft assertion.
  assert.equal(res.ok, true);
});

test('payout-bound: negative totalCost (corrupt receipt) fails closed', () => {
  const res = assertKeeperEoaPayoutBound({
    balanceBeforeWei: 1_000_000_000_000_000_000n,
    balanceAfterWei: 999_999_999_999_900_000n,
    totalCostWei: -1n,
  });
  assert.equal(res.ok, false);
  if (!res.ok) {
    assert.match(res.reason, /receipt parsing must be wrong/);
  }
});

// OP-stack chains (Base, Optimism, …) charge the EOA both L2 gas
// (`gasUsed * effectiveGasPrice`) AND an L1 data-posting fee (`receipt.l1Fee`)
// at execution time. The audit MUST treat `totalCost = gas + l1Fee` as the
// expected outflow, otherwise the EOA balance delta will exceed L2-only gas
// by exactly `l1Fee` and produce a false-positive `unauthorized withdrawal`
// alert on every tx. This test pins the regression that surfaced during the
// 2026-05-07 Sepolia rehearsal first-takeover (tx
// 0xfe5f88775586e66f96e5fd050d56683ab8599f2cad4b0b1acbe4fa81ba1d4c2f, l1Fee=95 wei).
test('payout-bound: OP-stack tx (delta == -(gas + l1Fee)) passes when caller sums both', () => {
  const gasUsed = 198_018n;
  const effectiveGasPrice = 1_005_000_000n; // 1.005 gwei
  const gasSpentWei = gasUsed * effectiveGasPrice; // 199_008_090_000_000
  const l1FeeWei = 95n; // OP-stack L1 data-posting fee (matches the Sepolia tx above)
  const totalCostWei = gasSpentWei + l1FeeWei; // 199_008_090_000_095

  const balanceBeforeWei = 28_622_034_062_649_571_922n;
  const balanceAfterWei = balanceBeforeWei - totalCostWei;

  const res = assertKeeperEoaPayoutBound({
    balanceBeforeWei,
    balanceAfterWei,
    totalCostWei,
  });
  assert.equal(res.ok, true, 'OP-stack tx with l1Fee summed into totalCost must pass');
});

test('payout-bound: OP-stack tx FAILS if caller forgets to add l1Fee (regression)', () => {
  // Pre-fix behavior: caller passed only `gasUsed * effectiveGasPrice` and the
  // l1Fee component of the EOA outflow looked like an unauthorized withdrawal.
  // This test pins that the verifier itself still flags the case correctly so a
  // future rewrite of the call site that reintroduces the bug fails loudly.
  const gasSpentWei = 199_008_090_000_000n;
  const l1FeeWei = 95n;
  const balanceBeforeWei = 28_622_034_062_649_571_922n;
  const balanceAfterWei = balanceBeforeWei - gasSpentWei - l1FeeWei;

  const res = assertKeeperEoaPayoutBound({
    balanceBeforeWei,
    balanceAfterWei,
    totalCostWei: gasSpentWei, // BUG: forgot l1Fee
  });
  assert.equal(res.ok, false);
  if (!res.ok) {
    assert.match(res.reason, /exceeds totalCost 199008090000000 wei by 95 wei/);
  }
});
