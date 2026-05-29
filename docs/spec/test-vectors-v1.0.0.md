# docs/spec/test-vectors-v1.0.0.md

This file provides **worked examples** ("test vectors") based on the v1.0.0 spec and constants.

Purpose:
- Make implementation and review faster by providing expected outputs for common calculations.
- Reduce ambiguity around rounding (floor vs ceil) and bps math.

Source of truth:
- `src/lib/Constants.sol`
- [Math and rounding appendix](../architecture/math-and-rounding-appendix-v1.0.0.md)

Conventions:
- bps denom is `10_000`.
- When the spec requires rounding down (floor), the examples reflect floor.
- Token units are simplified for readability unless otherwise noted.

---

## 1) Furnace duration weight (`wBps`)

From constants doc §3.4D (breakpoints):
- (7d, 100)
- (14d, 175)
- (21 days, 300)
- (30d, 500)
- (90d, 1_500)
- (180d, 4_000)
- (270d, 6_500)
- (365d, 10_000)

### Vector 1.1: exact breakpoint (min duration)
Input:
- `durationSeconds = 7 days`

Expected:
- `wBps = 100` (1%)

### Vector 1.2: exact breakpoint (low-end smoothing)
Input:
- `durationSeconds = 14 days`

Expected:
- `wBps = 175` (1.75%)

### Vector 1.3: exact breakpoint
Input:
- `durationSeconds = 90 days`

Expected:
- `wBps = 1_500` (15%)

### Vector 1.4: interpolation inside a segment
Input:
- `durationSeconds = 60 days` (between 30d and 90d)

Compute:
- Segment: (30d, 500) → (90d, 1_500)
- Progress: `(60 - 30) / (90 - 30) = 30 / 60 = 0.5`
- `wBps = 500 + (1_500 - 500) * 0.5 = 500 + 500 = 1_000`

Expected:
- `wBps = 1_000` (10%)

---

## 2) User spot cap (`userSpotBps`) – lock-% anchor

From constants doc §3.4:

- `MAX_USER_BONUS_BPS = 10_000`.
- Define lock-% (bps):
  - `lockedPctBps = clamp(floor(10_000 * lockedSupply / totalSupply), 0, 10_000)`.
- Base cap:
  - `baseUserBps = floor(MAX_USER_BONUS_BPS * LOCK_PCT_TARGET_BPS / (LOCK_PCT_TARGET_BPS + lockedPctBps))`.
- Reserve multiplier + time ramp:
  - `reserveFullnessBps = clamp(floor(10_000 * R / RESERVE_TARGET_FINAL), 0, RESERVE_FACTOR_MAX_BPS)`.
  - `swingAlphaBps = clamp(floor(10_000 * elapsed / SWING_TIME), 0, 10_000)`.
  - `reserveFactorBps = 10_000 + floor(swingAlphaBps * (reserveFullnessBps - 10_000) / 10_000)` (piecewise; use a **ceiling** adjustment on the down-branch when `reserveFullnessBps < 10_000`).
  - `userSpotBps = min(MAX_USER_BONUS_BPS, floor(baseUserBps * reserveFactorBps / 10_000))`.

For these vectors we pick conditions where `reserveFactorBps = 10_000` (no reserve effect), so `userSpotBps = baseUserBps`.

The vectors also pick `totalSupply = 10_000` for clean bps arithmetic.

### Vector 2.1: 0% locked
Assume:
- `totalSupply = 10_000`
- `lockedSupply = 0` → `lockedPctBps = 0`
- `reserveFactorBps = 10_000`

Compute:
- `baseUserBps = floor(10_000 * LOCK_PCT_TARGET_BPS / (LOCK_PCT_TARGET_BPS + 0)) = 10_000`
- `userSpotBps = 10_000`

Expected:
- `userSpotBps = 10_000` (100%)

### Vector 2.2: lockedPct equals LOCK_PCT_TARGET_BPS (half-max point)
Assume:
- `totalSupply = 10_000`
- `lockedSupply = LOCK_PCT_TARGET_BPS` → `lockedPctBps = LOCK_PCT_TARGET_BPS`
- `reserveFactorBps = 10_000`

Compute:
- `baseUserBps = floor(10_000 * LOCK_PCT_TARGET_BPS / (LOCK_PCT_TARGET_BPS + LOCK_PCT_TARGET_BPS)) = 5_000`
- `userSpotBps = 5_000`

Expected:
- `userSpotBps = 5_000` (50%)

### Vector 2.3: lockedPct equals 4× LOCK_PCT_TARGET_BPS
Assume:
- `totalSupply = 10_000`
- `lockedSupply = 4 * LOCK_PCT_TARGET_BPS` → `lockedPctBps = 4 * LOCK_PCT_TARGET_BPS`
- `reserveFactorBps = 10_000`

Compute:
- `baseUserBps = floor(10_000 * LOCK_PCT_TARGET_BPS / (LOCK_PCT_TARGET_BPS + 4 * LOCK_PCT_TARGET_BPS)) = floor(10_000 * 1/5) = 2_000`
- `userSpotBps = 2_000`

Expected:
- `userSpotBps = 2_000` (20%)

---

## 3) LP top-up (`lpRateBps`, `lpTopupSpotBps`, `grossSpotBps`)

From constants doc (§3.4):

- `LP_TOPUP_RATE_MIN_BPS = 750`
- `LP_TOPUP_RATE_MAX_BPS = 1_500`
- `LP_TOPUP_GAMMA = 2`
- `MAX_USER_BONUS_BPS = 10_000`

Formulas (base curve; reserve scaling omitted here, assume `lpScaleBps = 10_000`):

- `lpRateBps = LP_TOPUP_RATE_MIN_BPS + floor((LP_TOPUP_RATE_MAX_BPS - LP_TOPUP_RATE_MIN_BPS) * (userSpotBps^LP_TOPUP_GAMMA) / (MAX_USER_BONUS_BPS^LP_TOPUP_GAMMA))`
- `lpTopupSpotBps = floor(userSpotBps * lpRateBps / 10_000)`
- `grossSpotBps = userSpotBps + lpTopupSpotBps`

Note:
- In production, the **effective** LP top-up rate is additionally scaled down by reserve factor (down-only):
  - `lpRateBpsEffective = floor(lpRateBps * lpScaleBps / 10_000)` where `lpScaleBps ∈ [0..10_000]`.

### Vector 3.1: medium user cap (50%)

Assume:
- `userSpotBps = 5_000`

Compute:
- `span = 1_500 - 750 = 750`
- `numerator = 5_000^2 = 25_000_000`
- `denom = 10_000^2 = 100_000_000`
- `lpRateDelta = floor(750 * 25_000_000 / 100_000_000) = floor(187.5) = 187`
- `lpRateBps = 750 + 187 = 937`
- `lpTopupSpotBps = floor(5_000 * 937 / 10_000) = 468`
- `grossSpotBps = 5_000 + 468 = 5_468`

Expected:
- `lpRateBps = 937` (9.37% of user bonus)
- `lpTopupSpotBps = 468`
- `grossSpotBps = 5_468`

### Vector 3.2: maxed user cap (100%)

Assume:
- `userSpotBps = 10_000`

Compute:
- `span = 1_500 - 750 = 750`
- `numerator = 10_000^2 = 100_000_000`
- `denom = 10_000^2 = 100_000_000`
- `lpRateDelta = floor(750 * 100_000_000 / 100_000_000) = 750`
- `lpRateBps = 750 + 750 = 1_500`
- `lpTopupSpotBps = floor(10_000 * 1_500 / 10_000) = 1_500`
- `grossSpotBps = 10_000 + 1_500 = 11_500`

Expected:
- `lpRateBps = 1_500` (15% of user bonus)
- `lpTopupSpotBps = 1_500`
- `grossSpotBps = 11_500`

## 4) Takeover price decay

From constants doc (locked):
- `TAKEOVER_DECAY_PERIOD = 1 hour`
- `TAKEOVER_PRICE_FLOOR = 0.001 ether`
- For `0 <= t <= 1 hour`: `price = max(floor, referencePrice * (1 - t / decayPeriod))`
- Decay is toward 0, clamped at floor (not toward floor directly)

### Vector 4.1: half-way through decay window (high referencePrice)
Assume:
- `referencePrice = 0.01 ether`
- `t = 30 minutes`
- `floor = 0.001 ether`

Compute:
- Decayed = `referencePrice * t / decayPeriod = 0.01 * 0.5 = 0.005`
- Price = `referencePrice - decayed = 0.01 - 0.005 = 0.005 ether`
- Price > floor, so no clamping

Expected:
- `takeoverPrice = 0.005 ether`

### Vector 4.2: low referencePrice hits floor before 60 min
Assume:
- `referencePrice = 0.002 ether`
- `t = 30 minutes`
- `floor = 0.001 ether`

Compute:
- Decayed = `referencePrice * t / decayPeriod = 0.002 * 0.5 = 0.001`
- Price = `referencePrice - decayed = 0.002 - 0.001 = 0.001 ether`
- Price == floor

Expected:
- `takeoverPrice = 0.001 ether` (hits floor at exactly 30 min)

### Vector 4.3: low referencePrice past floor time
Assume:
- `referencePrice = 0.002 ether`
- `t = 45 minutes`
- `floor = 0.001 ether`

Compute:
- Decayed = `referencePrice * t / decayPeriod = 0.002 * 0.75 = 0.0015`
- Price = `referencePrice - decayed = 0.002 - 0.0015 = 0.0005 ether`
- Price < floor, clamp to floor

Expected:
- `takeoverPrice = 0.001 ether` (clamped at floor)

---

## 5) Furnace AMM bonus math (gross bonus)

From constants doc §3.4 (AMM-style):
- `grossBonus = R * P_eff / (V + P_eff)` (floor)

### Vector 5.1: whole-number example
Assume:
- Reserve `R = 1_000 CLAIM`
- Virtual depth `V = 2_000`
- Principal `P = 500`
- Duration weight `wBps = 4_000` (40%)
- `P_eff = floor(P * wBps / 10_000) = floor(500 * 4_000 / 10_000) = 200`

Compute:
- `grossBonus = floor(1_000 * 200 / (2_000 + 200))`
- `grossBonus = floor(200_000 / 2_200) = floor(90.909...) = 90`

Expected:
- `grossBonus = 90 CLAIM`

Clarification (non-binding):
- `grossBonus` is drawn from reserve. Split uses `lpRateBps` via `denom = 10_000 + lpRateBps`:
  - `userBonus = floor(grossBonus * 10_000 / denom)`
  - `lpReward = grossBonus - userBonus`
- Reserve decrements by `grossBonus` (gross), not by the net user bonus.
---

## 6) ShareholderRoyalties ETH index math

Source of truth:
- `docs/spec/spec-v1.0.0.md` §6.3 (Flush) and §6.4 (User checkpoint)
- `src/lib/Constants.sol` (MIN_VE_FLUSH)
- [Math and rounding appendix](../architecture/math-and-rounding-appendix-v1.0.0.md) (mulDivDown = floor)

Key rules:
- `totalWeight = totalVeBiasScaled = veTotal * 1e18` (processed total ve-bias, units `ve * 1e18`)
- `delta = mulDivDown(pendingShareholderETH, SHAREHOLDER_ACC, totalWeight)`
- If `delta == 0`, flush MUST return and MUST keep `pendingShareholderETH` unchanged.
- `distributed = mulDivDown(delta, totalWeight, SHAREHOLDER_ACC)`
- `pendingShareholderETH` decreases by `distributed` and retains the remainder dust.

### Vector 6.1: flush distributes almost all ETH and retains 1 wei dust

Assume:
- `SHAREHOLDER_ACC = 1e36`
- `pendingShareholderETH = 1 ether = 1_000_000_000_000_000_000 wei`
- processed total ve = `333e18`, so `totalWeight = 333e36`

Compute (all floor):
- `delta = floor(pending * SHAREHOLDER_ACC / totalWeight)`
  - `delta = floor(1e18 * 1e36 / (333e36))`
  - `delta = 3_003_003_003_003_003`
- `distributed = floor(delta * totalWeight / SHAREHOLDER_ACC)`
  - `distributed = 999_999_999_999_999_999 wei`
- `pendingAfter = pending - distributed`
  - `pendingAfter = 1 wei`

Expected:
- `ethPerVe` increases by `3_003_003_003_003_003`
- `pendingShareholderETH` decreases by `999_999_999_999_999_999 wei`
- `pendingShareholderETH` retains `1 wei` dust

### Vector 6.2: delta == 0 no-op keeps pending unchanged

Assume:
- `pendingShareholderETH = 1 wei`
- processed total ve = `1_000e18` (and `veTotal >= MIN_VE_FLUSH`), so `totalWeight = 1_000e36`

Compute:
- `delta = floor(1 * 1e36 / 1_000e36) = 0`

Expected:
- `flushPendingShareholderETH()` returns (no-op)
- `ethPerVe` unchanged
- `pendingShareholderETH` unchanged (still `1 wei`)

### Vector 6.3: user checkpoint accrual after a flush (constant-weight lock)

Assume after vector 6.1:
- `delta = 3_003_003_003_003_003` was applied to `ethPerVe`
- User has a single AutoMax / constant-weight lock with:
  - `amount = 10e18`
  - `userEthPerVePaid = 0`

Compute:
- For a constant-weight lock, `checkpointUser` still reduces to:
  - `accrued = floor(amount * 1e18 * (ethPerVe - paid) / 1e36)`
- With `paid = 0` and delta-only movement:
  - `accrued = floor(10e18 * 1e18 * delta / 1e36) = 30_030_030_030_030_030 wei`
  - `accrued ≈ 0.03003003003003003 ether`

Expected:
- `claimableEth[user]` increases by `30_030_030_030_030_030 wei`
- `userEthPerVePaid[user]` is set to the new `ethPerVe`
- For decaying locks, implementations MUST instead use the historical reward-checkpoint timestamps and time-weighted prefix sums; current `veBalanceOf(user)` alone is insufficient.
---

## 7) VeClaimNFT ve math (single mulDivDown)

Source of truth:
- `docs/spec/spec-v1.0.0.md` §4.1 (ve model)
- [Math and rounding appendix](../architecture/math-and-rounding-appendix-v1.0.0.md)

Rule (MUST):
- `ve = mulDivDown(amount, remainingSeconds, MAX_LOCK_DURATION)` (floor)

Assume:
- `MAX_LOCK_DURATION = 365 days = 31_536_000 seconds`

### Vector 7.1: full remaining equals principal
Assume:
- `amount = 1_000e18`
- `remainingSeconds = MAX_LOCK_DURATION`

Compute:
- `ve = floor(amount * MAX / MAX) = amount = 1_000e18`

Expected:
- `ve = 1_000e18`

### Vector 7.2: clean fraction (73 days = 1/5 of max)
Assume:
- `amount = 1_000e18`
- `remainingSeconds = 73 days = 6_307_200 seconds`

Compute:
- Ratio: `remaining / MAX = 73 / 365 = 1/5`
- `ve = floor(1_000e18 / 5) = 200e18`

Expected:
- `ve = 200e18`

### Vector 7.3: near-expiry (1 day remaining)
Assume:
- `amount = 1_000e18`
- `remainingSeconds = 1 day = 86_400 seconds`

Compute (floor):
- `ve = floor(1_000e18 * 86_400 / 31_536_000)`
- `ve = 2_739_726_027_397_260_273`

Expected:
- `ve = 2_739_726_027_397_260_273`

### Vector 7.4: double-floor hazard example
Assume:
- `amount = 1_000e18 + 1`
- `remainingSeconds = 1 day = 86_400 seconds`

Correct (single mulDivDown):
- `ve_single = floor((1_000e18 + 1) * 86_400 / 31_536_000) = 2_739_726_027_397_260_273`

Incorrect (double floor):
- `slope_floor = floor((1_000e18 + 1) / 31_536_000)`
- `ve_double = slope_floor * 86_400 = 2_739_726_027_397_209_600`

Difference:
- `ve_single - ve_double = 50_673` (small but real)

Expected:
- Implementations MUST use the single mulDivDown method.

---

## 8) MarketRouter Bonus Target Order conversion (targetBonusBps → discountBps)

Source of truth:
- `docs/spec/spec-v1.0.0.md` §8.2.y (Bonus Target Order)

Conversion (MUST):
- `discountBps = floor(targetBonusBps * 10_000 / (10_000 + targetBonusBps))`

### Vector 8.1: target bonus 0%
Input:
- `targetBonusBps = 0`

Compute:
- `discountBps = floor(0 * 10_000 / (10_000 + 0)) = 0`

Expected:
- `discountBps = 0`

### Vector 8.2: target bonus 50%
Input:
- `targetBonusBps = 5_000`

Compute:
- `discountBps = floor(5_000 * 10_000 / 15_000)`
- `discountBps = floor(50_000_000 / 15_000) = 3_333`

Expected:
- `discountBps = 3_333`

### Vector 8.3: target bonus 100%
Input:
- `targetBonusBps = 10_000`

Compute:
- `discountBps = floor(10_000 * 10_000 / 20_000) = 5_000`

Expected:
- `discountBps = 5_000`

---

## 9) EntryTokenRegistry route resolution vectors

Source of truth:
- `docs/spec/entry-token-registry-v1.0.0.md` §4 (Route resolution)

These vectors validate deterministic route selection (no user-supplied paths).

### Vector 9.1: resolveFurnaceRoute directToClaimEnabled = true

Assume:
- `TokenConfig.enabled = true`
- `TokenConfig.directToClaimEnabled = true`
- `isFurnaceEntryTokenExactReceiptSafe(tokenIn) = true`
- `tokenClaimStable/tokenClaimPool` are set and validated via `router.poolFor(...)`

Expected:
- `route.length = 1`
- `route[0] = { tokenIn, CLAIM, tokenClaimStable, tokenClaimPool }`
- `routeTokenId = 0` (DIRECT_TO_CLAIM)

### Vector 9.2: resolveFurnaceRoute directToClaimEnabled = false (via WETH)

Assume:
- `TokenConfig.enabled = true`
- `TokenConfig.directToClaimEnabled = false`
- `isFurnaceEntryTokenExactReceiptSafe(tokenIn) = true`
- `tokenWethStable/tokenWethPool` are set and validated
- global WETH/CLAIM hop is configured: `(wethClaimStable, wethClaimPool)`

Expected:
- `route.length = 2`
- `route[0] = { tokenIn, WETH, tokenWethStable, tokenWethPool }`
- `route[1] = { WETH, CLAIM, wethClaimStable, wethClaimPool }`
- `routeTokenId = 1` (VIA_WETH)

### Vector 9.3: resolveFurnaceRoute requires WETH/CLAIM hop when via-WETH

Assume:
- `TokenConfig.enabled = true`
- `TokenConfig.directToClaimEnabled = false`
- global WETH/CLAIM hop is unset

Expected:
- `resolveFurnaceRoute(tokenIn)` reverts

### Vector 9.3b: resolveFurnaceRoute requires Furnace exact-receipt-safe opt-in

Assume:
- `TokenConfig.enabled = true`
- `isFurnaceEntryTokenExactReceiptSafe(tokenIn) = false`

Expected:
- `resolveFurnaceRoute(tokenIn)` reverts `UnsafeEntryToken()`

### Vector 9.4: resolveTakeoverRoute always returns tokenIn -> WETH hop

Assume:
- `TokenConfig.enabled = true`

Expected:
- `route.length = 1`
- `route[0] = { tokenIn, WETH, tokenWethStable, tokenWethPool }`
