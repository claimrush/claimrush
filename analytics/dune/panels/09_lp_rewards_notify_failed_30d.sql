-- ClaimRush v1.0.0 Panel
-- Furnace LP rewards notify failures (last 30 days)
--
-- Shows cases where Furnace attempted `LpStakingVault7D.notifyRewards(amountClaim)` and it reverted,
-- but the Furnace swallowed the failure (best-effort) and emitted `LpRewardsNotifyFailed`.
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
  vault,
  amountClaim,
  revertData
FROM <DUNE_SCHEMA>.Furnace_evt_LpRewardsNotifyFailed
WHERE evt_block_number >= {{FURNACE_START_BLOCK}}
  AND evt_block_time >= date_add('day', -30, now())
ORDER BY evt_block_time DESC, evt_block_number DESC, evt_tx_hash DESC, evt_index DESC
LIMIT {{LIMIT}} OFFSET {{OFFSET}};

