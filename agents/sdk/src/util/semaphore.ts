import { parseStrictPositiveSafeInteger } from '../integers.js';

/**
 * Tiny async semaphore for throttling concurrent work.
 *
 * Usage:
 *   const sem = new Semaphore(8)
 *   const result = await sem.use(() => doRpc())
 */
export class Semaphore {
  private available: number;

  private readonly queue: Array<(release: () => void) => void> = [];
  private readonly _maxConcurrency: number;

  constructor(maxConcurrency: number) {
    // Fail-closed: fractional or malformed values fall back to 1 rather than
    // silently truncating (e.g. 2.5 → 1, not 2).
    const n = parseStrictPositiveSafeInteger(maxConcurrency) ?? 1;
    this._maxConcurrency = n;
    this.available = n;
  }

  get maxConcurrency(): number {
    return this._maxConcurrency;
  }

  async acquire(): Promise<() => void> {
    if (this.available > 0) {
      this.available -= 1;
      return () => this.release();
    }

    return await new Promise<() => void>((resolve) => {
      this.queue.push((release) => resolve(release));
    });
  }

  private release(): void {
    const next = this.queue.shift();
    if (next) {
      // Transfer the slot directly to the waiter.
      next(() => this.release());
      return;
    }

    this.available += 1;
  }

  async use<T>(fn: () => Promise<T>): Promise<T> {
    const release = await this.acquire();
    try {
      return await fn();
    } finally {
      release();
    }
  }
}
