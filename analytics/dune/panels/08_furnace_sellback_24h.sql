-- ClaimRush v1.0.0 Panel
-- Furnace sellback (24h, single row)

-- Data source:
-- - <DUNE_SCHEMA>.Furnace_evt_LockSoldToFurnace
--
-- Under the sellback primitive (lock -> liquid CLAIM):
-- - `lockAmount` is the ve principal withdrawn into Furnace
-- - `claimOut` is liquid CLAIM paid to the seller
-- - `lpReward` is CLAIM funded into the LP stream
-- - `reserveAdd` is the net credited to furnaceReserve

-- Outputs:
--   sells_24h:                   count of sellback executions
--   unique_sellers_24h:          distinct sellers
--   lock_amount_24h:             total principal processed
--   claim_paid_out_24h:          total liquid CLAIM paid to sellers
--   lp_funded_24h:               total CLAIM funded into LP stream from sellback cuts
--   reserve_add_24h:             total CLAIM credited to furnaceReserve from sellbacks
--   weighted_avg_spread_bps_24h: spread bps weighted by lockAmount
--   weighted_avg_bonus_ref_bps_used_24h: bonusRefBpsUsed (= max(spot, base) bps ref), weighted by lockAmount

-- Parameters:
--   {{FURNACE_START_BLOCK}} (integer)
-- Replace <DUNE_SCHEMA> with your decoded contract schema.

WITH base AS (
  SELECT
    seller,
    lockAmount,
    claimOut,
    lpReward,
    reserveAdd,
    spreadBps,
    bonusRefBpsUsed
  FROM <DUNE_SCHEMA>.Furnace_evt_LockSoldToFurnace
  WHERE evt_block_number >= {{FURNACE_START_BLOCK}}
    AND evt_block_time >= date_add('hour', -24, now())
)
SELECT
  COUNT(*) AS sells_24h,
  COUNT(DISTINCT seller) AS unique_sellers_24h,
  COALESCE(SUM(lockAmount), 0) AS lock_amount_24h,
  COALESCE(SUM(claimOut), 0) AS claim_paid_out_24h,
  COALESCE(SUM(lpReward), 0) AS lp_funded_24h,
  COALESCE(SUM(reserveAdd), 0) AS reserve_add_24h,
  CASE
    WHEN COALESCE(SUM(lockAmount), 0) = 0 THEN NULL
    ELSE CAST(SUM(CAST(spreadBps AS double) * CAST(lockAmount AS double)) / SUM(CAST(lockAmount AS double)) AS double)
  END AS weighted_avg_spread_bps_24h,
  CASE
    WHEN COALESCE(SUM(lockAmount), 0) = 0 THEN NULL
    ELSE CAST(SUM(CAST(bonusRefBpsUsed AS double) * CAST(lockAmount AS double)) / SUM(CAST(lockAmount AS double)) AS double)
  END AS weighted_avg_bonus_ref_bps_used_24h
FROM base;
