import { readFileSync } from 'node:fs';
import { join } from 'node:path';

import { isAddress, type Address } from 'viem';

import { findRepoRoot } from './repoRoot.js';

export type ManifestContractRef = {
  address: Address;
  startBlock: number;
};

export type DeploymentManifest = {
  name: string;
  version: string;
  chain: string;
  chainId: number;
  generatedAtUtc: string;
  notes?: string[];
  analytics?: unknown;
  contracts: Record<string, ManifestContractRef>;
};

export type LoadDeploymentManifestParams = {
  /** Manifest file stem in `/deployments/`, e.g. `local`, `base_sepolia`. */
  chain: string;
  /** Optional explicit repo root. If omitted, auto-detect by walking up from process.cwd(). */
  repoRoot?: string;
};

function toAddressOrThrow(value: unknown, ctx: string): Address {
  if (typeof value !== 'string') throw new Error(`${ctx}: expected string address`);
  if (!isAddress(value)) throw new Error(`${ctx}: invalid address ${value}`);
  return value as Address;
}

function toNumberOrThrow(value: unknown, ctx: string): number {
  if (typeof value !== 'number' || Number.isNaN(value)) throw new Error(`${ctx}: expected number`);
  return value;
}

function validateChainStem(chain: string): string {
  const stem = String(chain ?? '').trim();
  if (!stem) throw new Error('manifest.chain: expected non-empty chain name');
  // regex already constrains the character set, a very long stem could cause
  // filesystem issues (PATH_MAX) or unexpected log bloat.
  if (stem.length > 128) {
    throw new Error(`manifest.chain: chain name too long (${stem.length} > 128)`);
  }

  // Prevent path traversal and weird filesystem interactions.
  // This is a *filename stem* under /deployments, not an arbitrary path.
  if (!/^[a-zA-Z0-9_-]+$/.test(stem)) {
    throw new Error(
      `manifest.chain: invalid chain name '${stem}' (expected /^[a-zA-Z0-9_-]+$/; example: base_sepolia)`,
    );
  }

  return stem;
}

const RESERVED_KEYS = new Set(['__proto__', 'prototype', 'constructor']);

function validateContractKey(k: string, ctx: string): string {
  const name = String(k ?? '').trim();
  if (!name) throw new Error(`${ctx}: empty contract name`);

  // Avoid prototype mutation hazards when populating plain JS objects.
  if (RESERVED_KEYS.has(name)) {
    throw new Error(`${ctx}: illegal contract name '${name}'`);
  }

  // Contract names are simple keys (used in logs + ABI file name resolution).
  if (!/^[a-zA-Z0-9_-]+$/.test(name)) {
    throw new Error(
      `${ctx}: invalid contract name '${name}' (expected /^[a-zA-Z0-9_-]+$/; example: MineCore)`,
    );
  }

  return name;
}

/**
 * Load and minimally validate a deployment manifest from `/deployments/<chain>.json`.
 */
export function loadDeploymentManifest(params: LoadDeploymentManifestParams): DeploymentManifest {
  const repoRoot = params.repoRoot ?? findRepoRoot();
  const chainStem = validateChainStem(params.chain);
  const manifestPath = join(repoRoot, 'deployments', `${chainStem}.json`);
  const raw = readFileSync(manifestPath, 'utf8');
  const data = JSON.parse(raw) as Partial<DeploymentManifest>;

  if (!data || typeof data !== 'object') throw new Error(`Invalid JSON at ${manifestPath}`);

  const name = typeof data.name === 'string' ? data.name : 'ClaimRush';
  const version = typeof data.version === 'string' ? data.version : 'unknown';
  const chain = typeof data.chain === 'string' ? data.chain : chainStem;
  const chainId = toNumberOrThrow((data as any).chainId, `manifest.chainId (${manifestPath})`);
  const generatedAtUtc =
    typeof (data as any).generatedAtUtc === 'string' ? (data as any).generatedAtUtc : '';

  const contractsObj = (data as any).contracts;
  if (!contractsObj || typeof contractsObj !== 'object') {
    throw new Error(`manifest.contracts missing or invalid (${manifestPath})`);
  }

  // Use a null-prototype object to avoid surprises with '__proto__' keys.
  const contracts: Record<string, ManifestContractRef> = Object.create(null);

  for (const [k, v] of Object.entries(contractsObj)) {
    const contractName = validateContractKey(k, `manifest.contracts key (${manifestPath})`);

    const addr = toAddressOrThrow(
      (v as any).address,
      `manifest.contracts.${contractName}.address (${manifestPath})`,
    );
    const startBlock = toNumberOrThrow(
      (v as any).startBlock ?? 0,
      `manifest.contracts.${contractName}.startBlock (${manifestPath})`,
    );
    contracts[contractName] = { address: addr, startBlock };
  }

  return {
    name,
    version,
    chain,
    chainId,
    generatedAtUtc,
    notes: Array.isArray((data as any).notes) ? (data as any).notes : undefined,
    analytics: (data as any).analytics,
    contracts,
  };
}

export function getContractAddress(manifest: DeploymentManifest, contractName: string): Address {
  const ref = manifest.contracts[contractName];
  if (!ref) throw new Error(`Contract not found in manifest: ${contractName}`);
  return ref.address;
}

/**
 * Safety: ensure the deployment manifest chainId matches the connected RPC chainId.
 *
 * Why: using a manifest for the wrong chain can cause writes to go to arbitrary addresses,
 * including EOAs on the target chain (native value can be irreversibly transferred).
 */
export function assertManifestChainId(
  manifest: DeploymentManifest,
  actualChainId: number,
  ctx: string,
  opts?: { allowMismatch?: boolean },
): void {
  const allow = opts?.allowMismatch ?? false;
  if (!Number.isFinite(actualChainId)) {
    throw new Error(`${ctx}: invalid chainId from RPC: ${String(actualChainId)}`);
  }

  const expected = manifest.chainId;
  if (expected !== actualChainId && !allow) {
    const chainLabel = manifest.chain ? ` (${manifest.chain})` : '';
    throw new Error(
      `${ctx}: chainId mismatch (manifest=${expected}${chainLabel}, rpc=${actualChainId}). ` +
        `Refusing to continue. If this is intentional (e.g. a fork with a custom chainId), ` +
        `set allowChainIdMismatch=true or ALLOW_CHAIN_ID_MISMATCH=1.`,
    );
  }
}
