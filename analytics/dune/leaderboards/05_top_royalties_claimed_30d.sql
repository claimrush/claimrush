-- ClaimRush v1.0.0 Leaderboard 5
-- Top royalties claimed (30d)
--
-- Metric (per spec):
--   SUM(ShareholderRoyalties.ShareholderClaim.amountEth) by user
--
-- Notes:
-- - Includes both claim modes: ETH withdrawals (mode 0) and LOCK_FURNACE reinvests (mode 1).
--
-- REQUIRED: apply all filters before ORDER BY / LIMIT.
--
-- Dune parameters:
--   {{LIMIT}} (integer)
--   {{OFFSET}} (integer)
--   {{SHAREHOLDER_ROYALTIES_START_BLOCK}} (integer)  -- contract deployment/start block for performance filtering
--
-- Replace <DUNE_SCHEMA> with your decoded contract schema.

WITH base AS (
  SELECT
    "user",
    amountEth
  FROM <DUNE_SCHEMA>.ShareholderRoyalties_evt_ShareholderClaim
  WHERE evt_block_number >= {{SHAREHOLDER_ROYALTIES_START_BLOCK}}
    AND evt_block_time >= date_add('day', -30, now())
),
agg AS (
  SELECT
    "user" AS address,
    SUM(amountEth) AS eth_claimed
  FROM base
  GROUP BY 1
)
SELECT
  address,
  eth_claimed
FROM agg
ORDER BY eth_claimed DESC, address
LIMIT {{LIMIT}}
OFFSET {{OFFSET}};
