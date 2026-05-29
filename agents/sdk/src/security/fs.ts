import fs from 'node:fs';

/**
 * Hardened file helpers for agent/harness artifacts.
 *
 * Threat model
 * - In multi-tenant/CI environments, output/state directories may be writable by other users.
 * - Symlinks or special files (FIFO/device) can be planted to cause data exfiltration or DoS.
 *
 * Mitigations
 * - Open files with O_NOFOLLOW when supported (prevents following symlinks for the final path segment).
 * - Add O_NONBLOCK to avoid blocking opens on FIFOs.
 * - Verify the opened fd is a regular file via fstat.
 * - Best-effort enforce restrictive permissions via fchmod.
 */

export type SecureWriteOptions = {
  /** If true, append to the file (O_APPEND). Otherwise truncate (O_TRUNC). */
  append?: boolean;
  /** File mode used when creating (and best-effort enforced via fchmod). Default: 0o600. */
  mode?: number;
  /** Text encoding for writeTextFileNoFollow. Default: 'utf8'. */
  encoding?: BufferEncoding;
};

const DEFAULT_FILE_MODE = 0o600;

function normalizeMode(mode: number | undefined, fallback: number): number {
  if (typeof mode !== 'number' || !Number.isFinite(mode)) return fallback;
  const m = Math.trunc(mode);
  // 0..0o7777 is a reasonable bound for file perms.
  if (m < 0 || m > 0o7777) return fallback;
  return m;
}

function flagsForWrite(params: { append: boolean; wantNoFollow: boolean }): number {
  // Base flags
  const c: any = fs.constants as any;
  const O_WRONLY = c.O_WRONLY as number;
  const O_CREAT = c.O_CREAT as number;
  const O_APPEND = c.O_APPEND as number;
  const O_TRUNC = c.O_TRUNC as number;

  let flags = O_WRONLY | O_CREAT | (params.append ? O_APPEND : O_TRUNC);

  // Avoid leaking fds to child processes (best effort)
  if (typeof c.O_CLOEXEC === 'number') flags |= c.O_CLOEXEC as number;

  // Avoid blocking opens on FIFOs/pipes (best effort)
  if (typeof c.O_NONBLOCK === 'number') flags |= c.O_NONBLOCK as number;

  if (params.wantNoFollow && typeof c.O_NOFOLLOW === 'number') flags |= c.O_NOFOLLOW as number;

  return flags;
}

function isNoFollowUnsupported(err: any): boolean {
  const code = err?.code;
  return (
    code === 'EINVAL' ||
    code === 'ENOTSUP' ||
    code === 'EOPNOTSUPP' ||
    code === 'ENOSYS' ||
    code === 'UNKNOWN'
  );
}

function openWriteFdNoFollow(fp: string, opts?: SecureWriteOptions): number {
  const append = !!opts?.append;
  const mode = normalizeMode(opts?.mode, DEFAULT_FILE_MODE);

  const flagsNoFollow = flagsForWrite({ append, wantNoFollow: true });
  const flagsFallback = flagsForWrite({ append, wantNoFollow: false });

  let fd: number;

  try {
    fd = fs.openSync(fp, flagsNoFollow, mode);
  } catch (err: any) {
    // Some platforms/filesystems don't support O_NOFOLLOW.
    if (isNoFollowUnsupported(err)) {
      fd = fs.openSync(fp, flagsFallback, mode);
    } else {
      throw err;
    }
  }

  try {
    const st = fs.fstatSync(fd);
    if (!st.isFile()) {
      throw new Error(`Refusing to write non-regular file: ${fp}`);
    }

    // Best-effort: force restrictive permissions even when the file already exists.
    try {
      fs.fchmodSync(fd, mode);
    } catch {
      // ignore
    }

    return fd;
  } catch (err) {
    try {
      fs.closeSync(fd);
    } catch {
      // ignore
    }
    throw err;
  }
}

export function writeTextFileNoFollow(fp: string, text: string, opts?: SecureWriteOptions): void {
  const fd = openWriteFdNoFollow(fp, opts);
  try {
    fs.writeFileSync(fd, text, { encoding: opts?.encoding ?? 'utf8' });
  } finally {
    try {
      fs.closeSync(fd);
    } catch {
      // ignore
    }
  }
}

export function createWriteStreamNoFollow(
  fp: string,
  opts?: Omit<SecureWriteOptions, 'encoding'>,
): fs.WriteStream {
  // regular file via fstat and rejects symlinks/FIFOs/devices. However, the
  // original code passed the fd directly to createWriteStream without checking
  // for the degenerate case where the fd is valid but the underlying file was
  // unlinked between open and createWriteStream (race window). Additionally,
  // fs.createWriteStream re-opens the path when autoClose is set and the fd is
  // reused, which could follow a symlink planted between open and stream
  // creation. Pass the fd directly and avoid re-specifying the path to prevent
  // any double-open race. The null path ('') with an fd option is Node.js
  // supported behavior (the path is only used for error messages).
  const fd = openWriteFdNoFollow(fp, { append: opts?.append, mode: opts?.mode });
  try {
    return fs.createWriteStream('', {
      fd,
      flags: opts?.append ? 'a' : 'w',
      mode: normalizeMode(opts?.mode, DEFAULT_FILE_MODE),
      autoClose: true,
    });
  } catch (err) {
    try {
      fs.closeSync(fd);
    } catch {
      // ignore
    }
    throw err;
  }
}
