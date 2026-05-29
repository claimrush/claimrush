# DexAdapter implementer checklist (v1.0.0)

This is an **implementer-focused checklist** for `DexAdapter`, the DEX routing adapter used by `EntryTokenRegistry`.

Reference implementation: `src/DexAdapter.sol`.

Why it exists:
- ClaimRush v1.0.0 keeps the direct roots fixed and the runtime quartet governed behind stable proxy addresses, while still allowing routing/DEX evolution behind a small adapter surface.
- `EntryTokenRegistry` and `DexAdapter` together form the **routing trust surface**.

Source of truth:
- Contract set + upgrade policy: `docs/spec/spec-v1.0.0.md` §1.0.2 and §10.3
- Router interface + pool validation rules: [Aerodrome integration appendix](../architecture/aerodrome-integration-appendix-v1.0.0.md)
- Security posture for routing surfaces: the threat map §5

Spec aids (recommended):
- `docs/spec/spec-quality-standard-v1.0.0.md`
- `docs/spec/entry-token-registry-v1.0.0.md` (registry uses the adapter as its `router`)

This document **does not introduce new rules**. It restates MUST/MUST NOT requirements in an order suitable for incremental implementation and review.

---

## Goals

`DexAdapter` MUST:
- Implement the exact minimal router interface required by the Aerodrome appendix (no “almost compatible” signatures).
- Be **minimally custodial**:
  - no persistent accounting
  - no escrow
  - no balances held beyond transient swap execution
- Preserve deterministic routing:
  - the protocol roots/runtime and registry MUST NOT accept user-supplied routes
  - callers supply only allowlist-derived routes

`DexAdapter` MUST NOT:
- Introduce any **permissionless** or **non-owner** sweep/rescue/admin-drain capability. Exception: the shipped v1.0.0 `DexAdapter` includes bounded owner-only recovery: `rescueETH(address payable to)` (ETH) and `rescueToken(IERC20 token, address to)` (ERC-20), both `nonReentrant` + `onlyOwner`, with destination guards (no routing refunds to router/factory/WETH roots, etc.). See `spec-v1.0.0.md` §10.4 where applicable.
- Add protocol fees, affiliate cuts, or hidden transfer hooks.
- Expand scope beyond “adapter to an underlying router” without updating the canonical docs.

---

## Required interface (MUST match)

DexAdapter MUST implement `IDexAdapter` (`src/interfaces/IDexAdapter.sol`), which aligns with:
- [Aerodrome integration appendix](../architecture/aerodrome-integration-appendix-v1.0.0.md) §A.2

At minimum (names + semantics; `Route` = `IDexAdapter.Route`):

- `defaultFactory() external view returns (address)`
- `weth() external view returns (address)`
- `poolFor(address tokenA, address tokenB, bool stable, address factory) external view returns (address pool)`
- `getAmountsOut(uint256 amountIn, Route[] calldata routes) external view returns (uint256[] memory amounts)`
- `swapExactETHForTokens(uint256 amountOutMin, Route[] calldata routes, address to, uint256 deadline) external payable returns (uint256[] memory amounts)`
- `swapExactTokensForTokens(uint256 amountIn, uint256 amountOutMin, Route[] calldata routes, address to, uint256 deadline) external returns (uint256[] memory amounts)`

The reference `DexAdapter` implementation applies OpenZeppelin `nonReentrant` to both swap entrypoints and both rescue functions (modifiers are not part of the `IDexAdapter` ABI but are on the deployed contract).

**Additional public ABI (reference `src/DexAdapter.sol`, not part of `IDexAdapter`):**

- `constructor(address _aerodromeRouter, address initialOwner)` — `Ownable(initialOwner)`; pins `aerodromeRouter`, reads `defaultFactory()` / `weth()` from the router to set immutables `aerodromeFactory` and `wrappedNative`.
- Immutable getters: `aerodromeRouter`, `aerodromeFactory`, `wrappedNative` (public).
- `renounceOwnership() public pure override` — always reverts `Errors.NotAuthorized()` (lock-out prevention).
- `receive() external payable` — only accepts ETH from `aerodromeRouter` (router refunds); others revert `Errors.NotAuthorized()`.
- `rescueETH(address payable to) external nonReentrant onlyOwner`
- `rescueToken(IERC20 token, address to) external nonReentrant onlyOwner`

Constraints (required):
- `poolFor(...)` MUST include the `factory` parameter in the signature (v1.0.0 canonical).
- `Route` here is **`IDexAdapter.Route`**, not `EntryTokenRegistry` hop structs. See “Type collision” below.

---

## Type collision warning (MUST)

The Aerodrome appendix explicitly warns about a type collision:

- Router route type: `IDexAdapter.Route` (Aerodrome-shaped; referred to as **RouterRoute** in some docs)
- Registry hop type: `EntryTokenRegistry.RegistryRoute` (referred to as **RegistryRoute**)

They are **not interchangeable**.

Checklist:
- Do not reuse the registry struct for router calls.
- When converting a registry hop to a router hop:
  - drop the allowlisted `pool` field (registry-only validation surface)
  - set `factory` using `router.defaultFactory()` (v1.0.0 default)

Reference mapping: [Aerodrome integration appendix](../architecture/aerodrome-integration-appendix-v1.0.0.md) §A.2.

---

## Governance and upgrades (high-trust surface)

v1.0.0 policy (REQUIRED):
- `DexAdapter` MUST be deployed non-upgradeable (no proxy) in v1.0.0 (scope B-07).
- DexAdapter code at a given address MUST be treated as immutable (no proxy-style upgrades).
- Router/DEX changes MUST be done via redeploying DexAdapter and calling `EntryTokenRegistry.setRouterConfig(...)` through the live owner() path (typically timelocked in production).
  - Once the WETH/CLAIM hop or any token config exists, router/factory changes MUST use a fresh registry deployment instead of changing the existing registry in place.

Upgradeable DexAdapter profile:
- An upgradeable DexAdapter profile is not part of v1.0.0.
- If a different version introduces one, upgrades are high-trust and MUST be timelocked.
  - Guidance: multisig + onchain timelock.
  - Upgrade authorization MUST be ADMIN-only.
  - Upgrades MUST NOT add generic sweep/rescue/admin-drain functions.
  - Upgrades MUST preserve the required interface exactly.
- DexAdapter MUST NOT expose a governance setter to swap the underlying Aerodrome router (e.g., `setAerodromeRouter`).
  - v1.0.0 router/DEX changes MUST be executed by redeploying DexAdapter and calling `EntryTokenRegistry.setRouterConfig(...)` through the live owner() path (typically timelocked in production).

---

## Swap behavior checklist (adapter semantics)

Design goal (non-binding): forward swaps to the pinned `aerodromeRouter` after **defense-in-depth validation** (the shipped adapter is not a blind calldata pipe).

Checklist (reference `src/DexAdapter.sol`):
- Forward `amountOutMin`, `deadline`, and `to` to the underlying router **when validation passes**; the adapter additionally enforces:
  - `factory` on every hop equals the immutable `aerodromeFactory` (no alternate factory injection)
  - route length 1 or 2, chained `from`/`to`, no hops through `address(this)`, router, or factory addresses, EOAs rejected where enforced
  - `swapExactETHForTokens`: `msg.value > 0`, `deadline >= block.timestamp`, first hop `from == wrappedNative`, last token `to` is a contract and not `wrappedNative`
  - `swapExactTokensForTokens`: `amountIn > 0`, same deadline/`to` rules, post-swap allowance cleared, token balance invariants on the adapter
- `poolFor`: rejects zero addresses, `tokenA == tokenB`, wrong `factory`, or `this`/router as tokens; then forwards to the router.
- `getAmountsOut`: `amountIn > 0`, validates routes, checks returned `amounts.length == routes.length + 1`.
- Reverts use `src/lib/Errors.sol` (e.g. `AmountZero`, `DeadlineExpired`, `InvalidRoute`, `NotAContract`, `MinAmountOutNotMet`, `InvariantViolation`, `ReturnDataTooLarge`, `EthTransferFailed`, `TransferFailed`, `ApprovalFailed`, `InsufficientTokenBalance`, `InsufficientTokenAllowance`).
- Do not accept user-supplied routes from the UI:
  - Only the allowlist/registry layer MUST determine routes

## Events (reference implementation)

Owner recovery and transparency (from `src/lib/Events.sol`):
- `EthRescued(address indexed to, uint256 amount)`
- `TokenRescued(address indexed token, address indexed to, uint256 amount)`

---

## Minimum test checklist (derived)

- Interface correctness:
  - ABI and function selectors match the appendix interface.
- Route conversion sanity:
  - When converting registry hops to router hops, `factory` is set and `pool` is not treated as a router field.
- No-custody:
  - Adapter does not retain token balances after a swap (beyond dust that cannot be avoided by the underlying router).
- Governance controls:
  - `setAerodromeRouter` MUST NOT exist in the ABI (router/DEX changes ship via redeploy + timelocked registry router-config rewiring through `EntryTokenRegistry.setRouterConfig(...)`).
- Recovery surfaces:
  - `rescueETH` / `rescueToken` exist, are `onlyOwner` + `nonReentrant`, and are not permissionless sweeps.
