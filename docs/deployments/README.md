# docs/deployments/README.md

This folder contains the **docs-only canonical deployment manifests** for ClaimRush.

This folder is **generated** from the repo-root deployment manifests:
- `deployments/*.json` (machine-readable source of truth)

Why this exists:
- Many specs reference the deployment manifest as the source of truth for **contract addresses** and **start blocks**.
- When viewing documentation in isolation (only `docs/`), the repo-root `deployments/` folder may not be available.
- A canonical "here are the addresses" page is a core anti-phishing and user verification rail.

Hard rule:
- The network docs in this folder MUST match `deployments/<deploymentName>.json` for all shared fields:
  - `chainId`
  - contract addresses
  - runtime proxy metadata for `MineCore`, `Furnace`, `MarketRouter`, and `ShareholderRoyalties` (`address`, `implementation`, `proxyAdmin`)
  - `startBlock` values
  - third-party pins (Aerodrome, Chainlink)
  - protocol params consumed by offchain components

## Canonical manifests (v1.0.0)

- **Production (Base mainnet)**
  - Deployment name: `base_mainnet`
  - Chain ID: `8453`
  - Canonical docs manifest: [v1.0.0-base_mainnet.md](./v1.0.0-base_mainnet.md)

- **Production (Base mainnet)**
  - Deployment name: `base_mainnet.template`
  - Chain ID: `8453`
  - Canonical docs manifest: [v1.0.0-base_mainnet.template.md](./v1.0.0-base_mainnet.template.md)

- **Staging/testnet (Base Sepolia)**
  - Deployment name: `base_sepolia`
  - Chain ID: `84532`
  - Canonical docs manifest: [v1.0.0-base_sepolia.md](./v1.0.0-base_sepolia.md)

- **Network (local)**
  - Deployment name: `local`
  - Chain ID: `31337`
  - Canonical docs manifest: [v1.0.0-local.md](./v1.0.0-local.md)

## How to use this for verification (anti-phishing)

- Verify you are on the intended chain (chainId).
- Compare the in-app **About / Security** contract list to the relevant page in this folder.
- For the runtime quartet, treat `.contracts.<Name>.address` as the live proxy address users and integrations should call. `implementation` and `proxyAdmin` are governance metadata.
- If any address is `0x0000000000000000000000000000000000000000`, treat it as **not set**.
