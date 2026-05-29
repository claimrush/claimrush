# LpStakingVault7D implementer checklist (v1.0.0)

This is an **implementer-focused checklist** for the LP staking incentives vault (`LpStakingVault7D`).

**Constraint (required):** v1.0.0 enforces `UNBONDING_PERIOD = 7 days`.

Source of truth:
- Contract spec (canonical): `docs/spec/lp-staking-vault-spec.md`
- Reward funding sources:
  - Furnace gross bonus split: `docs/spec/spec-v1.0.0.md` (Furnace section)

Spec aids (recommended):
- `docs/spec/spec-quality-standard-v1.0.0.md`

This document **does not introduce new rules**. It restates MUST/MUST NOT requirements in an order suitable for incremental implementation and review.

---

## Goals

LpStakingVault7D MUST:
- Accept stakes of the canonical Aerodrome v2 WETH/CLAIM volatile LP token.
- Pay liquid CLAIM rewards to LP stakers.
- Enforce a Cosmos-like unbond model:
  - `UNBONDING_PERIOD = 7 days`
  - Unbonded amounts stop earning rewards immediately.
  - Matured unbonds are withdrawable only after unlock.
- Cap user unbond entries:
  - `MAX_UNBONDS_PER_USER = 25`
- Use O(1) reward-per-token style accounting (no loops over all stakers).

LpStakingVault7D MUST NOT:
- Provide admin drains of LP.
- Include sweep/rescue functions.

Ownership hardening (REQUIRED):
- `renounceOwnership()` MUST always revert with `Errors.NotAuthorized()`. Wiring setters, harvest keeper management, and auto-compound keeper management require a live owner.

---

## Checklist: core constants (v1.0.0)

From `Constants.sol` (LP vault section):
- `UNBONDING_PERIOD = 7 days`
- `MAX_UNBONDS_PER_USER = 25`

From `Constants.sol` (used by harvest swap floor and LP auto-compound defaults):
- `BPS_DENOM = 10_000`
- `HARVEST_MAX_SLIPPAGE_BPS = 100` (1%; on-chain sanity floor for WETH→CLAIM harvest swap vs spot quote — not sandwich-proof)
- `DEFAULT_LP_AUTOCOMPOUND_MAX_SLIPPAGE_BPS = 300` (3%; used when user sets `maxSlippageBps = 0` in auto-compound config)
- `MAX_LP_COMPOUND_USERS_PER_CALL = 50` (hard cap for `compoundForMany`, in addition to caller `maxUsers`)

Fee harvest to rewards is REQUIRED in v1.0.0; contract-local constants (see `LpStakingVault7D.sol`):
- `MIN_COMPOUND_INTERVAL = 1 days` (cooldown for auto-compound via `lastCompoundTs` and for manual lock via `lastUserLockTs`; these are independent per-user cooldowns)
- `minCompoundReward` (owner-settable global floor; default 1e18 = 1 CLAIM; auto-compound skips below this — no pause; adjustable via `setMinCompoundReward(uint256)`)
- `MAX_HARVEST_DEADLINE = 10 minutes` (`harvestFeesToRewards` requires `deadline` in `[block.timestamp, block.timestamp + MAX_HARVEST_DEADLINE]`)

**Not in this contract:** there is no `freezeConfig` / `configFrozen` (immutable roots + owner setters only; delegated auto-compound config uses `DelegationHub` as documented below).

---

## Checklist: staking state and accounting

Recommended minimum state for the shipped v1.0.0 contract:
- Global:
  - `totalStaked` (LP currently earning rewards)
  - `rewardPerTokenStored` (CLAIM per staked LP, scaled)
  - `accountedRewardBalance` (already-accounted CLAIM balance, including queued rewards)
  - `queuedRewards` (reward delta parked while `totalStaked == 0`)
- Per user:
  - `stakedBalance[user]`
  - `userRewardPerTokenPaid[user]`
  - `rewards[user]` (claimable CLAIM)
- Unbonding:
  - `unbonds[user][]` entries `{id, amount, unlockTime}` (`id` is the stable `unbondId` emitted in events; array order may change after `withdrawMatured` due to swap-and-pop)

Policy:
- Reward notifications MUST be based on actual CLAIM balance delta to avoid over-reporting.
- The shipped v1.0.0 implementation uses balance-delta accounting only; it does **not** use `lastUpdateTime`, `rewardRate`, or `rewardFinishAt` schedule variables.
- If `totalStaked == 0`, newly observed reward delta MUST be added to `queuedRewards` and distributed once staking resumes.
- Reward checkpointing MUST flush `queuedRewards` even when there is no new balance delta, provided `totalStaked > 0`. This prevents queued rewards from being stranded when external balance changes do not trigger a new delta.
- Clarification (non-binding): A safe implementation pattern is transfer-then-notify (measure delta after transfer) to make the delta deterministic.

---

## Checklist: stake(amount)

Signature: `stake(uint256 amount) external nonReentrant`

From `lp-staking-vault-spec.md` “User actions”.

MUST:
- Update rewards for `msg.sender` before mutating stake.
- Transfer LP from user → vault.
- Increase `stakedBalance[msg.sender]` and `totalStaked`.
- If `queuedRewards != 0` and staking is live again after the mutation, distribute the queued amount into the reward index.
- Emit `LpStaked(user, amount)`.

---

## Checklist: beginUnbond(amount)

Signature: `beginUnbond(uint256 amount) external nonReentrant`

MUST:
- Update rewards for `msg.sender` before mutating stake.
- Require `amount > 0` and `stakedBalance[msg.sender] >= amount`.
- Enforce unbond cap:
  - revert if active unbond entries for user already equals `MAX_UNBONDS_PER_USER`.
- Dust auto-round: if after subtracting `amount` from `stakedBalance[msg.sender]` the residual stake would be less than `MIN_UNBOND_AMOUNT`, auto-unbond the full remaining balance instead (prevents dust from being stranded).
- Decrease `stakedBalance[msg.sender]` and `totalStaked` immediately (stops earning rewards).
- Append a new unbond entry:
  - `unlockTime = block.timestamp + UNBONDING_PERIOD`
- Emit `LpUnbondStarted(user, unbondId, amount, unlockTime)`.

---

## Checklist: withdrawMatured()

Signature: `withdrawMatured() external nonReentrant`

MUST:
- Withdraw all matured unbond entries for the caller.
- Only withdraw entries with `block.timestamp >= unlockTime`.
- For each withdrawn entry:
  - transfer LP to the user
  - delete/close the entry so it no longer counts toward the cap
  - emit `LpUnbondWithdrawn(user, unbondId, amount)`

Bounded loop rule:
- The loop is bounded by `MAX_UNBONDS_PER_USER` (25), so worst-case gas is controlled.

Behavior (shipped):
- If no matured liquidity to withdraw (`totalOut == 0`), the call returns without transfer and without `LpUnbondWithdrawn` events.

---

## Checklist: claimRewards()

Signature: `claimRewards() external nonReentrant`

MUST:
- Update rewards for `msg.sender`.
- If claimable reward is zero: return without transfer and **without** emitting `LpRewardsClaimed`.
- Otherwise: transfer claimable CLAIM to the user, zero the user’s claimable balance, decrement accounted reward balance accordingly, and emit `LpRewardsClaimed(user, amountClaim)`.

---

## Checklist: claimRewardsAndLock(targetTokenId, durationSeconds, createAutoMax, minVeOut)

Signature: `claimRewardsAndLock(uint256 targetTokenId, uint256 durationSeconds, bool createAutoMax, uint256 minVeOut) external nonReentrant`

From `lp-staking-vault-spec.md` “claimRewardsAndLock”.

Goal:
- Harvest user rewards, then route them through Furnace so the Furnace bonus applies normally.

Rules (MUST):
- MUST provide slippage protection via `minVeOut`.
- MUST enforce per-user cooldown: revert `LockCooldown()` if `block.timestamp < lastUserLockTs[user] + MIN_COMPOUND_INTERVAL` (`MIN_COMPOUND_INTERVAL = 1 days`). On success, update `lastUserLockTs[user]` to `block.timestamp`. Note: this is independent from the `lastCompoundTs` cooldown used by auto-compound.
- If `targetTokenId == 0` (create a new lock through Furnace):
  - the resulting lock principal MUST satisfy the protocol minimum size:
    - `amountLocked >= MIN_LOCK_AMOUNT = 1_000e18`
  - if the claimable rewards (+ Furnace bonus) are below minimum: MUST revert.
- If `targetTokenId != 0` (compound into existing lock):
  - `durationSeconds` is passed to Furnace which clamps it to the lock's current remaining duration for non-AutoMax locks. Entry does not change the lock's duration.
- `createAutoMax` is only allowed when:
  - `targetTokenId == 0` AND `durationSeconds == MAX_LOCK_DURATION`
  - else MUST be false.

Expected call path:
- `LpStakingVault7D` calls:
  - `Furnace.enterWithClaimFor(user, claimAmount, targetTokenId, durationSeconds, createAutoMax, minVeOut)`

MUST emit:
- `LpRewardsLocked(user, amountClaim, principalClaim, bonusClaim, tokenId)` (see spec)
  - `tokenId` MUST be the actual destination lock id returned by `Furnace.enterWithClaimFor`; when a new lock is minted it MUST be the minted id (not the quote placeholder `0`).

Behavior (shipped):
- If claimable reward is zero: return early without Furnace call, without updating `lastCompoundTs`, and without emitting `LpRewardsLocked`.
- `principalClaim` / `bonusClaim` in the event may be zero if the Furnace quoter call fails (outer `enterWithClaimFor` still runs with user `minVeOut`).

---

## Auto-compound into Furnace (IN SCOPE for v1.0.0, OFF by default)

From `lp-staking-vault-spec.md` “Auto-compound into Furnace”.

Goal:
- Allow LP stakers to opt in to automated compounding of their LP rewards into veCLAIM via Furnace.

Surfaces (MUST exist):
- User config:
  - `setAutoCompoundConfig(bool enabled, uint256 tokenId, uint256 durationSeconds, uint32 maxSlippageBps, uint256 minRewardToCompound) external nonReentrant`
  - shipped code companion: `setAutoCompoundConfigForUser(address user, bool enabled, uint256 tokenId, uint256 durationSeconds, uint32 maxSlippageBps, uint256 minRewardToCompound) external nonReentrant` (requires `P_SET_LP_AUTOCOMPOUND_CONFIG_FOR`)
    - delegated auth MUST resolve the canonical hub through the live Furnace + MineCore bundle, not an untrusted raw `Furnace.delegationHub()` pointer, and MUST reject split-brain `MineCore.furnace() != Furnace` wiring before trusting the session
    - on success, MUST also emit `DelegationSessionUsed(user, delegate, actionType, permsUsed, refId, timestamp)` with action type `LP_STAKING_SET_AUTOCOMPOUND_CONFIG_FOR` (see `DelegationActionTypes.sol`)
- View: `getAutoCompoundConfig(address user) external view returns (bool enabled, bool paused, uint256 tokenId, uint256 durationSeconds, uint32 maxSlippageBps, uint256 minRewardToCompound)`
- Executor:
  - `compoundFor(address user) external nonReentrant onlyHarvestKeeper`
  - `compoundForMany(address[] calldata users, uint256 maxUsers) external nonReentrant onlyHarvestKeeper` (best-effort per user; effective user count is `min(users.length, maxUsers, MAX_LP_COMPOUND_USERS_PER_CALL)`)

Policy (MUST):
- Does not create new locks (`tokenId != 0` at config time; execution-time `tokenId == 0` => pause with reason invalid token).
- Uses Policy 2 behavior:
  - invalid destination lock at execution time => skip + pause.
- [ ] Auto-compound pauses (`AutoCompoundPaused`, EXPIRED reason) instead of clamping duration upward when the destination lock has `< MIN_LOCK_DURATION` remaining (non-AutoMax).

Slippage / sizing (shipped):
- Config-time: if `enabled`, require `maxSlippageBps <= 1000` (10%); else revert `SlippageTooHigh()`. `0` means “use default” at execution: `DEFAULT_LP_AUTOCOMPOUND_MAX_SLIPPAGE_BPS` (300), clamped to at most `BPS_DENOM` when computing `minVeOut`.
- Execution-time: `minVeOut` is derived from Furnace quoter × `(BPS_DENOM - slippageBps) / BPS_DENOM`, with minimum `1` when quote `veOut > 0` but rounding would yield `0`. Keeper cannot set `minVeOut` manually on this path.
- Per-user cooldown: skip (no pause) if `block.timestamp < lastCompoundTs[user] + MIN_COMPOUND_INTERVAL`.
- Skip (no pause) if `rewards[user] < minCompoundReward` (owner-settable; default 1 CLAIM).
- On successful compound: emit `LpRewardsLocked` (same shape as manual claim-and-lock). On Furnace revert: restore rewards, set `paused`, emit `AutoCompoundPaused` with `SHAREHOLDER_AUTOCOMPOUND_PAUSE_REASON_FURNACE_REVERT`. Do NOT advance `lastCompoundTs[user]` (consistent with main spec §6.7.4 and ShareholderRoyalties behavior; the `paused` flag already prevents retry griefing).
- Expected execution (ops): official maintainer bot calls:
  - preferred: `compoundForMany(...)`
  - fallback: `compoundFor(...)`
  - Execute directly (NOT via `MaintenanceHub`).

MUST emit:
- `AutoCompoundConfigured(address indexed user, bool enabled, uint256 tokenId, uint256 durationSeconds, uint32 maxSlippageBps, uint256 minRewardToCompound)`
- `AutoCompoundPaused(address indexed user, uint256 tokenId, uint8 reasonCode)` (reason codes: `Constants.SHAREHOLDER_AUTOCOMPOUND_PAUSE_REASON_*`)

---

## Rewards notifier (Furnace + self-notify from harvest)

Signature: `notifyRewards(uint256 amountClaim) external nonReentrant onlyRewardNotifier`

- The `amountClaim` parameter is **not trusted**; rewards are applied via balance delta (`claim.balanceOf(this)` vs `accountedRewardBalance`).
- `onlyRewardNotifier`: `msg.sender` MUST be `furnace` OR `address(this)` (harvest path self-notify).

---

## Fee harvest to rewards (REQUIRED, owner-or-keeper-allowlisted)

It MUST follow `lp-staking-vault-spec.md` “Fee harvest to rewards” policy:
- Before claiming current LP fees, checkpoint any pre-existing unaccounted CLAIM balance through the same balance-delta notifier path.
  - Rationale: prior best-effort Furnace `notifyRewards(...)` failures can leave real CLAIM sitting in the vault.
  - That pre-checkpointed balance MUST NOT be counted as this harvest's `feeClaim` / `claimToRewards`.
- Collect Aerodrome fees from this vault’s LP position.
- Swap WETH → CLAIM with `minClaimOut` and `deadline`.
  - Signature: `harvestFeesToRewards(uint256 deadline, uint256 minClaimOut) external nonReentrant onlyHarvestKeeper`
  - `deadline` MUST satisfy `deadline >= block.timestamp` AND `deadline <= block.timestamp + MAX_HARVEST_DEADLINE` (`MAX_HARVEST_DEADLINE = 10 minutes`), else `DeadlineTooFar()`.
  - If `wethToSwap == 0`, the shipped runtime ignores `minClaimOut`; effective swap min out is `0`.
  - If `wethToSwap > 0`, caller MUST pass non-zero `minClaimOut` (`MinClaimOutRequired()`); effective minimum is `max(callerMin, onChainFloor)` where on-chain floor uses `getAmountsOut` and `HARVEST_MAX_SLIPPAGE_BPS`. Owner-set `minHarvestClaimFloor` MUST also be met when non-zero (`MinClaimFloorNotMet()`). Grossly inconsistent caller min vs quote can revert `CallerQuoteDivergence()`. Quote failure reverts `HarvestQuoteFailed()`.
- Credit `claimToRewards = feeClaim + swapOutClaim` as rewards.
- Restrict execution to owner-managed harvest keepers (owner MAY always execute).
- Modifiers: `onlyHarvestKeeper` — `msg.sender == owner() || isHarvestKeeper[msg.sender]`.
- Expose owner-only: `setHarvestKeeper(address keeper, bool allowed)` (zero `keeper` reverts); `setMinHarvestClaimFloor(uint256 floor)` (absolute CLAIM floor for harvest swaps).
- Emit `LpFeesHarvestedToRewards(address indexed caller, uint256 feeWeth, uint256 feeClaim, uint256 claimToRewards)`.

## Preview helper (REQUIRED for automation)

From `lp-staking-vault-spec.md` “Fee harvest to rewards”.

MUST exist:
- `previewHarvestFeesToRewards() external view returns (uint256 feeWeth, uint256 feeClaim, uint256 expectedClaimOut)`

Rules (MUST):
- MUST be `view`.
- MUST NOT claim fees from the pool (no `claimFees()`/`getReward()` calls).
- `feeClaim` MUST report the current unaccounted CLAIM balance after excluding the already-accounted rewards reserve; it MUST NOT naively mirror the vault's full CLAIM balance.
- `expectedClaimOut` is a best-effort router quote for swapping `feeWeth`.
  - If the router quote call reverts, `expectedClaimOut` MUST be returned as `0`.

---

## Additional external API (shipped; UI / integrations)

- `earned(address user) external view returns (uint256)` — includes pending balance-delta and queued rewards in the effective reward-per-token snapshot.
- `getUnbondCount(address user) external view returns (uint256)`
- `getUnbondByIndex(address user, uint256 index) external view returns (uint256 unbondId, uint256 amount, uint256 unlockTime)` — swap-and-pop removes withdrawn entries, so only active entries are returned.
- Public immutables and counters as in `ILpStakingVault7D.sol` (e.g. `lpToken`, `weth`, `claim`, `ve`, `furnace`, `totalClaimRewardsClaimed`, …).
- `Ownable2Step`: `transferOwnership`, `acceptOwnership`, `pendingOwner`, etc.

---

## Checklist: required events (v1.0.0)

From `lp-staking-vault-spec.md`.

Staking/unbond (indexed params per `Events.sol`):
- `LpStaked(address indexed user, uint256 amount)`
- `LpUnbondStarted(address indexed user, uint256 indexed unbondId, uint256 amount, uint256 unlockTime)`
- `LpUnbondWithdrawn(address indexed user, uint256 indexed unbondId, uint256 amount)`

Rewards:
- `LpRewardsNotified(uint256 amountClaim)`
- `LpRewardsClaimed(address indexed user, uint256 amountClaim)`
- `LpRewardsLocked(address indexed user, uint256 amountClaim, uint256 principalClaim, uint256 bonusClaim, uint256 tokenId)`
  - `tokenId` MUST be the actual destination lock id returned by `Furnace.enterWithClaimFor`; when a new lock is minted it MUST be the minted id (not the quote placeholder `0`).
- `HarvestKeeperSet(address indexed keeper, bool allowed)`

Delegated auto-compound config (when using `setAutoCompoundConfigForUser`):
- `DelegationSessionUsed(address indexed user, address indexed delegate, uint8 indexed actionType, uint256 permsUsed, uint256 refId, uint256 timestamp)`

Auto-compound (OFF by default):
- `AutoCompoundConfigured(address indexed user, bool enabled, uint256 tokenId, uint256 durationSeconds, uint32 maxSlippageBps, uint256 minRewardToCompound)`
- `AutoCompoundPaused(address indexed user, uint256 tokenId, uint8 reasonCode)`

Fee harvest:
- `LpFeesHarvestedToRewards(address indexed caller, uint256 feeWeth, uint256 feeClaim, uint256 claimToRewards)`
