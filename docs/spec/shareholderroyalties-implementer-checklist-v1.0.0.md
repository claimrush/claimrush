# ShareholderRoyalties implementer checklist (v1.0.0)

This is an **implementer-focused checklist** for `ShareholderRoyalties`, the ETH index contract for veCLAIM holders (“Barons”).

Source of truth:
- Canonical behavior: `docs/spec/spec-v1.0.0.md` §6 (ShareholderRoyalties)
- Constants and clamps: `src/lib/Constants.sol`
- Rounding + index math: [math and rounding appendix](../architecture/math-and-rounding-appendix-v1.0.0.md)
- Event schema + enum codebook: `docs/analytics/dune-integration-pack-v1.0.0.md`

Spec aids (recommended):
- `docs/spec/state-machines-v1.0.0.md` (ShareholderRoyalties flush + claim diagrams)
- `docs/spec/test-vectors-v1.0.0.md` (§6 ETH index math)

This document restates requirements in an implementable order.

---

## Goals

ShareholderRoyalties MUST:
- Accept ETH allocations from MineCore on takeover (the 25% shareholder share).
- Hold only residual / unindexable ETH in `pendingShareholderETH` (for example zero-shareholder carry, dust, transient carry while `VeClaimNFT.globalLastTs()` is still stale, or deferred carry while checkpoint storage cannot safely represent a new reward timestamp).
- Maintain a global index `ethPerVe` plus historical reward checkpoints so delayed claims for decaying locks remain correct and bounded.
- Allow users to collect accrued ETH rewards via:
  - `ETH` mode (direct ETH withdrawal)
  - `LOCK_FURNACE` mode (forward ETH to Furnace and lock for the user)

Critical v1 constraint (v1.0.0+):
- v1 enforces a per-user veNFT cap (`MAX_VE_NFTS_PER_USER`), so all per-user reward reconstruction from `getShareholderLockParams(user)` remains gas-bounded.
- ShareholderRoyalties MUST still avoid any unbounded “enumerate all holders” style logic; all per-user work MUST remain bounded.

---

## Revert and no-op matrix

These rules are **behavioral contract** for integrators: the same call pattern MUST be safe across normal, edge, and “empty” states.

- `onTakeover(reignId)`:
  - MUST NOT revert when `msg.value == 0` (treat as no-op allocation).
  - MUST revert if caller is not `MineCore`.

- `flushPendingShareholderETH()` (permissionless):
  - MUST NOT revert when `pendingShareholderETH == 0` (no-op).
  - For non-zero pending ETH, MUST fail closed unless the live `Furnace / MarketRouter / MineCore / VeClaimNFT / ClaimToken` bundle still resolves to this exact `ShareholderRoyalties`.
  - MUST NOT revert when `VeClaimNFT.globalLastTs() != block.timestamp` after `checkpointTotalVe()`; this is a defer-and-return path while the ve checkpoint catches up.
  - MUST NOT revert when the processed denominator is zero or rounds below `MIN_VE_FLUSH` (no-op for residual pending ETH).
  - MUST return (no-op) when the computed `deltaEthPerVe == 0` (keep ETH in `pendingShareholderETH`).

- `checkpointUser(user)`:
  - MUST NOT revert for `user == address(0)` and MUST treat it as a no-op (do not write state).
  - MUST be safe when the user has no active or expired-ununlocked locks (updates paid / timestamp prefixes and returns).

- `checkpointTransfer(from, to)`:
  - MUST revert if caller is not `MarketRouter`.
  - MUST be safe when `from == to` (no-op).

- `claimShareholder(mode, ...)`:
  - MUST be `nonReentrant`.
  - MUST be safe when `claimableEth[msg.sender] == 0` (no-op return).
  - MUST revert on invalid `mode`.
  - In `ETH` mode: MUST revert if the ETH transfer fails.
  - In `LOCK_FURNACE` mode: MUST bubble the Furnace revert (atomic).
  - `LOCK_FURNACE` routing MUST reject a miswired Furnace target; user claimable ETH MUST remain intact on failure.

---

## Checklist: required state

Source: spec §6.1.

ShareholderRoyalties MUST track:
- `uint256 ethPerVe` – global index scaled by `ACC = 1e18`.
- `uint256 pendingShareholderETH` – ETH stored until flushed or deferred.
- `RewardCheckpoint[] rewardCheckpoints` with:
  - `cumulativeEthPerVe`
  - `cumulativeTimeWeightedEthPerVe`
- `uint256 ethPerVeTimeWeighted`
- `RewardCheckpoint[] _overflowCheckpoints` (capped at `MAX_OVERFLOW_CHECKPOINTS`; stores post-cap flush snapshots so `_getRewardPrefixBefore` can binary-search overflow history). Becomes a ring buffer with FIFO eviction when full; if a new distinct timestamp cannot be stored safely yet, flush must defer before advancing the indices.
- `uint256 _overflowRingHead` – ring-buffer write head (zero while the overflow array is still growing).
- `mapping(address => uint256) userEthPerVePaid`.
- `mapping(address => uint256) claimableEth`.
- `mapping(address => uint256) userTimeWeightedEthPerVePaid`.
- `mapping(address => uint40) userLastRewardTs`.
- `mapping(address => uint256) userRewardRemainder`.

And hold references to:
- `VeClaimNFT` (MUST provide `checkpointTotalVe()`, `totalVeBiasScaled()`, `globalLastTs()`, and `getShareholderLockParams(user)`).
- `Furnace` (used in `LOCK_FURNACE` mode).

---

## Checklist: access control + call graph

Source: spec §6.2 + §6.5.

Ownership hardening (REQUIRED):
- `renounceOwnership()` MUST always revert. Wiring setters, keeper management, and guardian rotation require a live owner.

Wiring safety guard (REQUIRED):
- `setWiring(...)` MUST attempt to flush pending ETH under the old wiring before switching. If `pendingShareholderETH > 0` after the flush attempt, MUST revert with `Errors.PendingEthNotDrained()`. This prevents rewiring the canonical bundle while unindexed ETH is still pending, which could strand or misattribute shareholder funds.

Gas cap on external ETH forwarding (REQUIRED):
- `_callWithValueNoReturndata` (used by ETH-mode claims and other value-forwarding paths) MUST cap the gas forwarded to the external call at `100_000`. This prevents a malicious or gas-greedy recipient from consuming unbounded gas during batch operations.

- `onTakeover(reignId)` MUST be callable only by MineCore.
- `checkpointTransfer(from,to)` MUST be callable only by MarketRouter and MUST be called **before** veNFT ownership changes.
---

## Checklist: events

Source: analytics pack + spec event list.

Emit canonical events (names + indexed fields MUST match analytics pack):
- `ShareholderTakeoverAllocation(reignId, amountEth)`
- `ShareholderFlush(amountEth, deltaEthPerVe)`
- `ShareholderClaim(user, mode, amountEth)`

Baron auto-compound events (REQUIRED in v1.0.0; emitted when users opt in; SPEC §6.7):
- `ShareholderAutoCompoundConfigured(user, enabled, tokenId, durationSeconds, minCadenceSeconds, minEthToCompound, maxSlippageBps)`
- `ShareholderAutoCompoundKeeperSet(keeper, allowed)`
- `ShareholderAutoCompoundPaused(user, tokenId, reasonCode)`
- `ShareholderAutoCompoundExecuted(user, executor, amountEth, tokenId, effectiveDurationSeconds)`

Mode codebook (MUST be stable):
- `0 = ETH`
- `1 = LOCK_FURNACE`

---

## Checklist: `onTakeover(uint256 reignId)` (payable)

Source: spec §6.2.

- Accept ETH via `msg.value`.
- MUST be safe if `msg.value == 0` (no-op).
- For non-zero ETH, MUST fail closed unless the live `Furnace`, `MarketRouter`, `MineCore`, `VeClaimNFT`, and `ClaimToken` bundle still resolves one canonical Baron bundle rooted at this exact `ShareholderRoyalties`.
- Increase `pendingShareholderETH += msg.value`.
- MUST immediately attempt indexing against the current processed denominator whenever `totalWeight > 0`, even if it rounds below `MIN_VE_FLUSH`.
  - This attempt MAY still return without indexing if `VeClaimNFT.globalLastTs()` remains behind `block.timestamp` after bounded checkpointing; in that case ETH stays in `pendingShareholderETH` until a later flush can use a current timestamp.
  - Rationale: later ve entrants MUST NOT dilute takeover ETH that was generated before they became shareholders, but stale timestamp indexing would let already-expired locks capture post-expiry rewards.
- Emit `ShareholderTakeoverAllocation(reignId, msg.value)`.

---

## Checklist: `flushPendingShareholderETH()`

Source: spec §6.3.

See `docs/spec/test-vectors-v1.0.0.md` §6 for numeric edge cases (delta==0, dust retention).

Algorithm (all rounding MUST be floor):
- If `pendingShareholderETH == 0`, return.
- For non-zero pending ETH, MUST fail closed unless the live `Furnace`, `MarketRouter`, `MineCore`, `VeClaimNFT`, and `ClaimToken` bundle still resolves one canonical Baron bundle rooted at this exact `ShareholderRoyalties`.
- Call `VeClaimNFT.checkpointTotalVe()` in a bounded loop (up to 10 iterations, breaking early if `globalLastTs() == block.timestamp` or `gasleft() < 300_000`).
- Let `rewardTs = VeClaimNFT.globalLastTs()`.
- If `rewardTs != block.timestamp`, return (defer until the ve checkpoint has fully caught up).
- Let `totalWeight = VeClaimNFT.totalVeBiasScaled()`.
- If `totalWeight == 0`, return.
- Let `veTotal = ceilDiv(totalWeight, 1e18)`.
- If `veTotal < MIN_VE_FLUSH`, return.
- If checkpoint storage cannot safely represent `rewardTs` (main array capped, overflow ring capped, oldest overflow entry still within `MAX_LOCK_DURATION`, and no same-block coalesce applies), return **without** modifying `pendingShareholderETH`, `ethPerVe`, or `ethPerVeTimeWeighted`.
- Compute `delta = mulDivDown(pendingShareholderETH, 1e36, totalWeight)`.
- If `delta == 0`, return **without** modifying `pendingShareholderETH`.
- Update `ethPerVe += delta`.
- Update `ethPerVeTimeWeighted += delta * rewardTs`.
- Store the reward checkpoint for `rewardTs`. If `rewardCheckpoints.length >= MAX_REWARD_CHECKPOINTS`, the main array is frozen and the checkpoint is routed to `_overflowCheckpoints` (ring-buffer with FIFO eviction at `MAX_OVERFLOW_CHECKPOINTS`).
- Compute `distributed = mulDivDown(delta, totalWeight, 1e36)`.
- Decrease `pendingShareholderETH -= distributed` (keep remainder dust pending).
- Emit `ShareholderFlush(distributed, delta)`.

Overflow ring-buffer implementation details:
- Once `_overflowCheckpoints` reaches `MAX_OVERFLOW_CHECKPOINTS`, new entries overwrite the oldest via FIFO ring-buffer eviction tracked by `_overflowRingHead` (points to the next slot to overwrite).
- Eviction guard: an entry is only evicted if its timestamp is older than `rewardTs - MAX_LOCK_DURATION`.
- Same-block coalescing applies at all stages: if the last-written overflow entry has the same timestamp as the new entry, cumulative values are updated in place rather than consuming a new slot.
- If all overflow entries are still within the active lock horizon and the new write has a **distinct** timestamp, the flush MUST have deferred earlier. The implementation MUST NOT keep an old timestamp while advancing `cumulativeTimeWeightedEthPerVe`, because that breaks decaying-lock expiry math.
- `_getRewardPrefixBefore` uses modular-index binary search to traverse the circular buffer: logical indices are translated to physical indices via `(logicalIdx + _overflowRingHead) % ovLen`.

Rationale:
- Prevents rounding-to-zero grief.
- Keeps residual pending ETH safe while canonical takeover allocations are indexed immediately once the checkpoint timestamp is current.
- Preserves correctness for delayed checkpoints on decaying locks.
- Ensures total claimable via the index never exceeds ETH deposited.

---

## Checklist: `checkpointUser(address user)`

Source: spec §6.4.

- Let `idx = ethPerVe`, `paid = userEthPerVePaid[user]`.
- If `idx == paid`, return.
- Load `(amounts, lockEnds, autoMaxFlags)` from `VeClaimNFT.getShareholderLockParams(user)`.
- MUST fail closed unless the live `Furnace`, `MarketRouter`, `MineCore`, `VeClaimNFT`, and `ClaimToken` still resolve one canonical Baron bundle rooted at this exact `ShareholderRoyalties`.
- For each lock:
  - AutoMax lock:
    - accrue against all unprocessed `deltaEthPerVe`.
  - Decaying lock:
    - only reward checkpoints with `rewardTs < lockEnd` count.
    - use prefix sums of `deltaEthPerVe` and `deltaEthPerVe * rewardTs`.
    - equivalently: `accrued = floor(slopeScaled(amount) * (lockEnd * Δidx - ΔtimeWeightedIdx) / 1e36)`.
- Add the whole-wei result to `claimableEth[user]`.
- Carry the sub-wei remainder forward in `userRewardRemainder[user]`.
- Set:
  - `userEthPerVePaid[user] = ethPerVe`
  - `userTimeWeightedEthPerVePaid[user] = ethPerVeTimeWeighted`
  - `userLastRewardTs[user] = latestRewardTs`

Constraints (required):
- MUST NOT revert due to rounding edge cases.
- Floor rounding only at ETH-credit boundaries.
- VeClaimNFT MUST checkpoint ShareholderRoyalties before every ve mutation, otherwise delayed reward reconstruction becomes invalid.

---

## Checklist: `checkpointTransfer(address from, address to)`

Source: spec §6.5.

- Callable only by MarketRouter.
- MUST be called **before** veNFT ownership changes.
- If `from == to`, return.
- Execute:
  1) `checkpointUser(from)`
  2) `checkpointUser(to)`
- Because `checkpointTransfer` delegates to `checkpointUser`, it MUST also fail closed when the live market/core/claim bundle drifts away from this royalties root.

Goal: no retroactive rewards to new lock owners.

---

## Checklist: `claimShareholder(uint8 mode, uint256 targetTokenId, uint256 durationSeconds, bool createAutoMax, uint256 minVeOut)`

Source: spec §6.6.

Constraints (required):
- MUST be `nonReentrant`.
- MUST follow CEI ordering: checkpoint → read amount → clear → external call.
- MUST fail closed unless the live `Furnace`, `MarketRouter`, `MineCore`, `VeClaimNFT`, and `ClaimToken` still resolve one canonical Baron bundle rooted at this exact `ShareholderRoyalties`.

Flow:
1) `checkpointUser(msg.sender)`
2) `amount = claimableEth[msg.sender]`
3) If `amount == 0`, return
4) Set `claimableEth[msg.sender] = 0`
5) Mode handling:
   - If `mode == ETH`:
     - Send `amount` wei ETH to `msg.sender` using `call` and revert on failure.
     - Ignore `targetTokenId`, `durationSeconds`, `createAutoMax`, `minVeOut`.
   - If `mode == LOCK_FURNACE`:
     - Call `Furnace.lockEthReward{value: amount}(msg.sender, amount, targetTokenId, durationSeconds, createAutoMax, minVeOut)`.
     - MUST bubble reverts (full tx reverts; claimable not lost).
   - Otherwise: revert invalid `mode`.
6) Emit `ShareholderClaim(msg.sender, mode, amount)`.

---

## Checklist: views

These views are part of the v1.0.0 surface area (see spec §11 views) and are REQUIRED for UI/keepers:
- `getShareholderState(user)` MUST return:
  - the authoritative live claim preview (stored `claimableEth` plus uncheckpointed rewards implied by historical reward checkpoints)
  - `VeClaimNFT.veBalanceOf(user)`
  - `userEthPerVePaid[user]`
- Offchain clients MUST treat the first field as authoritative and MUST NOT add a separate `currentVe * (ethPerVe - paid)` term.

- `getAutoCompoundConfig(user)` MUST return:
  - `enabled`, `paused`
  - `tokenId`
  - `durationSeconds`, `minCadenceSeconds`, `minEthToCompound`, `maxSlippageBps`, `lastCompoundTs`

---

## Keeper-allowlisted auto-compound (SPEC §6.7)

This feature is shipped in v1.0.0.

Clarification (in-scope surface and behavior):
- The onchain config + executors + events/views are part of the v1.0.0 contract surface (in scope).
- Opt-in is per user (disabled by default).
- Execution is keeper-allowlisted: callable by `owner` and addresses enabled via `setAutoCompoundKeeper(keeper, allowed)`.
- Running official keepers is an ops choice; users can always claim manually if no keeper is running.

Constants (REQUIRED):
- `MAX_AUTOCOMPOUND_SLIPPAGE_BPS = 2000` — promoted to `uint32 internal constant` for gas efficiency and ABI stability.

Key constraints (MUST):
- No economics change (same claimable ETH; same Furnace rules).
- MUST NOT create new locks as a fallback in v1.
- On downstream Furnace reverts, per-user accounting MUST either revert atomically (`compoundFor`) or be restored (`compoundForMany`). Canonical Baron-bundle drift discovered by `checkpointUser(user)` MUST instead fail closed before any per-user accounting mutation.

### State (REQUIRED)

Recommended per-user struct:

- `enabled`, `paused`
- `tokenId` (destination veNFT; MUST be existing)
- `durationSeconds` (target remaining duration; clamped to current remaining by Furnace for non-AutoMax locks)
- `minCadenceSeconds`, `minEthToCompound`, `maxSlippageBps`, `lastCompoundTs`

### Setter (REQUIRED): `setAutoCompoundConfig(...)`

- Callable by the user for self config.
- Shipped code companion: `setAutoCompoundConfigForUser(user, ...)` (requires `P_SET_SHAREHOLDER_AUTOCOMPOUND_CONFIG_FOR`).
  - Delegated auth MUST fail closed unless the live `Furnace`, `MarketRouter`, `MineCore`, `VeClaimNFT`, and `ClaimToken` still resolve one canonical Baron bundle and the live Furnace/MineCore pair still agree on one canonical `DelegationHub`; a raw `Furnace.delegationHub()` read is insufficient.
- On enable:
  - Require `tokenId` exists and is owned by the configured user (`msg.sender` on the self path; `user` on the delegation-gated path).
  - Require destination is unlisted and unexpired.
  - Enforce duration clamps; if destination is AutoMax, require `durationSeconds == MAX_LOCK_DURATION`.
- On disable:
  - MUST clear `paused`.
  - MUST clear `lastCompoundTs` (reset cadence state).
  - Clarification (non-binding): It is allowed to also clear destination fields.
- Emit `ShareholderAutoCompoundConfigured`.

### Keeper allowlist admin (REQUIRED): `setAutoCompoundKeeper(address keeper, bool allowed)`

- Callable by owner only.
- MUST reject `keeper == address(0)`.
- MUST set allowlist membership for auto-compound executors.
- MUST emit `ShareholderAutoCompoundKeeperSet(keeper, allowed)`.

### Executor (REQUIRED): `compoundFor(user)`

Reentrancy (duplicate, see above):
- MUST be `nonReentrant`.

Authorization:
- Caller MUST be `owner` or an allowlisted auto-compound keeper.

Cadence (MUST):
- If `lastCompoundTs != 0`, enforce `block.timestamp >= lastCompoundTs + minCadenceSeconds`.
  - `lastCompoundTs == 0` means “never successfully compounded” and MUST NOT block the first compound.

Flow (MUST):
1) `checkpointUser(user)`
   - This inherits the same canonical Baron-bundle fail-closed behavior as manual checkpoint / claim.
2) Read `amount = claimableEth[user]`.
3) If `amount == 0` or `amount < minEthToCompound`, return.
4) Validate destination lock at execution time:
   - owned by user
   - not listed
   - not expired
   - AutoMax invariants still hold
5) If destination invalid:
   - set `paused = true`
   - emit `ShareholderAutoCompoundPaused(user, tokenId, reasonCode)`
   - return (do not revert)
6) Compute effective duration:
   - `effectiveDurationSeconds = max(config.durationSeconds, remainingDurationSeconds(tokenId))`
   - AutoMax forces `MAX_LOCK_DURATION`
7) Quote + CEI ordering:
   - compute `minVeOut` from the live quote and the user’s stored `maxSlippageBps`
   - if the quote call fails, `compoundFor(user)` MUST revert rather than execute without a floor
   - set `claimableEth[user] = 0`
   - set `lastCompoundTs = now`
   - call `Furnace.lockEthReward{value: amount}(user, amount, tokenId, effectiveDurationSeconds, false, minVeOut)`
   - bubble Furnace reverts (atomic; claimable not lost)
8) Emit:
   - `ShareholderAutoCompoundExecuted(user, msg.sender, amount, tokenId, effectiveDurationSeconds)`
   - and a normal `ShareholderClaim(user, LOCK_FURNACE, amount)` for analytics consistency.

### Batch executor: `compoundForMany(users, maxUsers)`

Goal:
- Allow the official maintainer/keeper bot to compound multiple opted-in users in a single transaction while preserving per-user safety.

Input rules (MUST):
- MUST be gas-bounded:
  - Let `usersN = min(users.length, min(maxUsers, MAX_SHAREHOLDER_COMPOUND_USERS_PER_CALL))`.
  - Iterate only over `[0..usersN)`.
- MUST NOT iterate over all users onchain (caller supplies explicit worklist).
- The ABI has no per-user `minVeOut[]` companion array; slippage floors are derived on-chain per user.

Reentrancy (duplicate, see above):
- MUST be `nonReentrant`.

Authorization:
- Caller MUST be `owner` or an allowlisted auto-compound keeper.

Best-effort semantics (MUST):
- Canonical Baron-bundle check (`_requireCanonicalBaronRuntimeBundle`) runs once at the top and reverts the whole call if wiring is broken.
- Per-user: checkpoint failure → pauses that user (reason `CHECKPOINT_FAILED = 7`), continues batch.
- Per-user: quote failure → **skips** that user (emits `ShareholderAutoCompoundFailed`), continues batch. Does NOT pause the config, allowing retry on next cadence.
- Per-user: downstream Furnace call revert → pauses that user (reason `FURNACE_REVERT = 5`), restores user accounting, continues batch.

Events (MUST):
- Reuse the single-user events:
  - MUST emit `ShareholderAutoCompoundExecuted` and `ShareholderClaim(..., LOCK_FURNACE, ...)` per successful user.
  - MUST emit `ShareholderAutoCompoundPaused` when a user is paused due to invalid destination.

Reason codes (REQUIRED; canonical and immutable once deployed; see `docs/analytics/dune-integration-pack-v1.0.0.md`):
- `1` = `NOT_OWNER`
- `2` = `LISTED`
- `3` = `EXPIRED`
- `4` = `INVALID_TOKEN_ID`
- `5` = `FURNACE_REVERT` (downstream Furnace call failed; user accounting restored)
- `6` = `QUOTE_FAILED` (quote call failed for this user)
- `7` = `CHECKPOINT_FAILED` (checkpoint failed for this user)

---

## Worked examples (sanity checks)

These are non-normative examples to help implementers and reviewers catch rounding mistakes.

### Example A: flush distributes full pending amount

Assume:
- `SHAREHOLDER_ACC = 1e36`
- processed total ve = `200e18`, so `totalWeight = 200e36`
- `pendingShareholderETH = 1e18` wei (1 ETH)

Compute:
- `delta = floor(pending * SHAREHOLDER_ACC / totalWeight)
        = floor(1e18 * 1e36 / 200e36)
        = 5e15`
- `distributed = floor(delta * totalWeight / SHAREHOLDER_ACC)
              = floor(5e15 * 200e36 / 1e36)
              = 1e18`

So:
- `ethPerVe` increases by `5e15`
- `pendingShareholderETH` decreases by `1e18` (to 0)

### Example B: “delta == 0” dust protection

Assume:
- processed total ve = `MIN_VE_FLUSH = 100e18`, so `totalWeight = 100e36`
- `pendingShareholderETH = 99` wei

Compute:
- `delta = floor(99 * 1e36 / 100e36) = 0`

So:
- `flushPendingShareholderETH()` MUST return (no state changes)
- `pendingShareholderETH` stays `99` wei until enough ETH accumulates

### Example C: checkpoint accrues floor-rounded claimable ETH for a constant-weight lock

Assume:
- User has a single AutoMax / constant-weight lock with `amount = 50e18`
- `paid = 0`
- `idx = 5e15`

Compute:
- constant-weight lock weight = `amount * SHAREHOLDER_WEIGHT_SCALE = 50e18 * 1e18`
- `accrued = floor(amount * 1e18 * (idx - paid) / 1e36)
          = floor(50e18 * 1e18 * 5e15 / 1e36)
          = 2.5e17` wei (0.25 ETH)

So:
- `claimableEth[user] += 0.25 ETH`
- `userEthPerVePaid[user] = 5e15`

Important:
- Non-AutoMax decaying locks MUST NOT be settled from current `veBalanceOf(user)` alone.
- They require historical reward-checkpoint timestamps plus the time-weighted prefix sums described above.

---

## Checklist: minimum tests

Flush:
- Residual pending ETH below threshold: manual `flushPendingShareholderETH()` returns with no changes.
- Takeover below threshold with an existing processed denominator indexes immediately and later entrants cannot capture it.
- `pendingShareholderETH == 0` returns with no changes.
- `delta == 0` returns with no changes and keeps pending dust.
- Correct `ethPerVe` delta and distributed amount with rounding down.

Checkpointing:
- `checkpointUser` accrues correctly and is idempotent when `ethPerVe` unchanged.
- `checkpointTransfer(from,to)` checkpoints both sides and prevents retroactive capture.
- `checkpointUser(address(0))` is a no-op and does not revert.
- `checkpointTransfer(from, from)` (same address) is a no-op.

Claiming:
- ETH mode sends ETH and clears claimable.
- LOCK_FURNACE mode calls Furnace with the correct parameters and is atomic on revert (`minVeOut` revert does not lose claimable).
- Reentrancy guard: attacker cannot reenter claim to drain.
- Invalid mode (e.g. mode == 2) reverts with `InvalidMode` and preserves claimable.

Views:
- `getShareholderState(user)` returns the authoritative live preview including uncheckpointed rewards.
- `getShareholderState(address(0))` returns zeros.
- `getShareholderState` is idempotent (repeated calls return the same value).

Auto-compound (REQUIRED feature; executed only for opted-in users):
- Config set/clear stores expected fields and clears `paused`.
- Keeper allowlist:
  - owner can add/remove keepers via `setAutoCompoundKeeper`.
  - only owner/allowlisted keepers may execute `compoundFor` and `compoundForMany`.
- Cadence:
  - reverts when called before `minCadenceSeconds` since last success.
- Threshold:
  - no-op when below `minEthToCompound`.
- Destination invalidation (skip + pause):
  - pauses when destination is sold/not owned.
  - pauses when destination is listed.
  - pauses when destination is expired.
- Atomic revert:
  - if Furnace reverts (e.g., `minVeOut`), claimable and `lastCompoundTs` are not lost.

## Checklist: config freeze (`configFrozen` / `freezeConfig()`)

- `bool public configFrozen` — one-way flag, default `false`.
- `modifier whenNotFrozen()` — reverts `Errors.ConfigFrozen()` if `configFrozen == true`.
- Frozen setters (MUST have `whenNotFrozen`):
  - `setWiring(address _mineCore, address _mineMarket, address _furnace)` — `onlyOwner whenNotFrozen`
  - `setClaimAllHelper(address)` — `onlyOwner whenNotFrozen`
- `freezeConfig()` — `onlyOwner whenNotFrozen`:
  - MUST revert if `mineCore == address(0)`
  - MUST revert if `mineMarket == address(0)`
  - MUST revert if `address(furnace) == address(0)`
  - MUST revert if `claimAllHelper == address(0)` or `claimAllHelper.code.length == 0`
  - MUST revert if `ClaimAllHelper.royalties() != address(this)` or `ClaimAllHelper.mineCore() != mineCore` or `MineCore.claimAllHelper() != claimAllHelper`
  - MUST verify the full canonical Baron runtime bundle via `_requireCanonicalBaronRuntimeBundle()`
  - Sets `configFrozen = true`
  - Emits `Events.ConfigFrozen()`
- NOT frozen (remain `onlyOwner` after freeze):
  - `setAutoCompoundKeeper`
