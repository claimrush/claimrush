// Live-price quoting helpers.
//
// `getLivePrices` combines on-chain spot quotes (via DexAdapter) with the
// subgraph's `TokenPricingSnapshot` (TWAP-derived CLAIM<->ETH reference). The
// subgraph snapshot is NOT validated for freshness inside this module —
// callers that act on prices economically (takeovers, furnace entries, auto
// compounding) must check `snapshot.updatedAt` against the current block
// timestamp themselves and fall back to spot-only (or abort) when the TWAP is
// too stale. `createLivePricesCache` wraps these reads in `AsyncTtlCache`, so
// the staleness decision lives with the consumer that sets the TTL.

import type { Address, PublicClient } from 'viem';
import { erc20Abi, isAddress } from 'viem';

import type { ClaimRushContracts } from './contracts.js';
import {
  getDexAdapterConfig,
  quoteClaimToEth,
  quoteDexAmountsOut,
  quoteEntryTokenToClaim,
  quoteEntryTokenToEth,
  quoteEthToClaim,
} from './dexQuotes.js';
import type { DexRoute } from './dexQuotes.js';
import {
  SubgraphClient,
  getEntryTokenConfigs,
  getSubgraphProtocol,
  getTokenPricingSnapshot,
  normalizeSubgraphAddress,
  type SubgraphEntryTokenConfig,
  type SubgraphTokenPricingSnapshot,
} from './subgraph.js';

import { DEFAULT_PUBLIC_HTTP_URL_POLICY, type OutboundUrlPolicy } from './security/url.js';

import { safeErrorString } from './security/redact.js';

import { AsyncTtlCache } from './util/asyncTtlCache.js';
import { Semaphore } from './util/semaphore.js';

const STRICT_POSITIVE_DECIMAL_RE = /^\d+(?:\.\d+)?$/;

/**
 * Fail-closed parser for user-provided positive decimal strings (e.g. ETH
 * amounts, slippage fractions).
 *
 * Returns a positive finite number or `null` when the input is not a
 * canonical non-negative decimal. Zero is rejected as "positive" means
 * strictly greater than zero.
 */
export function parseStrictPositiveDecimalString(value: unknown): number | null {
  if (typeof value !== 'string') return null;
  const s = value.trim();
  if (!s || !STRICT_POSITIVE_DECIMAL_RE.test(s)) return null;
  const n = Number(s);
  if (!Number.isFinite(n) || n <= 0) return null;
  return n;
}

export type Erc20Meta = {
  address: Address;
  symbol?: string;
  name?: string;
  decimals?: number;
};

export type SpotQuote = {
  amountIn: bigint;
  amountOut: bigint;
  routes: DexRoute[];
  amounts: bigint[];
};

export type LiveEntryTokenPrice = {
  token: Erc20Meta;
  enabledInFurnace: boolean;
  enabledInMineCore: boolean;
  /** Optional subgraph config (informational only; onchain registry is source of truth for routing). */
  furnaceConfig?: {
    directToClaimEnabled: boolean;
    tokenClaimStable: boolean;
    tokenWethStable: boolean;
    exactReceiptSafe: boolean;
    updatedAt?: bigint;
  };
  /** Optional subgraph config (informational only; onchain registry is source of truth for routing). */
  mineCoreConfig?: {
    tokenWethStable: boolean;
    updatedAt?: bigint;
  };
  spot: {
    /** Spot quote for 1 token -> ETH (WETH). */
    tokenToEth?: SpotQuote;
    /** Spot quote for 1 token -> CLAIM (Furnace route). */
    tokenToClaim?: SpotQuote;
  };
  errors?: {
    meta?: string;
    tokenToEth?: string;
    tokenToClaim?: string;
  };
};

export type LivePricesSnapshot = {
  meta: {
    blockNumber: bigint;
    blockTimestamp: bigint;
  };
  eth: {
    symbol: 'ETH';
    decimals: 18;
    /** Optional ETH/USD from the subgraph (BigDecimal string). */
    usd?: string;
    usdUpdatedAt?: bigint;
  };
  claim: {
    token: Erc20Meta;
    /** Spot quotes (via DexAdapter) for 1 ETH and 1 CLAIM. */
    spot?: {
      claimOutPer1Eth: bigint;
      ethOutPer1Claim: bigint;
      routesEthToClaim: DexRoute[];
      routesClaimToEth: DexRoute[];
    };
    /** Optional CLAIM/ETH TWAP (BigDecimal string) from the subgraph. */
    claimEthTwap30m?: string;
    twapUpdatedAt?: bigint;
  };
  /** Entry tokens discovered (typically from the subgraph). */
  entryTokens: LiveEntryTokenPrice[];

  /** Optional raw subgraph snapshot for auditing/debug. */
  tokenPricingSnapshot?: SubgraphTokenPricingSnapshot | null;

  warnings: string[];
};

export type GetLivePricesParams = {
  contracts: ClaimRushContracts;
  publicClient: PublicClient;
  /** Subgraph endpoint used to enumerate entry tokens and read optional pricing snapshots. */
  subgraphUrl?: string;
  /** Optional outbound URL policy for subgraph calls (SSRF hardening). */
  subgraphNetworkPolicy?: OutboundUrlPolicy;
  /** Optional override list of entry tokens (skip subgraph enumeration). */
  entryTokens?: Address[];
  /** Max number of entry tokens to quote (after de-dupe). Default: 200. */
  maxTokens?: number;
  /** Whether to query subgraph TokenPricingSnapshot (TWAP + ETH/USD). Default: true. */
  includeSubgraphPricing?: boolean;
  /** Max concurrency for onchain reads (metadata + quotes). Default: 8. */
  concurrency?: number;
  /** Optional in-memory cache to reduce RPC/subgraph load across repeated snapshots. */
  cache?: LivePricesCache;
  /** Max age (seconds) for subgraph TWAP before it is treated as stale. Default: 600 (10 min). */
  maxTwapStaleSec?: number;
};

export type LiveEntryTokenFlags = {
  enabledInFurnace: boolean;
  enabledInMineCore: boolean;
  furnaceConfig?: LiveEntryTokenPrice['furnaceConfig'];
  mineCoreConfig?: LiveEntryTokenPrice['mineCoreConfig'];
};

export type LivePricesCacheTtls = {
  /** ERC20 metadata (name/symbol/decimals) TTL. Default: 6h. */
  erc20MetaMs: number;
  /** DexAdapter config (factory + wrapped native) TTL. Default: 5m. */
  dexConfigMs: number;
  /** Entry token flags (from the subgraph) TTL. Default: 60s. */
  entryTokenFlagsMs: number;
  /** Subgraph TokenPricingSnapshot TTL. Default: 15s. */
  subgraphPricingMs: number;
  /** CLAIM spot quotes TTL. Default: 5s. */
  claimSpotQuoteMs: number;
  /** Entry token spot quotes TTL (token->ETH + token->CLAIM). Default: 5s. */
  entryTokenSpotQuoteMs: number;
};

export type CreateLivePricesCacheParams = {
  /** Global RPC concurrency throttle used by getLivePrices when a cache is provided. Default: 16. */
  rpcConcurrency?: number;
  /** Max entries per cache map (best-effort). Default: 10_000. */
  maxEntries?: number;
  /** Override cache TTLs. */
  ttls?: Partial<LivePricesCacheTtls>;
};

export type LivePricesCache = {
  /** Set on first use to avoid repeated chainId RPC calls. */
  chainId?: number;
  /** RPC limiter used to throttle onchain and subgraph reads when caching is enabled. */
  limiter: Semaphore;
  ttls: LivePricesCacheTtls;

  // Long-ish lived caches
  erc20Meta: AsyncTtlCache<Erc20Meta>;
  dexConfig: AsyncTtlCache<{ factory: Address; wrappedNative: Address }>;

  // Subgraph surfaces
  entryTokenFlags: AsyncTtlCache<Array<[Address, LiveEntryTokenFlags]>>;
  subgraphPricing: AsyncTtlCache<SubgraphTokenPricingSnapshot | null>;

  // Short-lived quote caches
  claimSpot: AsyncTtlCache<NonNullable<LivePricesSnapshot['claim']['spot']>>;
  entryTokenToEth: AsyncTtlCache<SpotQuote>;
  entryTokenToClaim: AsyncTtlCache<SpotQuote>;
};

function clampFiniteInt(value: unknown, fallback: number, min: number, max: number): number {
  const n = typeof value === 'number' ? value : Number(value);
  if (!Number.isFinite(n)) return fallback;
  const i = Math.trunc(n);
  if (i < min) return min;
  if (i > max) return max;
  return i;
}

export function createLivePricesCache(params: CreateLivePricesCacheParams = {}): LivePricesCache {
  const ttls: LivePricesCacheTtls = {
    erc20MetaMs: 6 * 60 * 60 * 1000,
    dexConfigMs: 5 * 60 * 1000,
    entryTokenFlagsMs: 60 * 1000,
    subgraphPricingMs: 15 * 1000,
    claimSpotQuoteMs: 5 * 1000,
    entryTokenSpotQuoteMs: 5 * 1000,
    ...(params.ttls ?? {}),
  };

  const maxEntries = clampFiniteInt(params.maxEntries, 10_000, 1, 100_000);
  const rpcConcurrency = clampFiniteInt(params.rpcConcurrency, 16, 1, 128);
  const limiter = new Semaphore(rpcConcurrency);

  return {
    chainId: undefined,
    limiter,
    ttls,
    erc20Meta: new AsyncTtlCache({ maxEntries }),
    dexConfig: new AsyncTtlCache({ maxEntries: 64 }),
    entryTokenFlags: new AsyncTtlCache({ maxEntries: 64 }),
    subgraphPricing: new AsyncTtlCache({ maxEntries: 64 }),
    claimSpot: new AsyncTtlCache({ maxEntries: 256 }),
    entryTokenToEth: new AsyncTtlCache({ maxEntries }),
    entryTokenToClaim: new AsyncTtlCache({ maxEntries }),
  };
}

type EntryTokenRegistryTokenConfig = {
  enabled: boolean;
  directToClaimEnabled: boolean;
  tokenClaimStable: boolean;
  tokenClaimPool: Address;
  tokenWethStable: boolean;
  tokenWethPool: Address;
};

function decodeRegistryTokenConfig(raw: any): EntryTokenRegistryTokenConfig {
  // viem may return tuples as objects with both numeric keys and named keys.
  const enabled = (raw?.enabled ?? raw?.[0]) as boolean;
  const directToClaimEnabled = (raw?.directToClaimEnabled ?? raw?.[1]) as boolean;
  const tokenClaimStable = (raw?.tokenClaimStable ?? raw?.[2]) as boolean;
  const tokenClaimPool = (raw?.tokenClaimPool ?? raw?.[3]) as Address;
  const tokenWethStable = (raw?.tokenWethStable ?? raw?.[4]) as boolean;
  const tokenWethPool = (raw?.tokenWethPool ?? raw?.[5]) as Address;
  return {
    enabled,
    directToClaimEnabled,
    tokenClaimStable,
    tokenClaimPool,
    tokenWethStable,
    tokenWethPool,
  };
}

function pow10(decimals: number): bigint {
  if (!Number.isFinite(decimals) || decimals < 0 || decimals > 36)
    throw new Error(`Invalid decimals: ${decimals}`);
  let out = 1n;
  for (let i = 0; i < decimals; i++) out *= 10n;
  return out;
}

function asBigintOrUndefined(value: string | null | undefined): bigint | undefined {
  if (!value) return undefined;
  try {
    return BigInt(value);
  } catch {
    return undefined;
  }
}

async function readErc20Meta(params: {
  publicClient: PublicClient;
  token: Address;
}): Promise<Erc20Meta> {
  const { publicClient, token } = params;
  const meta: Erc20Meta = { address: token };

  // decimals
  try {
    const decimals = (await publicClient.readContract({
      address: token,
      abi: erc20Abi,
      functionName: 'decimals',
    })) as number;
    if (Number.isFinite(decimals)) meta.decimals = decimals;
  } catch {
    // ignore
  }

  // symbol
  try {
    const symbol = (await publicClient.readContract({
      address: token,
      abi: erc20Abi,
      functionName: 'symbol',
    })) as string;
    if (typeof symbol === 'string' && symbol.length) meta.symbol = symbol;
  } catch {
    // ignore
  }

  // name
  try {
    const name = (await publicClient.readContract({
      address: token,
      abi: erc20Abi,
      functionName: 'name',
    })) as string;
    if (typeof name === 'string' && name.length) meta.name = name;
  } catch {
    // ignore
  }

  return meta;
}

async function mapWithConcurrency<T, R>(
  items: T[],
  concurrency: number,
  fn: (item: T, i: number) => Promise<R>,
): Promise<R[]> {
  const limit = Math.max(1, Math.floor(concurrency));
  const out: R[] = new Array(items.length);
  let nextIndex = 0;

  async function worker(): Promise<void> {
    while (true) {
      const i = nextIndex++;
      if (i >= items.length) return;
      out[i] = await fn(items[i] as T, i);
    }
  }

  const workers = Array.from({ length: Math.min(limit, items.length) }, () => worker());
  await Promise.all(workers);
  return out;
}

function parseEntryTokenConfigForFlags(cfg: SubgraphEntryTokenConfig): {
  token: Address | null;
  registryId: string;
  furnaceConfig?: LiveEntryTokenPrice['furnaceConfig'];
  mineCoreConfig?: LiveEntryTokenPrice['mineCoreConfig'];
} {
  const token = normalizeSubgraphAddress(cfg.tokenIn);
  const registryId = (cfg.registry?.id ?? '').toLowerCase();

  // Heuristic: if directToClaimEnabled exists, it is a Furnace registry surface.
  // MineCore registry also uses the same schema, but directToClaimEnabled is still present.
  const furnaceConfig = {
    directToClaimEnabled: !!cfg.directToClaimEnabled,
    tokenClaimStable: !!cfg.tokenClaimStable,
    tokenWethStable: !!cfg.tokenWethStable,
    exactReceiptSafe: !!cfg.exactReceiptSafe,
    updatedAt: asBigintOrUndefined(cfg.updatedAt),
  };

  const mineCoreConfig = {
    tokenWethStable: !!cfg.tokenWethStable,
    updatedAt: asBigintOrUndefined(cfg.updatedAt),
  };

  return { token, registryId, furnaceConfig, mineCoreConfig };
}

function safeAddress(value: unknown): Address | null {
  if (typeof value !== 'string') return null;
  if (!isAddress(value)) return null;
  return value as Address;
}

/**
 * Fetch a "live" prices snapshot suitable for bots:
 * - Enumerates entry tokens (prefer subgraph; optional manual list).
 * - Pulls ERC20 metadata (name/symbol/decimals).
 * - Uses DexAdapter.getAmountsOut via allowlisted registry routes for spot quotes.
 * - Optionally includes subgraph TokenPricingSnapshot (CLAIM/ETH TWAP + ETH/USD).
 */
export async function getLivePrices(params: GetLivePricesParams): Promise<LivePricesSnapshot> {
  // and optional TWAP/ETH-USD from the subgraph, but:
  //
  // 1) There is NO freshness check on the subgraph TokenPricingSnapshot.
  //    The updatedAt field is exposed but never validated. If the subgraph
  //    is lagging or the TWAP oracle is stale, the SDK will return prices
  //    that are minutes or hours old, and callers (agent strategies) may
  //    execute trades at incorrect valuations.
  //
  // 2) Spot quotes from DexAdapter.getAmountsOut are point-in-time and
  //    subject to sandwich attacks. No slippage protection is applied at
  //    the pricing layer (it is expected to be applied downstream in the
  //    quoting layer, but this is not enforced).
  //
  // FIX: Add a maxStalenessSeconds option and check:
  //   if (subgraphPricing?.updatedAt &&
  //       blockTimestamp - BigInt(subgraphPricing.updatedAt) > maxStaleness)
  //     warnings.push('Subgraph pricing snapshot is stale');
  //   Also consider adding a spot-vs-TWAP divergence warning threshold.
  const warnings: string[] = [];
  const concurrency = clampFiniteInt(params.concurrency, 8, 1, 64);
  const cache = params.cache;
  const limiter = cache?.limiter;

  const withLimit = async <T>(fn: () => Promise<T>): Promise<T> => {
    return limiter ? await limiter.use(fn) : await fn();
  };

  // Resolve chainId once per process when a cache is supplied.
  let chainId: number | undefined;
  if (cache) {
    try {
      if (cache.chainId !== undefined) {
        chainId = cache.chainId;
      } else {
        chainId = await withLimit(() => params.publicClient.getChainId());
        cache.chainId = chainId;
      }
    } catch (err: any) {
      warnings.push(`Failed to read chainId: ${safeErrorString(err)}`);
      chainId = undefined;
    }
  }

  const block = await withLimit(() => params.publicClient.getBlock({ blockTag: 'latest' }));
  const blockNumber = block.number ?? 0n;
  const blockTimestamp = block.timestamp ?? 0n;

  const dexAdapterAddr = (params.contracts as any).DexAdapter?.address;
  const dexKey = `${chainId ?? 'na'}:${typeof dexAdapterAddr === 'string' ? dexAdapterAddr.toLowerCase() : 'na'}`;

  // DexAdapter pinned constants (factory + wrapped native).
  const dexCfg = cache
    ? await cache.dexConfig.getOrSet(`dexCfg:${dexKey}`, cache.ttls.dexConfigMs, () =>
        withLimit(() => getDexAdapterConfig({ contracts: params.contracts })),
      )
    : await getDexAdapterConfig({ contracts: params.contracts });

  // CLAIM token address (from manifest contracts map).
  const claimAddr = safeAddress((params.contracts as any).ClaimToken?.address);
  if (!claimAddr)
    throw new Error("Missing ClaimToken in contracts map (manifest.contracts['ClaimToken']).");
  const claimKey = `${chainId ?? 'na'}:${claimAddr.toLowerCase()}`;

  // CLAIM metadata (cached)
  const claimMeta = cache
    ? await cache.erc20Meta.getOrSet(`meta:${claimKey}`, cache.ttls.erc20MetaMs, () =>
        withLimit(() => readErc20Meta({ publicClient: params.publicClient, token: claimAddr })),
      )
    : await readErc20Meta({ publicClient: params.publicClient, token: claimAddr });

  const claimDecimals = claimMeta.decimals ?? 18;

  // CLAIM spot quotes (cached, short TTL)
  let claimSpot:
    | {
        claimOutPer1Eth: bigint;
        ethOutPer1Claim: bigint;
        routesEthToClaim: DexRoute[];
        routesClaimToEth: DexRoute[];
      }
    | undefined;

  const computeClaimSpot = async () => {
    const ethIn = 10n ** 18n;
    const qEthToClaim = await quoteEthToClaim({ contracts: params.contracts, ethIn });
    const qClaimToEth = await quoteClaimToEth({
      contracts: params.contracts,
      claimIn: pow10(claimDecimals),
    });

    return {
      claimOutPer1Eth: qEthToClaim.claimOut,
      ethOutPer1Claim: qClaimToEth.ethOut,
      routesEthToClaim: qEthToClaim.routes,
      routesClaimToEth: qClaimToEth.routes,
    };
  };

  try {
    claimSpot = cache
      ? await cache.claimSpot.getOrSet(`claimSpot:${claimKey}`, cache.ttls.claimSpotQuoteMs, () =>
          withLimit(computeClaimSpot),
        )
      : await computeClaimSpot();
    if (claimSpot && claimSpot.claimOutPer1Eth === 0n && claimSpot.ethOutPer1Claim === 0n) {
      warnings.push(
        'CLAIM spot quotes returned zero in both directions — discarding as likely invalid',
      );
      if (cache) cache.claimSpot.delete(`claimSpot:${claimKey}`);
      claimSpot = undefined;
    } else if (
      claimSpot &&
      (claimSpot.claimOutPer1Eth === 0n || claimSpot.ethOutPer1Claim === 0n)
    ) {
      warnings.push(
        'CLAIM spot quote is zero in one direction — possible pool manipulation or no liquidity; discarding',
      );
      if (cache) cache.claimSpot.delete(`claimSpot:${claimKey}`);
      claimSpot = undefined;
    }
  } catch (err: any) {
    warnings.push(`Failed to compute CLAIM spot quotes via DexAdapter: ${safeErrorString(err)}`);
  }

  // ---------------------------------------------------------------------------
  // Entry token discovery (subgraph preferred)
  // ---------------------------------------------------------------------------
  const maxTokens = clampFiniteInt(params.maxTokens, 200, 0, 2_000);
  const flagsByToken: Map<Address, LiveEntryTokenFlags> = new Map();
  let subgraphPricing: SubgraphTokenPricingSnapshot | null = null;

  if (params.entryTokens && params.entryTokens.length) {
    const seen = new Set<string>();
    for (const t of params.entryTokens) {
      const addr = safeAddress(t);
      if (!addr) {
        warnings.push(`Ignoring invalid entry token address: ${String(t)}`);
        continue;
      }
      const k = addr.toLowerCase();
      if (seen.has(k)) continue;
      seen.add(k);

      // With a manual list we don't know which registry the token is configured in.
      // Try both surfaces and record per-token errors when a registry route is missing.
      flagsByToken.set(addr, { enabledInFurnace: true, enabledInMineCore: true });

      if (flagsByToken.size >= maxTokens) break;
    }

    if (params.entryTokens.length > maxTokens) {
      warnings.push(`Entry token list truncated: ${params.entryTokens.length} -> ${maxTokens}`);
    }
  } else {
    if (!params.subgraphUrl) {
      throw new Error('getLivePrices: subgraphUrl is required when entryTokens is not provided');
    }

    const chainId =
      cache?.chainId ?? (await params.publicClient.getChainId().catch(() => undefined));
    if (cache && chainId !== undefined) cache.chainId = chainId;
    const subgraphNetworkPolicy =
      params.subgraphNetworkPolicy ??
      (chainId === 31337 ? undefined : DEFAULT_PUBLIC_HTTP_URL_POLICY);

    const sg = new SubgraphClient({
      url: params.subgraphUrl,
      networkPolicy: subgraphNetworkPolicy,
    });

    const tokenFlagsKey = `entryTokenFlags:${(params.subgraphUrl ?? '').toLowerCase()}:${maxTokens}`;

    const fetchFlags = async (): Promise<Array<[Address, LiveEntryTokenFlags]>> => {
      const protocol = await getSubgraphProtocol(sg).catch((err) => {
        warnings.push(`Subgraph protocol query failed: ${safeErrorString(err)}`);
        return null;
      });

      const furnaceRegAddr = normalizeSubgraphAddress(
        protocol?.furnaceEntryTokenRegistry ?? protocol?.entryTokenRegistry,
      );
      const mineCoreRegAddr = normalizeSubgraphAddress(protocol?.mineCoreEntryTokenRegistry);

      const furnaceRegId = furnaceRegAddr ? furnaceRegAddr.toLowerCase() : null;
      const mineCoreRegId = mineCoreRegAddr ? mineCoreRegAddr.toLowerCase() : null;

      if (!furnaceRegId)
        warnings.push('Subgraph: missing furnaceEntryTokenRegistry (and entryTokenRegistry alias)');
      if (!mineCoreRegId) warnings.push('Subgraph: missing mineCoreEntryTokenRegistry');

      const sgConfigs: Array<{ cfg: SubgraphEntryTokenConfig; src: 'furnace' | 'minecore' }> = [];

      if (furnaceRegId) {
        const cfgs = await getEntryTokenConfigs(sg, {
          registryId: furnaceRegId,
          max: maxTokens,
        }).catch((err) => {
          warnings.push(`Subgraph furnace EntryTokenConfig query failed: ${safeErrorString(err)}`);
          return [];
        });
        for (const c of cfgs) sgConfigs.push({ cfg: c, src: 'furnace' });
      }
      if (mineCoreRegId) {
        const cfgs = await getEntryTokenConfigs(sg, {
          registryId: mineCoreRegId,
          max: maxTokens,
        }).catch((err) => {
          warnings.push(`Subgraph minecore EntryTokenConfig query failed: ${safeErrorString(err)}`);
          return [];
        });
        for (const c of cfgs) sgConfigs.push({ cfg: c, src: 'minecore' });
      }

      const tmp: Map<Address, LiveEntryTokenFlags> = new Map();

      for (const { cfg, src } of sgConfigs) {
        const parsed = parseEntryTokenConfigForFlags(cfg);
        if (!parsed.token) continue;

        const existing = tmp.get(parsed.token) ?? {
          enabledInFurnace: false,
          enabledInMineCore: false,
        };

        if (src === 'furnace') {
          existing.enabledInFurnace = !!cfg.enabled && !!cfg.exactReceiptSafe;
          existing.furnaceConfig = parsed.furnaceConfig;
        }
        if (src === 'minecore') {
          existing.enabledInMineCore = true;
          existing.mineCoreConfig = parsed.mineCoreConfig;
        }

        tmp.set(parsed.token, existing);
        if (tmp.size >= maxTokens) break;
      }

      return [...tmp.entries()].filter(
        ([, flags]) => flags.enabledInFurnace || flags.enabledInMineCore,
      );
    };

    let entries: Array<[Address, LiveEntryTokenFlags]> = [];

    try {
      entries = cache
        ? await cache.entryTokenFlags.getOrSet(tokenFlagsKey, cache.ttls.entryTokenFlagsMs, () =>
            withLimit(fetchFlags),
          )
        : await fetchFlags();
    } catch (err: any) {
      warnings.push(`Entry token discovery failed: ${safeErrorString(err)}`);
      entries = [];
    }

    for (const [token, flags] of entries) {
      flagsByToken.set(token, flags);
      if (flagsByToken.size >= maxTokens) break;
    }

    if (params.includeSubgraphPricing ?? true) {
      const pricingKey = `subgraphPricing:${(params.subgraphUrl ?? '').toLowerCase()}`;
      try {
        subgraphPricing = cache
          ? await cache.subgraphPricing.getOrSet(pricingKey, cache.ttls.subgraphPricingMs, () =>
              withLimit(async () => {
                return await getTokenPricingSnapshot(sg).catch((err) => {
                  warnings.push(
                    `Subgraph TokenPricingSnapshot query failed: ${safeErrorString(err)}`,
                  );
                  return null;
                });
              }),
            )
          : await getTokenPricingSnapshot(sg).catch((err) => {
              warnings.push(`Subgraph TokenPricingSnapshot query failed: ${safeErrorString(err)}`);
              return null;
            });
      } catch (err: any) {
        warnings.push(`Subgraph TokenPricingSnapshot query failed: ${safeErrorString(err)}`);
      }
    }
  }

  const tokenList = [...flagsByToken.entries()];

  const entryTokens: LiveEntryTokenPrice[] = await mapWithConcurrency(
    tokenList,
    concurrency,
    async ([tokenAddr, flags]): Promise<LiveEntryTokenPrice> => {
      const errors: LiveEntryTokenPrice['errors'] = {};
      const tokenKey = `${chainId ?? 'na'}:${tokenAddr.toLowerCase()}`;

      const meta = await (
        cache
          ? cache.erc20Meta.getOrSet(`meta:${tokenKey}`, cache.ttls.erc20MetaMs, () =>
              withLimit(() =>
                readErc20Meta({ publicClient: params.publicClient, token: tokenAddr }),
              ),
            )
          : readErc20Meta({ publicClient: params.publicClient, token: tokenAddr })
      ).catch((err: any) => {
        errors.meta = safeErrorString(err);
        return { address: tokenAddr } as Erc20Meta;
      });

      const decimals = meta.decimals ?? 18;
      const amountIn = pow10(decimals);

      let tokenToClaim: SpotQuote | undefined;
      let tokenToEth: SpotQuote | undefined;

      if (flags.enabledInFurnace) {
        try {
          const quoteKey = `q:t2c:${tokenKey}:${amountIn.toString()}`;

          tokenToClaim = cache
            ? await cache.entryTokenToClaim.getOrSet(
                quoteKey,
                cache.ttls.entryTokenSpotQuoteMs,
                () =>
                  withLimit(async () => {
                    const q = await quoteEntryTokenToClaim({
                      contracts: params.contracts,
                      tokenIn: tokenAddr,
                      amountIn,
                    });
                    return {
                      amountIn,
                      amountOut: q.claimOut,
                      routes: q.routes,
                      amounts: q.amounts,
                    };
                  }),
              )
            : await (async () => {
                const q = await quoteEntryTokenToClaim({
                  contracts: params.contracts,
                  tokenIn: tokenAddr,
                  amountIn,
                });
                return { amountIn, amountOut: q.claimOut, routes: q.routes, amounts: q.amounts };
              })();
        } catch (err: any) {
          errors.tokenToClaim = safeErrorString(err);
        }
      }

      // token -> ETH (MineCore route preferred; Furnace fallback)
      if (flags.enabledInMineCore || flags.enabledInFurnace) {
        try {
          const quoteKey = `q:t2e:${tokenKey}:${amountIn.toString()}`;

          const computeTokenToEth = async (): Promise<SpotQuote> => {
            // Prefer MineCore takeover route if the token is enabled there.
            if (flags.enabledInMineCore) {
              const q = await quoteEntryTokenToEth({
                contracts: params.contracts,
                tokenIn: tokenAddr,
                amountIn,
              });
              return { amountIn, amountOut: q.ethOut, routes: q.routes, amounts: q.amounts };
            }

            // Fallback: token -> WETH using Furnace registry token config.
            const reg = (params.contracts as any).FurnaceEntryTokenRegistry;
            if (!reg) throw new Error('Missing FurnaceEntryTokenRegistry in contracts map');

            const rawCfg = await reg.read.getTokenConfig([tokenAddr]);
            const cfg = decodeRegistryTokenConfig(rawCfg);
            if (!cfg.enabled) throw new Error('Token disabled in Furnace registry');

            const routes: DexRoute[] = [
              {
                from: tokenAddr,
                to: dexCfg.wrappedNative,
                stable: cfg.tokenWethStable,
                factory: dexCfg.factory,
              },
            ];

            const amounts = await quoteDexAmountsOut({
              contracts: params.contracts,
              amountIn,
              routes,
            });
            const ethOut = amounts[amounts.length - 1];
            if (ethOut === undefined || ethOut === 0n) {
              throw new Error(
                `Fallback token-to-ETH quote returned zero or empty output for ${tokenAddr}`,
              );
            }
            return { amountIn, amountOut: ethOut, routes, amounts };
          };

          tokenToEth = cache
            ? await cache.entryTokenToEth.getOrSet(quoteKey, cache.ttls.entryTokenSpotQuoteMs, () =>
                withLimit(computeTokenToEth),
              )
            : await computeTokenToEth();
        } catch (err: any) {
          errors.tokenToEth = safeErrorString(err);
        }
      }

      const out: LiveEntryTokenPrice = {
        token: meta,
        enabledInFurnace: flags.enabledInFurnace,
        enabledInMineCore: flags.enabledInMineCore,
        furnaceConfig: flags.furnaceConfig,
        mineCoreConfig: flags.mineCoreConfig,
        spot: { tokenToEth, tokenToClaim },
      };

      if (errors.meta || errors.tokenToEth || errors.tokenToClaim) out.errors = errors;
      return out;
    },
  );

  // Sort for stable outputs.
  entryTokens.sort((a, b) => {
    const as = (a.token.symbol ?? '').toLowerCase();
    const bs = (b.token.symbol ?? '').toLowerCase();
    if (as && bs && as !== bs) return as.localeCompare(bs);
    return a.token.address.localeCompare(b.token.address);
  });

  // Optional subgraph TWAP + ETH/USD
  const MAX_TWAP_STALE_SEC = BigInt(Math.max(1, Math.floor(params.maxTwapStaleSec ?? 600)));
  const twapUpdatedAt = asBigintOrUndefined(subgraphPricing?.updatedAt);
  const ethUsdUpdatedAt = asBigintOrUndefined(subgraphPricing?.ethUsdUpdatedAt);

  if (subgraphPricing && twapUpdatedAt !== undefined && blockTimestamp > 0n) {
    if (blockTimestamp - twapUpdatedAt > MAX_TWAP_STALE_SEC) {
      warnings.push(
        `Subgraph pricing snapshot is stale (age=${blockTimestamp - twapUpdatedAt}s, threshold=${MAX_TWAP_STALE_SEC}s). ` +
          `TWAP and ETH/USD data may be outdated.`,
      );
      // Nullify stale pricing so callers fall back to spot-only quotes
      // rather than making trade decisions on outdated TWAP/ETH-USD data.
      subgraphPricing = subgraphPricing
        ? { ...subgraphPricing, claimEthTwap30m: null, ethUsd: null }
        : null;
    }
  }

  // Spot-vs-TWAP divergence check: warn when live spot price and subgraph TWAP
  // disagree by more than 20%, which may indicate oracle staleness or manipulation.
  if (subgraphPricing?.claimEthTwap30m && claimSpot && claimSpot.ethOutPer1Claim > 0n) {
    try {
      const twapRaw = subgraphPricing.claimEthTwap30m;
      const twapFloat = parseFloat(twapRaw);
      if (Number.isFinite(twapFloat) && twapFloat > 0) {
        const spotFloat = Number(claimSpot.ethOutPer1Claim) / 1e18;
        if (spotFloat > 0) {
          const ratio = Math.abs(spotFloat - twapFloat) / twapFloat;
          if (ratio > 0.2) {
            warnings.push(
              `Spot-vs-TWAP divergence is ${(ratio * 100).toFixed(1)}% ` +
                `(spot=${spotFloat.toFixed(8)}, twap=${twapFloat}). ` +
                `Trade decisions based on TWAP may be unsafe.`,
            );
          }
        }
      }
    } catch {
      // best-effort; never fail the snapshot for a warning
    }
  }

  if (
    subgraphPricing &&
    ethUsdUpdatedAt !== undefined &&
    blockTimestamp > 0n &&
    twapUpdatedAt !== ethUsdUpdatedAt
  ) {
    if (blockTimestamp - ethUsdUpdatedAt > MAX_TWAP_STALE_SEC) {
      warnings.push(
        `Subgraph ETH/USD price is stale (age=${blockTimestamp - ethUsdUpdatedAt}s, threshold=${MAX_TWAP_STALE_SEC}s).`,
      );
      subgraphPricing = subgraphPricing ? { ...subgraphPricing, ethUsd: null } : null;
    }
  }

  return {
    meta: { blockNumber, blockTimestamp },
    eth: {
      symbol: 'ETH',
      decimals: 18,
      usd: subgraphPricing?.ethUsd ?? undefined,
      usdUpdatedAt: ethUsdUpdatedAt,
    },
    claim: {
      token: claimMeta,
      spot: claimSpot,
      claimEthTwap30m: subgraphPricing?.claimEthTwap30m ?? undefined,
      twapUpdatedAt,
    },
    entryTokens,
    tokenPricingSnapshot: subgraphPricing,
    warnings,
  };
}
