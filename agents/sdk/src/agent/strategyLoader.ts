import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath, pathToFileURL } from 'node:url';

import type { AgentStrategy } from './strategies.js';

export type StrategyModuleLoaderOptions = {
  /** Base directory for resolving relative module specs. Default: process.cwd() */
  baseDir?: string;

  /**
   * If true (default), disallow module paths that resolve outside baseDir.
   *
   * Defense-in-depth when module specs come from user input.
   */
  disallowOutsideBaseDir?: boolean;

  /** Allowed file extensions. Default: ['.mjs', '.js', '.cjs'] */
  allowedExtensions?: string[];

  /** Allow `file:` URL specs. Default: true */
  allowFileUrls?: boolean;
};

type StrategyModule = {
  default?: unknown;
  strategies?: unknown;
  strategy?: unknown;
};

function asStrategies(v: unknown, source: string): AgentStrategy[] {
  if (!v) return [];
  // object before casting. A malformed module could export [null, "string", 42]
  // which would pass through here and crash later during strategy execution
  // with confusing errors, or worse, if a strategy's propose() is a specially
  // crafted Proxy that intercepts calls to exfiltrate agent context.
  if (Array.isArray(v)) {
    for (let i = 0; i < v.length; i++) {
      if (!v[i] || typeof v[i] !== 'object') {
        throw new Error(`Strategy module ${source}: element [${i}] is not a valid object`);
      }
    }
    return v as AgentStrategy[];
  }
  if (typeof v !== 'object')
    throw new Error(`Strategy module ${source}: export is not a valid object`);
  return [v as AgentStrategy];
}

function validateStrategies(strategies: AgentStrategy[], source: string): void {
  for (const s of strategies) {
    if (!s || typeof (s as any).id !== 'string' || !(s as any).id) {
      throw new Error(`Invalid strategy from ${source}: missing id`);
    }
    if (typeof (s as any).propose !== 'function') {
      throw new Error(
        `Invalid strategy ${(s as any).id ?? '<unknown>'} from ${source}: missing propose(...)`,
      );
    }
  }
}

function normalizeExts(exts: string[]): string[] {
  const out: string[] = [];
  const seen = new Set<string>();
  for (const e of exts) {
    const s = String(e ?? '')
      .trim()
      .toLowerCase();
    if (!s) continue;
    const v = s.startsWith('.') ? s : `.${s}`;
    if (seen.has(v)) continue;
    seen.add(v);
    out.push(v);
  }
  return out;
}

function resolveStrategyModulePath(
  spec: string,
  opts: Required<StrategyModuleLoaderOptions>,
): string {
  const s = String(spec ?? '').trim();
  if (!s) throw new Error('Empty module spec');

  const baseDir = path.resolve(opts.baseDir);

  // Normalize to a local filesystem path.
  const abs = s.startsWith('file:')
    ? (() => {
        if (!opts.allowFileUrls) {
          throw new Error(`file: URL specs are disabled by policy: ${s}`);
        }
        return fileURLToPath(s);
      })()
    : path.isAbsolute(s)
      ? s
      : path.resolve(baseDir, s);

  // Resolve symlinks for reliable path containment checks.
  const realAbs = fs.realpathSync(abs);

  if (opts.disallowOutsideBaseDir) {
    const rel = path.relative(baseDir, realAbs);
    const outside = rel.startsWith('..') || path.isAbsolute(rel);
    if (outside) {
      throw new Error(
        `Refusing to load strategy module outside baseDir (${baseDir}): ${spec} -> ${realAbs}`,
      );
    }
  }

  const st = fs.statSync(realAbs);
  if (!st.isFile()) {
    throw new Error(`Strategy module path is not a file: ${realAbs}`);
  }

  const ext = path.extname(realAbs).toLowerCase();
  if (!opts.allowedExtensions.includes(ext)) {
    throw new Error(
      `Refusing to load strategy module with extension '${ext}' (allowed: ${opts.allowedExtensions.join(', ')}): ${realAbs}`,
    );
  }

  return realAbs;
}

/**
 * Load strategies from ESM modules.
 *
 * Supported exports:
 * - export const strategies: AgentStrategy[]
 * - export default AgentStrategy[]
 * - export const strategy: AgentStrategy
 * - export default AgentStrategy
 */
export async function loadStrategiesFromModules(
  modules: string[],
  options?: StrategyModuleLoaderOptions,
): Promise<AgentStrategy[]> {
  const opts: Required<StrategyModuleLoaderOptions> = {
    baseDir: options?.baseDir ?? process.cwd(),
    disallowOutsideBaseDir: options?.disallowOutsideBaseDir ?? true,
    allowedExtensions: normalizeExts(options?.allowedExtensions ?? ['.mjs', '.js', '.cjs']),
    allowFileUrls: options?.allowFileUrls ?? true,
  };

  const out: AgentStrategy[] = [];

  for (const spec of modules ?? []) {
    const s = String(spec ?? '').trim();
    if (!s) continue;

    const abs = resolveStrategyModulePath(s, opts);
    const url = pathToFileURL(abs).href;

    const mod = (await import(url)) as StrategyModule;

    const v = mod.strategies ?? mod.strategy ?? mod.default;
    const strategies = asStrategies(v, s);

    if (!strategies.length) {
      throw new Error(
        `Strategy module ${s} did not export strategies (expected: export const strategies, export default, or export const strategy)`,
      );
    }

    validateStrategies(strategies, s);
    // Avoid spreading potentially large arrays into push(...) to prevent argument-limit crashes.
    for (const st of strategies) {
      out.push(st);
    }
  }

  return out;
}
