const STRICT_CHAIN_ID_DECIMAL_RE = /^[1-9]\d*$/;
const STRICT_CHAIN_ID_HEX_RE = /^0x[0-9a-f]+$/i;

function toSafePositiveNumber(value: bigint): number | null {
  if (value <= 0n) return null;
  if (value > BigInt(Number.MAX_SAFE_INTEGER)) return null;
  return Number(value);
}

export function parseChainIdStrict(raw: unknown): number | null {
  if (typeof raw === 'number') {
    return Number.isSafeInteger(raw) && raw > 0 ? raw : null;
  }

  if (typeof raw === 'bigint') {
    return toSafePositiveNumber(raw);
  }

  const s = String(raw ?? '').trim();
  if (!s) return null;

  try {
    if (STRICT_CHAIN_ID_HEX_RE.test(s)) {
      return toSafePositiveNumber(BigInt(s));
    }

    if (!STRICT_CHAIN_ID_DECIMAL_RE.test(s)) return null;
    return toSafePositiveNumber(BigInt(s));
  } catch {
    return null;
  }
}
