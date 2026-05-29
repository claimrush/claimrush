import 'dotenv/config';

import type { Address } from 'viem';
import { createWalletClient, http } from 'viem';

import {
  createClaimRushClients,
  executeAgentPlan,
  getClaimRushContracts,
  loadDeploymentManifest,
  stringifyJson,
} from '../src/index.js';

import type { AbiNetwork } from '../src/abis.js';
import { DEFAULT_ANVIL_MNEMONIC, deriveActors } from '../src/harness/accounts.js';

type CliOpts = {
  rpcUrl: string;

  // Optional private tx RPC (MEV-sensitive txs only)
  privateRpcUrl?: string;
  privateRpcMode?: 'off' | 'route' | 'only';

  chain: string;
  abiNetwork: AbiNetwork;
  actorIndex?: number;

  cmd:
    | 'offer-create'
    | 'offer-cancel'
    | 'offer-extend'
    | 'offer-cancel-expired'
    | 'offer-execute'
    | 'list-lock'
    | 'delist-lock'
    | 'cancel-expired-listing'
    | 'sell-lock'
    | 'sell-listed-lock';

  execute: boolean;
  pretty: boolean;
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

  const has = (flag: string): boolean => argv.includes(`--${flag}`);

  const help = has('help') || argv.includes('-h');
  if (help) {
    console.log(`
ClaimRush market actions demo (AgentPlan v1)

Builds a single-action AgentPlan and simulates or executes it.
This is mostly for:
- testing MarketRouter actions end-to-end
- giving external bots a concrete plan/action example

Usage
  npm -C agents/sdk run example:market -- [options]

Core
  --rpc-url <url>              HTTP RPC (default: RPC_URL or http://127.0.0.1:8545)
  --chain <name>               Manifest chain (default: CLAIMRUSH_CHAIN or local)
  --abi-network <name>         ABI folder (default: ABI_NETWORK or base_sepolia)
  --actor-index <n>            Which derived account to use (default: 0)

Private RPC (optional)
  --private-rpc-url <url>      Private tx RPC endpoint (default: PRIVATE_RPC_URL)
  --private-rpc-mode <mode>    off|route|only (default: route if url set)

Execution
  --execute                    Send tx (default: dry-run)
  --pretty                     Pretty-print JSON output

Command
  --cmd <name>                 One of:
                              - offer-create
                              - offer-cancel
                              - offer-extend
                              - offer-cancel-expired
                              - offer-execute
                              - list-lock
                              - delist-lock
                              - cancel-expired-listing
                              - sell-lock
                              - sell-listed-lock

Env vars (per command)
  offer-create
    TARGET_BONUS_BPS           e.g. 2500 for +25% bonus
    BUDGET_CLAIM               budget in CLAIM base units
    DURATION_DAYS or DURATION_SECONDS
    CREATE_AUTO_MAX            1|0 (default 0)
    ESCROW_TTL_SECONDS         how long the offer stays active (default 3600)
    DESTINATION_LOCK_ID        0 to create new lock, else add to existing lock (default 0)
    SLIPPAGE_BPS               bps guard for reserve bonus path (default 50)

  offer-cancel
    OFFER_ID

  offer-extend
    OFFER_ID
    TTL_SECONDS_FROM_NOW

  offer-cancel-expired
    OFFER_ID

  offer-execute
    OFFER_ID

  list-lock
    TOKEN_ID
    MIN_CLAIM_OUT              listing floor in CLAIM base units
    TTL_SECONDS                listing expiry from now (default 3600)

  delist-lock
    TOKEN_ID

  cancel-expired-listing
    TOKEN_ID

  sell-lock
    TOKEN_ID
    SLIPPAGE_BPS               bps guard for sell quote (default 50)
    DEADLINE_SECONDS           deadline from now (default 60)

  sell-listed-lock
    TOKEN_ID

Examples
  # Create an offer (simulate)
  RPC_URL=http://127.0.0.1:8545 TARGET_BONUS_BPS=2500 BUDGET_CLAIM=1000000000000000000 DURATION_DAYS=30 \
    npm -C agents/sdk run example:market -- --cmd offer-create

  # Sell a lock to the Furnace (simulate)
  RPC_URL=http://127.0.0.1:8545 TOKEN_ID=1 SLIPPAGE_BPS=50 DEADLINE_SECONDS=60 \
    npm -C agents/sdk run example:market -- --cmd sell-lock

  # Route only swap/takeover sends via private RPC (route mode)
  RPC_URL=http://127.0.0.1:8545 PRIVATE_RPC_URL=http://127.0.0.1:8545 PRIVATE_RPC_MODE=route TOKEN_ID=1 SLIPPAGE_BPS=50 DEADLINE_SECONDS=60 \
    npm -C agents/sdk run example:market -- --cmd sell-lock --execute
`);
    process.exit(0);
  }

  const rpcUrl = get('rpc-url') ?? env.RPC_URL ?? 'http://127.0.0.1:8545';
  const chain = get('chain') ?? env.CLAIMRUSH_CHAIN ?? 'local';
  const abiNetwork = (get('abi-network') ?? env.ABI_NETWORK ?? 'base_sepolia') as AbiNetwork;
  const actorIndex = get('actor-index')
    ? Number(get('actor-index'))
    : env.ACTOR_INDEX
      ? Number(env.ACTOR_INDEX)
      : undefined;

  const privateRpcUrl = get('private-rpc-url') ?? env.PRIVATE_RPC_URL;
  const privateRpcModeRaw = get('private-rpc-mode') ?? env.PRIVATE_RPC_MODE;

  const parsePrivateRpcMode = (v: string): 'off' | 'route' | 'only' => {
    const s = v.trim().toLowerCase();
    if (s === 'off') return 'off';
    if (s === 'route') return 'route';
    if (s === 'only') return 'only';
    throw new Error(`Invalid private rpc mode: ${v} (expected off|route|only)`);
  };

  const privateRpcMode = privateRpcModeRaw ? parsePrivateRpcMode(privateRpcModeRaw) : undefined;

  const cmd = (get('cmd') ?? env.CMD) as CliOpts['cmd'] | undefined;
  if (!cmd) {
    throw new Error('Missing --cmd <name> (or CMD env var). Use --help to see options.');
  }

  const execute = has('execute') ? true : env.EXECUTE === '1';
  const pretty = has('pretty') || env.PRETTY === '1';

  return {
    rpcUrl,
    privateRpcUrl,
    privateRpcMode,
    chain,
    abiNetwork,
    actorIndex,
    cmd,
    execute,
    pretty,
  };
}

function requireEnv(env: NodeJS.ProcessEnv, key: string): string {
  const v = env[key];
  if (!v || !v.trim()) throw new Error(`Missing env var ${key}`);
  return v.trim();
}

function envBigint(env: NodeJS.ProcessEnv, key: string, fallback?: string): bigint {
  const v = (env[key] ?? fallback ?? '').trim();
  if (!v) throw new Error(`Missing env var ${key}`);
  return BigInt(v);
}

function envBigintOptional(env: NodeJS.ProcessEnv, key: string, fallback: string): bigint {
  const v = (env[key] ?? fallback).trim();
  return BigInt(v);
}

function envBool(env: NodeJS.ProcessEnv, key: string, fallback = '0'): boolean {
  const v = (env[key] ?? fallback).trim().toLowerCase();
  return v === '1' || v === 'true' || v === 'yes';
}

async function main(): Promise<void> {
  const argv = process.argv.slice(2);
  const cli = parseArgs(argv, process.env);

  const { publicClient } = createClaimRushClients({ rpcUrl: cli.rpcUrl });
  const chainId = await publicClient.getChainId();

  const manifest = loadDeploymentManifest({ chain: cli.chain });

  const actorIndex = cli.actorIndex ?? 0;
  const privateKeysCsv =
    process.env.PRIVATE_KEYS ?? (process.env.PRIVATE_KEY ? process.env.PRIVATE_KEY : undefined);

  const actors = deriveActors({
    count: actorIndex + 1,
    mnemonic: process.env.MNEMONIC ?? process.env.LOCAL_MNEMONIC ?? DEFAULT_ANVIL_MNEMONIC,
    privateKeysCsv,
  });

  if (!actors.length) {
    throw new Error('No accounts available (set MNEMONIC or PRIVATE_KEYS)');
  }

  const actor = actors[Math.min(actorIndex, actors.length - 1)];
  const agent = actor.account.address as Address;

  const contracts = await getClaimRushContracts({
    publicClient,
    manifest,
    abiNetwork: cli.abiNetwork,
  });
  const walletClient = createWalletClient({ transport: http(cli.rpcUrl), account: actor.account });

  // Optional private RPC for MEV-sensitive sends (takeovers + swaps).
  const privateRpcUrl = cli.privateRpcUrl;
  const privateRpcMode =
    privateRpcUrl && privateRpcUrl.trim() ? (cli.privateRpcMode ?? 'route') : ('off' as const);

  const privateWalletClient =
    privateRpcUrl && privateRpcUrl.trim() && privateRpcMode !== 'off'
      ? createWalletClient({ transport: http(privateRpcUrl), account: actor.account })
      : undefined;

  const head = await publicClient.getBlock({ blockTag: 'latest' });

  // Build the requested single action.
  const env = process.env;

  // NOTE: We intentionally keep this example loosely typed so it stays stable across
  // schema evolutions (and so external agents can copy the JSON shape).
  let action: any;

  switch (cli.cmd) {
    case 'offer-create': {
      const targetBonusBps = envBigint(env, 'TARGET_BONUS_BPS');
      const budgetClaim = envBigint(env, 'BUDGET_CLAIM');

      const durationSeconds =
        env.DURATION_SECONDS && env.DURATION_SECONDS.trim()
          ? BigInt(env.DURATION_SECONDS.trim())
          : BigInt(requireEnv(env, 'DURATION_DAYS')) * 86_400n;

      action = {
        kind: 'marketRouter.createBonusTargetEscrowWithTarget',
        targetBonusBps,
        budgetClaim,
        durationSeconds,
        createAutoMax: envBool(env, 'CREATE_AUTO_MAX', '0'),
        escrowTtlSeconds: envBigintOptional(env, 'ESCROW_TTL_SECONDS', '3600'),
        destinationLockId: envBigintOptional(env, 'DESTINATION_LOCK_ID', '0'),
        slippageBps: envBigintOptional(env, 'SLIPPAGE_BPS', '50'),
      };
      break;
    }

    case 'offer-cancel': {
      const offerId = envBigint(env, 'OFFER_ID');
      action = { kind: 'marketRouter.cancelBonusTargetEscrow', offerId };
      break;
    }

    case 'offer-extend': {
      const offerId = envBigint(env, 'OFFER_ID');
      const ttlSecondsFromNow = envBigint(env, 'TTL_SECONDS_FROM_NOW');
      action = { kind: 'marketRouter.extendBonusTargetEscrowExpiry', offerId, ttlSecondsFromNow };
      break;
    }

    case 'offer-cancel-expired': {
      const offerId = envBigint(env, 'OFFER_ID');
      action = { kind: 'marketRouter.cancelExpiredBonusTargetEscrow', offerId };
      break;
    }

    case 'offer-execute': {
      const offerId = envBigint(env, 'OFFER_ID');
      action = { kind: 'marketRouter.executeAutoFurnace', offerId };
      break;
    }

    case 'list-lock': {
      const tokenId = envBigint(env, 'TOKEN_ID');
      const minClaimOut = envBigint(env, 'MIN_CLAIM_OUT');
      const ttlSeconds = envBigintOptional(env, 'TTL_SECONDS', '3600');
      action = { kind: 'marketRouter.listLock', tokenId, minClaimOut, ttlSeconds };
      break;
    }

    case 'delist-lock': {
      const tokenId = envBigint(env, 'TOKEN_ID');
      action = { kind: 'marketRouter.delistLock', tokenId };
      break;
    }

    case 'cancel-expired-listing': {
      const tokenId = envBigint(env, 'TOKEN_ID');
      action = { kind: 'marketRouter.cancelExpiredListing', tokenId };
      break;
    }

    case 'sell-lock': {
      const tokenId = envBigint(env, 'TOKEN_ID');
      const slippageBps = envBigintOptional(env, 'SLIPPAGE_BPS', '50');
      const deadlineSeconds = envBigintOptional(env, 'DEADLINE_SECONDS', '60');
      action = { kind: 'marketRouter.sellLockToFurnace', tokenId, slippageBps, deadlineSeconds };
      break;
    }

    case 'sell-listed-lock': {
      const tokenId = envBigint(env, 'TOKEN_ID');
      const deadlineSeconds = envBigintOptional(env, 'DEADLINE_SECONDS', '60');
      action = { kind: 'marketRouter.sellListedLockToFurnace', tokenId, deadlineSeconds };
      break;
    }

    default:
      throw new Error(`Unknown --cmd ${cli.cmd}`);
  }

  const plan: any = {
    chain: cli.chain,
    chainId,
    blockNumber: head.number,
    blockTimestamp: head.timestamp,
    agent,
    actions: [action],
  };

  console.log('Plan (single action):');
  console.log(stringifyJson(plan, { pretty: true }));

  const run = await executeAgentPlan({
    publicClient,
    walletClient,
    privateWalletClient,
    privateRpcMode,
    account: actor.account,
    manifest,
    abiNetwork: cli.abiNetwork,
    contracts,
    execute: cli.execute,
    plan,
  });

  console.log('\nResult:');
  console.log(stringifyJson(run, { pretty: cli.pretty }));

  const hasError = run.some((r) => r.error);
  if (hasError) {
    process.exit(1);
  }
}

main().catch((err) => {
  console.error(err);
  process.exit(1);
});
