-- ClaimRush v1.0.0 Panel
-- LP vault funding transfers without a matching LpRewardsNotified() in the same tx
--
-- Why this exists:
-- - Some funders (e.g. Furnace) transfer CLAIM into the LP vault and then call notifyRewards().
-- - notifyRewards() is expected to emit LpRewardsNotified(amountClaim).
-- - Upstream callers may swallow notifyRewards reverts to avoid DoS on unrelated flows (e.g. user locking).
--   In that case you can observe CLAIM transfers into the LP vault without a notify event in the same tx.
--
-- Parameters:
--   {{LIMIT}} (integer)
--   {{OFFSET}} (integer)
--   {{FURNACE_START_BLOCK}} (integer)               -- for ClaimToken_evt_Transfer
--   {{LP_STAKING_VAULT7D_START_BLOCK}} (integer)    -- for LpStakingVault7D_evt_LpRewardsNotified
--   {{LP_STAKING_VAULT_ADDRESS}} (varbinary literal, e.g. 0x1234...)
--
-- Replace <DUNE_SCHEMA> with your decoded contract schema.

WITH transfers_in AS (
  SELECT
    evt_block_time,
    evt_block_number,
    evt_tx_hash,
    "from" AS from_addr,
    "to" AS to_addr,
    value AS amount
  FROM <DUNE_SCHEMA>.ClaimToken_evt_Transfer
  WHERE evt_block_number >= {{FURNACE_START_BLOCK}}
    AND "to" = {{LP_STAKING_VAULT_ADDRESS}}
    AND evt_block_time >= date_add('day', -30, now())
),
tx_sums AS (
  SELECT
    evt_block_time,
    evt_block_number,
    evt_tx_hash,
    SUM(amount) AS claim_in,
    COUNT(*) AS n_transfers,
    MIN(from_addr) AS any_from
  FROM transfers_in
  GROUP BY 1, 2, 3
),
notified AS (
  SELECT DISTINCT evt_tx_hash
  FROM <DUNE_SCHEMA>.LpStakingVault7D_evt_LpRewardsNotified
  WHERE evt_block_number >= {{LP_STAKING_VAULT7D_START_BLOCK}}
    AND evt_block_time >= date_add('day', -30, now())
)
SELECT
  t.evt_block_time,
  t.evt_block_number,
  t.evt_tx_hash,
  t.claim_in,
  t.n_transfers,
  t.any_from
FROM tx_sums t
LEFT JOIN notified n ON n.evt_tx_hash = t.evt_tx_hash
WHERE n.evt_tx_hash IS NULL
ORDER BY t.evt_block_time DESC, t.evt_block_number DESC, t.evt_tx_hash
LIMIT {{LIMIT}} OFFSET {{OFFSET}};

