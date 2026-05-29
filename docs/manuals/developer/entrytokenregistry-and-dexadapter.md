# EntryTokenRegistry and DexAdapter

`EntryTokenRegistry` is the allowlist and deterministic routing table for multi-token entry. It controls which tokens can be used to enter the [Furnace](furnace.md) or take over the Crown, and how they swap to CLAIM or ETH. `DexAdapter` wraps the Aerodrome v2 router to keep the direct roots and proxy-backed runtime decoupled from a specific DEX.

It enables:
- Furnace.enterWithToken(tokenIn, amountIn, ...): tokenIn -> CLAIM (direct or via WETH)
- MineCore.takeoverWithToken(tokenIn, amountIn, minEthOut, maxPrice): tokenIn -> WETH -> unwrap -> ETH

Key constraints (v1.0.0):
- no user-supplied routes
- allowlist only
- every hop is validated against allowlisted pools via router.poolFor(...)

Critical token-safety policy:
- fee-on-transfer tokens MUST NOT be allowlisted
- rebasing / elastic-supply tokens MUST NOT be allowlisted
- ERC777-style transfer hooks or callback transfer behavior MUST NOT be allowlisted
- blacklist/freeze controls, proxy upgradeability, and admin-controlled transfer behavior MUST be reviewed before listing
- proxy-backed tokens MUST have an explicit upgrade monitor and a periodic governance re-review, recommended at least every 90 days
- only standard ERC20s with fixed balances and vanilla transfer semantics should be enabled in either registry instance

Furnace exact-receipt-safe opt-in (separate, owner-only):
- The registry stores a per-token `isFurnaceEntryTokenExactReceiptSafe(tokenIn)` flag, set via `setFurnaceEntryTokenExactReceiptSafe(tokenIn, exactReceiptSafe)` (`onlyOwner`). It is **independent** from `enabled` and from the per-token route config.
- Defaults to `false`. A token can be `enabled` for takeovers and via-WETH route inspection without being marked exact-receipt-safe; that combination explicitly **denies** non-WETH Furnace entry until governance opts in.
- The flag is the canonical fail-closed gate, enforced in **two places**:
  - `EntryTokenRegistry.resolveFurnaceRoute(tokenIn)` reverts `UnsafeEntryToken` if `false`. This is what `FurnaceQuoter.quoteEnterWithToken(...)` and SDK `resolveFurnaceEntryRoute({ tokenIn })` indirectly call, so quotes also revert (no quote-then-fail surprises for integrators).
  - `Furnace.enterWithToken(tokenIn, amountIn, ...)` calls `reg.isFurnaceEntryTokenExactReceiptSafe(tokenIn)` directly inside `_receiveEntryToken` and reverts `UnsafeEntryToken` before any pull/swap. Beyond that, `Furnace` then uses **balance-delta** accounting on the inbound transfer, so any discrepancy between `amountIn` and the actually-credited delta is impossible to hide downstream.
- WETH is exempt from this flag — `Furnace.enterWithToken(WETH, ...)` runs the explicit unwrap path and never consults the exact-receipt-safe map.

## Policy split: two registry instances

In v1.0.0 the protocol wires **two separate instances** of the same `EntryTokenRegistry` contract:

- **FurnaceEntryTokenRegistry** (deployment manifest key)
  - tokens allowed for onboarding into the Furnace
  - supports token routes `tokenIn -> CLAIM` (direct) or `tokenIn -> WETH -> CLAIM` (via WETH)
- **MineCoreEntryTokenRegistry** (deployment manifest key)
  - tokens allowed for token-based takeovers
  - supports the takeover route `tokenIn -> WETH -> unwrap -> ETH`
  - recommended to start empty or extremely conservative

These labels are used in `deployments/<network>.json` and on the app’s **Security** page. They are not different contract types.

This is a MUST, not just a recommendation: do not wire the same registry into both surfaces. `Wire.s.sol` rejects shared registries at wiring time (`registries must differ (policy split)`), because separate allowlists reduce the blast radius of a bad token/pool config.

## WETH special-case (required)

WETH is always supported without allowlisting:
- token configs forbid tokenIn == wrappedNative
- core entrypoints special-case tokenIn == WETH:
  - MineCore.takeoverWithToken(WETH, amountIn, minEthOut, maxPrice): unwrap 1:1, enforce ethOut >= minEthOut
  - Furnace.enterWithToken(WETH, amountIn,...): unwrap 1:1, then treat as ETH input
- the non-WETH exact-receipt guard applies only to ERC20 token entry; it does not change the built-in WETH unwrap path
- helper route resolution special-cases WETH too:
  - `FurnaceQuoter.resolveFurnaceRoute(WETH)` and SDK `resolveFurnaceEntryRoute({ tokenIn: WETH })` return the canonical single-hop `WETH -> CLAIM` route built from the pinned WETH/CLAIM hop
  - they report `routeTokenId = 1` (`VIA_WETH`) because this is the WETH-boundary path, not an allowlisted direct `tokenIn -> CLAIM` config

## RouterConfig

Registry stores global router config:
- router (v1.0.0 expects DexAdapter)
- factory (must equal router.defaultFactory())
- wrappedNative (must equal router.weth())
- claimToken (must match the immutable ClaimToken)

Important invariants:
- router, factory, wrappedNative, and claimToken must all be live contracts when set
- wrappedNative and claimToken are immutable after first set
- once the global WETH/CLAIM hop or any per-token pool config has been set, router/factory rewiring is no longer allowed in-place
  - stored `expectedPool` addresses are tied to that router/factory pair
  - use a fresh registry deployment if you must rotate routers or factories after route surfaces are configured

Access control:
- Router/hop/token-config setters are `onlyOwner`. In v1.0.0, the live owner path is the `TimelockController` governed by the Safe.
- Runtime safeguards prevent dangerous in-place changes even without a freeze: once the global WETH/CLAIM hop or any per-token pool config has been set, router/factory rewiring is no longer allowed in-place (see above).
- The guardian can disable tokens only; enabling and routing config changes require the owner.

## Canonical WETH/CLAIM hop

The registry stores the pinned WETH/CLAIM pool:
- used for Furnace ETH entry (ETH -> CLAIM)
- used for token routes that go tokenIn -> WETH -> CLAIM
- `setWethClaimHop(...)` is **one-shot**: once `_wethClaimPool != 0`, the call reverts `WethClaimHopAlreadySet`. There is no in-place rebinding — rotate by deploying a fresh registry.
- The setter requires live code at the pool address (rejects deterministic CREATE2 ghost addresses), validates `pool == router.poolFor(weth, claim, stable, factory)`, and rejects EIP-7702 delegated EOAs. Production/testnet genesis flows must defer this binding until `LaunchController.finalizeGenesis()` creates the canonical pool onchain.
- A takeover-only registry wired only into MineCore may leave this hop unset; the Furnace-wired registry requires it (any via-WETH `resolveFurnaceRoute` reverts `WethClaimHopNotSet` until it is set).
- per-token pool bindings have the same live-code + EIP-7702 rejection rules: `tokenWethPool` and any direct `tokenClaimPool` must already exist onchain when configured.

## Per-token TokenConfig

Each allowlisted token has:
- enabled (gate inside this registry instance)
- tokenIn -> WETH hop (always required)
- optional tokenIn -> CLAIM direct hop (Furnace-only)

Route resolution (ABI surface):
- `resolveTakeoverRoute(tokenIn) -> RegistryRoute[]`
  - always a single hop: `tokenIn -> WETH`
- `resolveFurnaceRoute(tokenIn) -> (RegistryRoute[] route, uint256 routeTokenId)`
  - if `directToClaimEnabled`:
    - route: `[tokenIn -> CLAIM]`
    - `routeTokenId = 0` (`DIRECT_TO_CLAIM`)
  - else:
    - route: `[tokenIn -> WETH, WETH -> CLAIM]`
    - `routeTokenId = 1` (`VIA_WETH`)

Important: `EntryTokenRegistry.resolveFurnaceRoute(tokenIn)` and `resolveTakeoverRoute(tokenIn)` reject a fixed set of `tokenIn` values regardless of allowlist state — `address(0)`, `WETH`, the immutable `claimToken`, the registry itself, the bound `router`, and the bound `factory` (revert `ZeroAddress` / `InvalidToken`). Non-contract or EIP-7702 delegated `tokenIn` addresses are also rejected (`NotAContract` / `DelegatedEOA`). The Furnace path additionally requires the `_furnaceEntryTokenExactReceiptSafe[tokenIn]` opt-in (see above) and reverts `UnsafeEntryToken` if missing.
- WETH route introspection lives in FurnaceQuoter / SDK helpers, not in `EntryTokenRegistry.resolveFurnaceRoute(...)`.
- `FurnaceQuoter.resolveFurnaceRoute(WETH)` returns `[WETH -> CLAIM]` with `routeTokenId = 1` (built from the pinned hop, not from the `tokenConfig` mapping).
- `MineCoreQuoter.resolveTakeoverRoute(WETH)` returns an **empty** route array (`length = 0`) to signal "no DEX hop, unwrap 1:1" — callers must not assume a 1-hop route shape.

`routeTokenId` is a stable codebook pinned by `docs/spec/entry-token-registry-v1.0.0.md`.

Note: This `routeTokenId` refers to the **swap route codebook** (0 = `DIRECT_TO_CLAIM`, 1 = `VIA_WETH`). The 4th return value of `FurnaceQuoter.quoteEnterWith*` is also named `routeTokenId` but carries the **destination lock's token ID** (or 0 for a new lock). Do not conflate the two.

## Guardian: disable-only token response + emergency key rotation

EntryTokenRegistry has a guardian role for incident response:
- owner can enable and disable tokens
- guardian can disable tokens only (emergency safety valve); guardian calling `setTokenEnabled(token, true)` reverts with `NotAuthorized`
- **Authorization gate runs first**: `setTokenEnabled` validates the caller (owner or guardian) **before** the idempotent same-state short-circuit. An unauthorized address calling `setTokenEnabled(token, currentState)` reverts `NotAuthorized` rather than silently no-op'ing. This is the canonical signal an integrator can rely on for permission probes.
- **1-hour cooldown** (`GUARDIAN_DISABLE_COOLDOWN`): when the **guardian** disables a token, `guardianDisabledUntil[tokenIn]` is set to `block.timestamp + 1 hours`. During this window, the owner cannot re-enable that token (both `setTokenEnabled(token, true)` and `setTokenConfig(token, _, _, _, true)` revert `NotAuthorized`). This gives incident responders time to escalate before the owner can override.
- **Owner disables never bump the cooldown**: when the owner disables a token (including the case where `owner == guardian` and the call is dispatched as the owner), `guardianDisabledUntil[tokenIn]` is left untouched. The cooldown is the guardian's emergency lever; an owner-initiated disable does not consume it.
- **Cooldown ratchet protection**: only the **first** guardian disable in a window moves `guardianDisabledUntil` forward (the setter checks `guardianDisabledUntil[tokenIn] <= block.timestamp` before extending). A compromised guardian therefore cannot indefinitely extend the cooldown by repeatedly redisabling the same token — bounded recovery still requires a guardian rotation, but the on-chain ceiling is exactly one cooldown window.
- Guardian rotation via `setGuardian(address)` is callable by **either the owner or the current guardian** (emergency self-rotation is intentional). The new guardian must be non-zero, cannot be the registry itself, and cannot be an EIP-7702 delegated EOA — `setGuardian` runs `_rejectDelegatedEOA(guardian)` so a 7702 designator (`0xef0100 || target`) reverts `DelegatedEOA`. Bare EOAs and ordinary contracts pass; the rejection exists because a 7702 signer can replace the executor running at the address and would otherwise inherit a public disable surface.

This is how the protocol can rapidly remove a problematic token or pool route without reopening routing config.

## DexAdapter

DexAdapter is the Aerodrome v2 router wrapper.

Why it exists:
- keeps the protocol's direct roots and runtime quartet from hard-binding to a specific DEX router forever
- pins the minimal swap ABI surface used by MineCore and Furnace

Exception: `LpStakingVault7D` uses the raw Aerodrome router directly (`IAerodromeRouter`) for its WETH→CLAIM fee-harvest swap path. It does not route through DexAdapter because the vault's swap surface is independent of the EntryTokenRegistry routing table — it only ever swaps harvested LP fees on the canonical WETH/CLAIM pool, not arbitrary user-supplied token routes.

Operational model:
- the constructor rejects zero / non-contract router pins, then snapshots that live router's `defaultFactory()` and `weth()` immutably at deployment time
- `aerodromeRouter` and `aerodromeFactory` are immutable — DexAdapter cannot change its router after deployment
- if the upstream DEX changes, deploy a fresh DexAdapter, a fresh EntryTokenRegistry, and rewire the consuming core contract via the timelocked owner

### Owner seat: 7702 designator-only guard

DexAdapter rejects an EIP-7702 designator (`0xEF0100 || target`) at the owner seat with `DelegatedEOA` but accepts a bare EOA. The check runs on:

- the constructor `initialOwner`
- `transferOwnership(newOwner)` (the inbound owner)
- the inherited two-step `acceptOwnership()` (the caller, when the contract uses `Ownable2Step`)

This is a looser guard than the strict `_rejectDelegatedEOA` used at every other owner seat in the protocol. The strict variant rejects bare EOAs alongside 7702 designators and is the right call for owner seats whose runtime peers are all contracts. DexAdapter is the asymmetric case: pool / token routing helpers in some operator setups expect to call the adapter from a bare-EOA owner, so the strict "must be a contract" rule is too restrictive here. Rejecting only the 7702 designator preserves that operational latitude while keeping the same execution-replacement risk closed — a 7702 signer can re-point the owner address at arbitrary code at any time, and the adapter owner controls the only mutable surface left on the contract.

The other adapter call sites (route inputs, pool addresses, swap inputs in `_validateRoutes` / `_assertCallerIsOwner`) keep the strict `_rejectDelegatedEOA`, which additionally reverts `NotAContract` on bare EOAs. The two helpers are intentionally distinct.

## Quoters (recommended)

Token-entry calls require user slippage guards:
- Furnace: `minVeOut`
- MineCore takeoverWithToken: `minEthOut`

Do not attempt to recreate routing offchain by hand.

Use canonical quote surfaces:
- **FurnaceQuoter** (resolve via `Furnace.furnaceQuoter()`):
  - `quoteEnterWithEth`
  - `quoteEnterWithClaim`
  - `quoteEnterWithToken`
  - Notes: quote calls revert if `furnaceQuoter` is unset or `lockingPaused == true`.
- MineCore token takeovers use a separate view contract:
  - `MineCoreQuoter.quoteTakeoverWithToken(tokenIn, amountIn) -> (ethOut, takeoverPrice)`
  - `MineCoreQuoter.resolveTakeoverRoute(tokenIn) -> RegistryRoute[]`
  - Pause caveat: `quoteTakeoverWithToken(...)` reverts while `takeoversPaused == true`, but `resolveTakeoverRoute(...)` remains callable for route inspection because it does not enforce the takeover pause gate.

Why MineCoreQuoter exists:
- keeps MineCore bytecode smaller (DEX quote + validation lives here)
- mirrors MineCore's swap validation:
  - routes are registry-resolved (no user-supplied routes)
  - allowlisted pool must match `router.poolFor(...)`
  - tokenIn == wrapped native is special-cased (unwrap 1:1)

Agent / UI recipe (token takeovers):
- quote `ethOut` for your chosen `amountIn`
- choose `slippageBps`
- compute `minEthOut = ethOut * (10_000 - slippageBps) / 10_000`
- call `MineCore.takeoverWithToken(tokenIn, amountIn, minEthOut, maxPrice)`

## Agent SDK helpers

The TypeScript Agent SDK provides a canonical way to consume these routes and quotes. The quoting helpers below take the configured `contracts` map returned by `await getClaimRushContracts({ publicClient, manifest, abiNetwork })` (async — resolves `FurnaceQuoter` from chain):

- Spot swap quoting via the protocol's DexAdapter:
  - `quoteDexAmountsOut({ contracts, amountIn, routes })`
- Route resolution (allowlisted):
  - `resolveMineCoreTakeoverRoute({ contracts, tokenIn })` (token -> WETH)
  - `resolveFurnaceEntryRoute({ contracts, tokenIn })` (token -> CLAIM direct or via WETH; for `tokenIn == WETH`, returns the canonical single-hop `WETH -> CLAIM` route with `routeTokenId = 1`)
- Common spot price helpers:
  - `quoteEthToClaim({ contracts, ethIn })`
  - `quoteClaimToEth({ contracts, claimIn })`
  - `quoteEntryTokenToEth({ contracts, tokenIn, amountIn })`
  - `quoteEntryTokenToClaim({ contracts, tokenIn, amountIn })`

For a “bot-ready” aggregated snapshot (CLAIM spot + all enabled entry tokens), use:
- `getLivePrices({ contracts, publicClient, subgraphUrl, ... })`
- `getLivePrices({ contracts, publicClient, entryTokens, ... })` when you want to bypass subgraph token enumeration
- Optional caching / throttling for polling loops: `getLivePrices({ contracts, publicClient, subgraphUrl, cache: createLivePricesCache(), ... })`
- CLI: `npm -C agents/sdk run example:prices`
- CLI with caching: `PRICES_CACHE=1 ... npm -C agents/sdk run example:prices`

## See also

- [Furnace](furnace.md) — lock entry paths that consume token swaps
- [Core Mechanics](core-mechanics.md) — takeover loop and entry token flows
- [Security, Guardian, Pausing](security-guardian-pausing.md) — token disable via Guardian
- [Getting Started](getting-started.md) — deployed addresses
- User manual: [Buy CLAIM](https://docs.claimru.sh/buy-claim)
