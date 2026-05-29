# Aerodrome Integration Appendix – ClaimRush v1.0.0

**Status:** Normative (this appendix is part of the spec surface for entry swaps + quotes).

This appendix pins the **DEX integration shape** used by ClaimRush v1.0.0 for:

Scope:
- Furnace entry swaps and quotes (explicit lock destination):
  - `enterWithEth(targetTokenId,durationSeconds,createAutoMax,minVeOut)`
  - `enterWithClaim(claimIn,targetTokenId,durationSeconds,createAutoMax,minVeOut)` (no swap)
  - `enterWithToken(tokenIn,amountIn,targetTokenId,durationSeconds,createAutoMax,minVeOut)`
  - `lockEthReward(user,ethAmount,targetTokenId,durationSeconds,createAutoMax,minVeOut)`
- MineCore token takeovers:
  - `takeoverWithToken(tokenIn,amountIn,minEthOut,maxPrice)`

Protocol boundaries (locked):
- No oracles / TWAPs
- No user-supplied routes, pools, or stable flags
- No permissionless token entry (allowlist only)

Routing policy (locked):
- Multi-hop is allowed **only** for the fixed pattern:
  - `tokenIn -> WETH -> CLAIM` (Furnace)
- TakeoverWithToken uses a fixed pattern:
  - `tokenIn -> WETH -> unwrap -> ETH` (MineCore)

Slippage model (locked):
- Furnace: protection is **only** `minVeOut` enforced on entry-attributable `veOut` for the newly locked amount
- MineCore takeoverWithToken: protection is `minEthOut` (or equivalent) on post-swap ETH

---

## A.1 Config model (EntryTokenRegistry, external)

DEX + routing config is **not stored** in Furnace or MineCore.

Instead:

- Furnace and MineCore each store a single pointer:
  - `EntryTokenRegistry entryTokenRegistry`
  - set by `owner` (timelocked in production)
  - The two pointers MUST be different in v1.0.0 (policy split):
    - one instance wired to Furnace (onboarding tokens)
    - one instance wired to MineCore (takeoverWithToken tokens)

- EntryTokenRegistry (governed) stores:
  - `router` = **DexAdapter** (implements the minimal router interface in §A.2)
    - At launch, DexAdapter may delegate to Aerodrome v2 internally.
  - `factory` + wrapped native (WETH)
  - the allowlisted `WETH -> CLAIM` hop (pool + stable flag)
  - per-token allowlisted hop pools and stable flags
  - all configured router/factory/token/pool addresses must be live contracts at bind time; deterministic undeployed pool addresses are not acceptable config

Core contracts MUST resolve routing via EntryTokenRegistry at runtime and MUST fail closed if:
- registry is unset
- token is not enabled
- any hop’s allowlisted pool does not match `router.poolFor(...)`

See: `docs/spec/entry-token-registry-v1.0.0.md`.

---

## A.2 Router API surface (minimal interface)

ClaimRush requires the following minimal router interface (compatible with Aerodrome v2).

- The `router` returned by `EntryTokenRegistry.getRouterConfig()` MUST be a **DexAdapter** that conforms to this interface.
- The protocol roots/runtime and registry MUST treat DexAdapter as the router and MUST NOT accept user-provided routes.

```solidity
interface IAerodromeRouter {
    struct Route {
        address from;
        address to;
        bool stable;
        address factory;
    }

    function defaultFactory() external view returns (address);
    function weth() external view returns (address);

    function poolFor(
        address tokenA,
        address tokenB,
        bool stable,
        address factory
    ) external view returns (address pool);

    function getAmountsOut(uint256 amountIn, Route[] calldata routes)
        external
        view
        returns (uint256[] memory amounts);

    function swapExactETHForTokens(
        uint256 amountOutMin,
        Route[] calldata routes,
        address to,
        uint256 deadline
    ) external payable returns (uint256[] memory amounts);

    function swapExactTokensForTokens(
        uint256 amountIn,
        uint256 amountOutMin,
        Route[] calldata routes,
        address to,
        uint256 deadline
    ) external returns (uint256[] memory amounts);
}
```

Constraints (required):
- `Route[]` supports 1-hop and 2-hop routing.
- ClaimRush MUST NOT accept user-provided `Route[]`.
- **DexAdapter MUST implement this interface exactly.** v1.0.0: DexAdapter is **non-upgradeable** (no proxy upgrades). DEX/router changes ship via redeploying DexAdapter and calling `EntryTokenRegistry.setRouterConfig(...)` through the live owner() path (typically timelocked in production). Once the WETH/CLAIM hop or any token config exists, router/factory changes require a fresh registry deployment instead of an in-place rewire.
- An upgradeable DexAdapter profile is not part of v1.0.0. Any later version that introduces one would require timelocked upgrades and the same bounded recovery surface.

> **WARNING (type collision):** the router swap route type (`IAerodromeRouter.Route`, referred to as **RouterRoute** in some docs) is **NOT** the same type as EntryTokenRegistry’s hop type (`RegistryRoute`).
> - `RegistryRoute` includes an explicit allowlisted `pool` address for validation/review.
> - `IAerodromeRouter.Route` includes a `factory` field and does not include `pool`.
> - These types are **not interchangeable**.

Mapping reminder (RegistryRoute → RouterRoute / `IAerodromeRouter.Route`):

```solidity
// Drop r.pool (it is for validation) and set factory (v1.0.0: router.defaultFactory()).
IAerodromeRouter.Route memory rr = IAerodromeRouter.Route({
    from: r.tokenIn,
    to: r.tokenOut,
    stable: r.stable,
    factory: factory
});
```

---

## A.3 Route encoding rules (fixed routing)

### A.3.1 Canonical hop: `WETH -> CLAIM`

EntryTokenRegistry defines the canonical `WETH -> CLAIM` hop:
- `from = WETH`
- `to = CLAIM`
- `stable = wethClaimStable` (expected: volatile `false` at launch)
- `factory = router.defaultFactory()`

Allowlist verification (MUST):
- `computed = router.poolFor(WETH, CLAIM, stable, factory)`
- `require(computed == wethClaimPool)`
- `wethClaimPool` MUST already be a deployed pool contract

### A.3.2 Furnace: `enterWithEth(targetTokenId,durationSeconds,createAutoMax,minVeOut)`

Fixed route:
- `ETH -> (router wraps to WETH) -> CLAIM`
- encoded as a single hop `WETH -> CLAIM`

Clarification:
- `targetTokenId`, `durationSeconds`, and `createAutoMax` do **not** change the swap route.
- They only affect where CLAIM is locked (destination lock) and the duration-weighted bonus multiplier.

### A.3.3 Furnace: `enterWithToken(tokenIn,amountIn,targetTokenId,durationSeconds,createAutoMax,minVeOut)`

Clarification:
- `targetTokenId`, `durationSeconds`, and `createAutoMax` do **not** change routing.
- Routing is determined only by `tokenIn` allowlist configuration in EntryTokenRegistry.

Fixed routing selection (no user paths):

- If a direct `tokenIn -> CLAIM` pool is configured and enabled in EntryTokenRegistry:
  - route length = 1
  - hop: `tokenIn -> CLAIM`

- Else:
  - route length = 2
  - hop 1: `tokenIn -> WETH`
  - hop 2: `WETH -> CLAIM` (canonical hop)

Every hop MUST be verified:
- `computedPool = router.poolFor(from, to, stable, factory)`
- `require(computedPool == allowlistedPoolFromRegistry)`
- the allowlisted pool address MUST already have live code onchain

BASE example:
- If a `BASE/CLAIM` pool does not exist at launch, configure BASE as:
  - Furnace route: `BASE -> WETH -> CLAIM`

### A.3.4 MineCore: `takeoverWithToken(tokenIn, amountIn, minEthOut, maxPrice)`

Fixed route:
- `tokenIn -> WETH` (single hop)
- then unwrap WETH to ETH

Hop verification (MUST):
- verify `tokenIn -> WETH` pool via `poolFor` against registry’s allowlisted pool
- require the allowlisted pool to already be a deployed contract

---

## A.4 Swap execution rules

### A.4.1 Deadline (locked)

Swaps MUST include a `deadline` parameter and forward it to the underlying router.

- If the calling function exposes a `deadline` parameter, it MUST forward the caller-supplied value unchanged.
- If the calling function does NOT expose a `deadline` (example: Furnace pinned ABI), it MUST compute:
  - `deadline = block.timestamp + SWAP_DEADLINE_SECONDS`

### A.4.2 Furnace swap slippage (locked)

For Furnace swaps:
- router `amountOutMin` may be `0`
- the only slippage protection is enforcing `minVeOut` on the entry-attributable `veOut` for the newly locked amount

### A.4.3 MineCore takeoverWithToken slippage

For takeoverWithToken:
- MUST enforce a user slippage guard: `minEthOut`
- MUST revert if post-swap ETH is less than `minEthOut`

Implementation note:
- You may set router `amountOutMin = minEthOut` on the `tokenIn -> WETH` swap, since WETH is unwrapped 1:1 to ETH.

Canonical quote helper:
- Use `MineCoreQuoter.quoteTakeoverWithToken(tokenIn, amountIn)` to compute the expected post-swap ETH output and derive `minEthOut`.

### A.4.4 Recipients

- Furnace swaps MUST receive CLAIM into Furnace (`to = address(Furnace)`).
- This allows Furnace to:
  - compute principal
  - apply bonus
  - route into the explicit lock destination passed to the entry call (targetTokenId,durationSeconds,createAutoMax)

- MineCore swaps MUST receive WETH into MineCore (`to = address(MineCore)`), then unwrap to ETH.

---

## A.5 Quote rules (MUST match execution)

Quote views MUST:
- resolve the same route selection logic (direct vs via WETH)
- use the same allowlisted pool verification logic
- use the same rounding rules as execution

Required quote views for UI (MUST include lock destination params):
- `quoteEnterWithEth(user, ethIn, targetTokenId, durationSeconds, createAutoMax)`
- `quoteEnterWithClaim(user, claimIn, targetTokenId, durationSeconds, createAutoMax)`
- `quoteEnterWithToken(user, tokenIn, amountIn, targetTokenId, durationSeconds, createAutoMax)`
- `MineCoreQuoter.quoteTakeoverWithToken(tokenIn, amountIn)`

Clarification:
- `lockEthReward(...)` uses the same swap path as `enterWithEth(...)`, so UIs can quote it via `quoteEnterWithEth(...)` with the same destination params.

Failure mode:
- If registry is unset, token is not enabled, or a hop verification fails: **revert**.

---

## A.6 Required safety checks (registry-side)

When configuring EntryTokenRegistry, governance MUST ensure:

- `router != 0`, `factory != 0`, `wrappedNative (WETH) != 0`, `claimToken != 0`.
- `router.weth() == wrappedNative`.

For each allowlisted hop (including `WETH -> CLAIM`):
- `router.poolFor(tokenA, tokenB, stable, factory)` matches the allowlisted pool address stored in the registry.

---

## A.7 Implementation reminders

- Never accept DEX route parameters from users.
- Multi-hop is allowed only for `tokenIn -> WETH -> CLAIM` under registry control.
- Keep quote paths and execution paths identical.
- Ensure EntryTokenRegistry can disable a token quickly if liquidity breaks or the token is found unsafe.

---

## A.8 Routing changes via DexAdapter replacement

v1.0.0 keeps the direct roots fixed and the runtime quartet on stable proxy addresses, while allowing routing logic to evolve by **redeploying** `DexAdapter` and **calling** `EntryTokenRegistry.setRouterConfig(...)` through the live owner() path (typically timelocked in production), as long as the v1 invariants are preserved. Once the WETH/CLAIM hop or any token config exists, router/factory changes require a fresh registry deployment instead of an in-place rewire.

Allowed routing changes (via DexAdapter replacement):
- Switching the underlying DEX/router implementation (e.g., Aerodrome → other) while keeping the same minimal interface.
- Supporting additional deterministic hop patterns (e.g., multi-hop) **only** under governance control (no user routes).

Hard requirements (MUST remain true):
- **Allowlist-only:** EntryTokenRegistry remains the source of truth for enabled tokens and allowlisted pools/hops.
- **No user-supplied routes:** users never provide routes, pools, or stable flags.
- **Fail-closed validation:** if any hop/pool validation fails, revert (no best-effort routing).
- **Safety guards remain primary:** Furnace MUST still enforce `minVeOut`; MineCore MUST still enforce `minEthOut` (or equivalent).
- **No permissionless sweeps:** DexAdapter MUST NOT include permissionless sweep/admin-drain functions. Bounded owner-only recovery (`rescueETH`, `rescueToken`, both `nonReentrant` + `onlyOwner` with destination guards) is permitted per v1.0.0 implementer checklist.
