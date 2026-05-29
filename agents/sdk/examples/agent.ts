import 'dotenv/config';

import type { Address } from 'viem';
import { parseEther } from 'viem';

import { createPolicyStrategy, loadStrategiesFromModules, runLiveAgent } from '../src/index.js';

type CliOpts = {
  rpcUrl: string;

  // Optional local HTTP monitor endpoint
  monitorEnabled: boolean;
  monitorHost?: string;
  monitorPort?: number;
  monitorToken?: string;
  monitorMaxRecent?: number;

  // Optional private tx RPC (MEV-sensitive txs only)
  privateRpcUrl?: string;
  privateRpcMode?: 'off' | 'route' | 'only';
  chain: string;
  abiNetwork: any;
  actorIndex?: number;

  /** Optional: manage this user identity via DelegationHub session. */
  actingForUser?: string;

  execute: boolean;
  once: boolean;
  tickSeconds?: number;
  maxActionsPerTick?: number;

  useEvents: boolean;
  eventPolling: boolean;

  subgraphUrl?: string;
  eventBackfill: boolean;
  eventBackfillLimit?: number;

  // Achievements API (optional)
  achievementsBaseUrl?: string;
  achievementsPollIntervalMs?: number;
  achievementsForceRefreshCooldownMs?: number;
  achievementsFetchTimeoutMs?: number;

  // Strategy plugins (optional)
  strategyModules: string[];
  includePolicyStrategy: boolean;
  policyStrategyPriority?: number;

  enableFurnaceEntry: boolean;
  furnaceEthIn?: string;
  lockDurationDays?: number;
  slippageBps?: number;
  createAutoMax: boolean;
  targetTokenId?: bigint;

  enableTakeovers: boolean;
  maxTakeoverEth?: string;
  takeoverCooldownSeconds?: number;

  enableRoyaltiesClaim: boolean;
  minRoyaltiesEthToClaim?: string;

  enableWithdrawals: boolean;
  minKingEthToWithdraw?: string;
  minRefundEthToWithdraw?: string;

  // Delegated safe maintenance (optional)
  enableSafeMaintenance: boolean;
  veExtendIfRemainingDays?: number;
  veExtendByDays?: number;

  // Optional: desired config sync (delegated-only)
  kingAutoLockDesired?: {
    enabled: boolean;
    targetTokenId: bigint;
    durationSeconds: bigint;
    createAutoMax: boolean;
    minVeOut: bigint;
  };
  royaltiesAutoCompoundDesired?: {
    enabled: boolean;
    tokenId: bigint;
    durationSeconds: bigint;
    minCadenceSeconds: bigint;
    minEthToCompound: bigint;
  };
  lpAutoCompoundDesired?: {
    enabled: boolean;
    tokenId: bigint;
    durationSeconds: bigint;
  };

  discordWebhookUrl?: string;

  outdir?: string;
  writeArtifacts: boolean;
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

    return out;
  };

  const has = (flag: string): boolean => argv.includes(`--${flag}`);

  const help = has('help') || argv.includes('-h');
  if (help) {
    console.log(`
ClaimRush live agent loop

Default is DRY-RUN (no tx). Use --execute to send tx.

Usage
  npm -C agents/sdk run example:agent -- [options]

Core
  --rpc-url <url>              HTTP RPC (default: RPC_URL or http://127.0.0.1:8545)
  --chain <name>               Manifest chain (default: CLAIMRUSH_CHAIN or local)
  --abi-network <name>         ABI folder (default: ABI_NETWORK or base_sepolia)
  --actor-index <n>            Which derived account to use (default: 0)

Private RPC (optional)
  --private-rpc-url <url>       Private tx RPC endpoint (default: PRIVATE_RPC_URL)
  --private-rpc-mode <mode>     off|route|only (default: route if url set)

Monitor (optional)
  --monitor                     Enable the local monitor server (default: off)
  --monitor-host <host>          Bind host (default: AGENT_MONITOR_HOST or 127.0.0.1)
  --monitor-port <n>             Port (default: AGENT_MONITOR_PORT or 8787)
  --monitor-token <token>        Bearer token (default: AGENT_MONITOR_TOKEN)
  --monitor-max-recent <n>       Max items kept per ring (default: AGENT_MONITOR_MAX_RECENT or 200)

Delegation
  --acting-for <address>       Manage a user identity via DelegationHub (agent is the derived actor)

Loop
  --execute                    Actually send tx (default: off)
  --once                       Run one decision cycle and exit
  --tick-seconds <n>           Poll interval (default: 10)
  --max-actions <n>            Max actions per cycle (default: 1)

Events
  --no-events                  Disable event wakeups (pure polling)
  --event-polling              Force polling mode (default: on)
  --no-event-polling           Prefer WS/subscription mode

Subgraph
  --subgraph-url <url>         Subgraph GraphQL endpoint (default: SUBGRAPH_URL)
  --event-backfill             Emit recent events from subgraph on startup
  --event-backfill-limit <n>   Max events per type (default: 100)

Achievements (optional)
  --achievements-base-url <url>        Base URL for /api/achievements (default: ACHIEVEMENTS_BASE_URL)
  --achievements-poll-ms <n>           Poll interval ms (default: ACHIEVEMENTS_POLL_MS or 20000)
  --achievements-refresh-cooldown-ms <n>  Debounce forced refresh after tx (default: ACHIEVEMENTS_REFRESH_COOLDOWN_MS or 5000)
  --achievements-timeout-ms <n>        Fetch timeout ms (default: ACHIEVEMENTS_TIMEOUT_MS or 10000)

Strategy plugins (optional)
  --strategy-module <path>            Load AgentStrategy plugins from an ESM module (repeatable)
  --include-policy-strategy           Also run the built-in policy as a low-priority fallback
  --policy-strategy-priority <n>      Priority for policy fallback (default: -100)

Strategies (safe by default)
  --enable-furnace-entry       Allow spending ETH to create ve
    --furnace-eth-in <eth>     ETH to spend on furnace entry
    --lock-duration-days <n>   ve lock duration (default: 30)
    --slippage-bps <n>         Slippage in bps (default: 50)
    --create-auto-max          Enable auto-max lock

  --enable-takeovers           Allow spending ETH to takeover
    --max-takeover-eth <eth>   Max takeover price you're willing to pay
    --takeover-cooldown-seconds <n>  Cooldown between takeover attempts (default: 60)

  --no-royalties-claim          Disable claiming shareholder ETH (default: enabled)
    --min-royalties-eth <eth>  Minimum claimable ETH before claiming (default: 0)

  --no-withdrawals              Disable withdrawing MineCore balances (default: enabled)
    --min-king-eth <eth>        Minimum king balance before withdrawing (default: 0)
    --min-refund-eth <eth>      Minimum refund balance before withdrawing (default: 0)

Delegated safe maintenance (optional)
  --enable-safe-maintenance      Enable low-risk delegated maintenance actions
    --ve-extend-if-remaining-days <n>  Refresh/extend when <n days remaining (default: 7)
    --ve-extend-by-days <n>            Extend by <n> days (default: 30)

Config sync (delegated-only; optional)
  # If you provide any of these flags (or env vars), the agent will try to sync them.
  --king-autolock-enabled <0|1>
    --king-autolock-target-token-id <id>     (default: 0)
    --king-autolock-duration-days <n>        (default: lock-duration-days)
    --king-autolock-create-auto-max
    --king-autolock-min-ve-out <n>           (default: 0)

  --royalties-autocompound-enabled <0|1>
    --royalties-autocompound-token-id <id|active>   (default: active)
    --royalties-autocompound-duration-days <n>      (default: lock-duration-days)
    --royalties-autocompound-min-cadence-seconds <n> (default: 3600)
    --royalties-autocompound-min-eth-to-compound <eth> (default: 0.01)

  --lp-autocompound-enabled <0|1>
    --lp-autocompound-token-id <id|active>    (default: active)
    --lp-autocompound-duration-days <n>       (default: lock-duration-days)


Discord
  --discord-webhook-url <url>  Discord webhook for notifications (default: DISCORD_WEBHOOK_URL)

Output
  --outdir <path>              Write artifacts here (default: agents/sdk/out/agent-<ts>)
  --no-write-artifacts         Disable artifact writing

Environment
  RPC_URL
  CLAIMRUSH_CHAIN
  ABI_NETWORK
  PRIVATE_RPC_URL
  PRIVATE_RPC_MODE
  AGENT_MONITOR_ENABLED
  AGENT_MONITOR_HOST
  AGENT_MONITOR_PORT
  AGENT_MONITOR_TOKEN
  AGENT_MONITOR_MAX_RECENT
  ACHIEVEMENTS_BASE_URL
  ACHIEVEMENTS_POLL_MS
  ACHIEVEMENTS_REFRESH_COOLDOWN_MS
  ACHIEVEMENTS_TIMEOUT_MS
  DISCORD_WEBHOOK_URL
  STRATEGY_MODULES
  INCLUDE_POLICY_STRATEGY
  POLICY_STRATEGY_PRIORITY
  MNEMONIC or LOCAL_MNEMONIC
  PRIVATE_KEYS or PRIVATE_KEY
  ACTING_FOR_USER
  ENABLE_SAFE_MAINTENANCE
  VE_EXTEND_IF_REMAINING_DAYS
  VE_EXTEND_BY_DAYS
  KING_AUTO_LOCK_ENABLED
  KING_AUTO_LOCK_TARGET_TOKEN_ID
  KING_AUTO_LOCK_DURATION_DAYS
  KING_AUTO_LOCK_CREATE_AUTO_MAX
  KING_AUTO_LOCK_MIN_VE_OUT
  ROYALTIES_AUTOCOMPOUND_ENABLED
  ROYALTIES_AUTOCOMPOUND_TOKEN_ID
  ROYALTIES_AUTOCOMPOUND_DURATION_DAYS
  ROYALTIES_AUTOCOMPOUND_MIN_CADENCE_SECONDS
  ROYALTIES_AUTOCOMPOUND_MIN_ETH_TO_COMPOUND
  LP_AUTOCOMPOUND_ENABLED
  LP_AUTOCOMPOUND_TOKEN_ID
  LP_AUTOCOMPOUND_DURATION_DAYS

Examples
  # Dry run (prints next action)
  npm -C agents/sdk run example:agent

  # Actually claim+withdraw if available
  RPC_URL=http://127.0.0.1:8545 npm -C agents/sdk run example:agent -- --execute

  # Enable takeovers with a hard cap
  npm -C agents/sdk run example:agent -- --enable-takeovers --max-takeover-eth 0.01 --execute

  # Ensure a ve lock
  npm -C agents/sdk run example:agent -- --enable-furnace-entry --furnace-eth-in 1000 --execute
`);
    process.exit(0);
  }

  const rpcUrl = get('rpc-url') ?? env.RPC_URL ?? 'http://127.0.0.1:8545';
  const chain = get('chain') ?? env.CLAIMRUSH_CHAIN ?? 'local';
  const abiNetwork = (get('abi-network') ?? env.ABI_NETWORK ?? 'base_sepolia') as any;
  const actorIndex = get('actor-index')
    ? Number(get('actor-index'))
    : env.ACTOR_INDEX
      ? Number(env.ACTOR_INDEX)
      : undefined;

  const monitorEnabled = has('monitor') || env.AGENT_MONITOR_ENABLED === '1';
  const monitorHost = get('monitor-host') ?? env.AGENT_MONITOR_HOST;
  const monitorPort = get('monitor-port')
    ? Number(get('monitor-port'))
    : env.AGENT_MONITOR_PORT
      ? Number(env.AGENT_MONITOR_PORT)
      : undefined;
  const monitorToken = get('monitor-token') ?? env.AGENT_MONITOR_TOKEN;
  const monitorMaxRecent = get('monitor-max-recent')
    ? Number(get('monitor-max-recent'))
    : env.AGENT_MONITOR_MAX_RECENT
      ? Number(env.AGENT_MONITOR_MAX_RECENT)
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

  const actingForUser = get('acting-for') ?? env.ACTING_FOR_USER;

  const execute = has('execute') ? true : env.EXECUTE === '1';
  const once = has('once') ? true : env.ONCE === '1';

  const tickSeconds = get('tick-seconds')
    ? Number(get('tick-seconds'))
    : env.TICK_SECONDS
      ? Number(env.TICK_SECONDS)
      : undefined;
  const maxActionsPerTick = get('max-actions')
    ? Number(get('max-actions'))
    : env.MAX_ACTIONS_PER_TICK
      ? Number(env.MAX_ACTIONS_PER_TICK)
      : undefined;

  const useEvents = has('no-events') ? false : true;
  const eventPolling = has('no-event-polling') ? false : true;

  const subgraphUrl = get('subgraph-url') ?? env.SUBGRAPH_URL;
  const eventBackfill = has('event-backfill') || env.EVENT_BACKFILL === '1';
  const eventBackfillLimit = get('event-backfill-limit')
    ? Number(get('event-backfill-limit'))
    : env.EVENT_BACKFILL_LIMIT
      ? Number(env.EVENT_BACKFILL_LIMIT)
      : undefined;
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

  const strategyModules = [
    ...getAll('strategy-module'),
    ...(env.STRATEGY_MODULES
      ? env.STRATEGY_MODULES.split(',')
          .map((s) => s.trim())
          .filter(Boolean)
      : []),
  ];

  const includePolicyStrategy =
    has('include-policy-strategy') || env.INCLUDE_POLICY_STRATEGY === '1';

  const policyStrategyPriorityRaw = get('policy-strategy-priority') ?? env.POLICY_STRATEGY_PRIORITY;
  const policyStrategyPriority = policyStrategyPriorityRaw
    ? Number(policyStrategyPriorityRaw)
    : undefined;

  const enableFurnaceEntry = has('enable-furnace-entry') || env.ENABLE_FURNACE_ENTRY === '1';
  const furnaceEthIn = get('furnace-eth-in') ?? env.FURNACE_ETH_IN;
  const lockDurationDays = get('lock-duration-days')
    ? Number(get('lock-duration-days'))
    : env.LOCK_DURATION_DAYS
      ? Number(env.LOCK_DURATION_DAYS)
      : undefined;
  const slippageBps = get('slippage-bps')
    ? Number(get('slippage-bps'))
    : env.SLIPPAGE_BPS
      ? Number(env.SLIPPAGE_BPS)
      : undefined;
  const createAutoMax = has('create-auto-max') || env.CREATE_AUTO_MAX === '1';

  const enableTakeovers = has('enable-takeovers') || env.ENABLE_TAKEOVERS === '1';
  const maxTakeoverEth = get('max-takeover-eth') ?? env.MAX_TAKEOVER_ETH;
  const takeoverCooldownSeconds = get('takeover-cooldown-seconds')
    ? Number(get('takeover-cooldown-seconds'))
    : env.TAKEOVER_COOLDOWN_SECONDS
      ? Number(env.TAKEOVER_COOLDOWN_SECONDS)
      : undefined;

  const enableRoyaltiesClaim = has('no-royalties-claim')
    ? false
    : env.ENABLE_ROYALTIES_CLAIM
      ? env.ENABLE_ROYALTIES_CLAIM === '1'
      : true;
  const minRoyaltiesEthToClaim = get('min-royalties-eth') ?? env.MIN_ROYALTIES_ETH;

  const enableWithdrawals = has('no-withdrawals')
    ? false
    : env.ENABLE_WITHDRAWALS
      ? env.ENABLE_WITHDRAWALS === '1'
      : true;
  const minKingEthToWithdraw = get('min-king-eth') ?? env.MIN_KING_ETH;
  const minRefundEthToWithdraw = get('min-refund-eth') ?? env.MIN_REFUND_ETH;

  // Delegated safe maintenance (optional)
  const enableSafeMaintenance =
    has('enable-safe-maintenance') || env.ENABLE_SAFE_MAINTENANCE === '1';
  const veExtendIfRemainingDays = get('ve-extend-if-remaining-days')
    ? Number(get('ve-extend-if-remaining-days'))
    : env.VE_EXTEND_IF_REMAINING_DAYS
      ? Number(env.VE_EXTEND_IF_REMAINING_DAYS)
      : undefined;
  const veExtendByDays = get('ve-extend-by-days')
    ? Number(get('ve-extend-by-days'))
    : env.VE_EXTEND_BY_DAYS
      ? Number(env.VE_EXTEND_BY_DAYS)
      : undefined;

  const parseBoolish = (v: string): boolean => {
    const s = v.trim().toLowerCase();
    if (s === '1' || s === 'true' || s === 'yes') return true;
    if (s === '0' || s === 'false' || s === 'no') return false;
    throw new Error(`Invalid boolean value: ${v}`);
  };

  const parseTokenIdSpec = (v: string): bigint => {
    const s = v.trim().toLowerCase();
    if (s === 'active') return 0n;
    return BigInt(s);
  };

  const secsFromDays = (days: number): bigint => BigInt(days) * 24n * 60n * 60n;

  // Optional: desired config sync (delegated-only)
  // MineCore king auto-lock
  const kingAutoLockEnabledRaw = get('king-autolock-enabled') ?? env.KING_AUTO_LOCK_ENABLED;
  const kingAutoLockTargetTokenIdRaw =
    get('king-autolock-target-token-id') ?? env.KING_AUTO_LOCK_TARGET_TOKEN_ID;
  const kingAutoLockDurationDaysRaw =
    get('king-autolock-duration-days') ?? env.KING_AUTO_LOCK_DURATION_DAYS;
  const kingAutoLockMinVeOutRaw = get('king-autolock-min-ve-out') ?? env.KING_AUTO_LOCK_MIN_VE_OUT;
  const kingAutoLockCreateAutoMax =
    has('king-autolock-create-auto-max') || env.KING_AUTO_LOCK_CREATE_AUTO_MAX === '1';

  const wantsKingAutoLock = Boolean(
    kingAutoLockEnabledRaw ||
    kingAutoLockTargetTokenIdRaw ||
    kingAutoLockDurationDaysRaw ||
    kingAutoLockMinVeOutRaw ||
    kingAutoLockCreateAutoMax,
  );

  const kingAutoLockDesired = wantsKingAutoLock
    ? {
        enabled: kingAutoLockEnabledRaw ? parseBoolish(kingAutoLockEnabledRaw) : true,
        targetTokenId: kingAutoLockTargetTokenIdRaw ? BigInt(kingAutoLockTargetTokenIdRaw) : 0n,
        durationSeconds: secsFromDays(
          kingAutoLockDurationDaysRaw
            ? Number(kingAutoLockDurationDaysRaw)
            : (lockDurationDays ?? 30),
        ),
        createAutoMax: kingAutoLockCreateAutoMax,
        minVeOut: kingAutoLockMinVeOutRaw ? BigInt(kingAutoLockMinVeOutRaw) : 0n,
      }
    : undefined;

  // ShareholderRoyalties auto-compound
  const royaltiesEnabledRaw =
    get('royalties-autocompound-enabled') ?? env.ROYALTIES_AUTOCOMPOUND_ENABLED;
  const royaltiesTokenIdRaw =
    get('royalties-autocompound-token-id') ?? env.ROYALTIES_AUTOCOMPOUND_TOKEN_ID;
  const royaltiesDurationDaysRaw =
    get('royalties-autocompound-duration-days') ?? env.ROYALTIES_AUTOCOMPOUND_DURATION_DAYS;
  const royaltiesMinCadenceRaw =
    get('royalties-autocompound-min-cadence-seconds') ??
    env.ROYALTIES_AUTOCOMPOUND_MIN_CADENCE_SECONDS;
  const royaltiesMinEthRaw =
    get('royalties-autocompound-min-eth-to-compound') ??
    env.ROYALTIES_AUTOCOMPOUND_MIN_ETH_TO_COMPOUND;

  const wantsRoyaltiesAutoCompound = Boolean(
    royaltiesEnabledRaw ||
    royaltiesTokenIdRaw ||
    royaltiesDurationDaysRaw ||
    royaltiesMinCadenceRaw ||
    royaltiesMinEthRaw,
  );

  const royaltiesAutoCompoundDesired = wantsRoyaltiesAutoCompound
    ? {
        enabled: royaltiesEnabledRaw ? parseBoolish(royaltiesEnabledRaw) : true,
        tokenId: royaltiesTokenIdRaw ? parseTokenIdSpec(royaltiesTokenIdRaw) : 0n,
        durationSeconds: secsFromDays(
          royaltiesDurationDaysRaw ? Number(royaltiesDurationDaysRaw) : (lockDurationDays ?? 30),
        ),
        minCadenceSeconds: BigInt(royaltiesMinCadenceRaw ? Number(royaltiesMinCadenceRaw) : 3600),
        minEthToCompound: royaltiesMinEthRaw ? parseEther(royaltiesMinEthRaw) : parseEther('0.01'),
      }
    : undefined;

  // LP vault auto-compound
  const lpEnabledRaw = get('lp-autocompound-enabled') ?? env.LP_AUTOCOMPOUND_ENABLED;
  const lpTokenIdRaw = get('lp-autocompound-token-id') ?? env.LP_AUTOCOMPOUND_TOKEN_ID;
  const lpDurationDaysRaw =
    get('lp-autocompound-duration-days') ?? env.LP_AUTOCOMPOUND_DURATION_DAYS;

  const wantsLpAutoCompound = Boolean(lpEnabledRaw || lpTokenIdRaw || lpDurationDaysRaw);

  const lpAutoCompoundDesired = wantsLpAutoCompound
    ? {
        enabled: lpEnabledRaw ? parseBoolish(lpEnabledRaw) : true,
        tokenId: lpTokenIdRaw ? parseTokenIdSpec(lpTokenIdRaw) : 0n,
        durationSeconds: secsFromDays(
          lpDurationDaysRaw ? Number(lpDurationDaysRaw) : (lockDurationDays ?? 30),
        ),
      }
    : undefined;

  const discordWebhookUrl = get('discord-webhook-url') ?? env.DISCORD_WEBHOOK_URL;

  const writeArtifacts = has('no-write-artifacts') ? false : true;
  const outdir = get('outdir') ?? env.OUTDIR;

  return {
    rpcUrl,
    monitorEnabled,
    monitorHost,
    monitorPort,
    monitorToken,
    monitorMaxRecent,
    privateRpcUrl,
    privateRpcMode,
    chain,
    abiNetwork,
    actorIndex,
    actingForUser,
    execute,
    once,
    tickSeconds,
    maxActionsPerTick,
    useEvents,
    eventPolling,
    subgraphUrl,
    eventBackfill,
    eventBackfillLimit,
    achievementsBaseUrl,
    achievementsPollIntervalMs,
    achievementsForceRefreshCooldownMs,
    achievementsFetchTimeoutMs,
    strategyModules,
    includePolicyStrategy,
    policyStrategyPriority,
    enableFurnaceEntry,
    furnaceEthIn,
    lockDurationDays,
    slippageBps,
    createAutoMax,
    enableTakeovers,
    maxTakeoverEth,
    takeoverCooldownSeconds,
    enableRoyaltiesClaim,
    minRoyaltiesEthToClaim,
    enableWithdrawals,
    minKingEthToWithdraw,
    minRefundEthToWithdraw,
    enableSafeMaintenance,
    veExtendIfRemainingDays,
    veExtendByDays,
    kingAutoLockDesired,
    royaltiesAutoCompoundDesired,
    lpAutoCompoundDesired,
    discordWebhookUrl,
    outdir,
    writeArtifacts,
  };
}

async function main(): Promise<void> {
  const argv = process.argv.slice(2);
  const cli = parseArgs(argv, process.env);

  const wantsStrategies = cli.strategyModules.length > 0 || cli.includePolicyStrategy;
  const strategies = wantsStrategies
    ? [
        ...(await loadStrategiesFromModules(cli.strategyModules)),
        ...(cli.includePolicyStrategy
          ? [createPolicyStrategy({ priority: cli.policyStrategyPriority ?? -100 })]
          : []),
      ]
    : undefined;

  const res = await runLiveAgent({
    rpcUrl: cli.rpcUrl,
    monitorEnabled: cli.monitorEnabled,
    monitorHost: cli.monitorHost,
    monitorPort: cli.monitorPort,
    monitorToken: cli.monitorToken,
    monitorMaxRecent: cli.monitorMaxRecent,
    privateRpcUrl: cli.privateRpcUrl,
    privateRpcMode: cli.privateRpcMode,
    chain: cli.chain,
    abiNetwork: cli.abiNetwork,
    actorIndex: cli.actorIndex,
    actingForUser: cli.actingForUser ? (cli.actingForUser as Address) : undefined,
    execute: cli.execute,
    once: cli.once,
    tickSeconds: cli.tickSeconds,
    maxActionsPerTick: cli.maxActionsPerTick,
    useEvents: cli.useEvents,
    eventPolling: cli.eventPolling,
    subgraphUrl: cli.subgraphUrl,
    eventBackfill: cli.eventBackfill,
    eventBackfillLimit: cli.eventBackfillLimit,
    achievementsBaseUrl: cli.achievementsBaseUrl,
    achievementsPollIntervalMs: cli.achievementsPollIntervalMs,
    achievementsForceRefreshCooldownMs: cli.achievementsForceRefreshCooldownMs,
    achievementsFetchTimeoutMs: cli.achievementsFetchTimeoutMs,
    strategies,
    enableFurnaceEntry: cli.enableFurnaceEntry,
    furnaceEthIn: cli.furnaceEthIn,
    lockDurationDays: cli.lockDurationDays,
    slippageBps: cli.slippageBps,
    createAutoMax: cli.createAutoMax,
    enableTakeovers: cli.enableTakeovers,
    maxTakeoverEth: cli.maxTakeoverEth,
    takeoverCooldownSeconds: cli.takeoverCooldownSeconds,
    enableRoyaltiesClaim: cli.enableRoyaltiesClaim,
    minRoyaltiesEthToClaim: cli.minRoyaltiesEthToClaim,
    enableWithdrawals: cli.enableWithdrawals,
    minKingEthToWithdraw: cli.minKingEthToWithdraw,
    minRefundEthToWithdraw: cli.minRefundEthToWithdraw,
    enableSafeMaintenance: cli.enableSafeMaintenance,
    veExtendIfRemainingDays: cli.veExtendIfRemainingDays,
    veExtendByDays: cli.veExtendByDays,
    kingAutoLockDesired: cli.kingAutoLockDesired,
    royaltiesAutoCompoundDesired: cli.royaltiesAutoCompoundDesired,
    lpAutoCompoundDesired: cli.lpAutoCompoundDesired,
    discordWebhookUrl: cli.discordWebhookUrl,
    outdir: cli.outdir,
    writeArtifacts: cli.writeArtifacts,
  });

  console.log(
    JSON.stringify(
      {
        ok: res.ok,
        chain: res.chain,
        chainId: res.chainId,
        agent: res.agent,
        user: res.user,
        outdir: res.outdir,
      },
      null,
      2,
    ),
  );
}

main().catch((err) => {
  console.error(err);
  process.exit(1);
});
