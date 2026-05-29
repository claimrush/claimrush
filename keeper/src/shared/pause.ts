import fs from 'node:fs';

import type { KeeperConfig } from './config.js';
import { nowUtcIso, saveJsonAtomic } from './state.js';

const MAX_PAUSE_FILE_BYTES = 64 * 1024;

export type PauseInfo = {
  paused: boolean;
  reason: string | null;
  untilUtc: string | null;
  source: 'env' | 'file' | null;
};

type PauseFileV1 = {
  version: 1;
  pausedAtUtc: string;
  pausedUntilUtc?: string | null;
  reason: string;
  details?: unknown;
};

function safeDateMs(iso: string | null | undefined): number | null {
  if (!iso) return null;
  const ms = Date.parse(String(iso));
  return Number.isFinite(ms) ? ms : null;
}

export function getPauseInfo(config: KeeperConfig): PauseInfo {
  if (config.paused) {
    return {
      paused: true,
      reason: 'KEEPER_PAUSED=1',
      untilUtc: null,
      source: 'env',
    };
  }

  const p = config.pauseFilePath;
  if (!p) return { paused: false, reason: null, untilUtc: null, source: null };

  if (p.includes('\0')) {
    return {
      paused: true,
      reason: 'pause file path contains null byte (fail-safe)',
      untilUtc: null,
      source: 'file',
    };
  }

  let st: fs.Stats;
  try {
    st = fs.lstatSync(p);
    if (st.isSymbolicLink()) {
      return {
        paused: true,
        reason: 'pause file is a symlink (refusing to follow)',
        untilUtc: null,
        source: 'file',
      };
    }
    if (!st.isFile()) {
      return {
        paused: true,
        reason: 'pause file is not a regular file (fail-safe)',
        untilUtc: null,
        source: 'file',
      };
    }
    if (st.size > MAX_PAUSE_FILE_BYTES) {
      return {
        paused: true,
        reason: `pause file exceeds ${MAX_PAUSE_FILE_BYTES} bytes (fail-safe)`,
        untilUtc: null,
        source: 'file',
      };
    }
  } catch (e: unknown) {
    if ((e as NodeJS.ErrnoException)?.code === 'ENOENT') {
      return { paused: false, reason: null, untilUtc: null, source: null };
    }
    return {
      paused: true,
      reason: 'pause file stat failed (fail-safe)',
      untilUtc: null,
      source: 'file',
    };
  }

  // the existence check and the read, the file could be deleted (auto-clear),
  // causing readFileSync to throw ENOENT. The outer catch handles this correctly
  // (returns paused=true with 'unreadable'), which is fail-safe behavior —
  // acceptable, just noting for completeness.

  try {
    const raw = fs.readFileSync(p, 'utf8');
    const s = String(raw ?? '').trim();
    if (!s) {
      return { paused: true, reason: 'pause file present', untilUtc: null, source: 'file' };
    }

    // If this is a circuit-breaker pause file, it is JSON.
    try {
      const obj = JSON.parse(s) as PauseFileV1;
      if (obj && typeof obj === 'object' && (obj as any).version === 1) {
        const untilUtc = (obj as any).pausedUntilUtc ?? null;
        const untilMs = safeDateMs(untilUtc);
        if (untilMs != null && untilMs <= Date.now()) {
          // Auto-clear expired circuit breaker pause.
          try {
            fs.unlinkSync(p);
          } catch {
            /* best-effort removal of expired pause file */
          }
          return { paused: false, reason: null, untilUtc: null, source: null };
        }

        const reason = String((obj as any).reason ?? 'paused');
        return {
          paused: true,
          reason,
          untilUtc: untilUtc ? String(untilUtc) : null,
          source: 'file',
        };
      }
    } catch {
      // If it *looks* like a JSON circuit-breaker pause file but is invalid/corrupt,
      // surface that explicitly. Invalid JSON can prevent auto-clear after cooldown
      // and requires manual operator intervention.
      if (s.startsWith('{') || s.startsWith('[')) {
        return {
          paused: true,
          reason: 'pause file present (invalid JSON)',
          untilUtc: null,
          source: 'file',
        };
      }

      // fallthrough: treat as manual pause file (plain text)
    }

    // Manual pause file: content is the reason (best effort).
    const reason = s.length > 200 ? s.slice(0, 200) + '…' : s;
    return { paused: true, reason, untilUtc: null, source: 'file' };
  } catch {
    return {
      paused: true,
      reason: 'pause file present (unreadable)',
      untilUtc: null,
      source: 'file',
    };
  }
}

export function writePauseFile({
  pauseFilePath,
  reason,
  cooldownMs,
  details,
}: {
  pauseFilePath: string;
  reason: string;
  cooldownMs?: number | null;
  details?: unknown;
}): { pausedAtUtc: string; pausedUntilUtc: string | null } {
  const pausedAtUtc = nowUtcIso();
  const pausedUntilUtc =
    cooldownMs != null && Number.isFinite(cooldownMs) && cooldownMs > 0
      ? new Date(Date.now() + cooldownMs).toISOString()
      : null;

  const payload: PauseFileV1 = {
    version: 1,
    pausedAtUtc,
    pausedUntilUtc,
    reason,
    details,
  };

  // IMPORTANT: write atomically.
  // A partial/truncated JSON pause file can be misclassified as a "manual" pause file,
  // preventing auto-clear after cooldown and requiring manual intervention.
  saveJsonAtomic(pauseFilePath, payload);
  return { pausedAtUtc, pausedUntilUtc };
}
