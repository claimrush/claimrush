# LP Staking Vault (LpStakingVault7D)

`LpStakingVault7D` lets users stake Aerodrome WETH/CLAIM LP tokens and earn CLAIM rewards. Rewards flow from the [Furnace](furnace.md) (LP top-up split + overflow drip), sellback LP cuts, and the vault's own Aerodrome fee harvest. This is the protocol's incentive layer for liquidity providers.

> **TL;DR:** Stake via `stake(amount)`. Exit through a 7-day cooldown: `beginUnbond(amount)` → wait → `withdrawMatured()`. Earn CLAIM via `claimRewards()` (Harvest) or `claimRewardsAndLock(...)` (Harvest & Lock, routed through the Furnace). Rewards come from the Furnace LP stream, sellback cuts, and the vault's Aerodrome fee harvest.

## Public API

| Function | Caller | Purpose |
|---|---|---|
| `stake(amount)` | user | Bond LP and start earning. |
| `beginUnbond(amount)` | user | Start the 7-day cooldown for `amount`. |
| `withdrawMatured()` | user | Sweep every matured unbond entry. |
| `getUnbondCount(user)` / `getUnbondByIndex(user, i)` | view | Enumerate active unbond entries. |
| `claimRewards()` | user | Harvest liquid CLAIM rewards to wallet. |
| `claimRewardsAndLock(targetTokenId, durationSeconds, createAutoMax, minVeOut)` | user | Harvest & Lock through the Furnace; honors `MIN_COMPOUND_INTERVAL`. |
| `setAutoCompoundConfig(...)` / `compoundFor(user, quote)` / `compoundForMany(...)` | user / owner-or-keeper | Auto-compound staked rewards. |
| `harvestFeesToRewards(deadline, minClaimOut)` | owner or harvest keeper | Aerodrome `claimFees()` → swap WETH → credit CLAIM rewards. |
| `previewHarvestFeesToRewards()` | view | Best-effort quote (`feeClaim` always `0` by design — see body). |
| `notifyRewards(amountClaim)` | Furnace only | Allowlisted reward notification from the LP stream. |
| `rewardPerToken()` / `earned(user)` | view | Reward accumulator and per-user accrual. |

## User lifecycle (ABI surface)

Stake:
- `stake(amount)`
  - bonds LP immediately
  - updates reward accounting

Unbond (start cooldown):
- `beginUnbond(amount)`
  - removes LP from `stakedBalance` immediately
  - creates an onchain unbond entry (`id`, `amount`, `unlockTime`)
- Constants (v1.0.0):
  - `UNBONDING_PERIOD = 7 days`
  - `MAX_UNBONDS_PER_USER = 25` (hard cap on active entries)

Withdraw:
- `withdrawMatured()`
  - withdraws **all matured** unbond entries
  - bounded in practice by `MAX_UNBONDS_PER_USER`

Views (for UIs):
- `getUnbondCount(user)`
- `getUnbondByIndex(user, index) -> (unbondId, amount, unlockTime)`
  - swap-and-pop removes withdrawn entries, so only active entries are returned

Rewards (CLAIM):
- `claimRewards()` — **Harvest** (liquid CLAIM to wallet)
- `claimRewardsAndLock(targetTokenId, durationSeconds, createAutoMax, minVeOut)` — **Harvest & Lock**
  - routes through Furnace so the Furnace bonus applies
  - caller supplies `minVeOut`. `minVeOut == 0` reverts `MinVeOutRequired` — derive it from a Furnace `quoteEnterWithClaim` quote the same way as a normal Furnace entry.
  - `durationSeconds` must be in `[MIN_LOCK_DURATION, MAX_LOCK_DURATION]` (else `InvalidDuration`).
  - When `createAutoMax == true`, you must pass `targetTokenId == 0` (else `AutoMaxMismatch`) and `durationSeconds == MAX_LOCK_DURATION` (else `InvalidDuration`) — i.e. AutoMax is only valid when creating a brand-new max-duration lock.
  - Subject to the same `MIN_COMPOUND_INTERVAL = 1 day` cooldown as auto-compound, tracked in a separate `lastUserLockTs[user]` slot (so the keeper-driven and user-initiated paths don't reset each other). Calls inside the cooldown revert `LockCooldown`.
  - The emitted `LpRewardsLocked.tokenId` is the actual destination lock id returned by Furnace; if a new lock is created, index the minted token id rather than assuming `0`.
  - `LpRewardsLocked.principalClaim` and `LpRewardsLocked.bonusClaim` are sourced from a fresh `FurnaceQuoter.quoteEnterWithClaim` invocation that runs in the same transaction as the lock. A quoter outage reverts the whole call: a successful `LpRewardsLocked` event therefore implies a successful quote with a known principal / bonus split, and subgraph history never records a zero-principal / zero-bonus entry from a transient quoter failure.

## Reward sources

Rewards credited by the vault can come from:
- Furnace-funded LP rewards (top-ups + streamed drip)
- Furnace sellback cut routed to LP rewards
- the vault's own Aerodrome LP fee harvest (WETH/CLAIM fees -> CLAIM rewards)

Reward accounting uses a standard reward-per-token accumulator:
- `ACC = 1e18`

## Fee harvest: Aerodrome LP fees -> CLAIM rewards

Owner-or-keeper-allowlisted method (vault owner or allowlisted harvest keeper):
- `harvestFeesToRewards(deadline, minClaimOut)`
  - first checkpoints any pre-existing unaccounted CLAIM (for example from a prior swallowed Furnace `notifyRewards(...)` failure) so this call's `feeClaim` / `claimToRewards` reflect the current harvest only
  - calls Aerodrome pool `claimFees()` (WETH + CLAIM)
  - swaps WETH -> CLAIM
  - credits (fee CLAIM + bought CLAIM) as new rewards using **balance-delta** accounting

`setHarvestKeeper(addr, true)` runs the delegated-EOA rejection on `addr` before allowlisting; a 7702-delegated address reverts `DelegatedEOA` at the setter. The disable path (`allowed == false`) skips the check so a compromised seat can always be removed. See [Security, Guardian, Pausing — Keeper allowlist 7702 guard](security-guardian-pausing.md#keeper-allowlist-7702-guard) for the cross-contract rule.

Preview helper (UI / keeper tooling):
- `previewHarvestFeesToRewards() -> (feeWeth, feeClaim, expectedClaimOut)`
  - does **not** call `claimFees()` (and cannot, in a `view`).
  - `feeWeth` is the vault's current WETH balance (the WETH side of any fees that have already been pulled into the vault).
  - **`feeClaim` is always returned as `0`** — by design, since the unclaimed CLAIM-side fees still inside the Aerodrome pool are unknown without calling `claimFees()`. Do not rely on this value as a "vault unaccounted CLAIM" estimate; for accurate previews, run an `eth_call` simulation of `harvestFeesToRewards`.
  - `expectedClaimOut` is a best-effort `IAerodromeRouter.getAmountsOut` spot quote on `feeWeth` (returns `0` if `feeWeth == 0` or the quote reverts). Same manipulable-pool-state caveat as `harvestFeesToRewards` — not a substitute for an off-chain TWAP / oracle when sizing `minClaimOut`.

`minClaimOut` handling:
- if `wethToSwap > 0`, `minClaimOut` MUST be non-zero
- if `wethToSwap == 0`, runtime clamps the effective floor to `0` and ignores the caller's `minClaimOut`
- the vault enforces an additional onchain sanity floor derived from an Aerodrome spot quote:
  - `effectiveMinClaimOut = max(minClaimOut, quoteFloor)` when a swap occurs
  - `quoteFloor = quotedOut * (1 - HARVEST_MAX_SLIPPAGE_BPS)`
  - v1.0.0: `HARVEST_MAX_SLIPPAGE_BPS = 100` (1%)
- this does **not** prevent sandwich attacks (quote and swap read the same manipulable state)
  - keepers MUST compute `minClaimOut` from a TWAP/oracle price
  - keepers SHOULD submit via a private relay for MEV protection

## Auto-compound (vault rewards -> veCLAIM)

Users can opt in to auto-compound their vault **CLAIM rewards** into the Furnace.

Key rules (v1.0.0):
- disabled by default (explicit opt-in)
- does **not** create new locks in v1.0.0
  - a destination `tokenId` is required
- execution is **owner-or-keeper-allowlisted**
  - `owner` or an allowlisted `isHarvestKeeper`

Config per user (onchain):
- `enabled`, `paused`
- `tokenId` destination
  - must be owned by the user
  - must not be listed
  - must not be expired
- `durationSeconds` (stored target remaining duration)
  - validated when saving config (MIN..MAX; AutoMax requires MAX)
  - execution uses `max(cfg.durationSeconds, lockEnd - now)` for normal locks, or `MAX_LOCK_DURATION` for AutoMax
  - adding capital does not change the lock's duration
- `maxSlippageBps`
  - `0` = use `DEFAULT_LP_AUTOCOMPOUND_MAX_SLIPPAGE_BPS` (v1.0.0: 300 = 3%)
  - clamped to `<= 1_000` (10%); reverts `SlippageTooHigh` above that

Config methods:
- `setAutoCompoundConfig(enabled, tokenId, durationSeconds, maxSlippageBps, minRewardToCompound)`
- `getAutoCompoundConfig(user) -> (enabled, paused, tokenId, durationSeconds, maxSlippageBps, minRewardToCompound)`
- Delegation-gated setter:
  - `setAutoCompoundConfigForUser(user, ...)` (requires `P_SET_LP_AUTOCOMPOUND_CONFIG_FOR`)
  - auth fails closed on bundle drift (see [Wiring safety model](protocol-overview.md#wiring-safety-model))

Execution (vault owner or allowlisted harvest keeper only):
- `compoundFor(user)`
- `compoundForMany(users[], maxUsers)`
  - processes up to `min(users.length, maxUsers, MAX_LP_COMPOUND_USERS_PER_CALL)`
  - v1.0.0: `MAX_LP_COMPOUND_USERS_PER_CALL = 50`

Slippage model (important):
- keepers do **not** pass `minVeOut`
- the vault computes `minVeOut` from a Furnace **spot quote** and the user's `maxSlippageBps`
- if the quote reverts **or** returns `veOut == 0`, the user is silently skipped (no pause, no revert). A zero quote is treated as transient depth/dust and never reaches `Furnace.enterWithClaimFor`, so the user cannot be paused into `MIN_VE_OUT_NOT_MET = 4` for a degenerate spot read.

Eligibility + pause behavior:
- best-effort per user (batch does not revert for a single failure)
- skips silently when `earned(user) < max(cfg.minRewardToCompound, minCompoundReward)` — both the per-user floor and the owner-settable **global** dust guard are checked, and the larger of the two wins. `minCompoundReward` defaults to 1 CLAIM (`1e18`); the owner can adjust it within `MAX_MIN_HARVEST_CLAIM_FLOOR`. The per-user `cfg.minRewardToCompound` can therefore raise but never lower the effective floor.
- `MIN_COMPOUND_INTERVAL = 1 day` cooldown applies to **both** paths, with separate timestamp slots so the keeper-driven and user-driven paths don't reset each other:
  - keeper auto-compound (`compoundFor` / `compoundForMany`): tracked in `lastCompoundTs[user]` (silent skip if hit).
  - user-initiated Harvest & Lock (`claimRewardsAndLock`): tracked in `lastUserLockTs[user]` (reverts `LockCooldown` if hit).
- pauses config if the destination lock becomes ineligible at execution time
  - not owner / listed / expired / invalid tokenId
  - user must save a new config to resume
- auto-compound pauses automatically when the destination **non-AutoMax** lock’s remaining time drops below `MIN_LOCK_DURATION` (7 days), using the `EXPIRED` pause reason (code 3)
- pause reason codes reuse `Constants.SHAREHOLDER_AUTOCOMPOUND_PAUSE_REASON_*` (codes 1..5 only — `QUOTE_FAILED = 6` and `CHECKPOINT_FAILED = 7` are not emitted by this vault, since both quote-revert and zero-`veOut` quote returns are silent skips and the vault does no per-user royalty checkpoint). Code 5 = `FURNACE_REVERT` on failed Furnace entry; the user's reward balance is restored before the pause is recorded.

UI/UX integration (recommended):
- Rewards actions should mirror Royalties:
  - Primary (default): **Harvest CLAIM**
  - Secondary: **Harvest & Lock**

## Strict debt-accounting invariant

`LpStakingVault7D` maintains two O(1) debt accumulators that bound how much CLAIM custody is liability vs surplus:

- `indexedClaimOwed` — public `uint256` getter. Total CLAIM that has been moved into the per-token reward index but not yet harvested or locked. Increased on every `notifyRewards`, harvest, or sellback that lands new CLAIM into the reward stream; decreased on every successful `claimRewards` / `claimRewardsAndLock` payout.
- `totalRewardsCredited` — public `uint256` getter. Sum of every staker's individual `rewards[user]` accumulator. Increased on every per-user reward checkpoint; decreased on every successful payout.

Both accumulators satisfy the strict invariant:

```text
totalRewardsCredited <= indexedClaimOwed
indexedClaimOwed - totalRewardsCredited == Σ_unallocated_indexed
```

The `Σ_unallocated_indexed` slack is CLAIM that has been moved into the index but has not yet been per-user-checkpointed (it accrues into individual `rewards[user]` lazily on the next `_updateReward(user)` touch). It is NOT idle balance — it is fully claimed-against by future per-user checkpoints.

Two related public counters are observable alongside the debt accumulators:

- `accountedRewardBalance` — public `uint256` getter; the vault's CLAIM balance as last seen by the reward-accounting paths. The vault uses **balance-delta** accounting on every `notifyRewards`, harvest, and pre-checkpoint sweep: `delta = claim.balanceOf(vault) - accountedRewardBalance` is what actually credits the index, regardless of the `amountClaim` argument. Forced surplus (CLAIM transferred into the vault outside the canonical paths) sits inert until the next reward-accounting touch folds it in via this balance-delta path.
- `queuedRewards` — public `uint256` getter; CLAIM received while `totalStaked == 0`. Parked here and flushed into the index by the next `stake()` call. Operators should alert when `queuedRewards` is large relative to typical stake sizes — the first staker after a zero-TVL window captures the entire queue.

LP custody (`IERC20(lpToken).balanceOf(vault)`) is **separate** from CLAIM custody — staked LP tokens are the WETH/CLAIM Aerodrome v2 pair token, not raw CLAIM, and they live in their own balance lane.

The Echidna properties `echidna_lp_debt_accounting_exact` and `echidna_total_credited_matches_sum` in `test/echidna/EchidnaLpStaking.sol` are the canonical fuzzers for this surface. Operator monitoring should read both accumulators through their public ABI rather than reconstructing them from per-user `rewards[user]` storage scans.

## Integrator notes

- If you display APR, use the canonical APR spec in `docs/spec/apr-calculation-spec-v1.0.0.md`.
- Do not label CLAIM rewards as "claim" in UI.
  Use **Harvest**.

## Operator notes

The remaining sections cover deploy-time wiring and the notifier allowlist. Integrators can skip unless instrumenting governance flows or troubleshooting an allowlist revert.

### Construction

The constructor rejects a delegated-EOA `initialOwner`: a 7702-delegated address reverts `DelegatedEOA`, while bare EOAs and ordinary contracts pass. The same rejection runs on the `_weth`, `_claim`, `_ve`, `_furnace`, and `_aerodromeRouter` wiring inputs, and on `transferOwnership`. See [Security, Guardian, Pausing — Initial-owner 7702 guard](security-guardian-pausing.md#initial-owner-7702-guard) for the cross-contract rule.

### notifyRewards allowlist

To prevent arbitrary reward injection, `notifyRewards` is allowlisted.

Authorized sources (v1.0.0):
- Furnace (LP reward split)
- this vault itself (`address(this)` remains allowlisted for vault-side notifier flows; current `harvestFeesToRewards` uses the same balance-delta accounting path without an external self-call)

Operational note:
- Upstream funders may treat `notifyRewards` as **best-effort** (swallow reverts) to avoid DoS on unrelated flows.
- This vault uses **balance-delta** accounting (`amountClaim` is ignored), so any CLAIM transferred without a successful notify can still be accounted on a later successful notify (including `notifyRewards(0)`).

## See also

- [Furnace](furnace.md) — LP overflow drip and lock bonus engine
- [Maintenance and Bots](maintenance-and-bots.md) — harvest and compound keeper loops
- [Core Mechanics](core-mechanics.md) — emission schedule and LP stream
- [Constants Reference](appendix-constants-v100.md) — reward durations and slippage bounds
- Tutorial: [Run a MaintenanceHub bot (poke loop)](tutorials/run-maintenance-bot.md)
- User manual: [Liquidity & LP Vault](https://docs.claimru.sh/liquidity-and-lp-vault)
