# VeClaimNFT implementer checklist (v1.0.0)

This is an **implementer-focused checklist** for `VeClaimNFT` (veCLAIM).

Source of truth:
- Canonical behavior: `docs/spec/spec-v1.0.0.md` §4 (VeClaimNFT)
- Constants: `src/lib/Constants.sol` (MIN/MAX lock durations, checkpoint bounds)
- Rounding rules: [math and rounding appendix](../architecture/math-and-rounding-appendix-v1.0.0.md)

Spec aids (recommended):
- `docs/spec/state-machines-v1.0.0.md` (VeClaimNFT lock lifecycle diagram)
- `docs/spec/test-vectors-v1.0.0.md` (§7 ve math)

This document is a restatement of requirements, ordered for implementation and review.

---

## Goals

VeClaimNFT MUST:
- Represent locks as ERC721 positions.
- Compute `ve` as time-weighted principal, with deterministic rounding.
- Support:
  - user lifecycle ops (create, add, extend, merge, unlock)
  - protocol routing hooks used by Furnace (create/add/extend on behalf of users)
- Provide global aggregates for MineCore finalization:
  - `checkpointGlobalState()` + `checkpointTotalVe()`
  - `totalVeCached()` that is safe to snapshot during takeovers

---

## Revert and no-op matrix

These rules are taken from the canonical VeClaimNFT mutation preconditions (spec §4.2) and marketplace coordination (spec §4.5).

- Shared mutation guard (all lifecycle mutations except `createLock` / `createLockFor`):
  - MUST revert if `tokenId` does not exist.
  - For user-facing mutations (non-`*For`), MUST revert if caller is not the lock owner.
  - For Furnace helper mutations (`*For`), MUST revert if `ownerOf(tokenId) != user`.
  - MUST revert if the lock is `listed`.
  - MUST revert if the lock is expired (`block.timestamp >= lockEnd`), except `unlock`.

- `createLock(amount, durationSeconds, autoMax)` / `createLockFor(user, amount, durationSeconds, autoMax)`:
  - MUST revert if `amount < MIN_LOCK_AMOUNT`.
  - MUST revert if `durationSeconds` is outside `[MIN_LOCK_DURATION, MAX_LOCK_DURATION]`.
  - MUST revert if `autoMax == true` and `durationSeconds != MAX_LOCK_DURATION`.
  - `createLockFor` MUST revert if caller is not the canonically wired Furnace.

- `addToLock(tokenId, amount)` / `addToLockFor(user, tokenId, amount)`:
  - MUST revert if `amount == 0`.

- `extendLockToFor(user, tokenId, newEnd)` (Furnace-only):
  - MUST revert if `newEnd <= oldEnd` (no shortening / no no-op).
  - MUST revert if `newEnd > block.timestamp + MAX_LOCK_DURATION`.
  - If `autoMax[tokenId] == true`, the effective end MUST be forced to `block.timestamp + MAX_LOCK_DURATION`.

- `mergeLocksFor(user, fromTokenId, intoTokenId)` (Furnace-only sibling backing `Furnace.mergeLocksWithBonus[For]`):
  - MUST revert if caller is not the canonically wired Furnace.
  - MUST revert if `fromTokenId == intoTokenId`.
  - MUST revert if either lock is not owned by `user`.
  - MUST revert if either lock is listed or expired.
  - The user-facing entry point (`Furnace.mergeLocksWithBonus`) accepts mixed AutoMax / non-AutoMax pairs (no `AutoMaxMismatch` revert on merge — survivor follows the OR-rule from `_mergeLocksInternal`) and pays an extension-style bonus on the duration delta. AutoMax is reversible post-merge via `setAutoMax(tokenId, false)`.

- `unlock(tokenId)`:
  - MUST revert if `block.timestamp < lockEnd[tokenId]`.
  - MUST revert if the lock is listed.

- `setListed(tokenId, listed)` (MarketRouter-only):
  - MUST revert if caller is not the canonically wired MarketRouter.
  - If setting `listed = true`:
    - MUST revert if the lock is expired.
    - MUST revert if the lock is already listed (idempotent false→true only).
  - If setting `listed = false`: MUST be allowed even if the lock is expired.
    - This allows a seller to delist then unlock.

---

## Canonical VeClaimNFT events

Event names and parameter order MUST match `docs/analytics/dune-integration-pack-v1.0.0.md`:

- `LockCreated(user, tokenId, amount, lockEnd, autoMax)`
- `LockExtended(user, tokenId, oldEnd, newEnd)`
- `LockAmountIncreased(user, tokenId, amountAdded)`
- `LockMerged(user, fromTokenId, intoTokenId, amountMoved)`
- `LockUnlocked(user, tokenId, amountReturned)`
- `AutoMaxSet(user, tokenId, autoMax)`

---

## Checklist: constants and time model


Source: constants doc + spec §4.1.

- Duration clamps:
  - `MIN_LOCK_DURATION = 7 days`
  - `MAX_LOCK_DURATION = 365 days`
- Minimum lock amount (minting only):
  - `MIN_LOCK_AMOUNT = 1_000e18` CLAIM (1,000 CLAIM)
- `autoMax` meaning:
  - If enabled, effective lock end is always `block.timestamp + MAX_LOCK_DURATION`.

Be explicit about time arithmetic:
- Treat end-times as timestamps (seconds).
- Ensure you never underflow `remaining = max(0, lockEnd - now)`.

---

## Checklist: ve math

Source: spec §4.1.

- ve at a timestamp:
  - `remaining = max(0, effectiveEnd - now)`
  - `ve = mulDivDown(amount, remaining, MAX_LOCK_DURATION)`
- Precision:
  - Implement with a single `mulDivDown`.
  - Do NOT compute `floor(amount / MAX_LOCK_DURATION) * remaining` (double-floor). See `docs/spec/test-vectors-v1.0.0.md` §7.
  - Global slope/bias math uses **ceil** rules where required (see checkpointing section).

---

## Checklist: core lifecycle functions

Source: spec §4.2.

User-facing (token owner only):
- `setAutoMax(tokenId, enabled)`
- `unlock(tokenId)` (only after expiry)

Delegated user-facing (DelegationHub session required):
- `unlockExpiredForUser(user, tokenId)` — requires `P_VE_UNLOCK_EXPIRED_FOR` session bit. Sends withdrawn CLAIM to the `user` (not the delegate).

Note: v1.0.0 routes lock extension and lock merging through Furnace:
- `Furnace.extendWithBonus(tokenId, durationSeconds, minBonusOut)` / `extendWithBonusFor(...)` (`P_VE_EXTEND_LOCK_FOR`).
- `Furnace.mergeLocksWithBonus(fromTokenId, intoTokenId, minBonusOut)` / `mergeLocksWithBonusFor(...)` (`P_VE_MERGE_LOCKS_FOR`). The raw `VeClaimNFT.mergeLocks{,ForUser}` user-facing entrypoints are removed.

Protocol hooks (protocol only, as specified):
- `createLockFor(user, amount, duration, autoMax) -> tokenId`
- `addToLockFor(user, tokenId, amount)`
- `extendLockToFor(user, tokenId, newEnd)`
- `mergeLocksFor(user, fromTokenId, intoTokenId)` (Furnace-only sibling backing the merge surface)

Constraints (required):
- v1.0.0 does **not** include `setAutoMaxFor(...)` protocol hooks.
- Protocol hooks MUST validate that `tokenId` is owned by the provided `user`.


Ownership hardening (REQUIRED):
- `renounceOwnership()` MUST always revert. Wiring setters, guardian rotation, and lock management require a live owner.

Access-control hardening (REQUIRED):
- VeClaimNFT MUST store `furnace` and `mineMarket`, but MUST NOT trust either raw pointer in isolation on hot mutation paths.
- Furnace-only helpers MUST fail closed unless the live Furnace still points back to the same `ve`, `CLAIM`, `MineCore`, and (when wired) `MarketRouter` / `ShareholderRoyalties` bundle.
- MarketRouter-only hooks MUST fail closed unless the live MarketRouter still points back to the same `ve`, `CLAIM`, `Furnace`, `MineCore`, and (when wired) `ShareholderRoyalties` bundle.
- Delegated ve-maintenance wrappers MUST resolve the delegation hub canonically through the live Furnace + MarketRouter + MineCore bundle; a raw `Furnace.delegationHub()` read is insufficient, and `MineCore.furnace()` MUST still equal that live Furnace before session bits are trusted.

### create restrictions you MUST enforce

From spec §4.2:

Shared mint validation (both `createLock` and `createLockFor`):
- Require `amount >= MIN_LOCK_AMOUNT`.
- Require `MIN_LOCK_DURATION <= duration <= MAX_LOCK_DURATION`.
- AutoMax validation (MUST):
  - If `autoMax == true`, MUST require `duration == MAX_LOCK_DURATION`.
  - If `duration < MAX_LOCK_DURATION`, MUST require `autoMax == false`.
  - At `duration == MAX_LOCK_DURATION`, `autoMax` is an explicit opt-in (both true and false are allowed).

Entry-point differences:
- `createLockFor` MUST be restricted to the canonically wired Furnace and mints to an explicit `user`.

---

## Checklist: add / extend / merge rules

Source: spec §4.2.

- `addToLock` / `addToLockFor`:
  - require `amount >= MIN_TOPUP_AMOUNT` (env-config §3.1B; floor bounds slope-rounding dust)
  - increase principal
  - for non-AutoMax locks (`autoMax == false`): MUST NOT change `lockEnd`
  - for AutoMax locks (`autoMax == true`): MAY refresh stored `lockEnd` to `block.timestamp + MAX_LOCK_DURATION` for metadata parity (no economic effect)
  - update `totalLockedClaim`
  - emit the required event

- `mergeLocksFor` (Furnace-only; user-facing surface is `Furnace.mergeLocksWithBonus[For]`):
  - move principal from `fromTokenId` into `intoTokenId`
  - burn / invalidate `fromTokenId`
  - AutoMax mismatch is intentionally NOT a revert path on merge: `_mergeLocksInternal` resolves the survivor with `newAutoMax = fromAutoMax || intoAutoMax` (OR-rule). `Furnace.mergeLocksWithBonus[For]` accepts mixed pairs on both the self and delegated paths.
  - if the resulting (post-OR) lock is AutoMax, the stored `lockEnd` MUST be set to `block.timestamp + MAX_LOCK_DURATION` (effective end is always max)
  - else, `lockEnd` of the merged position MUST be the max of the two ends (per spec)
  - the duration-delta bonus computed by Furnace is added to `intoTokenId` via `addToLockFor` (not by `mergeLocksFor` itself), so VeClaimNFT-level `LockMerged` emits `amountMoved` only.

- `unlock`:
  - MUST revert if `autoMax == true`
  - only after expiry (`block.timestamp >= lockEnd`)
  - return principal
  - clear accounting
  - emit the required event

---

## Checklist: aggregates and checkpointing

Source: spec §4.3.

You MUST support:
- `checkpointGlobalState()` (permissionless)
- `checkpointTotalVe()` (permissionless; shares the same internal implementation as `checkpointGlobalState()`, which already syncs `totalVeCached`. MineCore.takeover does not call this separately because `checkpointGlobalState()` handles it.)
- `totalVeCached()` as a snapshot-safe aggregate value

### Bounded work
- Global checkpointing MUST be bounded:
  - `MAX_SLOPE_CHANGES_PER_CALL = 250`

### Precision rules (do not improvise)
- Follow the rounding rules in spec §4.3:
  - apply pending slope changes
  - compute decay using the required `mulDivDown` / ceil rules where specified
- After checkpointing:
  - `totalVeCached` MUST be **conservative** (MUST NOT be underestimated).
  - Invariant (same timestamp): `totalVeCached >= Σ veOf(tokenId)` across all live locks.
  - Conservative rounding is allowed, so `totalVeCached` is allowed to be slightly higher than the exact sum.
  - `totalVeCached` MUST NOT be lower than the exact sum.

Recommended approach (minimize grief while staying conservative):
- Keep global aggregates in a scaled fixed-point space and round only once.
  - `SLOPE_SCALE = 1e18`
  - `slopeScaled = ceilDiv(amount * SLOPE_SCALE, MAX_LOCK_DURATION)`
  - `biasScaled  = slopeScaled * remaining`
- Maintain `globalBiasScaled` and set:
  - `totalVeCached = ceilDiv(globalBiasScaled, SLOPE_SCALE)`

Testing requirement:
- Add a property-style test that brute-forces `Σ veOf(tokenId)` over a small randomized set and asserts:
  - `totalVeCached >= bruteForceSum`


MineCore dependency:
- MineCore takeover MUST call `checkpointGlobalState()` before finalizing a reign. A separate `checkpointTotalVe()` call is not required because `checkpointGlobalState()` already syncs `totalVeCached`.

---

## Checklist: lock destination routing (Furnace integration)

Source: spec §4.4 and constants doc.

When the protocol routes a lock (for example from Furnace):
- Inputs include:
  - `targetTokenId` (0 = create a new lock)
  - `durationSeconds`
  - `createAutoMax`
- Clamp `durationSeconds` into `[MIN_LOCK_DURATION, MAX_LOCK_DURATION]`.
- If `autoMax[targetTokenId] == true`:
  - UI locks the slider
  - effective end ignores passed `newEnd` and uses `now + MAX_LOCK_DURATION`
- Destination invariants:
  - The quote that returns `veOut` MUST return only the ve attributable to the newly locked amount at the resulting remaining duration.
  - Entry into an existing non-AutoMax lock does not change its duration; `veOut` covers only the newly locked amount.

---

## Checklist: transfer restrictions and marketplace flags

Source: spec §4.5 and Market spec §8.

- Marketplace integration:
  - Maintain a `listed` flag so the marketplace can lock a position against mutation while listed.
  - While `listed == true`, the position MUST be immutable: disallow transfers and all mutations (add/extend/merge/split/unlock), except operations that are explicitly part of delisting.

- Transfer restrictions (MUST match spec §4.5):
  - `transferFrom` / `safeTransferFrom` MUST revert unless:
    - Mint (`from == address(0)`).
    - Burn (`to == address(0)`).
    - Caller is MarketRouter (`msg.sender == mineMarket`) and the transfer is **into Furnace custody** (`to == furnace`) and the token is not listed.
  - All other transfers MUST revert.
  - Furnace MUST NOT be usable as a general transfer adapter: it MUST NOT enable user↔user transfers.

---

## Checklist: Furnace burn-and-withdraw helper (sellback)

Source: spec §7.6 and VeClaimNFT spec §4.5.

To support Furnace sellback (lock → liquid CLAIM), VeClaimNFT MUST expose a Furnace-only burn-and-withdraw path that bypasses lock expiry.

Requirements (MUST):
- Only callable by the configured `furnace`.
- The token MUST be owned by `furnace` (Furnace takes custody first).
- MUST revert if the token is `listed`.
- MUST burn the token and withdraw its full underlying principal amount of CLAIM to the requested recipient (`Furnace`), even if `lockEnd > block.timestamp`.
- MUST update all accounting exactly as if the lock was removed (same slope/bias removal rules as unlock):
  - total locked supply
  - per-token and per-user aggregates
  - global checkpoints (`checkpointGlobalState`, `checkpointTotalVe`) as required
- MUST clear approvals and owner state as with a normal burn.

Notes:
- This method is an administrative escape hatch for Furnace only; users still use normal `unlock` when the lock has expired.
---

## Worked examples (sanity checks)

These examples are non-normative. They exist to catch unit/rounding mistakes.

### Example A: ve computation uses floor rounding

Assume:
- `amount = 1_000e18` CLAIM
- `remaining = 180 days`
- `MAX_LOCK_DURATION = 365 days`

Compute:
- `ve = floor(amount * remaining / MAX_LOCK_DURATION)`
- `ve ≈ floor(1_000e18 * 180 / 365) = 493e18` (approximate, before exact seconds math)

The implementation MUST use the exact seconds values onchain and MUST floor the final division.

### Example B: AutoMax forces end = now + MAX

If `autoMax[tokenId] == true`:
- `effectiveEnd = block.timestamp + MAX_LOCK_DURATION`
- Any attempt to extend (via `extendLockToFor`) MUST set `lockEnd` to `block.timestamp + MAX_LOCK_DURATION` (ignore the passed `newEnd`).

### Example C: conservative `totalVeCached`

At a fixed `block.timestamp`:
- `totalVeCached` MUST NOT be **lower** than the brute-force sum of per-lock `ve`.
- Being slightly higher (due to conservative ceiling in global aggregates) is acceptable; being lower is not.


## Checklist: CheckpointStale guards

Source: spec §4 (VeClaimNFT checkpoint invariants).

Critical lock mutations MUST verify that `globalLastTs == block.timestamp` before proceeding. If the global checkpoint is stale, the mutation MUST revert with `Errors.CheckpointStale()`.

This guard MUST be enforced in:
- `_mergeLocksInternal` — before combining slope/bias from two locks
- `setAutoMax` — before toggling autoMax state (both the no-op refresh path and the general path)
- `_update` — in the transfer path (before `from`/`to` ownership change)
- `_extendLockToInternal` — before extending a lock's end time

Rationale: stale global state during mutations can produce incorrect slope/bias accounting, which in turn corrupts `totalVeCached` and shareholder reward distribution.

---

## Common failure modes

- Treating `duration == MAX_LOCK_DURATION` as invalid on `createLock` (or otherwise drifting mint validation between `createLock` and `createLockFor`).
- Global checkpoint loops that are not bounded (can DOS finalization).
- Rounding drift between `totalVeCached()` and the sum of per-user views.
- Extending or merging in a way that allows shortening (time-weighted bypass).
- Performing lock mutations while the global checkpoint is stale (can corrupt slope/bias accounting).

## Checklist: config freeze (`configFrozen` / `freezeConfig()`)

- `bool public configFrozen` — one-way flag, default `false`.
- `modifier whenNotFrozen()` — reverts `Errors.ConfigFrozen()` if `configFrozen == true`.
- Frozen setters (MUST have `whenNotFrozen`):
  - `setFurnace(address)` — `onlyOwner whenNotFrozen`
  - `setMineMarket(address)` — `onlyOwner whenNotFrozen`
- `freezeConfig()` — `onlyOwner whenNotFrozen`:
  - MUST revert if `furnace == address(0)`
  - MUST revert if `mineMarket == address(0)`
  - Sets `configFrozen = true`
  - Emits `Events.ConfigFrozen()`
- NOT frozen (remain owner-configurable after freeze):
  - `setBaseURI`, `setContractURI` (metadata)
