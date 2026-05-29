import test from 'node:test';
import assert from 'node:assert/strict';

import {
  applySymmetricJitterBps,
  computeExponentialBackoffDelayMs,
} from '../src/shared/backoff.js';

test('keeper backoff: malformed failure count fails closed', () => {
  assert.equal(
    computeExponentialBackoffDelayMs({
      failureCount: '2.5',
      initialMs: 1_000,
      multiplier: 2,
      maxMs: 10_000,
      jitterBps: 0,
    }),
    0,
  );
});

test('keeper backoff: jitter never raises delay above the configured cap', () => {
  const originalRandom = Math.random;
  Math.random = () => 1;

  try {
    assert.equal(
      computeExponentialBackoffDelayMs({
        failureCount: 5,
        initialMs: 1_000,
        multiplier: 2,
        maxMs: 5_000,
        jitterBps: 5_000,
      }),
      5_000,
    );
  } finally {
    Math.random = originalRandom;
  }
});

test('keeper backoff: malformed jitter input leaves the base delay unchanged', () => {
  assert.equal(applySymmetricJitterBps(2_000, '500.5'), 2_000);
});
