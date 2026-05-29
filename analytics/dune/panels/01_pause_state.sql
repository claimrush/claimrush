-- ClaimRush v1.0.0 Panel
-- Latest pause states (single row)

-- Parameters:
--   {{MINECORE_START_BLOCK}} (integer)
--   {{FURNACE_START_BLOCK}} (integer)
--   {{MARKETROUTER_START_BLOCK}} (integer)
-- Replace <DUNE_SCHEMA> with your decoded contract schema.

WITH takeovers AS (
  SELECT paused
  FROM <DUNE_SCHEMA>.MineCore_evt_TakeoversPausedChanged
  WHERE evt_block_number >= {{MINECORE_START_BLOCK}}
  ORDER BY evt_block_number DESC, evt_index DESC
  LIMIT 1
),
locking AS (
  SELECT paused
  FROM <DUNE_SCHEMA>.Furnace_evt_LockingPausedChanged
  WHERE evt_block_number >= {{FURNACE_START_BLOCK}}
  ORDER BY evt_block_number DESC, evt_index DESC
  LIMIT 1
),
trading AS (
  SELECT paused
  FROM <DUNE_SCHEMA>.MarketRouter_evt_TradingPausedChanged
  WHERE evt_block_number >= {{MARKETROUTER_START_BLOCK}}
  ORDER BY evt_block_number DESC, evt_index DESC
  LIMIT 1
)
SELECT
  (SELECT paused FROM takeovers) AS takeovers_paused,
  (SELECT paused FROM locking) AS locking_paused,
  (SELECT paused FROM trading) AS trading_paused;
