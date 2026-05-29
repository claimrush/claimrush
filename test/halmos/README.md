# Halmos symbolic proofs

This directory holds the bounded symbolic proofs of the canonical M1-M6
accounting meta-properties from
[invariants-v1.0.0.md § 15](https://github.com/claimrush/claimrush/blob/main/docs/security/invariants-v1.0.0.md) (private monorepo).
Halmos explores all values inside the bounded input domain on each
`check_*` and proves the obligation cannot be violated.

The three verification layers compose:

- **Halmos (this directory)**: proves the obligation holds across a
  bounded symbolic input domain.
- **Foundry meta-property suites** (`test/invariants/*MetaProperties.t.sol`):
  fuzz the same obligation against the deployed contracts.
- **Echidna optimization-mode harnesses** (`test/echidna/optimize/`):
  search for the worst-case envelope deviation.

## Categories

### Cross-cutting bounded proofs

[`BoundedCriticalPathProofs.t.sol`](BoundedCriticalPathProofs.t.sol)
holds the seven launch-critical proofs that span more than one surface
(Furnace bonus floor / reserve solvency, AutoMax cursor preflight, ve
lock conservation, MarketRouter listing settlement, escrow close,
MineCore takeover bucketing, MineCore pause clamp). The bounded-proofs
driver script lives in the private operator monorepo; the matching
public-CI workflow is the meta-proofs matrix below.

### Per-surface M1-M6 matrix

One harness per value-paying surface. Each `check_*` carries a NatSpec
header naming the M-class it proves and the production function the
model mirrors.

| Surface | Harness |
| --- | --- |
| Furnace | [`Furnace_M1_M6_Proofs.t.sol`](Furnace_M1_M6_Proofs.t.sol) |
| MineCore | [`MineCore_M1_M6_Proofs.t.sol`](MineCore_M1_M6_Proofs.t.sol) |
| ShareholderRoyalties | [`ShareholderRoyalties_M1_M6_Proofs.t.sol`](ShareholderRoyalties_M1_M6_Proofs.t.sol) |
| MarketRouter | [`MarketRouter_M1_M6_Proofs.t.sol`](MarketRouter_M1_M6_Proofs.t.sol) |
| VeClaimNFT | [`VeClaimNFT_M1_M6_Proofs.t.sol`](VeClaimNFT_M1_M6_Proofs.t.sol) |
| LpStakingVault7D | [`LpStakingVault7D_M1_M6_Proofs.t.sol`](LpStakingVault7D_M1_M6_Proofs.t.sol) |
| GenesisLPVault24M | [`GenesisLPVault24M_M1_M6_Proofs.t.sol`](GenesisLPVault24M_M1_M6_Proofs.t.sol) |
| ClaimToken | [`ClaimToken_M1_M6_Proofs.t.sol`](ClaimToken_M1_M6_Proofs.t.sol) |
| EntryTokenRegistry | [`EntryTokenRegistry_M1_M6_Proofs.t.sol`](EntryTokenRegistry_M1_M6_Proofs.t.sol) |

Driver: [`scripts/run_halmos_meta_proofs.sh`](../../scripts/run_halmos_meta_proofs.sh).
Local single-surface invocation:
`bash scripts/run_halmos_meta_proofs.sh --surface=Furnace`. Local full-matrix
invocation: `bash scripts/run_halmos_meta_proofs.sh`.

### Model differential pinning

[`differential/`](differential/) holds Foundry differential tests that
pin the Halmos model helpers against the production source. Any
production refactor that touches a model-cited function must also
update the model in lockstep, and the differential test catches the
divergence before it silently invalidates the symbolic proof.

| Surface | Differential |
| --- | --- |
| Furnace | [`differential/Furnace_ModelDifferential.t.sol`](differential/Furnace_ModelDifferential.t.sol) |

Additional surfaces gain a differential file when their model helper
diverges from the cited production source in more than one line of
math.

## Technique

Halmos cannot symbolically execute the full deployed contracts under a
60s/branch budget. Each per-surface harness is a pure-function model:

1. **Bounded domain inputs.** Symbolic uints capped to `1e30` or smaller,
   bps to `Constants.BPS_DENOM`, durations to `[MIN_LOCK_DURATION,
   MAX_LOCK_DURATION]`, actor counts to `N = 2` or `N = 3`.
2. **Local model helpers.** Internal pure functions inside the harness
   mirror the production accounting math. Each model helper carries a
   NatSpec `@dev mirrors <ProductionFunction> in <path>:<line>` header.
   Where the production function is too branchy to model verbatim
   (notably `FurnaceGuardHelper.computeBonusAmmPayout`), the helper
   collapses to the canonical AMM kernel and the simplification is
   called out in NatSpec; differential coverage extends only to the
   verbatim-mirrored fragments.
3. **Single-assertion `check_*`.** Each `check_*` asserts one M-class
   obligation directly on the model output. Composite obligations split
   into separate `check_*` functions.
4. **`require` for bounding only.** `require` enforces the input
   domain. If the proof needs more bounding, the model gets tighter —
   the timeout never relaxes.

### Role-gating and floor-direction encoding

Role-gating gates (`onlyOwner`, `onlyMineCore`, the immutability
ratchets) and minimum-input floors (`MIN_LOCK_DURATION`,
`MIN_LOCK_AMOUNT`, `MIN_TOPUP_AMOUNT`, `MIN_EXTENSION_DURATION`,
`MIN_COMPOUND_INTERVAL`) are encoded as a single internal pure
`_<gate>(...)` function and exercised through split-branch
`check_*` functions:

- one check requires the input on the revert side and asserts
  `_<gate>(...) == true`;
- one check requires the input on the permit side and asserts
  `_<gate>(...) == false`.

The split-branch shape keeps the spec encoding non-circular: a
production refactor that drops a branch from a gate trips the
permit-side proof; a refactor that loosens a bound trips the
revert-side proof. The De Morgan compound `assert(reverts == !permitted)`
is intentionally avoided.

## Configuration

[`halmos.toml`](../../halmos.toml) at the repo root centralizes the loop
bound and solver timeouts:

```toml
[global]
loop = 2
solver-timeout-branching = 1000
solver-timeout-assertion = 60000
statistics = true
```

Per-driver scripts override only the contract / function selectors.

## Runtime budget

The full meta-proofs matrix (driven by
[`scripts/run_halmos_meta_proofs.sh`](../../scripts/run_halmos_meta_proofs.sh))
targets ≤ 15 minutes wall clock. CI splits into nine parallel jobs (one
per surface) so any single-surface budget overage stays isolated. If a
`check_*` times out, the model gets tighter — the timeout does not move.

## CI

Workflow: [`.github/workflows/halmos.yml`](../../.github/workflows/halmos.yml).
Halmos is pinned by `HALMOS_VERSION` in the workflow env (currently
`0.3.3`). Z3 is cached via `actions/cache` keyed on the pinned version.
The workflow runs on PRs touching `src/**`, `test/halmos/**`,
`halmos.toml`, or the driver script.

`continue-on-error: true` is set for the first 30 days after the
meta-proof matrix lands so failures are informational. Promote to
gating by removing `continue-on-error: true` once the matrix has run
stable in CI for 30 days.

In the private operator monorepo, `gates-security` includes both
`halmos-bounded-proofs` and `halmos-meta-proofs` as informational gates
(leading `-` ignores their exit code) for the same 30-day window.
Promote to gating by removing the leading `-` in the Makefile.

## Adding a new check

1. Pick the surface harness for the contract you are proving.
2. Pick the M-class your obligation falls under (or use an `Aux` prefix
   if it does not fit canonical M1-M6).
3. Add an `internal pure` model helper if the math is not already
   present, and cite the production source in NatSpec.
4. Add a `check_<surface><MClass><Obligation>(...)` function with a
   single assertion.
5. Run `bash scripts/run_halmos_meta_proofs.sh --surface=<Surface>` to
   confirm the proof passes.
6. If the model helper diverges from production in more than one line
   of math, add or extend a Foundry differential under `differential/`.

## Quality bar

- Every `check_*` MUST prove (Halmos exit 0, no counterexample) under
  the documented timeout.
- If a check cannot prove, mark it
  `// HALMOS: bounded-counterexample at <input>` and document the
  residual envelope in the harness NatSpec — the timeout does not
  relax.
- No `--match-test` skipping in CI. The full M1-M6 suite runs on every
  PR.
- A failing `check_*` against a real (non-bounding-error) counterexample
  halts the surface's commit, opens a Foundry test that reproduces
  against `master`, and surfaces for triage before any patch.

### Solver-bound exceptions

A small allowlist of `check_*` obligations is known to exceed the
documented solver budget on Z3 because the SMT lowering produces
QF_AUFBV `bvmul`/`bvudiv` over a symbolic dividend (a known
nonlinear-arithmetic decidability boundary, not a property defect).
These obligations are tracked explicitly in
`scripts/run_halmos_meta_proofs.sh::KNOWN_TIMEOUTS_<surface>` and each
entry MUST cite the Foundry differential or property test that pins
the same obligation concretely. The runner tolerates a `[TIMEOUT]`
on an allowlisted name as a bounded solver-budget event but still
fails the stage on:

- Any `[TIMEOUT]` whose function name is not in the allowlist (a new
  obligation has hit the boundary and needs to be either tightened or
  added to the allowlist with a concrete-coverage citation).
- Any `[FAIL]` / `[ERROR]` / `Counterexample` line (a real symbolic
  violation, regardless of allowlist status).

Current allowlist (Furnace surface):

| Obligation                                              | Concrete pin                                                                                                       |
| ------------------------------------------------------- | ------------------------------------------------------------------------------------------------------------------ |
| `check_furnaceM1PrincipalEffMonotonicInWeightDelta`     | `test/halmos/differential/Furnace_ModelDifferential.t.sol::testFuzz_modelPrincipalEffMatchesMulDiv` (10k+ runs).   |
| `check_furnaceM4PrincipalEffSplitNeverExceedsWhole`     | Same differential + `test/Furnace_ExtendWithBonusPathIndependence.t.sol::test_CyclingDoesNotInflateBaseline`.      |

Removing an entry from the allowlist is a one-way ratchet: do it as
soon as a property rewrite lets the symbolic prover converge so the
boundary is documented honestly.

See also:

- [invariants-v1.0.0.md § 15](https://github.com/claimrush/claimrush/blob/main/docs/security/invariants-v1.0.0.md) (private monorepo)
- [ci-security-gates-v1.0.0.md § Halmos](https://github.com/claimrush/claimrush/blob/main/docs/security/ci-security-gates-v1.0.0.md) (private monorepo)
- [foundry-test-plan-v1.0.0.md § Halmos](https://github.com/claimrush/claimrush/blob/main/docs/dev/foundry-test-plan-v1.0.0.md) (private monorepo)
- [`test/echidna/README.md`](../echidna/README.md)
