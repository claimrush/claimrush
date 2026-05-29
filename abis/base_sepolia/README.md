# Base Sepolia ABIs

These ABI JSON arrays are intended to match the deployed ClaimRush v1.0.0 contracts on Base Sepolia.

Notes
- For v1.0.0, the Base Sepolia contract ABIs are expected to be identical to Base mainnet.
- The files are duplicated under `abis/base_sepolia/` to match the scope deliverables and to keep the analytics/indexer workflow network-scoped.

Rules
- Each `*.abi.json` file is the raw ABI array only.
- Canonical event shapes are defined in `docs/analytics/dune-integration-pack-v1.0.0.md`.

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
- `python3 scripts/export_abis.py --network base_sepolia --outdir abis/base_sepolia`
