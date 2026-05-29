const STRICT_INTEGER_RE = /^[+-]?\d+$/;
const MAX_SAFE_INTEGER_BIGINT = BigInt(Number.MAX_SAFE_INTEGER);
const MIN_SAFE_INTEGER_BIGINT = BigInt(Number.MIN_SAFE_INTEGER);

export function parseStrictSafeInteger(value: unknown): number | undefined {
  if (typeof value === 'number') {
    return Number.isSafeInteger(value) ? value : undefined;
  }

  if (typeof value === 'bigint') {
    if (value > MAX_SAFE_INTEGER_BIGINT || value < MIN_SAFE_INTEGER_BIGINT) return undefined;
    return Number(value);
  }

  if (typeof value !== 'string') return undefined;

  const s = value.trim();
  if (!s || !STRICT_INTEGER_RE.test(s)) return undefined;

  const n = Number(s);
  return Number.isSafeInteger(n) ? n : undefined;
}

export function parseStrictNonNegativeSafeInteger(value: unknown): number | undefined {
  const n = parseStrictSafeInteger(value);
  if (n === undefined || n < 0) return undefined;
  return n;
}

export function parseStrictPositiveSafeInteger(value: unknown): number | undefined {
  const n = parseStrictSafeInteger(value);
  if (n === undefined || n <= 0) return undefined;
  return n;
}

export function clampStrictSafeInteger(
  value: unknown,
  fallback: number,
  min: number,
  max: number,
): number {
  const n = parseStrictSafeInteger(value);
  if (n === undefined) return fallback;
  if (n < min) return min;
  if (n > max) return max;
  return n;
}
