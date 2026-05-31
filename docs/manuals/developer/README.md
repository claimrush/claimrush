# ClaimRush Developers

Docs for smart-contract integrators, app and bot developers, and indexers.

## Start here

1. **[Getting Started](getting-started.md)** — repo setup, local stack, integration rules, key params
2. **[Repo Map](repo-map.md)** — shipped repo surface, path roles, and entry routes
3. **[Protocol Overview](protocol-overview.md)** — the CLAIM stream, contract map, trust boundaries
4. **Choose a track:**

| Goal | Type | Page |
|------|------|------|
| Building an app / client | Reference | [Core Mechanics](core-mechanics.md), [Furnace](furnace.md), [Locks](locks-veclaim.md) |
| Analytics / indexing | Reference | [Events & Indexing](events-and-indexing.md) |
| Building agents | Reference | [Agents & Automation](agents-and-automation.md) |
| Building keepers | Operator | [Maintenance & Bots](maintenance-and-bots.md) |
| Upgrading live runtime contracts | Operator | [Runtime Proxy Upgrades](runtime-proxy-upgrades.md) |
| Locking runtime logic permanently | Operator | [Freeze-and-Burn Finality](freeze-and-burn-finality.md) |
| Integration tutorials | Reference | [Tutorials](tutorials/README.md) |

## Naming map (UI vs protocol)

| UI | Protocol |
|----|----------|
| Crown | MineCore.currentKing + reign system |
| veCLAIM (overview at `/veclaim`) | VeClaimNFT (public concept surface) |
| Locks (cockpit at `/locks`) | VeClaimNFT (personal positions surface) |
| Barons | ShareholderRoyalties (ETH royalties to veCLAIM holders) |
| Furnace | Furnace (enter → lock with bonus) |
| Market | MarketRouter (listings + bonus target escrow) |
| LP Vault | LpStakingVault7D (Aerodrome WETH/CLAIM LP staking) |
| Bot access | DelegationHub (session registry for opt-in delegated agents) |
| Bundled Collect | ClaimAllHelper (one-call multi-surface payout + delegated wrapper) |
| CLAIM | ClaimToken (ERC20, 18 decimals) |

**Verbs:** ETH payouts = "Collect" | LP rewards = "Harvest"

## Source of truth

| What | File |
|------|------|
| Master index | docs/v1.0.0-index.md |
| Spec | docs/spec/spec-v1.0.0.md |
| Constants | src/lib/Constants.sol, docs/manuals/developer/appendix-constants-v100.md |
| Events | src/lib/Events.sol, docs/analytics/dune-integration-pack-v1.0.0.md |
| Roles | docs/manuals/developer/security-guardian-pausing.md |

## Deployed addresses

See [Getting Started — Deployed addresses](getting-started.md#deployed-addresses).

## Reference indexes

- [Errors Reference](errors.md) — every revert by surface
- [Glossary](glossary.md) — protocol vocabulary used across pages
- [Constants Reference](appendix-constants-v100.md) — canonical numeric thresholds
- [Developer FAQ](developer-faq.md) — common reverts, indexer gotchas, SDK and keeper questions
- [SUMMARY](SUMMARY.md) — full table of contents

## Scope

ClaimRush is the **protocol** (smart contracts, subgraph, keeper, SDK). The official application UI is proprietary and is not released. References to UI defaults in these docs describe integration guidance for apps built on the protocol — they are not a code release.

See [TRADEMARKS.md](https://github.com/claimrush/claimrush/blob/main/TRADEMARKS.md).
The protocol is licensed under the MIT License — see [LICENSE](https://github.com/claimrush/claimrush/blob/main/LICENSE).
Contributions require signing the Contributor License Agreement — see [CLA.md](https://github.com/claimrush/claimrush/blob/main/CLA.md) and [CONTRIBUTING.md](https://github.com/claimrush/claimrush/blob/main/CONTRIBUTING.md).

## See also

- [Getting Started](getting-started.md) — deployed addresses, SDK install, and first calls
- [Protocol Overview](protocol-overview.md) — architecture and CLAIM stream
- [Runtime Proxy Upgrades](runtime-proxy-upgrades.md) — production upgrade runbook for the proxy-backed runtime quartet
- [Freeze-and-Burn Finality](freeze-and-burn-finality.md) — permanent runtime finality ceremony and post-burn governance model
- [Tutorials](tutorials/README.md) — integration tutorials
- [Linking convention](https://github.com/claimrush/claimrush/blob/main/docs/manuals/LINKING.md) — how to link to other manuals, source files, and the CRAL companion yaml
- User manual: [ClaimRush User Manual](https://docs.claimru.sh/)
