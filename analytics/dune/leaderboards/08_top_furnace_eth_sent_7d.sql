-- ClaimRush v1.0.0 Leaderboard 8
-- Top ETH sent to Furnace (7d)
--
-- Metric (per spec):
--   SUM(Furnace.FurnaceEnter.ethIn) by user
--
-- Source: FurnaceEnter.user + FurnaceEnter.ethIn (preferred)
-- - This attributes ETH routed via ShareholderRoyalties.lockEthReward to the beneficiary user.
-- - Includes enterWithEth deposits (mode 0) and lockEthReward deposits (mode 2).
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
    ethIn
  FROM <DUNE_SCHEMA>.Furnace_evt_FurnaceEnter
  WHERE evt_block_number >= {{FURNACE_START_BLOCK}}
    AND evt_block_time >= date_add('day', -7, now())
    AND ethIn > 0
),
agg AS (
  SELECT
    "user" AS address,
    SUM(ethIn) AS eth_sent
  FROM base
  GROUP BY 1
)
SELECT
  address,
  eth_sent
FROM agg
ORDER BY eth_sent DESC, address
LIMIT {{LIMIT}}
OFFSET {{OFFSET}};
