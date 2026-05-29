/**
 * Shared .env file loader and scalar-parsing helpers for Node services.
 *
 * Consumers provide their own `searchDirs` so the loader is decoupled from
 * any particular project layout (keeper, event-watcher, etc.).
 */

import fs from 'node:fs';
import path from 'node:path';

const MAX_ENV_FILE_BYTES = 256 * 1024;

// ---------------------------------------------------------------------------
// Internal: .env value parser
// ---------------------------------------------------------------------------

/**
 * Parse a single env value string, supporting:
 *   - quoted values:   KEY="value" # inline comment
 *   - unquoted values: KEY=value   # inline comment
 *
 * @param {string | null | undefined} v
 * @returns {string | null | undefined}
 */
function parseEnvValue(v) {
  if (v == null) return v;
  const s = String(v).trim();
  if (!s) return s;

  const first = s[0];
  if (first === '"' || first === "'") {
    const quote = first;
    let escaped = false;
    for (let i = 1; i < s.length; i++) {
      const ch = s[i];
      if (escaped) {
        escaped = false;
        continue;
      }
      if (ch === '\\') {
        escaped = true;
        continue;
      }
      if (ch === quote) {
        return s.slice(1, i);
      }
    }

    // Unterminated quote: drop the leading quote and strip inline comment.
    return s
      .slice(1)
      .replace(/\s+#.*$/, '')
      .trim();
  }

  // Unquoted: strip inline comment.
  return s.replace(/\s+#.*$/, '').trim();
}

// ---------------------------------------------------------------------------
// resolveEnvFilePath
// ---------------------------------------------------------------------------

/**
 * Resolve an env file path against a list of candidate directories.
 *
 * @param {string} filePath  Relative or absolute path.
 * @param {string[]} searchDirs  Directories to search (in order).
 * @returns {string | null}  Resolved absolute path, or null if not found.
 */
function resolveEnvFilePath(filePath, searchDirs) {
  const raw = String(filePath);
  if (path.isAbsolute(raw)) return fs.existsSync(raw) ? raw : null;

  for (const dir of searchDirs) {
    const candidate = path.resolve(dir, raw);
    if (fs.existsSync(candidate)) return candidate;
  }

  return null;
}

function readEnvFileChecked(filePath) {
  const st = fs.statSync(filePath);
  if (!st.isFile()) {
    throw new Error(`Env file path is not a regular file: ${filePath}`);
  }
  if (st.size > MAX_ENV_FILE_BYTES) {
    throw new Error(`Env file too large: ${st.size} bytes (max ${MAX_ENV_FILE_BYTES})`);
  }
  return fs.readFileSync(filePath, 'utf8');
}

// ---------------------------------------------------------------------------
// loadEnvFile
// ---------------------------------------------------------------------------

/**
 * Load a `.env` file into `process.env` (does NOT override existing vars).
 *
 * @param {string | null | undefined} filePath  Path to the env file.
 * @param {{ searchDirs?: string[] }} [opts]
 *   - `searchDirs`: directories to search when `filePath` is relative.
 *     Defaults to `[process.cwd()]`.
 * @returns {{ loaded: boolean, count: number }}
 */
export function loadEnvFile(filePath, { searchDirs } = {}) {
  if (!filePath) return { loaded: false, count: 0 };

  const dirs = searchDirs && searchDirs.length ? searchDirs : [process.cwd()];
  const raw = String(filePath);
  const p = resolveEnvFilePath(raw, dirs);

  if (!p) {
    const tried = dirs.map((d) => path.resolve(d, raw)).join(', ');
    throw new Error(`Env file not found: ${raw} (tried ${tried})`);
  }

  const txt = readEnvFileChecked(p);
  const lines = txt.split(/\r?\n/);
  let count = 0;

  for (const rawLine of lines) {
    const line = rawLine.trim();
    if (!line || line.startsWith('#')) continue;
    const eq = line.indexOf('=');
    if (eq === -1) continue;

    const key = line.slice(0, eq).trim();
    if (!key) continue;

    const value = parseEnvValue(line.slice(eq + 1));

    // Do not override already-set env vars.
    if (process.env[key] == null) {
      // Coerce null/undefined to empty string: `process.env[k] = undefined`
      // stores the literal string "undefined", which is never what a .env
      // consumer wants.
      process.env[key] = value == null ? '' : String(value);
      count += 1;
    }
  }

  return { loaded: true, count };
}

// ---------------------------------------------------------------------------
// Scalar parsers
// ---------------------------------------------------------------------------

/**
 * Parse a value as a boolean, with a configurable default.
 *
 * @param {unknown} v
 * @param {{ defaultValue?: boolean }} [opts]
 * @returns {boolean}
 */
export function parseBool(v, { defaultValue = false } = {}) {
  if (v == null) return defaultValue;
  const s = String(v).trim().toLowerCase();
  if (['1', 'true', 'yes', 'y', 'on'].includes(s)) return true;
  if (['0', 'false', 'no', 'n', 'off'].includes(s)) return false;
  return defaultValue;
}

/**
 * Parse a value as a strict integer (base-10), with a configurable default.
 *
 * @param {unknown} v
 * @param {{ defaultValue?: number | null }} [opts]
 * @returns {number | null}
 */
export function parseIntStrict(v, { defaultValue = null } = {}) {
  if (v == null) return defaultValue;
  const s = String(v).trim();
  if (!s) return defaultValue;
  if (!/^[+-]?\d+$/.test(s)) return defaultValue;
  const n = Number.parseInt(s, 10);
  if (!Number.isFinite(n)) return defaultValue;
  return n;
}
