import * as http from 'node:http';
import { timingSafeEqual } from 'node:crypto';
import dns from 'node:dns';
import net from 'node:net';
import { URL } from 'node:url';

import type { Address, Hash } from 'viem';

import type { Achievement } from '../achievements/index.js';
import { stringifyJson } from '../events.js';
import { clampStrictSafeInteger, parseStrictNonNegativeSafeInteger } from '../integers.js';
import { safeErrorString } from '../security/redact.js';
import type { ClaimRushEvent } from '../events.js';
import type { BackoffState, BackoffTransition } from './backoff.js';
import type { AgentActionResult, AgentPlan, AgentTxTelemetry } from './types.js';
import type { AgentStrategyTrace } from './strategies.js';

export type AgentMonitorOptions = {
  host: string;
  port: number;

  /** Optional bearer token. If set, requests must send: Authorization: Bearer <token> */
  token?: string;

  /** Max items kept per ring (default: 200). */
  maxRecent?: number;

  meta: {
    chain: string;
    chainId: number;
    agent: Address;
    user: Address;
    delegated: boolean;
    execute: boolean;
    outdir?: string;
    stateDir?: string;
    privateRpcMode?: 'off' | 'route' | 'only';
  };
};

type Ring<T> = {
  push: (v: T) => void;
  list: (limit?: number) => T[];
};

function makeRing<T>(max: number): Ring<T> {
  const cap = clampStrictSafeInteger(max, 1, 1, Number.MAX_SAFE_INTEGER);
  const buf: T[] = [];

  return {
    push: (v: T) => {
      buf.push(v);
      while (buf.length > cap) buf.shift();
    },
    list: (limit?: number) => {
      // Fail-closed: malformed or fractional limits are ignored (returns all
      // buffered items) rather than silently truncating.
      const parsed = limit === undefined ? undefined : parseStrictNonNegativeSafeInteger(limit);
      const n = parsed ?? buf.length;
      const slice = buf.slice(Math.max(0, buf.length - n));
      return slice.reverse(); // newest first
    },
  };
}

function json(res: http.ServerResponse, status: number, body: unknown): void {
  const out = stringifyJson(body, { pretty: true }) + '\n';
  res.statusCode = status;
  res.setHeader('content-type', 'application/json; charset=utf-8');
  res.end(out);
}

function text(res: http.ServerResponse, status: number, body: string): void {
  res.statusCode = status;
  res.setHeader('content-type', 'text/plain; charset=utf-8');
  res.end(body);
}

function getBearer(req: http.IncomingMessage): string | undefined {
  const h = req.headers['authorization'];
  if (!h) return undefined;
  const s = Array.isArray(h) ? h[0] : h;
  const m = /^Bearer\s+(.+)$/i.exec(s);
  return m?.[1];
}

function parseLimit(u: URL, fallback: number): number {
  const raw = u.searchParams.get('limit');
  if (!raw) return fallback;
  // Fail-closed: malformed or fractional `?limit=...` values fall back to the
  // caller-provided default rather than silently truncating (e.g. 1.5 → 1).
  return parseStrictNonNegativeSafeInteger(raw) ?? fallback;
}

export type AgentMonitorSnapshot = {
  tsMs: number;
  blockNumber: string;
  blockTimestamp: string;
};

export type AgentMonitorPlan = {
  tsMs: number;
  blockNumber: string;
  actions: { kind: string }[];
};

export type AgentMonitorStrategy = {
  tsMs: number;
  blockNumber: string;
  traces: {
    id: string;
    priority: number;
    ok: boolean;
    durationMs: number;
    actionCount: number;
    stop?: boolean;
    error?: string;
    notes?: string[];
  }[];
};

export type AgentMonitorEvent = {
  tsMs: number;
  name: string;
  blockNumber: string;
  transactionHash: Hash;
  logIndex: number;
  source: 'rpc' | 'subgraph';
};

export type AgentMonitorTx = {
  tsMs: number;
  actionKind: string;
  simulated: boolean;
  hash?: Hash;
  tx?: AgentTxTelemetry;
  receiptBlockNumber?: string;
  errorKind?: string;
  errorName?: string;
  error?: string;
};

export type AgentMonitorState = {
  startedAtMs: number;
  meta: AgentMonitorOptions['meta'];

  lastSnapshot?: AgentMonitorSnapshot;
  lastPlan?: AgentMonitorPlan;
  lastStrategyRun?: AgentMonitorStrategy;
  lastEvent?: AgentMonitorEvent;
  lastTx?: AgentMonitorTx;
  lastAchievement?: { tsMs: number; kind: string; level?: string };

  backoff?: BackoffState;
  eventCursor?: {
    chainId: number;
    rewindBlocks: string;
    lastProcessedBlock?: string;
    lastProcessedBlockHash?: Hash;
    recentKeyCount: number;
  };

  counters: {
    snapshots: number;
    plans: number;
    strategies: number;
    events: number;
    txs: number;
    txErrors: number;
    achievements: number;
  };
};

export class AgentMonitor {
  readonly url: string;

  private readonly token?: string;
  private readonly tokenBytes?: Buffer;
  private readonly server: http.Server;
  private readonly state: AgentMonitorState;

  private readonly recentPlans: Ring<AgentMonitorPlan>;
  private readonly recentStrategies: Ring<AgentMonitorStrategy>;
  private readonly recentEvents: Ring<AgentMonitorEvent>;
  private readonly recentTxs: Ring<AgentMonitorTx>;
  private readonly recentAchievements: Ring<Achievement>;

  private closed = false;

  constructor(opts: AgentMonitorOptions) {
    this.token = opts.token;
    this.tokenBytes = this.token ? Buffer.from(this.token) : undefined;

    const maxRecentRaw = opts.maxRecent ?? 200;
    const maxRecent = clampStrictSafeInteger(maxRecentRaw, 200, 1, 5000);

    this.recentPlans = makeRing(maxRecent);
    this.recentStrategies = makeRing(maxRecent);
    this.recentEvents = makeRing(maxRecent);
    this.recentTxs = makeRing(maxRecent);
    this.recentAchievements = makeRing(maxRecent);

    this.state = {
      startedAtMs: Date.now(),
      meta: opts.meta,
      counters: {
        snapshots: 0,
        plans: 0,
        strategies: 0,
        events: 0,
        txs: 0,
        txErrors: 0,
        achievements: 0,
      },
    };

    this.server = http.createServer((req, res) => {
      void this.handle(req, res);
    });

    this.url = `http://${opts.host}:${opts.port}`;
  }

  async listen(params: { host: string; port: number }): Promise<void> {
    await new Promise<void>((resolve, reject) => {
      this.server.once('error', reject);
      this.server.listen(params.port, params.host, () => resolve());
    });
  }

  async close(): Promise<void> {
    if (this.closed) return;
    this.closed = true;
    await new Promise<void>((resolve) => {
      this.server.close(() => resolve());
    });
  }

  // -----------------
  // Update hooks
  // -----------------

  onSnapshot(meta: { blockNumber: bigint; blockTimestamp: bigint }): void {
    const snap: AgentMonitorSnapshot = {
      tsMs: Date.now(),
      blockNumber: meta.blockNumber.toString(),
      blockTimestamp: meta.blockTimestamp.toString(),
    };
    this.state.lastSnapshot = snap;
    this.state.counters.snapshots++;
  }

  onPlan(plan: AgentPlan): void {
    const p: AgentMonitorPlan = {
      tsMs: Date.now(),
      blockNumber: plan.blockNumber.toString(),
      actions: plan.actions.map((a) => ({ kind: (a as any).kind as string })),
    };
    this.state.lastPlan = p;
    this.state.counters.plans++;
    this.recentPlans.push(p);
  }

  onStrategies(s: { blockNumber: bigint; traces: AgentStrategyTrace[] }): void {
    const r: AgentMonitorStrategy = {
      tsMs: Date.now(),
      blockNumber: s.blockNumber.toString(),
      traces: s.traces.map((t) => ({
        id: t.id,
        priority: t.priority,
        ok: t.ok,
        durationMs: t.durationMs,
        actionCount: t.actionCount,
        stop: t.stop,
        error: t.error,
        notes: t.notes,
      })),
    };
    this.state.lastStrategyRun = r;
    this.state.counters.strategies++;
    this.recentStrategies.push(r);
  }

  onEvent(ev: ClaimRushEvent): void {
    const e: AgentMonitorEvent = {
      tsMs: Date.now(),
      name: ev.event,
      blockNumber: ev.blockNumber.toString(),
      transactionHash: ev.transactionHash,
      logIndex: ev.logIndex,
      source: ev.source ?? 'rpc',
    };
    this.state.lastEvent = e;
    this.state.counters.events++;
    this.recentEvents.push(e);
  }

  onTxResult(res: AgentActionResult): void {
    const info: any = (res as any).errorInfo;
    const tx: AgentMonitorTx = {
      tsMs: Date.now(),
      actionKind: (res.action as any)?.kind ?? 'unknown',
      simulated: res.simulated,
      hash: res.hash,
      tx: res.tx,
      receiptBlockNumber: res.receiptBlockNumber ? res.receiptBlockNumber.toString() : undefined,
      errorKind: info?.kind,
      errorName: info?.name,
      error: res.error ? safeErrorString(res.error) : undefined,
    };

    this.state.lastTx = tx;
    this.state.counters.txs++;
    if (res.error && !res.simulated) this.state.counters.txErrors++;
    this.recentTxs.push(tx);
  }

  onAchievement(a: Achievement): void {
    this.state.lastAchievement = { tsMs: Date.now(), kind: a.kind, level: a.level };
    this.state.counters.achievements++;
    this.recentAchievements.push(a);
  }

  onBackoff(t: BackoffTransition): void {
    this.state.backoff = t.state;
  }

  setEventCursorSnapshot(s: {
    chainId: number;
    rewindBlocks: bigint;
    lastProcessedBlock?: bigint;
    lastProcessedBlockHash?: Hash;
    recentKeyCount: number;
  }): void {
    this.state.eventCursor = {
      chainId: s.chainId,
      rewindBlocks: s.rewindBlocks.toString(),
      lastProcessedBlock: s.lastProcessedBlock?.toString(),
      lastProcessedBlockHash: s.lastProcessedBlockHash,
      recentKeyCount: s.recentKeyCount,
    };
  }

  // -----------------
  // HTTP
  // -----------------

  private async handle(req: http.IncomingMessage, res: http.ServerResponse): Promise<void> {
    try {
      // POST/PUT/DELETE can confuse security scanners and theoretically allow request
      // smuggling through reverse proxies that treat POST bodies differently.
      const method = (req.method ?? '').toUpperCase();
      if (method !== 'GET' && method !== 'HEAD') {
        res.setHeader('allow', 'GET, HEAD');
        json(res, 405, { error: 'method not allowed' });
        return;
      }

      if (!req.url) {
        json(res, 400, { error: 'missing url' });
        return;
      }

      if (this.tokenBytes) {
        const got = getBearer(req);
        if (!got) {
          json(res, 401, { error: 'unauthorized' });
          return;
        }

        const gotBytes = Buffer.from(got);
        const ok =
          gotBytes.length === this.tokenBytes.length && timingSafeEqual(gotBytes, this.tokenBytes);

        if (!ok) {
          json(res, 401, { error: 'unauthorized' });
          return;
        }
      }

      const u = new URL(req.url, 'http://localhost');
      // slashes (e.g. /recent/%2e%2e/state). URL constructor decodes percent-encoded
      const path = u.pathname;

      if (path === '/' || path === '/help') {
        text(
          res,
          200,
          [
            'ClaimRush Agent Monitor',
            '',
            'GET /health',
            'GET /state',
            'GET /recent/plans?limit=50',
            'GET /recent/strategies?limit=50',
            'GET /recent/events?limit=50',
            'GET /recent/txs?limit=50',
            'GET /recent/achievements?limit=50',
            '',
          ].join('\n'),
        );
        return;
      }

      if (path === '/health') {
        const now = Date.now();
        const lastSnap = this.state.lastSnapshot;
        const lastSnapshotAgeMs = lastSnap ? now - lastSnap.tsMs : undefined;
        const backoff = this.state.backoff;
        json(res, 200, {
          ok: true,
          nowMs: now,
          uptimeSeconds: Math.floor(process.uptime()),
          ...this.state.meta,
          lastSnapshotAgeMs,
          backoffActive: backoff ? backoff.active && now < backoff.cooldownUntilMs : false,
          counters: this.state.counters,
        });
        return;
      }

      if (path === '/state') {
        json(res, 200, {
          ...this.state,
          nowMs: Date.now(),
          uptimeSeconds: Math.floor(process.uptime()),
        });
        return;
      }

      if (path === '/recent/plans') {
        json(res, 200, { items: this.recentPlans.list(parseLimit(u, 50)) });
        return;
      }

      if (path === '/recent/strategies') {
        json(res, 200, { items: this.recentStrategies.list(parseLimit(u, 50)) });
        return;
      }

      if (path === '/recent/events') {
        json(res, 200, { items: this.recentEvents.list(parseLimit(u, 50)) });
        return;
      }

      if (path === '/recent/txs') {
        json(res, 200, { items: this.recentTxs.list(parseLimit(u, 50)) });
        return;
      }

      if (path === '/recent/achievements') {
        json(res, 200, { items: this.recentAchievements.list(parseLimit(u, 50)) });
        return;
      }

      json(res, 404, { error: 'not found', path });
    } catch (err) {
      json(res, 500, { error: safeErrorString(err) });
    }
  }
}

const DNS_LOOKUP_TIMEOUT_MS = 1500;

function isLoopbackIpLiteral(host: string): boolean {
  const h = String(host ?? '')
    .trim()
    .toLowerCase();
  if (!h) return false;
  const ipType = net.isIP(h);
  if (ipType === 4) {
    return h.startsWith('127.');
  }
  if (ipType === 6) {
    if (h === '::1') return true;
    // v4-mapped IPv6 like ::ffff:127.0.0.1
    if (h.startsWith('::ffff:127.')) return true;
  }
  return false;
}

async function isLoopbackHost(host: string): Promise<boolean> {
  const h = String(host ?? '')
    .trim()
    .toLowerCase();
  if (!h) return false;

  if (net.isIP(h)) return isLoopbackIpLiteral(h);

  // Resolve hostnames (including 'localhost') and require all answers to be loopback.
  // This prevents binding the monitor publicly without a token if 'localhost' is misconfigured.
  try {
    const lookupPromise = dns.promises.lookup(h, { all: true, verbatim: true });
    const addrs = (await Promise.race([
      lookupPromise,
      new Promise<never>((_, reject) =>
        setTimeout(() => reject(new Error('dns lookup timeout')), DNS_LOOKUP_TIMEOUT_MS),
      ),
    ])) as Array<{ address: string; family: number }>;

    if (!Array.isArray(addrs) || addrs.length === 0) return false;
    return addrs.every((a) => isLoopbackIpLiteral(a.address));
  } catch {
    return false;
  }
}

export async function startAgentMonitor(opts: AgentMonitorOptions): Promise<AgentMonitor> {
  const host = String(opts.host ?? '').trim();

  // Security: treat only hosts that *resolve* to loopback as loopback.
  // Avoid token bypass via hostnames and avoid trusting 'localhost' without verification.
  const loopback = await isLoopbackHost(host);

  if (!loopback) {
    const token = String(opts.token ?? '').trim();
    if (!token) {
      throw new Error(
        `Refusing to bind AgentMonitor to non-loopback host '${safeErrorString(host)}' without a bearer token. Set monitorToken (Authorization: Bearer <token>) or use 127.0.0.1.`,
      );
    }
  }

  const mon = new AgentMonitor(opts);
  await mon.listen({ host: opts.host, port: opts.port });
  return mon;
}
