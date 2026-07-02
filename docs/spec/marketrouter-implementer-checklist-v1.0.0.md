# MarketRouter implementer checklist (v1.0.0)

This is an **implementer-focused checklist** for `MarketRouter`, the veCLAIM lock management router (0% protocol fee).

**Strict mode invariant (Furnace-only lock trading):**
- The **Furnace is the only counterparty** for lock purchases.
- There are **no user-to-user lock sales**.
- MarketRouter is only for listing/delisting/managing locks as limit sells to the Furnace and for bonus target escrow entry orders.

Source of truth:
- Canonical behavior: `docs/spec/spec-v1.0.0.md` §8 (MarketRouter) + §4.5 (VeClaimNFT transfer restrictions)
- Listing settlement rules: `docs/spec/marketplace-correctness-addendum-v1.0.0.md`
- Constants + anti-spam defaults: `docs/spec/spec-v1.0.0.md` §8.2 + `src/lib/Constants.sol`
- Pause rules: `docs/spec/spec-v1.0.0.md` §5.6.2 (trading pause)

Spec aids (recommended):
- `docs/spec/state-machines-v1.0.0.md` (MarketRouter listing flow diagram)
- `docs/spec/test-vectors-v1.0.0.md` (§8 Bonus Target escrow conversion)

This document restates requirements in implementation order.

---

## Goals

MarketRouter MUST:
- Be the only lock management transfer path (wired into VeClaimNFT as `mineMarket`).
- Enforce listing invariants so veCLAIM positions cannot be double-sold or mutated while listed.
- Provide:
  - fixed-price listings (limit sells to Furnace with `minClaimOut` price floor)
  - bonus target escrow orders (entry orders into Furnace)
- Be safe in production:
  - proxy-backed (transparent proxy + ProxyAdmin owned by TimelockController)
  - upgrades require a timelock-delayed governance proposal

---

## Revert and no-op matrix

MarketRouter manages lock listings and entry orders, so pause and unwind semantics MUST be crisp.

- `pauseTrading(true)`:
  - MUST cause these actions to revert: `listLock`, listing settlement, direct `sellLockToFurnace`, `createBonusTargetEscrowWithTarget`, and `executeAutoFurnace`.
  - MUST still allow unwind paths while paused: `delistLock`, `cancelExpiredListing`, `cancelBonusTargetEscrow`, `cancelExpiredBonusTargetEscrow`, and `emergencyDelist` (spec §8.2).
  - `extendBonusTargetEscrowExpiry` MUST also revert when paused (`whenTradingEnabled`).

- `listLock(tokenId, minClaimOut, expiresAtTime)`:
  - MUST revert when `tradingPaused == true`.
  - MUST revert if caller is not the owner or MarketRouter lacks approval.
  - MUST revert if the lock is expired or otherwise restricted.

- `delistLock(tokenId)`:
  - MUST revert if caller is not the seller when local listing state is active.
  - MUST remain callable when `tradingPaused == true` (unwind).
  - Canonical-router replacement rescue: if the new canonical MarketRouter has no local listing entry for `tokenId` but the current owner still has `VeClaimNFT.listed == true`, `delistLock` MUST let that owner clear the stale ve-level listed flag and refresh `lastListingActionBlock[tokenId]`.

- Listing settlement (`sellListedLockToFurnace(tokenId, deadline)`):
  - MUST revert when `tradingPaused == true`.
  - MUST revert with `DeadlineExpired` if `block.timestamp > deadline`.
  - MUST revert if the listing is not active.
  - Strict-mode MarketRouter does not include an approval-revoked self-clear branch. Compatibility delist code `APPROVAL_REVOKED` remains reserved for analytics compatibility but is not emitted.
  - MUST revert if the Furnace cannot meet the `minClaimOut` price floor for approved listings.
  - Keeper-priority: during `SETTLEMENT_KEEPER_GRACE_SECONDS` (1800s) after `listedAtTime`, approved listings MUST revert for non-keeper/non-owner callers with `SettlementKeeperGracePeriod()`. After the grace window, approved settlement is permissionless.

- `sellLockToFurnace(tokenId, minClaimOut, deadline)`:
  - MUST revert when `tradingPaused == true`.
  - MUST auto-delist the token if it is listed to prevent double sale.
  - If it auto-delists, MUST emit `LockDelisted(tokenId, seller, SOLD_TO_FURNACE)`.
  - Routes to Furnace for sellback.

- `createBonusTargetEscrowWithTarget(...)`:
  - MUST revert when `tradingPaused == true`.
  - MUST enforce the creation-time anti-spam limits (min budget).

- `cancelBonusTargetEscrow(offerId)`:
  - MUST remain callable when `tradingPaused == true` (unwind).

- `executeAutoFurnace(offerId, deadline)`:
  - MUST revert when `tradingPaused == true`.
  - MUST revert with `DeadlineExpired` if `block.timestamp > deadline`.
  - MUST revert if the escrow is inactive or has `fundsRemaining == 0`.
  - MUST revert if the effective Furnace bonus for the remaining amount is below `targetBonusBps`.
  - Keeper-priority: during `SETTLEMENT_KEEPER_GRACE_SECONDS` (1800s) after `offer.createdAt`, MUST revert for non-keeper/non-owner callers with `SettlementKeeperGracePeriod()`. After the grace window, execution is permissionless.

- `emergencyDelist(tokenId)`:
  - MUST remain callable while paused.
  - MUST enforce `EMERGENCY_DELIST_MIN_AGE` (7 days) before force-clearing.

---

## Canonical events

Event names and parameter order MUST match `docs/analytics/dune-integration-pack-v1.0.0.md`.

- `LockListed(tokenId, seller, minClaimOut, listedAtTime, expiresAtTime)` — listing created (limit sell to Furnace)
- `LockDelisted(tokenId, seller, reason)` — listing removed
  - `LockDelisted.reason` codebook MUST be stable:
    - `0 = NORMAL`
    - `1 = EMERGENCY`
    - `2 = SOLD_INTO_OFFER` (reserved compatibility analytics code; not emitted by the strict-mode router)
    - `3 = SOLD_TO_FURNACE`
    - `4 = EXPIRED`
    - `5 = APPROVAL_REVOKED` (reserved compatibility analytics code; not emitted by the strict-mode router)
- `ListingSettled(tokenId, seller, claimOut, penalty)` — Furnace settled a listing
- `BonusTargetEscrowCreated(escrowId, buyer, discountBps, durationSeconds, createAutoMax, expiresAt, destinationLockId, budgetClaim, createdAt)`
- `BonusTargetEscrowConfigured(escrowId, buyer, targetBonusBps, slippageBps)`
- `BonusTargetEscrowCancelled(escrowId, buyer, refundClaim)`
- `BonusTargetEscrowExecuted(escrowId, buyer, claimIn, principalClaim, bonusClaim, veOut, routeTokenId, furnaceTokenId)`
- `BonusTargetEscrowAutoFurnaceExecuted(escrowId, buyer, claimIn, principalClaim, bonusClaim, veOut, routeTokenId, furnaceTokenId)`
- `BonusTargetEscrowExpired(escrowId, buyer, refundClaim)`
- `BonusTargetEscrowExpiryExtended(escrowId, buyer, oldExpiresAt, newExpiresAt)`
- `TradingPausedChanged(paused)`
- `SettlementKeeperSet(keeper, allowed)` — keeper whitelist change (MEV protection)

Constraints (required):
- Bonus target escrow executions MUST emit a normal `FurnaceEnter` (from Furnace) for analytics parity (mode = ENTER_WITH_CLAIM).

---

## Checklist: wiring and privilege

Source: spec §8 (intro) + §4.5.

- Constructor hardening (REQUIRED): deployment MUST fail closed unless `claim`, `ve`, and `royalties` are non-zero live contracts, `ve.claimToken() == claim`, and `royalties.ve() == ve`.
- MarketRouter is wired into VeClaimNFT:
  - VeClaimNFT MUST recognize MarketRouter as `mineMarket`.
- VeClaimNFT MUST restrict transfers so that:
  - only Furnace custody transfers are allowed (for sellback/settlement).
  - there are no user-to-user lock transfers.
- All lock settlements through MarketRouter MUST:
  - call `ShareholderRoyalties.checkpointTransfer` before transfer (required for correct shareholder accounting).
- Runtime canonical-Furnace hardening (REQUIRED): settlement and auto-Furnace execution MUST resolve the live Furnace from `ve.furnace()` and reject split-brain bundles unless `Furnace.{mineMarket,shareholderRoyalties}`, `ShareholderRoyalties`, `MineCore`, `ClaimToken`, and `VeClaimNFT` all point back to the same deployment roots.
- Settlement keeper priority (MEV protection):
  - `isSettlementKeeper` mapping controls which addresses may settle during the grace period.
  - `setSettlementKeeper(address, bool)` is always owner-only.
  - MaintenanceHub is kept off the settlement-keeper allowlist by default because `poke(args)` is permissionless. If operators intentionally want hub-driven auto-furnace execution during `SETTLEMENT_KEEPER_GRACE_SECONDS`, they must explicitly allowlist the hub; otherwise `poke(args)` only becomes eligible after grace.

---

## Checklist: listing model

Source: spec §8.1.

MarketRouter MUST implement a listing model with the following minimum state:
- `listed[tokenId]`
- `listedAtTime[tokenId]` (for emergency delist age checks, and event fields)
- `lastListingActionBlock[tokenId]` to prevent same-block relist and to support emergency workflows

Core invariants:
- A listed token MUST NOT be:
  - transferred outside MarketRouter/Furnace custody flows
  - merged, unlocked, or otherwise mutated in ways that violate the listing guarantees
- After a settlement:
  - internal listing state MUST be cleared
  - same-block relist MUST be prevented (per `lastListingActionBlock` rule)

Important: there are **two** "listing" concepts (do not conflate them):
- MarketRouter internal listing state (seller/minClaimOut/time + cooldown bookkeeping).
- VeClaimNFT's `listed` flag (mutation lock).
  - `listLock` MUST set it `true`.
  - `delistLock` MUST set it `false`.
  - Settlement MUST clear it before custody transfer into Furnace (it is a mutation guard, not a balance-bearing state).

---

## Checklist: required functions and their invariants

Source: spec §8.2.

Implement the functions in §8.2, preserving:
- CLAIM-only prices (v1.0.0 policy)
- 0% protocol fee (no treasury skim)
- Duration-based listing settlement penalty (mirrors Furnace round-trip loss: 99% at 365d, ~1.9% at 7d) — the retained cut is surfaced as `penalty = lockAmount - claimOut`, not a protocol fee
- Correct event emissions as specified
- Correct escrow and execution semantics for bonus target escrow orders

Key invariants by category:

### Listing (limit sell to Furnace)
- Listing creation (`listLock`):
  - verify owner/approval
  - set internal listing state (seller, `minClaimOut`, timestamps)
  - call `VeClaimNFT.setListed(tokenId, true)` to mutation-lock the position
  - record `listedAtTime`
  - emit `Events.LockListed` (with `listedAtTime`)
- Settlement:
  - MUST follow canonical ordering:
    1. Read listing and require it is active.
    2. No approval-revoked shortcut exists in strict mode; settlement proceeds directly to grace auth, live listed-flag validation, and quote checks.
    3. For approved listings, enforce keeper-priority auth.
    4. Require the live `VeClaimNFT.listed` flag to still be `true`. A stale local listing slot alone is not sufficient because canonical-router replacement rescue can clear the ve-level listed flag on a new router while an old router still retains local storage. If that old router is later rewired back, settlement MUST NOT resurrect that stale slot into a live sale.
    5. Verify Furnace can meet the `minClaimOut` price floor.
    6. Clear MarketRouter internal listing state, update `lastListingActionBlock[tokenId]`, and clear `VeClaimNFT.setListed(tokenId, false)` before custody transfer.
    7. Call `ShareholderRoyalties.checkpointTransfer(seller, furnace)` **BEFORE** veNFT transfer.
    8. Transfer veNFT to Furnace custody.
    9. Let Furnace execute the sellback math and payout.
       - Seller receives `claimOut` CLAIM.
       - `penalty = lockAmount - claimOut` is the total retained cut surfaced to indexers.
       - Furnace books that cut as `reserveAdd` plus optional `lpReward` funding into the LP stream.
    10. Emit `Events.ListingSettled(tokenId, seller, claimOut, penalty)`.

### Instant sellback to Furnace

- `sellLockToFurnace(tokenId, minClaimOut, deadline)`:
  - MUST auto-delist if the lock is listed (clear listing state first).
  - MUST transfer the lock to Furnace custody and burn it.
  - MUST pay the seller CLAIM from Furnace.
  - MUST emit `LockDelisted` (if applicable) and Furnace sellback events.

### Bonus target escrow (entry orders into Furnace)

Source: spec §8.2.y.

- Escrow creation (`createBonusTargetEscrowWithTarget`):
  - fail closed unless this router still resolves the live canonical Furnace / ShareholderRoyalties / MineCore / ClaimToken / VeClaimNFT market bundle
  - compute `discountBps` from `targetBonusBps` (for display)
  - escrow `budgetClaim` in MarketRouter as `fundsRemaining`
  - emit `BonusTargetEscrowCreated`

- Execution (`executeAutoFurnace(offerId, deadline)`):
  - permissionless (anyone can call; keeper-priority during grace period)
  - reverts with `DeadlineExpired` if `block.timestamp > deadline`
  - reverts if escrow expired
  - closes the escrow (CEI)
  - derives `executionDurationSeconds` from the resolved destination lock before quote/execution:
    - new lock: stored escrow `durationSeconds`
    - existing AutoMax lock: `MAX_LOCK_DURATION`
    - existing non-AutoMax lock: live remaining duration (`lockEnd - block.timestamp`)
  - quotes `FurnaceQuoter.quoteEnterWithClaim` (resolved via `furnace.furnaceQuoter()`) for the full remaining budget using `executionDurationSeconds`
  - `veOut` covers only the newly locked amount at the lock's remaining duration; entry into an existing lock does not change its duration
  - checks bonusBpsVsPrincipalClaim >= targetBonusBps (amount-specific)
  - sets `minVeOut = floor(veOut * (10_000 - slippageBps) / 10_000)`
  - if `veOut > 0` but floor-rounding would produce `minVeOut == 0`, clamps to `1`
  - calls `Furnace.enterWithClaimFor(...)` on behalf of the buyer using the same `executionDurationSeconds`
  - emits `BonusTargetEscrowExecuted`

- Cancellation (`cancelBonusTargetEscrow`):
  - buyer-only while this router is canonical
  - permissionless stale-router unwind once this router is no longer canonical for the live market bundle, while still refunding only the buyer
  - refunds remaining `fundsRemaining` CLAIM to buyer
  - MUST remain callable while paused
  - emits `BonusTargetEscrowCancelled`

- Expiry unwind (`cancelExpiredBonusTargetEscrow`):
  - permissionless at or after `block.timestamp >= expiresAt`
  - refunds remaining `fundsRemaining` CLAIM to buyer
  - emits `BonusTargetEscrowExpired`

- Expiry extension (`extendBonusTargetEscrowExpiry`):
  - buyer-only
  - MUST revert when `tradingPaused == true` (`whenTradingEnabled`)
  - MUST fail closed unless this router still resolves the live canonical Furnace / ShareholderRoyalties / MineCore / ClaimToken / VeClaimNFT market bundle
  - bounded by `newExpiresAt <= offer.createdAt + MAX_BONUS_TARGET_ESCROW_TTL_SECONDS`
  - emits `BonusTargetEscrowExpiryExtended`

---

## Checklist: anti-spam and economic controls

Source: spec §8.3.

Creation-time minimums (enforced only at escrow creation):
- `minBonusTargetEscrowBudget = 10_000e18` (10,000 CLAIM)

Per-escrow expiry (TTL):
- Each escrow stores `expiresAt` (timestamp), set at creation from `escrowTtlSeconds`:
  - If `escrowTtlSeconds == 0`, use `DEFAULT_BONUS_TARGET_ESCROW_TTL_SECONDS`.
  - Else require `1 <= escrowTtlSeconds <= MAX_BONUS_TARGET_ESCROW_TTL_SECONDS`.
- Escrows MUST reject execution at or after expiry (`block.timestamp >= expiresAt`).
- Remaining budget is refundable via `cancelBonusTargetEscrow` (buyer-only) or `cancelExpiredBonusTargetEscrow` (permissionless after expiry).

Governance:
- Configurable via the live `owner()` path (production policy expects multisig + timelock). `MarketRouter` is proxy-backed; keep the proxy address canonical and route code changes through the owned proxy admin.
- `renounceOwnership()` MUST revert with `NotAuthorized()` so replacement, settlement-keeper management, bonus-target spam controls, and owner break-glass execution remain available.
- `setGuardian(address)` MUST reject `address(this)` because the router cannot call `pauseTrading(bool)` on itself; self-assignment would brick the guardian pause surface until owner recovery.

---

## Checklist: pause behavior

Source: spec §8.2 (function 11).

- `pauseTrading(bool paused)`:
  - Guardian-only.
  - Sets `tradingPaused = paused`. Unpause by calling `pauseTrading(false)`.
  - When `tradingPaused == true`:
    - `listLock`, listing settlement (`sellListedLockToFurnace`), direct `sellLockToFurnace`, `executeAutoFurnace`, and `extendBonusTargetEscrowExpiry` MUST revert.
    - `delistLock`, `cancelExpiredListing`, `cancelBonusTargetEscrow`, `cancelExpiredBonusTargetEscrow`, and `emergencyDelist` MUST remain callable (unwind paths).

---

## Common implementation pitfalls

- Missing or late checkpointing (`checkpointTransfer`) causes shareholder accounting bugs.
- Describing settlement as if MarketRouter pays the seller or transfers the reserve cut itself. In code, Furnace executes payout and retained-cut accounting after custody transfer.
- Not updating `lastListingActionBlock[tokenId]` on all listing state changes (enables same-block relist via hooks).
- Not enforcing `effectiveLockEnd` using AutoMax semantics.
- Bonus target escrow execution math not using floor rules, causing economic drift.

---

## Contract test expectations

Source: spec test vectors + foundry test plan.

Listing tests:
- `testListLockSetsListedFlag`
- `testDelistLockClearsListedFlag`
- `testListingSettlementTransfersClaimToSellerAndBurnsLock`
- `testListingSettlementClearsListing`
- `testListingSettlementRevertsIfTradingPaused`
- `testListingSettlementCallsCheckpointTransferBeforeTransfer`

Bonus target escrow tests:
- `testCreateBonusTargetEscrowEscrowsClaim`
- `testExecuteBonusTargetEscrowRoutesToFurnace`
- `testExecuteBonusTargetEscrowRevertsIfBonusNotMet`
- `testCancelBonusTargetEscrowRefundsEscrow`
- `testCancelExpiredBonusTargetEscrowIsPermissionlessAfterExpiry`
- `testExtendBonusTargetEscrowExpiryBoundedByMaxTTL`

Pause tests:
- `testPausedBlocksListingAndSettlement`
- `testPausedAllowsUnwindPaths`

Settlement keeper priority tests:
- `test_setSettlementKeeper_onlyOwner`
- `test_setSettlementKeeper_zeroAddress_reverts`
- `test_setSettlementKeeper_emitsEvent`
- `test_listing_keeperCanSettleDuringGrace`
- `test_listing_randomUserRevertsDuringGrace`
- `test_listing_randomUserSucceedsAfterGrace`
- `test_offer_keeperCanExecuteDuringGrace`
- `test_offer_randomUserRevertsDuringGrace`
- `test_offer_randomUserSucceedsAfterGrace`

---

## Summary of strict mode invariants

1. **No user-to-user lock sales** — Furnace is the only counterparty.
2. **Listings are limit sells to Furnace** — not asks for other users to buy.
3. **Bonus target escrow is an entry order into Furnace** — not buying locks from users.
4. **All sellbacks are to Furnace** — either listed settlement or instant sellback.
