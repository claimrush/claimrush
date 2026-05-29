import { parseStrictNonNegativeSafeInteger, parseStrictPositiveSafeInteger } from '../integers.js';

export type AsyncTtlCacheOptions = {
  /** Maximum number of cache entries to keep (best-effort). Default: 10_000. */
  maxEntries?: number;
  /** Override time source (ms since epoch). */
  now?: () => number;
};

const DEFAULT_MAX_ENTRIES = 10_000;

const MISSING = Symbol('cache-miss');

type CacheEntry<V> = {
  expiresAtMs: number;
  lastAccessMs: number;
  value: V | typeof MISSING;
  inFlight?: Promise<V>;
};

function defaultNow(): number {
  return Date.now();
}

/**
 * Small in-memory async TTL cache with in-flight de-dupe.
 *
 * Notes
 * - If multiple callers request the same key while the value is being computed, they share the same Promise.
 * - On rejection, the entry is dropped so the next caller can retry.
 */
export class AsyncTtlCache<V> {
  private readonly map = new Map<string, CacheEntry<V>>();
  private readonly maxEntries: number;
  private readonly now: () => number;

  constructor(opts: AsyncTtlCacheOptions = {}) {
    // Fail-closed: fractional or otherwise malformed values fall back to the
    // default rather than silently truncating (e.g. 2.5 → 2).
    this.maxEntries =
      opts.maxEntries === undefined
        ? DEFAULT_MAX_ENTRIES
        : (parseStrictPositiveSafeInteger(opts.maxEntries) ?? DEFAULT_MAX_ENTRIES);
    this.now = opts.now ?? defaultNow;
  }

  get size(): number {
    return this.map.size;
  }

  clear(): void {
    this.map.clear();
  }

  delete(key: string): void {
    this.map.delete(key);
  }

  get(key: string): V | undefined {
    const ent = this.map.get(key);
    if (!ent) return undefined;

    const now = this.now();
    if (ent.expiresAtMs <= now) {
      this.map.delete(key);
      return undefined;
    }

    ent.lastAccessMs = now;
    return ent.value === MISSING ? undefined : ent.value;
  }

  set(key: string, value: V, ttlMs: number): void {
    // Fail-closed: malformed or fractional TTL values are treated as "do not
    // cache" rather than silently truncating, so stale / wrong-shaped TTLs
    // never extend an entry's lifetime beyond what the caller intended.
    const ttl = parseStrictNonNegativeSafeInteger(ttlMs);
    if (ttl === undefined || ttl <= 0) return;
    const now = this.now();
    this.map.set(key, { value, expiresAtMs: now + ttl, lastAccessMs: now });
    this.pruneIfNeeded();
  }

  /**
   * Get a cached value or compute + cache it.
   *
   * If ttlMs <= 0, no caching is performed.
   */
  async getOrSet(key: string, ttlMs: number, fn: () => Promise<V>): Promise<V> {
    // `undefined`, the cache stores { value: undefined } and future calls will
    // see `ent.value !== undefined` as FALSE, so they will re-invoke fn().
    // However, there is a brief window where the inFlight promise is stored
    // with value=undefined, and concurrent callers will await the same promise
    // and receive undefined — which is correct behavior but surprising.
    //
    // More importantly: if an attacker can cause fn() to throw intermittently,
    // the cache deletes the entry on error (line 100). But between the throw
    // and the delete, other callers may have already started a new fn() call,
    // creating a thundering-herd effect that amplifies RPC load.
    // FIX: Consider adding a short "negative cache" TTL (e.g. 1s) on error
    //      to prevent thundering herd:
    //        this.map.set(key, { value: undefined, inFlight: undefined,
    //          expiresAtMs: this.now() + 1000, lastAccessMs: this.now() });
    // Fail-closed: malformed or fractional TTL values skip caching entirely
    // and just call fn(). This mirrors `set()` so concurrent callers never
    // receive a stale value wedged in by a wrong-shaped TTL.
    const ttl = parseStrictNonNegativeSafeInteger(ttlMs);
    if (ttl === undefined || ttl <= 0) return await fn();

    const now = this.now();
    const ent = this.map.get(key);

    if (ent && ent.expiresAtMs > now) {
      ent.lastAccessMs = now;
      if (ent.value !== MISSING) return ent.value;
      if (ent.inFlight) return await ent.inFlight;
    }

    const p = (async () => {
      try {
        const v = await fn();
        this.map.set(key, {
          value: v,
          expiresAtMs: this.now() + ttl,
          lastAccessMs: this.now(),
        });
        this.pruneIfNeeded();
        return v;
      } catch (err) {
        const cooldownMs = Math.min(ttl, Math.max(1_000, Math.min(2_000, ttl)));
        const rejection = Promise.reject(err);
        rejection.catch(() => {});
        this.map.set(key, {
          value: MISSING,
          inFlight: rejection,
          expiresAtMs: this.now() + cooldownMs,
          lastAccessMs: this.now(),
        });
        throw err;
      }
    })();

    this.map.set(key, {
      value: MISSING,
      inFlight: p,
      expiresAtMs: now + ttl,
      lastAccessMs: now,
    });

    this.pruneIfNeeded();
    return await p;
  }

  private pruneIfNeeded(): void {
    if (this.map.size <= this.maxEntries) return;

    // Best-effort LRU prune (remove the oldest ~10%).
    const entries = [...this.map.entries()];
    entries.sort((a, b) => a[1].lastAccessMs - b[1].lastAccessMs);

    const toRemove = Math.max(1, Math.floor(this.maxEntries * 0.1));
    for (let i = 0; i < toRemove && i < entries.length; i++) {
      this.map.delete(entries[i]![0]);
    }
  }
}
