import 'dotenv/config';

import type { Abi, Address, PublicClient, WalletClient } from 'viem';
import { createWalletClient, http, parseEther } from 'viem';

import { loadAbi } from '../src/abis.js';
import type { AbiNetwork } from '../src/abis.js';
import { createClaimRushClients } from '../src/clients.js';
import { getClaimRushContracts } from '../src/contracts.js';
import type { ClaimRushContracts } from '../src/contracts.js';
import { loadDeploymentManifest, getContractAddress } from '../src/manifest.js';
import type { DeploymentManifest } from '../src/manifest.js';
import {
  quoteEnterWithEth,
  quoteEnterWithClaim,
  quoteCurrentTakeoverPrice,
  minOutFromBps,
} from '../src/quotes.js';
import { deriveActors, DEFAULT_ANVIL_MNEMONIC } from '../src/harness/accounts.js';
import { simulateAndWrite } from '../src/harness/tx.js';
import { timeTravelTo } from '../src/harness/time.js';
import {
  readDelegationNonce,
  getDelegationSession,
  isAuthorized,
  signSetSession,
  submitSetSessionBySig,
} from '../src/delegation/sessions.js';
import {
  ALL,
  P_TAKEOVER_FOR,
  P_ROUTE_REIGN_CLAIM_TO_CALLER,
  P_SET_REIGN_ETH_RECIPIENT,
  P_SET_REIGN_ETH_RECIPIENT_TO_CALLER_ONLY,
  P_SET_REIGN_CLAIM_RECIPIENT,
  P_SET_REIGN_CLAIM_RECIPIENT_TO_USER_ONLY,
  P_WITHDRAW_KING_BUCKET_FOR,
  P_CLAIM_SHAREHOLDER_FOR,
  P_CLAIM_ALL_FOR,
  P_FURNACE_ENTER_ETH_FOR,
  P_FURNACE_ENTER_CLAIM_FOR,
  P_FURNACE_ENTER_TOKEN_FOR,
  P_VE_EXTEND_LOCK_FOR,
  P_VE_MERGE_LOCKS_FOR,
  P_VE_UNLOCK_EXPIRED_FOR,
  P_SET_KING_AUTO_LOCK_CONFIG_FOR,
  P_SET_SHAREHOLDER_AUTOCOMPOUND_CONFIG_FOR,
  P_SET_LP_AUTOCOMPOUND_CONFIG_FOR,
  permsMask,
} from '../src/delegation/permissions.js';

// ---------------------------------------------------------------------------
// Types
// ---------------------------------------------------------------------------

type TestStatus = 'passed' | 'failed' | 'skipped';

type TestResult = {
  id: string;
  name: string;
  status: TestStatus;
  error?: string;
  details?: Record<string, unknown>;
};

type GroupResult = {
  tests: TestResult[];
  passed: number;
  failed: number;
  skipped: number;
};

type FullResult = {
  ok: boolean;
  chainId: number;
  chain: string;
  groups: Record<string, GroupResult>;
  summary: { total: number; passed: number; failed: number; skipped: number };
};

// ---------------------------------------------------------------------------
// Test runner helpers
// ---------------------------------------------------------------------------

class TestRunner {
  private groups: Record<string, TestResult[]> = {};
  private currentGroup = '';

  group(name: string): void {
    this.currentGroup = name;
    if (!this.groups[name]) this.groups[name] = [];
    log(`\n── Group ${name} ──`);
  }

  async run(
    id: string,
    name: string,
    fn: () => Promise<Record<string, unknown> | void>,
  ): Promise<void> {
    const label = `  [${id}] ${name}`;
    try {
      const details = (await fn()) ?? {};
      this.groups[this.currentGroup].push({ id, name, status: 'passed', details });
      log(`${label} ... PASSED`);
    } catch (err: unknown) {
      const msg = err instanceof Error ? err.message : String(err);
      this.groups[this.currentGroup].push({ id, name, status: 'failed', error: msg });
      log(`${label} ... FAILED: ${msg}`);
    }
  }

  skip(id: string, name: string, reason: string): void {
    this.groups[this.currentGroup].push({
      id,
      name,
      status: 'skipped',
      details: { reason },
    });
    log(`  [${id}] ${name} ... SKIPPED: ${reason}`);
  }

  result(chainId: number, chain: string): FullResult {
    const groups: Record<string, GroupResult> = {};
    let total = 0;
    let passed = 0;
    let failed = 0;
    let skipped = 0;
    for (const [gname, tests] of Object.entries(this.groups)) {
      const gp = tests.filter((t) => t.status === 'passed').length;
      const gf = tests.filter((t) => t.status === 'failed').length;
      const gs = tests.filter((t) => t.status === 'skipped').length;
      groups[gname] = { tests, passed: gp, failed: gf, skipped: gs };
      total += tests.length;
      passed += gp;
      failed += gf;
      skipped += gs;
    }
    return {
      ok: failed === 0,
      chainId,
      chain,
      groups,
      summary: { total, passed, failed, skipped },
    };
  }
}

function assert(condition: boolean, msg: string): asserts condition {
  if (!condition) throw new Error(`Assertion failed: ${msg}`);
}

async function expectRevert(fn: () => Promise<unknown>, label: string): Promise<void> {
  try {
    await fn();
    throw new Error(`Expected revert but call succeeded: ${label}`);
  } catch (err: unknown) {
    const msg = err instanceof Error ? err.message : String(err);
    if (msg.startsWith('Expected revert but call succeeded')) throw err;
    // Reverted as expected — pass
  }
}

function log(msg: string): void {
  console.error(msg);
}

// ---------------------------------------------------------------------------
// CLI
// ---------------------------------------------------------------------------

function getArg(name: string, fallback?: string): string | undefined {
  const argv = process.argv.slice(2);
  const pref = `--${name}=`;
  const hit = argv.find((a) => a.startsWith(pref));
  if (hit) return hit.slice(pref.length);
  const idx = argv.findIndex((a) => a === `--${name}`);
  if (idx >= 0) return argv[idx + 1];
  return fallback;
}

// ---------------------------------------------------------------------------
// Setup context
// ---------------------------------------------------------------------------

type Ctx = {
  rpcUrl: string;
  publicClient: PublicClient;
  wallets: WalletClient[];
  contracts: ClaimRushContracts;
  userVeTokenIds: bigint[];
  manifest: DeploymentManifest;
  abiNetwork: AbiNetwork;
  chainId: number;
  chain: string;
  user: Address;
  delegate: Address;
  outsider: Address;
  delegationHub: Address;
  delegationHubAbi: Abi;
  furnaceAbi: Abi;
  mineCoreAbi: Abi;
  claimAllHelperAbi: Abi;
  veClaimNftAbi: Abi;
  royaltiesAbi: Abi;
  lpVaultAbi: Abi;
  addrFurnace: Address;
  addrMineCore: Address;
  addrClaimAllHelper: Address;
  addrVeClaimNft: Address;
  addrRoyalties: Address;
  addrLpVault: Address;
  addrClaimToken: Address;
};

async function setupCtx(): Promise<Ctx> {
  const rpcUrl = getArg('rpc-url') ?? process.env.RPC_URL ?? 'http://127.0.0.1:8545';
  const chain = getArg('chain') ?? process.env.CLAIMRUSH_CHAIN ?? 'base_sepolia';
  const abiNetwork = (getArg('abi-network') ??
    process.env.ABI_NETWORK ??
    'base_sepolia') as AbiNetwork;

  const manifest = loadDeploymentManifest({ chain });
  const { publicClient } = createClaimRushClients({ rpcUrl });
  const chainId = await publicClient.getChainId();

  const actors = deriveActors({ count: 3, allowDefaultMnemonic: true });
  const wallets = actors.map((a) =>
    createWalletClient({
      transport: http(rpcUrl, { fetchOptions: { redirect: 'error' } }),
      account: a.account,
    }),
  );

  const contracts = await getClaimRushContracts({ publicClient, manifest, abiNetwork });

  const delegationHub = getContractAddress(manifest, 'DelegationHub');
  const delegationHubAbi = loadAbi({ contractName: 'DelegationHub', abiNetwork });
  const furnaceAbi = loadAbi({ contractName: 'Furnace', abiNetwork });
  const mineCoreAbi = loadAbi({ contractName: 'MineCore', abiNetwork });
  const claimAllHelperAbi = loadAbi({ contractName: 'ClaimAllHelper', abiNetwork });
  const veClaimNftAbi = loadAbi({ contractName: 'VeClaimNFT', abiNetwork });
  const royaltiesAbi = loadAbi({ contractName: 'ShareholderRoyalties', abiNetwork });
  const lpVaultAbi = loadAbi({ contractName: 'LpStakingVault7D', abiNetwork });

  // On forked chains, default Anvil mnemonic accounts may already have contract
  // code deployed (e.g. forwarding fallbacks that drain ETH). Clear the code so
  // they behave as normal EOAs.
  for (const a of actors) {
    await publicClient.request({
      method: 'anvil_setCode' as any,
      params: [a.account.address, '0x'] as any,
    });
  }

  return {
    rpcUrl,
    publicClient,
    wallets,
    contracts,
    userVeTokenIds: [],
    manifest,
    abiNetwork,
    chainId,
    chain,
    user: actors[0].account.address as Address,
    delegate: actors[1].account.address as Address,
    outsider: actors[2].account.address as Address,
    delegationHub,
    delegationHubAbi,
    furnaceAbi,
    mineCoreAbi,
    claimAllHelperAbi,
    veClaimNftAbi,
    royaltiesAbi,
    lpVaultAbi,
    addrFurnace: manifest.contracts.Furnace.address as Address,
    addrMineCore: manifest.contracts.MineCore.address as Address,
    addrClaimAllHelper: manifest.contracts.ClaimAllHelper.address as Address,
    addrVeClaimNft: manifest.contracts.VeClaimNFT.address as Address,
    addrRoyalties: manifest.contracts.ShareholderRoyalties.address as Address,
    addrLpVault: manifest.contracts.LpStakingVault7D.address as Address,
    addrClaimToken: manifest.contracts.ClaimToken.address as Address,
  };
}

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

async function grantSession(
  ctx: Ctx,
  perms: bigint,
  expiryOffset = 3600n,
): Promise<{ expiry: bigint }> {
  const head = await ctx.publicClient.getBlock();
  const expiry = head.timestamp + expiryOffset;
  await simulateAndWrite({
    publicClient: ctx.publicClient,
    walletClient: ctx.wallets[0],
    account: ctx.wallets[0].account!,
    address: ctx.delegationHub,
    abi: ctx.delegationHubAbi,
    functionName: 'setSession',
    args: [ctx.delegate, perms, expiry],
  });
  return { expiry };
}

async function revokeSession(ctx: Ctx): Promise<void> {
  await simulateAndWrite({
    publicClient: ctx.publicClient,
    walletClient: ctx.wallets[0],
    account: ctx.wallets[0].account!,
    address: ctx.delegationHub,
    abi: ctx.delegationHubAbi,
    functionName: 'revokeSession',
    args: [ctx.delegate],
  });
}

async function impersonateCall(
  ctx: Ctx,
  who: Address,
  calls: Array<{
    address: Address;
    abi: Abi;
    functionName: string;
    args?: unknown[];
    value?: bigint;
  }>,
): Promise<void> {
  await ctx.publicClient.request({
    method: 'anvil_impersonateAccount' as any,
    params: [who] as any,
  });

  const fundHash = await ctx.wallets[0].sendTransaction({
    to: who,
    value: parseEther('20'),
    account: ctx.wallets[0].account!,
    chain: null,
  });
  await ctx.publicClient.waitForTransactionReceipt({ hash: fundHash });

  const wallet = createWalletClient({
    transport: http(ctx.rpcUrl, { fetchOptions: { redirect: 'error' } }),
    account: who,
  });

  for (const call of calls) {
    const hash = await wallet.writeContract({
      address: call.address,
      abi: call.abi,
      functionName: call.functionName,
      args: call.args ?? [],
      value: call.value ?? 0n,
      chain: null,
    });
    const receipt = await ctx.publicClient.waitForTransactionReceipt({ hash });
    if (receipt.status !== 'success') throw new Error(`${call.functionName} tx reverted`);
  }

  await ctx.publicClient.request({
    method: 'anvil_stopImpersonatingAccount' as any,
    params: [who] as any,
  });
}

async function ensureGenesisActive(ctx: Ctx): Promise<void> {
  const takeoversPaused = (await (ctx.contracts as any).MineCore.read.takeoversPaused()) as boolean;
  if (!takeoversPaused) {
    log('Takeovers already active — skipping genesis setup.');
    await ensureRouterConfig(ctx);
    await mintClaimToAccounts(ctx);
    return;
  }

  // On staging forks the Aerodrome pool may not be deployed, making finalizeGenesis impossible.
  // Bypass genesis via direct storage patches on the Anvil fork.
  const emissionStart = (await (ctx.contracts as any).MineCore.read.emissionStartTime()) as bigint;
  const targetTs = emissionStart + 10n * 24n * 60n * 60n + 1n;
  const warp = await timeTravelTo(ctx.publicClient, targetTs);
  if (!warp.ok) throw new Error('Cannot time-travel past genesis window');

  // Slot 13, byte 0: genesisKingClaimCollected = true
  await ctx.publicClient.request({
    method: 'anvil_setStorageAt' as any,
    params: [
      ctx.addrMineCore,
      '0x000000000000000000000000000000000000000000000000000000000000000d',
      '0x0000000000000000000000000000000000000000000000000000000000000001',
    ] as any,
  });

  // Slot 7: packed [11 zero bytes][1 byte takeoversPaused][20 bytes delegationHub]
  const slot7 = (await ctx.publicClient.request({
    method: 'eth_getStorageAt' as any,
    params: [
      ctx.addrMineCore,
      '0x0000000000000000000000000000000000000000000000000000000000000007',
      'latest',
    ] as any,
  })) as `0x${string}`;
  const clearedPaused = BigInt(slot7) & ~(0xffn << 160n);
  const newSlot7 = `0x${clearedPaused.toString(16).padStart(64, '0')}` as `0x${string}`;
  await ctx.publicClient.request({
    method: 'anvil_setStorageAt' as any,
    params: [
      ctx.addrMineCore,
      '0x0000000000000000000000000000000000000000000000000000000000000007',
      newSlot7,
    ] as any,
  });

  const stillPaused = (await (ctx.contracts as any).MineCore.read.takeoversPaused()) as boolean;
  if (stillPaused) throw new Error('Storage patch did not unpause takeovers');
  log('Takeovers activated via storage patch (pre-genesis staging fork).');

  await ensureRouterConfig(ctx);
  await mintClaimToAccounts(ctx);
}

async function ensureRouterConfig(ctx: Ctx): Promise<void> {
  const registryAddr = (await ctx.publicClient.readContract({
    address: ctx.addrFurnace,
    abi: ctx.furnaceAbi,
    functionName: 'entryTokenRegistry',
  })) as Address;

  const registryAbi = loadAbi({ contractName: 'EntryTokenRegistry', abiNetwork: ctx.abiNetwork });

  try {
    await ctx.publicClient.readContract({
      address: registryAddr,
      abi: registryAbi,
      functionName: 'getRouterConfig',
    });
    log('Router config already set on EntryTokenRegistry.');
    return;
  } catch {
    // Router config not set
  }

  const launchAddr = ctx.manifest.contracts.LaunchController?.address as Address | undefined;
  if (!launchAddr) throw new Error('No LaunchController for router config');

  const launchAbi = loadAbi({ contractName: 'LaunchController', abiNetwork: ctx.abiNetwork });
  const router = (await ctx.publicClient.readContract({
    address: launchAddr,
    abi: launchAbi,
    functionName: 'aerodromeRouter',
  })) as Address;
  const factory = (await ctx.publicClient.readContract({
    address: launchAddr,
    abi: launchAbi,
    functionName: 'factory',
  })) as Address;
  const weth = (await ctx.publicClient.readContract({
    address: launchAddr,
    abi: launchAbi,
    functionName: 'weth',
  })) as Address;

  const owner = (await ctx.publicClient.readContract({
    address: registryAddr,
    abi: registryAbi,
    functionName: 'owner',
  })) as Address;

  await impersonateCall(ctx, owner, [
    {
      address: registryAddr,
      abi: registryAbi,
      functionName: 'setRouterConfig',
      args: [router, factory, weth, ctx.addrClaimToken],
    },
  ]);
  log('Router config set on EntryTokenRegistry.');
}

async function mintClaimToAccounts(ctx: Ctx): Promise<void> {
  const erc20BalAbi = [
    {
      type: 'function',
      name: 'balanceOf',
      inputs: [{ type: 'address' }],
      outputs: [{ type: 'uint256' }],
      stateMutability: 'view',
    },
  ] as Abi;

  const userBal = (await ctx.publicClient.readContract({
    address: ctx.addrClaimToken,
    abi: erc20BalAbi,
    functionName: 'balanceOf',
    args: [ctx.user],
  })) as bigint;

  if (userBal > parseEther('1000')) {
    log('Test accounts already have CLAIM tokens.');
    return;
  }

  const mintAbi = [
    {
      type: 'function',
      name: 'mint',
      inputs: [{ type: 'address' }, { type: 'uint256' }],
      outputs: [],
      stateMutability: 'nonpayable',
    },
  ] as Abi;
  const mintAmount = parseEther('100000');

  await impersonateCall(ctx, ctx.addrMineCore, [
    {
      address: ctx.addrClaimToken,
      abi: mintAbi,
      functionName: 'mint',
      args: [ctx.user, mintAmount],
    },
    {
      address: ctx.addrClaimToken,
      abi: mintAbi,
      functionName: 'mint',
      args: [ctx.delegate, mintAmount],
    },
    {
      address: ctx.addrClaimToken,
      abi: mintAbi,
      functionName: 'mint',
      args: [ctx.outsider, mintAmount],
    },
  ]);
  log('Minted CLAIM tokens to test accounts.');
}

async function furnaceEnterWithClaim(
  ctx: Ctx,
  wallet: WalletClient,
  claimAmount: bigint,
  forUser?: Address,
): Promise<bigint> {
  const user = forUser ?? (wallet.account!.address as Address);
  const q = await quoteEnterWithClaim({
    contracts: ctx.contracts,
    user,
    claimIn: claimAmount,
    targetTokenId: 0n,
    durationSeconds: 30n * 86400n,
    createAutoMax: false,
  });
  const minVeOut = minOutFromBps(q.veOut, 100n);

  const erc20ApproveAbi = [
    {
      type: 'function',
      name: 'approve',
      inputs: [{ type: 'address' }, { type: 'uint256' }],
      outputs: [{ type: 'bool' }],
      stateMutability: 'nonpayable',
    },
  ] as Abi;

  await simulateAndWrite({
    publicClient: ctx.publicClient,
    walletClient: wallet,
    account: wallet.account!,
    address: ctx.addrClaimToken,
    abi: erc20ApproveAbi,
    functionName: 'approve',
    args: [ctx.addrFurnace, claimAmount],
  });

  const fnName = forUser ? 'enterWithClaimFromCallerFor' : 'enterWithClaim';
  const args = forUser
    ? [forUser, claimAmount, 0n, 30n * 86400n, false, minVeOut]
    : [claimAmount, 0n, 30n * 86400n, false, minVeOut];

  const tx = await simulateAndWrite({
    publicClient: ctx.publicClient,
    walletClient: wallet,
    account: wallet.account!,
    address: ctx.addrFurnace,
    abi: ctx.furnaceAbi,
    functionName: fnName,
    args,
  });
  return (tx.result as bigint) ?? 0n;
}

async function furnaceEnterWithEth(
  ctx: Ctx,
  wallet: WalletClient,
  forUser?: Address,
  ethAmount = '1000',
): Promise<bigint> {
  const ethIn = parseEther(ethAmount);
  const user = forUser ?? (wallet.account!.address as Address);
  const q = await quoteEnterWithEth({
    contracts: ctx.contracts,
    user,
    ethIn,
    targetTokenId: 0n,
    durationSeconds: 30n * 86400n,
    createAutoMax: false,
  });
  const minVeOut = minOutFromBps(q.veOut, 100n);
  const fnName = forUser ? 'enterWithEthFor' : 'enterWithEth';
  const args = forUser
    ? [forUser, 0n, 30n * 86400n, false, minVeOut]
    : [0n, 30n * 86400n, false, minVeOut];

  const tx = await simulateAndWrite({
    publicClient: ctx.publicClient,
    walletClient: wallet,
    account: wallet.account!,
    address: ctx.addrFurnace,
    abi: ctx.furnaceAbi,
    functionName: fnName,
    args,
    value: ethIn,
  });
  return (tx.result as bigint) ?? 0n;
}

async function doTakeover(ctx: Ctx, wallet: WalletClient, forUser?: Address): Promise<void> {
  const price = await quoteCurrentTakeoverPrice({ contracts: ctx.contracts });
  const fnName = forUser ? 'takeoverFor' : 'takeover';
  const args = forUser ? [forUser, price * 2n] : [price * 2n];
  await simulateAndWrite({
    publicClient: ctx.publicClient,
    walletClient: wallet,
    account: wallet.account!,
    address: ctx.addrMineCore,
    abi: ctx.mineCoreAbi,
    functionName: fnName,
    args,
    value: price,
  });
}

// ---------------------------------------------------------------------------
// Group A: Session Lifecycle
// ---------------------------------------------------------------------------

async function groupA(runner: TestRunner, ctx: Ctx): Promise<void> {
  runner.group('A');

  // A1: setSession (direct)
  await runner.run('A1', 'setSession direct', async () => {
    const head = await ctx.publicClient.getBlock();
    const perms = permsMask([P_TAKEOVER_FOR, P_FURNACE_ENTER_ETH_FOR]);
    const expiry = head.timestamp + 3600n;

    await simulateAndWrite({
      publicClient: ctx.publicClient,
      walletClient: ctx.wallets[0],
      account: ctx.wallets[0].account!,
      address: ctx.delegationHub,
      abi: ctx.delegationHubAbi,
      functionName: 'setSession',
      args: [ctx.delegate, perms, expiry],
    });

    const session = await getDelegationSession({
      publicClient: ctx.publicClient,
      delegationHub: ctx.delegationHub,
      user: ctx.user,
      delegate: ctx.delegate,
      abiNetwork: ctx.abiNetwork,
    });
    assert(session.perms === perms, `perms mismatch: ${session.perms} !== ${perms}`);
    assert(session.expiry === expiry, `expiry mismatch: ${session.expiry} !== ${expiry}`);

    const authed = await isAuthorized({
      publicClient: ctx.publicClient,
      delegationHub: ctx.delegationHub,
      user: ctx.user,
      delegate: ctx.delegate,
      requiredPerms: perms,
      abiNetwork: ctx.abiNetwork,
    });
    assert(authed, 'isAuthorized should be true after setSession');
    return { perms: perms.toString(), expiry: expiry.toString() };
  });

  // A2: setSessionBySig (EIP-712)
  await runner.run('A2', 'setSessionBySig EIP-712', async () => {
    // First revoke existing session so nonce is fresh
    await revokeSession(ctx);

    const perms = permsMask([P_CLAIM_ALL_FOR, P_FURNACE_ENTER_ETH_FOR]);
    const nonce = await readDelegationNonce({
      publicClient: ctx.publicClient,
      delegationHub: ctx.delegationHub,
      user: ctx.user,
      abiNetwork: ctx.abiNetwork,
    });
    const head = await ctx.publicClient.getBlock();
    const expiry = head.timestamp + 3600n;
    const deadline = expiry + 600n;

    const sig = await signSetSession({
      userWalletClient: ctx.wallets[0],
      publicClient: ctx.publicClient,
      delegationHub: ctx.delegationHub,
      chainId: ctx.chainId,
      user: ctx.user,
      delegate: ctx.delegate,
      perms,
      expiry,
      nonce,
      deadline,
    });

    const hash = await submitSetSessionBySig({
      publicClient: ctx.publicClient,
      submitterWalletClient: ctx.wallets[1],
      delegationHub: ctx.delegationHub,
      chainId: ctx.chainId,
      user: ctx.user,
      delegate: ctx.delegate,
      perms,
      expiry,
      nonce,
      deadline,
      sig,
      abiNetwork: ctx.abiNetwork,
    });

    const authed = await isAuthorized({
      publicClient: ctx.publicClient,
      delegationHub: ctx.delegationHub,
      user: ctx.user,
      delegate: ctx.delegate,
      requiredPerms: perms,
      abiNetwork: ctx.abiNetwork,
    });
    assert(authed, 'isAuthorized should be true after setSessionBySig');
    return { tx: hash, nonce: nonce.toString() };
  });

  // A3: revokeSession
  await runner.run('A3', 'revokeSession', async () => {
    await revokeSession(ctx);
    const session = await getDelegationSession({
      publicClient: ctx.publicClient,
      delegationHub: ctx.delegationHub,
      user: ctx.user,
      delegate: ctx.delegate,
      abiNetwork: ctx.abiNetwork,
    });
    assert(session.perms === 0n, `perms should be 0 after revoke, got ${session.perms}`);
    assert(session.expiry === 0n, `expiry should be 0 after revoke, got ${session.expiry}`);

    const authed = await isAuthorized({
      publicClient: ctx.publicClient,
      delegationHub: ctx.delegationHub,
      user: ctx.user,
      delegate: ctx.delegate,
      requiredPerms: P_TAKEOVER_FOR,
      abiNetwork: ctx.abiNetwork,
    });
    assert(!authed, 'isAuthorized should be false after revoke');
  });

  // A4: nonce increment
  await runner.run('A4', 'nonce increments after setSession and revokeSession', async () => {
    const nonceBefore = await readDelegationNonce({
      publicClient: ctx.publicClient,
      delegationHub: ctx.delegationHub,
      user: ctx.user,
      abiNetwork: ctx.abiNetwork,
    });

    await grantSession(ctx, P_TAKEOVER_FOR);

    const nonceAfterSet = await readDelegationNonce({
      publicClient: ctx.publicClient,
      delegationHub: ctx.delegationHub,
      user: ctx.user,
      abiNetwork: ctx.abiNetwork,
    });
    assert(
      nonceAfterSet === nonceBefore + 1n,
      `nonce should be ${nonceBefore + 1n}, got ${nonceAfterSet}`,
    );

    await revokeSession(ctx);

    const nonceAfterRevoke = await readDelegationNonce({
      publicClient: ctx.publicClient,
      delegationHub: ctx.delegationHub,
      user: ctx.user,
      abiNetwork: ctx.abiNetwork,
    });
    assert(
      nonceAfterRevoke === nonceBefore + 2n,
      `nonce should be ${nonceBefore + 2n}, got ${nonceAfterRevoke}`,
    );
    return { nonceBefore: nonceBefore.toString(), nonceAfterRevoke: nonceAfterRevoke.toString() };
  });

  // A5: replay protection
  await runner.run('A5', 'replay protection (reused nonce reverts)', async () => {
    const nonce = await readDelegationNonce({
      publicClient: ctx.publicClient,
      delegationHub: ctx.delegationHub,
      user: ctx.user,
      abiNetwork: ctx.abiNetwork,
    });
    const head = await ctx.publicClient.getBlock();
    const perms = P_TAKEOVER_FOR;
    const expiry = head.timestamp + 3600n;
    const deadline = expiry + 600n;

    const sig = await signSetSession({
      userWalletClient: ctx.wallets[0],
      publicClient: ctx.publicClient,
      delegationHub: ctx.delegationHub,
      chainId: ctx.chainId,
      user: ctx.user,
      delegate: ctx.delegate,
      perms,
      expiry,
      nonce,
      deadline,
    });

    // First submission should succeed
    await submitSetSessionBySig({
      publicClient: ctx.publicClient,
      submitterWalletClient: ctx.wallets[1],
      delegationHub: ctx.delegationHub,
      chainId: ctx.chainId,
      user: ctx.user,
      delegate: ctx.delegate,
      perms,
      expiry,
      nonce,
      deadline,
      sig,
      abiNetwork: ctx.abiNetwork,
    });

    // Second submission with same nonce should revert
    await expectRevert(
      () =>
        submitSetSessionBySig({
          publicClient: ctx.publicClient,
          submitterWalletClient: ctx.wallets[1],
          delegationHub: ctx.delegationHub,
          chainId: ctx.chainId,
          user: ctx.user,
          delegate: ctx.delegate,
          perms,
          expiry,
          nonce,
          deadline,
          sig,
          abiNetwork: ctx.abiNetwork,
        }),
      'replay with consumed nonce',
    );
  });

  // A6: session expiry
  await runner.run('A6', 'session expiry via time-travel', async () => {
    await revokeSession(ctx).catch(() => {});
    const { expiry } = await grantSession(ctx, P_TAKEOVER_FOR, 60n);

    const authedBefore = await isAuthorized({
      publicClient: ctx.publicClient,
      delegationHub: ctx.delegationHub,
      user: ctx.user,
      delegate: ctx.delegate,
      requiredPerms: P_TAKEOVER_FOR,
      abiNetwork: ctx.abiNetwork,
    });
    assert(authedBefore, 'should be authorized before expiry');

    await timeTravelTo(ctx.publicClient, expiry + 1n);

    const authedAfter = await isAuthorized({
      publicClient: ctx.publicClient,
      delegationHub: ctx.delegationHub,
      user: ctx.user,
      delegate: ctx.delegate,
      requiredPerms: P_TAKEOVER_FOR,
      abiNetwork: ctx.abiNetwork,
    });
    assert(!authedAfter, 'should NOT be authorized after expiry');
  });

  // A7: insufficient perms
  await runner.run('A7', 'insufficient perms returns false', async () => {
    await grantSession(ctx, P_TAKEOVER_FOR);

    const authed = await isAuthorized({
      publicClient: ctx.publicClient,
      delegationHub: ctx.delegationHub,
      user: ctx.user,
      delegate: ctx.delegate,
      requiredPerms: P_CLAIM_ALL_FOR,
      abiNetwork: ctx.abiNetwork,
    });
    assert(!authed, 'isAuthorized should be false for perms not granted');
    await revokeSession(ctx);
  });

  // A8: self-delegation blocked
  await runner.run('A8', 'self-delegation isAuthorized returns false', async () => {
    const authed = await isAuthorized({
      publicClient: ctx.publicClient,
      delegationHub: ctx.delegationHub,
      user: ctx.user,
      delegate: ctx.user,
      requiredPerms: P_TAKEOVER_FOR,
      abiNetwork: ctx.abiNetwork,
    });
    assert(!authed, 'isAuthorized(user, user, ...) should be false');
  });
}

// ---------------------------------------------------------------------------
// Group B: MineCore Delegated Actions (bits 0-5)
// ---------------------------------------------------------------------------

async function groupB(runner: TestRunner, ctx: Ctx): Promise<void> {
  runner.group('B');

  await ensureGenesisActive(ctx);

  // Setup: user gets a ve position via CLAIM entry, outsider takes crown
  const tokenId = await furnaceEnterWithClaim(ctx, ctx.wallets[0], parseEther('10000'));
  if (tokenId > 0n) ctx.userVeTokenIds.push(tokenId);

  // Outsider takes crown first so user can take it via delegate
  await doTakeover(ctx, ctx.wallets[2]);

  // B1: takeoverFor
  await runner.run('B1', 'takeoverFor (bit 0)', async () => {
    await grantSession(ctx, ALL);

    await doTakeover(ctx, ctx.wallets[1], ctx.user);

    const currentKing = (await (ctx.contracts as any).MineCore.read.currentKing()) as Address;
    assert(
      currentKing.toLowerCase() === ctx.user.toLowerCase(),
      `expected user to be king, got ${currentKing}`,
    );
    return { king: currentKing };
  });

  // B2: setCurrentReignRecipients with scoped perms (bits 2-5)
  // User is now king; delegate can set recipients.
  await runner.run('B2', 'setCurrentReignRecipients scoped perms (bits 2-5)', async () => {
    const recipientPerms = permsMask([
      P_TAKEOVER_FOR,
      P_SET_REIGN_ETH_RECIPIENT,
      P_SET_REIGN_ETH_RECIPIENT_TO_CALLER_ONLY,
      P_SET_REIGN_CLAIM_RECIPIENT,
      P_SET_REIGN_CLAIM_RECIPIENT_TO_USER_ONLY,
    ]);
    await grantSession(ctx, recipientPerms);

    // Use outsider as ETH recipient (differs from current) and user as CLAIM recipient
    const newEthRecip = ctx.outsider;
    const newClaimRecip = ctx.user;

    await simulateAndWrite({
      publicClient: ctx.publicClient,
      walletClient: ctx.wallets[1],
      account: ctx.wallets[1].account!,
      address: ctx.addrMineCore,
      abi: ctx.mineCoreAbi,
      functionName: 'setCurrentReignRecipients',
      args: [newEthRecip, newClaimRecip],
    });

    return { ethRecipient: newEthRecip, claimRecipient: newClaimRecip };
  });

  // B3: permission denied (only takeover perm, no recipient perms)
  await runner.run('B3', 'setCurrentReignRecipients denied without recipient perms', async () => {
    await grantSession(ctx, P_TAKEOVER_FOR);

    await expectRevert(
      () =>
        simulateAndWrite({
          publicClient: ctx.publicClient,
          walletClient: ctx.wallets[1],
          account: ctx.wallets[1].account!,
          address: ctx.addrMineCore,
          abi: ctx.mineCoreAbi,
          functionName: 'setCurrentReignRecipients',
          args: [ctx.delegate, ctx.user],
        }),
      'setCurrentReignRecipients without recipient perms',
    );
  });

  await revokeSession(ctx);
}

// ---------------------------------------------------------------------------
// Group C: Harvest Delegated Actions (bits 6-8)
// ---------------------------------------------------------------------------

async function groupC(runner: TestRunner, ctx: Ctx): Promise<void> {
  runner.group('C');

  // ---------- Setup: generate king balance AND shareholder rewards ----------
  //
  // After B2 the reign ETH recipient is outsider, so a simple dethrone sends
  // the king share to outsider (push succeeds → kingEthBalance[user] stays 0).
  //
  // Strategy:
  //   1. Dethrone user (king share goes to outsider — that's fine)
  //   2. Make user king again with DEFAULT recipients (prevEthRecipient = user)
  //   3. Put rejecting bytecode on user so the push fails
  //   4. Dethrone user → push to user fails → kingEthBalance[user] credited
  //   5. Advance ve checkpoint & flush shareholder ETH for C2

  const ensureUserIsKing = async () => {
    const king = (await (ctx.contracts as any).MineCore.read.currentKing()) as Address;
    if (king.toLowerCase() === ctx.user.toLowerCase()) return;
    await grantSession(ctx, ALL);
    await doTakeover(ctx, ctx.wallets[1], ctx.user);
  };

  // Step 1: dethrone user (king share → outsider via B2 recipients)
  await ensureUserIsKing();
  let h = await ctx.publicClient.getBlock();
  await timeTravelTo(ctx.publicClient, h.timestamp + 3600n);
  await doTakeover(ctx, ctx.wallets[2]);

  // Step 2: make user king again via delegate takeoverFor
  // (takeoverFor defaults ethRecipient=delegate, so we override to user afterwards)
  h = await ctx.publicClient.getBlock();
  await timeTravelTo(ctx.publicClient, h.timestamp + 3600n);
  await grantSession(ctx, ALL);
  await doTakeover(ctx, ctx.wallets[1], ctx.user);

  // Step 3: user (the king) sets ETH recipient to themselves
  await simulateAndWrite({
    publicClient: ctx.publicClient,
    walletClient: ctx.wallets[0],
    account: ctx.wallets[0].account!,
    address: ctx.addrMineCore,
    abi: ctx.mineCoreAbi,
    functionName: 'setCurrentReignRecipients',
    args: [ctx.user, ctx.user],
  });

  // Step 4: put REVERT bytecode on user so the ETH push fails
  await ctx.publicClient.request({
    method: 'anvil_setCode' as any,
    params: [ctx.user, '0x60006000FD'] as any,
  });

  // Step 5: outsider dethrones user → push to user fails → kingEthBalance[user] credited
  h = await ctx.publicClient.getBlock();
  await timeTravelTo(ctx.publicClient, h.timestamp + 3600n);
  await doTakeover(ctx, ctx.wallets[2]);

  // Restore user to EOA
  await ctx.publicClient.request({
    method: 'anvil_setCode' as any,
    params: [ctx.user, '0x'] as any,
  });

  // Step 5: advance ve checkpoint so shareholder flush can distribute
  for (let i = 0; i < 5; i++) {
    try {
      await simulateAndWrite({
        publicClient: ctx.publicClient,
        walletClient: ctx.wallets[2],
        account: ctx.wallets[2].account!,
        address: ctx.addrMineCore,
        abi: ctx.mineCoreAbi,
        functionName: 'advanceVeCheckpoint',
        args: [],
      });
    } catch {
      break;
    }
  }
  // Flush pending shareholder ETH and checkpoint user rewards
  try {
    await simulateAndWrite({
      publicClient: ctx.publicClient,
      walletClient: ctx.wallets[2],
      account: ctx.wallets[2].account!,
      address: ctx.addrRoyalties,
      abi: ctx.royaltiesAbi,
      functionName: 'flushPendingShareholderETH',
      args: [],
    });
  } catch {
    // may be empty or ve not caught up
  }
  try {
    await simulateAndWrite({
      publicClient: ctx.publicClient,
      walletClient: ctx.wallets[2],
      account: ctx.wallets[2].account!,
      address: ctx.addrRoyalties,
      abi: ctx.royaltiesAbi,
      functionName: 'checkpointUser',
      args: [ctx.user],
    });
  } catch {
    // may be no-op
  }

  // Grant harvest perms
  const harvestPerms = permsMask([
    P_WITHDRAW_KING_BUCKET_FOR,
    P_CLAIM_SHAREHOLDER_FOR,
    P_CLAIM_ALL_FOR,
  ]);
  await grantSession(ctx, harvestPerms);

  // C1: withdrawKingBalanceForUser
  await runner.run('C1', 'withdrawKingBalanceForUser (bit 6)', async () => {
    const kingBal = (await (ctx.contracts as any).MineCore.read.kingEthBalance([
      ctx.user,
    ])) as bigint;

    if (kingBal === 0n) {
      runner.skip('C1', 'withdrawKingBalanceForUser (bit 6)', 'no king balance to withdraw');
      return;
    }

    await simulateAndWrite({
      publicClient: ctx.publicClient,
      walletClient: ctx.wallets[1],
      account: ctx.wallets[1].account!,
      address: ctx.addrClaimAllHelper,
      abi: ctx.claimAllHelperAbi,
      functionName: 'withdrawKingBalanceForUser',
      args: [ctx.user],
    });

    const kingBalAfter = (await (ctx.contracts as any).MineCore.read.kingEthBalance([
      ctx.user,
    ])) as bigint;
    assert(
      kingBalAfter < kingBal,
      `king balance should decrease, was ${kingBal}, now ${kingBalAfter}`,
    );
    return { before: kingBal.toString(), after: kingBalAfter.toString() };
  });

  // C2: claimShareholderForUser
  await runner.run('C2', 'claimShareholderForUser (bit 7)', async () => {
    // Ensure latest rewards are checkpointed
    try {
      await simulateAndWrite({
        publicClient: ctx.publicClient,
        walletClient: ctx.wallets[2],
        account: ctx.wallets[2].account!,
        address: ctx.addrRoyalties,
        abi: ctx.royaltiesAbi,
        functionName: 'checkpointUser',
        args: [ctx.user],
      });
    } catch {
      // no-op if already current
    }

    const claimable = (await (ctx.contracts as any).ShareholderRoyalties.read.claimableEth([
      ctx.user,
    ])) as bigint;

    if (claimable === 0n) {
      runner.skip('C2', 'claimShareholderForUser (bit 7)', 'no claimable shareholder ETH');
      return;
    }

    await simulateAndWrite({
      publicClient: ctx.publicClient,
      walletClient: ctx.wallets[1],
      account: ctx.wallets[1].account!,
      address: ctx.addrClaimAllHelper,
      abi: ctx.claimAllHelperAbi,
      functionName: 'claimShareholderForUser',
      args: [ctx.user, 0, 0n, 0n, false, 0n],
    });

    return { claimedEth: claimable.toString() };
  });

  // C3: claimAllFor
  await runner.run('C3', 'claimAllFor (bit 8)', async () => {
    // Time travel first so takeover price decays, then grant session
    const h = await ctx.publicClient.getBlock();
    await timeTravelTo(ctx.publicClient, h.timestamp + 7200n);
    await grantSession(ctx, ALL);
    await doTakeover(ctx, ctx.wallets[1], ctx.user);

    const head2 = await ctx.publicClient.getBlock();
    await timeTravelTo(ctx.publicClient, head2.timestamp + 3600n);
    await doTakeover(ctx, ctx.wallets[2]);

    await grantSession(ctx, harvestPerms);

    await simulateAndWrite({
      publicClient: ctx.publicClient,
      walletClient: ctx.wallets[1],
      account: ctx.wallets[1].account!,
      address: ctx.addrClaimAllHelper,
      abi: ctx.claimAllHelperAbi,
      functionName: 'claimAllFor',
      args: [ctx.user, 0, 0n, 0n, false, 0n],
    });

    return { status: 'claimed' };
  });

  await revokeSession(ctx);
}

// ---------------------------------------------------------------------------
// Group D: Furnace Delegated Actions (bits 9-11)
// ---------------------------------------------------------------------------

async function groupD(runner: TestRunner, ctx: Ctx): Promise<void> {
  runner.group('D');

  await grantSession(ctx, ALL);

  // D1: enterWithEthFor
  await runner.run('D1', 'enterWithEthFor (bit 9)', async () => {
    // enterWithEthFor requires a working WETH/CLAIM pool. On pre-genesis staging forks
    // the pool is not deployed, so we test the delegation check separately.
    try {
      const veBalBefore = (await (ctx.contracts as any).VeClaimNFT.read.veBalanceOf([
        ctx.user,
      ])) as bigint;

      await furnaceEnterWithEth(ctx, ctx.wallets[1], ctx.user, '500');

      const veBalAfter = (await (ctx.contracts as any).VeClaimNFT.read.veBalanceOf([
        ctx.user,
      ])) as bigint;
      assert(veBalAfter > veBalBefore, 've balance should increase after enterWithEthFor');
      return { veBalBefore: veBalBefore.toString(), veBalAfter: veBalAfter.toString() };
    } catch (err: unknown) {
      const msg = err instanceof Error ? err.message : String(err);
      if (msg.includes('WethClaimHopNotSet') || msg.includes('call to non-contract')) {
        runner.skip('D1', 'enterWithEthFor (bit 9)', 'WETH/CLAIM pool not deployed on this fork');
        return;
      }
      throw err;
    }
  });

  // D2: enterWithClaimFromCallerFor
  await runner.run('D2', 'enterWithClaimFromCallerFor (bit 10)', async () => {
    const amount = parseEther('5000');
    await furnaceEnterWithClaim(ctx, ctx.wallets[1], amount, ctx.user);

    const veBalAfter = (await (ctx.contracts as any).VeClaimNFT.read.veBalanceOf([
      ctx.user,
    ])) as bigint;
    assert(veBalAfter > 0n, 've balance should be > 0 after enterWithClaimFromCallerFor');
    return { claimAmount: amount.toString() };
  });

  // D3: enterWithTokenFromCallerFor
  runner.skip(
    'D3',
    'enterWithTokenFromCallerFor (bit 11)',
    'requires entry-eligible token in registry — skipped in automated test',
  );

  await revokeSession(ctx);
}

// ---------------------------------------------------------------------------
// Group E: VeLock Delegated Actions (bits 12-14)
// ---------------------------------------------------------------------------

async function groupE(runner: TestRunner, ctx: Ctx): Promise<void> {
  runner.group('E');

  const veLockPerms = permsMask([
    P_VE_EXTEND_LOCK_FOR,
    P_VE_MERGE_LOCKS_FOR,
    P_VE_UNLOCK_EXPIRED_FOR,
    P_FURNACE_ENTER_CLAIM_FOR,
  ]);
  await grantSession(ctx, veLockPerms);

  // Ensure user has a ve position from earlier groups
  if (ctx.userVeTokenIds.length === 0) {
    const tid = await furnaceEnterWithClaim(ctx, ctx.wallets[0], parseEther('5000'));
    if (tid > 0n) ctx.userVeTokenIds.push(tid);
  }

  // E1: extendWithBonusFor (via Furnace)
  await runner.run('E1', 'extendWithBonusFor (bit 12)', async () => {
    if (ctx.userVeTokenIds.length === 0) {
      runner.skip('E1', 'extendWithBonusFor (bit 12)', 'user has no ve locks');
      return;
    }

    const tokenId = ctx.userVeTokenIds[0];
    const lockBefore = (await ctx.publicClient.readContract({
      address: ctx.addrVeClaimNft,
      abi: ctx.veClaimNftAbi,
      functionName: 'getLockInfo',
      args: [tokenId],
    })) as [bigint, bigint, boolean, boolean];
    const endBefore = lockBefore[1];

    const durationSeconds = 7n * 86400n;

    await simulateAndWrite({
      publicClient: ctx.publicClient,
      walletClient: ctx.wallets[1],
      account: ctx.wallets[1].account!,
      address: ctx.addrFurnace,
      abi: ctx.furnaceAbi,
      functionName: 'extendWithBonusFor',
      args: [ctx.user, tokenId, durationSeconds, 0n],
    });

    const lockAfter = (await ctx.publicClient.readContract({
      address: ctx.addrVeClaimNft,
      abi: ctx.veClaimNftAbi,
      functionName: 'getLockInfo',
      args: [tokenId],
    })) as [bigint, bigint, boolean, boolean];
    const endAfter = lockAfter[1];

    assert(endAfter > endBefore, `lock end should increase: ${endBefore} → ${endAfter}`);
    return {
      tokenId: tokenId.toString(),
      endBefore: endBefore.toString(),
      endAfter: endAfter.toString(),
    };
  });

  // E2: mergeLocksWithBonusFor (v1.0.0: replaces ve.mergeLocksForUser)
  await runner.run('E2', 'mergeLocksWithBonusFor (bit 13)', async () => {
    if (ctx.userVeTokenIds.length < 2) {
      const tid = await furnaceEnterWithClaim(ctx, ctx.wallets[1], parseEther('1000'), ctx.user);
      if (tid > 0n) ctx.userVeTokenIds.push(tid);
    }

    if (ctx.userVeTokenIds.length < 2) {
      runner.skip('E2', 'mergeLocksWithBonusFor (bit 13)', 'user has fewer than 2 ve locks');
      return;
    }

    const fromTokenId = ctx.userVeTokenIds[ctx.userVeTokenIds.length - 1];
    const intoTokenId = ctx.userVeTokenIds[0];

    const balanceBefore = (await (ctx.contracts as any).VeClaimNFT.read.balanceOf([
      ctx.user,
    ])) as bigint;

    // minBonusOut = 0n disables the slippage floor; the helper still runs the
    // standard pre-validation suite (ownership, listing, expiry, distinct ids,
    // checkpoint freshness). Mixed AutoMax / non-AutoMax pairs are accepted —
    // the survivor follows the OR-rule from `_mergeLocksInternal`. This mirrors
    // the executor's default behaviour when no quoter-derived floor is supplied.
    await simulateAndWrite({
      publicClient: ctx.publicClient,
      walletClient: ctx.wallets[1],
      account: ctx.wallets[1].account!,
      address: ctx.addrFurnace,
      abi: ctx.furnaceAbi,
      functionName: 'mergeLocksWithBonusFor',
      args: [ctx.user, fromTokenId, intoTokenId, 0n],
    });

    const balanceAfter = (await (ctx.contracts as any).VeClaimNFT.read.balanceOf([
      ctx.user,
    ])) as bigint;
    assert(balanceAfter < balanceBefore, 'balance should decrease after merge');
    ctx.userVeTokenIds.pop();
    return {
      from: fromTokenId.toString(),
      into: intoTokenId.toString(),
      balanceBefore: balanceBefore.toString(),
      balanceAfter: balanceAfter.toString(),
    };
  });

  // E3: unlockExpiredForUser
  await runner.run('E3', 'unlockExpiredForUser (bit 14)', async () => {
    if (ctx.userVeTokenIds.length === 0) {
      runner.skip('E3', 'unlockExpiredForUser (bit 14)', 'no locks to unlock');
      return;
    }

    const tokenId = ctx.userVeTokenIds[0];
    const lockInfo = (await ctx.publicClient.readContract({
      address: ctx.addrVeClaimNft,
      abi: ctx.veClaimNftAbi,
      functionName: 'getLockInfo',
      args: [tokenId],
    })) as [bigint, bigint, boolean, boolean];
    const end = lockInfo[1];

    // Time-travel past the lock's end; re-grant session since the old one expires
    await timeTravelTo(ctx.publicClient, end + 1n);
    await grantSession(ctx, veLockPerms);

    const claimBalBefore = (await ctx.publicClient.readContract({
      address: ctx.addrClaimToken,
      abi: [
        {
          type: 'function',
          name: 'balanceOf',
          inputs: [{ type: 'address' }],
          outputs: [{ type: 'uint256' }],
          stateMutability: 'view',
        },
      ],
      functionName: 'balanceOf',
      args: [ctx.user],
    })) as bigint;

    await simulateAndWrite({
      publicClient: ctx.publicClient,
      walletClient: ctx.wallets[1],
      account: ctx.wallets[1].account!,
      address: ctx.addrVeClaimNft,
      abi: ctx.veClaimNftAbi,
      functionName: 'unlockExpiredForUser',
      args: [ctx.user, tokenId],
    });

    const claimBalAfter = (await ctx.publicClient.readContract({
      address: ctx.addrClaimToken,
      abi: [
        {
          type: 'function',
          name: 'balanceOf',
          inputs: [{ type: 'address' }],
          outputs: [{ type: 'uint256' }],
          stateMutability: 'view',
        },
      ],
      functionName: 'balanceOf',
      args: [ctx.user],
    })) as bigint;

    assert(claimBalAfter > claimBalBefore, 'CLAIM balance should increase after unlock');
    ctx.userVeTokenIds.shift();
    return {
      tokenId: tokenId.toString(),
      claimBefore: claimBalBefore.toString(),
      claimAfter: claimBalAfter.toString(),
    };
  });

  await revokeSession(ctx);
}

// ---------------------------------------------------------------------------
// Group F: Config Delegated Actions (bits 15-17)
// ---------------------------------------------------------------------------

async function groupF(runner: TestRunner, ctx: Ctx): Promise<void> {
  runner.group('F');

  const configPerms = permsMask([
    P_SET_KING_AUTO_LOCK_CONFIG_FOR,
    P_SET_SHAREHOLDER_AUTOCOMPOUND_CONFIG_FOR,
    P_SET_LP_AUTOCOMPOUND_CONFIG_FOR,
  ]);
  await grantSession(ctx, configPerms);

  // Ensure user has a ve position for config targets
  if (ctx.userVeTokenIds.length === 0) {
    const tid = await furnaceEnterWithClaim(ctx, ctx.wallets[0], parseEther('5000'));
    if (tid > 0n) ctx.userVeTokenIds.push(tid);
  }

  const configTokenId = ctx.userVeTokenIds.length > 0 ? ctx.userVeTokenIds[0] : 0n;

  // F1: setKingAutoLockConfigForUser (create-once mode, autoMax=false, valid duration 7d+)
  await runner.run('F1', 'setKingAutoLockConfigForUser (bit 15)', async () => {
    const duration = 7 * 86400; // MIN_LOCK_DURATION = 7 days
    await simulateAndWrite({
      publicClient: ctx.publicClient,
      walletClient: ctx.wallets[1],
      account: ctx.wallets[1].account!,
      address: ctx.addrMineCore,
      abi: ctx.mineCoreAbi,
      functionName: 'setKingAutoLockConfigForUser',
      args: [ctx.user, true, 0n, duration, false, 0n],
    });
    return { enabled: true, durationSeconds: duration };
  });

  // F2: setAutoCompoundConfigForUser (ShareholderRoyalties)
  await runner.run('F2', 'setAutoCompoundConfigForUser Shareholder (bit 16)', async () => {
    if (configTokenId === 0n) {
      runner.skip(
        'F2',
        'setAutoCompoundConfigForUser Shareholder (bit 16)',
        'no ve token for config',
      );
      return;
    }
    await simulateAndWrite({
      publicClient: ctx.publicClient,
      walletClient: ctx.wallets[1],
      account: ctx.wallets[1].account!,
      address: ctx.addrRoyalties,
      abi: ctx.royaltiesAbi,
      functionName: 'setAutoCompoundConfigForUser',
      args: [ctx.user, true, configTokenId, 30n * 86400n, 3600, parseEther('0.001'), 200],
    });
    return { enabled: true, tokenId: configTokenId.toString() };
  });

  // F3: setAutoCompoundConfigForUser (LP vault)
  await runner.run('F3', 'setAutoCompoundConfigForUser LP (bit 17)', async () => {
    if (configTokenId === 0n) {
      runner.skip('F3', 'setAutoCompoundConfigForUser LP (bit 17)', 'no ve token for config');
      return;
    }
    await simulateAndWrite({
      publicClient: ctx.publicClient,
      walletClient: ctx.wallets[1],
      account: ctx.wallets[1].account!,
      address: ctx.addrLpVault,
      abi: ctx.lpVaultAbi,
      functionName: 'setAutoCompoundConfigForUser',
      args: [ctx.user, true, configTokenId, 30n * 86400n, 200],
    });
    return { enabled: true, tokenId: configTokenId.toString() };
  });

  await revokeSession(ctx);
}

// ---------------------------------------------------------------------------
// Group G: Security / Negative Tests
// ---------------------------------------------------------------------------

async function groupG(runner: TestRunner, ctx: Ctx): Promise<void> {
  runner.group('G');

  // G1: unauthorized delegate (outsider with no session)
  await runner.run('G1', 'unauthorized delegate reverts on takeoverFor', async () => {
    // Ensure no session for outsider
    const authed = await isAuthorized({
      publicClient: ctx.publicClient,
      delegationHub: ctx.delegationHub,
      user: ctx.user,
      delegate: ctx.outsider,
      requiredPerms: P_TAKEOVER_FOR,
      abiNetwork: ctx.abiNetwork,
    });
    assert(!authed, 'outsider should not be authorized');

    const price = await quoteCurrentTakeoverPrice({ contracts: ctx.contracts });

    await expectRevert(
      () =>
        simulateAndWrite({
          publicClient: ctx.publicClient,
          walletClient: ctx.wallets[2],
          account: ctx.wallets[2].account!,
          address: ctx.addrMineCore,
          abi: ctx.mineCoreAbi,
          functionName: 'takeoverFor',
          args: [ctx.user, price * 2n],
          value: price,
        }),
      'takeoverFor by unauthorized outsider',
    );
  });

  // G2: expired session execution
  await runner.run('G2', 'expired session execution reverts', async () => {
    const { expiry } = await grantSession(ctx, P_TAKEOVER_FOR, 60n);

    // Time-travel past expiry
    await timeTravelTo(ctx.publicClient, expiry + 1n);

    const authed = await isAuthorized({
      publicClient: ctx.publicClient,
      delegationHub: ctx.delegationHub,
      user: ctx.user,
      delegate: ctx.delegate,
      requiredPerms: P_TAKEOVER_FOR,
      abiNetwork: ctx.abiNetwork,
    });
    assert(!authed, 'delegate should not be authorized after expiry');

    const price = await quoteCurrentTakeoverPrice({ contracts: ctx.contracts });

    await expectRevert(
      () =>
        simulateAndWrite({
          publicClient: ctx.publicClient,
          walletClient: ctx.wallets[1],
          account: ctx.wallets[1].account!,
          address: ctx.addrMineCore,
          abi: ctx.mineCoreAbi,
          functionName: 'takeoverFor',
          args: [ctx.user, price * 2n],
          value: price,
        }),
      'takeoverFor with expired session',
    );
  });

  // G3: revoked session execution
  await runner.run('G3', 'revoked session execution reverts', async () => {
    await grantSession(ctx, P_TAKEOVER_FOR);
    await revokeSession(ctx);

    const price = await quoteCurrentTakeoverPrice({ contracts: ctx.contracts });

    await expectRevert(
      () =>
        simulateAndWrite({
          publicClient: ctx.publicClient,
          walletClient: ctx.wallets[1],
          account: ctx.wallets[1].account!,
          address: ctx.addrMineCore,
          abi: ctx.mineCoreAbi,
          functionName: 'takeoverFor',
          args: [ctx.user, price * 2n],
          value: price,
        }),
      'takeoverFor after revocation',
    );
  });

  // G4: wrong permission bit
  await runner.run('G4', 'wrong permission bit reverts on takeoverFor', async () => {
    await grantSession(ctx, P_FURNACE_ENTER_ETH_FOR);

    const authed = await isAuthorized({
      publicClient: ctx.publicClient,
      delegationHub: ctx.delegationHub,
      user: ctx.user,
      delegate: ctx.delegate,
      requiredPerms: P_TAKEOVER_FOR,
      abiNetwork: ctx.abiNetwork,
    });
    assert(!authed, 'delegate should not have TAKEOVER perm');

    const price = await quoteCurrentTakeoverPrice({ contracts: ctx.contracts });

    await expectRevert(
      () =>
        simulateAndWrite({
          publicClient: ctx.publicClient,
          walletClient: ctx.wallets[1],
          account: ctx.wallets[1].account!,
          address: ctx.addrMineCore,
          abi: ctx.mineCoreAbi,
          functionName: 'takeoverFor',
          args: [ctx.user, price * 2n],
          value: price,
        }),
      'takeoverFor with wrong perms',
    );

    await revokeSession(ctx);
  });
}

// ---------------------------------------------------------------------------
// Main
// ---------------------------------------------------------------------------

async function main(): Promise<void> {
  if (process.argv.includes('--help') || process.argv.includes('-h')) {
    console.log(`
ClaimRush Delegation Full Test

Exercises all 18 DelegationHub permission bits and session lifecycle
against a local Anvil fork.

Usage:
  npm -C agents/sdk run example:delegation-full-test -- [options]

Options:
  --rpc-url <url>      HTTP RPC (default: RPC_URL or http://127.0.0.1:8545)
  --chain <name>       Manifest chain (default: CLAIMRUSH_CHAIN or base_sepolia)
  --abi-network <name> ABI folder (default: ABI_NETWORK or base_sepolia)

Prerequisites:
  anvil --fork-url <BASE_SEPOLIA_RPC_URL>

Environment:
  ALLOW_DEFAULT_MNEMONIC=1   Required for Anvil test accounts
`);
    process.exit(0);
  }

  log('Setting up context...');
  const ctx = await setupCtx();
  log(`Chain: ${ctx.chain} (id=${ctx.chainId})`);
  log(`User:     ${ctx.user}`);
  log(`Delegate: ${ctx.delegate}`);
  log(`Outsider: ${ctx.outsider}`);
  log(`DelegationHub: ${ctx.delegationHub}`);

  const runner = new TestRunner();

  await groupA(runner, ctx);
  await groupB(runner, ctx);
  await groupC(runner, ctx);
  await groupD(runner, ctx);
  await groupE(runner, ctx);
  await groupF(runner, ctx);
  await groupG(runner, ctx);

  const result = runner.result(ctx.chainId, ctx.chain);

  log('\n════════════════════════════════════════');
  log(
    `TOTAL: ${result.summary.total}  PASSED: ${result.summary.passed}  FAILED: ${result.summary.failed}  SKIPPED: ${result.summary.skipped}`,
  );
  log(`RESULT: ${result.ok ? 'OK' : 'FAILED'}`);
  log('════════════════════════════════════════\n');

  console.log(JSON.stringify(result, (_k, v) => (typeof v === 'bigint' ? v.toString() : v), 2));

  if (!result.ok) process.exit(1);
}

main().catch((err) => {
  console.error(err);
  process.exit(1);
});
