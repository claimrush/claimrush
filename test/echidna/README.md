# Echidna harness layout

This directory holds the property, assertion, optimization, and adversarial
harnesses driven by Echidna and Medusa. All harnesses share a single
`EchidnaSetup` deployment fixture mirrored from the canonical wiring in
`Wire.s.sol`.

## Categories

### Standard property/assertion harnesses

Drive `echidna_*` invariants in property mode (default `echidna.yaml`) and
`assert()` checks in assertion mode (operator-driven adversarial 24h sweeps
live in the private monorepo).

| Harness | Surface |
| --- | --- |
| `EchidnaClaimToken.sol` | `ClaimToken` ERC20 supply conservation, freeze, role gating |
| `EchidnaDelegationHub.sol` | `DelegationHub` permission grants, expiry, action gating |
| `EchidnaDexAdapter.sol` | `DexAdapter` token/ETH custody, allowance hygiene |
| `EchidnaEntryTokenRegistry.sol` | `EntryTokenRegistry` route resolution, guardian gating |
| `EchidnaFurnace.sol` | `Furnace` solvency, reserve, overdraft, spot bounds |
| `EchidnaGenesisLPVault24M.sol` | Genesis LP time-lock custody and fee-claim path |
| `EchidnaLpStaking.sol` | `LpStakingVault7D` LP custody, reward indexing, unbond lifecycle |
| `EchidnaMarketRouter.sol` | `MarketRouter` escrow conservation, listing index hygiene |
| `EchidnaMineCore.sol` + `_Extended.sol` | King takeover loop, royalty split, refund accounting |
| `EchidnaShareholder.sol` | `ShareholderRoyalties` index, claim, disjoint buckets |
| `EchidnaVeClaimNFT.sol` + `_Extended.sol` | `VeClaimNFT` lock math, ve-bias drift, transfer gating |
| `EchidnaGameLoop.sol` | Composite multi-contract game loop (gated by `scripts/check_echidna_coverage_acceptance.py`) |

### Adversarial composition harnesses

Drive misbehavior at the entry surfaces and at every ETH-receive callback.

| Harness | Mock | Attack class |
| --- | --- | --- |
| `EchidnaMaliciousERC20Entry.sol` | `MaliciousFeeOnTransferERC20`, `MaliciousRebaseERC20`, `MaliciousReentrantERC20` | Fee-on-transfer, rebase, transfer-callback reentrancy on entry tokens |
| `EchidnaReentrancyReceiver.sol` | `MaliciousReentrantReceiver` | Reentrant call back into MineCore / ShareholderRoyalties / MarketRouter on every ETH receive |
| `EchidnaMEVOrdering.sol` | none | Multi-actor sandwich, front-run, back-run, JIT list-and-pull |

Properties verify the protocol either rejects misbehavior cleanly or
delivers exactly the requested `minVeOut` / `minClaimOut` / `minEthOut`.
No silent shortfall.

### Optimization-mode harnesses

Drive `optimize_*` functions returning `int256` Echidna maximizes.
Live under `optimize/`. Each harness targets one value-paying surface.

| Harness | Targets |
| --- | --- |
| `optimize/EchidnaFurnaceOptimize.sol` | Reserve drain, bonus-bps cap, quote-vs-execute delta, balance deficit, actor CLAIM gain |
| `optimize/EchidnaMineCoreOptimize.sol` | Shareholder shortfall, King payout shortfall, ETH escrow deficit, takeover-price floor |
| `optimize/EchidnaShareholderOptimize.sol` | Stored-above-balance, bucket-sum-above-balance, claimed-above-accrued |
| `optimize/EchidnaMarketRouterOptimize.sol` | Escrow imbalance, inactive-offer funds, listing duplicates, actor CLAIM gain |
| `optimize/EchidnaLpStakingOptimize.sol` | `earned()`-above-balance, `queuedRewards`-above-balance, staked-above-LP, reward-sum drift |
| `optimize/EchidnaGenesisLPVault24MOptimize.sol` | LP custody deficit, unlock-time regression, absolute-lock ceiling |
| `optimize/EchidnaVeClaimNFTOptimize.sol` | `totalLockedClaim`-above-balance, NFT cap, ve-cache drift |
| `optimize/EchidnaClaimTokenOptimize.sol` | Supply drift, self-balance leak, sum-above-supply |
| `optimize/EchidnaEntryTokenRegistryOptimize.sol` | Route-resolution mismatch, guardian re-enable success, router rewire after freeze |

Every `optimize_*` value MUST stay `<= 0`. Positive values flag deviation
from the intended economic envelope and trigger triage.

## Drivers

The standard property and adversarial matrices, the optimization matrix,
and the Medusa matrix run automatically in CI on every PR (see the CI
table below).

Several operator-driven sweeps live in the private monorepo and are not
shipped to the public repo:

- **Adversarial 24h:** 24h assertion-mode sweep across all standard +
  adversarial harnesses.
- **Echidna optimization local sweep:** local equivalent of the public
  optimize CI matrix.
- **Medusa local sweep:** local Medusa parallel-fuzzer run; the local
  driver uses a custom Foundry+Medusa Docker image (the public CI uses
  the upstream image).
- **Echidna corpus seed from Foundry:** projects Foundry invariant traces
  into Echidna corpora.
- **Slither-mutate:** quarterly mutation-testing sweep on the
  highest-value surfaces.
- **Overnight orchestrator:** full nightly run (corpus seeding ->
  Echidna property -> optimization -> Medusa).

## Configs

| File | Drives |
| --- | --- |
| `echidna.yaml` | Standard property/assertion mode (13 standard + 3 adversarial gated; `EchidnaGameLoop` gated separately) |
| `echidna-optimize.yaml` | Optimization mode (9 surfaces under `optimize/`) |
| `medusa.json` | Medusa parallel runner (same harness set as Echidna) |

## CI

| Workflow | Behavior |
| --- | --- |
| `.github/workflows/echidna.yml` → `echidna` job | Gating; matrix over 13 standard + 3 adversarial harnesses |
| `.github/workflows/echidna.yml` → `echidna-optimize` job | Informational matrix over 9 optimization harnesses; promotes to gating after 30 days of stable runs |
| `.github/workflows/medusa.yml` | Informational matrix over the full harness set; promotes to gating after 30 days of stable runs |

## Coverage scope

Production contracts without dedicated Echidna harnesses are covered by
deterministic Foundry unit + invariant tests:

- `ClaimAllHelper` — stateless batch convenience router
- `LaunchController` — one-shot genesis finalization orchestrator
- `MaintenanceHub` — keeper-gated maintenance router
- `FurnaceQuoter` / `FurnaceGuardHelper` / `MineCoreHelper` /
  `MineCoreQuoter` — view/preview helpers (stateless)

Coverage rationale lives in [docs/security/ci-security-gates-v1.0.0.md](https://github.com/claimrush/claimrush/blob/main/docs/security/ci-security-gates-v1.0.0.md) § Echidna coverage (private monorepo).

## Companion: Halmos symbolic proofs

The Echidna stack searches for the worst-case observation. The Halmos
stack ([`test/halmos/`](../halmos/)) symbolically proves the same M1-M6
obligations across a bounded input domain. The two layers compose:
Halmos proves the obligation cannot be violated inside the domain;
Echidna optimization-mode harnesses look for an envelope deviation
outside the proved domain. See [`test/halmos/README.md`](../halmos/README.md).
