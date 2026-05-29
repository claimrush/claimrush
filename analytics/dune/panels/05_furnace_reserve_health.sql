-- ClaimRush v1.0.0 Panel
-- Furnace reserve health (single row)

-- This panel gives a smoothed view of Furnace reserve health vs a time-varying target.

-- Outputs:
--   reserve_estimate      -- current reserve (same definition as 02_furnace_reserve_estimate.sql)
--   reserve_target_final  -- long-run target reserve (constant set in this query)
--   swing_time_seconds    -- time to swing fully from 0 -> reserve_target_final (constant set in this query)
--   alpha                 -- progress scalar in [0,1] based on seconds_since_launch / swing_time_seconds
--   reserve_target_now    -- current target = reserve_target_final * alpha
--   raw_mult              -- reserve_estimate / reserve_target_now   (NULL when alpha=0 or reserve_target_now=0)
--   eff_mult              -- 1 + alpha * (raw_mult - 1)              (falls back to 1 when alpha=0)

-- Reserve model (event-based; exact if all Furnace events are decoded):
--   reserve_estimate =
--     SUM(ReserveCredited.amount)
--   + SUM(LockSoldToFurnace.reserveAdd)
--   - SUM(BonusPaid.grossBonusClaim)
--   - SUM(LpOverflowDripPaid.dripAmount)

-- Parameters:
--   {{FURNACE_START_BLOCK}} (integer)
--   {{FURNACE_LAUNCH_TIME}} (timestamp)
--   {{RESERVE_TARGET_FINAL_CLAIM}} (integer)  -- protocolParams.furnace.reserveTargetFinalClaim (whole CLAIM)
--   {{SWING_TIME_SECONDS}} (integer)          -- protocolParams.furnace.swingTimeSeconds (default: 5184000 = 60 days)
-- Replace <DUNE_SCHEMA> with your decoded contract schema.

-- NOTE: This panel works in raw token units (18 decimals) to match decoded event fields.
--       Provide RESERVE_TARGET_FINAL_CLAIM in whole CLAIM and we scale by 1e18 here.

WITH params AS (
  SELECT
    CAST({{RESERVE_TARGET_FINAL_CLAIM}} AS double) * 1e18 AS reserve_target_final, -- raw CLAIM units (18 decimals)
    CAST({{SWING_TIME_SECONDS}} AS double) AS swing_time_seconds,
    CAST(date_diff('second', {{FURNACE_LAUNCH_TIME}}, now()) AS double) AS seconds_since_launch
),

credited AS (
  SELECT
    COALESCE(SUM(amount), 0) AS total_credited
  FROM <DUNE_SCHEMA>.Furnace_evt_ReserveCredited
  WHERE evt_block_number >= {{FURNACE_START_BLOCK}}
),

sellback AS (
  SELECT
    COALESCE(SUM(reserveAdd), 0) AS total_sellback_add
  FROM <DUNE_SCHEMA>.Furnace_evt_LockSoldToFurnace
  WHERE evt_block_number >= {{FURNACE_START_BLOCK}}
),

spent_bonus AS (
  SELECT
    COALESCE(SUM(grossBonusClaim), 0) AS total_gross_bonus_spent
  FROM <DUNE_SCHEMA>.Furnace_evt_BonusPaid
  WHERE evt_block_number >= {{FURNACE_START_BLOCK}}
),

spent_overflow AS (
  SELECT
    COALESCE(SUM(dripAmount), 0) AS total_overflow_spent
  FROM <DUNE_SCHEMA>.Furnace_evt_LpOverflowDripPaid
  WHERE evt_block_number >= {{FURNACE_START_BLOCK}}
),

base AS (
  SELECT
    credited.total_credited
      + sellback.total_sellback_add
      - spent_bonus.total_gross_bonus_spent
      - spent_overflow.total_overflow_spent AS reserve_estimate,
    params.reserve_target_final,
    params.swing_time_seconds,
    params.seconds_since_launch
  FROM credited
  CROSS JOIN sellback
  CROSS JOIN spent_bonus
  CROSS JOIN spent_overflow
  CROSS JOIN params
),

alpha_calc AS (
  SELECT
    reserve_estimate,
    reserve_target_final,
    swing_time_seconds,
    seconds_since_launch,
    CASE
      WHEN swing_time_seconds <= 0 THEN 0.0
      ELSE LEAST(1.0, GREATEST(0.0, seconds_since_launch / swing_time_seconds))
    END AS alpha
  FROM base
),

targets AS (
  SELECT
    reserve_estimate,
    reserve_target_final,
    swing_time_seconds,
    alpha,
    CASE
      WHEN alpha <= 0.0 THEN 0.0
      ELSE reserve_target_final * alpha
    END AS reserve_target_now
  FROM alpha_calc
),

multipliers AS (
  SELECT
    reserve_estimate,
    reserve_target_final,
    swing_time_seconds,
    alpha,
    reserve_target_now,
    CASE
      WHEN reserve_target_now <= 0 THEN NULL
      ELSE reserve_estimate / reserve_target_now
    END AS raw_mult
  FROM targets
)

SELECT
  reserve_estimate,
  reserve_target_final,
  swing_time_seconds,
  alpha,
  reserve_target_now,
  raw_mult,
  1 + alpha * (COALESCE(raw_mult, 1) - 1) AS eff_mult
FROM multipliers;
