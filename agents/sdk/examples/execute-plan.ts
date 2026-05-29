import 'dotenv/config';

import fs from 'node:fs';
import path from 'node:path';

import type { Address } from 'viem';
import { createWalletClient, http } from 'viem';

import {
  AchievementEngine,
  createClaimRushClients,
  executeAgentPlan,
  expandPlanWithAutoApprovals,
  getClaimRushContracts,
  getGameStateSnapshot,
  loadDeploymentManifest,
  readPlanFromFile,
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

  // Optional: frontend achievements API polling (profile badges)
  achievementsBaseUrl?: string;
  achievementsPollIntervalMs?: number;
  achievementsForceRefreshCooldownMs?: number;
  achievementsFetchTimeoutMs?: number;

  planPath: string;
  execute: boolean;
  maxActions?: number;
  allowAgentMismatch: boolean;

  // Optional: auto-insert approvals before actions (execute only)
  autoApproveEnabled: boolean;
  autoApproveMode: 'exact' | 'max';
  autoApproveIncludeNftApprovals: boolean;

  outdir?: string;
  pretty: boolean;
};

function ensureDir(p: string): void {
  fs.mkdirSync(p, { recursive: true });
}

function defaultOutdir(): string {
  const ts = new Date().toISOString().replace(/[:.]/g, '-');
  return path.join('out', `execute-plan-${ts}`);
}

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
ClaimRush agent plan executor

Reads an AgentPlan JSON and simulates or executes actions.

Usage
  npm -C agents/sdk run example:execute-plan -- [options]

Required
  --plan <path>                Path to plan JSON

Core
  --rpc-url <url>              HTTP RPC (default: RPC_URL or http://127.0.0.1:8545)
  --chain <name>               Manifest chain (default: CLAIMRUSH_CHAIN or local)
  --abi-network <name>         ABI folder (default: ABI_NETWORK or base_sepolia)
  --actor-index <n>            Which derived account to use (default: 0)

Private RPC (optional)
  --private-rpc-url <url>       Private tx RPC endpoint (default: PRIVATE_RPC_URL)
  --private-rpc-mode <mode>     off|route|only (default: route if url set)

Execution
  --execute                    Send tx (default: dry-run)
  --max-actions <n>            Max actions to process
  --allow-agent-mismatch       Allow executing a plan whose agent != derived account

Auto approvals (optional)
  --auto-approve               Auto-insert ERC20/veNFT approvals before required actions (execute only)
  --auto-approve-mode <mode>   exact|max (default: exact)
  --no-auto-approve-nft        Disable auto-inserting veNFT approvals (MarketRouter)

Output
  --outdir <path>              Write artifacts here (default: agents/sdk/out/execute-plan-<ts>)
  --pretty                     Pretty-print run summary JSON

Achievements (optional)
  --achievements-base-url <url>        Base URL for /api/achievements (default: ACHIEVEMENTS_BASE_URL)
  --achievements-poll-ms <n>           Poll interval ms (default: ACHIEVEMENTS_POLL_MS or 20000)
  --achievements-refresh-cooldown-ms <n>  Debounce forced refresh after tx (default: ACHIEVEMENTS_REFRESH_COOLDOWN_MS or 5000)
  --achievements-timeout-ms <n>        Fetch timeout ms (default: ACHIEVEMENTS_TIMEOUT_MS or 10000)

Examples
  # Simulate a plan
  npm -C agents/sdk run example:execute-plan -- --plan /tmp/plan.json

  # Execute a plan
  npm -C agents/sdk run example:execute-plan -- --plan /tmp/plan.json --execute
`);
    process.exit(0);
  }

  const planPath = get('plan') ?? env.PLAN;
  if (!planPath) {
    throw new Error('Missing --plan <path> (or PLAN env var)');
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

  const parseBoolOrUndefined = (v: string | undefined): boolean | undefined => {
    if (v === undefined) return undefined;
    const s = v.trim().toLowerCase();
    if (!s) return undefined;
    if (s === '1' || s === 'true' || s === 'yes' || s === 'y' || s === 'on') return true;
    if (s === '0' || s === 'false' || s === 'no' || s === 'n' || s === 'off') return false;
    return undefined;
  };

  const parseAutoApproveMode = (v: string): 'exact' | 'max' => {
    const s = v.trim().toLowerCase();
    if (s === 'exact') return 'exact';
    if (s === 'max' || s === 'infinite' || s === 'maxuint' || s === 'maxuint256') return 'max';
    throw new Error(`Invalid auto approve mode: ${v} (expected exact|max)`);
  };

  const autoApproveEnabled = has('auto-approve')
    ? true
    : (parseBoolOrUndefined(env.AUTO_APPROVE_ENABLED) ?? false);
  const autoApproveModeRaw = get('auto-approve-mode') ?? env.AUTO_APPROVE_MODE;
  const autoApproveMode = autoApproveModeRaw ? parseAutoApproveMode(autoApproveModeRaw) : 'exact';
  const autoApproveIncludeNftApprovals = has('no-auto-approve-nft')
    ? false
    : (parseBoolOrUndefined(env.AUTO_APPROVE_NFT) ?? true);

  const execute = has('execute') ? true : env.EXECUTE === '1';
  const maxActions = get('max-actions')
    ? Number(get('max-actions'))
    : env.MAX_ACTIONS
      ? Number(env.MAX_ACTIONS)
      : undefined;

  const allowAgentMismatch = has('allow-agent-mismatch') || env.ALLOW_AGENT_MISMATCH === '1';

  const outdir = get('outdir') ?? env.OUTDIR;
  const pretty = has('pretty') || env.PRETTY === '1';

  const achievementsBaseUrl = get('achievements-base-url') ?? env.ACHIEVEMENTS_BASE_URL;

  const achievementsPollIntervalMs = get('achievements-poll-ms')
    ? Number(get('achievements-poll-ms'))
    : env.ACHIEVEMENTS_POLL_MS
      ? Number(env.ACHIEVEMENTS_POLL_MS)
      : undefined;

  const achievementsForceRefreshCooldownMs = get('achievements-refresh-cooldown-ms')
    ? Number(get('achievements-refresh-cooldown-ms'))
    : env.ACHIEVEMENTS_REFRESH_COOLDOWN_MS
      ? Number(env.ACHIEVEMENTS_REFRESH_COOLDOWN_MS)
      : undefined;

  const achievementsFetchTimeoutMs = get('achievements-timeout-ms')
    ? Number(get('achievements-timeout-ms'))
    : env.ACHIEVEMENTS_TIMEOUT_MS
      ? Number(env.ACHIEVEMENTS_TIMEOUT_MS)
      : undefined;

  return {
    rpcUrl,
    privateRpcUrl,
    privateRpcMode,
    chain,
    abiNetwork,
    actorIndex,
    planPath,
    execute,
    maxActions,
    allowAgentMismatch,
    autoApproveEnabled,
    autoApproveMode,
    autoApproveIncludeNftApprovals,
    outdir,
    pretty,
    achievementsBaseUrl,
    achievementsPollIntervalMs,
    achievementsForceRefreshCooldownMs,
    achievementsFetchTimeoutMs,
  };
}

async function main(): Promise<void> {
  const argv = process.argv.slice(2);
  const cli = parseArgs(argv, process.env);

  const plan = readPlanFromFile(cli.planPath);

  const { publicClient } = createClaimRushClients({ rpcUrl: cli.rpcUrl });
  const chainId = await publicClient.getChainId();

  if (Number(plan.chainId) !== Number(chainId)) {
    throw new Error(`Plan chainId ${plan.chainId} does not match RPC chainId ${chainId}`);
  }

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

  // If the plan contains actingForUser (newer plans), treat that as the managed identity.
  const actingForUser = (plan as any)?.actingForUser as Address | undefined;
  const user = (actingForUser ?? plan.agent) as Address;

  if (!cli.allowAgentMismatch && plan.agent.toLowerCase() !== agent.toLowerCase()) {
    throw new Error(
      `Plan agent ${plan.agent} does not match derived actor ${agent} (use --allow-agent-mismatch to override)`,
    );
  }

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

  const outdir = cli.outdir ?? defaultOutdir();
  ensureDir(outdir);

  let planResolved = plan;
  if (cli.execute && cli.autoApproveEnabled && plan.actions.length) {
    const expanded = await expandPlanWithAutoApprovals({
      plan,
      publicClient,
      account: actor.account,
      manifest,
      abiNetwork: cli.abiNetwork,
      privateRpcMode,
      options: {
        enabled: true,
        mode: cli.autoApproveMode,
        includeNftApprovals: cli.autoApproveIncludeNftApprovals,
      },
    });

    planResolved = expanded.plan;

    if (expanded.notes.length) {
      console.log(`[execute-plan] auto-approve: ${expanded.notes.join('; ')}`);
    }

    if (expanded.inserted > 0) {
      fs.writeFileSync(path.join(outdir, 'plan.autoApproved.json'), stringifyJson(planResolved));
    }
  }

  const resultsFp = path.join(outdir, 'results.jsonl');
  const resultsWs = fs.createWriteStream(resultsFp, { flags: 'a' });

  const achievementsFp = path.join(outdir, 'achievements.jsonl');
  const achievementsWs = fs.createWriteStream(achievementsFp, { flags: 'a' });

  const enableTakeovers = planResolved.actions.some(
    (a: any) => typeof a?.kind === 'string' && String(a.kind).startsWith('mineCore.takeover'),
  );
  const enableFurnaceEntry = planResolved.actions.some(
    (a: any) => typeof a?.kind === 'string' && String(a.kind).startsWith('furnace.enterWith'),
  );

  const achievements = new AchievementEngine({
    chain: cli.chain,
    chainId,
    agent,
    user,

    subgraphUrl: process.env.SUBGRAPH_URL,
    subgraphLagThresholdBlocks: process.env.SUBGRAPH_LAG_THRESHOLD_BLOCKS
      ? Number(process.env.SUBGRAPH_LAG_THRESHOLD_BLOCKS)
      : undefined,
    subgraphCheckIntervalMs: process.env.SUBGRAPH_CHECK_INTERVAL_MS
      ? Number(process.env.SUBGRAPH_CHECK_INTERVAL_MS)
      : undefined,
    rpcLagThresholdSeconds: process.env.RPC_LAG_THRESHOLD_SECONDS
      ? Number(process.env.RPC_LAG_THRESHOLD_SECONDS)
      : undefined,
    rpcLagRecentBlockChangeWindowSeconds: process.env.RPC_LAG_RECENT_WINDOW_SECONDS
      ? Number(process.env.RPC_LAG_RECENT_WINDOW_SECONDS)
      : undefined,

    achievementsBaseUrl: cli.achievementsBaseUrl,
    achievementsPollIntervalMs: cli.achievementsPollIntervalMs,
    achievementsForceRefreshCooldownMs: cli.achievementsForceRefreshCooldownMs,
    achievementsFetchTimeoutMs: cli.achievementsFetchTimeoutMs,

    emitActionUtility: process.env.EMIT_ACTION_UTILITY === '1',

    write: (a) => {
      achievementsWs.write(stringifyJson(a) + '\n');
    },
  });

  // Keep a copy of the plan in the output dir.
  fs.copyFileSync(cli.planPath, path.join(outdir, 'plan.json'));
  fs.writeFileSync(path.join(outdir, 'plan.resolved.json'), stringifyJson(planResolved));

  const startedAt = Date.now();

  // Initial tick: initializes badge baseline (if enabled) and captures pause state.
  const snap0 = await getGameStateSnapshot({
    publicClient,
    manifest,
    abiNetwork: cli.abiNetwork,
    preferOnchainLens: true,
    includeUserMarketDetails: false,
  });

  await achievements.onTick({
    snapshot: snap0,
    config: {
      enableTakeovers,
      enableFurnaceEntry,
    },
  });

  const results = await executeAgentPlan({
    plan: planResolved,
    publicClient,
    walletClient,
    privateWalletClient,
    privateRpcMode,
    account: actor.account,
    manifest,
    abiNetwork: cli.abiNetwork,
    contracts,
    execute: cli.execute,
    maxActions: cli.maxActions,
    stopOnError: true,
    onResult: async (r, idx) => {
      resultsWs.write(
        stringifyJson({
          idx,
          ts: Date.now(),
          action: r.action,
          simulated: r.simulated,
          hash: r.hash,
          receiptBlockNumber: r.receiptBlockNumber ? r.receiptBlockNumber.toString() : undefined,
          details: r.details,
          error: r.error,
        }) + '\n',
      );

      // Action-derived achievements + optional badge refresh after tx.
      achievements.onActionResult(r);

      // Tick after each action to drive badge polling (and any health checks).
      const snap = await getGameStateSnapshot({
        publicClient,
        manifest,
        abiNetwork: cli.abiNetwork,
        preferOnchainLens: true,
        includeUserMarketDetails: false,
      });

      await achievements.onTick({
        snapshot: snap,
        config: {
          enableTakeovers,
          enableFurnaceEntry,
        },
      });
    },
  });

  resultsWs.end();
  achievementsWs.end();

  const ok = results.every((r) => !r.error);

  const summary = {
    ok,
    execute: cli.execute,
    chain: cli.chain,
    chainId,
    derivedActor: agent,
    planAgent: plan.agent,
    actionsPlanned: plan.actions.length,
    actionsProcessed: results.length,
    outdir,
    resultsFile: resultsFp,
    achievementsFile: achievementsFp,
    ms: Date.now() - startedAt,
  };

  console.log(JSON.stringify(summary, null, cli.pretty ? 2 : 0));
}

main().catch((err) => {
  console.error(err);
  process.exit(1);
});
