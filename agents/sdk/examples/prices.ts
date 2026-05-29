import 'dotenv/config';
import {
  createClaimRushClients,
  getClaimRushContracts,
  getLivePrices,
  createLivePricesCache,
  loadDeploymentManifest,
  stringifyJson,
} from '../src/index.js';

async function main(): Promise<void> {
  const rpcUrl = process.env.RPC_URL ?? 'http://127.0.0.1:8545';
  const chain = process.env.CLAIMRUSH_CHAIN ?? 'local';
  const abiNetwork = (process.env.ABI_NETWORK ?? 'base_sepolia') as any;

  const subgraphUrl = process.env.SUBGRAPH_URL;
  if (!subgraphUrl) {
    throw new Error('SUBGRAPH_URL is required (GraphQL endpoint)');
  }

  const manifest = loadDeploymentManifest({ chain });
  const { publicClient } = createClaimRushClients({ rpcUrl });
  const contracts = await getClaimRushContracts({ publicClient, manifest, abiNetwork });

  const cache =
    (process.env.PRICES_CACHE ?? '0') === '1'
      ? createLivePricesCache({
          rpcConcurrency: Number(process.env.PRICES_RPC_CONCURRENCY ?? '16'),
          ttls: {
            erc20MetaMs: Number(process.env.PRICES_META_TTL_MS ?? String(6 * 60 * 60 * 1000)),
            dexConfigMs: Number(process.env.PRICES_DEX_TTL_MS ?? String(5 * 60 * 1000)),
            entryTokenFlagsMs: Number(process.env.PRICES_ENTRYTOKENS_TTL_MS ?? String(60 * 1000)),
            subgraphPricingMs: Number(process.env.PRICES_PRICING_TTL_MS ?? String(15 * 1000)),
            claimSpotQuoteMs: Number(process.env.PRICES_QUOTE_TTL_MS ?? String(5 * 1000)),
            entryTokenSpotQuoteMs: Number(process.env.PRICES_QUOTE_TTL_MS ?? String(5 * 1000)),
          },
        })
      : undefined;

  const prices = await getLivePrices({
    contracts,
    publicClient,
    subgraphUrl,
    cache,
    maxTokens: Number(process.env.MAX_TOKENS ?? '200'),
    includeSubgraphPricing: (process.env.INCLUDE_SUBGRAPH_PRICING ?? 'true') === 'true',
  });

  console.log(stringifyJson(prices, { pretty: true }));
}

main().catch((err) => {
  console.error(err);
  process.exit(1);
});
