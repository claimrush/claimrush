import { applySymmetricJitterBps } from '../shared/backoff.js';
import { parsePositiveSafeInteger } from '../shared/utils.js';

export function jitteredIntervalMs(intervalMs: number, jitterBps: number): number {
  const baseIntervalMs = parsePositiveSafeInteger(intervalMs, { defaultValue: 0 }) ?? 0;
  if (!baseIntervalMs) return 0;
  // jitter this is fine (predictability of task timing is not a security threat),
  // but if jitter were ever used for security-sensitive randomness (e.g., nonce
  // generation, backoff in adversarial contexts), this would need to be replaced
  // with crypto.getRandomValues().
  const out = Math.round(applySymmetricJitterBps(baseIntervalMs, jitterBps));
  return Math.max(0, out);
}

// If the system clock drifts forward and later corrects backwards (NTP/VM clock
// adjustments), status timestamps may appear "in the future". Without a guard,
// the daemon can stall tasks until that future time is reached.
const MAX_FUTURE_SKEW_MS = 5 * 60 * 1000; // 5 minutes

export function computeInitialNextRunMs(args: {
  nowMs: number;
  lastAttemptByTask: Record<string, string | null> | null;
  statusKey: string;
  intervalMs: number;
}): number {
  const { nowMs, lastAttemptByTask, statusKey, intervalMs } = args;
  const last = lastAttemptByTask?.[statusKey];
  if (!last) return nowMs;

  const parsed = Date.parse(last);
  if (!Number.isFinite(parsed)) return nowMs;

  // Clamp unreasonably-future timestamps (clock skew) so we don't sleep for hours.
  const skewMs = parsed - nowMs;
  if (skewMs > MAX_FUTURE_SKEW_MS) return nowMs;

  const iv = parsePositiveSafeInteger(intervalMs, { defaultValue: null });
  if (iv == null) return nowMs;

  const dueAt = parsed + iv;
  return dueAt <= nowMs ? nowMs : dueAt;
}
