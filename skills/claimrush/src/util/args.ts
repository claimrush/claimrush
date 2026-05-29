/**
 * Shared CLI flag parser. Supports the same shape as the SDK examples:
 *   --key value      or   --key=value      or   --flag (boolean)
 *
 * The parser is intentionally minimal (no third-party CLI library) so the
 * skill stays a single small build artifact.
 */

export type FlagBag = {
  argv: string[];
  has: (flag: string) => boolean;
  get: (key: string) => string | undefined;
  getAll: (key: string) => string[];
};

export function makeFlagBag(argv: string[]): FlagBag {
  const has = (flag: string): boolean => argv.includes(`--${flag}`);

  const get = (key: string): string | undefined => {
    const pref = `--${key}=`;
    const hit = argv.find((a) => a.startsWith(pref));
    if (hit) return hit.slice(pref.length);
    const idx = argv.findIndex((a) => a === `--${key}`);
    if (idx >= 0) return argv[idx + 1];
    return undefined;
  };

  const getAll = (key: string): string[] => {
    const out: string[] = [];
    const pref = `--${key}=`;
    for (let i = 0; i < argv.length; i++) {
      const arg = argv[i];
      if (!arg) continue;
      if (arg.startsWith(pref)) out.push(arg.slice(pref.length));
      else if (arg === `--${key}` && argv[i + 1] !== undefined) out.push(argv[i + 1] as string);
    }
    return out;
  };

  return { argv, has, get, getAll };
}

export function helpRequested(argv: string[]): boolean {
  return argv.includes('--help') || argv.includes('-h');
}
