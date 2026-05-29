import test from 'node:test';
import assert from 'node:assert/strict';

import {
  applyBps,
  clamp,
  fmtMs,
  parseNonNegativeSafeInteger,
  parsePositiveSafeInteger,
  parseUintBigIntOrNull,
  shortAddr,
  toBigIntSafe,
} from '../src/shared/utils.js';

test('keeper utils: clamp', () => {
  assert.equal(clamp(5, { min: 0, max: 10 }), 5);
  assert.equal(clamp(-1, { min: 0, max: 10 }), 0);
  assert.equal(clamp(999, { min: 0, max: 10 }), 10);
});

test('keeper utils: toBigIntSafe', () => {
  assert.equal(toBigIntSafe(null, { defaultValue: 7n }), 7n);
  assert.equal(toBigIntSafe('0x10'), 16n);
  assert.equal(toBigIntSafe('42'), 42n);
  assert.equal(toBigIntSafe('nope', { defaultValue: 9n }), 9n);
  // Non-integer numbers should not throw.
  assert.equal(toBigIntSafe(1.5, { defaultValue: 11n }), 11n);
});

test('keeper utils: applyBps', () => {
  assert.equal(applyBps(100n, 0), 100n);
  assert.equal(applyBps(100n, 10_000), 0n);
  assert.equal(applyBps(100n, 100), 99n);
});

test('keeper utils: parseUintBigIntOrNull', () => {
  assert.equal(parseUintBigIntOrNull('42'), 42n);
  assert.equal(parseUintBigIntOrNull('0x10'), 16n);
  assert.equal(parseUintBigIntOrNull(0), 0n);

  // Reject negative values (these are invalid for uint IDs like tokenId/offerId).
  assert.equal(parseUintBigIntOrNull('-1'), null);
  assert.equal(parseUintBigIntOrNull(-1), null);

  // Reject invalid/empty inputs.
  assert.equal(parseUintBigIntOrNull(''), null);
  assert.equal(parseUintBigIntOrNull('nope'), null);
});

test('keeper utils: parseNonNegativeSafeInteger', () => {
  assert.equal(parseNonNegativeSafeInteger(0), 0);
  assert.equal(parseNonNegativeSafeInteger('42'), 42);
  assert.equal(parseNonNegativeSafeInteger(42n), 42);
  assert.equal(parseNonNegativeSafeInteger('42ms'), null);
  assert.equal(parseNonNegativeSafeInteger(-1), null);
  assert.equal(parseNonNegativeSafeInteger(1.5), null);
});

test('keeper utils: parsePositiveSafeInteger', () => {
  assert.equal(parsePositiveSafeInteger(1), 1);
  assert.equal(parsePositiveSafeInteger('42'), 42);
  assert.equal(parsePositiveSafeInteger(42n), 42);
  assert.equal(parsePositiveSafeInteger(0), null);
  assert.equal(parsePositiveSafeInteger('1e3'), null);
  assert.equal(parsePositiveSafeInteger('7.0'), null);
});

test('keeper utils: fmtMs / shortAddr', () => {
  assert.equal(fmtMs(999), '999ms');
  assert.equal(fmtMs(1500), '1.5s');
  assert.equal(fmtMs(65_000), '1m5s');

  assert.equal(shortAddr('0x1234567890abcdef'), '0x1234...cdef');
});
