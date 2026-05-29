import fs from 'node:fs';
import crypto from 'node:crypto';
import path from 'node:path';

import { ensureDir, saveJsonAtomic } from './state.js';
import { parseNonNegativeSafeInteger } from './utils.js';

export interface FileLock {
  lockPath: string;
  ownerId: string;
  isHeld(): boolean;
  getLostReason(): string | null;
  release(): void;
}

const MAX_LOCK_FILE_BYTES = 16 * 1024;

function nowMs(): number {
  return Date.now();
}

function readLockFileText(lockPath: string): string {
  const st = fs.statSync(lockPath);
  if (!st.isFile()) {
    throw new Error(`Lock path is not a regular file: ${lockPath}`);
  }
  if (st.size > MAX_LOCK_FILE_BYTES) {
    throw new Error(`Lock file too large: ${st.size} bytes (max ${MAX_LOCK_FILE_BYTES})`);
  }
  return fs.readFileSync(lockPath, 'utf8');
}

function safeParseJson(txt: string): unknown {
  try {
    return JSON.parse(txt);
  } catch {
    return null;
  }
}

function writeLockFileAtomic(lockPath: string, data: unknown): void {
  // IMPORTANT: keep this atomic.
  //
  // Non-atomic overwrites can create transient invalid JSON (partial writes). Another
  // process attempting to acquire the lock can treat that as "stale" and break the
  // lock, causing two keepers to run concurrently.
  saveJsonAtomic(lockPath, data);
}

function isStaleByMtime(lockPath: string, ttlMs: number): boolean {
  const now = nowMs();
  try {
    // If the lock holder's clock is ahead and writes a future mtime, then the
    // clock corrects backwards, other processes will see the lock as non-stale
    // for longer than ttlMs. Conversely, a backward NTP jump on the *reader*
    // can make a valid lock appear stale, causing premature lock-breaking.
    // Suggested fix: prefer the JSON expiresAtMs field (which is already used
    // first); only fall back to mtime when JSON is truly unparseable.
    const st = fs.statSync(lockPath);
    const mtimeValue = st.mtime?.getTime?.() ?? (st as any).mtimeMs;
    const mtimeMs =
      typeof mtimeValue === 'number' && Number.isFinite(mtimeValue) && mtimeValue >= 0
        ? Math.trunc(mtimeValue)
        : (parseNonNegativeSafeInteger(mtimeValue) ?? 0);
    const ageMs = now - mtimeMs;
    // If the clock moves backwards or the value is invalid, fail closed (not stale).
    if (!Number.isFinite(ageMs) || ageMs < 0) return false;
    return ageMs > ttlMs;
  } catch (e: unknown) {
    if ((e as NodeJS.ErrnoException)?.code === 'ENOENT') return true;
    throw e;
  }
}

function throwAsync(err: Error): void {
  // Crash outside of the current call stack/try/catch (ex: inside heartbeat's try/catch),
  // so the process-level uncaughtException handler can report + exit.
  //
  // IMPORTANT: avoid an unref'd timer here. If the event loop is otherwise empty,
  // Node can exit before the timer fires, resulting in a silent zero-exit even
  // though we lost the lock.
  queueMicrotask(() => {
    throw err;
  });
}

export async function acquireFileLock({
  lockPath,
  ttlMs,
  heartbeatMs,
  exitOnLost = true,
  log,
}: {
  lockPath: string;
  ttlMs: number;
  heartbeatMs: number;
  /**
   * If true (default), losing the lock triggers a fatal error (process exit) to
   * prevent concurrent keepers from submitting transactions.
   */
  exitOnLost?: boolean;
  log?: ((msg: string) => void) | null;
}): Promise<FileLock> {
  const ownerId = crypto.randomUUID();
  const pid = process.pid;
  const _acquiredAtMs = Date.now();

  if (!lockPath) throw new Error('lockPath required');
  if (!Number.isFinite(ttlMs) || ttlMs <= 0) throw new Error('ttlMs must be > 0');

  let heartbeat: ReturnType<typeof setInterval> | null = null;
  let released = false;
  let lost = false;
  let lostReason: string | null = null;

  function fatalLockLost(reason: string): void {
    if (!exitOnLost) return;
    const err = new Error(`keeper lock lost (${reason}) at ${lockPath} (ownerId=${ownerId})`);
    (err as any).name = 'KeeperLockLostError';
    throwAsync(err);
  }

  function markLost(reason: string): void {
    if (released || lost) return;
    lost = true;
    lostReason = String(reason ?? 'unknown');

    try {
      if (heartbeat) clearInterval(heartbeat);
    } catch {
      /* best-effort timer cleanup */
    }
    heartbeat = null;

    if (log) log(`lock: LOST (${lostReason}) ${lockPath} (ownerId=${ownerId})`);

    fatalLockLost(lostReason);
  }

  function makeRecord(): {
    ownerId: string;
    pid: number;
    createdAtMs: number;
    updatedAtMs: number;
    expiresAtMs: number;
  } {
    const now = nowMs();
    return {
      ownerId,
      pid,
      createdAtMs: now,
      updatedAtMs: now,
      expiresAtMs: now + ttlMs,
    };
  }

  // Try acquire with stale-breaking.
  while (true) {
    try {
      ensureDir(path.dirname(lockPath));
      const fd = fs.openSync(lockPath, 'wx', 0o600);
      try {
        const rec = makeRecord();
        fs.writeFileSync(fd, JSON.stringify(rec, null, 2) + '\n', 'utf8');
      } finally {
        fs.closeSync(fd);
      }
      break;
    } catch (e: unknown) {
      const code = (e as NodeJS.ErrnoException)?.code;
      if (code !== 'EEXIST') {
        throw e;
      }

      // Lock exists; check expiry.
      //
      // IMPORTANT: never treat an invalid/unparseable lock file as stale immediately.
      // Another process may have created the file but not finished writing yet. If we
      // delete it we can create a split-brain where two keepers run concurrently.
      let stale: boolean;
      try {
        const txt = readLockFileText(lockPath);
        const rec = safeParseJson(txt) as Record<string, unknown> | null;
        const exp = parseNonNegativeSafeInteger(rec?.expiresAtMs, { defaultValue: null });

        if (exp != null && exp > 0) {
          stale = exp <= nowMs();
        } else {
          stale = isStaleByMtime(lockPath, ttlMs);
        }
      } catch (e2: unknown) {
        const c2 = (e2 as NodeJS.ErrnoException)?.code;
        if (c2 === 'ENOENT') {
          // Raced with deletion; retry acquire loop.
          continue;
        }
        // Fail closed: if we can't read/stat the lock file, do not attempt to break it.
        const msg = String((e2 as any)?.message ?? e2);
        throw new Error(
          `Cannot read lock file to determine staleness: ${lockPath} (${c2 ?? 'error'}: ${msg})`,
          { cause: e2 },
        );
      }

      if (stale) {
        try {
          fs.unlinkSync(lockPath);
          continue;
        } catch {
          // Someone else may have taken it; loop.
        }
      }

      if (log) log(`lock: already held at ${lockPath}`);
      throw new Error(`Lock already held: ${lockPath}`, { cause: e });
    }
  }

  if (log) log(`lock: acquired ${lockPath} (ownerId=${ownerId})`);

  // Intentionally NOT unref'd:
  // an unref'd timer would allow silent process exit while the lock is held,
  // enabling split-brain. This design choice is security-critical and MUST NOT be
  // changed without understanding the concurrent-keeper implications.

  // Heartbeat
  if (heartbeatMs > 0) {
    heartbeat = setInterval(() => {
      if (released || lost) return;

      let cur: Record<string, unknown> | null;
      try {
        const txt = readLockFileText(lockPath);
        cur = safeParseJson(txt) as Record<string, unknown> | null;
      } catch (e: unknown) {
        const code = (e as NodeJS.ErrnoException)?.code;
        if (code === 'ENOENT') {
          markLost('missing');
          return;
        }
        const msg = String((e as any)?.message ?? e);
        markLost(`heartbeat_read_failed:${code ?? 'error'}:${msg}`);
        return;
      }

      // If the lock record is corrupted/unparseable, do NOT attempt to "repair" it.
      // Treat this as a lost lock to avoid two keepers running concurrently.
      if (!cur || typeof cur !== 'object') {
        markLost('corrupt');
        return;
      }

      if (cur?.ownerId && cur.ownerId !== ownerId) {
        // Someone else took over.
        markLost('stolen');
        return;
      }

      const now = nowMs();

      const prevUpdated = parseNonNegativeSafeInteger(cur.updatedAtMs, { defaultValue: null });
      if (prevUpdated != null && prevUpdated > 0 && Math.abs(now - prevUpdated) > ttlMs * 2) {
        markLost(`clock_drift:gap=${Math.abs(now - prevUpdated)}ms`);
        return;
      }

      const next = {
        ...cur,
        ownerId,
        pid,
        updatedAtMs: now,
        expiresAtMs: now + ttlMs,
      };

      try {
        writeLockFileAtomic(lockPath, next);
      } catch (e: unknown) {
        const code = (e as NodeJS.ErrnoException)?.code;
        if (code === 'ENOENT') {
          markLost('missing');
          return;
        }
        const msg = String((e as any)?.message ?? e);
        markLost(`heartbeat_write_failed:${code ?? 'error'}:${msg}`);
        return;
      }

      try {
        const verifyTxt = readLockFileText(lockPath);
        const verifyRec = safeParseJson(verifyTxt) as Record<string, unknown> | null;
        if (verifyRec && verifyRec.ownerId !== ownerId) {
          markLost('overwritten');
          return;
        }
      } catch {
        // Best-effort; next heartbeat will catch persistent issues.
      }
    }, heartbeatMs);

    //
    // If all other async work completes and the event loop becomes empty,
    // an unref'd timer allows Node to exit with code 0 while the keeper
    // still holds the lock. Another keeper instance can then acquire the
    // same lock, creating a split-brain where two keepers submit txs.
  }

  return {
    lockPath,
    ownerId,

    isHeld() {
      return !released && !lost;
    },

    getLostReason() {
      return lostReason;
    },

    release() {
      if (released) return;
      released = true;
      try {
        if (heartbeat) clearInterval(heartbeat);
      } catch {
        /* best-effort timer cleanup */
      }

      // If we already lost the lock, do not delete a lock we don't own.
      if (lost) return;

      try {
        const txt = readLockFileText(lockPath);
        const rec = safeParseJson(txt) as Record<string, unknown> | null;
        if (!rec || typeof rec !== 'object' || rec.ownerId !== ownerId) {
          if (log) log(`lock: release skipped without ownership proof ${lockPath}`);
          return;
        }
      } catch (e: unknown) {
        const code = (e as NodeJS.ErrnoException)?.code;
        if (code !== 'ENOENT' && log) {
          const msg = String((e as any)?.message ?? e);
          log(`lock: release skipped (${code ?? 'error'}: ${msg}) ${lockPath}`);
        }
        return;
      }

      try {
        fs.unlinkSync(lockPath);
        if (log) log(`lock: released ${lockPath}`);
      } catch (e: unknown) {
        if ((e as NodeJS.ErrnoException)?.code !== 'ENOENT' && log) {
          const msg = String((e as any)?.message ?? e);
          log(
            `lock: release unlink failed (${(e as NodeJS.ErrnoException)?.code ?? 'error'}: ${msg}) ${lockPath}`,
          );
        }
      }
    },
  };
}
