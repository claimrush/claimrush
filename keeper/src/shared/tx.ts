import type { Address, Hex, PublicClient, WalletClient } from 'viem';
import type { PrivateKeyAccount } from 'viem/accounts';

import type { KeeperConfig } from './config.js';
import { postAlert } from './alert.js';
import { getPauseInfo } from './pause.js';
import {
  assertCircuitBreakerStateHealthy,
  getCircuitBreakerPauseInfo,
  recordTxFailure,
  recordTxSuccess,
} from './circuit_breaker.js';
import { assertKeeperEoaPayoutBound } from './payout_bound.js';
import { nowUtcIso } from './state.js';
import { parseNonNegativeSafeInteger, parsePositiveSafeInteger } from './utils.js';

export type SendTxSkipCode =
  | 'paused'
  | 'dry_run'
  | 'pending_guard'
  | 'fee_cap'
  | 'gas_limit_cap'
  | 'total_fee_cap'
  | 'unknown';

export type SendTxResult =
  | {
      ok: true;
      hash: Hex;
      receipt: unknown;
      gasLimit: bigint;
      maxFeePerGasWei: bigint | null;
      maxPriorityFeePerGasWei: bigint | null;
      /// Non-null when the post-tx EOA-balance audit detected an unexpected
      /// inflow / outflow vs `gasUsed * effectiveGasPrice`. The tx still
      /// confirmed (hence `ok: true`), but a violation MUST trip the circuit
      /// breaker and post a `keeper_payout_bound_violation` alert.
      payoutBoundViolation: {
        reason: string;
        balanceDeltaWei: bigint;
        totalCostWei: bigint;
      } | null;
    }
  | { ok: false; skipped: true; reason: string; code: SendTxSkipCode };

type WalletRequestFn = (args: { method: string; params?: unknown[] }) => Promise<unknown>;

class PendingTxGuardError extends Error {
  latestNonce: bigint;
  pendingNonce: bigint;

  constructor({ latestNonce, pendingNonce }: { latestNonce: bigint; pendingNonce: bigint }) {
    super(
      `pending tx guard: pendingNonce=${pendingNonce.toString()} latestNonce=${latestNonce.toString()} (set KEEPER_ALLOW_TX_WHILE_PENDING=1 to override)`,
    );
    this.name = 'PendingTxGuardError';
    this.latestNonce = latestNonce;
    this.pendingNonce = pendingNonce;
  }
}

function fmtErr(e: unknown): string {
  const errObj = e as { shortMessage?: string; message?: string };
  return String(errObj?.shortMessage ?? errObj?.message ?? e);
}

// C-2 (2026-04-17): viem + many RPCs surface tx `nonce` as bigint, hex string, or
// decimal string. The old replaced-tx detection only ran when `typeof nonce === 'number'`,
// so bigint/string nonces were silently skipped and tx polling hit the full timeout.
export function toTxNonce(raw: unknown): bigint | null {
  if (raw == null) return null;
  if (typeof raw === 'bigint') return raw >= 0n ? raw : null;
  if (typeof raw === 'number') {
    if (!Number.isSafeInteger(raw) || raw < 0) return null;
    return BigInt(raw);
  }
  if (typeof raw === 'string') {
    const trimmed = raw.trim();
    if (trimmed.length === 0) return null;
    try {
      const parsed = BigInt(trimmed);
      return parsed >= 0n ? parsed : null;
    } catch {
      return null;
    }
  }
  return null;
}

function isFeeCapTooLowErrorMessage(msg: string): boolean {
  const m = String(msg ?? '').toLowerCase();
  return (
    m.includes('max fee per gas less than block base fee') ||
    m.includes('max fee per gas less than base fee') ||
    m.includes('fee cap too low') ||
    (m.includes('base fee') && m.includes('exceeds') && m.includes('max fee'))
  );
}

async function sleep(ms: number): Promise<void> {
  await new Promise((resolve) => setTimeout(resolve, ms));
}

function getWalletRequestFn(walletClient: WalletClient): WalletRequestFn | null {
  const req = (walletClient as any)?.request as WalletRequestFn | undefined;
  return typeof req === 'function' ? req : null;
}

function isReceiptNotFoundError(e: unknown): boolean {
  const name = String((e as any)?.name ?? '');
  if (name.includes('NotFound')) return true;
  const msg = fmtErr(e).toLowerCase();
  return (
    msg.includes('not found') ||
    (msg.includes('receipt') && msg.includes('not') && msg.includes('found'))
  );
}

function receiptStatusOk(receipt: any): boolean | null {
  const st = receipt?.status;
  if (st == null) return null;

  if (st === 'success') return true;
  if (st === 'reverted') return false;

  if (typeof st === 'boolean') return st;

  if (typeof st === 'number') {
    if (st === 1) return true;
    if (st === 0) return false;
  }

  if (typeof st === 'bigint') {
    if (st === 1n) return true;
    if (st === 0n) return false;
  }

  if (typeof st === 'string') {
    const s = st.trim().toLowerCase();
    if (s === '0x1' || s === '0x01' || s === '1' || s === 'true') return true;
    if (s === '0x0' || s === '0x00' || s === '0' || s === 'false') return false;
  }

  return null;
}

async function tryGetReceiptViaWalletRpc({
  walletClient,
  hash,
}: {
  walletClient: WalletClient;
  hash: Hex;
}): Promise<any | null> {
  const req = getWalletRequestFn(walletClient);
  if (!req) return null;

  try {
    const r = await req({ method: 'eth_getTransactionReceipt', params: [hash] });
    return r ?? null;
  } catch (e) {
    if (isReceiptNotFoundError(e)) return null;
    return null;
  }
}

async function tryGetBlockNumberViaWalletRpc(walletClient: WalletClient): Promise<bigint | null> {
  const req = getWalletRequestFn(walletClient);
  if (!req) return null;

  try {
    const raw = await req({ method: 'eth_blockNumber', params: [] });
    if (raw == null) return null;
    return BigInt(raw as any);
  } catch {
    return null;
  }
}

async function tryGetBlockHashViaWalletRpc({
  walletClient,
  blockNumber,
}: {
  walletClient: WalletClient;
  blockNumber: bigint;
}): Promise<Hex | null> {
  const req = getWalletRequestFn(walletClient);
  if (!req) return null;

  // eth_getBlockByNumber expects a hex quantity (or "latest") and a boolean for full tx objects.
  const bnHex = `0x${blockNumber.toString(16)}`;

  try {
    const raw = await req({ method: 'eth_getBlockByNumber', params: [bnHex, false] });
    const h = (raw as any)?.hash;
    return typeof h === 'string' && h.startsWith('0x') ? (h as Hex) : null;
  } catch {
    return null;
  }
}

async function waitForReceiptWithConfirmations({
  publicClient,
  walletClient,
  hash,
  confirmations,
  timeoutMs,
  pollingIntervalMs,
}: {
  publicClient: PublicClient;
  walletClient?: WalletClient | null;
  hash: Hex;
  confirmations: number;
  timeoutMs: number;
  pollingIntervalMs: number;
}): Promise<any> {
  const start = Date.now();

  const conf = parsePositiveSafeInteger(confirmations, { defaultValue: 1 }) ?? 1;
  const pollMs = Math.max(
    50,
    parseNonNegativeSafeInteger(pollingIntervalMs, { defaultValue: 0 }) ?? 0,
  );

  // We intentionally prefer public RPC for reads/receipts (canonical read side),
  // but can fall back to the wallet RPC (tx submission side) for resilience when
  // the public RPC is lagging or degraded.
  let receipt: any | null = null;
  let sawReceipt = false;
  let lastErr: string | null = null;

  const tryGetReceiptAny = async (): Promise<any | null> => {
    try {
      const r = await publicClient.getTransactionReceipt({ hash } as any);
      return r ?? null;
    } catch (e) {
      if (!isReceiptNotFoundError(e)) lastErr = fmtErr(e);
    }

    if (walletClient) {
      const r = await tryGetReceiptViaWalletRpc({ walletClient, hash });
      return r ?? null;
    }

    return null;
  };

  const tryGetTipWithSource = async (): Promise<{
    tip: bigint | null;
    source: 'public' | 'wallet' | null;
  }> => {
    try {
      const tip = await publicClient.getBlockNumber();
      return { tip: BigInt(tip as any), source: 'public' };
    } catch (e) {
      lastErr = fmtErr(e);
    }

    if (walletClient) {
      const tip = await tryGetBlockNumberViaWalletRpc(walletClient);
      if (tip != null) return { tip, source: 'wallet' };
    }

    return { tip: null, source: null };
  };

  const tryGetCanonicalBlockHash = async (
    blockNumber: bigint,
    prefer: 'public' | 'wallet' | null,
  ): Promise<Hex | null> => {
    // If the tip came from wallet RPC, prefer that for the canonical hash check.
    if (prefer === 'wallet' && walletClient) {
      const h = await tryGetBlockHashViaWalletRpc({ walletClient, blockNumber });
      if (h) return h;
    }

    try {
      const blk: any = await publicClient.getBlock({ blockNumber } as any);
      const h = (blk as any)?.hash;
      return typeof h === 'string' && h.startsWith('0x') ? (h as Hex) : null;
    } catch {
      // Fall back to wallet RPC only if we haven't already tried it.
      if (walletClient && prefer !== 'wallet') {
        const h = await tryGetBlockHashViaWalletRpc({ walletClient, blockNumber });
        if (h) return h;
      }
      return null;
    }
  };

  while (Date.now() - start < timeoutMs) {
    // Stage 1: wait for a receipt.
    if (!receipt) {
      // If enough time has passed without a receipt, check whether the nonce
      // has advanced (tx replaced/dropped). This prevents hanging for the full
      // timeout on replaced txs which would otherwise trip the circuit breaker.
      const elapsed = Date.now() - start;
      if (elapsed > Math.min(timeoutMs / 3, 60_000)) {
        try {
          const txData = await publicClient.getTransaction({ hash } as any).catch(() => null);
          // C-2 (2026-04-17): normalize nonce across number / bigint / hex-string /
          // decimal-string shapes so the replaced-tx detection actually fires on
          // viem-based clients and RPCs that return non-number nonces.
          const txNonce = txData ? toTxNonce((txData as any).nonce) : null;
          if (txNonce != null) {
            const currentNonce = await publicClient
              .getTransactionCount({
                address: (txData as any).from,
                blockTag: 'latest',
              } as any)
              .then((n: any) => BigInt(n))
              .catch(() => null);
            if (currentNonce != null && currentNonce > txNonce) {
              throw new Error(
                `tx ${hash} likely replaced or dropped: nonce ${txNonce.toString()} already consumed (current=${currentNonce.toString()})`,
              );
            }
          }
        } catch (e: unknown) {
          if (String((e as Error)?.message ?? '').includes('likely replaced')) throw e;
          // Best-effort; continue polling on other errors.
        }
      }
      const r = await tryGetReceiptAny();
      if (!r) {
        await sleep(pollMs);
        continue;
      }

      receipt = r;
      sawReceipt = true;

      if (conf <= 1) return receipt;
    }

    // Stage 2: wait for confirmations, with reorg tolerance.
    let minedAt: bigint;
    try {
      minedAt = BigInt((receipt as any)?.blockNumber ?? 0n);
    } catch {
      minedAt = 0n;
    }

    // If we can't parse a block number, return the receipt rather than hanging forever.
    if (minedAt <= 0n) return receipt;

    const target = minedAt + BigInt(conf - 1);

    const { tip, source } = await tryGetTipWithSource();
    if (tip == null) {
      await sleep(pollMs);
      continue;
    }

    if (tip < target) {
      await sleep(pollMs);
      continue;
    }

    // Tip has advanced beyond the target confirmations for *our current* receipt.
    // Re-fetch the receipt to ensure it is still present (reorg-safe) and to pick
    // up a new mined block if the tx was re-included.
    const fresh = await tryGetReceiptAny();
    if (!fresh) {
      // Receipt disappeared: likely a reorg, replacement, or RPC inconsistency.
      // Reset and go back to waiting for a receipt within the same timeout budget.
      receipt = null;
      await sleep(pollMs);
      continue;
    }

    let freshBn: bigint;
    try {
      freshBn = BigInt((fresh as any)?.blockNumber ?? 0n);
    } catch {
      freshBn = 0n;
    }
    if (freshBn <= 0n) return fresh;

    const freshTarget = freshBn + BigInt(conf - 1);

    // If the tx was re-mined to a later block, we need to wait for confirmations again.
    if (tip < freshTarget) {
      receipt = fresh;
      await sleep(pollMs);
      continue;
    }

    // Canonicality check: ensure the receipt's block hash matches the canonical
    // block hash on the node that supplied the tip. This helps detect transient
    // fork mismatches between public and private RPC endpoints.
    const bh = (fresh as any)?.blockHash;
    if (typeof bh === 'string' && bh.startsWith('0x')) {
      const canonical = await tryGetCanonicalBlockHash(freshBn, source);
      if (canonical && canonical.toLowerCase() !== bh.toLowerCase()) {
        // Not canonical on the tip source; wait for RPCs to converge.
        receipt = null;
        await sleep(pollMs);
        continue;
      }
    }

    return fresh;
  }

  if (!sawReceipt) {
    throw new Error(
      `tx receipt timeout after ${timeoutMs}ms: ${hash}${lastErr ? ` (lastError=${lastErr})` : ''}`,
    );
  }

  const hint = receipt ? '' : ' (receipt disappeared; possible reorg/RPC inconsistency)';
  throw new Error(
    `tx confirmations timeout after ${timeoutMs}ms (need ${conf}): ${hash}${hint}${lastErr ? ` (lastError=${lastErr})` : ''}`,
  );
}

async function pendingGuard({
  config,
  publicClient,
  walletClient,
  address,
}: {
  config: KeeperConfig;
  publicClient: PublicClient;
  walletClient: WalletClient;
  address: Address;
}): Promise<void> {
  if (config.allowTxWhilePending) return;

  let latest: unknown = null;
  let pending: unknown = null;

  const req = getWalletRequestFn(walletClient);

  if (req) {
    try {
      [latest, pending] = await Promise.all([
        req({ method: 'eth_getTransactionCount', params: [address, 'latest'] }),
        req({ method: 'eth_getTransactionCount', params: [address, 'pending'] }),
      ]);
    } catch {
      latest = null;
      pending = null;
    }
  }

  if (latest == null || pending == null) {
    [latest, pending] = await Promise.all([
      publicClient.getTransactionCount({ address, blockTag: 'latest' } as any),
      publicClient.getTransactionCount({ address, blockTag: 'pending' } as any),
    ]);
  }

  let latestN: bigint;
  let pendingN: bigint;
  try {
    latestN = BigInt(latest as any);
    pendingN = BigInt(pending as any);
  } catch {
    throw new Error(
      `pending guard: could not parse nonce counts (latest=${String(latest)}, pending=${String(pending)})`,
    );
  }

  if (pendingN > latestN) {
    throw new PendingTxGuardError({ latestNonce: latestN, pendingNonce: pendingN });
  }
}

export async function sendContractTx({
  config,
  publicClient,
  walletClient,
  account,
  address,
  abi,
  functionName,
  args,
  value,
  minGasLimit,
  log,
  context,
}: {
  config: KeeperConfig;
  publicClient: PublicClient;
  walletClient: WalletClient;
  account: PrivateKeyAccount;
  address: Address;
  abi: unknown;
  functionName: string;
  args: unknown[];
  value?: bigint | null;
  minGasLimit?: bigint | null;
  log?: ((msg: string) => void) | null;
  context?: string | null;
}): Promise<SendTxResult> {
  const pause = getPauseInfo(config);
  if (pause.paused) {
    const reason = `paused (${pause.source ?? 'unknown'}): ${pause.reason ?? 'n/a'}${
      pause.untilUtc ? ` (until ${pause.untilUtc})` : ''
    }`;
    if (log) log(reason);
    return { ok: false, skipped: true, reason, code: 'paused' };
  }

  // Hard stop if dry-run is enabled.
  if (config.dryRun) {
    const reason = 'dry-run: tx submission disabled';
    if (log) log(reason);
    return { ok: false, skipped: true, reason, code: 'dry_run' };
  }

  // Treat the circuit breaker state file as trusted safety input. If it is
  // unreadable/corrupt, fail closed before we submit any new transaction.
  if (config.circuitBreakerEnabled) {
    const breakerState = assertCircuitBreakerStateHealthy(config);
    const breakerPause = getCircuitBreakerPauseInfo(config, breakerState);
    if (breakerPause.paused) {
      const reason = `paused (${breakerPause.source ?? 'unknown'}): ${breakerPause.reason ?? 'n/a'}${
        breakerPause.untilUtc ? ` (until ${breakerPause.untilUtc})` : ''
      }`;
      if (log) log(reason);
      return { ok: false, skipped: true, reason, code: 'paused' };
    }
  }

  // Guard against pending nonce buildup.
  try {
    await pendingGuard({ config, publicClient, walletClient, address: account.address as Address });
  } catch (e: unknown) {
    // Pending tx is an expected state (e.g. after a restart). Treat as a skip so
    // tasks don't record offer/listing backoff or spam alerts.
    if (e instanceof PendingTxGuardError) {
      const reason = fmtErr(e);
      if (log) log(`SKIP: ${reason}`);
      return { ok: false, skipped: true, reason, code: 'pending_guard' };
    }
    throw e;
  }

  // Fee-cap precheck: if the current base fee already exceeds our configured maxFeePerGas,
  // skip rather than attempting a tx that will be rejected or never included.
  if (config.txMaxFeePerGasWei != null) {
    try {
      const blk: any = await publicClient.getBlock({ blockTag: 'latest' } as any);
      const rawBase = (blk as any)?.baseFeePerGas;
      let baseWei: bigint | null = null;
      try {
        if (rawBase != null) baseWei = BigInt(rawBase as any);
      } catch {
        baseWei = null;
      }

      if (baseWei != null && baseWei > config.txMaxFeePerGasWei) {
        const reason = `tx fee cap too low: baseFeePerGas=${baseWei.toString()} wei > maxFeePerGas=${config.txMaxFeePerGasWei.toString()} wei`;
        if (log) log(`SKIP: ${reason}`);
        return { ok: false, skipped: true, reason, code: 'fee_cap' };
      }
    } catch (e: unknown) {
      // Best-effort only. If we cannot fetch the block/base fee, do not block tx submission.
      if (log) log(`WARN: could not check baseFeePerGas: ${fmtErr(e)}`);
    }
  }

  // L4-2 (2026-04-17): route `estimateContractGas` failures through the circuit
  // breaker. Previously an estimator throw would escape `sendContractTx` before
  // the outer `try { writeContract } catch { recordTxFailure }` could see it,
  // so repeated estimator failures never tripped the breaker.
  let gasEstimate: bigint;
  try {
    gasEstimate = (await publicClient.estimateContractGas({
      address,
      abi: abi as any,
      functionName: functionName as any,
      args: args as any,
      account,
      ...(value != null ? { value } : {}),
    })) as bigint;
  } catch (estErr: unknown) {
    const estMsg = fmtErr(estErr);
    // Fee-cap-too-low during estimation is a config rail, not a pipeline failure.
    if (isFeeCapTooLowErrorMessage(estMsg)) {
      const reason = `tx fee cap too low (estimate): ${estMsg}`;
      if (log) log(`SKIP: ${reason}`);
      return { ok: false, skipped: true, reason, code: 'fee_cap' };
    }
    try {
      const { tripped } = recordTxFailure({ config, error: estMsg });
      if (tripped && log) log(`circuit breaker tripped by estimator failure: ${estMsg}`);
    } catch (stateErr: unknown) {
      const stateMsg = fmtErr(stateErr);
      if (log) log(`FATAL: estimator failure could not update breaker state: ${stateMsg}`);
    }
    throw estErr;
  }

  const est = BigInt(gasEstimate as any);
  const mult = BigInt(config.txGasLimitMultiplierBps);
  const estimatedGasLimit = (est * mult + 9_999n) / 10_000n;
  const gasFloor = minGasLimit != null && minGasLimit > 0n ? minGasLimit : 0n;
  const gasLimit = estimatedGasLimit < gasFloor ? gasFloor : estimatedGasLimit;

  if (log)
    log(
      `tx gas: estimate=${est.toString()} gasLimit=${gasLimit.toString()} multBps=${config.txGasLimitMultiplierBps}${
        gasFloor > 0n ? ` floor=${gasFloor.toString()}` : ''
      }${context ? ` ctx=${context}` : ''}`,
    );

  // Optional max gas limit rail (gas units). Prevents pathological estimates from submitting huge transactions.
  if (config.txMaxGasLimit != null && gasLimit > config.txMaxGasLimit) {
    const reason = `tx max gas limit exceeded: gasLimit=${gasLimit.toString()} cap=${config.txMaxGasLimit.toString()}`;
    if (log) log(`SKIP: ${reason}`);
    return { ok: false, skipped: true, reason, code: 'gas_limit_cap' };
  }

  // Optional max total fee (worst case) rail.
  if (config.txMaxTotalFeeWei != null && config.txMaxFeePerGasWei != null) {
    const worst = gasLimit * config.txMaxFeePerGasWei;
    if (worst > config.txMaxTotalFeeWei) {
      const reason = `tx max total fee exceeded: worst=${worst.toString()} wei cap=${config.txMaxTotalFeeWei.toString()} wei`;
      if (log) log(`SKIP: ${reason}`);
      return { ok: false, skipped: true, reason, code: 'total_fee_cap' };
    }
  }

  if (config.txMaxFeePerGasWei != null) {
    try {
      const blk2: any = await publicClient.getBlock({ blockTag: 'latest' } as any);
      const rawBase2 = (blk2 as any)?.baseFeePerGas;
      let baseWei2: bigint | null = null;
      try {
        if (rawBase2 != null) baseWei2 = BigInt(rawBase2 as any);
      } catch {
        baseWei2 = null;
      }

      if (baseWei2 != null && baseWei2 > config.txMaxFeePerGasWei) {
        const reason = `tx fee cap too low (post-estimate recheck): baseFeePerGas=${baseWei2.toString()} wei > maxFeePerGas=${config.txMaxFeePerGasWei.toString()} wei`;
        if (log) log(`SKIP: ${reason}`);
        return { ok: false, skipped: true, reason, code: 'fee_cap' };
      }
    } catch (e: unknown) {
      if (log) log(`WARN: post-estimate baseFee recheck failed: ${fmtErr(e)}`);
    }
  }

  // Re-check pause state immediately before submission to close the TOCTOU
  // window between the initial check and writeContract. Gas estimation +
  // fee cap checks can take several seconds, during which an operator or
  // the circuit breaker may have paused the keeper.
  const pauseRecheck = getPauseInfo(config);
  if (pauseRecheck.paused) {
    const reason = `paused (recheck, ${pauseRecheck.source ?? 'unknown'}): ${pauseRecheck.reason ?? 'n/a'}${
      pauseRecheck.untilUtc ? ` (until ${pauseRecheck.untilUtc})` : ''
    }`;
    if (log) log(reason);
    return { ok: false, skipped: true, reason, code: 'paused' };
  }

  if (config.circuitBreakerEnabled) {
    const breakerRecheck = assertCircuitBreakerStateHealthy(config);
    const breakerPauseRecheck = getCircuitBreakerPauseInfo(config, breakerRecheck);
    if (breakerPauseRecheck.paused) {
      const reason = `paused (recheck, ${breakerPauseRecheck.source ?? 'unknown'}): ${breakerPauseRecheck.reason ?? 'n/a'}${
        breakerPauseRecheck.untilUtc ? ` (until ${breakerPauseRecheck.untilUtc})` : ''
      }`;
      if (log) log(reason);
      return { ok: false, skipped: true, reason, code: 'paused' };
    }
  }

  const req: any = {
    address,
    abi,
    functionName,
    args,
    account,
    gas: gasLimit,
  };

  if (value != null) req.value = value;

  if (config.txMaxFeePerGasWei != null) req.maxFeePerGas = config.txMaxFeePerGasWei;
  if (config.txMaxPriorityFeePerGasWei != null)
    req.maxPriorityFeePerGas = config.txMaxPriorityFeePerGasWei;

  let hash: Hex | null = null;

  // Snapshot the EOA balance immediately before submission so the post-tx
  // payout-bound audit can verify `delta == -gasSpent`. A null snapshot here
  // (RPC failure, etc.) disables the audit for this tx but never blocks the
  // submission — the audit is defense-in-depth, not a precondition.
  let balanceBeforeWei: bigint | null = null;
  try {
    balanceBeforeWei = await publicClient.getBalance({ address: account.address as Address });
  } catch (balErr: unknown) {
    if (log)
      log(
        `WARN: pre-tx EOA balance read failed: ${fmtErr(balErr)} (payout-bound audit disabled for this tx)`,
      );
  }

  try {
    hash = (await walletClient.writeContract(req)) as Hex;
    if (log) log(`tx submitted: ${hash}${context ? ` ctx=${context}` : ''}`);

    const receipt: any = await waitForReceiptWithConfirmations({
      publicClient,
      walletClient,
      hash,
      confirmations: config.txConfirmations,
      timeoutMs: config.txReceiptTimeoutMs,
      pollingIntervalMs: 2000,
    });

    // C-1 (2026-04-17): unknown receipt status is treated as failure, not success.
    // Previously `if (ok === false)` let null/unknown fall through to recordTxSuccess,
    // clearing the circuit breaker on malformed RPC payloads. Now any non-`true`
    // result (reverted OR indeterminate) throws and is routed through recordTxFailure.
    const ok = receiptStatusOk(receipt);
    if (ok !== true) {
      const reason = ok === false ? 'reverted' : 'status unknown';
      throw new Error(`tx ${reason}: ${hash}`);
    }

    // Payout-bound audit. The on-chain entry points the keeper calls
    // (harvestFeesToRewards, compoundFor, claimShareholderFor, ...) never pay
    // msg.sender — every payout routes to the user, vault, or protocol. The
    // EOA balance must therefore drop by exactly the total tx cost. On L1
    // chains that's `gasUsed * effectiveGasPrice`; on OP-stack chains (Base,
    // Optimism, …) the EOA also pays `receipt.l1Fee` for posting the tx
    // calldata to L1 at execution time. The total cost is the sum of both.
    //
    // Anything else indicates a contract regression (msg.sender accidentally
    // credited) or an unauthorized outflow. The audit runs best-effort: a
    // post-tx balance read failure logs a warning but does not block the ok
    // result. A confirmed violation trips the circuit breaker and posts a
    // `keeper_payout_bound_violation` alert; the tx itself is reported as ok
    // because it confirmed on-chain.
    let payoutBoundViolation: {
      reason: string;
      balanceDeltaWei: bigint;
      totalCostWei: bigint;
    } | null = null;
    if (balanceBeforeWei != null) {
      try {
        const balanceAfterWei = await publicClient.getBalance({
          address: account.address as Address,
        });
        const gasUsed = (receipt as any)?.gasUsed != null ? BigInt((receipt as any).gasUsed) : null;
        const effectiveGasPrice =
          (receipt as any)?.effectiveGasPrice != null
            ? BigInt((receipt as any).effectiveGasPrice)
            : null;
        // OP-stack chains (Base, Optimism, …) include `l1Fee` on the receipt:
        // the EOA-side cost of posting the tx data to L1 at execution time.
        // Absent on Ethereum L1 → default 0n so the audit reduces to the
        // standard `gasUsed * effectiveGasPrice` invariant there.
        const l1FeeWei = (receipt as any)?.l1Fee != null ? BigInt((receipt as any).l1Fee) : 0n;
        if (gasUsed != null && effectiveGasPrice != null) {
          const gasSpentWei = gasUsed * effectiveGasPrice;
          const totalCostWei = gasSpentWei + l1FeeWei;
          const audit = assertKeeperEoaPayoutBound({
            balanceBeforeWei,
            balanceAfterWei,
            totalCostWei,
          });
          if (!audit.ok) {
            payoutBoundViolation = {
              reason: audit.reason,
              balanceDeltaWei: audit.balanceDeltaWei,
              totalCostWei: audit.totalCostWei,
            };
            if (log) {
              log(
                `CRITICAL: payout-bound audit violation tx=${hash} ${audit.reason} (delta=${audit.balanceDeltaWei.toString()} totalCost=${audit.totalCostWei.toString()} gasSpent=${gasSpentWei.toString()} l1Fee=${l1FeeWei.toString()})`,
              );
            }
            try {
              const { tripped: pbTripped } = recordTxFailure({
                config,
                error: `payout_bound_violation: ${audit.reason}`,
              });
              if (pbTripped && log) {
                log(`circuit breaker tripped by payout-bound audit on tx ${hash}`);
              }
            } catch (breakerErr: unknown) {
              if (log) {
                log(
                  `FATAL: payout-bound violation could not update circuit breaker state: ${fmtErr(breakerErr)}`,
                );
              }
            }
            await postAlert(config.alertWebhookUrl, {
              type: 'keeper_payout_bound_violation',
              action: context ?? 'sendContractTx',
              deployment: config.deployment,
              timestampUtc: nowUtcIso(),
              error: audit.reason,
              txHash: hash,
              details: {
                balanceBeforeWei: balanceBeforeWei.toString(),
                balanceAfterWei: balanceAfterWei.toString(),
                totalCostWei: totalCostWei.toString(),
                gasSpentWei: gasSpentWei.toString(),
                l1FeeWei: l1FeeWei.toString(),
                balanceDeltaWei: audit.balanceDeltaWei.toString(),
              },
            });
          }
        } else if (log) {
          log(
            `WARN: payout-bound audit skipped on tx ${hash} (gasUsed=${gasUsed} effectiveGasPrice=${effectiveGasPrice})`,
          );
        }
      } catch (auditErr: unknown) {
        if (log) log(`WARN: payout-bound audit failed on tx ${hash}: ${fmtErr(auditErr)}`);
      }
    }

    try {
      recordTxSuccess(config);
    } catch (stateErr: unknown) {
      const stateMsg = fmtErr(stateErr);
      if (log) {
        log(
          `FATAL: confirmed tx ${hash} succeeded but circuit breaker success-state persistence failed: ${stateMsg}. Returning success for the confirmed tx; future sends will fail closed until the state file is repaired.`,
        );
      }
      await postAlert(config.alertWebhookUrl, {
        type: 'keeper_circuit_breaker_state_invalid',
        action: 'tx_success_state',
        deployment: config.deployment,
        timestampUtc: nowUtcIso(),
        error: stateMsg,
        txHash: hash,
        details: {
          statePath: config.circuitBreakerStatePath,
          pauseFilePath: config.pauseFilePath,
        },
      });
    }

    return {
      ok: true,
      hash,
      receipt,
      gasLimit,
      maxFeePerGasWei: config.txMaxFeePerGasWei,
      maxPriorityFeePerGasWei: config.txMaxPriorityFeePerGasWei,
      payoutBoundViolation,
    };
  } catch (e: unknown) {
    const err = fmtErr(e);

    // If the tx was never submitted and the RPC error indicates our fee cap is below
    // the current network base fee, treat this as a skip (configuration rail) rather
    // than a tx pipeline failure (avoids tripping the circuit breaker).
    if (!hash && isFeeCapTooLowErrorMessage(err)) {
      const reason = `tx fee cap too low: ${err}`;
      if (log) log(`SKIP: ${reason}`);
      return { ok: false, skipped: true, reason, code: 'fee_cap' };
    }

    let tripped: boolean;
    try {
      ({ tripped } = recordTxFailure({ config, error: err }));
    } catch (stateErr: unknown) {
      const stateMsg = fmtErr(stateErr);
      if (log) {
        log(
          `FATAL: tx failure could not update circuit breaker state: ${stateMsg}; originalError=${err}`,
        );
      }
      throw new Error(
        `tx failed (${err}) and circuit breaker state could not be updated: ${stateMsg}`,
        { cause: stateErr },
      );
    }

    // Only alert on circuit breaker trip to avoid spamming alerts (tasks already alert on failures).
    if (tripped) {
      await postAlert(config.alertWebhookUrl, {
        type: 'keeper_circuit_breaker_tripped',
        action: 'tx_pipeline',
        deployment: config.deployment,
        timestampUtc: nowUtcIso(),
        error: err,
        txHash: hash,
        details: {
          maxFailures: config.circuitBreakerMaxFailures,
          cooldownMs: config.circuitBreakerCooldownMs,
          pauseFilePath: config.pauseFilePath,
        },
      });
    }

    throw e;
  }
}
