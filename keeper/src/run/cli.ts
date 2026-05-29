export interface CliOptions {
  envPath: string | null;
  once: boolean;
  tasksRaw: string | null;
  rest: string[];
  command: string;
  args: string[];
}

const ALLOWED_DAEMON_TASKS = new Set([
  'poke',
  'harvest-staking',
  'sweep-market',
  'sweep-listings',
  'expire-offers',
  'compound-shareholders',
  'compound-lp',
  'checkpoint-before-expiry',
  'automax-bonus',
]);

const TASK_ALIASES: Record<string, string> = {
  harveststaking: 'harvest-staking',
  harvest_staking: 'harvest-staking',
  sweepmarket: 'sweep-market',
  sweep_market: 'sweep-market',
  market: 'sweep-market',

  sweeplistings: 'sweep-listings',
  sweep_listings: 'sweep-listings',
  listings: 'sweep-listings',

  expireoffers: 'expire-offers',
  expire_offers: 'expire-offers',
  expire: 'expire-offers',

  compoundshareholders: 'compound-shareholders',
  compound_shareholders: 'compound-shareholders',
  compoundbarons: 'compound-shareholders',
  compound_barons: 'compound-shareholders',
  barons: 'compound-shareholders',

  compoundlp: 'compound-lp',
  compound_lp: 'compound-lp',
  lp: 'compound-lp',

  checkpointbeforeexpiry: 'checkpoint-before-expiry',
  checkpoint_before_expiry: 'checkpoint-before-expiry',
  'checkpoint-expiry': 'checkpoint-before-expiry',

  automaxbonus: 'automax-bonus',
  automax_bonus: 'automax-bonus',
  automax: 'automax-bonus',
};

export function usage(): void {
  console.log(`\
ClaimRush keeper

Commands:
  status
  poke
  daemon [--once] [--tasks <list>]
  harvest-staking
  sweep-market
  sweep-listings
  expire-offers
  compound-shareholders
  compound-lp
  checkpoint-before-expiry
  automax-bonus

Options:
  --env <path>    Load environment variables from a file (does not override existing env)
  --once          For daemon: run each configured task once and exit
  --tasks <list>  For daemon: comma-separated task list (poke, harvest-staking, sweep-market, sweep-listings, expire-offers, compound-shareholders, compound-lp, checkpoint-before-expiry, automax-bonus, all)

Env vars (see .env.example for a template):
  KEEPER_DEPLOYMENT
  KEEPER_PUBLIC_RPC_URL / KEEPER_PRIVATE_RPC_URL
  KEEPER_PRIVATE_KEY
  KEEPER_DRY_RUN=1
`);
}

export function parseCli(argv: string[]): CliOptions {
  const out: CliOptions = {
    envPath: null,
    once: false,
    tasksRaw: null,
    rest: [],
    command: 'help',
    args: [],
  };

  for (let i = 0; i < argv.length; i += 1) {
    const a = argv[i];
    if (a === '--env') {
      const rawEnv = argv[i + 1];
      if (typeof rawEnv === 'string' && rawEnv.includes('\0')) {
        throw new Error('Invalid --env path: null byte in path');
      }
      out.envPath = rawEnv;
      i += 1;
      continue;
    }
    if (a === '--once') {
      out.once = true;
      continue;
    }
    if (a === '--tasks') {
      out.tasksRaw = argv[i + 1];
      i += 1;
      continue;
    }
    out.rest.push(a);
  }

  out.command = out.rest[0] ?? 'help';
  out.args = out.rest.slice(1);
  return out;
}

export function parseTasksList(raw: string | null): string[] | null {
  if (raw == null) return null;
  const s = String(raw ?? '').trim();
  if (!s) return null;

  const parts = s
    .split(/[\s,]+/)
    .map((x) => x.trim())
    .filter(Boolean);

  const out: string[] = [];
  for (const p0 of parts) {
    const p = p0.toLowerCase();
    if (p === 'all' || p === '*') {
      return [
        'poke',
        'harvest-staking',
        'sweep-market',
        'sweep-listings',
        'expire-offers',
        'checkpoint-before-expiry',
        'compound-shareholders',
        'compound-lp',
        'automax-bonus',
      ];
    }

    const normalized = TASK_ALIASES[p] ?? p;
    if (!ALLOWED_DAEMON_TASKS.has(normalized)) {
      throw new Error(
        `Unknown task in --tasks: ${p0}. Expected one of: poke, harvest-staking, sweep-market, sweep-listings, expire-offers, checkpoint-before-expiry, compound-shareholders, compound-lp, automax-bonus, all`,
      );
    }

    if (!out.includes(normalized)) out.push(normalized);
  }

  return out.length ? out : null;
}
