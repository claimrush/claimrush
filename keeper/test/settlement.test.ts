import test from 'node:test';
import assert from 'node:assert/strict';
import { writeFileSync, rmSync } from 'node:fs';

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
    // Default the test fixture to weekly so the existing Thursday-anchored
    // assertions act as a regression guard for the flip-back-to-weekly path.
    settlementPeriodSecs: 604_800,
    settlementDayUtc: 4,
    settlementHourUtc: 0,
    settlementWindowDurationSecs: 86_400,
    settlementTaskGapSecs: 60,
    settlementRetryWindowSecs: 3_600,
    settlementMaxDriftBps: 100,
    settlementStatePath: '/tmp/test-settlement.json',
    compoundShareholderMinCadenceSecs: 604_800,
    compoundLpMinCadenceSecs: 604_800,
    automaxOwnerCooldownSecs: 604_800,
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
const WEEK_SECS = 7 * 24 * 60 * 60;
const DAY_SECS = 24 * 60 * 60;

// ---------------------------------------------------------------------------
// Window timing — weekly cadence (regression guard for flip-back-to-weekly)
// ---------------------------------------------------------------------------

test('computeNextWindowMs (weekly): returns next Thursday 00:00 UTC', () => {
  // Monday 2026-04-20 12:00 UTC
  const mon = Date.UTC(2026, 3, 20, 12, 0, 0);
  const next = computeNextWindowMs(WEEK_SECS, 4, 0, mon);
  assert.equal(next, THU_OPEN);
});

test('computeNextWindowMs (weekly): if now is exactly the window open, returns next week', () => {
  const next = computeNextWindowMs(WEEK_SECS, 4, 0, THU_OPEN);
  assert.equal(next, THU_OPEN + WEEK_MS);
});

test('computeNextWindowMs (weekly): if now is past window open on Thursday, returns next week', () => {
  const pastOpen = THU_OPEN + 3_600_000;
  const next = computeNextWindowMs(WEEK_SECS, 4, 0, pastOpen);
  assert.equal(next, THU_OPEN + WEEK_MS);
});

test('computeNextWindowMs (weekly): respects custom day/hour', () => {
  // Sunday, hour 12 UTC
  const sat = Date.UTC(2026, 3, 18, 0, 0, 0); // Saturday
  const next = computeNextWindowMs(WEEK_SECS, 0, 12, sat);
  const expected = Date.UTC(2026, 3, 19, 12, 0, 0); // Sunday 12:00 UTC
  assert.equal(next, expected);
});

// ---------------------------------------------------------------------------
// Window timing — daily cadence (default)
// ---------------------------------------------------------------------------

test('computeNextWindowMs (daily): returns today at the anchor hour when still ahead', () => {
  // Monday 2026-04-20 09:00 UTC, anchor hour 12 -> same day 12:00
  const mon0900 = Date.UTC(2026, 3, 20, 9, 0, 0);
  const next = computeNextWindowMs(DAY_SECS, 4, 12, mon0900);
  assert.equal(next, Date.UTC(2026, 3, 20, 12, 0, 0));
});

test('computeNextWindowMs (daily): rolls to next day when anchor hour has passed', () => {
  // Monday 2026-04-20 13:00 UTC, anchor hour 12 -> next day 12:00
  const mon1300 = Date.UTC(2026, 3, 20, 13, 0, 0);
  const next = computeNextWindowMs(DAY_SECS, 4, 12, mon1300);
  assert.equal(next, Date.UTC(2026, 3, 21, 12, 0, 0));
});

test('computeNextWindowMs (daily): ignores day-of-week anchor', () => {
  // dayOfWeek argument (4=Thu) must not affect a daily period
  const tue = Date.UTC(2026, 3, 21, 1, 0, 0); // Tuesday 01:00
  const next = computeNextWindowMs(DAY_SECS, 4, 0, tue);
  assert.equal(next, Date.UTC(2026, 3, 22, 0, 0, 0)); // Wednesday 00:00, not Thursday
});

test('computeNextWindowMs (daily): exact anchor instant rolls to next day', () => {
  const anchor = Date.UTC(2026, 3, 20, 0, 0, 0);
  const next = computeNextWindowMs(DAY_SECS, 4, 0, anchor);
  assert.equal(next, anchor + DAY_MS);
});

test('computeNextWindowMs: daily config advances by one day in closeCycle', () => {
  const config = makeConfig({ settlementPeriodSecs: DAY_SECS });
  const state = makeState(THU_OPEN);
  const opened = openCycle(state, THU_OPEN, config);
  // Close partway through the cycle; next window is the following day's anchor.
  const closed = closeCycle(opened, config, THU_OPEN + 3_600_000);
  assert.equal(closed.nextWindowMs, THU_OPEN + DAY_MS);
});

test('closeCycle (daily, window == period): reopens back-to-back, never skips a day', () => {
  // Default daily config: 24h window inside a 24h period. The real close fires
  // an instant after windowCloseMs (== the next daily anchor). The next window
  // must be exactly that anchor (immediately due), NOT a day later.
  const config = makeConfig({
    settlementPeriodSecs: DAY_SECS,
    settlementWindowDurationSecs: DAY_SECS,
  });
  const state = makeState(THU_OPEN);
  const opened = openCycle(state, THU_OPEN, config);
  assert.equal(opened.current!.windowCloseMs, THU_OPEN + DAY_MS);
  // Daemon detects close one tick (5s) after windowCloseMs.
  const closeNow = THU_OPEN + DAY_MS + 5_000;
  const closed = closeCycle(opened, config, closeNow);
  assert.equal(closed.nextWindowMs, THU_OPEN + DAY_MS);
  // ...and it is immediately due, so the next cycle opens this same tick.
  assert.ok(closed.nextWindowMs <= closeNow);
});

test('closeCycle (weekly): next window is exactly one week after open', () => {
  const config = makeConfig(); // weekly default
  const state = makeState(THU_OPEN);
  const opened = openCycle(state, THU_OPEN, config);
  // Close ~24h after open (Friday), as the weekly 24h window does.
  const closed = closeCycle(opened, config, THU_OPEN + DAY_MS + 5_000);
  assert.equal(closed.nextWindowMs, THU_OPEN + WEEK_MS);
});

test('closeCycle (weekly, window < period): long downtime in the quiet gap schedules the next boundary, not a stale window', () => {
  // Weekly: 24h window inside a 7d period. Keeper opened the Thu window, then
  // was down for ~10 days. On close it must schedule the NEXT Thursday boundary
  // strictly in the future — not re-open a Thursday window whose 24h span has
  // already fully elapsed (we're deep in the quiet gap).
  const config = makeConfig({ settlementWindowDurationSecs: DAY_SECS }); // weekly default + 24h window
  const state = makeState(THU_OPEN);
  const opened = openCycle(state, THU_OPEN, config);
  const now = THU_OPEN + 10 * DAY_MS; // Thu+10d, mid-gap (next Thu is +14d... wait +7d already passed)
  const closed = closeCycle(opened, config, now);
  // Boundaries are THU+7d (window THU+7d..+8d, already elapsed at +10d) and
  // THU+14d. Must pick THU+14d (strictly future), never THU+7d.
  assert.equal(closed.nextWindowMs, THU_OPEN + 14 * DAY_MS);
  assert.ok(closed.nextWindowMs > now);
});

test('closeCycle (weekly, window < period): downtime while still inside a window opens it', () => {
  // Same config, but now we land at Thu+7d+12h — still inside the THU+7d
  // window's 24h span, so that window should be the next to open.
  const config = makeConfig({ settlementWindowDurationSecs: DAY_SECS });
  const state = makeState(THU_OPEN);
  const opened = openCycle(state, THU_OPEN, config);
  const now = THU_OPEN + 7 * DAY_MS + DAY_MS / 2; // 12h into the THU+7d window
  const closed = closeCycle(opened, config, now);
  assert.equal(closed.nextWindowMs, THU_OPEN + 7 * DAY_MS);
  assert.ok(closed.nextWindowMs <= now); // immediately due → opens this tick
});

test('closeCycle (daily): catches up after long downtime without replaying every cycle', () => {
  const config = makeConfig({ settlementPeriodSecs: DAY_SECS });
  const state = makeState(THU_OPEN);
  const opened = openCycle(state, THU_OPEN, config);
  // Daemon was down ~3.5 days. Next window should be the most recent past
  // boundary that is still <= now (so it opens once immediately), i.e. +3 days.
  const closed = closeCycle(opened, config, THU_OPEN + 3 * DAY_MS + DAY_MS / 2);
  assert.equal(closed.nextWindowMs, THU_OPEN + 3 * DAY_MS);
  assert.ok(closed.nextWindowMs <= THU_OPEN + 3 * DAY_MS + DAY_MS / 2);
  assert.ok(closed.nextWindowMs + DAY_MS > THU_OPEN + 3 * DAY_MS + DAY_MS / 2);
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

test('loadSettlementState: re-anchors a stale weekly window after flipping to daily', () => {
  // Simulates the cutover: a persisted weekly schedule (next window = a Thursday
  // several days out) is loaded under a daily config. The first daily window
  // must be the next 00:00 boundary, not the stale Thursday.
  const path = '/tmp/claimrush-settlement-reanchor-test.json';
  const now = Date.UTC(2026, 5, 2, 9, 0, 0); // Tue 2026-06-02 09:00 UTC
  const staleThursday = Date.UTC(2026, 5, 4, 0, 0, 0); // Thu 2026-06-04 00:00 UTC
  writeFileSync(
    path,
    JSON.stringify({
      version: 1,
      nextWindowMs: staleThursday,
      current: null,
      pendingPriorityQueue: [],
    }),
  );
  try {
    const config = makeConfig({ settlementPeriodSecs: DAY_SECS, settlementStatePath: path });
    const st = loadSettlementState(path, config, now);
    assert.equal(st.current, null);
    // Next 00:00 UTC after now = Wed 2026-06-03 00:00 UTC, well before the Thursday.
    assert.equal(st.nextWindowMs, Date.UTC(2026, 5, 3, 0, 0, 0));
    assert.ok(st.nextWindowMs < staleThursday);
  } finally {
    rmSync(path, { force: true });
  }
});

test('loadSettlementState: does NOT re-anchor under stable cadence or mid-cycle', () => {
  const path = '/tmp/claimrush-settlement-noreanchor-test.json';
  const now = Date.UTC(2026, 5, 2, 9, 0, 0);
  // Stable weekly: next window within one period → keep as persisted.
  const nextThu = Date.UTC(2026, 5, 4, 0, 0, 0);
  writeFileSync(
    path,
    JSON.stringify({ version: 1, nextWindowMs: nextThu, current: null, pendingPriorityQueue: [] }),
  );
  try {
    const weekly = makeConfig({ settlementStatePath: path }); // weekly default
    assert.equal(loadSettlementState(path, weekly, now).nextWindowMs, nextThu);

    // Missed window (nextWindowMs <= now) must remain for immediate catch-up.
    const missed = Date.UTC(2026, 5, 1, 0, 0, 0);
    writeFileSync(
      path,
      JSON.stringify({ version: 1, nextWindowMs: missed, current: null, pendingPriorityQueue: [] }),
    );
    const daily = makeConfig({ settlementPeriodSecs: DAY_SECS, settlementStatePath: path });
    assert.equal(loadSettlementState(path, daily, now).nextWindowMs, missed);

    // Mid-cycle (current != null) is never re-anchored even if far out.
    const far = Date.UTC(2026, 5, 20, 0, 0, 0);
    writeFileSync(
      path,
      JSON.stringify({
        version: 1,
        nextWindowMs: far,
        current: {
          cycleId: '2026-05-20',
          windowOpenMs: far,
          windowCloseMs: far + DAY_MS,
          phase: 'immediate',
          immediateTasksCompleted: [],
          harvestCompleted: false,
          spreadBatchesCompleted: [],
          spreadBatchesPending: [],
          priorityQueue: [],
          failedTasks: [],
          attemptCount: 0,
          lastAttemptMs: far,
        },
        pendingPriorityQueue: [],
      }),
    );
    assert.equal(loadSettlementState(path, daily, now).nextWindowMs, far);
  } finally {
    rmSync(path, { force: true });
  }
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
