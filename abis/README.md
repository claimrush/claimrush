# ClaimRush ABIs

This folder contains ABI JSON arrays for ClaimRush v1.0.0 contract interfaces.

Until `deployments/base_mainnet.json` is filled with real (non-zero) addresses/start blocks, treat these ABI files as **target interfaces** (derived from the v1.0.0 specs/build outputs), not "deployed truth".


Source of truth
- `docs/spec/spec-v1.0.0.md` (deliverables and required deployed contracts)
- `docs/analytics/dune-integration-pack-v1.0.0.md` (canonical event schema used by indexers)
- `docs/spec/*-implementer-checklist-v1.0.0.md` (required external function surface per contract)

Rules
- Each `*.abi.json` file MUST be the raw ABI array (the JSON value of the `abi` field), not a full artifact.
- Subgraph manifests MUST reference these exported `abis/<network>/*.abi.json` files directly. Do not maintain event-only shadow copies under `subgraph/abis/`.
- Network folders are named `<chain>_<env>`.
  - Production Base mainnet: `base_mainnet/`
  - Staging/testnet Base Sepolia: `base_sepolia/`
- Keep ABIs in sync with the docs above. If docs and ABIs disagree, resolve per `docs/v1.0.0-index.md` source-of-truth rules, then regenerate ABIs from build outputs.

DexAdapter upgradeability note
- DexAdapter upgrade profile is defined in `docs/spec/dexadapter-implementer-checklist-v1.0.0.md`.
- If DexAdapter is deployed as a UUPS proxy, exported DexAdapter ABIs MUST include the UUPS upgrade surface.
- If DexAdapter is deployed without a proxy, exported DexAdapter ABIs MUST NOT include any UUPS upgrade functions.

Required Base mainnet ABIs (v1.0.0)
- `abis/base_mainnet/ClaimToken.abi.json`
- `abis/base_mainnet/VeClaimNFT.abi.json`
- `abis/base_mainnet/MineCore.abi.json`
- `abis/base_mainnet/MineCoreQuoter.abi.json`
- `abis/base_mainnet/ShareholderRoyalties.abi.json`
- `abis/base_mainnet/Furnace.abi.json`
- `abis/base_mainnet/FurnaceQuoter.abi.json`
- `abis/base_mainnet/LpStakingVault7D.abi.json`
- `abis/base_mainnet/MarketRouter.abi.json`
- `abis/base_mainnet/EntryTokenRegistry.abi.json`
- `abis/base_mainnet/DexAdapter.abi.json`
- `abis/base_mainnet/ClaimAllHelper.abi.json`
- `abis/base_mainnet/DelegationHub.abi.json`
- `abis/base_mainnet/GenesisLPVault24M.abi.json`
- `abis/base_mainnet/LaunchController.abi.json`
- `abis/base_mainnet/MaintenanceHub.abi.json`
- `abis/base_mainnet/AgentLens.abi.json`
- `abis/base_mainnet/TimelockController.abi.json`

Required Base Sepolia ABIs (v1.0.0)
- `abis/base_sepolia/ClaimToken.abi.json`
- `abis/base_sepolia/VeClaimNFT.abi.json`
- `abis/base_sepolia/MineCore.abi.json`
- `abis/base_sepolia/MineCoreQuoter.abi.json`
- `abis/base_sepolia/ShareholderRoyalties.abi.json`
- `abis/base_sepolia/Furnace.abi.json`
- `abis/base_sepolia/FurnaceQuoter.abi.json`
- `abis/base_sepolia/LpStakingVault7D.abi.json`
- `abis/base_sepolia/MarketRouter.abi.json`
- `abis/base_sepolia/EntryTokenRegistry.abi.json`
- `abis/base_sepolia/DexAdapter.abi.json`
- `abis/base_sepolia/ClaimAllHelper.abi.json`
- `abis/base_sepolia/DelegationHub.abi.json`
- `abis/base_sepolia/GenesisLPVault24M.abi.json`
- `abis/base_sepolia/LaunchController.abi.json`
- `abis/base_sepolia/MaintenanceHub.abi.json`
- `abis/base_sepolia/AgentLens.abi.json`
- `abis/base_sepolia/TimelockController.abi.json`

Note
- For v1.0.0, the Base Sepolia contract ABIs are expected to be identical to Base mainnet.

Consumer matrix
- The table below is the authoritative answer to "why does this ABI exist
  in the public repo?". Readers who grep for a contract name and find an
  orphan-looking ABI should consult this table before assuming it is dead
  code.

| ABI                           | Indexed by subgraph? | Consumed by SDK / keeper / scripts?                                               | Notes                                                                                 |
| ----------------------------- | -------------------- | --------------------------------------------------------------------------------- | ------------------------------------------------------------------------------------- |
| `MineCore`                    | Yes                  | SDK (read + write), keeper, scripts                                               | Core mining state; subgraph indexes events.                                           |
| `VeClaimNFT`                  | Yes                  | SDK, keeper (auto-compound)                                                       | Lock NFT; used for onchain reads and transfer/checkpoint events.                      |
| `ShareholderRoyalties`        | Yes                  | SDK, keeper (compound-shareholders)                                               | Shareholder payouts; subgraph indexes settlement + wiring events.                     |
| `Furnace`                     | Yes                  | SDK, keeper (auto-furnace)                                                        | Entry/sellback flow; subgraph indexes entries + bonus receipts.                       |
| `LpStakingVault7D`            | Yes                  | SDK, keeper (harvest + compound-lp)                                               | LP vault; subgraph indexes stake/harvest events.                                      |
| `MarketRouter`                | Yes                  | SDK, keeper (sweep-market + sweep-listings)                                       | Order routing; subgraph indexes listings and settlements.                             |
| `FurnaceEntryTokenRegistry`   | Yes                  | SDK (entry planning)                                                              | Entry token config; subgraph tracks allowed entry tokens.                             |
| `MineCoreEntryTokenRegistry`  | Yes                  | SDK (entry planning)                                                              | Per-pool entry token config; subgraph tracks allowed entry tokens.                    |
| `ClaimAllHelper`              | Yes                  | SDK (bundled ops), keeper                                                         | Bundled user operations; subgraph indexes delegation-session usage.                   |
| `DelegationHub`               | Yes                  | SDK (delegation flow), keeper                                                     | Session delegation; subgraph indexes `SessionSet`.                                    |
| `GenesisLPVault24M`           | Yes                  | SDK (read), scripts (deploy + verify)                                             | 24-month genesis LP custody; subgraph indexes lock state.                             |
| `LaunchController`            | Yes                  | Scripts (deploy + finalize genesis)                                               | One-shot launch orchestrator; subgraph indexes finalize events.                       |
| `MaintenanceHub`              | Yes                  | Keeper (`poke`), SDK                                                              | Scheduler for maintenance tasks; subgraph indexes execution events.                   |
| `ClaimToken`                  | No                   | SDK (balance reads, entry planning), scripts                                      | ERC-20 token surface only; no custom events to index beyond standard `Transfer`.      |
| `DexAdapter`                  | No                   | SDK (quotes), scripts (deploy), keeper (harvest quote)                            | Onchain router wrapper; quotes/amountsOut are reads, not events.                      |
| `TimelockController`          | No                   | Scripts (bootstrap + ownership transfer), governance tooling                      | OpenZeppelin timelock; governance activity is out of scope for the protocol subgraph. |
| `AgentLens`                   | No                   | SDK (agent read helpers)                                                          | Read-only aggregator; no events.                                                      |
| `MineCoreQuoter`              | No                   | SDK (quotes)                                                                      | Pure read-only view contract; no events.                                              |
| `FurnaceQuoter`               | No                   | SDK (quotes), scripts                                                             | Pure read-only view contract; no events.                                              |

Adding a new ABI
- Export via `scripts/export_abis.py`, add a row to the table above, and
  answer the "subgraph? / SDK / keeper?" columns before merging.

Furnace notes
- The canonical analytics event is `FurnaceEnter(user, mode, ethIn, principalClaim, bonusClaim, tokenId)`.
- There is a single `bonusClaim` field. There is no separate per user and LP bonus field in the event.
- LP top up behavior is surfaced via views (see the Furnace ABI):
  - `getFurnaceState().lpTopupRateBps`
  - `getFurnaceState().quoteLpTopupBps`
  - `getLpOverflowDripPerDay()`

Indexing notes
- Indexers that decode calldata MUST have `Furnace.enterWithToken(tokenIn, amountIn, ...)` in the ABI to recover `tokenIn` and `amountIn` for token entries.
- `MarketRouter.executeAutoFurnace` emits both `BonusTargetEscrowExecuted(...)` and `BonusTargetEscrowAutoFurnaceExecuted(...)`. ABI exports MUST retain both events so indexers can account for the canonical generic receipt and the back-compat companion receipt.
- `MineCore.FurnaceChanged`, `VeClaimNFT.FurnaceChanged`, `VeClaimNFT.MineMarketChanged`, `Furnace.MineCoreChanged`, `Furnace.MineMarketChanged`, `Furnace.ShareholderRoyaltiesChanged`, and `ShareholderRoyalties.ShareholderWiringSet` MUST remain in exported ABIs so the subgraph can keep `Protocol` wiring fields on the latest observed current addresses.
- `Furnace.LpStreamFunded(amountFunded, newRatePerSec, newPeriodFinish)` MUST remain in exported ABIs so indexers can reconstruct the live LP rewards stream schedule.

Updating
- Build artifacts (for example: `forge build`).
- Export ABIs:
  - `python3 scripts/export_abis.py --network base_mainnet --outdir abis/base_mainnet`
  - `python3 scripts/export_abis.py --network base_sepolia --outdir abis/base_sepolia`
- Spot check:
  - Event signatures match `docs/analytics/dune-integration-pack-v1.0.0.md`.
  - Function signatures match the per-contract `docs/spec/*-implementer-checklist-v1.0.0.md`.
