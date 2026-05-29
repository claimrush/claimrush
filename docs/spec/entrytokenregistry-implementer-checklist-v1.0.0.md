# EntryTokenRegistry implementer checklist (v1.0.0)

This is an **implementer-focused checklist** for `EntryTokenRegistry`, the allowlist + deterministic-route surface used by:
- Furnace token entry (`enterWithToken` route resolution)
- MineCore takeover entry (`takeoverWithToken` route resolution)

Source of truth:
- EntryTokenRegistry spec: `docs/spec/entry-token-registry-v1.0.0.md`
- Aerodrome integration (pool validation): [Aerodrome integration appendix](../architecture/aerodrome-integration-appendix-v1.0.0.md)
- Constants + canonical token addresses: `src/lib/Constants.sol`
- Integration transparency + schema: `docs/analytics/dune-integration-pack-v1.0.0.md`

Spec aids (recommended):
- `docs/spec/spec-quality-standard-v1.0.0.md`
- `docs/spec/dexadapter-implementer-checklist-v1.0.0.md`
- `docs/manuals/developer/security-guardian-pausing.md`
- Operational security runbook (see operational documentation)
- `docs/spec/state-machines-v1.0.0.md`
- `docs/spec/test-vectors-v1.0.0.md`

This document **does not introduce new rules**. It restates MUST/MUST NOT requirements in an order suitable for incremental implementation and review.

---

## Goals

`EntryTokenRegistry` MUST:
- Be an **allowlist** (not permissionless listing).
- Provide deterministic, validated routes:
  - no user-supplied routes
  - no user-supplied pool selection
  - no user-supplied stable flags
- Validate every allowlisted hop using `router.poolFor(...) == expectedPool`.
- Support policy separation by allowing **two independent registry instances** (REQUIRED in v1.0.0):
  - one wired to Furnace
  - one wired to MineCore

`EntryTokenRegistry` MUST NOT:
- Become a custodial contract.
- Introduce swap execution logic (it only resolves + validates routes).

**Constants:** `EntryTokenRegistry` does not import or read `src/lib/Constants.sol`. No entries in that library are registry configuration inputs; treat this contract’s storage and router bindings as the source of truth for routing.

---

## Checklist: core storage + schema

### Ownership + guardian (contract surface)

The concrete `EntryTokenRegistry` inherits OpenZeppelin `Ownable2Step` / `Ownable` (two-step ownership transfer).

MUST exist:
- `constructor(address initialOwner)` — rejects `initialOwner == address(0)`; sets `Ownable(initialOwner)` and defaults `guardian = initialOwner` until rotated.
- `address public guardian` — auto-generated `guardian()` getter on the implementation (not declared on `IEntryTokenRegistry`; still part of the deployed ABI).
- `uint256 public constant GUARDIAN_DISABLE_COOLDOWN = 1 hours` — cooldown period after a guardian disable during which the owner cannot re-enable.
- `mapping(address => uint256) public guardianDisabledUntil` — per-token timestamp until which re-enabling is blocked.
- `setGuardian(address guardian) external` (declared on `IEntryTokenRegistry`) — callable by `owner()` **or** current `guardian`; `guardian != address(0)` and `guardian != address(this)`.

MUST emit:
- `GuardianChanged(address indexed oldGuardian, address indexed newGuardian)` (canonical definition in `src/lib/Events.sol`; contract emits via `Events.GuardianChanged`).

MUST NOT:
- `renounceOwnership()` — implementation overrides to always revert (prevents accidental permanent admin lock-out).

### RouterConfig (global)

Checklist:
- Store the RouterConfig fields:
  - `router`
  - `factory`
  - `wrappedNative` (WETH)
  - `claimToken` (CLAIM)

MUST exist:
- `setRouterConfig(address router, address factory, address wrappedNative, address claimToken) external` — `onlyOwner`
- `getRouterConfig() external view -> (address router, address factory, address wrappedNative, address claimToken)`

MUST validate on set:
- none are `address(0)`
- `router`, `factory`, `wrappedNative`, and `claimToken` MUST all be live contracts
- `factory` MUST equal `IDexAdapter(router).defaultFactory()`
- `wrappedNative` MUST equal `IDexAdapter(router).weth()`
- `wrappedNative` and `claimToken` MUST be immutable after initialization:
  - subsequent `setRouterConfig(...)` calls MUST supply the same `wrappedNative` and `claimToken` values, or revert
  - once the global WETH/CLAIM hop or any per-token config has been written, subsequent `setRouterConfig(...)` calls MUST also keep the same `router` and `factory`, or revert
- implementation MUST reject ambiguous wiring: `router` MUST NOT equal `factory`, `wrappedNative`, or `claimToken`; `factory` MUST NOT equal `wrappedNative` or `claimToken`; `wrappedNative` MUST NOT equal `claimToken`

MUST emit:
- `RouterConfigSet(address indexed router, address indexed factory, address indexed wrappedNative, address claimToken)` (canonical in `src/lib/Events.sol`; `claimToken` is not indexed)

### WETH/CLAIM hop (global)

This hop is used by:
- Furnace ETH entry boundary (`WETH -> CLAIM`)
- any route that resolves `tokenIn -> WETH -> CLAIM`

MUST exist:
- `setWethClaimHop(bool stable, address expectedPool) external` — `onlyOwner`
- `getWethClaimHop() external view -> (bool stable, address pool)`

MUST validate on set:
- `expectedPool != address(0)`
- `router.poolFor(wrappedNative, claimToken, stable, factory) == expectedPool`
- `expectedPool` MUST have live code at bind time

MUST emit:
- `WethClaimPoolSet(address indexed pool, bool stable)` (canonical in `src/lib/Events.sol`; argument order is **pool**, then **stable**)

### TokenConfig (per token)

ABI-visible struct MUST match:

```solidity
struct TokenConfig {
    bool enabled;                // v1.0.0: applies to BOTH takeover + Furnace entry (same as IEntryTokenRegistry)
    bool directToClaimEnabled;   // Furnace-only: if true, use tokenIn -> CLAIM hop
    bool tokenClaimStable;       // hop stable flag for tokenIn -> CLAIM
    address tokenClaimPool;      // allowlisted pool for tokenIn -> CLAIM
    bool tokenWethStable;        // hop stable flag for tokenIn -> WETH
    address tokenWethPool;       // allowlisted pool for tokenIn -> WETH
}
```

MUST exist:
- `setTokenConfig(address tokenIn, bool enabled, bool directToClaimEnabled, bool tokenClaimStable, address tokenClaimPool, bool tokenWethStable, address tokenWethPool) external` — `onlyOwner`
- `setFurnaceEntryTokenExactReceiptSafe(address tokenIn, bool exactReceiptSafe) external` — `onlyOwner`
- `setTokenEnabled(address tokenIn, bool enabled) external` (fast path) — callable by `owner()` (enable or disable) **or** `guardian` (**disable only**; enabling as guardian MUST revert). When guardian disables, MUST set `guardianDisabledUntil[tokenIn] = block.timestamp + GUARDIAN_DISABLE_COOLDOWN` (1 hour). Owner enable MUST revert if `guardianDisabledUntil[tokenIn] > block.timestamp`.
- `getTokenConfig(address tokenIn) external view -> TokenConfig memory`
- `isFurnaceEntryTokenExactReceiptSafe(address tokenIn) external view -> bool`

MUST validate on set:
- `tokenIn != address(0)`
- `tokenIn` MUST be a live ERC20 contract
- `tokenIn` MUST NOT equal `claimToken`, `wrappedNative`, the registry contract itself, `router`, or `factory`
  - (Reminder: WETH is handled as a special-case in MineCore/Furnace and MUST work without being configured as `tokenIn`.)
- if `directToClaimEnabled == true`:
  - `tokenClaimPool != address(0)`
  - `router.poolFor(tokenIn, claimToken, tokenClaimStable, factory) == tokenClaimPool`
  - `tokenClaimPool` MUST have live code at bind time
- always:
  - `tokenWethPool != address(0)`
  - `router.poolFor(tokenIn, wrappedNative, tokenWethStable, factory) == tokenWethPool`
  - `tokenWethPool` MUST have live code at bind time

MUST emit:
- `TokenConfigSet(address indexed tokenIn, bool enabled, bool directToClaimEnabled, bool tokenClaimStable, address tokenClaimPool, bool tokenWethStable, address tokenWethPool)` (canonical in `src/lib/Events.sol`)
- `FurnaceEntryTokenSafetySet(address indexed tokenIn, bool exactReceiptSafe)` (canonical in `src/lib/Events.sol`)
- `TokenEnabledChanged(address indexed tokenIn, bool enabled)` (canonical in `src/lib/Events.sol`)

---

## Checklist: route structs + codebook

### RegistryRoute struct

MUST exist and match:

```solidity
struct RegistryRoute {
    address tokenIn;
    address tokenOut;
    bool stable;
    address pool; // MUST equal router.poolFor(tokenIn, tokenOut, stable, factory)
}
```

WARNING:
- `RegistryRoute` is NOT the same as the Aerodrome router `Route` type.
- The `pool` field exists for traceability + validation and MUST NOT be treated as interchangeable with router execution types.

### routeTokenId codebook

MUST remain stable once deployed:
- `0` = `DIRECT_TO_CLAIM` (single hop `tokenIn -> CLAIM`)
- `1` = `VIA_WETH` (two hops `tokenIn -> WETH -> CLAIM`)

---

## Checklist: route resolution

### resolveFurnaceRoute(tokenIn)

MUST exist:
- `resolveFurnaceRoute(address tokenIn) external view -> (RegistryRoute[] memory route, uint256 routeTokenId)`

MUST:
- Revert if `tokenIn` was never configured (e.g. no `tokenWethPool` stored).
- Revert if `tokenIn` is configured but not enabled.
- Revert `UnsafeEntryToken()` if `tokenIn` is configured and enabled but not marked Furnace exact-receipt safe.
- Revert on forbidden or invalid `tokenIn` the same way as configuration: `address(0)`, non-contract, or `tokenIn` equal to CLAIM, wrapped native, registry, router, or factory.
- Revert if router, factory, wrapped native, or CLAIM token is unset (all four must be non-zero before resolution).

If `directToClaimEnabled == true`:
- Return a 1-hop route:
  - `{ tokenIn, claimToken, tokenClaimStable, tokenClaimPool }`
- Return `routeTokenId = 0`.

Else (via-WETH):
- MUST revert if the global WETH/CLAIM hop is not configured.
- Return a 2-hop route:
  - `{ tokenIn, wrappedNative, tokenWethStable, tokenWethPool }`
  - `{ wrappedNative, claimToken, wethClaimStable, wethClaimPool }`
- Return `routeTokenId = 1`.

### resolveTakeoverRoute(tokenIn)

MUST exist:
- `resolveTakeoverRoute(address tokenIn) external view -> (RegistryRoute[] memory route)`

MUST:
- Revert if `tokenIn` was never configured.
- Revert if `tokenIn` is configured but not enabled.
- Revert on forbidden or invalid `tokenIn` (same rules as `resolveFurnaceRoute`).
- Require router config to be set before resolving.
- Return a 1-hop route:
  - `{ tokenIn, wrappedNative, tokenWethStable, tokenWethPool }`

Integration note:
- MineCore MUST unwrap `wrappedNative` to ETH and then run the identical ETH takeover flow.

---

## Checklist: integration transparency (derived)

In v1.0.0, Furnace and MineCore use different registry instances (REQUIRED):
- UI/indexers MUST read the Furnace token list from the registry emitted by `Furnace.EntryTokenRegistrySet(...)`.
- UI/indexers MUST read the takeover token list from the registry emitted by `MineCore.EntryTokenRegistrySet(...)`.

---

## Checklist: governance + operations (derived)

MUST:
- In production, deployment policy expects the live `owner()` path to be the ADMIN timelock (timelock controlled by a multisig). On-chain, structural config (`setRouterConfig`, `setWethClaimHop`, `setTokenConfig`) is `onlyOwner`; `setTokenEnabled` additionally allows `guardian` for **disable-only**; `setGuardian` allows `owner()` or the current `guardian`.
- Additions/config edits MUST be timelocked (owner action).
- GUARDIAN disables MUST remain immediate and disable-only (cannot enable tokens).
- Guardian disable MUST set a 1-hour cooldown (`guardianDisabledUntil[tokenIn]`) blocking owner re-enable. Both `setTokenEnabled(enabled=true)` and `setTokenConfig(enabled=true)` MUST respect this cooldown.
- Ensure disabling a token is fast (use `setTokenEnabled`).

Operational intent:
- Listing new tokens is a deliberate governance action.
- Disabling a token MUST be fast when liquidity breaks or a token is found unsafe.

---

## Listing policy mini-checklist (derived)

Before listing a token, the spec requires conservative safety checks.

At minimum, confirm:
- No fee-on-transfer behavior.
- No rebasing or elastic-supply behavior.
- No ERC777-style hooks, callback transfer behavior, or non-standard balance accounting.
- Blacklist/freeze controls, compliance gates, and admin-controlled transfer restrictions have been reviewed and accepted.
- Proxy/admin upgradeability has been reviewed; proxy-backed tokens have an explicit upgrade monitor and periodic governance re-review, recommended at least every 90 days.
- Pools are correct for the `stable` flag and validate with `poolFor(...)`.
- Liquidity + slippage are acceptable for the intended user flows.
