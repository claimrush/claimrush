# ClaimRush v1.0.0 deployment manifest (Local)

<!--
  AUTO-GENERATED FILE. DO NOT EDIT.
  Source of truth: deployments/local.json
  Regenerate: bash scripts/sync_deployments_all.sh
-->

> ⚠️ Auto-generated from `deployments/local.json`. Do not edit by hand.
> Regenerate with `bash scripts/sync_deployments_all.sh`.

This file is the human-readable deployment manifest for ClaimRush v1.0.0 on Local.

`deployments/local.json` is canonical. This markdown file is generated from it.

Manifest validity on Local requires:
- Every REQUIRED address is non-zero.
- For local manifests, startBlock MAY be `0` on ephemeral chains, but persisted mirrors should be refreshed from the latest deployment output.
- Every component not deployed in v1.0.0 remains unset (`0x00…` / `0`).

## Core contracts

| Component | Status | Address | Implementation | Proxy admin | Proxy admin owner | Start block |
|---|---|---:|---:|---:|---:|---:|
| ClaimToken | REQUIRED | `0x5FbDB2315678afecb367f032d93F642f64180aa3` | — | — | — | `1` |
| VeClaimNFT | REQUIRED | `0xe7f1725E7734CE288F8367e1Bb143E90bb3F0512` | — | — | — | `3` |
| MineCore | REQUIRED | `0x610178dA211FEF7D417bC0e6FeD39F05609AD788` | `0x8A791620dd6260079BF849Dc5567aDC3F2FdC318` | `0x6F1216D1BFe15c98520CA1434FC1d9D57AC95321` | `0xf39Fd6e51aad88F6F4ce6aB8827279cffFb92266` | `3` |
| ShareholderRoyalties | REQUIRED | `0xCf7Ed3AccA5a467e9e704C703E8D87F634fB0Fc9` | `0x9fE46736679d2D9a65F0992F2272dE9f3c7fa6e0` | `0xd8058efe0198ae9dD7D563e1b4938Dcbc86A1F81` | `0xf39Fd6e51aad88F6F4ce6aB8827279cffFb92266` | `3` |
| Furnace | REQUIRED | `0x0165878A594ca255338adfa4d48449f69242Eb8F` | `0x5FC8d32690cc91D4c39d9d3abcBD16989F875707` | `0x3B02fF1e626Ed7a8fd6eC5299e2C54e1421B626B` | `0xf39Fd6e51aad88F6F4ce6aB8827279cffFb92266` | `3` |
| LpStakingVault7D | REQUIRED | `0xc5a5C42992dECbae36851359345FE25997F5C42d` | — | — | — | `9` |
| MarketRouter | REQUIRED | `0x2279B7A0a67DB372996a5FaB50D91eAA73d2eBe6` | `0xa513E6E4b8f2a923D98304ec87F64353C4D5C853` | `0x94099942864EA81cCF197E9D71ac53310b1468D8` | `0xf39Fd6e51aad88F6F4ce6aB8827279cffFb92266` | `3` |
| FurnaceEntryTokenRegistry | REQUIRED | `0x9A676e781A523b5d0C0e43731313A708CB607508` | — | — | — | `3` |
| MineCoreEntryTokenRegistry | REQUIRED | `0x0B306BF915C4d645ff596e518fAf3F9669b97016` | — | — | — | `4` |
| DexAdapter | REQUIRED | `0x3Aa5ebB10DC797CAC828524e59A333d0A371443c` | — | — | — | `6` |
| GameRouter | NOT DEPLOYED IN V1.0.0 (MUST remain unset) | `0x0000000000000000000000000000000000000000` | — | — | — | `0` |
| DelegationHub | REQUIRED | `0x0DCd1Bf9A1b36cE34237eEaFef220932846BCD82` | — | — | — | `3` |
| ClaimAllHelper | REQUIRED | `0xA51c1fc2f0D1a1b8494Ed1FE312d7C3a78Ed91C0` | — | — | — | `3` |

## Governance infrastructure

| Component | Address | Start block | Notes |
|---|---:|---:|---|
| TimelockController | `0xB7f8BC63BbcaD18155201308C8f3540b07f84F5e` | `4` | governance timelock (`minDelaySeconds = 0`); bootstrap admin = `0xf39Fd6e51aad88F6F4ce6aB8827279cffFb92266`; proposer = `0xf39Fd6e51aad88F6F4ce6aB8827279cffFb92266`; executor = `0xf39Fd6e51aad88F6F4ce6aB8827279cffFb92266` |

## Aerodrome

| Component | Address | Start block | Notes |
|---|---:|---:|---|
| Wrapped native (WETH) | `0x959922bE3CAee4b8Cd9a407cc3ac1C251C2007B1` | `5` | token used for the ETH swap path |
| Aerodrome router | `0x68B1D87F95878fE05B998F19b66F4baba5De1aed` | `6` | used internally by DexAdapter (swap routing) |
| CLAIM/WETH pool | `0x59b670e9fA9D0A427751Af201D676719a970857b` | `7` | Aerodrome v2 vAMM |
| LP token | `0x59b670e9fA9D0A427751Af201D676719a970857b` | `7` | same as pool in many cases |

## Chainlink

| Feed | Address | Notes |
|---|---:|---|
| ETH/USD price feed | `0x0000000000000000000000000000000000000000` | used for USD-denominated displays (UI/indexer only) |

## Genesis infrastructure (required)

| Component | Address | Start block | Notes |
|---|---:|---:|---|
| LaunchController | `0x67d269191c92Caf3cD7723F116c85e6E9bf55933` | `9` | one-shot genesis controller (`finalizeGenesis`) |
| GenesisLPVault24M | `0x09635F643e140090A9A8Dcd712eD6285858ceBef` | `8` | locks genesis LP 24 months; `lpWithdrawRecipient = 0xf39Fd6e51aad88F6F4ce6aB8827279cffFb92266` |

Wiring / config:
- `GenesisLPVault24M.lpWithdrawRecipient` MUST match the manifest-declared LP withdrawal recipient.
- LP lock starts at genesis (`LaunchController.finalizeGenesis()`). `GenesisLPVault24M.extendLock(newUnlockTime)` exists but is not part of the v1.0.0 manifest requirements.

## MaintenanceHub (required)
`deployments/local.json` MUST include `MaintenanceHub` under `contracts`.
| Component | Address | Start block | Notes |
|---|---:|---:|---|
| MaintenanceHub | `0x5081a39b8A5f0E35a8D959395a630b68B74Dd30f` | `25` | `rescueRecipient = 0xf39Fd6e51aad88F6F4ce6aB8827279cffFb92266` |

Wiring / config:
- `MaintenanceHub.rescueRecipient` MUST match the manifest-declared rescue recipient.

## Auxiliary read helpers

| Component | Address | Start block |
|---|---:|---:|
| AgentLens | `0xdbC43Ba45381e02825b14322cDdd15eC4B3164E6` | `27` |
| FurnaceQuoter | `0x70e0bA845a1A0F2DA3359C97E0285013525FFC49` | `16` |
| MineCoreQuoter | `0xE6E340D132b5f46d1e472DebcD681B2aBc16e57E` | `10` |

## Protocol params (Furnace)

| Param | Value | Units / notes |
|---|---:|---|
| `maxUserBonusBps` | `10000` | basis points (100%) |
| `lpTopupRateMinBps` | `750` | basis points (7.5%) |
| `lpTopupRateMaxBps` | `1500` | basis points (15%) |
| `lockTargetClaim` | `120000000` | compatibility field; bonus uses lock% targets |
| `lockPctTargetBps` | `700` | basis points (7.0%) |
| `lockPctMinForBoostCapBps` | `500` | basis points (5%) |
| `lockPctFullBoostCapBps` | `2000` | basis points (20%) |
| `reserveTargetFinalClaim` | `20000000` | CLAIM (whole tokens) target reserve at end of run |
| `reserveMultMaxBpsLowLock` | `15000` | basis points (1.5x) |
| `reserveMultMaxBps` | `20000` | basis points (2.0x) |
| `swingTimeSeconds` | `5184000` | seconds (60 days) |
| `bonusDecayWindowSeconds` | `10800` | seconds (3 hours) |
| `sellSpreadFloor7dBps` | `120` | basis points (1.2% at 7d) |

## Analytics config

- No address exclusions are applied in v1.0.0 leaderboards.
