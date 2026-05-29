-- ClaimRush v1.0.0 Leaderboard 3
-- Most takeovers executed (24h count)
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
  SELECT newKing
  FROM <DUNE_SCHEMA>.MineCore_evt_Takeover
  WHERE evt_block_number >= {{MINECORE_START_BLOCK}}
    AND evt_block_time >= date_add('hour', -24, now())
),
agg AS (
  SELECT
    newKing AS address,
    COUNT(*) AS takeover_count
  FROM base
  GROUP BY 1
)
SELECT
  address,
  takeover_count
FROM agg
ORDER BY takeover_count DESC, address
LIMIT {{LIMIT}}
OFFSET {{OFFSET}};
