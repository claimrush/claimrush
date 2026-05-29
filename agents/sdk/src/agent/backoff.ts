import type { ClaimRushErrorKind, ClaimRushErrorInfo } from '../errors.js';
import type { AgentActionResult } from './types.js';

export type BackoffConfig = {
  enabled: boolean;

  /** Base cooldown duration when entering backoff for the first time (ms). */
  baseCooldownMs: number;

  /** Maximum cooldown duration (ms). */
  maxCooldownMs: number;

  /** Multiplier applied when entering backoff repeatedly. */
  multiplier: number;

  /** Enter backoff after this many consecutive tx timeouts. */
  maxConsecutiveTimeouts: number;

  /** Enter backoff after this many consecutive errors (any kind). */
  maxConsecutiveErrors: number;

  /** Reset error streak if no error has occurred for this long (ms). */
  resetAfterMs: number;

  /** Which error kinds count toward the generic error streak (default: all). */
  countErrorKinds?: ClaimRushErrorKind[];
};

export type BackoffState = {
  active: boolean;
  cooldownUntilMs: number;
  cooldownMs: number;
  consecutiveErrors: number;
  consecutiveTimeouts: number;
  lastErrorAtMs?: number;
  lastErrorKind?: ClaimRushErrorKind;
  lastErrorName?: string;
  lastActionKind?: string;
};

export type BackoffTransition =
  | {
      kind: 'entered';
      state: BackoffState;
      reason: {
        errorKind: ClaimRushErrorKind;
        errorName?: string;
        message?: string;
        actionKind?: string;
      };
    }
  | { kind: 'cleared'; state: BackoffState };

function clamp(n: number, min: number, max: number): number {
  return Math.max(min, Math.min(max, n));
}

function inferErrorInfo(res: AgentActionResult): ClaimRushErrorInfo | undefined {
  // executor sets errorInfo for viem errors; some callers may stash it under details.
  const direct = (res as any).errorInfo as ClaimRushErrorInfo | undefined;
  if (direct) return direct;
  const details = res.details as any;
  const nested = details?.errorInfo as ClaimRushErrorInfo | undefined;
  if (nested) return nested;
  return undefined;
}

function shouldCountErrorKind(kind: ClaimRushErrorKind, allowList?: ClaimRushErrorKind[]): boolean {
  if (!allowList || allowList.length === 0) return true;
  return allowList.includes(kind);
}

export const DEFAULT_BACKOFF_CONFIG: BackoffConfig = {
  enabled: true,
  baseCooldownMs: 15_000,
  maxCooldownMs: 5 * 60_000,
  multiplier: 2,
  maxConsecutiveTimeouts: 1,
  maxConsecutiveErrors: 3,
  resetAfterMs: 2 * 60_000,
  countErrorKinds: undefined,
};

/**
 * Lightweight circuit-breaker for the live agent.
 *
 * Purpose:
 * - avoid repeatedly broadcasting failing txs (timeouts/reverts) when conditions are bad
 * - allow the agent to keep simulating/observing state while pausing writes
 */
export class BackoffController {
  readonly cfg: BackoffConfig;
  private state: BackoffState;

  constructor(cfg?: Partial<BackoffConfig>) {
    this.cfg = { ...DEFAULT_BACKOFF_CONFIG, ...(cfg ?? {}) };
    this.state = {
      active: false,
      cooldownUntilMs: 0,
      cooldownMs: 0,
      consecutiveErrors: 0,
      consecutiveTimeouts: 0,
    };
  }

  snapshot(): BackoffState {
    return { ...this.state };
  }

  isActive(nowMs: number = Date.now()): boolean {
    if (!this.cfg.enabled) return false;
    if (!this.state.active) return false;
    if (nowMs >= this.state.cooldownUntilMs) return false;
    return true;
  }

  remainingMs(nowMs: number = Date.now()): number {
    if (!this.isActive(nowMs)) return 0;
    return Math.max(0, this.state.cooldownUntilMs - nowMs);
  }

  /**
   * Called on each loop tick to clear expired cooldowns and optionally reset streaks.
   */
  maybeClear(nowMs: number = Date.now()): BackoffTransition | undefined {
    if (!this.cfg.enabled) return undefined;

    // Clear active cooldown once expired.
    if (this.state.active && nowMs >= this.state.cooldownUntilMs) {
      this.state = {
        ...this.state,
        active: false,
        cooldownUntilMs: 0,
      };
      return { kind: 'cleared', state: this.snapshot() };
    }

    // Reset streak if enough time has passed since the last error.
    if (this.state.lastErrorAtMs && nowMs - this.state.lastErrorAtMs >= this.cfg.resetAfterMs) {
      this.state = {
        ...this.state,
        consecutiveErrors: 0,
        consecutiveTimeouts: 0,
        lastErrorAtMs: undefined,
        lastErrorKind: undefined,
        lastErrorName: undefined,
        lastActionKind: undefined,
        // Also decay cooldown magnitude after long stability.
        cooldownMs: 0,
      };
    }

    return undefined;
  }

  /**
   * Record the outcome of an action and possibly enter backoff.
   */
  onActionResult(
    res: AgentActionResult,
    nowMs: number = Date.now(),
  ): BackoffTransition | undefined {
    if (!this.cfg.enabled) return undefined;

    // Ignore simulated results for streak accounting.
    if (res.simulated) return undefined;

    // Success: reset streak counters.
    if (!res.error) {
      this.state = {
        ...this.state,
        consecutiveErrors: 0,
        consecutiveTimeouts: 0,
        lastErrorAtMs: undefined,
        lastErrorKind: undefined,
        lastErrorName: undefined,
        lastActionKind: undefined,
      };
      return undefined;
    }

    const info = inferErrorInfo(res);
    const kind = info?.kind ?? ('unknown' as ClaimRushErrorKind);

    // Reset streaks if the last error was too long ago.
    if (this.state.lastErrorAtMs && nowMs - this.state.lastErrorAtMs >= this.cfg.resetAfterMs) {
      this.state = {
        ...this.state,
        consecutiveErrors: 0,
        consecutiveTimeouts: 0,
        cooldownMs: 0,
      };
    }

    const actionKind = (res.action as any)?.kind as string | undefined;

    const countThis = shouldCountErrorKind(kind, this.cfg.countErrorKinds);

    const consecutiveErrors = countThis
      ? this.state.consecutiveErrors + 1
      : this.state.consecutiveErrors;
    const consecutiveTimeouts =
      kind === 'tx_timeout' ? this.state.consecutiveTimeouts + 1 : this.state.consecutiveTimeouts;

    this.state = {
      ...this.state,
      consecutiveErrors,
      consecutiveTimeouts,
      lastErrorAtMs: nowMs,
      lastErrorKind: kind,
      lastErrorName: info?.errorName,
      lastActionKind: actionKind,
    };

    const hitTimeoutThreshold = consecutiveTimeouts >= Math.max(1, this.cfg.maxConsecutiveTimeouts);
    const hitErrorThreshold = consecutiveErrors >= Math.max(1, this.cfg.maxConsecutiveErrors);

    if (!hitTimeoutThreshold && !hitErrorThreshold) return undefined;

    const prevCooldown = this.state.cooldownMs;
    const nextCooldown =
      prevCooldown > 0
        ? clamp(
            Math.floor(prevCooldown * this.cfg.multiplier),
            this.cfg.baseCooldownMs,
            this.cfg.maxCooldownMs,
          )
        : clamp(this.cfg.baseCooldownMs, 1, this.cfg.maxCooldownMs);

    this.state = {
      ...this.state,
      active: true,
      cooldownMs: nextCooldown,
      cooldownUntilMs: nowMs + nextCooldown,
    };

    return {
      kind: 'entered',
      state: this.snapshot(),
      reason: {
        errorKind: kind,
        errorName: info?.errorName,
        message: info?.message,
        actionKind,
      },
    };
  }
}
