# Repo Map

This page maps the shipped public repo surface. It does not restate protocol mechanics.

## Scope

ClaimRush is the protocol: smart contracts, manifests, ABIs, subgraph, keeper, SDK, analytics templates, brand assets, and canonical docs.

The official application UI is proprietary and is not part of this repo.

## Top-level paths

| Path | Type | Role |
|------|------|------|
| `src/` | Canonical | Solidity source for the shipped protocol. |
| `script/` | Operator | Foundry deployment, wiring, finality, and smoke scripts. |
| `test/` | Reference | Foundry and helper tests for shipped behavior and invariants. |
| `deployments/` | Canonical | Network manifests: addresses, start blocks, and mirrored deployment references. |
| `abis/` | Canonical | Exported ABI arrays used by integrators, analytics, and the subgraph. |
| `docs/` | Canonical / Reference | Specs, manuals, architecture docs, analytics docs, and deployment references. |
| `subgraph/` | Reference | Shipped subgraph source, manifests, and build surface. |
| `analytics/` | Reference | Dune SQL templates and analytics query patterns. |
| `keeper/` | Operator | Keeper implementation, tests, and runtime checks. |
| `agents/` | Reference | Agent SDK and agent examples. |
| `skills/` | Reference | Chat-driven OpenClaw / Cursor agent skills wrapping the SDK with CRAL guardrails. |
| `packages/node-utils/` | Reference | Shared public Node utilities. |
| `plugins/` | Reference | Markdown specs for hosted AI-agent plugins (Base MCP, Coinbase Wallet agent mode). See [Base MCP plugin](base-mcp-plugin.md). Only the spec is published here; the hosted API service is operator-side. |
| `brand/` | Canonical | Brand assets, naming, and copy rules. |
| `scripts/` | Operator | Public-safe validation, export, deployment, and sync scripts. |
| `.github/workflows/` | Operator | Shipped workflow surface in the public repo. |

## High-signal files

| File | Type | Role |
|------|------|------|
| [`README.md`](https://github.com/claimrush/claimrush/blob/main/README.md) | Reference | Repo entrypoint and command surface. |
| [`docs/v1.0.0-index.md`](https://github.com/claimrush/claimrush/blob/main/docs/v1.0.0-index.md) | Canonical | Master documentation index and conflict-resolution rules. |
| [`PUBLIC_RELEASE_POLICY.md`](https://github.com/claimrush/claimrush/blob/main/PUBLIC_RELEASE_POLICY.md) | Canonical | Public release scope, export rules, and documentation posture. |
| [`Makefile`](https://github.com/claimrush/claimrush/blob/main/Makefile) | Operator | Shipped public Make target surface. |
| [`docs/README.md`](https://github.com/claimrush/claimrush/blob/main/docs/README.md) | Canonical | Public docs index for the shipped versioned set. |
| [`deployments/README.md`](https://github.com/claimrush/claimrush/blob/main/deployments/README.md) | Canonical | Deployment manifest index for shipped networks (canonical source of truth). The mirrored docs-folder copy lives at [`docs/deployments/README.md`](https://github.com/claimrush/claimrush/blob/main/docs/deployments/README.md). |

## Read paths

| Intent | First files |
|--------|-------------|
| Audit | [`docs/v1.0.0-index.md`](https://github.com/claimrush/claimrush/blob/main/docs/v1.0.0-index.md), [Architecture reference](https://github.com/claimrush/claimrush/blob/main/docs/architecture/architecture-reference-v1.0.0.md), [Deployment manifests index](https://github.com/claimrush/claimrush/blob/main/docs/deployments/README.md) |
| Integrate | [Getting started](getting-started.md), [Protocol overview](protocol-overview.md), [`abis/<network>/*.abi.json`](https://github.com/claimrush/claimrush/tree/main/abis) |
| Run locally | [Getting started](getting-started.md), [`Makefile`](https://github.com/claimrush/claimrush/blob/main/Makefile), [`script/DeployLocal.s.sol`](https://github.com/claimrush/claimrush/blob/main/script/DeployLocal.s.sol) |
| Index analytics | [Dune integration pack](https://github.com/claimrush/claimrush/blob/main/docs/analytics/dune-integration-pack-v1.0.0.md), [Subgraph schema](https://github.com/claimrush/claimrush/blob/main/docs/analytics/subgraph-schema-v1.0.0.md), [`subgraph/README.md`](https://github.com/claimrush/claimrush/blob/main/subgraph/README.md) |

## See also

- [Getting Started](getting-started.md)
- [Protocol Overview](protocol-overview.md)
- [Architecture Reference](https://github.com/claimrush/claimrush/blob/main/docs/architecture/architecture-reference-v1.0.0.md)
- [Master index](https://github.com/claimrush/claimrush/blob/main/docs/v1.0.0-index.md)
