# Analytics and leaderboards (v1.0.0)

Canonical supported analytics path (v1.0.0 in this repo):
- The Graph subgraph (`subgraph/`), serving the GraphQL contract in `docs/analytics/subgraph-schema-v1.0.0.md`.

Unsupported analytics backends (v1.0.0 in this repo):
- Custom indexers (Postgres or otherwise).

This folder contains REQUIRED Dune SQL templates under `analytics/dune/` (deliverable for v1.0.0).
Optional Dune panel templates in `analytics/dune/panels/` also include a 7d Furnace bonus history chart source.

Official leaderboard definitions (only these 8):
- `docs/analytics/leaderboards-ui-and-dune-compatible-v1.0.0.md`

Dune SQL templates under `analytics/dune/leaderboards/` implement the 8 spec
leaderboards 1:1 (file numbers 01–08 match spec leaderboard numbers #1–#8).

Duration filtering (per spec):
- Most leaderboards support: `24h`, `7d` (default), `30d`, `lifetime`
- “Top veCLAIM holders” (spec #6) is current-only (snapshot)

Dune integration pack (addresses, start blocks, enums, events):
- `docs/analytics/dune-integration-pack-v1.0.0.md`
- `deployments/base_mainnet.json`

Indexer/Dune implementation notes (normative):
- `docs/analytics/indexer-and-dune-implementation-guide-v1.0.0.md`

## Subgraph setup
1) Fill `deployments/base_mainnet.json` with real addresses and start blocks (startBlock MUST be > 0).
2) Sync the production manifest from the deployment manifest instead of hand-editing addresses:

```bash
python3 scripts/sync_subgraph_manifest_from_deployments.py \
  --manifest subgraph/subgraph.prod.yaml \
  --deployments deployments/base_mainnet.json
```

The production deploy script then copies `subgraph/subgraph.prod.yaml` into the active
`subgraph/subgraph.yaml` before build/deploy and restores the prior active file afterward.

3) Verify manifest drift, runtime readiness, manifest entity completeness, ABI event coverage, mutable wiring semantics, and codegen/build layout before deploy:

```bash
make subgraph-manifest-sync-check

make subgraph-live-runtime-readiness-check

python3 scripts/check_subgraph_manifest_entities.py \
  subgraph/subgraph.yaml \
  subgraph/subgraph.prod.yaml \
  subgraph/subgraph.staging.yaml \
  subgraph/subgraph.local.yaml

python3 scripts/check_subgraph_manifest_events_vs_abi.py \
  subgraph/subgraph.yaml \
  subgraph/subgraph.prod.yaml \
  subgraph/subgraph.staging.yaml

python3 scripts/check_subgraph_protocol_wiring_semantics.py
python3 scripts/check_subgraph_codegen_layout.py
```

4) Build and deploy the subgraph per `subgraph/README.md`.

Canonical indexing notes:
- `Protocol.mineCore`, `Protocol.marketRouter`, `Protocol.furnace`, and `Protocol.shareholderRoyalties` are latest-observed wiring fields. They are refreshed from canonical rewiring receipts (`MineCore.FurnaceChanged`, `VeClaimNFT.FurnaceChanged`, `VeClaimNFT.MineMarketChanged`, `Furnace.MineCoreChanged`, `Furnace.MineMarketChanged`, `Furnace.ShareholderRoyaltiesChanged`, `ShareholderRoyalties.ShareholderWiringSet`), with `ShareholderWiringSet` also providing an early bootstrap path before the first Baron business event.
- `MarketRouter.executeAutoFurnace` emits both `BonusTargetEscrowExecuted` (canonical generic execution receipt) and `BonusTargetEscrowAutoFurnaceExecuted` (back-compat companion receipt). Market execution volume should key off the generic receipt.
- `Furnace.LpStreamFunded` is indexed as `LpStreamFundedEvent`, while the latest live stream schedule is exposed on `FurnaceState.lpStreamRatePerSec` and `FurnaceState.lpStreamPeriodFinish`.
- Derived leaderboard sync captures the upstream subgraph `_meta` head once per run and MUST use that same `asOfBlock` / `asOfTs` as the upper cutoff for incremental ingest and the pinned block for the current ve snapshot. If `_meta` is unavailable, ingest may continue best-effort but snapshot materialization MUST be skipped instead of publishing mixed-head results.

Not part of v1.0.0 in this repo:
- Running these SQL templates as the canonical backend.
- Dune panel templates assembled into Dune views.

## Furnace bonus semantics (v1.0.0)

Per `docs/analytics/dune-integration-pack-v1.0.0.md` (and the main spec):

- `FurnaceEnter.bonusClaim` is the **net CLAIM bonus received by the user** (headline/UI bonus).
  - The headline-bonus metric is `SUM(FurnaceEnter.bonusClaim)` per user.
  - Note: the 8-board spec does not include a dedicated "bonus received" leaderboard; this metric is exposed
    only via panels and per-user views.

Notes:
- The canonical v1.0.0 event contract does not expose the LP rewards/top-up portion of a gross bonus as a separate field.
- Optional reserve-style panels in `analytics/dune/panels/` therefore treat `SUM(bonusClaim)` as “bonus spent” (partial accounting / lower bound).
  - If you need exact reserve accounting (user bonus + LP rewards + overflow drip), do it in an indexer that enriches events with additional state.
- Any shipped 7d / 24h Furnace event window (application or API) MUST capture subgraph `_meta` first, pin reads to that block, and paginate with a stable cursor. Do not use moving-head `skip` pagination for these public stats.

## Query hygiene requirement
- Any filter that changes which rows exist MUST happen before ORDER BY / LIMIT / pagination.
- No address exclusions are applied in v1.0.0 leaderboards.

## SQL lint
Run a lightweight sanity check over all analytics SQL templates:

- `make analytics-lint`
  - includes leaderboard snapshot-cutoff, worker window-guard, and admin system metrics snapshot-consistency checks

See also:
- `analytics/TESTING.md` (required analytics test gates)

## Related docs
- `docs/analytics/metrics-canon-v1.0.0.md` (canonical metric definitions, units, rounding)
- `docs/analytics/indexing-hosting-and-derived-data-reference-v1.0.0.md` (subgraph facade, derived REST, hosting)
