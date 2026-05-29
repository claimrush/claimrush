// Canonical DelegationHub permission bits.
//
// Source of truth: src/lib/DelegationPermissions.sol
//
// Notes
// - Values are ABI/stability sensitive.
// - Keep these in sync with protocol releases.

export const P_TAKEOVER_FOR = 1n << 0n;
export const P_ROUTE_REIGN_CLAIM_TO_CALLER = 1n << 1n;
export const P_SET_REIGN_ETH_RECIPIENT = 1n << 2n;
export const P_SET_REIGN_ETH_RECIPIENT_TO_CALLER_ONLY = 1n << 3n;
export const P_SET_REIGN_CLAIM_RECIPIENT = 1n << 4n;
export const P_SET_REIGN_CLAIM_RECIPIENT_TO_USER_ONLY = 1n << 5n;

export const P_WITHDRAW_KING_BUCKET_FOR = 1n << 6n;
export const P_CLAIM_SHAREHOLDER_FOR = 1n << 7n;
export const P_CLAIM_ALL_FOR = 1n << 8n;

export const P_FURNACE_ENTER_ETH_FOR = 1n << 9n;
export const P_FURNACE_ENTER_CLAIM_FOR = 1n << 10n;
export const P_FURNACE_ENTER_TOKEN_FOR = 1n << 11n;

export const P_VE_EXTEND_LOCK_FOR = 1n << 12n;
export const P_VE_MERGE_LOCKS_FOR = 1n << 13n;
export const P_VE_UNLOCK_EXPIRED_FOR = 1n << 14n;

export const P_SET_KING_AUTO_LOCK_CONFIG_FOR = 1n << 15n;
export const P_SET_SHAREHOLDER_AUTOCOMPOUND_CONFIG_FOR = 1n << 16n;
export const P_SET_LP_AUTOCOMPOUND_CONFIG_FOR = 1n << 17n;

// `ALL` is the bitmask of every defined permission, including the three
// fund-redirection bits (P_ROUTE_REIGN_CLAIM_TO_CALLER,
// P_SET_REIGN_ETH_RECIPIENT, P_SET_REIGN_CLAIM_RECIPIENT). Do NOT use `ALL`
// when delegating to a third-party agent; use `SAFE_AGENT_PERMS` (below)
// instead, which excludes those three bits.

export const ALL =
  P_TAKEOVER_FOR |
  P_ROUTE_REIGN_CLAIM_TO_CALLER |
  P_SET_REIGN_ETH_RECIPIENT |
  P_SET_REIGN_ETH_RECIPIENT_TO_CALLER_ONLY |
  P_SET_REIGN_CLAIM_RECIPIENT |
  P_SET_REIGN_CLAIM_RECIPIENT_TO_USER_ONLY |
  P_WITHDRAW_KING_BUCKET_FOR |
  P_CLAIM_SHAREHOLDER_FOR |
  P_CLAIM_ALL_FOR |
  P_FURNACE_ENTER_ETH_FOR |
  P_FURNACE_ENTER_CLAIM_FOR |
  P_FURNACE_ENTER_TOKEN_FOR |
  P_VE_EXTEND_LOCK_FOR |
  P_VE_MERGE_LOCKS_FOR |
  P_VE_UNLOCK_EXPIRED_FOR |
  P_SET_KING_AUTO_LOCK_CONFIG_FOR |
  P_SET_SHAREHOLDER_AUTOCOMPOUND_CONFIG_FOR |
  P_SET_LP_AUTOCOMPOUND_CONFIG_FOR;

export const SAFE_AGENT_PERMS =
  ALL & ~P_ROUTE_REIGN_CLAIM_TO_CALLER & ~P_SET_REIGN_ETH_RECIPIENT & ~P_SET_REIGN_CLAIM_RECIPIENT;

/** Convenience OR helper. */
export function permsMask(perms: bigint[]): bigint {
  let out = 0n;
  for (const p of perms) out |= p;
  return out;
}

export type DelegationPermInfo = {
  /** Full exported constant name (as used in docs + code). */
  constant: string;
  bit: bigint;
  /** Brief description of what this permission enables. */
  description: string;
};

/** Canonical permission registry (useful for UI + CLIs). */
export const PERM_DEFINITIONS: readonly DelegationPermInfo[] = [
  {
    constant: 'P_TAKEOVER_FOR',
    bit: P_TAKEOVER_FOR,
    description: 'Allow MineCore.takeoverFor(user).',
  },
  {
    constant: 'P_ROUTE_REIGN_CLAIM_TO_CALLER',
    bit: P_ROUTE_REIGN_CLAIM_TO_CALLER,
    description: 'Allow routing the reign CLAIM stream to the delegate (high risk).',
  },
  {
    constant: 'P_SET_REIGN_ETH_RECIPIENT',
    bit: P_SET_REIGN_ETH_RECIPIENT,
    description: 'Allow setting reign ETH recipient (high risk).',
  },
  {
    constant: 'P_SET_REIGN_ETH_RECIPIENT_TO_CALLER_ONLY',
    bit: P_SET_REIGN_ETH_RECIPIENT_TO_CALLER_ONLY,
    description: 'Allow setting reign ETH recipient only to the delegate.',
  },
  {
    constant: 'P_SET_REIGN_CLAIM_RECIPIENT',
    bit: P_SET_REIGN_CLAIM_RECIPIENT,
    description: 'Allow setting reign CLAIM recipient (high risk).',
  },
  {
    constant: 'P_SET_REIGN_CLAIM_RECIPIENT_TO_USER_ONLY',
    bit: P_SET_REIGN_CLAIM_RECIPIENT_TO_USER_ONLY,
    description: 'Allow setting reign CLAIM recipient only to the user.',
  },

  {
    constant: 'P_WITHDRAW_KING_BUCKET_FOR',
    bit: P_WITHDRAW_KING_BUCKET_FOR,
    description: 'Allow withdrawing user King bucket via ClaimAllHelper.',
  },
  {
    constant: 'P_CLAIM_SHAREHOLDER_FOR',
    bit: P_CLAIM_SHAREHOLDER_FOR,
    description: 'Allow claiming shareholder ETH for user via ClaimAllHelper.',
  },
  {
    constant: 'P_CLAIM_ALL_FOR',
    bit: P_CLAIM_ALL_FOR,
    description: 'Allow ClaimAllHelper.claimAllFor(user,...).',
  },

  {
    constant: 'P_FURNACE_ENTER_ETH_FOR',
    bit: P_FURNACE_ENTER_ETH_FOR,
    description: 'Allow Furnace.enterWithEthFor(user,...).',
  },
  {
    constant: 'P_FURNACE_ENTER_CLAIM_FOR',
    bit: P_FURNACE_ENTER_CLAIM_FOR,
    description: 'Allow Furnace.enterWithClaimFor(user,...).',
  },
  {
    constant: 'P_FURNACE_ENTER_TOKEN_FOR',
    bit: P_FURNACE_ENTER_TOKEN_FOR,
    description: 'Allow Furnace.enterWithTokenFor(user,...).',
  },

  {
    constant: 'P_VE_EXTEND_LOCK_FOR',
    bit: P_VE_EXTEND_LOCK_FOR,
    description: 'Allow extending ve lock for user.',
  },
  {
    constant: 'P_VE_MERGE_LOCKS_FOR',
    bit: P_VE_MERGE_LOCKS_FOR,
    description: 'Allow merging ve locks for user.',
  },
  {
    constant: 'P_VE_UNLOCK_EXPIRED_FOR',
    bit: P_VE_UNLOCK_EXPIRED_FOR,
    description: 'Allow unlocking expired ve lock for user.',
  },

  {
    constant: 'P_SET_KING_AUTO_LOCK_CONFIG_FOR',
    bit: P_SET_KING_AUTO_LOCK_CONFIG_FOR,
    description: 'Allow setting King auto-lock config for user.',
  },
  {
    constant: 'P_SET_SHAREHOLDER_AUTOCOMPOUND_CONFIG_FOR',
    bit: P_SET_SHAREHOLDER_AUTOCOMPOUND_CONFIG_FOR,
    description: 'Allow setting shareholder auto-compound config for user.',
  },
  {
    constant: 'P_SET_LP_AUTOCOMPOUND_CONFIG_FOR',
    bit: P_SET_LP_AUTOCOMPOUND_CONFIG_FOR,
    description: 'Allow setting LP auto-compound config for user.',
  },
] as const;

export const PERM_NAME_TO_BIT: Readonly<Record<string, bigint>> = Object.freeze(
  Object.fromEntries(PERM_DEFINITIONS.map((p) => [p.constant, p.bit])) as Record<string, bigint>,
);

function normalizePermConstant(raw: string): string {
  let n = raw.trim().toUpperCase();
  if (!n) return n;
  while (n.startsWith('P_')) n = n.slice(2);
  return `P_${n}`;
}

/**
 * Turns a list of perm names (e.g. ['TAKEOVER_FOR','CLAIM_ALL_FOR']) into a bitmask.
 * Accepts either `TAKEOVER_FOR` or `P_TAKEOVER_FOR`.
 */
export function permsFromNames(names: string[]): bigint {
  let out = 0n;
  for (const raw of names) {
    const key = normalizePermConstant(raw);
    const bit = PERM_NAME_TO_BIT[key];
    if (bit === undefined) throw new Error(`Unknown delegation permission: ${raw}`);
    out |= bit;
  }
  if (out !== 0n && (out & ~ALL) !== 0n) {
    throw new Error(
      `permsFromNames: resulting mask 0x${out.toString(16)} contains bits outside the ` +
        `known permission set (ALL=0x${ALL.toString(16)}). ` +
        `This may indicate a corrupted PERM_NAME_TO_BIT registry.`,
    );
  }
  return out;
}

/**
 * Parses a permission spec:
 * - Numeric: '1234' or '0x4d2'
 * - Names: 'TAKEOVER_FOR,CLAIM_ALL_FOR'
 */
export function parsePermsSpec(spec: string): bigint {
  const s = spec.trim();
  if (!s) return 0n;

  const MAX_KNOWN_BIT = 17n;
  const MAX_VALID_PERMS = (1n << (MAX_KNOWN_BIT + 1n)) - 1n;

  const numeric = /^0x[0-9a-fA-F]+$/.test(s) || /^[0-9]+$/.test(s);
  if (numeric) {
    const v = BigInt(s);
    if (v < 0n) throw new Error(`parsePermsSpec: negative value not allowed: ${s}`);
    if (v > MAX_VALID_PERMS) {
      throw new Error(
        `parsePermsSpec: value ${s} sets bits above the highest known permission (bit ${MAX_KNOWN_BIT}). ` +
          `This may grant undefined permissions. Use named permissions or update the SDK.`,
      );
    }
    return v;
  }

  const parts = s
    .split(',')
    .map((x) => x.trim())
    .filter(Boolean);
  return permsFromNames(parts);
}

/** Returns the list of permission constant names currently set in a mask. */
export function describePerms(perms: bigint): string[] {
  return PERM_DEFINITIONS.filter((p) => (perms & p.bit) !== 0n).map((p) => p.constant);
}
