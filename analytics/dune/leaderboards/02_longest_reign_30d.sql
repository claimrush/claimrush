-- ClaimRush v1.0.0 Leaderboard 2
-- Longest reign (30d)
--
-- Metric (per spec):
--   MAX(endTime - startTime) per king (longest single reign, in seconds)
--
-- Notes:
-- - Uses finalized-in-window semantics (filter by ReignFinalized.evt_block_time; not prorated).
-- - "Longest single reign" -- aggregate is MAX, not SUM.
--
-- REQUIRED: apply all filters before ORDER BY / LIMIT.
--
-- Dune parameters:
--   {{LIMIT}} (integer)
--   {{OFFSET}} (integer)
--   {{MINECORE_START_BLOCK}} (integer)  -- contract deployment/start block for performance filtering
--
-- Replace <DUNE_SCHEMA> with your decoded contract schema.

WITH base AS (
  SELECT
    king,
    (endTime - startTime) AS reign_seconds
  FROM <DUNE_SCHEMA>.MineCore_evt_ReignFinalized
  WHERE evt_block_number >= {{MINECORE_START_BLOCK}}
    AND evt_block_time >= date_add('day', -30, now())
),
agg AS (
  SELECT
    king AS address,
    MAX(reign_seconds) AS reign_seconds
  FROM base
  GROUP BY 1
)
SELECT
  address,
  reign_seconds
FROM agg
ORDER BY reign_seconds DESC, address
LIMIT {{LIMIT}}
OFFSET {{OFFSET}};
