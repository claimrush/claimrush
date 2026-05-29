// ---------------------------------------------------------------------------
// Thin wrapper around @claimrush/node-utils/env that provides service-specific
// search directories for .env file resolution.
//
// All env-parsing logic (parseBool, parseIntStrict, parseEnvValue, …) lives in
// the shared package — this file only re-exports and customises loadEnvFile.
// ---------------------------------------------------------------------------

import path from 'node:path';
import { fileURLToPath } from 'node:url';
import { loadEnvFile as _loadEnvFile, parseBool, parseIntStrict } from '@claimrush/node-utils/env';

export { parseBool, parseIntStrict };

function getSearchDirs(): string[] {
  // keeper/src/shared/env.ts → keeper/
  const keeperRoot = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..', '..');
  // keeper/ → repo root
  const repoRoot = path.resolve(keeperRoot, '..');
  return [process.cwd(), keeperRoot, repoRoot];
}

export function loadEnvFile(filePath: string | null | undefined): {
  loaded: boolean;
  count: number;
} {
  return _loadEnvFile(filePath, { searchDirs: getSearchDirs() });
}
