import test from 'node:test';
import assert from 'node:assert/strict';

import { runStrategies } from '../dist/src/index.js';
import { SubgraphClient } from '../dist/src/subgraph.js';
import {
  getRecentFurnaceEnters,
  getRecentShareholderAutoCompounds,
  getRecentShareholderClaims,
  getRecentTakeovers,
} from '../dist/src/subgraph.js';
import { TxManager, DEFAULT_TX_REPLACEMENT_POLICY } from '../dist/src/tx/txManager.js';
import { Semaphore } from '../dist/src/util/semaphore.js';
import { AsyncTtlCache } from '../dist/src/util/asyncTtlCache.js';

const ADDRESS_ONE = '0x0000000000000000000000000000000000000001';

test('agent strategies ignore malformed maxActions instead of truncating', async () => {
  const result = await runStrategies({
    maxActions: '1.5',
    ctx: {
      chain: 'base_mainnet',
      chainId: 8453,
      agent: ADDRESS_ONE,
      user: ADDRESS_ONE,
      snapshot: {},
      config: {},
      state: {},
      nowMs: Date.now(),
    },
    strategies: [
      { id: 'a', propose: () => [{ kind: 'mineCore.withdrawKingBalance', amount: 1n }] },
      {
        id: 'b',
        propose: () => [
          { kind: 'mineCore.withdrawKingBalance', amount: 2n },
          { kind: 'mineCore.withdrawKingBalance', amount: 3n },
        ],
      },
    ],
  });

  assert.equal(result.actions.length, 3);
});

test('subgraph client falls back on malformed maxResponseBytes', () => {
  const fallbackClient = new SubgraphClient({
    url: 'https://example.com/graphql',
    maxResponseBytes: '1.5',
  });
  assert.equal(fallbackClient.maxResponseBytes, 2_000_000);

  const strictClient = new SubgraphClient({
    url: 'https://example.com/graphql',
    maxResponseBytes: '256',
  });
  assert.equal(strictClient.maxResponseBytes, 256);
});

test('recent subgraph helpers ignore malformed fractional page sizes', async () => {
  /** @type {number[]} */
  const seen = [];
  const client = {
    query: async (_query, variables) => {
      seen.push(variables.first);
      return {
        takeovers: [],
        furnaceEnterEvents: [],
        shareholderClaimEvents: [],
        shareholderAutoCompoundExecutedEvents: [],
      };
    },
  };

  await getRecentTakeovers(client, '12.5');
  await getRecentFurnaceEnters(client, '12.5');
  await getRecentShareholderClaims(client, '12.5');
  await getRecentShareholderAutoCompounds(client, '12.5');

  assert.deepEqual(seen, [25, 25, 25, 25]);
});

test('tx manager replacement policy ignores malformed fractional overrides', () => {
  const manager = new TxManager({
    publicClient: {},
    address: ADDRESS_ONE,
    replacement: {
      timeoutMs: '1.5',
      pollIntervalMs: '1.5',
      maxAttempts: '2.5',
      feeBumpBps: '12500.5',
    },
  });

  assert.equal(manager.replacement.timeoutMs, DEFAULT_TX_REPLACEMENT_POLICY.timeoutMs);
  assert.equal(manager.replacement.pollIntervalMs, DEFAULT_TX_REPLACEMENT_POLICY.pollIntervalMs);
  assert.equal(manager.replacement.maxAttempts, DEFAULT_TX_REPLACEMENT_POLICY.maxAttempts);
  assert.equal(manager.replacement.feeBumpBps, DEFAULT_TX_REPLACEMENT_POLICY.feeBumpBps);
});

test('semaphore ignores malformed fractional max concurrency', () => {
  assert.equal(new Semaphore(4).maxConcurrency, 4);
  assert.equal(new Semaphore(2.5).maxConcurrency, 1);
});

test('async ttl cache ignores malformed fractional bounds', async () => {
  const cache = new AsyncTtlCache({ maxEntries: 2.5, now: () => 0 });
  cache.set('a', 'one', 100);
  cache.set('b', 'two', 100);
  cache.set('c', 'three', 100);
  assert.equal(cache.size, 3);

  const ttlCache = new AsyncTtlCache({ now: () => 0 });
  ttlCache.set('miss', 'value', 10.5);
  assert.equal(ttlCache.get('miss'), undefined);

  let calls = 0;
  const live = await ttlCache.getOrSet('live', 5.5, async () => {
    calls += 1;
    return 'fresh';
  });
  assert.equal(live, 'fresh');
  assert.equal(calls, 1);
  assert.equal(ttlCache.get('live'), undefined);
});
