# MarketRouter

MarketRouter is the lock management layer — listings (limit sell), sell now (instant exit), and bonus target escrows (patient entry). The [Furnace](furnace.md) is the only counterparty; MarketRouter orchestrates settlement. In the [CLAIM stream](protocol-overview.md), this is how locked positions exit or enter at market-determined prices.

> **TL;DR:** Sell now via `sellLockToFurnace(tokenId, minClaimOut, deadline)`. List via `listLock(tokenId, minClaimOut, expiresAtTime)`. Create buy intents via `createBonusTargetEscrowWithTarget(...)`. Settlement goes through the Furnace exclusively. Keeper grace period: 30 min after creation, then permissionless.

## Public API

| Function | Caller | Purpose |
|---|---|---|
| `sellLockToFurnace(tokenId, minClaimOut, deadline)` | lock owner | Sell now to the Furnace; instant CLAIM. |
| `listLock(tokenId, minClaimOut, expiresAtTime)` | lock owner | Create a limit-sell listing. |
| `delistLock(tokenId)` | lock owner | Cancel a live listing. |
| `cancelExpiredListing(tokenId)` | anyone | Sweep an expired listing. |
| `emergencyDelist(tokenId)` | lock owner | Break-glass delist after `EMERGENCY_DELIST_MIN_AGE`. |
| `sellListedLockToFurnace(tokenId, deadline)` | keeper / public after grace | Settle a listing to the Furnace. |
| `createBonusTargetEscrowWithTarget(...)` | offerer | Open a buy intent that fires when the Furnace bonus crosses a target. |
| `executeAutoFurnace(offerId, deadline)` | keeper / public after grace | Execute a bonus-target escrow. |
| `cancelBonusTargetEscrow(offerId)` | offerer | Cancel + refund escrow before fill. |
| `cancelExpiredBonusTargetEscrow(offerId)` | anyone | Sweep an expired offer. |
| `extendBonusTargetEscrowExpiry(offerId, newExpiresAt)` | offerer | Push out an offer's TTL. |
| `royalties()` | view | Canonical `ShareholderRoyalties` pointer used in Furnace reciprocal-binding. |
| `getListing(tokenId)` / `getOffer(offerId)` | view | Read-only state surface for UIs and indexers. |

Operator-only wiring setters and keeper allowlist surfaces live under [Operator notes](#operator-notes) at the bottom of this page.

## What it is

**MarketRouter** is the strict-mode trading surface for veCLAIM locks:

- The **Furnace is the only counterparty**.
- Locks are **not traded user-to-user**.
- All trading amounts are denominated in **CLAIM**.

MarketRouter is also the only allowed external transfer operator for veCLAIM:
- `VeClaimNFT` only allows transfers **from user → Furnace custody** when `msg.sender == mineMarket` (MarketRouter).
- Those transfers must go **only into the Furnace** (`to == furnace`).
- VeClaimNFT also fail-closes on bundle drift before accepting the transfer (see [Wiring safety model](protocol-overview.md#wiring-safety-model)).

## UI mapping

Integrator UIs typically expose MarketRouter inside the **Furnace** page ([/furnace](https://claimru.sh/furnace)) in the Market card tabs:

- **Sell now** — market sell to the Furnace
- **List Lock** — listings (limit sell)
- **Make Offer** — buy intents (limit buy / bonus target escrows)

Note: **Lock Now** (bonus entry) uses the Furnace directly; it does not touch MarketRouter.

Redirect URLs:

- [/furnace/market](https://claimru.sh/furnace/market) and [/furnace/offers](https://claimru.sh/furnace/offers) redirect into [/furnace?tab=offer](https://claimru.sh/furnace?tab=offer) (the embedded Market view).

## Primary surfaces

### Limit sell (listing)

- `listLock(tokenId, minClaimOut, expiresAtTime)`
- `delistLock(tokenId)`
- `cancelExpiredListing(tokenId)` (permissionless)
- `emergencyDelist(tokenId)` (seller-only after `EMERGENCY_DELIST_MIN_AGE`)
- `sellListedLockToFurnace(tokenId, deadline)` (settlement)

### Market sell (sell now)

- `sellLockToFurnace(tokenId, minClaimOut, deadline)`

### Limit buy (Buy intent)

- `createBonusTargetEscrowWithTarget(targetBonusBps, budgetClaim, durationSeconds, createAutoMax, escrowTtlSeconds, destinationLockId, slippageBps)`
- `executeAutoFurnace(offerId, deadline)`
- `cancelBonusTargetEscrow(offerId)`
- `cancelExpiredBonusTargetEscrow(offerId)` (permissionless)
- `extendBonusTargetEscrowExpiry(offerId, newExpiresAt)` (buyer-only)

## Settlement keeper grace period

Both listing settlement and buy-intent execution use a keeper-priority window:

- During the first `SETTLEMENT_KEEPER_GRACE_SECONDS` after creation (default **1800s / 30m**), only:
  - allowlisted settlement keepers (`setSettlementKeeper(address,bool)`), or
  - the contract owner
  can call:
  - `sellListedLockToFurnace(tokenId, deadline)`
  - `executeAutoFurnace(offerId, deadline)`

After the grace window, both are **permissionless**. In production, treat the owner key as a break-glass executor for this window, not as a normal keeper.

`MarketRouter` intentionally keeps a live owner path. `renounceOwnership()` is unsupported because router replacement / rewire, settlement-keeper changes, and guardian recovery remain operational responsibilities after launch.

Auth is checked on `msg.sender`. Allowlisting a permissionless contract as a settlement keeper lets its callers inherit grace-window rights. See [MaintenanceHub — Settlement keeper opt-in](maintenance-and-bots.md#deployment-hardening) for the `ALLOW_MAINTENANCE_HUB_SETTLEMENT_KEEPER` flag.

`setSettlementKeeper(addr, true)` runs the delegated-EOA rejection on `addr` before allowlisting; a 7702-delegated address reverts `DelegatedEOA` at the setter. The disable path (`allowed == false`) skips the check so a compromised seat can always be removed. See [Security, Guardian, Pausing — Keeper allowlist 7702 guard](security-guardian-pausing.md#keeper-allowlist-7702-guard) for the cross-contract rule.

Note: strict-mode `MarketRouter` does not use ERC-721 approvals for settlement. `LOCK_DELIST_REASON_APPROVAL_REVOKED` is a reserved analytics code and is not emitted.

## Listing lifecycle

### Create

`listLock(tokenId, minClaimOut, expiresAtTime)` stores:
- seller
- `minClaimOut` (net payout floor, in CLAIM)
- `listedAtTime` (timestamp)
- `expiresAtTime` (timestamp)
- `active` flag

It also sets the veNFT listed flag: `VeClaimNFT.setListed(tokenId, true)`.

Constraints:
- Caller must own the lock (v1.0.0: no separate ERC-721 approval required — MarketRouter has inherent transfer privileges on VeClaimNFT)
- Lock must not already be listed/frozen
- `expiresAtTime` must be:
  - greater than the current block timestamp, and
  - `<=` the lock’s **effective** end returned by `VeClaimNFT.getLockInfo(tokenId)`
    - if AutoMax is ON, the effective end is rolling (`block.timestamp + MAX_LOCK_DURATION`)
- Listing state changes are rate-limited by a **1-block cooldown** (cannot list and delist in the same block)

### Settle into Furnace

`sellListedLockToFurnace(tokenId, deadline)` does:

1. Enforce deadline: reverts with `DeadlineExpired` if `block.timestamp > deadline`.
2. Enforce listing is active and not expired.
3. Enforce keeper grace period (see above).
4. Load live lock info:
   - `ve.getLockInfo(tokenId)` → `(lockAmount, lockEnd, autoMax, listed)`
5. Quote the sellback (via **FurnaceQuoter**, resolved from `furnace.furnaceQuoter()`):
   - `furnaceQuoter.quoteSellLockToFurnaceFromInfo(lockAmount, lockEnd, autoMax)`
   - Reason: user-scoped sell quotes revert while a lock is listed.
6. Require `quoteClaimOut >= listing.minClaimOut` (where `quoteClaimOut` is the first return value from the quote call).
7. Clear the listing, clear the ve listed flag, and emit `LockDelisted(tokenId, seller, SOLD_TO_FURNACE)`.
8. Checkpoint royalties before transfer.
9. Transfer the veNFT to Furnace custody (strict transfer rule).
10. Call `furnace.sellLockToFurnaceFromMarket(seller, tokenId, quoteClaimOut)`.
11. Emit `ListingSettled(tokenId, seller, claimOut, penalty)`.

**Meaning of `penalty` in `ListingSettled`:**
- `penalty = lockAmount - claimOut` (clamped at 0)
- It is the total haircut implied by the quote. Furnace may book that retained cut partly into `reserveAdd` and partly into `lpReward` funding for the LP stream.
- It is not a platform fee.

### Expiry / cancellation

- If expired: `cancelExpiredListing(tokenId)` can be called by anyone.
- Seller can always `delistLock(tokenId)`.
- Canonical-router replacement rescue: after `VeClaimNFT.setMineMarket(newMarketRouter)` rewires the bundle, `delistLock(tokenId)` on the new router can clear a seller-owned stale ve `listed` flag even though the new router did not inherit the old router's local listing mapping.
- If the listing is stuck (e.g., UI failure) and older than `EMERGENCY_DELIST_MIN_AGE`: seller can `emergencyDelist(tokenId)`.

## Sell now flow

`sellLockToFurnace(tokenId, minClaimOut, deadline)`:

- Optionally auto-delists if currently listed
- Checkpoints royalties, transfers veNFT to Furnace custody
- Calls `furnace.sellLockToFurnaceFromMarket(seller, tokenId, minClaimOut)`
- Emits `MarketSellToFurnace(tokenId, seller, minClaimOut, deadline, claimOut)`

`minClaimOut` + `deadline` are the user’s slippage / anti-stale guards.

## Buy intents (bonus target escrows)

### What is stored

`createBonusTargetEscrowWithTarget(...)`:

- Transfers `budgetClaim` from buyer into MarketRouter escrow
- Computes and stores `discountBps` from `targetBonusBps`
  - `discountBps = floor(targetBonusBps * 10_000 / (10_000 + targetBonusBps))`
- Validates TTL (`escrowTtlSeconds`) and stores `expiresAt = now + ttl`
  - if `escrowTtlSeconds == 0`, uses `DEFAULT_BONUS_TARGET_ESCROW_TTL_SECONDS` (30 days)
  - onchain constraint is `MIN_BONUS_TARGET_ESCROW_TTL_SECONDS <= ttl <= MAX_BONUS_TARGET_ESCROW_TTL_SECONDS`, where `MIN_BONUS_TARGET_ESCROW_TTL_SECONDS = 300` (5 minutes; anti-flash-collateral-griefing) and `MAX_BONUS_TARGET_ESCROW_TTL_SECONDS = 90 days`. Out-of-range TTLs revert `InvalidOfferTtl`.
- Validates `slippageBps`
  - onchain constraint is `slippageBps < 10_000`; `slippageBps >= 10_000` reverts `SlippageTooHigh`
- Validates `targetBonusBps` and the derived `discountBps`
  - `targetBonusBps == 0` reverts `AmountZero`
  - `discountBps > maxBonusTargetEscrowDiscountBps` reverts `DiscountTooHigh` (the owner-managed extra cap, default 8_000)
- Validates the resolved lock duration
  - `effectiveDuration` (= `MAX_LOCK_DURATION` when `createAutoMax`, else `durationSeconds`) must satisfy `MIN_LOCK_DURATION <= effectiveDuration <= MAX_LOCK_DURATION` or the call reverts `InvalidDuration`
- If `destinationLockId != 0`, validates that lock immediately at creation time
  - it must already be buyer-owned, not listed, not expired, match the offer's AutoMax mode, and not shorten the effective lock end relative to `block.timestamp + effectiveDuration`
  - **non-AutoMax destinations** additionally require `lockEnd - block.timestamp >= MIN_LOCK_DURATION` (7 days remaining); short-tail locks revert `InvalidDuration`
  - otherwise the create call reverts; later execution still re-validates and falls back to `resolvedLockId = 0` if the destination has become ineligible since creation
- Stores an offer with:
  - buyer
  - fundsRemaining (initially `budgetClaim`)
  - `durationSeconds` (effective duration)
    - if `createAutoMax == true`, effective duration is forced to `MAX_LOCK_DURATION`
  - `createAutoMax`
  - destinationLockId
    - `0` = create a new lock at execution time
    - nonzero = validated immediately at creation against the current destination-lock eligibility checks (same owner, not expired, not listed, matching AutoMax flag, no lock-shortening, and **non-AutoMax destinations must still have `>= MIN_LOCK_DURATION` remaining**)
  - expiresAt
  - configured target: `targetBonusBps`, `slippageBps`, and `configured = true`
- Creation-time constraints that matter in practice:
  - `slippageBps` must be `< 10_000` (`BPS_DENOM`) or creation reverts `SlippageTooHigh`
  - `discountBps` (derived from `targetBonusBps`) must be `<= maxBonusTargetEscrowDiscountBps` or creation reverts `DiscountTooHigh`
  - `budgetClaim` must be `>= minBonusTargetEscrowBudget` or creation reverts `BudgetTooSmall`
  - a saved nonzero `destinationLockId` is still re-checked at execution time; if that lock later becomes ineligible (transferred, expired, listed, AutoMax mismatch, lock-shortening, or for non-AutoMax now under 7 days remaining), execution falls back to `resolvedLockId = 0` and creates a new lock instead of reverting for stale destination metadata

### Global offer parameters (anti-spam / safety)

MarketRouter enforces two owner-managed global parameters on new buy intents:

- `minBonusTargetEscrowBudget` (CLAIM): minimum `budgetClaim` required to create an offer.
  - Default: `DEFAULT_MIN_BONUS_TARGET_ESCROW_BUDGET` (v1.0.0: 10,000 CLAIM).
  - **Increase-only** (cannot be decreased).
- `maxBonusTargetEscrowDiscountBps` (BPS): extra cap on the offer's **implied discount** (`discountBps`, derived from `targetBonusBps`).
  - Default: `DEFAULT_MAX_BONUS_TARGET_ESCROW_DISCOUNT_BPS` (v1.0.0: 8,000).
  - Can be set to `10,000` to effectively disable the extra cap.

Admin surface (owner):
- `setBonusTargetEscrowParams(minBudgetClaim, maxDiscountBps)`
- emits `BonusTargetEscrowParamsChanged(oldMinBudget, newMinBudget, oldMaxDiscountBps, newMaxDiscountBps)`

### Execution trigger

`executeAutoFurnace(offerId, deadline)`:

1. Enforce deadline: reverts with `DeadlineExpired` if `block.timestamp > deadline`.
2. Enforce offer is active and not expired.
3. Enforce keeper grace period (see above).
4. Snapshot the escrow/config and close the offer immediately (CEI one-shot). Any later revert restores the escrow because the whole transaction reverts.
5. Resolve the destination lock id (use `destinationLockId` if it is still eligible; otherwise set `resolvedLockId = 0`, which means create a new lock). This is a second live eligibility check at execution time; a destination lock that was valid when the offer was created can still fall back to a new lock if it later becomes listed, expired, AutoMax-mismatched, or longer-dated than the target end.
6. Resolve the live Furnace from `ve.furnace()` and fail closed on bundle drift (see [Wiring safety model](protocol-overview.md#wiring-safety-model)).
7. Derive `executionDurationSeconds` from the resolved destination semantics:
   - new lock: use the escrow's stored `durationSeconds`
   - existing AutoMax lock: use `MAX_LOCK_DURATION`
   - existing non-AutoMax lock: use the live remaining duration (`lockEnd - block.timestamp`) because entry does not extend duration
8. Quote the live entry (via **FurnaceQuoter**, resolved from `furnace.furnaceQuoter()`):
   - `furnaceQuoter.quoteEnterWithClaim(buyer, claimIn, resolvedLockId, executionDurationSeconds, createAutoMax)`
9. Compute `bonusBpsVsPrincipalClaim = floor(bonusClaim * 10_000 / principalClaim)` from the quote. This is the realized bonus rate expressed in bps relative to **principalClaim** (the gross amount the buyer pays in). It is NOT the bps ratio against `principalEff` (the duration-weighted effective principal that feeds the Furnace AMM curve). For a near-MAX duration the two ratios converge; for shorter durations they diverge.
10. Require `bonusBpsVsPrincipalClaim >= targetBonusBps`.
11. Compute `minVeOut = floor(veOut * (10_000 - slippageBps) / 10_000)` from the live quote.
    - `veOut` here covers only the newly locked amount at the lock's remaining duration; entry into an existing lock does not change its duration.
    - If `veOut > 0` but floor-rounding would produce `minVeOut == 0`, `executeAutoFurnace` clamps it to `1` before calling Furnace.
12. Call `furnace.enterWithClaimFor(buyer, claimIn, resolvedLockId, executionDurationSeconds, createAutoMax, minVeOut)`.

Events:
- `BonusTargetEscrowCreated`
- `BonusTargetEscrowConfigured`
- `BonusTargetEscrowExecuted` (canonical generic execution receipt)
- `BonusTargetEscrowAutoFurnaceExecuted` (back-compat companion receipt)

Cancellation / expiry:
- Buyer can `cancelBonusTargetEscrow(offerId)` at any time.
- If the router is no longer canonical for the live market bundle, anyone can trigger `cancelBonusTargetEscrow(offerId)` as a refund-only unwind rescue; CLAIM still returns to the buyer.
- Anyone can `cancelExpiredBonusTargetEscrow(offerId)` at or after expiry.

### Extend expiry

`extendBonusTargetEscrowExpiry(offerId, newExpiresAt)`:

- Buyer-only.
- `newExpiresAt` is an **absolute** expiry timestamp (unix seconds).
- Must be:
  - greater than the current `expiresAt`, and
  - `<= offer.createdAt + MAX_BONUS_TARGET_ESCROW_TTL_SECONDS`

UI helper:
- `getBonusTargetEscrowExpiryBounds(offerId)` returns `maxExpiresAt` (computed from the offer's creation timestamp).

## Read-only helpers (UI/indexers)

- `getListing(tokenId)` / `getUserListings(user)`
- `getBonusTargetEscrow(offerId)` / `getUserBonusTargetEscrows(user)`
- `bonusTargetConfigs(offerId)` (public mapping getter: targetBonusBps + slippageBps + configured)
- `getBonusTargetEscrowExpiryBounds(offerId)` → `(createdAt, expiresAt, maxExpiresAt)`
- `totalEscrowedClaim()` → total CLAIM currently held in active bonus target escrows (sum of all `fundsRemaining`)

## Batch and pagination helpers

### Batch expiry cleanup

- `cancelExpiredListingBatch(uint256[] calldata tokenIds)` — batch-cancel expired listings. Best-effort: ineligible items are silently skipped.
- `cancelExpiredBonusTargetEscrowBatch(uint256[] calldata offerIds)` — batch-cancel expired bonus target escrows. Best-effort: ineligible items are silently skipped.

### Stale listing cleanup

- `cleanupStaleListing(uint256 tokenId)` — permissionless: clear a zombie listing where MarketRouter local state is active but the ve-level listed flag was already cleared (e.g. after a router rollback). Emits `LockDelisted`.

### Paginated read helpers

- `getUserListingsPaginated(address user, uint256 offset, uint256 limit) → (uint256[] ids, bool hasMore)` — paginate a user's active listing token IDs.
- `getUserBonusTargetEscrowsPaginated(address user, uint256 offset, uint256 limit) → (uint256[] ids, bool hasMore)` — paginate a user's active bonus target escrow IDs.
- `totalEscrowedClaimPaginated(uint256 startId, uint256 endId) → uint256 total` — paginated version of `totalEscrowedClaim` for onchain safety. `startId` is inclusive (min 1), `endId` is exclusive (capped at `nextOfferId`).

The non-paginated `getUserListings`, `getUserBonusTargetEscrows`, and `totalEscrowedClaim` are retained for off-chain convenience but are gas-unbounded.

## Trading pause behavior

When `tradingPaused == true`:

Disabled (reverts `TradingPaused`):
- `listLock`
- `sellListedLockToFurnace`
- `sellLockToFurnace`
- `createBonusTargetEscrowWithTarget`
- `executeAutoFurnace`
- `extendBonusTargetEscrowExpiry`

Allowed (exits and housekeeping):
- `delistLock`
- `cancelExpiredListing`
- `emergencyDelist`
- `cancelBonusTargetEscrow`
- `cancelExpiredBonusTargetEscrow`

## Operator notes

The remaining section covers deploy-time wiring. Integrators can skip unless instrumenting governance flows or troubleshooting a bundle-drift revert.

### Wiring hardening

Runtime settlement does not trust a raw Furnace pointer.

- The constructor rejects non-contract / split-brain roots: `claim`, `ve`, and `royalties` must be live contracts, `ve.claimToken()` must equal `claim`, and `royalties.ve()` must equal `ve`.
- Settlement and auto-Furnace execution resolve the live Furnace from `ve.furnace()`.
- Those paths fail closed on bundle drift (see [Wiring safety model](protocol-overview.md#wiring-safety-model)).
- Runtime wiring checks are enforced on every settlement and auto-Furnace execution path.

## See also

- [Furnace](furnace.md) — lock bonus engine and Sell now settlement
- [Locks (veCLAIM)](locks-veclaim.md) — lock lifecycle and ve mechanics
- [ClaimAllHelper](claimallhelper.md) — bundled collect + lock
- [Events and Indexing](events-and-indexing.md) — Market event reference
- Tutorial: [Index Market listings](tutorials/index-market-orderbook.md)
- User manual: [Market](https://docs.claimru.sh/market)
