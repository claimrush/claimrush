# Metrics canon for ClaimRush v1.0.0

This document defines the canonical meanings, units, rounding rules, and computation policies for analytics metrics.

Purpose:
- Prevent dashboards from disagreeing on “the same” number.
- Provide a pinned source for units (wei vs ETH), time semantics, rounding, and attribution.

Scope (v1.0.0):
- Metrics used by the official UI leaderboards and lists.
- Common dashboard metrics derived from events for community analytics.

This document is normative for analytics (subgraph, Dune, and any off-chain indexers).

Related docs:
- Official leaderboard definitions: `docs/analytics/leaderboards-ui-and-dune-compatible-v1.0.0.md`
- Canonical event decoding + enum/codebook: `docs/analytics/dune-integration-pack-v1.0.0.md`
- Indexer implementation notes: `docs/analytics/indexer-and-dune-implementation-guide-v1.0.0.md`
- Analytics trust boundary: `docs/analytics/subgraph-schema-v1.0.0.md` and `docs/analytics/indexing-hosting-and-derived-data-reference-v1.0.0.md`

---

## Global conventions (REQUIRED)

### Units

- ETH amounts are stored and computed in **wei** (`uint256`), unless explicitly labeled “ETH”.
- CLAIM amounts are stored and computed in **wei** (18 decimals).
- “minClaimOut” fields are in **CLAIM wei**.
- Durations are **seconds**.
- Timestamps are **seconds** (block timestamp).
- Basis points are **bps** where `10_000 = 100%`.

UI formatting (non-binding):
- ETH and CLAIM should be displayed with 4–6 decimals in UI tables, but all backend computations remain in wei.

### Time source

Analytics MUST use on-chain time:
- Use block timestamps from event rows (`evt_block_time` on Dune, `block.timestamp` stored by the subgraph).
- Trailing windows (“last 24h/7d/30d”) are computed relative to query time, but the filter uses event timestamps.

### Rounding

Unless explicitly stated:
- Use integer arithmetic.
- Use **rounding down** (`floor`) for computed quantities.

Rationale:
- Rounding down avoids overstating user balances or outputs.

### Start blocks

All dashboards MUST filter event tables by start block.

Source of truth:
- `deployments/base_mainnet.json`.

---

## Product KPIs (UI + gameplay health)

This section pins the definitions for the product KPIs used to judge UI quality and game health.
These KPIs are not leaderboards, and they must never be framed as profit/ROI.

Canonical KPI definitions and the required UI instrumentation are defined in the sections below.

### Meaningful onchain actions (for Active Players and Retention)

A wallet is considered "active" in a time window if it participates in at least one of:

- Crown takeover
  - Event: `MineCore.Takeover`
  - Actor address: `newKing`

- Furnace entry (Lock with Bonus)
  - Event: `Furnace.FurnaceEnter`
  - Actor address: `user`

- Royalties collection (Collect ETH or Collect & Lock)
  - Event: `ShareholderRoyalties.ShareholderClaim`
  - Actor address: `user`

Rules (required):
- Use onchain timestamps for windowing.
- De-duplicate at least by `{chainId, txHash, actor}`.
- Attribute to the actor address from the event, not `tx.from`, when they differ.

### KPI computation policies (onchain-derived)

These rules apply when computing KPI variants that are based on onchain events.

- Weekly Active Players (WAP)
  - Definition: count of unique active wallets in the trailing 7 days.
  - Canonical source: the union of meaningful onchain actions above.

- Takeover participation breadth (7d)
  - Definition: count of unique takeover wallets (`MineCore.Takeover.newKing`) in trailing 7 days.

- Furnace lock participation rate (7d)
  - Definition:
    - numerator: unique wallets with `Furnace.FurnaceEnter.user` in trailing 7 days
    - denominator: Weekly Active Players (WAP) in trailing 7 days

- Net locked value growth (7d/30d)
  - Definition: `lockedSupplyEnd - lockedSupplyStart`, in CLAIM wei.
  - Canonical locked supply source:
    - `VeClaimNFT.totalLockedClaim()` (snapshot based), OR
    - event-sourced reconstruction using `VeClaimNFT` lock lifecycle events.
  - Snapshot guidance:
    - daily snapshots are sufficient for v1 dashboards
    - always label the "as of" timestamp and block number


## Canonical entities and metrics

### 1) Reign

Canonical on-chain sources:
- `MineCore.Takeover(reignId, previousKing, newKing, pricePaid, referencePrice, timestamp)`
- `MineCore.ReignFinalized(reignId, king, startTime, endTime, totalClaimMined, totalEthToKing)`

Definitions:
- `reignId` starts at `1` for the first player takeover.
- The “current reign” is the reign after the latest `Takeover` whose `ReignFinalized` has not yet been emitted.
- `reignLengthSeconds` (finalized reign) = `endTime - startTime`.

Important:
- Duration-filtered “Top CLAIM mined as King” uses **finalized-in-window** semantics: include a reign if its `ReignFinalized` event occurs in the window (no prorating).

### 2) Takeover price (ETH spent)

Canonical on-chain source:
- `MineCore.Takeover.pricePaid`.

Rules:
- “ETH spent on takeovers” MUST use `pricePaid`.
- Do NOT use `tx.value` as spend. `tx.value` may exceed `pricePaid` (refund path).

Attribution:
- The spender is `newKing` from the `Takeover` event.

### 3) Reference price

Canonical on-chain source:
- `MineCore.Takeover.referencePrice`.

Meaning:
- The protocol’s post-takeover reference anchor for decay.
- It is not “ETH spent”. It is a state variable used for pricing.

### 4) King ETH payout

Canonical on-chain source:
- `MineCore.ReignFinalized.totalEthToKing`.

Meaning:
- Total ETH allocated to the dethroned king for the finalized reign.

Notes:
- MineCore may attempt a best-effort push and fall back to a pull bucket. Analytics MUST treat `totalEthToKing` as the canonical amount allocated, independent of delivery mechanism.

### 5) King CLAIM mined

Canonical on-chain source:
- `MineCore.ReignFinalized.totalClaimMined`.

Meaning:
- Total CLAIM minted to the king for the finalized reign.

Attribution:
- The beneficiary is `king` in the `ReignFinalized` event.

### 6) Shareholder ETH allocations and distribution index

Canonical on-chain sources:
- `ShareholderRoyalties.ShareholderTakeoverAllocation(reignId, amountEth)`
- `ShareholderRoyalties.ShareholderFlush(amountEth, deltaEthPerVe)`
- `ShareholderRoyalties.ShareholderClaim(user, mode, amountEth)`

Definitions:
- `pendingShareholderETH` increases when `ShareholderTakeoverAllocation` is emitted.
- `flushPendingShareholderETH()` emits `ShareholderFlush` when distribution occurs.

Rules:
- Dashboards MUST NOT infer allocations from raw ETH transfers; use the emitted events.
- Claims MAY be manual (user call) or maintainer-driven (auto-compound via allowlisted keeper or owner break-glass). Both emit `ShareholderClaim`.

Claim attribution:
- The claimer/beneficiary is `user`.
- `mode` codebook is pinned in `docs/analytics/dune-integration-pack-v1.0.0.md`.

### 7) veCLAIM per-lock ve (current)

Canonical on-chain source:
- `VeClaimNFT.getLockInfo(tokenId)` for `amount` and `lockEnd`.

Canonical formula (required off-chain interpretation):

Let:
- `amountWei` = locked principal (CLAIM wei)
- `remaining = max(lockEnd - asOfTimestamp, 0)`
- `MAX = MAX_LOCK_DURATION_SECONDS`

Then:
- `veCurrentWei(tokenId, asOfTimestamp) = floor(amountWei * remaining / MAX)`

Rules:
- Per-lock ve MUST round down.
- User ve is the sum of per-lock ve across owned tokenIds.

Snapshot requirement:
- “Top veCLAIM holders (current)” MUST be computed from a **snapshot** at a single `asOfTimestamp` (and ideally an `asOfBlockNumber`).
- This is typically implemented as a small derived-data job (see indexer guide).

### 8) Locked supply

Canonical on-chain source:
- `VeClaimNFT.totalLockedClaim()`.

Rule:
- Dashboards MUST NOT equate `CLAIM.balanceOf(VeClaimNFT)` with locked supply.
- Direct token transfers (“donations”) to the ve contract can make the raw balance exceed `totalLockedClaim()`.

### 9) Furnace entries and realized bonus

Canonical on-chain sources:
- `Furnace.FurnaceEnter(user, mode, ethIn, principalClaim, bonusClaim, tokenId)`
- (optional deep dive) `Furnace.BonusPaid(...)` (contains quote and state deltas)

Definitions:
- `principalClaim` is the CLAIM principal locked (in CLAIM wei).
- `bonusClaim` is the extra CLAIM allocated from Furnace bonus mechanics (in CLAIM wei).
- `realizedBonusBps = floor(bonusClaim * 10_000 / principalClaim)` (if `principalClaim > 0`).
- For windowed leaderboards, use aggregate-of-sums semantics:
  - `windowedBonusBps(user) = floor( SUM(bonusClaim) * 10_000 / SUM(principalClaim) )` within the selected window.
  - Apply any minimum principal threshold AFTER aggregation (see leaderboard definitions).

Token-entry note:
- For `enterWithToken`, analytics MUST decode `tokenIn` and `amountIn` from calldata as specified in the indexer guide.
- WETH as `tokenIn` is supported as a special-case (unwrap to ETH); analytics should treat this as token entry with `tokenIn = WETH` and `amountInWei` populated from calldata.

### 10) MarketRouter (lock management)

**Strict mode invariant (Furnace-only lock trading):**
- The **Furnace is the only counterparty** for lock purchases.
- There are **no user-to-user lock sales**.
- Listings are limit sells to the Furnace.
- Bonus target escrow orders are entry orders into the Furnace.

Canonical on-chain sources:
- `MarketRouter.LockListed(tokenId, seller, minClaimOut, listedAtTime, expiresAtTime)` — listing created (limit sell to Furnace)
- `MarketRouter.LockDelisted(tokenId, seller, reason)` — listing removed
- `MarketRouter.ListingSettled(tokenId, seller, claimOut, penalty)` — Furnace settled a listing
- `MarketRouter.BonusTargetEscrowCreated(escrowId, buyer, discountBps, durationSeconds, createAutoMax, expiresAt, destinationLockId, budgetClaim, createdAt)`
- `MarketRouter.BonusTargetEscrowConfigured(escrowId, buyer, targetBonusBps, slippageBps)`
- `MarketRouter.BonusTargetEscrowExecuted(escrowId, buyer, claimIn, principalClaim, bonusClaim, veOut, routeTokenId, furnaceTokenId)`
- `MarketRouter.BonusTargetEscrowAutoFurnaceExecuted(escrowId, buyer, claimIn, principalClaim, bonusClaim, veOut, routeTokenId, furnaceTokenId)`
- `MarketRouter.BonusTargetEscrowCancelled(escrowId, buyer, refundClaim)`
- `MarketRouter.BonusTargetEscrowExpired(escrowId, buyer, refundClaim)`
- `MarketRouter.BonusTargetEscrowExpiryExtended(escrowId, buyer, oldExpiresAt, newExpiresAt)`

Rules:
- All listing prices and budgets are denominated in **CLAIM wei**.
- All settlements are Furnace settlements. There are no user-to-user trades.
- `executeAutoFurnace` emits both `BonusTargetEscrowExecuted` and `BonusTargetEscrowAutoFurnaceExecuted`; canonical execution volume and value metrics MUST key off the generic `BonusTargetEscrowExecuted` receipt to avoid double counting.

Common derived metrics (non-binding):
- "Market volume (CLAIM)" (windowed) = `SUM(claimOut)` over `ListingSettled` + `SUM(claimIn)` over `BonusTargetEscrowExecuted`.
- "Median listing settlement price per CLAIM" = `claimOut / lockAmount` (both in CLAIM wei; compute as a fixed-point ratio, round down).

---

## Forbidden metrics (v1.0.0)

These MUST NOT appear in the official UI leaderboards:
- APY
- ROI
- Long-horizon “net earned”
- Profit projections

Rationale:
- The official UI is not a portfolio performance tool.
