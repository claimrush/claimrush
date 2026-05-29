# Deployments manifests (v1.0.0)

These manifests are REQUIRED for:
- application wiring
- analytics (Dune/subgraph) block filtering
- external integrators

## Why this exists
Dune queries and indexers need:
- contract addresses
- **start blocks** (deployment blocks) for efficient filtering
- Aerodrome pool/router/WETH addresses
- Chainlink ETH/USD feed address (for USD-denominated displays; UI/indexer-only)

## Source of truth

Hard rule:
- `deployments/<deploymentName>.json` is the single canonical source of truth.

All other deployment-manifest copies are auto-generated from the JSON:
- `deployments/<deploymentName>.md`
- `docs/deployments/<version>-<deploymentName>.md`
- Application-specific runtime copies (when present)

Regenerate:

```bash
bash scripts/sync_deployments_all.sh
```

CI enforcement:
- CI runs the generator and fails if any generated file would change (manifest drift).

## Update rule

- Update `deployments/<deploymentName>.json` immediately after deploying on the target network.
- Treat all values as public.
- Do not include leaderboard outputs; manifests contain configuration only.
- `protocolParams` MUST be present for every offchain-consumed constant.
- Manifest constants MUST match the deployed onchain configuration.
- After updating JSON, run:

```bash
bash scripts/sync_deployments_all.sh
```

## Start block guidance
- `startBlock` MUST be the block number of the deployment transaction for that address.
- For Dune performance, always filter:
  - `evt_block_number >= startBlock`
- Deterministic addresses are **not** the same thing as deployed contracts. In v1.0.0, the canonical Aerodrome WETH/CLAIM pool address is known before genesis finalization:
  - **Base Sepolia**: `Deploy.s.sol` auto-materializes the pool via `factory.createPool()` (chainId 84532 only), so the pool exists immediately after deployment.
  - **Base mainnet**: `Deploy.s.sol` pins the deterministic pool address up front, but `LaunchController.finalizeGenesis()` materializes the live pool and verifies that it matches the pinned address.
- Therefore:
  - On Sepolia, `aerodrome.claimWethPool.address` and `aerodrome.lpToken.address` may be filled in pre-genesis because the pool is created during deploy.
  - On Base mainnet, keep `aerodrome.claimWethPool.address`, `aerodrome.lpToken.address`, and both `startBlock` fields at zero until finalization succeeds and the pool has live code.
  - `aerodrome.claimWethPool.startBlock` and `aerodrome.lpToken.startBlock`:
    - On Sepolia: can be set to the `Deploy.s.sol` broadcast block (pool is created during deploy)
    - On mainnet: MUST remain `0` until finalization succeeds, then update from the finalization receipt block
  - `script/FinalizeGenesis.s.sol:FinalizeGenesis` is followed by one `script/Wire.s.sol:Wire` run so `FurnaceEntryTokenRegistry` binds the now-live canonical WETH/CLAIM hop

## Base mainnet update procedure

1) Deploy all v1.0.0 contracts on Base mainnet.
2) For each deployed address, read the deployment transaction receipt and record its `blockNumber`.
3) Update `deployments/base_mainnet.json`:
   - Set `generatedAtUtc`.
   - Set every deployed contract `address`.
   - Set every deployed contract `startBlock`.
   - Set Aerodrome addresses and their `startBlock` values.
   - For `aerodrome.claimWethPool` / `aerodrome.lpToken`: on Base mainnet, leave both `address = 0x0000000000000000000000000000000000000000` and `startBlock = 0` until genesis finalization succeeds, then fill them from the finalization receipt block. The Base Sepolia deploy-time pool behavior described above does not apply to the mainnet procedure.
   - Set Chainlink feed pins directly: `chainlink.ethUsdFeed.address`.
4) Run:

```bash
bash scripts/sync_deployments_all.sh
```
