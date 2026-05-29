/**
 * Payout-bound invariant for keeper tasks.
 *
 * Every keeper task (`harvest_staking`, `compound_lp`, `compound_shareholders`,
 * `automax_bonus`, `sweep_market`, `sweep_listings`, `expire_offers`,
 * `checkpoint_before_expiry`, `poke`) calls a contract entry point that pays
 * rewards to the user, vault, or protocol — never to `msg.sender` (the keeper
 * EOA). The keeper EOA balance must therefore strictly decrease by exactly the
 * total tx cost on a successful transaction. Any positive delta indicates a
 * contract regression where a payout was accidentally routed to `msg.sender`;
 * a negative delta beyond the total tx cost indicates an unauthorized
 * withdrawal from the EOA.
 *
 * `assertKeeperEoaPayoutBound` codifies that invariant as a pure check that any
 * caller can apply against `(balanceBefore, balanceAfter, totalCost)`. The
 * tolerance is fixed at zero — tx cost accounting is deterministic from the
 * receipt.
 *
 * On OP-stack chains (Base, Optimism, …) the EOA pays both the L2 execution
 * gas (`gasUsed * effectiveGasPrice`) AND an L1 data-posting fee (`l1Fee`,
 * deducted at execution). The caller MUST sum both into `totalCostWei` before
 * invoking this check, otherwise the EOA balance delta will exceed the L2-only
 * gas cost by exactly `l1Fee` and the audit will produce a false positive.
 */

export type EoaPayoutCheckResult =
  | { ok: true }
  | { ok: false; reason: string; balanceDeltaWei: bigint; totalCostWei: bigint };

/**
 * Verify the keeper EOA balance moved by exactly `-totalCostWei` over a tx window.
 *
 * @param balanceBeforeWei EOA balance immediately before tx submission.
 * @param balanceAfterWei  EOA balance immediately after the receipt was confirmed.
 * @param totalCostWei     Full EOA-side tx cost. On Ethereum L1 this is
 *                         `receipt.gasUsed * receipt.effectiveGasPrice`.
 *                         On OP-stack chains add `receipt.l1Fee` (the cost of
 *                         posting the tx data to L1, deducted from the EOA at
 *                         execution time alongside L2 gas).
 *
 * Returns `{ ok: true }` if the invariant holds, otherwise `{ ok: false, ... }`
 * with the observed delta and the expected total cost so the caller can route
 * the violation through its alert / circuit-breaker channel.
 */
export function assertKeeperEoaPayoutBound(input: {
  balanceBeforeWei: bigint;
  balanceAfterWei: bigint;
  totalCostWei: bigint;
}): EoaPayoutCheckResult {
  const { balanceBeforeWei, balanceAfterWei, totalCostWei } = input;

  if (totalCostWei < 0n) {
    return {
      ok: false,
      reason: 'totalCostWei < 0 — receipt parsing must be wrong',
      balanceDeltaWei: balanceAfterWei - balanceBeforeWei,
      totalCostWei,
    };
  }

  const balanceDeltaWei = balanceAfterWei - balanceBeforeWei;

  // The invariant: balanceAfter == balanceBefore - totalCost. Anything else is suspicious.
  // - A positive delta means a contract paid the keeper EOA (regression: should pay the user / vault).
  // - A negative delta beyond totalCost means an unauthorized outflow (unexpected ETH transfer).
  if (balanceDeltaWei === -totalCostWei) {
    return { ok: true };
  }

  if (balanceDeltaWei > 0n) {
    return {
      ok: false,
      reason: `keeper EOA received ${balanceDeltaWei.toString()} wei from this tx — no task should pay msg.sender`,
      balanceDeltaWei,
      totalCostWei,
    };
  }

  // balanceDeltaWei < 0 here. Compare its magnitude against totalCostWei.
  const outflowWei = -balanceDeltaWei;
  if (outflowWei > totalCostWei) {
    const excessWei = outflowWei - totalCostWei;
    return {
      ok: false,
      reason: `keeper EOA outflow ${outflowWei.toString()} wei exceeds totalCost ${totalCostWei.toString()} wei by ${excessWei.toString()} wei — unauthorized withdrawal`,
      balanceDeltaWei,
      totalCostWei,
    };
  }

  // outflow < totalCost: the EOA effectively received `totalCost - outflow` wei back.
  // Either the receipt's totalCost reading is wrong, or a contract paid the keeper
  // a partial gas rebate. Fail closed in both cases.
  const rebateWei = totalCostWei - outflowWei;
  return {
    ok: false,
    reason: `keeper EOA received ${rebateWei.toString()} wei (outflow ${outflowWei.toString()} wei < totalCost ${totalCostWei.toString()} wei) — no task should pay msg.sender`,
    balanceDeltaWei,
    totalCostWei,
  };
}
