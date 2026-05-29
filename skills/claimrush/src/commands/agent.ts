import path from 'node:path';

import {
  loadStrategiesFromModules,
  runLiveAgent,
} from '@claimrush/agent-sdk';
import type { LiveAgentOptions } from '@claimrush/agent-sdk';

import { helpRequested, makeFlagBag } from '../util/args.js';
import { isChainName, resolveNetwork, defaultTakeoverHardCap } from '../safety/networks.js';
import { applyCralGuards, jsonStringify, parseEthStrict } from '../safety/cral.js';
import { loadCralPack } from '../safety/cralPack.js';
import { parseActingFor, repoRoot } from '../util/identity.js';

const HELP = `claimrush agent - run the live agent loop (thin pass-through to runLiveAgent)

USAGE
  claimrush agent --once  [--enable-takeovers] [--enable-furnace-entry] ...
  claimrush agent --loop  [--tick-seconds 12] [--monitor]
                  [--strategy-module ./mod.mjs ...] [--execute]

COMMON
  --chain / --rpc-url / --acting-for / --execute / --i-understand / --pretty

STRATEGY TOGGLES (mirrors example:agent)
  --enable-takeovers        --enable-furnace-entry
  --enable-royalties-claim  --enable-withdrawals
  --max-takeover-eth <E>    --furnace-eth-in <E>
  --slippage-bps <bps>      --lock-duration-days <N>
  --target-token-id <N>     --auto-max
  --takeover-cooldown-seconds <N>
  --min-royalties-eth-to-claim <E>
  --min-king-eth-to-withdraw <E>  --min-refund-eth-to-withdraw <E>

LOOP CONTROL
  --once                    Run a single tick (DEFAULT - safe-by-default).
  --loop                    Run forever (must be explicitly requested).
  --tick-seconds <N>        Cadence (default 12).
  --monitor                 Start the embedded HTTP monitor on 127.0.0.1:8787.
  --monitor-port <N>        Override port.
  --monitor-token <s>       Bearer token for monitor.

PRIVATE RPC
  --private-rpc-url <url>   Forwarded to runLiveAgent.
  --private-rpc-mode <m>    off|route|only.

STRATEGY PLUGINS
  --strategy-module ./mod.mjs    (repeatable; module exports default {plan(...)})

NOTES
  - This command applies the CRAL preflight (caps, slippage cap) before the
    agent loop starts. The SDK enforces deadlines + simulation per tick.
  - --execute on --chain base requires --i-understand.
`;

export async function runAgent(argv: string[]): Promise<number> {
  const f = makeFlagBag(argv);
  if (helpRequested(argv)) {
    console.log(HELP);
    return 0;
  }

  const chainArg = f.get('chain') ?? process.env.CLAIMRUSH_CHAIN ?? 'local';
  if (!isChainName(chainArg)) {
    console.error(`[agent] invalid --chain '${chainArg}'`);
    return 64;
  }

  const execute = f.has('execute');
  const iUnderstand = f.has('i-understand');
  const net = resolveNetwork({
    chain: chainArg,
    rpcUrl: f.get('rpc-url'),
    requireAllowlistedRpc: execute && chainArg === 'base',
  });

  // CRAL preflight using the supplied caps.
  const maxTakeoverEthStr = f.get('max-takeover-eth');
  const maxTakeoverWei = maxTakeoverEthStr ? parseEthStrict(maxTakeoverEthStr, 'max-takeover-eth') : undefined;
  if (f.has('enable-takeovers') && execute && !maxTakeoverWei) {
    console.error('[agent] --enable-takeovers + --execute requires --max-takeover-eth');
    return 64;
  }
  if (maxTakeoverWei && maxTakeoverWei > defaultTakeoverHardCap(net.chain)) {
    console.error(
      `[agent] --max-takeover-eth ${maxTakeoverWei} > hard cap ${defaultTakeoverHardCap(net.chain)} for chain ${net.chain}`,
    );
    return 65;
  }
  if (f.has('enable-furnace-entry') && execute && !f.get('furnace-eth-in')) {
    console.error('[agent] --enable-furnace-entry + --execute requires --furnace-eth-in');
    return 64;
  }
  if (execute && f.has('loop')) {
    console.error(
      '[agent] --execute + --loop requires explicit acknowledgement. Run with --once first; pass --i-acknowledge-loop-execute to override.',
    );
    if (!f.has('i-acknowledge-loop-execute')) return 65;
  }

  const slippageBpsRaw = f.get('slippage-bps');
  const slippageBps = slippageBpsRaw ? BigInt(slippageBpsRaw) : undefined;
  const guard = applyCralGuards({
    action: 'agent',
    chain: net.chain,
    execute,
    iUnderstand,
    slippageBps,
    spendCapWei: maxTakeoverWei,
    spendCapKind: 'takeover',
  });
  if (!guard.ok) {
    console.error(`[agent] CRAL preflight failed: ${guard.reason}`);
    return 65;
  }

  const strategyModules = f.getAll('strategy-module').map((p) => path.resolve(p));
  const strategies = strategyModules.length
    ? await loadStrategiesFromModules(strategyModules, { baseDir: repoRoot() })
    : undefined;

  const options: LiveAgentOptions = {
    rpcUrl: net.rpcUrl,
    chain: net.manifestStem,
    abiNetwork: net.abiNetwork,

    privateRpcUrl: f.get('private-rpc-url') ?? process.env.PRIVATE_RPC_URL,
    privateRpcMode: ((f.get('private-rpc-mode') ?? process.env.PRIVATE_RPC_MODE) as
      | 'off'
      | 'route'
      | 'only'
      | undefined) ?? undefined,

    actorIndex: f.get('actor-index') ? Number(f.get('actor-index')) : undefined,
    actingForUser: parseActingFor(f.get('acting-for')),

    execute,
    once: !f.has('loop'),
    tickSeconds: f.get('tick-seconds') ? Number(f.get('tick-seconds')) : undefined,
    maxActionsPerTick: f.get('max-actions-per-tick') ? Number(f.get('max-actions-per-tick')) : undefined,

    monitorEnabled: f.has('monitor'),
    monitorPort: f.get('monitor-port') ? Number(f.get('monitor-port')) : undefined,
    monitorToken: f.get('monitor-token'),

    enableFurnaceEntry: f.has('enable-furnace-entry'),
    enableTakeovers: f.has('enable-takeovers'),
    enableRoyaltiesClaim: f.has('enable-royalties-claim'),
    enableWithdrawals: f.has('enable-withdrawals'),

    furnaceEthIn: f.get('furnace-eth-in'),
    lockDurationDays: f.get('lock-duration-days') ? Number(f.get('lock-duration-days')) : undefined,
    targetTokenId: f.get('target-token-id') ? BigInt(f.get('target-token-id') as string) : undefined,
    createAutoMax: f.has('auto-max'),
    slippageBps: slippageBps ? Number(slippageBps) : undefined,

    maxTakeoverEth: maxTakeoverEthStr,
    takeoverCooldownSeconds: f.get('takeover-cooldown-seconds')
      ? Number(f.get('takeover-cooldown-seconds'))
      : undefined,

    minRoyaltiesEthToClaim: f.get('min-royalties-eth-to-claim'),
    minKingEthToWithdraw: f.get('min-king-eth-to-withdraw'),
    minRefundEthToWithdraw: f.get('min-refund-eth-to-withdraw'),

    strategies,

    outdir: f.get('outdir'),
    writeArtifacts: !f.has('no-artifacts'),
  };

  let cralContext: { packId: string; packVersion: string; hardRules: string[] } | undefined;
  if (!f.has('no-cral-context')) {
    try {
      const pack = loadCralPack(f.get('cral-path'));
      cralContext = {
        packId: pack.packId,
        packVersion: pack.packVersion,
        hardRules: pack.hardRules,
      };
    } catch (err: unknown) {
      cralContext = undefined;
      console.error(`[agent] CRAL context not loaded: ${(err as Error).message ?? String(err)}`);
    }
  }

  const result = await runLiveAgent(options);

  console.log(
    jsonStringify(
      {
        ok: true,
        stage: execute ? 'executed' : 'simulated',
        chain: net.chain,
        runResult: {
          ticks: (result as any).ticks ?? null,
          actionsPlanned: (result as any).actionsPlanned ?? null,
          actionsExecuted: (result as any).actionsExecuted ?? null,
          stoppedReason: (result as any).stoppedReason ?? null,
          outdir: (result as any).outdir ?? null,
        },
        cralNotes: guard.notes,
        cralContext,
      },
      f.has('pretty'),
    ),
  );
  return 0;
}
