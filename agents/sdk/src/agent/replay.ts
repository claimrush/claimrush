import fs from 'node:fs';
import path from 'node:path';
import readline from 'node:readline';

import type { Address } from 'viem';

import { stringifyJson } from '../events.js';
import { createWriteStreamNoFollow, writeTextFileNoFollow } from '../security/fs.js';
import type { ClaimRushSnapshot } from '../snapshot.js';
import { buildActionPlan } from './policy.js';
import type {
  PolicyCallerContext,
  PolicyConfig,
  PolicyDelegationContext,
  PolicyState,
} from './policy.js';
import { summarizeAgentActionsForLog } from './planLog.js';
import { runStrategies, type AgentStrategy, type AgentStrategyTrace } from './strategies.js';
import type { AgentAction, AgentPlan } from './types.js';

export type AgentRunSessionV1 = {
  version: 'v1';
  ts: number;
  chain: string;
  chainId: number;
  agent: Address;
  /** Managed identity (same as agent when self-playing). */
  user: Address;
  delegated: boolean;
  execute: boolean;
  outdir?: string;
  stateDir?: string;
  privateRpcMode?: 'off' | 'route' | 'only';
  autoApproveEnabled?: boolean;
  autoApproveMode?: 'exact' | 'max';
  autoApproveIncludeNftApprovals?: boolean;
  writeTickRecords?: boolean;
  planning?: {
    mode: 'policy' | 'strategies';
    strategies?: { id: string; priority: number }[];
  };
  policyConfig: PolicyConfig;
};

export type AgentTickRecordV1 = {
  version: 'v1';
  ts: number;
  nowMs: number;
  policyState: PolicyState;
  caller?: PolicyCallerContext;
  delegation?: PolicyDelegationContext;
  snapshot: ClaimRushSnapshot;
};

export type ReplayAgentRunParams = {
  /** Existing run directory produced by example:agent (must contain session.json + ticks.jsonl). */
  runDir: string;
  /**
   * Output directory for replay artifacts.
   *
   * Default: <runDir>/replay-<timestamp>
   */
  outdir?: string;

  /** Max ticks to replay (useful for quick iterations). */
  maxTicks?: number;

  /** Pretty-print replay JSON output. Default: false. */
  pretty?: boolean;

  /**
   * Compare the replayed decisions to the original decisions.jsonl.
   *
   * - This compares the console-friendly action summaries written in decisions.jsonl.
   * - It is meant as a regression signal, not a cryptographic proof.
   */
  compare?: boolean;

  /** Optional override for the baseline decisions file. Default: <runDir>/decisions.jsonl */
  baselineDecisionsFp?: string;

  /** Optional strategy plugins used for planning. If omitted, replay uses the built-in policy planner. */
  strategies?: AgentStrategy[];
};

export type ReplayCompareResult = {
  enabled: true;
  ok: boolean;
  baselineFp: string;
  baselineTickCount: number;
  mismatches: number;
  firstMismatchTick?: number;
  outCompareFp: string;
};

export type ReplayAgentRunResult = {
  ok: boolean;
  outdir: string;
  tickCount: number;
  lastPlan?: AgentPlan;
  compare?: ReplayCompareResult;
};

/**
 * JSON.parse helper that revives BigInt values written via stringifyJson/stringifySnapshot.
 *
 * This converts any string that matches /^\d+$/ into a BigInt.
 */
const MAX_BIGINT_DECIMAL_DIGITS = 256;
const DECIMAL_RE = /^\d+$/;

function clampFiniteInt(v: unknown, min: number, max: number, fallback: number): number {
  const n = typeof v === 'number' ? v : Number(v);
  if (!Number.isFinite(n)) return fallback;
  return Math.max(min, Math.min(max, Math.trunc(n)));
}

export function parseJsonWithBigInt<T = any>(line: string): T {
  return JSON.parse(line, (_k, v) => {
    if (typeof v === 'string' && v.length <= MAX_BIGINT_DECIMAL_DIGITS && DECIMAL_RE.test(v))
      return globalThis.BigInt(v);
    return v;
  }) as T;
}

function parseJsonPlain<T = any>(line: string): T {
  return JSON.parse(line) as T;
}

async function* readJsonlWith<T = any>(fp: string, parse: (s: string) => T): AsyncGenerator<T> {
  const rs = fs.createReadStream(fp, { encoding: 'utf8' });
  const rl = readline.createInterface({ input: rs, crlfDelay: Infinity });
  for await (const line of rl) {
    const s = String(line).trim();
    if (!s) continue;
    yield parse(s);
  }
}

async function* readJsonl<T = any>(fp: string): AsyncGenerator<T> {
  yield* readJsonlWith<T>(fp, parseJsonWithBigInt);
}

async function* readJsonlPlain<T = any>(fp: string): AsyncGenerator<T> {
  yield* readJsonlWith<T>(fp, parseJsonPlain);
}

export function readAgentRunSession(
  runDir: string,
  opts?: { maxBytes?: number },
): AgentRunSessionV1 {
  const fp = path.join(runDir, 'session.json');
  if (!fs.existsSync(fp)) {
    throw new Error(`Missing session.json in runDir: ${runDir}`);
  }

  const maxBytes = clampFiniteInt(opts?.maxBytes, 1, 10_000_000, 1_000_000);

  const st = fs.statSync(fp);
  if (!st.isFile()) throw new Error(`session.json is not a file: ${fp}`);
  if (st.size > maxBytes) {
    throw new Error(`session.json too large: ${st.size} bytes (maxBytes=${maxBytes})`);
  }

  const raw = fs.readFileSync(fp, 'utf8').trim();
  if (!raw) throw new Error(`Empty session.json in runDir: ${runDir}`);
  const session = parseJsonWithBigInt<AgentRunSessionV1>(raw);
  if (session.version !== 'v1') {
    throw new Error(`Unsupported session.json version: ${(session as any).version}`);
  }
  return session;
}

function defaultReplayOutdir(runDir: string): string {
  const ts = new Date().toISOString().replace(/[:.]/g, '-');
  return path.join(runDir, `replay-${ts}`);
}

function ensureDir(p: string): void {
  fs.mkdirSync(p, { recursive: true, mode: 0o700 });
}

function deepEqual(a: any, b: any): boolean {
  if (a === b) return true;
  if (typeof a !== typeof b) return false;
  if (a === null || b === null) return a === b;

  if (Array.isArray(a)) {
    if (!Array.isArray(b)) return false;
    if (a.length !== b.length) return false;
    for (let i = 0; i < a.length; i++) {
      if (!deepEqual(a[i], b[i])) return false;
    }
    return true;
  }

  if (typeof a === 'object') {
    if (Array.isArray(b)) return false;
    const ak = Object.keys(a).sort();
    const bk = Object.keys(b).sort();
    if (ak.length !== bk.length) return false;
    for (let i = 0; i < ak.length; i++) {
      if (ak[i] !== bk[i]) return false;
      if (!deepEqual((a as any)[ak[i]], (b as any)[bk[i]])) return false;
    }
    return true;
  }

  return false;
}

function findFirstDiff(
  baseline: any[],
  replay: any[],
): { index: number; reason: string } | undefined {
  if (baseline.length !== replay.length) {
    return { index: -1, reason: `length baseline=${baseline.length} replay=${replay.length}` };
  }
  for (let i = 0; i < baseline.length; i++) {
    if (!deepEqual(baseline[i], replay[i])) {
      return { index: i, reason: `action mismatch at index=${i}` };
    }
  }
  return undefined;
}

/**
 * Replay a recorded agent run offline.
 *
 * This does NOT execute transactions. It re-runs the planner against the recorded
 * per-tick snapshots and writes replayed plans to a JSONL file:
 * - <outdir>/replay.plans.jsonl
 */
export async function replayAgentRun(params: ReplayAgentRunParams): Promise<ReplayAgentRunResult> {
  const session = readAgentRunSession(params.runDir);

  const ticksFp = path.join(params.runDir, 'ticks.jsonl');
  if (!fs.existsSync(ticksFp)) {
    throw new Error(
      `Missing ticks.jsonl in runDir: ${params.runDir} (enable WRITE_TICK_RECORDS=1 when running the agent)`,
    );
  }

  const compareEnabled = Boolean(params.compare);
  const baselineFp = compareEnabled
    ? (params.baselineDecisionsFp ?? path.join(params.runDir, 'decisions.jsonl'))
    : undefined;

  let baselineActions: any[][] | undefined;
  if (compareEnabled) {
    if (!baselineFp) throw new Error('compare enabled but baselineFp is missing');
    if (!fs.existsSync(baselineFp)) {
      throw new Error(`Missing baseline decisions file: ${baselineFp}`);
    }

    baselineActions = [];
    for await (const line of readJsonlPlain<any>(baselineFp)) {
      if (line && Array.isArray((line as any).actions)) {
        baselineActions.push((line as any).actions);
      }
    }
  }

  const planningMode = session.planning?.mode ?? 'policy';
  const strategies = params.strategies && params.strategies.length ? params.strategies : undefined;

  if (compareEnabled && planningMode === 'strategies' && !strategies) {
    const ids = session.planning?.strategies?.map((s) => s.id).filter(Boolean);
    const hint = ids && ids.length ? ` (strategies: ${ids.join(', ')})` : '';
    throw new Error(
      `This run was recorded in strategies mode${hint}, but replay was invoked without strategies. Provide strategies (ReplayAgentRunParams.strategies) or disable --compare.`,
    );
  }

  const outdir = params.outdir ?? defaultReplayOutdir(params.runDir);
  ensureDir(outdir);

  const outPlansFp = path.join(outdir, 'replay.plans.jsonl');
  const ws = createWriteStreamNoFollow(outPlansFp, { append: true, mode: 0o600 });

  const outCompareFp = compareEnabled ? path.join(outdir, 'replay.compare.jsonl') : undefined;
  const compareWs = outCompareFp
    ? createWriteStreamNoFollow(outCompareFp, { append: true, mode: 0o600 })
    : undefined;

  const pretty = Boolean(params.pretty);
  const maxTicks = params.maxTicks;

  let tickCount = 0;
  let lastPlan: AgentPlan | undefined;

  let mismatches = 0;
  let firstMismatchTick: number | undefined;

  try {
    for await (const tick of readJsonl<AgentTickRecordV1>(ticksFp)) {
      if (tick.version !== 'v1') continue;

      tickCount++;
      if (maxTicks !== undefined && tickCount > maxTicks) break;

      const state = tick.policyState ?? {};

      let strategyTraces: AgentStrategyTrace[] | undefined;
      let actions: AgentAction[];
      if (strategies) {
        const out = await runStrategies({
          strategies,
          ctx: {
            chain: session.chain,
            chainId: session.chainId,
            agent: session.agent,
            user: session.user,
            snapshot: tick.snapshot,
            config: session.policyConfig,
            state,
            nowMs: tick.nowMs,
            caller: tick.caller,
            delegation: tick.delegation,
          },
        });
        actions = out.actions;
        strategyTraces = out.traces;
      } else {
        actions = buildActionPlan({
          snapshot: tick.snapshot,
          config: session.policyConfig,
          state,
          nowMs: tick.nowMs,
          caller: tick.caller,
          delegation: tick.delegation,
        });
      }

      const plan: AgentPlan = {
        chain: session.chain,
        chainId: session.chainId,
        agent: session.agent,
        blockNumber: tick.snapshot.meta.blockNumber,
        blockTimestamp: tick.snapshot.meta.blockTimestamp,
        actions,
      };

      lastPlan = plan;

      ws.write(
        stringifyJson(
          {
            version: 'v1',
            tick: tickCount,
            nowMs: tick.nowMs,
            blockNumber: plan.blockNumber,
            blockTimestamp: plan.blockTimestamp,
            strategyTraces: strategyTraces
              ? strategyTraces.map((t) => ({
                  id: t.id,
                  priority: t.priority,
                  ok: t.ok ? '1' : '0',
                  durationMs: t.durationMs,
                  actionCount: t.actionCount,
                  stop: t.stop ? '1' : '0',
                  error: t.error,
                }))
              : undefined,
            actions: plan.actions,
          },
          { pretty },
        ) + '\n',
      );

      if (compareEnabled && baselineActions && compareWs) {
        const expected = baselineActions[tickCount - 1];
        const got = summarizeAgentActionsForLog(plan.actions);

        if (!expected) {
          mismatches++;
          if (firstMismatchTick === undefined) firstMismatchTick = tickCount;
          compareWs.write(
            stringifyJson(
              {
                version: 'v1',
                tick: tickCount,
                blockNumber: plan.blockNumber,
                reason: 'baseline missing tick',
                expected: null,
                got,
              },
              { pretty },
            ) + '\n',
          );
          continue;
        }

        const diff = findFirstDiff(expected, got);
        if (diff) {
          mismatches++;
          if (firstMismatchTick === undefined) firstMismatchTick = tickCount;
          compareWs.write(
            stringifyJson(
              {
                version: 'v1',
                tick: tickCount,
                blockNumber: plan.blockNumber,
                reason: diff.reason,
                diffIndex: diff.index,
                expected,
                got,
              },
              { pretty },
            ) + '\n',
          );
        }
      }
    }

    if (compareEnabled && baselineActions && compareWs) {
      if (baselineActions.length > tickCount) {
        mismatches++;
        if (firstMismatchTick === undefined) firstMismatchTick = tickCount + 1;
        compareWs.write(
          stringifyJson(
            {
              version: 'v1',
              tick: tickCount + 1,
              blockNumber: lastPlan?.blockNumber,
              reason: `baseline has extra ticks baseline=${baselineActions.length} replay=${tickCount}`,
            },
            { pretty },
          ) + '\n',
        );
      }
    }
  } finally {
    ws.end();
    if (compareWs) compareWs.end();
  }

  const compareOk = compareEnabled ? mismatches === 0 : true;

  const compareResult: ReplayCompareResult | undefined = compareEnabled
    ? {
        enabled: true,
        ok: compareOk,
        baselineFp: baselineFp as string,
        baselineTickCount: baselineActions?.length ?? 0,
        mismatches,
        firstMismatchTick,
        outCompareFp: outCompareFp as string,
      }
    : undefined;

  // Emit a small summary file for convenience.
  writeTextFileNoFollow(
    path.join(outdir, 'replay.summary.json'),
    stringifyJson(
      {
        ok: compareOk,
        runDir: params.runDir,
        outdir,
        tickCount,
        lastBlockNumber: lastPlan?.blockNumber,
        lastActionCount: lastPlan?.actions.length,
        compare: compareResult,
      },
      { pretty },
    ),
    { encoding: 'utf8', mode: 0o600 },
  );

  return { ok: compareOk, outdir, tickCount, lastPlan, compare: compareResult };
}
