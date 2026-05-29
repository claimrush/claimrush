/* global URL, TextEncoder */

/**
 * Lightweight HTTP health server for the keeper daemon.
 *
 * Exposes:
 *   GET /healthz  — structured JSON health status
 *   GET /health   — alias for /healthz
 *   GET /metrics  — Prometheus text-format metrics
 *
 * Reads the keeper status file on demand and augments with live state
 * (lock held, uptime, etc.).
 *
 * Enable by setting `KEEPER_HEALTH_PORT` (e.g. `9091`).  Default host
 * is `127.0.0.1`.  Set `KEEPER_HEALTH_TOKEN` to require bearer auth.
 */

import http from 'node:http';

const startedAtMs = Date.now();

const authTextEncoder = new TextEncoder();

function timingSafeEqualStr(a, b) {
  const aBytes = authTextEncoder.encode(String(a));
  const bBytes = authTextEncoder.encode(String(b));
  const len = Math.max(aBytes.length, bBytes.length);
  let mismatch = aBytes.length ^ bBytes.length;
  for (let i = 0; i < len; i++) {
    mismatch |= (aBytes[i] ?? 0) ^ (bBytes[i] ?? 0);
  }
  return mismatch === 0;
}

function isLoopbackHost(host) {
  const h = String(host ?? '')
    .trim()
    .toLowerCase();
  return h === 'localhost' || h === '127.0.0.1' || h === '::1';
}

/**
 * @param {string} v
 * @returns {string}
 */
function escapeLabelValue(v) {
  return String(v).replace(/\\/g, '\\\\').replace(/\n/g, '\\n').replace(/"/g, '\\"');
}

/**
 * @param {Record<string, unknown>} labels
 * @returns {string}
 */
function formatLabels(labels) {
  const parts = [];
  for (const [k, v] of Object.entries(labels)) {
    if (v == null) continue;
    parts.push(`${k}="${escapeLabelValue(String(v))}"`);
  }
  return parts.length ? `{${parts.join(',')}}` : '';
}

function toMetricNumber(value) {
  if (typeof value === 'number') return Number.isFinite(value) ? value : 0;
  if (typeof value === 'bigint') {
    if (value < BigInt(Number.MIN_SAFE_INTEGER) || value > BigInt(Number.MAX_SAFE_INTEGER)) {
      return 0;
    }
    return Number(value);
  }
  return 0;
}

/**
 * @param {string} name
 * @param {Record<string, unknown>} labels
 * @param {unknown} value
 * @returns {string}
 */
function metricLine(name, labels, value) {
  const n = toMetricNumber(value);
  return `${name}${formatLabels(labels)} ${n}`;
}

/**
 * Build Prometheus text-format metrics from keeper health data.
 *
 * @param {{ deployment: string; chainId: number; lockHeld: boolean; uptimeSec: number; status: any }} data
 * @returns {string}
 */
function buildPrometheusMetrics({ deployment, chainId, lockHeld, uptimeSec, status }) {
  const labels = {
    deployment,
    chain_id: chainId,
    component: 'keeper',
  };

  /** @type {string[]} */
  const lines = [];

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
    const taskKeys = Object.keys(status.lastAttemptByTask ?? {});
    if (taskKeys.length) {
      lines.push(
        '# HELP claimrush_keeper_task_last_attempt_age_seconds Seconds since last attempt per task.',
      );
      lines.push('# TYPE claimrush_keeper_task_last_attempt_age_seconds gauge');

      const nowMs = Date.now();
      for (const task of taskKeys) {
        const ts = status.lastAttemptByTask[task];
        if (!ts) continue;
        const parsed = Date.parse(ts);
        if (!Number.isFinite(parsed)) continue;
        const ageSec = Math.max(0, Math.floor((nowMs - parsed) / 1000));
        lines.push(
          metricLine('claimrush_keeper_task_last_attempt_age_seconds', { ...labels, task }, ageSec),
        );
      }
    }

    // Per-task revert counts.
    const revertKeys = Object.keys(status.revertCounts ?? {});
    if (revertKeys.length) {
      lines.push('# HELP claimrush_keeper_task_revert_count Total reverts per task.');
      lines.push('# TYPE claimrush_keeper_task_revert_count counter');
      for (const task of revertKeys) {
        const count = toMetricNumber(status.revertCounts[task] ?? 0);
        if (!count && status.revertCounts[task] !== 0 && status.revertCounts[task] !== 0n) continue;
        lines.push(metricLine('claimrush_keeper_task_revert_count', { ...labels, task }, count));
      }
    }
  }

  return `${lines.join('\n')}\n`;
}

/**
 * @typedef {{
 *   host: string;
 *   port: number;
 *   token?: string | null;
 *   getStatus: () => any;
 *   deployment: string;
 *   chainId: number;
 *   isLockHeld: () => boolean;
 *   log: (msg: string) => void;
 * }} KeeperHealthServerOptions
 */

/**
 * Start the keeper health HTTP server.
 *
 * @param {KeeperHealthServerOptions} opts
 * @returns {Promise<http.Server | null>}
 */
export async function startKeeperHealthServer(opts) {
  const { host, port, getStatus, deployment, chainId, isLockHeld, log } = opts;
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
      if (requiredToken) {
        const auth = (req.headers['authorization'] ?? '').toString().trim();
        if (!timingSafeEqualStr(auth, `Bearer ${requiredToken}`)) {
          res.writeHead(403, {
            'content-type': 'text/plain; charset=utf-8',
            'cache-control': 'no-store',
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
        });
        res.end(body);
        return;
      }

      if (url.pathname === '/metrics') {
        const status = getStatus();
        const lockHeld = isLockHeld();
        const uptimeSec = Math.max(0, Math.floor((Date.now() - startedAtMs) / 1000));
        const body = buildPrometheusMetrics({ deployment, chainId, lockHeld, uptimeSec, status });

        res.writeHead(200, {
          'content-type': 'text/plain; version=0.0.4; charset=utf-8',
          'cache-control': 'no-store',
        });
        res.end(body);
        return;
      }

      res.writeHead(404, {
        'content-type': 'text/plain; charset=utf-8',
        'cache-control': 'no-store',
      });
      res.end('Not found');
    } catch (e) {
      log(`keeper health server error: ${/** @type {Error} */ (e)?.stack ?? String(e)}`);
      res.writeHead(500, {
        'content-type': 'text/plain; charset=utf-8',
        'cache-control': 'no-store',
      });
      res.end('Internal Server Error');
    }
  });

  await new Promise((resolve, reject) => {
    server.once('error', reject);
    server.listen(port, host, () => {
      server.off('error', reject);
      resolve(undefined);
    });
  });

  log(`Health server listening on http://${host}:${port} (/healthz, /metrics)`);
  return server;
}
