import type { Account, Address, PublicClient } from 'viem';
import { erc20Abi, erc721Abi, maxUint256 } from 'viem';

import type { AbiNetwork } from '../abis.js';
import type { DeploymentManifest } from '../manifest.js';

import type { AgentAction, AgentPlan } from './types.js';

export type AutoApproveMode = 'exact' | 'max';

export type AutoApproveOptions = {
  enabled: boolean;
  // which persist across agent sessions. If the approved spender contract is
  // ever compromised (e.g. proxy upgrade attack), all tokens can be drained
  // without further interaction. Operators should prefer 'exact' mode and
  // periodically review outstanding approvals.
  //
  /**
   * Approve sizing policy.
   *
   * Default: 'exact'.
   */
  mode?: AutoApproveMode;
  /**
   * If true, include veNFT approvals (ERC721 approve) for MarketRouter actions.
   *
   * Default: true.
   */
  includeNftApprovals?: boolean;
};

export type ExpandPlanWithAutoApprovalsResult = {
  plan: AgentPlan;
  notes: string[];
  inserted: number;
};

function sameAddress(a: Address, b: Address): boolean {
  return a.toLowerCase() === b.toLowerCase();
}

function allowanceKey(token: Address, spender: Address): string {
  return `${token.toLowerCase()}:${spender.toLowerCase()}`;
}

async function safeReadAllowance(params: {
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

async function safeReadErc721Owner(params: {
  publicClient: PublicClient;
  nft: Address;
  tokenId: bigint;
}): Promise<Address | null> {
  try {
    const out = (await params.publicClient.readContract({
      address: params.nft,
      abi: erc721Abi,
      functionName: 'ownerOf',
      args: [params.tokenId],
    })) as Address;
    return out;
  } catch {
    return null;
  }
}

async function safeReadErc721Approved(params: {
  publicClient: PublicClient;
  nft: Address;
  tokenId: bigint;
}): Promise<Address | null> {
  try {
    const out = (await params.publicClient.readContract({
      address: params.nft,
      abi: erc721Abi,
      functionName: 'getApproved',
      args: [params.tokenId],
    })) as Address;
    return out;
  } catch {
    return null;
  }
}

async function safeReadErc721IsApprovedForAll(params: {
  publicClient: PublicClient;
  nft: Address;
  owner: Address;
  operator: Address;
}): Promise<boolean | null> {
  try {
    const out = (await params.publicClient.readContract({
      address: params.nft,
      abi: erc721Abi,
      functionName: 'isApprovedForAll',
      args: [params.owner, params.operator],
    })) as boolean;
    return out;
  } catch {
    return null;
  }
}

export async function expandPlanWithAutoApprovals(p: {
  plan: AgentPlan;
  publicClient: PublicClient;
  account: Account;
  manifest: DeploymentManifest;
  abiNetwork: AbiNetwork;
  privateRpcMode?: 'off' | 'route' | 'only';
  options: AutoApproveOptions;
}): Promise<ExpandPlanWithAutoApprovalsResult> {
  if (!p.options.enabled) {
    return { plan: p.plan, notes: [], inserted: 0 };
  }

  const mode: AutoApproveMode = p.options.mode ?? 'exact';
  const includeNftApprovals: boolean = p.options.includeNftApprovals ?? true;

  // Approvals are not allowlisted in PRIVATE_RPC_MODE=only.
  if (p.privateRpcMode === 'only') {
    return {
      plan: p.plan,
      notes: ['auto-approve skipped (PRIVATE_RPC_MODE=only blocks approvals)'],
      inserted: 0,
    };
  }

  const caller = p.account.address as Address;

  const addrFurnace = p.manifest.contracts.Furnace.address as Address;
  const addrMineCore = p.manifest.contracts.MineCore.address as Address;
  const addrMarketRouter = (p.manifest.contracts as any).MarketRouter?.address as
    | Address
    | undefined;
  const addrClaimToken = (p.manifest.contracts as any).ClaimToken?.address as Address | undefined;
  const addrVe = (p.manifest.contracts as any).VeClaimNFT?.address as Address | undefined;

  const notes: string[] = [];
  const expanded: AgentAction[] = [];

  const allowanceCache = new Map<string, bigint | null>();
  const plannedAllowances = new Map<string, bigint>();
  const plannedVeApprovals = new Set<string>();

  const ensureAllowance = async (params: {
    token: Address;
    spender: Address;
    minAllowance: bigint;
    label: string;
  }): Promise<AgentAction | undefined> => {
    const k = allowanceKey(params.token, params.spender);

    const planned = plannedAllowances.get(k);
    if (planned !== undefined && planned >= params.minAllowance) {
      return undefined;
    }

    let allowance = allowanceCache.get(k);
    if (allowance === undefined) {
      allowance = await safeReadAllowance({
        publicClient: p.publicClient,
        token: params.token,
        owner: caller,
        spender: params.spender,
      });
      allowanceCache.set(k, allowance);
    }

    const cur = allowance ?? 0n;

    if (allowance === null) {
      notes.push(
        `warn: cannot read allowance for ${params.label} (token=${params.token} spender=${params.spender}); inserting approval anyway`,
      );
    }

    const effective = planned !== undefined ? planned : cur;
    if (effective >= params.minAllowance) return undefined;

    const approveAmount = mode === 'max' ? maxUint256 : params.minAllowance;
    // are a well-known grief vector — if the approved contract is compromised
    // (proxy upgrade, admin key leak) the attacker can drain the full token
    // balance without a separate approval step. The SDK defaults to 'exact'
    // mode, but operators who opt into 'max' should see a clear audit trail.
    if (mode === 'max') {
      notes.push(
        `SECURITY: granting MaxUint256 approval for ${params.label} ` +
          `(token=${params.token} spender=${params.spender}). ` +
          `Consider 'exact' mode to limit exposure.`,
      );
    }
    plannedAllowances.set(k, approveAmount);

    notes.push(
      `approve: ${params.label} token=${params.token} spender=${params.spender} min=${params.minAllowance.toString()} mode=${mode}`,
    );

    return {
      kind: 'erc20.ensureAllowance',
      token: params.token,
      spender: params.spender,
      minAllowance: params.minAllowance,
      approveAmount,
    };
  };

  const ensureVeApprove = async (params: {
    tokenId: bigint;
    operator: Address;
    label: string;
  }): Promise<AgentAction | undefined> => {
    if (!includeNftApprovals) return undefined;
    if (!addrVe) {
      notes.push(
        `warn: VeClaimNFT missing in manifest; cannot auto-approve veNFT for ${params.label}`,
      );
      return undefined;
    }

    const key = `${addrVe.toLowerCase()}:${params.tokenId.toString()}:${params.operator.toLowerCase()}`;
    if (plannedVeApprovals.has(key)) return undefined;

    const owner = await safeReadErc721Owner({
      publicClient: p.publicClient,
      nft: addrVe,
      tokenId: params.tokenId,
    });
    if (!owner) {
      notes.push(
        `warn: cannot read ownerOf(${params.tokenId.toString()}); skipping veNFT auto-approve for ${params.label}`,
      );
      return undefined;
    }

    if (!sameAddress(owner, caller)) {
      // Common case: already listed locks may be owned by MarketRouter.
      notes.push(
        `note: veNFT tokenId=${params.tokenId.toString()} not owned by caller; skipping auto-approve for ${params.label}`,
      );
      return undefined;
    }

    const isAll = await safeReadErc721IsApprovedForAll({
      publicClient: p.publicClient,
      nft: addrVe,
      owner,
      operator: params.operator,
    });

    if (isAll === true) {
      plannedVeApprovals.add(key);
      return undefined;
    }

    const approved = await safeReadErc721Approved({
      publicClient: p.publicClient,
      nft: addrVe,
      tokenId: params.tokenId,
    });

    if (approved && sameAddress(approved, params.operator)) {
      plannedVeApprovals.add(key);
      return undefined;
    }

    plannedVeApprovals.add(key);
    notes.push(
      `approve: veNFT tokenId=${params.tokenId.toString()} operator=${params.operator} (${params.label})`,
    );

    return {
      kind: 've.approve',
      spender: params.operator,
      tokenId: params.tokenId,
    };
  };

  for (const action of p.plan.actions) {
    // If a plan already contains explicit approvals, treat them as planned state.
    if (action.kind === 'erc20.approve') {
      plannedAllowances.set(allowanceKey(action.token, action.spender), action.amount);
      expanded.push(action);
      continue;
    }

    if (action.kind === 'erc20.ensureAllowance') {
      const k = allowanceKey(action.token, action.spender);
      const prev = plannedAllowances.get(k) ?? 0n;
      const next = action.approveAmount > prev ? action.approveAmount : prev;
      plannedAllowances.set(k, next);
      expanded.push(action);
      continue;
    }

    if (action.kind === 've.approve') {
      if (addrVe) {
        plannedVeApprovals.add(
          `${addrVe.toLowerCase()}:${action.tokenId.toString()}:${action.spender.toLowerCase()}`,
        );
      }
      expanded.push(action);
      continue;
    }

    if (action.kind === 've.setApprovalForAll') {
      // We don't auto-generate setApprovalForAll, but preserve it if present.
      expanded.push(action);
      continue;
    }

    const inserts: AgentAction[] = [];

    switch (action.kind) {
      case 'furnace.enterWithClaim':
      case 'furnace.enterWithClaimFromCallerFor': {
        if (!addrClaimToken) {
          notes.push(
            `warn: ClaimToken missing in manifest; cannot auto-approve for ${action.kind}`,
          );
          break;
        }

        const need = action.claimIn;
        const appr = await ensureAllowance({
          token: addrClaimToken,
          spender: addrFurnace,
          minAllowance: need,
          label: 'CLAIM->Furnace',
        });
        if (appr) inserts.push(appr);
        break;
      }

      case 'furnace.enterWithToken':
      case 'furnace.enterWithTokenFromCallerFor': {
        const need = action.amountIn;
        const appr = await ensureAllowance({
          token: action.tokenIn,
          spender: addrFurnace,
          minAllowance: need,
          label: 'token->Furnace',
        });
        if (appr) inserts.push(appr);
        break;
      }

      case 'mineCore.takeoverWithToken': {
        const need = action.amountIn;
        const appr = await ensureAllowance({
          token: action.tokenIn,
          spender: addrMineCore,
          minAllowance: need,
          label: 'token->MineCore',
        });
        if (appr) inserts.push(appr);
        break;
      }

      case 'marketRouter.createBonusTargetEscrowWithTarget': {
        if (!addrMarketRouter) {
          notes.push('warn: MarketRouter missing in manifest; cannot auto-approve offer budget');
          break;
        }
        if (!addrClaimToken) {
          notes.push('warn: ClaimToken missing in manifest; cannot auto-approve offer budget');
          break;
        }

        const need = action.budgetClaim;
        const appr = await ensureAllowance({
          token: addrClaimToken,
          spender: addrMarketRouter,
          minAllowance: need,
          label: 'CLAIM->MarketRouter',
        });
        if (appr) inserts.push(appr);
        break;
      }

      case 'marketRouter.listLock': {
        if (!addrMarketRouter) {
          notes.push('warn: MarketRouter missing in manifest; cannot auto-approve veNFT');
          break;
        }
        const appr = await ensureVeApprove({
          tokenId: action.tokenId,
          operator: addrMarketRouter,
          label: 'listLock',
        });
        if (appr) inserts.push(appr);
        break;
      }

      case 'marketRouter.sellLockToFurnace':
      case 'marketRouter.sellListedLockToFurnace': {
        if (!addrMarketRouter) {
          notes.push('warn: MarketRouter missing in manifest; cannot auto-approve veNFT');
          break;
        }
        const appr = await ensureVeApprove({
          tokenId: action.tokenId,
          operator: addrMarketRouter,
          label: action.kind,
        });
        if (appr) inserts.push(appr);
        break;
      }

      default:
        break;
    }

    expanded.push(...inserts, action);
  }

  // Fast path: no inserts.
  if (expanded.length === p.plan.actions.length) {
    return { plan: p.plan, notes, inserted: 0 };
  }

  const plan: AgentPlan = {
    ...p.plan,
    actions: expanded,
  };

  return { plan, notes, inserted: expanded.length - p.plan.actions.length };
}
