import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

import type { Account, Address } from 'viem';
import { getAddress, isAddress } from 'viem';
import { mnemonicToAccount, privateKeyToAccount } from 'viem/accounts';

/**
 * Locate the ClaimRush repo root by walking up from the skill's dist/ dir
 * until we find a `deployments/` folder. The SDK provides its own
 * `findRepoRoot`, but it is keyed off the SDK's location, not the skill's;
 * walking up from this file is more reliable when the skill is npm-linked.
 */
export function repoRoot(): string {
  // import.meta.url -> .../skills/claimrush/dist/util/identity.js
  const here = path.dirname(fileURLToPath(import.meta.url));
  let dir = here;
  for (let i = 0; i < 8; i++) {
    if (
      isFile(path.join(dir, 'package.json')) &&
      isDir(path.join(dir, 'deployments')) &&
      isDir(path.join(dir, 'agents'))
    ) {
      return dir;
    }
    const parent = path.dirname(dir);
    if (parent === dir) break;
    dir = parent;
  }
  // Fallback: the skill is always installed at <repo>/skills/claimrush so
  // ../../.. from here is always the repo root if package layout is intact.
  return path.resolve(here, '..', '..', '..', '..');
}

function isDir(p: string): boolean {
  try {
    return fs.statSync(p).isDirectory();
  } catch {
    return false;
  }
}

function isFile(p: string): boolean {
  try {
    return fs.statSync(p).isFile();
  } catch {
    return false;
  }
}

const DEFAULT_ANVIL_MNEMONIC = 'test test test test test test test test test test test junk';
const PRIVATE_KEY_RE = /^0x[0-9a-fA-F]{64}$/;

/**
 * Derive an Account from PRIVATE_KEYS / MNEMONIC / LOCAL_MNEMONIC. Mirrors
 * `agents/sdk/src/harness/accounts.ts` semantics, but reimplemented here
 * because the SDK does not export this helper from its public entrypoint.
 *
 * Priority:
 *   1) PRIVATE_KEYS (comma-separated)  ->  PRIVATE_KEY (single)
 *   2) MNEMONIC                        ->  LOCAL_MNEMONIC
 *   3) DEFAULT_ANVIL_MNEMONIC          (only when ALLOW_DEFAULT_MNEMONIC=1)
 */
export function loadAgentAccount(actorIndex = 0): { account: Account; agent: Address } {
  const idx = Math.max(0, Math.floor(actorIndex));

  const pkCsv = process.env.PRIVATE_KEYS ?? process.env.PRIVATE_KEY;
  if (pkCsv && pkCsv.trim()) {
    const list = pkCsv
      .split(',')
      .map((s) => s.trim())
      .filter(Boolean)
      .map((raw) => (raw.startsWith('0x') ? raw : `0x${raw}`));
    const chosen = list[Math.min(idx, list.length - 1)];
    if (!chosen) throw new Error('PRIVATE_KEYS resolves to no usable entries');
    if (!PRIVATE_KEY_RE.test(chosen)) {
      throw new Error('PRIVATE_KEYS entry is not a valid 0x-prefixed 32-byte hex string');
    }
    const account = privateKeyToAccount(chosen as `0x${string}`);
    return { account, agent: account.address as Address };
  }

  const mnemonic = process.env.MNEMONIC ?? process.env.LOCAL_MNEMONIC;
  if (mnemonic && mnemonic.trim()) {
    const account = mnemonicToAccount(mnemonic.trim(), { addressIndex: idx });
    return { account, agent: account.address as Address };
  }

  const allowDefault = (process.env.ALLOW_DEFAULT_MNEMONIC ?? '').trim() === '1';
  if (!allowDefault) {
    throw new Error(
      '[claimrush-skill] No wallet configured. Set MNEMONIC or PRIVATE_KEYS, ' +
        'or set ALLOW_DEFAULT_MNEMONIC=1 to use the public Anvil mnemonic on local chains.',
    );
  }
  const account = mnemonicToAccount(DEFAULT_ANVIL_MNEMONIC, { addressIndex: idx });
  return { account, agent: account.address as Address };
}

/** Validate + checksum an `--acting-for 0x...` address, or return undefined. */
export function parseActingFor(input: string | undefined): Address | undefined {
  if (!input) return undefined;
  const v = input.trim();
  if (!isAddress(v)) throw new Error(`--acting-for is not a valid address: ${input}`);
  return getAddress(v) as Address;
}
