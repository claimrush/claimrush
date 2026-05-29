/**
 * Lightweight HTTP health server for the keeper daemon.
 *
 * Exposes:
 *   GET /healthz  — JSON: `{ ok, uptimeSec }` without bearer auth; full status only when `KEEPER_HEALTH_TOKEN` is set and supplied
 *   GET /health   — alias for /healthz
 *   GET /metrics  — Prometheus text-format metrics
 *
 * Reads the keeper status file on demand and augments with live state
 * (lock held, uptime, etc.).
 *
 * Enable by setting `KEEPER_HEALTH_PORT` (e.g. `9091`).  Default host
 * is `127.0.0.1`.  Set `KEEPER_HEALTH_TOKEN` to require bearer auth.
 */

import crypto from 'node:crypto';
import http from 'node:http';

import { parseNonNegativeSafeInteger } from './utils.js';

function timingSafeEqualStr(a: string, b: string): boolean {
  const ha = crypto.createHash('sha256').update(String(a)).digest();
  const hb = crypto.createHash('sha256').update(String(b)).digest();
  return crypto.timingSafeEqual(ha, hb);
}

function isLoopbackHost(host: string): boolean {
  const h = String(host ?? '')
    .trim()
    .toLowerCase();
  return h === 'localhost' || h === '127.0.0.1' || h === '::1';
}

function escapeLabelValue(v: string): string {
  return String(v).replace(/\\/g, '\\\\').replace(/\n/g, '\\n').replace(/"/g, '\\"');
}

function formatLabels(labels: Record<string, unknown>): string {
  const parts: string[] = [];
  for (const [k, v] of Object.entries(labels)) {
    if (v == null) continue;
    parts.push(`${k}="${escapeLabelValue(String(v))}"`);
  }
  return parts.length ? `{${parts.join(',')}}` : '';
}

function toMetricNumber(value: unknown): number {
  if (typeof value === 'number') return Number.isFinite(value) ? value : 0;
  if (typeof value === 'bigint') {
    if (value < BigInt(Number.MIN_SAFE_INTEGER) || value > BigInt(Number.MAX_SAFE_INTEGER))
      return 0;
    return Number(value);
  }
  return 0;
}

function metricLine(name: string, labels: Record<string, unknown>, value: unknown): string {
  const n = toMetricNumber(value);
  return `${name}${formatLabels(labels)} ${n}`;
}

/**
 * Build Prometheus text-format metrics from keeper health data.
 */
export function buildPrometheusMetrics(data: {
  deployment: string;
  chainId: number;
  lockHeld: boolean;
  uptimeSec: number;
  status: Record<string, unknown> | null;
}): string {
  const { deployment, chainId, lockHeld, uptimeSec, status } = data;
  const labels: Record<string, unknown> = {
    deployment,
    chain_id: chainId,
    component: 'keeper',
  };

  const lines: string[] = [];

  lines.push('# HELP claimrush_keeper_up 1 if the keeper process is running.');
  lines.push('# TYPE claimrush_keeper_up gauge');
  lines.push(metricLine('claimrush_keeper_up', labels, 1));

  lines.push('# HELP claimrush_keeper_lock_held 1 if the file lock is currently held.');
  lines.push('# TYPE claimrush_keeper_lock_held gauge');
  lines.push(metricLine('claimrush_keeper_lock_held', labels, lockHeld ? 1 : 0));

  lines.push('# HELP claimrush_keeper_uptime_seconds Process uptime in seconds.');
  lines.push('# TYPE claimrush_keeper_uptime_seconds gauge');
  lines.push(metricLine('claimrush_keeper_uptime_seconds', labels, uptimeSec));

  if (status) {
    // Per-task last-attempt age in seconds.
    const lastAttemptByTask = (status.lastAttemptByTask ?? {}) as Record<string, string | null>;
    const taskKeys = Object.keys(lastAttemptByTask);
    if (taskKeys.length) {
      lines.push(
        '# HELP claimrush_keeper_task_last_attempt_age_seconds Seconds since last attempt per task.',
      );
      lines.push('# TYPE claimrush_keeper_task_last_attempt_age_seconds gauge');

      const nowMs = Date.now();
      for (const task of taskKeys) {
        const ts = lastAttemptByTask[task];
        if (!ts) continue;
        const parsed = Date.parse(ts);
        if (!Number.isFinite(parsed)) continue;
        const ageSec = Math.max(0, Math.floor((nowMs - parsed) / 1000));
        lines.push(
          metricLine('claimrush_keeper_task_last_attempt_age_seconds', { ...labels, task }, ageSec),
        );
      }
    }

    // Per-task last-success age in seconds.
    const lastSuccessByTask = (status.lastSuccessByTask ?? {}) as Record<string, string | null>;
    const successKeys = Object.keys(lastSuccessByTask);
    if (successKeys.length) {
      lines.push(
        '# HELP claimrush_keeper_task_last_success_age_seconds Seconds since last success per task.',
      );
      lines.push('# TYPE claimrush_keeper_task_last_success_age_seconds gauge');

      const nowMs = Date.now();
      for (const task of successKeys) {
        const ts = lastSuccessByTask[task];
        if (!ts) continue;
        const parsed = Date.parse(ts);
        if (!Number.isFinite(parsed)) continue;
        const ageSec = Math.max(0, Math.floor((nowMs - parsed) / 1000));
        lines.push(
          metricLine('claimrush_keeper_task_last_success_age_seconds', { ...labels, task }, ageSec),
        );
      }
    }

    // Per-task last-skip age in seconds.
    const lastSkipByTask = (status.lastSkipByTask ?? {}) as Record<string, string | null>;
    const skipKeys = Object.keys(lastSkipByTask);
    if (skipKeys.length) {
      lines.push(
        '# HELP claimrush_keeper_task_last_skip_age_seconds Seconds since last skip per task.',
      );
      lines.push('# TYPE claimrush_keeper_task_last_skip_age_seconds gauge');

      const nowMs = Date.now();
      for (const task of skipKeys) {
        const ts = lastSkipByTask[task];
        if (!ts) continue;
        const parsed = Date.parse(ts);
        if (!Number.isFinite(parsed)) continue;
        const ageSec = Math.max(0, Math.floor((nowMs - parsed) / 1000));
        lines.push(
          metricLine('claimrush_keeper_task_last_skip_age_seconds', { ...labels, task }, ageSec),
        );
      }
    }

    // Per-task revert counts.
    const revertCounts = (status.revertCounts ?? {}) as Record<string, number>;
    const revertKeys = Object.keys(revertCounts);
    if (revertKeys.length) {
      lines.push('# HELP claimrush_keeper_task_revert_count Total reverts per task.');
      lines.push('# TYPE claimrush_keeper_task_revert_count counter');
      for (const task of revertKeys) {
        const count = parseNonNegativeSafeInteger(revertCounts[task], { defaultValue: null });
        if (count == null) continue;
        lines.push(metricLine('claimrush_keeper_task_revert_count', { ...labels, task }, count));
      }
    }
  }

  return `${lines.join('\n')}\n`;
}

// Simple per-IP rate limiter to prevent DoS via health endpoint flooding.
// Each request reads the status file from disk; unbounded requests can starve
// the keeper's transaction pipeline I/O.
const RATE_WINDOW_MS = 10_000;
const RATE_MAX_REQUESTS = 30;
const RATE_CLEANUP_INTERVAL_MS = 30_000;
const ipHits = new Map<string, { count: number; windowStart: number }>();
let lastCleanupMs = Date.now();

function pruneStaleIpEntries(): void {
  const now = Date.now();
  if (now - lastCleanupMs < RATE_CLEANUP_INTERVAL_MS && ipHits.size <= 1000) return;
  lastCleanupMs = now;
  for (const [k, v] of ipHits.entries()) {
    if (now - v.windowStart > RATE_WINDOW_MS) ipHits.delete(k);
  }
}

function checkRateLimit(ip: string): boolean {
  const now = Date.now();
  pruneStaleIpEntries();
  let entry = ipHits.get(ip);
  if (!entry || now - entry.windowStart > RATE_WINDOW_MS) {
    entry = { count: 1, windowStart: now };
    ipHits.set(ip, entry);
    return true;
  }
  entry.count += 1;
  return entry.count <= RATE_MAX_REQUESTS;
}

export interface KeeperHealthServerOptions {
  host: string;
  port: number;
  /** Optional bearer token. When set, all requests must include `Authorization: Bearer <token>`. */
  token?: string | null;
  getStatus: () => Record<string, unknown> | null;
  deployment: string;
  chainId: number;
  isLockHeld: () => boolean;
  log: (msg: string) => void;
}

/**
 * Start the keeper health HTTP server.
 */
export async function startKeeperHealthServer(
  opts: KeeperHealthServerOptions,
): Promise<http.Server | null> {
  const { host, port, getStatus, deployment, chainId, isLockHeld, log } = opts;
  const startedAtMs = Date.now();
  const requiredToken = (opts.token ?? '').trim() || null;

  if (!Number.isFinite(port) || port <= 0) return null;

  if (!requiredToken && !isLoopbackHost(host)) {
    throw new Error(
      `Refusing to start unauthenticated keeper health server on host "${host}". ` +
        `Set KEEPER_HEALTH_TOKEN or bind KEEPER_HEALTH_HOST=127.0.0.1.`,
    );
  }

  const server = http.createServer(async (req, res) => {
    try {
      const clientIp = String(req.socket?.remoteAddress ?? 'unknown');
      if (!checkRateLimit(clientIp)) {
        res.writeHead(429, {
          'content-type': 'text/plain; charset=utf-8',
          'cache-control': 'no-store',
          'retry-after': '10',
        });
        res.end('Too Many Requests');
        return;
      }
      const method = String(req.method ?? 'GET').toUpperCase();
      if (method !== 'GET' && method !== 'HEAD') {
        res.writeHead(405, {
          'content-type': 'text/plain; charset=utf-8',
          'cache-control': 'no-store',
          'x-content-type-options': 'nosniff',
        });
        res.end('Method Not Allowed');
        return;
      }

      if (requiredToken) {
        const auth = (req.headers['authorization'] ?? '').toString().trim();
        if (!timingSafeEqualStr(auth, `Bearer ${requiredToken}`)) {
          res.writeHead(403, {
            'content-type': 'text/plain; charset=utf-8',
            'cache-control': 'no-store',
            'x-content-type-options': 'nosniff',
          });
          res.end('Forbidden');
          return;
        }
      }

      const url = new URL(req.url ?? '/', 'http://localhost');
      const exposeFullStatus = Boolean(requiredToken);

      if (url.pathname === '/healthz' || url.pathname === '/health') {
        const lockHeld = isLockHeld();
        const uptimeSec = Math.max(0, Math.floor((Date.now() - startedAtMs) / 1000));
        const ok = lockHeld;

        const body = exposeFullStatus
          ? JSON.stringify(
              {
                ok,
                component: 'keeper',
                deployment,
                chainId,
                lockHeld,
                uptimeSec,
                status: getStatus(),
              },
              null,
              2,
            )
          : JSON.stringify({ ok, uptimeSec });

        res.writeHead(ok ? 200 : 503, {
          'content-type': 'application/json; charset=utf-8',
          'cache-control': 'no-store',
          'x-content-type-options': 'nosniff',
        });
        res.end(body);
        return;
      }

      if (url.pathname === '/metrics') {
        // Only expose per-task status data when the caller has authenticated.
        // On unauthenticated loopback, emit only the basic up/lock/uptime gauges.
        const status = exposeFullStatus ? getStatus() : null;
        const lockHeld = isLockHeld();
        const uptimeSec = Math.max(0, Math.floor((Date.now() - startedAtMs) / 1000));
        const body = buildPrometheusMetrics({ deployment, chainId, lockHeld, uptimeSec, status });

        res.writeHead(200, {
          'content-type': 'text/plain; version=0.0.4; charset=utf-8',
          'cache-control': 'no-store',
          'x-content-type-options': 'nosniff',
        });
        res.end(body);
        return;
      }

      res.writeHead(404, {
        'content-type': 'text/plain; charset=utf-8',
        'cache-control': 'no-store',
        'x-content-type-options': 'nosniff',
      });
      res.end('Not found');
    } catch (e) {
      const errMsg = String((e as Error)?.message ?? e);
      log(
        `keeper health server error: ${errMsg.length > 200 ? errMsg.slice(0, 200) + '…' : errMsg}`,
      );
      if (!res.headersSent) {
        res.writeHead(500, {
          'content-type': 'text/plain; charset=utf-8',
          'cache-control': 'no-store',
          'x-content-type-options': 'nosniff',
        });
      }
      try {
        res.end('Internal Server Error');
      } catch {
        // Socket may already be destroyed; best-effort only.
      }
    }
  });

  // Reduce exposure to slowloris-style connection holding. The health server is
  // intentionally simple; keep its timeouts tight.
  server.keepAliveTimeout = 5_000;
  server.headersTimeout = 10_000;
  server.requestTimeout = 10_000;

  await new Promise<void>((resolve, reject) => {
    server.once('error', reject);
    server.listen(port, host, () => {
      server.off('error', reject);
      resolve();
    });
  });

  log(`Health server listening on http://${host}:${port} (/healthz, /metrics)`);
  return server;
}
