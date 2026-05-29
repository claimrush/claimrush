import 'dotenv/config';

import fs from 'node:fs';
import path from 'node:path';
import readline from 'node:readline';

import {
  createPolicyStrategy,
  loadStrategiesFromModules,
  parseJsonWithBigInt,
  readAgentRunSession,
  runStrategies,
  stringifyJson,
  type AgentPlan,
  type AgentTickRecordV1,
} from '../src/index.js';

type CliOpts = {
  runDir: string;
  /** 1-indexed tick number; omit to use the last tick. */
  tick?: number;
  pretty: boolean;

  strategyModules: string[];
  includePolicyStrategy: boolean;
  policyStrategyPriority?: number;
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
ClaimRush strategy runner (offline)

Runs AgentStrategy plugins once against a recorded tick from a previous agent run.

Usage
  npm -C agents/sdk run example:strategy -- --run-dir <path> [options]

Required
  --run-dir <path>               Existing run directory containing session.json + ticks.jsonl

Options
  --tick <n>                     1-indexed tick number (default: last tick)
  --pretty                       Pretty-print JSON output

  --strategy-module <path>       Load AgentStrategy plugins from an ESM module (repeatable)
  --include-policy-strategy      Also run the built-in policy strategy as a low-priority fallback
  --policy-strategy-priority <n> Priority for policy fallback (default: -100)

Env
  RUN_DIR
  TICK
  PRETTY=1
  STRATEGY_MODULES=./a.mjs,./b.mjs
  INCLUDE_POLICY_STRATEGY=1
  POLICY_STRATEGY_PRIORITY=-100

Notes
- This does NOT execute transactions.
- Requires ticks.jsonl, which is produced when the live agent is started with WRITE_TICK_RECORDS=1.
`);
    process.exit(0);
  }

  const runDir = get('run-dir') ?? env.RUN_DIR;
  if (!runDir) throw new Error('Missing --run-dir <path> (or RUN_DIR env var)');

  const tickRaw = get('tick') ?? env.TICK;
  const tick = tickRaw ? Number(tickRaw) : undefined;
  if (tick !== undefined && (!Number.isFinite(tick) || tick <= 0)) {
    throw new Error(`Invalid --tick (expected positive integer), got: ${tickRaw}`);
  }

  const pretty = has('pretty') || env.PRETTY === '1';

  const strategyModules = getAll('strategy-module');
  const includePolicyStrategy =
    has('include-policy-strategy') || env.INCLUDE_POLICY_STRATEGY === '1';

  const policyStrategyPriorityRaw = get('policy-strategy-priority') ?? env.POLICY_STRATEGY_PRIORITY;
  const policyStrategyPriority = policyStrategyPriorityRaw
    ? Number(policyStrategyPriorityRaw)
    : undefined;

  if (strategyModules.length === 0 && !includePolicyStrategy) {
    throw new Error('No strategies provided. Use --strategy-module or --include-policy-strategy.');
  }

  return {
    runDir,
    tick,
    pretty,
    strategyModules,
    includePolicyStrategy,
    policyStrategyPriority,
  };
}

async function readTickRecord(params: {
  ticksFp: string;
  tick?: number;
}): Promise<{ tick: number; record: AgentTickRecordV1 }> {
  const rs = fs.createReadStream(params.ticksFp, { encoding: 'utf8' });
  const rl = readline.createInterface({ input: rs, crlfDelay: Infinity });

  let tickCount = 0;
  let lastTick: AgentTickRecordV1 | undefined;
  let lastTickNum = 0;

  for await (const line of rl) {
    const s = String(line).trim();
    if (!s) continue;

    const rec = parseJsonWithBigInt<AgentTickRecordV1>(s);
    if (!rec || rec.version !== 'v1') continue;

    tickCount++;

    if (params.tick !== undefined) {
      if (tickCount === params.tick) {
        return { tick: tickCount, record: rec };
      }
    } else {
      lastTick = rec;
      lastTickNum = tickCount;
    }
  }

  if (params.tick !== undefined) {
    throw new Error(`Tick ${params.tick} not found in ${params.ticksFp} (has ${tickCount} ticks)`);
  }

  if (!lastTick) throw new Error(`No ticks found in ${params.ticksFp}`);
  return { tick: lastTickNum, record: lastTick };
}

async function main(): Promise<void> {
  const argv = process.argv.slice(2);
  const cli = parseArgs(argv, process.env);

  const runDir = path.resolve(cli.runDir);
  const session = readAgentRunSession(runDir);

  const ticksFp = path.join(runDir, 'ticks.jsonl');
  if (!fs.existsSync(ticksFp)) {
    throw new Error(
      `Missing ticks.jsonl in runDir: ${runDir} (enable WRITE_TICK_RECORDS=1 when running example:agent)`,
    );
  }

  const { tick, record } = await readTickRecord({ ticksFp, tick: cli.tick });

  const strategies = [
    ...(cli.strategyModules.length ? await loadStrategiesFromModules(cli.strategyModules) : []),
    ...(cli.includePolicyStrategy
      ? [createPolicyStrategy({ priority: cli.policyStrategyPriority ?? -100 })]
      : []),
  ];

  const out = await runStrategies({
    strategies,
    ctx: {
      chain: session.chain,
      chainId: session.chainId,
      agent: session.agent,
      user: session.user,
      snapshot: record.snapshot,
      config: session.policyConfig,
      state: record.policyState ?? {},
      nowMs: record.nowMs,
      caller: record.caller,
      delegation: record.delegation,
    },
  });

  const plan: AgentPlan = {
    chain: session.chain,
    chainId: session.chainId,
    agent: session.agent,
    blockNumber: record.snapshot.meta.blockNumber,
    blockTimestamp: record.snapshot.meta.blockTimestamp,
    actions: out.actions,
  };

  console.log(
    stringifyJson(
      {
        version: 'v1',
        runDir,
        tick,
        nowMs: record.nowMs,
        blockNumber: plan.blockNumber,
        blockTimestamp: plan.blockTimestamp,
        strategyTraces: out.traces.map((t) => ({
          id: t.id,
          priority: t.priority,
          ok: t.ok ? '1' : '0',
          durationMs: t.durationMs,
          actionCount: t.actionCount,
          stop: t.stop ? '1' : '0',
          error: t.error,
          notes: t.notes,
        })),
        plan,
      },
      { pretty: cli.pretty },
    ),
  );
}

main().catch((err) => {
  console.error(err);
  process.exit(1);
});
