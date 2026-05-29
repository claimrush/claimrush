import type { PublicClient } from 'viem';

import { parseNonNegativeSafeInteger, parsePositiveSafeInteger } from './utils.js';

function fmtErr(e: unknown): string {
  const errObj = e as { shortMessage?: string; message?: string };
  return String(errObj?.shortMessage ?? errObj?.message ?? e);
}

// Viem's HttpRequestError stashes the upstream response body / detail text in
// fields other than `message`/`shortMessage` (most commonly `details`,
// sometimes `cause.details` or a nested `cause.message`).  For heuristic
// classification we want to see ALL of those at once so we can match on
// strings like `upstream_http_400` that live in the upstream body.
function allErrorText(e: unknown, depth = 0): string {
  if (e == null || depth > 4) return '';
  if (typeof e !== 'object') return String(e);

  const eo = e as Record<string, unknown>;
  const parts: string[] = [];
  const push = (v: unknown): void => {
    if (typeof v === 'string' && v) parts.push(v);
  };

  push(eo.shortMessage);
  push(eo.message);
  push(eo.details);
  push(eo.responseBody);
  push(eo.body);
  push(eo.reason);
  if (eo.cause) parts.push(allErrorText(eo.cause, depth + 1));

  return parts.join(' | ');
}

function isRateLimitMessage(msg: string): boolean {
  const m = msg.toLowerCase();
  return (
    m.includes('rate limit') ||
    m.includes('too many requests') ||
    m.includes('http 429') ||
    m.includes('status code 429')
  );
}

function sleep(ms: number): Promise<void> {
  return new Promise((resolve) => setTimeout(resolve, ms));
}

export function parseRpcLogIndex(value: unknown): bigint | null {
  if (typeof value === 'bigint') return value >= 0n ? value : null;
  if (typeof value === 'number') {
    return Number.isSafeInteger(value) && value >= 0 ? BigInt(value) : null;
  }

  const s = String(value ?? '').trim();
  if (!s) return null;
  if (!/^(?:0|[1-9]\d*|0x[0-9a-fA-F]+)$/.test(s)) return null;

  try {
    const parsed = BigInt(s);
    return parsed >= 0n ? parsed : null;
  } catch {
    return null;
  }
}

export function jitterMs(ms: number, jitterBps: unknown): number {
  const base = parsePositiveSafeInteger(ms, { defaultValue: 0 }) ?? 0;
  if (!base) return 0;
  const bps = Math.min(10_000, parseNonNegativeSafeInteger(jitterBps, { defaultValue: 0 }) ?? 0);
  if (bps === 0) return base;
  const r = (Math.random() * 2 - 1) * (bps / 10_000);
  const out = Math.round(base * (1 + r));
  return Math.max(0, out);
}

export function computeBackoffMs({
  attempt,
  baseMs,
  maxMs,
}: {
  attempt: unknown;
  baseMs: unknown;
  maxMs: unknown;
}): number {
  const a = parseNonNegativeSafeInteger(attempt, { defaultValue: 0 }) ?? 0;
  const base = parsePositiveSafeInteger(baseMs, { defaultValue: 1 }) ?? 1;
  const max = Math.max(base, parsePositiveSafeInteger(maxMs, { defaultValue: base }) ?? base);
  // Exponential backoff: base * 2^attempt, capped.
  const raw = base * Math.pow(2, a);
  return Math.min(max, Math.trunc(raw));
}

function extractJsonRpcErrorCode(e: unknown): number | null {
  if (!e || typeof e !== 'object') return null;
  const code = (e as any)?.code ?? (e as any)?.cause?.code ?? (e as any)?.data?.code;
  if (typeof code === 'number' && Number.isInteger(code)) return code;
  return null;
}

function shouldSplitGetLogsErrorMessage(msg: string): boolean {
  const m = msg.toLowerCase();

  // Avoid amplifying provider throttling.
  if (isRateLimitMessage(m)) return false;

  // Common provider errors when eth_getLogs is too large (range or result count).
  if (
    m.includes('query returned more than') ||
    m.includes('more than 10000') ||
    m.includes('too many results') ||
    m.includes('too many logs') ||
    m.includes('log response size exceeded') ||
    m.includes('response size exceeded') ||
    m.includes('payload too large') ||
    m.includes('request too large') ||
    (m.includes('block range') &&
      (m.includes('too large') || m.includes('too wide') || m.includes('exceed'))) ||
    m.includes('exceeds max block range') ||
    (m.includes('eth_getlogs') &&
      (m.includes('limit') || m.includes('exceed') || m.includes('too large')))
  ) {
    return true;
  }

  // claimrush-rpc-proxy wrapper: upstream 4xx errors from Alchemy (including
  // the free-tier `eth_getLogs` 10-block limit) come back as
  // `{"ok":false,"error":"upstream_http_400"}` with an outer HTTP 502.  The
  // body is surfaced in viem's `details` field, so we match the literal
  // token here.  413 is the payload-too-large sibling.  Only 400/413 are
  // treated as splittable: 401/403/404/429/5xx are auth/quota/infra issues
  // that bisecting will not help with.
  if (m.includes('upstream_http_400') || m.includes('upstream_http_413')) return true;

  // Alchemy also returns a raw 400 with `Log response size exceeded. You
  // can make eth_getLogs requests with up to a <N> block range ...` in
  // cases the proxy did NOT intercept.  The free-tier message specifically
  // says "up to a 10 block range".  Match both shapes.
  if (m.includes('up to a') && m.includes('block range')) return true;

  return false;
}

// Also match on JSON-RPC error codes which are more stable across providers
// than error message text. -32005 = server limit exceeded, -32602 = invalid
// params (used by some providers for range-too-large).
function shouldSplitGetLogsError(e: unknown): boolean {
  const code = extractJsonRpcErrorCode(e);
  if (code === -32005 || code === -32602) {
    const msg = allErrorText(e).toLowerCase();
    if (isRateLimitMessage(msg)) return false;
    return true;
  }
  return shouldSplitGetLogsErrorMessage(allErrorText(e));
}

/**
 * Robust wrapper for `publicClient.getLogs`.
 *
 * Some RPC providers enforce strict limits on eth_getLogs (block-range and/or
 * max log count). When those limits are hit, the keeper previously failed the
 * entire scan and would retry forever from the same block.
 *
 * This helper automatically bisects the requested block-range until it fits
 * within provider limits (or until we hit the min range / split budget).
 */
export async function getLogsWithAutoSplit<T = any>({
  publicClient,
  request,
  log,
  maxSplits = 256,
  rateLimitRetries = 5,
  rateLimitBackoffMs = 500,
  rateLimitMaxBackoffMs = 30_000,
  rateLimitJitterBps = 500,
}: {
  publicClient: PublicClient;
  request: Record<string, unknown>;
  log?: ((msg: string) => void) | null;
  /** Hard cap to avoid pathological split storms. */
  maxSplits?: number;

  /** Retries when the RPC provider returns a throttling / 429 response. */
  rateLimitRetries?: number;
  /** Initial backoff delay for rate-limits (ms). */
  rateLimitBackoffMs?: number;
  /** Max backoff delay for rate-limits (ms). */
  rateLimitMaxBackoffMs?: number;
  /** Jitter applied to backoff delays (bps). */
  rateLimitJitterBps?: number;
}): Promise<T[]> {
  if (!request) return [];

  const rawFrom = (request as any).fromBlock;
  const rawTo = (request as any).toBlock;

  // If the request isn't block-bounded, just pass through.
  if (rawFrom == null || rawTo == null) {
    return (await publicClient.getLogs(request as any)) as any;
  }

  let from0: bigint;
  let to0: bigint;
  try {
    from0 = typeof rawFrom === 'bigint' ? rawFrom : BigInt(rawFrom as any);
    to0 = typeof rawTo === 'bigint' ? rawTo : BigInt(rawTo as any);
  } catch {
    return (await publicClient.getLogs(request as any)) as any;
  }

  const baseReq: Record<string, unknown> = { ...request };
  delete (baseReq as any).fromBlock;
  delete (baseReq as any).toBlock;

  const out: T[] = [];
  const stack: Array<{ from: bigint; to: bigint }> = [{ from: from0, to: to0 }];

  const rlRetries = parseNonNegativeSafeInteger(rateLimitRetries, { defaultValue: 0 }) ?? 0;
  const rlBaseMs = parsePositiveSafeInteger(rateLimitBackoffMs, { defaultValue: 1 }) ?? 1;
  const rlMaxMs = Math.max(
    rlBaseMs,
    parsePositiveSafeInteger(rateLimitMaxBackoffMs, { defaultValue: rlBaseMs }) ?? rlBaseMs,
  );
  const rlJitter = Math.min(
    10_000,
    parseNonNegativeSafeInteger(rateLimitJitterBps, { defaultValue: 0 }) ?? 0,
  );

  let splits = 0;
  let logged = 0;
  let rateLogged = 0;

  const getLogsRange = async (from: bigint, to: bigint): Promise<any[]> => {
    let attempt = 0;
    while (true) {
      try {
        return (await publicClient.getLogs({
          ...(baseReq as any),
          fromBlock: from,
          toBlock: to,
        })) as any[];
      } catch (e: unknown) {
        const msg = allErrorText(e) || fmtErr(e);
        if (isRateLimitMessage(msg) && attempt < rlRetries) {
          const backoff = computeBackoffMs({ attempt, baseMs: rlBaseMs, maxMs: rlMaxMs });
          const delay = jitterMs(backoff, rlJitter);

          if (log && rateLogged < 3) {
            log(
              `rpc getLogs rate-limited; backing off ${delay}ms then retrying (${attempt + 1}/${rlRetries}) ${from.toString()}..${to.toString()} (${msg.slice(0, 140)})`,
            );
            rateLogged += 1;
          }

          attempt += 1;
          await sleep(delay);
          continue;
        }
        throw e;
      }
    }
  };

  while (stack.length) {
    const { from, to } = stack.pop()!;

    try {
      const logs = await getLogsRange(from, to);

      if (Array.isArray(logs) && logs.length) out.push(...(logs as any));
      continue;
    } catch (e: unknown) {
      const msg = allErrorText(e) || fmtErr(e);

      if (from < to && shouldSplitGetLogsError(e)) {
        splits += 1;
        if (splits > maxSplits) {
          throw new Error(
            `getLogs split budget exceeded (maxSplits=${maxSplits}) for range ${from.toString()}..${to.toString()}: ${msg}`,
            { cause: e },
          );
        }

        const mid = from + (to - from) / 2n;

        if (mid === from || mid === to) {
          throw new Error(`getLogs failed on single-block range ${from.toString()}: ${msg}`, {
            cause: e,
          });
        }

        if (log && logged < 3) {
          log(
            `rpc getLogs too large; splitting ${from.toString()}..${to.toString()} -> ${from.toString()}..${mid.toString()} + ${(mid + 1n).toString()}..${to.toString()} (${msg.slice(0, 140)})`,
          );
          logged += 1;
        }

        // Process lower range first to preserve chronological ordering.
        stack.push({ from: mid + 1n, to });
        stack.push({ from, to: mid });
        continue;
      }

      throw e;
    }
  }

  if (splits > 0 && out.length > 1) {
    out.sort((a: any, b: any) => {
      const aBn = BigInt(a?.blockNumber ?? 0n);
      const bBn = BigInt(b?.blockNumber ?? 0n);
      if (aBn !== bBn) return aBn < bBn ? -1 : 1;
      const aLi = parseRpcLogIndex(a?.logIndex) ?? 0n;
      const bLi = parseRpcLogIndex(b?.logIndex) ?? 0n;
      if (aLi === bLi) return 0;
      return aLi < bLi ? -1 : 1;
    });
  }

  // Deduplicate logs after split recombination. Some RPC providers return
  // overlapping results at split boundaries, and the SCAN_OVERLAP_BLOCKS
  // tolerance used by callers intentionally rescans recent blocks. Without
  // dedup, duplicate logs cause double-counting of events (e.g., a user
  // appearing twice in the opted-in list, or an offer processed twice).
  if (out.length > 1) {
    const seen = new Set<string>();
    let write = 0;
    for (let read = 0; read < out.length; read++) {
      const l = out[read] as any;
      const key = `${String(l?.blockNumber ?? '')}:${String(l?.logIndex ?? '')}:${String(l?.transactionHash ?? '')}`;
      if (seen.has(key)) continue;
      seen.add(key);
      out[write++] = out[read];
    }
    out.length = write;
  }

  return out;
}
