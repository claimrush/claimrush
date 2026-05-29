import fs from 'node:fs';

import type { Address } from 'viem';

import type { AgentAction, AgentPlan } from './types.js';
import { parseStrictNonNegativeSafeInteger } from '../integers.js';
import { writeTextFileNoFollow } from '../security/fs.js';

// Guardrails for plan parsing (DoS resistance).
const DEFAULT_MAX_PLAN_BYTES = 20_000_000;
const MAX_PLAN_BYTES_HARD = 200_000_000;
const DEFAULT_MAX_PLAN_ACTIONS = 100_000;

// BigInt parsing can be expensive for extremely long strings.
// Plans produced by this SDK only emit decimal strings well below this size.
const MAX_BIGINT_DECIMAL_DIGITS = 256;
const DECIMAL_RE = /^\d+$/;

function clampFiniteInt(v: unknown, min: number, max: number, fallback: number): number {
  const n = typeof v === 'number' ? v : Number(v);
  if (!Number.isFinite(n)) return fallback;
  return Math.max(min, Math.min(max, Math.trunc(n)));
}

function nni(v: unknown, ctx: string): number {
  const n = parseStrictNonNegativeSafeInteger(v);
  if (n === undefined) {
    throw new Error(`${ctx}: expected non-negative safe integer`);
  }
  return n;
}

function bi(v: unknown, ctx: string = 'plan.bigint'): bigint {
  if (typeof v !== 'string') {
    throw new Error(`${ctx}: expected decimal string`);
  }
  const s = v.trim();
  if (!s) throw new Error(`${ctx}: empty decimal string`);
  if (s.length > MAX_BIGINT_DECIMAL_DIGITS) {
    throw new Error(`${ctx}: decimal string too long (${s.length} digits)`);
  }
  if (!DECIMAL_RE.test(s)) {
    throw new Error(`${ctx}: invalid decimal string`);
  }
  return globalThis.BigInt(s);
}

export type AgentActionJsonV1 =
  | {
      kind: 'furnace.enterWithEth';
      ethIn: string;
      targetTokenId: string;
      durationSeconds: string;
      createAutoMax: boolean;
      slippageBps: string;
    }
  | {
      kind: 'furnace.enterWithEthFor';
      user: Address;
      ethIn: string;
      targetTokenId: string;
      durationSeconds: string;
      createAutoMax: boolean;
      slippageBps: string;
    }
  | {
      kind: 'furnace.enterWithClaim';
      claimIn: string;
      targetTokenId: string;
      durationSeconds: string;
      createAutoMax: boolean;
      slippageBps: string;
    }
  | {
      kind: 'furnace.enterWithClaimFromCallerFor';
      user: Address;
      claimIn: string;
      targetTokenId: string;
      durationSeconds: string;
      createAutoMax: boolean;
      slippageBps: string;
    }
  | {
      kind: 'furnace.enterWithToken';
      tokenIn: Address;
      amountIn: string;
      targetTokenId: string;
      durationSeconds: string;
      createAutoMax: boolean;
      slippageBps: string;
    }
  | {
      kind: 'furnace.enterWithTokenFromCallerFor';
      user: Address;
      tokenIn: Address;
      amountIn: string;
      targetTokenId: string;
      durationSeconds: string;
      createAutoMax: boolean;
      slippageBps: string;
    }
  | {
      kind: 'mineCore.takeover';
      price: string;
    }
  | {
      kind: 'mineCore.takeoverFor';
      newKing: Address;
      price: string;
    }
  | {
      kind: 'mineCore.takeoverWithToken';
      tokenIn: Address;
      amountIn: string;
      slippageBps: string;
    }
  | {
      kind: 'mineCore.setCurrentReignRecipients';
      ethRecipient: Address;
      claimRecipient: Address;
    }
  | {
      kind: 'mineCore.setKingAutoLockConfig';
      enabled: boolean;
      targetTokenId: string;
      durationSeconds: string;
      createAutoMax: boolean;
      minVeOut: string;
    }
  | {
      kind: 'royalties.claimShareholderEth';
      claimable: string;
    }
  | {
      kind: 'royalties.claimShareholderLock';
      targetTokenId: string;
      durationSeconds: string;
      createAutoMax: boolean;
      slippageBps: string;
    }
  | {
      kind: 'royalties.setAutoCompoundConfig';
      enabled: boolean;
      tokenId: string;
      durationSeconds: string;
      minCadenceSeconds: string;
      minEthToCompound: string;
    }
  | {
      kind: 'claimAllHelper.claimShareholderForUser';
      user: Address;
      claimable: string;
      mode: number;
      targetTokenId: string;
      durationSeconds: string;
      createAutoMax: boolean;
      minVeOut: string;
    }
  | {
      kind: 'claimAllHelper.withdrawKingBalanceForUser';
      user: Address;
      amount: string;
    }
  | {
      kind: 'claimAllHelper.claimAllFor';
      user: Address;
      claimable: string;
      mode: number;
      targetTokenId: string;
      durationSeconds: string;
      createAutoMax: boolean;
      minVeOut: string;
    }
  | {
      kind: 'mineCore.withdrawKingBalance';
      amount: string;
    }
  | {
      kind: 'mineCore.withdrawRefundBalance';
      amount: string;
      to: Address;
    }
  | {
      kind: 'marketRouter.sellLockToFurnace';
      tokenId: string;
      slippageBps: string;
      deadlineSeconds: string;
    }
  | {
      kind: 'marketRouter.sellListedLockToFurnace';
      tokenId: string;
      deadlineSeconds: string;
    }
  | {
      kind: 'marketRouter.listLock';
      tokenId: string;
      minClaimOut: string;
      ttlSeconds: string;
    }
  | {
      kind: 'marketRouter.delistLock';
      tokenId: string;
    }
  | {
      kind: 'marketRouter.cancelExpiredListing';
      tokenId: string;
    }
  | {
      kind: 'marketRouter.createBonusTargetEscrowWithTarget';
      targetBonusBps: string;
      budgetClaim: string;
      durationSeconds: string;
      createAutoMax: boolean;
      escrowTtlSeconds: string;
      destinationLockId: string;
      slippageBps: string;
    }
  | {
      kind: 'marketRouter.cancelBonusTargetEscrow';
      offerId: string;
    }
  | {
      kind: 'marketRouter.extendBonusTargetEscrowExpiry';
      offerId: string;
      ttlSecondsFromNow: string;
    }
  | {
      kind: 'marketRouter.cancelExpiredBonusTargetEscrow';
      offerId: string;
    }
  | {
      kind: 'marketRouter.executeAutoFurnace';
      offerId: string;
    }
  | {
      kind: 'erc20.approve';
      token: Address;
      spender: Address;
      amount: string;
    }
  | {
      kind: 'erc20.ensureAllowance';
      token: Address;
      spender: Address;
      minAllowance: string;
      approveAmount: string;
    }
  | {
      kind: 've.approve';
      spender: Address;
      tokenId: string;
    }
  | {
      kind: 've.setApprovalForAll';
      operator: Address;
      approved: boolean;
    }
  | {
      kind: 'furnace.extendWithBonus';
      tokenId: string;
      durationSeconds: string;
      minBonusOut: string;
    }
  | {
      kind: 'furnace.extendWithBonusFor';
      user: Address;
      tokenId: string;
      durationSeconds: string;
      minBonusOut: string;
    }
  | {
      kind: 'furnace.mergeLocksWithBonus';
      fromTokenId: string;
      intoTokenId: string;
      minBonusOut: string;
    }
  | {
      kind: 've.unlock';
      tokenId: string;
    }
  | {
      kind: 've.setAutoMax';
      tokenId: string;
      enabled: boolean;
    }
  | {
      kind: 've.checkpointGlobalState';
    }
  | {
      kind: 've.checkpointTotalVe';
    }
  | {
      kind: 'furnace.mergeLocksWithBonusFor';
      user: Address;
      fromTokenId: string;
      intoTokenId: string;
      minBonusOut: string;
    }
  | {
      kind: 've.unlockExpiredForUser';
      user: Address;
      tokenId: string;
    }
  | {
      kind: 'mineCore.setKingAutoLockConfigForUser';
      user: Address;
      enabled: boolean;
      targetTokenId: string;
      durationSeconds: string;
      createAutoMax: boolean;
      minVeOut: string;
    }
  | {
      kind: 'royalties.setAutoCompoundConfigForUser';
      user: Address;
      enabled: boolean;
      tokenId: string;
      durationSeconds: string;
      minCadenceSeconds: string;
      minEthToCompound: string;
    }
  | {
      kind: 'lpVault.setAutoCompoundConfigForUser';
      user: Address;
      enabled: boolean;
      tokenId: string;
      durationSeconds: string;
    };

export type AgentPlanJsonV1 = {
  /** Semantic version tag for this JSON shape. */
  version: 'agentPlan.v1';
  chain: string;
  chainId: number;
  blockNumber: string;
  blockTimestamp: string;
  agent: Address;
  actions: AgentActionJsonV1[];
};

function toActionJsonV1(action: AgentAction): AgentActionJsonV1 {
  switch (action.kind) {
    case 'furnace.enterWithEth':
      return {
        kind: action.kind,
        ethIn: action.ethIn.toString(),
        targetTokenId: action.targetTokenId.toString(),
        durationSeconds: action.durationSeconds.toString(),
        createAutoMax: action.createAutoMax,
        slippageBps: action.slippageBps.toString(),
      };

    case 'furnace.enterWithEthFor':
      return {
        kind: action.kind,
        user: action.user,
        ethIn: action.ethIn.toString(),
        targetTokenId: action.targetTokenId.toString(),
        durationSeconds: action.durationSeconds.toString(),
        createAutoMax: action.createAutoMax,
        slippageBps: action.slippageBps.toString(),
      };

    case 'furnace.enterWithClaim':
      return {
        kind: action.kind,
        claimIn: action.claimIn.toString(),
        targetTokenId: action.targetTokenId.toString(),
        durationSeconds: action.durationSeconds.toString(),
        createAutoMax: action.createAutoMax,
        slippageBps: action.slippageBps.toString(),
      };

    case 'furnace.enterWithClaimFromCallerFor':
      return {
        kind: action.kind,
        user: action.user,
        claimIn: action.claimIn.toString(),
        targetTokenId: action.targetTokenId.toString(),
        durationSeconds: action.durationSeconds.toString(),
        createAutoMax: action.createAutoMax,
        slippageBps: action.slippageBps.toString(),
      };

    case 'furnace.enterWithToken':
      return {
        kind: action.kind,
        tokenIn: action.tokenIn,
        amountIn: action.amountIn.toString(),
        targetTokenId: action.targetTokenId.toString(),
        durationSeconds: action.durationSeconds.toString(),
        createAutoMax: action.createAutoMax,
        slippageBps: action.slippageBps.toString(),
      };

    case 'furnace.enterWithTokenFromCallerFor':
      return {
        kind: action.kind,
        user: action.user,
        tokenIn: action.tokenIn,
        amountIn: action.amountIn.toString(),
        targetTokenId: action.targetTokenId.toString(),
        durationSeconds: action.durationSeconds.toString(),
        createAutoMax: action.createAutoMax,
        slippageBps: action.slippageBps.toString(),
      };

    case 'mineCore.takeover':
      return { kind: action.kind, price: action.price.toString() };

    case 'mineCore.takeoverFor':
      return { kind: action.kind, newKing: action.newKing, price: action.price.toString() };

    case 'mineCore.takeoverWithToken':
      return {
        kind: action.kind,
        tokenIn: action.tokenIn,
        amountIn: action.amountIn.toString(),
        slippageBps: action.slippageBps.toString(),
      };

    case 'mineCore.setCurrentReignRecipients':
      return {
        kind: action.kind,
        ethRecipient: action.ethRecipient,
        claimRecipient: action.claimRecipient,
      };

    case 'mineCore.setKingAutoLockConfig':
      return {
        kind: action.kind,
        enabled: action.enabled,
        targetTokenId: action.targetTokenId.toString(),
        durationSeconds: action.durationSeconds.toString(),
        createAutoMax: action.createAutoMax,
        minVeOut: action.minVeOut.toString(),
      };

    case 'royalties.claimShareholderEth':
      return { kind: action.kind, claimable: action.claimable.toString() };

    case 'royalties.claimShareholderLock':
      return {
        kind: action.kind,
        targetTokenId: action.targetTokenId.toString(),
        durationSeconds: action.durationSeconds.toString(),
        createAutoMax: action.createAutoMax,
        slippageBps: action.slippageBps.toString(),
      };

    case 'royalties.setAutoCompoundConfig':
      return {
        kind: action.kind,
        enabled: action.enabled,
        tokenId: action.tokenId.toString(),
        durationSeconds: action.durationSeconds.toString(),
        minCadenceSeconds: action.minCadenceSeconds.toString(),
        minEthToCompound: action.minEthToCompound.toString(),
      };

    case 'claimAllHelper.claimShareholderForUser':
      return {
        kind: action.kind,
        user: action.user,
        claimable: action.claimable.toString(),
        mode: action.mode,
        targetTokenId: action.targetTokenId.toString(),
        durationSeconds: action.durationSeconds.toString(),
        createAutoMax: action.createAutoMax,
        minVeOut: action.minVeOut.toString(),
      };

    case 'claimAllHelper.withdrawKingBalanceForUser':
      return { kind: action.kind, user: action.user, amount: action.amount.toString() };

    case 'claimAllHelper.claimAllFor':
      return {
        kind: action.kind,
        user: action.user,
        claimable: action.claimable.toString(),
        mode: action.mode,
        targetTokenId: action.targetTokenId.toString(),
        durationSeconds: action.durationSeconds.toString(),
        createAutoMax: action.createAutoMax,
        minVeOut: action.minVeOut.toString(),
      };

    case 'mineCore.withdrawKingBalance':
      return { kind: action.kind, amount: action.amount.toString() };

    case 'mineCore.withdrawRefundBalance':
      return { kind: action.kind, amount: action.amount.toString(), to: action.to };

    case 'marketRouter.sellLockToFurnace':
      return {
        kind: action.kind,
        tokenId: action.tokenId.toString(),
        slippageBps: action.slippageBps.toString(),
        deadlineSeconds: action.deadlineSeconds.toString(),
      };

    case 'marketRouter.sellListedLockToFurnace':
      return {
        kind: action.kind,
        tokenId: action.tokenId.toString(),
        deadlineSeconds: action.deadlineSeconds.toString(),
      };

    case 'marketRouter.listLock':
      return {
        kind: action.kind,
        tokenId: action.tokenId.toString(),
        minClaimOut: action.minClaimOut.toString(),
        ttlSeconds: action.ttlSeconds.toString(),
      };

    case 'marketRouter.delistLock':
      return { kind: action.kind, tokenId: action.tokenId.toString() };

    case 'marketRouter.cancelExpiredListing':
      return { kind: action.kind, tokenId: action.tokenId.toString() };

    case 'marketRouter.createBonusTargetEscrowWithTarget':
      return {
        kind: action.kind,
        targetBonusBps: action.targetBonusBps.toString(),
        budgetClaim: action.budgetClaim.toString(),
        durationSeconds: action.durationSeconds.toString(),
        createAutoMax: action.createAutoMax,
        escrowTtlSeconds: action.escrowTtlSeconds.toString(),
        destinationLockId: action.destinationLockId.toString(),
        slippageBps: action.slippageBps.toString(),
      };

    case 'marketRouter.cancelBonusTargetEscrow':
      return { kind: action.kind, offerId: action.offerId.toString() };

    case 'marketRouter.extendBonusTargetEscrowExpiry':
      return {
        kind: action.kind,
        offerId: action.offerId.toString(),
        ttlSecondsFromNow: action.ttlSecondsFromNow.toString(),
      };

    case 'marketRouter.cancelExpiredBonusTargetEscrow':
      return { kind: action.kind, offerId: action.offerId.toString() };

    case 'marketRouter.executeAutoFurnace':
      return { kind: action.kind, offerId: action.offerId.toString() };

    case 'erc20.approve':
      return {
        kind: action.kind,
        token: action.token,
        spender: action.spender,
        amount: action.amount.toString(),
      };

    case 'erc20.ensureAllowance':
      return {
        kind: action.kind,
        token: action.token,
        spender: action.spender,
        minAllowance: action.minAllowance.toString(),
        approveAmount: action.approveAmount.toString(),
      };

    case 've.approve':
      return { kind: action.kind, spender: action.spender, tokenId: action.tokenId.toString() };

    case 've.setApprovalForAll':
      return { kind: action.kind, operator: action.operator, approved: action.approved };

    case 'furnace.extendWithBonus':
      return {
        kind: action.kind,
        tokenId: action.tokenId.toString(),
        durationSeconds: action.durationSeconds.toString(),
        minBonusOut: action.minBonusOut.toString(),
      };

    case 'furnace.extendWithBonusFor':
      return {
        kind: action.kind,
        user: action.user,
        tokenId: action.tokenId.toString(),
        durationSeconds: action.durationSeconds.toString(),
        minBonusOut: action.minBonusOut.toString(),
      };

    case 'furnace.mergeLocksWithBonus':
      return {
        kind: action.kind,
        fromTokenId: action.fromTokenId.toString(),
        intoTokenId: action.intoTokenId.toString(),
        minBonusOut: action.minBonusOut.toString(),
      };

    case 've.unlock':
      return { kind: action.kind, tokenId: action.tokenId.toString() };

    case 've.setAutoMax':
      return { kind: action.kind, tokenId: action.tokenId.toString(), enabled: action.enabled };

    case 've.checkpointGlobalState':
      return { kind: action.kind };

    case 've.checkpointTotalVe':
      return { kind: action.kind };

    case 'furnace.mergeLocksWithBonusFor':
      return {
        kind: action.kind,
        user: action.user,
        fromTokenId: action.fromTokenId.toString(),
        intoTokenId: action.intoTokenId.toString(),
        minBonusOut: action.minBonusOut.toString(),
      };

    case 've.unlockExpiredForUser':
      return {
        kind: action.kind,
        user: action.user,
        tokenId: action.tokenId.toString(),
      };

    case 'mineCore.setKingAutoLockConfigForUser':
      return {
        kind: action.kind,
        user: action.user,
        enabled: action.enabled,
        targetTokenId: action.targetTokenId.toString(),
        durationSeconds: action.durationSeconds.toString(),
        createAutoMax: action.createAutoMax,
        minVeOut: action.minVeOut.toString(),
      };

    case 'royalties.setAutoCompoundConfigForUser':
      return {
        kind: action.kind,
        user: action.user,
        enabled: action.enabled,
        tokenId: action.tokenId.toString(),
        durationSeconds: action.durationSeconds.toString(),
        minCadenceSeconds: action.minCadenceSeconds.toString(),
        minEthToCompound: action.minEthToCompound.toString(),
      };

    case 'lpVault.setAutoCompoundConfigForUser':
      return {
        kind: action.kind,
        user: action.user,
        enabled: action.enabled,
        tokenId: action.tokenId.toString(),
        durationSeconds: action.durationSeconds.toString(),
      };

    default: {
      // Exhaustive check
      const _x: never = action;
      return _x;
    }
  }
}

function fromActionJsonV1(action: AgentActionJsonV1): AgentAction {
  switch (action.kind) {
    case 'furnace.enterWithEth':
      return {
        kind: action.kind,
        ethIn: bi(action.ethIn),
        targetTokenId: bi(action.targetTokenId),
        durationSeconds: bi(action.durationSeconds),
        createAutoMax: Boolean(action.createAutoMax),
        slippageBps: bi(action.slippageBps),
      };

    case 'furnace.enterWithEthFor':
      return {
        kind: action.kind,
        user: action.user,
        ethIn: bi(action.ethIn),
        targetTokenId: bi(action.targetTokenId),
        durationSeconds: bi(action.durationSeconds),
        createAutoMax: Boolean(action.createAutoMax),
        slippageBps: bi(action.slippageBps),
      };

    case 'furnace.enterWithClaim':
      return {
        kind: action.kind,
        claimIn: bi(action.claimIn),
        targetTokenId: bi(action.targetTokenId),
        durationSeconds: bi(action.durationSeconds),
        createAutoMax: Boolean(action.createAutoMax),
        slippageBps: bi(action.slippageBps),
      };

    case 'furnace.enterWithClaimFromCallerFor':
      return {
        kind: action.kind,
        user: action.user,
        claimIn: bi(action.claimIn),
        targetTokenId: bi(action.targetTokenId),
        durationSeconds: bi(action.durationSeconds),
        createAutoMax: Boolean(action.createAutoMax),
        slippageBps: bi(action.slippageBps),
      };

    case 'furnace.enterWithToken':
      return {
        kind: action.kind,
        tokenIn: action.tokenIn,
        amountIn: bi(action.amountIn),
        targetTokenId: bi(action.targetTokenId),
        durationSeconds: bi(action.durationSeconds),
        createAutoMax: Boolean(action.createAutoMax),
        slippageBps: bi(action.slippageBps),
      };

    case 'furnace.enterWithTokenFromCallerFor':
      return {
        kind: action.kind,
        user: action.user,
        tokenIn: action.tokenIn,
        amountIn: bi(action.amountIn),
        targetTokenId: bi(action.targetTokenId),
        durationSeconds: bi(action.durationSeconds),
        createAutoMax: Boolean(action.createAutoMax),
        slippageBps: bi(action.slippageBps),
      };

    case 'mineCore.takeover':
      return { kind: action.kind, price: bi(action.price) };

    case 'mineCore.takeoverFor':
      return { kind: action.kind, newKing: action.newKing, price: bi(action.price) };

    case 'mineCore.takeoverWithToken':
      return {
        kind: action.kind,
        tokenIn: action.tokenIn,
        amountIn: bi(action.amountIn),
        slippageBps: bi(action.slippageBps),
      };

    case 'mineCore.setCurrentReignRecipients':
      return {
        kind: action.kind,
        ethRecipient: action.ethRecipient,
        claimRecipient: action.claimRecipient,
      };

    case 'mineCore.setKingAutoLockConfig':
      return {
        kind: action.kind,
        enabled: Boolean(action.enabled),
        targetTokenId: bi(action.targetTokenId),
        durationSeconds: bi(action.durationSeconds),
        createAutoMax: Boolean(action.createAutoMax),
        minVeOut: bi(action.minVeOut),
      };

    case 'royalties.claimShareholderEth':
      return { kind: action.kind, claimable: bi(action.claimable) };

    case 'royalties.claimShareholderLock':
      return {
        kind: action.kind,
        targetTokenId: bi(action.targetTokenId),
        durationSeconds: bi(action.durationSeconds),
        createAutoMax: Boolean(action.createAutoMax),
        slippageBps: bi(action.slippageBps),
      };

    case 'royalties.setAutoCompoundConfig':
      return {
        kind: action.kind,
        enabled: Boolean(action.enabled),
        tokenId: bi(action.tokenId),
        durationSeconds: bi(action.durationSeconds),
        minCadenceSeconds: bi(action.minCadenceSeconds),
        minEthToCompound: bi(action.minEthToCompound),
      };

    case 'claimAllHelper.claimShareholderForUser':
      return {
        kind: action.kind,
        user: action.user,
        claimable: bi(action.claimable),
        mode: nni(action.mode, 'claimAllHelper.claimShareholderForUser.mode'),
        targetTokenId: bi(action.targetTokenId),
        durationSeconds: bi(action.durationSeconds),
        createAutoMax: Boolean(action.createAutoMax),
        minVeOut: bi(action.minVeOut),
      };

    case 'claimAllHelper.withdrawKingBalanceForUser':
      return { kind: action.kind, user: action.user, amount: bi(action.amount) };

    case 'claimAllHelper.claimAllFor':
      return {
        kind: action.kind,
        user: action.user,
        claimable: bi(action.claimable),
        mode: nni(action.mode, 'claimAllHelper.claimAllFor.mode'),
        targetTokenId: bi(action.targetTokenId),
        durationSeconds: bi(action.durationSeconds),
        createAutoMax: Boolean(action.createAutoMax),
        minVeOut: bi(action.minVeOut),
      };

    case 'mineCore.withdrawKingBalance':
      return { kind: action.kind, amount: bi(action.amount) };

    case 'mineCore.withdrawRefundBalance':
      return { kind: action.kind, amount: bi(action.amount), to: action.to };

    case 'marketRouter.sellLockToFurnace':
      return {
        kind: action.kind,
        tokenId: bi(action.tokenId),
        slippageBps: bi(action.slippageBps),
        deadlineSeconds: bi(action.deadlineSeconds),
      };

    case 'marketRouter.sellListedLockToFurnace':
      return {
        kind: action.kind,
        tokenId: bi(action.tokenId),
        deadlineSeconds: bi(action.deadlineSeconds),
      };

    case 'marketRouter.listLock':
      return {
        kind: action.kind,
        tokenId: bi(action.tokenId),
        minClaimOut: bi(action.minClaimOut),
        ttlSeconds: bi(action.ttlSeconds),
      };

    case 'marketRouter.delistLock':
      return { kind: action.kind, tokenId: bi(action.tokenId) };

    case 'marketRouter.cancelExpiredListing':
      return { kind: action.kind, tokenId: bi(action.tokenId) };

    case 'marketRouter.createBonusTargetEscrowWithTarget':
      return {
        kind: action.kind,
        targetBonusBps: bi(action.targetBonusBps),
        budgetClaim: bi(action.budgetClaim),
        durationSeconds: bi(action.durationSeconds),
        createAutoMax: Boolean(action.createAutoMax),
        escrowTtlSeconds: bi(action.escrowTtlSeconds),
        destinationLockId: bi(action.destinationLockId),
        slippageBps: bi(action.slippageBps),
      };

    case 'marketRouter.cancelBonusTargetEscrow':
      return { kind: action.kind, offerId: bi(action.offerId) };

    case 'marketRouter.extendBonusTargetEscrowExpiry':
      return {
        kind: action.kind,
        offerId: bi(action.offerId),
        ttlSecondsFromNow: bi(action.ttlSecondsFromNow),
      };

    case 'marketRouter.cancelExpiredBonusTargetEscrow':
      return { kind: action.kind, offerId: bi(action.offerId) };

    case 'marketRouter.executeAutoFurnace':
      return { kind: action.kind, offerId: bi(action.offerId) };

    case 'erc20.approve':
      return {
        kind: action.kind,
        token: action.token,
        spender: action.spender,
        amount: bi(action.amount),
      };

    case 'erc20.ensureAllowance':
      return {
        kind: action.kind,
        token: action.token,
        spender: action.spender,
        minAllowance: bi(action.minAllowance),
        approveAmount: bi(action.approveAmount),
      };

    case 've.approve':
      return { kind: action.kind, spender: action.spender, tokenId: bi(action.tokenId) };

    case 've.setApprovalForAll':
      return { kind: action.kind, operator: action.operator, approved: Boolean(action.approved) };

    case 'furnace.extendWithBonus':
      return {
        kind: action.kind,
        tokenId: bi(action.tokenId),
        durationSeconds: bi(action.durationSeconds),
        minBonusOut: bi(action.minBonusOut),
      };

    case 'furnace.extendWithBonusFor':
      return {
        kind: action.kind,
        user: action.user,
        tokenId: bi(action.tokenId),
        durationSeconds: bi(action.durationSeconds),
        minBonusOut: bi(action.minBonusOut),
      };

    case 'furnace.mergeLocksWithBonus':
      return {
        kind: action.kind,
        fromTokenId: bi(action.fromTokenId),
        intoTokenId: bi(action.intoTokenId),
        minBonusOut: bi(action.minBonusOut),
      };

    case 've.unlock':
      return { kind: action.kind, tokenId: bi(action.tokenId) };

    case 've.setAutoMax':
      return {
        kind: action.kind,
        tokenId: bi(action.tokenId),
        enabled: Boolean(action.enabled),
      };

    case 've.checkpointGlobalState':
      return { kind: action.kind };

    case 've.checkpointTotalVe':
      return { kind: action.kind };

    case 'furnace.mergeLocksWithBonusFor':
      return {
        kind: action.kind,
        user: action.user,
        fromTokenId: bi(action.fromTokenId),
        intoTokenId: bi(action.intoTokenId),
        minBonusOut: bi(action.minBonusOut),
      };

    case 've.unlockExpiredForUser':
      return {
        kind: action.kind,
        user: action.user,
        tokenId: bi(action.tokenId),
      };

    case 'mineCore.setKingAutoLockConfigForUser':
      return {
        kind: action.kind,
        user: action.user,
        enabled: Boolean(action.enabled),
        targetTokenId: bi(action.targetTokenId),
        durationSeconds: bi(action.durationSeconds),
        createAutoMax: Boolean(action.createAutoMax),
        minVeOut: bi(action.minVeOut),
      };

    case 'royalties.setAutoCompoundConfigForUser':
      return {
        kind: action.kind,
        user: action.user,
        enabled: Boolean(action.enabled),
        tokenId: bi(action.tokenId),
        durationSeconds: bi(action.durationSeconds),
        minCadenceSeconds: bi(action.minCadenceSeconds),
        minEthToCompound: bi(action.minEthToCompound),
      };

    case 'lpVault.setAutoCompoundConfigForUser':
      return {
        kind: action.kind,
        user: action.user,
        enabled: Boolean(action.enabled),
        tokenId: bi(action.tokenId),
        durationSeconds: bi(action.durationSeconds),
      };

    default: {
      // Exhaustive check
      const _x: never = action;
      return _x;
    }
  }
}

export function toPlanJsonV1(plan: AgentPlan): AgentPlanJsonV1 {
  return {
    version: 'agentPlan.v1',
    chain: plan.chain,
    chainId: plan.chainId,
    blockNumber: plan.blockNumber.toString(),
    blockTimestamp: plan.blockTimestamp.toString(),
    agent: plan.agent,
    actions: plan.actions.map(toActionJsonV1),
  };
}

export function fromPlanJsonV1(plan: AgentPlanJsonV1): AgentPlan {
  return {
    chain: plan.chain,
    chainId: plan.chainId,
    blockNumber: bi(plan.blockNumber),
    blockTimestamp: bi(plan.blockTimestamp),
    agent: plan.agent,
    actions: (plan.actions ?? []).map(fromActionJsonV1),
  };
}

export function stringifyPlan(plan: AgentPlan, opts?: { pretty?: boolean }): string {
  const json = toPlanJsonV1(plan);
  return JSON.stringify(json, null, opts?.pretty ? 2 : 0);
}

export function parsePlan(text: string, opts?: { maxActions?: number }): AgentPlan {
  const parsed = JSON.parse(text) as unknown;
  if (!parsed || typeof parsed !== 'object') {
    throw new Error('Invalid plan JSON: expected object');
  }

  const version = (parsed as any).version as unknown;
  if (version !== 'agentPlan.v1') {
    throw new Error(`Unsupported plan version: ${String(version)}`);
  }

  // Prevent pathological plans from consuming unbounded CPU/memory.
  const cap = clampFiniteInt(opts?.maxActions, 1, 1_000_000, DEFAULT_MAX_PLAN_ACTIONS);
  const actions = (parsed as any).actions;
  if (Array.isArray(actions) && actions.length > cap) {
    throw new Error(`Plan too large: actions=${actions.length} (maxActions=${cap})`);
  }

  return fromPlanJsonV1(parsed as AgentPlanJsonV1);
}

export function readPlanFromFile(
  fp: string,
  opts?: { maxBytes?: number; maxActions?: number },
): AgentPlan {
  const maxBytes = clampFiniteInt(opts?.maxBytes, 1, MAX_PLAN_BYTES_HARD, DEFAULT_MAX_PLAN_BYTES);

  const st = fs.statSync(fp);
  if (!st.isFile()) throw new Error(`Plan path is not a file: ${fp}`);
  if (st.size > maxBytes) {
    throw new Error(`Plan file too large: ${st.size} bytes (maxBytes=${maxBytes})`);
  }

  const text = fs.readFileSync(fp, 'utf8');
  return parsePlan(text, { maxActions: opts?.maxActions });
}

export function writePlanToFile(fp: string, plan: AgentPlan, opts?: { pretty?: boolean }): void {
  writeTextFileNoFollow(fp, stringifyPlan(plan, opts) + '\n', { encoding: 'utf8', mode: 0o600 });
}
