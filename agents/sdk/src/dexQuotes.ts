// DEX quoting helpers.
//
// `quoteDexAmountsOut` returns raw `DexAdapter.getAmountsOut` results. Callers
// that act on these quotes (takeover routing, Furnace entries) must apply
// their own minOut slippage guards — a manipulated pool can return very small
// amounts, and this module intentionally stays quote-only.
//
// Route resolution (`resolveMineCoreTakeoverRoute`, `resolveFurnaceEntryRoute`)
// trusts the on-chain `EntryTokenRegistry`. This is the protocol's designated
// source of truth for routes; callers that need additional validation should
// enforce it at the call site.

import type { Address } from 'viem';
import type { ClaimRushContracts } from './contracts.js';

/**
 * Minimal route struct used by DexAdapter (Aerodrome-style router).
 *
 * Solidity: IDexAdapter.Route { from, to, stable, factory }
 */
export type DexRoute = {
  from: Address;
  to: Address;
  stable: boolean;
  factory: Address;
};

/**
 * Route struct returned by EntryTokenRegistry (Furnace/MineCore).
 *
 * Solidity: IEntryTokenRegistry.RegistryRoute { tokenIn, tokenOut, stable, pool }
 */
export type RegistryRoute = {
  tokenIn: Address;
  tokenOut: Address;
  stable: boolean;
  pool: Address;
};

export type DexAdapterConfig = {
  factory: Address;
  wrappedNative: Address;
};

export type WethClaimHop = {
  stable: boolean;
  pool: Address;
};

const ZERO_ADDRESS = '0x0000000000000000000000000000000000000000' as Address;

function requireContract(contracts: ClaimRushContracts, name: string): any {
  const c = (contracts as any)[name];
  if (!c) throw new Error(`Missing required contract '${name}' in manifest/contracts map`);
  return c;
}

function decodeRegistryRoute(r: any): RegistryRoute {
  // viem can return tuple structs as objects with both numeric keys and named keys.
  const tokenIn = (r?.tokenIn ?? r?.[0]) as Address;
  const tokenOut = (r?.tokenOut ?? r?.[1]) as Address;
  const stable = (r?.stable ?? r?.[2]) as boolean;
  const pool = (r?.pool ?? r?.[3]) as Address;
  if (tokenIn === ZERO_ADDRESS || tokenOut === ZERO_ADDRESS) {
    throw new Error(
      `Registry route contains zero address: tokenIn=${tokenIn}, tokenOut=${tokenOut}`,
    );
  }
  return { tokenIn, tokenOut, stable, pool };
}

export function toDexRoutes(registryRoutes: RegistryRoute[], factory: Address): DexRoute[] {
  return registryRoutes.map((r) => ({
    from: r.tokenIn,
    to: r.tokenOut,
    stable: r.stable,
    factory,
  }));
}

export function reverseDexRoutes(routes: DexRoute[]): DexRoute[] {
  return [...routes]
    .reverse()
    .map((r) => ({ from: r.to, to: r.from, stable: r.stable, factory: r.factory }));
}

/**
 * Read the pinned DexAdapter config (factory + wrapped native).
 */
export async function getDexAdapterConfig(params: {
  contracts: ClaimRushContracts;
}): Promise<DexAdapterConfig> {
  const dex = requireContract(params.contracts, 'DexAdapter');
  const [factory, wrappedNative] = (await Promise.all([
    dex.read.defaultFactory(),
    dex.read.weth(),
  ])) as readonly [Address, Address];

  return { factory, wrappedNative };
}

/**
 * DexAdapter.getAmountsOut(amountIn, routes)
 */
export async function quoteDexAmountsOut(params: {
  contracts: ClaimRushContracts;
  amountIn: bigint;
  // DexAdapter to return [0n, 0n, ...] which is technically correct but
  // could mislead callers into thinking a route exists when it doesn't.
  // FIX: if (params.amountIn <= 0n) throw new Error('amountIn must be > 0');
  routes: DexRoute[];
}): Promise<bigint[]> {
  if (params.amountIn <= 0n) throw new Error('quoteDexAmountsOut: amountIn must be > 0');
  if (!params.routes.length) throw new Error('quoteDexAmountsOut: routes must not be empty');
  const dex = requireContract(params.contracts, 'DexAdapter');
  const amounts = (await dex.read.getAmountsOut([params.amountIn, params.routes])) as bigint[];
  const finalAmount = amounts[amounts.length - 1];
  if (finalAmount === undefined || finalAmount === 0n) {
    throw new Error('quoteDexAmountsOut: route returned zero output — likely no liquidity');
  }
  return amounts;
}

/**
 * FurnaceEntryTokenRegistry.getRouterConfig() -> (router, factory, wrappedNative, claimToken)
 */
export async function getFurnaceRegistryRouterConfig(params: {
  contracts: ClaimRushContracts;
}): Promise<{ router: Address; factory: Address; wrappedNative: Address; claimToken: Address }> {
  const reg = requireContract(params.contracts, 'FurnaceEntryTokenRegistry');
  const [router, factory, wrappedNative, claimToken] =
    (await reg.read.getRouterConfig()) as readonly [Address, Address, Address, Address];
  return { router, factory, wrappedNative, claimToken };
}

/**
 * FurnaceEntryTokenRegistry.getWethClaimHop() -> (stable, pool)
 */
export async function getWethClaimHop(params: {
  contracts: ClaimRushContracts;
}): Promise<WethClaimHop> {
  const reg = requireContract(params.contracts, 'FurnaceEntryTokenRegistry');
  const [stable, pool] = (await reg.read.getWethClaimHop()) as readonly [boolean, Address];
  return { stable, pool };
}

/**
 * Spot quote: ETH (WETH) -> CLAIM using the registry's configured WETH/CLAIM hop.
 */
export async function quoteEthToClaim(params: {
  contracts: ClaimRushContracts;
  ethIn: bigint;
}): Promise<{ claimOut: bigint; routes: DexRoute[]; amounts: bigint[] }> {
  const { factory, wrappedNative, claimToken } = await getFurnaceRegistryRouterConfig({
    contracts: params.contracts,
  });
  const hop = await getWethClaimHop({ contracts: params.contracts });

  const routes: DexRoute[] = [
    {
      from: wrappedNative,
      to: claimToken,
      stable: hop.stable,
      factory,
    },
  ];
  const amounts = await quoteDexAmountsOut({
    contracts: params.contracts,
    amountIn: params.ethIn,
    routes,
  });
  const claimOut = amounts[amounts.length - 1];
  if (claimOut === undefined) throw new Error('quoteEthToClaim: amounts array is empty');
  return { claimOut, routes, amounts };
}

/**
 * Spot quote: CLAIM -> ETH (WETH) using the registry's configured WETH/CLAIM hop (reversed).
 */
export async function quoteClaimToEth(params: {
  contracts: ClaimRushContracts;
  claimIn: bigint;
}): Promise<{ ethOut: bigint; routes: DexRoute[]; amounts: bigint[] }> {
  const { factory, wrappedNative, claimToken } = await getFurnaceRegistryRouterConfig({
    contracts: params.contracts,
  });
  const hop = await getWethClaimHop({ contracts: params.contracts });

  const routes: DexRoute[] = [
    {
      from: claimToken,
      to: wrappedNative,
      stable: hop.stable,
      factory,
    },
  ];
  const amounts = await quoteDexAmountsOut({
    contracts: params.contracts,
    amountIn: params.claimIn,
    routes,
  });
  const ethOut = amounts[amounts.length - 1];
  if (ethOut === undefined) throw new Error('quoteClaimToEth: amounts array is empty');
  return { ethOut, routes, amounts };
}

/**
 * MineCoreEntryTokenRegistry.resolveTakeoverRoute(tokenIn) -> RegistryRoute[]
 *
 * This is the canonical allowlisted route used by MineCore.takeoverWithToken.
 */
export async function resolveMineCoreTakeoverRoute(params: {
  contracts: ClaimRushContracts;
  tokenIn: Address;
}): Promise<{ route: RegistryRoute[]; factory: Address }> {
  const reg = requireContract(params.contracts, 'MineCoreEntryTokenRegistry');
  const [, factory] = (await reg.read.getRouterConfig()) as readonly [
    Address,
    Address,
    Address,
    Address,
  ];
  const raw = (await reg.read.resolveTakeoverRoute([params.tokenIn])) as any;
  const route: RegistryRoute[] = Array.isArray(raw) ? raw.map(decodeRegistryRoute) : [];
  return { route, factory };
}

/**
 * FurnaceEntryTokenRegistry.resolveFurnaceRoute(tokenIn) -> (RegistryRoute[] route, uint256 routeTokenId)
 *
 * Special-case: for tokenIn == wrapped native (WETH), mirror Furnace.enterWithToken(WETH, ...)
 * by returning the canonical single-hop WETH -> CLAIM route from getWethClaimHop().
 */
export async function resolveFurnaceEntryRoute(params: {
  contracts: ClaimRushContracts;
  tokenIn: Address;
}): Promise<{ route: RegistryRoute[]; routeTokenId: bigint; factory: Address }> {
  const reg = requireContract(params.contracts, 'FurnaceEntryTokenRegistry');
  const [, factory, wrappedNative, claimToken] = (await reg.read.getRouterConfig()) as readonly [
    Address,
    Address,
    Address,
    Address,
  ];

  if (params.tokenIn.toLowerCase() === wrappedNative.toLowerCase()) {
    const [stable, pool] = (await reg.read.getWethClaimHop()) as readonly [boolean, Address];
    if (pool.toLowerCase() === ZERO_ADDRESS.toLowerCase()) {
      throw new Error('FurnaceEntryTokenRegistry WETH/CLAIM hop is not configured');
    }

    const route: RegistryRoute[] = [
      {
        tokenIn: wrappedNative,
        tokenOut: claimToken,
        stable,
        pool,
      },
    ];
    return { route, routeTokenId: 1n, factory };
  }

  const [rawRoute, routeTokenId] = (await reg.read.resolveFurnaceRoute([params.tokenIn])) as any;
  const route: RegistryRoute[] = Array.isArray(rawRoute) ? rawRoute.map(decodeRegistryRoute) : [];
  return { route, routeTokenId: routeTokenId as bigint, factory };
}

/**
 * Quote tokenIn -> ETH using MineCore's allowlisted takeover route, but via DexAdapter.getAmountsOut.
 *
 * Notes
 * - For takeovers specifically, prefer MineCoreQuoter.quoteTakeoverWithToken(...), which also returns takeoverPrice.
 */
export async function quoteEntryTokenToEth(params: {
  contracts: ClaimRushContracts;
  tokenIn: Address;
  amountIn: bigint;
}): Promise<{ ethOut: bigint; routes: DexRoute[]; amounts: bigint[] }> {
  const { route: registryRoute, factory } = await resolveMineCoreTakeoverRoute({
    contracts: params.contracts,
    tokenIn: params.tokenIn,
  });
  if (!registryRoute.length) {
    throw new Error(
      `quoteEntryTokenToEth: MineCore registry returned no route for token ${params.tokenIn}`,
    );
  }
  const routes = toDexRoutes(registryRoute, factory);
  const amounts = await quoteDexAmountsOut({
    contracts: params.contracts,
    amountIn: params.amountIn,
    routes,
  });
  const ethOut = amounts[amounts.length - 1];
  if (ethOut === undefined) throw new Error('quoteEntryTokenToEth: amounts array is empty');
  return { ethOut, routes, amounts };
}

/**
 * Quote tokenIn -> CLAIM using Furnace's allowlisted entry route (direct-to-CLAIM if configured, else via WETH).
 */
export async function quoteEntryTokenToClaim(params: {
  contracts: ClaimRushContracts;
  tokenIn: Address;
  amountIn: bigint;
}): Promise<{ claimOut: bigint; routes: DexRoute[]; amounts: bigint[]; routeTokenId: bigint }> {
  const {
    route: registryRoute,
    factory,
    routeTokenId,
  } = await resolveFurnaceEntryRoute({
    contracts: params.contracts,
    tokenIn: params.tokenIn,
  });
  if (!registryRoute.length) {
    throw new Error(
      `quoteEntryTokenToClaim: Furnace registry returned no route for token ${params.tokenIn}`,
    );
  }
  const routes = toDexRoutes(registryRoute, factory);
  const amounts = await quoteDexAmountsOut({
    contracts: params.contracts,
    amountIn: params.amountIn,
    routes,
  });
  const claimOut = amounts[amounts.length - 1];
  if (claimOut === undefined) throw new Error('quoteEntryTokenToClaim: amounts array is empty');
  return { claimOut, routes, amounts, routeTokenId };
}
