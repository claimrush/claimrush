import type { Address, PublicClient } from 'viem';
import { isAddress } from 'viem';

import {
  isAuthorized,
  describePerms,
  P_TAKEOVER_FOR,
  P_FURNACE_ENTER_ETH_FOR,
  P_FURNACE_ENTER_CLAIM_FOR,
  P_FURNACE_ENTER_TOKEN_FOR,
  P_CLAIM_SHAREHOLDER_FOR,
  P_CLAIM_ALL_FOR,
  P_WITHDRAW_KING_BUCKET_FOR,
  P_VE_EXTEND_LOCK_FOR,
  P_VE_MERGE_LOCKS_FOR,
  P_VE_UNLOCK_EXPIRED_FOR,
  P_SET_KING_AUTO_LOCK_CONFIG_FOR,
  P_SET_SHAREHOLDER_AUTOCOMPOUND_CONFIG_FOR,
  P_SET_LP_AUTOCOMPOUND_CONFIG_FOR,
} from '@claimrush/agent-sdk';

import type { AbiNetwork } from './networks.js';

/** Map an AgentAction kind to the DelegationHub permission bit it requires. */
export function permsForActionKind(kind: string): bigint {
  switch (kind) {
    case 'mineCore.takeoverFor':
      return P_TAKEOVER_FOR;
    case 'furnace.enterWithEthFor':
      return P_FURNACE_ENTER_ETH_FOR;
    case 'furnace.enterWithClaimFromCallerFor':
      return P_FURNACE_ENTER_CLAIM_FOR;
    case 'furnace.enterWithTokenFromCallerFor':
      return P_FURNACE_ENTER_TOKEN_FOR;
    case 'claimAllHelper.claimShareholderForUser':
      return P_CLAIM_SHAREHOLDER_FOR;
    case 'claimAllHelper.claimAllFor':
      return P_CLAIM_ALL_FOR;
    case 'claimAllHelper.withdrawKingBalanceForUser':
      return P_WITHDRAW_KING_BUCKET_FOR;
    case 'furnace.extendWithBonusFor':
      return P_VE_EXTEND_LOCK_FOR;
    case 've.mergeLocksForUser':
      return P_VE_MERGE_LOCKS_FOR;
    case 've.unlockExpiredFor':
      return P_VE_UNLOCK_EXPIRED_FOR;
    case 'mineCore.setKingAutoLockConfigFor':
      return P_SET_KING_AUTO_LOCK_CONFIG_FOR;
    case 'royalties.setAutoCompoundConfigForUser':
      return P_SET_SHAREHOLDER_AUTOCOMPOUND_CONFIG_FOR;
    case 'lpAutoCompound.setConfigFor':
      return P_SET_LP_AUTOCOMPOUND_CONFIG_FOR;
    default:
      return 0n;
  }
}

/**
 * Verify the live `DelegationHub.isAuthorized(user, delegate, requiredPerms)`
 * before sending any *For action. The CRAL guidance is to re-check session
 * validity before EVERY write because the user may revoke mid-cycle.
 */
export async function requireLiveSession(p: {
  publicClient: PublicClient;
  delegationHub: Address;
  user: Address;
  delegate: Address;
  requiredPerms: bigint;
  abiNetwork: AbiNetwork;
}): Promise<{ ok: boolean; reason?: string; permsHumanReadable?: string[] }> {
  if (!isAddress(p.user)) return { ok: false, reason: `invalid acting-for user: ${p.user}` };
  if (!isAddress(p.delegate)) return { ok: false, reason: `invalid delegate: ${p.delegate}` };
  if (p.requiredPerms === 0n) return { ok: true, permsHumanReadable: [] };

  let authorized = false;
  try {
    authorized = await isAuthorized({
      publicClient: p.publicClient,
      delegationHub: p.delegationHub,
      user: p.user,
      delegate: p.delegate,
      requiredPerms: p.requiredPerms,
      abiNetwork: p.abiNetwork,
    });
  } catch (err: unknown) {
    return {
      ok: false,
      reason: `DelegationHub.isAuthorized read failed: ${(err as Error).message ?? String(err)}`,
    };
  }
  if (!authorized) {
    return {
      ok: false,
      reason:
        `DelegationHub session does not grant required perms ` +
        `${describePerms(p.requiredPerms).join(',') || p.requiredPerms.toString()} to ` +
        `delegate ${p.delegate} for user ${p.user}.`,
      permsHumanReadable: describePerms(p.requiredPerms),
    };
  }
  return { ok: true, permsHumanReadable: describePerms(p.requiredPerms) };
}

/**
 * Light RPC head-staleness probe. Returns the head block + age and a flag
 * the command can show to the user. CRAL emits `RPC_LAG_DETECTED` with a
 * tunable threshold; we surface the same data here.
 */
export async function rpcHeadProbe(
  publicClient: PublicClient,
): Promise<{ blockNumber: bigint; timestamp: bigint; ageSeconds: bigint }> {
  const head = await publicClient.getBlock({ blockTag: 'latest' });
  const now = BigInt(Math.floor(Date.now() / 1000));
  return {
    blockNumber: head.number ?? 0n,
    timestamp: head.timestamp,
    ageSeconds: now > head.timestamp ? now - head.timestamp : 0n,
  };
}
