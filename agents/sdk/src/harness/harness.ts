import fs from 'node:fs';
import path from 'node:path';

import type { Abi, Address } from 'viem';
import { createWalletClient, http, parseEther } from 'viem';

import { loadAbi } from '../abis.js';
import { createClaimRushClients } from '../clients.js';
import { parseAndValidateOutboundUrlWithDns } from '../security/url.js';
import { redactUrlForLogging, safeErrorString } from '../security/redact.js';
import { createWriteStreamNoFollow, writeTextFileNoFollow } from '../security/fs.js';
import { getClaimRushContracts } from '../contracts.js';
import { assertManifestChainId, loadDeploymentManifest } from '../manifest.js';
import { getGameStateSnapshot, stringifySnapshot } from '../snapshot.js';
import { minOutFromBps, quoteEnterWithEth, quoteCurrentTakeoverPrice } from '../quotes.js';
import { startClaimRushEventStream, stringifyJson } from '../events.js';
import type { AbiNetwork } from '../abis.js';
import type { DeploymentManifest } from '../manifest.js';

import { deriveActors, DEFAULT_ANVIL_MNEMONIC, type DerivedActor } from './accounts.js';
import { invariant } from './assert.js';
import { timeTravelTo } from './time.js';
import { simulateAndWrite } from './tx.js';

import {
  P_FURNACE_ENTER_ETH_FOR,
  P_TAKEOVER_FOR,
  isAuthorized,
  permsMask,
  readDelegationNonce,
  signSetSession,
  submitSetSessionBySig,
} from '../delegation/index.js';

import { clampStrictSafeInteger } from '../integers.js';

/**
 * Fail-closed bounded-integer parser for harness configuration.
 *
 * Accepts only canonical safe integers; malformed strings (fractional,
 * suffixed, exponential) fall back to `fallback`. Valid integers are clamped
 * to `[min, max]`.
 */
export function parseHarnessBoundedInt(
  value: unknown,
  fallback: number,
  min: number,
  max: number,
): number {
  return clampStrictSafeInteger(value, fallback, min, max);
}

function parseIntOrUndefined(v: string | undefined): number | undefined {
  if (v === undefined) return undefined;
  const s = v.trim();
  if (!s) return undefined;
  const n = Number(s);
  if (!Number.isFinite(n)) return undefined;
  return Math.trunc(n);
}

function clampFiniteInt(value: unknown, fallback: number, min: number, max: number): number {
  const n = typeof value === 'number' ? value : Number(value);
  if (!Number.isFinite(n)) return fallback;
  const i = Math.trunc(n);
  if (i < min) return min;
  if (i > max) return max;
  return i;
}

export type HarnessScenario = 'all' | 'furnace' | 'takeovers' | 'claim' | 'delegated';

export type HarnessOptions = {
  rpcUrl: string;
  chain?: string;
  abiNetwork?: AbiNetwork;
  manifest?: DeploymentManifest;

  /**
   * Safety: require manifest.chainId to match the connected RPC chainId.
   *
   * Set true to bypass (useful for dev forks or custom chainId setups).
   *
   * Env: ALLOW_CHAIN_ID_MISMATCH=1
   *
   * Default: false.
   */
  allowChainIdMismatch?: boolean;

  scenario?: HarnessScenario;

  // actors
  actorCount?: number;
  mnemonic?: string;
  privateKeysCsv?: string;

  /**
   * Safety: allow using DEFAULT_ANVIL_MNEMONIC on non-local chains.
   *
   * The Anvil mnemonic is publicly known and should only be used on local/dev chains.
   *
   * Env: ALLOW_INSECURE_DEFAULT_MNEMONIC=1
   *
   * Default: false.
   */
  allowInsecureDefaultMnemonic?: boolean;

  // furnace entry
  ethIn?: string; // human ETH
  lockDurationDays?: number;
  createAutoMax?: boolean;
  slippageBps?: number;

  // takeovers
  takeoverCount?: number;
  timeBetweenTakeoversSec?: number;

  // genesis/time travel
  finalizeGenesisIfNeeded?: boolean;

  // delegation (delegated smoke scenario)
  delegatedPerms?: string; // bigint (hex or decimal)
  delegatedExpirySeconds?: number;
  delegatedSigDeadlineSeconds?: number;
  delegatedRunTakeover?: boolean;

  // output
  outdir?: string;
  writeArtifacts?: boolean;
  // If true, require all enabled scenarios to complete.
  strict?: boolean;

  // event collection
  collectEvents?: boolean;
  eventPolling?: boolean;
};

export type HarnessResult = {
  ok: boolean;
  chainId: number;
  chain: string;
  outdir?: string;
  actors: Array<{ label: string; address: Address }>;
  steps: Array<{ name: string; status: 'ok' | 'skipped' | 'error'; details?: any }>;
};

function ensureDir(p: string): void {
  fs.mkdirSync(p, { recursive: true, mode: 0o700 });
}

function writeText(fp: string, contents: string): void {
  ensureDir(path.dirname(fp));
  writeTextFileNoFollow(fp, contents, { encoding: 'utf8', mode: 0o600 });
}

function defaultOutdir(): string {
  const ts = new Date().toISOString().replace(/[:.]/g, '-');
  return path.join('out', `harness-${ts}`);
}

function asAddr(x: string): Address {
  return x as Address;
}

function parseBigintMaybe(v?: string): bigint | undefined {
  if (!v) return undefined;
  const s = v.trim();
  if (!s) return undefined;
  try {
    // BigInt supports decimal ("123") and hex ("0x...")
    return BigInt(s);
  } catch {
    return undefined;
  }
}

export async function runClaimRushHarness(opts: HarnessOptions): Promise<HarnessResult> {
  const chain = opts.chain ?? process.env.CLAIMRUSH_CHAIN ?? 'local';
  const abiNetwork = opts.abiNetwork ?? ((process.env.ABI_NETWORK ?? 'base_sepolia') as AbiNetwork);
  const scenario = opts.scenario ?? 'all';

  const writeArtifacts = opts.writeArtifacts ?? true;
  const outdir = writeArtifacts ? (opts.outdir ?? defaultOutdir()) : undefined;
  if (outdir) ensureDir(outdir);

  const manifest = opts.manifest ?? loadDeploymentManifest({ chain });

  const validatedRpcUrl = (
    await parseAndValidateOutboundUrlWithDns(opts.rpcUrl, 'HarnessOptions.rpcUrl', {
      // Some providers embed basic auth in the URL.
      allowCredentials: true,
    })
  ).toString();

  // Public client
  const { publicClient } = createClaimRushClients({ rpcUrl: validatedRpcUrl });
  const chainId = await publicClient.getChainId();

  const envAllow = (process.env.ALLOW_CHAIN_ID_MISMATCH ?? '').trim().toLowerCase();
  const allowChainIdMismatch =
    opts.allowChainIdMismatch ??
    (envAllow
      ? envAllow === '1' || envAllow === 'true' || envAllow === 'yes' || envAllow === 'y'
      : false);

  assertManifestChainId(manifest, chainId, 'runClaimRushHarness', {
    allowMismatch: allowChainIdMismatch,
  });

  const privateKeysCsv =
    opts.privateKeysCsv ??
    process.env.PRIVATE_KEYS ??
    (process.env.PRIVATE_KEY ? process.env.PRIVATE_KEY : undefined);

  const mnemonicRaw = opts.mnemonic ?? process.env.MNEMONIC ?? process.env.LOCAL_MNEMONIC;
  const mnemonic = (mnemonicRaw ?? DEFAULT_ANVIL_MNEMONIC).trim();

  const envAllowDefaultMnemonic = (process.env.ALLOW_INSECURE_DEFAULT_MNEMONIC ?? '')
    .trim()
    .toLowerCase();
  const allowInsecureDefaultMnemonic =
    opts.allowInsecureDefaultMnemonic ??
    (envAllowDefaultMnemonic
      ? envAllowDefaultMnemonic === '1' ||
        envAllowDefaultMnemonic === 'true' ||
        envAllowDefaultMnemonic === 'yes' ||
        envAllowDefaultMnemonic === 'y'
      : false);

  const usingDefaultMnemonic = !privateKeysCsv && mnemonic === DEFAULT_ANVIL_MNEMONIC;

  if (chainId !== 31337 && usingDefaultMnemonic && !allowInsecureDefaultMnemonic) {
    throw new Error(
      `Refusing to run harness with DEFAULT_ANVIL_MNEMONIC on non-local chainId=${chainId}. ` +
        `Provide MNEMONIC or PRIVATE_KEYS. To bypass (not recommended), set ` +
        `allowInsecureDefaultMnemonic=true or ALLOW_INSECURE_DEFAULT_MNEMONIC=1.`,
    );
  }

  const actors: DerivedActor[] = deriveActors({
    count: opts.actorCount ?? 3,
    mnemonic,
    privateKeysCsv,
    allowDefaultMnemonic: true,
  });

  invariant(actors.length >= 1, 'Need at least one actor');
  const actorAddrs = actors.map((a) => ({ label: a.label, address: asAddr(a.account.address) }));

  // Read-only contract clients for quotes/state.
  const contracts = await getClaimRushContracts({ publicClient, manifest, abiNetwork });

  // ABI handles for writes.
  const furnaceAbi = loadAbi({ contractName: 'Furnace', abiNetwork }) as Abi;
  const mineCoreAbi = loadAbi({ contractName: 'MineCore', abiNetwork }) as Abi;
  const royaltiesAbi = loadAbi({ contractName: 'ShareholderRoyalties', abiNetwork }) as Abi;
  const launchControllerAbi = loadAbi({ contractName: 'LaunchController', abiNetwork }) as Abi;

  // Addresses
  const addrFurnace = manifest.contracts.Furnace.address as Address;
  const addrMineCore = manifest.contracts.MineCore.address as Address;
  const addrRoyalties = manifest.contracts.ShareholderRoyalties.address as Address;
  const addrLaunchController = manifest.contracts.LaunchController?.address as Address | undefined;
  const addrDelegationHub = manifest.contracts.DelegationHub?.address as Address | undefined;

  // Event stream (optional)
  let eventsFp: string | undefined;
  let stopStream: (() => void) | undefined;
  if (writeArtifacts && outdir && (opts.collectEvents ?? true)) {
    const eventsPath = path.join(outdir, 'events.jsonl');
    eventsFp = eventsPath;
    const ws = createWriteStreamNoFollow(eventsPath, { append: true, mode: 0o600 });

    const handle = await startClaimRushEventStream({
      publicClient,
      manifest,
      abiNetwork,
      fromBlock: undefined,
      poll: opts.eventPolling ?? true,
      onEvent: (ev) => {
        ws.write(stringifyJson(ev) + '\n');
      },
      onError: (err) => {
        ws.write(stringifyJson({ level: 'error', error: safeErrorString(err) }) + '\n');
      },
    });
    stopStream = () => {
      try {
        handle.stop();
      } finally {
        ws.end();
      }
    };
  }

  const steps: HarnessResult['steps'] = [];

  async function recordSnapshot(label: string, user?: Address): Promise<void> {
    if (!writeArtifacts || !outdir) return;
    const snap = await getGameStateSnapshot({
      publicClient,
      manifest,
      abiNetwork,
      user,
    });
    writeText(
      path.join(outdir, `snapshot.${label}.json`),
      stringifySnapshot(snap, { pretty: true }) + '\n',
    );
  }

  // Always take an initial snapshot (global) if writing artifacts.
  await recordSnapshot('before', actors[0].account.address as Address);

  const strict = opts.strict ?? chain === 'local';

  // Wallet clients per actor.
  const wallets = actors.map((a) =>
    createWalletClient({
      transport: http(validatedRpcUrl, { fetchOptions: { redirect: 'error' } }),
      account: a.account,
    }),
  );

  async function ensureGenesisFinalized(): Promise<boolean> {
    if (!(opts.finalizeGenesisIfNeeded ?? true)) {
      steps.push({ name: 'genesis.finalize', status: 'skipped', details: { reason: 'disabled' } });
      return false;
    }

    if (!addrLaunchController) {
      steps.push({
        name: 'genesis.finalize',
        status: 'skipped',
        details: { reason: 'no LaunchController in manifest' },
      });
      return false;
    }

    const takeoversPaused = (await (contracts as any).MineCore.read.takeoversPaused()) as boolean;
    if (!takeoversPaused) {
      steps.push({
        name: 'genesis.finalize',
        status: 'skipped',
        details: { reason: 'already active' },
      });
      return false;
    }

    // Warp time to emissionStartTime + 10 days + 1 second.
    const emissionStart = (await (contracts as any).MineCore.read.emissionStartTime()) as bigint;
    const targetTs = emissionStart + 10n * 24n * 60n * 60n + 1n;
    const warp = await timeTravelTo(publicClient, targetTs);
    if (!warp.ok) {
      steps.push({
        name: 'genesis.finalize',
        status: 'skipped',
        details: {
          reason: 'rpc does not support time travel',
          emissionStart: emissionStart.toString(),
        },
      });
      return false;
    }

    // finalizeGenesis() payable, requires exactly 50 ETH.
    const actor0 = actors[0];
    const actor0Wallet = wallets[0];
    const value = parseEther('50');

    try {
      const tx = await simulateAndWrite({
        publicClient,
        walletClient: actor0Wallet,
        account: actor0.account,
        address: addrLaunchController,
        abi: launchControllerAbi,
        functionName: 'finalizeGenesis',
        args: [],
        value,
      });

      const pausedAfter = (await (contracts as any).MineCore.read.takeoversPaused()) as boolean;
      invariant(
        !pausedAfter,
        'genesis.finalize: expected takeoversPaused=false after finalizeGenesis',
      );

      steps.push({
        name: 'genesis.finalize',
        status: 'ok',
        details: { method: warp.method, tx: tx.hash, block: tx.receipt.blockNumber.toString() },
      });
      return true;
    } catch (err) {
      steps.push({
        name: 'genesis.finalize',
        status: 'error',
        details: { error: safeErrorString(err) },
      });
      if (strict) throw err;
      return false;
    }
  }

  async function runFurnaceEntry(): Promise<boolean> {
    const enabled = scenario === 'all' || scenario === 'furnace';
    if (!enabled) {
      steps.push({
        name: 'furnace.enter',
        status: 'skipped',
        details: { reason: 'scenario disabled' },
      });
      return false;
    }

    const lockingPaused = (await (contracts as any).Furnace.read.lockingPaused()) as boolean;
    if (lockingPaused) {
      steps.push({
        name: 'furnace.enter',
        status: 'skipped',
        details: { reason: 'lockingPaused=true' },
      });
      return false;
    }

    const actor0 = actors[0];
    const actor0Wallet = wallets[0];

    const ethInStr = opts.ethIn ?? process.env.ETH_IN ?? '1000';
    const ethIn = parseEther(ethInStr);
    const targetTokenId = 0n;
    const lockDurationDays = clampFiniteInt(
      opts.lockDurationDays ?? parseIntOrUndefined(process.env.LOCK_DURATION_DAYS) ?? 30,
      30,
      0,
      3650,
    );
    const durationSeconds = BigInt(lockDurationDays) * 24n * 60n * 60n;
    const createAutoMax = opts.createAutoMax ?? process.env.CREATE_AUTO_MAX === 'true';
    const slippageBps = BigInt(
      clampFiniteInt(
        opts.slippageBps ?? parseIntOrUndefined(process.env.SLIPPAGE_BPS) ?? 50,
        50,
        0,
        10_000,
      ),
    );

    const q = await quoteEnterWithEth({
      contracts,
      user: actor0.account.address as Address,
      ethIn,
      targetTokenId,
      durationSeconds,
      createAutoMax,
    });

    const minVeOut = minOutFromBps(q.veOut, slippageBps);

    try {
      const tx = await simulateAndWrite({
        publicClient,
        walletClient: actor0Wallet,
        account: actor0.account,
        address: addrFurnace,
        abi: furnaceAbi,
        functionName: 'enterWithEth',
        args: [targetTokenId, durationSeconds, createAutoMax, minVeOut],
        value: ethIn,
      });

      // Assert the actor now has nonzero ve.
      const veBal = (await (contracts as any).VeClaimNFT.read.veBalanceOf([
        actor0.account.address,
      ])) as bigint;
      invariant(veBal > 0n, 'furnace.enter: expected veBalanceOf(actor0) > 0');

      steps.push({
        name: 'furnace.enter',
        status: 'ok',
        details: {
          ethIn: ethInStr,
          durationDays: lockDurationDays,
          quoted: {
            principalClaim: q.principalClaim.toString(),
            bonusClaim: q.bonusClaim.toString(),
            veOut: q.veOut.toString(),
            routeTokenId: q.routeTokenId.toString(),
          },
          minVeOut: minVeOut.toString(),
          tokenIdUsed: (tx.result as any)?.toString?.() ?? undefined,
          tx: tx.hash,
          block: tx.receipt.blockNumber.toString(),
        },
      });

      return true;
    } catch (err) {
      steps.push({
        name: 'furnace.enter',
        status: 'error',
        details: { error: safeErrorString(err) },
      });
      if (strict) throw err;
      return false;
    }
  }

  async function runTakeovers(): Promise<boolean> {
    const enabled = scenario === 'all' || scenario === 'takeovers';
    if (!enabled) {
      steps.push({
        name: 'mineCore.takeovers',
        status: 'skipped',
        details: { reason: 'scenario disabled' },
      });
      return false;
    }

    const takeoversPaused = (await (contracts as any).MineCore.read.takeoversPaused()) as boolean;
    if (takeoversPaused) {
      steps.push({
        name: 'mineCore.takeovers',
        status: 'skipped',
        details: { reason: 'takeoversPaused=true' },
      });
      return false;
    }

    const takeoverCount = clampFiniteInt(
      opts.takeoverCount ?? parseIntOrUndefined(process.env.TAKEOVER_COUNT) ?? 2,
      2,
      0,
      1000,
    );
    const gap = clampFiniteInt(
      opts.timeBetweenTakeoversSec ?? parseIntOrUndefined(process.env.TAKEOVER_GAP_SEC) ?? 3600,
      3600,
      0,
      86_400,
    );

    // Use actors 1..N as kings to avoid the ve-holder (actor0) being blocked by "no self takeover".
    invariant(
      actors.length >= 3,
      'takeovers: need at least 3 actors (actor0=shareholder, actor1/2=king contenders)',
    );

    const txs: Array<{ i: number; actor: string; hash: string; pricePaid: string }> = [];
    for (let i = 0; i < takeoverCount; i++) {
      const contenderIdx = 1 + (i % (actors.length - 1));
      const actor = actors[contenderIdx];
      const wallet = wallets[contenderIdx];

      const price = await quoteCurrentTakeoverPrice({ contracts });
      const tx = await simulateAndWrite({
        publicClient,
        walletClient: wallet,
        account: actor.account,
        address: addrMineCore,
        abi: mineCoreAbi,
        functionName: 'takeover',
        args: [price * 2n],
        value: price,
      });

      txs.push({ i, actor: actor.label, hash: tx.hash, pricePaid: price.toString() });

      // Move time forward to accrue emissions and avoid identical timestamps (optional).
      if (gap > 0 && i < takeoverCount - 1) {
        const head = await publicClient.getBlock();
        await timeTravelTo(publicClient, head.timestamp + BigInt(gap));
      }
    }

    const currentKing = (await (contracts as any).MineCore.read.currentKing()) as Address;
    invariant(
      currentKing !== ('0x0000000000000000000000000000000000000000' as Address),
      'takeovers: expected nonzero king',
    );

    steps.push({
      name: 'mineCore.takeovers',
      status: 'ok',
      details: { takeoverCount, txs, currentKing },
    });
    return true;
  }

  async function runClaim(): Promise<boolean> {
    const enabled = scenario === 'all' || scenario === 'claim';
    if (!enabled) {
      steps.push({
        name: 'royalties.claim',
        status: 'skipped',
        details: { reason: 'scenario disabled' },
      });
      return false;
    }

    const actor0 = actors[0];
    const actor0Wallet = wallets[0];

    // Claimable ETH should be >0 if takeovers happened while actor0 had ve.
    const claimableBefore = (await (contracts as any).ShareholderRoyalties.read.claimableEth([
      actor0.account.address,
    ])) as bigint;

    if (claimableBefore === 0n) {
      steps.push({
        name: 'royalties.claim',
        status: 'skipped',
        details: { reason: 'claimableEth=0 (did you run takeovers?)' },
      });
      return false;
    }

    try {
      const tx = await simulateAndWrite({
        publicClient,
        walletClient: actor0Wallet,
        account: actor0.account,
        address: addrRoyalties,
        abi: royaltiesAbi,
        functionName: 'claimShareholder',
        // mode=0 (ETH); other params ignored
        args: [0, 0n, 0n, false, 0n],
      });

      const claimableAfter = (await (contracts as any).ShareholderRoyalties.read.claimableEth([
        actor0.account.address,
      ])) as bigint;
      invariant(
        claimableAfter === 0n,
        'royalties.claim: expected claimableEth(actor0)=0 after claim',
      );

      steps.push({
        name: 'royalties.claim',
        status: 'ok',
        details: {
          claimableBefore: claimableBefore.toString(),
          tx: tx.hash,
          block: tx.receipt.blockNumber.toString(),
        },
      });
      return true;
    } catch (err) {
      steps.push({
        name: 'royalties.claim',
        status: 'error',
        details: { error: safeErrorString(err) },
      });
      if (strict) throw err;
      return false;
    }
  }

  async function runDelegatedSmoke(): Promise<boolean> {
    if (scenario !== 'delegated') return false;

    invariant(
      actors.length >= 2,
      'delegated: need at least 2 actors (actor0=user, actor1=delegate)',
    );

    if (!addrDelegationHub) {
      steps.push({
        name: 'delegation.setSessionBySig',
        status: 'skipped',
        details: { reason: 'no DelegationHub in manifest' },
      });
      return false;
    }

    const userIdx = 0;
    const delegateIdx = 1;

    const userActor = actors[userIdx];
    const delegateActor = actors[delegateIdx];

    const user = userActor.account.address as Address;
    const delegate = delegateActor.account.address as Address;

    // Default perms for this smoke test: bot can enter Furnace (bot pays) and take over the Crown for the user.
    const defaultPerms = permsMask([P_FURNACE_ENTER_ETH_FOR, P_TAKEOVER_FOR]);
    const perms =
      parseBigintMaybe(opts.delegatedPerms ?? process.env.DELEGATED_PERMS) ?? defaultPerms;

    const expirySeconds = BigInt(
      clampFiniteInt(
        opts.delegatedExpirySeconds ??
          parseIntOrUndefined(process.env.DELEGATED_SESSION_EXPIRY_SECONDS) ??
          3600,
        3600,
        60,
        86_400,
      ),
    );
    const deadlineSeconds = BigInt(
      clampFiniteInt(
        opts.delegatedSigDeadlineSeconds ??
          parseIntOrUndefined(process.env.DELEGATED_SIG_DEADLINE_SECONDS) ??
          600,
        600,
        60,
        86_400,
      ),
    );

    let ranSomething = false;

    // 1) Set session by signature (user signs, delegate submits).
    try {
      const nonce = await readDelegationNonce({
        publicClient,
        delegationHub: addrDelegationHub,
        user,
        abiNetwork,
      });

      // Get a FRESH timestamp right before signing to minimize timing issues.
      // This is critical because ensureGenesisFinalized() may have warped time,
      // and we need the deadline to be relative to the current chain state.
      const head = await publicClient.getBlock();
      const nowTs = head.timestamp;
      const expiry = nowTs + expirySeconds;
      const deadline = nowTs + deadlineSeconds;

      const sig = await signSetSession({
        userWalletClient: wallets[userIdx],
        publicClient,
        delegationHub: addrDelegationHub,
        chainId,
        user,
        delegate,
        perms,
        expiry,
        nonce,
        deadline,
      });

      const hash = await submitSetSessionBySig({
        publicClient,
        submitterWalletClient: wallets[delegateIdx],
        abiNetwork,
        delegationHub: addrDelegationHub,
        chainId,
        user,
        delegate,
        perms,
        expiry,
        nonce,
        deadline,
        sig,
      });

      const receipt = await publicClient.waitForTransactionReceipt({ hash });

      const okAuth = await isAuthorized({
        publicClient,
        delegationHub: addrDelegationHub,
        user,
        delegate,
        requiredPerms: perms,
        abiNetwork,
      });
      invariant(okAuth, 'delegation.setSessionBySig: expected isAuthorized=true after set');

      steps.push({
        name: 'delegation.setSessionBySig',
        status: 'ok',
        details: {
          user,
          delegate,
          perms: perms.toString(),
          expiry: expiry.toString(),
          deadline: deadline.toString(),
          tx: hash,
          block: receipt.blockNumber.toString(),
        },
      });
      ranSomething = true;
    } catch (err) {
      steps.push({
        name: 'delegation.setSessionBySig',
        status: 'error',
        details: { error: safeErrorString(err) },
      });
      if (strict) throw err;
      return false;
    }

    // 2) Delegated Furnace entry (delegate pays ETH, user receives ve lock).
    if ((perms & P_FURNACE_ENTER_ETH_FOR) === 0n) {
      steps.push({
        name: 'delegated.furnace.enterWithEthFor',
        status: 'skipped',
        details: { reason: 'perm not granted (P_FURNACE_ENTER_ETH_FOR)' },
      });
    } else {
      const lockingPaused = (await (contracts as any).Furnace.read.lockingPaused()) as boolean;
      if (lockingPaused) {
        steps.push({
          name: 'delegated.furnace.enterWithEthFor',
          status: 'skipped',
          details: { reason: 'lockingPaused=true' },
        });
      } else {
        const ethInStr = opts.ethIn ?? process.env.DELEGATED_ETH_IN ?? process.env.ETH_IN ?? '1000';
        const ethIn = parseEther(ethInStr);
        const targetTokenId = 0n;
        const lockDurationDays = clampFiniteInt(
          opts.lockDurationDays ??
            parseIntOrUndefined(process.env.DELEGATED_LOCK_DURATION_DAYS) ??
            parseIntOrUndefined(process.env.LOCK_DURATION_DAYS) ??
            30,
          30,
          0,
          3650,
        );
        const durationSeconds = BigInt(lockDurationDays) * 24n * 60n * 60n;

        const createAutoMax =
          opts.createAutoMax ??
          (process.env.DELEGATED_CREATE_AUTO_MAX !== undefined
            ? process.env.DELEGATED_CREATE_AUTO_MAX === 'true'
            : process.env.CREATE_AUTO_MAX === 'true');

        const slippageBps = BigInt(
          clampFiniteInt(
            opts.slippageBps ??
              parseIntOrUndefined(process.env.DELEGATED_SLIPPAGE_BPS) ??
              parseIntOrUndefined(process.env.SLIPPAGE_BPS) ??
              50,
            50,
            0,
            10_000,
          ),
        );

        try {
          const q = await quoteEnterWithEth({
            contracts,
            user,
            ethIn,
            targetTokenId,
            durationSeconds,
            createAutoMax,
          });

          const minVeOut = minOutFromBps(q.veOut, slippageBps);

          const tx = await simulateAndWrite({
            publicClient,
            walletClient: wallets[delegateIdx],
            account: delegateActor.account,
            address: addrFurnace,
            abi: furnaceAbi,
            functionName: 'enterWithEthFor',
            args: [user, targetTokenId, durationSeconds, createAutoMax, minVeOut],
            value: ethIn,
          });

          const veBal = (await (contracts as any).VeClaimNFT.read.veBalanceOf([user])) as bigint;
          invariant(
            veBal > 0n,
            'delegated.furnace.enterWithEthFor: expected veBalanceOf(user) > 0',
          );

          steps.push({
            name: 'delegated.furnace.enterWithEthFor',
            status: 'ok',
            details: {
              user,
              delegate,
              ethIn: ethInStr,
              durationDays: lockDurationDays,
              quoted: {
                principalClaim: q.principalClaim.toString(),
                bonusClaim: q.bonusClaim.toString(),
                veOut: q.veOut.toString(),
                routeTokenId: q.routeTokenId.toString(),
              },
              minVeOut: minVeOut.toString(),
              tokenIdUsed: (tx.result as any)?.toString?.() ?? undefined,
              tx: tx.hash,
              block: tx.receipt.blockNumber.toString(),
            },
          });
          ranSomething = true;
        } catch (err) {
          steps.push({
            name: 'delegated.furnace.enterWithEthFor',
            status: 'error',
            details: { user, delegate, error: safeErrorString(err) },
          });
          if (strict) throw err;
        }
      }
    }

    // 3) Delegated takeoverFor (delegate pays ETH, user becomes King).
    const doTakeover =
      opts.delegatedRunTakeover ??
      (process.env.DELEGATED_RUN_TAKEOVER !== undefined
        ? process.env.DELEGATED_RUN_TAKEOVER === '1'
        : true);

    if (!doTakeover) {
      steps.push({
        name: 'delegated.mineCore.takeoverFor',
        status: 'skipped',
        details: { reason: 'disabled' },
      });
      return ranSomething;
    }

    if ((perms & P_TAKEOVER_FOR) === 0n) {
      steps.push({
        name: 'delegated.mineCore.takeoverFor',
        status: 'skipped',
        details: { reason: 'perm not granted (P_TAKEOVER_FOR)' },
      });
      return ranSomething;
    }

    const takeoversPaused = (await (contracts as any).MineCore.read.takeoversPaused()) as boolean;
    if (takeoversPaused) {
      steps.push({
        name: 'delegated.mineCore.takeoverFor',
        status: 'skipped',
        details: { reason: 'takeoversPaused=true' },
      });
      return ranSomething;
    }

    const currentKingBefore = (await (contracts as any).MineCore.read.currentKing()) as Address;
    if (currentKingBefore === user) {
      steps.push({
        name: 'delegated.mineCore.takeoverFor',
        status: 'skipped',
        details: { reason: 'user is already currentKing' },
      });
      return ranSomething;
    }

    try {
      const price = await quoteCurrentTakeoverPrice({ contracts });
      const tx = await simulateAndWrite({
        publicClient,
        walletClient: wallets[delegateIdx],
        account: delegateActor.account,
        address: addrMineCore,
        abi: mineCoreAbi,
        functionName: 'takeoverFor',
        args: [user, price * 2n],
        value: price,
      });

      const currentKingAfter = (await (contracts as any).MineCore.read.currentKing()) as Address;
      invariant(
        currentKingAfter === user,
        'delegated.mineCore.takeoverFor: expected user to become currentKing',
      );

      steps.push({
        name: 'delegated.mineCore.takeoverFor',
        status: 'ok',
        details: {
          user,
          delegate,
          pricePaid: price.toString(),
          tx: tx.hash,
          block: tx.receipt.blockNumber.toString(),
        },
      });

      ranSomething = true;
    } catch (err) {
      steps.push({
        name: 'delegated.mineCore.takeoverFor',
        status: 'error',
        details: { error: safeErrorString(err) },
      });
      if (strict) throw err;
    }

    return ranSomething;
  }
  let ranSomething = false;
  try {
    // 1) If needed, finalize genesis (unpauses takeovers) on local devnets.
    await ensureGenesisFinalized();

    // Scenarios are mutually exclusive; the delegated smoke test has its own flow.
    if (scenario === 'delegated') {
      ranSomething = (await runDelegatedSmoke()) || ranSomething;
    } else {
      // 2) Create ve position (so we can receive shareholder ETH from takeovers).
      ranSomething = (await runFurnaceEntry()) || ranSomething;

      // 3) Do some takeovers to generate shareholder ETH.
      ranSomething = (await runTakeovers()) || ranSomething;

      // 4) Claim shareholder ETH.
      ranSomething = (await runClaim()) || ranSomething;
    }
  } finally {
    if (stopStream) stopStream();
  }

  await recordSnapshot('after', actors[0].account.address as Address);

  const ok = strict ? steps.every((s) => s.status !== 'error') : ranSomething;

  if (writeArtifacts && outdir) {
    writeText(
      path.join(outdir, 'run.json'),
      stringifyJson(
        {
          ok,
          chain,
          chainId,
          rpcUrl: redactUrlForLogging(opts.rpcUrl),
          scenario,
          actors: actorAddrs,
          steps,
          artifacts: {
            beforeSnapshot: 'snapshot.before.json',
            afterSnapshot: 'snapshot.after.json',
            events: eventsFp ? path.basename(eventsFp) : undefined,
          },
        },
        { pretty: true },
      ) + '\n',
    );
  }

  return {
    ok,
    chainId,
    chain,
    outdir,
    actors: actorAddrs,
    steps,
  };
}
