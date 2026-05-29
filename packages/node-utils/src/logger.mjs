// ---------------------------------------------------------------------------
// Structured JSON logger for Node.js services.
//
// Mirrors the worker-utils `makeLogger` interface so logs from Workers and
// Node services share the same schema and can be queried uniformly:
//
//   { "ts": "…", "level": "info", "msg": "…", "component": "keeper", … }
//
// The returned logger is also *callable* — `log("message")` is shorthand for
// `log.info("message")` — so existing call-sites that use a simple
// `(msg: string) => void` function continue to work unchanged.
// ---------------------------------------------------------------------------

/**
 * @typedef {'debug' | 'info' | 'warn' | 'error'} LogLevel
 */

/**
 * @typedef {Record<string, unknown>} LogFields
 */

/**
 * @typedef {((message: string, fields?: LogFields) => void) & {
 *   debug: (message: string, fields?: LogFields) => void;
 *   info:  (message: string, fields?: LogFields) => void;
 *   warn:  (message: string, fields?: LogFields) => void;
 *   error: (message: string, fields?: LogFields) => void;
 *   child: (extra: LogFields) => NodeLogger;
 * }} NodeLogger
 */

/**
 * @param {LogLevel} level
 * @param {string} message
 * @param {LogFields} fields
 */
function emit(level, message, fields) {
  const safeFields = sanitizeLogFields(fields);

  const payload = {
    ts: new Date().toISOString(),
    level,
    msg: sanitizeLogMessage(message),
    ...safeFields,
  };

  const line = JSON.stringify(payload);

  if (level === 'error') console.error(line);
  else if (level === 'warn') console.warn(line);
  else console.log(line);
}

/**
 * Create a structured JSON logger for Node.js services.
 *
 * Standard fields for observability consistency:
 *   - `component`  — service name (e.g. "event-watcher", "keeper")
 *   - `nodeId`     — instance / deployment identifier
 *   - `chainId`    — EVM chain ID
 *   - `requestId`  — correlation ID propagated across services
 *
 * @param {LogFields} [baseFields]
 * @returns {NodeLogger}
 */
export function makeNodeLogger(baseFields = {}) {
  const base = { ...baseFields };

  /** @type {NodeLogger} */
  const log = function log(message, fields = {}) {
    emit('info', message, { ...base, ...fields });
  };

  log.debug = (message, fields = {}) => emit('debug', message, { ...base, ...fields });
  log.info = (message, fields = {}) => emit('info', message, { ...base, ...fields });
  log.warn = (message, fields = {}) => emit('warn', message, { ...base, ...fields });
  log.error = (message, fields = {}) => emit('error', message, { ...base, ...fields });
  log.child = (extra) => makeNodeLogger({ ...base, ...extra });

  return log;
}

// ---------------------------------------------------------------------------
// Lightweight structured-log metric emitters (mirrors worker-utils).
// ---------------------------------------------------------------------------

/**
 * @param {string} name
 * @param {number} value
 * @param {'counter' | 'gauge' | 'timing'} [kind]
 * @param {LogFields} [labels]
 */
export function emitMetric(name, value, kind = 'counter', labels = {}) {
  emit('info', 'metric', {
    metric: name,
    value,
    kind,
    ...labels,
  });
}

/**
 * @param {string} name
 * @param {number} durationMs
 * @param {LogFields} [labels]
 */
export function emitTiming(name, durationMs, labels = {}) {
  emitMetric(name, durationMs, 'timing', labels);
}

// ---------------------------------------------------------------------------
// Error serialization + redaction (privacy backstop)
// ---------------------------------------------------------------------------

// NOTE: This intentionally mirrors the worker-utils `serializeError` redaction
// logic so Node services and Workers share the same safety guarantees.

// The negative lookaheads are critical: without them, EVM_ADDRESS_RE matches
// the first 40 hex chars of a 64-char tx hash, which silently mangles tx
// hashes in structured-field redaction (where TX_HASH_RE is intentionally
// not applied). Same reasoning for SHORT_ADDRESS_RE's trailing boundary.
const EVM_ADDRESS_RE = /0x[0-9a-fA-F]{40}(?![0-9a-fA-F])/g;
const TX_HASH_RE = /0x[0-9a-fA-F]{64}(?![0-9a-fA-F])/g;

// Allow shortened addresses like 0x1234…abcd or 0x1234...abcd
const SHORT_ADDRESS_RE = /0x[0-9a-fA-F]{4,6}[…\u2026.]{1,3}[0-9a-fA-F]{4}(?![0-9a-fA-F])/g;

// ENS + Basename (e.g. vitalik.eth, name.base.eth)
const ENS_NAME_RE = /\b[a-zA-Z0-9][-a-zA-Z0-9]*(?:\.[a-zA-Z0-9][-a-zA-Z0-9]*)*\.eth\b/gi;

// Email addresses (PII)
const EMAIL_RE = /\b[A-Z0-9._%+-]+@[A-Z0-9.-]+\.[A-Z]{2,}\b/gi;

// Common secret-bearing patterns in error strings.
const BEARER_TOKEN_RE = /\bBearer\s+[A-Za-z0-9._~+/=-]{8,}\b/gi;
const SECRET_KV_RE =
  /\b(authorization|x-api-key|api-key|api_key|access_token|token|secret|signature|sig)\s*[:=]\s*([A-Za-z0-9._~+/=-]{6,})/gi;
const URL_SECRET_PARAM_RE =
  /([?&](?:access_token|token|api_key|apikey|secret|signature|sig)=)[^&\s]+/gi;

// URL userinfo (e.g. https://[userinfo]@host, redis://[userinfo]@host)
const URL_USERINFO_RE = /\b([a-zA-Z][a-zA-Z0-9+.-]*:\/\/)([^@\s\/]{1,256})@/g;

// Provider-style API keys embedded in URL paths.
// Examples:
// - Infura:   https://mainnet.infura.io/v3/<projectId>
// - Alchemy:  https://eth-mainnet.g.alchemy.com/v2/<apiKey>
// - TheGraph: https://gateway.thegraph.com/api/<apiKey>/subgraphs/id/<id>
// - Moralis:  https://speedy-nodes-nyc.moralis.io/<apiKey>/eth/mainnet
const URL_PATH_TOKEN_V2_V3_RE = /(\/v[23]\/)[A-Za-z0-9._~+/=-]{6,}/g;
const URL_PATH_TOKEN_API_RE = /(\/api\/)[A-Za-z0-9._~+/=-]{6,}(?=\/|\?|#|$)/g;
const URL_PATH_TOKEN_MORALIS_RE =
  /(\bmoralis\.io\/)[A-Za-z0-9._~+/=-]{6,}(?=\/|\?|#|$)/gi;

// Provider keys sometimes appear as a hostname label (subdomain). Redact long, key-like labels.
// Keep this conservative to avoid mangling common hostnames.
const URL_HOST_LABEL_TOKEN_RE =
  /\b([a-zA-Z][a-zA-Z0-9+.-]*:\/\/)([A-Za-z0-9._~+/=-]{14,})\.([a-zA-Z0-9.-]{2,})\b/g;

// Catch-all for very long hex blobs (e.g. SIWE signatures, calldata) that should not be logged.
const LONG_HEX_BLOB_RE = /0x[0-9a-fA-F]{100,}/g;

function truncateForLog(text, maxChars) {
  if (typeof text !== 'string') return '';
  if (text.length <= maxChars) return text;
  return text.slice(0, maxChars) + '...';
}
function redactSensitiveTextForFields(input) {
  const s = String(input ?? '');
  // Keep redaction simple and cheap; apply most specific patterns first.
  return s
    .replace(BEARER_TOKEN_RE, 'Bearer [redacted]')
    .replace(SECRET_KV_RE, (_m, key) => `${key}=[redacted]`)
    .replace(URL_USERINFO_RE, '$1[redacted]@')
    .replace(URL_PATH_TOKEN_API_RE, '$1[redacted]')
    .replace(URL_PATH_TOKEN_V2_V3_RE, '$1[redacted]')
    .replace(URL_PATH_TOKEN_MORALIS_RE, '$1[redacted]')
    .replace(URL_HOST_LABEL_TOKEN_RE, '$1[redacted].$3')
    .replace(URL_SECRET_PARAM_RE, '$1[redacted]')
    // Preserve tx hashes in structured fields; still redact addresses + secrets.
    .replace(EVM_ADDRESS_RE, '0x[addr]')
    .replace(SHORT_ADDRESS_RE, '0x[addr]')
    .replace(ENS_NAME_RE, '[ens]')
    .replace(EMAIL_RE, '[email]')
    .replace(LONG_HEX_BLOB_RE, '0x[hex]');
}

function isSensitiveFieldKey(key) {
  const k = String(key ?? '').trim().toLowerCase();
  if (!k) return false;

  if (k === 'authorization' || k === 'cookie' || k === 'set-cookie') return true;

  if (k.includes('password') || k.includes('passphrase')) return true;
  if (k.includes('private_key') || k.includes('privatekey')) return true;
  if (k.includes('mnemonic') || k.includes('seed_phrase') || k === 'seed') return true;
  if (k.includes('api_key') || k === 'apikey' || k === 'x-api-key' || k === 'api-key') return true;

  if (k.includes('turnstile') || k.includes('vapid')) return true;

  if (k.includes('client_secret') || k.includes('secret_key') || k.endsWith('secret') || k.includes('secret')) {
    return true;
  }

  if (k === 'signature' || k === 'sig' || k.endsWith('_sig')) return true;

  if (k.includes('token') && !k.includes('tokenid') && !k.includes('token_id')) {
    if (
      k === 'token' ||
      k.endsWith('_token') ||
      k.endsWith('token') ||
      k.includes('access_token') ||
      k.includes('refresh_token') ||
      k.includes('id_token')
    ) {
      return true;
    }
  }

  return false;
}

function sanitizeLogString(value) {
  const MAX_FIELD_CHARS = 1024;
  return truncateForLog(redactSensitiveTextForFields(value), MAX_FIELD_CHARS);
}

function sanitizeLogValue(value, depth, seen) {
  const MAX_DEPTH = 5;
  const MAX_ARRAY_LENGTH = 50;
  const MAX_KEYS = 80;

  if (value == null) return value;

  const t = typeof value;
  if (t === 'string') return sanitizeLogString(value);
  if (t === 'number' || t === 'boolean') return value;
  if (t === 'bigint') return value.toString();

  if (value instanceof Error) return serializeError(value);

  if (Array.isArray(value)) {
    const out = value.slice(0, MAX_ARRAY_LENGTH).map((v) => sanitizeLogValue(v, depth + 1, seen));
    if (value.length > MAX_ARRAY_LENGTH) out.push(`[+${value.length - MAX_ARRAY_LENGTH} more]`);
    return out;
  }

  if (t === 'object') {
    if (seen.has(value)) return '[circular]';
    seen.add(value);

    if (depth >= MAX_DEPTH) return '[object]';

    const entries = Object.entries(value);
    const out = {};
    for (const [k0, v] of entries.slice(0, MAX_KEYS)) {
      const k = String(k0).slice(0, 128);
      if (isSensitiveFieldKey(k)) {
        out[k] = '[redacted]';
        continue;
      }
      out[k] = sanitizeLogValue(v, depth + 1, seen);
    }
    if (entries.length > MAX_KEYS) out.__cr_truncated_keys = entries.length - MAX_KEYS;
    return out;
  }

  return sanitizeLogString(String(value));
}

function sanitizeLogFields(fields) {
  const seen = new WeakSet();
  const out = sanitizeLogValue(fields, 0, seen);
  if (out && typeof out === 'object' && !Array.isArray(out)) return out;
  return {};
}

function sanitizeLogMessage(message) {
  const MAX_MESSAGE_CHARS = 256;
  // Treat the message like a structured field: scrub secrets/PII but preserve tx hashes.
  return truncateForLog(redactSensitiveTextForFields(String(message ?? '')), MAX_MESSAGE_CHARS);
}


function redactSensitiveText(input) {
  const s = String(input ?? '');
  // Keep redaction simple and cheap; apply most specific patterns first.
  return s
    .replace(BEARER_TOKEN_RE, 'Bearer [redacted]')
    .replace(SECRET_KV_RE, (_m, key) => `${key}=[redacted]`)
    .replace(URL_USERINFO_RE, '$1[redacted]@')
    .replace(URL_PATH_TOKEN_API_RE, '$1[redacted]')
    .replace(URL_PATH_TOKEN_V2_V3_RE, '$1[redacted]')
    .replace(URL_PATH_TOKEN_MORALIS_RE, '$1[redacted]')
    .replace(URL_HOST_LABEL_TOKEN_RE, '$1[redacted].$3')
    .replace(URL_SECRET_PARAM_RE, '$1[redacted]')
    .replace(TX_HASH_RE, '0x[tx]')
    .replace(EVM_ADDRESS_RE, '0x[addr]')
    .replace(SHORT_ADDRESS_RE, '0x[addr]')
    .replace(ENS_NAME_RE, '[ens]')
    .replace(EMAIL_RE, '[email]')
    .replace(LONG_HEX_BLOB_RE, '0x[hex]');
}

/**
 * Serialize an unknown error into safe, redacted, bounded fields.
 *
 * Intended usage:
 *   log.error('something_failed', { error: serializeError(err) })
 */
export function serializeError(err) {
  const MAX_MESSAGE_CHARS = 512;
  const MAX_STACK_LINES = 12;
  const MAX_STACK_CHARS = 4096;

  if (err instanceof Error) {
    const name = typeof err.name === 'string' ? err.name.slice(0, 64) : undefined;

    const rawMsg = typeof err.message === 'string' ? err.message : '';
    const message = truncateForLog(redactSensitiveText(rawMsg || 'Error'), MAX_MESSAGE_CHARS);

    const rawStack = err.stack ? String(err.stack) : '';
    const stack = rawStack
      ? truncateForLog(
          rawStack
            .split('\n')
            .slice(0, MAX_STACK_LINES)
            .map((line) => redactSensitiveText(line))
            .join('\n'),
          MAX_STACK_CHARS,
        )
      : undefined;

    return {
      ...(name ? { name } : {}),
      message,
      ...(stack ? { stack } : {}),
    };
  }

  const msg = truncateForLog(redactSensitiveText(String(err ?? 'UNKNOWN_ERROR')), MAX_MESSAGE_CHARS);
  return { message: msg };
}