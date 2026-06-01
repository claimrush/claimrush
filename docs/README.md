# Docs index (ClaimRush v1.0.0)

Canonical documentation entrypoint: `docs/v1.0.0-index.md`.

Source of truth rules: `docs/v1.0.0-index.md` defines conflict resolution for this repo.

This folder contains the canonical v1.0.0 documentation bundled with the repo.

> This repo ships the canonical public protocol documentation for v1.0.0.

## Document signals

| Signal | Meaning |
|--------|---------|
| Canonical | Source of truth for shipped behavior, release data, or conflict resolution. |
| Reference | Explanatory or navigational material for the shipped surface. |
| Operator | Deployment, runtime, validation, or maintenance surface. |

## Entry points

| Intent | First files |
|--------|-------------|
| Audit | [docs/v1.0.0-index.md](v1.0.0-index.md) [Canonical], [Repo Map](manuals/developer/repo-map.md) [Reference], [Architecture reference](architecture/architecture-reference-v1.0.0.md) [Reference], [Deployment manifests index](deployments/README.md) [Canonical] |
| Integrate | [Getting started](manuals/developer/getting-started.md) [Reference], [Protocol overview](manuals/developer/protocol-overview.md) [Reference], [Furnace](manuals/developer/furnace.md) [Reference], [Entry token registry](spec/entry-token-registry-v1.0.0.md) [Canonical] |
| Run locally | [Getting started](manuals/developer/getting-started.md) [Reference], [`README.md`](../README.md) [Reference], [`Makefile`](../Makefile) [Operator], [`script/DeployLocal.s.sol`](../script/DeployLocal.s.sol) [Operator] |
| Index analytics | [Dune integration pack](analytics/dune-integration-pack-v1.0.0.md) [Canonical], [Subgraph schema](analytics/subgraph-schema-v1.0.0.md) [Canonical], [Indexer and Dune implementation guide](analytics/indexer-and-dune-implementation-guide-v1.0.0.md) [Reference], [`subgraph/README.md`](../subgraph/README.md) [Reference] |

## Security reporting

- Security contact: `security@claimru.sh` (or see `https://claimru.sh/security`).
- Do not report vulnerabilities via unsolicited DMs or Telegram/Discord "support".
- See `SECURITY.md` in the repo root for our disclosure policy.

## Deployment manifests (addresses + start blocks)

Docs-only canonical address lists (mirrors the repo-root `deployments/*` manifests):

- [Deployment manifests index](deployments/README.md)
- [v1.0.0 Base mainnet](deployments/v1.0.0-base_mainnet.md)
- [v1.0.0 Base Sepolia](deployments/v1.0.0-base_sepolia.md)

## Links

### Canonical spec
- [Protocol spec](spec/spec-v1.0.0.md)
- [Entry token registry](spec/entry-token-registry-v1.0.0.md)
- [Vault spec](spec/vault-spec.md)
- [LP staking vault spec](spec/lp-staking-vault-spec.md)
- [Maintenance hub](spec/maintenance-hub-spec-v1.0.0.md)
- [Launch controller](spec/launch-controller-spec-v1.0.0.md)
- [APR calculation](spec/apr-calculation-spec-v1.0.0.md)
- [Marketplace correctness addendum](spec/marketplace-correctness-addendum-v1.0.0.md)
- [King auto-lock](spec/king-autolock-spec-v1.0.0.md)

### Implementer checklists
- [ClaimToken](spec/claimtoken-implementer-checklist-v1.0.0.md)
- [MineCore](spec/minecore-implementer-checklist-v1.0.0.md)
- [VeClaimNFT](spec/veclaimnft-implementer-checklist-v1.0.0.md)
- [Furnace](spec/furnace-implementer-checklist-v1.0.0.md)
- [MarketRouter](spec/marketrouter-implementer-checklist-v1.0.0.md)
- [ShareholderRoyalties](spec/shareholderroyalties-implementer-checklist-v1.0.0.md)
- [EntryTokenRegistry](spec/entrytokenregistry-implementer-checklist-v1.0.0.md)
- [DexAdapter](spec/dexadapter-implementer-checklist-v1.0.0.md)
- [LaunchController](spec/launchcontroller-implementer-checklist-v1.0.0.md)
- [GenesisLPVault24M](spec/genesislpvault24m-implementer-checklist-v1.0.0.md)
- [LpStakingVault7D](spec/lpstakingvault7d-implementer-checklist-v1.0.0.md)
- [MaintenanceHub](spec/maintenancehub-implementer-checklist-v1.0.0.md)
- [ClaimAllHelper](spec/claimallhelper-implementer-checklist-v1.0.0.md)

### Spec aids
- [Spec quality standard](spec/spec-quality-standard-v1.0.0.md)
- [Glossary](spec/glossary-v1.0.0.md)
- [State machines](spec/state-machines-v1.0.0.md)
- [Test vectors](spec/test-vectors-v1.0.0.md)

### Reference architecture
- [Architecture reference](architecture/architecture-reference-v1.0.0.md)
- [Math and rounding appendix](architecture/math-and-rounding-appendix-v1.0.0.md)
- [Aerodrome integration appendix](architecture/aerodrome-integration-appendix-v1.0.0.md)
- [Aerodrome liquidity bootstrap appendix](architecture/aerodrome-liquidity-bootstrap-appendix-v1.0.0.md)
- [Runtime quartet upgrade path](architecture/runtime-quartet-upgrade-path-v1.0.0.md)
- [Base MCP plugin appendix](architecture/base-mcp-plugin-appendix-v1.0.0.md)

### Security

The short public-facing disclosure policy lives at the repo root in
[`SECURITY.md`](../SECURITY.md). It covers supported versions, severity tiers,
response targets, reporting channels, and safe-harbour expectations.

For the public security index — including pointers to the live
verification surfaces (`https://docs.claimru.sh/security`,
`https://claimru.sh/status`), the policy on which security documents
are intentionally private, and the channel for requesting access to
working security documents under coordinated-disclosure terms — see
[`docs/security/README.md`](security/README.md).

The long-form v1.0.0 security architecture (trust boundaries, roles,
invariants, threat map, verification plan, test matrix, third-party trust
inventory, etc.) is shared directly during coordinated disclosure on request.
Email `security@claimru.sh` to coordinate access for an audit, integration
review, or vulnerability triage.

### Reference developer manuals
- [Repo map](manuals/developer/repo-map.md)
- [Getting started](manuals/developer/getting-started.md)
- [Protocol overview](manuals/developer/protocol-overview.md)
- [Core mechanics](manuals/developer/core-mechanics.md)
- [Furnace](manuals/developer/furnace.md)
- [MarketRouter](manuals/developer/marketrouter.md)
- [ShareholderRoyalties & Barons](manuals/developer/shareholderroyalties-barons.md)
- [Locks & VeClaim](manuals/developer/locks-veclaim.md)
- [DelegationHub](manuals/developer/delegationhub.md)
- [EntryTokenRegistry & DexAdapter](manuals/developer/entrytokenregistry-and-dexadapter.md)
- [ClaimAllHelper](manuals/developer/claimallhelper.md)
- [LP staking vault](manuals/developer/lp-staking-vault-lpstakingvault7d.md)
- [Genesis](manuals/developer/genesis.md)
- [Freeze & burn finality](manuals/developer/freeze-and-burn-finality.md)
- [Runtime proxy upgrades](manuals/developer/runtime-proxy-upgrades.md)
- [Security & guardian pausing](manuals/developer/security-guardian-pausing.md)
- [Events & indexing](manuals/developer/events-and-indexing.md)
- [Token supply API](manuals/developer/token-supply-api.md)
- [Maintenance & bots](manuals/developer/maintenance-and-bots.md)
- [Agents & automation](manuals/developer/agents-and-automation.md)
- [Base MCP plugin](manuals/developer/base-mcp-plugin.md)
- [Appendix: constants](manuals/developer/appendix-constants-v100.md)
- [House charter](manuals/developer/house-charter.md)
- [Manual index](manuals/developer/README.md)
- Tutorials:
  - [Build a Base MCP agent for ClaimRush](manuals/developer/tutorials/build-base-mcp-agent.md)
  - [Build crown price & takeover](manuals/developer/tutorials/build-crown-price-and-takeover.md)
  - [Collect Barons ETH or lock](manuals/developer/tutorials/collect-barons-eth-or-lock.md)
  - [Index market orderbook](manuals/developer/tutorials/index-market-orderbook.md)
  - [Index takeovers & reigns](manuals/developer/tutorials/index-takeovers-and-reigns.md)
  - [Integrate Furnace quotes & enter](manuals/developer/tutorials/integrate-furnace-quotes-and-enter.md)
  - [Run ClaimRush OpenClaw skill](manuals/developer/tutorials/run-claimrush-openclaw-skill.md)
  - [Run crown bot at 30min](manuals/developer/tutorials/run-crown-bot-at-30min.md)
  - [Run maintenance bot](manuals/developer/tutorials/run-maintenance-bot.md)

### Reference user manuals

The user manual is published at **<https://docs.claimru.sh/>** and is not mirrored in this repository. Deep links:

- [Overview](https://docs.claimru.sh/overview)
- [Getting started](https://docs.claimru.sh/getting-started)
- [Core concepts](https://docs.claimru.sh/core-concepts)
- [Buy CLAIM](https://docs.claimru.sh/buy-claim)
- [Furnace](https://docs.claimru.sh/furnace)
- [Market](https://docs.claimru.sh/market)
- [Locks](https://docs.claimru.sh/locks)
- [Liquidity & LP vault](https://docs.claimru.sh/liquidity-and-lp-vault)
- [Be king](https://docs.claimru.sh/be-king)
- [House](https://docs.claimru.sh/house)
- [Leaderboards](https://docs.claimru.sh/leaderboards)
- [Activity](https://docs.claimru.sh/activity)
- [Radar & notifications](https://docs.claimru.sh/radar-and-notifications)
- [Profiles & achievements](https://docs.claimru.sh/profiles-and-achievements)
- [Chat](https://docs.claimru.sh/chat)
- [Status](https://docs.claimru.sh/status)
- [Strategy](https://docs.claimru.sh/strategy)
- [Bots & automation](https://docs.claimru.sh/bots-and-automation)
- [Security](https://docs.claimru.sh/security)
- [Safety & risk](https://docs.claimru.sh/safety-and-risk)
- [FAQ & troubleshooting](https://docs.claimru.sh/faq-troubleshooting)
- [Glossary](https://docs.claimru.sh/glossary)
- [Manual index](https://docs.claimru.sh/)
- Tutorials:
  - [Collect & lock](https://docs.claimru.sh/tutorials/collect-and-lock)
  - [Collect ETH](https://docs.claimru.sh/tutorials/collect-eth)
  - [Enter furnace](https://docs.claimru.sh/tutorials/enter-furnace)
  - [Forge eternal lock](https://docs.claimru.sh/tutorials/forge-eternal-lock)
  - [Sell a lock to furnace](https://docs.claimru.sh/tutorials/sell-a-lock-to-furnace)
  - [Sell a lock](https://docs.claimru.sh/tutorials/sell-a-lock)
  - [Set up radar](https://docs.claimru.sh/tutorials/set-up-radar)
  - [Stake LP](https://docs.claimru.sh/tutorials/stake-lp)
  - [Take the crown](https://docs.claimru.sh/tutorials/take-the-crown)
  - [Use with an AI assistant (Base MCP)](https://docs.claimru.sh/tutorials/use-with-ai-assistants)

### Canonical analytics
- [Dune integration pack](analytics/dune-integration-pack-v1.0.0.md)
- [Subgraph schema](analytics/subgraph-schema-v1.0.0.md)
- [Metrics canon](analytics/metrics-canon-v1.0.0.md)
- [Indexer & Dune implementation guide](analytics/indexer-and-dune-implementation-guide-v1.0.0.md)
- [Leaderboards](analytics/leaderboards-ui-and-dune-compatible-v1.0.0.md)
- [Indexing hosting & derived data](analytics/indexing-hosting-and-derived-data-reference-v1.0.0.md)
