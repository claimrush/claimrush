# Dune templates (v1.0.0)

This folder contains copy/paste SQL templates for:
- 8 leaderboard templates (`leaderboards/`) — file numbers 01–08 match the canonical spec
  leaderboards #1–#8 in `docs/analytics/leaderboards-ui-and-dune-compatible-v1.0.0.md`
- the “recent reigns” UI list (`ui_lists/`)
- optional dashboard panels and small chart sources (`panels/`)

## Duration variants

Most leaderboards ship as 4 separate files:
- `*_24h.sql`
- `*_7d.sql`
- `*_30d.sql`
- `*_lifetime.sql`

Leaderboard #6 (“Top veCLAIM holders”) is snapshot-only:
- `06_top_barons_by_ve_current.sql`

## Setup

Before using these templates:
1) Fill `deployments/base_mainnet.json` after deployment.
   - Optional helper: `python3 scripts/render_dune_params.py deployments/base_mainnet.json` prints Dune parameter defaults (start blocks + optional panel params).
2) Decide how you will decode contracts on Dune:
   - Preferred: verify contracts on the Base explorer and import ABIs via Dune.
   - Fallback: publish ABI JSON arrays under `abis/base_mainnet/` and import manually.
3) Create a single Dune project and add all ClaimRush contract addresses to it.
   - This gives you one schema to reference as `<DUNE_SCHEMA>` in the templates.

Required parameters in most templates:
- `{{LIMIT}}` (integer)
- `{{OFFSET}}` (integer)
- contract start blocks (integers) for performance:
  - `{{MINECORE_START_BLOCK}}`
  - `{{FURNACE_START_BLOCK}}`
  - `{{SHAREHOLDER_ROYALTIES_START_BLOCK}}`
  - `{{VECLAIMNFT_START_BLOCK}}`

Additional start blocks used by optional panels:
- `{{ENTRY_TOKEN_REGISTRY_START_BLOCK}}`
  - Set to the minimum deployed start block across EntryTokenRegistry contracts (two-registry deployments)
- `{{MARKETROUTER_START_BLOCK}}`

Additional parameters used by optional panels:
- `{{FURNACE_LAUNCH_TIME}}` (timestamp)  -- Furnace launch timestamp
- `{{RESERVE_TARGET_FINAL_CLAIM}}` (integer)  -- protocolParams.furnace.reserveTargetFinalClaim (whole CLAIM)
- `{{SWING_TIME_SECONDS}}` (integer)  -- protocolParams.furnace.swingTimeSeconds (default: 5184000 = 60 days)
- `{{LP_STAKING_VAULT7D_START_BLOCK}}` (integer)  -- LP staking vault deployment block

One optional panel also requires the LP staking vault address:
- `{{LP_STAKING_VAULT_ADDRESS}}` (varbinary literal, e.g. `0x1234...`)


## FurnaceEnter mode enum

The `FurnaceEnter` event field `mode` encodes the entry path:

| mode | Name | Description |
|------|------|-------------|
| 0 | `ENTER_WITH_ETH` | Direct ETH entry |
| 1 | `ENTER_WITH_CLAIM` | Direct CLAIM entry |
| 2 | `LOCK_FURNACE` | Lock sold back to Furnace |
| 3 | `ENTER_WITH_TOKEN` | Entry via arbitrary ERC20 token |
| 4 | `EXTEND_WITH_BONUS` | AutoMax automatic bonus extension (keeper-driven) |

Mode 4 entries are emitted by keeper calls to auto-extend ve locks with accrued bonus. A separate
`AutoMaxBonusClaimed(user, tokenId, bonusClaim)` event is also emitted for activity-feed tracking.

## enterWithToken calldata decoding (required)

Some players enter the Furnace via `enterWithToken(...)` (event `FurnaceEnter` with `mode = 3`).
The canonical `FurnaceEnter` event does **not** include `tokenIn` / `amountIn` fields, so you must
recover them from the transaction calldata (and optionally cross-check via ERC20 transfers).

Template provided:
- `panels/07_furnace_enter_with_token_decoded_30d.sql`
  - decodes `tokenIn` + `amountIn` from `base.transactions.data`
  - computes `amountInObserved` from `erc20_base.evt_transfer` (user -> furnace)

## Furnace bonus + LP semantics (Dune)

You will see two Furnace events:

- `<DUNE_SCHEMA>.Furnace_evt_FurnaceEnter`
  - includes `principalClaim` and `bonusClaim` (net user bonus; headline UI number)
  - does not include the LP portion of a gross bonus

- `<DUNE_SCHEMA>.Furnace_evt_BonusPaid`
  - emitted when a non-zero bonus is drawn from reserve
  - includes:
    - `grossBonusClaim` (reserve spent)
    - `userBonusClaim` (user portion)
    - `lpTopupClaim` (LP portion)

LP streaming (v1.0.0+):
- `lpTopupClaim` and `<DUNE_SCHEMA>.Furnace_evt_LpOverflowDripPaid.dripAmount` represent CLAIM **funded into the Furnace LP stream**.
- Actual transfers to the vault happen over time and can be observed via:
  - `<DUNE_SCHEMA>.LpStakingVault7D_evt_LpRewardsNotified` (preferred), or
  - ERC20 transfers to the `lpRewardsVault` address.

Templates apply these semantics:

- Panel #04 (“Furnace bonus split (24h)”):
  - uses `BonusPaid` to split user bonus vs LP topup funding

- Panel #02/05 (Reserve estimate / health):
  - adds: `ReserveCredited.amount` + `LockSoldToFurnace.reserveAdd`
  - subtracts: `BonusPaid.grossBonusClaim` + `LpOverflowDripPaid.dripAmount`

Note: bonus-rate and headline "bonus received" metrics are exposed via panels only;
they are not part of the canonical 8-board leaderboard spec.

## Sellback (lock → liquid CLAIM)

When enabled, Furnace emits `<DUNE_SCHEMA>.Furnace_evt_LockSoldToFurnace`:

- `lockAmount`  -- underlying principal withdrawn from ve
- `claimOut`    -- liquid CLAIM paid to seller
- `reserveAdd`  -- net credited to `furnaceReserve`
- `lpReward`    -- funded into the LP stream (streamed to stakers over time)
- `spreadBps`, `bonusRefBpsUsed`, `lpSaleShareBps` are diagnostic fields for dashboards

Query hygiene rule (non-negotiable):
- Multi-row outputs should be computed in the query/indexer layer (never FE-only filtering).
- Apply all filters before ORDER BY / LIMIT / pagination.
- No address exclusions are applied in v1.0.0 leaderboards.

## Operational observability (optional)

Two optional panels help ops catch misconfigurations and accounting drift:

- `panels/09_lp_rewards_notify_failed_30d.sql`
  - Shows `Furnace_evt_LpRewardsNotifyFailed` occurrences (LP notify reverted but transfer succeeded).

- `panels/10_furnace_reserve_clamped_30d.sql`
  - Shows `Furnace_evt_ReserveClamped` occurrences (reserve accounting was clamped to onchain backing).
