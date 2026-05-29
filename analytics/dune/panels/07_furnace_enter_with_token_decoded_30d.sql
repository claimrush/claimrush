-- ClaimRush v1.0.0 Panel
-- Furnace enters (ENTER_WITH_TOKEN) with calldata decoding + observed ERC20 transfer
--
-- What this gives you:
-- - For FurnaceEnter events where mode = ENTER_WITH_TOKEN (3):
--   - tokenIn (decoded from tx calldata)
--   - amountIn (decoded from tx calldata)
--   - amountInObserved (sum of ERC20 transfers user -> furnace in same tx)
--
-- Dune parameters:
--   {{LIMIT}} (integer)
--   {{OFFSET}} (integer)
--   {{FURNACE_START_BLOCK}} (integer)  -- contract deployment/start block for performance filtering
--
-- Replace <DUNE_SCHEMA> with your decoded contract schema.
--
-- Notes:
-- - This checks two function selectors (pinned in the v1.0.0 repo mappings):
--   a) enterWithToken(address,uint256,uint256,uint256,bool,uint256)
--      selector: 0xbcbbebe1
--      calldata: [selector(4)][tokenIn(32)][amountIn(32)]...
--   b) enterWithTokenFromCallerFor(address,address,uint256,uint256,uint256,bool,uint256)
--      selector: 0xa2602c01
--      calldata: [selector(4)][user(32)][tokenIn(32)][amountIn(32)]...
--
-- - Calldata offsets (Dune varbinary_substring, 1-indexed):
--   enterWithToken:
--   - bytes 5..36  : arg0 (tokenIn) as 32-byte word (rightmost 20 bytes)
--   - bytes 37..68 : arg1 (amountIn) as uint256
--   enterWithTokenFromCallerFor:
--   - bytes 5..36  : arg0 (user) -- skip
--   - bytes 37..68 : arg1 (tokenIn) as 32-byte word (rightmost 20 bytes)
--   - bytes 69..100: arg2 (amountIn) as uint256

WITH enters AS (
  SELECT
    evt_block_time,
    evt_block_number,
    evt_tx_hash,
    contract_address AS furnace_address,
    "user" AS user_address,
    mode,
    ethIn,
    principalClaim,
    bonusClaim,
    tokenId
  FROM <DUNE_SCHEMA>.Furnace_evt_FurnaceEnter
  WHERE evt_block_number >= {{FURNACE_START_BLOCK}}
    AND mode = 3
    AND evt_block_time >= date_add('day', -30, now())
),

txs AS (
  SELECT
    hash,
    data
  FROM base.transactions
  WHERE block_number >= {{FURNACE_START_BLOCK}}
    AND hash IN (SELECT evt_tx_hash FROM enters)
    AND block_time >= date_add('day', -31, now())
),

decoded AS (
  SELECT
    e.*,
    CASE
      WHEN varbinary_substring(t.data, 1, 4) = 0xbcbbebe1 THEN varbinary_substring(t.data, 17, 20)
      WHEN varbinary_substring(t.data, 1, 4) = 0xa2602c01 THEN varbinary_substring(t.data, 49, 20)
      ELSE NULL
    END AS tokenIn,
    CASE
      WHEN varbinary_substring(t.data, 1, 4) = 0xbcbbebe1 THEN varbinary_to_uint256(varbinary_substring(t.data, 37, 32))
      WHEN varbinary_substring(t.data, 1, 4) = 0xa2602c01 THEN varbinary_to_uint256(varbinary_substring(t.data, 69, 32))
      ELSE NULL
    END AS amountIn
  FROM enters e
  LEFT JOIN txs t
    ON t.hash = e.evt_tx_hash
),

observed AS (
  SELECT
    d.evt_tx_hash,
    COALESCE(SUM(tr."value"), uint256 '0') AS amountInObserved
  FROM decoded d
  LEFT JOIN erc20_base.evt_transfer tr
    ON tr.evt_tx_hash = d.evt_tx_hash
    AND tr.contract_address = d.tokenIn
    AND tr."from" = d.user_address
    AND tr."to" = d.furnace_address
    AND tr.evt_block_time >= date_add('day', -31, now())
  GROUP BY 1
)

SELECT
  d.evt_block_time,
  d.evt_block_number,
  d.evt_tx_hash,
  d.user_address AS "user",
  d.tokenIn,
  tmeta.symbol AS token_symbol,
  tmeta.decimals AS token_decimals,
  d.amountIn,
  o.amountInObserved,
  CASE WHEN o.amountInObserved > uint256 '0' THEN o.amountInObserved ELSE d.amountIn END AS amountInCanonical,
  d.principalClaim,
  d.bonusClaim,
  d.ethIn,
  d.tokenId
FROM decoded d
LEFT JOIN observed o
  ON o.evt_tx_hash = d.evt_tx_hash
LEFT JOIN tokens.erc20 tmeta
  ON tmeta.blockchain = 'base'
  AND tmeta.contract_address = d.tokenIn
ORDER BY d.evt_block_time DESC, d.evt_block_number DESC, d.evt_tx_hash, d.tokenId
LIMIT {{LIMIT}}
OFFSET {{OFFSET}};
