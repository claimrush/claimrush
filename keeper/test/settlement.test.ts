import test from 'node:test';
import assert from 'node:assert/strict';

import {
  computeNextWindowMs,
  isWindowOpen,
  isWindowDue,
  cycleIdFromWindowMs,
  openCycle,
  closeCycle,
  isImmediatePhaseComplete,
  markImmediateTaskDone,
  transitionToSpread,
  scheduleBatches,
  shouldPauseBatch,
  markHarvestDone,
  markBatchCompleted,
  isSpreadPhaseComplete,
  getNextDueBatch,
  populateSpreadBatches,
  loadSettlementState,
  IMMEDIATE_TASKS,
} from '../src/run/settlement.js';
import type { SettlementState } from '../src/run/types.js';
import type { KeeperConfig } from '../src/shared/config.js';

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

function makeConfig(overrides: Partial<KeeperConfig> = {}): KeeperConfig {
  return {
    settlementEnabled: true,
    settlementDayUtc: 4,
    settlementHourUtc: 0,
    settlementWindowDurationSecs: 86_400,
    settlementTaskGapSecs: 60,
    settlementRetryWindowSecs: 3_600,
    settlementMaxDriftBps: 100,
    settlementStatePath: '/tmp/test-settlement.json',
    compoundMaxUsersShareholders: 5,
    morningCachePath: '/tmp/test-mornings.json',
    ...overrides,
  } as KeeperConfig;
}

function makeState(nextWindowMs: number): SettlementState {
  return {
    version: 1,
    nextWindowMs,
    current: null,
    pendingPriorityQueue: [],
  };
}

// Thursday 2026-04-23 00:00:00 UTC
const THU_OPEN = Date.UTC(2026, 3, 23, 0, 0, 0);
const WEEK_MS = 7 * 24 * 60 * 60 * 1000;
const DAY_MS = 24 * 60 * 60 * 1000;

// ---------------------------------------------------------------------------
// Window timing
// ---------------------------------------------------------------------------

test('computeNextWindowMs: returns next Thursday 00:00 UTC', () => {
  // Monday 2026-04-20 12:00 UTC
  const mon = Date.UTC(2026, 3, 20, 12, 0, 0);
  const next = computeNextWindowMs(4, 0, mon);
  assert.equal(next, THU_OPEN);
});

test('computeNextWindowMs: if now is exactly the window open, returns next week', () => {
  const next = computeNextWindowMs(4, 0, THU_OPEN);
  assert.equal(next, THU_OPEN + WEEK_MS);
});

test('computeNextWindowMs: if now is past window open on Thursday, returns next week', () => {
  const pastOpen = THU_OPEN + 3_600_000;
  const next = computeNextWindowMs(4, 0, pastOpen);
  assert.equal(next, THU_OPEN + WEEK_MS);
});

test('computeNextWindowMs: respects custom day/hour', () => {
  // Sunday, hour 12 UTC
  const sat = Date.UTC(2026, 3, 18, 0, 0, 0); // Saturday
  const next = computeNextWindowMs(0, 12, sat);
  const expected = Date.UTC(2026, 3, 19, 12, 0, 0); // Sunday 12:00 UTC
  assert.equal(next, expected);
});

test('isWindowOpen: true during window', () => {
  assert.ok(isWindowOpen(THU_OPEN, DAY_MS, THU_OPEN + 1000));
});

test('isWindowOpen: false before window', () => {
  assert.ok(!isWindowOpen(THU_OPEN, DAY_MS, THU_OPEN - 1));
});

test('isWindowOpen: false at window close', () => {
  assert.ok(!isWindowOpen(THU_OPEN, DAY_MS, THU_OPEN + DAY_MS));
});

test('isWindowDue: true when now >= next', () => {
  assert.ok(isWindowDue(THU_OPEN, THU_OPEN));
  assert.ok(isWindowDue(THU_OPEN, THU_OPEN + 1));
});

test('isWindowDue: false when now < next', () => {
  assert.ok(!isWindowDue(THU_OPEN, THU_OPEN - 1));
});

// ---------------------------------------------------------------------------
// Cycle ID determinism
// ---------------------------------------------------------------------------

test('cycleIdFromWindowMs: returns ISO date string', () => {
  assert.equal(cycleIdFromWindowMs(THU_OPEN), '2026-04-23');
});

test('cycleIdFromWindowMs: deterministic across same input', () => {
  const a = cycleIdFromWindowMs(THU_OPEN);
  const b = cycleIdFromWindowMs(THU_OPEN);
  assert.equal(a, b);
});

test('cycleIdFromWindowMs: different for different weeks', () => {
  const a = cycleIdFromWindowMs(THU_OPEN);
  const b = cycleIdFromWindowMs(THU_OPEN + WEEK_MS);
  assert.notEqual(a, b);
});

// ---------------------------------------------------------------------------
// Cycle lifecycle: idempotent restart
// ---------------------------------------------------------------------------

test('openCycle: creates cycle with correct fields', () => {
  const config = makeConfig();
  const state = makeState(THU_OPEN);
  const opened = openCycle(state, THU_OPEN, config);

  assert.ok(opened.current);
  assert.equal(opened.current.cycleId, '2026-04-23');
  assert.equal(opened.current.phase, 'immediate');
  assert.equal(opened.current.windowOpenMs, THU_OPEN);
  assert.equal(opened.current.windowCloseMs, THU_OPEN + DAY_MS);
  assert.deepEqual(opened.current.immediateTasksCompleted, []);
  assert.equal(opened.current.harvestCompleted, false);
});

test('openCycle: carries priority queue from prior cycle', () => {
  const config = makeConfig();
  const state: SettlementState = {
    ...makeState(THU_OPEN),
    pendingPriorityQueue: ['0xAAA', '0xBBB'],
  };
  const opened = openCycle(state, THU_OPEN, config);

  assert.deepEqual(opened.current!.priorityQueue, ['0xAAA', '0xBBB']);
  assert.deepEqual(opened.pendingPriorityQueue, []);
});

test('closeCycle: moves pending users to priority queue', () => {
  const config = makeConfig();
  let state = makeState(THU_OPEN);
  state = openCycle(state, THU_OPEN, config);
  state = transitionToSpread(state);

  state = {
    ...state,
    current: {
      ...state.current!,
      spreadBatchesPending: ['0xCCC', '0xDDD'],
    },
  };

  const closed = closeCycle(state, config, THU_OPEN + DAY_MS);
  assert.equal(closed.current, null);
  assert.deepEqual(closed.pendingPriorityQueue, ['0xCCC', '0xDDD']);
  assert.ok(closed.nextWindowMs > THU_OPEN);
});

// ---------------------------------------------------------------------------
// Immediate phase
// ---------------------------------------------------------------------------

test('isImmediatePhaseComplete: false when tasks remain', () => {
  const config = makeConfig();
  let state = makeState(THU_OPEN);
  state = openCycle(state, THU_OPEN, config);
  assert.ok(!isImmediatePhaseComplete(state.current!));
});

test('isImmediatePhaseComplete: true when all immediate tasks done', () => {
  const config = makeConfig();
  let state = makeState(THU_OPEN);
  state = openCycle(state, THU_OPEN, config);
  for (const t of IMMEDIATE_TASKS) {
    state = markImmediateTaskDone(state, t);
  }
  assert.ok(isImmediatePhaseComplete(state.current!));
});

test('markImmediateTaskDone: idempotent', () => {
  const config = makeConfig();
  let state = makeState(THU_OPEN);
  state = openCycle(state, THU_OPEN, config);
  state = markImmediateTaskDone(state, 'compound-lp');
  state = markImmediateTaskDone(state, 'compound-lp');
  assert.equal(state.current!.immediateTasksCompleted.length, 1);
});

test('transitionToSpread: changes phase', () => {
  const config = makeConfig();
  let state = makeState(THU_OPEN);
  state = openCycle(state, THU_OPEN, config);
  state = transitionToSpread(state);
  assert.equal(state.current!.phase, 'spread');
});

// ---------------------------------------------------------------------------
// Spread phase: batch scheduling
// ---------------------------------------------------------------------------

test('scheduleBatches: splits users into batches', () => {
  const users = ['0x1', '0x2', '0x3', '0x4', '0x5', '0x6', '0x7'];
  const batches = scheduleBatches({
    taskName: 'compound-shareholders',
    users,
    priorityUsers: [],
    windowOpenMs: THU_OPEN,
    windowCloseMs: THU_OPEN + DAY_MS,
    batchSize: 3,
    morningCache: null,
  });

  assert.equal(batches.length, 3); // ceil(7/3)
  assert.equal(batches[0].users.length, 3);
  assert.equal(batches[1].users.length, 3);
  assert.equal(batches[2].users.length, 1);
  assert.ok(batches.every((b) => b.taskName === 'compound-shareholders'));
  assert.ok(batches.every((b) => !b.completed));
});

test('scheduleBatches: priority users placed first', () => {
  const users = ['0x1', '0x2', '0x3', '0x4'];
  const batches = scheduleBatches({
    taskName: 'compound-shareholders',
    users,
    priorityUsers: ['0x3'],
    windowOpenMs: THU_OPEN,
    windowCloseMs: THU_OPEN + DAY_MS,
    batchSize: 2,
    morningCache: null,
  });

  const firstBatchUsers = batches[0].users;
  assert.ok(firstBatchUsers.includes('0x3'));
});

test('scheduleBatches: all times within window', () => {
  const users = Array.from({ length: 20 }, (_, i) => `0x${i.toString(16)}`);
  const batches = scheduleBatches({
    taskName: 'compound-shareholders',
    users,
    priorityUsers: [],
    windowOpenMs: THU_OPEN,
    windowCloseMs: THU_OPEN + DAY_MS,
    batchSize: 5,
    morningCache: null,
  });

  for (const b of batches) {
    assert.ok(b.scheduledAtMs >= THU_OPEN, `batch at ${b.scheduledAtMs} is before window open`);
    assert.ok(
      b.scheduledAtMs < THU_OPEN + DAY_MS,
      `batch at ${b.scheduledAtMs} is after window close`,
    );
  }
});

test('scheduleBatches: empty users returns empty', () => {
  const batches = scheduleBatches({
    taskName: 'compound-shareholders',
    users: [],
    priorityUsers: [],
    windowOpenMs: THU_OPEN,
    windowCloseMs: THU_OPEN + DAY_MS,
    batchSize: 5,
    morningCache: null,
  });
  assert.equal(batches.length, 0);
});

test('scheduleBatches: sorted by scheduledAtMs', () => {
  const users = Array.from({ length: 50 }, (_, i) => `0x${i.toString(16)}`);
  const batches = scheduleBatches({
    taskName: 'compound-shareholders',
    users,
    priorityUsers: [],
    windowOpenMs: THU_OPEN,
    windowCloseMs: THU_OPEN + DAY_MS,
    batchSize: 5,
    morningCache: null,
  });

  for (let i = 1; i < batches.length; i++) {
    assert.ok(batches[i].scheduledAtMs >= batches[i - 1].scheduledAtMs);
  }
});

// ---------------------------------------------------------------------------
// Market-impact gating
// ---------------------------------------------------------------------------

test('shouldPauseBatch: pauses when drift exceeds tolerance', () => {
  assert.ok(shouldPauseBatch(1_000_000n, 10_200, 10_000, 100));
});

test('shouldPauseBatch: allows when drift within tolerance', () => {
  assert.ok(!shouldPauseBatch(1_000_000n, 10_050, 10_000, 100));
});

test('shouldPauseBatch: allows zero input', () => {
  assert.ok(!shouldPauseBatch(0n, 10_500, 10_000, 100));
});

test('shouldPauseBatch: allows when baseline is zero', () => {
  assert.ok(!shouldPauseBatch(1_000_000n, 10_000, 0, 100));
});

test('populateSpreadBatches: sets completed batches and pending users', () => {
  const config = makeConfig();
  let state = makeState(THU_OPEN);
  state = openCycle(state, THU_OPEN, config);
  state = transitionToSpread(state);

  const batches = [
    {
      taskName: 'compound-shareholders',
      users: ['0xA', '0xB'],
      scheduledAtMs: THU_OPEN + 1000,
      completed: false,
    },
    {
      taskName: 'compound-shareholders',
      users: ['0xC'],
      scheduledAtMs: THU_OPEN + 2000,
      completed: false,
    },
  ];
  const pending = batches.flatMap((b) => b.users);
  state = populateSpreadBatches(state, batches, pending);
  assert.deepEqual(state.current!.spreadBatchesCompleted, batches);
  assert.deepEqual(state.current!.spreadBatchesPending, ['0xA', '0xB', '0xC']);
});

test('loadSettlementState: cold start uses provided nowMs for next window', () => {
  const fixed = Date.UTC(2030, 5, 10, 12, 0, 0);
  const config = makeConfig({
    settlementStatePath: '/tmp/claimrush-nonexistent-settlement-state-xyz-12345.json',
  });
  const st = loadSettlementState(config.settlementStatePath, config, fixed);
  assert.equal(st.current, null);
  assert.ok(st.nextWindowMs >= fixed);
});

// ---------------------------------------------------------------------------
// Spread state mutations
// ---------------------------------------------------------------------------

test('markHarvestDone: sets flag', () => {
  const config = makeConfig();
  let state = makeState(THU_OPEN);
  state = openCycle(state, THU_OPEN, config);
  state = transitionToSpread(state);
  state = markHarvestDone(state);
  assert.ok(state.current!.harvestCompleted);
});

test('markBatchCompleted: removes users from pending', () => {
  const config = makeConfig();
  let state = makeState(THU_OPEN);
  state = openCycle(state, THU_OPEN, config);
  state = transitionToSpread(state);

  state = {
    ...state,
    current: {
      ...state.current!,
      spreadBatchesPending: ['0x1', '0x2', '0x3'],
      spreadBatchesCompleted: [
        {
          taskName: 'compound-shareholders',
          users: ['0x1', '0x2'],
          scheduledAtMs: THU_OPEN + 1000,
          completed: false,
        },
        {
          taskName: 'compound-shareholders',
          users: ['0x3'],
          scheduledAtMs: THU_OPEN + 2000,
          completed: false,
        },
      ],
    },
  };

  const doneAt = THU_OPEN + 60_000;
  state = markBatchCompleted(state, 0, ['0x1', '0x2'], doneAt);
  assert.ok(state.current!.spreadBatchesCompleted[0].completed);
  assert.ok(!state.current!.spreadBatchesCompleted[1].completed);
  assert.deepEqual(state.current!.spreadBatchesPending, ['0x3']);
  assert.equal(state.current!.lastAttemptMs, doneAt);
});

test('getNextDueBatch: returns first due uncompleted batch', () => {
  const config = makeConfig();
  let state = makeState(THU_OPEN);
  state = openCycle(state, THU_OPEN, config);
  state = transitionToSpread(state);

  state = {
    ...state,
    current: {
      ...state.current!,
      spreadBatchesCompleted: [
        {
          taskName: 'compound-shareholders',
          users: ['0x1'],
          scheduledAtMs: THU_OPEN + 1000,
          completed: true,
        },
        {
          taskName: 'compound-shareholders',
          users: ['0x2'],
          scheduledAtMs: THU_OPEN + 2000,
          completed: false,
        },
      ],
    },
  };

  const result = getNextDueBatch(state.current!, THU_OPEN + 3000);
  assert.ok(result);
  assert.equal(result.index, 1);
  assert.deepEqual(result.batch.users, ['0x2']);
});

test('getNextDueBatch: returns null when none due yet', () => {
  const config = makeConfig();
  let state = makeState(THU_OPEN);
  state = openCycle(state, THU_OPEN, config);
  state = transitionToSpread(state);

  state = {
    ...state,
    current: {
      ...state.current!,
      spreadBatchesCompleted: [
        {
          taskName: 'compound-shareholders',
          users: ['0x1'],
          scheduledAtMs: THU_OPEN + 100_000,
          completed: false,
        },
      ],
    },
  };

  const result = getNextDueBatch(state.current!, THU_OPEN + 1000);
  assert.equal(result, null);
});

test('isSpreadPhaseComplete: true when all done', () => {
  const config = makeConfig();
  let state = makeState(THU_OPEN);
  state = openCycle(state, THU_OPEN, config);
  state = transitionToSpread(state);
  state = markHarvestDone(state);

  state = {
    ...state,
    current: {
      ...state.current!,
      spreadBatchesCompleted: [
        {
          taskName: 'compound-shareholders',
          users: ['0x1'],
          scheduledAtMs: THU_OPEN + 1000,
          completed: true,
        },
      ],
    },
  };

  assert.ok(isSpreadPhaseComplete(state.current!));
});

test('isSpreadPhaseComplete: false when harvest not done', () => {
  const config = makeConfig();
  let state = makeState(THU_OPEN);
  state = openCycle(state, THU_OPEN, config);
  state = transitionToSpread(state);

  state = {
    ...state,
    current: {
      ...state.current!,
      spreadBatchesCompleted: [
        {
          taskName: 'compound-shareholders',
          users: ['0x1'],
          scheduledAtMs: THU_OPEN + 1000,
          completed: true,
        },
      ],
    },
  };

  assert.ok(!isSpreadPhaseComplete(state.current!));
});

// ---------------------------------------------------------------------------
// Starvation protection: priority inversion across cycles
// ---------------------------------------------------------------------------

test('starvation protection: missed users get priority in next cycle', () => {
  const config = makeConfig();

  // Cycle 1: some users not processed
  let state = makeState(THU_OPEN);
  state = openCycle(state, THU_OPEN, config);
  state = transitionToSpread(state);
  state = {
    ...state,
    current: {
      ...state.current!,
      spreadBatchesPending: ['0xLATE1', '0xLATE2'],
    },
  };

  // Close cycle -- pending become priority
  state = closeCycle(state, config, THU_OPEN + DAY_MS);
  assert.deepEqual(state.pendingPriorityQueue, ['0xLATE1', '0xLATE2']);

  // Cycle 2: priority users are carried into cycle
  state = openCycle(state, THU_OPEN + WEEK_MS, config);
  assert.deepEqual(state.current!.priorityQueue, ['0xLATE1', '0xLATE2']);
  assert.deepEqual(state.pendingPriorityQueue, []);
});
