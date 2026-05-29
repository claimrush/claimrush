# Aerodrome Liquidity Bootstrap Appendix – ClaimRush v1.0.0

**Status:** Normative (this appendix is part of the spec surface for genesis liquidity bootstrap).

This appendix pins the **Aerodrome v2 genesis liquidity bootstrap** used by ClaimRush v1.0.0.

Pinned shape (v1.0.0):
- Create (if needed) and seed the canonical **WETH/CLAIM volatile (vAMM)** pool.
- Use **exact amounts**: `requiredSeedEth` (50 ETH on mainnet; proportionally scaled for shorter genesis durations) and `claimSeed`.
- Mint LP tokens **directly** to `GenesisLPVault24M`.

Scope:
- `LaunchController.finalizeGenesis()` pool creation + liquidity seeding.

Protocol boundaries:
- Furnace entry swaps and quotes (covered by `docs/architecture/aerodrome-integration-appendix-v1.0.0.md`).
- MineCore takeover swaps.
- Oracle / TWAP usage.

---

## B.1 Canonical pool definition (locked)

- Tokens:
  - `tokenA = WETH` (`dexAdapter.weth()`)
  - `tokenB = CLAIM`
- Pool type:
  - **volatile** vAMM
  - `stable = false`
- Factory:
  - `factory = dexAdapter.defaultFactory()` at LaunchController construction time and cache it immutably for finalization

The canonical pool address is:

- `pool = dexAdapter.poolFor(WETH, CLAIM, stable=false, factory)`

Constraints (required):
- `poolFor(...)` MUST be used to compute the canonical pool address (deterministic).
- Deployments MUST pass this computed `pool` into `GenesisLPVault24M` at construction.

### B.1.1 Pre-seed recovery policy (v1.0.0 locked)

In v1.0.0, genesis MUST **fail closed** if the canonical Aerodrome pool is pre-seeded with LP.

**Onchain guard (REQUIRED):** LaunchController MUST enforce:
- If the pool already exists (`pool.code.length != 0`), require:
  - `IERC20(pool).totalSupply() == 0`
- Otherwise (pool not deployed yet), treat LP supply as 0 and proceed.

If the guard fails, `finalizeGenesis()` MUST revert with `PoolNotEmpty()`.

**Operational fallback (REQUIRED to document):** LaunchController is intended to be ownerless and the canonical pool address is immutable. If LP is pre-seeded, there is no onchain recovery path — abort and redeploy.

---

## B.2 Minimal Aerodrome interface surface (bootstrap)

ClaimRush v1.0.0 uses `DexAdapter` only for **canonical address computation and drift checks** (`weth`, `defaultFactory`, `poolFor`). `LaunchController` stores the immutable name `aerodromeRouter`, and deployment wires the protocol `DexAdapter` into that slot.

Genesis liquidity seeding is performed by:
- Explicitly calling the Aerodrome **pool factory** to `getPool/createPool`.
- Transferring the two seed assets to the pool.
- Calling `pool.mint(to)` to mint LP.

Minimal acceptable interface shapes:

```solidity
/// @notice DexAdapter subset used only for deterministic pool addressing and wiring validation.
interface IDexAdapterPoolFor {
    function defaultFactory() external view returns (address);
    function weth() external view returns (address);

    function poolFor(
        address tokenA,
        address tokenB,
        bool stable,
        address factory
    ) external view returns (address pool);
}

interface IPoolFactory {
    function getPool(address tokenA, address tokenB, bool stable) external view returns (address pool);
    function createPool(address tokenA, address tokenB, bool stable) external returns (address pool);
}

/// @notice Aerodrome v2 pool interface subset for genesis LP mint.
/// @dev Pool contract is also the LP ERC20 token.
interface IAerodromePoolMint {
    function mint(address to) external returns (uint256 liquidity);
}

interface IWETH {
    function deposit() external payable;
}
```

---

## B.3 Genesis liquidity bootstrap (LaunchController)

### B.3.1 Inputs

At genesis finalization:
- `ethSeed = requiredSeedEth` (exact; `MAINNET_GENESIS_SEED_ETH * duration / MAINNET_GENESIS_DURATION` — 50 ether on mainnet, 5 ether on testnets)
- `claimSeed = claimMinted`, where `claimMinted` is the amount minted by `MineCore.collectGenesisKingClaim(address(this))` during `finalizeGenesis()`. Pre-existing / donated controller `CLAIM` is excluded from the canonical seed.

### B.3.2 Canonical seeding method (REQUIRED): direct pool mint

LaunchController MUST seed genesis liquidity by **directly minting LP on the pool**.

Required steps:

1) **Resolve (or create) the canonical pool**
   - Re-check `dexAdapter.weth()` and require it still equals the cached immutable `weth`.
   - Use the cached immutable `factory` captured at LaunchController construction time (do not re-read `router.defaultFactory()` here).
   - Resolve:
     - `pool = IPoolFactory(factory).getPool(weth, CLAIM, stable=false)`.
   - If missing:
     - `pool = IPoolFactory(factory).createPool(weth, CLAIM, stable=false)`.
   - Required runtime wiring validation:
     - `require(pool == expectedPool)` where `expectedPool = dexAdapter.poolFor(weth, CLAIM, false, factory)`.

2) **Pre-seed guard (REQUIRED)**
   - If `IERC20(pool).totalSupply() != 0`, revert `PoolNotEmpty()`.

3) **Transfer the two seed assets into the pool**
   - Transfer `claimSeed` to the pool:
     - `IERC20(CLAIM).transfer(pool, claimSeed)`.
   - Wrap and transfer ETH to the pool:
     - `IWETH(weth).deposit{value: ethSeed}()`.
     - `IERC20(weth).transfer(pool, ethSeed)`.

4) **Mint LP directly to the vault**
   - `liquidity = IAerodromePoolMint(pool).mint(address(GenesisLPVault24M))`.

5) **Start the vault lock**
   - `GenesisLPVault24M.startLock()` (one-shot).

Operational hardening (RECOMMENDED):
- Send the `finalizeGenesis()` transaction via a private relay to avoid mempool grief/MEV games around pool creation and initial price formation.

### B.3.3 Rationale (correctness + MEV hardening)

This direct-mint bootstrap is pinned because it:
- Enforces **exact amounts by construction** (no partial add).
- Removes reliance on router `_addLiquidity` reserve-based “optimal amount” logic.
- Eliminates router ETH dust refund mechanics and any `deadline` dependency.

Important security note:
- A router-based `addLiquidityETH` call with **strict mins** can revert if the pool is not in the “empty reserves” state.
- Because pool creation is permissionless, a public-mempool genesis tx can be griefed into failure by pre-creating the pool and moving it out of the empty-reserves branch.

---

## B.4 Deterministic pool address and pre-deployment

Aerodrome v2 pool addresses are deterministic for a given:
- token0/token1 ordering
- stable flag
- factory

Therefore:
- `dexAdapter.poolFor(WETH, CLAIM, false, factory)` returns the eventual pool address even before creation.
- LaunchController can safely pin that address at deployment; later `router.defaultFactory()` drift must not silently change the genesis target pool.

This property enables:
- Deploying `GenesisLPVault24M` before the pool exists.
- Validating wiring in `LaunchController.finalizeGenesis()`:
  - `require(GenesisLPVault24M.pool() == expectedPool)`

---
