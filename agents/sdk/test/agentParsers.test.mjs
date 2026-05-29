import test from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';

import { parsePlan, startAgentMonitor } from '../dist/src/index.js';
import { EventCursor } from '../dist/src/agent/eventCursor.js';

const HASH_ONE = `0x${'1'.repeat(64)}`;
const HASH_TWO = `0x${'2'.repeat(64)}`;
const ADDRESS_ONE = '0x0000000000000000000000000000000000000001';
const ADDRESS_TWO = '0x0000000000000000000000000000000000000002';

function makeTempDir(prefix) {
  return fs.mkdtempSync(path.join(os.tmpdir(), prefix));
}

test('agent cursor ignores malformed persisted chainId and strict-fallbacks malformed maxRecentKeys', async () => {
  const dir = makeTempDir('claimrush-agent-cursor-');
  const fp = path.join(dir, 'event-cursor.json');

  fs.writeFileSync(
    fp,
    JSON.stringify({
      version: 1,
      chainId: '8453.5',
      rewindBlocks: '5',
      lastProcessedBlock: '99',
      recentKeys: ['stale-key'],
    }),
  );

  const cursor = EventCursor.load({
    filePath: fp,
    chainId: 8453,
    rewindBlocks: 5n,
    maxRecentKeys: '1.5',
  });

  assert.equal(cursor.snapshot().recentKeyCount, 0);

  const publicClient = {
    async getBlock({ blockNumber }) {
      const hex = blockNumber.toString(16).padStart(64, '0');
      return { hash: `0x${hex}` };
    },
  };

  await cursor.recordProcessedEvent(
    {
      contract: 'MineCore',
      address: ADDRESS_ONE,
      event: 'Takeover',
      args: {},
      blockNumber: 1n,
      transactionHash: HASH_ONE,
      logIndex: 0,
      source: 'rpc',
    },
    publicClient,
  );

  await cursor.recordProcessedEvent(
    {
      contract: 'MineCore',
      address: ADDRESS_ONE,
      event: 'Takeover',
      args: {},
      blockNumber: 2n,
      transactionHash: HASH_TWO,
      logIndex: 0,
      source: 'rpc',
    },
    publicClient,
  );

  assert.equal(cursor.snapshot().recentKeyCount, 2);
});

test('parsePlan rejects fractional claim-all helper modes', () => {
  const planText = JSON.stringify({
    version: 'agentPlan.v1',
    chain: 'base_mainnet',
    chainId: 8453,
    blockNumber: '1',
    blockTimestamp: '2',
    agent: ADDRESS_ONE,
    actions: [
      {
        kind: 'claimAllHelper.claimAllFor',
        user: ADDRESS_TWO,
        claimable: '1',
        mode: 1.5,
        targetTokenId: '0',
        durationSeconds: '0',
        createAutoMax: false,
        minVeOut: '0',
      },
    ],
  });

  assert.throws(
    () => parsePlan(planText),
    /claimAllHelper\.claimAllFor\.mode: expected non-negative safe integer/,
  );
});

test('agent monitor ignores malformed recent limit query params', async () => {
  const monitor = await startAgentMonitor({
    host: '127.0.0.1',
    port: 0,
    maxRecent: '3.5',
    meta: {
      chain: 'base_mainnet',
      chainId: 8453,
      agent: ADDRESS_ONE,
      user: ADDRESS_ONE,
      delegated: false,
      execute: false,
    },
  });

  try {
    monitor.onPlan({
      chain: 'base_mainnet',
      chainId: 8453,
      blockNumber: 1n,
      blockTimestamp: 1n,
      agent: ADDRESS_ONE,
      actions: [{ kind: 'mineCore.withdrawKingBalance', amount: 1n }],
    });
    monitor.onPlan({
      chain: 'base_mainnet',
      chainId: 8453,
      blockNumber: 2n,
      blockTimestamp: 2n,
      agent: ADDRESS_ONE,
      actions: [{ kind: 'mineCore.withdrawKingBalance', amount: 2n }],
    });
    monitor.onPlan({
      chain: 'base_mainnet',
      chainId: 8453,
      blockNumber: 3n,
      blockTimestamp: 3n,
      agent: ADDRESS_ONE,
      actions: [{ kind: 'mineCore.withdrawKingBalance', amount: 3n }],
    });

    const port = monitor.server.address().port;
    const invalidLimitRes = await fetch(`http://127.0.0.1:${port}/recent/plans?limit=1.5`);
    const invalidLimitJson = await invalidLimitRes.json();
    assert.equal(invalidLimitRes.status, 200);
    assert.equal(invalidLimitJson.items.length, 3);

    const strictLimitRes = await fetch(`http://127.0.0.1:${port}/recent/plans?limit=2`);
    const strictLimitJson = await strictLimitRes.json();
    assert.equal(strictLimitRes.status, 200);
    assert.equal(strictLimitJson.items.length, 2);
  } finally {
    await monitor.close();
  }
});
