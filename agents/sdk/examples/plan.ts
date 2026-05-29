import 'dotenv/config';

import { getAddress, isAddress, parseEther } from 'viem';

import type { Address } from 'viem';

import {
  buildActionPlan,
  createClaimRushClients,
  getClaimRushContracts,
  getDelegationSession,
  getGameStateSnapshot,
  loadDeploymentManifest,
  stringifyPlan,
  writePlanToFile,
} from '../src/index.js';

import type {
  PolicyCallerContext,
  PolicyDelegationContext,
  PolicyConfig,
} from '../src/agent/policy.js';
import type { AgentPlan } from '../src/agent/types.js';
import type { AbiNetwork } from '../src/abis.js';

import { DEFAULT_ANVIL_MNEMONIC, deriveActors } from '../src/harness/accounts.js';

type CliOpts = {
  rpcUrl: string;
  chain: string;
  abiNetwork: AbiNetwork;
  actorIndex?: number;

  /** Optional: manage this user identity via DelegationHub session. */
  actingForUser?: string;

  // Strategy toggles
  enableFurnaceEntry: boolean;
  enableTakeovers: boolean;
  enableRoyaltiesClaim: boolean;
  enableWithdrawals: boolean;

  // Strategy params
  furnaceEthIn?: string;
  lockDurationDays?: number;
  targetTokenId?: bigint;
  createAutoMax: boolean;
  slippageBps?: number;

  maxTakeoverEth?: string;
  takeoverCooldownSeconds?: number;

  minRoyaltiesEthToClaim?: string;
  minKingEthToWithdraw?: string;
  minRefundEthToWithdraw?: string;

  // Output
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

  out?: string;
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
ClaimRush agent plan builder

Builds an AgentPlan JSON (no tx). Intended for external agents/LLMs to:
- read snapshot elsewhere
- decide actions
- output a plan
- then execute the plan with example:execute-plan

Usage
  npm -C agents/sdk run example:plan -- [options]

Core
  --rpc-url <url>              HTTP RPC (default: RPC_URL or http://127.0.0.1:8545)
  --chain <name>               Manifest chain (default: CLAIMRUSH_CHAIN or local)
  --abi-network <name>         ABI folder (default: ABI_NETWORK or base_sepolia)
  --actor-index <n>            Which derived account to use (default: 0)

Delegation
  --acting-for <address>       Manage a user identity via DelegationHub (agent is the derived actor)

Strategies
  --enable-furnace-entry       Include a furnace entry action if no ve position exists
    --furnace-eth-in <eth>
    --lock-duration-days <n>   (default: 30)
    --slippage-bps <n>         (default: 50)
    --create-auto-max

  --enable-takeovers           Include a takeover action if price <= cap
    --max-takeover-eth <eth>
    --takeover-cooldown-seconds <n>

  --no-royalties-claim          Disable claiming shareholder ETH (default: enabled)
    --min-royalties-eth <eth>

  --no-withdrawals              Disable withdrawing MineCore balances (default: enabled)
    --min-king-eth <eth>
    --min-refund-eth <eth>

Output
  --out <path>                 Write plan JSON to this path
  --pretty                     Pretty-print JSON

Environment
  RPC_URL
  CLAIMRUSH_CHAIN
  ABI_NETWORK
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
  # Build a dry plan from the default policy
  npm -C agents/sdk run example:plan

  # Write a plan to a file
  npm -C agents/sdk run example:plan -- --out /tmp/plan.json --pretty
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

  const actingForUser = get('acting-for') ?? env.ACTING_FOR_USER;

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
  const targetTokenId = get('target-token-id')
    ? BigInt(get('target-token-id')!)
    : env.TARGET_TOKEN_ID
      ? BigInt(env.TARGET_TOKEN_ID)
      : undefined;

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

  const out = get('out') ?? env.PLAN_OUT;
  const pretty = has('pretty') || env.PRETTY === '1';

  return {
    rpcUrl,
    chain,
    abiNetwork,
    actorIndex,
    actingForUser,
    enableFurnaceEntry,
    enableTakeovers,
    enableRoyaltiesClaim,
    enableWithdrawals,
    furnaceEthIn,
    lockDurationDays,
    targetTokenId,
    createAutoMax,
    slippageBps,
    maxTakeoverEth,
    takeoverCooldownSeconds,
    minRoyaltiesEthToClaim,
    minKingEthToWithdraw,
    minRefundEthToWithdraw,
    enableSafeMaintenance,
    veExtendIfRemainingDays,
    veExtendByDays,
    kingAutoLockDesired,
    royaltiesAutoCompoundDesired,
    lpAutoCompoundDesired,
    out,
    pretty,
  };
}

function parseEthOrZero(v: string | undefined): bigint {
  if (!v) return 0n;
  const s = v.trim();
  if (!s) return 0n;
  if (Number(s) === 0) return 0n;
  return parseEther(s);
}

async function main(): Promise<void> {
  const argv = process.argv.slice(2);
  const cli = parseArgs(argv, process.env);

  const manifest = loadDeploymentManifest({ chain: cli.chain });
  const { publicClient } = createClaimRushClients({ rpcUrl: cli.rpcUrl });
  const chainId = await publicClient.getChainId();

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

  const actingForRaw = cli.actingForUser;
  if (actingForRaw && actingForRaw.trim() && !isAddress(actingForRaw)) {
    throw new Error(`Invalid actingForUser address: ${actingForRaw}`);
  }
  const user = actingForRaw && actingForRaw.trim() ? (getAddress(actingForRaw) as Address) : agent;
  const delegated = user.toLowerCase() !== agent.toLowerCase();

  const contracts = await getClaimRushContracts({
    publicClient,
    manifest,
    abiNetwork: cli.abiNetwork,
  });

  const lockDurationDays = cli.lockDurationDays ?? 30;
  const lockDurationSeconds = BigInt(lockDurationDays) * 24n * 60n * 60n;

  const veExtendIfRemainingSeconds =
    cli.veExtendIfRemainingDays != null
      ? BigInt(cli.veExtendIfRemainingDays) * 24n * 60n * 60n
      : undefined;
  const veExtendBySeconds =
    cli.veExtendByDays != null ? BigInt(cli.veExtendByDays) * 24n * 60n * 60n : undefined;

  const policyConfig: PolicyConfig = {
    agent,
    enableFurnaceEntry: cli.enableFurnaceEntry,
    enableTakeovers: cli.enableTakeovers,
    enableRoyaltiesClaim: cli.enableRoyaltiesClaim,
    enableWithdrawals: cli.enableWithdrawals,
    furnaceEthIn: parseEthOrZero(cli.furnaceEthIn),
    lockDurationSeconds,
    targetTokenId: cli.targetTokenId ?? 0n,
    createAutoMax: cli.createAutoMax,
    slippageBps: BigInt(cli.slippageBps ?? 50),
    maxTakeoverEth: parseEthOrZero(cli.maxTakeoverEth),
    takeoverCooldownSeconds: cli.takeoverCooldownSeconds ?? 60,
    minRoyaltiesEthToClaim: parseEthOrZero(cli.minRoyaltiesEthToClaim),
    minKingEthToWithdraw: parseEthOrZero(cli.minKingEthToWithdraw),
    minRefundEthToWithdraw: parseEthOrZero(cli.minRefundEthToWithdraw),

    enableSafeMaintenance: cli.enableSafeMaintenance,
    veExtendIfRemainingSeconds,
    veExtendBySeconds,
    kingAutoLockDesired: cli.kingAutoLockDesired,
    royaltiesAutoCompoundDesired: cli.royaltiesAutoCompoundDesired,
    lpAutoCompoundDesired: cli.lpAutoCompoundDesired,
  };

  const snap = await getGameStateSnapshot({
    publicClient,
    manifest,
    abiNetwork: cli.abiNetwork,
    user,
  });

  let caller: PolicyCallerContext | undefined;
  let delegation: PolicyDelegationContext | undefined;

  if (delegated) {
    const delegationHub = (manifest.contracts as any).DelegationHub?.address as Address | undefined;
    if (!delegationHub) {
      throw new Error('Delegated mode requires DelegationHub in the deployment manifest');
    }

    const callerEthBalance = await publicClient.getBalance({ address: agent });
    const mineCoreKingEthBalance = (await (contracts as any).MineCore.read.kingEthBalance([
      agent,
    ])) as bigint;
    const mineCoreRefundEthBalance = (await (contracts as any).MineCore.read.refundEthBalance([
      agent,
    ])) as bigint;

    caller = {
      address: agent,
      ethBalance: callerEthBalance,
      mineCoreKingEthBalance,
      mineCoreRefundEthBalance,
    };

    const session = await getDelegationSession({
      publicClient,
      delegationHub,
      user,
      delegate: agent,
      abiNetwork: cli.abiNetwork,
    });

    delegation = { user, delegate: agent, perms: session.perms, expiry: session.expiry };
  }

  const actions = buildActionPlan({
    snapshot: snap,
    config: policyConfig,
    state: {},
    caller,
    delegation,
  });
  const plan: AgentPlan = {
    chain: cli.chain,
    chainId,
    blockNumber: snap.meta.blockNumber,
    blockTimestamp: snap.meta.blockTimestamp,
    agent,
    actions,
  };

  if (cli.out) {
    writePlanToFile(cli.out, plan, { pretty: cli.pretty });
  }

  console.log(stringifyPlan(plan, { pretty: cli.pretty }));
}

main().catch((err) => {
  console.error(err);
  process.exit(1);
});
