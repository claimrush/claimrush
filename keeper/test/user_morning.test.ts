import test from 'node:test';
import assert from 'node:assert/strict';

import { detectMorningHour, normalizeActivityTimestamps } from '../src/shared/user_morning.js';

test('keeper user_morning: normalizeActivityTimestamps filters malformed values', () => {
  const timestamps = normalizeActivityTimestamps([
    { timestamp: '1700000000' },
    { timestamp: '1e3' },
    { timestamp: '700.5' },
    { timestamp: '1700003600' },
  ]);

  assert.deepEqual(timestamps, [1_700_000_000, 1_700_003_600]);
});

test('keeper user_morning: detectMorningHour remains stable with normalized timestamps', () => {
  const timestamps = normalizeActivityTimestamps([
    { timestamp: String(6 * 3600) },
    { timestamp: String(7 * 3600) },
    { timestamp: String(8 * 3600) },
    { timestamp: String(9 * 3600) },
    { timestamp: String(10 * 3600) },
    { timestamp: String(11 * 3600) },
    { timestamp: String(12 * 3600) },
    { timestamp: String(13 * 3600) },
    { timestamp: String(14 * 3600) },
    { timestamp: String(15 * 3600) },
    { timestamp: '1e3' },
  ]);

  const hour = detectMorningHour(timestamps);

  assert.equal(hour, 6);
});
