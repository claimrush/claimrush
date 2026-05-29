import 'dotenv/config';

import {
  createClaimRushClients,
  getContractAddress,
  loadDeploymentManifest,
  isAuthorized,
  permsMask,
  P_CLAIM_ALL_FOR,
  P_TAKEOVER_FOR,
  readDelegationNonce,
  signSetSession,
  submitSetSessionBySig,
} from '../src/index.js';
import { deriveActors } from '../src/harness/accounts.js';

function getArg(name: string, fallback?: string): string | undefined {
  const idx = process.argv.indexOf(`--${name}`);
  if (idx === -1) return fallback;
  return process.argv[idx + 1] ?? fallback;
}

async function main(): Promise<void> {
  const rpcUrl = process.env.RPC_URL ?? getArg('rpc-url');
  if (!rpcUrl) throw new Error('Missing RPC_URL');

  const chain = process.env.CLAIMRUSH_CHAIN ?? getArg('chain', 'local')!;
  const abiNetwork = (process.env.ABI_NETWORK ?? getArg('abi-network', 'base_sepolia')) as any;

  // Use the same account derivation rules as the harness (actor0=user, actor1=delegate).
  const actors = deriveActors({
    count: 2,
    mnemonic: process.env.MNEMONIC,
    privateKeysCsv: process.env.PRIVATE_KEYS,
  });
  if (!actors[0] || !actors[1]) throw new Error('Need at least 2 accounts (user + delegate)');

  const user = (process.env.USER_ADDRESS ?? actors[0].account.address) as `0x${string}`;
  const delegate = (process.env.DELEGATE_ADDRESS ?? actors[1].account.address) as `0x${string}`;

  const manifest = loadDeploymentManifest({ chain });
  const delegationHub = getContractAddress(manifest, 'DelegationHub');

  const userClients = createClaimRushClients({ rpcUrl, account: actors[0].account });
  const delegateClients = createClaimRushClients({ rpcUrl, account: actors[1].account });

  const chainId = await userClients.publicClient.getChainId();

  // Compose a minimal permission set for demo purposes.
  // (In production, keep perms tight and expiries short.)
  const perms = permsMask([P_TAKEOVER_FOR, P_CLAIM_ALL_FOR]);

  const now = BigInt(Math.floor(Date.now() / 1000));
  const expirySeconds = BigInt(
    process.env.SESSION_EXPIRY_SECONDS ?? getArg('expiry-seconds', '3600')!,
  );
  const deadlineSeconds = BigInt(
    process.env.SIG_DEADLINE_SECONDS ?? getArg('deadline-seconds', '600')!,
  );

  const expiry = now + expirySeconds;
  const deadline = now + deadlineSeconds;

  const nonce = await readDelegationNonce({
    publicClient: userClients.publicClient,
    delegationHub,
    user,
    abiNetwork,
  });

  console.error(`user:     ${user}`);
  console.error(`delegate: ${delegate}`);
  console.error(`hub:      ${delegationHub}`);
  console.error(`perms:    ${perms.toString()}`);
  console.error(`nonce:    ${nonce.toString()}`);
  console.error(`expiry:   ${expiry.toString()} (+${expirySeconds}s)`);
  console.error(`deadline: ${deadline.toString()} (+${deadlineSeconds}s)`);

  // User signs typed data (EOA). In production this should come from the user's wallet.
  const sig = await signSetSession({
    userWalletClient: userClients.walletClient!,
    publicClient: userClients.publicClient,
    delegationHub,
    chainId,
    user,
    delegate,
    perms,
    expiry,
    nonce,
    deadline,
  });

  // Anyone can submit; we use the delegate to pay gas.
  const hash = await submitSetSessionBySig({
    publicClient: delegateClients.publicClient,
    submitterWalletClient: delegateClients.walletClient!,
    delegationHub,
    chainId,
    user,
    delegate,
    perms,
    expiry,
    nonce,
    deadline,
    sig,
    abiNetwork,
  });

  console.error(`tx: ${hash}`);

  // Confirm authorization for a single permission bit.
  const ok = await isAuthorized({
    publicClient: delegateClients.publicClient,
    delegationHub,
    user,
    delegate,
    requiredPerms: P_TAKEOVER_FOR,
    abiNetwork,
  });

  console.log(
    JSON.stringify(
      {
        ok,
        chainId,
        user,
        delegate,
        delegationHub,
        perms: perms.toString(),
        requiredPerm: P_TAKEOVER_FOR.toString(),
        tx: hash,
      },
      null,
      2,
    ),
  );
}

main().catch((err) => {
  console.error(err);
  process.exit(1);
});
