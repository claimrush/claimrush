import type { KeeperConfig } from './config.js';
import { loadJsonDetailed, nowUtcIso, saveJsonAtomic } from './state.js';
import { writePauseFile } from './pause.js';
import { parseNonNegativeSafeInteger, parsePositiveSafeInteger } from './utils.js';

export type CircuitBreakerState = {
  version: 1;
  consecutiveFailures: number;
  lastFailureAtUtc: string | null;
  lastSuccessAtUtc: string | null;
  trippedAtUtc: string | null;
  pausedUntilUtc: string | null;
  lastError: string | null;
};

export class CircuitBreakerStateError extends Error {
  readonly statePath: string;

  constructor(message: string, statePath: string) {
    super(message);
    this.name = 'CircuitBreakerStateError';
    this.statePath = statePath;
  }
}

function initState(): CircuitBreakerState {
  return {
    version: 1,
    consecutiveFailures: 0,
    lastFailureAtUtc: null,
    lastSuccessAtUtc: null,
    trippedAtUtc: null,
    pausedUntilUtc: null,
    lastError: null,
  };
}

function requireOptionalString(
  value: unknown,
  { field, statePath }: { field: string; statePath: string },
): string | null {
  if (value == null) return null;
  if (typeof value === 'string') return value;
  throw new CircuitBreakerStateError(
    `circuit breaker state field ${field} must be a string or null (${statePath})`,
    statePath,
  );
}

function requireOptionalIsoTimestamp(
  value: unknown,
  { field, statePath }: { field: string; statePath: string },
): string | null {
  const out = requireOptionalString(value, { field, statePath });
  if (out == null) return null;
  if (!Number.isFinite(Date.parse(out))) {
    throw new CircuitBreakerStateError(
      `circuit breaker state field ${field} must be a valid ISO timestamp or null (${statePath})`,
      statePath,
    );
  }
  return out;
}

function safeDateMs(iso: string | null | undefined): number | null {
  if (!iso) return null;
  const ms = Date.parse(String(iso));
  return Number.isFinite(ms) ? ms : null;
}

function computePausedUntilUtc({
  trippedAtUtc,
  cooldownMs,
}: {
  trippedAtUtc: string;
  cooldownMs: number | null | undefined;
}): string | null {
  const cooldown = parsePositiveSafeInteger(cooldownMs);
  if (cooldown == null) return null;
  const trippedAtMs = safeDateMs(trippedAtUtc);
  if (trippedAtMs == null) return null;
  return new Date(trippedAtMs + cooldown).toISOString();
}

function getEffectivePausedUntilUtc({
  state,
  cooldownMs,
}: {
  state: CircuitBreakerState;
  cooldownMs: number | null | undefined;
}): string | null {
  if (state.pausedUntilUtc) return state.pausedUntilUtc;
  if (!state.trippedAtUtc) return null;
  return computePausedUntilUtc({ trippedAtUtc: state.trippedAtUtc, cooldownMs });
}

function requireState(x: unknown, statePath: string): CircuitBreakerState {
  if (!x || typeof x !== 'object' || Array.isArray(x)) {
    throw new CircuitBreakerStateError(
      `circuit breaker state must be a JSON object (${statePath})`,
      statePath,
    );
  }

  const s = x as Partial<CircuitBreakerState>;
  if (s.version !== 1) {
    throw new CircuitBreakerStateError(
      `circuit breaker state version must be 1 (${statePath})`,
      statePath,
    );
  }

  const consecutiveFailures = parseNonNegativeSafeInteger(s.consecutiveFailures, {
    defaultValue: null,
  });
  if (consecutiveFailures == null) {
    throw new CircuitBreakerStateError(
      `circuit breaker consecutiveFailures must be a non-negative integer (${statePath})`,
      statePath,
    );
  }

  return {
    version: 1,
    consecutiveFailures,
    lastFailureAtUtc: requireOptionalIsoTimestamp(s.lastFailureAtUtc, {
      field: 'lastFailureAtUtc',
      statePath,
    }),
    lastSuccessAtUtc: requireOptionalIsoTimestamp(s.lastSuccessAtUtc, {
      field: 'lastSuccessAtUtc',
      statePath,
    }),
    trippedAtUtc: requireOptionalIsoTimestamp(s.trippedAtUtc, {
      field: 'trippedAtUtc',
      statePath,
    }),
    pausedUntilUtc: requireOptionalIsoTimestamp(s.pausedUntilUtc, {
      field: 'pausedUntilUtc',
      statePath,
    }),
    lastError: requireOptionalString(s.lastError, {
      field: 'lastError',
      statePath,
    }),
  };
}

export function loadCircuitBreakerState(statePath: string): CircuitBreakerState {
  const cur = loadJsonDetailed(statePath);
  if (cur.kind === 'missing') return initState();
  if (cur.kind === 'error') {
    throw new CircuitBreakerStateError(
      `circuit breaker state unreadable or invalid JSON (${statePath}): ${String(cur.error?.message ?? cur.error)}`,
      statePath,
    );
  }
  return requireState(cur.value, statePath);
}

export function assertCircuitBreakerStateHealthy(config: KeeperConfig): CircuitBreakerState {
  if (!config.circuitBreakerEnabled) return initState();
  return loadCircuitBreakerState(config.circuitBreakerStatePath);
}

export function getCircuitBreakerPauseInfo(
  config: KeeperConfig,
  state: CircuitBreakerState = assertCircuitBreakerStateHealthy(config),
): { paused: boolean; untilUtc: string | null; reason: string | null; source: 'state' | null } {
  if (!config.circuitBreakerEnabled) {
    return { paused: false, untilUtc: null, reason: null, source: null };
  }
  if (!state.trippedAtUtc) {
    return { paused: false, untilUtc: null, reason: null, source: null };
  }

  const untilUtc = getEffectivePausedUntilUtc({
    state,
    cooldownMs: config.circuitBreakerCooldownMs,
  });
  const untilMs = safeDateMs(untilUtc);
  if (untilMs != null && untilMs <= Date.now()) {
    return { paused: false, untilUtc, reason: null, source: null };
  }

  return {
    paused: true,
    untilUtc,
    reason: 'circuit breaker tripped',
    source: 'state',
  };
}

export function recordTxSuccess(config: KeeperConfig): CircuitBreakerState {
  if (!config.circuitBreakerEnabled) return initState();

  const cur = loadCircuitBreakerState(config.circuitBreakerStatePath);
  const next: CircuitBreakerState = {
    ...cur,
    consecutiveFailures: 0,
    lastSuccessAtUtc: nowUtcIso(),
    trippedAtUtc: null,
    pausedUntilUtc: null,
    lastError: null,
  };
  saveJsonAtomic(config.circuitBreakerStatePath, next);
  return next;
}

export function recordTxFailure({ config, error }: { config: KeeperConfig; error: string }): {
  state: CircuitBreakerState;
  tripped: boolean;
} {
  if (!config.circuitBreakerEnabled) {
    return { state: initState(), tripped: false };
  }

  const cur0 = loadCircuitBreakerState(config.circuitBreakerStatePath);

  const maxFailures =
    Number.isFinite(config.circuitBreakerMaxFailures) && config.circuitBreakerMaxFailures > 0
      ? Math.trunc(config.circuitBreakerMaxFailures)
      : 1;

  // If we previously tripped with a cooldown and the cooldown has passed, reset the
  // failure counter so we don't immediately re-trip after a single failure post-cooldown.
  const nowMs = Date.now();
  const effectivePausedUntilUtc = getEffectivePausedUntilUtc({
    state: cur0,
    cooldownMs: config.circuitBreakerCooldownMs,
  });
  const untilMs = safeDateMs(effectivePausedUntilUtc);
  const cooldownExpired = untilMs !== null && Number.isFinite(untilMs) && untilMs <= nowMs;

  const cur: CircuitBreakerState = cooldownExpired
    ? {
        ...cur0,
        consecutiveFailures: 0,
        trippedAtUtc: null,
        pausedUntilUtc: null,
      }
    : cur0;

  const next: CircuitBreakerState = {
    ...cur,
    consecutiveFailures: Math.min(
      (parseNonNegativeSafeInteger(cur.consecutiveFailures, { defaultValue: 0 }) ?? 0) + 1,
      maxFailures + 10,
    ),
    lastFailureAtUtc: nowUtcIso(),
    lastError: String(error ?? '').slice(0, 2048),
  };

  let tripped = false;

  // After a cooldown expires, the first failure is a "probe" to see if the
  // underlying issue is resolved. Do not re-trip on the first failure after
  // cooldown — require at least maxFailures again. This prevents a permanent
  // trip-cooldown-trip loop when maxFailures=1.
  const effectiveThreshold = cooldownExpired ? Math.max(maxFailures, 2) : maxFailures;

  if (next.consecutiveFailures >= effectiveThreshold) {
    // Important: allow re-tripping after a cooldown.
    // Previously, we only tripped once until a tx success occurred, which could allow
    // infinite failing tx attempts after the pause file auto-cleared.
    const trippedAtUtc = nowUtcIso();

    next.trippedAtUtc = trippedAtUtc;
    next.pausedUntilUtc = computePausedUntilUtc({
      trippedAtUtc,
      cooldownMs: config.circuitBreakerCooldownMs,
    });

    try {
      const pause = writePauseFile({
        pauseFilePath: config.pauseFilePath,
        reason: `circuit breaker tripped after ${next.consecutiveFailures} consecutive tx failures`,
        cooldownMs: config.circuitBreakerCooldownMs,
        details: {
          deployment: config.deployment,
          lastError: next.lastError,
          maxFailures,
        },
      });

      next.pausedUntilUtc = pause.pausedUntilUtc;
      tripped = true;
    } catch (e: unknown) {
      // Fail closed: if we can't write the pause file, keep the tripped cooldown
      // in circuit_breaker.json so future sends still stop.
      const msg = String((e as Error)?.message ?? e);
      next.lastError = `${next.lastError ?? ''} (circuit breaker pause write failed: ${msg})`;
      tripped = true;
    }
  }

  saveJsonAtomic(config.circuitBreakerStatePath, next);
  return { state: next, tripped };
}
