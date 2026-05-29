# Base mainnet ABIs

These ABI JSON arrays are intended to match the deployed ClaimRush v1.0.0 contracts on Base mainnet.

Rules
- Each `*.abi.json` file is the raw ABI array only.
- Canonical event shapes are defined in `docs/analytics/dune-integration-pack-v1.0.0.md`.
  - Canonical parameter types and indexed flags are pinned in:
    - `docs/spec/spec-v1.0.0.md` (§11.2 Events for analytics)
    - `docs/spec/maintenance-hub-spec-v1.0.0.md` (MaintenanceHub.Poked)

Repo guardrail
- `python3 scripts/check_abi_event_schema.py --network base_mainnet`

Checks
- Furnace
  - `FurnaceEnter(user, mode, ethIn, principalClaim, bonusClaim, tokenId)`
  - `getFurnaceState()` returns:
    - `reserve`
    - `lockedSupply`
    - `userSpotBonusBps`
    - `lpTopupRateBps`
    - `quoteUserBonusBps`
    - `quoteLpTopupBps`
    - `virtualDepth`
    - `lastUpdate`
- VeClaimNFT
  - `getLockInfo(tokenId)` returns `(amount, lockEnd, autoMax, listed)`
  - emits `LockCreated`, `LockExtended`, `LockAmountIncreased`, `LockMerged`, `LockUnlocked`, `AutoMaxSet`
- EntryTokenRegistry
  - emits `RouterConfigSet`, `WethClaimPoolSet`, `TokenConfigSet`, `TokenEnabledChanged`

Regenerating
- `forge build`
- `python3 scripts/export_abis.py --network base_mainnet --outdir abis/base_mainnet`
