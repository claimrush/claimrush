import { parseNonNegativeSafeInteger } from './utils.js';

function normalizeFiniteNonNegativeNumber(value: unknown, defaultValue: number): number {
  if (typeof value === 'number') {
    return Number.isFinite(value) && value >= 0 ? value : defaultValue;
  }
  if (typeof value === 'bigint') {
    if (value < 0n || value > BigInt(Number.MAX_SAFE_INTEGER)) return defaultValue;
    return Number(value);
  }
  return defaultValue;
}

export function applySymmetricJitterBps(value: number, jitterBps: unknown): number {
  const base = normalizeFiniteNonNegativeNumber(value, 0);
  if (!base) return 0;

  const parsedJitter = parseNonNegativeSafeInteger(jitterBps, { defaultValue: 0 }) ?? 0;
  if (!parsedJitter) return base;

  const clampedJitterBps = Math.min(parsedJitter, 10_000);
  const spread = clampedJitterBps / 10_000;
  const offset = (Math.random() * 2 - 1) * spread;
  const jittered = base * (1 + offset);
  return Number.isFinite(jittered) && jittered >= 0 ? jittered : base;
}

export function computeExponentialBackoffDelayMs(args: {
  failureCount: unknown;
  initialMs: number;
  multiplier: number;
  maxMs: number;
  jitterBps?: unknown;
}): number {
  const count = parseNonNegativeSafeInteger(args.failureCount, { defaultValue: 0 }) ?? 0;
  if (count <= 0) return 0;

  const base = normalizeFiniteNonNegativeNumber(args.initialMs, 0);
  const multiplier = Math.max(1, normalizeFiniteNonNegativeNumber(args.multiplier, 1));
  const cap = normalizeFiniteNonNegativeNumber(args.maxMs, 0);
  if (cap <= 0) return 0;

  let delay = base * Math.pow(multiplier, Math.max(0, count - 1));
  if (!Number.isFinite(delay) || delay < 0) delay = cap;
  delay = Math.min(delay, cap);

  const jittered = applySymmetricJitterBps(delay, args.jitterBps);
  const rounded = Math.round(jittered);
  if (!Number.isFinite(rounded) || rounded < 0) return cap;
  return Math.min(cap, rounded);
}
