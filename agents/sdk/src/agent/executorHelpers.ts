import type { Abi, Account, Address, PublicClient, WalletClient } from 'viem';
import { erc20Abi } from 'viem';

import type { AgentAction, AgentTxTelemetry } from './types.js';

import {
  P_CLAIM_ALL_FOR,
  P_CLAIM_SHAREHOLDER_FOR,
  P_FURNACE_ENTER_CLAIM_FOR,
  P_FURNACE_ENTER_ETH_FOR,
  P_FURNACE_ENTER_TOKEN_FOR,
  P_SET_KING_AUTO_LOCK_CONFIG_FOR,
  P_SET_LP_AUTOCOMPOUND_CONFIG_FOR,
  P_SET_SHAREHOLDER_AUTOCOMPOUND_CONFIG_FOR,
  P_TAKEOVER_FOR,
  P_VE_EXTEND_LOCK_FOR,
  P_VE_MERGE_LOCKS_FOR,
  P_VE_UNLOCK_EXPIRED_FOR,
  P_WITHDRAW_KING_BUCKET_FOR,
} from '../delegation/permissions.js';

export type DelegationRequirement = {
  user: Address;
  requiredPerms: bigint;
};

export function getDelegationRequirementForAction(
  action: AgentAction,
): DelegationRequirement | undefined {
  switch (action.kind) {
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

    default:
      return undefined;
  }
}

export type PrivateTxRoute = 'public' | 'private';

export function buildTxTelemetry(params: {
  txSender: { route: PrivateTxRoute; mode: 'off' | 'route' | 'only' };
  tx?: { hash: any; receipt: any; meta?: { nonce: bigint; attempts: number; hashes: any[] } };
  receipt?: any;
  meta?: { nonce: bigint; attempts: number; hashes: any[] };
}): AgentTxTelemetry {
  const out: AgentTxTelemetry = {
    route: params.txSender.route,
    privateRpcMode: params.txSender.mode,
  };

  const meta = params.tx?.meta ?? params.meta;
  if (meta) {
    out.nonce = meta.nonce;
    out.attempts = meta.attempts;
    out.hashes = meta.hashes as any;
  }

  const receipt = params.tx?.receipt ?? params.receipt;
  if (receipt) {
    out.blockNumber = receipt.blockNumber;
    out.status = (receipt as any)?.status;
    out.gasUsed = (receipt as any)?.gasUsed;

    const eff = (receipt as any)?.effectiveGasPrice;
    if (typeof eff === 'bigint') {
      out.effectiveGasPrice = eff;
    }

    if (typeof out.gasUsed === 'bigint' && typeof out.effectiveGasPrice === 'bigint') {
      out.feePaidWei = out.gasUsed * out.effectiveGasPrice;
    }
  }

  return out;
}

export function isPrivateTxAllowed(action: AgentAction): boolean {
  // Swap or MEV-sensitive actions only.
  switch (action.kind) {
    // Takeovers are highly MEV-sensitive.
    case 'mineCore.takeover':
    case 'mineCore.takeoverFor':
    case 'mineCore.takeoverWithToken':
      return true;

    // Furnace entry includes a swap (via DexAdapter) under the hood for ETH + token routes.
    case 'furnace.enterWithEth':
    case 'furnace.enterWithEthFor':
    case 'furnace.enterWithToken':
    case 'furnace.enterWithTokenFromCallerFor':
      return true;

    // CLAIM entry is not a swap, but may still be MEV-sensitive for large movements.
    case 'furnace.enterWithClaim':
    case 'furnace.enterWithClaimFromCallerFor':
      return true;

    // Shareholder claim that locks via Furnace (mode=LOCK_FURNACE).
    case 'royalties.claimShareholderLock':
      return true;

    // Market exits / fills can be MEV-sensitive (price impact / reserve dynamics).
    case 'marketRouter.sellLockToFurnace':
    case 'marketRouter.sellListedLockToFurnace':
    case 'marketRouter.executeAutoFurnace':
      return true;

    // ClaimAllHelper can optionally perform a Furnace lock (mode=LOCK_FURNACE).
    case 'claimAllHelper.claimShareholderForUser':
    case 'claimAllHelper.claimAllFor':
      return action.mode === 1;

    default:
      return false;
  }
}

export function pickWalletClientForAction(params: {
  action: AgentAction;
  publicWalletClient: WalletClient;
  privateWalletClient?: WalletClient;
  privateRpcMode?: 'off' | 'route' | 'only';
}): {
  walletClient: WalletClient;
  route: PrivateTxRoute;
  mode: 'off' | 'route' | 'only';
  blocked: boolean;
  reason?: string;
} {
  const havePrivate = Boolean(params.privateWalletClient);
  const mode: 'off' | 'route' | 'only' = havePrivate ? (params.privateRpcMode ?? 'route') : 'off';
  const allowed = isPrivateTxAllowed(params.action);

  if (mode === 'only' && !allowed) {
    return {
      walletClient: params.publicWalletClient,
      route: 'public',
      mode,
      blocked: true,
      reason: `Blocked by PRIVATE_RPC_MODE=only (action kind=${params.action.kind})`,
    };
  }

  if (mode !== 'off' && allowed && params.privateWalletClient) {
    return { walletClient: params.privateWalletClient, route: 'private', mode, blocked: false };
  }

  return { walletClient: params.publicWalletClient, route: 'public', mode, blocked: false };
}

export async function simulateOnly(params: {
  publicClient: PublicClient;
  account: Account;
  address: Address;
  abi: Abi;
  functionName: string;
  args?: readonly unknown[];
  value?: bigint;
}): Promise<unknown> {
  const sim = await params.publicClient.simulateContract({
    account: params.account,
    address: params.address,
    abi: params.abi,
    functionName: params.functionName as any,
    args: params.args as any,
    value: params.value,
  });

  return (sim as any).result;
}

export async function readAllowance(params: {
  publicClient: PublicClient;
  token: Address;
  owner: Address;
  spender: Address;
}): Promise<bigint | null> {
  try {
    const out = (await params.publicClient.readContract({
      address: params.token,
      abi: erc20Abi,
      functionName: 'allowance',
      args: [params.owner, params.spender],
    })) as bigint;
    return out;
  } catch {
    return null;
  }
}
