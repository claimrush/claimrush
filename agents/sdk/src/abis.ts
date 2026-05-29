import { readFileSync } from 'node:fs';
import { join } from 'node:path';
import type { Abi } from 'viem';
import { findRepoRoot } from './repoRoot.js';

export type AbiNetwork = 'base_mainnet' | 'base_sepolia';

export type LoadAbiParams = {
  contractName: string;
  /** Which ABI folder to read from under `/abis/`. Default: `base_sepolia`.
   *
   * Note: for v1.0.0, Base Sepolia and Base mainnet ABIs are expected to be identical.
   */
  abiNetwork?: AbiNetwork;
  repoRoot?: string;
};

const ABI_NETWORKS: AbiNetwork[] = ['base_mainnet', 'base_sepolia'];
const SAFE_STEM_RE = /^[a-zA-Z0-9_-]+$/;

function validateAbiNetwork(v: unknown): AbiNetwork {
  if (v === undefined || v === null) return 'base_sepolia';
  const s = String(v).trim();
  if (!s) return 'base_sepolia';

  if (s === 'base_mainnet' || s === 'base_sepolia') return s as AbiNetwork;

  throw new Error(
    `Invalid abiNetwork '${s}' (allowed: ${ABI_NETWORKS.join(', ')}). ` +
      `This value is used as a folder name under /abis/.`,
  );
}

function validateContractName(v: unknown): string {
  const s = String(v ?? '').trim();
  if (!s) throw new Error('loadAbi.contractName: expected non-empty string');

  // Prevent path traversal / weird filesystem interactions.
  // ABI file names are simple stems under /abis/<network>/.
  if (!SAFE_STEM_RE.test(s)) {
    throw new Error(
      `loadAbi.contractName: invalid contractName '${s}' (expected ${SAFE_STEM_RE}; example: MineCore)`,
    );
  }

  return s;
}

const abiCache = new Map<string, Abi>();

export function loadAbi(params: LoadAbiParams): Abi {
  const repoRoot = params.repoRoot ?? findRepoRoot();

  // NOTE: runtime validation is important here because env/config casts can bypass TS unions.
  const abiNetwork = validateAbiNetwork((params as any).abiNetwork);
  const contractName = validateContractName((params as any).contractName);

  const key = `${repoRoot}::${abiNetwork}::${contractName}`;
  const cached = abiCache.get(key);
  if (cached) return cached;

  const abiPath = join(repoRoot, 'abis', abiNetwork, `${contractName}.abi.json`);
  const raw = readFileSync(abiPath, 'utf8');
  const data = JSON.parse(raw);
  if (!Array.isArray(data)) throw new Error(`Invalid ABI JSON (expected array) at ${abiPath}`);

  const abi = data as Abi;
  abiCache.set(key, abi);
  return abi;
}
