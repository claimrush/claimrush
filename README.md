# ClaimRush v1.0.0

Reference repo for the ClaimRush v1.0.0 protocol, subgraph, keeper, agents SDK, and canonical docs.

This repo ships protocol source, manifests, ABIs, subgraph, keeper, SDK, analytics templates, brand assets, and canonical docs.

The official application UI is proprietary and is not part of this repo.

## Start by intent

| Intent | First files |
|--------|-------------|
| Audit | [docs/v1.0.0-index.md](docs/v1.0.0-index.md), [docs/manuals/developer/repo-map.md](docs/manuals/developer/repo-map.md), [docs/architecture/architecture-reference-v1.0.0.md](docs/architecture/architecture-reference-v1.0.0.md) |
| Integrate | [docs/manuals/developer/getting-started.md](docs/manuals/developer/getting-started.md), [docs/manuals/developer/protocol-overview.md](docs/manuals/developer/protocol-overview.md), [docs/manuals/developer/furnace.md](docs/manuals/developer/furnace.md) |
| Run locally | [docs/manuals/developer/getting-started.md](docs/manuals/developer/getting-started.md), `make deps`, `make build`, `make test` |
| Index analytics | [docs/analytics/dune-integration-pack-v1.0.0.md](docs/analytics/dune-integration-pack-v1.0.0.md), [docs/analytics/subgraph-schema-v1.0.0.md](docs/analytics/subgraph-schema-v1.0.0.md), [subgraph/README.md](subgraph/README.md) |

## Release scope

- Canonical docs index: [docs/v1.0.0-index.md](docs/v1.0.0-index.md)
- Repo map: [docs/manuals/developer/repo-map.md](docs/manuals/developer/repo-map.md)
- Public release policy: [PUBLIC_RELEASE_POLICY.md](PUBLIC_RELEASE_POLICY.md)

Runtime trust model:
- `ClaimToken` and `VeClaimNFT` are direct, permanent root contracts.
- `MineCore`, `Furnace`, `MarketRouter`, and `ShareholderRoyalties` are deployed behind named transparent proxies, and their proxy addresses are the canonical runtime addresses recorded in manifests.
- permanent finality uses a timelocked freeze-and-burn ceremony: `ClaimToken` freezes at wire time; the ceremony batch freezes the remaining four contracts, then burns the four runtime `ProxyAdmin`s. Surviving post-freeze owner knobs remain timelocked.
- Deployment manifests record proxy metadata for the runtime quartet via `address` (proxy), `implementation`, and `proxyAdmin`.

## Docs

All public protocol docs shipped with this release live under `docs/`.

### Canonical entrypoints
- [docs/v1.0.0-index.md](docs/v1.0.0-index.md)
- [docs/manuals/developer/repo-map.md](docs/manuals/developer/repo-map.md)
- [PUBLIC_RELEASE_POLICY.md](PUBLIC_RELEASE_POLICY.md)

### Whitepaper
- [Activity-Routed Ownership — Protocol Design (PDF)](docs/whitepaper/ClaimRush_Activity_Routed_Ownership_Protocol_Design_v1.0.0.pdf) — frozen snapshot; canonical home is <https://claimru.sh/whitepaper>

### Protocol spec
- `docs/spec/spec-v1.0.0.md`
- `docs/spec/entry-token-registry-v1.0.0.md` (allowlisted entry tokens + routing)
- `docs/spec/vault-spec.md` (Genesis LP Vault; required genesis infrastructure)
- `docs/spec/lp-staking-vault-spec.md` (LP staking vault; on-protocol)

### Manuals
- `docs/manuals/developer/` (getting started, core mechanics, Furnace, MarketRouter, events, agents)
- User manual (online): <https://docs.claimru.sh/> (not mirrored in this repo)

### Analytics
- `docs/analytics/dune-integration-pack-v1.0.0.md`

## Commands
- `make gates` (repo consistency checks: ABI, analytics, subgraph manifest sync, wiring/codegen semantics, schema/entity parity checks)
- `make deps`
- `make build`
- `make test` (or `forge test -vvv`)

If compilation fails:
- Run `make deps`
- Check `remappings.txt`
- Verify `lib/` is populated

## Agents and automation

Three ways to build automated players:
- **Self-run agents**: bot plays from its own wallet (most direct; no delegation).
- **Delegated bots**: bot acts for a user address via DelegationHub sessions.
- **Chat-driven via OpenClaw / Cursor skill**: workspace-scoped skill at `skills/claimrush/` wraps the SDK with a chat-friendly CLI and enforces the [CRAL](docs/manuals/developer/agents-and-automation.cral.yaml) safety pack (caps, slippage, deadlines, mainnet `--i-understand` gate, dry-run by default).

Docs:
- Developer manual: `docs/manuals/developer/agents-and-automation.md`
- SDK: `agents/sdk/README.md`
- Skill: `skills/claimrush/SKILL.md` (agent-facing) and `skills/claimrush/README.md` (human notes)
- Tutorial: `docs/manuals/developer/tutorials/run-claimrush-openclaw-skill.md`

Local setup (SDK):

```bash
npm -C agents/sdk ci
RPC_URL=http://127.0.0.1:8545 npm -C agents/sdk run example:snapshot

# Optional: live prices and spot swap quotes (requires subgraph)
# SUBGRAPH_URL=http://127.0.0.1:8000/subgraphs/name/claimrush/local \
#   RPC_URL=http://127.0.0.1:8545 npm -C agents/sdk run example:prices

RPC_URL=http://127.0.0.1:8545 npm -C agents/sdk run example:events
RPC_URL=http://127.0.0.1:8545 npm -C agents/sdk run example:harness
RPC_URL=http://127.0.0.1:8545 npm -C agents/sdk run example:agent -- --once
```

Local setup (chat skill):

```bash
bash skills/claimrush/scripts/setup.sh
RPC_URL=http://127.0.0.1:8545 bash skills/claimrush/scripts/cr.sh status --pretty
RPC_URL=http://127.0.0.1:8545 bash skills/claimrush/scripts/cr.sh agent
```

Safety:
- The reference agent runs in **dry-run** mode unless `--execute` is provided.
- Spending actions (Furnace entry, takeovers) are opt-in and require explicit caps / amounts.
- Mainnet writes via the skill additionally require `--i-understand` and a `CR_SKILL_BASE_RPC_ALLOWLIST`-allowlisted RPC URL.

## Start here

- **Implementers and reviewers:** Read [docs/v1.0.0-index.md](docs/v1.0.0-index.md) for the canonical read order and source-of-truth rules.
- **Contributors:** See [CONTRIBUTING.md](CONTRIBUTING.md) for the contribution process.
- **Freeze-and-burn** refers to the one-time governance ceremony that permanently locks core game logic. Details in [docs/manuals/developer/protocol-overview.md](docs/manuals/developer/protocol-overview.md).

## Foundry scripts
- `script/Deploy.s.sol`: production deployment script (deploys the required core + genesis contracts except `MaintenanceHub`; no wiring)
  - simulates the full deploy sequence (constructors + proxy initializations) before broadcasting so malformed Aerodrome roots or a late revert cannot leave a partial live deployment onchain
  - fails closed if the wrapped `DexAdapter` resolves `weth()` / `defaultFactory()` to non-contract addresses
  - on Base mainnet (chainId 8453), validates `AERODROME_ROUTER`, `ADMIN_SAFE`, and `LP_WITHDRAW_RECIPIENT` against the canonical v1.0.0 addresses pinned in the deployment docs unless you deliberately use the documented break-glass override flags
  - defaults `INITIAL_OWNER` to the deployer
  - requires `ADMIN_SAFE`; `Deploy.s.sol` grants proposer/executor rights on the governance `TimelockController` to that Safe
  - if `INITIAL_OWNER != deployer`, the script requires `ALLOW_NON_DEPLOYER_INITIAL_OWNER=true` (explicit opt-in for split-key deployment, because `LaunchController.guardian` also follows `INITIAL_OWNER`)
  - deploys `MineCore`, `Furnace`, `MarketRouter`, and `ShareholderRoyalties` as implementation + transparent-proxy pairs, and treats the proxy addresses as the canonical runtime addresses for downstream wiring
- `script/DeployLocal.s.sol` / `script/DeployLocalDexHarness.s.sol`: local-only core + mock-Dex deploy helpers used by the local deployment flow
  - both simulate their full constructor / pool-registration sequences before broadcasting so a late local constructor or factory-registration revert cannot leave a partial local stack behind
  - `DeployLocalDexHarness.s.sol` also asserts that the freshly deployed `DexAdapter` and router resolve the expected local WETH / factory / pool roots before the broadcast sequence is considered successful
- `script/DeployMaintenanceHub.s.sol`: deploys `MaintenanceHub` after the initial wiring sequence so its constructor can validate the canonical `MarketRouter` / `Furnace` / `VeClaimNFT` / `ShareholderRoyalties` links
- `script/DeployAgentLens.s.sol`: optional `AgentLens` deploy helper for any chain
  - fails closed if the supplied addresses do not already resolve to one canonical live bundle, including optional `MaintenanceHub` pins and companion dependency requirements for `MaintenanceHub` / `LpStakingVault7D` / `GenesisLPVault24M` / `LaunchController`
- `script/Wire.s.sol`: production wiring (reads `deployments/<network>.json`; run once before `DeployMaintenanceHub.s.sol`, run again after the hub address is added, and rerun once more after `FinalizeGenesis.s.sol` creates the live CLAIM/WETH pool so `FurnaceEntryTokenRegistry` can bind the canonical WETH/CLAIM hop; it also performs the wire-time `ClaimToken` freeze/owner-renounce while leaving the remaining quartet unfrozen until freeze-and-burn finality; simulates the full wire sequence before broadcasting so wrong owner/guardian keys fail closed before any partial writes; validates manifest `chainId` matches `block.chainid`; on mainnet, validates canonical Aerodrome router address and cross-checks manifest `claimWethPool` against deterministic `poolFor()` computation)
  - expects `deployments/<network>.json` to treat the runtime quartet `address` fields as proxy addresses
  - manual Foundry-only flows must update `deployments/<network>.json` with the `MaintenanceHub` address/startBlock before the second wiring sequence; the sync scripts only mirror manifests and do not parse new broadcasts into JSON
- `script/FreezeAndBurn.s.sol`: canonical freeze-and-burn finality path. Schedules/executes one timelock batch that asserts `ClaimToken` is already frozen/ownerless from `Wire.s.sol`, freezes the remaining 4 freeze-gated contracts first, and only then burns the 4 runtime `ProxyAdmin`s. If any freeze precondition fails, no proxy admin is burned.
  - expects both the direct protocol `owner()` paths and the runtime `ProxyAdmin`s to already be owned by `TimelockController`; `ADMIN_SAFE` controls proposer/canceller/executor roles on that timelock
  - for proxy-backed runtime contracts, this freezes the documented wiring setters but does not disable upgrades by the owned proxy admins
- `script/FinalizeGenesis.s.sol` / `script/FinalizeLocalGenesis.s.sol`: genesis finalization helpers (both simulate the full finalize + guardian-rotation + postcondition sequence before broadcasting so stale ownership, paused-takeover, or missing-LP-lock state fail closed before any live tx)
- `script/SmokeFullApp.s.sol`: comprehensive full-app smoke test covering ~40 transaction paths across all deployed contracts (Furnace entries, lock management, market ops, takeovers, royalties, delegation, LP vault, ClaimAllHelper, maintenance, checkpoints, token ops, DEX); local-only, requires genesis-finalized Anvil
- `script/SmokeSepolia.s.sol`: live-chain variant of `SmokeFullApp` for Base Sepolia; broadcast-only (no cheatcodes), ~35 paths, reads `deployments/base_sepolia.json`; run post-genesis when CLAIM/WETH pool is live
- `scripts/deploy_prod.mjs`: end-to-end helper (intentionally limited to `base_mainnet` and `base_sepolia`)
  - fails closed if the RPC chainId does not match the selected manifest/network
  - production/testnet deploys require the canonical `ADMIN_SAFE` and `LP_WITHDRAW_RECIPIENT`; the wrapper can source them from `deployments/<network>.json`, but it refuses env/manifest mismatches
  - deploy (optional)
  - write manifests (addresses + start blocks) when `--deploy`, `--refresh-manifest-from-broadcast`, or `--refresh-live-state` is used
  - manual broadcast-derived refreshes now require exact timestamped broadcast artifacts (`run-<timestamp>.json`); `run-latest.json` is intentionally rejected to prevent stale artifact reuse
  - deploy-based manifest refreshes also record `GenesisLPVault24M.lpWithdrawRecipient`, `TimelockController.proposer`, and `TimelockController.executor`, and they clear stale `MaintenanceHub` / `AgentLens` / `FurnaceQuoter` helper entries before the post-wire helper refresh
  - `--finalize-broadcast-file <path>` plus `--refresh-live-state` refreshes live CLAIM/WETH pool metadata after `FinalizeGenesis.s.sol` and fails closed if the pool is live but its `startBlock` is still unknown
  - if `INITIAL_OWNER != deployer`, the wrapper refuses the one-command `--deploy --wire` path; use the manual split-key flow so the owner can execute the remaining owner-only wiring calls
  - if `MaintenanceHub` is already present in the manifest, the wrapper preflights it before wiring and reuses it only when its live runtime bytecode still matches the current canonical `MarketRouter` / `Furnace` / `VeClaimNFT` / `ShareholderRoyalties` / `WETH` roots and its `rescueRecipient()` still matches the manifest pin
  - `--wire` refreshes `FurnaceQuoter`, immutable helper pins, and deploys/reuses `AgentLens` so a normal `--deploy --wire --verify` flow can end with a canonical helper manifest; `--deploy-agent-lens` remains available for standalone helper repair/redeploys
  - wire (optional)
  - verify (optional)
  - wire-only / verify-only runs use the existing manifest and do not require a local Deploy broadcast artifact
  - wrapper: `node scripts/deploy_prod.mjs --network base_sepolia --rpc-url $RPC_URL --deploy --wire --verify`
- `script/FinalizeOwnership.s.sol`: ownership handoff helper
  - on Base mainnet / Base Sepolia, `OWNERSHIP_ACTION=initiate` now fails closed unless genesis is finalized, `MineCore.guardian` has rotated away from `LaunchController`, and `ClaimToken` is already frozen plus owner-renounced from `Wire.s.sol`
  - simulates the full initiate / accept sequence before broadcasting so a stale manifest or non-conforming target cannot leave ownership half-transferred across the stack
  - the standard manifest-driven path now also refuses missing, code-less, or duplicate ownership targets before any simulated or live handoff, rejects `NEW_OWNER == current actor`, and fails closed on unexpected `owner` / `pendingOwner` drift unless you intentionally opt into the env-driven manual subset mode, which now requires at least one explicit target
  - canonical mainnet usage is `NEW_OWNER = deployments/<network>.json .contracts.TimelockController.address`; do not point `NEW_OWNER` at `ADMIN_SAFE`
  - when present in the manifest, the helper transfers the four runtime `proxyAdmin` contracts alongside the normal owned contracts
  - `ALLOW_UNSAFE_PRE_FINAL_HANDOFF=true` is a break-glass escape hatch only for deliberate manual recovery flows
- `script/FinalizeTimelockBootstrap.s.sol`: renounces the deployer's bootstrap timelock admin role after verifying `ADMIN_SAFE` already has proposer/canceller/executor roles
- `script/TimelockAcceptOwnership.s.sol`: schedules/executes the timelock batch that calls `acceptOwnership()` on the direct `Ownable2Step` contracts after `FinalizeOwnership.s.sol` sets `pendingOwner = TimelockController`
  - use it for rehearsal and calldata generation on fork/test environments; on mainnet, the actual `scheduleBatch(...)` / `executeBatch(...)` calls must come from the `ADMIN_SAFE`-controlled timelock path

## Genesis infrastructure (required)
- `LaunchController` – one-shot genesis controller (10d accrual → materialize King bucket + liquidity + LP lock + activate).
- `GenesisLPVault24M` – genesis LP lock vault (24-month lock + fixed-recipient withdrawal; see `docs/spec/vault-spec.md`).

Contract/file naming in `src/` is aligned to these docs.

## Analytics templates
- Supported v1.0.0 templates: Dune SQL templates live in `analytics/dune/`.
- Query hygiene (filter-before-order/limit) is enforced in the reference queries.

## Deployment + analytics artifacts
- `deployments/` (addresses + start blocks; required for Dune)
- `abis/` (ABI JSON arrays; or verify contracts on explorer)
- `analytics/` (Dune SQL templates; query hygiene patterns)

## Trademarks

See [TRADEMARKS.md](TRADEMARKS.md). ClaimRush is the protocol; the name, logos, domains, and handles are not licensed for reuse. The official application UI is proprietary and is not released.

## Contributing

See [CONTRIBUTING.md](CONTRIBUTING.md) to set up, open a PR, and sign the CLA.

## License

MIT — see [LICENSE](LICENSE).
