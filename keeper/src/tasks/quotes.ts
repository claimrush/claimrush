import type { Address, PublicClient } from 'viem';
import { parseEther } from 'viem';

import {
  AERODROME_POOL_ABI,
  AERODROME_ROUTER_ABI,
  ERC20_ABI,
  LP_STAKING_VAULT_ABI,
  FURNACE_ABI,
} from '../shared/abis.js';
import { applyBps } from '../shared/utils.js';

function addrEq(a: string | null | undefined, b: string | null | undefined): boolean {
  if (!a || !b) return false;
  return String(a).toLowerCase() === String(b).toLowerCase();
}

export async function quoteMinClaimOutStaking({
  publicClient,
  vaultAddress,
  slippageBps,
  log,
}: {
  publicClient: PublicClient;
  vaultAddress: Address;
  slippageBps: number;
  log?: ((msg: string) => void) | null;
}): Promise<{ ok: boolean; minClaimOut?: bigint; error?: string; [key: string]: unknown }> {
  return quoteMinClaimOutForVault({
    publicClient,
    vaultAddress,
    slippageBps,
    log,
  });
}

async function quoteMinClaimOutForVault({
  publicClient,
  vaultAddress,
  slippageBps,
  log,
}: {
  publicClient: PublicClient;
  vaultAddress: Address;
  slippageBps: number;
  log?: ((msg: string) => void) | null;
}): Promise<{ ok: boolean; minClaimOut?: bigint; error?: string; [key: string]: unknown }> {
  const vaultAbi = LP_STAKING_VAULT_ABI;
  const poolFn = 'lpToken';

  const label = 'LpStakingVault7D';

  try {
    const block = await publicClient.getBlock();
    const blockTs = block.timestamp;

    const [pool, weth, claim, router, factory, stable] = await Promise.all([
      publicClient.readContract({ address: vaultAddress, abi: vaultAbi, functionName: poolFn }),
      publicClient.readContract({ address: vaultAddress, abi: vaultAbi, functionName: 'weth' }),
      publicClient.readContract({ address: vaultAddress, abi: vaultAbi, functionName: 'claim' }),
      publicClient.readContract({
        address: vaultAddress,
        abi: vaultAbi,
        functionName: 'aerodromeRouter',
      }),
      publicClient.readContract({
        address: vaultAddress,
        abi: vaultAbi,
        functionName: 'aerodromeFactory',
      }),
      publicClient.readContract({
        address: vaultAddress,
        abi: vaultAbi,
        functionName: 'wethClaimStable',
      }),
    ]);

    const feeWethBefore: bigint = await publicClient.readContract({
      address: weth,
      abi: ERC20_ABI,
      functionName: 'balanceOf',
      args: [vaultAddress],
    });

    const [token0, token1] = await Promise.all([
      publicClient.readContract({ address: pool, abi: AERODROME_POOL_ABI, functionName: 'token0' }),
      publicClient.readContract({ address: pool, abi: AERODROME_POOL_ABI, functionName: 'token1' }),
    ]);

    // Simulate claimFees as if the vault called it.
    let claimFeesOut: readonly [bigint, bigint];
    try {
      const sim = await publicClient.simulateContract({
        address: pool,
        abi: AERODROME_POOL_ABI,
        functionName: 'claimFees',
        account: vaultAddress,
      });
      claimFeesOut = sim.result;
    } catch (e: unknown) {
      const err = e as { shortMessage?: string; message?: string };
      return {
        ok: false,
        label,
        vaultAddress,
        pool,
        reason: 'claimFees simulation failed',
        error: String(err?.shortMessage ?? err?.message ?? e),
      };
    }

    const [claimed0, claimed1] = claimFeesOut;
    let claimedWeth = 0n;
    if (addrEq(token0, weth)) claimedWeth = claimed0;
    else if (addrEq(token1, weth)) claimedWeth = claimed1;

    const feeWeth = feeWethBefore + claimedWeth;
    const wethToSwap = feeWeth;

    if (wethToSwap === 0n) {
      return {
        ok: true,
        label,
        vaultAddress,
        pool,
        weth,
        claim,
        router,
        factory,
        stable,
        quoteBlockNumber: block.number,
        quoteBlockTimestamp: blockTs,
        feeWethBefore,
        claimedWeth,
        feeWeth,
        wethToSwap,
        expectedClaimOut: 0n,
        minClaimOut: 0n,
      };
    }

    // Quote swap output and apply slippage.
    let amountsOut: readonly bigint[];
    try {
      // tx will execute in a future block. On volatile markets, the swap output
      // can diverge significantly from the quote. The slippageBps tolerance
      // (configurable, max 5000 = 50%) provides a buffer, but operators should
      // set this as tight as possible.
      // Suggested fix: consider fetching the quote inside the sendContractTx
      // flow (as part of gas estimation) to minimize the time gap, or add a
      // freshness check that re-quotes if > N seconds have elapsed.
      amountsOut = await publicClient.readContract({
        address: router,
        abi: AERODROME_ROUTER_ABI,
        functionName: 'getAmountsOut',
        args: [wethToSwap, [{ from: weth, to: claim, stable, factory }]],
      });
    } catch (e: unknown) {
      const err = e as { shortMessage?: string; message?: string };
      return {
        ok: false,
        label,
        vaultAddress,
        pool,
        weth,
        claim,
        router,
        factory,
        stable,
        reason: 'router getAmountsOut failed',
        error: String(err?.shortMessage ?? err?.message ?? e),
      };
    }

    const expectedClaimOut =
      Array.isArray(amountsOut) && amountsOut.length > 0 ? amountsOut[amountsOut.length - 1] : 0n;
    const minClaimOut = applyBps(expectedClaimOut, slippageBps);

    if (log) {
      log(
        `${label} quote: wethToSwap=${wethToSwap.toString()} expectedClaimOut=${expectedClaimOut.toString()} minClaimOut=${minClaimOut.toString()}`,
      );
    }

    return {
      ok: true,
      label,
      vaultAddress,
      pool,
      weth,
      claim,
      router,
      factory,
      stable,
      quoteBlockNumber: block.number,
      quoteBlockTimestamp: blockTs,
      feeWethBefore,
      claimedWeth,
      feeWeth,
      wethToSwap,
      expectedClaimOut,
      minClaimOut,
    };
  } catch (e: unknown) {
    const err = e as { shortMessage?: string; message?: string };
    return {
      ok: false,
      label,
      vaultAddress,
      reason: 'unexpected quote error',
      error: String(err?.shortMessage ?? err?.message ?? e),
    };
  }
}

/**
 * CLAIM out for a fixed 1 WETH swap along the vault's Aerodrome route (drift / gating reads).
 */
export async function readStakingVaultClaimOutForOneWeth({
  publicClient,
  vaultAddress,
}: {
  publicClient: PublicClient;
  vaultAddress: Address;
}): Promise<{ ok: true; claimOut: bigint } | { ok: false; error: string }> {
  const vaultAbi = LP_STAKING_VAULT_ABI;
  try {
    const [weth, claim, router, factory, stable] = await Promise.all([
      publicClient.readContract({ address: vaultAddress, abi: vaultAbi, functionName: 'weth' }),
      publicClient.readContract({ address: vaultAddress, abi: vaultAbi, functionName: 'claim' }),
      publicClient.readContract({
        address: vaultAddress,
        abi: vaultAbi,
        functionName: 'aerodromeRouter',
      }),
      publicClient.readContract({
        address: vaultAddress,
        abi: vaultAbi,
        functionName: 'aerodromeFactory',
      }),
      publicClient.readContract({
        address: vaultAddress,
        abi: vaultAbi,
        functionName: 'wethClaimStable',
      }),
    ]);

    const amountsOut = await publicClient.readContract({
      address: router,
      abi: AERODROME_ROUTER_ABI,
      functionName: 'getAmountsOut',
      args: [parseEther('1'), [{ from: weth, to: claim, stable, factory }]],
    });

    const claimOut =
      Array.isArray(amountsOut) && amountsOut.length > 0
        ? (amountsOut[amountsOut.length - 1] as bigint)
        : 0n;

    return { ok: true, claimOut };
  } catch (e: unknown) {
    const err = e as { shortMessage?: string; message?: string };
    return {
      ok: false,
      error: String(err?.shortMessage ?? err?.message ?? e),
    };
  }
}

export async function quoteMinVeOut({
  publicClient,
  furnaceAddress,
  user,
  claimIn,
  targetTokenId,
  durationSeconds,
  createAutoMax,
  slippageBps,
}: {
  publicClient: PublicClient;
  furnaceAddress: Address;
  user: Address;
  claimIn: bigint;
  targetTokenId: bigint;
  durationSeconds: bigint;
  createAutoMax: boolean;
  slippageBps: number;
}): Promise<{
  principalClaim: bigint;
  bonusClaim: bigint;
  veOut: bigint;
  routeTokenId: bigint;
  minVeOut: bigint;
}> {
  const out = await publicClient.readContract({
    address: furnaceAddress,
    abi: FURNACE_ABI,
    functionName: 'quoteEnterWithClaim',
    args: [user, claimIn, targetTokenId, durationSeconds, createAutoMax],
  });

  const veOut: bigint = out?.[2] ?? 0n;
  const minVeOut = applyBps(veOut, slippageBps);

  return {
    principalClaim: out?.[0] ?? 0n,
    bonusClaim: out?.[1] ?? 0n,
    veOut,
    routeTokenId: out?.[3] ?? 0n,
    minVeOut,
  };
}

export async function quoteMinVeOutEth({
  publicClient,
  furnaceAddress,
  user,
  ethIn,
  targetTokenId,
  durationSeconds,
  createAutoMax,
  slippageBps,
}: {
  publicClient: PublicClient;
  furnaceAddress: Address;
  user: Address;
  ethIn: bigint;
  targetTokenId: bigint;
  durationSeconds: bigint;
  createAutoMax: boolean;
  slippageBps: number;
}): Promise<{
  principalClaim: bigint;
  bonusClaim: bigint;
  veOut: bigint;
  routeTokenId: bigint;
  minVeOut: bigint;
}> {
  const out = await publicClient.readContract({
    address: furnaceAddress,
    abi: FURNACE_ABI,
    functionName: 'quoteEnterWithEth',
    args: [user, ethIn, targetTokenId, durationSeconds, createAutoMax],
  });

  const veOut: bigint = out?.[2] ?? 0n;
  const minVeOut = applyBps(veOut, slippageBps);

  return {
    principalClaim: out?.[0] ?? 0n,
    bonusClaim: out?.[1] ?? 0n,
    veOut,
    routeTokenId: out?.[3] ?? 0n,
    minVeOut,
  };
}
