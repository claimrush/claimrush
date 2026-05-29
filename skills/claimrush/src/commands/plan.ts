import path from 'node:path';

import { createWalletClient, getAddress, http } from 'viem';
import type { Address } from 'viem';

import {
  buildActionPlan,
  createClaimRushClients,
  executeAgentPlan,
  getClaimRushContracts,
  getDelegationSession,
  getGameStateSnapshot,
  loadDeploymentManifest,
  readPlanFromFile,
  stringifyPlan,
  writePlanToFile,
} from '@claimrush/agent-sdk';
import type { AgentAction, AgentPlan } from '@claimrush/agent-sdk';

import { helpRequested, makeFlagBag } from '../util/args.js';
import { isChainName, resolveNetwork } from '../safety/networks.js';
import { applyCralGuards, appendReceipt, jsonStringify, parseEthStrict } from '../safety/cral.js';
import { loadAgentAccount, parseActingFor, repoRoot } from '../util/identity.js';
import { permsForActionKind, requireLiveSession } from '../safety/preflight.js';

const HELP = `claimrush plan - AgentPlan v1: build or execute

USAGE
  claimrush plan build  [strategy toggles + caps] [--out path] [--pretty]
  claimrush plan execute --plan path [--max-actions N] [--execute]

BUILD
  Mirrors example:plan. Output is an AgentPlan JSON that any executor (the SDK
  example or 'claimrush plan execute') can run later.

EXECUTE
  Runs the actions in the plan. Dry-run by default; pass --execute to send.
  Mainnet additionally requires --i-understand.

COMMON
  --chain / --rpc-url / --acting-for / --pretty
`;

export async function runPlan(argv: string[]): Promise<number> {
  if (helpRequested(argv) || argv.length === 0) {
    console.log(HELP);
    return 0;
  }
  const sub = String(argv[0]);
  const rest = argv.slice(1);
  const f = makeFlagBag(rest);

  const chainArg = f.get('chain') ?? process.env.CLAIMRUSH_CHAIN ?? 'local';
  if (!isChainName(chainArg)) {
    console.error(`[plan] invalid --chain '${chainArg}'`);
    return 64;
  }

  if (sub === 'build') return await runBuild(rest, chainArg, f);
  if (sub === 'execute') return await runExecute(rest, chainArg, f);
  console.error(`[plan] unknown subcommand: ${sub}`);
  console.error(HELP);
  return 64;
}

async function runBuild(
  _argv: string[],
  chainArg: 'local' | 'base_sepolia' | 'base',
  f: ReturnType<typeof makeFlagBag>,
): Promise<number> {
  const net = resolveNetwork({ chain: chainArg, rpcUrl: f.get('rpc-url') });
  const manifest = loadDeploymentManifest({ chain: net.manifestStem });
  const { account, agent } = loadAgentAccount(
    f.get('actor-index') ? Number(f.get('actor-index')) : 0,
  );
  const { publicClient } = createClaimRushClients({ rpcUrl: net.rpcUrl, account });

  const actingForUser = parseActingFor(f.get('acting-for'));
  const subject: Address = actingForUser ?? (getAddress(agent) as Address);

  const snapshot = await getGameStateSnapshot({
    publicClient,
    manifest,
    abiNetwork: net.abiNetwork,
    user: subject,
  });

  const lockDurationDays = f.get('lock-duration-days') ? Number(f.get('lock-duration-days')) : 30;
  const lockDurationSeconds = BigInt(Math.floor(lockDurationDays * 86_400));

  // Belt-and-braces CRAL: parse strict if values are passed.
  const furnaceEthIn = f.get('furnace-eth-in');
  const maxTakeoverEth = f.get('max-takeover-eth');
  if (furnaceEthIn) parseEthStrict(furnaceEthIn, 'furnace-eth-in');
  if (maxTakeoverEth) parseEthStrict(maxTakeoverEth, 'max-takeover-eth');

  const policyConfig = {
    agent,
    enableFurnaceEntry: f.has('enable-furnace-entry'),
    enableTakeovers: f.has('enable-takeovers'),
    enableRoyaltiesClaim: f.has('enable-royalties-claim'),
    enableWithdrawals: f.has('enable-withdrawals'),
    furnaceEthIn: furnaceEthIn ? parseEthStrict(furnaceEthIn, 'furnace-eth-in') : 0n,
    lockDurationSeconds,
    targetTokenId: f.get('target-token-id') ? BigInt(f.get('target-token-id') as string) : 0n,
    createAutoMax: f.has('auto-max'),
    slippageBps: BigInt(f.get('slippage-bps') ?? 50),
    maxTakeoverEth: maxTakeoverEth ? parseEthStrict(maxTakeoverEth, 'max-takeover-eth') : 0n,
    takeoverCooldownSeconds: f.get('takeover-cooldown-seconds')
      ? Number(f.get('takeover-cooldown-seconds'))
      : 60,
    minRoyaltiesEthToClaim: f.get('min-royalties-eth-to-claim')
      ? parseEthStrict(f.get('min-royalties-eth-to-claim') as string, 'min-royalties-eth-to-claim')
      : 0n,
    minKingEthToWithdraw: f.get('min-king-eth-to-withdraw')
      ? parseEthStrict(f.get('min-king-eth-to-withdraw') as string, 'min-king-eth-to-withdraw')
      : 0n,
    minRefundEthToWithdraw: f.get('min-refund-eth-to-withdraw')
      ? parseEthStrict(f.get('min-refund-eth-to-withdraw') as string, 'min-refund-eth-to-withdraw')
      : 0n,
  } as any;

  let caller: any;
  let delegation: any;
  if (actingForUser) {
    const hub = (manifest.contracts as any).DelegationHub?.address as Address | undefined;
    if (!hub) throw new Error('Delegated mode requires DelegationHub in deployments');
    const callerEth = await publicClient.getBalance({ address: agent });
    const session = await getDelegationSession({
      publicClient,
      delegationHub: hub,
      user: actingForUser,
      delegate: agent,
      abiNetwork: net.abiNetwork,
    });
    caller = { address: agent, ethBalance: callerEth };
    delegation = {
      user: actingForUser,
      delegate: agent,
      perms: session.perms,
      expiry: session.expiry,
    };
  }

  const actions: AgentAction[] = buildActionPlan({
    snapshot,
    config: policyConfig,
    state: {},
    caller,
    delegation,
  });

  const chainId = await publicClient.getChainId();
  const plan: AgentPlan = {
    chain: net.manifestStem,
    chainId,
    blockNumber: (snapshot as any).meta?.blockNumber ?? 0n,
    blockTimestamp: (snapshot as any).meta?.blockTimestamp ?? 0n,
    agent,
    actions,
  };

  const out = f.get('out');
  if (out) {
    writePlanToFile(out, plan, { pretty: f.has('pretty') });
    console.error(`[plan build] wrote: ${out}`);
  }
  console.log(stringifyPlan(plan, { pretty: f.has('pretty') }));
  return 0;
}

async function runExecute(
  _argv: string[],
  chainArg: 'local' | 'base_sepolia' | 'base',
  f: ReturnType<typeof makeFlagBag>,
): Promise<number> {
  const planPath = f.get('plan');
  if (!planPath) {
    console.error('[plan execute] --plan <path> required');
    return 64;
  }
  const execute = f.has('execute');
  const iUnderstand = f.has('i-understand');

  const net = resolveNetwork({
    chain: chainArg,
    rpcUrl: f.get('rpc-url'),
    requireAllowlistedRpc: execute && chainArg === 'base',
  });

  const manifest = loadDeploymentManifest({ chain: net.manifestStem });
  const { account, agent } = loadAgentAccount(
    f.get('actor-index') ? Number(f.get('actor-index')) : 0,
  );

  const { publicClient } = createClaimRushClients({ rpcUrl: net.rpcUrl, account });
  const walletClient = createWalletClient({ transport: http(net.rpcUrl), account });

  const privateRpcUrl = f.get('private-rpc-url') ?? process.env.PRIVATE_RPC_URL;
  const privateRpcMode = (f.get('private-rpc-mode') ?? process.env.PRIVATE_RPC_MODE) as
    | 'off'
    | 'route'
    | 'only'
    | undefined;
  const privateWalletClient =
    privateRpcUrl && privateRpcUrl.trim() && privateRpcMode !== 'off'
      ? createWalletClient({ transport: http(privateRpcUrl), account })
      : undefined;

  const contracts = await getClaimRushContracts({
    publicClient,
    manifest,
    abiNetwork: net.abiNetwork,
  });

  const plan = readPlanFromFile(path.resolve(planPath));
  const chainId = await publicClient.getChainId();
  if (Number(plan.chainId) !== chainId) {
    throw new Error(`[plan execute] plan chainId=${plan.chainId} != rpc chainId=${chainId}`);
  }

  const guard = applyCralGuards({
    action: 'plan',
    chain: net.chain,
    execute,
    iUnderstand,
  });
  if (!guard.ok) {
    console.error(`[plan execute] CRAL preflight failed: ${guard.reason}`);
    return 65;
  }

  const actingForUser = parseActingFor(f.get('acting-for'));
  if (actingForUser) {
    const hub = (manifest.contracts as any).DelegationHub?.address;
    if (!hub) {
      console.error('[plan execute] DelegationHub not found in manifest for chain');
      return 70;
    }
    for (const a of plan.actions) {
      const requiredPerms = permsForActionKind((a as any).kind);
      if (requiredPerms === 0n) continue;
      const r = await requireLiveSession({
        publicClient,
        delegationHub: hub,
        user: actingForUser,
        delegate: agent,
        requiredPerms,
        abiNetwork: net.abiNetwork,
      });
      if (!r.ok) {
        console.error(`[plan execute] delegation precheck failed: ${r.reason}`);
        return 66;
      }
    }
  }

  const maxActions = f.get('max-actions') ? Number(f.get('max-actions')) : undefined;

  const results = await executeAgentPlan({
    plan,
    publicClient,
    walletClient,
    privateWalletClient,
    privateRpcMode: privateRpcMode ?? (privateRpcUrl ? 'route' : 'off'),
    account,
    manifest,
    abiNetwork: net.abiNetwork,
    contracts,
    execute,
    maxActions,
  });

  const ok = results.every((r) => !r.error);
  const receipt = {
    ok,
    stage: execute ? 'executed' : 'simulated',
    plan: planPath,
    cralNotes: guard.notes,
    actingForUser,
    results: results.map((r) => ({
      actionKind: (r.action as any).kind,
      simulated: r.simulated,
      txHash: (r as any).hash ?? (r as any).txHash ?? null,
      error: r.error
        ? {
            classification: (r.error as any).classification,
            shortMessage: (r.error as any).shortMessage,
          }
        : null,
    })),
  };
  appendReceipt(repoRoot(), 'plan-execute', receipt);
  console.log(
    jsonStringify(receipt, f.has('pretty') ? true : false),
  );
  return ok ? 0 : 1;
}
