# LaunchController spec (v1.0.0)

**Status:** Normative (implementation-facing contract spec).

`LaunchController` is the protocol-enforced **genesis finalization** orchestrator.

It MUST run **exactly once**, guardian-authorized, after the 10-day genesis accrual window, to:
- Materialize the genesis **King-stream** CLAIM accrual into this contract.
- Seed Aerodrome v2 **WETH/CLAIM volatile** liquidity using:
  - **the required seed ETH** (see §1 for proportional scaling) provided by the caller via `msg.value`
  - **the CLAIM amount materialized by `MineCore.collectGenesisKingClaim(address(this))` in that same finalization transaction**
- Lock the LP in `GenesisLPVault24M` (start the 24-month lock).
- Unpause takeovers to activate the game.
- Exclude donated/pre-existing `CLAIM` already sitting on `LaunchController` from the canonical genesis seed; any residual balances are swept to `guardian` during finalization.

This contract MUST NOT be a treasury:
- No owner.
- No arbitrary external withdrawals / rescue.
- Only the single intended genesis finalization path, plus bounded internal donation handling tied to finalization.

Reference docs:
- `docs/spec/spec-v1.0.0.md` (§1.2)
- `docs/spec/vault-spec.md` (GenesisLPVault24M)
- [Aerodrome liquidity bootstrap appendix](../architecture/aerodrome-liquidity-bootstrap-appendix-v1.0.0.md) (pool creation + direct pool mint bootstrap)


Operational procedure:
- Canonical operator timeline: see the genesis execution checklist in operational documentation.
- This spec defines contract behavior; the checklist defines the only approved mainnet sequence.

---

## 1. Constants (v1.0.0 policy)

All constants below are **locked** for v1.0.0.

- `GENESIS_ACCRUAL_DURATION = 10 days` on Base mainnet (chain-gated, set at initialization; 1 day on testnets/local)
- `MAINNET_GENESIS_SEED_ETH = 50 ether`
- `MAINNET_GENESIS_DURATION = 10 days`
- Required seed ETH scales proportionally with genesis duration:
  - `requiredSeedEth = MAINNET_GENESIS_SEED_ETH * duration / MAINNET_GENESIS_DURATION`
  - Base mainnet (10 days): 50 ether
  - Testnets/local (1 day): 5 ether
  - **Constraint**: `MineCore.GENESIS_ACCRUAL_DURATION` MUST be a whole number of seconds that exactly divides `MAINNET_GENESIS_DURATION` (= 864000). Otherwise the integer division at the controller rounds `requiredSeedEth` down by less than one wei, and operators executing a manual fallback against the rounded value would revert with `GenesisExactSeedRequired` even though the off-chain calculation looks correct. The two production durations (10 days and 1 day) satisfy this constraint exactly. Bespoke testnet deployments that pick a non-multiple value (e.g. `10 days + 1 second`) are out of spec.
- Aerodrome pool type:
  - `WETH/CLAIM` **volatile** vAMM
  - `POOL_STABLE = false`

---

## 2. Required wiring / configuration

### 2.1 External contract dependencies

LaunchController MUST be deployed with immutable references to:
- `ClaimToken` (`CLAIM`)
- `MineCore`
- `GenesisLPVault24M`
- `DexAdapter` (`IDexAdapter`; wired into the historical `aerodromeRouter` immutable / constructor slot)

Constraints (required; v1.0.0 pinned behavior):
- v1 deployment passes the protocol `DexAdapter` into LaunchController; LaunchController uses only this adapter surface:
  - `weth()` and `defaultFactory()` address discovery at construction time
  - drift checks against the cached `weth` / `factory` roots during finalization
  - deterministic pool addressing via `poolFor(...)` (wiring validation)
- Genesis liquidity seeding MUST NOT rely on any adapter/router `addLiquidity*` surface.
  - v1.0.0 pins a **direct pool mint** bootstrap (see §4.1 step 4 and the liquidity bootstrap appendix).
- Constructor wiring MUST fail closed before this controller can be installed as the MineCore guardian during genesis:
  - `_claim`, `_mineCore`, `_genesisLpVault`, `_aerodromeRouter`, and `_guardian` MUST be non-zero
  - `_claim`, `_mineCore`, `_genesisLpVault`, and `_aerodromeRouter` MUST have code
  - `IMineCoreGenesisClaimView(_mineCore).claim() == _claim`
  - `IDexAdapter(_aerodromeRouter).weth()` and `IDexAdapter(_aerodromeRouter).defaultFactory()` MUST be non-zero contract addresses
  - `IDexAdapter(_aerodromeRouter).poolFor(WETH, CLAIM, false, factory)` MUST be non-zero and MUST equal `GenesisLPVault24M.pool()`

Minimal acceptable interface shape for the genesis LP vault:

```solidity
interface IGenesisLPVault24M {
    /// @notice The canonical Aerodrome v2 WETH/CLAIM pool (also the LP token).
    function pool() external view returns (address);

    /// @notice One-shot: start the 24-month lock timer (records lockStartTime + unlockTime).
    function startLock() external;
}
```

### 2.2 MineCore genesis materialization (REQUIRED)

MineCore MUST implement a genesis accrual bucket for the King-stream and expose a function callable by LaunchController to materialize it.

**Required behavior:**
- Accrue King-stream emissions for the window `[T0, T0 + GENESIS_ACCRUAL_DURATION]` into a dedicated genesis bucket.
- Only after the window has ended, allow LaunchController to mint that bucket into itself.
- This materialization MUST be **one-shot**.

A minimal acceptable interface shape:

```solidity
interface IMineCoreGenesis {
    function emissionStartTime() external view returns (uint256);
    function takeoversPaused() external view returns (bool);

    /// @notice Mint the genesis King-stream bucket into `to`.
    /// @dev MUST revert if called before T0+GENESIS_ACCRUAL_DURATION or if already collected.
    ///      MUST restrict caller to the canonical LaunchController-like guardian for this exact MineCore + CLAIM pair
    ///      (v1: enforce via MineCore.guardian == that canonical contract during genesis).
    ///      MUST also reject EOA callers (`msg.sender.code.length == 0`).
    ///      claimMinted MUST equal the integral of the King emission schedule over [T0, T0+GENESIS_ACCRUAL_DURATION) (see spec-v1 §5.4.3), independent of call time.
    function collectGenesisKingClaim(address to) external returns (uint256 claimMinted);

    /// @notice Unpause takeovers after genesis.
    /// @dev In v1, LaunchController MUST be able to call this (see §2.3).
    function setTakeoversPaused(bool paused) external;
}
```

Pinned behavior for `collectGenesisKingClaim(to)` (v1.0.0):

- **Caller**: MUST be LaunchController (permissionless callers are NOT allowed).
  - In v1, the enforcement mechanism is: `collectGenesisKingClaim` is `onlyGuardian`, rejects EOAs, and additionally requires the installed guardian to be the canonical LaunchController-like contract wired to this exact `MineCore + CLAIM` root.
  - A pre-existing contract owner/guardian used for split-key deployment cannot call `collectGenesisKingClaim` directly before the owner-only canonical handoff installs that guardian.
- **Timing**: MUST revert unless `block.timestamp >= emissionStartTime + GENESIS_ACCRUAL_DURATION`.
- **One-shot**: MUST revert if already collected.
- **Minted amount**: MUST be deterministic and computed as:
  - `claimMinted = integral_king( emissionStartTime, emissionStartTime + GENESIS_ACCRUAL_DURATION )` using the King stream linear-decay integral in `spec-v1.0.0.md §5.4.3`.
  - It MUST NOT accrue beyond `GENESIS_ACCRUAL_DURATION` (call-time does not change the amount).

Clarification:
- The Furnace-stream emission during genesis is still minted/credited to `Furnace` as usual (MineCore responsibility). LaunchController does not handle the Furnace stream.

### 2.3 Authority model during genesis (REQUIRED)

`finalizeGenesis()` is guardian-authorized and triggered by an operational guardian key, while LaunchController remains the onchain MineCore guardian during genesis.

Pinned v1.0.0 requirement:
- `finalizeGenesis()` caller MUST be the immutable `guardian` configured at LaunchController deployment.
- `MineCore.guardian` MUST equal `LaunchController` for the entire genesis window (from `MineCore.emissionStartTime()` until `finalizeGenesis()` succeeds).
- The pre-genesis handoff that sets `MineCore.guardian = LaunchController` MUST be owner-initiated; the current guardian MUST NOT be able to self-install that LaunchController contract role.
- A pre-existing contract owner/guardian (for example a Safe or timelock used in a split-key deployment) MUST still be able to perform that first owner-only handoff. `GenesisGuardianLocked` begins only after the installed guardian is the canonical LaunchController-like contract wired to this exact MineCore + CLAIM root, and that pre-existing contract owner/guardian MUST NOT be able to materialize the genesis bucket directly before the handoff.
- `MineCore.setTakeoversPaused(false)` MUST be callable by `MineCore.guardian`.

Post-genesis requirement:
- `finalizeGenesis()` atomically rotates `MineCore.guardian` from this controller to the immutable `guardian` address configured at LaunchController deployment (see §4.1 step 7). No separate post-finalization guardian rotation is needed unless the operator requires a different long-term guardian than the one baked into LaunchController.

### 2.4 Aerodrome pool address (REQUIRED validation)

LaunchController MUST precompute and store the canonical pool address at construction:

- `factory = dexAdapter.defaultFactory()` at LaunchController construction time
- `weth = dexAdapter.weth()` at LaunchController construction time
- `pool = dexAdapter.poolFor(WETH, CLAIM, stable=false, factory)`

This allows:
- Deploying `GenesisLPVault24M` before the pool exists (deterministic address).
- Validating that `GenesisLPVault24M.pool == expectedPool` during finalization.

See the [Aerodrome liquidity bootstrap appendix](../architecture/aerodrome-liquidity-bootstrap-appendix-v1.0.0.md).

---

## 3. Storage / immutables

LaunchController MUST be minimal.

Immutables (REQUIRED):
- `address public immutable claim`
- `address public immutable mineCore`
- `address public immutable genesisLpVault`
- `address public immutable aerodromeRouter` (historical field name; stores the `DexAdapter` address in v1 deployment)
- `address public immutable weth`
- `address public immutable factory`
- `address public immutable expectedPool` (computed via `poolFor` at construction)
- `address public immutable guardian` (authorized `finalizeGenesis()` caller)

Required state:
- `bool public genesisFinalized`

Transparency state (REQUIRED):
- `uint256 public genesisFinalizedAt`
- `uint256 public genesisClaimMinted`
- `uint256 public genesisClaimToLiquidity`
- `uint256 public genesisLpMinted`

---

## 4. External functions

### 4.1 finalizeGenesis()

**Signature (REQUIRED):**

```solidity
function finalizeGenesis() external payable;
```

Properties (REQUIRED):
- Guardian-only caller authorization (`msg.sender == guardian`).
- Payable.
- One-shot.
- MUST be protected by `nonReentrant`.

#### Preconditions (REQUIRED)

`finalizeGenesis()` MUST revert unless all are true:

- `genesisFinalized == false`
- `msg.sender == guardian`
- `msg.value == requiredSeedEth` (exact; see §1 for proportional scaling)
- `block.timestamp >= MineCore.emissionStartTime() + GENESIS_ACCRUAL_DURATION`
- `MineCore.takeoversPaused() == true`
Constructor invariants already enforced before deployment can succeed (REQUIRED):
- zero-address wiring is rejected
- `_claim`, `_mineCore`, `_genesisLpVault`, and `_aerodromeRouter` must have code
- `MineCore.claim() == CLAIM`
- cached `weth` / `factory` must be non-zero contracts
- `GenesisLPVault24M.pool() == expectedPool` at construction

Additional runtime safety checks (REQUIRED):
- Validate canonical pool wiring:
  - `GenesisLPVault24M(genesisLpVault).pool() == expectedPool`
  - `IDexAdapter(aerodromeRouter).weth() == weth`
  - `expectedPool == IDexAdapter(aerodromeRouter).poolFor(weth, claim, false, factory)`

- **Pre-seed guard (REQUIRED):** the genesis pool MUST NOT be pre-seeded.
  - If the pool already exists (`expectedPool.code.length != 0`), LaunchController MUST require:
    - `IERC20(expectedPool).totalSupply() == 0`
  - If LP supply is non-zero, `finalizeGenesis()` MUST revert (error: `PoolNotEmpty()`).
  - Operational recovery: LaunchController is intended to be ownerless and `expectedPool` is immutable. If the pool is pre-seeded, there is no onchain recovery path — abort and redeploy.

#### Execution steps (REQUIRED)

1) **Mark one-shot state**
   - Set `genesisFinalized = true` (CEI).

2) **Pre-seed pool guard (before CLAIM materialization)**
   - Call `_ensureEmptyOrSkim(expectedPool)` to clear any donations at the deterministic pool address before any protocol tokens are minted.
   - If the pool exists with zero LP supply but has stray `CLAIM`/`WETH`, attempt `pool.skim(guardian)`.
   - If donated balances remain material after skim, revert (`PoolDonationRemains()`), preventing skewed initial pool ratio.

3) **Materialize the genesis King-stream CLAIM into LaunchController**
   - Call `MineCore.collectGenesisKingClaim(address(this))`.
   - Record `genesisClaimMinted` from the balance delta (not the return value alone).

4) **Seed Aerodrome WETH/CLAIM volatile liquidity**
   - Let `claimForLiquidity = genesisClaimMinted` (equivalently, the `CLAIM` balance delta created by step 3).
   - `claimForLiquidity` MUST NOT be the entire `IERC20(CLAIM).balanceOf(address(this))`, because donated/pre-existing controller `CLAIM` is intentionally excluded from the canonical genesis seed.
   - Require `claimForLiquidity > 0`.

   v1.0.0 pinned bootstrap (REQUIRED): **direct pool mint**

   Required interface shapes (minimal):

   ```solidity
   interface IPoolFactory {
       function getPool(address tokenA, address tokenB, bool stable) external view returns (address pool);
       function createPool(address tokenA, address tokenB, bool stable) external returns (address pool);
   }

   interface IAerodromePoolMint {
       function mint(address to) external returns (uint256 liquidity);
   }

   interface IWETH {
       function deposit() external payable;
   }
   ```

   Steps:
   - Re-check `dexAdapter.weth()` and require it still equals the cached immutable `weth`.
   - Use the cached immutable `factory` captured at construction (do not re-read `router.defaultFactory()` here).
   - Resolve (or create) the pool:
     - `pool = IPoolFactory(factory).getPool(weth, CLAIM, POOL_STABLE)`.
     - If `pool == address(0)`: `pool = IPoolFactory(factory).createPool(weth, CLAIM, POOL_STABLE)`.
   - Validate canonical address (REQUIRED):
     - `require(pool == expectedPool)`.
   - Second pre-seed guard (REQUIRED): `_ensureEmptyOrSkim(pool)` after pool creation to catch donations that arrived between steps 2 and 4.
   - Transfer both seed assets into the pool:
     - `IERC20(CLAIM).transfer(pool, claimForLiquidity)`.
     - `IWETH(weth).deposit{value: requiredSeedEth}()`.
     - `IERC20(weth).transfer(pool, requiredSeedEth)`.
   - Mint LP directly to the vault:
     - `liquidity = IAerodromePoolMint(pool).mint(genesisLpVault)`.

   Recordkeeping (REQUIRED):
   - `genesisClaimToLiquidity = claimForLiquidity`.
   - `genesisLpMinted = liquidity`.
   - `genesisClaimMinted == genesisClaimToLiquidity` for the canonical seed amount.

5) **Start the 24-month LP lock**
   - Call `GenesisLPVault24M(genesisLpVault).startLock()`.

6) **Unpause takeovers (activate the game)**
   - Call `MineCore.setTakeoversPaused(false)`.

7) **Rotate MineCore guardian**
   - Call `MineCore.setGuardian(guardian)` to rotate from this defunct controller to the operational guardian baked into the LaunchController immutable.

8) **Record finalization timestamp + emit event**
   - `genesisFinalizedAt = block.timestamp`.
   - Record the genesis amounts: `genesisClaimMinted`, `genesisClaimToLiquidity`, `genesisLpMinted`.
   - Emit `GenesisFinalized(...)`.

9) **Sweep residual donations (REQUIRED)**
   - Sweep any residual `CLAIM`, `WETH`, or LP token balance held by LaunchController to `guardian`.
   - This handles any tokens donated to the controller that were excluded from the canonical genesis seed.

#### Postconditions (REQUIRED)

After a successful `finalizeGenesis()`:
- LaunchController MUST hold:
  - `0` CLAIM (`genesisClaimMinted` sent to liquidity; any residual donated `CLAIM` swept to `guardian`)
  - `0` WETH (`requiredSeedEth` wrapped and transferred to the pool; any residual donated `WETH` swept to `guardian`)
  - `0` LP tokens (LP minted directly to `GenesisLPVault24M`; any donated LP swept to `guardian`)
- `GenesisLPVault24M.lockStartTime != 0`.
- `MineCore.takeoversPaused == false`.

---

## 5. Events (REQUIRED)

LaunchController MUST emit:

```solidity
event GenesisFinalized(
    uint256 timestamp,
    uint256 claimMinted,
    uint256 claimToLiquidity,
    uint256 lpMinted,
    address pool,
    address genesisLpVault
);
```

---

## 6. ETH handling

`finalizeGenesis()` is payable and requires `msg.value == requiredSeedEth` (50 ether on mainnet; proportionally scaled for shorter genesis durations, see §1).

Pinned behavior (v1.0.0):
- The canonical genesis liquidity bootstrap uses **direct pool mint** (no `DexAdapter` or raw-router `addLiquidity*` path).
- Therefore, no adapter/router ETH dust refunds are expected.
- LaunchController MUST NOT include `receive()` or `fallback()` payable functions.

LaunchController MUST NOT include any arbitrary ETH withdrawal method.

---

## 7. Forbidden surfaces (MUST NOT)

LaunchController MUST NOT include:
- `owner` / `onlyOwner` admin surfaces.
- Any externally callable generic `sweep`, `recover`, `rescue`, `withdraw`, or arbitrary token/ETH transfer function.
- Any method to re-run genesis or to redirect genesis funds.

Clarification:
- Internal donation handling bounded to `finalizeGenesis()` is allowed in v1.0.0:
  - pool donation skim to `guardian`
  - controller residual token sweep to `guardian`

The only intended state transition is `genesisFinalized: false → true`.
