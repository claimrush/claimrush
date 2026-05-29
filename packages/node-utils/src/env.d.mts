/**
 * Load a `.env` file into `process.env` (does NOT override existing vars).
 *
 * @param filePath  Path to the env file.
 * @param opts
 *   - `searchDirs`: directories to search when `filePath` is relative.
 *     Defaults to `[process.cwd()]`.
 */
export function loadEnvFile(
  filePath: string | null | undefined,
  opts?: { searchDirs?: string[] },
): { loaded: boolean; count: number };

/**
 * Parse a value as a boolean, with a configurable default.
 */
export function parseBool(v: unknown, opts?: { defaultValue?: boolean }): boolean;

/**
 * Parse a value as a strict integer (base-10), with a configurable default.
 */
export function parseIntStrict(v: unknown, opts?: { defaultValue?: number | null }): number | null;
