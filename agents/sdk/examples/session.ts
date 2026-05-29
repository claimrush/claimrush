import 'dotenv/config';

import fs from 'node:fs';

import { getAddress, isAddress } from 'viem';

import type { Address } from 'viem';

import {
  buildSetSessionTypedData,
  createClaimRushClients,
  describePerms,
  getDelegationSession,
  loadDeploymentManifest,
  parsePermsSpec,
  readDelegationNonce,
  stringifyJson,
  submitSetSessionBySig,
} from '../src/index.js';

import type { AbiNetwork } from '../src/abis.js';

import { DEFAULT_ANVIL_MNEMONIC, deriveActors } from '../src/harness/accounts.js';

type Cmd = 'build' | 'submit' | 'status';

type CliOpts = {
  rpcUrl: string;
  chain: string;
  abiNetwork: AbiNetwork;
  actorIndex?: number;

  cmd: Cmd;

  user: string;
  delegate: string;

  // Build params
  permsSpec?: string;
  /** Optional absolute unix seconds (overrides --expiry-seconds). */
  expiry?: string;
  expirySeconds?: number;
  /** Optional absolute unix seconds (overrides --deadline-seconds). */
  deadline?: string;
  deadlineSeconds?: number;
  /** Convenience: build a revoke payload (perms=0, expiry=0). */
  revoke: boolean;

  // Files
  out?: string;
  typedDataPath?: string;
  sig?: string;
  sigPath?: string;

  requiredPermsSpec?: string;
  pretty: boolean;
};

function parseArgs(argv: string[], env: NodeJS.ProcessEnv): CliOpts {
  const get = (key: string): string | undefined => {
    const pref = `--${key}=`;
    const hit = argv.find((a) => a.startsWith(pref));
    if (hit) return hit.slice(pref.length);
    const idx = argv.findIndex((a) => a === `--${key}`);
    if (idx >= 0) return argv[idx + 1];
    return undefined;
  };

  const has = (flag: string): boolean => argv.includes(`--${flag}`);

  const help = has('help') || argv.includes('-h');
  if (help) {
    console.log(`
ClaimRush DelegationHub session helper

Commands
  --cmd build                Build EIP-712 typed data JSON for DelegationHub.setSessionBySig
  --cmd submit               Submit setSessionBySig using a typed-data JSON + signature
  --cmd status               Print current session state

Usage
  npm -C agents/sdk run example:session -- [options]

Core
  --rpc-url <url>            HTTP RPC (default: RPC_URL or http://127.0.0.1:8545)
  --chain <name>             Manifest chain (default: CLAIMRUSH_CHAIN or local)
  --abi-network <name>       ABI folder (default: ABI_NETWORK or base_sepolia)
  --actor-index <n>          Which derived account is the delegate submitter (default: 1)

Addresses
  --user <address>           The user identity granting permissions (default: USER_ADDRESS or actor0)
  --delegate <address>       The delegate/bot address (default: DELEGATE_ADDRESS or actor1)

Build
  --perms <spec>             Permission spec (default: TAKEOVER_FOR,CLAIM_ALL_FOR)
                             - numeric: 0x... or decimal
                             - names: TAKEOVER_FOR,CLAIM_ALL_FOR (prefix P_ optional)
  --expiry <unixSeconds>     Optional absolute expiry (overrides --expiry-seconds)
  --expiry-seconds <n>       Session expiry seconds from chain timestamp (default: 3600)
  --deadline <unixSeconds>   Optional absolute signature deadline (overrides --deadline-seconds)
  --deadline-seconds <n>     Signature deadline seconds from chain timestamp (default: 600)
  --revoke                   Convenience: build a revoke payload (perms=0, expiry=0)
  --out <path>               Write typed data JSON to a file (default: stdout)
  --pretty                   Pretty JSON

Submit
  --typed-data <path>        Typed data JSON file produced by --cmd build
  --sig <hex>                Signature hex
  --sig-path <path>          Read signature hex from file

Status
  --required-perms <spec>    Optional: check whether session satisfies these perms (mask or names)

Environment
  RPC_URL
  CLAIMRUSH_CHAIN
  ABI_NETWORK
  USER_ADDRESS
  DELEGATE_ADDRESS
  MNEMONIC / PRIVATE_KEYS
  SESSION_CMD
  SESSION_PERMS
  SESSION_EXPIRY (absolute unix seconds)
  SESSION_EXPIRY_SECONDS
  SESSION_DEADLINE (absolute unix seconds)
  SIG_DEADLINE_SECONDS
  SESSION_TYPED_DATA
  SESSION_SIG

Examples
  # Build typed data for a wallet to sign
  RPC_URL=http://127.0.0.1:8545 \
    npm -C agents/sdk run example:session -- --cmd build --perms TAKEOVER_FOR,CLAIM_ALL_FOR --pretty --out /tmp/session.json

  # Submit after the user signs (delegate pays gas)
  RPC_URL=http://127.0.0.1:8545 \
    npm -C agents/sdk run example:session -- --cmd submit --typed-data /tmp/session.json --sig 0x...

  # Inspect status
  RPC_URL=http://127.0.0.1:8545 \
    npm -C agents/sdk run example:session -- --cmd status --required-perms TAKEOVER_FOR
`);
    process.exit(0);
  }

  return {
    rpcUrl: env.RPC_URL ?? get('rpc-url') ?? 'http://127.0.0.1:8545',
    chain: env.CLAIMRUSH_CHAIN ?? get('chain') ?? 'local',
    abiNetwork: (env.ABI_NETWORK ?? get('abi-network') ?? 'base_sepolia') as AbiNetwork,
    actorIndex: get('actor-index') ? Number(get('actor-index')) : undefined,

    cmd: (env.SESSION_CMD ?? get('cmd') ?? 'status') as Cmd,

    user: env.USER_ADDRESS ?? get('user') ?? '',
    delegate: env.DELEGATE_ADDRESS ?? get('delegate') ?? '',

    permsSpec: env.SESSION_PERMS ?? get('perms'),
    expiry: env.SESSION_EXPIRY ?? get('expiry'),
    expirySeconds: env.SESSION_EXPIRY_SECONDS
      ? Number(env.SESSION_EXPIRY_SECONDS)
      : get('expiry-seconds')
        ? Number(get('expiry-seconds'))
        : undefined,
    deadline: env.SESSION_DEADLINE ?? get('deadline'),
    deadlineSeconds: env.SIG_DEADLINE_SECONDS
      ? Number(env.SIG_DEADLINE_SECONDS)
      : get('deadline-seconds')
        ? Number(get('deadline-seconds'))
        : undefined,
    revoke: has('revoke'),

    out: get('out'),
    typedDataPath: env.SESSION_TYPED_DATA ?? get('typed-data'),
    sig: env.SESSION_SIG ?? get('sig'),
    sigPath: get('sig-path'),

    requiredPermsSpec: get('required-perms'),
    pretty: has('pretty'),
  };
}

function readTextMaybeFile(value?: string, path?: string): string | undefined {
  if (value && value.trim()) return value.trim();
  if (path && path.trim()) return fs.readFileSync(path.trim(), 'utf8').trim();
  return undefined;
}

async function main(): Promise<void> {
  const opts = parseArgs(process.argv.slice(2), process.env);

  const manifest = loadDeploymentManifest({ chain: opts.chain });
  const delegationHub = (manifest.contracts as any).DelegationHub?.address as Address | undefined;
  if (!delegationHub) throw new Error('DelegationHub not found in manifest');

  const actors = deriveActors({
    count: 10,
    mnemonic: process.env.MNEMONIC ?? DEFAULT_ANVIL_MNEMONIC,
    privateKeysCsv: process.env.PRIVATE_KEYS,
  });

  // Default addresses (local): actor0=user, actor1=delegate.
  const fallbackUser = actors[0]?.account.address;
  const fallbackDelegate = actors[1]?.account.address;

  const user = getAddress(
    (opts.user && isAddress(opts.user) ? opts.user : fallbackUser) as Address,
  );
  const delegate = getAddress(
    (opts.delegate && isAddress(opts.delegate) ? opts.delegate : fallbackDelegate) as Address,
  );

  // Delegate is the submitter by default (actor1). Users shouldn't put their private key on the bot.
  const submitterIdx = opts.actorIndex ?? 1;
  const submitter = actors[submitterIdx];
  if (!submitter) throw new Error(`Missing derived actor at index ${submitterIdx}`);

  const clients = createClaimRushClients({ rpcUrl: opts.rpcUrl, account: submitter.account });
  const chainId = await clients.publicClient.getChainId();

  // Use chain time (not local time) for expiry/deadline.
  const head = await clients.publicClient.getBlock({ blockTag: 'latest' });
  const now = head.timestamp;

  if (opts.cmd === 'status') {
    const session = await getDelegationSession({
      publicClient: clients.publicClient,
      delegationHub,
      user,
      delegate,
      abiNetwork: opts.abiNetwork,
    });

    const active = session.expiry !== 0n && session.expiry >= now;
    const secondsUntilExpiry = active ? session.expiry - now : 0n;

    const requiredPerms = opts.requiredPermsSpec
      ? parsePermsSpec(opts.requiredPermsSpec)
      : undefined;
    const satisfies =
      requiredPerms !== undefined
        ? active && (session.perms & requiredPerms) === requiredPerms
        : undefined;

    console.log(
      stringifyJson(
        {
          chainId,
          user,
          delegate,
          delegationHub,
          now: now.toString(),
          perms: session.perms.toString(),
          permsNames: describePerms(session.perms),
          expiry: session.expiry.toString(),
          active,
          secondsUntilExpiry: secondsUntilExpiry.toString(),
          requiredPerms: requiredPerms?.toString(),
          satisfiesRequiredPerms: satisfies,
        },
        { pretty: opts.pretty },
      ),
    );
    return;
  }

  if (opts.cmd === 'build') {
    const perms = opts.revoke ? 0n : parsePermsSpec(opts.permsSpec ?? 'TAKEOVER_FOR,CLAIM_ALL_FOR');
    const expirySeconds = BigInt(opts.expirySeconds ?? 3600);
    const deadlineSeconds = BigInt(opts.deadlineSeconds ?? 600);

    const expiry = opts.revoke ? 0n : opts.expiry ? BigInt(opts.expiry) : now + expirySeconds;
    const deadline = opts.deadline ? BigInt(opts.deadline) : now + deadlineSeconds;

    const nonce = await readDelegationNonce({
      publicClient: clients.publicClient,
      delegationHub,
      user,
      abiNetwork: opts.abiNetwork,
    });

    const typed = buildSetSessionTypedData({
      chainId,
      delegationHub,
      user,
      delegate,
      perms,
      expiry,
      nonce,
      deadline,
    });

    const json = stringifyJson(typed, { pretty: opts.pretty });

    if (opts.out) {
      fs.writeFileSync(opts.out, json);
      console.error(`wrote: ${opts.out}`);
    } else {
      console.log(json);
    }

    console.error(`user:     ${user}`);
    console.error(`delegate: ${delegate}`);
    console.error(`hub:      ${delegationHub}`);
    console.error(`chainId:  ${chainId}`);
    console.error(`nonce:    ${nonce.toString()}`);
    console.error(`perms:    ${perms.toString()} (${describePerms(perms).join(', ') || 'none'})`);
    const expiryNote = opts.revoke
      ? '(revoke)'
      : opts.expiry
        ? '(absolute)'
        : `(+${expirySeconds.toString()}s)`;
    const deadlineNote = opts.deadline ? '(absolute)' : `(+${deadlineSeconds.toString()}s)`;

    console.error(`expiry:   ${expiry.toString()} ${expiryNote}`);
    console.error(`deadline: ${deadline.toString()} ${deadlineNote}`);

    return;
  }

  if (opts.cmd === 'submit') {
    const typedPath = opts.typedDataPath;
    if (!typedPath) throw new Error('Missing --typed-data <path>');

    const sig = readTextMaybeFile(opts.sig, opts.sigPath);
    if (!sig) throw new Error('Missing --sig 0x... or --sig-path <file>');
    if (!/^0x[0-9a-fA-F]+$/.test(sig))
      throw new Error('Signature must be a 0x-prefixed hex string');

    let typed: any;
    try {
      typed = JSON.parse(fs.readFileSync(typedPath, 'utf8'));
    } catch (err: any) {
      throw new Error(`Failed to parse typed data file '${typedPath}': ${err?.message ?? err}`);
    }
    const domain = typed?.domain;
    const msg = typed?.message;

    const verifyingContract = domain?.verifyingContract;
    const typedChainId = domain?.chainId;

    if (!verifyingContract || !isAddress(verifyingContract))
      throw new Error('Invalid typed data domain.verifyingContract');

    const msgUser = msg?.user;
    const msgDelegate = msg?.delegate;
    if (!msgUser || !isAddress(msgUser)) throw new Error('Invalid typed data message.user');
    if (!msgDelegate || !isAddress(msgDelegate))
      throw new Error('Invalid typed data message.delegate');

    const perms = BigInt(msg?.perms);
    const expiry = BigInt(msg?.expiry);
    const nonce = BigInt(msg?.nonce);
    const deadline = BigInt(msg?.deadline);

    if (typedChainId !== undefined && Number(typedChainId) !== chainId) {
      // Hard failure: submitting an EIP-712 signature whose domain.chainId
      // does not match the RPC chainId will either revert on signature
      // verification (DelegationHub rejects) or, in the case of a replay-
      // unsafe pattern copied elsewhere, let a signature intended for a
      // different network land on this one. Fail before building the tx.
      throw new Error(
        `EIP-712 chainId mismatch: typed domain.chainId=${typedChainId}, ` +
          `RPC chainId=${chainId}. Refusing to submit; re-sign on the target ` +
          `network or point the submitter RPC at chainId=${typedChainId}.`,
      );
    }

    const hash = await submitSetSessionBySig({
      publicClient: clients.publicClient,
      submitterWalletClient: clients.walletClient!,
      delegationHub: getAddress(verifyingContract as Address),
      chainId,
      user: getAddress(msgUser as Address),
      delegate: getAddress(msgDelegate as Address),
      perms,
      expiry,
      nonce,
      deadline,
      sig: sig as `0x${string}`,
      abiNetwork: opts.abiNetwork,
    });

    console.log(
      stringifyJson(
        {
          ok: true,
          tx: hash,
          chainId,
          delegationHub: verifyingContract,
          user: msgUser,
          delegate: msgDelegate,
          perms: perms.toString(),
          permsNames: describePerms(perms),
          expiry: expiry.toString(),
          nonce: nonce.toString(),
          deadline: deadline.toString(),
        },
        { pretty: opts.pretty },
      ),
    );

    return;
  }

  throw new Error(`Unknown cmd: ${opts.cmd}`);
}

main().catch((err) => {
  console.error(err);
  process.exit(1);
});
