# LaunchController implementer checklist (v1.0.0)

This is an **implementer-focused checklist** for the protocol-enforced genesis finalization orchestrator (`LaunchController`).

Reference contract: `src/genesis/LaunchController.sol`.

Source of truth:
- Contract spec (canonical): `docs/spec/launch-controller-spec-v1.0.0.md`
- Genesis overview: `docs/spec/spec-v1.0.0.md` §1.2
- Aerodrome bootstrap: [Aerodrome liquidity bootstrap appendix](../architecture/aerodrome-liquidity-bootstrap-appendix-v1.0.0.md)
- Vault (genesis LP lock): `docs/spec/vault-spec.md`
Spec aids (recommended):
- `docs/spec/spec-quality-standard-v1.0.0.md`
- `docs/spec/state-machines-v1.0.0.md`

This document **does not introduce new rules**. It restates MUST/MUST NOT requirements in an order suitable for incremental implementation and review.

---

## Goals

LaunchController MUST:
- Finalize genesis **exactly once** (one-shot).
- Restrict `finalizeGenesis()` to immutable `guardian` (guardian-only operational trigger).
- Require the caller to provide **exactly** `requiredSeedEth` via `msg.value` (50 ether on mainnet; proportionally scaled for shorter genesis durations: `MAINNET_GENESIS_SEED_ETH * duration / MAINNET_GENESIS_DURATION`).
- Materialize the 10-day **King-stream** genesis accrual from MineCore into LaunchController.
- Seed Aerodrome v2 **WETH/CLAIM volatile** liquidity with:
  - the required seed ETH (caller funded; see Goals for scaling)
  - the `CLAIM` amount materialized by `MineCore.collectGenesisKingClaim(address(this))` in the same transaction
- Mint the LP token **directly** to `GenesisLPVault24M`.
- Start the 24-month LP lock in `GenesisLPVault24M`.
- Unpause takeovers (activate the game).

LaunchController MUST NOT:
- Have an `owner()` / OpenZeppelin-style admin surface (no `Ownable`).
- Act as a treasury (no discretionary protocol spending beyond the one-shot genesis orchestration).
- Provide **permissionless** token/ETH recovery or arbitrary withdrawals.
- Provide any path to re-run `finalizeGenesis()` or redirect canonical genesis seed economics after the one-shot.

**Clarification (reference implementation):** bounded internal donation handling during `finalizeGenesis()` is allowed. The controller MAY skim unexpected pool donations to `guardian` and MAY internally sweep residual `CLAIM`, `WETH`, and LP balances to `guardian` before the one-shot completes. It MUST NOT expose reusable external `sweepToken`, `sweepETH`, `recover*`, `rescue*`, `withdraw*`, `receive()`, or `fallback()` surfaces.

---

## Checklist: required wiring (immutables / config)

From `launch-controller-spec-v1.0.0.md` §2:

Deploy LaunchController with immutable references to:
- `ClaimToken` (CLAIM)
- `MineCore`
- `GenesisLPVault24M`
- `DexAdapter` (wired into the historical `aerodromeRouter` constructor slot)

Required constructor fail-closed checks:
- reject zero-address wiring for `_claim`, `_mineCore`, `_genesisLpVault`, `_aerodromeRouter`, `_guardian`
- require code at `_claim`, `_mineCore`, `_genesisLpVault`, `_aerodromeRouter`
- require `MineCore.claim() == CLAIM`
- require `DexAdapter.weth()` and `DexAdapter.defaultFactory()` to be non-zero contracts
- require `DexAdapter.poolFor(WETH, CLAIM, false, factory)` to be non-zero and to equal `GenesisLPVault24M.pool()`

Required cached immutables/state:
- Cache `weth = dexAdapter.weth()` and `factory = dexAdapter.defaultFactory()` immutably at construction.
- Precompute and store `expectedPool` using `dexAdapter.poolFor(WETH, CLAIM, stable=false, factory)`.
- `finalizeGenesis()` should keep using the cached `factory`; do not re-bind the canonical pool to a later adapter `defaultFactory()` value.
- Minimal one-shot state (REQUIRED):
  - `bool public genesisFinalized`
  - `uint256 public genesisFinalizedAt`
  - `uint256 public genesisClaimMinted`
  - `uint256 public genesisClaimToLiquidity`
  - `uint256 public genesisLpMinted`

---

## Checklist: finalizeGenesis() preconditions (MUST revert)

From `launch-controller-spec-v1.0.0.md` §4.1:

`finalizeGenesis()` MUST revert unless all are true:
- `genesisFinalized == false`
- `msg.sender == guardian`
- `msg.value == requiredSeedEth` (exact; `MAINNET_GENESIS_SEED_ETH * duration / MAINNET_GENESIS_DURATION`)
- `block.timestamp >= MineCore.emissionStartTime() + MineCore.GENESIS_ACCRUAL_DURATION()` (chain-gated, set at initialization: 10 days on Base mainnet, 1 day on testnets/local)
- `MineCore.takeoversPaused() == true`

Constructor invariants already enforced (REQUIRED):
- zero-address / code-less wiring is rejected before deployment can succeed
- `MineCore.claim() == CLAIM`
- cached `weth` / `factory` are non-zero contracts
- `GenesisLPVault24M.pool() == expectedPool` at construction

Pool pre-seed guard (REQUIRED):
- If the expected pool already exists, LaunchController MUST enforce:
  - `IERC20(pool).totalSupply() == 0`
- If LP supply is non-zero: MUST revert with local `PoolNotEmpty()` (declared on `LaunchController` in the reference implementation).
- If donated pool balances remain material after an attempted `skim(guardian)`: MUST revert with local `PoolDonationRemains()`.

Required runtime rechecks:
- `GenesisLPVault24M(genesisLpVault).pool() == expectedPool`
- `IDexAdapter(aerodromeRouter).weth() == weth`
- `expectedPool == IDexAdapter(aerodromeRouter).poolFor(WETH, CLAIM, false, factory)`

---

## Checklist: finalizeGenesis() deterministic execution steps (ordering)

From `launch-controller-spec-v1.0.0.md` §4.1.

`finalizeGenesis()` MUST be `external payable nonReentrant` and follow this sequence:

Revert surface (reference): `Errors.NotAuthorized` (caller not `guardian`), `Errors.GenesisAlreadyFinalized`, `Errors.GenesisExactSeedRequired` (`msg.value != requiredSeedEth`), `Errors.GenesisAccrualWindowNotComplete`, `Errors.GenesisMustBePaused`, `Errors.GenesisPoolMismatch`, `Errors.GenesisWethMismatch`, `Errors.GenesisNoClaimForLiquidity`, plus local `PoolNotEmpty()` / `PoolDonationRemains()`.

1) **Mark one-shot state (CEI)**
- Set `genesisFinalized = true` before external calls.

2) **Pre-seed pool guard (before CLAIM materialization)**
- Call `_ensureEmptyOrSkim(expectedPool)` to clear any donations at the deterministic pool address.
- If the pool exists with zero LP supply but has stray `CLAIM`/`WETH`, attempt `pool.skim(guardian)`.
- If donated balances remain material after skim, revert (`PoolDonationRemains()`).

3) **Materialize the genesis King-stream CLAIM into LaunchController**
- Call `MineCore.collectGenesisKingClaim(address(this))`.
- Enforce MineCore’s pinned behavior:
  - MUST revert if called before `T0 + GENESIS_ACCRUAL_DURATION`.
  - MUST be one-shot.
  - MUST be called by the canonical LaunchController contract itself; MineCore rejects EOAs and unrelated contract guardians even if they are the current guardian.
  - MUST mint the deterministic King-stream integral over `[T0, T0 + GENESIS_ACCRUAL_DURATION)`.

4) **Seed Aerodrome WETH/CLAIM volatile liquidity (direct pool mint)**
- Let `claimForLiquidity = genesisClaimMinted` (equivalently, the `CLAIM` balance delta created by `collectGenesisKingClaim`).
- MUST NOT use the entire `CLAIM.balanceOf(address(this))`, because donated/pre-existing controller `CLAIM` is excluded from the canonical genesis seed and is swept to `guardian` after finalization.
- Require `claimForLiquidity > 0`.
- Re-check `dexAdapter.weth()` and require it still equals the cached immutable `weth`.
- Resolve (or create) the pool via the cached immutable `factory` from construction (do not re-read adapter `defaultFactory()` here).
- Enforce:
  - canonical address (recommended): `pool == expectedPool`
  - second pre-seed guard: `_ensureEmptyOrSkim(pool)` after pool creation to catch donations between steps 2 and 4
- Transfer both seed assets into the pool:
  - transfer `claimForLiquidity` CLAIM to the pool
  - wrap ETH to WETH and transfer `requiredSeedEth` WETH to the pool
- Mint LP directly to the vault:
  - `liquidity = pool.mint(genesisLpVault)`

5) **Start the 24-month LP lock**
- Call `GenesisLPVault24M.startLock()`.

6) **Unpause takeovers (activate the game)**
- Call `MineCore.setTakeoversPaused(false)`.

7) **Rotate MineCore guardian**
- Call `MineCore.setGuardian(guardian)` to rotate from this defunct controller to the operational guardian.

8) **Emit event + record transparency state (REQUIRED)**
- Record `genesisFinalizedAt = block.timestamp`.
- Record the genesis amounts: `genesisClaimMinted`, `genesisClaimToLiquidity`, `genesisLpMinted`.
- Emit `GenesisFinalized(...)`.

9) **Sweep residual donations (REQUIRED)**
- Sweep any residual `CLAIM`, `WETH`, and LP token balances held by LaunchController to `guardian`.

Post-mint balance cross-check (MUST):
- After `pool.mint(genesisLpVault)`, verify `IERC20(pool).balanceOf(genesisLpVault) >= lpMinted`.
- If the check fails, revert with `Errors.GenesisLpBalanceMismatch()`.

Postconditions (recommended checks):
- LaunchController holds `0` CLAIM, `0` WETH, `0` LP.
- `GenesisLPVault24M.lockStartTime != 0`.
- `MineCore.takeoversPaused == false`.

---

## Checklist: events

From `launch-controller-spec-v1.0.0.md` §5.

LaunchController MUST emit:
- `GenesisFinalized(timestamp, claimMinted, claimToLiquidity, lpMinted, pool, genesisLpVault)`

**Additional events (reference `src/genesis/LaunchController.sol`):**
- `DeploymentValidated(address indexed claim, address indexed mineCore, address genesisLpVault, address guardian, address expectedPool)` — emitted from the constructor after wiring/pool validation (only `claim` and `mineCore` are indexed topics; `genesisLpVault`, `guardian`, and `expectedPool` are non-indexed log data).
- `TokenSwept(address indexed token, address indexed to, uint256 amount)` — emitted only from bounded internal cleanup during `finalizeGenesis()`.
- `SkimFailed(address indexed pool, bytes reason)` — emitted when `pool.skim(guardian)` reverts during the donation-handling step. The `reason` field contains bounded revert data (up to 128 bytes) from the failed skim call.

Rule:
- If the event signature differs anywhere, **the LaunchController contract spec wins** (per `docs/v1.0.0-index.md`).

---

## Checklist: forbidden surfaces (MUST NOT)

LaunchController MUST NOT include:
- `owner` / `onlyOwner` admin functions.
- Permissionless `withdraw` / `sweep` / `recover` / `rescue` surfaces.
- Any method to re-run genesis or redirect canonical genesis seed funds after finalization.

**Allowed (reference implementation):** internal `_sweepToken` / skim logic inside `finalizeGenesis()` routing proceeds to `guardian`. No reusable post-genesis sweep/recover surface is allowed.

The only intended one-shot genesis flag transition is:
- `genesisFinalized: false → true`.