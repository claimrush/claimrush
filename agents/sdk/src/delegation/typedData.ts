import type { Address } from 'viem';

export const DELEGATION_HUB_EIP712_NAME = 'ClaimRush DelegationHub';
export const DELEGATION_HUB_EIP712_VERSION = '1';

export type SetSessionTypedDataParams = {
  chainId: number;
  delegationHub: Address;

  user: Address;
  delegate: Address;
  perms: bigint;
  /** unix seconds */
  expiry: bigint;
  nonce: bigint;
  /** unix seconds */
  deadline: bigint;
};

// Matches DelegationHub.sol
// keccak256("SetSession(address user,address delegate,uint256 perms,uint256 expiry,uint256 nonce,uint256 deadline)")
export const SET_SESSION_PRIMARY_TYPE = 'SetSession' as const;

export const SET_SESSION_TYPES = {
  SetSession: [
    { name: 'user', type: 'address' },
    { name: 'delegate', type: 'address' },
    { name: 'perms', type: 'uint256' },
    // DelegationHub encodes expiry as uint256(expiry)
    { name: 'expiry', type: 'uint256' },
    { name: 'nonce', type: 'uint256' },
    { name: 'deadline', type: 'uint256' },
  ],
} as const;

/**
 * Builds the EIP-712 typed data payload required by DelegationHub.setSessionBySig.
 *
 * `chainId` is validated as a positive integer to prevent a zero/negative/NaN
 * chainId from producing a well-formed domain separator that binds to no real
 * chain (defense-in-depth alongside on-chain block.chainid enforcement).
 */
export function buildSetSessionTypedData(params: SetSessionTypedDataParams) {
  if (!Number.isInteger(params.chainId) || params.chainId <= 0) {
    throw new Error('chainId must be a positive integer');
  }

  return {
    domain: {
      name: DELEGATION_HUB_EIP712_NAME,
      version: DELEGATION_HUB_EIP712_VERSION,
      chainId: params.chainId,
      verifyingContract: params.delegationHub,
    },
    types: SET_SESSION_TYPES,
    primaryType: SET_SESSION_PRIMARY_TYPE,
    message: {
      user: params.user,
      delegate: params.delegate,
      perms: params.perms,
      expiry: params.expiry,
      nonce: params.nonce,
      deadline: params.deadline,
    },
  } as const;
}
