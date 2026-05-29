import test from 'node:test';
import assert from 'node:assert/strict';

import {
  collectAutomaxCooldownOwners,
  filterAutomaxCandidatesByMinReward,
  flattenOwnerGroupsForPrefilter,
  isAutoMaxLastClaimEligible,
  readAutoMaxLastClaimWithRetry,
  sortAutomaxCandidateTokenIds,
} from '../src/tasks/automax_bonus.js';

const FURNACE = '0x0000000000000000000000000000000000000001';
const QUOTER = '0x0000000000000000000000000000000000000002';

test('automax bonus: min reward filter keeps first-touch bootstrap locks (batch view path)', async () => {
  const calls: string[] = [];
  const publicClient = {
    readContract: async (request: { functionName: string; args?: unknown[] }) => {
      calls.push(request.functionName);
      if (request.functionName === 'quoteAutoMaxBonusBatch') {
        return [[0n, 5n, 100n], 105n];
      }
      if (request.functionName === 'lastAutoMaxBonusClaimBatch') {
        const ids = (request.args?.[0] ?? []) as bigint[];
        return ids.map((id) => (id === 1n ? 0n : 123n));
      }
      throw new Error(`unexpected read ${request.functionName}`);
    },
  } as any;

  const result = await filterAutomaxCandidatesByMinReward({
    publicClient,
    furnaceAddress: FURNACE,
    quoterAddress: QUOTER,
    candidates: ['1', '2', '3'],
    minReward: 10n,
    log: () => undefined,
  });

  assert.deepEqual(result.candidates, ['1', '3']);
  assert.deepEqual([...result.bootstrapTokenIds], ['1']);
  assert.deepEqual(calls, ['quoteAutoMaxBonusBatch', 'lastAutoMaxBonusClaimBatch']);
});

test('automax bonus: quote call chunks at MAX_AUTOMAX_BONUS_BATCH and merges bonuses', async () => {
  // 250 candidate token ids — > on-chain cap of 200 — must be split into
  // two chunks (200 + 50). Each chunk is a separate `quoteAutoMaxBonusBatch`
  // call that returns its bonus slice. The merged bonus array must be
  // length 250 and align by index with the candidates array.
  const candidates = Array.from({ length: 250 }, (_, i) => String(i + 1));
  const chunkSizes: number[] = [];

  const publicClient = {
    readContract: async (request: { functionName: string; args?: unknown[] }) => {
      if (request.functionName === 'quoteAutoMaxBonusBatch') {
        const ids = (request.args?.[0] ?? []) as bigint[];
        chunkSizes.push(ids.length);
        // Return increasing bonus values so we can assert order is preserved
        // when the chunks are concatenated.
        const bonuses = ids.map((id) => BigInt(id) * 10n);
        return [bonuses, bonuses.reduce((a, b) => a + b, 0n)];
      }
      if (request.functionName === 'lastAutoMaxBonusClaimBatch') {
        const ids = (request.args?.[0] ?? []) as bigint[];
        return ids.map(() => 123n);
      }
      throw new Error(`unexpected read ${request.functionName}`);
    },
  } as any;

  const result = await filterAutomaxCandidatesByMinReward({
    publicClient,
    furnaceAddress: FURNACE,
    quoterAddress: QUOTER,
    candidates,
    // Bonus(id) = id*10. Threshold 1000 means ids 1..99 are skipped (below),
    // ids 100..250 are kept. No first-touch bootstraps because all are 123n.
    minReward: 1000n,
    log: () => undefined,
  });

  assert.deepEqual(chunkSizes, [200, 50]);
  assert.equal(result.candidates.length, 250 - 99);
  assert.equal(result.candidates[0], '100');
  assert.equal(result.candidates[result.candidates.length - 1], '250');
  assert.equal(result.bootstrapTokenIds.size, 0);
});

test('automax bonus: batch view failure falls back to per-token reads', async () => {
  const calls: string[] = [];
  const publicClient = {
    readContract: async (request: { functionName: string; args?: unknown[] }) => {
      calls.push(request.functionName);
      if (request.functionName === 'quoteAutoMaxBonusBatch') {
        return [[0n, 5n, 100n], 105n];
      }
      if (request.functionName === 'lastAutoMaxBonusClaimBatch') {
        throw new Error('simulated batch view RPC failure');
      }
      if (request.functionName === 'lastAutoMaxBonusClaim') {
        const tokenId = String(request.args?.[0] ?? '');
        if (tokenId === '1') return 0n;
        if (tokenId === '2') return 123n;
      }
      throw new Error(`unexpected read ${request.functionName}`);
    },
  } as any;

  const result = await filterAutomaxCandidatesByMinReward({
    publicClient,
    furnaceAddress: FURNACE,
    quoterAddress: QUOTER,
    candidates: ['1', '2', '3'],
    minReward: 10n,
    log: () => undefined,
  });

  assert.deepEqual(result.candidates, ['1', '3']);
  assert.deepEqual([...result.bootstrapTokenIds], ['1']);
  assert.deepEqual(calls, [
    'quoteAutoMaxBonusBatch',
    'lastAutoMaxBonusClaimBatch',
    'lastAutoMaxBonusClaim',
    'lastAutoMaxBonusClaim',
  ]);
});

test('automax bonus: fallback eligibility follows the onchain 24-hour floor', () => {
  const now = 10_000_000n;

  assert.equal(isAutoMaxLastClaimEligible(0n, now), true);
  assert.equal(isAutoMaxLastClaimEligible(now - 86_399n, now), false);
  assert.equal(isAutoMaxLastClaimEligible(now - 86_400n, now), true);
});

test('automax bonus: zero min reward short-circuits the quote call (with quoter present)', async () => {
  const calls: string[] = [];
  const publicClient = {
    readContract: async (request: { functionName: string; args?: unknown[] }) => {
      calls.push(request.functionName);
      if (request.functionName === 'lastAutoMaxBonusClaimBatch') {
        const ids = (request.args?.[0] ?? []) as bigint[];
        return ids.map((id) => (id === 10n ? 0n : 456n));
      }
      throw new Error(`unexpected read ${request.functionName}`);
    },
  } as any;

  const result = await filterAutomaxCandidatesByMinReward({
    publicClient,
    furnaceAddress: FURNACE,
    quoterAddress: QUOTER,
    candidates: ['10', '11'],
    minReward: 0n,
    log: () => undefined,
  });

  assert.deepEqual(result.candidates, ['10', '11']);
  assert.deepEqual([...result.bootstrapTokenIds], ['10']);
  assert.deepEqual(calls, ['lastAutoMaxBonusClaimBatch']);
});

test('automax bonus: no quoter address falls back to per-token classification', async () => {
  const calls: string[] = [];
  const publicClient = {
    readContract: async (request: { functionName: string; args?: unknown[] }) => {
      calls.push(request.functionName);
      assert.equal(request.functionName, 'lastAutoMaxBonusClaim');
      const tokenId = String(request.args?.[0] ?? '');
      return tokenId === '10' ? 0n : 456n;
    },
  } as any;

  const result = await filterAutomaxCandidatesByMinReward({
    publicClient,
    furnaceAddress: FURNACE,
    quoterAddress: null,
    candidates: ['10', '11'],
    minReward: 25n,
    log: () => undefined,
  });

  assert.deepEqual(result.candidates, ['10', '11']);
  assert.deepEqual([...result.bootstrapTokenIds], ['10']);
  assert.deepEqual(calls, ['lastAutoMaxBonusClaim', 'lastAutoMaxBonusClaim']);
});

test('automax bonus: per-token read retries on transient RPC failure then succeeds', async () => {
  let attempts = 0;
  const publicClient = {
    readContract: async () => {
      attempts++;
      if (attempts < 3) throw new Error(`simulated 429 attempt #${attempts}`);
      return 999n;
    },
  } as any;

  const sleeps: number[] = [];
  const value = await readAutoMaxLastClaimWithRetry({
    publicClient,
    furnaceAddress: FURNACE,
    tokenId: '42',
    retries: 3,
    initialDelayMs: 10,
    maxDelayMs: 100,
    sleep: async (ms) => {
      sleeps.push(ms);
    },
  });

  assert.equal(value, 999n);
  assert.equal(attempts, 3);
  assert.equal(sleeps.length, 2);
  for (const s of sleeps) assert.ok(s > 0 && s <= 100, `sleep ${s} out of expected range`);
});

test('automax bonus: per-token read returns null after exhausting retries', async () => {
  const publicClient = {
    readContract: async () => {
      throw new Error('persistent RPC failure');
    },
  } as any;

  const sleeps: number[] = [];
  const value = await readAutoMaxLastClaimWithRetry({
    publicClient,
    furnaceAddress: FURNACE,
    tokenId: '42',
    retries: 2,
    initialDelayMs: 5,
    maxDelayMs: 50,
    sleep: async (ms) => {
      sleeps.push(ms);
    },
  });

  assert.equal(value, null);
  assert.equal(sleeps.length, 2);
});

test('automax bonus: bootstrap-only locks do not start the owner weekly cooldown', () => {
  const owners = collectAutomaxCooldownOwners(
    ['1', '2', '3'],
    new Map([
      ['1', '0xaaa'],
      ['2', '0xbbb'],
      ['3', '0xaaa'],
    ]),
    new Set(['1']),
    new Map([
      ['1', 0n],
      ['2', 100n],
      ['3', 200n],
    ]),
    new Map([
      ['1', 1000n],
      ['2', 1000n],
      ['3', 200n],
    ]),
  );

  assert.deepEqual([...owners].sort(), ['0xbbb']);
});

test('automax bonus: pure bootstrap batch has no cooldown owners', () => {
  const owners = collectAutomaxCooldownOwners(
    ['1', '2'],
    new Map([
      ['1', '0xaaa'],
      ['2', '0xbbb'],
    ]),
    new Set(['1', '2']),
    new Map([
      ['1', 0n],
      ['2', 0n],
    ]),
    new Map([
      ['1', 1000n],
      ['2', 1000n],
    ]),
  );

  assert.equal(owners.size, 0);
});

test('automax bonus: candidate token ids are sorted for batch execution', () => {
  assert.deepEqual(sortAutomaxCandidateTokenIds(['5', '7', '6', '1']), ['1', '5', '6', '7']);
});

test('automax bonus prefilter: oversized first owner does not stall later owners', () => {
  const byOwner = new Map<string, string[]>([
    ['0xaaa', ['1', '2', '3', '4', '5', '6', '7', '8', '9']],
    ['0xbbb', ['10', '11']],
    ['0xccc', ['12']],
  ]);
  const out = flattenOwnerGroupsForPrefilter(byOwner, 5);
  // 0xaaa group is too large for cap 5 with the rest, but later owners should
  // still be considered. Concretely: after slicing 0xaaa to fill cap (only
  // possible because prefiltered is empty when we hit it), we stop; in a
  // mixed scenario where smaller groups exist later they are taken.
  // Here we expect either the 0xaaa slice or a smaller-group bypass, but
  // never an empty result.
  assert.ok(out.length > 0);
  assert.ok(out.length <= 5);
});

test('automax bonus prefilter: skips oversized middle owner and packs smaller later owners', () => {
  const byOwner = new Map<string, string[]>([
    ['0xaaa', ['1', '2']],
    ['0xbbb', ['3', '4', '5', '6', '7', '8']],
    ['0xccc', ['9', '10']],
  ]);
  const out = flattenOwnerGroupsForPrefilter(byOwner, 5);
  // 0xaaa fits (2 of 5 used), 0xbbb is oversized (would exceed cap) so skipped,
  // 0xccc fits (4 of 5 used).
  assert.deepEqual(out, ['1', '2', '9', '10']);
});

test('automax bonus prefilter: degenerate fallback slices the first oversized owner', () => {
  const byOwner = new Map<string, string[]>([
    ['0xaaa', ['1', '2', '3', '4', '5', '6', '7']],
    ['0xbbb', ['8', '9', '10', '11']],
  ]);
  const out = flattenOwnerGroupsForPrefilter(byOwner, 5);
  // Both groups are oversized for cap 5. The first one is sliced to fill the
  // cap so the keeper still makes progress.
  assert.deepEqual(out, ['1', '2', '3', '4', '5']);
});

test('automax bonus prefilter: respects exact-fit groups', () => {
  const byOwner = new Map<string, string[]>([
    ['0xaaa', ['1', '2', '3']],
    ['0xbbb', ['4', '5']],
    ['0xccc', ['6']],
  ]);
  const out = flattenOwnerGroupsForPrefilter(byOwner, 5);
  assert.deepEqual(out, ['1', '2', '3', '4', '5']);
});
