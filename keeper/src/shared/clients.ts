import {
  createPublicClient,
  createWalletClient,
  defineChain,
  http,
  type Chain,
  type PublicClient,
  type Transport,
  type WalletClient,
} from 'viem';
import { privateKeyToAccount, type PrivateKeyAccount } from 'viem/accounts';

import { recordTier, TIER_HEADER_NAME } from './tier_observer.js';
import { parseNonNegativeSafeInteger, parsePositiveSafeInteger } from './utils.js';

/**
 * Record the `x-rpc-proxy-upstream-tier` response header into the tier
 * observer after every public-client RPC call.  The observer feeds the
 * daemon scheduler's primary-vs-fallback cadence decision.
 *
 * We use viem's `onFetchResponse` callback rather than wrapping `fetch`
 * itself: it's an officially supported extension point, doesn't require
 * re-implementing fetch semantics, and runs only after the response has
 * been received (so our bookkeeping can't interfere with the request).
 */
function onPublicFetchResponse(res: Response): void {
  try {
    recordTier(res.headers.get(TIER_HEADER_NAME));
  } catch {
    // Observer bookkeeping must never throw into viem's request pipeline.
  }
}

/**
 * Shared client bundle passed to every keeper task.
 *
 * Using parameterised viem types (Chain is always defined) means
 * ABI-level type inference kicks in automatically for `readContract`,
 * `writeContract`, `simulateContract`, `getLogs`, etc. – and
 * `writeContract` no longer requires an explicit `chain` argument.
 */
export interface ViemClients {
  publicClient: PublicClient<Transport, Chain>;
  walletClient: WalletClient<Transport, Chain, PrivateKeyAccount>;
  account: PrivateKeyAccount;
}

interface BuildClientsOpts {
  chainId: number;
  publicRpcUrl: string | undefined;
  privateRpcUrl: string | undefined;
  privateKey: string | undefined;
  publicRpcAuthToken: string | null | undefined;
  privateRpcAuthToken: string | null | undefined;
  publicRpcTimeoutMs?: number | null | undefined;
  privateRpcTimeoutMs?: number | null | undefined;
  rpcRetryCount?: number | null | undefined;
  rpcBatchWaitMs?: number | null | undefined;
  /**
   * Optional override for the Multicall3 deployment address.  When omitted we
   * fall back to the canonical address `0xcA11bde05977b3631167028862bE2a173976CA11`
   * which is deployed on virtually every mainstream EVM network including
   * Base (8453) and Base Sepolia (84532).  viem's `publicClient.multicall()`
   * REQUIRES a non-empty `contracts.multicall3` on the chain definition — if
   * it is missing the call fails with `Chain does not support contract
   * "multicall3"` and every batched task (compound-lp, compound-shareholders,
   * listings_discovery, etc.) breaks.
   */
  multicall3Address?: string | null | undefined;
  /** Optional block at which Multicall3 was deployed on this chain. */
  multicall3BlockCreated?: number | null | undefined;
}

/**
 * Canonical Multicall3 address. Deployed deterministically (via CREATE2 with
 * a well-known salt) to the same address on Ethereum mainnet, Base mainnet,
 * Base Sepolia, Optimism, Arbitrum, Polygon, and most other mainstream
 * chains.  See https://www.multicall3.com/ for the authoritative list.
 */
const CANONICAL_MULTICALL3_ADDRESS = '0xcA11bde05977b3631167028862bE2a173976CA11';

interface ClientsResult extends ViemClients {
  chain: Chain;
}

export function buildClients({
  chainId,
  publicRpcUrl,
  privateRpcUrl,
  privateKey,
  publicRpcAuthToken,
  privateRpcAuthToken,
  publicRpcTimeoutMs,
  privateRpcTimeoutMs,
  rpcRetryCount,
  rpcBatchWaitMs,
  multicall3Address,
  multicall3BlockCreated,
}: BuildClientsOpts): ClientsResult {
  if (!publicRpcUrl) throw new Error('KEEPER_PUBLIC_RPC_URL missing');
  if (!privateRpcUrl) throw new Error('KEEPER_PRIVATE_RPC_URL missing');
  if (!privateKey) throw new Error('KEEPER_PRIVATE_KEY missing');

  const normalizedChainId = parsePositiveSafeInteger(chainId, { defaultValue: null });
  if (normalizedChainId == null) throw new Error('KEEPER_CHAIN_ID must be a positive safe integer');

  for (const [label, url] of [
    ['public RPC', publicRpcUrl],
    ['private RPC', privateRpcUrl],
  ] as const) {
    const parsed = new URL(url);
    const scheme = parsed.protocol.toLowerCase();
    if (scheme !== 'https:' && scheme !== 'http:' && scheme !== 'wss:' && scheme !== 'ws:') {
      throw new Error(
        `${label} URL uses unsupported scheme "${scheme}". Only http(s) and ws(s) are allowed.`,
      );
    }
    if (parsed.username || parsed.password) {
      throw new Error(
        `${label} URL contains embedded credentials (userinfo). Use KEEPER_*_RPC_AUTH_TOKEN instead.`,
      );
    }
  }

  // Resolve Multicall3 address: explicit override > canonical constant.
  // We intentionally do NOT look up per-chainId addresses from viem's bundled
  // chain list: the canonical CREATE2 deployment covers every network we
  // target and keeping the logic here means new chains work out-of-the-box
  // without a client update.
  const rawMulticall3 =
    typeof multicall3Address === 'string' && multicall3Address.trim().length > 0
      ? multicall3Address.trim()
      : CANONICAL_MULTICALL3_ADDRESS;
  if (!/^0x[0-9a-fA-F]{40}$/.test(rawMulticall3)) {
    throw new Error(
      `KEEPER_MULTICALL3_ADDRESS must be a 20-byte hex address (got ${JSON.stringify(rawMulticall3)})`,
    );
  }
  const multicall3Entry: { address: `0x${string}`; blockCreated?: number } = {
    address: rawMulticall3 as `0x${string}`,
  };
  const blockCreated = parseNonNegativeSafeInteger(multicall3BlockCreated, { defaultValue: null });
  if (blockCreated != null) multicall3Entry.blockCreated = blockCreated;

  const chain = defineChain({
    id: normalizedChainId,
    name: `chain-${normalizedChainId}`,
    nativeCurrency: { name: 'Ether', symbol: 'ETH', decimals: 18 },
    rpcUrls: {
      default: { http: [publicRpcUrl] },
    },
    contracts: {
      multicall3: multicall3Entry,
    },
  });

  const account = privateKeyToAccount(privateKey as `0x${string}`);

  // Never follow redirects for JSON-RPC calls.
  // Redirects can mask auth failures (e.g. Cloudflare Access login) and can leak
  // bearer tokens or provider API keys (when embedded in the URL).
  const publicFetchOptions = {
    redirect: 'manual' as const,
    ...(publicRpcAuthToken
      ? {
          headers: {
            authorization: `Bearer ${publicRpcAuthToken}`,
          },
        }
      : {}),
  };

  const privateFetchOptions = {
    redirect: 'manual' as const,
    ...(privateRpcAuthToken
      ? {
          headers: {
            authorization: `Bearer ${privateRpcAuthToken}`,
          },
        }
      : {}),
  };

  const baseTransportOpts: any = {
    // Bound RPC call latency so the keeper cannot hang indefinitely on degraded endpoints.
    // viem http transport uses this timeout per request.
    timeout: undefined as any,
    // Pollers run continuously; avoid retry bursts when RPC is down.
    retryCount: parseNonNegativeSafeInteger(rpcRetryCount, { defaultValue: 0 }) ?? 0,
    // (network hiccup, 502 from a load balancer) will fail the entire task.
    // The daemon loop retries at the next interval, so this is not critical,
    // but a retryCount of 1-2 with exponential backoff would improve resilience
    // for non-idempotent operations like estimateContractGas that are safe to
    // retry.
  };

  const batchWait = parsePositiveSafeInteger(rpcBatchWaitMs, { defaultValue: null });
  if (batchWait != null) {
    baseTransportOpts.batch = { wait: batchWait };
  }

  const publicTransportOpts = {
    ...baseTransportOpts,
    fetchOptions: publicFetchOptions,
    timeout: parsePositiveSafeInteger(publicRpcTimeoutMs, { defaultValue: 15_000 }) ?? 15_000,
    // Only the PUBLIC (read) client feeds the tier observer.  The private
    // client targets the writeUpstreams path (local node or a write-
    // dedicated proxy) and doesn't influence cadence decisions.
    onFetchResponse: onPublicFetchResponse,
  };

  const privateTransportOpts = {
    ...baseTransportOpts,
    fetchOptions: privateFetchOptions,
    timeout: parsePositiveSafeInteger(privateRpcTimeoutMs, { defaultValue: 15_000 }) ?? 15_000,
  };

  const publicClient = createPublicClient({
    chain,
    transport: http(publicRpcUrl, publicTransportOpts),
  });

  const walletClient = createWalletClient({
    chain,
    transport: http(privateRpcUrl, privateTransportOpts),
    account,
  });

  return { chain, account, publicClient, walletClient };
}
