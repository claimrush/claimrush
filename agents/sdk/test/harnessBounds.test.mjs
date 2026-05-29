import test from 'node:test';
import assert from 'node:assert/strict';

import { parseHarnessBoundedInt } from '../dist/src/harness/harness.js';

test('parseHarnessBoundedInt accepts canonical integers within bounds', () => {
  assert.equal(parseHarnessBoundedInt('30', 7, 0, 365), 30);
  assert.equal(parseHarnessBoundedInt(45, 7, 0, 365), 45);
});

test('parseHarnessBoundedInt ignores malformed fractional values instead of truncating', () => {
  assert.equal(parseHarnessBoundedInt('1.5', 7, 0, 365), 7);
  assert.equal(parseHarnessBoundedInt('25seconds', 7, 0, 365), 7);
});
