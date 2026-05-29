import crypto from 'node:crypto';

import { parseNonNegativeSafeInteger, parsePositiveSafeInteger } from './utils.js';

const ALERT_DEDUPE_MAX_KEYS = 1000;
const ALERT_DEDUPE_HARD_CAP = 5000;
const ALERT_ERROR_BODY_MAX_BYTES = 4_096;
const lastAlertAtMsByKey = new Map<string, number>();

function truncate(v: unknown, n: number): string {
  const s = String(v ?? '');
  if (s.length <= n) return s;
  return s.slice(0, Math.max(0, n - 1)) + '…';
}

function shortHash(s: string): string {
  return crypto.createHash('sha256').update(s).digest('hex').slice(0, 16);
}

const REDACT_PATTERNS: string[] = [
  'privatekey',
  'private_key',
  'authtoken',
  'auth_token',
  'authorization',
  'secret',
  'password',
  'token',
  'apikey',
  'api_key',
  'credential',
  'credentials',
  'mnemonic',
  'seed',
];

function isSensitiveKey(key: string): boolean {
  const k = String(key).toLowerCase();
  return REDACT_PATTERNS.some((p) => k === p || k.includes(p));
}

// Matches 0x-prefixed 64-char hex strings (256-bit private keys) in string
// values. Prevents accidentally leaking signing keys through alert webhooks
// when viem includes them in low-level error traces.
const HEX_256BIT_RE = /0x[0-9a-fA-F]{64}(?![0-9a-fA-F])/g;

function redactHex256InString(s: string): string {
  HEX_256BIT_RE.lastIndex = 0;
  if (!HEX_256BIT_RE.test(s)) return s;
  HEX_256BIT_RE.lastIndex = 0;
  return s.replace(HEX_256BIT_RE, '0x[REDACTED:hex256]');
}

function sanitizePayload(payload: unknown, depth = 0): unknown {
  if (depth > 5) return '[REDACTED:depth]';
  if (!payload || typeof payload !== 'object') return payload;
  if (Array.isArray(payload)) {
    return payload.map((item) => sanitizePayload(item, depth + 1));
  }
  const p = payload as Record<string, unknown>;
  const out: Record<string, unknown> = {};
  for (const [k, v] of Object.entries(p)) {
    if (isSensitiveKey(k)) {
      out[k] = '[REDACTED]';
    } else if (v && typeof v === 'object') {
      out[k] = sanitizePayload(v, depth + 1);
    } else {
      out[k] = typeof v === 'string' ? redactHex256InString(v) : v;
    }
  }
  if (typeof out.error === 'string' && (out.error as string).length > 2048) {
    out.error = (out.error as string).slice(0, 2048) + '…[truncated]';
  }
  if (typeof out.stack === 'string' && (out.stack as string).length > 4096) {
    out.stack = (out.stack as string).slice(0, 4096) + '…[truncated]';
  }
  return out;
}

function makeDedupeKey(payload: unknown): string {
  if (!payload || typeof payload !== 'object' || Array.isArray(payload)) {
    return `non_object|${truncate(payload, 200)}`;
  }

  const p = payload as Record<string, unknown>;
  const type = String(p.type ?? '');
  const action = String(p.action ?? '');
  const deployment = String(p.deployment ?? '');

  // Include `message` as a last-resort distinguishing field. Some callers
  // set `message` but omit both `error` and `reason`; without this, distinct
  // failures sharing (type|action|deployment) would collapse to the same
  // dedupe key and over-suppress legitimately different alerts. When both
  // `error`/`reason` and `message` are present, the former is preferred.
  const detail = String(p.error ?? p.reason ?? p.message ?? '');
  const detailKey = truncate(detail, 200);
  const detailHash = detail.length > 200 ? shortHash(detail) : '';

  const key = `${type}|${action}|${deployment}|${detailKey}|${detailHash}`;
  return key.trim() ? key : `unknown|${truncate(payload, 200)}`;
}

function pruneDedupeMap(cutoffMs: number): void {
  if (lastAlertAtMsByKey.size <= ALERT_DEDUPE_HARD_CAP) return;

  for (const [k, ts] of lastAlertAtMsByKey.entries()) {
    if (ts < cutoffMs) lastAlertAtMsByKey.delete(k);
  }

  // Hard cap to prevent unbounded growth (very unlikely in practice).
  if (lastAlertAtMsByKey.size <= ALERT_DEDUPE_MAX_KEYS) return;

  let removed = 0;
  for (const k of lastAlertAtMsByKey.keys()) {
    lastAlertAtMsByKey.delete(k);
    removed += 1;
    if (removed >= 100) break;
    if (lastAlertAtMsByKey.size <= ALERT_DEDUPE_MAX_KEYS) break;
  }
}

async function readResponseTextUpTo(
  res: Response,
  maxBytes: number,
): Promise<{ text: string; exceeded: boolean }> {
  const body = res.body;
  if (!body) return { text: '', exceeded: false };

  const reader = body.getReader();
  const chunks: Uint8Array[] = [];
  let total = 0;
  let exceeded = false;

  try {
    while (true) {
      const { done, value } = await reader.read();
      if (done) break;
      if (!value || value.byteLength === 0) continue;

      const remaining = maxBytes - total;
      if (remaining <= 0) {
        exceeded = true;
        try {
          await reader.cancel();
        } catch {
          // ignore
        }
        break;
      }

      if (value.byteLength > remaining) {
        chunks.push(value.slice(0, remaining));
        total += remaining;
        exceeded = true;
        try {
          await reader.cancel();
        } catch {
          // ignore
        }
        break;
      }

      chunks.push(value);
      total += value.byteLength;
    }
  } catch {
    return { text: '', exceeded: false };
  } finally {
    try {
      reader.releaseLock();
    } catch {
      // ignore
    }
  }

  const out = new Uint8Array(total);
  let offset = 0;
  for (const chunk of chunks) {
    out.set(chunk, offset);
    offset += chunk.byteLength;
  }

  return { text: new TextDecoder().decode(out), exceeded };
}

export async function postAlert(
  url: string | null | undefined,
  payload: unknown,
  {
    log,
    timeoutMs,
    dedupeWindowMs,
  }: {
    log?: ((msg: string) => void) | null;
    /** Optional override. If omitted, uses KEEPER_ALERT_TIMEOUT_MS/SECS or a safe default. */
    timeoutMs?: number | null;
    /** Optional alert de-duplication window. If omitted, uses KEEPER_ALERT_DEDUP_WINDOW_SECS. */
    dedupeWindowMs?: number | null;
  } = {},
): Promise<{ sent: boolean; status?: number; error?: string }> {
  if (!url) return { sent: false };

  // Optional de-dupe to prevent alert storms when the daemon repeats the same
  // failure every loop (RPC down, fee cap too low, etc).
  //
  // Default: disabled (0). Enable via KEEPER_ALERT_DEDUP_WINDOW_SECS="60" (example).
  const envDedupeSecs = parseNonNegativeSafeInteger(process.env.KEEPER_ALERT_DEDUP_WINDOW_SECS);
  const dedupeMs =
    parseNonNegativeSafeInteger(dedupeWindowMs ?? null) ??
    (envDedupeSecs != null ? envDedupeSecs * 1000 : 0);

  if (dedupeMs > 0) {
    const nowMs = Date.now();

    if (lastAlertAtMsByKey.size > ALERT_DEDUPE_HARD_CAP) {
      const cutoff = nowMs - Math.max(dedupeMs * 2, 5 * 60 * 1000);
      pruneDedupeMap(cutoff);
    }

    const key = makeDedupeKey(payload);
    const last = lastAlertAtMsByKey.get(key) ?? 0;
    if (last > 0 && nowMs - last < dedupeMs) {
      return { sent: false, error: `deduped within ${dedupeMs}ms` };
    }
    // Do NOT set the timestamp here. The window must anchor to the last
    // *successfully sent* alert. Setting it before send causes a sliding
    // window that never suppresses alerts arriving at exactly dedupeMs intervals.

    const cutoff = nowMs - Math.max(dedupeMs * 2, 5 * 60 * 1000);
    pruneDedupeMap(cutoff);
  }

  // Prevent alerting from hanging the keeper on slow/unresponsive endpoints.
  // Default: 5 seconds. Clamp to [250ms, 60s].
  const envMs = parsePositiveSafeInteger(process.env.KEEPER_ALERT_TIMEOUT_MS);
  const envSecs = parsePositiveSafeInteger(process.env.KEEPER_ALERT_TIMEOUT_SECS);
  const derived = envMs ?? (envSecs != null ? envSecs * 1000 : null);

  let tms = parsePositiveSafeInteger(timeoutMs ?? derived ?? 5000) ?? 5000;
  tms = Math.max(250, Math.min(60_000, tms));

  const controller = new AbortController();
  const timer = setTimeout(() => controller.abort(), tms);
  // Don't keep the process alive just to wait for an alert.
  (timer as any).unref?.();

  // misconfigured or injected URL (e.g. file://, ftp://) could trigger
  // unexpected behavior. Only allow http/https schemes.
  // NOTE: This validation is already present in the codebase.
  let parsedUrl: URL;
  try {
    parsedUrl = new URL(url);
  } catch {
    if (log) log(`alert webhook skipped: invalid URL`);
    return { sent: false, error: 'invalid URL' };
  }
  const scheme = parsedUrl.protocol.toLowerCase();
  if (scheme !== 'https:' && scheme !== 'http:') {
    if (log) log(`alert webhook skipped: unsupported scheme ${scheme}`);
    return { sent: false, error: `unsupported URL scheme: ${scheme}` };
  }

  try {
    const res = await fetch(parsedUrl.href, {
      method: 'POST',
      // Do not follow redirects when sending alert payloads. A redirect here is
      // usually a misconfiguration (wrong URL/path, Access/login page, etc) and
      // should be surfaced as a failure instead of leaking the payload elsewhere.
      redirect: 'manual',
      headers: { 'content-type': 'application/json' },
      body: JSON.stringify(sanitizePayload(payload)),
      signal: controller.signal,
    });

    if (!res.ok) {
      const { text, exceeded } = await readResponseTextUpTo(res, ALERT_ERROR_BODY_MAX_BYTES).catch(
        () => ({ text: '', exceeded: false }),
      );
      const snippetBase = text.slice(0, 200);
      const snippet = exceeded ? `${snippetBase}<body_too_large>` : snippetBase;
      if (log) log(`alert webhook HTTP ${res.status}: ${snippet}`);
      return { sent: false, status: res.status };
    }

    // Anchor dedup window to actual send time (not attempt time).
    if (dedupeMs > 0) {
      lastAlertAtMsByKey.set(makeDedupeKey(payload), Date.now());
    }

    return { sent: true, status: res.status };
  } catch (e: unknown) {
    const name = String((e as any)?.name ?? '');
    const msg = String((e as Error)?.message ?? e);

    if (name === 'AbortError') {
      if (log) log(`alert webhook timeout after ${tms}ms`);
      return { sent: false, error: `timeout after ${tms}ms` };
    }

    if (log) log(`alert webhook error: ${msg}`);
    return { sent: false, error: msg };
  } finally {
    try {
      clearTimeout(timer);
    } catch {
      // best-effort only
    }
  }
}
