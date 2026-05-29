-- ClaimRush v1.0.0 Leaderboard 4
-- Top ETH spent on takeovers (30d)
--
-- Metric (per spec):
--   SUM(MineCore.Takeover.pricePaid) by newKing
--
-- REQUIRED: apply all filters before ORDER BY / LIMIT.
--
-- Dune parameters:
--   {{LIMIT}} (integer)
--   {{OFFSET}} (integer)
--   {{MINECORE_START_BLOCK}} (integer)  -- contract deployment/start block for performance filtering
--
-- Replace <DUNE_SCHEMA> with your decoded contract schema.
-- Preferred source: MineCore.Takeover event.

WITH base AS (
  SELECT
    newKing,
    pricePaid
  FROM <DUNE_SCHEMA>.MineCore_evt_Takeover
  WHERE evt_block_number >= {{MINECORE_START_BLOCK}}
    AND evt_block_time >= date_add('day', -30, now())
),
agg AS (
  SELECT
    newKing AS address,
    SUM(pricePaid) AS eth_spent
  FROM base
  GROUP BY 1
)
SELECT
  address,
  eth_spent
FROM agg
ORDER BY eth_spent DESC, address
LIMIT {{LIMIT}}
OFFSET {{OFFSET}};
