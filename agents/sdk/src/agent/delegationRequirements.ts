import type { Address } from 'viem';

import {
  P_TAKEOVER_FOR,
  P_WITHDRAW_KING_BUCKET_FOR,
  P_CLAIM_SHAREHOLDER_FOR,
  P_CLAIM_ALL_FOR,
  P_FURNACE_ENTER_ETH_FOR,
  P_FURNACE_ENTER_CLAIM_FOR,
  P_FURNACE_ENTER_TOKEN_FOR,
  P_VE_EXTEND_LOCK_FOR,
  P_VE_MERGE_LOCKS_FOR,
  P_VE_UNLOCK_EXPIRED_FOR,
  P_SET_KING_AUTO_LOCK_CONFIG_FOR,
  P_SET_SHAREHOLDER_AUTOCOMPOUND_CONFIG_FOR,
  P_SET_LP_AUTOCOMPOUND_CONFIG_FOR,
} from '../delegation/permissions.js';

import type { AgentAction } from './types.js';

export type DelegationRequirement = {
  user: Address;
  requiredPerms: bigint;
};

/**
 * Returns the delegation requirement for an action, or null if no delegation is needed.
 *
 * Delegated actions (with `For` suffix) require an active DelegationHub session
 * with the appropriate permission bits.
 */
export function getDelegationRequirementForAction(
  action: AgentAction,
): DelegationRequirement | null {
  switch (action.kind) {
    // ------------------------------------------------------------
    // Non-delegated (self-play) actions
    // ------------------------------------------------------------
    case 'furnace.enterWithEth':
    case 'furnace.enterWithClaim':
    case 'furnace.enterWithToken':
    case 'mineCore.takeover':
    case 'mineCore.takeoverWithToken':
    case 'mineCore.setCurrentReignRecipients':
    case 'mineCore.setKingAutoLockConfig':
    case 'royalties.claimShareholderEth':
    case 'royalties.claimShareholderLock':
    case 'royalties.setAutoCompoundConfig':
    case 'mineCore.withdrawKingBalance':
    case 'mineCore.withdrawRefundBalance':
    case 'marketRouter.sellLockToFurnace':
    case 'marketRouter.sellListedLockToFurnace':
    case 'marketRouter.listLock':
    case 'marketRouter.delistLock':
    case 'marketRouter.cancelExpiredListing':
    case 'marketRouter.createBonusTargetEscrowWithTarget':
    case 'marketRouter.cancelBonusTargetEscrow':
    case 'marketRouter.extendBonusTargetEscrowExpiry':
    case 'marketRouter.cancelExpiredBonusTargetEscrow':
    case 'marketRouter.executeAutoFurnace':
    case 'erc20.approve':
    case 'erc20.ensureAllowance':
    case 've.approve':
    case 've.setApprovalForAll':
    case 'furnace.extendWithBonus':
    case 'furnace.mergeLocksWithBonus':
    case 've.unlock':
    case 've.setAutoMax':
    case 've.checkpointGlobalState':
    case 've.checkpointTotalVe':
      return null;

    // ------------------------------------------------------------
    // Delegated actions
    // ------------------------------------------------------------
    case 'furnace.enterWithEthFor':
      return { user: action.user, requiredPerms: P_FURNACE_ENTER_ETH_FOR };

    case 'furnace.enterWithClaimFromCallerFor':
      return { user: action.user, requiredPerms: P_FURNACE_ENTER_CLAIM_FOR };

    case 'furnace.enterWithTokenFromCallerFor':
      return { user: action.user, requiredPerms: P_FURNACE_ENTER_TOKEN_FOR };

    case 'mineCore.takeoverFor':
      return { user: action.newKing, requiredPerms: P_TAKEOVER_FOR };

    case 'claimAllHelper.claimShareholderForUser':
      return { user: action.user, requiredPerms: P_CLAIM_SHAREHOLDER_FOR };

    case 'claimAllHelper.withdrawKingBalanceForUser':
      return { user: action.user, requiredPerms: P_WITHDRAW_KING_BUCKET_FOR };

    case 'claimAllHelper.claimAllFor':
      return { user: action.user, requiredPerms: P_CLAIM_ALL_FOR };

    case 'furnace.extendWithBonusFor':
      return { user: action.user, requiredPerms: P_VE_EXTEND_LOCK_FOR };

    case 'furnace.mergeLocksWithBonusFor':
      return { user: action.user, requiredPerms: P_VE_MERGE_LOCKS_FOR };

    case 've.unlockExpiredForUser':
      return { user: action.user, requiredPerms: P_VE_UNLOCK_EXPIRED_FOR };

    case 'mineCore.setKingAutoLockConfigForUser':
      return { user: action.user, requiredPerms: P_SET_KING_AUTO_LOCK_CONFIG_FOR };

    case 'royalties.setAutoCompoundConfigForUser':
      return { user: action.user, requiredPerms: P_SET_SHAREHOLDER_AUTOCOMPOUND_CONFIG_FOR };

    case 'lpVault.setAutoCompoundConfigForUser':
      return { user: action.user, requiredPerms: P_SET_LP_AUTOCOMPOUND_CONFIG_FOR };

    default: {
      // Exhaustiveness check: if we reach here, a new action kind was added but not handled.
      const _exhaustive: never = action;
      throw new Error(`Unhandled action kind: ${(_exhaustive as AgentAction).kind}`);
    }
  }
}
