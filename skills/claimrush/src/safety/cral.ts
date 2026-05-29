import fs from 'node:fs';
import path from 'node:path';
import readline from 'node:readline';

import { parseEther, parseUnits } from 'viem';

import {
  defaultFurnaceHardCap,
  defaultTakeoverHardCap,
  maxSlippageBps,
  type ChainName,
} from './networks.js';

/**
 * Central CRAL guardrail layer. Every write command must call
 * `applyCralGuards` before sending a transaction so the safety rules from
 * `docs/manuals/developer/agents-and-automation.cral.yaml` are uniformly
 * enforced (integer-only units, dry-run default, caps, slippage, deadlines,
 * mainnet --i-understand gate).
 *
 * The guard is intentionally chatty in dry-run: it prints the parsed,
 * fully-typed numeric inputs, the hard caps it would compare against, and
 * the next step it would take. The LLM relays this to the user so a human
 * can sanity-check before ever passing `--execute`.
 */

export type CralAction =
  | 'takeover'
  | 'lock'
  | 'collect'
  | 'withdraw'
  | 'market'
  | 'plan'
  | 'agent'
  | 'session';

export type CralOptions = {
  action: CralAction;
  chain: ChainName;
  execute: boolean;
  iUnderstand: boolean;
  /** Slippage in bps (only for token / quote-based actions). */
  slippageBps?: bigint;
  /** Maximum ETH the caller is willing to spend on this single action. */
  spendCapWei?: bigint;
  /** Spend cap kind drives which env hard-cap is applied. */
  spendCapKind?: 'takeover' | 'furnace' | 'other';
  /** Tx deadline (seconds from now). */
  deadlineSeconds?: bigint;
  /** Describe acting-for user (so the receipt records identity). */
  actingForUser?: string;
};

export type CralGuardOk = {
  ok: true;
  notes: string[];
  /** Effective spend cap (after hard-cap clamp). */
  spendCapWei?: bigint;
};

export type CralGuardErr = { ok: false; reason: string };

export type CralGuardResult = CralGuardOk | CralGuardErr;

/**
 * Validate the static inputs of a command before any RPC call. Returns
 * structured ok/err so commands can `return` an error JSON without throwing
 * (helpful for chat agents that prefer error JSON over stack traces).
 *
 * NOTE: this performs synchronous checks only. Use `confirmMainnetIfNeeded`
 * separately (it may prompt) and use `requireLiveSession` for the delegated
 * permission precheck (async, requires PublicClient).
 */
export function applyCralGuards(opts: CralOptions): CralGuardResult {
  const notes: string[] = [];

  // Slippage bound (token paths only).
  if (opts.slippageBps !== undefined) {
    if (opts.slippageBps < 0n) return { ok: false, reason: 'slippage-bps must be >= 0' };
    const cap = maxSlippageBps();
    if (opts.slippageBps > cap) {
      return {
        ok: false,
        reason: `slippage-bps=${opts.slippageBps.toString()} exceeds CR_SKILL_MAX_SLIPPAGE_BPS=${cap.toString()}`,
      };
    }
    notes.push(`slippage-bps=${opts.slippageBps.toString()} (cap=${cap.toString()})`);
  }

  // Deadline bound (writes only).
  if (opts.deadlineSeconds !== undefined) {
    if (opts.deadlineSeconds < 5n || opts.deadlineSeconds > 3600n) {
      return {
        ok: false,
        reason: `deadline-seconds out of range (5..3600): ${opts.deadlineSeconds.toString()}`,
      };
    }
    notes.push(`deadline-seconds=${opts.deadlineSeconds.toString()}`);
  }

  // Spend caps with hard cap clamp.
  let effectiveCap = opts.spendCapWei;
  if (opts.spendCapWei !== undefined) {
    if (opts.spendCapWei < 0n) return { ok: false, reason: 'spend cap must be >= 0' };
    const hardCap =
      opts.spendCapKind === 'takeover'
        ? defaultTakeoverHardCap(opts.chain)
        : opts.spendCapKind === 'furnace'
          ? defaultFurnaceHardCap(opts.chain)
          : undefined;
    if (hardCap !== undefined && opts.spendCapWei > hardCap) {
      return {
        ok: false,
        reason:
          `spend cap ${opts.spendCapWei.toString()} wei exceeds hard cap ` +
          `${hardCap.toString()} wei for chain '${opts.chain}'. ` +
          `Override with CR_SKILL_MAX_${opts.spendCapKind === 'takeover' ? 'TAKEOVER' : 'FURNACE'}_ETH_HARDCAP if intentional.`,
      };
    }
    effectiveCap = hardCap !== undefined && opts.spendCapWei > hardCap ? hardCap : opts.spendCapWei;
    notes.push(`spend-cap=${effectiveCap.toString()} wei`);
  }

  // Mainnet --execute requires --i-understand.
  if (opts.execute && opts.chain === 'base' && !opts.iUnderstand) {
    return {
      ok: false,
      reason:
        '--execute on --chain base requires --i-understand to confirm you intend to send on Base mainnet.',
    };
  }

  if (!opts.execute) {
    notes.push('execute=false (dry-run; no tx will be sent)');
  } else {
    notes.push('execute=true');
    if (opts.chain === 'base') notes.push('mainnet=true (i-understand acknowledged)');
  }

  if (opts.actingForUser) notes.push(`acting-for-user=${opts.actingForUser}`);

  return { ok: true, notes, spendCapWei: effectiveCap };
}

/**
 * Optional interactive double-check for mainnet writes whose effective spend
 * exceeds 0.005 ETH. In non-TTY contexts the answer defaults to "no" so an
 * unattended caller cannot accidentally spend real ETH.
 */
export async function confirmMainnetIfNeeded(p: {
  chain: ChainName;
  execute: boolean;
  spendWei?: bigint;
  /** Skip the interactive prompt (used when caller already collected confirmation). */
  skipInteractive?: boolean;
}): Promise<{ ok: boolean; reason?: string }> {
  if (p.chain !== 'base' || !p.execute) return { ok: true };
  const threshold = parseEther('0.005');
  if ((p.spendWei ?? 0n) <= threshold) return { ok: true };

  if (p.skipInteractive) return { ok: true };
  if (!process.stdin.isTTY) {
    return {
      ok: false,
      reason:
        'mainnet write > 0.005 ETH from a non-TTY context. ' +
        'Pipe yes through stdin or run interactively to confirm.',
    };
  }

  const rl = readline.createInterface({ input: process.stdin, output: process.stderr });
  const answer: string = await new Promise((resolve) =>
    rl.question(
      `[claimrush-skill] About to spend up to ${p.spendWei!.toString()} wei on Base mainnet. Continue? [y/N] `,
      (a) => {
        rl.close();
        resolve(a.trim().toLowerCase());
      },
    ),
  );
  if (answer === 'y' || answer === 'yes') return { ok: true };
  return { ok: false, reason: 'user declined mainnet confirmation' };
}

// ---------------------------------------------------------------------------
// Integer-only unit parsing.
// ---------------------------------------------------------------------------

/**
 * Parse an ETH amount (string) to wei. Accepts only decimal strings with up
 * to 18 fractional digits; refuses scientific notation, negatives, NaN,
 * Infinity, or anything that round-trips through Number.
 */
export function parseEthStrict(input: string, label: string): bigint {
  const v = (input ?? '').trim();
  if (!/^\d+(?:\.\d{1,18})?$/.test(v)) {
    throw new Error(
      `[claimrush-skill] ${label}='${input}' is not a valid decimal ETH amount (max 18 fractional digits, no exponent).`,
    );
  }
  return parseEther(v);
}

/** Parse a token amount (raw base units OR decimal w/ explicit decimals). */
export function parseTokenStrict(input: string, decimals: number, label: string): bigint {
  const v = (input ?? '').trim();
  if (/^\d+$/.test(v)) return BigInt(v); // raw base units
  if (!/^\d+(?:\.\d{1,30})?$/.test(v)) {
    throw new Error(`[claimrush-skill] ${label}='${input}' is not a valid token amount`);
  }
  return parseUnits(v, decimals);
}

/** Parse a non-negative bigint. Refuses scientific or negative values. */
export function parseBigIntStrict(input: string, label: string): bigint {
  const v = (input ?? '').trim();
  if (!/^\d+$/.test(v)) {
    throw new Error(`[claimrush-skill] ${label}='${input}' must be a non-negative integer`);
  }
  return BigInt(v);
}

// ---------------------------------------------------------------------------
// Receipts
// ---------------------------------------------------------------------------

let cachedReceiptsDir: string | null = null;

/**
 * Resolve the per-run receipts directory. Defaults to `agents/sdk/out/skill-<ts>/`
 * to colocate with existing SDK artifacts. Override via `CR_SKILL_OUTDIR`.
 */
export function ensureReceiptsDir(repoRoot: string): string {
  if (cachedReceiptsDir) return cachedReceiptsDir;
  const env = process.env.CR_SKILL_OUTDIR?.trim();
  const base = env
    ? path.resolve(env)
    : path.join(repoRoot, 'agents/sdk/out', `skill-${new Date().toISOString().replace(/[:.]/g, '-')}`);
  fs.mkdirSync(base, { recursive: true });
  cachedReceiptsDir = base;
  return base;
}

/** Append a JSONL receipt for a command invocation. BigInt-safe. */
export function appendReceipt(repoRoot: string, name: string, payload: unknown): string {
  const dir = ensureReceiptsDir(repoRoot);
  const fp = path.join(dir, `${name}.jsonl`);
  fs.appendFileSync(fp, jsonStringify(payload) + '\n');
  return fp;
}

export function jsonStringify(value: unknown, pretty = false): string {
  return JSON.stringify(
    value,
    (_k, v) => (typeof v === 'bigint' ? v.toString() : v),
    pretty ? 2 : 0,
  );
}
