-- ClaimRush v1.0.0 Panel
-- Latest takeover (single row)

-- Parameters:
--   {{MINECORE_START_BLOCK}} (integer)
-- Replace <DUNE_SCHEMA> with your decoded contract schema.

SELECT
  reignId,
  previousKing,
  newKing,
  pricePaid,
  referencePrice,
  "timestamp" AS timestamp,
  evt_block_number,
  evt_block_time
FROM <DUNE_SCHEMA>.MineCore_evt_Takeover
WHERE evt_block_number >= {{MINECORE_START_BLOCK}}
ORDER BY evt_block_number DESC, evt_index DESC
LIMIT 1;
