import type { Address } from 'viem';
import type { ClaimRushContracts } from './contracts.js';

export type FurnaceQuoteEnterResult = {
  principalClaim: bigint;
  bonusClaim: bigint;
  veOut: bigint;
  routeTokenId: bigint;
};

export type FurnaceQuoteSellLockToFurnaceResult = {
  /** Amount of CLAIM currently locked in the veNFT. */
  lockAmount: bigint;
  /** Amount of liquid CLAIM expected out from selling the lock to the Furnace. */
  claimOut: bigint;
  /** Spread applied to the sell price, in basis points. */
  spreadBps: bigint;
  /** LP reward paid out as part of the sell (CLAIM). */
  lpReward: bigint;
  /** Amount added to the Furnace reserve (CLAIM). */
  reserveAdd: bigint;
};

export type MineCoreTakeoverWithTokenQuote = {
  /** Expected native ETH output from swapping `amountIn` of `tokenIn` via MineCore's allowlisted takeover route. */
  ethOut: bigint;
  /** The current takeover price at `block.timestamp` (returned for convenience). */
  takeoverPrice: bigint;
};

export type MineCoreRegistryRoute = {
  tokenIn: Address;
  tokenOut: Address;
  stable: boolean;
  pool: Address;
};

function requireContract(contracts: ClaimRushContracts, name: string): any {
  const c = (contracts as any)[name];
  if (!c) throw new Error(`Missing required contract '${name}' in manifest/contracts map`);
  return c;
}

/** MineCore.getCurrentTakeoverPrice() */
export async function quoteCurrentTakeoverPrice(params: {
  contracts: ClaimRushContracts;
}): Promise<bigint> {
  const mineCore = requireContract(params.contracts, 'MineCore');
  const price = await mineCore.read.getCurrentTakeoverPrice();
  return price as bigint;
}

/** FurnaceQuoter.getFurnaceState() */
export async function getFurnaceState(params: { contracts: ClaimRushContracts }): Promise<unknown> {
  const quoter = requireContract(params.contracts, 'FurnaceQuoter');
  return await quoter.read.getFurnaceState();
}

/**
 * FurnaceQuoter.quoteEnterWithEth(user, ethIn, targetTokenId, durationSeconds, createAutoMax)
 * -> (principalClaim, bonusClaim, veOut, routeTokenId)
 */
export async function quoteEnterWithEth(params: {
  contracts: ClaimRushContracts;
  user: Address;
  ethIn: bigint;
  targetTokenId: bigint;
  durationSeconds: bigint;
  createAutoMax: boolean;
}): Promise<FurnaceQuoteEnterResult> {
  const quoter = requireContract(params.contracts, 'FurnaceQuoter');
  const [principalClaim, bonusClaim, veOut, routeTokenId] = (await quoter.read.quoteEnterWithEth([
    params.user,
    params.ethIn,
    params.targetTokenId,
    params.durationSeconds,
    params.createAutoMax,
  ])) as readonly [bigint, bigint, bigint, bigint];

  return { principalClaim, bonusClaim, veOut, routeTokenId };
}

/**
 * FurnaceQuoter.quoteEnterWithClaim(user, claimIn, targetTokenId, durationSeconds, createAutoMax)
 * -> (principalClaim, bonusClaim, veOut, routeTokenId)
 */
export async function quoteEnterWithClaim(params: {
  contracts: ClaimRushContracts;
  user: Address;
  claimIn: bigint;
  targetTokenId: bigint;
  durationSeconds: bigint;
  createAutoMax: boolean;
}): Promise<FurnaceQuoteEnterResult> {
  const quoter = requireContract(params.contracts, 'FurnaceQuoter');
  const [principalClaim, bonusClaim, veOut, routeTokenId] = (await quoter.read.quoteEnterWithClaim([
    params.user,
    params.claimIn,
    params.targetTokenId,
    params.durationSeconds,
    params.createAutoMax,
  ])) as readonly [bigint, bigint, bigint, bigint];

  return { principalClaim, bonusClaim, veOut, routeTokenId };
}

/**
 * FurnaceQuoter.quoteEnterWithToken(user, tokenIn, amountIn, targetTokenId, durationSeconds, createAutoMax)
 * -> (principalClaim, bonusClaim, veOut, routeTokenId)
 */
export async function quoteEnterWithToken(params: {
  contracts: ClaimRushContracts;
  user: Address;
  tokenIn: Address;
  amountIn: bigint;
  targetTokenId: bigint;
  durationSeconds: bigint;
  createAutoMax: boolean;
}): Promise<FurnaceQuoteEnterResult> {
  const quoter = requireContract(params.contracts, 'FurnaceQuoter');
  const [principalClaim, bonusClaim, veOut, routeTokenId] = (await quoter.read.quoteEnterWithToken([
    params.user,
    params.tokenIn,
    params.amountIn,
    params.targetTokenId,
    params.durationSeconds,
    params.createAutoMax,
  ])) as readonly [bigint, bigint, bigint, bigint];

  return { principalClaim, bonusClaim, veOut, routeTokenId };
}

/**
 * FurnaceQuoter.quoteSellLockToFurnace(user, tokenId)
 * -> (lockAmount, claimOut, spreadBps, lpReward, reserveAdd)
 */
export async function quoteSellLockToFurnace(params: {
  contracts: ClaimRushContracts;
  user: Address;
  tokenId: bigint;
}): Promise<FurnaceQuoteSellLockToFurnaceResult> {
  const quoter = requireContract(params.contracts, 'FurnaceQuoter');
  const [lockAmount, claimOut, spreadBps, lpReward, reserveAdd] =
    (await quoter.read.quoteSellLockToFurnace([params.user, params.tokenId])) as readonly [
      bigint,
      bigint,
      bigint,
      bigint,
      bigint,
    ];

  return { lockAmount, claimOut, spreadBps, lpReward, reserveAdd };
}

/**
 * MineCoreQuoter.quoteTakeoverWithToken(tokenIn, amountIn) -> (ethOut, takeoverPrice)
 *
 * Use-case
 * - Offchain agents/UIs need a canonical way to compute `minEthOut` for:
 *   `MineCore.takeoverWithToken(tokenIn, amountIn, minEthOut)`
 */
export async function quoteTakeoverWithToken(params: {
  contracts: ClaimRushContracts;
  tokenIn: Address;
  amountIn: bigint;
}): Promise<MineCoreTakeoverWithTokenQuote> {
  const quoter = requireContract(params.contracts, 'MineCoreQuoter');
  const [ethOut, takeoverPrice] = (await quoter.read.quoteTakeoverWithToken([
    params.tokenIn,
    params.amountIn,
  ])) as readonly [bigint, bigint];

  return { ethOut, takeoverPrice };
}

/**
 * MineCoreQuoter.resolveTakeoverRoute(tokenIn) -> RegistryRoute[]
 *
 * Notes
 * - Returns an empty array when tokenIn == wrapped native (implicit unwrap route).
 * - Reverts if tokenIn is not enabled or the registry pool mismatches router.poolFor.
 */
export async function resolveTakeoverRoute(params: {
  contracts: ClaimRushContracts;
  tokenIn: Address;
}): Promise<MineCoreRegistryRoute[]> {
  const quoter = requireContract(params.contracts, 'MineCoreQuoter');
  const raw = (await quoter.read.resolveTakeoverRoute([params.tokenIn])) as any;

  if (!Array.isArray(raw)) return [];
  return raw.map((r: any) => {
    // viem can return tuple structs as objects with both numeric keys and named keys.
    const tokenIn = (r?.tokenIn ?? r?.[0]) as Address;
    const tokenOut = (r?.tokenOut ?? r?.[1]) as Address;
    const stable = (r?.stable ?? r?.[2]) as boolean;
    const pool = (r?.pool ?? r?.[3]) as Address;
    return { tokenIn, tokenOut, stable, pool };
  });
}

/** Convenience: quote + compute `minEthOut` using the standard slippage helper. */
export async function quoteTakeoverWithTokenMinOut(params: {
  contracts: ClaimRushContracts;
  tokenIn: Address;
  amountIn: bigint;
  slippageBps: bigint;
}): Promise<MineCoreTakeoverWithTokenQuote & { minEthOut: bigint }> {
  const q = await quoteTakeoverWithToken(params);
  const minEthOut = minOutFromBps(q.ethOut, params.slippageBps);
  return { ...q, minEthOut };
}

/** Compute a slippage-adjusted minOut value, where bps is in [0, 10_000]. */
export function minOutFromBps(expectedOut: bigint, slippageBps: bigint): bigint {
  if (slippageBps < 0n || slippageBps > 10_000n) throw new Error('slippageBps out of range');
  return (expectedOut * (10_000n - slippageBps)) / 10_000n;
}
