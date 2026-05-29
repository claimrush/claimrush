-- ClaimRush v1.0.0 Panel
-- Latest EntryTokenRegistry router config (two-registry model; 1 row per registry address)

-- Parameters:
--   {{ENTRY_TOKEN_REGISTRY_START_BLOCK}} (integer)
--     - Set this to the minimum deployed start block across registries for performance.
-- Replace <DUNE_SCHEMA> with your decoded contract schema.

WITH ranked AS (
  SELECT
    contract_address,
    router,
    factory,
    wrappedNative,
    claimToken,
    evt_block_number,
    evt_block_time,
    ROW_NUMBER() OVER (
      PARTITION BY contract_address
      ORDER BY evt_block_number DESC, evt_index DESC
    ) AS rn
  FROM <DUNE_SCHEMA>.EntryTokenRegistry_evt_RouterConfigSet
  WHERE evt_block_number >= {{ENTRY_TOKEN_REGISTRY_START_BLOCK}}
)
SELECT
  contract_address,
  router,
  factory,
  wrappedNative,
  claimToken,
  evt_block_number,
  evt_block_time
FROM ranked
WHERE rn = 1
ORDER BY contract_address;
