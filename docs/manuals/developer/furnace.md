# Furnace

The Furnace is the protocol's bonus engine and the only counterparty for lock creation and settlement. Every path into veCLAIM passes through the Furnace — whether a user locks CLAIM directly, compounds royalties, or routes LP rewards. It sits at the center of the [CLAIM stream](protocol-overview.md).

> **TL;DR:** Enter via `enterWithEth(...)`, `enterWithClaim(...)`, or `enterWithToken(...)`. The Furnace adds a reserve-backed bonus (up to 100% net, duration-weighted), locks principal + bonus as veCLAIM, and optionally tops up LP rewards. Sell back via `MarketRouter.sellLockToFurnace(tokenId, minClaimOut, deadline)` for liquid CLAIM. Quote views (`quoteEnterWith*`, `quoteSellLockToFurnace*`, `getFurnaceState`) live on the **FurnaceQuoter** contract — resolve via `Furnace.furnaceQuoter()`.

## Public API

| Function | Caller | Purpose |
|---|---|---|
| `enterWithEth(targetTokenId, durationSeconds, createAutoMax, minVeOut)` | user (payable) | Lock ETH-converted CLAIM into a new or existing lock. |
| `enterWithClaim(claimAmount, ...)` | user | Lock CLAIM directly. |
| `enterWithToken(tokenIn, amountIn, ...)` | user | Lock via swap from any allowlisted token. |
| `enterWith*For(user, ...)` | delegate | Bot-pays / user-receives variants gated by DelegationHub. |
| `enterWithClaimFor(user, ...)` | allowlisted | MarketRouter, MineCore (King auto-lock), `LpStakingVault7D`. |
| `lockEthReward(user, ethAmount, ...)` | `ShareholderRoyalties` only | Counterparty for Baron `mode=1` compound. |
| `extendWithBonus(tokenId, newDurationSeconds, minBonusOut)` | user | Extend a non-AutoMax lock and accrue bonus on the delta. |
| `mergeWithBonus(srcTokenId, dstTokenId, minBonusOut)` | user | Merge two locks; pays extension bonus on the duration delta. |
| `claimAutoMaxBonus(tokenId)` | anyone (cooldown) | Permissionless extension-bonus pull for AutoMax locks (24 h onchain cooldown). |
| `tick()` | anyone | Permissionless LP-stream / overflow-drip upkeep. |
| `furnaceQuoter()` | view | Resolve the `FurnaceQuoter` for off-chain quote views. |
| `getFurnaceState()` | view (via Quoter) | `(reserve, lockedSupply, userSpotBonusBps, lpTopupRateBps, …)`. |

Sell-side surfaces live on `MarketRouter`; see [MarketRouter](marketrouter.md). Operator-only setters and emergency rewires live under [Operator notes](#operator-notes) at the bottom of this page.

## Entry methods

All entry methods converge into the same internal flow:
- swap to CLAIM if needed
- compute bonus (gross, then split)
- lock principal + net user bonus into veCLAIM
- route the LP portion (if enabled)

External entry points (direct user):
- enterWithEth(targetTokenId, durationSeconds, createAutoMax, minVeOut)
- enterWithClaim(claimAmount, targetTokenId, durationSeconds, createAutoMax, minVeOut)
- enterWithToken(tokenIn, amountIn, targetTokenId, durationSeconds, createAutoMax, minVeOut)

Token-entry safety note:
- WETH stays on the built-in 1:1 unwrap path and does not use the ERC20 exact-receipt guard
- every other token entry path fail-closes unless the initial `transferFrom` into Furnace credits exactly `amountIn`
- fee-on-transfer, rebasing, and other balance-mutating ERC20s therefore revert before any swap executes
- `FurnaceQuoter.quoteEnterWithToken(...)` still quotes on the requested `amountIn`, so quote fidelity assumes standard ERC20 transfer semantics

Allowlisted entry (protocol-controlled callers):
- enterWithClaimFor(user, claimAmount, targetTokenId, durationSeconds, createAutoMax, minVeOut)
  - allowlisted callers: MarketRouter (`mineMarket`), MineCore (King auto-lock), LpStakingVault7D (`lpRewardsVault`)
  - if the caller is MarketRouter, Furnace also fail-closes unless `MarketRouter.royalties()` still matches the canonical `ShareholderRoyalties` root wired into Furnace
- lockEthReward(user, ethAmount, targetTokenId, durationSeconds, createAutoMax, minVeOut)
  - only ShareholderRoyalties can call this
  - `msg.value` must equal `ethAmount` exactly; the Furnace does not source `ethAmount` from idle ETH balance

Delegated entry (bot pays, user receives lock; session-gated via DelegationHub):
- enterWithEthFor(user, targetTokenId, durationSeconds, createAutoMax, minVeOut)
- enterWithClaimFromCallerFor(user, claimAmount, targetTokenId, durationSeconds, createAutoMax, minVeOut)
- enterWithTokenFromCallerFor(user, tokenIn, amountIn, targetTokenId, durationSeconds, createAutoMax, minVeOut)

## Lock destination selection

Destination rules (contract):
- targetTokenId == 0: create a new lock (recipient is msg.sender or explicit user for enterWithClaimFor). `createAutoMax` only applies on this path.
- targetTokenId != 0: add to an existing lock (must be owned by the recipient). Furnace preserves the destination lock's existing AutoMax mode and ignores `createAutoMax` for existing locks.

UI auto-selection (all "lock into ve" flows):

**Duration:** Default is **AutoMax** (365 days). Lowering the slider disables AutoMax; returning to 365d does not re-enable it (requires explicit toggle).

**Lock destination** is a clickable dropdown (not behind an Advanced panel). Shows the auto-selected lock or "New lock".

Selection logic:

- **AutoMax intent** (`wantsAutoMax == true`): pick the eligible AutoMax lock with the highest `tokenId`. If none exist, create new (`createAutoMax = true`) if lock-cap room remains; otherwise mark AutoMax unavailable and block submit.
- **Fixed-duration intent** (`wantsAutoMax == false`): pick the eligible fixed lock with highest `remainingSec` ≤ `targetSec`. Tie-break: highest `amountWei`, then highest `tokenId`. If none compatible, create new if room; otherwise block with reason.
- **No eligible locks**: create new (requires `MIN_LOCK_AMOUNT` CLAIM + spare lock-cap room).
- **Eligible** = owned, not listed, not expired (AutoMax locks never treated as expired while `autoMax == true`).

Duration rules for existing destinations:

- Non-AutoMax: `durationSeconds` is clamped to the lock's current remaining duration. Entry does not extend; use `Furnace.extendWithBonus` for that.
- Entry into an existing **non-AutoMax** lock reverts with `InvalidDuration` if the lock has less than 7 days (`MIN_LOCK_DURATION`) remaining. This prevents near-expiry bonus extraction.
- AutoMax: `durationSeconds` MUST equal `MAX_LOCK_DURATION` exactly; any other value reverts (`InvalidDuration`). Pre-fill 365d and disable the slider.

Manual override persists per-wallet until the selected lock becomes invalid, then falls back to Auto. The rules above are the complete v1.0.0 destination-selection algorithm.

Slippage guard:
- minVeOut is a minimum entry-attributable ve delta expected from the newly locked amount
- Entry into an existing lock does not change its duration, so `veOut` reflects only the newly locked amount at the lock's remaining duration
- Furnace reverts if the guarded `veOut` is below `minVeOut`

Implementation sharp edge:
- even pure CLAIM paths (`enterWithClaim`, `enterWithClaimFor`, and the corresponding FurnaceQuoter quote) still fail closed unless `EntryTokenRegistry` is set and its router/factory/wrappedNative/CLAIM config is populated
- this is an implementation precondition for config parity with the swap paths; it does **not** by itself require a token-specific allowlisted route or the canonical WETH→CLAIM hop unless the chosen path actually needs them

## Extension bonus (non-AutoMax locks)

Extending a lock's duration through the Furnace awards a bonus on the **existing** locked capital for the incremental duration commitment. No new capital is required — the bonus is funded entirely from the Furnace reserve using the same bonus AMM as entry.

Entry points:
- extendWithBonus(tokenId, durationSeconds, minBonusOut) -> bonusClaim
- extendWithBonusFor(user, tokenId, durationSeconds, minBonusOut) -> bonusClaim (delegated; requires `P_VE_EXTEND_LOCK_FOR`)

Rejects AutoMax locks — AutoMax locks receive bonuses automatically via `claimAutoMaxBonus` (see [AutoMax automatic bonus growth](#automax-automatic-bonus-growth)).

Math:

```text
oldRemaining = lockEnd - now
d            = clamp(durationSeconds, MIN_LOCK_DURATION, MAX_LOCK_DURATION)

# Sub-bp duration-weight curve (Step 3); see env-config §3.4D.
weightDelta  = durationWeight(d) - durationWeight(oldRemaining)
principalEff = mulDiv( lockAmount, weightDelta, WEIGHT_DENOM )   # WEIGHT_DENOM = BPS_DENOM * WEIGHT_PRECISION
bonus        = bonusAMM(principalEff)   # same CPMM as entry path (Step 5)
```

This is path-independent with respect to the duration weight curve: extending from 30d to 365d in one step yields the same `principalEff` as extending 30d → 180d → 365d in two steps. The AMM curve is concave, so splitting extensions gives slightly less total bonus — identical to the entry-side behavior. With deep virtual depth, the difference is negligible.

Execution flow:
1. Validate lock: not AutoMax, not listed, not expired, owned by user
2. Compute `weightDelta` and `principalEff`
3. Call `_applyBonusAmm(user, lockAmount, principalEff, d)` for `userBonus`
4. Extend lock: `ve.extendLockToFor(user, tokenId, newEnd)`
5. Apply the bonus payout floor (see [Bonus payout floor](#bonus-payout-floor)):
   - `userBonus >= MIN_TOPUP_AMOUNT` → `ve.addToLockFor(user, tokenId, userBonus)`
   - `0 < userBonus < MIN_TOPUP_AMOUNT` → credit dust to `furnaceReserve`, set surfaced `bonusClaim = 0`
6. Enforce `minBonusOut` guard against the surfaced `bonusClaim` (reverts `MinVeOutNotMet`)
7. Sync reserve, emit `FurnaceEnter(user, MODE_EXTEND_WITH_BONUS=4, 0, 0, bonusClaim, tokenId)`

Quote view:
- `quoteExtendWithBonus(user, tokenId, durationSeconds)` -> `(lockAmount, bonusClaim, newEndSec)`

## AutoMax automatic bonus growth

A key advantage of AutoMax locks is **automatic bonus growth**. Because AutoMax locks are perpetually at MAX_LOCK_DURATION, the protocol accrues extension bonuses on their behalf — no manual extensions, no gas costs for the user, no risk of forgetting. A permissionless function allows any caller (keeper/bot) to trigger accrual for any AutoMax lock:

- claimAutoMaxBonus(tokenId) -> bonusClaim
- claimAutoMaxBonusBatch(tokenIds[], maxLocks) -> totalBonus

State:
- `lastAutoMaxBonusClaim(tokenId)` — per-lock timestamp of the last `claimAutoMaxBonus` settlement (public mapping)

Rules:
- Only for AutoMax locks (reverts on non-AutoMax for single; batch silently skips ineligible locks)
- 24h minimum cooldown per lock (if elapsed < 1 day, single returns 0; batch skips)
- First call initializes the timestamp and returns 0 bonus (no retroactive accrual)
- If elapsed > MAX_LOCK_DURATION, elapsed is clamped to MAX_LOCK_DURATION
- Batch: processes up to `min(tokenIds.length, maxLocks, MAX_AUTOMAX_BONUS_BATCH)` locks per call (MAX_AUTOMAX_BONUS_BATCH = 200)

Math:

```text
elapsed            = now - lastAutoMaxBonusClaim[tokenId]
pseudoOldRemaining = MAX_LOCK_DURATION - elapsed

# Sub-bp duration-weight curve (Step 3); see env-config §3.4D.
weightDelta  = durationWeight(MAX_LOCK_DURATION) - durationWeight(pseudoOldRemaining)
principalEff = mulDiv( lockAmount, weightDelta, WEIGHT_DENOM )   # WEIGHT_DENOM = BPS_DENOM * WEIGHT_PRECISION
bonus        = bonusAMM(principalEff)
```

AutoMax lockers receive the same bonus a non-AutoMax locker would earn by extending from `(MAX - elapsed)` back to `MAX` every `elapsed` seconds — but without lifting a finger. This hands-free compounding is one of the strongest incentives for choosing AutoMax.

Execution flow:
1. Validate lock: must be AutoMax, not listed, not expired
2. Check `lastAutoMaxBonusClaim[tokenId]` — if 0, initialize and return 0
3. If `elapsed < 1 day`, return 0 (no revert)
4. Compute incremental weight and `principalEff`
5. Preview the AutoMax bonus; if the delivered bonus would be `0` because it is below `MIN_TOPUP_AMOUNT`, return `0` without spending reserve or advancing `lastAutoMaxBonusClaim`
6. Call `_applyBonusAmm(lockOwner, lockAmount, principalEff, MAX_LOCK_DURATION)`
7. Apply the bonus payout floor (see [Bonus payout floor](#bonus-payout-floor)):
   - `userBonus >= MIN_TOPUP_AMOUNT` → `ve.addToLockFor(lockOwner, tokenId, userBonus)`
   - `0 < userBonus < MIN_TOPUP_AMOUNT` → surfaced `bonusClaim = 0` (the step-5 preview short-circuits this branch under quote/execute parity)
8. Update `lastAutoMaxBonusClaim[tokenId] = now` only after a delivered user bonus is paid
9. Emit `AutoMaxBonusClaimed(lockOwner, tokenId, bonusClaim)` (dedicated event — does **not** appear in the activity feed)

Quote views (on FurnaceQuoter):
- `FurnaceQuoter.quoteAutoMaxBonus(tokenId)` -> `(lockAmount, bonusClaim)`
- `FurnaceQuoter.quoteAutoMaxBonusBatch(tokenIds[])` -> `(bonuses[], totalBonus)`

Keeper integration:
- Onchain eligibility: `lastAutoMaxBonusClaim[tokenId] == 0` or `now - lastAutoMaxBonusClaim[tokenId] >= 1 day` (24h onchain floor)
- Official keeper enforces a **7-day per-owner cooldown** off-chain and groups all of a user's eligible locks together (protocol max: 32 locks per user)
- Use `quoteAutoMaxBonusBatch(tokenIds)` to preview bonus amounts; skip locks below the minimum reward threshold (`KEEPER_AUTOMAX_BONUS_MIN_REWARD`, default **100 CLAIM**) to avoid wasting gas on small accruals
- Use `claimAutoMaxBonusBatch(tokenIds, maxLocks)` to process up to 200 locks per tx (ineligible locks are silently skipped, capped by `MAX_AUTOMAX_BONUS_BATCH`)
- Single-lock fallback: `claimAutoMaxBonus(tokenId)`
- Gas cost naturally bounds throughput

## Sell lock to Furnace (instant liquidity)

Furnace can buy a veCLAIM NFT lock back for liquid CLAIM.

Quote endpoints (on **FurnaceQuoter**, not Furnace — resolve address via `Furnace.furnaceQuoter()`):
- quoteSellLockToFurnace(user, tokenId) -> (lockAmount, claimOut, spreadBps, lpReward, reserveAdd)
- quoteSellLockToFurnaceFromInfo(lockAmount, lockEnd, autoMax) -> (claimOut, spreadBps, lpReward, reserveAdd)
- quoteSellLockToFurnaceBreakdown(user, tokenId) -> SellLockQuoteBreakdown
- quoteSellLockForExecution(lockAmount, lockEnd, autoMax) -> SellExecutionQuote (used internally by FurnaceGuardHelper for execution alignment)
  - Note: user-scoped sell quotes (`quoteSellLockToFurnace`, `quoteSellLockToFurnaceBreakdown`) revert while a lock is listed. Use `quoteSellLockToFurnaceFromInfo(lockAmount, lockEnd, autoMax)` for listed-lock settlement quoting (see MarketRouter listing settlement flow).

Execution endpoints (strict mode):
- MarketRouter.sellLockToFurnace(tokenId, minClaimOut, deadline) -> claimOut
- MarketRouter.sellListedLockToFurnace(tokenId, deadline) -> claimOut (listed settlement)
- Furnace.sellLockToFurnaceFromMarket(seller, tokenId, minClaimOut) -> claimOut (restricted to the canonical `mineMarket` bundle)

Mechanics (high level):
- The lock is burned and its underlying locked CLAIM becomes available to the Furnace.
- A dynamic spread is applied (convex vs `userSpotBonusBps`, adjusted by remaining lock time):
  - `claimOut` is paid to the seller.
  - `lpReward` is funded into the LP rewards stream.
  - `reserveAdd` is credited to `furnaceReserve`.

Daily LP sellback cap (volume-driven LP funding):
- Applies only when `lpRewardsVault != 0x0`.
- The sellback `lpReward` is clamped by a per-day cap:
  - `inflowPerDay = MineCore.getFurnaceEmissionRateAt(now) * 1 days`
  - `capInflow = floor(inflowPerDay * LP_SALE_REWARD_CAP_INFLOW_SHARE_BPS / 10_000)`
  - `capPerDay = (inflowPerDay == 0 || capInflow == 0) ? LP_SALE_REWARD_CAP_FIXED_CAP_PER_DAY : min(capInflow, LP_SALE_REWARD_CAP_FIXED_CAP_PER_DAY)`
  - `remaining = max(0, capPerDay - lpSaleFundedToday)`
  - `lpReward = min(lpRewardRaw, remaining)`
- Any cut not sent to LP (due to the cap) flows into `reserveAdd`.
- View helpers:
  - `getLpSaleRewardCapPerDay()`
  - `getLpSaleRewardFundedToday()`
  - `getLpSaleRewardCapRemaining()`

Accounting rule:
- MUST checkpoint `ShareholderRoyalties` for the seller before burning/transferring the NFT so the seller keeps the ETH earned up to the sell.

## MarketRouter integration

The Furnace exposes helper entry points that are **restricted to the canonically wired MarketRouter bundle** (`mineMarket`) for settlement:

- `sellLockToFurnaceFromMarket(address seller, uint256 tokenId, uint256 minClaimOut) -> claimOut`

Operational expectations:
- `sellLockToFurnaceFromMarket` expects MarketRouter to:
  - checkpoint the seller in ShareholderRoyalties,
  - clear any listing / ve listed flag,
  - move the veNFT into Furnace custody with `safeTransferFrom(...)`,
  - then call this function to burn and pay out.
- Both custody admission and settlement execution fail closed on bundle drift (see [Wiring safety model](protocol-overview.md#wiring-safety-model)). A raw `Furnace.mineMarket` pointer match is not sufficient.
- Furnace records the observed `safeTransferFrom(...)` sender during custody transfer and rejects any `seller` argument that does not match that observed owner.

User-facing entry points in MarketRouter (strict mode):

- `sellLockToFurnace(tokenId, minClaimOut, deadline)` — **Market sell (Sell now)**: immediate sellback with slippage-derived minimum payout + caller-supplied `deadline` (recommended UI defaults: **60s** in Sell now tab, **120s** in the Furnace hero Sell modal).
- **Limit sell (Market listing)** settlement:
  - Keeper-priority for `SETTLEMENT_KEEPER_GRACE_SECONDS` (30 min) after creation — only allowlisted keepers or the `MarketRouter` owner may settle.
  - After the grace window, settlement is permissionless when the live sell quote meets `minClaimOut` and the listing has not expired.
  - Strict-mode `MarketRouter` does not use ERC-721 approvals for settlement. `APPROVAL_REVOKED` is a reserved analytics code and is not emitted.


Semantics + UI labels (source of truth):

Sell side:
- `minClaimOut` is the user's **Minimum payout** (net CLAIM the seller is willing to receive).
- For **Sell now (Market sell)**:
  - UI shows **Estimated payout now** (live quote) + **Minimum payout** (`minClaimOut`)
  - the UI derives `minClaimOut` from slippage and passes a short `deadline` timestamp (`now + TTL`; the recommended defaults are **60s** in the Sell now tab and **120s** in the Furnace hero Sell modal). Onchain only enforces the timestamp the caller actually passes.
- For **Market listings (Limit sell)**:
  - listing intent is `listLock(tokenId, minClaimOut, expiresAtTime)`
  - expiry is enforced onchain (must be ≤ lock end)
  - recommended default expiry: **30d**
  - expired listings can be cleared permissionlessly via `cancelExpiredListing(tokenId)`

Buy side:
- **Buy now (Enter now / Market buy)**:
  - immediate Furnace entry (mints/tops up your veCLAIM lock; not a user-to-user purchase)
  - user picks `tokenIn` + `amountIn` and the lock config
  - UI shows **Estimated ve out now** (live quote; covers only the newly locked amount at the lock's remaining duration) + **Minimum ve out** (`minVeOut`, slippage-derived)
  - if `tokenIn != CLAIM` (swap path), swaps use an onchain deadline `block.timestamp + SWAP_DEADLINE_SECONDS` (currently 300s)
- **Limit buy (Buy intent)**:
  - implemented via bonus target escrows in MarketRouter (see MarketRouter docs)
  - escrow stores `budgetClaim`, `expiresAt`, `targetBonusBps`, `slippageBps`, and lock config
  - `executeAutoFurnace(offerId, deadline)` derives `minVeOut` and calls `Furnace.enterWithClaimFor(...)`

## Quote views (for setting minVeOut)

All quote views live on the **FurnaceQuoter** contract, not on Furnace itself. Resolve the address via `Furnace.furnaceQuoter()`:

- FurnaceQuoter.quoteEnterWithEth(user, ethIn, targetTokenId, durationSeconds, createAutoMax)
- FurnaceQuoter.quoteEnterWithClaim(user, claimIn, targetTokenId, durationSeconds, createAutoMax)
- FurnaceQuoter.quoteEnterWithToken(user, tokenIn, amountIn, targetTokenId, durationSeconds, createAutoMax)
- FurnaceQuoter.quoteExtendWithBonus(user, tokenId, durationSeconds) -> (lockAmount, bonusClaim, newEndSec)
- FurnaceQuoter.quoteAutoMaxBonus(tokenId) -> (lockAmount, bonusClaim)

Implementation detail (important):

- Owner sets the quoter via `setFurnaceQuoter(...)` (emits `FurnaceQuoterSet`). Callers resolve the address via `Furnace.furnaceQuoter()` and call it directly. If `furnaceQuoter` is unset on the Furnace, consumers (MarketRouter settlement, ShareholderRoyalties auto-compound) that resolve via `furnace.furnaceQuoter()` will get `address(0)` and revert.
- `quoteEnterWith*` and `quoteSellLockToFurnace*` revert while `lockingPaused == true`, matching execution behavior.
- `getFurnaceState()` stays readable while locking is paused.
- **Sharp edge:** even no-swap CLAIM paths (`enterWithClaim`, `enterWithClaimFor`, `quoteEnterWithClaim`) require live `EntryTokenRegistry` + router config. Treat broken registry wiring as fatal for CLAIM entry too, not just swap paths.

Each returns:
- principalClaim (post-swap principal)
- bonusClaim (net user bonus)
- veOut (entry-attributable ve delta for the newly locked amount at the lock's remaining duration)
- tokenIdUsed (4th return value; named `routeTokenId` in the ABI)
  - `0` = create a new lock
  - otherwise = route into an existing destination lock tokenId

Note: This `tokenIdUsed` is unrelated to EntryTokenRegistry `routeTokenId` (DIRECT_TO_CLAIM / VIA_WETH).

Client pattern:
- veOutQuote = quote...veOut
- minVeOut = floor( veOutQuote * (10,000 - slippageBps) / 10,000 )
- Note: `veOutQuote` covers only the newly locked amount at the lock's remaining duration.

Important (swap safety model):
- `minVeOut` is mandatory: Furnace reverts with `MinVeOutRequired` if `minVeOut == 0`.
- On swap paths (ETH/token entry):
  - DexAdapter swaps use `amountOutMin = 0` at the router level.
  - Slippage protection is enforced atomically downstream via the `minVeOut` check.
  - Swap deadline is protocol-set: `block.timestamp + SWAP_DEADLINE_SECONDS` (currently **300s**).

Also available on FurnaceQuoter:
- FurnaceQuoter.getFurnaceState() → (reserve, lockedSupply, userSpotBonusBps, lpTopupRateBps, quoteUserBonusBps, quoteLpTopupBps, virtualDepth, lastUpdate)

## Bonus model (single source of truth)

Bonus economics are pinned in `src/lib/Constants.sol` (section 3.4). Values are reproduced below to keep the derivation self-contained; the canonical list lives in [Constants Reference](appendix-constants-v100.md).

### Key constants (v1.0.0)

Basis points:
- BPS_DENOM = 10,000

User bonus cap and gross cap:
- MAX_USER_BONUS_BPS = 10,000 (100% net user cap)
- MAX_GROSS_BONUS_BPS = 12,500 (125% hard clamp, user + LP). With current LP top-up max (15%), max gross is 11,500 (115%).

LP top-up rate (a fraction of the user bonus):
- LP_TOPUP_RATE_MIN_BPS = 750 (7.5% of user bonus)
- LP_TOPUP_RATE_MAX_BPS = 1,500 (15% of user bonus)
- LP_TOPUP_GAMMA = 2 (convex curve; higher makes lpRate grow more slowly at low bonuses)

Note:
- Effective LP top-up rate is scaled down by a down-only LP scale derived from the same capped reserve factor used for `userSpotBps`.
  - `lpScaleBps = min(10_000, reserveFactorBps)` after the lock-% max-boost cap.
  - `lpRateBps = floor(lpRateBpsBase * lpScaleBps / 10_000)`.

Anchors:
- LOCK_PCT_TARGET_BPS = 700 (7.0% total lock; half-max point for base cap)
- LOCK_TARGET = 120,000,000 CLAIM (absolute-supply constant; primary base cap uses lock%)
- RESERVE_TARGET_FINAL = 20,000,000 CLAIM
- RESERVE_FACTOR_MAX_BPS = 20,000 (2.0x)

Time controls:
- SWING_TIME = 60 days (reserve control ramps in)
- BONUS_DECAY_WINDOW = 3 hours (bonus cool-off recovery)

### Step 1: user spot bonus cap (lock-% + reserve control)

Inputs:
- totalSupply = CLAIM.totalSupply()
- lockedSupply = ve.totalLockedClaim()
- lockedPctBps = clamp(floor(BPS_DENOM * lockedSupply / totalSupply), 0, BPS_DENOM)
- reserve R = furnaceReserve
- elapsed = timeSinceLaunch

Base cap (lock-% anchored):

```text
baseUserBps = floor( MAX_USER_BONUS_BPS * LOCK_PCT_TARGET_BPS / (LOCK_PCT_TARGET_BPS + lockedPctBps) )
```

Reserve fullness (clamped):

```text
reserveFullnessBps = clamp( floor( BPS_DENOM * R / RESERVE_TARGET_FINAL ), 0, RESERVE_FACTOR_MAX_BPS )
```

Ramp-in (0 at launch, 100% at SWING_TIME):

```text
swingAlphaBps = clamp( floor( BPS_DENOM * elapsed / SWING_TIME ), 0, BPS_DENOM )
```

Reserve factor (signed-floor semantics, implemented piecewise):

```text
if reserveFullnessBps >= BPS_DENOM:
  reserveFactorBps = BPS_DENOM + floor( swingAlphaBps * (reserveFullnessBps - BPS_DENOM) / BPS_DENOM )
else:
  reserveFactorBps = BPS_DENOM - ceil( swingAlphaBps * (BPS_DENOM - reserveFullnessBps) / BPS_DENOM )
```

Lock-% dependent max boost cap (prevents 100% headlines in low lock adoption regimes):

```text
if lockedPctBps <= LOCK_PCT_MIN_FOR_BOOST_CAP_BPS:
  maxReserveFactorBps = RESERVE_FACTOR_MAX_BPS_LOWLOCK
else if lockedPctBps >= LOCK_PCT_FULL_BOOST_CAP_BPS:
  maxReserveFactorBps = RESERVE_FACTOR_MAX_BPS
else:
  maxReserveFactorBps = RESERVE_FACTOR_MAX_BPS_LOWLOCK +
    floor((RESERVE_FACTOR_MAX_BPS - RESERVE_FACTOR_MAX_BPS_LOWLOCK) *
          (lockedPctBps - LOCK_PCT_MIN_FOR_BOOST_CAP_BPS) /
          (LOCK_PCT_FULL_BOOST_CAP_BPS - LOCK_PCT_MIN_FOR_BOOST_CAP_BPS))

reserveFactorBps = min(reserveFactorBps, maxReserveFactorBps)
```

Final user spot cap:

```text
userSpotBps = min( MAX_USER_BONUS_BPS, floor( baseUserBps * reserveFactorBps / BPS_DENOM ) )
```

Intuition:
- more lockedPctBps => lower userSpotBps
- low reserve => damp userSpotBps (after ramp-in)
- high reserve => boost userSpotBps (after ramp-in)

### Step 2: LP top-up rate (additive)

LP top-up is a split of the gross bonus, not a subtraction from the user.

LP top-up is enabled only when lpRewardsVault is set.

```text
if lpRewardsVault == 0x0:
  lpRateBpsBase = 0
  lpRateBps = 0
else:
  span = (LP_TOPUP_RATE_MAX_BPS - LP_TOPUP_RATE_MIN_BPS)
  γ = LP_TOPUP_GAMMA   # v1.0.0 pinned to 2
  lpRateBpsBase = LP_TOPUP_RATE_MIN_BPS
               + floor( span * (userSpotBps^γ) / (MAX_USER_BONUS_BPS^γ) )

  # reserveFactorBps here is the Step 1 runtime factor after the low-lock max-boost cap
  lpScaleBps = min( BPS_DENOM, reserveFactorBps )
  lpRateBps = floor( lpRateBpsBase * lpScaleBps / BPS_DENOM )

lpTopupSpotBps = floor( userSpotBps * lpRateBps / BPS_DENOM )

grossSpotBps = min( MAX_GROSS_BONUS_BPS, userSpotBps + lpTopupSpotBps )
```

### Step 3: duration weight

The Furnace scales bonus by a non-linear duration weight curve evaluated at sub-bp internal precision so `principalEff` tracks duration deltas at sub-second resolution.

Breakpoints (v1.0.0):

| Duration | wBps | w% |
|---:|---:|---:|
| 7 days | 100 | 1% |
| 14 days | 175 | 1.75% |
| 21 days | 300 | 3% |
| 30 days | 500 | 5% |
| 90 days | 1,500 | 15% |
| 180 days | 4,000 | 40% |
| 270 days | 6,500 | 65% |
| 365 days | 10,000 | 100% |

Footnote: the 7-day floor applies only when the lock actually has **≥ 7 days** remaining. Locks with **< 7 days** remaining are rejected as entry destinations.

Computation:
- clamp durationSeconds into [MIN_LOCK_DURATION, MAX_LOCK_DURATION]
- find the surrounding breakpoints (d0, w0) and (d1, w1)
- linear interpolate at sub-bp precision:
  - `weight = w0 * WEIGHT_PRECISION + mulDiv(durationSeconds - d0, (w1 - w0) * WEIGHT_PRECISION, d1 - d0)`
- the public bps view `durationWeightBps(durationSeconds)` returns `weight / WEIGHT_PRECISION` (integer floor) for dashboards and integrators

Effective principal:

```text
P_eff = mulDiv( P, weight, WEIGHT_DENOM )   # WEIGHT_DENOM = BPS_DENOM * WEIGHT_PRECISION
```

If P_eff == 0:
- gross bonus is 0
- AMM state does not change

### Step 4: virtual depth (bonus cool-off)

The bonus is priced using a constant-product-like AMM that uses:
- reserve R
- virtual depth V

Target virtual depth (cap enforcement):

```text
if grossSpotBps == 0 or R == 0:
  vTarget = 0
else:
  vTarget = ceil( R * BPS_DENOM / grossSpotBps )
```

Recovery / convergence:
- If V < vTarget (e.g. reserve decreased or spot cap changed): V snaps up to vTarget immediately (no gradual ramp)
- If V > vTarget (e.g. after a large entry): V decays linearly back toward vTarget over BONUS_DECAY_WINDOW (3 hours)
- If dt >= BONUS_DECAY_WINDOW since last update: V snaps to vTarget
- large entries increase V (via Step 5: V = V + P_eff) and reduce near-term quotes

### Step 5: gross bonus payout and split

Gross bonus (drawn from reserve):

```text
grossBonus = floor( R * P_eff / (V + P_eff) )
R = R - grossBonus
V = V + P_eff
```

Split gross bonus into user + LP:

```text
denom = BPS_DENOM + lpRateBps
userBonus = floor( grossBonus * BPS_DENOM / denom )
lpBonus   = grossBonus - userBonus   # remainder
```

Locking amount:
- Furnace locks (principal + userBonus) into veCLAIM.

LP routing:
- if lpRewardsVault == 0x0 then lpRateBps == 0 and lpBonus == 0
- if lpRewardsVault != 0x0 then lpBonus is funded into the Furnace LP rewards stream (then streamed to LpStakingVault7D over LP_STREAM_WINDOW; transfers happen on later accrual/tick calls)
- each LP stream re-fund emits `LpStreamFunded(amountFunded, newRatePerSec, newPeriodFinish)` so offchain systems can track the live schedule without replaying every reserve-affecting event

### Bonus payout floor

The user-bonus delivery step on `extendWithBonus[For]`,
`mergeLocksWithBonus[For]`, and `claimAutoMaxBonus[Batch]` calls
`VeClaimNFT.addToLockFor`, which enforces `amount >= MIN_TOPUP_AMOUNT`
(1 CLAIM; env-config §3.1B). When the user-bonus output of the AMM falls in
`(0, MIN_TOPUP_AMOUNT)`, user-initiated extend / merge calls credit the dust
to `furnaceReserve` and surface `bonusClaim = 0`. Permissionless AutoMax
claims preflight this case and return `0` without spending reserve or
advancing the user's claim cursor. The surviving lock receives no bonus on
that call.

The AMM debit (`reserveBefore - grossBonus`) has already been applied in
[spec §7.3.4](https://github.com/claimrush/claimrush/blob/main/docs/spec/spec-v1.0.0.md#734-gross-bonus-payout-and-split),
so the dust credit returns the user-side share to `furnaceReserve` whenever
the surviving lock cannot receive it. The bucketed solvency invariant
`ClaimToken.balanceOf(Furnace) >= furnaceReserve + lpStreamRemaining` holds
either way. The LP-side share (`lpRewardClaim`) is unaffected and continues
to fund the LP rewards stream per [spec §7.3.6](https://github.com/claimrush/claimrush/blob/main/docs/spec/spec-v1.0.0.md#736-lp-rewards-stream-14-day-smoothing).

Slippage-sensitive integrators MUST evaluate `minBonusOut` against the
surfaced `bonusClaim` so callers can opt in to revert via `MinVeOutNotMet`
rather than silently accepting a zero-payout extension.

## Reserve accounting

State:
- furnaceReserve R: CLAIM available to pay bonuses
- bonusVirtualDepth V: AMM depth used to quote and pay bonuses
- lastBonusUpdate: timestamp used for V recovery

Invariant:
- furnaceReserve is always bounded by the Furnace's onchain CLAIM holdings, excluding the LP stream liability:
  - `furnaceReserve <= claim.balanceOf(furnace) - lpStreamLiability`
  - where `lpStreamLiability = (finish - lastUpdate) * rate + lpStreamCarry`, which is strictly >= `getLpStreamRemaining()` whenever there are matured-but-unpaid tokens or non-zero carry dust.
  - if the invariant would be violated (e.g. MineCore over-credits reserve), the Furnace clamps reserve down and emits `ReserveClamped`

Reserve inflow:
- MineCore mints the Furnace emission stream to the Furnace
- MineCore calls Furnace.creditReserve(amount)

Operational dependency:
- MineCore intentionally fails closed on Furnace reserve accrual. During takeovers it mints the Furnace emission stream and then calls `Furnace.creditReserve(amount)`. If `creditReserve` reverts, the takeover reverts as well so the protocol never leaves untracked CLAIM sitting in the Furnace reserve bucket.
- Operators should monitor repeated takeover failures / `InvariantViolation()` during launch and keep a guardian pause procedure ready if Furnace reserve accounting becomes unhealthy.

Reserve outflow:
- gross bonus payouts (user bonus + LP top-up)
- optional LP overflow drip (protocol -> LP rewards stream)

### Weekly reserve cycle (settlement window)

When the keeper's weekly settlement window is enabled (see [maintenance-and-bots.md — Weekly Settlement Window](maintenance-and-bots.md#weekly-settlement-window)), reserve draws from auto-compound and AutoMax tasks are concentrated into a periodic cycle rather than spread across the week.

Reserve draw pattern:
- **Window open (immediate phase):** `compound-lp` and `automax-bonus` draw from `furnaceReserve` via `_applyBonusAmm` at window open. This creates a discrete trough in R.
- **Window spread (price-sensitive phase):** `compound-shareholders` batches draw from `furnaceReserve` via `lockEthReward` (ETH → swap → CLAIM → Furnace) over the 24-hour window. Each batch draws reserve for the bonus component.
- **Recovery:** `bonusVirtualDepth` V recovers on the `BONUS_DECAY_WINDOW` (3h) timescale after each draw event. This means V partially recovers between spread-phase batches.
- **Refill:** Between windows, the reserve refills continuously via the MineCore emission stream (`creditReserve`), sellback credits, and overflow drip.

Effect on bonus rates: during the settlement window, bonus rates may be lower than at other times because `furnaceReserve` is being drawn down. Between windows, the reserve refills and bonus rates recover. The existing tooltip ("Bonus is variable. It depends on overall lock level, Furnace reserve, and recent activity.") covers this behavior.

Cross-reference: [Weekly Settlement Window](maintenance-and-bots.md#weekly-settlement-window) for configuration and two-phase design.

## LP rewards stream (smoothing)

All Furnace-funded LP rewards are folded into a rolling stream with window `LP_STREAM_WINDOW = 14 days`:
- per-entry LP top-up split (`lpBonus` / `lpRewardClaim`)
- LP overflow drip
- sellback LP share

This is a *smoothing layer*:
- funding adds to the stream schedule
- accrual transfers `owed = dt * ratePerSec` to `lpRewardsVault` and then best-effort calls `notifyRewards(owed)`
  - if `notifyRewards` reverts, the Furnace emits `LpRewardsNotifyFailed(vault, owed, revertData)` and does not revert the upstream tx
  - in shipped v1.0.0, that `revertData` field is emitted as empty bytes for hardening; Furnace intentionally does not copy arbitrary LP-vault revert data
- stream schedule changes are observable directly via `LpStreamFunded(amountFunded, newRatePerSec, newPeriodFinish)`
  - the CLAIM transfer still succeeds, so the vault can reconcile via balance-delta when a later notify or fee harvest succeeds

## LP overflow drip (protocol -> LP rewards stream)

This is separate from the per-entry LP top-up split.

Enabled only when lpRewardsVault != 0x0.

Constants (v1.0.0):
- LP_OVERFLOW_DRIP_START = 18 months
- LP_OVERFLOW_DRIP_RAMP = 180 days
- LP_OVERFLOW_DRIP_INFLOW_SHARE_CAP_BPS = 1,000 (10%)
- LP_OVERFLOW_DRIP_FIXED_CAP_PER_DAY = 30,000 CLAIM/day
- LP_OVERFLOW_DRIP_GATE_K = 2,000,000 CLAIM

Daily drip (conceptual):
- excess = max(0, R - RESERVE_TARGET_FINAL)
- gate(t) = excess / (excess + K)
- alpha(t) ramps from 0 to 1 after LP_OVERFLOW_DRIP_START over LP_OVERFLOW_DRIP_RAMP
- drip(t) = min(capFixedPerDay, capInflowPerDay) * gate(t) * alpha(t)
- capInflowPerDay = inflowPerDay * INFLOW_SHARE_CAP

Implementation notes:
- The drip accrues on state-changing calls (entry bonus paths, sellback, creditReserve) and via `tick()`.
- Read helpers:
  - `getLpOverflowDripPerDay()`
  - `getLpStreamRemaining()`
  - `getLpStreamState()`
- Upkeep entrypoint:
  - `tick()` (permissionless; accrues the LP stream and optionally funds the overflow drip into that stream; returns the CLAIM amount streamed to `lpRewardsVault` in this call)
- There is no dedicated `getLpOverflowDripState()` getter in the shipped v1.0.0 ABI.

## LP rewards toggle ("when enabled")

Furnace has a single config switch:
- lpRewardsVault

Effects:
- enables LP top-up split (lpRateBps > 0)
- enables LP overflow drip accrual

Configuration:
- `setLpRewardsVault(address)` is `onlyOwner`
- `address(0)` disables LP split routing and future overflow-drip funding
- non-zero vaults must:
  - be a contract (`code.length > 0`)
  - report `furnace() == address(this)`, `claim()` == Furnace's CLAIM, and `ve()` == Furnace's VeClaimNFT (prevents miswiring)
- changing the vault address, including switching to `address(0)`, fails closed while already-earned LP liability remains attributable to the current vault (`LpRewardsStreamActive`)
  - that liability includes both the parked LP stream remainder and overflow-drip rewards already accrued for the current vault period but not yet checkpointed into the stream
- any successful vault change resets `lastLpOverflowDripUpdate` so a new vault period cannot inherit backlog from a prior or disabled period
- emits `LpRewardsVaultSet(oldVault, newVault)` on change

## Operator notes

The remaining sections cover deploy-time wiring, emergency-only recovery paths, and the bytecode-relief architecture. Integrators can skip this section unless instrumenting governance flows or troubleshooting a bundle-drift revert.

### Wiring setters and EOA-rejection rules

Every Furnace wiring setter that takes a contract address validates the candidate before storing it. Two rules are uniformly enforced; a third (reciprocal-binding) is enforced on the setters whose target exposes a canonical back-pointer.

| Setter | Zero-address | Bare EOA | Delegated EOA (EIP-7702) | Reciprocal binding required |
|---|---|---|---|---|
| `setMineCore(address core)` | `ZeroAddress` | `NotAContract` | `DelegatedEOA` | `core.furnace()` must be `0` (pre-wire) or equal to this Furnace |
| `setMineMarket(address market)` | `ZeroAddress` | `NotAContract` | `DelegatedEOA` | per-call canonical wiring is checked at every entry; setter does not enforce |
| `setShareholderRoyalties(address sr)` | `ZeroAddress` | `NotAContract` | `DelegatedEOA` | `sr.furnace()` must be `0` (pre-wire) or equal to this Furnace; `sr.ve()` must be `0` or equal to Furnace's VeClaimNFT |
| `setDelegationHub(address hub)` | `ZeroAddress` | `NotAContract` | `WiringMismatch` (implicit, via reciprocal binding — see note) | `MineCore.furnace() == this`, `MineCore.delegationHub() == hub`, `MineCore.claim() == claim`, `MineCore.ve() == ve` |
| `setLpRewardsVault(address vault)` | allowed (disables) | `NotAContract` (when non-zero) | `DelegatedEOA` (when non-zero) | `vault.furnace() == this`, `vault.claim() == claim`, `vault.ve() == ve` |
| `setEntryTokenRegistry(address reg)` | `ZeroAddress` | `NotAContract` | `DelegatedEOA` | `reg != MineCore.entryTokenRegistry()` (registries must be distinct) |
| `setFurnaceQuoter(address q)` | `ZeroAddress` | `NotAContract` | `DelegatedEOA` | `q.furnace() == this`. Setter additionally probes `q.userSpotBonusBps(...)` and `q.lpScaleBps(...)` (must not revert). The quoter's `claim()` and `ve()` back-pointers are bound at the quoter's own deploy time — they are **not** re-validated at setter time, so deploy/wire scripts must verify them out-of-band. |

Notes:

- **Bare EOA vs delegated EOA.** Solidity's `code.length == 0` check rejects bare externally-owned accounts but is satisfied by an EIP-7702 designator account whose runtime is exactly 23 bytes starting with `0xEF 0x01 0x00`. Most Furnace setters call `FurnaceGuardHelper._rejectDelegatedEOA(addr)`, which inspects the runtime bytecode and reverts with the typed `Errors.DelegatedEOA()` selector if the candidate is a 7702 designator. The `code.length == 0` check still runs first and reverts with `Errors.NotAContract()` for true EOAs, so the two reverts are distinguishable off-chain.
- **`setDelegationHub` rejects delegated EOAs implicitly.** The setter does not call `_rejectDelegatedEOA` directly because the reciprocal-binding check via `requireCanonicalDelegationHub` already requires `MineCore.delegationHub() == hub`. A 7702 designator address cannot be reciprocally wired into a canonical MineCore (since `MineCore.setDelegationHub` itself rejects EIP-7702 designators), so any 7702 candidate fails the wiring check with `Errors.WiringMismatch()` rather than `Errors.DelegatedEOA()`.
- **Pre-wire convention.** During first-time deployment, the target's reciprocal `furnace()` getter typically returns `0` because the Furnace address has not yet been written. The setters accept `0` as "not yet wired" and reject any non-zero mismatch. After the deploy script completes, every reciprocal getter must point at the canonical Furnace; freezing then locks that bundle.
- **`setDelegationHub` is post-freeze configurable.** The setter is `onlyOwner` (no `whenNotFrozen`) so a broken or compromised DelegationHub can be replaced after the canonical freeze. The reciprocal-binding check ensures any replacement must already be wired into MineCore alongside the canonical `claim` / `ve` / `furnace` roots; drift is therefore not settable through the legitimate path. The defense-in-depth runtime check at every Furnace delegated-entry site continues to reject drift even when storage is mutated out-of-band (e.g. via a rogue proxy upgrade).

### Emergency LP-vault rewire (delayed recovery)

If the canonically wired `lpRewardsVault` is ever broken (custody bug, runaway accrual, governance lock-out), Furnace exposes a delayed recovery path that bypasses the LP-stream-active guard on `setLpRewardsVault`. Three external entry points form the lifecycle:

| Function | Caller | Effect |
|---|---|---|
| `requestEmergencyVaultRewire(address newVault)` | `onlyOwner` | Stages `newVault` and arms an executor cooldown of `EMERGENCY_VAULT_REWIRE_DELAY` (**7 days**). Emits `EmergencyVaultRewireRequested(address indexed vault, uint256 liability, uint256 executeAfter)` (`liability` is the LP-stream liability snapshotted at request time). Cancels and re-arms if a request is already pending. |
| `cancelEmergencyVaultRewire()` | `onlyOwner` | Clears any pending request. Emits `EmergencyVaultRewireCancelled()` (no params). The `guardian` role cannot cancel. |
| `executeEmergencyVaultRewire()` | `onlyOwner` | After the 7-day delay elapses, atomically clears stream rate / finish / carry / overflow-drip state and writes the new vault. Emits `EmergencyVaultRewireExecuted(address indexed oldVault, uint256 strandedAmount)` (the new vault address is the staged `targetVault` from the prior request — read it from the matching `EmergencyVaultRewireRequested.vault` topic). |

Notes for integrators:

- The lifecycle is the **only** Furnace path that can rewire `lpRewardsVault` while LP liability remains attributable to the current vault. The 7-day delay gives operators time to cancel via the guardian if the request was made in error.
- All three external selectors and event topic0s are ABI-stable. Internally, Furnace forwards `msg.data` via inline-assembly `delegatecall` to `FurnaceGuardHelper`, which executes the storage writes in Furnace's storage context. The `delegatecall` gate is `address(this) == _furnace` on the helper; direct EOA / external calls into the helper revert with `NotAuthorized`. End users and indexers see no behavioral difference.
- The delayed path remains owner-callable after `freezeConfig()`; it is a documented exception to the "frozen setters" rule.
- `rescuePendingSellNFT(uint256 tokenId)` (owner-only) is an analogous narrow recovery path for stuck Furnace-custodied sellback NFTs. It also runs via `delegatecall` to `FurnaceGuardHelper`, clearing the `pendingSellSeller` and `lastAutoMaxBonusClaim` mapping slots and burning the lock back to the original seller.

### Delegatecall event emission (EIP-170 relief)

Several Furnace events — `BonusPaid`, `LpOverflowDripPaid`, `LockSoldToFurnace`, and `FurnaceMergeWithBonus` — are emitted from the Furnace address via `delegatecall` into `FurnaceGuardHelper`. This keeps Furnace runtime bytecode under the EIP-170 limit while preserving the Furnace address as the log emitter (delegatecall runs in the caller's context). The events are declared in `IFurnace` (or `Events.sol`) so they appear in Furnace's compiled ABI; off-chain tooling does not need to merge the `FurnaceGuardHelper` ABI to decode them.

### FurnaceGuardHelper

`FurnaceGuardHelper` is a companion contract deployed **before** `Furnace` and passed in via the 4-arg `new Furnace(claim, ve, helper, owner)` constructor (EIP-170 + EIP-3860 bytecode relief — inlining the helper deploy in `Furnace`'s constructor pushed initcode over the EIP-3860 49,152-byte ceiling). It holds externalized guard checks, math helpers, swap execution, the merge-with-bonus body, and delegatecall-only event emitters that run in Furnace's storage context.

#### Deployment and immutables

- Helper constructor binds the canonical `(claim, ve)` roots into `_claim` / `_ve` immutables and snapshots `_self = address(this)` (used to detect when the helper is called via delegatecall from a hosting contract).
- `_isCanonicalFurnace(address)` cross-checks any caller / `address(this)` by staticcalling `claim()` and `ve()` against the immutable roots, so a proxy upgrade of `Furnace` cannot redirect the helper at a foreign root pair.
- Helper-side guards: `_requireFurnaceOrSelf()` (callable from the canonical Furnace or from the helper's own address), `_requireDelegatecallCanonicalFurnace()` (must be invoked via `delegatecall` and the executing storage owner must satisfy `_isCanonicalFurnace`).
- Furnace stores the helper address in `address payable internal immutable _guardHelper` (no setter, even owner-callable; the helper is permanent for the lifetime of a given Furnace runtime).

#### Key helper functions (called by Furnace)

| Function | Type | Purpose |
|----------|------|---------|
| `resolveEntryDurationAndWeight(ve, user, targetTokenId, durationSeconds, createAutoMax)` | view | Resolve effective lock duration and duration-weight for a Furnace entry (new or existing lock) |
| `resolveExistingLockDestination(ve, user, targetTokenId, amountLocked, durationSeconds)` | view | Validate and resolve destination lock for add-to-lock entries |
| `validateNewLock(amountLocked, durationSeconds, createAutoMax)` | pure | Validate new lock params and compute veOut |
| `clampAndDurationWeightBps(durationSeconds)` | pure | Clamp duration to [MIN, MAX] and return piecewise duration-weight curve value |
| `normalizeSellExecutionQuote(quoter, lockAmount, lockEnd, autoMax, minClaimOut, ...)` | view | Validate and normalize a sell-to-Furnace execution quote (slippage, invariant, LP reward cap) |
| `computeBonusAmmRates(...)` / `computeBonusAmmPayout(...)` | pure | AMM-style bonus math: LP rate, gross spot bps, virtual depth, payout split |
| `splitBonusAmm(grossBonus, lpRateBps)` | pure | Split gross bonus into user + LP portions |
| `previewSellImpactVolume(currentVolume, lastUpdate, nowTs)` | pure | Decay-weighted sell impact volume preview |
| `computeAccruedSellImpactVolume(currentVol, lastUpdate, addAmount)` | view | Compute accrued sell impact after a sellback |
| `previewOverflowDrip(core, deploymentTime, reserve)` | view | Preview LP overflow drip parameters (alpha, gate, cap, per-day) |
| `computeStreamSchedule(amount, currentFinish, currentRate, carry, nowTs)` | pure | Recompute LP stream rate/finish/carry after funding |

#### Delegatecall-only functions (run in Furnace context)

| Function | Purpose |
|----------|---------|
| `createLockDelegated(claim, ve, user, amount, duration, autoMax)` | Approve + create lock via VeClaimNFT on behalf of Furnace |
| `addToLockDelegated(claim, ve, user, tokenId, amount)` | Approve + add-to-lock via VeClaimNFT on behalf of Furnace |
| `emitBonusPaid(frame, reserveAfter, virtualDepthAfter)` | Emit `BonusPaid` event (15 data words) from the Furnace address |
| `emitLockSoldToFurnace(...)` | Emit `LockSoldToFurnace` event from the Furnace address |
| `emitLpOverflowDripPaid(...)` | Emit `LpOverflowDripPaid` event from the Furnace address |
| `receiveTokenBalanceDelta(tokenIn, from, amountIn)` | Balance-delta `transferFrom` for token entries |
| `requestEmergencyVaultRewire(address newVault)` | Body of Furnace's emergency rewire request — stages `newVault` and arms the 7-day executor cooldown. Furnace's external shim forwards `msg.data` here. |
| `cancelEmergencyVaultRewire()` | Body of Furnace's emergency rewire cancel — clears pending request slots. |
| `executeEmergencyVaultRewire()` | Body of Furnace's emergency rewire execute — clears LP-stream and overflow-drip state then writes the new vault. |
| `rescuePendingSellNFT(uint256 tokenId)` | Body of Furnace's stuck-NFT rescue — clears `pendingSellSeller[tokenId]` + `lastAutoMaxBonusClaim[tokenId]`, then burns the lock back to the original seller. |
| `mergeLocksWithBonus(fromTokenId, intoTokenId, minBonusOut)` | Body of Furnace's merge-with-bonus — pre-validates ownership / listing / expiry, computes the extension-style bonus on the duration delta, deposits bonus + merged principal into the surviving lock, then defers to `VeClaimNFT.mergeLocksFor`. Mixed AutoMax pairs are accepted; survivor's `autoMax` is `from.autoMax \|\| into.autoMax`. Calls back into `Furnace.__bonusAmmFromHelper` to apply the AMM split inside Furnace's own `nonReentrant` lock. Emits `Events.FurnaceMergeWithBonus`. |
| `mergeLocksWithBonusFor(user, fromTokenId, intoTokenId, minBonusOut)` | Same body as `mergeLocksWithBonus`, plus `DelegationHub.consume(user, msg.sender, P_VE_MERGE_LOCKS_FOR, ...)` so a delegate can run the merge on `user`'s behalf. Bonus + merged principal stay with `user`. Emits `Events.FurnaceMergeWithBonus` and `DelegationSessionUsed`. |

The four emergency / rescue functions are externally exposed by `Furnace` itself — the `Furnace`-side shim is a single inline-assembly trampoline (`_delegateMsgDataToHelper`) that forwards `msg.data` unchanged via `delegatecall` to `FurnaceGuardHelper` and bubbles the original typed-error selectors and return data on revert. External callers, event consumers, and integrators see only `Furnace`'s ABI surface. The split exists purely to keep `Furnace` under the EIP-170 24,576-byte ceiling.

The two merge externals use a parallel pattern (`_delegateMergeToHelper`): a `nonReentrant whenLockingEnabled` shim on Furnace forwards `msg.data` via `delegatecall` to the helper's selector-matched body and decodes the returned `uint256 bonusClaim` from the free-memory pointer. The helper re-enters Furnace via a regular `CALL` to the auth-gated `__bonusAmmFromHelper(...)` to apply the bonus AMM split inside Furnace's own `nonReentrant` lock. `__bonusAmmFromHelper` itself only checks `msg.sender == address(this)`; it intentionally omits its own `nonReentrant` because the wrapping merge external still owns the lock.

#### Swap execution

| Function | Purpose |
|----------|---------|
| `executeSwapEthToClaim(registry, router, factory, weth, claimToken, recipient)` | ETH → CLAIM via DexAdapter (deadline: `block.timestamp + SWAP_DEADLINE_SECONDS`) |
| `executeSwapTokenToClaim(registry, tokenIn, amountIn, router, factory, weth, claimToken, recipient)` | ERC-20 → CLAIM via DexAdapter (unwraps WETH to ETH path if tokenIn == weth) |
| `buildAndValidateSwapRoutes(reg, tokenIn, router, factory, weth, claimToken)` | Build and validate DEX routes from EntryTokenRegistry |

#### Wiring and validation checks

Cross-contract wiring integrity checks used by Furnace during entry, sellback, and configuration flows:

- **Per-call canonical gates** — `requireCanonicalMineMarket`, `requireCanonicalMineMarketEntryCaller`, `requireOnlyShareholderRoyalties`, `validateSellLockReceive`, `validateReceiveEth`.
- **Setter-time canonical gates** — `requireCanonicalDelegationHub` (reciprocal `MineCore.{furnace,delegationHub,claim,ve}` binding for `Furnace.setDelegationHub`), `validateMineCoreSetter` (reciprocal `core.furnace()` binding + EIP-7702 reject for `Furnace.setMineCore`), `validateMineMarketSetter` (EIP-7702 reject for `Furnace.setMineMarket`), `validateShareholderRoyaltiesSetter` (reciprocal `sr.{furnace,ve}` binding + EIP-7702 reject for `Furnace.setShareholderRoyalties`), `requireLpRewardsVaultCompatible`, `requireFurnaceQuoterCompatible`, `validateDistinctEntryTokenRegistry`, `getValidatedRouterConfig`.
- **Helper-internal primitive** — `_rejectDelegatedEOA(addr)` inspects the address's runtime bytecode and reverts with `Errors.DelegatedEOA()` if it is a 23-byte EIP-7702 designator (`0xEF 0x01 0x00 || delegate20`). The check is precise: a 23-byte runtime that does **not** start with the magic prefix is allowed through (covers minimal-proxy patterns and similar). Bare EOAs are rejected earlier with `Errors.NotAContract()`.

#### Sell-impact tracking

The Furnace tracks cumulative sell volume via `sellImpactVolume` / `lastSellImpactUpdate` state variables. When a Furnace entry settles within 200 bps (2.00%) of the user-supplied `minVeOut`, `NearSlippageLimitEntry(user, tokenIdUsed, minVeOut, actualVeOut, marginBps)` is emitted as a transparency signal — both `user` and `tokenIdUsed` are indexed so MEV / keeper observability tooling can filter per-user or per-lock without scanning every entry. The sell impact decays linearly over `BONUS_DECAY_WINDOW`. FurnaceGuardHelper provides `previewSellImpactVolume` and `computeAccruedSellImpactVolume` for off-chain previews.

## See also

- [Locks (veCLAIM)](locks-veclaim.md) — lock lifecycle, ve decay, and AutoMax
- [Market (MarketRouter)](marketrouter.md) — listings, escrows, and Furnace settlement
- [ShareholderRoyalties (Barons)](shareholderroyalties-barons.md) — ETH royalty distribution
- [Core Mechanics](core-mechanics.md) — takeover loop and emission schedule
- Tutorial: [Integrate Furnace quotes + enter](tutorials/integrate-furnace-quotes-and-enter.md)
- User manual: [The Furnace](https://docs.claimru.sh/furnace)
