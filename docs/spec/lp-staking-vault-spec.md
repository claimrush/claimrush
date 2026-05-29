# docs/spec/lp-staking-vault-spec.md

> [!WARNING]
> **Locked for v1.0.0 (do not edit without version bump)**
>
> This file is part of the v1.0.0 canonical spec set.
> Behavior changes belong in a separately versioned spec file, and the repo indexes must point to the active version.

## Purpose

Provide an on-protocol LP staking incentive for the canonical Aerodrome v2 WETH/CLAIM vAMM LP token.

This vault:
- Incentivizes liquidity by paying liquid CLAIM rewards to LP stakers.
- Is funded by **transparent onchain sources** (no protocol fees):
  - Furnace-funded LP rewards stream (dripped over time):
    - A split of the Furnace gross bonus (`lpRewardClaim`).
    - Furnace overflow drip (protocol; `lpOverflowDripPerDay`).
    - Furnace sellback LP share (protocol; `lpReward` from sellback).
  - Donated staked-LP fees (harvested from this vault's Aerodrome fees, swapped to CLAIM, donated to LP rewards).
- Uses a Cosmos-like unbond model to reduce short-term farm-and-dump behavior.

Protocol boundaries:
- No gauges, bribes, ve(3,3), or vote markets.
- The Furnace bonus curve does not depend on LP stake. LP rewards are a separate flow.

---

## Asset

Staked token:
- Aerodrome v2 WETH/CLAIM vAMM LP token for the canonical CLAIM/WETH pool.

Rewards token:
- CLAIM (liquid ERC20)

---

## Lock / unbond mechanics

Rules:
- Staking is “bonded” immediately.
- Withdraw requires unbond:
  - `UNBONDING_PERIOD = 7 days`
- User can have multiple concurrent unbond entries but capped:
  - `MAX_UNBONDS_PER_USER = 25`

While unbonding:
- The unbonded amount stops earning rewards immediately.
- The user cannot withdraw until the unlock time is reached.

---

## Rewards (CLAIM)

LP stakers earn rewards from these sources:

1) Furnace-funded LP rewards stream
- Furnace computes a gross bonus (`grossBonusClaim`) for each entry.
- A dynamic cut of the gross bonus (`lpRewardClaim`) is funded into the Furnace LP stream and dripped to this vault over `LP_STREAM_WINDOW` (14 days).
- Furnace MAY additionally fund the same LP stream via:
  - Overflow drip (protocol; reserve-funded).
  - Sellback LP share (protocol; cut-funded).

2) Vault-held LP fees (donated)
- This vault MUST expose `harvestFeesToRewards(...)` to harvest Aerodrome fees from its own LP position (the staked LP).
- Net of the WETH bounty, all fee value is swapped to CLAIM and credited as rewards.

Clarification (non-binding):
- These fee flows are **not protocol fees**. They are AMM swap fees earned by vault-held LP.
- No burn occurs for LP-fee-derived CLAIM. Fee-derived CLAIM is routed to LP stakers as additional rewards.

Accounting model:
- Standard `rewardPerToken` accounting (O(1), no loops over all stakers).
- Reward notifications MUST use actual token balance delta to avoid over-reporting.
- Clarification (non-binding): A safe implementation pattern is transfer-then-notify (measure delta after transfer) to make the delta deterministic.

RewardPerToken math (REQUIRED):
- Units: LP, WETH, and CLAIM are 18-decimal ERC20 units.
- Scaling: `ACC = 1e18` and `rewardPerTokenStored` is cumulative CLAIM-per-LP scaled by `ACC`.
- Earned: `earned(user) = rewards[user] + floor(stakedBalance[user] * (rewardPerTokenStored - userRewardPerTokenPaid[user]) / ACC)`.
- Reward funding: `notifyRewards(amountClaim)` MUST use CLAIM balance-delta accounting; the `amountClaim` parameter MUST NOT be trusted.
  - If `totalStakedLP == 0`, newly funded rewards MUST be queued and distributed on the next `stake(...)`.
- Update timing: the internal reward checkpoint helper `_updateReward(user)` MUST run before any change to `stakedBalance[user]` and before any reward payout/lock.
- Rounding: every division MUST round DOWN (floor) (math appendix §M.1).

Headline counters (REQUIRED for indexers/UI):
- `totalClaimRewardsFundedFromFurnace`
- `totalClaimRewardsFundedFromVaultFees`
- `totalClaimRewardsClaimed`
- `totalClaimRewardsLockedViaFurnace`

---

## User actions

### stake(amount)
- Transfers LP token from user to vault.
- Increases user bonded stake.

### beginUnbond(amount)
- Creates an unbond entry:
  - `{amount, unlockTime = now + UNBONDING_PERIOD}`
- Decreases bonded stake immediately.
- MUST revert if user already has `MAX_UNBONDS_PER_USER` active unbonds.

### withdrawMatured()
Withdraw all matured unbond entries for the caller (bounded loop, max 25 entries).

Rules:
- MUST transfer only entries with `block.timestamp >= unlockTime`.
- MUST close/delete each withdrawn entry so it no longer counts toward the cap.
- MUST NOT allow withdrawal of any unbond entry before its unlock time.

### claimRewards()
UI action: “Harvest CLAIM”.
- Transfers claimable CLAIM rewards to the user.

### claimRewardsAndLock(targetTokenId, durationSeconds, createAutoMax, minVeOut)
Single-action “Harvest & Lock” flow:
- Claims user rewards, then routes them through Furnace so the Furnace bonus applies normally.
- The user selects a **lock destination** (existing lock or create new) and a **lock duration** (7 days to 1 year).
- MUST provide slippage protection via `minVeOut`.

Parameters:
- `targetTokenId`
  - If `0`: create a new lock for the user inside the Furnace entry flow.
    - New locks have a protocol minimum size: `amountLocked >= MIN_LOCK_AMOUNT = 1_000e18` CLAIM (1,000 CLAIM).
    - If the claimable rewards (+ Furnace bonus) are below this, the call MUST revert and the caller MUST select an existing lock.
  - Else: compound into the specified existing lock (entry does not change the lock's duration).
- `durationSeconds`
  - Desired remaining lock duration after this action.
  - MUST satisfy `MIN_LOCK_DURATION <= durationSeconds <= MAX_LOCK_DURATION`.
- `createAutoMax`
  - Only applicable if `targetTokenId == 0` AND `durationSeconds == MAX_LOCK_DURATION`.
  - Else MUST be false.

High-level behavior:
- Vault calls Furnace using the contract-funded entry path (see core spec):
  - `Furnace.enterWithClaimFor(user, claimAmount, targetTokenId, durationSeconds, createAutoMax, minVeOut)`
- Furnace applies the duration-weighted Furnace bonus and routes principal + bonus into the selected lock destination.

Constraints (required):
- If `targetTokenId != 0` and the lock is non-AutoMax with remaining duration `< MIN_LOCK_DURATION`, Furnace entry reverts `InvalidDuration`.
- If `targetTokenId != 0` (otherwise), the Furnace clamps `durationSeconds` to the lock's current remaining duration for non-AutoMax locks. Entry does not change the lock's duration.
- If the selected lock is AutoMax:
  - The effective duration is always 1 year.

---

## Auto-compound into Furnace (OFF by default)

Goal:
- Allow LP stakers to opt in to automated compounding of their LP rewards into veCLAIM via Furnace.

Key properties (MUST):
- Auto-compound MUST be **disabled by default** (explicit user opt-in).
- Auto-compound MUST NOT create new locks in v1.0.0:
  - `tokenId != 0` is required for every compound attempt.
- Execution MUST be keeper-allowlisted (plus owner).
  - The official executor is an offchain **maintainer bot** with keeper authorization.
  - Auto-compound is intentionally **not** bundled into `MaintenanceHub.poke(...)`.
  - Rationale: compounding requires user worklists and per-user swap-safety params; the vault exposes dedicated single-user and batch executors that the maintainer bot calls directly.

### User configuration (REQUIRED)

Per-user config (REQUIRED):
- `bool enabled`
- `bool paused`
- `uint256 tokenId`
- `uint256 durationSeconds`
- `uint32 maxSlippageBps` (user-configured max slippage in basis points; 0 = use `DEFAULT_LP_AUTOCOMPOUND_MAX_SLIPPAGE_BPS`)

Configuration function (REQUIRED):
- `setAutoCompoundConfig(bool enabled, uint256 tokenId, uint256 durationSeconds, uint32 maxSlippageBps, uint256 minRewardToCompound)`

Supported delegation-gated companion:
- `setAutoCompoundConfigForUser(address user, bool enabled, uint256 tokenId, uint256 durationSeconds, uint32 maxSlippageBps, uint256 minRewardToCompound)`
  - Requires `P_SET_LP_AUTOCOMPOUND_CONFIG_FOR`.
  - MUST fail closed unless the live Furnace and MineCore resolve the same canonical `DelegationHub` through one shared Furnace root (`MineCore.furnace() == Furnace`); a raw `Furnace.delegationHub()` read is insufficient.

Rules (MUST):
- If `enabled == false`:
  - The implementation MUST treat auto-compound as disabled (executor no-ops).
  - It is allowed to clear stored values (pause flag, tokenId, duration), but MUST emit the config event.
- If `enabled == true`:
  - `tokenId` MUST be a valid existing lock owned by the configured user (`msg.sender` on the self path; `user` on the delegation-gated path).
  - `tokenId` MUST NOT be listed.
  - `tokenId` MUST NOT be expired.
  - `MIN_LOCK_DURATION <= durationSeconds <= MAX_LOCK_DURATION`.
  - If `tokenId` is AutoMax, `durationSeconds` MUST be `MAX_LOCK_DURATION`.
- `maxSlippageBps` is stored per-user. If `0`, the contract uses `DEFAULT_LP_AUTOCOMPOUND_MAX_SLIPPAGE_BPS` at execution time.
- Any successful config change MUST set `paused = false`.
- MUST emit `AutoCompoundConfigured(user, enabled, tokenId, durationSeconds, maxSlippageBps, minRewardToCompound)`.

### Execution model (REQUIRED)

Executor functions (REQUIRED):
- `compoundFor(address user)`
- `compoundForMany(address[] users, uint256 maxUsers)`

Note: `minVeOut` is **not** passed by the caller. The contract computes it on-chain from the user's stored `maxSlippageBps` and a Furnace quote (see "Execution behavior" below).

Batch rules (MUST):
- MUST be best-effort per user:
  - A failure for one user MUST NOT revert the entire batch call.
  - The failed user’s rewards/config state MUST NOT be lost on failure.
- MUST NOT iterate over all users onchain (caller supplies explicit worklist).
- MUST be gas-bounded:
  - Let `usersN = min(users.length, min(maxUsers, MAX_LP_COMPOUND_USERS_PER_CALL))`.
  - Iterate only over `[0..usersN)`.

Expected caller (ops):
- The official **maintainer bot** monitors eligible users and submits:
  - preferred: `compoundForMany(...)`
  - fallback: `compoundFor(...)`
- Both executor functions are keeper-allowlisted (owner + configured keepers).

### Execution behavior

On a compound attempt for `user`:

1) If auto-compound is not enabled or is paused: return (no-op).
2) If `earned(user) == 0`: return (no-op).
3) Validate the destination lock is still eligible at execution time:
   - owned by `user`
   - not listed
   - not expired
4) Compute effective duration:
   - If the destination is non-AutoMax and `remainingDurationSeconds(tokenId) < MIN_LOCK_DURATION`: skip compounding, set `paused = true`, emit `AutoCompoundPaused` with reason **EXPIRED** — do **not** clamp duration upward to satisfy the minimum.
   - Else: `effectiveDurationSeconds = max(configDurationSeconds, remainingDurationSeconds(tokenId))` (Furnace clamps this to remaining for non-AutoMax locks).
   - If the destination is AutoMax: treat `effectiveDurationSeconds = MAX_LOCK_DURATION`.
5) Compute `minVeOut` on-chain:
   - Query `Furnace.quoteEnterWithClaim(user, claimAmount, tokenId, effectiveDurationSeconds, false)` to obtain `veOut` for the newly locked amount at the resulting remaining duration.
   - Let `slippageBps = maxSlippageBps` (or `DEFAULT_LP_AUTOCOMPOUND_MAX_SLIPPAGE_BPS` if `0`).
   - Compute `minVeOut = veOut * (BPS_DENOM - slippageBps) / BPS_DENOM`.
   - If `veOut > 0` but floor-rounding would produce `minVeOut == 0`, clamp to `1` before calling Furnace.
   - If the quote call reverts, skip the compound (return) to avoid MEV.
6) Route through Furnace:
   - `Furnace.enterWithClaimFor(user, claimAmount, tokenId, effectiveDurationSeconds, false, minVeOut)`
   - where `minVeOut` is computed on-chain as described in step 5.

### Failure behavior (Policy 2: skip + pause)

If the configured destination lock becomes invalid/ineligible at execution time:
- Do not create a new lock.
- Do not revert.
- Skip compounding for that user.
- Mark the user’s auto-compound as `paused = true` until they update configuration.
- MUST emit `AutoCompoundPaused(user, tokenId, reasonCode)`.


---

## Fee harvest to rewards (REQUIRED, owner-or-keeper-allowlisted)

The vault MUST expose an Aerodrome fee harvest from its LP position and credit it as additional LP rewards.
Harvest execution is restricted to an owner-managed keeper allowlist (plus owner).

Policy:
- 100% of harvested fees are credited to LP stakers as CLAIM rewards.
- No bounty is paid to the keeper; gas is funded out-of-band.
- No CLAIM is burned.
- This introduces a liveness dependency on configured keepers.

Function:
- `harvestFeesToRewards(uint256 deadline, uint256 minClaimOut)`
- `setHarvestKeeper(address keeper, bool allowed)` (owner-only)

Required flow:
1) Before processing the current harvest, checkpoint any pre-existing unaccounted CLAIM balance through the same balance-delta notifier path.
   - Rationale: a prior best-effort Furnace `notifyRewards(...)` failure can leave real CLAIM sitting in the vault.
   - That pre-checkpointed balance MUST NOT be counted as this call's `feeClaim` or `claimToRewards`.
2) Collect fees from the Aerodrome pool, then observe `(feeWeth, feeClaim)` as the current harvest inputs.
   - `feeClaim` is the vault's current unaccounted CLAIM after excluding the already-accounted rewards reserve; it is not `claim.balanceOf(address(this))` directly.
   - Revert if `feeWeth == 0` AND `feeClaim == 0` (no fees to process).
3) Swap WETH → CLAIM:
   - `wethToSwap = feeWeth`
   - If `wethToSwap == 0`:
     - `swapOutClaim = 0`
     - the shipped runtime clamps the effective floor to `0`; the caller's `minClaimOut` is ignored in this branch rather than required to be `0`.
   - Else:
     - Swap via Aerodrome router with `deadline`.
     - Enforce `swapOutClaim >= minClaimOut`.
4) Credit rewards:
   - `claimToRewards = feeClaim + swapOutClaim`
   - MUST credit rewards via the same balance-delta notifier path as `notifyRewards(...)` after the harvested fees are in the vault.
   - Clarification: the shipped v1.0.0 code uses an internal helper for this step, not an external self-call.
5) Update `lastFeeHarvestTs` and emit `LpFeesHarvestedToRewards(...)`.

Keeper authorization (REQUIRED):
- `harvestFeesToRewards(...)` MUST revert for callers not in the harvest keeper allowlist (unless caller is owner).
- Keeper allowlist changes MUST be owner-only and indexable via event emission.

Helper (REQUIRED for automation):
- `previewHarvestFeesToRewards()` → `(feeWeth, feeClaim, expectedClaimOut)`
  - `expectedClaimOut` is a best-effort router quote for swapping `feeWeth`.
    - If the router quote call reverts, `expectedClaimOut` MUST be returned as `0`.

Constraints (required):
- `MaintenanceHub.poke(...)` does not invoke this function in v1.0.0.
---

## Test vectors required (REQUIRED)

Implementations MUST include tests that cover these vectors exactly.

1) RewardPerToken distribution (round down)
- Given `totalStakedLP = 100e18`, `notifyRewards` funds `toDistribute = 1_000e18` CLAIM
- `rewardPerTokenStored` increases by `floor(1_000e18 * 1e18 / 100e18) = 10e18`
- A user with `10e18` LP staked earns `floor(10e18 * 10e18 / 1e18) = 100e18` CLAIM

2) Queue on zero staked
- Given `totalStakedLP = 0`, `notifyRewards` funds `500e18` CLAIM
- Rewards MUST be queued and distributed on the next `stake(...)`.

3) Unbond stops earning
- After `beginUnbond(amount)`, that `amount` MUST stop earning rewards immediately, and `withdrawMatured()` MUST NOT change reward accounting.

4) Fee harvest swaps all WETH
- Given `feeWeth = 1e18`, `feeClaim = 0`
- `wethToSwap = 1e18`; the entire amount is swapped to CLAIM and credited as rewards.

5) Fee harvest no-fees guard
- If `feeWeth == 0` AND `feeClaim == 0`, `harvestFeesToRewards(...)` MUST revert.

## Events (required)

- `LpStaked(user, amount)`
- `LpUnbondStarted(user, unbondId, amount, unlockTime)`
- `LpUnbondWithdrawn(user, unbondId, amount)`

Rewards:
- `LpRewardsNotified(amountClaim)`
- `LpRewardsClaimed(user, amountClaim)`
- `LpRewardsLocked(user, amountClaim, principalClaim, bonusClaim, tokenId)`
  - `tokenId` MUST be the actual destination lock id returned by `Furnace.enterWithClaimFor`; when a new lock is minted it MUST be the minted id (not the quote placeholder `0`).

Auto-compound:
- `AutoCompoundConfigured(user, enabled, tokenId, durationSeconds, maxSlippageBps, minRewardToCompound)`
- `AutoCompoundPaused(user, tokenId, reasonCode)`
- `HarvestKeeperSet(keeper, allowed)`

Fee harvest:
- `LpFeesHarvestedToRewards(caller, feeWeth, feeClaim, claimToRewards)`

---

## Security / invariants (high-level)

- No admin drain of LP.
- No sweep/rescue functions.
- Reward accounting MUST be bounded (O(1) per user action).
- Unbond cap enforced (`MAX_UNBONDS_PER_USER`).
- Users cannot withdraw LP before unbond unlock.
- Harvest & Lock (claimRewardsAndLock) MUST be CEI-ordered and `nonReentrant`.
- For each fee harvest:
  - `claimToRewards = feeClaim + swapOutClaim`.
  - No CLAIM is burned as part of fee harvest paths.
- Auto-compound is disabled by default.
  - MUST be opt-in.
  - MUST NOT create new locks.
  - MUST validate destination lock eligibility each attempt.
  - MUST pause-on-invalid destination (emit `AutoCompoundPaused(...)` and no-op).
