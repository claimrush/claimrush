# docs/spec/apr-calculation-spec-v1.0.0.md

> [!WARNING]
> **Locked for v1.0.0 (do not edit without version bump)**
>
> This file is part of the v1.0.0 canonical spec set.
> Behavior changes belong in a separately versioned spec file, and the repo indexes must point to the active version.

This document specifies **offchain** APR calculations for ClaimRush v1.0.0.

Implementation status note:
- The formulas in this document are canonical for any UI/indexer that chooses to publish APR.
- This repo ships the subgraph schema and singleton helpers for `TokenPricingSnapshot` / `AprSnapshot`, but it does **not** ship a producer that populates those entities with live pricing or APR values.
- Until an external pricing/APR producer is added, integrators should expect those fields to be null or stale and should surface `APR unavailable` instead of assuming the data exists.

Scope:
- Computes **Estimated APR (24h)** for the LP Staking Vault.
- Computes **Estimated veAPR (24h)** for ve lockers (Barons).

Protocol boundaries:
- This is not a promise of returns.
- This does not include impermanent loss (IL), price PnL, gas costs, or compounding (APY).
- This does not change any onchain mechanics.

Constants:
- `APR_ANNUALIZATION_DAYS = 365` — annualization basis used by every APR display surface.
- `MIN_APR_TVL_USD = 50_000` — TVL floor under which APR is suppressed (UI / indexer parity).
- These are UI/indexer-only constants; they intentionally do not live in `src/lib/Constants.sol` because the protocol has no onchain APR.

---

## Units + rounding (required)

- Amount units: token amounts are in native token units (18 decimals for CLAIM/WETH/LP).
- Rounding: all divisions MUST round DOWN (floor) (see [math and rounding appendix](../architecture/math-and-rounding-appendix-v1.0.0.md) §M.1).
- Time window: the 24h window is `[asOfTs - 86_400, asOfTs)` where `headTs` is the analytics backend head block timestamp and `asOfTs = floor(headTs / 3600) * 3600`.
- Output: compute APR as integer **basis points** (bps):
  - `aprBps = floor(10_000 * APR_ANNUALIZATION_DAYS * numeratorUsd / denominatorUsd)`
  - UI percent string = `aprBps / 100` with 2 decimals.
- Edge cases: if any denominator is `0`, APR MUST be unavailable.

---

## Common pricing primitives (v1)

All APR values are computed in USD using the same UI/indexer pricing model:

- **ETH/USD**: Chainlink ETH/USD feed on Base (read-only).
- **CLAIM/ETH**: 30 minute DEX TWAP from the canonical CLAIM/WETH pool.
- **CLAIM/USD**:
  - `claimUsd = claimEthTwap30m * ethUsd`

Rules:
- Pricing is UI/indexer-only and MUST NOT be used for onchain safety checks.
- If any required pricing input is missing or stale, APR MUST be treated as unavailable.
- Staleness thresholds (APR marked unavailable):
  - Define `headTs` as the timestamp of the newest indexed block used for APR (subgraph `_meta.block.timestamp`).
  - Define `nowTs` as the current wall-clock timestamp (seconds).
  - APR MUST be unavailable if any condition holds:
    - Indexer lag: `nowTs - headTs > 1_800` seconds.
    - ETH/USD feed stale: `headTs - ethUsd.updatedAt > 7_200` seconds.
    - CLAIM/ETH TWAP missing: `claimEthTwap30m` cannot be computed for the full window `[headTs - 1_800, headTs]` (insufficient observations).

---

## Estimated APR (24h) — LP Staking Vault

### UI behavior (required)

- Display:
  - `Estimated APR (24h): {x}%`
- Tooltip:
  - “Annualized from the last 24h. Estimate only.”
- If `avgTVL24hUsd < MIN_APR_TVL_USD`:
  - Display: `APR unavailable`
  - Tooltip: “APR shown only when avg TVL (24h) ≥ $50,000.”

### Definition (required)

- `APR24h = APR_ANNUALIZATION_DAYS * (rewardsValue24hUsd / avgTVL24hUsd)`

Where:

#### A) rewardsValue24hUsd

- `rewardsClaim24h` = sum of LP vault reward funding over the last 24h (CLAIM units).
  - Source of truth: `LpRewardsNotified(amountClaim)` events.
  - This implicitly includes all funding sources (Furnace split + fee donations), since they all result in reward notifications.
- `rewardsValue24hUsd = rewardsClaim24h * claimUsd`

#### B) avgTVL24hUsd

- `tvlUsd(t) = totalStakedLP(t) * lpValueUsd(t)`

Where:

- `totalStakedLP(t)` is the total LP currently earning rewards in the LP vault.
  - Indexer MUST maintain this from vault events:
    - `LpStaked(user, amount)` increases total
    - `LpUnbondStarted(user, unbondId, amount, unlockTime)` decreases total
  - Clarification: `LpUnbondWithdrawn(...)` does not change `totalStakedLP` if the decrease is accounted for at `beginUnbond`.

- `lpValueUsd(t)` is derived from the canonical CLAIM/WETH pool reserves:
  - `claimPerLP = reserveClaim / totalSupplyLP`
  - `wethPerLP  = reserveWeth  / totalSupplyLP`
  - `lpValueUsd = claimPerLP * claimUsd + wethPerLP * ethUsd`

Data inputs required (for `lpValueUsd`):
- pool reserves (via `Sync` events or periodic `getReserves()` snapshots)
- pool `totalSupply()` snapshots
- `ethUsd` (Chainlink)
- `claimEthTwap30m` (canonical pool TWAP)

Averaging rule:
- `avgTVL24hUsd` is the time-average of `tvlUsd(t)` over the last 24 hours.
- Implementations MUST use 24 hourly snapshots and the arithmetic mean (one value per hour) to compute `avgTVL24hUsd`.

Threshold rule:
- If `avgTVL24hUsd < MIN_APR_TVL_USD`, return NULL for APR and show `APR unavailable` in the UI.

---

## Estimated veAPR (24h) — ve lockers (Barons)

### UI behavior (required)

- Display:
  - `Estimated veAPR (24h): {y}%`
- Tooltip:
  - “Annualized from the last 24h shareholder ETH flow. Estimate only.”

### Definition (required)

- `veAPR24h = APR_ANNUALIZATION_DAYS * (shareholderEthAllocated24hUsd / totalLockedClaimUsd)`

Where:

#### A) shareholderEthAllocated24hUsd

- `eth24h` = sum of ETH allocated to `ShareholderRoyalties` over the last 24h.
- Event source: sum `ShareholderTakeoverAllocation(reignId, amountEth)` over the last 24h.

Convert to USD:
- `shareholderEthAllocated24hUsd = eth24h * ethUsd`

#### B) totalLockedClaimUsd

- `totalLockedClaim` = current total locked CLAIM in ve locks.
- Source of truth: `VeClaimNFT.totalLockedClaim()` (indexer snapshot).

Convert to USD:
- `totalLockedClaimUsd = totalLockedClaim * claimUsd`

Clarification (non-binding):
- veAPR is a short-window estimate. It will spike with takeover bursts and fall during quiet periods.


---

## Test vectors required

LP APR (bps):
- Given:
  - `APR_ANNUALIZATION_DAYS = 365`
  - `rewardsValue24hUsd = 50`
  - `avgTVL24hUsd = 100_000`
- Then:
  - `APR24h = 365 * (50 / 100_000) = 0.1825`
  - `aprBps = floor(10_000 * 0.1825) = 1825` (UI displays `18.25%`).

veAPR (bps):
- Given:
  - `eth24h = 0.1 ETH`, `ethUsd = 2_000` → `shareholderEthAllocated24hUsd = 200`
  - `totalLockedClaim = 20_000_000 CLAIM`, `claimUsd = 0.01` → `totalLockedClaimUsd = 200_000`
- Then:
  - `veAPR24h = 365 * (200 / 200_000) = 0.365`
  - `veAprBps = floor(10_000 * 0.365) = 3650` (UI displays `36.50%`).

Threshold gate:
- If `avgTVL24hUsd < MIN_APR_TVL_USD`, the UI MUST display `APR unavailable`.
