import type { KeeperConfig } from '../shared/config.js';
import type { DeploymentManifest } from '../shared/deployments.js';
import type { FileLock } from '../shared/lock.js';
import type { ViemClients } from '../shared/clients.js';
import type { CliOptions } from './cli.js';

export type LogFn = (msg: string) => void;

export interface TaskDef {
  name: string;
  statusKey: string;
  intervalSecs: number;
  run: () => Promise<unknown>;
}

export interface DaemonTask extends TaskDef {
  intervalMs: number;
  nextRunAtMs: number;
  /**
   * Epoch-ms at which the task's most recent run finished (success or
   * failure).  `0` before the first run has completed.  Used by the
   * event-driven debounce to enforce `KEEPER_EVENT_MIN_REPEAT_SECS`
   * between successive event-triggered runs of the same task.
   */
  lastRunEndMs: number;
}

export type DaemonRunArgs = {
  cli: CliOptions;
  config: KeeperConfig;
  manifest: DeploymentManifest;
  clients: ViemClients;
  log: LogFn;
  lock: FileLock;
};

// ---------------------------------------------------------------------------
// Weekly settlement window types
// ---------------------------------------------------------------------------

export type SettlementPhase = 'idle' | 'immediate' | 'spread';

export interface BatchEntry {
  taskName: string;
  users: string[];
  scheduledAtMs: number;
  completed: boolean;
}

/**
 * Persisted per-cycle state for the weekly settlement window.
 *
 * Keyed by a deterministic `cycleId` so restarts mid-window resume
 * idempotently without re-running completed work.
 *
 * Only structural data is persisted (addresses, phase, completion flags).
 * Quotes, reward amounts, and impact estimates are never persisted --
 * they must be fetched fresh at execution time.
 */
export interface SettlementCycleState {
  cycleId: string;
  windowOpenMs: number;
  windowCloseMs: number;
  phase: SettlementPhase;

  immediateTasksCompleted: string[];
  harvestCompleted: boolean;

  spreadBatchesCompleted: BatchEntry[];
  spreadBatchesPending: string[];

  /**
   * CLAIM out for 1 WETH via the vault Aerodrome route at spread baseline (set on first drift read).
   * Used for relative drift vs current `getAmountsOut` (string bigint for JSON).
   */
  spreadBaselineClaimOut1Weth?: string;

  /**
   * Users missed in the prior cycle (drift pause, window close, quote
   * failure). They get first position in the next cycle's spread queue.
   * Within the priority tier, morning-window jitter still applies.
   */
  priorityQueue: string[];

  failedTasks: string[];
  attemptCount: number;
  lastAttemptMs: number;
}

export interface SettlementState {
  version: number;
  nextWindowMs: number;
  current: SettlementCycleState | null;
  /** Carried forward from the prior cycle on window close. */
  pendingPriorityQueue: string[];
}
