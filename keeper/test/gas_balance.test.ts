import test from 'node:test';
import assert from 'node:assert/strict';

import { decideGasBalanceAlert, formatWeiAsEth } from '../src/run/daemon.js';

const ONE_ETH = 1_000_000_000_000_000_000n;

test('formatWeiAsEth: whole, fractional, and trimmed', () => {
  assert.equal(formatWeiAsEth(0n), '0');
  assert.equal(formatWeiAsEth(ONE_ETH), '1');
  assert.equal(formatWeiAsEth(ONE_ETH / 2n), '0.5');
  // 0.475184441228834531 ETH — no trailing-zero trim needed
  assert.equal(formatWeiAsEth(475_184_441_228_834_531n), '0.475184441228834531');
  // trailing zeros trimmed
  assert.equal(formatWeiAsEth(50_000_000_000_000_000n), '0.05');
});

test('decideGasBalanceAlert: above floor never alerts', () => {
  const d = decideGasBalanceAlert({
    balanceWei: ONE_ETH,
    minWei: ONE_ETH / 2n,
    nowMs: 1_000,
    lastAlertAtMs: 0,
    alertRepeatMs: 60_000,
  });
  assert.deepEqual(d, { below: false, alert: false });
});

test('decideGasBalanceAlert: first crossing alerts immediately', () => {
  const d = decideGasBalanceAlert({
    balanceWei: ONE_ETH / 4n,
    minWei: ONE_ETH / 2n,
    nowMs: 5_000,
    lastAlertAtMs: 0,
    alertRepeatMs: 60_000,
  });
  assert.deepEqual(d, { below: true, alert: true });
});

test('decideGasBalanceAlert: throttled while still low inside repeat window', () => {
  const d = decideGasBalanceAlert({
    balanceWei: ONE_ETH / 4n,
    minWei: ONE_ETH / 2n,
    nowMs: 50_000,
    lastAlertAtMs: 10_000,
    alertRepeatMs: 60_000,
  });
  assert.deepEqual(d, { below: true, alert: false });
});

test('decideGasBalanceAlert: re-alerts once repeat interval elapses', () => {
  const d = decideGasBalanceAlert({
    balanceWei: ONE_ETH / 4n,
    minWei: ONE_ETH / 2n,
    nowMs: 70_001,
    lastAlertAtMs: 10_000,
    alertRepeatMs: 60_000,
  });
  assert.deepEqual(d, { below: true, alert: true });
});

test('decideGasBalanceAlert: exact-floor balance is not below', () => {
  const d = decideGasBalanceAlert({
    balanceWei: ONE_ETH / 2n,
    minWei: ONE_ETH / 2n,
    nowMs: 1_000,
    lastAlertAtMs: 0,
    alertRepeatMs: 60_000,
  });
  assert.deepEqual(d, { below: false, alert: false });
});
