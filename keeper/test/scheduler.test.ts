import test from 'node:test';
import assert from 'node:assert/strict';

import { normalizeKeeperWaitForLockSecs } from '../src/run/lock.js';
import { computeInitialNextRunMs, jitteredIntervalMs } from '../src/run/scheduler.js';

test('keeper scheduler: malformed jitter input leaves interval unchanged', () => {
  assert.equal(jitteredIntervalMs(30_000, '250.5' as unknown as number), 30_000);
});

test('keeper scheduler: malformed interval input falls back to immediate retry', () => {
  const nowMs = Date.now();
  assert.equal(
    computeInitialNextRunMs({
      nowMs,
      lastAttemptByTask: { autoFurnace: new Date(nowMs - 1_000).toISOString() },
      statusKey: 'autoFurnace',
      intervalMs: '30.5' as unknown as number,
    }),
    nowMs,
  );
});

test('keeper lock wait: malformed wait values fail closed to zero seconds', () => {
  assert.equal(normalizeKeeperWaitForLockSecs('15.5'), 0);
  assert.equal(normalizeKeeperWaitForLockSecs(-1), 0);
});
