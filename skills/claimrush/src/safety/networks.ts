import { parseEther } from 'viem';

import type { AbiNetwork as SdkAbiNetwork } from '@claimrush/agent-sdk';

export type ChainName = 'local' | 'base_sepolia' | 'base';
export type AbiNetwork = SdkAbiNetwork;

const KNOWN_CHAINS: ReadonlySet<ChainName> = new Set(['local', 'base_sepolia', 'base']);

export const DEFAULT_RPC_BY_CHAIN: Record<ChainName, string> = {
  local: 'http://127.0.0.1:8545',
  base_sepolia: 'https://sepolia.base.org',
  base: 'https://mainnet.base.org',
};

export function isChainName(v: string): v is ChainName {
  return KNOWN_CHAINS.has(v as ChainName);
}

export function abiNetworkForChain(chain: ChainName): AbiNetwork {
  // Local uses the base_sepolia ABI bundle (matches deployments/local.json conventions).
  if (chain === 'base') return 'base_mainnet';
  return 'base_sepolia';
}

export type ResolveNetworkParams = {
  chain: string;
  rpcUrl?: string;
  /** When true (mainnet write path), require an allowlisted RPC URL. */
  requireAllowlistedRpc?: boolean;
  env?: NodeJS.ProcessEnv;
};

export type ResolvedNetwork = {
  chain: ChainName;
  /** Filename stem under /deployments/ (the SDK reads `<stem>.json`). */
  manifestStem: 'local' | 'base_sepolia' | 'base_mainnet';
  rpcUrl: string;
  abiNetwork: AbiNetwork;
  isMainnet: boolean;
};

export function manifestStemForChain(chain: ChainName): ResolvedNetwork['manifestStem'] {
  if (chain === 'base') return 'base_mainnet';
  return chain;
}

/**
 * Validate chain + RPC URL. Refuses unknown chains. For Base mainnet, when
 * `requireAllowlistedRpc=true`, requires the RPC to be listed in
 * `CR_SKILL_BASE_RPC_ALLOWLIST` so a typo cannot accidentally hit production.
 */
export function resolveNetwork(p: ResolveNetworkParams): ResolvedNetwork {
  const env = p.env ?? process.env;
  if (!isChainName(p.chain)) {
    throw new Error(
      `[claimrush-skill] unknown --chain '${p.chain}'. Allowed: local | base_sepolia | base.`,
    );
  }

  const rpcUrl = p.rpcUrl?.trim() || env.RPC_URL?.trim() || DEFAULT_RPC_BY_CHAIN[p.chain];
  if (!rpcUrl) {
    throw new Error(`[claimrush-skill] no RPC_URL resolved for chain '${p.chain}'`);
  }

  const isMainnet = p.chain === 'base';

  if (isMainnet && p.requireAllowlistedRpc) {
    const raw = (env.CR_SKILL_BASE_RPC_ALLOWLIST ?? '').trim();
    if (!raw) {
      throw new Error(
        `[claimrush-skill] mainnet writes require CR_SKILL_BASE_RPC_ALLOWLIST. ` +
          `Set it to a comma-separated list of allowed RPC URLs before passing --execute on --chain base.`,
      );
    }
    const allow = raw
      .split(',')
      .map((s) => s.trim())
      .filter(Boolean);
    if (!allow.includes(rpcUrl)) {
      throw new Error(
        `[claimrush-skill] RPC '${rpcUrl}' is not in CR_SKILL_BASE_RPC_ALLOWLIST. ` +
          `Refusing to send mainnet writes through an unrecognised endpoint.`,
      );
    }
  }

  return {
    chain: p.chain,
    manifestStem: manifestStemForChain(p.chain),
    rpcUrl,
    abiNetwork: abiNetworkForChain(p.chain),
    isMainnet,
  };
}

/** Hard caps applied per-chain. */
export function defaultTakeoverHardCap(chain: ChainName, env: NodeJS.ProcessEnv = process.env): bigint {
  const explicit = env.CR_SKILL_MAX_TAKEOVER_ETH_HARDCAP?.trim();
  if (explicit) return parseEther(explicit);
  return chain === 'base' ? parseEther('0.05') : parseEther('1');
}

export function defaultFurnaceHardCap(chain: ChainName, env: NodeJS.ProcessEnv = process.env): bigint {
  const explicit = env.CR_SKILL_MAX_FURNACE_ETH_HARDCAP?.trim();
  if (explicit) return parseEther(explicit);
  return chain === 'base' ? parseEther('1') : parseEther('100');
}

export function maxSlippageBps(env: NodeJS.ProcessEnv = process.env): bigint {
  const explicit = env.CR_SKILL_MAX_SLIPPAGE_BPS?.trim();
  if (explicit) {
    const n = BigInt(explicit);
    if (n < 0n || n > 10_000n) {
      throw new Error(`[claimrush-skill] CR_SKILL_MAX_SLIPPAGE_BPS out of range: ${explicit}`);
    }
    return n;
  }
  return 200n;
}
