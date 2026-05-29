# MaintenanceHub implementer checklist (v1.0.0)

- Constructor MUST reject zero addresses for `marketRouter`, `furnace`, `ve`, `royalties`, `weth`, and `rescueRecipient`. It MUST also reject EOAs (addresses with no code) for `marketRouter`, `furnace`, `ve`, `royalties`, and `weth`. `rescueRecipient` MAY be an EOA (the deployment default is the deployer address).

This is an **implementer-focused checklist** for `MaintenanceHub`, a **permissionless maintenance entrypoint** that bundles protocol upkeep actions into a single transaction.

Source of truth:
- Reference implementation: `src/MaintenanceHub.sol`
- MaintenanceHub canonical spec: `docs/spec/maintenance-hub-spec-v1.0.0.md`
- Event schema conventions: `docs/analytics/dune-integration-pack-v1.0.0.md`

Spec aids (recommended):
- `docs/spec/spec-quality-standard-v1.0.0.md`
- `docs/spec/state-machines-v1.0.0.md`
- `docs/spec/test-vectors-v1.0.0.md`

This document **does not introduce new rules**. It restates MUST/MUST NOT requirements in an order suitable for incremental implementation and review.

---

## Goals

`MaintenanceHub` MUST:
- Be **permissionless** (no roles, allowlists, or signatures).
- Provide a single `poke(args)` entrypoint that fail-closes on canonical bundle drift and otherwise best-effort executes maintenance sub-actions.
- Ensure work is **bounded** by caller-supplied lists and explicit caps.
- Forward any WETH bounty received during `poke(args)` to the poke caller.

`MaintenanceHub` MUST NOT:
- Change protocol economics by itself.
- Introduce new privileged surfaces.

---

## Dependencies

The canonical spec defines the maintenance surfaces and intended call order.

External dependencies (addresses wired at deploy time):
- `MarketRouter`
- `Furnace`
- `VeClaimNFT`
- `ShareholderRoyalties`
- Canonical `WETH`
- `rescueRecipient` — immutable recipient for stuck-token rescues

Transitive canonical roots (resolved at deploy and poke time):
- `MineCore` via `ShareholderRoyalties.mineCore()`
- `ClaimToken` via `VeClaimNFT.claimToken()`

Deployment consequence (MUST):
- Because these addresses are constructor-bound and immutable, any rewiring of the canonical market bundle MUST redeploy `MaintenanceHub` against the new bundle.

Canonical upkeep bundle requirement (MUST):
- Constructor deployment MUST reject unless the immutable bundle resolves one canonical `MarketRouter / Furnace / VeClaimNFT / ShareholderRoyalties / MineCore / ClaimToken` tree.
- At minimum, the implementation MUST validate:
  - `ve.claimToken()` resolves to a nonzero contract `claim`
  - `royalties.mineCore()` resolves to a nonzero contract `core`
  - `MarketRouter.{ve, royalties, claim}` matches `{ve, royalties, claim}`
  - `Furnace.{ve, claim, shareholderRoyalties, mineMarket, mineCore}` matches `{ve, claim, royalties, marketRouter, core}`
  - `VeClaimNFT.{mineMarket, furnace, claimToken}` matches `{marketRouter, furnace, claim}`
  - `ShareholderRoyalties.{mineMarket, furnace, ve, mineCore}` matches `{marketRouter, furnace, ve, core}`
  - `MineCore.{furnace, royalties, ve, claim}` matches `{furnace, royalties, ve, claim}`
  - `ClaimToken.mineCore() == core`

---

## Types

The canonical spec defines these types as part of the external ABI (MUST).

ABI requirements (MUST):
- The `PokeArgs` struct field order is part of the ABI and MUST NOT change.

```solidity
struct PokeArgs {
  uint256[] offerIds;

  uint256 maxOffers;
}
```

Checklist:
- Keep the `PokeArgs` surface stable. It is intentionally explicit and bounded.
- Treat `offerIds` as a user-provided worklist (never iterate unbounded storage).

---

## poke(PokeArgs args)

Permissionless. Reference ABI: `function poke(PokeArgs calldata args) external nonReentrant`.

Revert surface (reference: `src/lib/Errors.sol`): constructor and `_requireCanonicalBundle()` use `Errors.ZeroAddress`, `Errors.NotAContract`, and `Errors.WiringMismatch` as implemented.

### Canonical preflight (MUST)

- At the start of `poke(args)`, re-resolve the live upkeep bundle and fail closed before any sub-action if the bundle no longer matches the canonical roots captured at deployment.
- Best-effort semantics apply only after this preflight succeeds.

### Bounded work (MUST)

- Let `maxOffersClamped = min(args.maxOffers, MAX_MAINTENANCE_OFFERS_PER_CALL)`.
- Let `offersN = min(args.offerIds.length, maxOffersClamped)`.
- Iterate only up to that computed limit.

### Best-effort execution (MUST)

After the canonical preflight passes, for every external sub-action:
- Wrap in `try/catch`.
- If it reverts, **continue** (do not revert the entire `poke`).

### Recommended sub-action order

The canonical spec lists the intended order. Implement in this order unless the canonical spec changes:

1) ve checkpoints (optional but recommended)
2) shareholder flush (optional but recommended)
3) Market sweep (always attempt)
4) Furnace tick (optional but recommended)

---

## Sub-action checklist

### 1) ve checkpoints

Best-effort call:
- `VeClaimNFT.checkpointGlobalState()`

Clarification (non-binding):
- Takeover already checkpoints, but this is a liveness backstop between takeovers.

### 2) Shareholder flush

Best-effort:
- `ShareholderRoyalties.flushPendingShareholderETH()`
- Do this before any auto-Furnace execution so pre-existing `pendingShareholderETH` is indexed against the pre-entry shareholder set whenever the ve checkpoint catches up in that same tx. If `globalLastTs()` remains stale, the flush no-ops and the pending ETH stays queued for a later attempt.

### 3) Market sweep

For `i` from `0` to `min(args.offerIds.length, maxOffersClamped) - 1`:
- `offerId = args.offerIds[i]`
- Skip `offerId == 0` (do not count as attempted).
- Otherwise increment attempted count, then call `MarketRouter.executeAutoFurnace(offerId, block.timestamp + _OFFER_DEADLINE_GRACE)` with a **gas-capped** low-level call (per implementation: `1_500_000` gas per offer, `_OFFER_DEADLINE_GRACE = 300` seconds); treat success as return status only (no bubbled revert).
- If remaining gas falls below the implementation’s offer loop buffer, stop iterating early (bounded work + liveness).
- Track attempted + succeeded counts.

### 4) Furnace tick

Best-effort:
- `Furnace.tick()` with a bounded gas stipend (per implementation: `500_000` gas forwarded to the call).

## WETH bounty forwarding (MUST)

The shipped implementation forwards the WETH **delta** accrued during the poke call:

- Let `wethBounty = WETH.balanceOf(address(this)) - wethBefore` after all sub-actions complete (where `wethBefore` is captured at entry; if the balance decreased, bounty is zero).
- If `wethBounty > 0`, attempt forwarding using `try IERC20(address(weth)).transfer(msg.sender, wethBounty)`. If the transfer fails, the WETH remains on the hub (no revert). Note: stuck WETH is captured in `wethBefore` on subsequent pokes, so it is **not** automatically included in later bounty deltas. It only leaves the hub when a later poke accrues new WETH delta that succeeds in transferring.

Rationale (non-binding, matches `MaintenanceHub.sol`): the hub forwards only the WETH delta accrued during the current `poke` call, ensuring keepers receive compensation proportional to the work performed. Using `try/catch` instead of `safeTransfer` ensures a failing WETH transfer does not revert the entire poke.

## Token rescue

- `rescueToken(IERC20 token)` — transfers the hub's entire balance of `token` to the immutable `rescueRecipient`.
- Callable by anyone (permissionless).
- MUST revert if `token` is the canonical `weth`.
- Purpose: recover ERC20 tokens accidentally sent to the hub (WETH is excluded — it is forwarded via bounty logic).

---

## Events (MUST)

Emit a single summary event (REQUIRED):

- `Poked(address caller, bool checkpointOk, bool flushOk, uint256 offersAttempted, uint256 offersSucceeded, bool furnaceTickSucceeded, uint256 bountyWethForwarded)`

Event requirements (MUST):
- `Poked(...)` MUST be emitted exactly once for every successful `poke(args)` call.
- `bountyWethForwarded` MUST equal the WETH amount transferred to the caller in that call (in the reference implementation: the delta `wethAfter - wethBefore`, i.e. only WETH accrued during this poke).
- `checkpointOk` MUST be true when `checkpointGlobalState()` succeeded.
- `flushOk` MUST be true when `flushPendingShareholderETH()` succeeded.

Implementation notes:
- Emission is REQUIRED for monitoring and keeper analytics.
- If an official analytics schema exists for this event, it MUST match.

---

## Minimum test checklist (derived)

- `poke(args)` does not revert if:
  - any single `executeAutoFurnace` reverts
  - `checkpointGlobalState()` reverts
  - shareholder flush reverts
  - furnace tick reverts

- Constructor / preflight hardening:
  - constructor rejects a foreign `MarketRouter.claim()` root even when `ve` / `royalties` look canonical on shallow checks
  - constructor rejects a foreign `Furnace.claim()` root even when `mineCore` / `ve` / `royalties` look canonical on shallow checks
  - constructor rejects a foreign `ShareholderRoyalties.mineCore()` root even when `furnace` / `marketRouter` look canonical on shallow checks
  - `poke(args)` reverts before any sub-action if `MarketRouter.claim()` drifts away from `VeClaimNFT.claimToken()`
  - `poke(args)` reverts before any sub-action if `Furnace.claim()` drifts away from the canonical `ClaimToken`
  - `poke(args)` reverts before any sub-action if `ShareholderRoyalties.mineCore()` drifts away from the canonical `MineCore`

- Order regression:
  - checkpoints run before shareholder flush
  - shareholder flush runs before market sweep so a new auto-Furnace entry cannot dilute older `pendingShareholderETH`

- Work is bounded:
  - respects `maxOffers`

- Bounty forwarding:
  - forwards only the WETH **delta** (`wethAfter - wethBefore`) accrued during poke to the caller via non-reverting `try/catch`
  - `bountyWethForwarded` in `Poked` matches the transferred amount
  - `checkpointOk` in `Poked` reflects the success of `checkpointGlobalState()`
  - `flushOk` in `Poked` reflects the success of `flushPendingShareholderETH()`

- Token rescue:
  - `rescueToken(token)` transfers the full token balance to `rescueRecipient`
  - reverts if `token` is WETH
