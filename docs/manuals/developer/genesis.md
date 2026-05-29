
# Genesis

Genesis is the one-time launch sequence that:
- materializes the first 10d of Crown stream (King-stream) emissions
- seeds the initial WETH/CLAIM liquidity pool with the materialized 10d King-stream CLAIM bucket
- locks genesis LP for 24 months
- activates takeovers

Contracts:
- LaunchController
- GenesisLPVault24M

## LaunchController.finalizeGenesis

One-shot and guardian-authorized, with strict guards.

Hard requirements (v1.0.0):
- `msg.value == requiredSeedEth` (exact; `50 ETH * duration / 10 days` — 50 ETH on mainnet, 5 ETH on testnets)
- `block.timestamp >= emissionStartTime + 10 days`
- `MineCore.takeoversPaused() == true`
- `MineCore.guardian() == LaunchController` during the genesis window
- the pre-genesis handoff that installs `LaunchController` as `MineCore.guardian` must be done by `MineCore.owner()`; the current guardian cannot self-install that contract role
- `MineCore.collectGenesisKingClaim(...)` must be called by the canonical LaunchController contract itself (MineCore rejects EOAs and unrelated contract guardians even if they are the current guardian)
- Aerodrome WETH/CLAIM pool is empty (no LP minted)
- `LaunchController` pins `router.weth()` and `router.defaultFactory()` at deployment. Later `router.defaultFactory()` drift is ignored, but `router.weth()` or `router.poolFor(..., cachedFactory)` drift still aborts finalization.

Constructor wiring rejection (v1.0.0):
- The `LaunchController` constructor rejects bare EOAs and zero-address roots on every wiring input.
- It also rejects EIP-7702 delegation designators on every wiring input. A delegation designator is exactly 23 bytes of code prefixed by `0xEF0100`; the constructor reverts with `Errors.DelegatedEOA()` rather than relying on the bare `code.length == 0` check, which a designator pointing at a real contract would otherwise bypass.
- The constructor also rejects `_guardian == LaunchController` and any case where the canonical CREATE2 pool address derives to `LaunchController`. Both shapes would fold post-genesis state back into the controller and are rejected up front with `Errors.GenesisPoolMismatch()`.

Read-only preflight surface:
- `LaunchController.preflight()` returns `(uint256 statusBitmask, uint256 requiredSeedEth)`. Each bit reads as `1` when the matching precondition holds. `finalizeGenesis()` requires bits 0..10 set and `msg.value == requiredSeedEth`.
- Bit layout (LSB first): bit 0 `!genesisFinalized`; bit 1 `GENESIS_ACCRUAL_DURATION > 0`; bit 2 `emissionStartTime > 0`; bit 3 `block.timestamp >= emissionStartTime + duration`; bit 4 `takeoversPaused == true`; bit 5 `genesisLpVault.pool() == expectedPool`; bit 6 `aerodromeRouter.weth() == weth`; bit 7 `aerodromeRouter.poolFor(weth, claim, false, factory) == expectedPool`; bit 8 pool LP supply `== 0`; bit 9 pool weth + claim balances `== 0` (no donation); bit 10 `expectedPool != address(LaunchController)` (CREATE2 self-collision guard).
- This view is intended for off-chain monitoring and operator runbooks. The state-mutating `finalizeGenesis()` re-checks every condition independently.

Operational note:
- `Deploy.s.sol` sets `LaunchController.guardian = INITIAL_OWNER`.
- For the supported production/testnet flow, leave `INITIAL_OWNER` unset so the deployer remains the bootstrap owner through genesis and ownership handoff. On mainnet, finality is deferred and executed through the timelock as the freeze-and-burn ceremony.
- If `INITIAL_OWNER != deployer`, `Deploy.s.sol` requires `ALLOW_NON_DEPLOYER_INITIAL_OWNER=true`; split-key ownership at deploy time is explicit opt-in. The wrapper `scripts/deploy_prod.mjs --deploy --wire` refuses that configuration, so use the manual split-key flow instead.
- `Deploy.s.sol` simulates the full deploy sequence (constructors + proxy initializations) before broadcasting and fails closed if the wrapped `DexAdapter` resolves `weth()` / `defaultFactory()` to non-contract roots, so a malformed Aerodrome router cannot leave a partial live deployment onchain.
- Advanced split-key deployments with a contract `INITIAL_OWNER` remain supported: that pre-existing contract owner/guardian can still perform the first owner-only handoff into `LaunchController`, because the MineCore genesis lock starts only after the installed guardian is the canonical LaunchController-like contract. That pre-existing contract owner/guardian still cannot call `MineCore.collectGenesisKingClaim(...)` directly before the handoff.
- `FinalizeGenesis.s.sol` assumes one operator key can both call `LaunchController.finalizeGenesis()` and rotate `MineCore.guardian`, so keep `MineCore.owner == LaunchController.guardian` until post-genesis guardian rotation is complete.
- Accepted mainnet posture: pre-genesis deployments are disposable until `LaunchController.finalizeGenesis()` completes successfully. Once the canonical LaunchController-style guardian is installed, MineCore will not let operators rotate to a replacement guardian until `collectGenesisKingClaim()` succeeds. If finalization is miswired or permanently reverting, recover by redeploying/restarting the pre-genesis bundle rather than expecting in-place guardian recovery. Do not treat the deployment as publicly green until finalization completes and `MineCore.guardian` rotates away from `LaunchController`.

Flow (all steps execute atomically inside `finalizeGenesis()`):
1. Pre-seed pool guard: skim any donations at the pool address
2. `MineCore.collectGenesisKingClaim(to=LaunchController)`
3. Seed liquidity with:
   - the `CLAIM` minted by `MineCore.collectGenesisKingClaim(...)` in step 2
   - donated/pre-existing `CLAIM` already sitting on `LaunchController` is excluded from the canonical seed and swept to `guardian`
   - exactly `requiredSeedEth` worth of WETH (50 ETH on mainnet, proportionally scaled for testnets)
   - LP minted directly to `GenesisLPVault24M`
4. `GenesisLPVault24M.startLock()` (24 months)
5. `MineCore.setTakeoversPaused(false)`
6. `MineCore.setGuardian(guardian)` — LaunchController atomically rotates the MineCore guardian from itself to the operational guardian baked into its immutable `guardian` field

Important:
- `finalizeGenesis()` does **not** create a veCLAIM position. The first ve lock still comes from a normal user / Furnace lock flow after launch.

Best-effort residual sweep:
- After step 6 the controller sweeps any residual `CLAIM`, `WETH`, and LP token balances on `LaunchController` to the operational `guardian`. The sweep runs after `genesisFinalized = true` and after the MineCore guardian rotation, so a sweep revert would otherwise unwind the entire one-shot genesis. Each sweep is therefore best-effort: a malformed token (revert on `transfer`, returns `false`, returns malformed payload, or reverts on `balanceOf`) emits `SweepFailed(token, reason)` and finalization continues. The donated token simply persists on the controller in that pathological case; the canonical genesis assets still flow through correctly because the seed transfers happen in steps 1–4 before the sweep.

## GenesisLPVault24M

Responsibilities:
- custody the canonical Aerodrome WETH/CLAIM LP from genesis
- enforce a 24 month lock (`INITIAL_LOCK_DURATION = 730 days`)
- allow `lpWithdrawRecipient` to extend the lock to a later `unlockTime` (never shorten)
- on `withdrawLp()`, **claim accumulated Aerodrome trading fees** via `pool.claimFees()` and forward the resulting `token0` + `token1` balances to `lpWithdrawRecipient` in the same transaction, before the LP transfer

After unlock:
- `withdrawLp()` is callable only by `lpWithdrawRecipient` (recipient-only access control)
- destination is fixed (`lpWithdrawRecipient`)
- the call delivers (a) the LP token, and (b) 24 months of accumulated WETH + CLAIM trading fees, atomically in one transaction
- emission order in that transaction: `FeesClaimedAndForwarded(token0, token1, amount0Forwarded, amount1Forwarded)` first (only if at least one of the forwarded amounts is non-zero), then `WithdrawLp(to, amount)`. The residual-LP path emits `ResidualLpSwept(to, amount)` instead of `WithdrawLp` and follows the same ordering for the fee event

Why the fee forward lives inside `withdrawLp()`:
- Aerodrome v2 keeps trading fees in per-LP-holder `claimable0/1` slots that are separate from pool reserves. They are settled into the LP holder's own ERC-20 balance only when `pool.claimFees()` is called from that holder's address.
- The vault has no other code path that can call `pool.claimFees()` from its own address. Without this on-vault claim step, the entire 24 months of fee accruals would settle into `claimable0[vault]` / `claimable1[vault]` and become permanently unrecoverable after the LP token leaves the vault.
- The corrective change (next broadcast SHA) is bounded: the only tokens this code path can move are the pool's own `token0` / `token1`, the destination is the immutable `lpWithdrawRecipient`, and the source call is `pool.claimFees()` only — it is **not** a generic admin sweep. See [`docs/spec/vault-spec.md`](https://github.com/claimrush/claimrush/blob/main/docs/spec/vault-spec.md) "MUST NOT scope" and [`docs/architecture/architecture-reference-v1.0.0.md`](https://github.com/claimrush/claimrush/blob/main/docs/architecture/architecture-reference-v1.0.0.md) §8 bounded-exceptions list.

Best-effort failure mode:
- All three pool reads (`pool.claimFees()`, `pool.token0()`, `pool.token1()`) are wrapped in their own `try/catch`. If any of them reverts (e.g. a misbehaving pool, or an emergency wiring pathology where `pool` does not actually point at an Aerodrome v2 pool), `withdrawLp()` still succeeds and the LP token still transfers to `lpWithdrawRecipient`. Fees are forwarded only on the happy path; LP recovery is never blocked by a fee-claim or token-lookup pathology.

Production / testnet deploy note:
- `GenesisLPVault24M` bakes `lpWithdrawRecipient` immutably at deploy time.
- Set `LP_WITHDRAW_RECIPIENT` explicitly before `Deploy.s.sol`; later ownership transfer does not change the eventual LP withdrawal destination.

### Operator tooling for the 24-month window

Two read-only operator tools track the genesis LP vault between `startLock()` and `withdrawLp()`:

1. **Pre-unlock dry-run** (`make genesis-lp-withdraw-dry-run`). Spawns a Base mainnet fork via Anvil, impersonates the immutable `lpWithdrawRecipient`, warps past `unlockTime`, and executes `withdrawLp()` against the live deployed bytecode. Reports the LP and fee-token deltas the recipient would receive, plus three invariant checks (`LP transfer == pre-balance`, `vault drained`, `at least one fee token forwarded`). Exit code is non-zero if any structural invariant fails. Recommended cadence: every quarter, and once more during the final week before unlock. Requires `BASE_MAINNET_RPC_URL`.

2. **Quarterly accrual monitor** (`make genesis-lp-accrual-snapshot`). Pure-view snapshot of `pool.balanceOf(vault)` plus `pool.claimable0(vault)` / `pool.claimable1(vault)`, appended to `monitoring/genesis-lp-accrual.jsonl`. Each row records the lock state, pending fees per side, and the delta against the previous snapshot. A negative delta on either side (claimable balance went down between snapshots) emits an alert on stderr and exits with code `2`, because nothing should be calling `pool.claimFees()` from the vault address before `withdrawLp()`. Suitable for cron: `0 12 1 ★/3 * BASE_MAINNET_RPC_URL=... node scripts/genesis_lp_accrual_monitor.mjs` (replace ★ with `*`).

3. **Admin dashboard panel**. The operator-only `/admin/system` page surfaces the same `pool.claimable0/1(vault)` reads alongside LP balance, unlock countdown, and the immutable recipient address. Updates every 60 s while the page is open. Use this for daily operator visibility; use (1) and (2) for periodic correctness checks.

All three read `pool.claimable0/1(vault)` rather than calling `claimFees()`. The non-mutating view path means the monitor cannot accidentally settle fees out of the claimable slots before withdrawal.

## Pre-genesis wiring preflight

Before any genesis assets move:
- Run `Wire.s.sol` once after `Deploy.s.sol`
- `Wire.s.sol` simulates the full sequence before broadcasting, so treat a preflight revert as a real owner/guardian/config mismatch and fix it before sending live wiring txs
- Deploy `MaintenanceHub` only after that first wire pass
- `DeployMaintenanceHub.s.sol` resolves its constructor roots from `DEPLOYMENTS_MANIFEST_JSON` or `deployments/<network>.json`, so in manual Foundry-only flows refresh the core manifest before broadcasting and treat env roots as cross-checks only
- In manual Foundry-only flows, update `deployments/<network>.json` with the `MaintenanceHub` address/startBlock before re-running `Wire.s.sol`; the sync scripts only mirror manifests and do not parse broadcasts into JSON
- Re-run `Wire.s.sol` after `DeployMaintenanceHub.s.sol` so keeper roles and any explicitly configured settlement roles are attached; `MaintenanceHub` itself only joins the settlement-keeper allowlist if `ALLOW_MAINTENANCE_HUB_SETTLEMENT_KEEPER=true` is set for that pass
- Run `scripts/verify_deployment.py` and fix any wiring mismatches before touching genesis funds. If you intentionally allowlisted `MaintenanceHub` as a settlement keeper, pass `--expect-maintenancehub-settlement-keeper` too

Production / testnet note:
- The canonical CLAIM/WETH pool does not have live code until `LaunchController.finalizeGenesis()` succeeds.
- Because `EntryTokenRegistry.setWethClaimHop(...)` requires live pool code, the first two production/testnet wire passes intentionally defer the Furnace registry WETH/CLAIM hop until after genesis finalization.
- Re-run `Wire.s.sol` once after finalization to bind that hop.

Operationally important:
- Do **not** delay genesis for finality. The v1.0.0 deployment flow launches without freezing and reaches permanent finality only after the governed verification window.
- `FreezeAndBurn.s.sol` is the canonical finality path. ClaimToken freezes at wire time; the script asserts it is already frozen, then freezes the remaining four contracts and burns runtime `ProxyAdmin`s in one timelock batch.
- Pre-seeding the WETH/CLAIM pool causes `LaunchController.finalizeGenesis()` to revert with `PoolNotEmpty()`.

## Scripted execution

Production / Base Sepolia:

```bash
export PRIVATE_KEY=0x...
export GUARDIAN=0x...   # required on production/testnet finalize runs, including reruns

forge script script/FinalizeGenesis.s.sol:FinalizeGenesis \
  --rpc-url "$RPC_URL" \
  --broadcast \
  -vvv
```

`FinalizeGenesis.s.sol` simulates the full finalize + guardian-rotation + postcondition sequence before broadcasting. It fails closed if `GUARDIAN` is missing or points back at `LaunchController`, if `PRIVATE_KEY` no longer controls both `LaunchController.guardian` and `MineCore.owner` while post-genesis rotation is pending, if the broadcaster cannot fund the fixed 50 ETH genesis seed, or if the simulated final state still leaves takeovers paused / LP lock unset.

Local Anvil:

```bash
make finalize-genesis
```

`FinalizeLocalGenesis.s.sol` also simulates the full finalize + guardian-rotation + postcondition sequence before broadcasting, so a bad local state or missing 5 ETH seed balance fails closed before any live tx. `make finalize-genesis` / `scripts/finalize_genesis.sh` are local-only helpers and refuse nonlocal RPC chain ids. They also assume `LOCAL_PRIVATE_KEY` still controls both `LaunchController.guardian` and `MineCore.owner` while the post-genesis guardian rotation is pending, reject `GUARDIAN == LaunchController`, pin `GUARDIAN` to the derived local deployer during the standard helper flow so ambient shell overrides cannot split that path, and only report success after guardian rotation plus the genesis LP lock state are confirmed. `DeployLocalExtras.s.sol` also simulates the full local extras constructor sequence before broadcasting, rejects `LOCAL_GENESIS_BURN_GUARDIAN != local deployer`, and cross-checks the local DexAdapter/router/factory/WETH/pool roots so the local deploy cannot bake an unfinishable genesis path.

After a successful production/testnet finalization:
- update `deployments/<network>.json`
- set `aerodrome.claimWethPool.startBlock` to the finalization tx block
- set `aerodrome.lpToken.startBlock` to the same block
- re-run `Wire.s.sol` once so `FurnaceEntryTokenRegistry` can bind the now-live canonical WETH/CLAIM hop
- note: `Wire.s.sol` deploys `FurnaceQuoter` inline (not via `Deploy.s.sol`) and wires it into `Furnace.setFurnaceQuoter(...)`. The production manifest refresh path (`scripts/deploy_prod.mjs --wire`) then records the live `Furnace.furnaceQuoter()` address back into `deployments/<network>.json`. You can also read it directly onchain or from the Wire broadcast log.
- re-run `scripts/verify_deployment.py --expected-guardian "$GUARDIAN"` after wiring so the post-genesis hop, guardian target, and manifest start blocks are all verified against the manifest
- confirm `MineCore.guardian == GUARDIAN`
- regenerate mirrors with `bash scripts/sync_deployments_all.sh --write` and `python3 scripts/sync_docs_deployments.py --write`

## Post-genesis checks

After `finalizeGenesis()` succeeds:
- `LaunchController.genesisFinalized() == true`
- `MineCore.takeoversPaused() == false`
- `GenesisLPVault24M.lockStartTime() != 0`
- `GenesisLPVault24M.lpLockedAmount() > 0`
- `FurnaceEntryTokenRegistry.getWethClaimHop().pool == aerodrome.claimWethPool.address`
- `MineCoreEntryTokenRegistry.getWethClaimHop().pool` may still be `address(0)` if that registry is takeover-only
- `MineCore.guardian` is rotated to the long-term guardian
- On Base mainnet / Base Sepolia, ownership handoff happens **before** the freeze-and-burn ceremony. `FinalizeOwnership.s.sol` initiate mode fails closed unless genesis is finalized, `MineCore.guardian` has rotated away from `LaunchController`, and `ClaimToken` is already frozen plus owner-renounced from `Wire.s.sol`. Set `NEW_OWNER` to the deployed `TimelockController` address, not `ADMIN_SAFE`. Before running `FinalizeOwnership.s.sol`, bootstrap the timelock with `FinalizeTimelockBootstrap.s.sol` and have `ADMIN_SAFE` pre-schedule the `TimelockAcceptOwnership.s.sol` batch so the delay matures first. Once the operation is ready, run `FinalizeOwnership.s.sol` and immediately execute the ready `acceptOwnership()` batch through the timelock path. Direct protocol contracts still use `Ownable2Step`; runtime `ProxyAdmin` contracts use plain `Ownable` and transfer ownership immediately during initiate mode. Use `OWNERSHIP_ADDRS_FROM_ENV=true` only for deliberate manual subset recovery, and set at least one explicit ownership target when that mode is enabled.

See also: [freeze-and-burn-finality.md](freeze-and-burn-finality.md).

## See also

- [Protocol Overview](protocol-overview.md) — architecture and contract relationships
- [Core Mechanics](core-mechanics.md) — genesis accrual bucket and emission schedule
- [Getting Started](getting-started.md) — deployed addresses
- [Constants Reference](appendix-constants-v100.md) — shared `Constants.sol` values used around genesis
