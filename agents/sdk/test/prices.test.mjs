import test from 'node:test';
import assert from 'node:assert/strict';

import { parseStrictPositiveDecimalString } from '../dist/src/prices.js';

test('prices: parseStrictPositiveDecimalString rejects malformed suffixes', () => {
  assert.equal(parseStrictPositiveDecimalString('1.5eth'), null);
  assert.equal(parseStrictPositiveDecimalString('10sec'), null);
  assert.equal(parseStrictPositiveDecimalString('-1'), null);
});

test('prices: parseStrictPositiveDecimalString accepts canonical positive decimals', () => {
  assert.equal(parseStrictPositiveDecimalString('0.5'), 0.5);
  assert.equal(parseStrictPositiveDecimalString('12'), 12);
});
