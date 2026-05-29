import type { KeeperConfig } from '../shared/config.js';
import type { HostLock } from '../shared/host_lock.js';
import type { FileLock } from '../shared/lock.js';

import { acquireHostSocketLock } from '../shared/host_lock.js';
import { acquireFileLock } from '../shared/lock.js';
import { sleep, fmtMs, parseNonNegativeSafeInteger } from '../shared/utils.js';

export function normalizeKeeperWaitForLockSecs(value: unknown): number {
  return parseNonNegativeSafeInteger(value, { defaultValue: 0 }) ?? 0;
}

function composeLocks(primary: FileLock, secondary: HostLock | null): FileLock {
  if (!secondary) return primary;

  return {
    lockPath: primary.lockPath,
    ownerId: primary.ownerId,
    isHeld() {
      return primary.isHeld() && secondary.isHeld();
    },
    getLostReason() {
      return primary.getLostReason() ?? secondary.getLostReason();
    },
    release() {
      // Release BOTH, independent of failures in either.  We release the
      // state-dir lock first so it is visibly freed for any operator or
      // peer process watching that path, then drop the host socket.
      try {
        primary.release();
      } catch {
        /* best-effort */
      }
      try {
        secondary.release();
      } catch {
        /* best-effort */
      }
    },
  };
}

async function acquireOnce(config: KeeperConfig, log: (msg: string) => void): Promise<FileLock> {
  // Acquire the host-scoped lock FIRST.  It's keyed on (uid, deployment)
  // via a Linux abstract UNIX socket and therefore cannot be bypassed by
  // swapping `KEEPER_STATE_DIR` or by a systemd unit with `PrivateTmp=true`.
  // Any duplicate-instance footgun gets caught before we touch the real
  // state directory.
  let hostLock: HostLock | null = null;
  if (config.hostLockName) {
    hostLock = await acquireHostSocketLock({ name: config.hostLockName, log });
  }

  try {
    const stateLock = await acquireFileLock({
      lockPath: config.lockPath,
      ttlMs: config.lockTtlMs,
      heartbeatMs: config.lockHeartbeatMs,
      log,
    });
    return composeLocks(stateLock, hostLock);
  } catch (e) {
    // If the state-dir lock fails, release the host lock so a retrying
    // peer can grab it instead of spin-blocking on us.
    try {
      hostLock?.release();
    } catch {
      /* best-effort */
    }
    throw e;
  }
}

export async function acquireLockMaybeWait(args: {
  config: KeeperConfig;
  log: (msg: string) => void;
  waitForLock: number;
}): Promise<FileLock> {
  const { config, log, waitForLock } = args;
  const waitMs = normalizeKeeperWaitForLockSecs(waitForLock) * 1000;

  const maxAttempts = waitMs > 0 ? Math.max(1, Math.ceil(waitMs / 1000) * 2) : 0;
  let attempt = 0;

  if (!waitMs) {
    return acquireOnce(config, log);
  }

  while (true) {
    try {
      return await acquireOnce(config, log);
    } catch (e: any) {
      const msg = String(e?.message ?? e);
      if (msg.startsWith('Lock already held:')) {
        attempt += 1;
        if (attempt >= maxAttempts) {
          throw new Error(
            `lock acquisition failed after ${attempt} attempts (budget=${fmtMs((waitMs * maxAttempts) / maxAttempts)})`,
            { cause: e },
          );
        }
        const backoffMs = Math.min(waitMs, 1000 * Math.pow(2, Math.min(attempt - 1, 6)));
        log(
          `lock already held. attempt ${attempt}/${maxAttempts}, retrying in ${fmtMs(backoffMs)}`,
        );
        await sleep(backoffMs);
        continue;
      }
      throw e;
    }
  }
}
