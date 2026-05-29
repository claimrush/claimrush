import 'dotenv/config';
import type { Address } from 'viem';
import {
  createClaimRushClients,
  getGameStateSnapshot,
  loadDeploymentManifest,
  stringifySnapshot,
} from '../src/index.js';

async function main(): Promise<void> {
  const rpcUrl = process.env.RPC_URL ?? 'http://127.0.0.1:8545';
  const chain = process.env.CLAIMRUSH_CHAIN ?? 'local';
  const abiNetwork = (process.env.ABI_NETWORK ?? 'base_sepolia') as any;

  const user = (process.env.USER_ADDRESS as Address | undefined) ?? undefined;

  const manifest = loadDeploymentManifest({ chain });
  const { publicClient } = createClaimRushClients({ rpcUrl });

  const snap = await getGameStateSnapshot({
    publicClient,
    manifest,
    abiNetwork,
    user,
  });

  console.log(stringifySnapshot(snap, { pretty: true }));
}

main().catch((err) => {
  console.error(err);
  process.exit(1);
});
