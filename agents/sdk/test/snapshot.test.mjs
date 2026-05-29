import test from 'node:test';
import assert from 'node:assert/strict';

import {
  parseSnapshotNonNegativeSafeNumber,
  parseSnapshotSafeNumber,
} from '../dist/src/snapshot.js';

test('parseSnapshotSafeNumber accepts canonical safe integers', () => {
  assert.equal(parseSnapshotSafeNumber(42), 42);
  assert.equal(parseSnapshotSafeNumber(42n), 42);
  assert.equal(parseSnapshotSafeNumber('42'), 42);
});

test('parseSnapshotSafeNumber fails closed on malformed or unsafe integers', () => {
  assert.equal(parseSnapshotSafeNumber('1.5', 7), 7);
  assert.equal(parseSnapshotSafeNumber('25blocks', 7), 7);
  assert.equal(parseSnapshotSafeNumber(BigInt(Number.MAX_SAFE_INTEGER) + 1n, 7), 7);
});

test('parseSnapshotNonNegativeSafeNumber rejects negative values', () => {
  assert.equal(parseSnapshotNonNegativeSafeNumber(42), 42);
  assert.equal(parseSnapshotNonNegativeSafeNumber('42'), 42);
  assert.equal(parseSnapshotNonNegativeSafeNumber(-1, 18), 18);
  assert.equal(parseSnapshotNonNegativeSafeNumber('-5', 18), 18);
});
