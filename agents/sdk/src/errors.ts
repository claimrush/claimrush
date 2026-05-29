import { TxTimeoutError } from './tx/txManager.js';
import { safeErrorString } from './security/redact.js';

export type ClaimRushErrorKind =
  | 'tx_timeout'
  | 'not_authorized'
  | 'paused'
  | 'slippage'
  | 'deadline'
  | 'insufficient_balance'
  | 'insufficient_allowance'
  | 'unknown';

export type ClaimRushErrorInfo = {
  kind: ClaimRushErrorKind;
  /** Decoded custom error name, when available. */
  errorName?: string;
  /** Best-effort short message extracted from the thrown error. */
  message: string;
};

function firstString(...values: unknown[]): string | undefined {
  for (const v of values) {
    if (typeof v === 'string' && v.length > 0) return v;
  }
  return undefined;
}

function extractErrorName(err: any): string | undefined {
  return firstString(
    err?.cause?.data?.errorName,
    err?.cause?.cause?.data?.errorName,
    err?.data?.errorName,
    err?.errorName,
    err?.cause?.errorName,
  );
}

function extractMessage(err: any): string {
  return (
    firstString(err?.shortMessage, err?.message, err?.cause?.shortMessage, err?.cause?.message) ??
    'Unknown error'
  );
}

/**
 * Best-effort error classifier for viem execution errors.
 *
 * Intended use:
 * - log structured errors in agents
 * - decide whether to retry or backoff
 *
 * Unrecognized `errorName` values fall through to `kind='unknown'` and the
 * original message is preserved (redacted) so callers can still log + alert.
 */
export function classifyViemError(err: unknown): ClaimRushErrorInfo {
  if (err instanceof TxTimeoutError) {
    return { kind: 'tx_timeout', message: safeErrorString(err.message) };
  }

  const e = err as any;
  const errorName = extractErrorName(e);
  const message = safeErrorString(extractMessage(e));

  if (errorName === 'NotAuthorized' || errorName === 'OnlyAdmin' || errorName === 'OnlyGuardian') {
    return { kind: 'not_authorized', errorName, message };
  }

  if (
    errorName === 'TakeoversPaused' ||
    errorName === 'TradingPaused' ||
    errorName === 'LockingPaused'
  ) {
    return { kind: 'paused', errorName, message };
  }

  if (
    errorName === 'MinVeOutNotMet' ||
    errorName === 'MinEthOutNotMet' ||
    errorName === 'MinClaimOutNotMet' ||
    errorName === 'MaxPriceExceeded' ||
    errorName === 'SlippageTooHigh'
  ) {
    return { kind: 'slippage', errorName, message };
  }

  if (errorName === 'DeadlineExpired') {
    return { kind: 'deadline', errorName, message };
  }

  if (errorName === 'InsufficientEthBalance' || errorName === 'InsufficientTokenBalance') {
    return { kind: 'insufficient_balance', errorName, message };
  }

  if (errorName === 'InsufficientTokenAllowance') {
    return { kind: 'insufficient_allowance', errorName, message };
  }

  if (errorName) {
    console.warn(`[ClaimRush SDK] Unclassified contract error: ${errorName}`);
  }
  return { kind: 'unknown', errorName, message };
}
