import test from 'node:test';
import assert from 'node:assert/strict';

import { inCompoundCooldown } from '../src/tasks/compound_lp.js';
import { effectiveShareholderCadenceSeconds } from '../src/tasks/compound_shareholders.js';

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
