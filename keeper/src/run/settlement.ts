/**
 * Weekly settlement window scheduler.
 *
 * Orchestrates a two-phase execution cycle for reward settlement tasks:
 *   Phase 1 (immediate): non-price-sensitive tasks at window open.
 *   Phase 2 (spread): price-sensitive tasks distributed across a 24h window.
 *
 * This module owns timing, batching, and cycle state management.
 * It does NOT own the actual task execution (that stays in the task modules).
 */

import type { KeeperConfig } from '../shared/config.js';
import type { MorningCache } from '../shared/user_morning.js';
import { loadJsonDetailed, saveJsonAtomic } from '../shared/state.js';
import type { BatchEntry, LogFn, SettlementCycleState, SettlementState } from './types.js';

// ---------------------------------------------------------------------------
// Constants
// ---------------------------------------------------------------------------

const WEEK_MS = 7 * 24 * 60 * 60 * 1000;

export const IMMEDIATE_TASKS = ['compound-lp', 'automax-bonus'] as const;
export const SPREAD_TASKS = ['harvest-staking', 'compound-shareholders'] as const;
export const SETTLEMENT_TASK_NAMES = [...IMMEDIATE_TASKS, ...SPREAD_TASKS] as const;

// ---------------------------------------------------------------------------
// Window timing
// ---------------------------------------------------------------------------

/**
 * Compute the next window-open timestamp (ms) on or after `nowMs`.
 *
 * @param dayOfWeek 0=Sun..6=Sat (default 4=Thu)
 * @param hourUtc   0-23
 * @param nowMs     reference timestamp
 */
export function computeNextWindowMs(dayOfWeek: number, hourUtc: number, nowMs: number): number {
  const d = new Date(nowMs);
  d.setUTCHours(hourUtc, 0, 0, 0);

  const currentDay = d.getUTCDay();
  let daysAhead = dayOfWeek - currentDay;
  if (daysAhead < 0) daysAhead += 7;

  const candidate = d.getTime() + daysAhead * 24 * 60 * 60 * 1000;

  if (candidate <= nowMs) {
    return candidate + WEEK_MS;
  }
  return candidate;
}

export function isWindowOpen(
  windowOpenMs: number,
  windowDurationMs: number,
  nowMs: number,
): boolean {
  return nowMs >= windowOpenMs && nowMs < windowOpenMs + windowDurationMs;
}

export function isWindowDue(nextWindowMs: number, nowMs: number): boolean {
  return nowMs >= nextWindowMs;
}

/**
 * Deterministic cycle ID derived from the window-open timestamp.
 * Uses the Thursday UTC ISO date string (e.g., "2026-04-23").
 */
export function cycleIdFromWindowMs(windowOpenMs: number): string {
  return new Date(windowOpenMs).toISOString().slice(0, 10);
}

// ---------------------------------------------------------------------------
// State persistence
// ---------------------------------------------------------------------------

const STATE_VERSION = 1;

function initState(nextWindowMs: number): SettlementState {
  return {
    version: STATE_VERSION,
    nextWindowMs,
    current: null,
    pendingPriorityQueue: [],
  };
}

export function loadSettlementState(
  filePath: string,
  config: KeeperConfig,
  nowMs: number = Date.now(),
): SettlementState {
  const result = loadJsonDetailed(filePath);
  if (result.kind === 'ok' && result.value != null) {
    const raw = result.value as Record<string, unknown>;
    if (raw.version === STATE_VERSION) {
      return raw as unknown as SettlementState;
    }
  }

  const nextMs = computeNextWindowMs(config.settlementDayUtc, config.settlementHourUtc, nowMs);
  return initState(nextMs);
}

export function saveSettlementState(filePath: string, state: SettlementState): void {
  saveJsonAtomic(filePath, state);
}

// ---------------------------------------------------------------------------
// Cycle lifecycle
// ---------------------------------------------------------------------------

export function openCycle(
  state: SettlementState,
  nowMs: number,
  config: KeeperConfig,
): SettlementState {
  const windowOpenMs = state.nextWindowMs;
  const windowDurationMs = config.settlementWindowDurationSecs * 1000;

  const cycle: SettlementCycleState = {
    cycleId: cycleIdFromWindowMs(windowOpenMs),
    windowOpenMs,
    windowCloseMs: windowOpenMs + windowDurationMs,
    phase: 'immediate',

    immediateTasksCompleted: [],
    harvestCompleted: false,

    spreadBatchesCompleted: [],
    spreadBatchesPending: [],

    priorityQueue: [...state.pendingPriorityQueue],

    failedTasks: [],
    attemptCount: 0,
    lastAttemptMs: nowMs,
  };

  return {
    ...state,
    current: cycle,
    pendingPriorityQueue: [],
  };
}

export function closeCycle(
  state: SettlementState,
  config: KeeperConfig,
  nowMs: number,
): SettlementState {
  const cycle = state.current;
  const missedUsers = cycle?.spreadBatchesPending ?? [];

  const nextWindowMs = computeNextWindowMs(
    config.settlementDayUtc,
    config.settlementHourUtc,
    nowMs,
  );

  return {
    ...state,
    nextWindowMs,
    current: null,
    pendingPriorityQueue: missedUsers,
  };
}

// ---------------------------------------------------------------------------
// Immediate phase helpers
// ---------------------------------------------------------------------------

export function isImmediatePhaseComplete(cycle: SettlementCycleState): boolean {
  return IMMEDIATE_TASKS.every((t) => cycle.immediateTasksCompleted.includes(t));
}

export function markImmediateTaskDone(state: SettlementState, taskName: string): SettlementState {
  if (!state.current) return state;
  const cycle = state.current;
  if (cycle.immediateTasksCompleted.includes(taskName)) return state;
  return {
    ...state,
    current: {
      ...cycle,
      immediateTasksCompleted: [...cycle.immediateTasksCompleted, taskName],
    },
  };
}

export function transitionToSpread(state: SettlementState): SettlementState {
  if (!state.current) return state;
  return {
    ...state,
    current: {
      ...state.current,
      phase: 'spread',
    },
  };
}

// ---------------------------------------------------------------------------
// Spread phase: batch scheduling
// ---------------------------------------------------------------------------

/**
 * Build a batch schedule for a set of users across the spread window.
 *
 * Priority-queue users are placed first (but still jittered), then remaining
 * users are distributed across the remaining window. When a `morningCache`
 * is available, users with a detected morning hour are clustered near that
 * hour if it falls within the window.
 */
export function scheduleBatches(args: {
  taskName: string;
  users: string[];
  priorityUsers: string[];
  windowOpenMs: number;
  windowCloseMs: number;
  batchSize: number;
  morningCache: MorningCache | null;
}): BatchEntry[] {
  const { taskName, users, priorityUsers, windowOpenMs, windowCloseMs, batchSize, morningCache } =
    args;

  const windowMs = windowCloseMs - windowOpenMs;
  if (windowMs <= 0 || users.length === 0) return [];

  const prioritySet = new Set(priorityUsers.map((a) => a.toLowerCase()));

  const ordered: string[] = [];
  const nonPriority: string[] = [];
  for (const u of users) {
    if (prioritySet.has(u.toLowerCase())) {
      ordered.push(u);
    } else {
      nonPriority.push(u);
    }
  }

  shuffleArray(nonPriority);
  ordered.push(...nonPriority);

  const batches: BatchEntry[] = [];
  const totalBatches = Math.ceil(ordered.length / batchSize);
  const slotMs = totalBatches > 1 ? windowMs / totalBatches : 0;

  for (let i = 0; i < ordered.length; i += batchSize) {
    const batchUsers = ordered.slice(i, i + batchSize);
    const batchIndex = Math.floor(i / batchSize);

    let scheduledAtMs: number;
    if (morningCache && batchUsers.length === 1) {
      const morning = morningCache.users[batchUsers[0].toLowerCase()];
      if (morning != null) {
        scheduledAtMs = alignToMorning(windowOpenMs, windowCloseMs, morning);
      } else {
        scheduledAtMs = windowOpenMs + batchIndex * slotMs + jitterMs(slotMs * 0.3);
      }
    } else {
      scheduledAtMs = windowOpenMs + batchIndex * slotMs + jitterMs(slotMs * 0.3);
    }

    scheduledAtMs = Math.max(windowOpenMs, Math.min(scheduledAtMs, windowCloseMs - 60_000));

    batches.push({
      taskName,
      users: batchUsers,
      scheduledAtMs: Math.round(scheduledAtMs),
      completed: false,
    });
  }

  batches.sort((a, b) => a.scheduledAtMs - b.scheduledAtMs);
  return batches;
}

function alignToMorning(
  windowOpenMs: number,
  windowCloseMs: number,
  morningHourUtc: number,
): number {
  const windowOpenDate = new Date(windowOpenMs);
  const dayStartMs = Date.UTC(
    windowOpenDate.getUTCFullYear(),
    windowOpenDate.getUTCMonth(),
    windowOpenDate.getUTCDate(),
  );

  let target = dayStartMs + morningHourUtc * 3600 * 1000;
  if (target < windowOpenMs) target += 24 * 3600 * 1000;
  if (target >= windowCloseMs) {
    return windowOpenMs + jitterMs(windowCloseMs - windowOpenMs);
  }
  return target + jitterMs(30 * 60 * 1000);
}

function jitterMs(maxMs: number): number {
  return Math.floor(Math.random() * Math.max(0, maxMs));
}

function shuffleArray<T>(arr: T[]): void {
  for (let i = arr.length - 1; i > 0; i--) {
    const j = Math.floor(Math.random() * (i + 1));
    [arr[i], arr[j]] = [arr[j], arr[i]];
  }
}

// ---------------------------------------------------------------------------
// Market-impact gating
// ---------------------------------------------------------------------------

/**
 * Whether the next batch should pause due to excessive price drift.
 *
 * @param estimatedInputWei  Wei amount the batch will swap.
 * @param currentQuoteBps    Current quote (bps from oracle).
 * @param baselineQuoteBps   Quote at window open or after last successful batch.
 * @param maxDriftBps        Configurable tolerance (e.g. 100 = 1%).
 */
export function shouldPauseBatch(
  estimatedInputWei: bigint,
  currentQuoteBps: number,
  baselineQuoteBps: number,
  maxDriftBps: number,
): boolean {
  if (baselineQuoteBps <= 0) return false;
  if (estimatedInputWei <= 0n) return false;

  const drift = Math.abs(currentQuoteBps - baselineQuoteBps);
  return drift > maxDriftBps;
}

// ---------------------------------------------------------------------------
// Spread state mutations
// ---------------------------------------------------------------------------

export function populateSpreadBatches(
  state: SettlementState,
  batches: BatchEntry[],
  allUsers: string[],
): SettlementState {
  if (!state.current) return state;
  return {
    ...state,
    current: {
      ...state.current,
      spreadBatchesPending: allUsers,
      spreadBatchesCompleted: [
        ...state.current.spreadBatchesCompleted,
        ...batches.map((b) => ({ ...b })),
      ],
    },
  };
}

export function markHarvestDone(state: SettlementState): SettlementState {
  if (!state.current) return state;
  return {
    ...state,
    current: {
      ...state.current,
      harvestCompleted: true,
    },
  };
}

export function markBatchCompleted(
  state: SettlementState,
  batchIndex: number,
  processedUsers: string[],
  nowMs: number,
): SettlementState {
  if (!state.current) return state;
  const cycle = state.current;

  const updatedBatches = cycle.spreadBatchesCompleted.map((b, i) =>
    i === batchIndex ? { ...b, completed: true } : b,
  );

  const processedSet = new Set(processedUsers.map((u) => u.toLowerCase()));
  const remainingPending = cycle.spreadBatchesPending.filter(
    (u) => !processedSet.has(u.toLowerCase()),
  );

  return {
    ...state,
    current: {
      ...cycle,
      spreadBatchesCompleted: updatedBatches,
      spreadBatchesPending: remainingPending,
      attemptCount: cycle.attemptCount + 1,
      lastAttemptMs: nowMs,
    },
  };
}

export function markTaskFailed(state: SettlementState, taskName: string): SettlementState {
  if (!state.current) return state;
  const cycle = state.current;
  if (cycle.failedTasks.includes(taskName)) return state;
  return {
    ...state,
    current: {
      ...cycle,
      failedTasks: [...cycle.failedTasks, taskName],
    },
  };
}

// ---------------------------------------------------------------------------
// Query helpers
// ---------------------------------------------------------------------------

export function getNextDueBatch(
  cycle: SettlementCycleState,
  nowMs: number,
): { batch: BatchEntry; index: number } | null {
  for (let i = 0; i < cycle.spreadBatchesCompleted.length; i++) {
    const b = cycle.spreadBatchesCompleted[i];
    if (!b.completed && b.scheduledAtMs <= nowMs) {
      return { batch: b, index: i };
    }
  }
  return null;
}

export function isSpreadPhaseComplete(cycle: SettlementCycleState): boolean {
  return (
    cycle.harvestCompleted &&
    cycle.spreadBatchesCompleted.length > 0 &&
    cycle.spreadBatchesCompleted.every((b) => b.completed)
  );
}

// ---------------------------------------------------------------------------
// Logging
// ---------------------------------------------------------------------------

export function logSettlementSummary(state: SettlementState, log: LogFn): void {
  const cycle = state.current;
  if (!cycle) {
    const next = new Date(state.nextWindowMs).toISOString();
    log(`settlement: idle. next window at ${next}`);
    return;
  }

  const phase = cycle.phase;
  const completedBatches = cycle.spreadBatchesCompleted.filter((b) => b.completed).length;
  const totalBatches = cycle.spreadBatchesCompleted.length;
  const pending = cycle.spreadBatchesPending.length;

  log(
    `settlement [${cycle.cycleId}]: phase=${phase} immediate=${cycle.immediateTasksCompleted.length}/${IMMEDIATE_TASKS.length} ` +
      `harvest=${cycle.harvestCompleted} batches=${completedBatches}/${totalBatches} pending=${pending}`,
  );
}
