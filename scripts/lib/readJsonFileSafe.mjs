import fs from 'node:fs';

const DEFAULT_MAX_JSON_FILE_BYTES = 25 * 1024 * 1024;

export function readJsonFileSafe(
  filePath,
  {
    label = 'JSON file',
    maxBytes = DEFAULT_MAX_JSON_FILE_BYTES,
  } = {},
) {
  const st = fs.statSync(filePath);
  if (!st.isFile()) {
    throw new Error(`${label} is not a regular file: ${filePath}`);
  }
  if (st.size > maxBytes) {
    throw new Error(`${label} too large: ${st.size} bytes (max ${maxBytes})`);
  }

  const raw = fs.readFileSync(filePath, 'utf8');
  try {
    return JSON.parse(raw);
  } catch (err) {
    const msg = err instanceof Error ? err.message : String(err);
    throw new Error(`Invalid ${label} JSON at ${filePath}: ${msg}`);
  }
}
