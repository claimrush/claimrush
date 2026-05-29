-- ClaimRush v1.0.0 Leaderboard 6
-- Top veCLAIM holders (current snapshot)
--
-- Metric (per spec):
--   veBalance per address at the latest block (snapshot)
--
-- Timeframe:
--   Current snapshot only -- duration filter does NOT apply.
--
-- Dune reality:
-- - Dune dashboards should not rely on calling view functions.
-- - To compute "current ve by address", you need either:
--   A) a maintained snapshot table/view (recommended), OR
--   B) reconstruction from VeClaimNFT lock lifecycle events + ERC721 Transfer history (advanced).
--
-- REQUIRED: apply all filters before ORDER BY / LIMIT.
--
-- Dune parameters:
--   {{LIMIT}} (integer)
--   {{OFFSET}} (integer)
--   {{VECLAIMNFT_START_BLOCK}} (integer)  -- deployment/start block (used by your snapshot builder)
--
-- Replace <VE_SNAPSHOT_VIEW> with your implementation.
-- Expected shape:
--   <VE_SNAPSHOT_VIEW>(address, ve_balance, blockNumber, updatedAt)
--
-- Notes for building <VE_SNAPSHOT_VIEW>:
-- - Inputs:
--   - <DUNE_SCHEMA>.VeClaimNFT_evt_LockCreated (includes lockEnd + autoMax)
--   - <DUNE_SCHEMA>.VeClaimNFT_evt_LockAmountIncreased
--   - <DUNE_SCHEMA>.VeClaimNFT_evt_LockExtended
--   - <DUNE_SCHEMA>.VeClaimNFT_evt_AutoMaxSet
--   - <DUNE_SCHEMA>.VeClaimNFT_evt_LockMerged / LockUnlocked
--   - <DUNE_SCHEMA>.VeClaimNFT_evt_Transfer (ERC721 ownership)
-- - Output:
--   - latest ve per address at the latest block
-- - Filter for performance:
--   - evt_block_number >= {{VECLAIMNFT_START_BLOCK}}
--
-- Leaderboard query (consumes the snapshot)

WITH base AS (
  SELECT
    address,
    ve_balance
  FROM <VE_SNAPSHOT_VIEW>
)
SELECT
  address,
  ve_balance
FROM base
ORDER BY ve_balance DESC, address
LIMIT {{LIMIT}}
OFFSET {{OFFSET}};
