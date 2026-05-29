-- ClaimRush v1.0.0 Leaderboard 1
-- Top CLAIM mined as King (24h)
--
-- Metric (per spec):
--   SUM(MineCore.ReignFinalized.totalClaimMined) by king
--
-- Notes:
-- - Uses finalized-in-window semantics (filter by ReignFinalized.evt_block_time; not prorated).
-- - The current King is counted only after their reign is finalized (emitted when dethroned).
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
    totalClaimMined
  FROM <DUNE_SCHEMA>.MineCore_evt_ReignFinalized
  WHERE evt_block_number >= {{MINECORE_START_BLOCK}}
    AND evt_block_time >= date_add('hour', -24, now())
),
agg AS (
  SELECT
    king AS address,
    SUM(totalClaimMined) AS claim_mined
  FROM base
  GROUP BY 1
)
SELECT
  address,
  claim_mined
FROM agg
ORDER BY claim_mined DESC, address
LIMIT {{LIMIT}}
OFFSET {{OFFSET}};
