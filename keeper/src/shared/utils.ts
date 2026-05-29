export function sleep(ms: number): Promise<void> {
  return new Promise((resolve) => setTimeout(resolve, ms));
}

/**
 * Sleep that can be woken early by calling the returned `wake()` function.
 *
 * Designed for the keeper's idle-sleep in the main loop: when a WS event
 * arrives the event bus calls `wake()` to collapse the remaining sleep
 * so the scheduler can re-evaluate immediately, without polluting the
 * loop with `AbortController` plumbing at every call site.
 *
 * Idempotent: repeated `wake()` calls are no-ops after the first.
 * `ms <= 0` resolves synchronously on the microtask queue.
 */
export function interruptibleSleep(ms: number): {
  promise: Promise<void>;
  wake: () => void;
} {
  let wake!: () => void;
  let woken = false;
  const promise = new Promise<void>((resolve) => {
    if (ms <= 0) {
      woken = true;
      resolve();
      wake = () => {};
      return;
    }
    const timer = setTimeout(() => {
      if (woken) return;
      woken = true;
      resolve();
    }, ms);
    wake = () => {
      if (woken) return;
      woken = true;
      clearTimeout(timer);
      resolve();
    };
  });
  return { promise, wake };
}

export function clamp(
  n: number,
  { min, max }: { min?: number | null; max?: number | null },
): number {
  let x = n;
  if (min != null && x < min) x = min;
  if (max != null && x > max) x = max;
  return x;
}

export function toBigIntSafe(
  v: unknown,
  { defaultValue = 0n }: { defaultValue?: bigint } = {},
): bigint {
  if (v == null) return defaultValue;
  if (typeof v === 'bigint') return v;
  if (typeof v === 'number') {
    if (!Number.isFinite(v) || !Number.isInteger(v)) return defaultValue;
    try {
      return BigInt(v);
    } catch {
      return defaultValue;
    }
  }
  const s = String(v).trim();
  if (!s) return defaultValue;
  try {
    if (s.startsWith('0x') || s.startsWith('0X')) return BigInt(s);
    return BigInt(s);
  } catch {
    return defaultValue;
  }
}

/**
 * Best-effort bigint parsing.
 *
 * Use for on-disk state values (JSON) where corruption/manual edits are possible.
 * Returns null instead of throwing.
 */
export function parseBigIntOrNull(v: unknown): bigint | null {
  if (v == null) return null;
  if (typeof v === 'bigint') return v;
  if (typeof v === 'number') {
    if (!Number.isFinite(v) || !Number.isInteger(v)) return null;
    return BigInt(v);
  }

  const s = String(v).trim();
  if (!s) return null;
  try {
    return BigInt(s);
  } catch {
    return null;
  }
}

/**
 * Best-effort unsigned bigint parsing (>= 0).
 *
 * Useful for on-disk state values that represent uint IDs (tokenId, offerId, …).
 * Returns null for negative values to avoid pathological calls like BigInt(-1).
 */
export function parseUintBigIntOrNull(v: unknown): bigint | null {
  const n = parseBigIntOrNull(v);
  if (n == null) return null;
  if (n < 0n) return null;
  return n;
}

export function parseNonNegativeSafeInteger(
  v: unknown,
  { defaultValue = null }: { defaultValue?: number | null } = {},
): number | null {
  if (typeof v === 'number') {
    return Number.isSafeInteger(v) && v >= 0 ? v : defaultValue;
  }
  if (typeof v === 'bigint') {
    if (v < 0n || v > BigInt(Number.MAX_SAFE_INTEGER)) return defaultValue;
    return Number(v);
  }
  const s = String(v ?? '').trim();
  if (!s) return defaultValue;
  if (!/^(?:0|[1-9]\d*)$/.test(s)) return defaultValue;
  const parsed = Number(s);
  return Number.isSafeInteger(parsed) ? parsed : defaultValue;
}

export function parsePositiveSafeInteger(
  v: unknown,
  { defaultValue = null }: { defaultValue?: number | null } = {},
): number | null {
  const parsed = parseNonNegativeSafeInteger(v, { defaultValue });
  return parsed != null && parsed > 0 ? parsed : defaultValue;
}

export function applyBps(amount: bigint, bps: number | bigint): bigint {
  const denom = 10_000n;
  const b = BigInt(bps);
  if (b <= 0n) return amount;
  if (b >= denom) return 0n;
  return (amount * (denom - b)) / denom;
}

export function fmtMs(ms: number): string {
  if (!Number.isFinite(ms)) return `${ms}`;
  if (ms < 1000) return `${ms}ms`;
  const s = ms / 1000;
  if (s < 60) return `${s.toFixed(1)}s`;
  const m = Math.floor(s / 60);
  const r = Math.floor(s % 60);
  return `${m}m${r}s`;
}

export function shortAddr(addr: string | null | undefined): string {
  if (!addr || typeof addr !== 'string') return String(addr);
  if (addr.length < 12) return addr;
  return `${addr.slice(0, 6)}...${addr.slice(-4)}`;
}
