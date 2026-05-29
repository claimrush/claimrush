import { isAddress, zeroAddress, type Address } from 'viem';

import type { DeploymentManifest } from '../manifest.js';

import type { AgentAction } from './types.js';

export type AgentExecutionSecurity = {
  /** Disable all runtime security checks (not recommended). Default: enabled. */
  enabled?: boolean;

  /** Optional allowlist: if set, only these action kinds may execute. */
  allowedActionKinds?: string[];

  /** Optional denylist: these action kinds are never allowed. */
  deniedActionKinds?: string[];

  /**
   * Delegation scope: if set, delegated actions are only allowed for these users.
   *
   * Useful to prevent a compromised strategy/plugin from acting for a different user
   * when the agent happens to have multiple active delegation sessions.
   */
  delegatedUserAllowlist?: Address[];

  /** If true, skip delegated user scoping checks. Default: false. */
  allowAnyDelegatedUser?: boolean;

  /**
   * Approval spender allowlist.
   *
   * Default (when unset): all manifest contract addresses.
   */
  approvalSpenderAllowlist?: Address[];

  /** If true, allow approvals to any spender/operator. Default: false. */
  allowAnyApprovalSpender?: boolean;

  /**
   * veNFT operator/spender allowlist.
   *
   * Default (when unset): approvalSpenderAllowlist.
   */
  nftOperatorAllowlist?: Address[];

  /** If true, allow ve approvals to any operator/spender. Default: false. */
  allowAnyNftOperator?: boolean;

  /** If false (default), MineCore.withdrawRefundBalance must withdraw to the signer unless allowlisted. */
  allowThirdPartyWithdrawals?: boolean;

  /** If set and third-party withdrawals are disabled, allow these recipients in addition to signer. */
  withdrawalRecipientAllowlist?: Address[];

  /** Global cap for native value sent in a call (wei). */
  maxCallValueWei?: bigint;

  /** Global cap for ERC20 approve/ensureAllowance approveAmount (wei). */
  maxApprovalAmount?: bigint;

  /**
   * Max allowed slippageBps across all actions.
   *
   * Default: 10_000 (100%).
   *
   * In production, prefer setting this to your configured slippageBps to prevent
   * strategies from silently widening slippage.
   */
  maxSlippageBps?: bigint;

  /** Validate basic invariants (addresses, non-negative, bps bounds, seconds bounds). Default: true. */
  validateInputs?: boolean;

  /** Allow very large seconds fields (> uint32). Default: false. */
  allowLargeSeconds?: boolean;
};

export type ActionSecurityCheckResult =
  | { ok: true }
  | {
      ok: false;
      error: string;
      details?: Record<string, unknown>;
    };

const UINT32_MAX = 0xffff_ffffn;

function normAddr(a: string): string {
  return a.toLowerCase();
}

function uniqAddrs(addrs: (string | Address)[]): Address[] {
  const seen = new Set<string>();
  const out: Address[] = [];
  for (const a of addrs) {
    const s = String(a).toLowerCase();
    if (!s) continue;
    if (seen.has(s)) continue;
    seen.add(s);
    out.push(s as Address);
  }
  return out;
}

function deriveManifestContractAllowlist(manifest: DeploymentManifest): Address[] {
  const refs = Object.values(manifest.contracts ?? {});
  const addrs = refs.map((r) => (r as any)?.address).filter((v) => typeof v === 'string');
  return uniqAddrs(addrs as Address[]);
}

function includesAddr(list: Address[], addr: string): boolean {
  const needle = normAddr(addr);
  return list.some((a) => normAddr(a) === needle);
}

function isActionKindAllowed(
  actionKind: string,
  sec: AgentExecutionSecurity,
): ActionSecurityCheckResult {
  const allowed = sec.allowedActionKinds?.filter(Boolean) ?? [];
  if (allowed.length > 0 && !allowed.includes(actionKind)) {
    return {
      ok: false,
      error: `Action kind '${actionKind}' is not in allowedActionKinds`,
      details: { actionKind, allowedActionKinds: allowed },
    };
  }

  const denied = sec.deniedActionKinds?.filter(Boolean) ?? [];
  if (denied.length > 0 && denied.includes(actionKind)) {
    return {
      ok: false,
      error: `Action kind '${actionKind}' is blocked by deniedActionKinds`,
      details: { actionKind, deniedActionKinds: denied },
    };
  }

  return { ok: true };
}

function validateActionShape(
  action: AgentAction,
  sec: AgentExecutionSecurity,
): ActionSecurityCheckResult {
  if (sec.validateInputs === false) return { ok: true };

  // Address fields used across AgentAction variants.
  const addressKeys = [
    'user',
    'tokenIn',
    'newKing',
    'ethRecipient',
    'claimRecipient',
    'to',
    'token',
    'spender',
    'operator',
  ] as const;

  for (const k of addressKeys) {
    const v = (action as any)[k];
    if (v === undefined) continue;
    if (typeof v !== 'string' || !isAddress(v)) {
      return {
        ok: false,
        error: `Invalid address field '${k}': ${String(v)}`,
        details: { field: k, value: v },
      };
    }
  }

  for (const [k, v] of Object.entries(action as any)) {
    if (typeof v === 'bigint') {
      if (v < 0n) {
        return {
          ok: false,
          error: `Invalid bigint field '${k}': must be >= 0`,
          details: { field: k, value: v.toString() },
        };
      }

      // Basic bps bounds.
      if (k.endsWith('Bps')) {
        const configured = k === 'slippageBps' ? (sec.maxSlippageBps ?? 10_000n) : 10_000n;
        const max = configured > 10_000n ? 10_000n : configured;
        if (v > max) {
          return {
            ok: false,
            error: `Invalid '${k}': ${v.toString()} (max ${max.toString()})`,
            details: { field: k, value: v.toString(), max: max.toString() },
          };
        }
      }

      // Seconds fields are encoded as uint32 onchain in most places.
      if (!sec.allowLargeSeconds && k.includes('Seconds') && v > UINT32_MAX) {
        return {
          ok: false,
          error: `Invalid seconds field '${k}': ${v.toString()} (exceeds uint32 max)`,
          details: { field: k, value: v.toString(), max: UINT32_MAX.toString() },
        };
      }
    }
  }

  // Numeric fields: enforce finiteness + integer semantics to avoid NaN/Infinity
  // sneaking into ABI encoding paths.
  for (const [k, v] of Object.entries(action as any)) {
    if (typeof v === 'number') {
      if (!Number.isFinite(v) || !Number.isInteger(v)) {
        return {
          ok: false,
          error: `Invalid number field '${k}': expected finite integer`,
          details: { field: k, value: String(v) },
        };
      }
    }
  }

  // Action-specific numeric bounds.
  if (
    action.kind === 'claimAllHelper.claimShareholderForUser' ||
    action.kind === 'claimAllHelper.claimAllFor'
  ) {
    const mode = (action as any).mode as unknown;
    if (
      typeof mode !== 'number' ||
      !Number.isFinite(mode) ||
      !Number.isInteger(mode) ||
      (mode !== 0 && mode !== 1)
    ) {
      return {
        ok: false,
        error: `Invalid mode: ${String(mode)} (expected 0=ETH or 1=LOCK_FURNACE)`,
        details: { mode },
      };
    }
  }

  return { ok: true };
}

function callValueForAction(action: AgentAction): bigint | undefined {
  switch (action.kind) {
    case 'mineCore.takeover':
    case 'mineCore.takeoverFor':
      return (action as any).price as bigint;

    case 'furnace.enterWithEth':
    case 'furnace.enterWithEthFor':
      return (action as any).ethIn as bigint;

    default:
      return undefined;
  }
}

/**
 * Enforce security policy for an AgentAction before any on-chain execution.
 */
export function checkAgentActionSecurity(params: {
  action: AgentAction;
  execute: boolean;
  manifest: DeploymentManifest;
  signer: Address;
  security?: AgentExecutionSecurity;
  /** Delegated user (if this action requires delegation). */
  delegatedUser?: Address;
}): ActionSecurityCheckResult {
  const sec: AgentExecutionSecurity = params.security ?? {};
  if (sec.enabled === false) return { ok: true };

  // Kind allow/deny lists.
  const kindCheck = isActionKindAllowed(params.action.kind, sec);
  if (!kindCheck.ok) return kindCheck;

  // Structured input validation (addresses, bounds).
  const shapeCheck = validateActionShape(params.action, sec);
  if (!shapeCheck.ok) return shapeCheck;

  // Delegation scope: only allow acting for explicitly scoped users.
  if (!sec.allowAnyDelegatedUser && params.delegatedUser) {
    // the previous logic silently allowed ANY delegated user, defeating the
    // purpose of scoping. A compromised strategy could act for any user the
    // agent has an active delegation session with. Now: if a delegated action
    // is proposed but no allowlist is configured, reject by default. Operators
    // must explicitly set allowAnyDelegatedUser=true or populate the allowlist.
    const allowed = sec.delegatedUserAllowlist ?? [];
    if (allowed.length === 0 || !includesAddr(allowed, params.delegatedUser)) {
      return {
        ok: false,
        error: `Delegated action is out of scope for user ${params.delegatedUser} (allowlist ${allowed.length === 0 ? 'empty — configure delegatedUserAllowlist or set allowAnyDelegatedUser' : 'miss'})`,
        details: {
          delegatedUser: params.delegatedUser,
          allowedUsers: allowed,
        },
      };
    }
  }

  // Native value caps.
  const v = callValueForAction(params.action);
  if (v !== undefined && sec.maxCallValueWei !== undefined && v > sec.maxCallValueWei) {
    return {
      ok: false,
      error: `Call value exceeds maxCallValueWei (${v.toString()} > ${sec.maxCallValueWei.toString()})`,
      details: {
        actionKind: params.action.kind,
        valueWei: v.toString(),
        maxCallValueWei: sec.maxCallValueWei.toString(),
      },
    };
  }

  // Approval gating.
  const manifestAllow = deriveManifestContractAllowlist(params.manifest);
  const spenderAllow = sec.approvalSpenderAllowlist ?? manifestAllow;
  const nftAllow = sec.nftOperatorAllowlist ?? spenderAllow;

  if (!sec.allowAnyApprovalSpender) {
    if (params.action.kind === 'erc20.approve' || params.action.kind === 'erc20.ensureAllowance') {
      const spender = (params.action as any).spender as Address;
      if (!includesAddr(spenderAllow, spender)) {
        return {
          ok: false,
          error: `ERC20 approval spender not allowed: ${spender}`,
          details: {
            spender,
            spenderAllowlist: spenderAllow,
          },
        };
      }
    }
  }

  if (sec.maxApprovalAmount !== undefined) {
    if (params.action.kind === 'erc20.approve') {
      const amt = (params.action as any).amount as bigint;
      if (amt > sec.maxApprovalAmount) {
        return {
          ok: false,
          error: `ERC20 approve amount exceeds maxApprovalAmount (${amt.toString()} > ${sec.maxApprovalAmount.toString()})`,
          details: { amount: amt.toString(), maxApprovalAmount: sec.maxApprovalAmount.toString() },
        };
      }
    }

    if (params.action.kind === 'erc20.ensureAllowance') {
      const amt = (params.action as any).approveAmount as bigint;
      if (amt > sec.maxApprovalAmount) {
        return {
          ok: false,
          error: `ERC20 ensureAllowance approveAmount exceeds maxApprovalAmount (${amt.toString()} > ${sec.maxApprovalAmount.toString()})`,
          details: {
            approveAmount: amt.toString(),
            maxApprovalAmount: sec.maxApprovalAmount.toString(),
          },
        };
      }
    }
  }

  if (!sec.allowAnyNftOperator) {
    if (params.action.kind === 've.approve') {
      const spender = (params.action as any).spender as Address;
      if (!includesAddr(nftAllow, spender)) {
        return {
          ok: false,
          error: `veNFT approve spender not allowed: ${spender}`,
          details: { spender, operatorAllowlist: nftAllow },
        };
      }
    }

    if (params.action.kind === 've.setApprovalForAll') {
      const operator = (params.action as any).operator as Address;
      if (!includesAddr(nftAllow, operator)) {
        return {
          ok: false,
          error: `veNFT operator not allowed: ${operator}`,
          details: { operator, operatorAllowlist: nftAllow },
        };
      }
    }
  }

  // as withdrawRefundBalance. Without this check, a compromised strategy could
  // submit a withdrawKingBalance action directing accumulated king-bucket funds
  // to an attacker-controlled address. The fix mirrors the existing recipient
  // gating applied to withdrawRefundBalance (above).
  if (params.action.kind === 'mineCore.withdrawKingBalance') {
    const to = (params.action as any).to as Address;
    if (normAddr(to) === normAddr(zeroAddress)) {
      return {
        ok: false,
        error: `withdrawKingBalance: recipient is the zero address (would burn funds)`,
        details: { to },
      };
    }
    if (!sec.allowThirdPartyWithdrawals) {
      const signer = params.signer;
      const extra = sec.withdrawalRecipientAllowlist ?? [];

      const ok = normAddr(to) === normAddr(signer) || (extra.length > 0 && includesAddr(extra, to));
      if (!ok) {
        return {
          ok: false,
          error: `withdrawKingBalance recipient not allowed: ${to}`,
          details: { to, signer, withdrawalRecipientAllowlist: extra },
        };
      }
    }
  }

  // Withdrawal recipient gating.
  if (params.action.kind === 'mineCore.withdrawRefundBalance') {
    const to = (params.action as any).to as Address;
    if (normAddr(to) === normAddr(zeroAddress)) {
      return {
        ok: false,
        error: `withdrawRefundBalance: recipient is the zero address (would burn funds)`,
        details: { to },
      };
    }
    if (!sec.allowThirdPartyWithdrawals) {
      const signer = params.signer;
      const extra = sec.withdrawalRecipientAllowlist ?? [];

      const ok = normAddr(to) === normAddr(signer) || (extra.length > 0 && includesAddr(extra, to));
      if (!ok) {
        return {
          ok: false,
          error: `withdrawRefundBalance recipient not allowed: ${to}`,
          details: {
            to,
            signer,
            withdrawalRecipientAllowlist: extra,
          },
        };
      }
    }
  }

  return { ok: true };
}
