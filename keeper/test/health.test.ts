import test from 'node:test';
import assert from 'node:assert/strict';

import { buildPrometheusMetrics, startKeeperHealthServer } from '../src/shared/health.js';

test('keeper health: refuses unauthenticated non-loopback bind', async () => {
  await assert.rejects(
    () =>
      startKeeperHealthServer({
        host: '0.0.0.0',
        port: 19091,
        token: '',
        getStatus: () => null,
        deployment: 'test',
        chainId: 8453,
        isLockHeld: () => true,
        log: () => undefined,
      }),
    /Refusing to start unauthenticated keeper health server/,
  );
});

test('keeper health: prometheus metrics skip malformed numeric status values', () => {
  const body = buildPrometheusMetrics({
    deployment: 'test',
    chainId: 8453,
    lockHeld: true,
    uptimeSec: '15oops' as any,
    status: {
      revertCounts: {
        good: 3,
        bad: '3oops',
        huge: '9007199254740993',
      },
    },
  });

  assert.match(body, /claimrush_keeper_uptime_seconds\{[^}]*\} 0/);
  assert.match(body, /claimrush_keeper_task_revert_count\{[^}]*task="good"[^}]*\} 3/);
  assert.doesNotMatch(body, /task="bad"/);
  assert.doesNotMatch(body, /task="huge"/);
});
