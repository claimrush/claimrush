import type { Address } from 'viem';
import { isAddress } from 'viem';

import {
  fetchRedirectMode,
  parseAndValidateOutboundUrl,
  parseAndValidateOutboundUrlWithDns,
  type OutboundUrlPolicy,
} from './security/url.js';

import { safeErrorString } from './security/redact.js';
import { clampStrictSafeInteger } from './integers.js';

import { readResponseTextLimited } from './security/fetch.js';

export type SubgraphClientParams = {
  /** GraphQL endpoint URL (e.g. https://api.studio.thegraph.com/query/... ). */
  url: string;
  /** Default timeout for requests. Default: 10s. */
  timeoutMs?: number;
  /** Optional extra headers (Authorization, etc). */
  headers?: Record<string, string>;

  /** Optional outbound URL policy for SSRF/redirect hardening. */
  networkPolicy?: OutboundUrlPolicy;

  /**
   * Max response bytes to read from the subgraph (prevents memory blowups on
   * misconfigured/malicious endpoints).
   *
   * Default: 2_000_000 (2MB).
   */
  maxResponseBytes?: number;
};

type GraphQLError = {
  message: string;
};

type GraphQLResponse<T> = {
  data?: T;
  errors?: GraphQLError[];
};

// SubgraphClient is hardened for public HTTP endpoints:
// - outbound URLs are validated by `parseAndValidateOutboundUrl` (SSRF denylist,
//   credential stripping, protocol allowlist);
// - each query re-resolves DNS via `parseAndValidateOutboundUrlWithDns` so a
//   hostname that flips to loopback/private/link-local at request time is
//   rejected;
// - response bodies are capped by `readResponseTextLimited` to prevent memory
//   blowups from hostile endpoints.
//
// Callers that use pricing / snapshot data for economic decisions should apply
// their own freshness checks on `updatedAt` — this module intentionally does
// not treat subgraph lag as an error.

export class SubgraphClient {
  public readonly url: string;
  public readonly timeoutMs: number;
  public readonly headers: Record<string, string>;
  public readonly maxResponseBytes: number;

  private readonly networkPolicy?: OutboundUrlPolicy;

  constructor(params: SubgraphClientParams) {
    if (!params.url) throw new Error('SubgraphClient: url is required');

    // Best-effort SSRF hardening (blocks link-local + cloud metadata by default).
    const u = parseAndValidateOutboundUrl(params.url, 'SubgraphClient.url', params.networkPolicy);
    this.url = u.toString();
    this.networkPolicy = params.networkPolicy;

    this.timeoutMs = params.timeoutMs ?? 10_000;
    this.headers = params.headers ?? {};

    const maxBytesRaw = params.maxResponseBytes ?? 2_000_000;
    this.maxResponseBytes = clampStrictSafeInteger(maxBytesRaw, 2_000_000, 1, 20_000_000);
  }

  async query<T>(query: string, variables?: Record<string, unknown>): Promise<T> {
    const controller = new AbortController();
    const timeout = setTimeout(() => controller.abort(), this.timeoutMs);

    try {
      const safeUrl = await parseAndValidateOutboundUrlWithDns(
        this.url,
        'SubgraphClient.url',
        this.networkPolicy,
      );

      const res = await fetch(safeUrl.toString(), {
        method: 'POST',
        headers: {
          'content-type': 'application/json',
          ...this.headers,
        },
        body: JSON.stringify({ query, variables: variables ?? {} }),
        redirect: fetchRedirectMode(this.networkPolicy) as any,
        signal: controller.signal,
      });

      const limit = res.ok ? this.maxResponseBytes : Math.min(this.maxResponseBytes, 64_000);
      const { text: bodyText, truncated, readError } = await readResponseTextLimited(res, limit);

      if (!res.ok) {
        const snippet = bodyText.slice(0, 500);
        const suffix = truncated ? '...[truncated]' : '';
        throw new Error(`Subgraph HTTP ${res.status}: ${snippet}${suffix}`);
      }

      if (truncated) {
        throw new Error(`Subgraph response exceeded maxResponseBytes=${this.maxResponseBytes}`);
      }

      // If the response stream aborted mid-read, surface that distinctly so
      // the caller doesn't see an opaque "invalid JSON response" when the
      // real cause was a dropped connection.
      if (readError) {
        throw new Error(`Subgraph: response read failed: ${readError}`);
      }

      let json: GraphQLResponse<T>;
      try {
        json = JSON.parse(bodyText) as GraphQLResponse<T>;
      } catch {
        throw new Error('Subgraph: invalid JSON response');
      }
      if (json.errors && json.errors.length) {
        const msg = json.errors.map((e) => safeErrorString(e.message)).join(' | ');
        throw new Error(`Subgraph GraphQL error: ${msg}`);
      }
      if (!json.data) throw new Error('Subgraph: missing data');
      return json.data;
    } finally {
      clearTimeout(timeout);
    }
  }
}

export type SubgraphMeta = {
  blockNumber: number;
};

export type SubgraphProtocol = {
  chainId: number;
  version: string;
  deployedAtBlock: string;

  claimToken: string;
  veClaimNft: string;
  mineCore: string;
  shareholderRoyalties: string;
  furnace: string;
  marketRouter: string;

  furnaceEntryTokenRegistry?: string | null;
  mineCoreEntryTokenRegistry?: string | null;
  entryTokenRegistry?: string | null;

  dexAdapter?: string | null;
  lpStakingVault?: string | null;
  launchController?: string | null;
  genesisLpVault24m?: string | null;

  takeoversPaused: boolean;
  lockingPaused: boolean;
  tradingPaused: boolean;
};

export type SubgraphVeLock = {
  tokenId: string;
  amountWei: string;
  lockEnd: string;
  autoMax: boolean;
  listed: boolean;
  createdAt: string;
  updatedAt: string;
  currentVeWei?: string | null;
};

export type SubgraphUser = {
  id: string;
  address: string;
  takeoverCount: number;
  ethSpentOnTakeoversWei: string;
  kingClaimMinedWei: string;
  shareholderEthClaimedWei: string;
  furnaceEthInWei: string;
  furnacePrincipalClaimInWei: string;
  veBalanceWei?: string | null;
  totalLockedClaimWei?: string | null;
  locks?: SubgraphVeLock[];
};

export type SubgraphTakeover = {
  id: string;
  timestamp: string;
  blockNumber: string;
  txHash: string;
  pricePaidWei: string;
  referencePriceWei: string;
  previousKing?: { id: string } | null;
  newKing: { id: string };
  reign: { id: string; reignId: string };
};

export type SubgraphFurnaceEnterEvent = {
  id: string;
  timestamp: string;
  blockNumber: string;
  txHash: string;
  user: { id: string } | null;
  mode: number;
  ethInWei: string;
  principalClaimWei: string;
  bonusClaimWei: string;
  tokenId: string;
};

export type SubgraphShareholderClaimEvent = {
  id: string;
  timestamp: string;
  txHash: string;
  user: { id: string } | null;
  mode: number;
  amountEthWei: string;
};

export type SubgraphShareholderAutoCompoundExecutedEvent = {
  id: string;
  timestamp: string;
  txHash: string;
  user: { id: string } | null;
  executor: { id: string } | null;
  amountEthWei: string;
  tokenId: string;
  effectiveDurationSeconds: string;
};

export type SubgraphTokenPricingSnapshot = {
  id: string;
  updatedAt?: string | null;
  claimEthTwap30m?: string | null;
  ethUsd?: string | null;
  ethUsdUpdatedAt?: string | null;
  totalSupplyWei?: string | null;
};

export type SubgraphEntryTokenRegistry = {
  id: string;
  address: string;

  guardian?: string | null;

  router?: string | null;
  factory?: string | null;
  wrappedNative?: string | null;
  claimToken?: string | null;

  wethClaimPool?: string | null;
  wethClaimPoolStable?: boolean | null;
  updatedAt?: string | null;
};

export type SubgraphEntryTokenConfig = {
  id: string;
  registry: SubgraphEntryTokenRegistry;
  tokenIn: string;
  enabled: boolean;
  directToClaimEnabled: boolean;
  tokenClaimStable: boolean;
  tokenClaimPool: string;
  tokenWethStable: boolean;
  tokenWethPool: string;
  exactReceiptSafe: boolean;
  updatedAt: string;
};

const Q_META = `
  query Meta {
    _meta {
      block {
        number
      }
    }
  }
`;

const Q_PROTOCOL = `
  query Protocol {
    protocol(id: "1") {
      chainId
      version
      deployedAtBlock

      claimToken
      veClaimNft
      mineCore
      shareholderRoyalties
      furnace
      marketRouter

      furnaceEntryTokenRegistry
      mineCoreEntryTokenRegistry
      entryTokenRegistry

      dexAdapter
      lpStakingVault
      launchController
      genesisLpVault24m

      takeoversPaused
      lockingPaused
      tradingPaused
    }
  }
`;

const Q_TOKEN_PRICING_SNAPSHOT = `
  query TokenPricingSnapshot {
    tokenPricingSnapshot(id: "1") {
      id
      updatedAt
      claimEthTwap30m
      ethUsd
      ethUsdUpdatedAt
      totalSupplyWei
    }
  }
`;

const Q_USER = `
  query User($id: ID!, $includeLocks: Boolean!, $maxLocks: Int!) {
    user(id: $id) {
      id
      address
      takeoverCount
      ethSpentOnTakeoversWei
      kingClaimMinedWei
      shareholderEthClaimedWei
      furnaceEthInWei
      furnacePrincipalClaimInWei
      veBalanceWei
      totalLockedClaimWei
      locks(first: $maxLocks, orderBy: tokenId, orderDirection: desc) @include(if: $includeLocks) {
        tokenId
        amountWei
        lockEnd
        autoMax
        listed
        createdAt
        updatedAt
        currentVeWei
      }
    }
  }
`;

const Q_TAKEOVERS = `
  query Takeovers($first: Int!) {
    takeovers(first: $first, orderBy: blockNumber, orderDirection: desc) {
      id
      timestamp
      blockNumber
      txHash
      pricePaidWei
      referencePriceWei
      previousKing { id }
      newKing { id }
      reign { id reignId }
    }
  }
`;

const Q_FURNACE_ENTERS = `
  query FurnaceEnters($first: Int!) {
    furnaceEnterEvents(first: $first, orderBy: blockNumber, orderDirection: desc) {
      id
      timestamp
      blockNumber
      txHash
      user { id }
      mode
      ethInWei
      principalClaimWei
      bonusClaimWei
      tokenId
    }
  }
`;

const Q_SHAREHOLDER_CLAIMS = `
  query ShareholderClaims($first: Int!) {
    shareholderClaimEvents(first: $first, orderBy: timestamp, orderDirection: desc) {
      id
      timestamp
      txHash
      user { id }
      mode
      amountEthWei
    }
  }
`;

const Q_SHAREHOLDER_AUTOCOMPOUNDS = `
  query ShareholderAutoCompounds($first: Int!) {
    shareholderAutoCompoundExecutedEvents(first: $first, orderBy: timestamp, orderDirection: desc) {
      id
      timestamp
      txHash
      user { id }
      executor { id }
      amountEthWei
      tokenId
      effectiveDurationSeconds
    }
  }
`;

const Q_ENTRY_TOKEN_CONFIGS_BY_REGISTRY = `
  query EntryTokenConfigs($registry: ID!, $first: Int!, $skip: Int!) {
    entryTokenConfigs(
      first: $first
      skip: $skip
      orderBy: updatedAt
      orderDirection: desc
      where: { registry: $registry, enabled: true }
    ) {
      id
      registry {
        id
        address
      }
      tokenIn
      enabled
      directToClaimEnabled
      tokenClaimStable
      tokenClaimPool
      tokenWethStable
      tokenWethPool
      exactReceiptSafe
      updatedAt
    }
  }
`;

export async function getSubgraphMeta(client: SubgraphClient): Promise<SubgraphMeta | null> {
  type R = { _meta?: { block?: { number?: number } } };
  const data = await client.query<R>(Q_META);
  const num = data._meta?.block?.number;
  if (typeof num !== 'number' || !Number.isSafeInteger(num) || num < 0) return null;
  return { blockNumber: num };
}

export async function getSubgraphProtocol(
  client: SubgraphClient,
): Promise<SubgraphProtocol | null> {
  type R = { protocol?: SubgraphProtocol | null };
  const data = await client.query<R>(Q_PROTOCOL);
  return data.protocol ?? null;
}

export async function getTokenPricingSnapshot(
  client: SubgraphClient,
): Promise<SubgraphTokenPricingSnapshot | null> {
  type R = { tokenPricingSnapshot?: SubgraphTokenPricingSnapshot | null };
  const data = await client.query<R>(Q_TOKEN_PRICING_SNAPSHOT);
  return data.tokenPricingSnapshot ?? null;
}

export async function getSubgraphUser(
  client: SubgraphClient,
  user: Address,
  opts?: {
    includeLocks?: boolean;
    maxLocks?: number;
  },
): Promise<SubgraphUser | null> {
  type R = { user?: SubgraphUser | null };

  const includeLocks = opts?.includeLocks ?? true;
  const maxLocks = opts?.maxLocks ?? 200;

  const id = user.toLowerCase();
  const data = await client.query<R>(Q_USER, { id, includeLocks, maxLocks });
  return data.user ?? null;
}

export async function getRecentTakeovers(
  client: SubgraphClient,
  first: number | string = 25,
): Promise<SubgraphTakeover[]> {
  first = clampStrictSafeInteger(first, 25, 1, 1000);
  type R = { takeovers?: SubgraphTakeover[] };
  const data = await client.query<R>(Q_TAKEOVERS, { first });
  return data.takeovers ?? [];
}

export async function getRecentFurnaceEnters(
  client: SubgraphClient,
  first: number | string = 25,
): Promise<SubgraphFurnaceEnterEvent[]> {
  first = clampStrictSafeInteger(first, 25, 1, 1000);
  type R = { furnaceEnterEvents?: SubgraphFurnaceEnterEvent[] };
  const data = await client.query<R>(Q_FURNACE_ENTERS, { first });
  return data.furnaceEnterEvents ?? [];
}

export async function getRecentShareholderClaims(
  client: SubgraphClient,
  first: number | string = 25,
): Promise<SubgraphShareholderClaimEvent[]> {
  first = clampStrictSafeInteger(first, 25, 1, 1000);
  type R = { shareholderClaimEvents?: SubgraphShareholderClaimEvent[] };
  const data = await client.query<R>(Q_SHAREHOLDER_CLAIMS, { first });
  return data.shareholderClaimEvents ?? [];
}

export async function getRecentShareholderAutoCompounds(
  client: SubgraphClient,
  first: number | string = 25,
): Promise<SubgraphShareholderAutoCompoundExecutedEvent[]> {
  first = clampStrictSafeInteger(first, 25, 1, 1000);
  type R = {
    shareholderAutoCompoundExecutedEvents?: SubgraphShareholderAutoCompoundExecutedEvent[];
  };
  const data = await client.query<R>(Q_SHAREHOLDER_AUTOCOMPOUNDS, { first });
  return data.shareholderAutoCompoundExecutedEvents ?? [];
}

export async function getEntryTokenConfigs(
  client: SubgraphClient,
  opts: {
    /** Registry id is the registry address lowercased (EntryTokenRegistry.id in the subgraph). */
    registryId: string;
    /** Max number of configs to fetch. Default: 500. */
    max?: number;
    /** Page size for pagination. Default: 250 (subgraph-safe). */
    pageSize?: number;
  },
): Promise<SubgraphEntryTokenConfig[]> {
  const max = Math.max(0, opts.max ?? 500);
  if (max === 0) return [];

  const pageSize = Math.min(Math.max(1, opts.pageSize ?? 250), 1000);
  const MAX_PAGES = 20;
  const out: SubgraphEntryTokenConfig[] = [];

  for (let skip = 0, page = 0; out.length < max; skip += pageSize, page++) {
    if (page >= MAX_PAGES) {
      throw new Error(
        `getEntryTokenConfigs: exceeded MAX_PAGES=${MAX_PAGES} — possible infinite pagination loop`,
      );
    }
    const first = Math.min(pageSize, max - out.length);
    type R = { entryTokenConfigs?: SubgraphEntryTokenConfig[] };
    const data = await client.query<R>(Q_ENTRY_TOKEN_CONFIGS_BY_REGISTRY, {
      registry: opts.registryId,
      first,
      skip,
    });
    const items = data.entryTokenConfigs ?? [];
    out.push(...items);
    if (items.length < first) break;
  }

  return out;
}

export function normalizeSubgraphAddress(value: string | null | undefined): Address | null {
  if (!value) return null;
  // Bytes fields from subgraph are usually 0x-prefixed hex.
  if (!isAddress(value)) return null;
  if (/^0x0{40}$/i.test(value)) return null;
  return value as Address;
}
