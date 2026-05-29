-- ClaimRush v1.0.0 UI list
-- Recent reigns (finalized)
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
    reignId,
    king,
    startTime,
    endTime,
    totalClaimMined,
    totalEthToKing
  FROM <DUNE_SCHEMA>.MineCore_evt_ReignFinalized
  WHERE evt_block_number >= {{MINECORE_START_BLOCK}}
)
SELECT
  reignId,
  king,
  startTime,
  endTime,
  totalClaimMined,
  totalEthToKing
FROM base
ORDER BY endTime DESC, reignId DESC
LIMIT {{LIMIT}}
OFFSET {{OFFSET}};
