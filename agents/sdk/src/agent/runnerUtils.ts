import fs from 'node:fs';
import path from 'node:path';

import type { Address } from 'viem';
import { parseEther } from 'viem';

export function ensureDir(p: string): void {
  fs.mkdirSync(p, { recursive: true, mode: 0o700 });
}

export function defaultOutdir(): string {
  const ts = new Date().toISOString().replace(/[:.]/g, '-');
  return path.join('out', `agent-${ts}`);
}

export function defaultStateDir(params: {
  chain: string;
  chainId: number;
  agent: Address;
  user: Address;
}): string {
  const chain = String(params.chain ?? '').trim();
  // Safety: `chain` is used as a filesystem path segment.
  // If callers bypass manifest loading by passing a manifest directly, `chain` can come from
  // untrusted config/env. Prevent path traversal or odd filesystem interactions.
  if (!chain) {
    throw new Error('defaultStateDir.chain: expected non-empty chain name');
  }
  if (!/^[a-zA-Z0-9_-]+$/.test(chain)) {
    throw new Error(
      `defaultStateDir.chain: invalid chain '${chain}' (expected /^[a-zA-Z0-9_-]+$/; example: base_sepolia)`,
    );
  }

  const who =
    params.user.toLowerCase() === params.agent.toLowerCase()
      ? params.agent
      : `${params.agent}-for-${params.user}`;
  return path.join('out', 'agent-state', chain, String(params.chainId), who);
}

export function parseIntOrUndefined(v: string | undefined): number | undefined {
  if (v === undefined) return undefined;
  const s = v.trim();
  if (!s) return undefined;
  // Accept only strict integer literals (optional sign + digits). Fractional
  // ("1.5"), exponential ("1e3"), and suffixed ("10ms") forms return
  // undefined so the caller surfaces a misconfigured env var instead of
  // coercing it to a truncated integer.
  if (!/^[+-]?\d+$/.test(s)) return undefined;
  const n = Number(s);
  if (!Number.isSafeInteger(n)) return undefined;
  return n;
}

export function parseBoolOrUndefined(v: string | undefined): boolean | undefined {
  if (v === undefined) return undefined;
  const s = v.trim().toLowerCase();
  if (!s) return undefined;
  if (s === '1' || s === 'true' || s === 'yes' || s === 'y' || s === 'on') return true;
  if (s === '0' || s === 'false' || s === 'no' || s === 'n' || s === 'off') return false;
  return undefined;
}

export function parseEthOrZero(v: string | undefined): bigint {
  if (!v) return 0n;
  const s = v.trim();
  if (!s) return 0n;
  // Canonical zero literals ('0', '00', '0.0', …) short-circuit to 0n.
  // Non-canonical forms such as '0e0' fall through to parseEther so callers
  // see a clear parsing error for malformed input.
  if (/^0+(\.0+)?$/.test(s)) return 0n;
  return parseEther(s);
}

export function parsePrivateRpcMode(v: string | undefined): 'off' | 'route' | 'only' | undefined {
  if (!v) return undefined;
  const s = v.trim().toLowerCase();
  if (s === 'off') return 'off';
  if (s === 'route') return 'route';
  if (s === 'only') return 'only';
  throw new Error(`Invalid PRIVATE_RPC_MODE: ${v}`);
}

export function parseAutoApproveMode(v: string | undefined): 'exact' | 'max' | undefined {
  if (!v) return undefined;
  const s = v.trim().toLowerCase();
  if (s === 'exact') return 'exact';
  if (s === 'max') return 'max';
  throw new Error(`Invalid AUTO_APPROVE_MODE: ${v}`);
}

export class Signal {
  private pending = false;
  private resolver: (() => void) | undefined;

  trigger(): void {
    if (this.resolver) {
      const r = this.resolver;
      this.resolver = undefined;
      r();
      return;
    }
    this.pending = true;
  }

  async wait(timeoutMs: number): Promise<'signal' | 'timeout'> {
    if (this.pending) {
      this.pending = false;
      return 'signal';
    }

    return await new Promise((resolve) => {
      const t = setTimeout(() => {
        cleanup();
        resolve('timeout');
      }, timeoutMs);

      const cleanup = () => {
        clearTimeout(t);
        this.resolver = undefined;
      };

      this.resolver = () => {
        cleanup();
        resolve('signal');
      };
    });
  }
}
