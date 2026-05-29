#!/usr/bin/env node
/**
 * ClaimRush OpenClaw skill CLI.
 *
 * Verbs:
 *   status       monitor      takeover     lock         collect
 *   withdraw     market       session      plan         agent
 *
 * Every write verb is dry-run by default; pass --execute to send. Mainnet
 * (--chain base) additionally requires --i-understand.
 */

import { runStatus } from './commands/status.js';
import { runMonitor } from './commands/monitor.js';
import { runTakeover } from './commands/takeover.js';
import { runLock } from './commands/lock.js';
import { runCollect } from './commands/collect.js';
import { runWithdraw } from './commands/withdraw.js';
import { runMarket } from './commands/market.js';
import { runSession } from './commands/session.js';
import { runPlan } from './commands/plan.js';
import { runAgent } from './commands/agent.js';
import { runFurnace } from './commands/furnace.js';
import { runCral } from './commands/cral.js';

import { jsonStringify } from './safety/cral.js';

type Verb =
  | 'status'
  | 'monitor'
  | 'takeover'
  | 'lock'
  | 'furnace'
  | 'collect'
  | 'withdraw'
  | 'market'
  | 'session'
  | 'plan'
  | 'agent'
  | 'cral';

const VERBS: ReadonlyArray<Verb> = [
  'status',
  'monitor',
  'takeover',
  'lock',
  'furnace',
  'collect',
  'withdraw',
  'market',
  'session',
  'plan',
  'agent',
  'cral',
];

function topLevelHelp(): string {
  return `claimrush - OpenClaw skill CLI for ClaimRush

USAGE
  claimrush <verb> [flags]
  claimrush --help

VERBS
  status       Read game state (mineCore + furnace + royalties + optional user slice)
  monitor      Tail events / achievements
  takeover     mineCore.takeover or takeoverWithToken (write; dry-run by default)
  lock         furnace.enterWithEth | enterWithClaim | enterWithToken (write)
  furnace      Chat alias: 'furnace lock <ETH>' / 'furnace status' (rewrites to lock/status)
  collect      Collect ETH royalties: royalties.claimShareholderEth | claimShareholderLock (write)
  withdraw     mineCore.withdrawKingBalance | withdrawRefundBalance (write)
  market       offer-create | list | sell-to-furnace (write)
  session      DelegationHub: build | submit | revoke | status
  plan         AgentPlan v1: build | execute (delegated-aware)
  agent        Run the live agent loop (defaults to --once; --loop is opt-in)
  cral         Print the parsed CRAL safety pack (json | prompt | hard-rules)

GLOBAL FLAGS (most verbs)
  --chain <name>            local | base_sepolia | base   (default: local or env CLAIMRUSH_CHAIN)
  --rpc-url <url>           override RPC (default: env RPC_URL or chain default)
  --acting-for <0x...>      manage a user identity via DelegationHub (delegated mode)
  --execute                 actually send tx (default: false / dry-run)
  --i-understand            required with --execute on --chain base
  --pretty                  pretty JSON output

ENVIRONMENT (highlights)
  RPC_URL CLAIMRUSH_CHAIN ABI_NETWORK
  PRIVATE_RPC_URL PRIVATE_RPC_MODE
  MNEMONIC LOCAL_MNEMONIC PRIVATE_KEYS PRIVATE_KEY
  CR_SKILL_MAX_TAKEOVER_ETH_HARDCAP CR_SKILL_MAX_FURNACE_ETH_HARDCAP
  CR_SKILL_MAX_SLIPPAGE_BPS CR_SKILL_BASE_RPC_ALLOWLIST CR_SKILL_OUTDIR

Run 'claimrush <verb> --help' for verb-specific flags.

Reference
  - SDK README:           agents/sdk/README.md
  - CRAL safety pack:     docs/manuals/developer/agents-and-automation.cral.yaml
`;
}

async function main(): Promise<number> {
  const argv = process.argv.slice(2);

  if (argv.length === 0 || argv[0] === '--help' || argv[0] === '-h' || argv[0] === 'help') {
    console.log(topLevelHelp());
    return 0;
  }

  const verbArg = String(argv[0]);
  if (!VERBS.includes(verbArg as Verb)) {
    console.error(`[claimrush] unknown verb: ${verbArg}`);
    console.error(topLevelHelp());
    return 64;
  }

  const verb = verbArg as Verb;
  const rest = argv.slice(1);

  try {
    switch (verb) {
      case 'status':
        return await runStatus(rest);
      case 'monitor':
        return await runMonitor(rest);
      case 'takeover':
        return await runTakeover(rest);
      case 'lock':
        return await runLock(rest);
      case 'furnace':
        return await runFurnace(rest);
      case 'collect':
        return await runCollect(rest);
      case 'withdraw':
        return await runWithdraw(rest);
      case 'market':
        return await runMarket(rest);
      case 'session':
        return await runSession(rest);
      case 'plan':
        return await runPlan(rest);
      case 'agent':
        return await runAgent(rest);
      case 'cral':
        return await runCral(rest);
    }
  } catch (err: unknown) {
    const msg = (err as Error).message ?? String(err);
    console.error(
      jsonStringify(
        {
          ok: false,
          verb,
          error: msg,
        },
        true,
      ),
    );
    return 1;
  }
}

main().then(
  (code) => process.exit(code ?? 0),
  (err) => {
    console.error(err);
    process.exit(1);
  },
);
