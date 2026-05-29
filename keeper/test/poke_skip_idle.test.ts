import test from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';

import { loadJson, saveJsonAtomic } from '../src/shared/state.js';

interface PokeState {
  lastSeenPendingShareholderETH: string;
  lastTakeoverScanBlock: number | null;
  lastLpTickPokeTs: number | null;
  lastProcessedTakeoverReignId: string;
}

function loadPokeState(statePath: string): PokeState {
  const raw = loadJson(statePath, { fallback: null }) as PokeState | null;
  return {
    lastSeenPendingShareholderETH: raw?.lastSeenPendingShareholderETH ?? '0',
    lastTakeoverScanBlock: raw?.lastTakeoverScanBlock ?? null,
    lastLpTickPokeTs: raw?.lastLpTickPokeTs ?? null,
    lastProcessedTakeoverReignId: raw?.lastProcessedTakeoverReignId ?? '0',
  };
}

function savePokeState(statePath: string, state: PokeState): void {
  saveJsonAtomic(statePath, state);
}

function shouldSkipPoke({
  pendingShareholderETH,
  lastSeenPendingShareholderETH,
  lpRemaining,
  lpPeriodFinish,
  blockTimestamp,
  globalLastTs,
  pokeStaleThresholdSecs,
  pokeLpTickIntervalSecs,
  lastLpTickPokeTs,
  hasOffers,
}: {
  pendingShareholderETH: bigint;
  lastSeenPendingShareholderETH: bigint;
  lpRemaining: bigint;
  lpPeriodFinish: bigint;
  blockTimestamp: bigint;
  globalLastTs: bigint;
  pokeStaleThresholdSecs: number;
  pokeLpTickIntervalSecs: number;
  lastLpTickPokeTs: number | null;
  hasOffers: boolean;
}): { skip: boolean; reasons: string[] } {
  if (hasOffers) return { skip: false, reasons: ['has offers'] };

  const reasons: string[] = [];

  if (pendingShareholderETH > lastSeenPendingShareholderETH) {
    reasons.push('pendingShareholderETH increased');
  }

  const lpStreamActive = lpRemaining > 0n && blockTimestamp < lpPeriodFinish;
  if (lpStreamActive) {
    const lastTickTs = lastLpTickPokeTs ?? 0;
    const elapsed = Number(blockTimestamp) - lastTickTs;
    if (elapsed >= pokeLpTickIntervalSecs) {
      reasons.push('lpStream tick due');
    }
  }

  if (globalLastTs > 0n && blockTimestamp - globalLastTs > BigInt(pokeStaleThresholdSecs)) {
    reasons.push('veCheckpoint stale');
  }

  return { skip: reasons.length === 0, reasons };
}

test('poke state: round-trip through load/save', () => {
  const tmpDir = fs.mkdtempSync(path.join(os.tmpdir(), 'claimrush-poke-'));
  const statePath = path.join(tmpDir, 'poke.json');

  try {
    const initial = loadPokeState(statePath);
    assert.equal(initial.lastSeenPendingShareholderETH, '0');
    assert.equal(initial.lastTakeoverScanBlock, null);
    assert.equal(initial.lastLpTickPokeTs, null);
    assert.equal(initial.lastProcessedTakeoverReignId, '0');

    savePokeState(statePath, {
      lastSeenPendingShareholderETH: '12345',
      lastTakeoverScanBlock: 100,
      lastLpTickPokeTs: 500,
      lastProcessedTakeoverReignId: '42',
    });
    const loaded = loadPokeState(statePath);
    assert.equal(loaded.lastSeenPendingShareholderETH, '12345');
    assert.equal(loaded.lastTakeoverScanBlock, 100);
    assert.equal(loaded.lastLpTickPokeTs, 500);
    assert.equal(loaded.lastProcessedTakeoverReignId, '42');

    savePokeState(statePath, {
      lastSeenPendingShareholderETH: '999999999999999',
      lastTakeoverScanBlock: 200,
      lastLpTickPokeTs: 1000,
      lastProcessedTakeoverReignId: '99',
    });
    const loaded2 = loadPokeState(statePath);
    assert.equal(loaded2.lastSeenPendingShareholderETH, '999999999999999');
    assert.equal(loaded2.lastTakeoverScanBlock, 200);
    assert.equal(loaded2.lastLpTickPokeTs, 1000);
    assert.equal(loaded2.lastProcessedTakeoverReignId, '99');
  } finally {
    fs.rmSync(tmpDir, { recursive: true, force: true });
  }
});

test('poke state: missing file returns defaults', () => {
  const tmpDir = fs.mkdtempSync(path.join(os.tmpdir(), 'claimrush-poke-'));
  const statePath = path.join(tmpDir, 'nonexistent.json');

  try {
    const state = loadPokeState(statePath);
    assert.equal(state.lastSeenPendingShareholderETH, '0');
  } finally {
    fs.rmSync(tmpDir, { recursive: true, force: true });
  }
});

test('poke state: oversized file falls back to defaults', () => {
  const tmpDir = fs.mkdtempSync(path.join(os.tmpdir(), 'claimrush-poke-'));
  const statePath = path.join(tmpDir, 'oversized.json');

  try {
    fs.writeFileSync(statePath, 'x'.repeat(1024 * 1024 + 1), 'utf8');
    const state = loadPokeState(statePath);
    assert.equal(state.lastSeenPendingShareholderETH, '0');
    assert.equal(state.lastTakeoverScanBlock, null);
    assert.equal(state.lastLpTickPokeTs, null);
    assert.equal(state.lastProcessedTakeoverReignId, '0');
  } finally {
    fs.rmSync(tmpDir, { recursive: true, force: true });
  }
});

test('skip-if-idle: skips when nothing has changed', () => {
  const result = shouldSkipPoke({
    pendingShareholderETH: 100n,
    lastSeenPendingShareholderETH: 100n,
    lpRemaining: 0n,
    lpPeriodFinish: 0n,
    blockTimestamp: 1000n,
    globalLastTs: 500n,
    pokeStaleThresholdSecs: 900,
    pokeLpTickIntervalSecs: 300,
    lastLpTickPokeTs: null,
    hasOffers: false,
  });
  assert.equal(result.skip, true);
  assert.equal(result.reasons.length, 0);
});

test('skip-if-idle: pokes when pendingShareholderETH increases', () => {
  const result = shouldSkipPoke({
    pendingShareholderETH: 200n,
    lastSeenPendingShareholderETH: 100n,
    lpRemaining: 0n,
    lpPeriodFinish: 0n,
    blockTimestamp: 1000n,
    globalLastTs: 500n,
    pokeStaleThresholdSecs: 900,
    pokeLpTickIntervalSecs: 300,
    lastLpTickPokeTs: null,
    hasOffers: false,
  });
  assert.equal(result.skip, false);
  assert.ok(result.reasons.includes('pendingShareholderETH increased'));
});

test('skip-if-idle: does NOT poke when pendingShareholderETH decreases (flushed)', () => {
  const result = shouldSkipPoke({
    pendingShareholderETH: 50n,
    lastSeenPendingShareholderETH: 100n,
    lpRemaining: 0n,
    lpPeriodFinish: 0n,
    blockTimestamp: 1000n,
    globalLastTs: 500n,
    pokeStaleThresholdSecs: 900,
    pokeLpTickIntervalSecs: 300,
    lastLpTickPokeTs: null,
    hasOffers: false,
  });
  assert.equal(result.skip, true);
});

test('skip-if-idle: pokes when LP stream is active and tick interval elapsed', () => {
  const result = shouldSkipPoke({
    pendingShareholderETH: 100n,
    lastSeenPendingShareholderETH: 100n,
    lpRemaining: 5000n,
    lpPeriodFinish: 2000n,
    blockTimestamp: 1000n,
    globalLastTs: 500n,
    pokeStaleThresholdSecs: 900,
    pokeLpTickIntervalSecs: 300,
    lastLpTickPokeTs: 600,
    hasOffers: false,
  });
  assert.equal(result.skip, false);
  assert.ok(result.reasons.includes('lpStream tick due'));
});

test('skip-if-idle: skips LP stream poke when tick interval not yet elapsed', () => {
  const result = shouldSkipPoke({
    pendingShareholderETH: 100n,
    lastSeenPendingShareholderETH: 100n,
    lpRemaining: 5000n,
    lpPeriodFinish: 2000n,
    blockTimestamp: 1000n,
    globalLastTs: 500n,
    pokeStaleThresholdSecs: 900,
    pokeLpTickIntervalSecs: 300,
    lastLpTickPokeTs: 800,
    hasOffers: false,
  });
  assert.equal(result.skip, true);
});

test('skip-if-idle: LP stream active with null lastLpTickPokeTs always triggers', () => {
  const result = shouldSkipPoke({
    pendingShareholderETH: 100n,
    lastSeenPendingShareholderETH: 100n,
    lpRemaining: 5000n,
    lpPeriodFinish: 2000n,
    blockTimestamp: 1000n,
    globalLastTs: 500n,
    pokeStaleThresholdSecs: 900,
    pokeLpTickIntervalSecs: 300,
    lastLpTickPokeTs: null,
    hasOffers: false,
  });
  assert.equal(result.skip, false);
  assert.ok(result.reasons.includes('lpStream tick due'));
});

test('skip-if-idle: skips when LP stream is expired', () => {
  const result = shouldSkipPoke({
    pendingShareholderETH: 100n,
    lastSeenPendingShareholderETH: 100n,
    lpRemaining: 5000n,
    lpPeriodFinish: 900n,
    blockTimestamp: 1000n,
    globalLastTs: 500n,
    pokeStaleThresholdSecs: 900,
    pokeLpTickIntervalSecs: 300,
    lastLpTickPokeTs: null,
    hasOffers: false,
  });
  assert.equal(result.skip, true);
});

test('skip-if-idle: pokes when veCheckpoint is stale', () => {
  const result = shouldSkipPoke({
    pendingShareholderETH: 100n,
    lastSeenPendingShareholderETH: 100n,
    lpRemaining: 0n,
    lpPeriodFinish: 0n,
    blockTimestamp: 2000n,
    globalLastTs: 100n,
    pokeStaleThresholdSecs: 900,
    pokeLpTickIntervalSecs: 300,
    lastLpTickPokeTs: null,
    hasOffers: false,
  });
  assert.equal(result.skip, false);
  assert.ok(result.reasons.includes('veCheckpoint stale'));
});

test('skip-if-idle: pokes when there are offers (short-circuit)', () => {
  const result = shouldSkipPoke({
    pendingShareholderETH: 100n,
    lastSeenPendingShareholderETH: 100n,
    lpRemaining: 0n,
    lpPeriodFinish: 0n,
    blockTimestamp: 1000n,
    globalLastTs: 500n,
    pokeStaleThresholdSecs: 900,
    pokeLpTickIntervalSecs: 300,
    lastLpTickPokeTs: null,
    hasOffers: true,
  });
  assert.equal(result.skip, false);
  assert.ok(result.reasons.includes('has offers'));
});

test('skip-if-idle: multiple reasons combined', () => {
  const result = shouldSkipPoke({
    pendingShareholderETH: 200n,
    lastSeenPendingShareholderETH: 100n,
    lpRemaining: 5000n,
    lpPeriodFinish: 3000n,
    blockTimestamp: 2000n,
    globalLastTs: 100n,
    pokeStaleThresholdSecs: 900,
    pokeLpTickIntervalSecs: 300,
    lastLpTickPokeTs: null,
    hasOffers: false,
  });
  assert.equal(result.skip, false);
  assert.equal(result.reasons.length, 3);
});

test('skip-if-idle: globalLastTs=0 does not trigger stale (uninitialized)', () => {
  const result = shouldSkipPoke({
    pendingShareholderETH: 100n,
    lastSeenPendingShareholderETH: 100n,
    lpRemaining: 0n,
    lpPeriodFinish: 0n,
    blockTimestamp: 2000n,
    globalLastTs: 0n,
    pokeStaleThresholdSecs: 900,
    pokeLpTickIntervalSecs: 300,
    lastLpTickPokeTs: null,
    hasOffers: false,
  });
  assert.equal(result.skip, true);
});
