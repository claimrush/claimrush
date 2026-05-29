import 'dotenv/config';

import path from 'node:path';

import { replayAgentRun, stringifyJson, loadStrategiesFromModules } from '../src/index.js';

type CliOpts = {
  runDir: string;
  outdir?: string;
  maxTicks?: number;
  pretty: boolean;
  compare: boolean;
  baseline?: string;
  strategyModules: string[];
};

function parseArgs(argv: string[], env: NodeJS.ProcessEnv): CliOpts {
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
      const a = argv[i];
      if (a.startsWith(pref)) {
        const v = a.slice(pref.length);
        if (v) out.push(v);
        continue;
      }
      if (a === `--${key}`) {
        const v = argv[i + 1];
        if (v && !v.startsWith('--')) {
          out.push(v);
          i++;
        }
      }
    }

    // Env fallbacks (comma-separated or single)
    const envList = env.STRATEGY_MODULES ?? env.STRATEGY_MODULE;
    if (envList) {
      for (const part of envList.split(',')) {
        const v = String(part).trim();
        if (v) out.push(v);
      }
    }

    return out;
  };

  const has = (flag: string): boolean => argv.includes(`--${flag}`);

  const help = has('help') || argv.includes('-h');
  if (help) {
    console.log(`
ClaimRush agent replay (offline)

Replays the planner against recorded tick snapshots produced by example:agent with WRITE_TICK_RECORDS=1.

Usage
  npm -C agents/sdk run example:replay -- --run-dir <path> [options]

Required
  --run-dir <path>          Existing run directory (agents/sdk/out/agent-<ts>/)

Options
  --outdir <path>           Output directory for replay artifacts (default: <runDir>/replay-<ts>)
  --max-ticks <n>           Max ticks to replay (default: all)
  --pretty                  Pretty-print JSON output
  --compare                 Compare replayed action summaries vs baseline decisions.jsonl
  --baseline <path>         Override baseline decisions file (default: <runDir>/decisions.jsonl)
  --strategy-module <path>  Load strategy plugins module (repeatable; env: STRATEGY_MODULES)

Notes
- This does NOT execute transactions.
- Requires that the original run was started with WRITE_TICK_RECORDS=1 so ticks.jsonl exists.
- Output:
  - replay.plans.jsonl
  - replay.summary.json
  - replay.compare.jsonl (only when --compare)

Example
  RPC_URL=http://127.0.0.1:8545 WRITE_TICK_RECORDS=1 \
    npm -C agents/sdk run example:agent

  npm -C agents/sdk run example:replay -- --run-dir agents/sdk/out/agent-2026-02-03T00-00-00Z --compare
`);
    process.exit(0);
  }

  const runDir = get('run-dir') ?? env.RUN_DIR;
  if (!runDir) throw new Error('Missing --run-dir <path> (or RUN_DIR env var)');

  const outdir = get('outdir') ?? env.OUTDIR;
  const maxTicks = get('max-ticks')
    ? Number(get('max-ticks'))
    : env.MAX_TICKS
      ? Number(env.MAX_TICKS)
      : undefined;
  const pretty = has('pretty') || env.PRETTY === '1';
  const compare = has('compare') || env.COMPARE === '1';
  const baseline = get('baseline') ?? env.BASELINE;

  const strategyModules = getAll('strategy-module');

  return { runDir, outdir, maxTicks, pretty, compare, baseline, strategyModules };
}

async function main(): Promise<void> {
  const argv = process.argv.slice(2);
  const cli = parseArgs(argv, process.env);

  // Normalize runDir to avoid accidental relative confusion when invoked from repo root.
  const runDir = path.resolve(cli.runDir);

  const strategies = cli.strategyModules.length
    ? await loadStrategiesFromModules(cli.strategyModules)
    : undefined;

  const res = await replayAgentRun({
    runDir,
    outdir: cli.outdir ? path.resolve(cli.outdir) : undefined,
    maxTicks: cli.maxTicks,
    pretty: cli.pretty,
    compare: cli.compare,
    baselineDecisionsFp: cli.baseline ? path.resolve(cli.baseline) : undefined,
    strategies,
  });

  console.log(
    stringifyJson(
      {
        ok: res.ok,
        outdir: res.outdir,
        tickCount: res.tickCount,
        lastBlockNumber: res.lastPlan?.blockNumber,
        lastActionCount: res.lastPlan?.actions.length,
        compare: res.compare
          ? {
              ok: res.compare.ok,
              mismatches: res.compare.mismatches,
              baselineTickCount: res.compare.baselineTickCount,
              outCompareFp: res.compare.outCompareFp,
            }
          : undefined,
      },
      { pretty: cli.pretty },
    ),
  );

  if (cli.compare && res.compare && !res.compare.ok) {
    process.exit(2);
  }
}

main().catch((err) => {
  console.error(err);
  process.exit(1);
});
