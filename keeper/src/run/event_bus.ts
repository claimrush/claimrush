/**
 * Event bus: optional WebSocket layer that drives "hot" keeper tasks on
 * on-chain events instead of waiting for their polling cadence.
 *
 * ## Scope
 *
 * The bus is a strict optimization: if it fails entirely (WS URL unset,
 * WS server down, subscriptions never fire), the keeper still makes
 * forward progress because every hot task keeps its polling fallback
 * (see `effectiveIntervalMsForTask`) and the catch-up safety net (phase
 * 4d) will reconcile any missed events.  The bus only ever *pokes* the
 * scheduler to run a task sooner than its next polling slot — it never
 * runs tasks inline and never skips running a task.
 *
 * ## Connection model
 *
 * - Primary URL is `config.wsUrl`; if that drops we rotate to
 *   `config.wsUrlFallback`, then back to primary, then fallback, …
 * - Exponential backoff caps at 30 s between reconnect attempts.
 * - A `newHeads` subscription is opened on every (re)connect so the bus
 *   can report liveness as "saw a block in the last N seconds".  We
 *   don't trigger any task from `newHeads` itself — it's pure health
 *   signal.  That keeps the interface between the bus and the scheduler
 *   narrow: the bus fires `onTrigger(taskName, reason)` only when a log
 *   we've explicitly subscribed to arrives.
 *
 * ## Why not just run the task inline from the WS callback?
 *
 * - The scheduler already serializes tasks, enforces per-task timeouts,
 *   honours the circuit breaker, and acquires the host lock.  Going
 *   through it preserves all of those invariants "for free".
 * - A burst of events (e.g. dozens of market offers in one block) would
 *   otherwise start dozens of concurrent task runs.  Scheduling coalesces
 *   them: if the task is already due or running, further events are
 *   no-ops until the next cycle.
 */

import WebSocket from 'ws';

import { RpcWs, type RpcLog, type RpcBlockHeader } from '../shared/rpc_ws.js';
import type { LogFn } from './types.js';

/** Filter passed to `eth_subscribe('logs', filter)`. */
export interface LogFilter {
  address: string[];
  topics: Array<string | string[] | null>;
}

/** Reason why a task was triggered; attached to the `onTrigger` callback. */
export interface TriggerReason {
  /** Block number (hex string from the RPC, converted to `bigint` by us). */
  block: bigint;
  /** Log source: `address` + first topic (event signature hash). */
  source: { address: string; topic0: string };
  /** Transaction hash that emitted the log; helpful in debug logs. */
  txHash: string;
}

export type TriggerCallback = (taskName: string, reason: TriggerReason) => void;

export interface EventBusOptions {
  wsUrl: string | null;
  wsUrlFallback: string | null;
  log: LogFn;
  /**
   * Called when WS receives a log matching a subscribed filter.  The bus
   * never runs the task itself — it only signals the scheduler to wake
   * and re-evaluate.  Errors thrown by the callback are logged and
   * swallowed so the bus keeps dispatching subsequent events.
   */
  onTrigger: TriggerCallback;
  /**
   * Called after every successful (re)connect so the scheduler can, e.g.
   * reset its "WS unhealthy for too long" timer.  Optional.
   */
  onConnected?: () => void;
  /**
   * Called when the WS connection drops.  The bus will attempt to
   * reconnect on its own; this hook is purely informational.  Optional.
   */
  onDisconnected?: (err: Error | null) => void;
}

const WS_HEALTH_SILENCE_MS = 120_000;
const BACKOFF_INITIAL_MS = 1_000;
const BACKOFF_MAX_MS = 30_000;

interface Subscription {
  taskName: string;
  filter: LogFilter;
  subId: string | null;
}

/**
 * Event bus state machine:
 *
 *   stopped → connecting → open → (closed) → connecting → …
 *                      ↑                         ↓
 *                      └──── backoff reconnect ──┘
 *
 * `stop()` transitions to a terminal `stopped` state; once stopped, the
 * bus refuses to start again (callers make a fresh instance).  This
 * matches the one-instance-per-daemon-run lifecycle we need.
 */
export class EventBus {
  readonly wsUrl: string | null;
  readonly wsUrlFallback: string | null;
  readonly log: LogFn;

  #onTrigger: TriggerCallback;
  #onConnected: (() => void) | null;
  #onDisconnected: ((err: Error | null) => void) | null;

  #rpc: RpcWs | null;
  #state: 'stopped' | 'starting' | 'connecting' | 'open' | 'backoff' | 'closing';
  #subscriptions: Subscription[];

  /**
   * Which URL we last tried to connect to.  Used to alternate
   * primary/fallback on successive reconnect attempts.
   */
  #lastUrlTried: 'primary' | 'fallback' | null;

  #backoffMs: number;
  #backoffTimer: ReturnType<typeof setTimeout> | null;

  /** Monotonic counter for logging and for `getReconnectCount()`. */
  #connectAttempts: number;

  /** Last time (ms epoch) we received any message or a new head. */
  #lastMessageAtMs: number;

  /** Highest block we've observed via `newHeads` or via a subscribed log. */
  #lastEventBlock: bigint | null;

  /** Shutdown signaling: set to true by `stop()`; checked before reconnect. */
  #stopRequested: boolean;

  constructor(opts: EventBusOptions) {
    this.wsUrl = opts.wsUrl;
    this.wsUrlFallback = opts.wsUrlFallback;
    this.log = opts.log;
    this.#onTrigger = opts.onTrigger;
    this.#onConnected = opts.onConnected ?? null;
    this.#onDisconnected = opts.onDisconnected ?? null;

    this.#rpc = null;
    this.#state = 'stopped';
    this.#subscriptions = [];
    this.#lastUrlTried = null;
    this.#backoffMs = BACKOFF_INITIAL_MS;
    this.#backoffTimer = null;
    this.#connectAttempts = 0;
    this.#lastMessageAtMs = 0;
    this.#lastEventBlock = null;
    this.#stopRequested = false;
  }

  /**
   * Register a task to be triggered when any log matching `filter`
   * arrives over WS.  MUST be called before `start()`; after the bus
   * is running the subscription set is frozen (re-subscribes happen
   * automatically on every reconnect using this list).
   *
   * We keep the pre-start constraint because letting subscriptions be
   * added/removed live would double the test surface and, more
   * importantly, turn "did event X trigger task Y?" into a race against
   * connect timing.  Phase 4c configures the full list up front and we
   * haven't found a use case that needs dynamic subscriptions.
   */
  subscribe(taskName: string, filter: LogFilter): void {
    if (this.#state !== 'stopped') {
      throw new Error(
        `EventBus.subscribe() may only be called before start(); current state: ${this.#state}`,
      );
    }
    this.#subscriptions.push({ taskName, filter, subId: null });
  }

  /**
   * Open the WS and install every subscription registered via
   * `subscribe()`.  If no WS URL is configured, the bus logs an info
   * message and resolves immediately — callers can safely await this
   * even when WS is disabled.
   */
  async start(): Promise<void> {
    if (this.#state !== 'stopped') {
      throw new Error(`EventBus.start() called in state ${this.#state}`);
    }
    if (!this.wsUrl && !this.wsUrlFallback) {
      this.log('[event_bus] disabled (no KEEPER_WS_URL configured)');
      return;
    }

    this.#state = 'starting';
    this.#stopRequested = false;
    await this.#connectWithRetry();
  }

  /**
   * Close the WS cleanly.  Cancels any pending backoff timer.  Safe to
   * call from a signal handler.
   */
  async stop(): Promise<void> {
    this.#stopRequested = true;
    this.#state = 'closing';

    if (this.#backoffTimer) {
      clearTimeout(this.#backoffTimer);
      this.#backoffTimer = null;
    }

    const rpc = this.#rpc;
    this.#rpc = null;
    if (rpc && rpc.ws) {
      try {
        rpc.ws.close();
      } catch (err) {
        this.log(`[event_bus] error closing WS: ${String((err as Error)?.message ?? err)}`);
      }
    }

    this.#state = 'stopped';
  }

  /** True iff WS is open AND a message was seen in the last 2 min. */
  isHealthy(): boolean {
    if (this.#state !== 'open') return false;
    if (this.#lastMessageAtMs === 0) return false;
    return Date.now() - this.#lastMessageAtMs < WS_HEALTH_SILENCE_MS;
  }

  /** Last time (ms epoch) we received any WS message (log or newHeads). */
  getLastMessageAtMs(): number {
    return this.#lastMessageAtMs;
  }

  /**
   * Highest block number the bus has observed.  Used by the phase-4d
   * safety net to know where to start its catch-up scan.  Returns
   * `null` if we've never seen a block.
   */
  getLastEventBlock(): bigint | null {
    return this.#lastEventBlock;
  }

  /** Total successful connects since construction; exposed for metrics. */
  getReconnectCount(): number {
    return this.#connectAttempts;
  }

  /**
   * Pick which URL to try next.  Simple alternation: if we just tried
   * primary (or never tried anything), try fallback next and vice versa.
   * When only one URL is configured we stick with it.
   */
  #pickNextUrl(): { url: string; which: 'primary' | 'fallback' } | null {
    const hasPrimary = !!this.wsUrl;
    const hasFallback = !!this.wsUrlFallback;
    if (!hasPrimary && !hasFallback) return null;
    if (!hasFallback) return { url: this.wsUrl!, which: 'primary' };
    if (!hasPrimary) return { url: this.wsUrlFallback!, which: 'fallback' };

    const next: 'primary' | 'fallback' = this.#lastUrlTried === 'primary' ? 'fallback' : 'primary';
    return {
      url: next === 'primary' ? this.wsUrl! : this.wsUrlFallback!,
      which: next,
    };
  }

  async #connectWithRetry(): Promise<void> {
    const target = this.#pickNextUrl();
    if (!target) {
      this.log('[event_bus] no WS URL configured; bus will remain idle');
      this.#state = 'stopped';
      return;
    }
    this.#lastUrlTried = target.which;
    this.#state = 'connecting';
    this.#connectAttempts += 1;

    const rpc = new RpcWs(target.url, {
      onLog: (msg) => this.log(`[event_bus.ws] ${msg}`),
    });

    rpc.onClose = () => {
      // Only reconnect if we're not in the middle of tearing down.
      if (this.#stopRequested) return;
      this.log(
        `[event_bus] WS closed (url=${target.which}); scheduling reconnect in ${this.#backoffMs}ms`,
      );
      this.#state = 'backoff';
      if (this.#onDisconnected) {
        try {
          this.#onDisconnected(null);
        } catch (err) {
          this.log(
            `[event_bus] onDisconnected handler threw: ${String((err as Error)?.message ?? err)}`,
          );
        }
      }
      this.#scheduleReconnect();
    };

    try {
      await rpc.connect();
    } catch (err) {
      const msg = String((err as Error)?.message ?? err);
      this.log(`[event_bus] connect failed (url=${target.which}): ${msg}`);
      this.#state = 'backoff';
      this.#scheduleReconnect();
      return;
    }

    this.#rpc = rpc;
    this.#state = 'open';
    // Reset backoff on any successful connect.  The next failure will
    // start again from the initial delay — this matches the common
    // "quick recovery after blip" pattern.
    this.#backoffMs = BACKOFF_INITIAL_MS;
    this.log(
      `[event_bus] connected (url=${target.which}, attempt=${this.#connectAttempts}); installing ${this.#subscriptions.length} subscription(s)`,
    );

    try {
      await this.#installSubscriptions(rpc);
    } catch (err) {
      const msg = String((err as Error)?.message ?? err);
      this.log(`[event_bus] failed to install subscriptions: ${msg}; closing and retrying`);
      try {
        rpc.ws?.close();
      } catch {
        // closing a dead socket is best-effort
      }
      this.#state = 'backoff';
      this.#scheduleReconnect();
      return;
    }

    if (this.#onConnected) {
      try {
        this.#onConnected();
      } catch (err) {
        this.log(
          `[event_bus] onConnected handler threw: ${String((err as Error)?.message ?? err)}`,
        );
      }
    }
  }

  async #installSubscriptions(rpc: RpcWs): Promise<void> {
    await rpc.subscribeNewHeads((header: RpcBlockHeader) => this.#handleHead(header));

    for (const sub of this.#subscriptions) {
      const subId = await rpc.subscribeLogs(sub.filter, (logMsg: RpcLog) =>
        this.#handleLog(sub.taskName, logMsg),
      );
      sub.subId = subId;
    }
  }

  #handleHead(header: RpcBlockHeader): void {
    this.#lastMessageAtMs = Date.now();
    const num = parseBlockNumber(header.number);
    if (num != null) {
      if (this.#lastEventBlock == null || num > this.#lastEventBlock) {
        this.#lastEventBlock = num;
      }
    }
  }

  #handleLog(taskName: string, logMsg: RpcLog): void {
    if (logMsg.removed) {
      // Reorg'd logs are not useful for triggering — the safety net
      // will reconcile on its next pass if a permanent log replaces this.
      return;
    }
    this.#lastMessageAtMs = Date.now();
    const num = parseBlockNumber(logMsg.blockNumber);
    if (num != null) {
      if (this.#lastEventBlock == null || num > this.#lastEventBlock) {
        this.#lastEventBlock = num;
      }
    }
    const topic0 = Array.isArray(logMsg.topics) && logMsg.topics.length > 0 ? logMsg.topics[0] : '';
    try {
      this.#onTrigger(taskName, {
        block: num ?? 0n,
        source: { address: logMsg.address, topic0 },
        txHash: logMsg.transactionHash,
      });
    } catch (err) {
      this.log(
        `[event_bus] onTrigger(${taskName}) threw: ${String((err as Error)?.message ?? err)}`,
      );
    }
  }

  #scheduleReconnect(): void {
    if (this.#stopRequested) return;
    if (this.#backoffTimer) clearTimeout(this.#backoffTimer);
    const delay = this.#backoffMs;
    this.#backoffMs = Math.min(this.#backoffMs * 2, BACKOFF_MAX_MS);
    this.#backoffTimer = setTimeout(() => {
      this.#backoffTimer = null;
      void this.#connectWithRetry();
    }, delay);
  }
}

/**
 * Parse a hex-prefixed block number.  Returns `null` on anything
 * unexpected so bad RPC payloads can't crash the bus.
 */
function parseBlockNumber(raw: string | undefined): bigint | null {
  if (typeof raw !== 'string' || !raw) return null;
  try {
    return BigInt(raw);
  } catch {
    return null;
  }
}

// Silence "unused import" when ws types aren't referenced outside the
// RpcWs wrapper.  Keeping the import ensures the ws peer dep is resolved
// from this module's type graph.
export type _WsRef = typeof WebSocket;
