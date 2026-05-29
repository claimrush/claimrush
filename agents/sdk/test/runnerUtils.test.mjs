import test from 'node:test';
import assert from 'node:assert/strict';

import { parseEthOrZero, parseIntOrUndefined } from '../dist/src/agent/runnerUtils.js';

test('agent runner utils: parseIntOrUndefined accepts only strict integers', () => {
  assert.equal(parseIntOrUndefined('42'), 42);
  assert.equal(parseIntOrUndefined('-7'), -7);
  assert.equal(parseIntOrUndefined(' 15 '), 15);

  assert.equal(parseIntOrUndefined('1.5'), undefined);
  assert.equal(parseIntOrUndefined('10ms'), undefined);
  assert.equal(parseIntOrUndefined(''), undefined);
});

test('agent runner utils: parseEthOrZero accepts canonical zero only', () => {
  assert.equal(parseEthOrZero('0'), 0n);
  assert.equal(parseEthOrZero('0.0'), 0n);
  assert.throws(() => parseEthOrZero('0e0'));
});
