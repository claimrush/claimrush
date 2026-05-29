import { existsSync } from 'node:fs';
import { dirname, join, resolve } from 'node:path';

export type RepoRootHints = {
  /** Defaults to process.cwd(). */
  startDir?: string;
  /** Max directory levels to walk up while searching for the repo root. Default: 10 */
  maxDepth?: number;
};

/**
 * Finds the ClaimRush repo root by walking up from a start directory.
 *
 * Resolution order:
 * 1. `hints.startDir` explicit override
 * 2. `CLAIMRUSH_REPO_ROOT` env var (useful when running from outside the monorepo)
 * 3. Walk up from `process.cwd()`
 */
export function findRepoRoot(hints: RepoRootHints = {}): string {
  const envRoot = process.env['CLAIMRUSH_REPO_ROOT'];
  if (!hints.startDir && envRoot) {
    const resolved = resolve(envRoot);
    if (existsSync(join(resolved, 'deployments')) && existsSync(join(resolved, 'abis'))) {
      return resolved;
    }
  }

  const startDir = hints.startDir ?? process.cwd();
  const maxDepth = hints.maxDepth ?? 10;

  let dir = resolve(startDir);
  for (let i = 0; i <= maxDepth; i++) {
    const hasDeployments = existsSync(join(dir, 'deployments'));
    const hasAbis = existsSync(join(dir, 'abis'));
    if (hasDeployments && hasAbis) return dir;

    const parent = dirname(dir);
    if (parent === dir) break;
    dir = parent;
  }

  throw new Error(
    `Could not locate ClaimRush repo root from startDir=${startDir}. ` +
      `Expected to find both 'deployments/' and 'abis/' in some parent directory.`,
  );
}
