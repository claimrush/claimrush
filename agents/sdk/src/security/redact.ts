import { URL } from 'node:url';

/**
 * Best-effort URL redaction for logs + artifacts.
 *
 * Goals:
 * - avoid leaking API keys embedded in URL paths (Infura/Alchemy/QuickNode style)
 * - avoid leaking basic auth credentials (user:pass@host)
 * - avoid leaking API keys embedded in hostnames (subdomain tokens)
 * - keep enough info (origin + short path prefix) for debugging
 */

function looksLikeToken(s: string): boolean {
  const v = String(s ?? '').trim();
  if (!v) return false;
  if (v.length < 16) return false;

  // Hex strings (common project IDs)
  if (/^[0-9a-f]{16,}$/i.test(v)) return true;

  // base64/base64url-ish
  if (/^[A-Za-z0-9+/]{16,}={0,2}$/.test(v)) return true;

  // Common provider project ids are alnum/underscore/hyphen and include digits.
  // Requiring digits reduces false-positives on long human-readable subdomains.
  if (/^[a-z0-9_-]{16,}$/i.test(v) && /\d/.test(v)) return true;

  return false;
}

function redactPathSegment(seg: string): string {
  const s = String(seg ?? '').trim();
  if (!s) return s;

  // Many providers embed API keys or tokens in long path segments.
  // Redact segments that look opaque (long, mostly alnum/hex/base64url-ish).
  if (s.length >= 16) {
    // Path segments are very likely to be secret (Infura/Alchemy/QuickNode style),
    // so be conservative and redact all long segments.
    return '<redacted>';
  }

  return s;
}

function redactHostnameForLogging(hostname: string): string {
  const h = String(hostname ?? '').trim();
  if (!h) return '';

  const lower = h.toLowerCase();
  if (lower === 'localhost') return h;

  // IP literals are not secrets.
  if (/^[0-9.]+$/.test(h)) return h;
  if (h.includes(':')) return h; // IPv6 or v4-mapped IPv6

  const labels = h.split('.').filter(Boolean);
  if (labels.length <= 2) return h;

  // Keep the registrable domain suffix (best-effort: last 2 labels).
  const head = labels.slice(0, Math.max(0, labels.length - 2));
  const tail = labels.slice(Math.max(0, labels.length - 2));

  const redHead = head.map((lab) => (looksLikeToken(lab) ? '<redacted>' : lab));
  return [...redHead, ...tail].join('.');
}

function redactHostLabelsInText(text: string): string {
  const s = String(text ?? '');
  if (!s) return s;

  // Catch token-like hostname labels even when a full URL isn't present.
  // Example: "getaddrinfo ENOTFOUND <token>.provider.com"
  return s.replace(/\b([a-z0-9_-]{16,})(?=\.)/gi, (m) => (looksLikeToken(m) ? '<redacted>' : m));
}

/**
 * Redact a URL string for logs/artifacts.
 *
 * Example:
 * - https://base-mainnet.infura.io/v3/ABCDEF... -> https://base-mainnet.infura.io/v3/<redacted>
 */

function tryRedactUrlForLogging(raw: string): string | undefined {
  try {
    const u = new URL(raw);

    // origin excludes username/password by design, but may include secret-y subdomains.
    const safeHostname = redactHostnameForLogging(u.hostname);
    const host = safeHostname.includes(':') ? `[${safeHostname}]` : safeHostname;
    const port = u.port ? `:${u.port}` : '';
    const origin = `${u.protocol}//${host}${port}`;

    const parts = u.pathname.split('/').filter(Boolean);
    const kept = parts.slice(0, 2).map(redactPathSegment);
    const safePath = kept.length ? `/${kept.join('/')}` : '';

    return origin + safePath;
  } catch {
    return undefined;
  }
}

export function redactUrlForLogging(raw: string): string {
  const s = String(raw ?? '').trim();
  if (!s) return '';

  const out = tryRedactUrlForLogging(s);
  return out ?? redactHostLabelsInText(s);
}

/**
 * Redact any http(s) URLs found in free-form text.
 */
export function redactUrlsInText(text: string): string {
  const s = String(text ?? '');
  if (!s) return s;

  // Match broadly, then trim common trailing punctuation until the candidate parses.
  // This supports IPv6 literal URLs like https://[::1]:8545/... which include brackets.
  return s.replace(/\bhttps?:\/\/[^\s"'<>]+/gi, (m) => {
    // First try as-is.
    const direct = tryRedactUrlForLogging(m);
    if (direct) return direct;

    // Otherwise, strip trailing punctuation one char at a time.
    let candidate = m;
    let suffix = '';
    const trailing = /[\]\)\}\,\.\;\:\!\?]+$/;

    while (candidate && trailing.test(candidate)) {
      const last = candidate[candidate.length - 1] as string;
      suffix = last + suffix;
      candidate = candidate.slice(0, -1);

      const attempt = tryRedactUrlForLogging(candidate);
      if (attempt) return attempt + suffix;
    }

    return m;
  });
}

/**
 * Convert an error into a stable, redacted string suitable for logs/artifacts.
 */
export function safeErrorString(err: unknown): string {
  let msg = '';
  try {
    if (typeof err === 'string') msg = err;
    else if (!err) msg = 'unknown error';
    else {
      const anyErr = err as any;
      msg = anyErr?.shortMessage ?? anyErr?.message ?? String(err);
    }
  } catch {
    msg = 'unknown error';
  }

  return redactHostLabelsInText(redactUrlsInText(msg));
}

function isPlainObject(v: unknown): v is Record<string, unknown> {
  if (!v || typeof v !== 'object') return false;
  const proto = Object.getPrototypeOf(v);
  return proto === Object.prototype || proto === null;
}

/**
 * Deep-redact any strings inside a JSON-like value for safe logging/artifacts.
 *
 * - Strings are passed through safeErrorString() (URL + hostname token redaction).
 * - Bigints are preserved (stringifyJson handles them).
 * - Objects/arrays are traversed up to maxDepth to avoid huge structures.
 */
export function redactJsonForLogging(value: unknown, opts?: { maxDepth?: number }): unknown {
  const maxDepth = Math.max(0, Math.floor(opts?.maxDepth ?? 6));
  const seen = new WeakSet<object>();

  const walk = (v: any, depth: number): any => {
    if (typeof v === 'string') return safeErrorString(v);
    if (typeof v === 'bigint' || typeof v === 'number' || typeof v === 'boolean') return v;
    if (v === null || v === undefined) return v;

    if (v instanceof URL) return redactUrlForLogging(v.toString());
    if (v instanceof Error) {
      return { name: v.name, message: safeErrorString(v) };
    }

    if (Array.isArray(v)) {
      if (depth >= maxDepth) {
        return v.map((x) => (typeof x === 'string' ? safeErrorString(x) : x));
      }
      return v.map((x) => walk(x, depth + 1));
    }

    if (typeof v === 'object') {
      if (seen.has(v)) return '<circular>';
      seen.add(v);

      const out: any = isPlainObject(v) ? Object.create(null) : {};
      const entries = Object.entries(v);

      if (depth >= maxDepth) {
        for (const [k, val] of entries) {
          out[k] = typeof val === 'string' ? safeErrorString(val) : val;
        }
        return out;
      }

      for (const [k, val] of entries) {
        out[k] = walk(val, depth + 1);
      }
      return out;
    }

    return v;
  };

  return walk(value as any, 0);
}
