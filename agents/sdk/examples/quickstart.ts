import 'dotenv/config';
import { formatEther, parseEther, type Address } from 'viem';
import {
  createClaimRushClients,
  getClaimRushContracts,
  loadDeploymentManifest,
  quoteCurrentTakeoverPrice,
  quoteEnterWithEth,
} from '../src/index.js';

// Protocol minimum: 1,000 CLAIM tokens required to create a new lock.
// On local testnet with default liquidity setup, 1 ETH ≈ 1 CLAIM, so ~1000 ETH needed.
// Production networks have different exchange rates based on actual market prices.
const DEFAULT_ETH_IN_LOCAL = '1000';

async function main(): Promise<void> {
  const rpcUrl = process.env.RPC_URL ?? 'http://127.0.0.1:8545';
  const chain = process.env.CLAIMRUSH_CHAIN ?? 'local';
  const abiNetwork = (process.env.ABI_NETWORK ?? 'base_sepolia') as any;

  const manifest = loadDeploymentManifest({ chain });
  const { publicClient } = createClaimRushClients({ rpcUrl });
  const contracts = await getClaimRushContracts({ publicClient, manifest, abiNetwork });

  const takeoverPrice = await quoteCurrentTakeoverPrice({ contracts });
  console.log(`Current takeover price: ${formatEther(takeoverPrice)} ETH`);

  // Furnace quote example
  // Note: Creating a new lock (targetTokenId=0) requires >= 1,000 CLAIM after swap.
  // Use a higher ETH amount on local testnet, or target an existing lock.
  const userEnv = process.env.USER_ADDRESS;
  if (!userEnv && chain !== 'local') {
    throw new Error('USER_ADDRESS env var is required for non-local chains');
  }
  const ANVIL_ACCOUNT_0 = '0xf39Fd6e51aad88F6F4ce6aB8827279cffFb92266' as Address;
  if (!userEnv && chain === 'local') {
    console.warn('[quickstart] Using Anvil account #0 — not for production use');
  }
  const user: Address = userEnv ? (userEnv as Address) : ANVIL_ACCOUNT_0;
  const ethIn = parseEther(process.env.ETH_IN ?? DEFAULT_ETH_IN_LOCAL);
  const targetTokenId = BigInt(process.env.TARGET_TOKEN_ID ?? '0');
  const durationSeconds = BigInt(process.env.DURATION_SECONDS ?? String(60 * 60 * 24 * 7)); // 7 days
  const createAutoMax = (process.env.CREATE_AUTO_MAX ?? 'false') === 'true';

  console.log(`Quoting entry with ${formatEther(ethIn)} ETH...`);

  try {
    const q = await quoteEnterWithEth({
      contracts,
      user,
      ethIn,
      targetTokenId,
      durationSeconds,
      createAutoMax,
    });

    console.log('Furnace.quoteEnterWithEth(...) =>');
    console.log({
      principalClaim: q.principalClaim.toString(),
      bonusClaim: q.bonusClaim.toString(),
      veOut: q.veOut.toString(),
      routeTokenId: q.routeTokenId.toString(),
    });
  } catch (err: any) {
    // Handle common contract errors with helpful messages
    const errorName = err?.cause?.data?.errorName ?? err?.data?.errorName;
    if (errorName === 'MinLockAmountNotMet') {
      console.error('\nError: MinLockAmountNotMet');
      console.error('The resulting CLAIM amount is below the 1,000 CLAIM minimum for new locks.');
      console.error('Solutions:');
      console.error('  1. Increase ETH_IN (e.g., ETH_IN=100 or higher on local testnet)');
      console.error('  2. Target an existing lock with TARGET_TOKEN_ID=<tokenId>');
      process.exit(1);
    }
    throw err;
  }

  // Sanity: ensure RPC works
  const block = await publicClient.getBlockNumber();
  console.log(`Connected. Current block: ${block}`);
}

main().catch((err) => {
  console.error(err);
  process.exit(1);
});
