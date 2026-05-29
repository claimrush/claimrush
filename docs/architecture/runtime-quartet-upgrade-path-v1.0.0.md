# Runtime Quartet Upgrade Path – ClaimRush v1.0.0

## Current deployment model

ClaimRush v1.0.0 uses a split trust model:

- Direct, permanent roots:
  - `ClaimToken`
  - `VeClaimNFT`
- Transparent-proxy runtime quartet:
  - `MineCore`
  - `Furnace`
  - `MarketRouter`
  - `ShareholderRoyalties`

The canonical protocol addresses for the runtime quartet are the proxy addresses recorded in
`deployments/*.json` under `.contracts.<Name>.address`. Each of those manifest entries also records:

- `implementation`
- `proxyAdmin`
- `proxyAdminOwner`

## Trust model properties

The proxy-backed quartet
preserves the live addresses and storage for the mutable runtime surfaces that hold protocol state:

- `MineCore` keeps reign state, king balances, and pending king CLAIM state.
- `Furnace` keeps reserve, LP stream, and sellback-related state.
- `MarketRouter` keeps listings, offers, and escrow state.
- `ShareholderRoyalties` keeps checkpointed ETH-per-ve accounting and per-user reward state.

Because the proxy address and storage stay stable, upgrades change logic without forcing a new game
address or a manual state transfer.

## What remains intentionally direct

`ClaimToken` and `VeClaimNFT` remain direct-deployed and permanent.

That means:

- CLAIM keeps the same token address.
- veCLAIM keeps the same NFT address.
- The protocol still has two fixed asset roots even though the runtime quartet is upgradeable.

This is the boundary the implementation enforces.

## Governance model

Upgrades are performed through transparent-proxy `ProxyAdmin` contracts.

Operationally:

- each runtime proxy has its own `ProxyAdmin`
- ownership handoff moves those `ProxyAdmin` contracts into the protocol timelock
- `FinalizeOwnership.s.sol`, `FinalizeTimelockBootstrap.s.sol`, and `TimelockAcceptOwnership.s.sol` complete the canonical handoff
- production posture is `Safe -> TimelockController -> ProxyAdmin -> proxy`

Important:

- `freezeConfig()` alone does not disable proxy upgrades
- `freezeConfig()` only locks the documented wiring setters on the freeze-gated contracts
- runtime upgrades remain a governance-controlled trust surface until the final freeze-and-burn ceremony renounces ownership on the four runtime `ProxyAdmin`s

## Finality lifecycle

Finality proceeds through five stages:

1. **Deploy** — Proxy addresses and direct roots are deployed. Proxy-backed contracts are upgradeable through the `ProxyAdmin` → timelock chain.
2. **Timelock handoff** — `ProxyAdmin` ownership and protocol `owner()` are transferred into the `Safe → TimelockController` chain. All governance actions are now time-delayed and publicly visible before execution.
3. **`freezeConfig()`** — Locks the documented wiring setters on `ClaimToken`, `MineCore`, `Furnace`, `VeClaimNFT`, and `ShareholderRoyalties`. Does not disable proxy upgrades or remove timelock authority. `MarketRouter` has no `freezeConfig()`.
4. **Burn proxy admins** — A timelocked batch renounces ownership on the four runtime `ProxyAdmin`s. After this executes, quartet logic is permanent.
5. **What survives** — Post-freeze owner knobs (operational peripherals, routing allowlists) remain governed through the timelock. These do not change game economics.

## Deployment and manifest consequences

The deployment flow treats proxy addresses as canonical runtime addresses everywhere:

- scripts wire `ClaimToken` and `VeClaimNFT` to the runtime proxies
- helpers and satellites pin the proxy addresses, not implementation addresses
- manifests and generated deployment docs surface both the canonical proxy address
  and the current implementation/admin metadata

Any deployment, verification, or ownership-handoff process must account for:

- proxy address
- implementation address
- proxy admin owner
- timelock address and delay

## Operational recommendation

For user-facing communications, the correct summary is:

- the token and veNFT roots are permanent
- the live runtime quartet is upgradeable through transparent proxies
- freeze locks wiring setters
- freeze-and-burn locks runtime logic permanently
- surviving owner knobs remain a governed timelock action, not a user-accessible protocol toggle
