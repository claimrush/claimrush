#!/usr/bin/env node

import fs from 'node:fs';
import path from 'node:path';

import { makeNodeLogger, serializeError } from '@claimrush/node-utils/logger';
import { loadEnvFile } from './shared/env.js';
import { loadConfigFromEnv } from './shared/config.js';
import { getRepoRoot } from './shared/paths.js';
import { loadDeploymentManifest } from './shared/deployments.js';
import { buildClients } from './shared/clients.js';
import { postAlert } from './shared/alert.js';
import { parseChainIdStrict } from './shared/chainId.js';
import { nowUtcIso } from './shared/state.js';
import { parseNonNegativeSafeInteger } from './shared/utils.js';
import { parseCli, usage } from './run/cli.js';
import { acquireLockMaybeWait } from './run/lock.js';
import { printStatus } from './tasks/status.js';
import { dispatchKeeperCommand } from './run/commands.js';

function mkLogger(deployment: string, chainId?: number): (msg: string) => void {
  return makeNodeLogger({
    component: 'keeper',
    deployment,
    ...(chainId != null && Number.isFinite(chainId) ? { chainId } : {}),
  });
}

const fatalLog = makeNodeLogger({ component: 'keeper' });

function withTimeout<T>(p: Promise<T>, timeoutMs: number, label: string): Promise<T> {
  const ms = parseNonNegativeSafeInteger(timeoutMs, { defaultValue: 0 }) ?? 0;
  if (!ms) return p;

  let t: ReturnType<typeof setTimeout> | null = null;
  const timeout = new Promise<never>((_, reject) => {
    t = setTimeout(() => reject(new Error(`${label} timeout after ${ms}ms`)), ms);
    // IMPORTANT: do not unref this timeout. Awaiting a Promise does not keep Node alive,
    // so an unref'd timer could allow a silent process exit before the timeout fires.
  });

  return Promise.race([p, timeout]).finally(() => {
    try {
      if (t) clearTimeout(t);
    } catch {
      // best-effort
    }
  }) as Promise<T>;
}

async function getWalletRpcChainId(walletClient: unknown, timeoutMs: number): Promise<number> {
  const req = (walletClient as any)?.request as
    | ((args: { method: string; params?: unknown[] }) => Promise<unknown>)
    | undefined;

  if (typeof req !== 'function') {
    throw new Error('walletClient.request missing; cannot validate private RPC chainId');
  }

  const raw = await withTimeout(
    req({ method: 'eth_chainId', params: [] }),
    timeoutMs,
    'private RPC eth_chainId',
  );
  const cid = parseChainIdStrict(raw);
  if (cid == null) {
    throw new Error(`private RPC returned invalid chainId: ${String(raw)}`);
  }
  return cid;
}

/**
 * Classify a boot-time RPC error as transient (worth retrying) vs structural.
 *
 * Transient: DNS not ready, interface not up, remote TLS handshake failure,
 * upstream 502/503, connection reset, timeout — typical at host reboot when
 * the network stack comes up in the same second as systemd starts us.
 *
 * Structural: anything that looks like HTTP auth/quota or a chainId-shape
 * mismatch — retrying just delays a real misconfiguration error.
 */
function isTransientBootError(e: unknown): boolean {
  if (!e) return false;
  const msg = String((e as { message?: string })?.message ?? e).toLowerCase();

  // viem wraps fetch errors with this literal prefix.
  if (msg.includes('fetch failed')) return true;
  if (msg.includes('http request failed')) return true;
  if (msg.includes('timeout after')) return true;
  if (msg.includes('network error')) return true;
  if (msg.includes('socket hang up')) return true;

  // Node net/dns error codes (bubble up via cause chain).
  if (msg.includes('enotfound') || msg.includes('eai_again')) return true;
  if (msg.includes('econnreset') || msg.includes('econnrefused')) return true;
  if (msg.includes('etimedout') || msg.includes('ehostunreach')) return true;
  if (msg.includes('enetunreach')) return true;

  // Transient upstream errors worth retrying; 4xx and chain-mismatch messages
  // are explicitly excluded so bad config fails fast.
  if (msg.includes('status: 502') || msg.includes('status: 503') || msg.includes('status: 504'))
    return true;

  return false;
}

/**
 * Run the two chainId probes with a bounded retry loop.
 *
 * Background: on fresh host boot, systemd starts us before the outbound
 * network is fully up (DNS resolvers, IPv6 RA, etc.).  The first couple of
 * `eth_chainId` calls to the RPC endpoint come back as `fetch failed` and
 * previously crashed the keeper fatally.  `Restart=always` papered over it
 * after ~20s, but it produced two alarming `Fatal error` lines per reboot.
 *
 * We retry transient failures up to `attempts` times with exponential backoff.
 * Structural errors (bad chainId, auth failure, etc.) surface on the first
 * attempt with no delay.
 */
async function probeChainIdsWithRetry({
  publicClient,
  walletClient,
  timeoutMs,
  attempts,
  baseBackoffMs,
  log,
}: {
  publicClient: { getChainId: () => Promise<number> };
  walletClient: unknown;
  timeoutMs: number;
  attempts: number;
  baseBackoffMs: number;
  log: (msg: string) => void;
}): Promise<{ publicChainId: number; privateChainId: number }> {
  let lastErr: unknown = null;
  for (let attempt = 1; attempt <= attempts; attempt += 1) {
    try {
      const [publicChainId, privateChainId] = await Promise.all([
        withTimeout(publicClient.getChainId(), timeoutMs, 'public RPC eth_chainId'),
        getWalletRpcChainId(walletClient, timeoutMs),
      ]);
      if (attempt > 1) {
        log(`boot: RPC chainId probe succeeded on attempt ${attempt}/${attempts}`);
      }
      return { publicChainId, privateChainId };
    } catch (e: unknown) {
      lastErr = e;
      if (attempt >= attempts || !isTransientBootError(e)) {
        throw e;
      }
      const delay = Math.min(10_000, baseBackoffMs * Math.pow(2, attempt - 1));
      const msg = String((e as { message?: string })?.message ?? e).slice(0, 160);
      log(
        `boot: RPC chainId probe attempt ${attempt}/${attempts} failed (transient); retrying in ${delay}ms — ${msg}`,
      );
      await new Promise((resolve) => setTimeout(resolve, delay));
    }
  }
  throw lastErr ?? new Error('probeChainIdsWithRetry: exhausted attempts with no recorded error');
}

function isTruthyEnv(v: unknown): boolean {
  const s = String(v ?? '')
    .trim()
    .toLowerCase();
  return s === '1' || s === 'true' || s === 'yes' || s === 'y';
}

function checkSecureDir({
  dirPath,
  label,
  log,
  allowInsecure,
}: {
  dirPath: string;
  label: string;
  log: (msg: string) => void;
  allowInsecure: boolean;
}): void {
  try {
    const st = fs.statSync(dirPath);
    if (!st.isDirectory()) {
      log(`WARN: ${label} is not a directory: ${dirPath}`);
      return;
    }

    const mode = st.mode & 0o777;
    const worldWritable = (mode & 0o002) !== 0;
    const groupWritable = (mode & 0o020) !== 0;

    if (worldWritable && !allowInsecure) {
      throw new Error(
        `Refusing to start: ${label} is world-writable (mode ${mode.toString(8)}): ${dirPath}. ` +
          'Fix permissions (recommended: chmod 700) or set KEEPER_ALLOW_INSECURE_FS=1 to override.',
      );
    }

    if (worldWritable) {
      log(
        `WARN: ${label} is world-writable (mode ${mode.toString(8)}): ${dirPath}. ` +
          'This allows other local users/processes to tamper with keeper state.',
      );
    } else if (groupWritable) {
      log(
        `WARN: ${label} is group-writable (mode ${mode.toString(8)}): ${dirPath}. ` +
          'Consider tightening to 700/750 to prevent state tampering.',
      );
    }
  } catch (e: unknown) {
    const msg = String((e as Error)?.message ?? e);
    // Bubble up hard failures; log soft failures and continue.
    if (msg.startsWith('Refusing to start:')) throw e;
    log(`WARN: could not stat ${label}: ${dirPath} (${msg})`);
  }
}

// Fatal-path timing contract:
//   - postAlert itself enforces its own deadline via `timeoutMs`. It returns
//     `{ sent: false, error: 'timeout' }` on deadline and never rejects for
//     network / HTTP errors.
//   - `HARD_DEADLINE_MS` is the absolute max time between "fatal trigger" and
//     "process exits", set to postAlert's deadline PLUS a small buffer so the
//     alert HTTP request actually has a chance to complete before we tear the
//     process down.
//
// Previous behaviour used a fixed 750ms setTimeout that fired well before the
// 2000ms postAlert timeout, so slow webhooks would produce a "crashed + no
// page" outcome even when the alert would have succeeded. That regression is
// fixed here by (a) starting the alert and waiting on its settlement, and
// (b) only falling back to a hard deadline if the alert promise never
// settles at all.
const FATAL_ALERT_TIMEOUT_MS = 2000;
const FATAL_HARD_DEADLINE_MS = FATAL_ALERT_TIMEOUT_MS + 500;

function fatalExit(type: string, err: unknown): void {
  // Always arm the deadline FIRST so a synchronous exception below (or an
  // alert promise that somehow never settles) still forces an exit within a
  // bounded wall-clock time. The deadline timer intentionally references the
  // event loop so we don't exit early before async work lands; postAlert's
  // own fetch socket already keeps the loop alive during delivery.
  const deadlineTimer = setTimeout(() => {
    try {
      process.stderr.write(`fatal_exit_deadline_hit type=${type} ms=${FATAL_HARD_DEADLINE_MS}\n`);
    } catch {
      /* best-effort */
    }
    process.exit(1);
  }, FATAL_HARD_DEADLINE_MS);

  const exitNow = (reason: 'alert_settled' | 'alert_threw' | 'log_failed'): void => {
    try {
      clearTimeout(deadlineTimer);
    } catch {
      /* ignore */
    }
    // Emit on a microtask so any already-queued log writes flush first.
    setImmediate(() => {
      try {
        process.stderr.write(`fatal_exit type=${type} reason=${reason}\n`);
      } catch {
        /* best-effort */
      }
      process.exit(1);
    });
  };

  try {
    const e = serializeError(err);

    fatalLog.error('Fatal error', {
      type,
      error: e.message,
      ...(e.name ? { errorName: e.name } : {}),
      ...(e.stack ? { stack: e.stack } : {}),
    });

    // IMPORTANT: read env at call-time so `--env <file>` is honored.
    const url = process.env.KEEPER_ALERT_WEBHOOK_URL ?? null;
    const deployment = process.env.KEEPER_DEPLOYMENT ?? null;

    // The fatal-path alert is best-effort w.r.t. the process exiting, but we
    // deliberately WAIT for it to settle (up to its own timeout) before
    // shutting down, so slow webhooks don't produce a silent "crash with no
    // page" outcome. postAlert never rejects for HTTP/network/timeout (those
    // become `{ sent: false, error }` on the resolved result); the .catch
    // arm covers genuinely unexpected throws.
    const alertPromise = postAlert(
      url,
      {
        type: `keeper_${type}`,
        action: 'process',
        deployment: deployment ?? 'unknown',
        timestampUtc: nowUtcIso(),
        error: e.message,
        ...(e.name ? { errorName: e.name } : {}),
        ...(e.stack ? { stack: e.stack } : {}),
      },
      {
        log: fatalLog,
        timeoutMs: FATAL_ALERT_TIMEOUT_MS,
        dedupeWindowMs: 0,
      },
    );

    alertPromise
      .then((result) => {
        if (!result.sent) {
          fatalLog.error('Fatal-path alert was NOT delivered', {
            type,
            url: url ? '<configured>' : '<unset>',
            ...(result.status !== undefined ? { status: result.status } : {}),
            ...(result.error ? { alertError: result.error } : {}),
          });
        }
      })
      .catch((alertErr: unknown) => {
        const msg = String((alertErr as Error)?.message ?? alertErr);
        fatalLog.error('Fatal-path alert threw', {
          type,
          alertError: msg,
        });
      })
      .finally(() => {
        exitNow('alert_settled');
      });
  } catch (inner) {
    // Outer try is intentionally best-effort (we are exiting either way),
    // but we still emit a last-resort line directly to stderr so the crash
    // is not invisible if the structured logger itself fails.
    try {
      process.stderr.write(
        `fatal_exit_logging_failed type=${type} inner=${String(
          (inner as Error)?.message ?? inner,
        )}\n`,
      );
    } catch {
      /* truly nothing we can do */
    }
    exitNow('log_failed');
  } finally {
    // Ensure a non-zero exit code even if the process exits "naturally".
    process.exitCode = 1;
  }
}

process.on('uncaughtException', (err) => fatalExit('uncaught_exception', err));
process.on('unhandledRejection', (reason) => fatalExit('unhandled_rejection', reason));

async function main(): Promise<void> {
  const cli = parseCli(process.argv.slice(2));

  const bootLog = makeNodeLogger({ component: 'keeper' });

  if (cli.envPath) {
    const r = loadEnvFile(cli.envPath);
    bootLog(`Loaded env file: ${cli.envPath} (${r.count} vars)`);
  }

  if (cli.command === 'help' || cli.command === '-h' || cli.command === '--help') {
    usage();
    return;
  }

  const config = loadConfigFromEnv();

  if (cli.command === 'status') {
    printStatus({ statusPath: config.statusPath });
    return;
  }

  // Filesystem safety: the keeper state directory and pause/lock files are trusted inputs.
  // If these paths are writable by other users/processes on the same host, they can tamper
  // with the keeper's idempotency + safety rails (pause file, circuit breaker state, cursors, …).
  //
  // Default behaviour:
  // - Refuse to start if the state dir is world-writable.
  // - Warn (but continue) if the dir is group-writable.
  //
  // Override (NOT recommended): set KEEPER_ALLOW_INSECURE_FS=1.
  const allowInsecureFs = isTruthyEnv(process.env.KEEPER_ALLOW_INSECURE_FS);

  checkSecureDir({
    dirPath: config.stateDir,
    label: 'KEEPER_STATE_DIR',
    log: bootLog,
    allowInsecure: allowInsecureFs,
  });

  checkSecureDir({
    dirPath: config.deploymentStateDir,
    label: 'deployment state dir',
    log: bootLog,
    allowInsecure: allowInsecureFs,
  });

  checkSecureDir({
    dirPath: path.dirname(config.pauseFilePath),
    label: 'pause file dir',
    log: bootLog,
    allowInsecure: allowInsecureFs,
  });

  // Safety: if the same RPC auth token is configured for both endpoints but the URLs differ,
  // you may unintentionally send a private proxy token to a public upstream.
  if (
    config.privateRpcAuthToken &&
    config.publicRpcAuthToken &&
    config.privateRpcAuthToken === config.publicRpcAuthToken &&
    config.publicRpcUrl &&
    config.privateRpcUrl &&
    config.publicRpcUrl !== config.privateRpcUrl
  ) {
    bootLog(
      'WARN: RPC auth token is configured for both public + private RPC endpoints, but URLs differ. ' +
        'If the public RPC is a third-party upstream, prefer setting KEEPER_PRIVATE_RPC_AUTH_TOKEN and ' +
        'KEEPER_PUBLIC_RPC_AUTH_TOKEN separately to avoid leaking the private token.',
    );
  }

  const repoRoot = getRepoRoot();
  const { manifest } = loadDeploymentManifest({ repoRoot, deployment: config.deployment });
  const chainId = parseChainIdStrict(manifest?.chainId) ?? 0;
  const log = mkLogger(config.deployment, chainId);

  // L2-7 (2026-04-17): SIGHUP handler re-reads the deployment manifest from
  // disk and mutates the existing object in place. Task closures (built once
  // by `buildDaemonTaskDefs`) read `manifest.contracts.<key>.address` at call
  // time via `getContractAddress`, so mutating the object propagates new
  // addresses to every in-flight task without a restart. Chain-id changes
  // still require a restart (RPC boot check compares it on start). Docs and
  // ops runbook reference this via `kill -HUP <pid>` for manifest hot-swap.
  process.on('SIGHUP', () => {
    try {
      const { manifest: fresh } = loadDeploymentManifest({
        repoRoot,
        deployment: config.deployment,
      });
      const freshChainId = parseChainIdStrict((fresh as any)?.chainId) ?? 0;
      if (freshChainId !== chainId) {
        log(
          `SIGHUP: refused to reload manifest: chainId changed (boot=${chainId} fresh=${freshChainId}); restart keeper instead`,
        );
        return;
      }
      for (const key of Object.keys(manifest as Record<string, unknown>)) {
        delete (manifest as Record<string, unknown>)[key];
      }
      Object.assign(manifest as Record<string, unknown>, fresh as Record<string, unknown>);
      log('SIGHUP: deployment manifest reloaded in place');
    } catch (e: unknown) {
      const msg = (e as Error)?.message ?? String(e);
      log(`SIGHUP: manifest reload failed (keeping previous manifest): ${msg}`);
    }
  });

  const clients = buildClients({
    chainId,
    publicRpcUrl: config.publicRpcUrl,
    privateRpcUrl: config.privateRpcUrl,
    privateKey: config.privateKey,
    publicRpcAuthToken: config.publicRpcAuthToken,
    privateRpcAuthToken: config.privateRpcAuthToken,
    publicRpcTimeoutMs: config.publicRpcTimeoutMs,
    privateRpcTimeoutMs: config.privateRpcTimeoutMs,
    rpcRetryCount: config.rpcRetryCount,
    rpcBatchWaitMs: config.rpcBatchWaitMs,
    multicall3Address: config.multicall3Address,
    multicall3BlockCreated: config.multicall3BlockCreated,
  });

  // Scrub the private key from process.env after use.
  if (process.env.KEEPER_PRIVATE_KEY) {
    process.env.KEEPER_PRIVATE_KEY = '0x' + '0'.repeat(64); // pragma: allowlist secret
    delete process.env.KEEPER_PRIVATE_KEY;
  }

  // The viem Account holds the derived key internally; the raw hex is no longer needed.
  // Overwrite the key material before releasing the reference to reduce the window
  // where the raw hex is reachable in memory (e.g., via heap dumps, core dumps).
  if (typeof config.privateKey === 'string' && config.privateKey.length > 0) {
    // pragma: allowlist secret
    (config as any).privateKey = '0x' + '0'.repeat(64); // pragma: allowlist secret
  }
  (config as any).privateKey = undefined; // pragma: allowlist secret

  // Optional safety rail: refuse to run if the derived account address does not
  // match the expected keeper address. Prevents accidental live runs with the
  // wrong key (e.g. staging key in production or vice versa). Consider making
  // this check mandatory in production deployments.
  if (config.expectedAccountAddress) {
    const expected = String(config.expectedAccountAddress).toLowerCase();
    const actual = String(clients.account.address).toLowerCase();
    if (expected !== actual) {
      throw new Error(
        `keeper key mismatch: expectedAddress=${config.expectedAccountAddress} actualAddress=${clients.account.address}. ` +
          'Check KEEPER_PRIVATE_KEY and KEEPER_EXPECTED_ADDRESS.',
      );
    }
  }

  // Safety: ensure BOTH RPC endpoints are on the expected chain.
  // This catches misconfigured RPC URLs (or miswired RPC proxy) early before any tx attempts.
  //
  // Important: the keeper uses `publicRpcUrl` for reads (logs, eth_call, receipts) and
  // `privateRpcUrl` for transaction submission. A mismatch can cause silent tx failures
  // or, worse, transactions sent to the wrong network.
  const bootRpcTimeoutMs = 10_000;
  // Retry transient fetch/DNS errors at boot; structural errors still fail fast.
  // 5 attempts × exponential backoff (500/1000/2000/4000/8000ms between) ≈
  // up to ~15s of grace, which covers the typical "network not up yet" window
  // after a host reboot without masking real misconfiguration.
  const { publicChainId, privateChainId } = await probeChainIdsWithRetry({
    publicClient: clients.publicClient,
    walletClient: clients.walletClient,
    timeoutMs: bootRpcTimeoutMs,
    attempts: 5,
    baseBackoffMs: 500,
    log,
  });

  if (publicChainId !== chainId || privateChainId !== chainId) {
    throw new Error(
      `RPC chainId mismatch: expected=${chainId} public=${publicChainId} private=${privateChainId}. ` +
        `Check KEEPER_PUBLIC_RPC_URL and KEEPER_PRIVATE_RPC_URL (and any RPC proxy routing).`,
    );
  }

  const lock = await acquireLockMaybeWait({
    config,
    log,
    waitForLock: cli.command === 'daemon' ? config.daemonLockWaitSecs : 0,
  });

  const cleanup = (): void => {
    try {
      lock.release();
    } catch {
      /* best-effort cleanup */
    }
  };

  // On SIGINT/SIGTERM, give any in-flight microtask (a persistSettlement()
  // flush, a state-file write, a final webhook POST started but not yet
  // awaited) a bounded window to finish before we tear down the lock and
  // exit. Without this grace period, a state write interrupted at an
  // await point can leave the on-disk state one iteration behind the
  // last tx we actually sent — and the restarted keeper would then
  // re-do work that was already on-chain.
  //
  // A *hard* upper bound (SHUTDOWN_HARD_DEADLINE_MS) guarantees init
  // systems (systemd, docker, k8s) still see a timely exit even if a
  // misbehaving task deadlocks in a finally block.
  const SHUTDOWN_GRACE_MS = 1500;
  const SHUTDOWN_HARD_DEADLINE_MS = 5000;
  let shuttingDown = false;
  const gracefulExit = (code: number, signal: string): void => {
    if (shuttingDown) return;
    shuttingDown = true;
    log(`shutdown: received ${signal}, draining for up to ${SHUTDOWN_GRACE_MS}ms`);
    const hardKill = setTimeout(() => {
      try {
        cleanup();
      } catch {
        /* best-effort */
      }
      log(`shutdown: hard deadline reached, exiting with code ${code}`);
      process.exit(code);
    }, SHUTDOWN_HARD_DEADLINE_MS);
    hardKill.unref?.();

    setTimeout(() => {
      try {
        cleanup();
      } catch {
        /* best-effort */
      }
      process.exit(code);
    }, SHUTDOWN_GRACE_MS).unref?.();
  };
  process.on('SIGINT', () => gracefulExit(130, 'SIGINT'));
  process.on('SIGTERM', () => gracefulExit(143, 'SIGTERM'));

  try {
    await dispatchKeeperCommand({ cli, config, manifest, clients, log, lock });
  } finally {
    cleanup();
  }
}

main().catch((e) => fatalExit('main_error', e));
