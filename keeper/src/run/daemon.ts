import type http from 'node:http';
import { fmtMs, sleep, interruptibleSleep } from '../shared/utils.js';
import { startKeeperHealthServer } from '../shared/health.js';
import { readStatus } from '../tasks/status.js';
import type { StatusState } from '../shared/state.js';
import { loadJsonDetailed } from '../shared/state.js';
import { parseTasksList } from './cli.js';
import { computeInitialNextRunMs, jitteredIntervalMs } from './scheduler.js';
import { buildDaemonTaskDefs, refreshMorningCacheForRewardTasks } from './tasks.js';
import { parseIntStrict } from '../shared/env.js';
import { CircuitBreakerStateError } from '../shared/circuit_breaker.js';
import { parseChainIdStrict } from '../shared/chainId.js';
import { currentTier, type Tier } from '../shared/tier_observer.js';
import { EventBus, type TriggerReason } from './event_bus.js';
import { resolveHotSubscriptions } from './hot_events.js';
import type { DaemonRunArgs, DaemonTask, SettlementState as SettlementStateType } from './types.js';

/**
 * Tasks whose cadence adapts to the tier observed on the keeper's public
 * RPC proxy.  Only the "hot" polling tasks participate: they are the ones
 * that contribute meaningfully to Alchemy CU spend when we're on fallback,
 * and the ones whose latency-to-event matters enough to keep short when
 * we're on a local node.  Slow maintenance tasks (compound-*, automax-*,
 * checkpoint-before-expiry, harvest-staking, settlement tasks) keep their
 * configured intervals regardless of tier.
 */
const ADAPTIVE_CADENCE_TASKS: ReadonlySet<string> = new Set([
  'poke',
  'sweep-market',
  'sweep-listings',
  'expire-offers',
]);

/**
 * WS bus health as seen by the scheduler.  Derived from the event bus:
 *
 *   - `disabled`               — no KEEPER_WS_URL configured at all
 *   - `healthy`                — WS open AND seen a message recently
 *   - `recently-disconnected`  — WS closed/silent but still inside the
 *                                configurable grace window (default 5 min)
 *   - `disconnected`           — WS silent for longer than the grace
 */
export type WsStatus = 'disabled' | 'healthy' | 'recently-disconnected' | 'disconnected';

/**
 * Classify the current WS bus state.  Kept as a pure function (no
 * side-effects, no timers) so it's trivially testable and so the
 * scheduler can re-evaluate it every loop iteration without cost.
 *
 * We treat "never connected" specially: if the bus has never received
 * any message (`lastMessageAtMs === 0`), the grace window does NOT
 * apply — we assume polling until the first message proves WS is
 * actually working.  Otherwise a mis-configured URL would silently
 * park the keeper on the safety-net cadence forever.
 */
export function computeWsStatus(
  bus: { wsUrl: string | null; isHealthy(): boolean; getLastMessageAtMs(): number },
  graceMs: number,
  nowMs: number = Date.now(),
): WsStatus {
  if (!bus.wsUrl) return 'disabled';
  if (bus.isHealthy()) return 'healthy';
  const last = bus.getLastMessageAtMs();
  if (last > 0 && nowMs - last <= graceMs) return 'recently-disconnected';
  return 'disconnected';
}

/**
 * Resolve the interval a task should use for its NEXT run, given the
 * currently-observed RPC upstream tier AND the event-bus health.
 * Returns `task.intervalMs` for any task not in the adaptive set
 * (stable cadence).  For adaptive (hot) tasks:
 *
 *   1. If WS is healthy (or only briefly dropped) → use the SAFETY-NET
 *      interval (default 1h).  The event bus is primary; polling is a
 *      reconciliation backstop.
 *   2. Otherwise (WS disabled, or dropped longer than grace):
 *        - tier=`primary`              → `intervalSecsPrimary`
 *        - tier=`fallback` or `unknown`→ `intervalSecsFallback`
 *
 * Rationale: `unknown` tier means either (a) there is no ClaimRush RPC
 * proxy in front of us (common for community operators running the
 * keeper against a public provider directly) or (b) we have not seen
 * enough samples yet.  Both cases safely default to the CONSERVATIVE
 * cadence — we only switch to the aggressive short interval on positive
 * confirmation that we are on a cheap upstream (`tier=primary`).  This
 * keeps CU spend reasonable for Alchemy-free-tier community operators
 * while still letting serious ops (with a local node behind the proxy)
 * poll aggressively when WS is unavailable.  The ws-healthy fast path
 * supersedes this: if events are flowing, polling is just a backstop.
 */
export function effectiveIntervalMsForTask(
  task: { name: string; intervalMs: number },
  config: {
    intervalSecsPrimary: number;
    intervalSecsFallback: number;
    safetyNetIntervalSecs: number;
  },
  tier: Tier,
  wsStatus: WsStatus = 'disabled',
): number {
  if (!ADAPTIVE_CADENCE_TASKS.has(task.name)) return task.intervalMs;
  if (wsStatus === 'healthy' || wsStatus === 'recently-disconnected') {
    return config.safetyNetIntervalSecs * 1000;
  }
  if (tier === 'primary') return config.intervalSecsPrimary * 1000;
  return config.intervalSecsFallback * 1000;
}

/**
 * Pure decision function for the event-driven trigger debounce.
 *
 * Given the current task bookkeeping (`nextRunAtMs`, `lastRunEndMs`) and
 * the configured `minRepeatMs`, returns what the daemon should do with
 * a freshly-arrived event:
 *
 *   - `{ kind: 'ignored' }` — task is already due or currently running
 *     (`nextRunAtMs <= now`); the main loop will execute it on its next
 *     pass, so this event is a no-op.
 *
 *   - `{ kind: 'run' }` — no recent run within the min-repeat window;
 *     the caller should set `nextRunAtMs = 0` and wake the sleep so the
 *     task fires on the next iteration.
 *
 *   - `{ kind: 'deferred', scheduledAtMs }` — last run ended inside the
 *     min-repeat window; the caller should set
 *     `nextRunAtMs = min(nextRunAtMs, scheduledAtMs)` (clamp to at most
 *     the earliest-allowed deadline) and wake the sleep.  Multiple
 *     events inside the window collapse onto the same deadline.
 *
 *   - `{ kind: 'coalesced' }` — same as `deferred` but there's already
 *     a pending deadline inside the window, so the caller has nothing
 *     to change.  Surfaced separately to keep the log output honest.
 *
 * Keeping this pure (no `Date.now()`, no mutation) makes the spam-burst
 * scenarios trivial to exercise in unit tests.
 */
export type EventDecision =
  | { kind: 'ignored' }
  | { kind: 'run' }
  | { kind: 'deferred'; scheduledAtMs: number }
  | { kind: 'coalesced' };

export function decideEventTrigger(
  state: { nextRunAtMs: number; lastRunEndMs: number },
  nowMs: number,
  minRepeatMs: number,
): EventDecision {
  if (state.nextRunAtMs <= nowMs) return { kind: 'ignored' };
  const earliestAllowedMs =
    state.lastRunEndMs > 0 && minRepeatMs > 0 ? state.lastRunEndMs + minRepeatMs : 0;
  if (earliestAllowedMs > nowMs) {
    if (earliestAllowedMs < state.nextRunAtMs) {
      return { kind: 'deferred', scheduledAtMs: earliestAllowedMs };
    }
    return { kind: 'coalesced' };
  }
  return { kind: 'run' };
}
import {
  SETTLEMENT_TASK_NAMES,
  IMMEDIATE_TASKS,
  isWindowDue,
  loadSettlementState,
  saveSettlementState,
  openCycle,
  closeCycle,
  isImmediatePhaseComplete,
  markImmediateTaskDone,
  transitionToSpread,
  markHarvestDone,
  markBatchCompleted,
  markTaskFailed,
  getNextDueBatch,
  isSpreadPhaseComplete,
  logSettlementSummary,
  scheduleBatches,
  populateSpreadBatches,
} from './settlement.js';
import { loadMorningCache } from '../shared/user_morning.js';
import { getContractAddress } from '../shared/deployments.js';
import { readStakingVaultClaimOutForOneWeth } from '../tasks/quotes.js';

function getTaskTimeoutMs(): number {
  return Math.min(
    600_000,
    Math.max(
      30_000,
      (parseIntStrict(process.env.KEEPER_TASK_TIMEOUT_SECS, { defaultValue: 300 }) ?? 300) * 1000,
    ),
  );
}

/**
 * Wrap `promise` with a hard wall-clock deadline.
 *
 * IMPORTANT: this is a *soft* timeout — the underlying `promise` is NOT
 * cancelled when the deadline fires. A slow RPC / HTTP call kicked off by
 * `promise` will keep running after withTimeout has rejected, and can still
 * submit a transaction, mutate state, or emit subsequent logs under the
 * next scheduler iteration. Callers that need true cancellation MUST pass
 * an AbortSignal through their own call stack and respect it — withTimeout
 * alone is not sufficient.
 *
 * We accept this design here because the daemon loop already serialises
 * task-level work (one iteration per `tasks` pass), so a late-arriving
 * result from a previously-timed-out task is logged and discarded by the
 * outer iteration; it cannot cause duplicate tx submission under the
 * current call sites. This contract is load-bearing: reusing withTimeout
 * from concurrent call sites without adding per-call AbortSignals would
 * reintroduce the double-submit risk.
 */
function withTimeout<T>(promise: Promise<T>, ms: number, label: string): Promise<T> {
  return new Promise<T>((resolve, reject) => {
    const timer = setTimeout(
      () => reject(new Error(`task "${label}" timed out after ${ms}ms`)),
      ms,
    );
    promise.then(
      (v) => {
        clearTimeout(timer);
        resolve(v);
      },
      (e) => {
        clearTimeout(timer);
        reject(e);
      },
    );
    // Note: we intentionally do NOT add an extra .catch() here — the
    // promise.then(onFulfilled, onRejected) above already attaches a
    // rejection handler to `promise`, so a late rejection after the timer
    // has fired is considered handled (it just becomes a no-op inner reject
    // on the outer Promise, which has already settled).
  });
}

export async function runDaemon(args: DaemonRunArgs): Promise<void> {
  const { cli, config, manifest, clients, log, lock } = args;
  const selected = parseTasksList(cli.tasksRaw) ?? config.daemonTasks;
  const TASK_TIMEOUT_MS = getTaskTimeoutMs();

  const assertLockHeld = (): void => {
    if (lock && typeof lock.isHeld === 'function' && !lock.isHeld()) {
      const reason = typeof lock.getLostReason === 'function' ? lock.getLostReason() : 'unknown';
      throw new Error(`keeper lock lost (${reason}); exiting to avoid concurrent keepers`);
    }
  };

  const defs = buildDaemonTaskDefs({ config, manifest, clients, log });

  const settlementTaskSet = new Set<string>(SETTLEMENT_TASK_NAMES as readonly string[]);
  const settlementEnabled = config.settlementEnabled;

  const tasks: DaemonTask[] = selected
    .filter((name: string) => {
      if (settlementEnabled && settlementTaskSet.has(name)) return false;
      return true;
    })
    .map((name: string) => {
      const def = defs[name];
      if (!def) throw new Error(`unknown daemon task: ${name}`);
      return {
        ...def,
        intervalMs: def.intervalSecs * 1000,
        nextRunAtMs: 0,
        lastRunEndMs: 0,
      };
    });

  const status = readStatus({ statusPath: config.statusPath }) as StatusState | null;
  const lastAttemptByTask = status?.lastAttemptByTask ?? null;
  const now0 = Date.now();
  const initialTier = currentTier();
  for (const t of tasks) {
    t.nextRunAtMs = computeInitialNextRunMs({
      nowMs: now0,
      lastAttemptByTask,
      statusKey: t.statusKey,
      // Respect the adaptive tier for the FIRST scheduling pass too, so
      // that a keeper started cold with lastAttempt within the primary
      // interval but while the proxy is on fallback doesn't schedule its
      // next run at an already-overdue timestamp.
      intervalMs: effectiveIntervalMsForTask(t, config, initialTier),
    });
  }

  const taskNames = tasks.map((t) => t.name).join(',');
  log(`daemon tasks: ${taskNames}`);

  const chainId = parseChainIdStrict(manifest?.chainId) ?? 0;

  const getStatus = (): Record<string, unknown> | null => {
    const s = readStatus({ statusPath: config.statusPath }) as any;
    return s && typeof s === 'object' ? (s as Record<string, unknown>) : null;
  };

  // Optional health server (liveness + Prometheus metrics).
  // Best-effort: if it fails to start, keep the daemon running but log the error.
  let healthServer: http.Server | null = null;
  if (config.healthPort > 0) {
    try {
      healthServer = await startKeeperHealthServer({
        host: config.healthHost,
        port: config.healthPort,
        token: config.healthToken,
        getStatus,
        deployment: config.deployment,
        chainId,
        isLockHeld: () => (lock && typeof lock.isHeld === 'function' ? lock.isHeld() : true),
        log,
      });
    } catch (e: any) {
      log(`health server failed to start: ${String(e?.message ?? e)}`);
      healthServer = null;
    }
  }

  const closeHealthServer = async (): Promise<void> => {
    if (!healthServer) return;
    await new Promise<void>((resolve) => {
      try {
        healthServer!.close(() => resolve());
      } catch {
        resolve();
      }
    });
  };

  // ---------------------------------------------------------------
  // Optional event bus (phase 4): WS-driven triggers for hot tasks.
  //
  // The bus only POKES the scheduler — it never runs a task inline.  On
  // a matching log we flip `nextRunAtMs = 0` for the affected task(s)
  // and call `wakeIdleSleep()` so the main loop re-evaluates now instead
  // of waiting for its current `interruptibleSleep` to expire.
  //
  // If `config.wsUrl` is null, `EventBus.start()` returns immediately
  // and `wakeIdleSleep` is never called — the daemon keeps running as a
  // pure polling loop.  No code path below should assume the bus is live.
  // ---------------------------------------------------------------
  let wakeIdleSleep: () => void = () => {
    // Replaced each loop iteration with the current sleep's wake()
    // function.  Outside a sleep this is a no-op.
  };

  const taskByName = new Map<string, DaemonTask>(tasks.map((t) => [t.name, t]));
  const allowedEventTasks = new Set(config.eventDrivenTasks);

  const eventMinRepeatMs = Math.max(0, config.eventMinRepeatSecs * 1000);

  const onEventTrigger = (taskName: string, reason: TriggerReason): void => {
    if (!allowedEventTasks.has(taskName)) return;
    const t = taskByName.get(taskName);
    if (!t) return;
    const nowMs = Date.now();
    const decision = decideEventTrigger(t, nowMs, eventMinRepeatMs);
    switch (decision.kind) {
      case 'ignored':
        log(
          `daemon: event for ${taskName} ignored (already due; block=${reason.block}, tx=${reason.txHash})`,
        );
        return;
      case 'coalesced':
        log(
          `daemon: event for ${taskName} coalesced (pending run already in min-repeat window; block=${reason.block}, tx=${reason.txHash})`,
        );
        return;
      case 'deferred':
        t.nextRunAtMs = decision.scheduledAtMs;
        log(
          `daemon: event triggered ${taskName} (deferred ${fmtMs(decision.scheduledAtMs - nowMs)} by min-repeat; block=${reason.block}, tx=${reason.txHash})`,
        );
        wakeIdleSleep();
        return;
      case 'run':
        t.nextRunAtMs = 0;
        log(`daemon: event triggered ${taskName} (block=${reason.block}, tx=${reason.txHash})`);
        wakeIdleSleep();
        return;
    }
  };

  const eventBus = new EventBus({
    wsUrl: config.wsUrl,
    wsUrlFallback: config.wsUrlFallback,
    log,
    onTrigger: onEventTrigger,
    onConnected: () => log('[event_bus] connected; hot tasks are event-driven'),
    onDisconnected: () =>
      log('[event_bus] disconnected; falling back to polling cadence until reconnect'),
  });

  // Register hot-task subscriptions (Takeover, market offer lifecycle,
  // listings) *before* starting the bus — EventBus.subscribe() rejects
  // calls made after start().  Any subscription whose contract isn't in
  // the manifest is silently skipped by resolveHotSubscriptions, which
  // keeps the bus usable on partial deployments.
  const hotSubs = resolveHotSubscriptions(manifest, log);
  const enabledEventTaskSet = new Set(config.eventDrivenTasks);
  for (const sub of hotSubs) {
    if (!enabledEventTaskSet.has(sub.taskName)) {
      log(
        `[event_bus] skipping subscription for ${sub.taskName} (${sub.label}): task disabled via KEEPER_EVENT_DRIVEN_TASKS`,
      );
      continue;
    }
    if (!taskByName.has(sub.taskName)) {
      log(
        `[event_bus] skipping subscription for ${sub.taskName} (${sub.label}): task not scheduled in this keeper run`,
      );
      continue;
    }
    eventBus.subscribe(sub.taskName, sub.filter);
    log(`[event_bus] registered subscription: ${sub.taskName} <- ${sub.label}`);
  }

  try {
    await eventBus.start();
  } catch (e: any) {
    log(`[event_bus] start failed (continuing with polling-only): ${String(e?.message ?? e)}`);
  }

  const closeEventBus = async (): Promise<void> => {
    try {
      await eventBus.stop();
    } catch (e: any) {
      log(`[event_bus] stop error: ${String(e?.message ?? e)}`);
    }
  };

  if (cli.once) {
    log('daemon --once: running all configured tasks once');
    try {
      for (const t of tasks) {
        assertLockHeld();

        const started = Date.now();
        try {
          log(`daemon: running ${t.name}`);
          await withTimeout(t.run(), TASK_TIMEOUT_MS, t.name);
        } catch (e: any) {
          log(`daemon task ${t.name} threw: ${String(e?.shortMessage ?? e?.message ?? e)}`);
        } finally {
          const elapsed = Date.now() - started;
          log(`daemon: ${t.name} done (elapsed=${fmtMs(elapsed)})`);
        }
      }
      log('daemon --once: exiting');
    } finally {
      await closeEventBus();
      await closeHealthServer();
    }
    return;
  }

  // Enforce task ordering: harvest-staking must run before compound tasks
  // when both are due in the same tick, otherwise compounds operate on stale
  // reward balances. Similarly, sweeps before expires avoids wasted gas.
  const TASK_PRIORITY: Record<string, number> = {
    'harvest-staking': 0,
    poke: 1,
    'sweep-market': 2,
    'sweep-listings': 3,
    'expire-offers': 4,
    'compound-shareholders': 5,
    'compound-lp': 6,
    'automax-bonus': 7,
    'checkpoint-before-expiry': 8,
  };

  let lastMorningRefreshMs = 0;
  const MORNING_REFRESH_INTERVAL_MS = 6 * 60 * 60 * 1000; // check every 6h (actual refresh is weekly)

  // -- Settlement state (only meaningful when settlementEnabled) --
  let sState: SettlementStateType | null = null;
  if (settlementEnabled) {
    sState = loadSettlementState(config.settlementStatePath, config);
    logSettlementSummary(sState, log);
  }

  const persistSettlement = (): void => {
    if (sState) saveSettlementState(config.settlementStatePath, sState);
  };

  // In-memory per-batch retry backoff. Keyed by `${taskName}:${batchIndex}`.
  // When a spread batch fails inside its retry window the outer loop would
  // otherwise re-run it every iteration (no sleep), so we remember the next
  // earliest re-run time here. This state is intentionally in-memory only:
  // on restart we re-enter the tight loop once, which is acceptable.
  const spreadBatchRetryAtMs = new Map<string, number>();
  const spreadBatchRetryAttempt = new Map<string, number>();
  const SPREAD_RETRY_BASE_MS = 15_000; // first retry wait
  const SPREAD_RETRY_MAX_MS = 5 * 60_000; // cap at 5 minutes
  const spreadBatchKey = (taskName: string, index: number): string => `${taskName}:${index}`;
  const computeSpreadBackoffMs = (attempt: number): number => {
    // Exponential (base * 2^(attempt-1)) with small jitter, capped.
    const exp = Math.min(SPREAD_RETRY_MAX_MS, SPREAD_RETRY_BASE_MS * Math.pow(2, attempt - 1));
    const jitterBps = Math.floor(Math.random() * 1000); // 0..999 bps = 0..9.99%
    return Math.floor(exp * (1 + jitterBps / 10_000));
  };

  while (true) {
    assertLockHeld();

    if (config.subgraphUrl && Date.now() - lastMorningRefreshMs > MORNING_REFRESH_INTERVAL_MS) {
      try {
        await refreshMorningCacheForRewardTasks(config, [], log);
        lastMorningRefreshMs = Date.now();
      } catch (e: any) {
        log(`morning-cache refresh error: ${String(e?.message ?? e)}`);
      }
    }

    // ---------------------------------------------------------------
    // Settlement window processing (when enabled)
    // ---------------------------------------------------------------
    if (settlementEnabled && sState) {
      const now = Date.now();

      // Window close check: if we're past the window, close the cycle
      if (sState.current && now >= sState.current.windowCloseMs) {
        log(`settlement: window closed for cycle ${sState.current.cycleId}`);
        sState = closeCycle(sState, config, now);
        persistSettlement();
        logSettlementSummary(sState, log);
      }

      // Window open trigger
      if (!sState.current && isWindowDue(sState.nextWindowMs, now)) {
        log('settlement: opening settlement window');
        sState = openCycle(sState, now, config);
        persistSettlement();
        logSettlementSummary(sState, log);
      }

      // Phase 1: Immediate (non-price-sensitive)
      if (sState.current?.phase === 'immediate') {
        const taskGapMs = config.settlementTaskGapSecs * 1000;
        const currentCycle = sState.current;

        for (const taskName of IMMEDIATE_TASKS) {
          if (currentCycle.immediateTasksCompleted.includes(taskName)) continue;

          const def = defs[taskName];
          if (!def) {
            // A task listed in IMMEDIATE_TASKS but missing from `defs` is a
            // code-level misconfiguration (typo in the constant or a task
            // removed from `buildDaemonTaskDefs`). Previously this branch
            // marked the task complete and silently moved on, which
            // permanently skipped work for the cycle. Treat it as a task
            // failure instead so the circuit breaker / status surface can
            // expose the issue loudly, and persist state before continuing.
            log(
              `settlement: unknown immediate task ${taskName} (not present in defs); marking failed`,
            );
            sState = markTaskFailed(sState, taskName);
            persistSettlement();
            continue;
          }

          assertLockHeld();
          const started = Date.now();
          try {
            log(`settlement [immediate]: running ${taskName}`);
            await withTimeout(def.run(), TASK_TIMEOUT_MS, taskName);
            sState = markImmediateTaskDone(sState, taskName);
            log(`settlement [immediate]: ${taskName} done (${fmtMs(Date.now() - started)})`);
          } catch (e: any) {
            log(
              `settlement [immediate]: ${taskName} failed: ${String(e?.shortMessage ?? e?.message ?? e)}`,
            );
            sState = markTaskFailed(sState, taskName);
            if (e instanceof CircuitBreakerStateError) throw e;
          }
          persistSettlement();

          if (taskGapMs > 0) {
            log(`settlement: gap ${fmtMs(taskGapMs)} before next immediate task`);
            await sleep(taskGapMs);
          }
        }

        // Transition to spread phase
        if (sState.current && isImmediatePhaseComplete(sState.current)) {
          log('settlement: immediate phase complete, transitioning to spread');
          sState = transitionToSpread(sState);
          persistSettlement();
        }
      }

      // Phase 2: Spread (price-sensitive)
      if (sState.current?.phase === 'spread') {
        const cycle = sState.current;

        // Harvest: run once if not yet done
        if (!cycle.harvestCompleted) {
          const harvestDef = defs['harvest-staking'];
          if (harvestDef) {
            assertLockHeld();
            const started = Date.now();
            try {
              log('settlement [spread]: running harvest-staking');
              await withTimeout(harvestDef.run(), TASK_TIMEOUT_MS, 'harvest-staking');
              sState = markHarvestDone(sState);
              log(`settlement [spread]: harvest-staking done (${fmtMs(Date.now() - started)})`);
            } catch (e: any) {
              log(
                `settlement [spread]: harvest-staking failed: ${String(e?.shortMessage ?? e?.message ?? e)}`,
              );
              sState = markTaskFailed(sState, 'harvest-staking');
              if (e instanceof CircuitBreakerStateError) throw e;
            }
            persistSettlement();
          } else {
            sState = markHarvestDone(sState);
            persistSettlement();
          }
        }

        // Compound-shareholders batches: schedule if not yet populated
        if (cycle.spreadBatchesCompleted.length === 0 && cycle.spreadBatchesPending.length === 0) {
          const compoundDef = defs['compound-shareholders'];
          if (compoundDef) {
            const mc = loadMorningCache(config.morningCachePath);
            const csState = loadJsonDetailed(config.compoundShareholdersStatePath);
            const allUsers: string[] =
              csState.kind === 'ok' &&
              csState.value != null &&
              typeof csState.value === 'object' &&
              Array.isArray((csState.value as Record<string, unknown>).users)
                ? ((csState.value as Record<string, unknown>).users as unknown[]).filter(
                    (u): u is string => typeof u === 'string' && u.length > 0,
                  )
                : [];
            const priorityUsers = [...cycle.priorityQueue];

            const batches = scheduleBatches({
              taskName: 'compound-shareholders',
              users: allUsers.length > 0 ? allUsers : priorityUsers,
              priorityUsers,
              windowOpenMs: cycle.windowOpenMs,
              windowCloseMs: cycle.windowCloseMs,
              batchSize: config.compoundMaxUsersShareholders,
              morningCache: mc,
            });

            const spreadPendingUsers = batches.flatMap((b) => b.users);
            sState = populateSpreadBatches(sState, batches, spreadPendingUsers);
            persistSettlement();
            log(`settlement [spread]: scheduled ${batches.length} compound-shareholders batches`);
          }
        }

        // Process due batches
        if (sState.current) {
          const nowMs = Date.now();
          const dueBatch = getNextDueBatch(sState.current, nowMs);
          if (dueBatch) {
            const { batch, index } = dueBatch;
            const batchDef = defs[batch.taskName];
            if (batchDef) {
              assertLockHeld();
              let skipBatchForDrift = false;

              const vaultAddr = getContractAddress(manifest, 'LpStakingVault7D');
              const vaultOk =
                vaultAddr &&
                vaultAddr.toLowerCase() !== '0x0000000000000000000000000000000000000000';

              if (cycle.harvestCompleted && vaultOk) {
                const quoteRes = await readStakingVaultClaimOutForOneWeth({
                  publicClient: clients.publicClient,
                  vaultAddress: vaultAddr,
                });
                if (!quoteRes.ok) {
                  log(
                    `settlement [spread]: drift quote unavailable (fail open): ${quoteRes.error}`,
                  );
                } else {
                  const curOut = quoteRes.claimOut;
                  let baselineStr = sState.current!.spreadBaselineClaimOut1Weth;
                  if (baselineStr == null || baselineStr === '') {
                    sState = {
                      ...sState,
                      current: {
                        ...sState.current!,
                        spreadBaselineClaimOut1Weth: curOut.toString(),
                      },
                    };
                    persistSettlement();
                    baselineStr = curOut.toString();
                  }
                  const baselineOut = BigInt(baselineStr);
                  // Compare in pure bigint space before coercing to Number.
                  // Previously we did `Number(diff * 10_000n / baselineOut)`,
                  // which loses precision (and can overflow to Infinity) when
                  // the ratio numerator exceeds 2^53. The pause decision is
                  // really `diff/baseline > maxDriftBps/10_000`, so keep the
                  // inequality in bigint, then only coerce for logging.
                  const diffBig =
                    baselineOut > curOut ? baselineOut - curOut : curOut - baselineOut;
                  const maxBps = BigInt(config.settlementMaxDriftBps);
                  const pause = baselineOut > 0n && diffBig * 10_000n > baselineOut * maxBps;
                  // For logging only — clamp to a safe i53 range so very
                  // large ratios don't become `Infinity` in JSON output.
                  let driftBpsForLog = 0;
                  if (baselineOut > 0n) {
                    const ratioBig = (diffBig * 10_000n) / baselineOut;
                    driftBpsForLog =
                      ratioBig > 9_007_199_254_740_991n
                        ? Number.MAX_SAFE_INTEGER
                        : Number(ratioBig);
                  }
                  if (pause) {
                    log(
                      `settlement [spread]: pausing batch ${index} (driftBps=${driftBpsForLog} > ${config.settlementMaxDriftBps}); will retry after idle sleep`,
                    );
                    skipBatchForDrift = true;
                  }
                }
              }

              if (!skipBatchForDrift) {
                // Respect the backoff imposed after a prior failure on this
                // same batch. Without this check, a batch that keeps failing
                // inside its retry window would be re-run every outer-loop
                // iteration with no sleep, hammering the RPC and the
                // circuit breaker until the window closes or success.
                const retryKey = spreadBatchKey(batch.taskName, index);
                const notBefore = spreadBatchRetryAtMs.get(retryKey) ?? 0;
                if (nowMs < notBefore) {
                  log(
                    `settlement [spread]: batch ${index} in backoff (${fmtMs(notBefore - nowMs)} left); deferring`,
                  );
                  continue;
                }

                const started = nowMs;
                try {
                  log(
                    `settlement [spread]: running batch ${index} (${batch.taskName}, ${batch.users.length} users)`,
                  );
                  await withTimeout(batchDef.run(), TASK_TIMEOUT_MS, batch.taskName);
                  const completedAt = Date.now();
                  sState = markBatchCompleted(sState, index, batch.users, completedAt);
                  log(`settlement [spread]: batch ${index} done (${fmtMs(completedAt - started)})`);
                  // Clear any backoff state on success.
                  spreadBatchRetryAtMs.delete(retryKey);
                  spreadBatchRetryAttempt.delete(retryKey);
                } catch (e: any) {
                  log(
                    `settlement [spread]: batch ${index} failed: ${String(e?.shortMessage ?? e?.message ?? e)}`,
                  );
                  const failAt = Date.now();
                  const retryUntilMs =
                    batch.scheduledAtMs + config.settlementRetryWindowSecs * 1000;
                  if (failAt >= retryUntilMs) {
                    sState = markTaskFailed(sState, batch.taskName);
                    spreadBatchRetryAtMs.delete(retryKey);
                    spreadBatchRetryAttempt.delete(retryKey);
                  } else {
                    // Schedule exponential backoff before next retry.
                    // Cap at the retry window end so we don't sleep past the
                    // point where we'd mark the batch failed anyway.
                    const attempt = (spreadBatchRetryAttempt.get(retryKey) ?? 0) + 1;
                    spreadBatchRetryAttempt.set(retryKey, attempt);
                    const backoffMs = computeSpreadBackoffMs(attempt);
                    const nextAt = Math.min(failAt + backoffMs, retryUntilMs);
                    spreadBatchRetryAtMs.set(retryKey, nextAt);
                    log(
                      `settlement [spread]: batch ${index} still within retry window (${fmtMs(
                        retryUntilMs - failAt,
                      )} left); next retry in ${fmtMs(nextAt - failAt)} (attempt ${attempt})`,
                    );
                  }
                  if (e instanceof CircuitBreakerStateError) throw e;
                }
                persistSettlement();
              }
            }
          }
        }

        // Check if spread phase is complete
        if (sState.current && isSpreadPhaseComplete(sState.current)) {
          log('settlement: spread phase complete');
          sState = closeCycle(sState, config, Date.now());
          persistSettlement();
          logSettlementSummary(sState, log);
          continue;
        }
      }
    }

    // ---------------------------------------------------------------
    // Normal interval-based task loop
    // ---------------------------------------------------------------
    const now = Date.now();
    const due = tasks
      .filter((t) => now >= t.nextRunAtMs)
      .sort((a, b) => {
        const pa = TASK_PRIORITY[a.name] ?? 99;
        const pb = TASK_PRIORITY[b.name] ?? 99;
        if (pa !== pb) return pa - pb;
        return a.nextRunAtMs - b.nextRunAtMs;
      });

    if (!due.length) {
      const nextAt = Math.min(...tasks.map((t) => t.nextRunAtMs));
      const sleepMs = Math.max(250, nextAt - now);
      log(`daemon idle: sleeping ${fmtMs(sleepMs)} (next at ${new Date(nextAt).toISOString()})`);
      // Use an interruptible sleep so an incoming WS event can collapse
      // the remaining time — event_bus.onEventTrigger sets the affected
      // task's nextRunAtMs to 0 and then calls `wakeIdleSleep()`, so we
      // re-enter the loop immediately rather than waiting out an
      // (often long) polling interval.  When no event arrives the sleep
      // resolves normally, identical to the old `await sleep(sleepMs)`.
      const { promise, wake } = interruptibleSleep(sleepMs);
      wakeIdleSleep = wake;
      try {
        await promise;
      } finally {
        wakeIdleSleep = () => {};
      }
      continue;
    }

    for (const t of due) {
      assertLockHeld();
      const started = Date.now();
      try {
        log(`daemon: running ${t.name}`);
        await withTimeout(t.run(), TASK_TIMEOUT_MS, t.name);
      } catch (e: any) {
        log(`daemon task ${t.name} threw: ${String(e?.shortMessage ?? e?.message ?? e)}`);
        if (e instanceof CircuitBreakerStateError) {
          throw e;
        }
      } finally {
        const endedAt = Date.now();
        const elapsed = endedAt - started;
        t.lastRunEndMs = endedAt;
        // Resolve the interval freshly for each reschedule so the keeper
        // picks up tier AND ws-health changes without needing to restart.
        // For non-adaptive tasks this is identical to the old
        // `t.intervalMs`.
        const tier = currentTier();
        const wsStatus = computeWsStatus(eventBus, config.wsDisconnectedGraceSecs * 1000);
        const baseIntervalMs = effectiveIntervalMsForTask(t, config, tier, wsStatus);
        const nextDelayMs = jitteredIntervalMs(baseIntervalMs, config.daemonJitterBps);
        t.nextRunAtMs = endedAt + nextDelayMs;
        const cadenceTag = ADAPTIVE_CADENCE_TASKS.has(t.name)
          ? ` [tier=${tier} ws=${wsStatus}]`
          : '';
        log(
          `daemon: ${t.name} done (elapsed=${fmtMs(elapsed)}). next in ${fmtMs(nextDelayMs)}${cadenceTag}`,
        );
      }
    }
  }
}
