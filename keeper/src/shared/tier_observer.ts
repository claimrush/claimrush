/**
 * Tier observer — records the `x-rpc-proxy-upstream-tier` response header
 * seen on each upstream RPC call and exposes a summary (`primary` /
 * `fallback` / `unknown`) used by the keeper daemon to pick its scheduling
 * cadence.
 *
 * Design notes:
 *
 *  - The observer is a process-wide singleton.  The keeper has exactly one
 *    public RPC client per process, and the adaptive-cadence decision is
 *    process-wide (affects every task's `nextRunAtMs`), so there is no
 *    benefit to per-client scoping.  Keeping it as a module-level value
 *    also sidesteps the problem of threading an observer instance through
 *    every task function signature.
 *
 *  - We intentionally do NOT weight samples by time, latency, or request
 *    method.  A simple majority over the last N samples is both trivial to
 *    reason about and resilient to transient mis-routes (e.g. a single
 *    request that happened to probe the primary just before it was marked
 *    unhealthy).  If that proves too jittery in production, upgrade to an
 *    EWMA here without changing callers.
 *
 *  - `null` samples (header absent) are kept in the window rather than
 *    dropped.  That way a keeper misconfigured to bypass the proxy
 *    entirely degrades to `unknown` after N=20 calls, which the scheduler
 *    treats as the safe/fast primary cadence (as if on a local node) —
 *    the tier header is the trigger for slowing down, not for speeding up.
 */

export type Tier = 'primary' | 'fallback' | 'unknown';

const DEFAULT_WINDOW_SIZE = 20;

/**
 * Accepted values of the `x-rpc-proxy-upstream-tier` response header.
 * Any other string is coerced to `null` (treated as missing).
 */
function coerceSample(raw: string | null | undefined): 'primary' | 'fallback' | null {
  if (raw == null) return null;
  const v = String(raw).trim().toLowerCase();
  if (v === 'primary') return 'primary';
  if (v === 'fallback') return 'fallback';
  return null;
}

export interface TierObserver {
  recordTier(raw: string | null | undefined): void;
  currentTier(): Tier;
  /** For tests / diagnostics: snapshot of the rolling window. */
  samples(): Array<'primary' | 'fallback' | null>;
  /** For tests: reset the observer to an empty window. */
  reset(): void;
  /** Window size.  Exposed for tests. */
  windowSize: number;
}

export function createTierObserver(windowSize: number = DEFAULT_WINDOW_SIZE): TierObserver {
  if (!Number.isInteger(windowSize) || windowSize <= 0) {
    throw new Error(`tier_observer: windowSize must be a positive integer, got ${windowSize}`);
  }

  // Ring buffer implementation.  Not allocation-free, but allocation cost is
  // dwarfed by the RPC round-trip that produced the sample.
  const window: Array<'primary' | 'fallback' | null> = [];

  const recordTier = (raw: string | null | undefined): void => {
    const sample = coerceSample(raw);
    window.push(sample);
    if (window.length > windowSize) window.shift();
  };

  const currentTier = (): Tier => {
    if (window.length === 0) return 'unknown';

    let primary = 0;
    let fallback = 0;
    for (const s of window) {
      if (s === 'primary') primary += 1;
      else if (s === 'fallback') fallback += 1;
    }

    // If fewer than half the samples carried a tier header, we are likely
    // talking to something other than our proxy.  Fail open to the safe
    // fast-path cadence rather than silently stretch intervals.
    if (primary + fallback < Math.ceil(window.length / 2)) {
      return 'unknown';
    }

    // Strict majority for "fallback" — in a tie we prefer the faster
    // cadence, since the scheduler only slows down when confidently on a
    // fallback upstream.
    return fallback > primary ? 'fallback' : 'primary';
  };

  const samples = (): Array<'primary' | 'fallback' | null> => window.slice();

  const reset = (): void => {
    window.length = 0;
  };

  return {
    recordTier,
    currentTier,
    samples,
    reset,
    windowSize,
  };
}

// Module-level singleton used by the keeper's HTTP transport.
const globalObserver = createTierObserver();

export function recordTier(raw: string | null | undefined): void {
  globalObserver.recordTier(raw);
}

export function currentTier(): Tier {
  return globalObserver.currentTier();
}

export function tierObserverSamples(): Array<'primary' | 'fallback' | null> {
  return globalObserver.samples();
}

export function resetTierObserver(): void {
  globalObserver.reset();
}

/** Header name is exported so tests and client code don't hard-code a typo. */
export const TIER_HEADER_NAME = 'x-rpc-proxy-upstream-tier';
