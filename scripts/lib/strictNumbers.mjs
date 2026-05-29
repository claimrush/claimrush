function parseDecimalDigits(raw) {
  if (!/^\d+$/.test(raw)) return null;
  const parsed = Number(raw);
  return Number.isSafeInteger(parsed) ? parsed : null;
}

function parseHexDigits(raw) {
  if (!/^0x[0-9a-f]+$/i.test(raw)) return null;
  try {
    const parsed = BigInt(raw);
    if (parsed < BigInt(Number.MIN_SAFE_INTEGER) || parsed > BigInt(Number.MAX_SAFE_INTEGER)) {
      return null;
    }
    return Number(parsed);
  } catch {
    return null;
  }
}

export function parseStrictSafeInteger(
  value,
  { defaultValue = null, min = Number.MIN_SAFE_INTEGER, max = Number.MAX_SAFE_INTEGER, allowHex = false } = {},
) {
  let parsed = null;

  if (typeof value === "number") {
    parsed = Number.isSafeInteger(value) ? value : null;
  } else if (typeof value === "bigint") {
    if (value >= BigInt(Number.MIN_SAFE_INTEGER) && value <= BigInt(Number.MAX_SAFE_INTEGER)) {
      parsed = Number(value);
    }
  } else if (typeof value === "string") {
    const raw = value.trim();
    if (raw) {
      parsed = parseDecimalDigits(raw);
      if (parsed == null && allowHex) parsed = parseHexDigits(raw);
    }
  }

  if (parsed == null) return defaultValue;
  if (parsed < min || parsed > max) return defaultValue;
  return parsed;
}

export function parseStrictNonNegativeSafeInteger(value, options = {}) {
  return parseStrictSafeInteger(value, { min: 0, ...options });
}

export function parseStrictPositiveSafeInteger(value, options = {}) {
  return parseStrictSafeInteger(value, { min: 1, ...options });
}
