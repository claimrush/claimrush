import type { Abi, Address, PublicClient, WalletClient } from 'viem';
import { isAddress } from 'viem';

import type { AbiNetwork } from '../abis.js';
import { loadAbi } from '../abis.js';
import { buildSetSessionTypedData } from './typedData.js';

export type DelegationHubReadParams = {
  publicClient: PublicClient;
  delegationHub: Address;
  abiNetwork?: AbiNetwork;
  repoRoot?: string;
};

export type DelegationSession = {
  perms: bigint;
  expiry: bigint;
};

function loadDelegationHubAbi(params: { abiNetwork?: AbiNetwork; repoRoot?: string }): Abi {
  return loadAbi({
    contractName: 'DelegationHub',
    abiNetwork: params.abiNetwork,
    repoRoot: params.repoRoot,
  });
}

export async function readDelegationNonce(
  params: DelegationHubReadParams & {
    user: Address;
  },
): Promise<bigint> {
  const abi = loadDelegationHubAbi(params);
  const res = await params.publicClient.readContract({
    address: params.delegationHub,
    abi,
    functionName: 'nonces',
    args: [params.user],
  });
  return res as unknown as bigint;
}

export async function getDelegationSession(
  params: DelegationHubReadParams & {
    user: Address;
    delegate: Address;
  },
): Promise<DelegationSession> {
  const abi = loadDelegationHubAbi(params);
  const res = await params.publicClient.readContract({
    address: params.delegationHub,
    abi,
    functionName: 'getSession',
    args: [params.user, params.delegate],
  });

  // viem returns tuples either as arrays or as objects with numeric keys
  const perms = (res as any)[0] as bigint;
  const expiry = (res as any)[1] as bigint;
  return { perms, expiry };
}

export async function isAuthorized(
  params: DelegationHubReadParams & {
    user: Address;
    delegate: Address;
    requiredPerms: bigint;
  },
): Promise<boolean> {
  const abi = loadDelegationHubAbi(params);
  const res = await params.publicClient.readContract({
    address: params.delegationHub,
    abi,
    functionName: 'isAuthorized',
    args: [params.user, params.delegate, params.requiredPerms],
  });
  return res as unknown as boolean;
}

export type SetSessionBySigParams = {
  delegationHub: Address;
  chainId: number;

  user: Address;
  delegate: Address;
  perms: bigint;
  expiry: bigint;
  nonce: bigint;
  deadline: bigint;
  sig: `0x${string}`;
};

/**
 * Signs the EIP-712 payload for DelegationHub.setSessionBySig using the user's wallet.
 *
 * Notes
 * - For EOAs this is straightforward.
 * - For smart wallets (EIP-1271), signature generation is wallet-specific.
 * - `submitSetSessionBySig` simulates before broadcast and validates both
 *   `deadline` and `expiry` against the current block, so a stale or
 *   already-expired session is rejected up front with a clear error.
 */

export async function signSetSession(params: {
  userWalletClient: WalletClient;
  publicClient: PublicClient;
  delegationHub: Address;
  chainId: number;

  user: Address;
  delegate: Address;
  perms: bigint;
  expiry: bigint;
  nonce: bigint;
  deadline: bigint;
}): Promise<`0x${string}`> {
  if (!params.userWalletClient.account)
    throw new Error('userWalletClient must be created with an account');
  if (!isAddress(params.user) || !isAddress(params.delegate) || !isAddress(params.delegationHub)) {
    throw new Error('Invalid address in signSetSession');
  }
  if (params.expiry <= 0n) {
    throw new Error('signSetSession: expiry must be a positive timestamp');
  }
  if (params.nonce < 0n) {
    throw new Error('signSetSession: nonce must be non-negative');
  }
  if (params.user.toLowerCase() === params.delegate.toLowerCase()) {
    throw new Error('signSetSession: delegate must differ from user (self-delegation is a no-op)');
  }
  if (params.perms === 0n) {
    throw new Error(
      'signSetSession: perms must be non-zero (empty permission mask grants nothing)',
    );
  }
  if (params.deadline < params.expiry) {
    throw new Error(
      `signSetSession: deadline must be >= expiry to allow time for submission ` +
        `(deadline=${params.deadline}, expiry=${params.expiry})`,
    );
  }

  const block = await params.publicClient.getBlock();
  if (params.expiry <= block.timestamp) {
    throw new Error(
      `signSetSession: expiry must be greater than current block timestamp ` +
        `(expiry=${params.expiry}, block.timestamp=${block.timestamp})`,
    );
  }
  if (params.deadline <= block.timestamp) {
    throw new Error(
      `signSetSession: deadline must be greater than current block timestamp (deadline=${params.deadline}, block.timestamp=${block.timestamp})`,
    );
  }

  const MAX_SESSION_DURATION_SEC = 365n * 24n * 60n * 60n;
  const sessionDuration = params.expiry - block.timestamp;
  if (sessionDuration > MAX_SESSION_DURATION_SEC) {
    throw new Error(
      `signSetSession: session duration ${sessionDuration}s exceeds maximum of ${MAX_SESSION_DURATION_SEC}s (~1 year). ` +
        `Long-lived sessions weaken the time-boxed security model. ` +
        `Prefer shorter durations with periodic renewal.`,
    );
  }

  const typed = buildSetSessionTypedData({
    chainId: params.chainId,
    delegationHub: params.delegationHub,
    user: params.user,
    delegate: params.delegate,
    perms: params.perms,
    expiry: params.expiry,
    nonce: params.nonce,
    deadline: params.deadline,
  });

  return await params.userWalletClient.signTypedData(typed as any);
}

/**
 * Submits DelegationHub.setSessionBySig.
 *
 * Anyone can submit this tx; typically the delegate pays gas.
 */
export async function submitSetSessionBySig(
  params: {
    publicClient: PublicClient;
    submitterWalletClient: WalletClient;
    abiNetwork?: AbiNetwork;
    repoRoot?: string;
  } & SetSessionBySigParams,
): Promise<`0x${string}`> {
  if (!params.submitterWalletClient.account)
    throw new Error('submitterWalletClient must be created with an account');

  if (!params.sig || params.sig.length < 6) {
    throw new Error(
      'setSessionBySig: sig must be a valid hex-encoded signature (got empty or stub value)',
    );
  }

  // Pre-check: verify deadline hasn't expired before attempting submission.
  // This provides a clearer error than the contract revert.
  const block = await params.publicClient.getBlock();
  if (block.timestamp > params.deadline) {
    throw new Error(
      `setSessionBySig: deadline expired before submission. ` +
        `block.timestamp=${block.timestamp}, deadline=${params.deadline}, ` +
        `diff=${block.timestamp - params.deadline}s. ` +
        `Consider increasing deadlineSeconds or reducing delay between timestamp capture and submission.`,
    );
  }

  if (block.timestamp >= params.expiry) {
    throw new Error(
      `setSessionBySig: session expiry is in the past. ` +
        `block.timestamp=${block.timestamp}, expiry=${params.expiry}. ` +
        `The created session would be immediately expired and unusable.`,
    );
  }

  const abi = loadDelegationHubAbi(params);

  // Simulate first to obtain a properly typed request object (viem `chain` typing).
  const sim = await params.publicClient.simulateContract({
    account: params.submitterWalletClient.account,
    address: params.delegationHub,
    abi,
    functionName: 'setSessionBySig',
    args: [
      params.user,
      params.delegate,
      params.perms,
      params.expiry,
      params.nonce,
      params.deadline,
      params.sig,
    ],
  });

  return await params.submitterWalletClient.writeContract(sim.request);
}
