# Math and Rounding Appendix – ClaimRush v1.0.0

**Status:** Normative (this appendix defines required rounding behavior).

Goal:
- Make rounding choices explicit so:
  - quotes match execution,
  - caps are enforced strictly,
  - no silent value leakage occurs via rounding drift.

---

## M.1 Units and conventions

- **CLAIM** uses 18 decimals.
- **ve** uses 18 decimals (same scale as locked CLAIM principal).
- **BPS** math uses:
  - `BPS_DENOM = 10_000`
- **ETH-per-ve index** uses a fixed-point accumulator:
  - `ACC = 1e18`
- Time is seconds since Unix epoch (`block.timestamp`).

Default rounding rule:
- Unless stated otherwise, divisions MUST round **DOWN** (floor).

Exception rule:
- Use rounding **UP** (ceiling) only when required to enforce a strict cap or conservative denominator.

Recommended primitive:
- Use OpenZeppelin `Math.mulDiv` (supports floor/ceil) for overflow-safe 512-bit mul/div.

---

## M.1.1 Rounding policy by operation type

These rules exist to prevent value extraction via rounding (split deposits, dust farming) and to keep quotes trustworthy.

**Rule A (user value):** when computing any user-facing value that flows **out of** the protocol, round **DOWN**.
- Examples:
  - ve per lock: `ve = floor(amount * remaining / MAX_LOCK_DURATION)`
  - Furnace bonus: `bonus = floor(R * p / (V + p))`
  - Shareholder accrual: `owed = floor(userVe * (ethPerVeDelta) / ACC)`
  - MarketRouter execution price: `price = floor(principal * (10_000 - discountBps) / 10_000)`

**Rule B (cap enforcement):** when computing a target value that enforces an **upper bound**, round **UP**.
- Examples:
  - Furnace `vTarget = ceil(R * 10_000 / spotBonusBps)` (strict bonus cap)
  - Any computed "minimum depth/collateral" derived from dividing by a cap rate

**Rule C (distribution denominators):** any cached value used as a **denominator** MUST be conservative (never underestimated).
- Example:
  - `totalVeCached` in VeClaimNFT (denominator for ETH-per-ve index)

**Rule D (state evolution):** decay and distribution steps MUST NOT over-credit users.
- When decaying toward a target:
  - subtract a **floor** of the decay amount
- When distributing:
  - subtract only the amount actually distributed; keep the remainder in the pending bucket

Implementation notes:
- Prefer `Math.mulDiv(x, y, d, Rounding.Floor/Ceil)` for all nontrivial mul/div.
- Avoid "double-floor" patterns that drift downward over time (and break quote parity).


---

## M.2 Furnace bonus rounding rules (user cap + LP top-up + AMM)

This section defines rounding rules for the Furnace model so that a Solidity
implementation:

- Never overpays users or LPs.
- Never overstates user / LP bonus bps.
- Avoids overflow by using `mulDiv` for products followed by division.

Conventions:

- `BPS_DENOM = 10_000`.
- All multipliers are stored as bps integers (e.g. 1.0x = 10_000, 2.0x = 20_000).
- All divisions that affect user-visible caps or payout amounts MUST round DOWN
  (floor) unless explicitly stated otherwise.
- Use rounding UP (ceiling) only when required to enforce a strict cap or conservative
  denominator (notably `vTarget`).

Recommended primitive:
- OpenZeppelin `Math.mulDiv` (overflow-safe 512-bit mul/div) with explicit rounding.

- `vTarget = ceil(R * BPS_DENOM / spotBps)`

Constraints (required):
- `vTarget` MUST use **ceiling** rounding.
- If `spotBps == 0`, treat `vTarget = 0` and pay no bonus.

Required invariant (integer-safe):
- For any entry with `p > 0` and `spotBps > 0`:
  - `bonus * BPS_DENOM <= p * spotBps`

Rationale:
- `V >= ceil(R * BPS_DENOM / spotBps)` implies `R / V <= spotBps / BPS_DENOM`.
- Since `V + p >= V` and `bonus` is floored, the cap cannot be exceeded.
### M.2.1 Lock-% anchor: `baseUserBps`

The base user cap is anchored to locked CLAIM as a share of total supply.

Definitions:

- `totalSupply`: total supply of CLAIM (`ClaimToken.totalSupply()`).
- `lockedSupply`: total CLAIM locked in ve (`VeClaimNFT.totalLockedClaim()`).
- `lockedPctBps = clamp(floor(10_000 * lockedSupply / totalSupply), 0, 10_000)`.

Formula:

```text
baseUserBps = floor(MAX_USER_BONUS_BPS * LOCK_PCT_TARGET_BPS / (LOCK_PCT_TARGET_BPS + lockedPctBps))
```

Rounding & implementation:

```solidity
uint256 lockedPctBps = totalSupply == 0
  ? 0
  : Math.mulDiv(BPS_DENOM, lockedSupply, totalSupply); // floor
if (lockedPctBps > BPS_DENOM) lockedPctBps = BPS_DENOM;

uint256 den = LOCK_PCT_TARGET_BPS + lockedPctBps;
uint256 baseUserBps = Math.mulDiv(MAX_USER_BONUS_BPS, LOCK_PCT_TARGET_BPS, den); // floor
```

---

### M.2.2 Reserve multipliers: `rawMultBps`, `alphaBps`, `effMultBps`

Multipliers are represented in bps:

- `rawMultBps`: raw reserve multiplier in `[0, RESERVE_FACTOR_MAX_BPS]`.
- `alphaBps`: bootstrap progress in `[0, 10_000]`.
- `effMultBps`: time-ramped reserve multiplier before the low-lock max-boost cap.
- `maxReserveFactorBps`: lock-% dependent cap in `[RESERVE_FACTOR_MAX_BPS_LOWLOCK, RESERVE_FACTOR_MAX_BPS]`.
- `reserveFactorBps`: the capped runtime factor actually applied to the user cap, `min(effMultBps, maxReserveFactorBps)`.

Mapping note (naming used elsewhere in the repo):
- `reserveFullnessBps` ≙ `rawMultBps`
- `swingAlphaBps` ≙ `alphaBps` (bootstrap progress for reserve control)
- `reserveFactorBps` is the capped runtime factor; it equals `effMultBps` only when the low-lock max-boost cap is inactive.

#### rawMultBps

Formula:

```text
rawMultBps = clamp( floor(10_000 * R / RESERVE_TARGET_FINAL), 0, RESERVE_FACTOR_MAX_BPS )
```

Implementation:

```solidity
// Precondition: RESERVE_TARGET_FINAL > 0
uint256 rawMultBps = Math.mulDiv(BPS_DENOM, R, RESERVE_TARGET_FINAL); // floor
if (rawMultBps > RESERVE_FACTOR_MAX_BPS) rawMultBps = RESERVE_FACTOR_MAX_BPS;
```

#### alphaBps

Formula:

```text
alphaBps = clamp( floor(10_000 * elapsed / SWING_TIME), 0, 10_000 )
```

Implementation:

```solidity
// Precondition: SWING_TIME > 0
uint256 alphaBps = Math.mulDiv(BPS_DENOM, elapsed, SWING_TIME); // floor
if (alphaBps > BPS_DENOM) alphaBps = BPS_DENOM;
```

#### effMultBps

Formula:

```text
effMultBps = 10_000 + floor( alphaBps * (rawMultBps - 10_000) / 10_000 )
```

Implementation note:
- `(rawMultBps - 10_000)` is signed.
- Use a piecewise implementation to avoid uint underflow:

```solidity
uint256 effMultBps;

if (rawMultBps >= BPS_DENOM) {
    uint256 deltaUp = rawMultBps - BPS_DENOM;
    uint256 adjUp = Math.mulDiv(alphaBps, deltaUp, BPS_DENOM); // floor
    effMultBps = BPS_DENOM + adjUp;
} else {
    uint256 deltaDown = BPS_DENOM - rawMultBps;
    uint256 adjDown = Math.mulDiv(alphaBps, deltaDown, BPS_DENOM, Math.Rounding.Ceil); // ceil (signed-floor for negative)
    effMultBps = BPS_DENOM - adjDown;
}
```

Bounds:

- `0 <= rawMultBps <= RESERVE_FACTOR_MAX_BPS`.
- `0 <= alphaBps <= 10_000`.
- `0 <= effMultBps <= RESERVE_FACTOR_MAX_BPS`.
- At launch (`alphaBps = 0`) → `effMultBps = 10_000`.
- After ramp (`alphaBps = 10_000`) → `effMultBps = rawMultBps`.

---

### M.2.3 User spot cap: `userSpotBps`

Formula:

```text
reserveFactorBps = min(effMultBps, maxReserveFactorBps)
userSpotBps = min(MAX_USER_BONUS_BPS, floor(baseUserBps * reserveFactorBps / 10_000))
```

Implementation:

```solidity
uint256 lockedPctBps = totalSupply == 0
  ? 0
  : Math.mulDiv(BPS_DENOM, lockedSupply, totalSupply); // floor
if (lockedPctBps > BPS_DENOM) lockedPctBps = BPS_DENOM;

uint256 maxFactorBps = _maxReserveFactorBps(lockedPctBps);
uint256 reserveFactorBps = effMultBps;
if (reserveFactorBps > maxFactorBps) reserveFactorBps = maxFactorBps;

uint256 userSpotBps = Math.mulDiv(baseUserBps, reserveFactorBps, BPS_DENOM); // floor
if (userSpotBps > MAX_USER_BONUS_BPS) userSpotBps = MAX_USER_BONUS_BPS;
```

---

### M.2.4 LP top-up (additive) and `grossSpotBps`

LP top-up rate uses a base convex curve plus reserve-aware down-scaling:

- Let `u = userSpotBps` and `U = MAX_USER_BONUS_BPS`.
- Let `γ = LP_TOPUP_GAMMA` (pinned to `2` in v1.0.0).
- Let `lpScaleBps = min(10_000, reserveFactorBps)` where `reserveFactorBps` is the same low-lock-capped runtime factor used for `userSpotBps`.

```text
lpRateBpsBase = LP_MIN + floor( (LP_MAX - LP_MIN) * (u^γ) / (U^γ) )
lpRateBps     = floor(lpRateBpsBase * lpScaleBps / 10_000)
```

LP top-up cap and gross cap:

```text
lpTopupSpotBps = floor(userSpotBps * lpRateBps / 10_000)
grossSpotBps   = userSpotBps + lpTopupSpotBps
```

Implementation (supports γ = 1 or 2 only):

```solidity
uint256 lpRateBpsBase;
if (lpRewardsVault == address(0)) {
    lpRateBpsBase = 0;
} else {
    uint256 span = LP_TOPUP_RATE_MAX_BPS - LP_TOPUP_RATE_MIN_BPS;

    uint256 extra;
    uint256 gamma = LP_TOPUP_GAMMA;
    if (gamma == 1) {
        // Linear: (bonus/MAX)
        extra = Math.mulDiv(span, userSpotBps, MAX_USER_BONUS_BPS); // floor
    } else if (gamma == 2) {
        // Convex: (bonus/MAX)^2
        uint256 num = userSpotBps * userSpotBps;
        uint256 denom = MAX_USER_BONUS_BPS * MAX_USER_BONUS_BPS;
        extra = Math.mulDiv(span, num, denom); // floor
    } else {
        revert InvariantViolation();
    }

    lpRateBpsBase = LP_TOPUP_RATE_MIN_BPS + extra;

    if (lpRateBpsBase < LP_TOPUP_RATE_MIN_BPS) lpRateBpsBase = LP_TOPUP_RATE_MIN_BPS;
    if (lpRateBpsBase > LP_TOPUP_RATE_MAX_BPS) lpRateBpsBase = LP_TOPUP_RATE_MAX_BPS;
}

uint256 lpScaleBps = reserveFactorBps > BPS_DENOM ? BPS_DENOM : reserveFactorBps;
uint256 lpRateBps = Math.mulDiv(lpRateBpsBase, lpScaleBps, BPS_DENOM); // floor

uint256 lpTopupSpotBps = Math.mulDiv(userSpotBps, lpRateBps, BPS_DENOM); // floor
uint256 grossSpotBps = userSpotBps + lpTopupSpotBps;
```

---

### M.2.5 vTarget (ceiling)

To enforce the gross cap strictly without rounding leak:

```text
vTarget = ceil(R * 10_000 / grossSpotBps)   (only when grossSpotBps > 0)
```

Implementation:

```solidity
uint256 vTarget;
if (grossSpotBps == 0 || R == 0) {
    vTarget = 0; // zero-bonus regime
} else {
    vTarget = Math.mulDiv(R, BPS_DENOM, grossSpotBps, Math.Rounding.Ceil);
}
```

Behavior when `grossSpotBps == 0`:

- Constraint: treat as “bonus disabled”; quotes and payouts MUST return 0.
- Implementations MUST avoid division by zero and MUST NOT produce non-zero bonuses.

---

### M.2.6 Quote bps (gross/user/LP)

Gross quote:

```text
quoteGrossBps = floor(R * 10_000 / max(V, vTarget))
```

Split the internal gross quote into returned user + LP fields:

```text
denom = 10_000 + lpRateBps
quoteUserBonusBps = floor(quoteGrossBps * 10_000 / denom)
quoteLpTopupBps = floor(quoteUserBonusBps * lpRateBps / 10_000)
```

Implementation:

```solidity
uint256 denQuote = V > vTarget ? V : vTarget;

uint256 quoteGrossBps;
if (denQuote == 0 || R == 0) {
    quoteGrossBps = 0;
} else {
    quoteGrossBps = Math.mulDiv(R, BPS_DENOM, denQuote); // floor
}

uint256 denom = BPS_DENOM + lpRateBps;
uint256 quoteUserBonusBps = quoteGrossBps == 0 ? 0 : Math.mulDiv(quoteGrossBps, BPS_DENOM, denom); // floor
if (quoteUserBonusBps > userSpotBps) quoteUserBonusBps = userSpotBps;
uint256 quoteLpTopupBps = Math.mulDiv(quoteUserBonusBps, lpRateBps, BPS_DENOM); // floor
```

Returned quote fields satisfy `quoteUserBonusBps + quoteLpTopupBps <= quoteGrossBps`; the gap is floor dust from splitting the internal gross quote into user + LP bps.

---



### M.2.7 Bonus payment (AMM formula)

Given:
- `R = furnaceReserve`
- `V = bonusVirtualDepth` (after applying decay + `max(V, vTarget)`)
- `p = principalClaim`

Compute:
- `bonus = floor(R * p / (V + p))`

Update (exact):
- `R := R - bonus`
- `V := V + p`

Quote functions MUST use the exact same rounding and update simulation.

Zero-effective actions:
- If the entry’s effective principal is 0, the bonus MUST be 0.
  - Clarification (non-binding): Effective principal can be 0 due to duration-weighting.
- To prevent griefing via timestamp manipulation, the AMM update MUST be skipped (no change to `bonusVirtualDepth` and `lastBonusUpdate`) when effective principal is 0.


---

### M.2.8 Bonus split on payout (amounts)

After computing the gross bonus amount:

```text
userBonus = floor(grossBonus * 10_000 / denom)
lpBonus   = grossBonus - userBonus
```

State updates use gross:

- `R := R - grossBonus`
- `V := V + P_eff`

Implementation:

```solidity
uint256 denom = BPS_DENOM + lpRateBps;
uint256 userBonus = Math.mulDiv(grossBonus, BPS_DENOM, denom); // floor
uint256 lpBonus = grossBonus - userBonus;

R -= grossBonus;
V += P_eff;
```



### M.2.9 LP overflow drip (daily reserve → LP rewards stream)

This subsection defines rounding for the LP overflow drip defined in:
- `src/lib/Constants.sol` §3.4.6

All amounts are per 24 hours.

#### gBps (excess gate)

Given:
- `excess = max(0, R - RESERVE_TARGET_FINAL)`

Compute:

```text
gBps = floor(10_000 * excess / (excess + LP_OVERFLOW_DRIP_GATE_K))
```

Rounding:
- Use floor rounding.
- If `excess == 0`, define `gBps = 0` (no division-by-zero or weird edge behavior).

Implementation:

```solidity
uint256 gBps;
if (excess == 0) {
    gBps = 0;
} else {
    uint256 den = excess + LP_OVERFLOW_DRIP_GATE_K;
    gBps = Math.mulDiv(BPS_DENOM, excess, den); // floor
    if (gBps > BPS_DENOM) gBps = BPS_DENOM; // defensive clamp
}
```

#### alphaBps (time ramp-in)

Compute:

- If `tSinceLaunch <= LP_OVERFLOW_DRIP_START`: `alphaBps = 0`
- Else if `tSinceLaunch >= LP_OVERFLOW_DRIP_START + LP_OVERFLOW_DRIP_RAMP`: `alphaBps = 10_000`
- Else:

```text
alphaBps = floor(10_000 * (tSinceLaunch - LP_OVERFLOW_DRIP_START) / LP_OVERFLOW_DRIP_RAMP)
```

Rounding:
- Use floor rounding.
- Clamp into `[0, 10_000]`.
- Clarification: this `alphaBps` is the drip ramp-in (distinct from the SWING_TIME `alphaBps` used in reserve control).

Implementation:

```solidity
uint256 alphaBps;
if (tSinceLaunch <= LP_OVERFLOW_DRIP_START) {
    alphaBps = 0;
} else if (tSinceLaunch >= LP_OVERFLOW_DRIP_START + LP_OVERFLOW_DRIP_RAMP) {
    alphaBps = BPS_DENOM;
} else {
    uint256 elapsed = tSinceLaunch - LP_OVERFLOW_DRIP_START;
    alphaBps = Math.mulDiv(BPS_DENOM, elapsed, LP_OVERFLOW_DRIP_RAMP); // floor
    if (alphaBps > BPS_DENOM) alphaBps = BPS_DENOM;
}
```

#### capInflowPerDay (inflow-based cap)

Given:
- `furnaceInflowPerDay = currentFurnaceEmissionRatePerSecond * 86_400`

Compute:

```text
capInflowPerDay = floor(furnaceInflowPerDay * LP_OVERFLOW_DRIP_INFLOW_SHARE_CAP_BPS / 10_000)
```

Implementation:

```solidity
uint256 capInflowPerDay = Math.mulDiv(furnaceInflowPerDay, LP_OVERFLOW_DRIP_INFLOW_SHARE_CAP_BPS, BPS_DENOM); // floor
```

#### lpOverflowDripPerDay (mulDiv chain)

Let:

```text
baseCap = min(LP_OVERFLOW_DRIP_FIXED_CAP_PER_DAY, capInflowPerDay)
```

Then compute:

```text
lpOverflowDripPerDay = floor(baseCap * alphaBps / 10_000 * gBps / 10_000)
```

Rounding:
- Apply floor at each step.
- Suggested implementation uses two `mulDiv` calls (avoids 3-term overflow and makes floors explicit):

```solidity
uint256 baseCap = capInflowPerDay < LP_OVERFLOW_DRIP_FIXED_CAP_PER_DAY ? capInflowPerDay : LP_OVERFLOW_DRIP_FIXED_CAP_PER_DAY;

// step1 = floor(baseCap * alphaBps / 10_000)
uint256 step1 = (baseCap == 0 || alphaBps == 0) ? 0 : Math.mulDiv(baseCap, alphaBps, BPS_DENOM); // floor

// step2 = floor(step1 * gBps / 10_000)
uint256 lpOverflowDripPerDay = (step1 == 0 || gBps == 0) ? 0 : Math.mulDiv(step1, gBps, BPS_DENOM); // floor
```

Bounds:
- `lpOverflowDripPerDay <= baseCap` (since `alphaBps, gBps <= 10_000` and we floor).

### M.2.10 Furnace LP rewards stream (`LP_STREAM_WINDOW` smoothing)

This subsection defines rounding and cursor semantics for the Furnace LP rewards stream (§7.3.6).

Purpose:
- Smooth the LP reward rate by streaming any Furnace-funded LP rewards (bonus LP split, overflow drip, sellback LP share) linearly over `LP_STREAM_WINDOW` (14 days).

State variables (Furnace):
- `rate = lpStreamRatePerSec`
- `finish = lpStreamPeriodFinish`
- `last = lpStreamLastUpdate`

#### Accrual (`_accrueLpStream`)

Let:
- `t = min(now, finish)`

If `rate == 0` or `finish == 0` or `t <= last`, then `owed = 0`.

Else:

```text
dt   = t - last
owed = dt * rate
```

Rounding:
- All terms are integers; `owed` is exact.
- `last` MUST advance to `t` before the external transfer/notify.

#### Funding (`_fundLpStream(amount)`)

On each funding call with `amount` (after accruing the existing stream):

```text
remaining = (finish > now) ? (finish - now) * rate : 0
total     = remaining + amount

newRate   = floor(total / LP_STREAM_WINDOW)
newFinish = now + LP_STREAM_WINDOW
last      = now
```

Dust:
- Because of integer division, up to `(LP_STREAM_WINDOW - 1)` wei may remain undistributed as dust inside Furnace.
- This is acceptable and is carried forward implicitly by `remaining` on the next funding call.



## M.3 ShareholderRoyalties ETH-per-ve index

Let:
- `pending = pendingShareholderETH` (ETH in contract not yet indexed)
- `T_scaled = totalVeBiasScaled` (processed total ve-bias, units `ve * 1e18`)
- `ethPerVe` scaled by `ACC = 1e18` (canonical name / scale)
- `SHAREHOLDER_ACC = 1e36`

Flush step (permissionless residual flush; MUST no-op when `T_scaled == 0` or when `ceil(T_scaled / 1e18) < MIN_VE_FLUSH`):

- if checkpoint storage cannot safely represent `rewardTs` yet (for example both checkpoint arrays are saturated and the oldest overflow entry is still inside `MAX_LOCK_DURATION`), the flush MUST no-op before changing any indices and leave ETH in `pendingShareholderETH`
- `deltaIndex = floor(pending * 1e36 / T_scaled)`
- `ethPerVe := ethPerVe + deltaIndex`
- `ethPerVeTimeWeighted := ethPerVeTimeWeighted + deltaIndex * rewardTs`
- store reward checkpoint `(rewardTs, cumulativeEthPerVe, cumulativeTimeWeightedEthPerVe)`. If `rewardCheckpoints` is at `MAX_REWARD_CHECKPOINTS`, the main array is frozen and the snapshot is routed to `_overflowCheckpoints` (ring-buffer with FIFO eviction at `MAX_OVERFLOW_CHECKPOINTS`). Distinct timestamps inside a fully saturated active-horizon ring are deferred instead of being coalesced into a pinned older timestamp.

To avoid dust loss, only subtract the amount actually “distributed” by this index move:

- `distributed = floor(deltaIndex * T_scaled / 1e36)`
- `pendingShareholderETH := pendingShareholderETH - distributed`

User accrual:

- AutoMax lock:
  - `owed = floor(amount * 1e18 * Δidx / 1e36)`
- Decaying lock:
  - let `Δidx` and `ΔtimeWeightedIdx` be prefix-sum deltas over reward checkpoints with `rewardTs < lockEnd`
  - `owed = floor(slopeScaled(amount) * (lockEnd * Δidx - ΔtimeWeightedIdx) / 1e36)`
- Carry any sub-wei remainder forward per user rather than dropping it.

All ETH-credit boundaries MUST round DOWN.

---

## M.4 MineCore emission integrals

MineCore MUST mint emissions via the integral of the linear-decay schedule (trapezoid), not `rate(end) * dt`.

For a segment fully inside the decay region:

- `emitted = floor((rate(t0) + rate(t1)) * dt / 2)`

If an interval crosses the floor boundary:

- split into 2 segments:
  - decay segment (trapezoid)
  - floor segment (`floorRate * dtFloor`)

Rounding MUST NOT cause over-minting:
- round each segment DOWN, then sum.

---

## M.5 VeClaimNFT rounding

### M.5.1 Per-lock ve

Per-lock ve MUST be computed with a **single** floor mul/div:

- `ve = floor(amount * remaining / MAX_LOCK_DURATION)`

MUST NOT use “double-floor” slope math:
- Do NOT compute `slope = floor(amount / MAX)` then `slope * remaining`.

### M.5.2 Global aggregates MUST be conservative

`totalVeCached` is used as a **denominator** for ETH distribution.

Safety requirement (from SPEC):
- After checkpointing, `totalVeCached` MUST be **>=** the sum of all user `veBalanceOf(user)` values at the same timestamp.
- Conservative rounding is allowed, so `totalVeCached` is allowed to be slightly higher than the exact sum.
- `totalVeCached` MUST NOT be lower than the exact sum.

Why this is strict:
- Underestimating `totalVeCached` over-credits the ETH-per-ve index and can make `sum(userOwed)` exceed available ETH.

Required rounding directions for checkpoint math:
- Per-lock ve (user-facing): floor.
- Any division that affects a cached **denominator**: round **UP** (or delay rounding and do a single final ceil).
- Time decay subtraction: subtract a floor of the decay amount.

Recommended implementation pattern (minimize grief while staying conservative):
- Keep global aggregates in a **scaled** fixed-point space and round only once.
  - `SLOPE_SCALE = 1e18`
  - `slopeScaled_i = ceilDiv(amount_i * SLOPE_SCALE, MAX_LOCK_DURATION)`
  - `biasScaled_i = slopeScaled_i * remaining_i`
- Maintain:
  - `globalSlopeScaled = Σ slopeScaled_i`
  - `globalBiasScaled  = Σ biasScaled_i`
- On checkpoint:
  - apply time decay in scaled space using `mulDivDown` for the decay amount
  - set `totalVeCached = ceilDiv(globalBiasScaled, SLOPE_SCALE)`

Caution:
- Do NOT compute an unscaled `slope = ceilDiv(amount, MAX_LOCK_DURATION)` in whole-token units.
  - It can make tiny locks contribute a full unit of slope and becomes griefable.

## M.6 MarketRouter pricing (bonus target escrows)

Bonus target escrow execution price is derived from lock principal and discount, and MUST be deterministic.

Constraint: escrow pricing is based on principal only; lock duration is not part of the execution price.

Definitions:

- `BPS_DENOM = 10_000`.
- `discountBps` is expressed in basis points of the lock principal (`0 <= discountBps < 10_000`).

Pricing:

- `price = floor(principal * (BPS_DENOM - discountBps) / BPS_DENOM)`
- Equivalent form:
  - `price = principal * (10_000 - discountBps) / 10_000` (floor)

Implication of the v1 cap:

- With `maxBonusTargetEscrowDiscountBps = 8_000` (80% max discount), the minimum allowed execution price is:
  - `principal * 2_000 / 10_000` (**20%** of principal)

Rounding DOWN is required.

(If you round UP, you can violate the implied discount cap.)

---

## M.7 Cross-module rule: quotes MUST match execution

Any quote view used to derive `minVeOut` MUST:

- replicate the exact same route selection,
- replicate the exact same rounding,
- revert if configuration is unset,
- and, for call sites that feed the result into `Furnace.enter*`, clamp positive quotes that floor-round to zero up to `1`.

If quote math differs from execution math, users will:
- set a `minVeOut` that can never succeed (bad UX), or
- set a `minVeOut` that is weaker than intended (MEV exposure).

---

## M.8 Exploit-resistance and quote-integrity tests

These are the minimum tests that MUST exist to keep the “invisible mechanics” non-exploitable.

Furnace (bonus AMM):
- **Cap enforcement:** for all `p > 0`, assert:
  - `bonus * 10_000 <= p * spotBonusBps`
- **Ceil vTarget:** when `(R * 10_000) % spotBonusBps != 0`, assert:
  - `vTarget == floor(R * 10_000 / spotBonusBps) + 1`
- **Preview/update parity:** assert:
  - `_previewVirtualDepth(grossSpotBonusBps)` equals the value written by `_updateVirtualDepth(grossSpotBonusBps)` for the same state and timestamp.
- **Split resistance (same timestamp):**
  - `bonus(P1) + bonus(P2) <= bonus(P1 + P2)` (allow at most dust if your implementation needs a tolerance).
- **Dust farming guard:**
  - Repeated tiny deposits MUST NOT extract more bonus than a single combined deposit beyond rounding dust.

VeClaimNFT (denominator safety):
- After `checkpointTotalVe()`:
  - `totalVeCached >= Σ veOf(tokenId)` (brute-forced over a small randomized set in tests).

Quote integrity (trust):
- For every quote view used to set `minVeOut`:
  - `quote == simulateExecution` for the same inputs and the same pre-state (within explicit, documented tolerances only).


