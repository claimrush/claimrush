import test from 'node:test';
import assert from 'node:assert/strict';

import { parseChainIdStrict } from '../src/shared/chainId.js';

test('parseChainIdStrict accepts valid decimal and hex chain IDs', () => {
  assert.equal(parseChainIdStrict(8453), 8453);
  assert.equal(parseChainIdStrict(8453n), 8453);
  assert.equal(parseChainIdStrict('8453'), 8453);
  assert.equal(parseChainIdStrict('0x2105'), 8453);
  assert.equal(parseChainIdStrict(' 0X2105 '), 8453);
});

test('parseChainIdStrict rejects malformed suffixes and invalid values', () => {
  assert.equal(parseChainIdStrict('8453oops'), null);
  assert.equal(parseChainIdStrict('0x2105oops'), null);
  assert.equal(parseChainIdStrict('0'), null);
  assert.equal(parseChainIdStrict('-1'), null);
  assert.equal(parseChainIdStrict(0), null);
  assert.equal(parseChainIdStrict(BigInt(Number.MAX_SAFE_INTEGER) + 1n), null);
});
