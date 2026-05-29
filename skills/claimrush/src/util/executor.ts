import type { Account, Address, PublicClient, WalletClient } from 'viem';
import { createWalletClient, http } from 'viem';

import {
  createClaimRushClients,
  executeAgentPlan,
  getClaimRushContracts,
  loadDeploymentManifest,
} from '@claimrush/agent-sdk';
import type {
  AgentAction,
  AgentActionResult,
  AgentPlan,
} from '@claimrush/agent-sdk';

import { isChainName, resolveNetwork } from '../safety/networks.js';
import type { ChainName, ResolvedNetwork } from '../safety/networks.js';
import { applyCralGuards, appendReceipt, confirmMainnetIfNeeded, jsonStringify } from '../safety/cral.js';
import type { CralAction } from '../safety/cral.js';
import { permsForActionKind, requireLiveSession } from '../safety/preflight.js';
import { loadAgentAccount, parseActingFor, repoRoot } from './identity.js';
import { makeFlagBag } from './args.js';

export type WriteContext = {
  net: ResolvedNetwork;
  publicClient: PublicClient;
  walletClient: WalletClient;
  privateWalletClient?: WalletClient;
  privateRpcMode: 'off' | 'route' | 'only';
  account: Account;
  agent: Address;
  actingForUser?: Address;
  manifest: ReturnType<typeof loadDeploymentManifest>;
  contracts: Awaited<ReturnType<typeof getClaimRushContracts>>;
  chainId: number;
  blockNumber: bigint;
  blockTimestamp: bigint;
  execute: boolean;
  iUnderstand: boolean;
  pretty: boolean;
};

export type CommonFlags = {
  chain: ChainName;
  rpcUrl?: string;
  privateRpcUrl?: string;
  privateRpcMode?: 'off' | 'route' | 'only';
  actorIndex?: number;
  actingFor?: Address;
  execute: boolean;
  iUnderstand: boolean;
  pretty: boolean;
};

export function parseCommonFlags(argv: string[]): CommonFlags {
  const f = makeFlagBag(argv);
  const chainArg = f.get('chain') ?? process.env.CLAIMRUSH_CHAIN ?? 'local';
  if (!isChainName(chainArg)) {
    throw new Error(`invalid --chain '${chainArg}' (allowed: local | base_sepolia | base)`);
  }

  const privateRpcModeRaw = (f.get('private-rpc-mode') ?? process.env.PRIVATE_RPC_MODE ?? '').trim();
  const privateRpcMode: CommonFlags['privateRpcMode'] | undefined =
    privateRpcModeRaw === 'off' || privateRpcModeRaw === 'route' || privateRpcModeRaw === 'only'
      ? privateRpcModeRaw
      : undefined;

  return {
    chain: chainArg,
    rpcUrl: f.get('rpc-url') ?? undefined,
    privateRpcUrl: f.get('private-rpc-url') ?? process.env.PRIVATE_RPC_URL ?? undefined,
    privateRpcMode,
    actorIndex: f.get('actor-index') ? Number(f.get('actor-index')) : undefined,
    actingFor: parseActingFor(f.get('acting-for')),
    execute: f.has('execute'),
    iUnderstand: f.has('i-understand'),
    pretty: f.has('pretty'),
  };
}

/**
 * Build the full write-context (clients, manifests, contracts, chain head).
 *
 * This routes the RPC URL through `resolveNetwork` so the mainnet-allowlist
 * gate kicks in *before* any RPC call when the caller passes --execute.
 */
export async function buildWriteContext(common: CommonFlags): Promise<WriteContext> {
  // Static CRAL gate: refuse mainnet --execute without --i-understand BEFORE
  // we touch the filesystem (deployment manifest) or the RPC. The full guard
  // (including spend-cap validation) re-runs inside submitActions, but the
  // early check here keeps the "no RPC call" contract on the mainnet path.
  if (common.chain === 'base' && common.execute && !common.iUnderstand) {
    throw new Error(
      'mainnet (--chain base --execute) requires --i-understand. Refusing to send any RPC.',
    );
  }

  const net = resolveNetwork({
    chain: common.chain,
    rpcUrl: common.rpcUrl,
    requireAllowlistedRpc: common.execute && common.chain === 'base',
  });

  const manifest = loadDeploymentManifest({ chain: net.manifestStem });

  const { account, agent } = loadAgentAccount(common.actorIndex ?? 0);

  const { publicClient } = createClaimRushClients({ rpcUrl: net.rpcUrl, account });
  const walletClient = createWalletClient({ transport: http(net.rpcUrl), account });

  const privateRpcUrl = common.privateRpcUrl?.trim();
  const privateRpcMode: 'off' | 'route' | 'only' =
    privateRpcUrl && privateRpcUrl.length > 0 ? (common.privateRpcMode ?? 'route') : 'off';
  const privateWalletClient =
    privateRpcMode !== 'off' && privateRpcUrl
      ? createWalletClient({ transport: http(privateRpcUrl), account })
      : undefined;

  const contracts = await getClaimRushContracts({
    publicClient,
    manifest,
    abiNetwork: net.abiNetwork,
  });
  const chainId = await publicClient.getChainId();
  const head = await publicClient.getBlock({ blockTag: 'latest' });

  return {
    net,
    publicClient,
    walletClient,
    privateWalletClient,
    privateRpcMode,
    account,
    agent,
    actingForUser: common.actingFor,
    manifest,
    contracts,
    chainId,
    blockNumber: head.number ?? 0n,
    blockTimestamp: head.timestamp,
    execute: common.execute,
    iUnderstand: common.iUnderstand,
    pretty: common.pretty,
  };
}

export type SubmitOptions = {
  cralAction: CralAction;
  /** Spend cap (when applicable) for the CRAL guard. */
  spendCapWei?: bigint;
  spendCapKind?: 'takeover' | 'furnace' | 'other';
  slippageBps?: bigint;
  deadlineSeconds?: bigint;
  /** Pre-attempt notes that the receipt should record. */
  notes?: Record<string, unknown>;
  receiptName: string;
};

/**
 * Run an action plan through the SDK's executeAgentPlan, applying every CRAL
 * guard before sending. This is the single place writes go through.
 */
export async function submitActions(
  ctx: WriteContext,
  actions: AgentAction[],
  opts: SubmitOptions,
): Promise<{
  exitCode: number;
  receipt: Record<string, unknown>;
  results: AgentActionResult[];
}> {
  const guard = applyCralGuards({
    action: opts.cralAction,
    chain: ctx.net.chain,
    execute: ctx.execute,
    iUnderstand: ctx.iUnderstand,
    slippageBps: opts.slippageBps,
    spendCapWei: opts.spendCapWei,
    spendCapKind: opts.spendCapKind,
    deadlineSeconds: opts.deadlineSeconds,
    actingForUser: ctx.actingForUser,
  });
  if (!guard.ok) {
    const receipt = {
      ok: false,
      stage: 'cral-guard',
      reason: guard.reason,
      execute: ctx.execute,
      chain: ctx.net.chain,
      actions,
    };
    appendReceipt(repoRoot(), opts.receiptName, receipt);
    console.log(jsonStringify(receipt, ctx.pretty));
    return { exitCode: 65, receipt, results: [] };
  }

  // Delegated session precheck (one isAuthorized call per unique kind/user pair).
  if (ctx.actingForUser) {
    const hub = (ctx.manifest.contracts as any).DelegationHub?.address as Address | undefined;
    if (!hub) {
      const receipt = {
        ok: false,
        stage: 'delegation-precheck',
        reason: 'DelegationHub not found in manifest for this chain',
      };
      appendReceipt(repoRoot(), opts.receiptName, receipt);
      console.log(jsonStringify(receipt, ctx.pretty));
      return { exitCode: 66, receipt, results: [] };
    }
    for (const a of actions) {
      const required = permsForActionKind((a as any).kind);
      if (required === 0n) continue;
      const r = await requireLiveSession({
        publicClient: ctx.publicClient,
        delegationHub: hub,
        user: ctx.actingForUser,
        delegate: ctx.agent,
        requiredPerms: required,
        abiNetwork: ctx.net.abiNetwork,
      });
      if (!r.ok) {
        const receipt = {
          ok: false,
          stage: 'delegation-precheck',
          actionKind: (a as any).kind,
          reason: r.reason,
        };
        appendReceipt(repoRoot(), opts.receiptName, receipt);
        console.log(jsonStringify(receipt, ctx.pretty));
        return { exitCode: 66, receipt, results: [] };
      }
    }
  }

  const mainnetCheck = await confirmMainnetIfNeeded({
    chain: ctx.net.chain,
    execute: ctx.execute,
    spendWei: opts.spendCapWei,
  });
  if (!mainnetCheck.ok) {
    const receipt = {
      ok: false,
      stage: 'mainnet-confirm',
      reason: mainnetCheck.reason,
    };
    appendReceipt(repoRoot(), opts.receiptName, receipt);
    console.log(jsonStringify(receipt, ctx.pretty));
    return { exitCode: 66, receipt, results: [] };
  }

  const plan: AgentPlan = {
    chain: ctx.net.manifestStem,
    chainId: ctx.chainId,
    blockNumber: ctx.blockNumber,
    blockTimestamp: ctx.blockTimestamp,
    agent: ctx.agent,
    actions,
  };

  const results = await executeAgentPlan({
    plan,
    publicClient: ctx.publicClient,
    walletClient: ctx.walletClient,
    privateWalletClient: ctx.privateWalletClient,
    privateRpcMode: ctx.privateRpcMode,
    account: ctx.account,
    manifest: ctx.manifest,
    abiNetwork: ctx.net.abiNetwork,
    contracts: ctx.contracts,
    execute: ctx.execute,
  });

  const ok = results.every((r) => !r.error);
  const exitCode = ok ? 0 : 1;
  const receipt: Record<string, unknown> = {
    ok,
    stage: ctx.execute ? 'executed' : 'simulated',
    chain: ctx.net.chain,
    chainId: ctx.chainId,
    blockNumber: ctx.blockNumber.toString(),
    agent: ctx.agent,
    actingForUser: ctx.actingForUser,
    privateRpcMode: ctx.privateRpcMode,
    cralNotes: guard.notes,
    extra: opts.notes ?? {},
    actions,
    results: results.map((r) => ({
      actionKind: (r.action as any).kind,
      simulated: r.simulated,
      simReturn: serializeSimReturn(r),
      txHash: (r as any).hash ?? (r as any).txHash ?? null,
      txReceiptStatus: (r as any).txReceiptStatus ?? null,
      error: r.error
        ? {
            classification: (r.error as any).classification,
            shortMessage: (r.error as any).shortMessage,
            details: (r.error as any).details,
          }
        : null,
    })),
  };

  appendReceipt(repoRoot(), opts.receiptName, receipt);
  console.log(jsonStringify(receipt, ctx.pretty));
  return { exitCode, receipt, results };
}

function serializeSimReturn(r: AgentActionResult): unknown {
  const v = (r as any).simReturn;
  if (typeof v === 'bigint') return v.toString();
  if (Array.isArray(v)) return v.map((x) => (typeof x === 'bigint' ? x.toString() : x));
  return v ?? null;
}
