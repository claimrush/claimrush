# Deployment archive

Historical manifests preserved for the audit trail. These are NOT used by any tool at runtime.

The live manifest for each network is the corresponding file one level up:
- `deployments/base_mainnet.json` — the current Base mainnet manifest.
- `deployments/base_sepolia.json` — the current Base Sepolia manifest.

Archived entries:

| File | Network | Deploy date | Status | Notes |
|---|---|---|---|---|
| `base_mainnet_apr14.json` | Base mainnet | 2026-04-14 | DECOMMISSIONED 2026-04-23 | Apr 14 protocol set. All 4 ProxyAdmins renounced (`owner() == 0x0`). All 4 `configFrozen == true` on immutable-setter contracts. Contracts remain on-chain but cannot be upgraded or reconfigured. Superseded by the May 3 09:00 EST fresh redeploy. |
