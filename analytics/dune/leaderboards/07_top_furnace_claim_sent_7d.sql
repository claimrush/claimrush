-- ClaimRush v1.0.0 Leaderboard 7
-- Top CLAIM sent to Furnace (7d)
--
-- Metric (per spec):
--   SUM(Furnace.FurnaceEnter.principalClaim) by user
--
-- Source: FurnaceEnter.user + FurnaceEnter.principalClaim (preferred)
-- - principalClaim is the CLAIM principal of a successful Furnace entry call.
--
-- REQUIRED: apply all filters before ORDER BY / LIMIT.
--
-- Dune parameters:
--   {{LIMIT}} (integer)
--   {{OFFSET}} (integer)
--   {{FURNACE_START_BLOCK}} (integer)  -- contract deployment/start block for performance filtering
--
-- Replace <DUNE_SCHEMA> with your decoded contract schema.

WITH base AS (
  SELECT
    "user",
    principalClaim
  FROM <DUNE_SCHEMA>.Furnace_evt_FurnaceEnter
  WHERE evt_block_number >= {{FURNACE_START_BLOCK}}
    AND evt_block_time >= date_add('day', -7, now())
    AND principalClaim > 0
),
agg AS (
  SELECT
    "user" AS address,
    SUM(principalClaim) AS claim_sent
  FROM base
  GROUP BY 1
)
SELECT
  address,
  claim_sent
FROM agg
ORDER BY claim_sent DESC, address
LIMIT {{LIMIT}}
OFFSET {{OFFSET}};
