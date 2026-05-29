# ClaimRush v1.0.0 deployment manifest (Base mainnet)

<!--
  AUTO-GENERATED FILE. DO NOT EDIT.
  Source of truth: deployments/base_mainnet.template.json
  Regenerate: bash scripts/sync_deployments_all.sh
-->

> ⚠️ Auto-generated from `deployments/base_mainnet.template.json`. Do not edit by hand.
> Regenerate with `bash scripts/sync_deployments_all.sh`.

This file is the human-readable deployment manifest for ClaimRush v1.0.0 on Base mainnet.

`deployments/base_mainnet.template.json` is canonical. This markdown file is generated from it.

Manifest validity on Base mainnet requires:
- Every REQUIRED address is non-zero.
- Every REQUIRED start block is non-zero.
- Every component not deployed in v1.0.0 remains unset (`0x00…` / `0`).

## Core contracts

| Component | Status | Address | Implementation | Proxy admin | Proxy admin owner | Start block |
|---|---|---:|---:|---:|---:|---:|
| ClaimToken | REQUIRED | `0x0000000000000000000000000000000000000000` | — | — | — | `0` |
| VeClaimNFT | REQUIRED | `0x0000000000000000000000000000000000000000` | — | — | — | `0` |
| MineCore | REQUIRED | `0x0000000000000000000000000000000000000000` | `0x0000000000000000000000000000000000000000` | `0x0000000000000000000000000000000000000000` | `0x0000000000000000000000000000000000000000` | `0` |
| ShareholderRoyalties | REQUIRED | `0x0000000000000000000000000000000000000000` | `0x0000000000000000000000000000000000000000` | `0x0000000000000000000000000000000000000000` | `0x0000000000000000000000000000000000000000` | `0` |
| Furnace | REQUIRED | `0x0000000000000000000000000000000000000000` | `0x0000000000000000000000000000000000000000` | `0x0000000000000000000000000000000000000000` | `0x0000000000000000000000000000000000000000` | `0` |
| LpStakingVault7D | REQUIRED | `0x0000000000000000000000000000000000000000` | — | — | — | `0` |
| MarketRouter | REQUIRED | `0x0000000000000000000000000000000000000000` | `0x0000000000000000000000000000000000000000` | `0x0000000000000000000000000000000000000000` | `0x0000000000000000000000000000000000000000` | `0` |
| FurnaceEntryTokenRegistry | REQUIRED | `0x0000000000000000000000000000000000000000` | — | — | — | `0` |
| MineCoreEntryTokenRegistry | REQUIRED | `0x0000000000000000000000000000000000000000` | — | — | — | `0` |
| DexAdapter | REQUIRED | `0x0000000000000000000000000000000000000000` | — | — | — | `0` |
| GameRouter | NOT DEPLOYED IN V1.0.0 (MUST remain unset) | `0x0000000000000000000000000000000000000000` | — | — | — | `0` |
| DelegationHub | REQUIRED | `0x0000000000000000000000000000000000000000` | — | — | — | `0` |
| ClaimAllHelper | REQUIRED | `0x0000000000000000000000000000000000000000` | — | — | — | `0` |

## Governance infrastructure

| Component | Address | Start block | Notes |
|---|---:|---:|---|
| TimelockController | `0x0000000000000000000000000000000000000000` | `0` | governance timelock (`minDelaySeconds = 172800`) |

## Aerodrome

| Component | Address | Start block | Notes |
|---|---:|---:|---|
| Wrapped native (WETH) | `0x4200000000000000000000000000000000000006` | `0` | token used for the ETH swap path |
| Aerodrome router | `0xcF77a3Ba9A5CA399B7c97c74d54e5b1Beb874E43` | `0` | used internally by DexAdapter (swap routing) |
| CLAIM/WETH pool | `0x0000000000000000000000000000000000000000` | `0` | Aerodrome v2 vAMM |
| LP token | `0x0000000000000000000000000000000000000000` | `0` | same as pool in many cases |

## Chainlink

| Feed | Address | Notes |
|---|---:|---|
| ETH/USD price feed | `0x71041dddad3595F9CEd3DcCFBe3D1F4b0a16Bb70` | used for USD-denominated displays (UI/indexer only) |

## Genesis infrastructure (required)

| Component | Address | Start block | Notes |
|---|---:|---:|---|
| LaunchController | `0x0000000000000000000000000000000000000000` | `0` | one-shot genesis controller (`finalizeGenesis`) |
| GenesisLPVault24M | `0x0000000000000000000000000000000000000000` | `0` | locks genesis LP 24 months; `lpWithdrawRecipient = 0xE12f0a3557309c225890dBa8D4a42f5300110554` |

Wiring / config:
- `GenesisLPVault24M.lpWithdrawRecipient` MUST match the manifest-declared LP withdrawal recipient.
- LP lock starts at genesis (`LaunchController.finalizeGenesis()`). `GenesisLPVault24M.extendLock(newUnlockTime)` exists but is not part of the v1.0.0 manifest requirements.

## MaintenanceHub (required)
`deployments/base_mainnet.template.json` MUST include `MaintenanceHub` under `contracts`.
| Component | Address | Start block | Notes |
|---|---:|---:|---|
| MaintenanceHub | `0x0000000000000000000000000000000000000000` | `0` |  |

Wiring / config:
- `MaintenanceHub.rescueRecipient` MUST match the manifest-declared rescue recipient.

## Auxiliary read helpers

| Component | Address | Start block |
|---|---:|---:|
| AgentLens | `0x0000000000000000000000000000000000000000` | `0` |
| FurnaceQuoter | `0x0000000000000000000000000000000000000000` | `0` |
| MineCoreQuoter | `0x0000000000000000000000000000000000000000` | `0` |

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
