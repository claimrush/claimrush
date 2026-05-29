import fs from 'node:fs';

import { createWalletClient, getAddress, http, isAddress, type Address } from 'viem';

import {
  buildSetSessionTypedData,
  createClaimRushClients,
  describePerms,
  getDelegationSession,
  loadDeploymentManifest,
  parsePermsSpec,
  readDelegationNonce,
  submitSetSessionBySig,
} from '@claimrush/agent-sdk';

import { helpRequested, makeFlagBag } from '../util/args.js';
import { isChainName, resolveNetwork } from '../safety/networks.js';
import { jsonStringify, parseBigIntStrict } from '../safety/cral.js';
import { loadAgentAccount } from '../util/identity.js';

const HELP = `claimrush session - DelegationHub session lifecycle (gasless from user)

USAGE
  claimrush session build  --user 0xUser --delegate 0xBot --perms TAKEOVER_FOR,CLAIM_ALL_FOR
                           [--expiry-seconds 3600] [--deadline-seconds 600] [--out path] [--pretty]

  claimrush session submit --typed-data path --sig 0x... [--actor-index 1] [--execute] [--pretty]

  claimrush session revoke --user 0xUser --delegate 0xBot
                           [--expiry-seconds 0] [--deadline-seconds 600] [--out path]

  claimrush session status --user 0xUser --delegate 0xBot [--required-perms TAKEOVER_FOR]

NOTES
  - 'build' and 'revoke' produce typed data the user must sign with their wallet.
  - 'submit' broadcasts the user's signature with the delegate's wallet (gasless for user).
  - 'submit' is dry-run by default for safety; pass --execute to actually send.
  - 'status' is read-only.
`;

export async function runSession(argv: string[]): Promise<number> {
  if (helpRequested(argv) || argv.length === 0) {
    console.log(HELP);
    return 0;
  }
  const sub = String(argv[0]);
  const rest = argv.slice(1);
  const f = makeFlagBag(rest);

  const chainArg = f.get('chain') ?? process.env.CLAIMRUSH_CHAIN ?? 'local';
  if (!isChainName(chainArg)) {
    console.error(`[session] invalid --chain '${chainArg}'`);
    return 64;
  }
  const net = resolveNetwork({
    chain: chainArg,
    rpcUrl: f.get('rpc-url'),
    requireAllowlistedRpc: chainArg === 'base' && sub === 'submit' && f.has('execute'),
  });

  const manifest = loadDeploymentManifest({ chain: net.manifestStem });
  const delegationHub = (manifest.contracts as any).DelegationHub?.address as Address | undefined;
  if (!delegationHub) {
    console.error(`[session] DelegationHub not found in manifest for chain ${net.chain}`);
    return 70;
  }

  const pretty = f.has('pretty');

  if (sub === 'status') {
    const userIn = f.get('user');
    const delegateIn = f.get('delegate');
    if (!userIn || !isAddress(userIn) || !delegateIn || !isAddress(delegateIn)) {
      console.error('[session status] requires --user 0x... --delegate 0x...');
      return 64;
    }
    const { publicClient } = createClaimRushClients({ rpcUrl: net.rpcUrl });
    const session = await getDelegationSession({
      publicClient,
      delegationHub,
      user: getAddress(userIn) as Address,
      delegate: getAddress(delegateIn) as Address,
      abiNetwork: net.abiNetwork,
    });
    const head = await publicClient.getBlock({ blockTag: 'latest' });
    const active = session.expiry !== 0n && session.expiry >= head.timestamp;
    const requiredPermsSpec = f.get('required-perms');
    const requiredPerms = requiredPermsSpec ? parsePermsSpec(requiredPermsSpec) : undefined;
    const satisfies =
      requiredPerms !== undefined ? active && (session.perms & requiredPerms) === requiredPerms : null;
    console.log(
      jsonStringify(
        {
          chain: net.chain,
          delegationHub,
          user: userIn,
          delegate: delegateIn,
          chainTimestamp: head.timestamp.toString(),
          perms: session.perms.toString(),
          permsNames: describePerms(session.perms),
          expiry: session.expiry.toString(),
          active,
          requiredPerms: requiredPerms?.toString(),
          satisfiesRequiredPerms: satisfies,
        },
        pretty,
      ),
    );
    return 0;
  }

  if (sub === 'build' || sub === 'revoke') {
    const userIn = f.get('user');
    const delegateIn = f.get('delegate');
    if (!userIn || !isAddress(userIn) || !delegateIn || !isAddress(delegateIn)) {
      console.error(`[session ${sub}] requires --user 0x... --delegate 0x...`);
      return 64;
    }
    const user = getAddress(userIn) as Address;
    const delegate = getAddress(delegateIn) as Address;

    const { publicClient } = createClaimRushClients({ rpcUrl: net.rpcUrl });
    const chainId = await publicClient.getChainId();
    const head = await publicClient.getBlock({ blockTag: 'latest' });
    const now = head.timestamp;

    const expirySeconds = f.get('expiry-seconds')
      ? parseBigIntStrict(f.get('expiry-seconds') as string, 'expiry-seconds')
      : 3600n;
    const deadlineSeconds = f.get('deadline-seconds')
      ? parseBigIntStrict(f.get('deadline-seconds') as string, 'deadline-seconds')
      : 600n;

    const isRevoke = sub === 'revoke';
    const perms = isRevoke
      ? 0n
      : parsePermsSpec(f.get('perms') ?? 'TAKEOVER_FOR,CLAIM_ALL_FOR');
    const expiry = isRevoke ? 0n : now + expirySeconds;
    const deadline = now + deadlineSeconds;

    const nonce = await readDelegationNonce({
      publicClient,
      delegationHub,
      user,
      abiNetwork: net.abiNetwork,
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

    const json = jsonStringify(typed, pretty);
    const out = f.get('out');
    if (out) {
      fs.writeFileSync(out, json);
      console.error(`[session ${sub}] wrote: ${out}`);
    } else {
      console.log(json);
    }
    console.error(
      `[session ${sub}] user=${user} delegate=${delegate} hub=${delegationHub} chainId=${chainId} ` +
        `nonce=${nonce.toString()} perms=${perms.toString()} (${describePerms(perms).join(',') || 'none'}) ` +
        `expiry=${expiry.toString()} deadline=${deadline.toString()}`,
    );
    return 0;
  }

  if (sub === 'submit') {
    const typedDataPath = f.get('typed-data');
    const sig = f.get('sig')?.trim();
    if (!typedDataPath || !sig) {
      console.error('[session submit] requires --typed-data <path> and --sig 0x...');
      return 64;
    }
    if (!/^0x[0-9a-fA-F]+$/.test(sig)) {
      console.error('[session submit] --sig must be 0x-prefixed hex');
      return 64;
    }
    let typed: any;
    try {
      typed = JSON.parse(fs.readFileSync(typedDataPath, 'utf8'));
    } catch (err: unknown) {
      console.error(
        `[session submit] failed to parse typed data file ${typedDataPath}: ${(err as Error).message}`,
      );
      return 64;
    }
    const verifyingContract = typed?.domain?.verifyingContract;
    const typedChainId = typed?.domain?.chainId;
    const userMsg = typed?.message?.user;
    const delegateMsg = typed?.message?.delegate;
    if (!verifyingContract || !isAddress(verifyingContract))
      throw new Error('invalid typed data domain.verifyingContract');
    if (!userMsg || !isAddress(userMsg)) throw new Error('invalid typed data message.user');
    if (!delegateMsg || !isAddress(delegateMsg)) throw new Error('invalid typed data message.delegate');

    const perms = BigInt(typed.message.perms);
    const expiry = BigInt(typed.message.expiry);
    const nonce = BigInt(typed.message.nonce);
    const deadline = BigInt(typed.message.deadline);

    const actorIndex = f.get('actor-index') ? Number(f.get('actor-index')) : 1;
    const { account } = loadAgentAccount(actorIndex);
    const { publicClient } = createClaimRushClients({ rpcUrl: net.rpcUrl, account });
    const walletClient = createWalletClient({ transport: http(net.rpcUrl), account });
    const chainId = await publicClient.getChainId();
    if (typedChainId !== undefined && Number(typedChainId) !== chainId) {
      throw new Error(
        `EIP-712 chainId mismatch: typed=${typedChainId}, rpc=${chainId}. Refusing to submit.`,
      );
    }

    if (!f.has('execute')) {
      console.log(
        jsonStringify(
          {
            ok: true,
            stage: 'simulated',
            note: 'pass --execute to actually broadcast setSessionBySig',
            verifyingContract,
            user: userMsg,
            delegate: delegateMsg,
            perms: perms.toString(),
            permsNames: describePerms(perms),
            expiry: expiry.toString(),
            nonce: nonce.toString(),
            deadline: deadline.toString(),
            submitter: account.address,
          },
          pretty,
        ),
      );
      return 0;
    }

    if (net.chain === 'base' && !f.has('i-understand')) {
      console.error('[session submit] --execute on --chain base requires --i-understand');
      return 65;
    }

    const hash = await submitSetSessionBySig({
      publicClient,
      submitterWalletClient: walletClient,
      delegationHub: getAddress(verifyingContract as Address),
      chainId,
      user: getAddress(userMsg as Address),
      delegate: getAddress(delegateMsg as Address),
      perms,
      expiry,
      nonce,
      deadline,
      sig: sig as `0x${string}`,
      abiNetwork: net.abiNetwork,
    });
    console.log(
      jsonStringify(
        {
          ok: true,
          stage: 'executed',
          tx: hash,
          chainId,
          delegationHub: verifyingContract,
          user: userMsg,
          delegate: delegateMsg,
          perms: perms.toString(),
          permsNames: describePerms(perms),
          expiry: expiry.toString(),
          nonce: nonce.toString(),
          deadline: deadline.toString(),
          submitter: account.address,
        },
        pretty,
      ),
    );
    return 0;
  }

  console.error(`[session] unknown subcommand: ${sub}`);
  console.error(HELP);
  return 64;
}
