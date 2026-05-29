import fs from 'node:fs';
import path from 'node:path';
import { isAddress, type Address } from 'viem';

// Deployment names are used to build paths like `deployments/<name>.json`.
// Restrict to a safe filename subset to prevent path traversal.
const DEPLOYMENT_NAME_RE = /^[a-zA-Z0-9_.-]{1,64}$/;
const MAX_DEPLOYMENT_MANIFEST_BYTES = 512 * 1024;

function assertSafeDeploymentName(name: string): string {
  const s = String(name ?? '').trim();
  if (!s) throw new Error('deployment name is required');
  if (s === '.' || s === '..')
    throw new Error('invalid deployment name: "." and ".." are not allowed');
  if (!DEPLOYMENT_NAME_RE.test(s)) {
    throw new Error(
      `invalid deployment name: ${s}. Allowed characters: letters, numbers, "_", ".", "-" (max 64; no slashes)`,
    );
  }
  return s;
}

export interface DeploymentManifest {
  chainId?: number;
  contracts?: Record<string, { address?: string; startBlock?: number; blockNumber?: number }>;
  [key: string]: unknown;
}

function isObject(x: unknown): x is Record<string, unknown> {
  return x != null && typeof x === 'object' && !Array.isArray(x);
}

const RESERVED_KEYS = new Set(['__proto__', 'constructor', 'prototype']);

const ZERO_ADDR: Address = '0x0000000000000000000000000000000000000000';

export function zeroAddress(): Address {
  return ZERO_ADDR;
}

export function isZeroAddress(addr: string | null | undefined): boolean {
  if (!addr) return true;
  return String(addr).toLowerCase() === ZERO_ADDR;
}

export function loadDeploymentManifest({
  repoRoot,
  deployment,
}: {
  repoRoot: string;
  deployment: string;
}): { path: string; manifest: DeploymentManifest } {
  const safe = assertSafeDeploymentName(deployment);
  const p = path.join(repoRoot, 'deployments', `${safe}.json`);
  if (!fs.existsSync(p)) {
    throw new Error(`Deployments manifest not found: ${p}`);
  }
  const st = fs.statSync(p);
  if (!st.isFile()) {
    throw new Error(`Deployments manifest path is not a regular file: ${p}`);
  }
  if (st.size > MAX_DEPLOYMENT_MANIFEST_BYTES) {
    throw new Error(
      `Deployments manifest too large: ${st.size} bytes (max ${MAX_DEPLOYMENT_MANIFEST_BYTES})`,
    );
  }
  const json = JSON.parse(fs.readFileSync(p, 'utf8')) as unknown;
  return { path: p, manifest: normalizeDeploymentManifest(json) };
}

export function getContractAddress(manifest: DeploymentManifest, contractKey: string): Address {
  if (!isObject(manifest?.contracts)) return ZERO_ADDR;
  const entry = (manifest.contracts as Record<string, Record<string, unknown>>)[contractKey];
  const addr = entry?.address;
  if (typeof addr !== 'string' || !isAddress(addr)) return ZERO_ADDR;
  return addr as Address;
}

export function getContractStartBlock(manifest: DeploymentManifest, contractKey: string): number {
  if (!isObject(manifest?.contracts)) return 0;
  const entry = (manifest.contracts as Record<string, Record<string, unknown>>)[contractKey];
  if (!isObject(entry)) return 0;

  // Most manifests use startBlock, local uses blockNumber.
  const v = entry.startBlock ?? entry.blockNumber ?? 0;
  if (typeof v === 'number') {
    return Number.isSafeInteger(v) && v >= 0 ? v : 0;
  }
  if (typeof v === 'string') {
    const parsed = parseBlockLike(v);
    return parsed ?? 0;
  }
  return 0;
}

export function requireNonZeroAddress(addr: Address, label: string): Address {
  if (isZeroAddress(addr)) {
    throw new Error(`Missing ${label} address (zero address)`);
  }
  return addr;
}

function parseBlockLike(value: unknown): number | undefined {
  if (typeof value === 'number') {
    return Number.isSafeInteger(value) && value >= 0 ? value : undefined;
  }
  if (typeof value === 'string') {
    const s = value.trim();
    if (!s) return undefined;
    if (/^\d+$/.test(s)) {
      const parsed = Number(s);
      return Number.isSafeInteger(parsed) && parsed >= 0 ? parsed : undefined;
    }
    if (/^0x[0-9a-fA-F]+$/.test(s)) {
      const parsed = BigInt(s);
      return parsed <= BigInt(Number.MAX_SAFE_INTEGER) ? Number(parsed) : undefined;
    }
    return undefined;
  }
  return undefined;
}

export function normalizeDeploymentManifest(raw: unknown): DeploymentManifest {
  if (!isObject(raw)) {
    throw new Error('deployment manifest: expected object');
  }

  const out: DeploymentManifest = Object.create(null);

  for (const [key, value] of Object.entries(raw)) {
    if (RESERVED_KEYS.has(key)) continue;
    if (key === 'contracts') continue;
    out[key] = value;
  }

  const chainId = raw.chainId;
  if (chainId !== undefined) {
    if (typeof chainId !== 'number' || !Number.isSafeInteger(chainId) || chainId <= 0) {
      throw new Error('deployment manifest.chainId: expected positive safe integer');
    }
    out.chainId = chainId;
  }

  const contractsRaw = raw.contracts;
  if (contractsRaw !== undefined) {
    if (!isObject(contractsRaw)) {
      throw new Error('deployment manifest.contracts: expected object');
    }

    const contracts: Record<
      string,
      { address?: string; startBlock?: number; blockNumber?: number }
    > = Object.create(null);

    for (const [key, value] of Object.entries(contractsRaw)) {
      if (RESERVED_KEYS.has(key)) {
        throw new Error(`deployment manifest.contracts: illegal key '${key}'`);
      }
      if (!isObject(value)) {
        throw new Error(`deployment manifest.contracts.${key}: expected object`);
      }

      const entry: { address?: string; startBlock?: number; blockNumber?: number } =
        Object.create(null);

      if (typeof value.address === 'string' && isAddress(value.address)) {
        entry.address = value.address;
      }

      const startBlock = parseBlockLike(value.startBlock);
      if (startBlock !== undefined) entry.startBlock = startBlock;

      const blockNumber = parseBlockLike(value.blockNumber);
      if (blockNumber !== undefined) entry.blockNumber = blockNumber;

      contracts[key] = entry;
    }

    out.contracts = contracts;
  }

  return out;
}
