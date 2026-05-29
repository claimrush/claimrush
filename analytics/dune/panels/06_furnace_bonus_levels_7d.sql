-- ClaimRush v1.0.0 Panel 06
-- Furnace bonus levels (last 7 days)
--
-- Purpose:
-- - Time series suitable for a small Furnace bonus history chart.
--
-- Data source:
-- - Event-derived realized bonus rate:
--     implied_bonus_bps = bonusClaim / principalClaim * 10_000
--   (Uses FurnaceEnter events; does NOT require view calls.)
--
-- Notes:
-- - This is a realized bonus rate on actual entries, not a spot quote.
-- - If there are hours with no entries, those hours will be missing from the series.
--
-- Dune parameters:
--   {{FURNACE_START_BLOCK}} (integer)  -- contract deployment/start block for performance filtering
--
-- Replace <DUNE_SCHEMA> with your decoded contract schema.
--
-- Output columns:
--   hour
--   median_bonus_bps
--   avg_bonus_bps
--   sample_count
--   q33_bonus_bps_24h
--   q66_bonus_bps_24h
--   bonus_tier
--   bonus_tier_level

WITH raw AS (
  SELECT
    evt_block_time,
    date_trunc('hour', evt_block_time) AS hour,
    (CAST(bonusClaim AS double) * 10000.0) / NULLIF(CAST(principalClaim AS double), 0) AS implied_bonus_bps
  FROM <DUNE_SCHEMA>.Furnace_evt_FurnaceEnter
  WHERE evt_block_number >= {{FURNACE_START_BLOCK}}
    AND evt_block_time >= date_add('day', -7, now())
    AND principalClaim > 0
),
quantiles_24h AS (
  SELECT
    approx_percentile(implied_bonus_bps, 0.33) AS q33_bonus_bps_24h,
    approx_percentile(implied_bonus_bps, 0.66) AS q66_bonus_bps_24h
  FROM raw
  WHERE evt_block_time >= date_add('hour', -24, now())
),
hourly AS (
  SELECT
    hour,
    approx_percentile(implied_bonus_bps, 0.50) AS median_bonus_bps,
    avg(implied_bonus_bps) AS avg_bonus_bps,
    count(*) AS sample_count
  FROM raw
  GROUP BY 1
)
SELECT
  h.hour,
  h.median_bonus_bps,
  h.avg_bonus_bps,
  h.sample_count,
  q.q33_bonus_bps_24h,
  q.q66_bonus_bps_24h,
  CASE
    WHEN q.q33_bonus_bps_24h IS NULL OR q.q66_bonus_bps_24h IS NULL THEN NULL
    WHEN h.median_bonus_bps >= q.q66_bonus_bps_24h THEN 'High'
    WHEN h.median_bonus_bps >= q.q33_bonus_bps_24h THEN 'Mid'
    ELSE 'Low'
  END AS bonus_tier,
  CASE
    WHEN q.q33_bonus_bps_24h IS NULL OR q.q66_bonus_bps_24h IS NULL THEN NULL
    WHEN h.median_bonus_bps >= q.q66_bonus_bps_24h THEN 3
    WHEN h.median_bonus_bps >= q.q33_bonus_bps_24h THEN 2
    ELSE 1
  END AS bonus_tier_level
FROM hourly h
CROSS JOIN quantiles_24h q
ORDER BY h.hour ASC;
