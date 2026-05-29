import type { Address } from 'viem';

import type { ClaimRushSnapshot } from '../snapshot.js';
import {
  P_CLAIM_ALL_FOR,
  P_CLAIM_SHAREHOLDER_FOR,
  P_FURNACE_ENTER_ETH_FOR,
  P_SET_KING_AUTO_LOCK_CONFIG_FOR,
  P_SET_LP_AUTOCOMPOUND_CONFIG_FOR,
  P_SET_SHAREHOLDER_AUTOCOMPOUND_CONFIG_FOR,
  P_TAKEOVER_FOR,
  P_WITHDRAW_KING_BUCKET_FOR,
} from '../delegation/permissions.js';

import type { AgentAction } from './types.js';

export type PolicyConfig = {
  agent: Address;

  enableFurnaceEntry: boolean;
  enableTakeovers: boolean;
  enableRoyaltiesClaim: boolean;
  enableWithdrawals: boolean;

  // Furnace entry params
  furnaceEthIn: bigint;
  lockDurationSeconds: bigint;
  targetTokenId: bigint;
  createAutoMax: boolean;
  slippageBps: bigint;

  // Takeovers
  maxTakeoverEth: bigint;
  takeoverCooldownSeconds: number;

  // Thresholds
  minRoyaltiesEthToClaim: bigint;
  minKingEthToWithdraw: bigint;
  minRefundEthToWithdraw: bigint;

  // ------------------------------------------------------------
  // Delegated safe maintenance (optional)
  // ------------------------------------------------------------

  /** Enable delegated safe-maintenance actions (ve refresh, config sync). */
  enableSafeMaintenance?: boolean;
  /** Refresh/extend when remaining duration is below this threshold (seconds). */
  veExtendIfRemainingSeconds?: bigint;
  /** Extend by this many seconds. */
  veExtendBySeconds?: bigint;

  // ------------------------------------------------------------
  // Delegated-only config sync (optional)
  // ------------------------------------------------------------

  /** Optional: desired MineCore king auto-lock config for the managed user. */
  kingAutoLockDesired?: {
    enabled: boolean;
    targetTokenId: bigint;
    durationSeconds: bigint;
    createAutoMax: boolean;
    minVeOut: bigint;
  };

  /** Optional: desired ShareholderRoyalties auto-compound config (tokenId=0 means "use active lock"). */
  royaltiesAutoCompoundDesired?: {
    enabled: boolean;
    tokenId: bigint;
    durationSeconds: bigint;
    minCadenceSeconds: bigint;
    minEthToCompound: bigint;
  };

  /** Optional: desired LP vault auto-compound config (tokenId=0 means "use active lock"). */
  lpAutoCompoundDesired?: {
    enabled: boolean;
    tokenId: bigint;
    durationSeconds: bigint;
  };
};

export type PolicyState = {
  lastTakeoverAtMs?: number;
};

export type PolicyCallerContext = {
  /** The account that will sign + pay gas (and sometimes pay ETH). */
  address: Address;
  /** Wallet ETH balance of the caller. */
  ethBalance: bigint;
  /** MineCore.kingEthBalance[caller] */
  mineCoreKingEthBalance: bigint;
  /** MineCore.refundEthBalance[caller] */
  mineCoreRefundEthBalance: bigint;
};

export type PolicyDelegationContext = {
  /** The delegated user identity being managed. */
  user: Address;
  /** The delegate (caller) address. */
  delegate: Address;
  /** Bitmask of permissions granted in DelegationHub. */
  perms: bigint;
  /** Session expiry (unix seconds). */
  expiry: bigint;
};

function sameAddress(a: Address, b: Address): boolean {
  return a.toLowerCase() === b.toLowerCase();
}

function hasPerm(perms: bigint, bit: bigint): boolean {
  return (perms & bit) !== 0n;
}

function isDelegationActive(params: {
  delegation?: PolicyDelegationContext;
  blockTimestamp?: bigint;
}): boolean {
  const d = params.delegation;
  if (!d) return false;
  if (d.expiry === 0n) return false;
  const now = params.blockTimestamp ?? BigInt(Math.floor(Date.now() / 1000));
  return d.expiry >= now;
}

export function buildActionPlan(params: {
  snapshot: ClaimRushSnapshot;
  config: PolicyConfig;
  state: PolicyState;
  nowMs?: number;
  caller?: PolicyCallerContext;
  delegation?: PolicyDelegationContext;
}): AgentAction[] {
  const nowMs = params.nowMs ?? Date.now();
  const { snapshot, config, state } = params;

  const subject = snapshot.user;
  if (!subject) return [];

  const caller: PolicyCallerContext =
    params.caller ??
    ({
      address: subject.address,
      ethBalance: subject.ethBalance,
      mineCoreKingEthBalance: subject.mineCore.kingEthBalance,
      mineCoreRefundEthBalance: subject.mineCore.refundEthBalance,
    } satisfies PolicyCallerContext);

  // "Delegated mode" is determined purely by who is *sending* txs (caller) versus
  // who is being managed (subject). If they differ, we must ONLY emit delegated
  // action kinds (..ForUser / ..For) and only when an active session grants perms.
  const delegated = !sameAddress(caller.address, subject.address);
  const delegationActive = isDelegationActive({
    delegation: params.delegation,
    blockTimestamp: snapshot.meta.blockTimestamp,
  });
  const perms = delegated && delegationActive ? (params.delegation?.perms ?? 0n) : 0n;

  const actions: AgentAction[] = [];

  // ------------------------------------------------------------
  // 0) Delegated safe maintenance (optional)
  // ------------------------------------------------------------

  const hasDesiredConfig = Boolean(
    config.kingAutoLockDesired ||
    config.royaltiesAutoCompoundDesired ||
    config.lpAutoCompoundDesired,
  );

  if (hasDesiredConfig && delegated && delegationActive) {
    const _nowSec = snapshot.meta.blockTimestamp;

    // v1.0.0: Routing pointers removed. Token IDs must be explicitly specified in config.
    // spec == 0 means "no lock selected" (callers must provide explicit token IDs).
    const resolveLockTokenId = (spec: bigint): bigint => {
      return spec > 0n ? spec : 0n;
    };

    // Without routing pointers, we can't cache lock info for arbitrary tokens.
    // Assume usable if tokenId > 0; on-chain calls will revert if lock is invalid.
    const checkResolvedLockUsable = (resolvedTokenId: bigint): boolean => {
      return resolvedTokenId > 0n;
    };

    // MineCore king auto-lock config (explicit desired only).
    const desiredKing = config.kingAutoLockDesired;
    if (desiredKing && hasPerm(perms, P_SET_KING_AUTO_LOCK_CONFIG_FOR)) {
      const cur = subject.mineCore.kingAutoLockConfig;
      const mismatch =
        cur.enabled !== desiredKing.enabled ||
        cur.targetTokenId !== desiredKing.targetTokenId ||
        BigInt(cur.durationSeconds) !== desiredKing.durationSeconds ||
        cur.createAutoMax !== desiredKing.createAutoMax ||
        cur.minVeOut !== desiredKing.minVeOut;

      if (mismatch) {
        actions.push({
          kind: 'mineCore.setKingAutoLockConfigForUser',
          user: subject.address,
          enabled: desiredKing.enabled,
          targetTokenId: desiredKing.targetTokenId,
          durationSeconds: desiredKing.durationSeconds,
          createAutoMax: desiredKing.createAutoMax,
          minVeOut: desiredKing.minVeOut,
        });
      }
    }

    // ShareholderRoyalties auto-compound config:
    // - if a desired config is provided, enforce it
    // - else, if enabled+paused, unpause by re-setting the same config
    const curRoy = subject.royalties.autoCompoundConfig;
    const desiredRoy =
      config.royaltiesAutoCompoundDesired ??
      (curRoy.enabled && curRoy.paused
        ? {
            enabled: true,
            tokenId: curRoy.tokenId,
            durationSeconds: curRoy.durationSeconds,
            minCadenceSeconds: BigInt(curRoy.minCadenceSeconds),
            minEthToCompound: curRoy.minEthToCompound,
          }
        : undefined);

    if (desiredRoy && hasPerm(perms, P_SET_SHAREHOLDER_AUTOCOMPOUND_CONFIG_FOR)) {
      const resolvedTokenId = desiredRoy.enabled
        ? resolveLockTokenId(desiredRoy.tokenId)
        : desiredRoy.tokenId;
      const wantsEnabled = desiredRoy.enabled;

      const canEnable =
        !wantsEnabled || (resolvedTokenId > 0n && checkResolvedLockUsable(resolvedTokenId));

      if (canEnable) {
        const mismatch =
          curRoy.enabled !== desiredRoy.enabled ||
          (wantsEnabled &&
            (curRoy.paused ||
              curRoy.tokenId !== resolvedTokenId ||
              curRoy.durationSeconds !== desiredRoy.durationSeconds ||
              BigInt(curRoy.minCadenceSeconds) !== desiredRoy.minCadenceSeconds ||
              curRoy.minEthToCompound !== desiredRoy.minEthToCompound));

        if (mismatch) {
          actions.push({
            kind: 'royalties.setAutoCompoundConfigForUser',
            user: subject.address,
            enabled: desiredRoy.enabled,
            tokenId: resolvedTokenId,
            durationSeconds: desiredRoy.durationSeconds,
            minCadenceSeconds: desiredRoy.minCadenceSeconds,
            minEthToCompound: desiredRoy.minEthToCompound,
          });
        }
      }
    }

    // LP vault auto-compound config (same behavior as royalties).
    const curLp = subject.lpVault7D.autoCompoundConfig;
    const desiredLp =
      config.lpAutoCompoundDesired ??
      (curLp.enabled && curLp.paused
        ? {
            enabled: true,
            tokenId: curLp.tokenId,
            durationSeconds: curLp.durationSeconds,
          }
        : undefined);

    if (desiredLp && hasPerm(perms, P_SET_LP_AUTOCOMPOUND_CONFIG_FOR)) {
      const resolvedTokenId = desiredLp.enabled
        ? resolveLockTokenId(desiredLp.tokenId)
        : desiredLp.tokenId;
      const wantsEnabled = desiredLp.enabled;

      const canEnable =
        !wantsEnabled || (resolvedTokenId > 0n && checkResolvedLockUsable(resolvedTokenId));

      if (canEnable) {
        const mismatch =
          curLp.enabled !== desiredLp.enabled ||
          (wantsEnabled &&
            (curLp.paused ||
              curLp.tokenId !== resolvedTokenId ||
              curLp.durationSeconds !== desiredLp.durationSeconds));

        if (mismatch) {
          actions.push({
            kind: 'lpVault.setAutoCompoundConfigForUser',
            user: subject.address,
            enabled: desiredLp.enabled,
            tokenId: resolvedTokenId,
            durationSeconds: desiredLp.durationSeconds,
          });
        }
      }
    }

    if (actions.length > 0) return actions;
  }

  let plannedClaimAllFor = false;

  // 0) If the subject has no ve position and furnace entry is configured, do it first.
  const needsVe = subject.ve.veBalance === 0n || subject.ve.nftBalance === 0n;
  const canFurnace =
    config.enableFurnaceEntry &&
    !snapshot.furnace.lockingPaused &&
    config.furnaceEthIn > 0n &&
    caller.ethBalance >= config.furnaceEthIn &&
    (!delegated || hasPerm(perms, P_FURNACE_ENTER_ETH_FOR));

  if (needsVe && canFurnace) {
    if (delegated) {
      actions.push({
        kind: 'furnace.enterWithEthFor',
        user: subject.address,
        ethIn: config.furnaceEthIn,
        targetTokenId: config.targetTokenId,
        durationSeconds: config.lockDurationSeconds,
        createAutoMax: config.createAutoMax,
        slippageBps: config.slippageBps,
      });
    } else {
      actions.push({
        kind: 'furnace.enterWithEth',
        ethIn: config.furnaceEthIn,
        targetTokenId: config.targetTokenId,
        durationSeconds: config.lockDurationSeconds,
        createAutoMax: config.createAutoMax,
        slippageBps: config.slippageBps,
      });
    }

    return actions;
  }

  // 1) Collect royalties
  if (config.enableRoyaltiesClaim) {
    const claimable = subject.royalties.shareholderState.claimable;
    if (claimable > 0n && claimable >= config.minRoyaltiesEthToClaim) {
      if (delegated) {
        if (hasPerm(perms, P_CLAIM_ALL_FOR)) {
          actions.push({
            kind: 'claimAllHelper.claimAllFor',
            user: subject.address,
            claimable,
            mode: 0,
            targetTokenId: 0n,
            durationSeconds: 0n,
            createAutoMax: false,
            minVeOut: 0n,
          });
          plannedClaimAllFor = true;
        } else if (hasPerm(perms, P_CLAIM_SHAREHOLDER_FOR)) {
          actions.push({
            kind: 'claimAllHelper.claimShareholderForUser',
            user: subject.address,
            claimable,
            mode: 0,
            targetTokenId: 0n,
            durationSeconds: 0n,
            createAutoMax: false,
            minVeOut: 0n,
          });
        }
      } else {
        actions.push({ kind: 'royalties.claimShareholderEth', claimable });
      }
    }
  }

  // 2) Withdraw balances
  if (config.enableWithdrawals) {
    if (delegated) {
      // 2a) Withdraw the subject's king bucket (only possible if delegated perms allow it)
      const userKingBal = subject.mineCore.kingEthBalance;
      if (userKingBal > 0n && userKingBal >= config.minKingEthToWithdraw) {
        if (hasPerm(perms, P_CLAIM_ALL_FOR) && !plannedClaimAllFor) {
          // claimAllFor works even if claimable == 0; it will still withdraw the king bucket.
          actions.push({
            kind: 'claimAllHelper.claimAllFor',
            user: subject.address,
            claimable: subject.royalties.shareholderState.claimable,
            mode: 0,
            targetTokenId: 0n,
            durationSeconds: 0n,
            createAutoMax: false,
            minVeOut: 0n,
          });
          plannedClaimAllFor = true;
        } else if (hasPerm(perms, P_WITHDRAW_KING_BUCKET_FOR)) {
          actions.push({
            kind: 'claimAllHelper.withdrawKingBalanceForUser',
            user: subject.address,
            amount: userKingBal,
          });
        }
      }

      // 2b) Withdraw the caller's buckets (refund + king) so the bot can keep looping.
      const refundBal = caller.mineCoreRefundEthBalance;
      if (refundBal > 0n && refundBal >= config.minRefundEthToWithdraw) {
        actions.push({
          kind: 'mineCore.withdrawRefundBalance',
          amount: refundBal,
          to: caller.address,
        });
      }

      const kingBal = caller.mineCoreKingEthBalance;
      if (kingBal > 0n && kingBal >= config.minKingEthToWithdraw) {
        actions.push({ kind: 'mineCore.withdrawKingBalance', amount: kingBal });
      }
    } else {
      // Self mode: withdraw the subject's buckets.
      const refundBal = subject.mineCore.refundEthBalance;
      if (refundBal > 0n && refundBal >= config.minRefundEthToWithdraw) {
        actions.push({
          kind: 'mineCore.withdrawRefundBalance',
          amount: refundBal,
          to: subject.address,
        });
      }

      const kingBal = subject.mineCore.kingEthBalance;
      if (kingBal > 0n && kingBal >= config.minKingEthToWithdraw) {
        actions.push({ kind: 'mineCore.withdrawKingBalance', amount: kingBal });
      }
    }
  }

  // 3) Takeovers
  if (config.enableTakeovers) {
    const cooldownOk =
      state.lastTakeoverAtMs === undefined ||
      nowMs - state.lastTakeoverAtMs >= config.takeoverCooldownSeconds * 1000;

    const price = snapshot.mineCore.currentTakeoverPrice;

    const baseChecks =
      cooldownOk &&
      !snapshot.mineCore.takeoversPaused &&
      !sameAddress(snapshot.mineCore.currentKing, subject.address) &&
      config.maxTakeoverEth > 0n &&
      price > 0n &&
      price <= config.maxTakeoverEth &&
      caller.ethBalance >= price;

    const canTakeover = baseChecks && (!delegated || hasPerm(perms, P_TAKEOVER_FOR));

    if (canTakeover) {
      if (delegated) {
        actions.push({ kind: 'mineCore.takeoverFor', newKing: subject.address, price });
      } else {
        actions.push({ kind: 'mineCore.takeover', price });
      }
    }
  }

  return actions;
}
