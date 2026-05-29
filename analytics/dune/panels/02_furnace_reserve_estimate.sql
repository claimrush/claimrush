-- ClaimRush v1.0.0 Panel
-- Furnace reserve estimate (single row)
--
-- All queries use the <DUNE_SCHEMA> placeholder, which operators replace with their
-- decoded contract schema (e.g. claimrush_base). If the decoded namespace changes
-- (e.g. re-decoding with a different project name), update the substituted value
-- or all queries silently return zero rows.

-- Reserve model (event-based; exact if all Furnace events are decoded):
--   reserve_estimate =
--     SUM(ReserveCredited.amount)
--   + SUM(LockSoldToFurnace.reserveAdd)
--   - SUM(BonusPaid.grossBonusClaim)
--   - SUM(LpOverflowDripPaid.dripAmount)
--
-- Notes:
-- - BonusPaid.grossBonusClaim is the gross bonus drawn from reserve (user + LP portion).
-- - LpOverflowDripPaid.dripAmount is reserve spent to fund the LP rewards stream.
-- - Under LP streaming, LP amounts are funded into a stream and transferred to the vault over time,
--   but the reserve impact occurs at funding time (captured by BonusPaid + LpOverflowDripPaid).

-- Parameters:
--   {{FURNACE_START_BLOCK}} (integer)
-- Replace <DUNE_SCHEMA> with your decoded contract schema.

WITH credited AS (
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
)

SELECT
  credited.total_credited,
  sellback.total_sellback_add,
  spent_bonus.total_gross_bonus_spent,
  spent_overflow.total_overflow_spent,
  credited.total_credited
    + sellback.total_sellback_add
    - spent_bonus.total_gross_bonus_spent
    - spent_overflow.total_overflow_spent AS reserve_estimate
FROM credited
CROSS JOIN sellback
CROSS JOIN spent_bonus
CROSS JOIN spent_overflow;
