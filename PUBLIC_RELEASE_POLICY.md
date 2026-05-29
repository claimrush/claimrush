# Public Release Policy

This repo publishes the ClaimRush v1.0.0 public release surface.

## Shipped Surface

The effective public repo is the shipped ClaimRush v1.0.0 release tree.

The shipped surface includes:
- protocol source and tests
- shipped documentation under `docs/`
- brand assets under `brand/`
- deployment manifests under `deployments/`
- exported ABIs under `abis/`
- analytics templates under `analytics/`
- shipped keeper, SDK, and `packages/node-utils/`
- public-safe scripts, workflows, and root config files

## Excluded Surface

The public repo does not ship:
- `frontend/`
- `docs-site/`
- `developers-site/`
- `workers/`
- `services/`
- `ops/private/`
- secrets, local state, generated build output, and machine-specific replay output

## Documentation Rule

Public prose, labels, comments, and NatSpec describe the current shipped state.

Public docs do not describe:
- internal decision logs
- remediation history
- scope changes
- future work
- unreleased application source paths

## Command Surface

Public docs and workflows reference only the commands, scripts, and paths that
ship in the public repo.

The public repo `Makefile` defines the shipped Make target surface.
