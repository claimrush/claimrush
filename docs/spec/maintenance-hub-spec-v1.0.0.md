# MaintenanceHub spec (v1.0.0)

This document specifies `MaintenanceHub`, a **permissionless maintenance entrypoint** that bundles protocol upkeep actions into a single transaction.

## Normative interpretation

- This document is normative for the `MaintenanceHub` contract in ClaimRush v1.0.0.
- Binding requirements are stated using MUST / MUST NOT / REQUIRED / NOT PART OF V1.0.0.
- Guidance language (including `recommended`, `should`, `may`, `optional`) is non-binding. Treat it as implementation and ops help only, unless restated as a binding requirement.

## Motivation

- Keep the MineCore takeover sequence deterministic and low-risk.
- Avoid swap-heavy, parameterized upkeep inside takeover.
- Provide a single onchain surface for:
  - Market auto-fallback execution (`MarketRouter.executeAutoFurnace`)
  - Furnace LP rewards stream accrual (`Furnace.tick`)
  - ve liveness (`VeClaimNFT.checkpointGlobalState`)
  - Shareholder liveness (`ShareholderRoyalties.flushPendingShareholderETH`)
  - (Intentionally excluded) Baron auto-compound is owner-or-keeper-allowlisted (per-user opt-in). Execution occurs directly via `ShareholderRoyalties.compoundForMany(...)` / `ShareholderRoyalties.compoundFor(...)` (see SPEC §6.7).
  - (Intentionally excluded) LP reward auto-compound is owner-or-keeper-allowlisted and per-user-configured. Execution occurs directly via `LpStakingVault7D.compoundForMany(...)` / `LpStakingVault7D.compoundFor(...)` by an offchain maintainer bot in normal operation, with owner break-glass retained (see `docs/spec/lp-staking-vault-spec.md`).

MaintenanceHub is a convenience router. It does not change protocol economics by itself; it only calls existing maintenance functions (some permissionless, some owner-or-keeper-gated).

## External dependencies

- `MarketRouter`
- `Furnace`
- `VeClaimNFT`
- `ShareholderRoyalties`
- `MineCore` (resolved transitively via `ShareholderRoyalties.mineCore()`)
- `ClaimToken` (resolved transitively via `VeClaimNFT.claimToken()`)

Constructor wiring requirement (MUST):
- `MaintenanceHub` MUST be deployed against a single canonical upkeep bundle.
- The constructor accepts a `rescueRecipient` address that designates the immutable recipient for stuck-token rescues (see [Token rescue](#token-rescue) below). `rescueRecipient` MUST be nonzero.
- The constructor MUST fail unless:
  - `ve.claimToken()` resolves to a nonzero contract `claim`
  - `royalties.mineCore()` resolves to a nonzero contract `core`
  - `MarketRouter.ve() == ve`
  - `MarketRouter.royalties() == royalties`
  - `MarketRouter.claim() == claim`
  - `Furnace.ve() == ve`
  - `Furnace.claim() == claim`
  - `Furnace.shareholderRoyalties() == royalties`
  - `Furnace.mineMarket() == marketRouter`
  - `Furnace.mineCore() == core`
  - `VeClaimNFT.mineMarket() == marketRouter`
  - `VeClaimNFT.furnace() == furnace`
  - `VeClaimNFT.claimToken() == claim`
  - `ShareholderRoyalties.mineMarket() == marketRouter`
  - `ShareholderRoyalties.furnace() == furnace`
  - `ShareholderRoyalties.ve() == ve`
  - `ShareholderRoyalties.mineCore() == core`
  - `MineCore.furnace() == furnace`
  - `MineCore.royalties() == royalties`
  - `MineCore.ve() == ve`
  - `MineCore.claim() == claim`
  - `ClaimToken.mineCore() == core`
- Rationale: `poke(args)` is intentionally best-effort. A split-brain deployment could otherwise look healthy while sweeping offers on one market and checkpointing / flushing / ticking a different deployment.
- Because this wiring is constructor-bound and immutable, any rewiring of the canonical market bundle MUST be followed by a fresh `MaintenanceHub` deployment against the new bundle.

## Design requirements

Permissionless
- Anyone MUST be able to call the maintenance entrypoint.
- `MaintenanceHub` MUST NOT require roles, allowlists, or signatures.

Bounded work
- The caller supplies an explicit list of offer IDs to process.
- The contract MUST enforce hard caps so calls remain gas-bounded.
- `args.maxOffers` MUST be clamped to `MAX_MAINTENANCE_OFFERS_PER_CALL`.

Best-effort execution
- After the canonical-bundle preflight passes, a failure in one sub-action MUST NOT revert the entire maintenance call.
- Use `try/catch` for each external call and continue.

Bounty forwarding
- `MaintenanceHub` MUST forward any WETH it receives during `poke(args)` to the poke caller before returning.

## Interface

### Types (MUST)

The following types are part of the external ABI and MUST remain stable in v1.0.0.

ABI requirements (MUST):
- The `PokeArgs` struct field order is part of the ABI and MUST NOT change.
- Reordering, inserting, removing, or changing the type of any field is a breaking change.

```solidity
struct PokeArgs {
  uint256[] offerIds;

  uint256 maxOffers;
}
```

### poke(PokeArgs args)

Permissionless.

Entry preflight (MUST):
- `poke(args)` MUST fail closed before any sub-action unless the live `MarketRouter`, `Furnace`, `VeClaimNFT`, `ShareholderRoyalties`, `MineCore`, and `ClaimToken` still resolve to the same canonical upkeep bundle described above.
- Rationale: a stale immutable hub must not partially checkpoint / flush / tick one deployment while sweeping offers against a different market or core / claim root.

Sub-action order (guidance; MUST remain best-effort and bounded):
1) ve checkpoints (optional but recommended)
2) shareholder flush (optional but recommended)
3) Market sweep (always attempt)
4) Furnace tick - LP rewards stream accrual (optional but recommended)

ve checkpoint
- Attempt `VeClaimNFT.checkpointGlobalState()`.
  - If it reverts (gas guard, etc), skip and continue.
- Clarification: the MineCore takeover sequence already performs this checkpoint. Including it here is a liveness backstop between takeovers.

Shareholder flush
- Attempt `ShareholderRoyalties.flushPendingShareholderETH()`.
- If it reverts, skip and continue.
- Clarification: the MineCore takeover sequence already auto-attempts a flush. Including it here is a liveness backstop between takeovers.
- Ordering rationale: when the ve checkpoint catches up in the same tx, performing the flush before `executeAutoFurnace(...)` prevents a new lock created later in the same `poke(args)` call from sharing older `pendingShareholderETH` that predates its entry. If `globalLastTs()` remains stale after the bounded checkpoint calls, the flush no-ops and the pending ETH stays queued for a later attempt.

Market sweep
- Let `maxOffersClamped = min(maxOffers, MAX_MAINTENANCE_OFFERS_PER_CALL)`.
- Iterate over `offerIds` in-order, up to `min(offerIds.length, maxOffersClamped)`.
- For each `offerId`, attempt `MarketRouter.executeAutoFurnace(offerId, deadline)` where `deadline = block.timestamp + _OFFER_DEADLINE_GRACE` (300 seconds).
- If it reverts, skip and continue.

Furnace tick
- Attempt `Furnace.tick()`.
- If it reverts, skip and continue.
- Purpose: Accrues the LP rewards stream (transfers owed CLAIM to `lpRewardsVault`) and processes the LP overflow drip (once-per-day distribution from reserve to LP stream).
- This ensures LP stakers receive their rewards on schedule, even when no other Furnace activity occurs.

Bounty forwarding
- Let `weth` be the canonical WETH token.
- Record `wethBefore = weth.balanceOf(address(this))` at the start of `poke(args)`.
- After all sub-actions, compute `wethDelta = weth.balanceOf(address(this)) - wethBefore`.
- If `wethDelta > 0`, forward `wethDelta` to `msg.sender` using a non-reverting `try IERC20(address(weth)).transfer(...)`. If the transfer fails, the WETH remains on the hub (no revert).

## Token rescue

- `rescueToken(IERC20 token)` — transfers the hub's entire balance of `token` to the immutable `rescueRecipient`.
- Callable by anyone (permissionless).
- MUST revert if `token` is the canonical `weth` (WETH is forwarded to callers via bounty logic, not rescued).
- Purpose: recover ERC20 tokens accidentally sent to the hub.

## Events (MUST)

Emit a single summary event (REQUIRED):

- `Poked(address caller, bool checkpointOk, bool flushOk, uint256 offersAttempted, uint256 offersSucceeded, bool furnaceTickSucceeded, uint256 bountyWethForwarded)`

Event requirements (MUST):
- `Poked(...)` MUST be emitted exactly once for every successful `poke(args)` call.
- `checkpointOk` MUST be true when `checkpointGlobalState()` succeeded.
- `flushOk` MUST be true when `flushPendingShareholderETH()` succeeded.

## Offchain automation expectations

Operational expectation (non-binding): the official keeper bot calls `MaintenanceHub.poke(args)` using event-driven triggers plus periodic reconciliation.

Operational guidance (cadence, redundancy, monitoring):
- See operational security runbook for cadence, redundancy, and monitoring guidance.
