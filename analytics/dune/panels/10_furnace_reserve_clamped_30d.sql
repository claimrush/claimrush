-- ClaimRush v1.0.0 Panel
-- Furnace reserve clamped occurrences (last 30 days)
--
-- Shows cases where `furnaceReserve` accounting was clamped down to match the Furnace's
-- onchain CLAIM backing (excluding any remaining LP stream liability).
--
-- NOTE: The Solidity event parameter is `lpStreamLiability` (total LP stream obligation,
-- not just getLpStreamRemaining()). The subgraph renames this to `lpStreamRemaining`.
-- Dune decoded columns follow the ABI, so we use the Solidity name here.
--
-- Parameters:
--   {{LIMIT}} (integer)
--   {{OFFSET}} (integer)
--   {{FURNACE_START_BLOCK}} (integer)
-- Replace <DUNE_SCHEMA> with your decoded contract schema.

SELECT
  evt_block_time,
  evt_block_number,
  evt_tx_hash,
  caller,
  oldReserve,
  newReserve,
  claimBalance,
  lpStreamLiability
FROM <DUNE_SCHEMA>.Furnace_evt_ReserveClamped
WHERE evt_block_number >= {{FURNACE_START_BLOCK}}
  AND evt_block_time >= date_add('day', -30, now())
ORDER BY evt_block_time DESC, evt_block_number DESC, evt_tx_hash DESC, evt_index DESC
LIMIT {{LIMIT}} OFFSET {{OFFSET}};

