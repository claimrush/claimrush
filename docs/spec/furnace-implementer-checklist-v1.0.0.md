# Furnace implementer checklist (v1.0.0)

This is an **implementer-focused checklist** for `Furnace`, the unified entry and bonus engine.

Source of truth:
- Canonical behavior: `docs/spec/spec-v1.0.0.md` §7 (Furnace)
- Lock routing rules: `docs/spec/spec-v1.0.0.md` §4.4 (VeClaimNFT lock destination)
- Constants and clamps: `src/lib/Constants.sol`
- Rounding + index math: [math and rounding appendix](../architecture/math-and-rounding-appendix-v1.0.0.md)

Spec aids (recommended):
- `docs/spec/state-machines-v1.0.0.md` (Furnace entry flow diagram)
- `docs/spec/test-vectors-v1.0.0.md` (§§1–5 Furnace math and bonus worked examples)

This document restates requirements in an implementable order.

---

## Goals

Furnace MUST:
- Accept entry assets and convert them into a veCLAIM lock for a recipient.
- Quote and apply a split-resistant bonus paid from `furnaceReserve`.
- Enforce slippage and routing invariants:
  - revert if registry config is missing or token route is not allowlisted
  - enforce `minVeOut` on all entry paths
- Split gross bonus into:
  - user bonus (increased commitment)
  - LP rewards cut funded into the Furnace LP rewards stream (dripping to `LpStakingVault7D`, if configured)
- Optionally fund LP rewards via the LP overflow drip (protocol; reserve → LP rewards stream, per-day; env-config §3.4.6).

---

## Revert and no-op matrix

These rules remove ambiguity for integrators and prevent “silent no-op” behavior that can strand user funds.

- **All entry functions** (`enterWithEth`, `enterWithClaim`, `enterWithClaimFor`, `enterWithToken`, `lockEthReward`):
  - MUST revert when `lockingPaused == true`.
  - MUST revert when the `EntryTokenRegistry` is unset.
  - MUST revert when the relevant route/pool config is not allowlisted in the registry (fail closed).
  - MUST revert when the entry-attributable `veOut` for the newly locked amount is below `minVeOut` (atomic slippage protection).
  - If `targetTokenId == 0` (create new lock): MUST revert when the resulting lock amount would be below `MIN_LOCK_AMOUNT`.

- **Quote views** (`quoteEnterWithEth`, `quoteEnterWithClaim`, `quoteEnterWithToken`, `quoteExtendWithBonus`, `quoteAutoMaxBonus`, `quoteAutoMaxBonusBatch`, `quoteSellLockToFurnace`, `quoteSellLockToFurnaceFromInfo`, `quoteSellLockToFurnaceBreakdown`, `quoteSellLockForExecution`):
  - MUST follow the same allowlist checks as execution.
  - MUST revert when `lockingPaused == true` (quotes are part of the live lock/sell surface).

- `enterWithClaimFor(...)`:
  - MUST revert when caller is not an authorized contract (spec §7.2).
  - When the caller is `MarketRouter`, MUST also fail closed unless the live `MarketRouter.royalties()` root still equals the canonical `ShareholderRoyalties` wired into Furnace.

- `lockEthReward(...)`:
  - MUST revert when caller is not `ShareholderRoyalties`.
  - MUST revert unless `msg.value == ethAmount`.
  - MUST use only the ETH transferred in with the current `lockEthReward(...)` call; idle Furnace ETH balance does not count toward `ethAmount`.

- Reserve funding (`creditReserve(...)`):
  - MUST be callable only by MineCore.
  - MUST treat `amount == 0` as a no-op.

---

## Checklist: required state

Source: spec §7.1.

Furnace MUST track:
- Token references:
  - CLAIM token
  - VeClaimNFT (veCLAIM)
  - ShareholderRoyalties (lock-mode routing)
- Registry:
  - `EntryTokenRegistry` address (MUST be set during initial wiring)
- Bonus accounting:
  - `furnaceReserve` (CLAIM inventory reserved for gross bonuses and LP rewards incentives)
  - `bonusVirtualDepth` + `lastBonusUpdate` (AMM-style quote state)
- LP reward split:
  - `lpRewardsVault` (can be `address(0)` to disable later LP routing)
  - rewires/disables MUST fail closed while already-earned LP liability remains attributable to the current vault
  - any successful vault change MUST reset the overflow-drip accrual cursor so a new vault period cannot inherit prior backlog
- LP rewards stream schedule (state in Furnace; spec §7.3.6):
  - `lpStreamRatePerSec`
  - `lpStreamPeriodFinish`
  - `lpStreamLastUpdate`
- LP overflow drip (protocol):
  - Implement a continuous reserve → LP rewards stream funding action per env-config §3.4.6: on each call, compute `dripped = (perDay * dt) / 1 days` where `dt` is elapsed since `lastLpOverflowDripUpdate`.
  - Track `lastLpOverflowDripUpdate` and advance it on every accrual. The drip is proportional to elapsed time (not once-per-day); the per-day rate is the cap, not the frequency.
- Pausing:
  - locking pause is routed/managed via MineCore rules (§5.6.2)
- Guardian wiring:
  - `Furnace.setMineCore(address _mineCore)` atomically sets `guardian = _mineCore`. No separate `setGuardian` call is needed.
  - `Furnace.guardian` MUST remain pinned to `MineCore` once set. `setGuardian` may only re-assert the current `MineCore` address.
  - `Furnace.setMineCore` MUST be called BEFORE `MineCore.setFurnace` (reciprocal wiring validation; MineCore checks `Furnace.mineCore() == address(this)`).

---

## Checklist: entry preconditions

Source: spec §7.2.

Before any entry path (or any quote view that depends on swap estimation):
- Registry MUST be configured (non-zero address).
- Token route and pool config MUST be allowlisted in the registry.
- If registry is unset, or token/pool is not allowlisted:
  - MUST revert (fail closed).
- `furnaceQuoter` MUST be nonzero before entering the principal processing path. If `furnaceQuoter == address(0)`, the entry MUST revert early (prevents downstream quote failures from masking a configuration error).

---

## Checklist: lock destination parameters (shared across all entry paths)

Source: spec §7.2 + §4.4.

All entry paths and quote views use these parameters:

- `targetTokenId`
  - `0` means “create a new lock for the receiver”.
  - non-zero means “use an existing lock id”.
  - If `targetTokenId == 0`, the minted veCLAIM lock MUST satisfy the protocol minimum:
    - `amountLocked >= MIN_LOCK_AMOUNT = 1_000e18` CLAIM (1,000 CLAIM).
    - If below this, the entry MUST revert (callers MUST route into an existing lock instead).
- `durationSeconds`
  - selected lock duration
  - MUST be clamped to `[MIN_LOCK_DURATION, MAX_LOCK_DURATION]`
- `createAutoMax`
  - only relevant when `targetTokenId == 0` and duration is max-duration
  - MUST obey VeClaimNFT restrictions (spec §4.2 + §4.4)
- `minVeOut`
  - slippage guard on the entry-attributable `veOut` for the newly locked amount
  - MUST be enforced on all entry paths

- [ ] `FurnaceGuardHelper.resolveEntryDurationAndWeight` and `resolveExistingLockDestination` revert with `InvalidDuration` when an existing non-AutoMax lock has `< MIN_LOCK_DURATION` remaining.

---

## Checklist: entry paths

Source: spec §7.2.

Implement the entry functions listed in §7.2, including the authorization restrictions where specified.

Key invariants (common to all):
- Determine `commitmentClaim` (the CLAIM amount that will be locked after swaps).
- Compute the bonus quote and apply it deterministically (below).
- Route into the destination lock per spec §4.4.
- Enforce `minVeOut`.

Special-case authorization:
- `enterWithClaimFor(...)` is restricted to the authorized contracts in spec (MarketRouter, LpStakingVault7D, MineCore). When the caller is MarketRouter, the implementation MUST also verify that `MarketRouter.royalties()` still matches the canonical `ShareholderRoyalties` root before accepting the entry.

Token entry routing (execution + quotes):
- **WETH special-case (REQUIRED):** if `tokenIn == wrappedNative` (WETH):
  - Execution MUST pull WETH, unwrap 1:1 to ETH, then swap `ETH -> CLAIM` via the pinned `WETH -> CLAIM` hop.
  - Quote MUST treat `amountIn` as `ethIn` (1:1 unwrap) and quote via the same pinned hop.
  - (WETH MUST NOT be configured as `tokenIn` in the registry.)
- Else: `tokenIn` MUST be enabled in `EntryTokenRegistry` for Furnace entry.
  - Resolve routing via the registry (no user-supplied routes/pools/stable flags):
    - if direct pool enabled: swap `tokenIn -> CLAIM`
    - else: swap `tokenIn -> WETH -> CLAIM`
  - Every hop MUST be validated vs the allowlisted pool via `router.poolFor(...)`.

---

## Checklist: bonus calculation and quoting semantics

Source: spec §7.3 + constants doc (§3.4).

You MUST implement:

- Locked-supply anchor + reserve ramp (user cap):
  - Compute `lockedSupply` as total CLAIM locked in ve (principal + locked bonuses), typically `VeClaimNFT.totalLockedClaim()`.
  - Compute `baseUserBps`, `reserveFullnessBps`, `swingAlphaBps`, `reserveFactorBps`, and `userSpotBps` exactly as pinned in env-config §3.4 and appendix §M.2.
    - When `reserveFullnessBps < 10_000`, the down-branch MUST use a **ceiling** adjustment to preserve signed-floor semantics.
  - Enforce `0 <= userSpotBps <= 10_000`.

- Additive LP top-up and gross cap:
  - Compute `lpRateBpsBase` in `[750, 1_500]` (convex in the normalized bonus) and apply reserve-aware scaling (down-only):
    - `lpRateBps = floor(lpRateBpsBase * lpScaleBps / 10_000)` where `lpScaleBps = min(10_000, reserveFactorBps(...))` after the lock-% max-boost cap.
  - Compute `lpTopupSpotBps` and `grossSpotBps = userSpotBps + lpTopupSpotBps`.
  - Enforce `grossSpotBps <= 12_500` (hard clamp). With defaults, `grossSpotBps <= 11_500` (115%).

- Stateful AMM + decay:
  - Maintain `furnaceReserve` (R), `bonusVirtualDepth` (V), `lastBonusUpdate`.
  - `BONUS_DECAY_WINDOW = 3 hours`.
  - For each entry, compute `vTarget = ceil(R * 10_000 / grossSpotBps)` when `grossSpotBps > 0` (else treat as zero-bonus regime).
  - Enforce `V >= vTarget` and linearly decay `V` back toward `vTarget` over `BONUS_DECAY_WINDOW`.
  - Compute gross bonus using AMM-style formula (env-config §3.4), with duration-weighted `P_eff`.

Bonus rounding + cap enforcement (do not improvise):
- `grossSpotBps` is computed with floor rounding.
- `vTarget` MUST be computed with **ceiling** rounding:
  - `vTarget = ceil(R * 10_000 / grossSpotBps)`
  - This is what makes the bonus cap strict in integer math.
- The gross bonus paid MUST be floored:
  - `grossBonus = floor(R * P_eff / (V + P_eff))`
- The implementation MUST satisfy (integer-safe):
  - `grossBonus * 10_000 <= P_eff * grossSpotBps`
- If the effective principal `P_eff == 0`, bonus MUST be 0 and the AMM update MUST be skipped (no change to `bonusVirtualDepth` and `lastBonusUpdate`).

Quoting MUST be consistent:

- Quote views MUST use the same calculation as state-changing entry functions.
- Quote views that depend on registry swap estimates MUST use the same registry config as execution.
- Quote bps MUST be returned as:
  - `quoteUserBonusBps` (net user, UI headline)
  - `quoteLpTopupBps` (additive LP top-up), computed as `floor(quoteUserBonusBps * lpTopupRateBps / 10_000)`
  - The internal `quoteGrossBps` used for clamping MUST NOT be reconstructed by exact subtraction from the returned fields; the returned split can be slightly lower due to floor dust.


Event emission (required for analytics; v1.0.0):
- On every entry where the AMM draws a non-zero bonus from `furnaceReserve`, Furnace MUST emit:
  - `BonusPaid(...)` (canonical schema pinned in `docs/analytics/dune-integration-pack-v1.0.0.md`; emitted via delegatecall to FurnaceGuardHelper; declared in IFurnace for ABI presence)

## Checklist: LP overflow drip (protocol → LP rewards stream)

Source: env-config §3.4.6 + math appendix §M.2.8.

Event emission (required for analytics; v1.0.0):
- On each drip transfer where `dripAmount > 0`, Furnace MUST emit:
  - `LpOverflowDripPaid(...)` (canonical schema pinned in `docs/analytics/dune-integration-pack-v1.0.0.md`; emitted via delegatecall to FurnaceGuardHelper; declared in IFurnace for ABI presence).

- This is separate from the per-lock LP top-up split (`lpRewardClaim`).
- Per 24 hours, compute `lpOverflowDripPerDay` from:
  - excess reserve above `RESERVE_TARGET_FINAL`,
  - time ramp-in (`LP_OVERFLOW_DRIP_START`, `LP_OVERFLOW_DRIP_RAMP`),
  - and inflow cap (`LP_OVERFLOW_DRIP_INFLOW_SHARE_CAP_BPS` of current Furnace inflow/day), with a fixed hard cap.
- If `furnaceReserve <= RESERVE_TARGET_FINAL` (excess == 0), drip MUST be 0.
- Drip MUST fund the Furnace LP rewards stream (same destination as `lpRewardClaim`), and MUST be disabled when `lpRewardsVault == address(0)`.
- Total reserve spent by drip over a 24h window MUST NOT exceed `lpOverflowDripPerDay` (execution guard required).

## Checklist: LP rewards stream (14-day smoothing)

Source: spec §7.3.6 + env-config §3.4F.

Goal:
- Smooth all Furnace-funded LP rewards (bonus splits, overflow drip, sellback LP share) over time to avoid reward-rate spikes.

Required behavior:
- Maintain stream schedule state:
  - `lpStreamRatePerSec`, `lpStreamPeriodFinish`, `lpStreamLastUpdate`.
- Derived value:
  - `lpStreamRemaining = (periodFinish > now) ? (periodFinish - now) * ratePerSec : 0`.
- Before any call that may change stream schedule (funding) or needs accurate accounting, Furnace MUST accrue:
  - Compute `owed = min((now - lastUpdate) * ratePerSec, lpStreamRemaining_before)`.
  - Transfer `owed` CLAIM to `lpRewardsVault` and call `LpStakingVault7D.notifyRewards(owed)` (delta-based, best-effort; MUST NOT revert upstream entry/lock flows if the vault call fails).
  - Update `lpStreamLastUpdate = now`.

Funding:
- `lpRewardClaim` from each `BonusPaid` must call `_fundLpStream(lpRewardClaim)` (if LP rewards enabled).
- `dripAmount` from the overflow drip must call `_fundLpStream(dripAmount)` (if LP rewards enabled).
- `lpReward` from sellback must call `_fundLpStream(lpReward)` (if LP rewards enabled).

Schedule update (standard “rollover”):
- If `now >= periodFinish`: start new 14-day schedule with `rate = amount / LP_STREAM_WINDOW`.
- Else: carry remaining + new amount into a fresh 14-day schedule.
- After each successful re-fund, Furnace MUST emit `LpStreamFunded(amountFunded, newRatePerSec, newPeriodFinish)`.

`tick()`:
- Permissionless.
- MUST call `_accrueLpStream()` and MAY also run the once-per-day overflow drip funding guard.

## Checklist: gross bonus split to LP rewards

Source: spec §7.3.4 + constants doc (§3.4).

- Gross bonus is computed in the AMM in **gross** units (total drawn from reserve).
- Gross bonus is split deterministically into:
  - user bonus (locked for the user)
  - LP reward (funded into the LP rewards stream if configured)

Split rule:

- `denom = 10_000 + lpRateBps`
- `userBonusClaim = floor(grossBonusClaim * 10_000 / denom)`
- `lpRewardClaim = grossBonusClaim - userBonusClaim`

Safety:

- Never overdraw reserve:
  - `grossBonusClaim <= furnaceReserve_before`.
- Exact split:
  - `userBonusClaim + lpRewardClaim == grossBonusClaim`.
- If `lpRewardsVault == address(0)`:
  - LP reward MUST be 0 and MUST NOT be funded/transferred when `lpRewardsVault == address(0)`; user bonus semantics MUST remain correct.

## Checklist: reserve funding and invariants

Source: spec §7.4.

Reserve rules:
- `furnaceReserve` is credited from MineCore emissions via `Furnace.creditReserve(...)`, and from sellback net retention (spec §7.6).
- Entry paths MUST NOT overdraw the reserve.
- All reserve arithmetic MUST follow rounding rules in the math appendix.

Invariants to preserve:
- Bucketed solvency MUST hold: `CLAIM.balanceOf(Furnace) >= furnaceReserve + lpStreamRemaining`.
- `furnaceReserve` decreases when paying gross bonuses and when funding the LP overflow drip (into the LP stream).
- Virtual-depth state MUST update on each entry to preserve split resistance.

---

## Checklist: sellback (veCLAIM → liquid CLAIM)

Source: spec §7.6 + env-config §3.4E.

Required entrypoint:
- `sellLockToFurnaceFromMarket(address seller, uint256 tokenId, uint256 minClaimOut)`.

User-facing instant sellback lives on `MarketRouter.sellLockToFurnace(tokenId, minClaimOut, deadline)`, which moves the lock into Furnace custody with `safeTransferFrom(...)` and then calls the restricted Furnace helper above. The helper must bind payout to the observed prior owner instead of trusting a caller-supplied `seller` blindly.

Preconditions (REQUIRED):
- Revert if `lockingPaused`.
- Revert unless the caller is the canonically wired `MarketRouter` bundle. A raw `Furnace.mineMarket` pointer match is not sufficient; the live `MarketRouter`, `VeClaimNFT`, `ShareholderRoyalties`, `MineCore`, and `ClaimToken` roots must still agree.
- Revert if lock is expired (`lockEnd <= now`); user should unlock normally.
- Revert if the lock is still listed.
- For user-facing sells, MarketRouter MUST clear any active listing first (auto-delist) before calling Furnace.

Flow (REQUIRED):
- Transfer the veCLAIM NFT from the user to Furnace with `safeTransferFrom(...)` so the receiver hook records the observed seller (requires VeClaimNFT transfer allowlist update).
- The receiver hook itself MUST fail closed unless the live `MarketRouter`, `VeClaimNFT`, `ShareholderRoyalties`, `MineCore`, and `ClaimToken` roots still agree on the same canonical bundle. A raw stored `mineMarket` pointer is not sufficient for custody admission.
- Call the VeClaimNFT furnace-only burn+withdraw method to withdraw the lock principal `L` to Furnace.
- Quote using `userSpotBonusBps` as the primary driver, computed for sellback using `lockedSupplyExcl` and `reserveBefore` (spec §7.6):
  - `lockedSupplyExcl = VeClaimNFT.totalLockedClaim()` after burning the sold lock (i.e., excluding `L`).
  - `reserveBefore = furnaceReserve` before crediting `reserveAdd`.
  - Compute `bonusBps` via the user spot bonus rules (spec §7.3.1) using `lockedSupplyExcl`, `reserveBefore`, and `elapsed`.
  - Compute `spreadNoArbBps = ceil(10_000 * bonusBps / (10_000 + bonusBps))`.
  - Compute `spreadCurveBps` via convex curve and take `spreadSystemBps = max(spreadNoArbBps, spreadCurveBps)`.
  - Apply duration factor to obtain final `spreadBps` (spec §7.6). In v1.0.0, `_sellSpreadWithSize` ignores the `sizeRatioBps` parameter — the size-dependent spread is computed for the breakdown struct but does not affect the actual spread.
  - `claimOut = floor(L * (10_000 - spreadBps) / 10_000)`.
  - Enforce `claimOut >= minClaimOut`.
- `cut = L - claimOut`.
- Split cut:
  - `lpReward = floor(cut * lpSaleShareBps / 10_000)` (0 if LP rewards disabled).
  - `reserveAdd = cut - lpReward`.
- Transfer `claimOut` to seller.
- Credit `reserveAdd` to `furnaceReserve`.
- Fund LP stream by `lpReward` (if enabled).
- The helper and the receiver hook MUST use the same canonical MarketRouter bundle check; custody admission must not accept a raw-pointer-only market that helper execution would later reject.

Event emission (required for analytics; v1.0.0):
- Emit `LockSoldToFurnace(...)` on every successful sellback (emitted via delegatecall to FurnaceGuardHelper; declared in IFurnace for ABI presence).

## Sell-impact tracking requirements

Source: spec §7.6 + Constants.sol `SELL_IMPACT_*`.

- Furnace MUST maintain `sellImpactVolume` and `lastSellImpactUpdate` state variables to track cumulative sell volume with linear decay over `BONUS_DECAY_WINDOW`.
- On each sellback, the accrued sell impact volume MUST be updated via `computeAccruedSellImpactVolume(currentVol, lastUpdate, lockAmount)`.
- When a Furnace entry occurs while sell impact is elevated, the contract MUST emit `NearSlippageLimitEntry(user, minVeOut, actualVeOut, marginBps)` as a transparency signal if the margin between actual and minimum ve output falls within the sell-impact monitoring threshold.
- FurnaceGuardHelper provides `previewSellImpactVolume` and `computeAccruedSellImpactVolume` for off-chain previews.

## Checklist: integration points

### MineCore -> Furnace
Source: spec §5.4.2 and §7.4.

- MineCore mints the Furnace emission stream and calls `Furnace.creditReserve(...)`.

### Furnace -> VeClaimNFT
Source: spec §4.4 and §7.2.

- Furnace routes the (commitment + bonus) amount into a veCLAIM destination:
  - create new lock or add to an existing lock (entry does not change the lock's duration)
- Ensure the resulting entry-attributable `veOut` satisfies `minVeOut`.

### Furnace -> ShareholderRoyalties
Source: spec §7.1.

- Furnace uses ShareholderRoyalties to resolve lock-mode routing where specified.

---

## Worked examples (sanity checks)

These examples are non-normative. They exist to catch rounding mistakes and “ceil vs floor” bugs during review.

### Example A: `vTarget` MUST use **ceiling** rounding

Assume:
- `R = 1_000` (CLAIM units)
- `grossSpotBps = 3_333`

Compute:
- `vTarget = ceil(R * 10_000 / grossSpotBps)
         = ceil(10_000_000 / 3_333)
         = ceil(3_000.3000...)
         = 3_001`

If an implementation incorrectly uses floor rounding (`3_000`), the cap becomes slightly porous.

### Example B: gross bonus cap inequality (spot cap is strict)

Assume:
- `R = 1_000`
- `V = 3_001` (already at `vTarget`)
- `P_eff = 100`
- `grossSpotBps = 3_333`

Compute:
- `grossBonus = floor(R * P_eff / (V + P_eff))
             = floor(1_000 * 100 / 3_101)
             = 32`

Check the required inequality:
- `grossBonus * 10_000 = 320_000`
- `P_eff * grossSpotBps = 333_300`
- `320_000 <= 333_300` ✅

### Example C: UI slippage protection for `minVeOut`

If `quoteVeOut = 1_234` and `slippageBps = 100` (1%):
- `quoteVeOut` here covers only the newly locked amount at the lock's remaining duration.
- `minVeOut = floor(quoteVeOut * (10_000 - slippageBps) / 10_000)
           = floor(1_234 * 9_900 / 10_000)
           = 1_221`
- If `quoteVeOut > 0` but floor-rounding would produce `minVeOut == 0`, clamp to `1` before calling Furnace.

---

## Required tests (minimum)

These are the “invisible mechanics” tests that prevent rounding exploits and quote trust failures.

Bonus AMM:
- **Ceil vTarget:** cases where `(R * 10_000) % grossSpotBps != 0` MUST still enforce the cap (no 1-wei leak).
- **Cap inequality:** for all fuzzed inputs with `P_eff > 0`:
  - `grossBonus * 10_000 <= P_eff * grossSpotBps`
- **Preview/update parity:** `_previewVirtualDepth(grossSpotBonusBps)` MUST equal the value written by `_updateVirtualDepth(grossSpotBonusBps)` for the same timestamp and state.
- **Split resistance:** `bonus(P1) + bonus(P2) <= bonus(P1 + P2)` in the same timestamp (allow only explicit dust tolerance if needed).

Quotes:
- For each quote view used by the UI:
  - `quote == simulateExecution` for identical inputs and pre-state.
  - If any external quote is drift-prone (DEX pools), the tolerated drift MUST be explicitly documented and bounded.


## Extension bonus (`extendWithBonus`) requirements

- MUST reject AutoMax locks (`autoMax == true` → revert)
- MUST reject if new clamped duration `d <= oldRemaining` (revert `InvalidDuration`)
- MUST reject if lock is listed, expired, or not owned by `user`
- MUST compute `weightDelta = durationWeight(d) - durationWeight(oldRemaining)` from the
  sub-bp duration-weight curve (env-config §3.4D)
- MUST compute `principalEff = Math.mulDiv(lockAmount, weightDelta, WEIGHT_DENOM)` (floor)
- MUST use the same bonus AMM (`_applyBonusAmm`) as entry paths
- MUST extend lock duration via `ve.extendLockToFor` before adding bonus
- MUST apply the bonus payout floor (spec §7.3.4.1):
  - if `userBonus >= MIN_TOPUP_AMOUNT`: deliver via `ve.addToLockFor`
  - else if `userBonus > 0`: credit the dust to `furnaceReserve` and surface `bonusClaim = 0` (the AMM debit is preserved; bucketed solvency holds)
  - else (`userBonus == 0`): standard skip
- MUST enforce `minBonusOut` guard against the surfaced `bonusClaim` (revert `MinVeOutNotMet` if `bonusClaim < minBonusOut`)
- MUST sync reserve after (`_syncFurnaceReserve`)
- MUST emit `FurnaceEnter(user, MODE_EXTEND_WITH_BONUS=4, 0, 0, bonusClaim, tokenId)`
- Delegated variant (`extendWithBonusFor`) MUST require `P_VE_EXTEND_LOCK_FOR` permission

## AutoMax automatic bonus growth (`claimAutoMaxBonus`) requirements

- `claimAutoMaxBonusBatch(tokenIds[], maxLocks)` SHOULD receive `tokenIds` in strictly ascending sorted order (`tokenIds[i] > tokenIds[i-1]` for all `i > 0`). Non-ascending pairs are **silently skipped** (O(n) duplicate detection via ascending-order check; no revert).
- MUST silently skip non-AutoMax locks (`autoMax == false` → skip)
- MUST silently skip if lock is listed, expired, or has zero amount
- MUST initialize `lastAutoMaxBonusClaim[tokenId]` to `block.timestamp` on first call (return 0 bonus)
- MUST enforce 24h on-chain cooldown (`elapsed < 1 day` → return 0; no revert, accrual window preserved). Official keeper enforces a 7-day per-owner cooldown off-chain
- MUST clamp `elapsed` to `MAX_LOCK_DURATION` if it exceeds max
- MUST compute `pseudoOldRemaining = MAX_LOCK_DURATION - elapsed`
- MUST compute `weightDelta = durationWeight(MAX) - durationWeight(pseudoOldRemaining)`
  from the sub-bp duration-weight curve and pair it with `WEIGHT_DENOM` when computing
  `principalEff` (env-config §3.4D)
- MUST use the same bonus AMM as entry paths
- MUST apply the bonus payout floor (spec §7.3.4.1):
  - if `userBonus >= MIN_TOPUP_AMOUNT`: deliver via `ve.addToLockFor(lockOwner, tokenId, userBonus)`
  - else if `userBonus > 0`: return `0` before applying the AMM, preserve the accrual window, and leave reserve unchanged
  - else (`userBonus == 0`): standard skip
- MUST update `lastAutoMaxBonusClaim[tokenId] = block.timestamp` AFTER the AMM call, and ONLY if a delivered `bonusClaim >= MIN_TOPUP_AMOUNT` was paid (preserves accrual window when AMM pays nothing or would deliver only dust)
- MUST sync reserve after (`_syncFurnaceReserve`)
- MUST emit `AutoMaxBonusClaimed(lockOwner, tokenId, bonusClaim)` (dedicated event — NOT `FurnaceEnter`, to avoid activity-feed spam from keeper calls)
- MUST be permissionless (any caller, not just lock owner)

## Common failure modes

- Quote functions do not match execution (UI shows one outcome, tx produces another).
- Using floor rounding for `vTarget` (cap leak) or rounding up the bonus (overpay).
- Updating AMM timestamps/state on zero-effective entries (timestamp griefing).
- Registry allowlist checks missing (unsafe swaps or bricked routes).
- LP reward routing occurs when `lpRewardsVault` is unset (may brick deposits depending on implementation).
- Bonus quote is not split-resistant (deposit splitting increases total bonus).
- Not enforcing `minVeOut` consistently.

## Checklist: config freeze (`configFrozen` / `freezeConfig()`)

- `bool public configFrozen` — one-way flag, default `false`.
- `modifier whenNotFrozen()` — reverts `Errors.ConfigFrozen()` if `configFrozen == true`.
- Frozen setters (MUST have `whenNotFrozen`):
  - `setShareholderRoyalties(address)` — `onlyOwner whenNotFrozen`
  - `setMineCore(address)` — `onlyOwner whenNotFrozen`
  - `setMineMarket(address)` — `onlyOwner whenNotFrozen`
  - `setFurnaceQuoter(address)` — `onlyOwner whenNotFrozen`
  - `setLpRewardsVault(address)` — `onlyOwner whenNotFrozen nonReentrant`
- Emergency LP-vault recovery path (remains callable after freeze):
  - `requestEmergencyVaultRewire(address newVault)` — `onlyOwner`
  - `cancelEmergencyVaultRewire()` — `onlyOwner`
  - `executeEmergencyVaultRewire()` — `onlyOwner`
- `freezeConfig()` — `onlyOwner whenNotFrozen`:
  - MUST revert if `shareholderRoyalties == address(0)`
  - MUST revert if `mineCore == address(0)`
  - MUST revert if `mineMarket == address(0)`
  - MUST revert if `furnaceQuoter == address(0)`
  - MUST validate the canonical Market/Furnace/MineCore/ShareholderRoyalties/CLAIM/ve bundle before locking
  - MUST validate `guardian == mineCore` before locking
  - MUST validate `furnaceQuoter.furnace() == address(this)` and the required quoter math selectors
  - If `lpRewardsVault != address(0)`, MUST validate the vault's immutable CLAIM / ve / Furnace roots before locking
  - Sets `configFrozen = true`
  - Emits `Events.ConfigFrozen()`
- NOT frozen (remain `onlyOwner` after freeze):
  - `setEntryTokenRegistry`, `setDelegationHub`
  - `setGuardian` (always callable by owner or current guardian)
  - `setLockingPaused` (guardian-gated via MineCore forwarding)
