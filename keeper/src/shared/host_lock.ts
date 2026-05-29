import net from 'node:net';

/**
 * Host-scoped advisory lock using a Linux abstract UNIX socket.
 *
 * Why an abstract socket rather than a file lock?
 *
 * The keeper runs under two common deployment patterns on the same host:
 *
 *   1. A system systemd unit with `PrivateTmp=true` + `ProtectHome=read-only`.
 *      This service sees a per-instance `/tmp` + `/var/tmp` namespace, so any
 *      filesystem lock in `os.tmpdir()` is invisible to other processes.
 *   2. A `systemd --user` unit (or a hand-rolled `nohup` shell command) with
 *      no sandboxing, which sees the real `/tmp`.
 *
 * These two services can therefore both "acquire" a filesystem-path lock
 * without contending, because they see different inodes for the same path,
 * which can allow a duplicate keeper instance (e.g. a user-unit running next
 * to the system unit) to hold a lock the other instance never sees.
 *
 * Abstract UNIX sockets (`\0name`) are identified purely by name inside the
 * host's network namespace.  They bypass the filesystem entirely, are not
 * affected by `PrivateTmp=*`, and the kernel automatically cleans them up
 * when the owning process exits — no stale-lock recovery required.  As
 * long as both keeper processes share the host network namespace (which
 * they do by default for both system services and user sessions on Linux),
 * they contend on the same abstract socket name.
 *
 * This lock is INTENTIONALLY independent of `KEEPER_STATE_DIR`: it is
 * keyed on `(uid, deployment)`, so two operators accidentally pointing the
 * same deployment at two different state dirs on the same host will
 * collide here regardless.
 */

const ABSTRACT_SOCKET_MAX_NAME_BYTES = 107; // Linux sun_path=108 incl. leading \0

export interface HostLock {
  /** Human-readable lock identity (the socket name without the leading \0). */
  name: string;
  isHeld(): boolean;
  getLostReason(): string | null;
  release(): void;
}

/**
 * Acquire an abstract-UNIX-socket lock with the given name.  Throws
 * `Error('Lock already held: <name>')` if another process already holds it
 * (so the message shape matches `acquireFileLock`).
 *
 * Returns `null` if abstract sockets are not supported by this platform
 * (e.g. non-Linux).  Callers should treat that as "host lock unavailable"
 * and decide whether to continue (best-effort) or fail closed.
 */
export async function acquireHostSocketLock(args: {
  name: string;
  log?: ((msg: string) => void) | null;
}): Promise<HostLock | null> {
  const { name, log } = args;

  if (!name || typeof name !== 'string') {
    throw new Error('host lock: name required');
  }
  const nameBytes = Buffer.byteLength(name, 'utf8');
  if (nameBytes > ABSTRACT_SOCKET_MAX_NAME_BYTES - 1) {
    throw new Error(
      `host lock: name too long (${nameBytes} bytes, max ${ABSTRACT_SOCKET_MAX_NAME_BYTES - 1}): ${name}`,
    );
  }

  // Abstract sockets are a Linux-only kernel feature.  On macOS/Windows we
  // silently degrade — the state-dir lock remains the sole safety net.
  if (process.platform !== 'linux') {
    if (log) log(`host lock: abstract sockets unavailable on ${process.platform}; skipping`);
    return null;
  }

  const socketPath = `\0${name}`;

  const server = net.createServer();
  // Reject any incoming connection immediately — the socket is only being
  // used as a named mutex, not an actual IPC channel.
  server.on('connection', (sock) => {
    try {
      sock.destroy();
    } catch {
      /* best-effort */
    }
  });
  server.on('error', () => {
    // Surface via the listen() promise below; ignore spurious post-listen errors.
  });

  await new Promise<void>((resolve, reject) => {
    const onError = (err: NodeJS.ErrnoException): void => {
      server.off('listening', onListening);
      if (err?.code === 'EADDRINUSE') {
        reject(new Error(`Lock already held: ${name}`));
      } else {
        reject(err);
      }
    };
    const onListening = (): void => {
      server.off('error', onError);
      resolve();
    };
    server.once('error', onError);
    server.once('listening', onListening);
    try {
      server.listen(socketPath);
    } catch (err) {
      server.off('listening', onListening);
      server.off('error', onError);
      reject(err as Error);
    }
  });

  if (log) log(`host lock: acquired abstract socket ${JSON.stringify(name)}`);

  let released = false;
  let lostReason: string | null = null;

  // If the socket server emits a post-listen error (rare; typically means
  // the kernel closed it under us) we treat it as lost.  This mirrors how
  // `acquireFileLock` marks the lock lost when the heartbeat fails.
  server.on('close', () => {
    if (!released) {
      lostReason = lostReason ?? 'server_closed';
    }
  });

  return {
    name,
    isHeld() {
      return !released && lostReason == null;
    },
    getLostReason() {
      return lostReason;
    },
    release() {
      if (released) return;
      released = true;
      try {
        server.close();
      } catch {
        /* best-effort */
      }
      // Unref so a hanging socket can never keep Node alive past shutdown.
      try {
        server.unref();
      } catch {
        /* best-effort */
      }
      if (log) log(`host lock: released abstract socket ${JSON.stringify(name)}`);
    },
  };
}
