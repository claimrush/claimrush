import test from 'node:test';
import assert from 'node:assert/strict';

import { assertLiveDeadlineBound, assertNoLiveUnsafeMinOut } from '../src/shared/config.js';

test('assertNoLiveUnsafeMinOut: dry-run permits both overrides (local dev convenience)', () => {
  assert.doesNotThrow(() =>
    assertNoLiveUnsafeMinOut({
      liveRun: false,
      allowUnsafeMinOut: true,
      allowUnsafeMinVeOut: true,
    }),
  );
});

test('assertNoLiveUnsafeMinOut: live + allowUnsafeMinOut throws', () => {
  assert.throws(
    () =>
      assertNoLiveUnsafeMinOut({
        liveRun: true,
        allowUnsafeMinOut: true,
        allowUnsafeMinVeOut: false,
      }),
    /KEEPER_ALLOW_UNSAFE_MIN_OUT=1 is forbidden under KEEPER_LIVE_RUN=1/,
  );
});

test('assertNoLiveUnsafeMinOut: live + allowUnsafeMinVeOut throws', () => {
  assert.throws(
    () =>
      assertNoLiveUnsafeMinOut({
        liveRun: true,
        allowUnsafeMinOut: false,
        allowUnsafeMinVeOut: true,
      }),
    /KEEPER_ALLOW_UNSAFE_MIN_VE_OUT=1 is forbidden under KEEPER_LIVE_RUN=1/,
  );
});

test('assertNoLiveUnsafeMinOut: live with both overrides off is permitted (the prod default)', () => {
  assert.doesNotThrow(() =>
    assertNoLiveUnsafeMinOut({
      liveRun: true,
      allowUnsafeMinOut: false,
      allowUnsafeMinVeOut: false,
    }),
  );
});

test('assertLiveDeadlineBound: dry-run permits wide deadlines for local testing', () => {
  assert.doesNotThrow(() => assertLiveDeadlineBound({ liveRun: false, deadlineSecs: 3_600 }));
});

test('assertLiveDeadlineBound: live deadline over 60 seconds throws', () => {
  assert.throws(
    () => assertLiveDeadlineBound({ liveRun: true, deadlineSecs: 61 }),
    /KEEPER_DEADLINE_SECS must be <= 60 under KEEPER_LIVE_RUN=1/,
  );
});

test('assertLiveDeadlineBound: live deadline at 60 seconds is permitted', () => {
  assert.doesNotThrow(() => assertLiveDeadlineBound({ liveRun: true, deadlineSecs: 60 }));
});
