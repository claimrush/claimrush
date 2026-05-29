import 'dotenv/config';
import { formatEther, type Address } from 'viem';
import {
  createClaimRushClients,
  getClaimRushContracts,
  loadDeploymentManifest,
  quoteCurrentTakeoverPrice,
  quoteTakeoverWithTokenMinOut,
  resolveTakeoverRoute,
} from '../src/index.js';

function parseBigintEnv(name: string): bigint | undefined {
  const v = process.env[name];
  if (!v) return undefined;
  try {
    return BigInt(v);
  } catch {
    throw new Error(`${name} must be an integer string (raw base units). Got: ${v}`);
  }
}

async function main(): Promise<void> {
  const rpcUrl = process.env.RPC_URL ?? 'http://127.0.0.1:8545';
  const chain = process.env.CLAIMRUSH_CHAIN ?? 'local';
  const abiNetwork = (process.env.ABI_NETWORK ?? 'base_sepolia') as any;

  const manifest = loadDeploymentManifest({ chain });
  const { publicClient } = createClaimRushClients({ rpcUrl });
  const contracts = await getClaimRushContracts({ publicClient, manifest, abiNetwork });

  // Discover wrapped native (WETH) from the MineCore registry.
  const reg = (contracts as any).MineCoreEntryTokenRegistry;
  if (!reg) throw new Error("Missing required contract 'MineCoreEntryTokenRegistry' in manifest");
  const routerCfg = (await reg.read.getRouterConfig()) as readonly [
    Address,
    Address,
    Address,
    Address,
  ];
  const wrappedNative = routerCfg[2];

  const takeoverPriceLive = await quoteCurrentTakeoverPrice({ contracts });

  const tokenIn = ((process.env.TOKEN_IN as Address | undefined) ?? wrappedNative) as Address;

  // AMOUNT_IN is raw token base units.
  // If tokenIn is wrapped native, default to exactly the current takeover price (WETH unwrap is 1:1).
  const amountInEnv = parseBigintEnv('AMOUNT_IN');
  const amountIn =
    amountInEnv ?? (tokenIn.toLowerCase() === wrappedNative.toLowerCase() ? takeoverPriceLive : 0n);
  if (amountIn === 0n) {
    throw new Error(
      'AMOUNT_IN is required for non-wrappedNative tokens (raw base units). ' +
        'Example: AMOUNT_IN=1000000 for 1 USDC (6 decimals).',
    );
  }

  // Default slippage:
  // - WETH unwrap: 0 bps (no swap)
  // - others: 100 bps (1%) unless overridden
  const defaultSlippageBps = tokenIn.toLowerCase() === wrappedNative.toLowerCase() ? 0n : 100n;
  const slippageBps = parseBigintEnv('SLIPPAGE_BPS') ?? defaultSlippageBps;

  // Resolve + validate route (will revert if token not allowlisted or pool mismatch).
  // Empty route means tokenIn == wrappedNative (implicit unwrap route).
  let route: any[] = [];
  try {
    route = await resolveTakeoverRoute({ contracts, tokenIn });
  } catch {
    route = [];
  }

  const q = await quoteTakeoverWithTokenMinOut({ contracts, tokenIn, amountIn, slippageBps });

  // Optional stricter suggestion: never allow minEthOut below the current takeover price.
  const minEthOutStrict = q.minEthOut < q.takeoverPrice ? q.takeoverPrice : q.minEthOut;

  const out = {
    chain,
    rpcUrl,

    tokenIn,
    wrappedNative,
    amountIn: amountIn.toString(),

    takeoverPriceLive: takeoverPriceLive.toString(),
    takeoverPriceLiveEth: formatEther(takeoverPriceLive),

    // Values from MineCoreQuoter
    takeoverPriceAtQuote: q.takeoverPrice.toString(),
    takeoverPriceAtQuoteEth: formatEther(q.takeoverPrice),
    expectedEthOut: q.ethOut.toString(),
    expectedEthOutEth: formatEther(q.ethOut),

    slippageBps: slippageBps.toString(),
    minEthOut: q.minEthOut.toString(),
    minEthOutEth: formatEther(q.minEthOut),
    minEthOutStrict: minEthOutStrict.toString(),
    minEthOutStrictEth: formatEther(minEthOutStrict),

    enoughForTakeover: q.ethOut >= q.takeoverPrice,

    // Suggested call args
    takeoverWithTokenArgs: {
      tokenIn,
      amountIn: amountIn.toString(),
      minEthOut: q.minEthOut.toString(),
      minEthOutStrict: minEthOutStrict.toString(),
    },

    validatedRoute: route,
  };

  const pretty = (process.env.PRETTY ?? 'true') === 'true';
  console.log(JSON.stringify(out, null, pretty ? 2 : 0));
}

main().catch((err) => {
  console.error(err);
  process.exit(1);
});
