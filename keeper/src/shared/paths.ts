import path from 'node:path';
import { fileURLToPath } from 'node:url';

export function getKeeperRoot(): string {
  const __filename = fileURLToPath(import.meta.url);
  const __dirname = path.dirname(__filename);
  // keeper/src/shared -> keeper
  return path.resolve(__dirname, '../..');
}

export function getRepoRoot(): string {
  const keeperRoot = getKeeperRoot();
  return path.resolve(keeperRoot, '..');
}

export function resolveFromKeeper(p: string | null | undefined): string | null | undefined {
  if (!p) return p;
  if (path.isAbsolute(p)) return p;
  return path.resolve(getKeeperRoot(), p);
}

export function resolveFromRepo(p: string | null | undefined): string | null | undefined {
  if (!p) return p;
  if (path.isAbsolute(p)) return p;
  return path.resolve(getRepoRoot(), p);
}
