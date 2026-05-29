import { BigInt } from "@graphprotocol/graph-ts";

// Spec: docs/spec/spec-v1.0.0.md
export const MAX_LOCK_DURATION_SECONDS = 31536000; // 365 days

const ZERO = BigInt.fromI32(0);
const MAX = BigInt.fromI32(MAX_LOCK_DURATION_SECONDS);

// AutoMax semantics (protocol): an AutoMax lock is treated as if it is continuously
// extended to the maximum duration, so ve never decays while autoMax=true.
//
// IMPORTANT: The subgraph cannot update continuously between events, so this helper
// must be correct at event time to keep per-user aggregate deltas consistent.
export function currentVeWei(amountWei: BigInt, lockEnd: BigInt, now: BigInt, autoMax: bool): BigInt {
  // overflow in AssemblyScript BigInt. No division-by-zero risk since MAX is a compile-time
  // constant. Precision loss from integer division is inherent to the ve model and matches
  // the on-chain calculation.
  if (autoMax) {
    return amountWei;
  }

  if (lockEnd.le(now)) {
    return ZERO;
  }

  const remaining = lockEnd.minus(now);
  return amountWei.times(remaining).div(MAX);
}
