import type { Address, Hash, PublicClient, WalletClient } from 'viem';

import { clampStrictSafeInteger } from '../integers.js';
import { safeErrorString } from '../security/redact.js';

export type TxReplacementPolicy = {
  /**
   * Enable fee-bumping + resubmission of the *same nonce* when a tx is not mined
   * within `timeoutMs`.
   */
  enabled: boolean;

  /**
   * How long to wait for a receipt (ms).
   *
   * - If `enabled=true`, we bump fees + resubmit after this timeout.
   * - If `enabled=false`, we throw {@link TxTimeoutError} after this timeout (no resubmission).
   *
   * Default: 45_000.
   */
  timeoutMs: number;

  /**
   * Poll interval for receipt checks (ms).
   * Default: 1_500.
   */
  pollIntervalMs: number;

  /**
   * Max total broadcast attempts (including the first).
   * Default: 3.
   */
  maxAttempts: number;

  /**
   * Multiplicative fee bump applied per attempt (in bps).
   * Must be > 10_000 to satisfy typical replacement rules.
   * Default: 12_500 (+25%).
   */
  feeBumpBps: number;
};

export const DEFAULT_TX_REPLACEMENT_POLICY: TxReplacementPolicy = {
  enabled: false,
  timeoutMs: 45_000,
  pollIntervalMs: 1_500,
  maxAttempts: 3,
  feeBumpBps: 12_500,
};

function clampFiniteInt(v: unknown, min: number, max: number, fallback: number): number {
  return clampStrictSafeInteger(v, fallback, min, max);
}

export class TxTimeoutError extends Error {
  override readonly name = 'TxTimeoutError';
  readonly nonce: bigint;
  readonly hashes: Hash[];
  readonly lastHash: Hash;

  constructor(params: { nonce: bigint; hashes: Hash[] }) {
    super(
      `Transaction not mined before timeout (nonce=${params.nonce}, attempts=${params.hashes.length})`,
    );
    this.nonce = params.nonce;
    this.hashes = params.hashes;
    this.lastHash = params.hashes[params.hashes.length - 1]!;
  }
}

export class TxRevertedError extends Error {
  override readonly name = 'TxRevertedError';
  readonly hash: Hash;

  constructor(params: { hash: Hash }) {
    super(`Transaction reverted (hash=${params.hash})`);
    this.hash = params.hash;
  }
}

function sleep(ms: number): Promise<void> {
  return new Promise((resolve) => setTimeout(resolve, ms));
}

// The `runExclusive` mutex is non-reentrant: callers must not nest
// `writeContract` inside `fn`, or the inner call will deadlock waiting on the
// outer call's lock.
//
// `allocateNonce` takes max(local cache, network pending). This is correct for
// single-agent operation. Multi-agent setups sharing the same address must
// coordinate nonces externally (e.g. via a leader-elected sender), because a
// concurrent process can claim a nonce between our cache and network sync.

function bumpByBps(v: bigint, bps: bigint): bigint {
  // ceil(v * bps / 10_000) + 1 to guarantee strictly increasing
  const num = v * bps;
  const out = (num + 9_999n) / 10_000n;
  return out > v ? out : v + 1n;
}

function extractMessage(err: unknown): string {
  const e: any = err;
  const candidates = [
    e?.shortMessage,
    e?.message,
    e?.cause?.shortMessage,
    e?.cause?.message,
    e?.cause?.cause?.message,
  ];
  for (const c of candidates) {
    if (typeof c === 'string' && c.length > 0) return safeErrorString(c);
  }
  try {
    return safeErrorString(err);
  } catch {
    return '';
  }
}

function isNonceTooLowError(err: unknown): boolean {
  const msg = extractMessage(err).toLowerCase();
  return (
    msg.includes('nonce too low') ||
    msg.includes('nonce is too low') ||
    msg.includes('nonce has already been used')
  );
}

function isNonceTooHighError(err: unknown): boolean {
  const msg = extractMessage(err).toLowerCase();
  return msg.includes('nonce too high') || msg.includes('nonce is too high');
}

function isReplacementUnderpricedError(err: unknown): boolean {
  const msg = extractMessage(err).toLowerCase();
  return (
    msg.includes('replacement transaction underpriced') ||
    (msg.includes('replacement') && msg.includes('underpriced')) ||
    msg.includes('fee too low to replace')
  );
}

function isNotFoundError(err: unknown): boolean {
  const msg = extractMessage(err);
  // viem ^2.x throws TransactionReceiptNotFoundError with shortMessage:
  //   `Transaction receipt with hash "0x…" could not be found.`
  // Earlier include-list missed this phrasing, which caused the TxManager to
  // surface the error to callers instead of continuing to poll for the
  // receipt. Treat any "not found" / "could not be found" wording as retryable.
  return (
    typeof msg === 'string' &&
    (msg.includes('TransactionReceiptNotFound') ||
      msg.includes('Transaction receipt not found') ||
      msg.includes('transaction not found') ||
      msg.includes('Transaction not found') ||
      msg.includes('Unknown transaction') ||
      msg.includes('could not be found'))
  );
}

async function waitForReceiptOrTimeout(params: {
  publicClient: PublicClient;
  hash: Hash;
  timeoutMs: number;
  pollIntervalMs: number;
}): Promise<Awaited<ReturnType<PublicClient['waitForTransactionReceipt']>> | undefined> {
  const started = Date.now();
  const safePollMs = Math.max(100, params.pollIntervalMs);
  while (true) {
    try {
      const receipt = await params.publicClient.getTransactionReceipt({ hash: params.hash });
      return receipt as any;
    } catch (err) {
      if (!isNotFoundError(err)) throw err;
    }

    if (Date.now() - started >= params.timeoutMs) return undefined;
    await sleep(safePollMs);
  }
}

type FeeParams =
  | { gasPrice: bigint; maxFeePerGas?: undefined; maxPriorityFeePerGas?: undefined }
  | { gasPrice?: undefined; maxFeePerGas: bigint; maxPriorityFeePerGas: bigint };

async function getInitialFees(
  publicClient: PublicClient,
  request: any,
): Promise<FeeParams | undefined> {
  const gasPrice = request?.gasPrice as bigint | undefined;
  const maxFeePerGas = request?.maxFeePerGas as bigint | undefined;
  const maxPriorityFeePerGas = request?.maxPriorityFeePerGas as bigint | undefined;

  if (typeof gasPrice === 'bigint') return { gasPrice };
  if (typeof maxFeePerGas === 'bigint' && typeof maxPriorityFeePerGas === 'bigint')
    return { maxFeePerGas, maxPriorityFeePerGas };

  try {
    const est = await (publicClient as any).estimateFeesPerGas?.();
    if (!est) return undefined;

    if (typeof est.gasPrice === 'bigint') return { gasPrice: est.gasPrice };
    if (typeof est.maxFeePerGas === 'bigint' && typeof est.maxPriorityFeePerGas === 'bigint') {
      return { maxFeePerGas: est.maxFeePerGas, maxPriorityFeePerGas: est.maxPriorityFeePerGas };
    }
  } catch {
    // ignore
  }

  return undefined;
}

function bumpFees(prev: FeeParams | undefined, policy: TxReplacementPolicy): FeeParams | undefined {
  if (!prev) return undefined;
  const bps = BigInt(policy.feeBumpBps);

  if ('gasPrice' in prev && typeof prev.gasPrice === 'bigint') {
    return { gasPrice: bumpByBps(prev.gasPrice, bps) };
  }

  if ('maxFeePerGas' in prev && 'maxPriorityFeePerGas' in prev) {
    return {
      maxFeePerGas: bumpByBps(prev.maxFeePerGas, bps),
      maxPriorityFeePerGas: bumpByBps(prev.maxPriorityFeePerGas, bps),
    };
  }

  return prev;
}

export type TxManagerParams = {
  /**
   * Canonical public client for receipts and fee estimates.
   */
  publicClient: PublicClient;

  /**
   * Optional additional clients for nonce discovery (e.g., private tx RPC).
   *
   * We take the max of all pending nonces to be robust across RPC providers.
   */
  nonceClients?: PublicClient[];

  /**
   * Sender address (account).
   */
  address: Address;

  /**
   * Replacement policy (fee bump + resubmit on timeout).
   */
  replacement?: Partial<TxReplacementPolicy>;
};

/**
 * Simple nonce + replacement manager for agent tx sending.
 *
 * Goals
 * - Avoid nonce collisions across public/private RPC routes.
 * - Optionally fee-bump and resubmit the same nonce when a tx is stuck.
 *
 * Notes
 * - This intentionally serializes tx sending (one in flight) to keep the agent deterministic.
 * - It caches the next nonce locally so private-mempool txs that are not visible on the public RPC
 *   do not cause repeated-nonce broadcasts.
 */
export class TxManager {
  readonly publicClient: PublicClient;
  readonly nonceClients: PublicClient[];
  readonly address: Address;
  readonly replacement: TxReplacementPolicy;

  private lock: Promise<void> = Promise.resolve();
  private nextNonce: bigint | undefined;

  constructor(p: TxManagerParams) {
    this.publicClient = p.publicClient;
    this.nonceClients = [p.publicClient, ...(p.nonceClients ?? [])];
    this.address = p.address;
    const merged: TxReplacementPolicy = {
      ...DEFAULT_TX_REPLACEMENT_POLICY,
      ...(p.replacement ?? {}),
    };

    // Hardening: clamp user-configurable timings + retry parameters to avoid
    // accidental busy loops or extreme retry storms in long-running agents.
    //
    // These bounds are intentionally conservative and can be widened in code if needed.
    merged.timeoutMs = clampFiniteInt(
      merged.timeoutMs,
      1_000,
      10 * 60_000,
      DEFAULT_TX_REPLACEMENT_POLICY.timeoutMs,
    );
    merged.pollIntervalMs = clampFiniteInt(
      merged.pollIntervalMs,
      100,
      60_000,
      DEFAULT_TX_REPLACEMENT_POLICY.pollIntervalMs,
    );
    merged.pollIntervalMs = Math.min(merged.pollIntervalMs, merged.timeoutMs);
    merged.maxAttempts = clampFiniteInt(
      merged.maxAttempts,
      1,
      10,
      DEFAULT_TX_REPLACEMENT_POLICY.maxAttempts,
    );
    merged.feeBumpBps = clampFiniteInt(
      merged.feeBumpBps,
      10_001,
      100_000,
      DEFAULT_TX_REPLACEMENT_POLICY.feeBumpBps,
    );

    this.replacement = merged;
  }

  private async runExclusive<T>(fn: () => Promise<T>): Promise<T> {
    const prev = this.lock;
    let release: () => void = () => {};
    this.lock = new Promise<void>((resolve) => {
      release = resolve;
    });
    await prev;
    try {
      return await fn();
    } finally {
      release();
    }
  }

  /**
   * Convert a getTransactionCount result to bigint.
   *
   * viem ^2.x returns `number` from getTransactionCount, not `bigint`.
   * Accept both to be resilient across viem versions and custom transports.
   */
  private static toBigIntNonce(v: unknown): bigint | undefined {
    if (typeof v === 'bigint') return v;
    if (typeof v === 'number' && Number.isFinite(v) && v >= 0) return BigInt(Math.floor(v));
    return undefined;
  }

  private async getNetworkPendingNonce(): Promise<bigint> {
    let max = 0n;

    for (const c of this.nonceClients) {
      // Some RPC providers don't support `blockTag: 'pending'`.
      // Fall back to latest, which is still better than returning 0.
      let n: bigint | undefined;

      try {
        const pending = await c.getTransactionCount({ address: this.address, blockTag: 'pending' });
        n = TxManager.toBigIntNonce(pending);
      } catch {
        // ignore
      }

      if (n === undefined) {
        try {
          const latest = await c.getTransactionCount({ address: this.address });
          n = TxManager.toBigIntNonce(latest);
        } catch {
          // ignore
        }
      }

      if (n !== undefined && n > max) max = n;
    }

    return max;
  }

  private async syncNonce(): Promise<void> {
    const net = await this.getNetworkPendingNonce();
    if (this.nextNonce === undefined || net > this.nextNonce) {
      this.nextNonce = net;
    }
  }

  private async allocateNonce(): Promise<bigint> {
    // max of (local cache, network pending). If the local cache is ahead
    // of the network (e.g. after a private mempool tx), the nonce is correct.
    // However, if a concurrent process sends a tx with a nonce between
    // our cache and the network, we will collide. Document this limitation.
    await this.syncNonce();
    if (this.nextNonce === undefined) {
      this.nextNonce = await this.getNetworkPendingNonce();
    }
    const nonce = this.nextNonce;
    if (nonce === undefined) throw new Error('Failed to allocate nonce');
    return nonce;
  }

  /**
   * Broadcast a contract write (already simulated) with managed nonce + optional replacement.
   */
  async writeContract(params: { walletClient: WalletClient; request: any }): Promise<{
    hash: Hash;
    receipt: Awaited<ReturnType<PublicClient['waitForTransactionReceipt']>>;
    meta: { nonce: bigint; attempts: number; hashes: Hash[] };
  }> {
    return await this.runExclusive(async () => {
      const maxNonceResyncAttempts = 2;

      for (let nonceAttempt = 1; nonceAttempt <= maxNonceResyncAttempts; nonceAttempt++) {
        const nonce = await this.allocateNonce();
        let fees = await getInitialFees(this.publicClient, params.request);

        const hashes: Hash[] = [];
        const maxAttempts = Math.max(1, this.replacement.maxAttempts);

        let retryWithFreshNonce = false;

        let lastBroadcastError: unknown | undefined;

        for (let attempt = 1; attempt <= maxAttempts; attempt++) {
          const req: any = { ...params.request, nonce };

          if (fees) {
            if ('gasPrice' in fees) req.gasPrice = fees.gasPrice;
            else {
              req.maxFeePerGas = fees.maxFeePerGas;
              req.maxPriorityFeePerGas = fees.maxPriorityFeePerGas;
            }
          }

          let hash: Hash;
          try {
            hash = await params.walletClient.writeContract(req);
          } catch (err) {
            lastBroadcastError = err;

            // If our nonce is stale (e.g., pending tx not visible to our nonceClients), resync and retry.
            if (isNonceTooLowError(err) || isNonceTooHighError(err)) {
              this.nextNonce = undefined;
              await this.syncNonce();

              if (nonceAttempt < maxNonceResyncAttempts) {
                retryWithFreshNonce = true;
                break;
              }
            }

            // If the node reports a replacement-underpriced error, try bumping fees and retrying.
            if (isReplacementUnderpricedError(err)) {
              if (!fees) fees = await getInitialFees(this.publicClient, req);
              fees = bumpFees(fees, this.replacement);
              continue;
            }

            this.nextNonce = undefined;
            throw err;
          }

          try {
            hashes.push(hash);

            // Commit nonce after the first successful broadcast (not just attempt 1).
            // This handles the case where the first attempt fails with "replacement underpriced"
            // but a subsequent attempt succeeds.
            if (hashes.length === 1) {
              this.nextNonce = nonce + 1n;
            }

            const receipt = await waitForReceiptOrTimeout({
              publicClient: this.publicClient,
              hash,
              timeoutMs: this.replacement.timeoutMs,
              pollIntervalMs: this.replacement.pollIntervalMs,
            });

            if (receipt) {
              if (receipt.status !== 'success') {
                throw new TxRevertedError({ hash });
              }
              // Defensive: ensure nextNonce is always ahead of confirmed nonce,
              // even if a prior receipt-polling error left the cache stale.
              if (this.nextNonce !== undefined && this.nextNonce <= nonce) {
                this.nextNonce = nonce + 1n;
              }
              return { hash, receipt, meta: { nonce, attempts: attempt, hashes } };
            }
          } catch (e) {
            if (!(e instanceof TxRevertedError)) {
              this.nextNonce = undefined;
            }
            throw e;
          }

          // Timed out. If replacement is disabled, stop immediately.
          if (!this.replacement.enabled) {
            // Clear cached nonce so the next send re-syncs from the network.
            this.nextNonce = undefined;
            throw new TxTimeoutError({ nonce, hashes });
          }

          // Prepare next attempt.
          fees = bumpFees(fees, this.replacement);
          if (!fees) {
            fees = await getInitialFees(this.publicClient, params.request);
            if (fees) fees = bumpFees(fees, this.replacement);
          }
        }

        if (retryWithFreshNonce) {
          continue;
        }

        // Exhausted attempts for this nonce.
        this.nextNonce = undefined;
        if (hashes.length === 0) {
          if (lastBroadcastError instanceof Error) throw lastBroadcastError;
          throw new Error(`Failed to broadcast transaction: ${extractMessage(lastBroadcastError)}`);
        }
        throw new TxTimeoutError({ nonce, hashes });
      }

      throw new Error('Failed to broadcast transaction (nonce sync)');
    });
  }
}
