import type { AgentAction } from './types.js';

/**
 * Console-friendly summaries for decisions.jsonl.
 *
 * This is intentionally conservative: only a small subset of actions include parameters.
 * Most actions are summarized by { kind } only to keep logs stable across releases.
 */
export function summarizeAgentActionForLog(a: AgentAction): Record<string, any> {
  switch (a.kind) {
    case 'furnace.enterWithEth':
      return {
        kind: a.kind,
        ethIn: a.ethIn.toString(),
        durationSeconds: a.durationSeconds.toString(),
      };
    case 'furnace.enterWithEthFor':
      return {
        kind: a.kind,
        user: a.user,
        ethIn: a.ethIn.toString(),
        durationSeconds: a.durationSeconds.toString(),
      };
    case 'mineCore.takeover':
      return { kind: a.kind, price: a.price.toString() };
    case 'mineCore.takeoverFor':
      return { kind: a.kind, newKing: a.newKing, price: a.price.toString() };
    case 'royalties.claimShareholderEth':
      return { kind: a.kind, claimable: a.claimable.toString() };
    case 'claimAllHelper.claimShareholderForUser':
      return { kind: a.kind, user: a.user, claimable: a.claimable.toString(), mode: a.mode };
    case 'claimAllHelper.withdrawKingBalanceForUser':
      return { kind: a.kind, user: a.user, amount: a.amount.toString() };
    case 'claimAllHelper.claimAllFor':
      return { kind: a.kind, user: a.user, claimable: a.claimable.toString(), mode: a.mode };
    case 'mineCore.withdrawKingBalance':
      return { kind: a.kind, amount: a.amount.toString() };
    case 'furnace.extendWithBonusFor':
      return {
        kind: a.kind,
        user: a.user,
        tokenId: a.tokenId.toString(),
        durationSeconds: a.durationSeconds.toString(),
        minBonusOut: a.minBonusOut.toString(),
      };
    case 've.unlockExpiredForUser':
      return { kind: a.kind, user: a.user, tokenId: a.tokenId.toString() };
    case 'furnace.mergeLocksWithBonusFor':
      return {
        kind: a.kind,
        user: a.user,
        fromTokenId: a.fromTokenId.toString(),
        intoTokenId: a.intoTokenId.toString(),
        minBonusOut: a.minBonusOut.toString(),
      };
    case 'mineCore.setKingAutoLockConfigForUser':
      return {
        kind: a.kind,
        user: a.user,
        enabled: a.enabled ? '1' : '0',
        targetTokenId: a.targetTokenId.toString(),
        durationSeconds: a.durationSeconds.toString(),
        createAutoMax: a.createAutoMax ? '1' : '0',
        minVeOut: a.minVeOut.toString(),
      };
    case 'royalties.setAutoCompoundConfigForUser':
      return {
        kind: a.kind,
        user: a.user,
        enabled: a.enabled ? '1' : '0',
        tokenId: a.tokenId.toString(),
        durationSeconds: a.durationSeconds.toString(),
        minCadenceSeconds: a.minCadenceSeconds.toString(),
        minEthToCompound: a.minEthToCompound.toString(),
      };
    case 'lpVault.setAutoCompoundConfigForUser':
      return {
        kind: a.kind,
        user: a.user,
        enabled: a.enabled ? '1' : '0',
        tokenId: a.tokenId.toString(),
        durationSeconds: a.durationSeconds.toString(),
      };
    case 'mineCore.withdrawRefundBalance':
      return { kind: a.kind, amount: a.amount.toString(), to: a.to };
    default:
      return { kind: (a as any).kind };
  }
}

export function summarizeAgentActionsForLog(actions: AgentAction[]): Record<string, any>[] {
  return actions.map(summarizeAgentActionForLog);
}
