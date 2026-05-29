# ClaimRush Subgraph (v1.0.0)

Canonical supported analytics backend (v1.0.0 in this repo):
- The Graph subgraph in this folder.

Source of truth (MUST match):
- GraphQL schema contract: `docs/analytics/subgraph-schema-v1.0.0.md`
- Canonical event decoding contract: `docs/analytics/dune-integration-pack-v1.0.0.md`
- Addresses + start blocks: the deployment manifest for the target network
  - Production: `deployments/base_mainnet.json`
  - Staging: `deployments/base_sepolia.json`
  - Local: `deployments/local.json`

Unsupported analytics paths (v1.0.0 in this repo):
- Assembled Dune views.
- Custom indexers (Postgres or otherwise).

## Indexing assumptions

These are **intentional** constraints of the v1.0.0 subgraph that downstream services rely on:

- Reorg safety: all state is derived **only** from onchain events and deterministic `eth_call` reads at the indexed block. No wall-clock time, no randomization.
- Event IDs: immutable entities use `{txHash}-{logIndex}` IDs. Non-immutable “current state” entities use stable IDs (e.g. `tokenId`, `reignId`, ...).
- ve snapshots:
  - `User.totalLockedClaimWei` and `User.veBalanceWei` are **event-driven snapshots**, not continuously-updated values. `veBalanceWei` does not decay between events.
  - `VeLock.currentVeWei` stores the per-lock snapshot at the lock’s last activity. Aggregate updates replace the stored snapshot with a new snapshot at event time (including decay catch-up on activity boundaries like Transfer/Extend/Unlock).
  - “Top veCLAIM holders (current)” must be computed by the derived-data job described in `docs/analytics/subgraph-schema-v1.0.0.md`.
- EntryTokenRegistry templates start indexing at the wiring block (when MineCore/Furnace emits `EntryTokenRegistrySet`). Historical registry events before that block may not be seen.
  - To avoid missing critical config like `RouterConfigSet`, the subgraph snapshots registry state via onchain reads at wiring time.
  - The subgraph creates at most one dynamic data source per registry address to avoid duplicate event processing when both MineCore and Furnace wire the same registry.
  - Allowlisted `TokenConfig` rows are still discovered from emitted `TokenConfigSet` / `TokenEnabledChanged` events (the registry does not provide enumeration).
  - Back-compat alias: `Protocol.entryTokenRegistry` is set to `0x0` until the Furnace emits `EntryTokenRegistrySet`. Once `furnaceEntryTokenRegistry` is known, `entryTokenRegistry` MUST equal it.
- Furnace bonus snapshots:
  - 24h bonus quantiles/min/max are computed from 5-minute buckets. “Live” `currentBps` is updated every indexed block on staging/prod (the manifests that enable the Furnace block handler).
  - Full 24h window recomputes run at most once per 5-minute bucket (performance guard).
  - 7d/30d min/max recomputes run at most once per day (on UTC day boundary) using DailyFurnaceAgg rollups.
  - DailyFurnaceAgg.reserveEnd is initialized from Furnace.getFurnaceState().reserve on the first observed block of each UTC day, and is updated by reserve-affecting events (BonusPaid, LpOverflowDripPaid, ReserveClamped/Credited, LockSoldToFurnace).
    - LockSoldToFurnace emits only reserveAdd (delta). When available, the subgraph uses an onchain read (getFurnaceState().reserve) at the indexed block to set the canonical post-sellback reserve and avoid drift when indexing starts mid-history.
  - The local/default manifests (`subgraph/subgraph.local.yaml` and `subgraph/subgraph.yaml` when pointed at `deployments/local.json`) intentionally omit the Furnace block handler for local graph-node workflows. On local, bonus timing/snapshot data still advances on Furnace bonus/reserve events, but idle periods will not refresh `currentBps` until the next relevant event.
- Furnace LP rewards stream wiring + health:
  - `Protocol.lpStakingVault` is updated from `Furnace.LpRewardsVaultSet` (canonical) and may change pre-freeze.
  - `Protocol.furnaceQuoter` is updated from `Furnace.FurnaceQuoterSet` (canonical) and emits immutable `FurnaceQuoterSetEvent`.
  - `LpRewardsNotifyFailed` events are indexed as `LpRewardsNotifyFailedEvent` for monitoring (notify is best-effort; the CLAIM transfer still succeeds).
  - `ReserveClamped` events are indexed as `ReserveClampedEvent` and also update `FurnaceState.reserve` to `newReserve`.
- MineCore king auto-lock (optional automation):
  - `KingAutoLockConfigured/Executed/Skipped/Failed` are normalized into `ActivityItem.kind` values `KING_AUTOLOCK_*`.
  - The full config payload (duration, minVeOut, etc.) is not stored as a dedicated entity in v1.0.0.

- MineCore reign recipients routing:
  - `ReignRecipientsSetEvent.isMidReignUpdate` is derived for the first observed recipients config per reign.
  - If the tx receipt contains a MineCore `Takeover` log, treat it as takeover-time config (`isMidReignUpdate=false`); otherwise treat it as a mid-reign update.
  - This requires `receipt: true` for the MineCore `ReignRecipientsSet` handler in all manifests.

- MineCore withdrawals + refund bucket:
  - `KingWithdrawal` is always emitted on successful king withdrawals.
  - If a withdrawal is sent to `to != king`, MineCore also emits `KingWithdrawalTo(king,to,amount)` for destination tracking.
    - The subgraph indexes this as `KingWithdrawalToEvent` (in addition to `KingWithdrawalEvent`).
  - Refund fallback (failed refund transfer) is surfaced via `RefundCredited(to, amount)` and `RefundWithdrawn(user,to,amount)`.
    - The subgraph indexes these as `RefundCreditedEvent` and `RefundWithdrawnEvent` for traceability.
  - Royalties hardening (non-fatal):
    - If ShareholderRoyalties reverts during takeover allocation or flush, MineCore emits:
      - `ShareholderRoyaltiesTakeoverFailed(reignId, amountEth, reason)`
      - `ShareholderRoyaltiesFlushFailed(reason)`
    - The subgraph indexes these as immutable events `ShareholderRoyaltiesTakeoverFailedEvent` and `ShareholderRoyaltiesFlushFailedEvent`.
    - In v1.0.0, `reason` is expected to be empty bytes (hardening: never allocate/copy revert data).

- Protocol wiring singleton:
  - `Protocol.mineCore`, `Protocol.marketRouter`, `Protocol.furnace`, and `Protocol.shareholderRoyalties` track the latest observed current wiring within the indexed event surface, not just the first non-zero seed.
  - Canonical update receipts are `MineCore.FurnaceChanged`, `VeClaimNFT.FurnaceChanged`, `VeClaimNFT.MineMarketChanged`, `Furnace.MineCoreChanged`, `Furnace.MineMarketChanged`, `Furnace.ShareholderRoyaltiesChanged`, and `ShareholderRoyalties.ShareholderWiringSet`.
  - `ShareholderWiringSet(mineCore, mineMarket, furnace)` still gives fresh deployments an early bootstrap path before the first Baron claim/flush/allocation event.
  - If any rewiring event points at a newly deployed indexed peer contract, operators still need a manifest/datasource update for full event coverage on that new emitter.
  - v1.0.0 does not expose a dedicated immutable `ShareholderWiringSetEvent` entity.

- Keeper allowlists (ops transparency):
  - `ShareholderRoyalties.ShareholderAutoCompoundKeeperSet` updates `ShareholderAutoCompoundKeeper` (current allowlist state) and emits immutable `ShareholderAutoCompoundKeeperSetEvent`.
  - `LpStakingVault7D.HarvestKeeperSet` updates `HarvestKeeper` (current allowlist state) and emits immutable `HarvestKeeperSetEvent`.
  - `MarketRouter.SettlementKeeperSet` updates `MarketSettlementKeeper` (current allowlist state) and emits immutable `MarketSettlementKeeperSetEvent`.
  - Keeper allowlists are not enumerable onchain; the subgraph can only reconstruct allowlist membership from emitted `*KeeperSet` events.

- MaintenanceHub (ops transparency):
  - `MaintenanceHub.Poked` is indexed as immutable `MaintenancePokedEvent` (includes `checkpointOk`, `flushOk` fields).

- MarketRouter offer spam controls (bonus target escrows):
  - `MarketRouterParams` tracks the latest known `minBonusTargetEscrowBudgetClaimWei` and `maxBonusTargetEscrowDiscountBps`.
  - Updated from `MarketRouter.BonusTargetEscrowParamsChanged`.
  - If indexing starts mid-history, the subgraph performs a best-effort deterministic onchain snapshot (`minBonusTargetEscrowBudget()` / `maxBonusTargetEscrowDiscountBps()`) the first time any MarketRouter event is observed (skipped on `local`).

- Market listings (orderbook normalization):
  - `MarketListing.priceBps` is computed as `minClaimOutWei / VeLock.amountWei * 10_000`.
  - If `VeLock.amountWei` is missing (e.g. indexing starts mid-history), the subgraph attempts a deterministic onchain hydration:
    - resolve ve address via `MarketRouter.ve()`
    - read `VeClaimNFT.getLockInfo(tokenId)` at the indexed block
  - On `local` networks, these eth_calls are skipped (Anvil may prune old block state). In that case `priceBps` falls back to a large sentinel (`1_000_000_000`) to avoid sorting unknown listings as “cheapest”.

- Market trades (back-compat):
  - `MarketTradeEvent` is derived from the canonical sellback signal `Furnace.LockSoldToFurnace` (strict mode: Furnace-only counterparty).
  - `kind = "BUY"`, `buyer = Furnace address`, `seller = event.seller`.
  - `priceInClaimWei = claimOut` (seller payout), `feeToFurnaceWei = cut` (lockAmount - claimOut).
  - `lockAmountWei = lockAmount`, `discountBps = floor(cut * 10_000 / lockAmount)` (nullable if lockAmount == 0).
  - `offer` is retained only for schema compatibility and stays `null` in the strict-mode subgraph.

- Global offer execution history:
  - `BonusTargetEscrowEvent.kind = "FILLED"` is written from the canonical generic receipt `MarketRouter.BonusTargetEscrowExecuted`.
  - `BonusTargetEscrowEvent.kind = "AUTO_FURNACE_EXECUTED"` remains the same-tx companion row for detail and compatibility consumers. History UIs should dedupe or filter these companion rows to avoid showing one fill twice.

- VeClaimNFT burns (Transfer to 0x0):
  - User burns are handled by lifecycle events (LockUnlocked / LockMerged) and MUST NOT be double-counted.
  - Furnace burns (sellback/settlement) may occur before Protocol.furnace is discovered when indexing starts mid-history.
    - To avoid misclassifying user burns (unlock/merge), the subgraph only handles Transfer(to=0) burns when `from` equals the canonical Furnace address.
      - Prefer `Protocol.furnace` when known; otherwise resolve via `VeClaimNFT.furnace()` at the indexed block (non-local networks).

- LP auto-compound attribution:
  - `LpRewardsLockedEvent.autoCompounded` is `true` only when the top-level tx calls `LpStakingVault7D.compoundFor(address)` or `compoundForMany(address[],uint256)`.
  - Calls routed through other contracts (multicalls/routers) may not be detected (selector-based).

- Furnace token entries (mode=3):
  - `FurnaceEnterEvent.tokenIn/amountInWei` are populated only for top-level txs calling `Furnace.enterWithToken` or `Furnace.enterWithTokenFromCallerFor`.
  - For delegated token entries, observed token transfer is attributed to the payer (`tx.from`) rather than the recipient user.
  - Observed amounts are derived from ERC20 `Transfer` logs and clamped to calldata to resist tx-poisoning.
- Tx joins: `TxFurnaceEnter` is only written for txs that include the auto-furnace execution receipt pair (`MarketRouter.BonusTargetEscrowExecuted` plus back-compat `MarketRouter.BonusTargetEscrowAutoFurnaceExecuted`). It is used to recover the final `FurnaceEnter.tokenId` when the MarketRouter receipt omits the minted token id. When `Protocol.marketRouter` is already known, the join helper also requires the receipt to come from that canonical emitter (not just a matching topic). If a tx emits multiple `FurnaceEnter` events for the same user, the last one wins.
- DelegationHub sessions: `expiry = 0` is immediately expired, not an active “no expiry” session. Explicit revocation is `perms = 0` AND `expiry = 0` (`revokeSession` clears both).

## Configure (REQUIRED before staging/prod subgraph deploys)

A staging/prod subgraph deploy requires every indexed contract in the target deployment manifest to have a non-zero address and `startBlock > 0`.

1) Open the deployment manifest for the network you are about to deploy and confirm every contract you index has:
- `address` != `0x0000000000000000000000000000000000000000`
- `startBlock` > 0

Indexed contracts in v1.0.0 include (non-exhaustive):
- MineCore, Furnace, ShareholderRoyalties, VeClaimNFT, MaintenanceHub
- DelegationHub + ClaimAllHelper (bot sessions + session history)

If any indexed contract has a zero address or `startBlock = 0`, the target deployment manifest is invalid for indexed deployment.

2) Sync the target manifest from the deployment manifest (from repo root):

```bash
# Production
python3 scripts/sync_subgraph_manifest_from_deployments.py \
  --manifest subgraph/subgraph.prod.yaml \
  --deployments deployments/base_mainnet.json

# Staging
python3 scripts/sync_subgraph_manifest_from_deployments.py \
  --manifest subgraph/subgraph.staging.yaml \
  --deployments deployments/base_sepolia.json
```

Notes:
- The sync script fails if any required address is zero or any required start block is 0.
- This is intentional; the manifest stays invalid for indexed deployment until those values are set.
- The deploy scripts copy the chosen network-specific manifest into `subgraph/subgraph.yaml` for the deploy run, sync that active file, build, deploy, and then restore the prior `subgraph.yaml`.
- For a repo-wide manifest sync gate, run `make subgraph-manifest-sync-check`.
- For an explicit pre-deploy live-network runtime gate, run `make subgraph-live-runtime-readiness-check`.

## Validate manifest (RECOMMENDED)

This catches subtle `indexed` mismatches between `subgraph.yaml` and pinned ABIs. Subgraph manifests are expected to consume the canonical exported `../abis/<network>/*.abi.json` files directly.

```bash
# From the subgraph/ folder
python3 ../scripts/check_subgraph_manifest_events_vs_abi.py subgraph.yaml

# Or validate multiple manifests in one go (repo root paths also supported)
python3 ../scripts/check_subgraph_manifest_events_vs_abi.py subgraph.yaml subgraph.prod.yaml subgraph.staging.yaml subgraph.local.yaml
```

## Validate runtime readiness (RECOMMENDED before staging/prod deploys)

This catches manifests that still point at the zero address or use `startBlock = 0` even when schema/ABI parity checks are green. Use `--allow-network local` for local-only manifests. The default `make gates` path does not include live runtime readiness, so run this check explicitly for staging/prod deployments.

```bash
make subgraph-live-runtime-readiness-check
```

## Validate ABI coverage (RECOMMENDED)

This fails when a newly exported ABI event is left unindexed unless it is explicitly allowlisted as intentionally unindexed. It is the guardrail that catches event coverage drift such as missing `BonusTargetEscrowExecuted`, `LpStreamFunded`, or mutable wiring handlers like `Furnace.MineCoreChanged`.

```bash
# From the repo root
python3 scripts/check_subgraph_manifest_events_vs_abi.py \
  subgraph/subgraph.yaml \
  subgraph/subgraph.prod.yaml \
  subgraph/subgraph.staging.yaml \
  subgraph/subgraph.local.yaml
```

## Validate mutable protocol wiring semantics (RECOMMENDED)

This catches semantic drift that raw ABI coverage cannot see, such as a handler existing in the manifest but still using write-once seeding for mutable peer addresses.

```bash
python3 scripts/check_subgraph_protocol_wiring_semantics.py
```

## Validate codegen/build layout (RECOMMENDED)

This catches stale checked-in generated artifacts and ensures `npm run build` regenerates the auto-generated GraphQL/AssemblyScript bindings (the gitignored generated/ output of `graph codegen`) before compiling.

```bash
python3 scripts/check_subgraph_codegen_layout.py
```

## Validate derived event kinds (RECOMMENDED)

This catches drift that ABI coverage checks cannot see, such as a mapping no longer writing `BonusTargetEscrowEvent.kind = "FILLED"` while the schema and consumer docs still expect that history row.

```bash
python3 scripts/check_subgraph_derived_event_kinds.py
```

## Validate manifest entity completeness (RECOMMENDED)

This catches mappings that started constructing a new entity without updating manifest `entities:` metadata.

```bash
python3 scripts/check_subgraph_manifest_entities.py \
  subgraph/subgraph.yaml \
  subgraph/subgraph.prod.yaml \
  subgraph/subgraph.staging.yaml \
  subgraph/subgraph.local.yaml
```

## Validate schema contract (RECOMMENDED)

This enforces that `schema.graphql` is a **superset** of the pinned v1.0.0 consumer data contract.

```bash
python ../scripts/check_subgraph_schema_vs_doc.py \
  --doc ../docs/analytics/subgraph-schema-v1.0.0.md \
  --schema schema.graphql
```

## Build (REQUIRED)

Use **Node 22.x** (match the repo root `.nvmrc`). Graph CLI 0.98+ and its dependency tree expect a current Node; installs may warn with `EBADENGINE` on older runtimes.

```bash
cd subgraph
npm ci
python3 ../scripts/check_subgraph_codegen_layout.py
npm run build
```

## Deploy

Two indexer providers are supported and can be targeted from the same deploy script:

- **Goldsky** — primary upstream for `/api/subgraph` (the URL the frontend + workers actually query).
- **Subgraph Studio (The Graph)** — fallback mirror, wired into `SUBGRAPH_FALLBACK_DIRECT_URL` / `SUBGRAPH_FALLBACK_URL`.

`scripts/subgraph_deploy_staging.sh` and `scripts/subgraph_deploy_prod.sh` sync the manifest, build once, then deploy to whichever providers are enabled via env flags. By default both providers run; set `DEPLOY_GOLDSKY=0` or `DEPLOY_STUDIO=0` to skip one.

### Prerequisites (one-time per operator machine)

- Node 22.x (match the repo root `.nvmrc`). Graph CLI 0.98+ expects a current Node.
- Subgraph Studio leg: nothing extra to install — the `graph` CLI is pinned in `subgraph/package.json` devDependencies and runs from `subgraph/node_modules/.bin/graph`.
- Goldsky leg: install the Goldsky CLI on your `PATH`. The script calls `goldsky login` and `goldsky subgraph deploy`, both of which require the binary.

  Follow the official install instructions at <https://docs.goldsky.com/introduction>. Do NOT pipe the install script straight into a shell — download the installer to a file, inspect it, then run it. After install:

  ```bash
  goldsky --version   # sanity check
  ```

  (The Goldsky CLI is not on npm, so it cannot be pinned as a subgraph devDependency.)

### Required env

| Var | Scope | Notes |
|-----|-------|-------|
| `DEPLOY_STUDIO` | both scripts | `1` (default) / `0`. Skip the Studio deploy when `0`. |
| `DEPLOY_GOLDSKY` | both scripts | `1` (default) / `0`. Skip the Goldsky deploy when `0`. |
| `SUBGRAPH_STUDIO_DEPLOY_KEY` | Studio | Required when `DEPLOY_STUDIO=1`. |
| `SUBGRAPH_STUDIO_SLUG` | Studio | Default: `claimrush-v1-0-0-staging` (staging) / `claimrush-v1-0-0` (prod). |
| `SUBGRAPH_VERSION_LABEL` | Studio | Default: `v1.0.0-staging` (staging) / `v1.0.0` (prod). |
| `GOLDSKY_DEPLOY_KEY` | Goldsky | Required when `DEPLOY_GOLDSKY=1`. Used by `goldsky login --token`. |
| `GOLDSKY_SUBGRAPH_SLUG` | Goldsky | Default: `claimrush-staging` (staging) / `claimrush` (prod). |
| `GOLDSKY_VERSION_LABEL` | Goldsky | **Required** when `DEPLOY_GOLDSKY=1` (no default; Goldsky versions diverge from Studio, e.g. `v1.0.5`). |
| `CONFIRM_PROD=YES` | prod only | Required to run `subgraph_deploy_prod.sh`. |

At least one of `DEPLOY_STUDIO` / `DEPLOY_GOLDSKY` must be `1`. If any enabled provider fails, the run aborts (no silent partial deploy).

Deploy order is Studio first, then Goldsky. The build runs once before either provider so a build failure blocks both.

### Staging deploy

From repo root:

```bash
# Both providers (default)
SUBGRAPH_STUDIO_DEPLOY_KEY=... \
GOLDSKY_DEPLOY_KEY=...         \
GOLDSKY_VERSION_LABEL=v1.0.6   \
  bash scripts/subgraph_deploy_staging.sh

# Goldsky only (bump only the primary)
DEPLOY_STUDIO=0                \
GOLDSKY_DEPLOY_KEY=...         \
GOLDSKY_VERSION_LABEL=v1.0.6   \
  bash scripts/subgraph_deploy_staging.sh

# Studio only (refresh the fallback mirror)
DEPLOY_GOLDSKY=0               \
SUBGRAPH_STUDIO_DEPLOY_KEY=... \
  bash scripts/subgraph_deploy_staging.sh
```

### Production deploy

From repo root:

```bash
CONFIRM_PROD=YES               \
SUBGRAPH_STUDIO_DEPLOY_KEY=... \
GOLDSKY_DEPLOY_KEY=...         \
GOLDSKY_VERSION_LABEL=1.0.1    \
  bash scripts/subgraph_deploy_prod.sh
```

Same env-gate semantics (`DEPLOY_STUDIO=0` / `DEPLOY_GOLDSKY=0`) apply.

### After deploying

After a successful Goldsky or Studio publish you also need to point the
consumers at the new URL. The exact wiring lives in the private app surfaces
(web and chat workers), but the contract is named entirely in environment
variables so this README can stay public:

- **Goldsky leg**: set `SUBGRAPH_DIRECT_URL` in the web app config and the
  `SUBGRAPH_URL` secret on both chat-worker configs (the realtime worker and
  the jobs worker) to the new endpoint:
  `https://api.goldsky.com/api/public/<project_id>/subgraphs/<slug>/<version>/gn`
- **Studio leg**: set `SUBGRAPH_FALLBACK_DIRECT_URL` in the web app config and
  the `SUBGRAPH_FALLBACK_URL` secret on the chat workers if you bumped the
  Studio version.

## Staging vs Production manifests (REQUIRED)

This repo keeps two explicit manifests to prevent accidental cross-network deploys:

- `subgraph/subgraph.staging.yaml` (Base Sepolia)
  - Uses ABIs from `abis/base_sepolia/`
  - Addresses + start blocks MUST come from `deployments/base_sepolia.json`
  - Graph network: `base-sepolia`

- `subgraph/subgraph.prod.yaml` (Base mainnet)
  - Uses ABIs from `abis/base_mainnet/`
  - Addresses + start blocks MUST come from `deployments/base_mainnet.json`
  - Graph network: `base`

`subgraph/subgraph.yaml` is treated as the *active* manifest used by `graph` tooling. Deploy scripts copy the correct manifest into `subgraph.yaml` for the deploy run and restore it afterward.

## Local dev subgraph

For realistic local development, index a local chain (Anvil/Hardhat) with a local graph-node.

This repo ships a separate manifest:
- `subgraph/subgraph.local.yaml` (network: `local`, addresses from `deployments/local.json`)

Keep the checked-in local manifests synced from `deployments/local.json`. The default `subgraph/subgraph.yaml` used by `graph codegen` / `graph build` is also expected to match the local deployment manifest in local workflows.

```bash
make subgraph-manifest-sync-check
```

From repo root, after a local protocol deployment has populated `deployments/local.json`:

```bash
bash scripts/graphnode_local_up.sh
bash scripts/subgraph_deploy_local.sh
```

Defaults (override via env vars):
- `SUBGRAPH_NAME=claimrush/local`
- `GRAPH_NODE=http://127.0.0.1:8020`
- `IPFS=http://127.0.0.1:5001`

Notes:
- If you see `ECONNREFUSED` to `127.0.0.1:8020`, your local graph-node stack isn’t running.
- `scripts/subgraph_deploy_local.sh` is non-interactive; override `VERSION_LABEL` if you want.
