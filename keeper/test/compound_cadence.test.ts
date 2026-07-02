import test from 'node:test';
import assert from 'node:assert/strict';

import { inCompoundCooldown } from '../src/tasks/compound_lp.js';
import {
  effectiveShareholderCadenceSeconds,
  shareholderSpreadJitterSeconds,
} from '../src/tasks/compound_shareholders.js';

const DAY_MS = 24 * 60 * 60 * 1000;
const WEEK_MS = 7 * DAY_MS;
const DAY_SECS = 24 * 60 * 60;
const WEEK_SECS = 7 * DAY_SECS;

function lpStateWith(
  user: string,
  lastCompoundedMs: number,
): Parameters<typeof inCompoundCooldown>[0] {
  return {
    version: 1,
    lastScannedBlock: '0',
    users: [user],
    cursor: 0,
    failures: {},
    lastCompounded: { [user.toLowerCase()]: new Date(lastCompoundedMs).toISOString() },
  };
}

// ---------------------------------------------------------------------------
// LP per-user cooldown (period-driven)
// ---------------------------------------------------------------------------

test('inCompoundCooldown (daily): user compounded < 1 day ago is in cooldown', () => {
  const user = '0xAbC0000000000000000000000000000000000001';
  const state = lpStateWith(user, Date.now() - 23 * 60 * 60 * 1000); // 23h ago
  assert.equal(inCompoundCooldown(state, user, DAY_MS), true);
});

test('inCompoundCooldown (daily): user compounded > 1 day ago is eligible', () => {
  const user = '0xAbC0000000000000000000000000000000000001';
  const state = lpStateWith(user, Date.now() - 25 * 60 * 60 * 1000); // 25h ago
  assert.equal(inCompoundCooldown(state, user, DAY_MS), false);
});

test('inCompoundCooldown (weekly): same 25h-old entry is still in cooldown under weekly period', () => {
  const user = '0xAbC0000000000000000000000000000000000001';
  const state = lpStateWith(user, Date.now() - 25 * 60 * 60 * 1000); // 25h ago
  assert.equal(inCompoundCooldown(state, user, WEEK_MS), true);
});

test('inCompoundCooldown: never-compounded user is not in cooldown', () => {
  const user = '0xAbC0000000000000000000000000000000000002';
  const state = {
    version: 1,
    lastScannedBlock: '0',
    users: [user],
    cursor: 0,
    failures: {},
    lastCompounded: {},
  };
  assert.equal(inCompoundCooldown(state, user, DAY_MS), false);
});

test('inCompoundCooldown: malformed timestamp fails open (not in cooldown)', () => {
  const user = '0xAbC0000000000000000000000000000000000003';
  const state = {
    version: 1,
    lastScannedBlock: '0',
    users: [user],
    cursor: 0,
    failures: {},
    lastCompounded: { [user.toLowerCase()]: 'not-a-date' },
  };
  assert.equal(inCompoundCooldown(state, user, DAY_MS), false);
});

// ---------------------------------------------------------------------------
// Shareholder effective cadence (period-driven floor vs user choice)
// ---------------------------------------------------------------------------

test('effectiveShareholderCadenceSeconds: keeper floor applies when user cadence is lower', () => {
  // Daily keeper floor, user configured 6h -> floor wins.
  assert.equal(effectiveShareholderCadenceSeconds(DAY_SECS, 6 * 60 * 60), DAY_SECS);
});

test('effectiveShareholderCadenceSeconds: user choice wins when longer than floor', () => {
  // Daily keeper floor, user configured weekly -> user wins.
  assert.equal(effectiveShareholderCadenceSeconds(DAY_SECS, WEEK_SECS), WEEK_SECS);
});

test('effectiveShareholderCadenceSeconds: weekly floor reproduces weekly cadence', () => {
  // Flip-back-to-weekly: floor 7d, user 6h -> weekly wins.
  assert.equal(effectiveShareholderCadenceSeconds(WEEK_SECS, 6 * 60 * 60), WEEK_SECS);
});

test('effectiveShareholderCadenceSeconds: 24h+5min floor clears the on-chain 24h limit', () => {
  // Prod cadence: a per-user keeper floor of 24h+5min sits just above the
  // on-chain 24h `minCadenceSeconds`, so the keeper only attempts once the
  // contract will accept it (no wasted on-chain CadenceNotMet skip), holding a
  // ~daily cadence instead of drifting to every other day.
  const FLOOR_24H_5M = 24 * 60 * 60 + 5 * 60; // 86700
  assert.equal(effectiveShareholderCadenceSeconds(FLOOR_24H_5M, DAY_SECS), FLOOR_24H_5M);
  assert.ok(FLOOR_24H_5M > DAY_SECS);
});

// ---------------------------------------------------------------------------
// Per-user spread jitter (fan synchronized users across the day)
// ---------------------------------------------------------------------------

const SPREAD = 6 * 60 * 60; // 6h

test('shareholderSpreadJitterSeconds: 0 spread disables jitter', () => {
  const user = '0xAbC0000000000000000000000000000000000001';
  assert.equal(shareholderSpreadJitterSeconds(user, 1000n, 0), 0);
  assert.equal(shareholderSpreadJitterSeconds(user, 1000n, -5), 0);
});

test('shareholderSpreadJitterSeconds: result is within [0, spread)', () => {
  for (let i = 0; i < 50; i++) {
    const user = `0xAbC00000000000000000000000000000000000${i.toString(16).padStart(2, '0')}`;
    const j = shareholderSpreadJitterSeconds(user, 1_700_000_000n, SPREAD);
    assert.ok(j >= 0 && j < SPREAD, `jitter ${j} out of range for ${user}`);
  }
});

test('shareholderSpreadJitterSeconds: deterministic for the same (user, lastCompoundTs)', () => {
  const user = '0xAbC0000000000000000000000000000000000009';
  const a = shareholderSpreadJitterSeconds(user, 1_700_000_000n, SPREAD);
  const b = shareholderSpreadJitterSeconds(user, 1_700_000_000n, SPREAD);
  assert.equal(a, b);
});

test('shareholderSpreadJitterSeconds: re-randomizes after a new compound (different lastCompoundTs)', () => {
  const user = '0xAbC000000000000000000000000000000000000a';
  const a = shareholderSpreadJitterSeconds(user, 1_700_000_000n, SPREAD);
  const b = shareholderSpreadJitterSeconds(user, 1_700_086_700n, SPREAD);
  // Not guaranteed different in theory, but must differ for these fixtures so
  // the day-to-day jitter property is exercised.
  assert.notEqual(a, b);
});

test('shareholderSpreadJitterSeconds: spreads a synchronized cohort across the window', () => {
  // 10 users that all last compounded at the same timestamp must NOT collapse
  // to the same offset — they should occupy a spread of distinct buckets.
  const ts = 1_700_000_000n;
  const offsets = new Set<number>();
  for (let i = 0; i < 10; i++) {
    const user = `0xUser00000000000000000000000000000000${i.toString().padStart(4, '0')}`;
    offsets.add(shareholderSpreadJitterSeconds(user, ts, SPREAD));
  }
  // Expect near-unique offsets (allow a tiny chance of collision).
  assert.ok(offsets.size >= 9, `expected >=9 distinct offsets, got ${offsets.size}`);
});

test('shareholderSpreadJitterSeconds: first-compound cohort (shared firstSeen anchor) fans out', () => {
  // First-ever compound has no cadence anchor, so the keeper anchors the spread
  // on a shared `firstSeen` second (e.g. the launch backlog discovered at the
  // same scan). With the anchor as salt, a synchronized cohort must still land
  // at distinct offsets in [0, spread) rather than all clearing at firstSeen.
  const firstSeen = 1_782_358_000n;
  const offsets: number[] = [];
  for (let i = 0; i < 10; i++) {
    const user = `0xBacklog0000000000000000000000000000${i.toString().padStart(4, '0')}`;
    const j = shareholderSpreadJitterSeconds(user, firstSeen, SPREAD);
    assert.ok(j >= 0 && j < SPREAD);
    offsets.push(j);
  }
  assert.ok(
    new Set(offsets).size >= 9,
    `expected >=9 distinct offsets, got ${new Set(offsets).size}`,
  );
});
