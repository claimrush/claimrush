import dns from 'node:dns';
import { URL } from 'node:url';

import { safeErrorString } from './redact.js';

export type OutboundUrlPolicy = {
  /** Allowed URL protocols. Default: ['https:', 'http:'] */
  allowedProtocols?: string[];

  /** Exact-match hostname allowlist (lowercased). If set, only these hosts are allowed. */
  allowedHosts?: string[];

  /** Exact-match hostname denylist (lowercased). */
  deniedHosts?: string[];

  /** Allow URLs with username/password components. Default: false */
  allowCredentials?: boolean;

  /** Allow loopback hosts (localhost, 127.0.0.0/8, ::1). Default: true */
  allowLoopback?: boolean;

  /** Allow RFC1918 private IPv4 + IPv6 unique-local addresses. Default: true */
  allowPrivateIps?: boolean;

  /** Allow link-local IP ranges (169.254.0.0/16, fe80::/10). Default: false */
  allowLinkLocal?: boolean;

  /** Allow following redirects in fetch(). Default: false */
  allowRedirects?: boolean;

  /**
   * Resolve hostnames to IPs and apply allow/deny rules to the resolved addresses.
   *
   * Mitigates SSRF via DNS (hostname -> private/link-local/denylisted IP).
   *
   * Default: true for hostname targets unless explicitly disabled.
   */
  resolveDns?: boolean;

  /** DNS lookup timeout (ms). Default: 2000. */
  dnsLookupTimeoutMs?: number;
};

export const DEFAULT_OUTBOUND_URL_POLICY: Required<
  Pick<
    OutboundUrlPolicy,
    | 'allowedProtocols'
    | 'allowedHosts'
    | 'deniedHosts'
    | 'allowCredentials'
    | 'allowLoopback'
    | 'allowPrivateIps'
    | 'allowLinkLocal'
    | 'allowRedirects'
  >
> = {
  allowedProtocols: ['https:', 'http:'],
  allowedHosts: [],
  deniedHosts: [
    // Cloud metadata services (common SSRF targets)
    '169.254.169.254',
    '169.254.170.2',
    '100.100.100.200',
    'metadata.google.internal',
    'metadata',
    'fd00:ec2::254',
    // Unspecified / invalid as outbound targets
    '0.0.0.0',
    '::',
  ],
  allowCredentials: false,
  allowLoopback: true,
  allowPrivateIps: true,
  allowLinkLocal: false,
  allowRedirects: false,
};

/**
 * Safer defaults for *public* HTTP(S) endpoints (subgraphs, achievements APIs, etc).
 *
 * Compared to DEFAULT_OUTBOUND_URL_POLICY this:
 * - disallows loopback + RFC1918/ULA targets (mitigates SSRF to internal services)
 * - disallows credentials in URLs
 */
export const DEFAULT_PUBLIC_HTTP_URL_POLICY: OutboundUrlPolicy = {
  ...DEFAULT_OUTBOUND_URL_POLICY,
  allowCredentials: false,
  allowLoopback: false,
  allowPrivateIps: false,
  allowLinkLocal: false,
  allowRedirects: false,
};

function normalizeHostname(raw: string): string {
  let h = String(raw ?? '')
    .trim()
    .toLowerCase();

  // Node's WHATWG URL keeps IPv6 hosts bracketed (e.g. "[::1]").
  if (h.startsWith('[') && h.endsWith(']')) {
    h = h.slice(1, -1);
  }

  // Strip RFC6874 zone identifiers, e.g. "fe80::1%25lo0".
  const pct = h.indexOf('%');
  if (pct >= 0) {
    h = h.slice(0, pct);
  }

  // Strip a trailing dot for FQDN canonicalization.
  while (h.endsWith('.')) {
    h = h.slice(0, -1);
  }

  return h;
}

function uniqNormalizedHosts(list: string[] | undefined): string[] {
  if (!list || list.length === 0) return [];
  const out: string[] = [];
  const seen = new Set<string>();
  for (const v of list) {
    const s = normalizeHostname(String(v));
    if (!s) continue;
    if (seen.has(s)) continue;
    seen.add(s);
    out.push(s);
  }
  return out;
}

function isIpv4Literal(host: string): boolean {
  if (!/^[0-9.]+$/.test(host)) return false;
  const parts = host.split('.');
  if (parts.length !== 4) return false;
  for (const p of parts) {
    if (!p.length) return false;
    if (p.length > 1 && p.startsWith('0')) {
      // Avoid octal ambiguity.
      return false;
    }
    const n = Number(p);
    if (!Number.isInteger(n) || n < 0 || n > 255) return false;
  }
  return true;
}

function ipv4ToInt(host: string): number {
  const [a, b, c, d] = host.split('.').map((x) => Number(x));
  return (((a << 24) >>> 0) + (b << 16) + (c << 8) + d) >>> 0;
}

function inIpv4Cidr(host: string, base: string, maskBits: number): boolean {
  if (!isIpv4Literal(host) || !isIpv4Literal(base)) return false;
  const h = ipv4ToInt(host);
  const b = ipv4ToInt(base);
  const mask = maskBits === 0 ? 0 : (0xffff_ffff << (32 - maskBits)) >>> 0;
  return (h & mask) === (b & mask);
}

function parseIpv4Bytes(host: string): number[] | undefined {
  if (!isIpv4Literal(host)) return undefined;
  const parts = host.split('.').map((x) => Number(x));
  if (parts.length !== 4) return undefined;
  for (const n of parts) {
    if (!Number.isInteger(n) || n < 0 || n > 255) return undefined;
  }
  return parts;
}

function parseHextet(h: string): number | undefined {
  if (!h || h.length > 4) return undefined;
  if (!/^[0-9a-f]{1,4}$/i.test(h)) return undefined;
  const n = Number.parseInt(h, 16);
  if (!Number.isFinite(n) || n < 0 || n > 0xffff) return undefined;
  return n;
}

function parseIpv6ToBytes(host: string): Uint8Array | undefined {
  // Best-effort IPv6 parser for literal addresses.
  // Returns undefined if the input does not look like IPv6.
  const h = host.toLowerCase();
  if (!h.includes(':')) return undefined;

  const parts = h.split('::');
  if (parts.length > 2) return undefined;

  const hasCompression = parts.length === 2;

  const headParts = parts[0] ? parts[0].split(':').filter((p) => p.length > 0) : [];
  const tailParts = hasCompression
    ? parts[1]
      ? parts[1].split(':').filter((p) => p.length > 0)
      : []
    : [];

  // Optional IPv4 tail, e.g. ::ffff:192.0.2.1
  let ipv4Bytes: number[] | undefined;
  const tailHasIpv4 = tailParts.length > 0 && tailParts[tailParts.length - 1]!.includes('.');
  const headHasIpv4 =
    !hasCompression && headParts.length > 0 && headParts[headParts.length - 1]!.includes('.');

  if (tailHasIpv4) {
    ipv4Bytes = parseIpv4Bytes(tailParts[tailParts.length - 1]!);
    if (!ipv4Bytes) return undefined;
    tailParts.pop();
  } else if (headHasIpv4) {
    ipv4Bytes = parseIpv4Bytes(headParts[headParts.length - 1]!);
    if (!ipv4Bytes) return undefined;
    headParts.pop();
  }

  const ipv4Hextets = ipv4Bytes ? 2 : 0;
  const totalHextets = headParts.length + tailParts.length + ipv4Hextets;

  if (!hasCompression) {
    // No '::' compression: must be exactly 8 hextets.
    if (totalHextets !== 8) return undefined;
  } else {
    if (totalHextets > 8) return undefined;
  }

  const missing = hasCompression ? 8 - totalHextets : 0;

  const hextets: number[] = [];

  for (const p of headParts) {
    const n = parseHextet(p);
    if (n === undefined) return undefined;
    hextets.push(n);
  }

  for (let i = 0; i < missing; i++) hextets.push(0);

  for (const p of tailParts) {
    const n = parseHextet(p);
    if (n === undefined) return undefined;
    hextets.push(n);
  }

  if (ipv4Bytes) {
    hextets.push(((ipv4Bytes[0]! << 8) | ipv4Bytes[1]!) & 0xffff);
    hextets.push(((ipv4Bytes[2]! << 8) | ipv4Bytes[3]!) & 0xffff);
  }

  if (hextets.length !== 8) return undefined;

  const out = new Uint8Array(16);
  for (let i = 0; i < 8; i++) {
    const n = hextets[i]!;
    out[i * 2] = (n >> 8) & 0xff;
    out[i * 2 + 1] = n & 0xff;
  }

  return out;
}

function isIpv4MappedIpv6(bytes: Uint8Array): boolean {
  // ::ffff:0:0/96
  for (let i = 0; i < 10; i++) {
    if (bytes[i] !== 0) return false;
  }
  return bytes[10] === 0xff && bytes[11] === 0xff;
}

function ipv4FromMapped(bytes: Uint8Array): string {
  return `${bytes[12]}.${bytes[13]}.${bytes[14]}.${bytes[15]}`;
}

function isLoopback(host: string): boolean {
  const h = host.toLowerCase();
  if (h === 'localhost') return true;
  if (isIpv4Literal(h) && inIpv4Cidr(h, '127.0.0.0', 8)) return true;

  const v6 = parseIpv6ToBytes(h);
  if (!v6) return false;

  // IPv4-mapped loopback
  if (isIpv4MappedIpv6(v6)) {
    const v4 = ipv4FromMapped(v6);
    return inIpv4Cidr(v4, '127.0.0.0', 8);
  }

  // ::1
  for (let i = 0; i < 15; i++) {
    if (v6[i] !== 0) return false;
  }
  return v6[15] === 1;
}

function isLinkLocal(host: string): boolean {
  const h = host.toLowerCase();

  if (isIpv4Literal(h) && inIpv4Cidr(h, '169.254.0.0', 16)) return true;

  const v6 = parseIpv6ToBytes(h);
  if (!v6) return false;

  // IPv4-mapped link-local
  if (isIpv4MappedIpv6(v6)) {
    const v4 = ipv4FromMapped(v6);
    return inIpv4Cidr(v4, '169.254.0.0', 16);
  }

  // fe80::/10
  return v6[0] === 0xfe && (v6[1] & 0xc0) === 0x80;
}

function isPrivateIp(host: string): boolean {
  const h = host.toLowerCase();

  if (isIpv4Literal(h)) {
    if (inIpv4Cidr(h, '10.0.0.0', 8)) return true;
    if (inIpv4Cidr(h, '172.16.0.0', 12)) return true;
    if (inIpv4Cidr(h, '192.168.0.0', 16)) return true;
    if (inIpv4Cidr(h, '100.64.0.0', 10)) return true; // CGNAT
    return false;
  }

  const v6 = parseIpv6ToBytes(h);
  if (!v6) return false;

  // IPv4-mapped private ranges
  if (isIpv4MappedIpv6(v6)) {
    const v4 = ipv4FromMapped(v6);
    if (inIpv4Cidr(v4, '10.0.0.0', 8)) return true;
    if (inIpv4Cidr(v4, '172.16.0.0', 12)) return true;
    if (inIpv4Cidr(v4, '192.168.0.0', 16)) return true;
    if (inIpv4Cidr(v4, '100.64.0.0', 10)) return true;
    return false;
  }

  // Unspecified ::
  let allZero = true;
  for (let i = 0; i < 16; i++) {
    if (v6[i] !== 0) {
      allZero = false;
      break;
    }
  }
  if (allZero) return true;

  // Unique local fc00::/7
  return (v6[0] & 0xfe) === 0xfc;
}

/**
 * Parse and validate an outbound URL used for network calls.
 *
 * Goals:
 * - prevent accidental use of non-http(s) schemes
 * - prevent credential leakage via user:pass@host
 * - provide a best-effort SSRF denylist (cloud metadata + link-local)
 * - enable optional strict allowlisting
 */
export function parseAndValidateOutboundUrl(
  raw: string,
  ctx: string,
  policy?: OutboundUrlPolicy,
): URL {
  const p = {
    ...DEFAULT_OUTBOUND_URL_POLICY,
    ...(policy ?? {}),
  };

  const allowedHosts = uniqNormalizedHosts(p.allowedHosts);
  const deniedHosts = uniqNormalizedHosts([
    ...DEFAULT_OUTBOUND_URL_POLICY.deniedHosts,
    ...(p.deniedHosts ?? []),
  ]);

  if (typeof raw !== 'string' || !raw.trim()) {
    throw new Error(`${ctx}: expected non-empty URL string`);
  }

  if (/[^\S\r\n]*[\r\n]/.test(raw)) {
    throw new Error(`${ctx}: URL contains invalid newline characters`);
  }

  let u: URL;
  try {
    u = new URL(raw);
  } catch {
    throw new Error(`${ctx}: invalid URL`);
  }

  if (!p.allowedProtocols.includes(u.protocol)) {
    throw new Error(
      `${ctx}: unsupported URL protocol '${u.protocol}' (allowed: ${p.allowedProtocols.join(', ')})`,
    );
  }

  if (!p.allowCredentials && (u.username || u.password)) {
    throw new Error(`${ctx}: URL must not include credentials (user:pass@host)`);
  }

  const host = normalizeHostname(u.hostname);
  if (!host) {
    throw new Error(`${ctx}: URL is missing a hostname`);
  }

  // If this is an IPv4-mapped IPv6 literal, also compare the derived IPv4 host
  // against allow/deny lists. This prevents bypasses like [::ffff:a9fe:a9fe].
  let mappedV4: string | undefined;
  const v6 = parseIpv6ToBytes(host);
  if (v6 && isIpv4MappedIpv6(v6)) {
    mappedV4 = ipv4FromMapped(v6);
  }

  const allowOk =
    allowedHosts.length === 0 ||
    allowedHosts.includes(host) ||
    (mappedV4 ? allowedHosts.includes(mappedV4) : false);

  if (!allowOk) {
    throw new Error(`${ctx}: hostname '${safeErrorString(host)}' is not in the allowlist`);
  }

  const denyHit = deniedHosts.includes(host) || (mappedV4 ? deniedHosts.includes(mappedV4) : false);
  if (denyHit) {
    throw new Error(`${ctx}: hostname '${safeErrorString(host)}' is blocked by denylist`);
  }

  if (!p.allowLoopback && isLoopback(host)) {
    throw new Error(`${ctx}: loopback host '${safeErrorString(host)}' is not allowed`);
  }

  if (!p.allowLinkLocal && isLinkLocal(host)) {
    throw new Error(`${ctx}: link-local host '${safeErrorString(host)}' is not allowed`);
  }

  if (!p.allowPrivateIps && isPrivateIp(host)) {
    throw new Error(`${ctx}: private IP host '${safeErrorString(host)}' is not allowed`);
  }

  return u;
}

async function dnsLookupAll(host: string, timeoutMs: number): Promise<string[]> {
  let timer: any;
  // CRITICAL: if the timeout wins the race, `dns.promises.lookup` is still
  // pending. If the lookup later rejects (ENOTFOUND, resolver failure,
  // SERVFAIL), nothing is attached to its rejection and Node emits
  // `unhandledRejection`, which can destabilize long-running processes that
  // call this on a hot path (subgraph, achievements, keeper boot checks).
  // We attach a no-op .catch to the lookup promise explicitly so late
  // rejections are silenced regardless of which side of the race wins.
  const lookupPromise = dns.promises.lookup(host, { all: true, verbatim: true }) as any;
  (lookupPromise as Promise<unknown>).catch(() => {
    /* swallow late rejection; the caller already saw the timeout reject */
  });
  try {
    const rows = (await Promise.race([
      lookupPromise,
      new Promise((_, reject) => {
        timer = setTimeout(
          () => reject(new Error(`DNS lookup timed out after ${timeoutMs}ms`)),
          timeoutMs,
        );
      }),
    ])) as any[];

    return (rows ?? [])
      .map((r) => (r as any)?.address)
      .filter((a) => typeof a === 'string' && a.length > 0);
  } finally {
    if (timer) clearTimeout(timer);
  }
}

/**
 * Parse + validate an outbound URL, then (optionally) resolve hostnames to IPs and
 * apply IP-range restrictions to the resolved addresses.
 *
 * Why: without DNS checks, a hostname that resolves to loopback/private/link-local/denylisted
 * IPs can bypass literal-IP checks (SSRF via DNS).
 */
export async function parseAndValidateOutboundUrlWithDns(
  raw: string,
  ctx: string,
  policy?: OutboundUrlPolicy,
): Promise<URL> {
  const u = parseAndValidateOutboundUrl(raw, ctx, policy);

  // Effective policy for range checks.
  const p = {
    ...DEFAULT_OUTBOUND_URL_POLICY,
    ...(policy ?? {}),
  };

  // Default behavior: resolve hostnames unless explicitly disabled.
  const shouldResolve = policy?.resolveDns === false ? false : true;

  const host = normalizeHostname(u.hostname);

  // Skip DNS for IP literals and localhost (already handled by parseAndValidateOutboundUrl).
  const isIpLiteral = isIpv4Literal(host) || !!parseIpv6ToBytes(host);
  if (!shouldResolve || host === 'localhost' || isIpLiteral) return u;

  // Coerce the timeout to a positive finite integer (ms). Non-finite or
  // non-numeric inputs (strings, NaN, null) fall back to the 2000 ms default
  // so the deadline comparison against Date.now() always has a real value.
  const rawTimeout = policy?.dnsLookupTimeoutMs;
  const timeoutCandidate =
    typeof rawTimeout === 'number' && Number.isFinite(rawTimeout) && rawTimeout > 0
      ? Math.floor(rawTimeout)
      : 2000;
  const timeoutMs = Math.max(1, timeoutCandidate);

  const deniedHosts = uniqNormalizedHosts([
    ...DEFAULT_OUTBOUND_URL_POLICY.deniedHosts,
    ...(policy?.deniedHosts ?? []),
  ]);

  let resolved: string[];
  try {
    resolved = await dnsLookupAll(host, timeoutMs);
  } catch (err) {
    throw new Error(
      `${ctx}: DNS lookup failed for host '${safeErrorString(host)}': ${safeErrorString(err)}`,
    );
  }

  if (!resolved.length) {
    throw new Error(`${ctx}: DNS lookup returned no addresses for host '${safeErrorString(host)}'`);
  }

  for (const addr of resolved) {
    const ip = normalizeHostname(addr);
    if (!ip) continue;

    if (deniedHosts.includes(ip)) {
      throw new Error(
        `${ctx}: resolved IP '${ip}' for host '${safeErrorString(host)}' is blocked by denylist`,
      );
    }

    if (!p.allowLoopback && isLoopback(ip)) {
      throw new Error(
        `${ctx}: resolved IP '${ip}' for host '${safeErrorString(host)}' is loopback and not allowed`,
      );
    }

    if (!p.allowLinkLocal && isLinkLocal(ip)) {
      throw new Error(
        `${ctx}: resolved IP '${ip}' for host '${safeErrorString(host)}' is link-local and not allowed`,
      );
    }

    if (!p.allowPrivateIps && isPrivateIp(ip)) {
      throw new Error(
        `${ctx}: resolved IP '${ip}' for host '${safeErrorString(host)}' is private and not allowed`,
      );
    }
  }

  return u;
}

export function fetchRedirectMode(policy?: OutboundUrlPolicy): 'follow' | 'manual' | 'error' {
  const allow = policy?.allowRedirects ?? DEFAULT_OUTBOUND_URL_POLICY.allowRedirects;
  return allow ? 'follow' : 'error';
}
