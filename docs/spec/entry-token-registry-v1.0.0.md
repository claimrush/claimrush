# Entry Token Registry – ClaimRush v1.0.0

**Status:** Normative for multi-token entry configuration and Furnace token-entry safety gating.

## Normative interpretation

- This document is normative for ClaimRush v1.0.0 multi-token entry configuration.
- Binding requirements are stated using MUST / MUST NOT / REQUIRED / NOT PART OF V1.0.0.
- Guidance language (including `recommended`, `should`, `may`, `optional`) is non-binding. Treat it as implementation and ops help only, unless restated as a binding requirement.

This document defines the **EntryTokenRegistry** contract and the operational policies around it.

EntryTokenRegistry enables **allowlisted entry tokens** while keeping ClaimRush’s canonical currencies unchanged:

- Takeover accounting currency: **ETH only**
- King and Baron payouts: **ETH only**
- Furnace output: **CLAIM only**
- Leaderboards/analytics: ETH-denominated for takeover spend and payout metrics (no per-entry-token leaderboards)

The registry (and its configured router, typically **DexAdapter**) is the primary new trust surface introduced by multi-token entry.

---

## 1) Purpose

EntryTokenRegistry provides a curated allowlist of ERC20 tokens that can be used to:

- enter the Furnace via `enterWithToken(tokenIn, amountIn, targetTokenId, durationSeconds, createAutoMax, minVeOut)`
  - swap `tokenIn -> CLAIM` (direct if configured, else via WETH)
- pay for takeovers via `takeoverWithToken(tokenIn, amountIn, minEthOut, maxPrice)`
  - swap `tokenIn -> WETH -> unwrap -> ETH`
  - then run the takeover logic unchanged using the resulting ETH
  - All MineCore takeover preconditions apply (including that the current King cannot takeover again).

Special-case: **WETH is always supported without allowlisting** (REQUIRED)

- `TokenConfig` explicitly forbids `tokenIn == wrappedNative` (WETH), so WETH MUST NOT be configured/enabled via this registry.
- Nevertheless, both core entrypoints MUST support WETH as a built-in boundary:
  - **MineCore**: `takeoverWithToken(wrappedNative, amountIn, minEthOut, maxPrice)` MUST pull WETH, unwrap 1:1 to ETH, set `ethOut = amountIn`, and enforce `ethOut >= minEthOut` (then proceed with the normal ETH takeover flow).
  - **Furnace**: `enterWithToken(wrappedNative, amountIn, ...)` MUST pull WETH, unwrap 1:1 to ETH, and proceed exactly like ETH entry (swap `ETH -> CLAIM` via the pinned `WETH -> CLAIM` hop).
  - Quoting helpers MUST treat WETH as equivalent to ETH input (1:1 unwrap), even though it is not present in registry token lists.


Key constraints:

- Allowlist only (not permissionless)
- No user-supplied swap routes, pools, or stable flags
- Routing is fixed and deterministic per token
- Every hop is validated against allowlisted pools using `router.poolFor(tokenA, tokenB, stableFlag, factory)`

---

## 2) Trust model

Core game contracts are intended to be **frozen/immutable in spirit** for gameplay and economics.

- Core contracts do **not** maintain a mutable token allowlist.
- Core contracts query EntryTokenRegistry at runtime to decide:
  - whether a token is enabled
  - whether direct `tokenIn -> CLAIM` is enabled
  - which allowlisted pools/stable flags are allowed per hop (validated via `router.poolFor(...)`)

Router indirection (REQUIRED in v1.0.0):

- EntryTokenRegistry stores a single `router` pointer. In v1.0.0 this `router` MUST point to **DexAdapter** (a router adapter implementing the minimal `IAerodromeRouter` subset documented in the Aerodrome appendix).
- At launch, DexAdapter may delegate to the raw Aerodrome v2 router internally, but the protocol roots/runtime should not be permanently bound to any specific DEX implementation.

DEX routing changes (how to evolve routing without changing the core):

- v1.0.0 uses a **non-upgradeable** DexAdapter (no proxy upgrades).
- Router/DEX changes MUST ship via **redeploying DexAdapter** and **calling `EntryTokenRegistry.setRouterConfig(...)` through the live owner() path (typically timelocked in production)**.
  - Once the global WETH/CLAIM hop or any per-token pool config has been set, `router` and `factory` MUST NOT be changed in place.
  - Route changes after route configuration MUST use a fresh registry deployment, followed by rewiring the consuming core contract via timelocked owner setters.
  - Incident response: GUARDIAN can disable individual tokens immediately via `setTokenEnabled(token, false)`; OWNER can rotate the guardian key at any time.

Security notes (MUST):

- DexAdapter redeploy + registry rewire is **high-trust** and MUST be governed through the live `owner()` path, with production policy expecting multisig + timelock.
- DexAdapter MUST be minimally custodial and MUST NOT include generic sweep/rescue/admin-drain functions. The shipped v1.0.0 DexAdapter includes bounded owner-only recovery: `rescueETH(address payable to)` for native ETH and `rescueToken(IERC20 token, address to)` for ERC-20 tokens stuck from Aerodrome router refunds. See `spec-v1.0.0.md` §10.4 for the full exception rationale.

EntryTokenRegistry is governed by:

- **OWNER (ADMIN)**
  - In production, deployment policy expects the live `owner()` path to be the **ADMIN timelock** (timelock controlled by a multisig). Contracts themselves enforce only `owner()`.
  - Owner governs additions and configuration changes.

- **GUARDIAN (disable-only token toggles; self-rotation fast path)**
  - A separate address for fast incident response.
  - Guardian can **disable tokens immediately** (set `enabled=false`).
  - Guardian MUST NOT be able to enable tokens.
  - Guardian MUST NOT be able to change router/factory/WETH/CLAIM config.
  - Guardian MAY rotate the guardian key via `setGuardian(address)` (emergency fast path only; not a routing/config power).

Operational intent (REQUIRED):

- **Additions are timelocked** (owner = timelock).
- **Disables are immediate** (guardian disable-only).

---

## 3) Locked interface and config schema (normative)

This section pins the **exact** public/external API and the ABI-visible structs/events used by:
- Furnace (`enterWithToken`, quoting)
- MineCore (`takeoverWithToken`)
- UI + indexers (token list + transparency)
- Dune/Subgraph decoding

### 3.0 Registry instances and policy separation (v1.0.0)

In v1.0.0, `TokenConfig.enabled` gates BOTH Furnace and takeover route resolution **within a given registry instance**.

- Furnace reads `enabled` from the registry address wired into Furnace.
- MineCore reads `enabled` from the registry address wired into MineCore.

Those registry addresses MUST be different (policy split).

Required deployment pattern (policy split without changing the ABI):

- Deploy **two** EntryTokenRegistry instances:
  - `FurnaceEntryTokenRegistry`: tokens allowed for Furnace entry (may include stablecoins for onboarding).
  - `MineCoreEntryTokenRegistry`: tokens allowed for `takeoverWithToken` (recommended to start empty, or extremely conservative).

Do NOT wire the **same** registry into both Furnace and MineCore. That would couple onboarding-token policy with takeover-token policy.

MineCore-only registry special case (clarification):
- If a registry instance is wired only into MineCore (takeoverWithToken only), the global `WETH -> CLAIM` hop is not required.
- The `WETH -> CLAIM` hop is required only for Furnace ETH entry and Furnace via-WETH routes.
- Accordingly, EntryTokenRegistry only requires router config to be initialized. Furnace enforces at runtime that its wired registry has a live `WETH -> CLAIM` hop and that `MarketRouter.royalties()` matches `Furnace.shareholderRoyalties()`.

(ETH entry is always allowed and does not go through the registry.)

### 3.1 RouterConfig (global)

**Write API (MUST exist):**
- `function setRouterConfig(address router, address factory, address wrappedNative, address claimToken) external;`
  - after any WETH/CLAIM hop or per-token config exists, `setRouterConfig(...)` MUST revert if `router` or `factory` changes

**Read API (MUST exist):**
- `function getRouterConfig() external view returns (address router, address factory, address wrappedNative, address claimToken);`

**Required validations (MUST):**
- `router != address(0)`, `factory != address(0)`, `wrappedNative != address(0)`, `claimToken != address(0)`
- `router`, `factory`, `wrappedNative`, and `claimToken` MUST all be live contracts (not EOAs / undeployed addresses)
- `factory` MUST equal `IDexAdapter(router).defaultFactory()`
- `wrappedNative` MUST equal `IDexAdapter(router).weth()`
- `wrappedNative` and `claimToken` MUST be immutable after initialization:
  - subsequent `setRouterConfig(...)` calls MUST supply the same `wrappedNative` and `claimToken` values, or revert
  - after any WETH/CLAIM hop or per-token config exists, subsequent `setRouterConfig(...)` calls MUST also keep the same `router` and `factory`, or revert
- emit `RouterConfigSet(router, factory, wrappedNative, claimToken)`

### 3.2 Canonical WETH/CLAIM hop (global)

This hop is used by:
- the Furnace ETH entry boundary (`WETH -> CLAIM`)
- any token entry route that goes `tokenIn -> WETH -> CLAIM`

**Write API (MUST exist):**
- `function setWethClaimHop(bool stable, address expectedPool) external;`

**Read API (MUST exist):**
- `function getWethClaimHop() external view returns (bool stable, address pool);`

**Required validations (MUST):**
- `expectedPool != address(0)`
- MUST validate:
  - `router.poolFor(wrappedNative, claimToken, stable, factory) == expectedPool`
- `expectedPool` MUST be a live pool contract (not merely a deterministic address that has not been deployed yet)
- emit `WethClaimPoolSet(expectedPool, stable)`

### 3.3 Per-token config (TokenConfig)

**ABI-visible struct (MUST exist):**

```solidity
struct TokenConfig {
    bool enabled;                // v1.0.0: gates BOTH resolve paths inside this registry instance
    bool directToClaimEnabled;   // Furnace-only: if true, use tokenIn -> CLAIM hop
    bool tokenClaimStable;       // hop stable flag for tokenIn -> CLAIM
    address tokenClaimPool;      // allowlisted pool for tokenIn -> CLAIM
    bool tokenWethStable;        // hop stable flag for tokenIn -> WETH
    address tokenWethPool;       // allowlisted pool for tokenIn -> WETH
}
```

**Write API (MUST exist):**
- `function setTokenConfig(address tokenIn, bool enabled, bool directToClaimEnabled, bool tokenClaimStable, address tokenClaimPool, bool tokenWethStable, address tokenWethPool) external;`
- `function setTokenEnabled(address tokenIn, bool enabled) external;` (fast path)

**Read API (MUST exist):**
- `function getTokenConfig(address tokenIn) external view returns (TokenConfig memory);`

**Required validations (MUST):**
- `tokenIn != address(0)`
- `tokenIn` MUST be a live ERC20 contract
- `tokenIn != claimToken` and `tokenIn != wrappedNative`
- if `directToClaimEnabled == true`:
  - `tokenClaimPool != address(0)`
  - MUST validate:
    - `router.poolFor(tokenIn, claimToken, tokenClaimStable, factory) == tokenClaimPool`
  - `tokenClaimPool` MUST be a live pool contract
- always (for takeover, and for Furnace via-WETH route):
  - `tokenWethPool != address(0)`
  - MUST validate:
    - `router.poolFor(tokenIn, wrappedNative, tokenWethStable, factory) == tokenWethPool`
  - `tokenWethPool` MUST be a live pool contract

**Events (MUST emit):**
- On full config update: `TokenConfigSet(tokenIn, enabled, directToClaimEnabled, tokenClaimStable, tokenClaimPool, tokenWethStable, tokenWethPool)`
- On fast enable/disable: `TokenEnabledChanged(tokenIn, enabled)`

### 3.3.1 Furnace exact-receipt safety bit

Non-WETH Furnace token entry is an explicit opt-in surface. A token must be marked as exact-receipt safe before a non-WETH Furnace route can resolve. This closes the quote/execution parity gap where a configured fee-on-transfer or rebasing token could produce a Furnace quote even though execution normalizes to the actual received balance.

**Write API (MUST exist):**
- `function setFurnaceEntryTokenExactReceiptSafe(address tokenIn, bool exactReceiptSafe) external;`

**Read API (MUST exist):**
- `function isFurnaceEntryTokenExactReceiptSafe(address tokenIn) external view returns (bool);`

**Event (MUST emit):**
- `event FurnaceEntryTokenSafetySet(address indexed tokenIn, bool exactReceiptSafe);`

**Error:**
- `error UnsafeEntryToken();`

**Semantics (MUST):**
- The Furnace exact-receipt safety bit MUST default to `false`.
- `setTokenConfig(...)` MUST NOT auto-enable the Furnace safety bit.
- `setTokenEnabled(tokenIn, false)` MUST NOT clear the Furnace safety bit.
- Only `owner()` may change the Furnace safety bit.
- The setter MUST reject invalid token addresses using the same token identity constraints as the main token-config surface.

### 3.4 RegistryRoute struct + route type codebook

Route resolution functions return a deterministic hop list using the ABI-visible struct:

```solidity
struct RegistryRoute {
    address tokenIn;
    address tokenOut;
    bool stable;
    address pool; // MUST equal router.poolFor(tokenIn, tokenOut, stable, factory)
}
```

> **WARNING (type collision):** `RegistryRoute` is **NOT** the same type as the Aerodrome router swap route (`IAerodromeRouter.Route`).
> - `RegistryRoute` includes an explicit allowlisted `pool` address for *validation/review*.
> - `IAerodromeRouter.Route` includes a `factory` field for swap execution and does **not** include `pool`.
> - These types are **not interchangeable**.

Mapping example (RegistryRoute → RouterRoute / `IAerodromeRouter.Route`):

```solidity
// Convert allowlisted RegistryRoute hops into router swap routes.
// Clarification: r.pool is used only for validation (poolFor match) and is not passed into the router Route.
IAerodromeRouter.Route[] memory routerRoutes = new IAerodromeRouter.Route[](registryRoutes.length);
for (uint256 i = 0; i < registryRoutes.length; ++i) {
    RegistryRoute memory r = registryRoutes[i];
    routerRoutes[i] = IAerodromeRouter.Route({
        from: r.tokenIn,
        to: r.tokenOut,
        stable: r.stable,
        factory: factory // v1.0.0: router.defaultFactory()
    });
}
```

`routeTokenId` codebook (MUST be stable once deployed):
- `0` = `DIRECT_TO_CLAIM` (single hop `tokenIn -> CLAIM`)
- `1` = `VIA_WETH` (two hops `tokenIn -> WETH -> CLAIM`)

---

## 4) Route resolution (normative)

Route resolution exists to:
- prevent user-supplied routing
- keep execution and quoting aligned (UI, contracts, analytics)
- keep all hops allowlisted and validated

### 4.1 Furnace route resolution

**Signature (MUST exist):**
- `function resolveFurnaceRoute(address tokenIn) external view returns (RegistryRoute[] memory route, uint256 routeTokenId);`

**Semantics (MUST):**
- MUST revert if `tokenIn` is not enabled.
- MUST revert `UnsafeEntryToken()` unless `isFurnaceEntryTokenExactReceiptSafe(tokenIn) == true`.
- If `directToClaimEnabled` is true:
  - return a 1-hop route:
    - `route[0] = { tokenIn, claimToken, tokenClaimStable, tokenClaimPool }`
  - return `routeTokenId = 0`
- Else (via-WETH):
  - MUST revert if the global WETH/CLAIM hop is not configured.
  - return a 2-hop route:
    - `route[0] = { tokenIn, wrappedNative, tokenWethStable, tokenWethPool }`
    - `route[1] = { wrappedNative, claimToken, wethClaimStable, wethClaimPool }`
  - return `routeTokenId = 1`

### 4.2 Takeover route resolution

**Signature (MUST exist):**
- `function resolveTakeoverRoute(address tokenIn) external view returns (RegistryRoute[] memory route);`

**Semantics (MUST):**
- MUST revert if `tokenIn` is not enabled.
- `resolveTakeoverRoute(tokenIn)` MUST ignore the Furnace exact-receipt safety bit. Takeover token support is governed solely by the shared token config and takeover route validations.
- return a 1-hop route:
  - `route[0] = { tokenIn, wrappedNative, tokenWethStable, tokenWethPool }`
- MineCore MUST unwrap `wrappedNative` to ETH and then run the identical ETH takeover flow.

### 4.3 Furnace / Quoter alignment

- Furnace MUST check the same safety predicate before attempting non-WETH token custody.
- FurnaceQuoter MUST rely on `resolveFurnaceRoute(...)` for non-WETH token quotes so quote availability and execution availability stay aligned.
- WETH MUST remain exempt from this gate because it follows the dedicated unwrap path, not the registry-driven ERC20 custody path.

---

## 5) What core contracts read from the registry

EntryTokenRegistry is read by:

- **Furnace**
  - decides whether `tokenIn` is enabled for entry
  - decides whether the route is direct `tokenIn -> CLAIM` or via WETH
  - validates each hop via `poolFor` and the allowlisted pool address

- **MineCore**
  - decides whether `tokenIn` is enabled for takeover
  - validates the `tokenIn -> WETH` hop via `poolFor` and allowlisted pool address

Integration transparency (required):
- MineCore and Furnace MUST each expose a one-time wiring setter for the registry pointer and emit:
  - `EntryTokenRegistrySet(address indexed registry)`
(See `docs/spec/spec-v1.0.0.md` and `docs/analytics/dune-integration-pack-v1.0.0.md`.)

---

## 6) What offchain systems read from the registry (UI, indexers)

To support “auto-adapting UI” and external dashboards:

- UIs MUST NOT hardcode token lists.
- **Clarification:** `wrappedNative` (WETH) is an implicit option (handled in core contracts) and may not appear in the registry token list.
- The shipped v1.0.0 registry does **not** expose an onchain enumeration getter.
- UIs and indexers derive the token universe from `TokenConfigSet` / `TokenEnabledChanged` events (preferred) and/or deployment metadata, then read `getTokenConfig(tokenIn)` for known addresses.

If Furnace and MineCore are wired to different registry instances:

- UIs MUST read the Furnace token list from the registry emitted by `Furnace.EntryTokenRegistrySet(...)`.
- UIs MUST read the takeover token list from the registry emitted by `MineCore.EntryTokenRegistrySet(...)`.

Recommended read surface (shipped in this repo):

- `getTokenConfig(tokenIn) -> TokenConfig`
- `getRouterConfig() -> (router, factory, wrappedNative, claimToken)`
- `getWethClaimHop() -> (stable, pool)`

Clarification (non-binding):

- Discovered token addresses are ERC20 tokens only (not ETH).
- UI should always prepend an `ETH` option to the computed list.
- Token metadata (symbol/decimals/icon) is not required to be stored in the registry; UI can read ERC20 metadata offchain and cache.

---

## 7) Governance controls

EntryTokenRegistry MUST expose governance controls to:

- set global router configuration (OWNER)
- list/configure a token (OWNER)
- rotate the guardian key (OWNER; current GUARDIAN also allowed as the documented emergency fast path)
- disable a token immediately (GUARDIAN, disable-only)

Production ownership (REQUIRED):

- Production deployment policy expects OWNER to be the **ADMIN timelock** (timelock controlled by a multisig). Contracts themselves enforce only the live `owner()` address.
- GUARDIAN MUST be a separate key/address.

Immediate disables (REQUIRED):

- GUARDIAN MUST be able to disable tokens immediately via `setTokenEnabled(tokenIn, false)`.
- GUARDIAN MUST NOT be able to enable tokens:
  - `setTokenEnabled(tokenIn, true)` MUST revert when called by GUARDIAN.

Guardian disable cooldown (REQUIRED):

- When GUARDIAN disables a token, the registry MUST set a 1-hour cooldown (`GUARDIAN_DISABLE_COOLDOWN = 1 hours`) during which the OWNER cannot re-enable that token.
- Both `setTokenEnabled(tokenIn, true)` and `setTokenConfig(tokenIn, enabled=true, ...)` MUST respect this cooldown and revert if `guardianDisabledUntil[tokenIn] > block.timestamp`.
- This prevents the OWNER from immediately overriding a GUARDIAN emergency disable, giving the incident response team time to escalate.
- After the cooldown expires, the OWNER may re-enable the token normally.

Config restrictions (REQUIRED):

- GUARDIAN MUST NOT be able to change router/factory/WETH/CLAIM config.
- GUARDIAN MUST NOT be able to change pools or stable flags.

Guardian rotation (REQUIRED):

- OWNER MUST be able to rotate the guardian key at any time (for example via `setGuardian(address)`), and the change MUST emit an indexable event (e.g. `GuardianChanged`).
- v1.0.0 also allows the current GUARDIAN to rotate itself via `setGuardian(address)` (emergency fast path; avoids waiting on owner-path governance delay).
- `setGuardian` MUST reject `address(0)` and `address(this)` (the registry contract itself cannot act as guardian).
- `setGuardian` MUST reject EIP-7702 delegated EOAs — addresses whose code is exactly the 23-byte designator `0xef0100 || target` revert `DelegatedEOA`. Bare EOAs (`code.length == 0`) and ordinary contracts pass. The 7702 signer can replace the executor running at the address at any time, so admitting one would expose a public guardian-only token-disable / rotation surface to whoever currently runs as code there.

---

## 8) Listing a new token (required policy)

Governance (REQUIRED):
- Listing/configuring/enabling tokens MUST be executed by OWNER through the live `owner()` path (production policy expects the ADMIN timelock).

Allowlisting is not permissionless.

Before listing a token:

- **Token behavior checks (required)**
  - No fee-on-transfer (FOT) behavior
  - No rebasing
  - No ERC777-style hooks or callback transfer behavior
  - No non-standard `transfer/transferFrom` behavior

- **Liquidity + routing checks (required)**
  - Confirm there is sufficient liquidity in the intended Aerodrome pool(s)
  - Decide stable vs volatile per hop
  - Compute the expected pool via `router.poolFor(tokenA, tokenB, stable, factory)`
  - Only allow pools that match the expected `poolFor` result

- **Operational readiness (required)**
  - Monitoring in place for pool liquidity, swap failure rate, and revert spikes
  - Clear process to disable the token quickly if needed

On-chain configuration steps (conceptual):

1. Add token config in EntryTokenRegistry (disabled by default).
2. Validate `poolFor` matches allowlisted pools for each enabled hop.
3. Enable token.

BASE example:

- `BASE` may be allowlisted as `tokenIn`.
- If no `BASE/CLAIM` pool exists at launch, configure:
  - Furnace route: `BASE -> WETH -> CLAIM`
  - Takeover route: `BASE -> WETH -> ETH`

---

## 9) Disabling a token (required policy)

EntryTokenRegistry MUST be able to disable a token quickly.

In production, token disables MUST be executable immediately via GUARDIAN (disable-only) (see §7).

When disabled (in the relevant registry instance):

- If disabled in the registry wired into **Furnace**, `enterWithToken(tokenIn, ...)` MUST revert for that token.
- If disabled in the registry wired into **MineCore**, `takeoverWithToken(tokenIn, ...)` MUST revert for that token.

If you want to disable a token everywhere and you are using two registries, disable it in both.

Reasons to disable:

- pool liquidity collapse
- token exploit or unsafe transfer behavior discovered
- routing pool becomes unreliable

---

## 10) Slippage and user protection

Furnace:

- Slippage protection remains `minVeOut`.
- Router swaps should not take user routes; the contract enforces `minVeOut` on the entry-attributable `veOut` for the newly locked amount.

TakeoverWithToken:

- MUST accept a user slippage parameter such as `minEthOut`.
- The contract MUST revert if `ethOut < minEthOut`.
- The takeover price check uses **post-swap ETH**:
  - `require(ethOut >= currentTakeoverPrice)`
- MineCore charges only the current takeover price (`pricePaid = currentTakeoverPrice`). Any excess `ethOut - pricePaid` MUST be returned or credited (hybrid refund).

Leaderboards:

- Leaderboards remain ETH-denominated for takeover spend and payout metrics (no per-entry-token leaderboards).
- The canonical takeover spend metric is `pricePaid` in the `Takeover` event.
- For token entry, `pricePaid` is the charged current takeover price. Post-swap ETH above `pricePaid` is excess and is returned/credited.

---

## 11) Summary

EntryTokenRegistry introduces curated multi-token entry while preserving:

- ETH accounting and payout
- CLAIM-only Furnace output
- ETH-only leaderboards

All routing remains fixed, allowlisted, and validated via `poolFor`.
