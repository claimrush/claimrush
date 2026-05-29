import type { Account } from 'viem';
import { mnemonicToAccount, privateKeyToAccount } from 'viem/accounts';

export type DerivedActor = {
  label: string;
  account: Account;
};

// Must match scripts/local.mjs default.
//
// This mnemonic is publicly known (standard Anvil/Hardhat default). It is only
// safe on local dev chains. `deriveActors` refuses to use it unless the caller
// opts in explicitly via `allowDefaultMnemonic: true` or the
// `ALLOW_DEFAULT_MNEMONIC=1` env var, and logs a warning even then.
export const DEFAULT_ANVIL_MNEMONIC = 'test test test test test test test test test test test junk';

const PRIVATE_KEY_RE = /^0x[0-9a-fA-F]{64}$/;

function normalize0x(hex: string): `0x${string}` {
  const h = hex.startsWith('0x') ? hex : `0x${hex}`;
  return h as `0x${string}`;
}

/**
 * Validate a hex string is a well-formed secp256k1 private key.
 *
 * ClaimRush's offchain keeper enforces this exact shape on its own config
 * boundary, and the SDK harness must match so that misconfigured callers get
 * a clear, boundary-owned error instead of a viem-internal trace deep inside
 * `privateKeyToAccount`. The function throws with the entry index (when
 * provided) and never logs the secret itself.
 */
function assertPrivateKeyHex(raw: string, indexHint?: number): `0x${string}` {
  const normalised = normalize0x(raw);
  if (!PRIVATE_KEY_RE.test(normalised)) {
    const where = indexHint !== undefined ? ` at index ${indexHint}` : '';
    throw new Error(
      `[ClaimRush SDK] Invalid private key${where}: expected /^0x[0-9a-fA-F]{64}$/ ` +
        `(32 raw bytes, optional 0x prefix). Private key value is not included in this error.`,
    );
  }
  return normalised;
}

/**
 * Derive a deterministic list of accounts.
 *
 * Priority:
 * 1) PRIVATE_KEYS (comma-separated)
 * 2) MNEMONIC (with derivation path m/44'/60'/0'/0/i)
 * 3) DEFAULT_ANVIL_MNEMONIC
 */
export function deriveActors(params?: {
  count?: number;
  mnemonic?: string;
  privateKeysCsv?: string;
  /** When true, allow silent fallback to DEFAULT_ANVIL_MNEMONIC without env guard. */
  allowDefaultMnemonic?: boolean;
}): DerivedActor[] {
  const count = params?.count ?? 3;
  if (count <= 0) return [];

  const privateKeysCsv = params?.privateKeysCsv?.trim();
  if (privateKeysCsv) {
    const keys = privateKeysCsv
      .split(',')
      .map((s) => s.trim())
      .filter(Boolean);
    return keys.slice(0, count).map((pk, i) => ({
      label: `actor${i}`,
      account: privateKeyToAccount(assertPrivateKeyHex(pk, i)),
    }));
  }

  const mnemonic = (params?.mnemonic?.trim() || DEFAULT_ANVIL_MNEMONIC).trim();
  if (mnemonic === DEFAULT_ANVIL_MNEMONIC) {
    const envAllow = (process.env.ALLOW_DEFAULT_MNEMONIC ?? '').trim().toLowerCase();
    const explicitAllow =
      params?.allowDefaultMnemonic === true || envAllow === '1' || envAllow === 'true';
    if (!explicitAllow) {
      throw new Error(
        '[ClaimRush SDK] Refusing to use DEFAULT_ANVIL_MNEMONIC. ' +
          'Derived keys are publicly known and MUST NOT be used on mainnet. ' +
          'Set MNEMONIC or PRIVATE_KEYS env var, or set ALLOW_DEFAULT_MNEMONIC=1 to bypass.',
      );
    }
    console.warn(
      '[ClaimRush SDK] WARNING: Using default Anvil mnemonic. ' +
        'Derived keys are publicly known and MUST NOT be used on mainnet. ' +
        'Set MNEMONIC or PRIVATE_KEYS env var for production use.',
    );
  }
  const out: DerivedActor[] = [];
  for (let i = 0; i < count; i++) {
    // Use addressIndex (not accountIndex) to match Anvil's derivation: m/44'/60'/0'/0/{i}
    const account = mnemonicToAccount(mnemonic, { addressIndex: i });
    out.push({ label: `actor${i}`, account });
  }
  return out;
}
