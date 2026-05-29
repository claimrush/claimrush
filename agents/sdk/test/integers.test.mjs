import test from 'node:test';
import assert from 'node:assert/strict';

import {
  clampStrictSafeInteger,
  parseStrictNonNegativeSafeInteger,
  parseStrictPositiveSafeInteger,
  parseStrictSafeInteger,
} from '../dist/src/integers.js';

test('strict integer helpers reject malformed and unsafe values', () => {
  assert.equal(parseStrictSafeInteger('42'), 42);
  assert.equal(parseStrictSafeInteger(17n), 17);
  assert.equal(parseStrictSafeInteger('1.5'), undefined);
  assert.equal(parseStrictSafeInteger('10ms'), undefined);
  assert.equal(parseStrictSafeInteger(BigInt(Number.MAX_SAFE_INTEGER) + 1n), undefined);

  assert.equal(parseStrictNonNegativeSafeInteger('-1'), undefined);
  assert.equal(parseStrictNonNegativeSafeInteger('0'), 0);
  assert.equal(parseStrictPositiveSafeInteger('0'), undefined);
  assert.equal(parseStrictPositiveSafeInteger('7'), 7);
});

test('strict integer clamp falls back on malformed values and clamps whole integers', () => {
  assert.equal(clampStrictSafeInteger('3', 10, 0, 5), 3);
  assert.equal(clampStrictSafeInteger('99', 10, 0, 5), 5);
  assert.equal(clampStrictSafeInteger('-4', 10, 0, 5), 0);
  assert.equal(clampStrictSafeInteger('1.5', 10, 0, 5), 10);
});
