import crypto from 'node:crypto';
import fs from 'node:fs';
import path from 'node:path';

import { parseNonNegativeSafeInteger } from './utils.js';

export interface StatusState {
  version: number;
  deployment: string;
  chainId: number;
  createdAtUtc: string;
  lastAttemptAtUtc: string | null;
  lastSuccessAtUtc: string | null;
  lastTxHash: string | null;
  // Last time a task run was skipped due to safety rails (paused, dry-run,
  // pending nonce guard, fee caps, etc). Skips are NOT treated as failures.
  lastSkipAtUtc: string | null;
  lastAttemptByTask: Record<string, string | null>;
  lastSuccessByTask: Record<string, string | null>;
  lastSkipByTask: Record<string, string | null>;
  lastSkipReasonByTask: Record<string, string | null>;
  lastTxHashByTask: Record<string, string | null>;
  lastErrorByTask: Record<string, string | null>;
  revertCounts: Record<string, number>;
  lastError: string | null;
  [key: string]: unknown;
}

export interface MarketState {
  version: number;
  lastScannedBlock: number;
  candidates: unknown[];
  offerFailures: Record<string, unknown>;
}

export interface ListingsState {
  version: number;
  lastScannedBlock: number;
  candidates: unknown[];
  listingFailures: Record<string, unknown>;
}

const MAX_JSON_STATE_FILE_BYTES = 1024 * 1024;

export function ensureDir(p: string): void {
  // Prefer private-by-default permissions for on-disk keeper state.
  // Existing directories are not modified.
  fs.mkdirSync(p, { recursive: true, mode: 0o700 });
}

function readJsonFileText(filePath: string): string {
  const st = fs.statSync(filePath);
  if (!st.isFile()) {
    throw new Error(`JSON state path is not a regular file: ${filePath}`);
  }
  if (st.size > MAX_JSON_STATE_FILE_BYTES) {
    throw new Error(
      `JSON state file too large: ${st.size} bytes (max ${MAX_JSON_STATE_FILE_BYTES})`,
    );
  }
  return fs.readFileSync(filePath, 'utf8');
}

export function loadJson(
  filePath: string,
  { fallback = null }: { fallback?: unknown } = {},
  // errors, disk errors) and returns the fallback. A corrupt status file is
  // indistinguishable from a missing one, causing silent state reset. Consider
  // using loadJsonDetailed() in paths where state integrity matters.
): unknown {
  try {
    if (!fs.existsSync(filePath)) return fallback;
    return JSON.parse(readJsonFileText(filePath));
  } catch {
    return fallback;
  }
}

export type JsonLoadDetailedResult =
  | { kind: 'missing' }
  | { kind: 'ok'; value: unknown }
  | { kind: 'error'; error: Error };

export function loadJsonDetailed(filePath: string): JsonLoadDetailedResult {
  if (!fs.existsSync(filePath)) return { kind: 'missing' };

  try {
    return { kind: 'ok', value: JSON.parse(readJsonFileText(filePath)) };
  } catch (err: unknown) {
    const error = err instanceof Error ? err : new Error(String(err));
    return { kind: 'error', error };
  }
}

export function saveJsonAtomic(filePath: string, value: unknown): void {
  const dir = path.dirname(filePath);
  ensureDir(dir);

  if (filePath.includes('\0')) {
    throw new Error(
      `saveJsonAtomic: filePath contains null byte: ${filePath.replace(/\0/g, '\\0')}`,
    );
  }

  const resolved = path.resolve(filePath);
  const resolvedDir = path.resolve(dir);
  if (
    !resolved.startsWith(resolvedDir + path.sep) &&
    resolved !== path.resolve(resolvedDir, path.basename(filePath))
  ) {
    throw new Error(`saveJsonAtomic: filePath escapes its directory: ${filePath}`);
  }

  const json = JSON.stringify(value, null, 2) + '\n';

  // Keeper state files should be private-by-default. Always write them as 0600
  // to avoid leaking operational metadata (cursors, backoff state, status, ...),
  // even if the enclosing directory is accidentally more permissive.
  const mode = 0o600;

  // IMPORTANT: write atomically without following attacker-controlled symlinks.
  // - Use O_EXCL ('wx') on the temp file to avoid overwriting an existing path.
  // - Use a random suffix to reduce collisions.
  // - fsync the temp file for better crash consistency.
  let tmp = '';
  let fd: number | null = null;
  for (let i = 0; i < 5; i++) {
    tmp = `${filePath}.tmp.${process.pid}.${crypto.randomBytes(6).toString('hex')}`;
    try {
      fd = fs.openSync(tmp, 'wx', mode);
      break;
    } catch (e: any) {
      if (e?.code === 'EEXIST') continue;
      throw e;
    }
  }

  if (fd == null) {
    // Extremely unlikely fallback.
    tmp = `${filePath}.tmp.${process.pid}.${Date.now()}`;
    fd = fs.openSync(tmp, 'wx', mode);
  }

  try {
    fs.writeFileSync(fd, json, 'utf8');
    try {
      fs.fsyncSync(fd);
    } catch (fsyncErr) {
      // durable on disk. If we proceed to rename and the OS crashes before the
      // write buffer is flushed, we atomically replace good data with garbage.
      // Instead of logging and continuing, abort the write entirely: close the
      // fd, unlink the temp, and throw so the caller sees the failure.
      const msg = String((fsyncErr as Error)?.message ?? fsyncErr);
      console.error(`[saveJsonAtomic] fsync failed for ${filePath}: ${msg}`);
      try {
        fs.closeSync(fd);
      } catch {
        /* ignore */
      }
      try {
        if (tmp) fs.unlinkSync(tmp);
      } catch {
        /* ignore */
      }
      throw new Error(
        `[saveJsonAtomic] fsync failed for ${filePath}; aborting atomic write to prevent data corruption: ${msg}`,
        { cause: fsyncErr },
      );
    }
  } catch (e) {
    try {
      fs.closeSync(fd);
    } catch {
      // ignore
    }
    try {
      if (tmp) fs.unlinkSync(tmp);
    } catch {
      // ignore
    }
    throw e;
  }

  try {
    fs.closeSync(fd);
  } catch {
    // ignore
  }

  try {
    fs.renameSync(tmp, filePath);

    // Best-effort: fsync the containing directory so the rename is durable across
    // crashes/power loss (otherwise, the rename can be lost on some filesystems).
    try {
      const dfd = fs.openSync(dir, 'r');
      try {
        fs.fsyncSync(dfd);
      } finally {
        try {
          fs.closeSync(dfd);
        } catch {
          // ignore
        }
      }
    } catch {
      // best-effort only
    }
  } catch (e) {
    try {
      if (tmp) fs.unlinkSync(tmp);
    } catch {
      // ignore
    }
    throw e;
  }
}

export function nowUtcIso(): string {
  return new Date().toISOString();
}

function isPlainObject(v: unknown): v is Record<string, unknown> {
  return !!v && typeof v === 'object' && !Array.isArray(v);
}

const STATUS_TASK_KEYS: string[] = [
  'poke',
  'harvestStaking',
  'autoFurnace',
  'sweepListings',
  'expireOffers',
  'compoundShareholders',
  'compoundLp',
  'checkpointBeforeExpiry',
  'automaxBonus',
];

function initNullMap(keys: string[]): Record<string, null> {
  const out: Record<string, null> = {};
  for (const k of keys) out[k] = null;
  return out;
}

export function initStatusState({
  deployment,
  chainId,
}: {
  deployment: string;
  chainId: number;
}): StatusState {
  return {
    version: 2,
    deployment,
    chainId,
    createdAtUtc: nowUtcIso(),

    // Backwards-compatible top-level fields
    lastAttemptAtUtc: null,
    lastSuccessAtUtc: null,
    lastTxHash: null,

    // Skip telemetry (safety rails triggered)
    lastSkipAtUtc: null,

    // Per-task fields for production-grade monitoring
    // Keys match revertCounts keys.
    lastAttemptByTask: initNullMap(STATUS_TASK_KEYS),
    lastSuccessByTask: initNullMap(STATUS_TASK_KEYS),
    lastSkipByTask: initNullMap(STATUS_TASK_KEYS),
    lastSkipReasonByTask: initNullMap(STATUS_TASK_KEYS),
    lastTxHashByTask: initNullMap(STATUS_TASK_KEYS),
    lastErrorByTask: initNullMap(STATUS_TASK_KEYS),

    revertCounts: {
      poke: 0,
      harvestStaking: 0,
      autoFurnace: 0,
      sweepListings: 0,
      expireOffers: 0,
      compoundShareholders: 0,
      compoundLp: 0,
      checkpointBeforeExpiry: 0,
      automaxBonus: 0,
    },

    lastError: null,
  };
}

export function bumpRevertCount(status: StatusState, key: string): StatusState {
  const out = { ...status };
  out.revertCounts = { ...(status.revertCounts ?? {}) };
  out.revertCounts[key] =
    (parseNonNegativeSafeInteger(out.revertCounts[key], { defaultValue: 0 }) ?? 0) + 1;
  return out;
}

function mergeMaps(curVal: unknown, patchVal: unknown): unknown {
  if (!isPlainObject(curVal) && !isPlainObject(patchVal)) return patchVal;
  if (!isPlainObject(curVal) && isPlainObject(patchVal)) return { ...patchVal };
  if (isPlainObject(curVal) && !isPlainObject(patchVal)) return patchVal;
  return { ...(curVal as Record<string, unknown>), ...(patchVal as Record<string, unknown>) };
}

export function updateStatusFile({
  statusPath,
  patch,
  init,
}: {
  statusPath: string;
  patch: Partial<StatusState>;
  init?: () => StatusState;
}): StatusState {
  let cur: StatusState;
  const loaded = loadJsonDetailed(statusPath);
  if (loaded.kind === 'ok' && loaded.value != null) {
    cur = loaded.value as StatusState;
  } else if (loaded.kind === 'error') {
    console.error(
      `[updateStatusFile] corrupt status file ${statusPath}: ${loaded.error.message}; reinitializing`,
    );
    cur = init ? init() : ({} as StatusState);
  } else {
    cur = init ? init() : ({} as StatusState);
  }
  const next: StatusState = {
    ...cur,
    ...patch,
  };

  // Deep-merge the per-task maps so callers can patch a single task field
  // without overwriting other tasks.
  for (const k of [
    'lastAttemptByTask',
    'lastSuccessByTask',
    'lastSkipByTask',
    'lastSkipReasonByTask',
    'lastTxHashByTask',
    'lastErrorByTask',
  ] as const) {
    if (k in (patch ?? {})) {
      (next as Record<string, unknown>)[k] = mergeMaps(cur?.[k], patch?.[k]);
    }
  }

  saveJsonAtomic(statusPath, next);
  return next;
}

export function initMarketState(): MarketState {
  return {
    version: 2,
    lastScannedBlock: 0,
    candidates: [],

    // Per-offer backoff state for Market auto-furnace attempts.
    // Keyed by offerId (string).
    offerFailures: {},
  };
}

export function initListingsState(): ListingsState {
  return {
    version: 1,
    lastScannedBlock: 0,
    candidates: [],

    // Per-listing backoff state for listing settlement attempts.
    // Keyed by tokenId (string).
    listingFailures: {},
  };
}
