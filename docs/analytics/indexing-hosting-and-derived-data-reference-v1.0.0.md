# Indexing hosting + derived-data reference (v1.0.0)

This document is the canonical reference for the v1.0.0 indexing layer on **Base**.

It defines:
- Where the GraphQL read backend lives (subgraph hosting).
- How required derived views are produced and served.
- What the application pins via environment configuration.

This reference is normative for v1.0.0.

References:
- Schema (GraphQL contract): `docs/analytics/subgraph-schema-v1.0.0.md`
- Indexer implementation guide: `docs/analytics/indexer-and-dune-implementation-guide-v1.0.0.md`
- Analytics trust boundary: `docs/analytics/subgraph-schema-v1.0.0.md` and `docs/analytics/indexer-and-dune-implementation-guide-v1.0.0.md`

---

## A) High-level architecture (v1.0.0)

The application reads from three sources:

1. **GraphQL read backend** (primary multi-row read path)
   - Canonical endpoint pinned via `NEXT_PUBLIC_SUBGRAPH_URL`.
   - Proxies to an upstream subgraph host for entity reads and lists.
   - Serves resolver-style leaderboards (and other derived fields) from durable storage when the upstream subgraph cannot provide them.

   Implementation in this repo (v1.0.0):
   - The application serves `https://<origin>/api/subgraph` as the public same-origin GraphQL facade.
   - The facade proxies most allowlisted operations to `SUBGRAPH_URL`.
   - The facade answers leaderboard operations from durable storage (materialized tables), not from the upstream subgraph.

2. **Derived-data REST API** (required for rank lookup + certain “now” / sortable views)
   - Public same-origin endpoints under `https://<origin>/api/leaderboards/...`
   - The application proxies those requests to internal `/api/derived/...` endpoints.
   - Backed by periodic jobs writing to D1.
   - Used by the UI for “Find my rank” and for any derived leaderboard that should be fetchable without GraphQL.

3. **Base RPC** (write-gating and point lookups only)
   - Balances, allowances, chain id
   - Transaction status and receipts
   - MUST NOT be used to power leaderboards or multi-row lists.

---

## B) Production hosting (Base mainnet)

### B1) GraphQL read backend (subgraph + facade)

Policy:
- v1.0.0 uses a managed subgraph host for reliable indexing and low operational burden.
- The project MUST pin a single canonical GraphQL endpoint for the UI in production.
- In this repo, the pinned endpoint is a **facade** (`/api/subgraph`) that:
  - forwards standard entity queries to an upstream subgraph host, and
  - serves resolver-style leaderboards from D1 (because standard graph-node schemas do not expose these fields).

Upstream subgraph host:
- The repo deployment flow targets managed subgraph hosting via Subgraph Studio.

Hard rules:
- The upstream deployed schema MUST match `docs/analytics/subgraph-schema-v1.0.0.md` for entity types.
- The facade MUST implement the resolver-style leaderboard fields described in that schema doc.
- Data sources MUST match `deployments/base_mainnet.json` for addresses and `startBlock`.
- The application MUST surface indexing freshness using `_meta`.

Application env var (required):
- `NEXT_PUBLIC_SUBGRAPH_URL` = pinned production GraphQL endpoint.
  - Canonical same-origin value: `https://<origin>/api/subgraph`

Facade service config (required behind the facade):
- `SUBGRAPH_URL` = pinned upstream subgraph GraphQL endpoint (managed host / graph-node).
- `SUBGRAPH_AUTH_TOKEN` (optional) if the upstream host is private.

Operational notes:
- Record the upstream deployment identifier (deployment id / subgraph id) and the git commit used to deploy.
- Treat GraphQL as best-effort (never action-gating).

### B2) Derived-data layer (leaderboards + rank lookup + ve snapshot)

Why it exists (required):
- Standard graph-node GraphQL does not support custom resolver queries or query-time `GROUP BY` style aggregations.
- The v1.0.0 UI requires leaderboards that are:
  - duration-filtered (24h / 7d / 30d / lifetime),
  - sortable with deterministic tie-breaking,
  - pageable beyond the first page, and
  - able to return **any address** rank (“Find my rank”), even when outside the top N rows.
- “Top veCLAIM holders (current)” additionally requires a snapshot because ve decays continuously.

Derived-data pipeline (v1.0.0; REQUIRED):
- Implement a small derived pipeline backed by durable storage (e.g. D1).
- The pipeline has two responsibilities:

  1) **Mirror / ingest** (incremental)
     - Pull the required event entities and lock state from the upstream subgraph.
     - Capture the upstream `_meta` head once per run and apply it as the upper cutoff for all incremental ingest queries (`<= asOfBlockNumber` / `<= asOfTimestamp`).
     - Store a compact, query-friendly representation in D1.
     - Maintain an ingestion cursor so the job is incremental and idempotent.

  2) **Materialize leaderboards** (periodic snapshots)
     - For each board + duration, compute an ordered result set at one consistent `asOfTimestamp` / `asOfBlockNumber`.
     - Pin any live lock scan used for `Top veCLAIM holders (current)` to `block: { number: asOfBlockNumber }` so the current-ve snapshot cannot read a newer head than the one recorded in D1.
     - If `_meta` is unavailable, skip snapshot materialization rather than publishing rows with placeholder or mixed-head `asOf` metadata.
     - Persist ranked rows and snapshot metadata in D1 for fast reads.

Storage requirements (minimum; D1):
- Mirrored event tables (names are illustrative):
  - `lb_events_takeover` (newKing, pricePaidWei, timestamp, blockNumber, txHash, logIndex)
- `lb_events_reign_finalized` (king, totalClaimMinedWei, startTime, endTime, totalEthToKingWei, timestamp, blockNumber, txHash, logIndex)
  - `lb_events_shareholder_claim` (user, amountEthWei, timestamp, blockNumber, txHash, logIndex)
  - `lb_events_furnace_enter` (user, ethInWei, principalClaimWei, bonusClaimWei, mode, timestamp, blockNumber, txHash, logIndex)
  - `lb_events_lock_created` + `lb_events_lock_amount_increased` (user, amountWei, timestamp, blockNumber, txHash, logIndex)
- Lock state tables for ve snapshot:
  - `lb_locks` keyed by `tokenId` with `owner`, `amountWei`, `lockEnd`, `autoMax`
- Lifetime aggregates (optional):
  - `lb_user_lifetime` keyed by `address` with pre-aggregated lifetime totals
- Materialized leaderboards (REQUIRED):
  - `leaderboard_snapshot(boardKey, duration, asOfTimestamp, asOfBlockNumber, computedAt, rowCount)`
  - `leaderboard_row(boardKey, duration, rank, address, valueWei, valueInt)`

Indexes (REQUIRED):
- Paging: `PRIMARY(boardKey, duration, rank)`
- Rank lookup: `UNIQUE(boardKey, duration, address)`

Deterministic ordering (REQUIRED):
- Order by metric descending, then by `address` ascending as a tie-breaker:
  - `ORDER BY value DESC, address ASC`
- Assign ranks as 1..N in that stable order.

Cadence:
- Ingest + recompute on a fixed schedule (example: every 5 minutes).
- The snapshot metadata MUST be included in responses so the UI can label freshness.

API surfaces

1) GraphQL facade (`/api/subgraph`)
- The UI keeps using the GraphQL contract in `docs/analytics/subgraph-schema-v1.0.0.md`.
- The public same-origin endpoint is served by the application and proxied internally to the GraphQL facade.
- The facade MUST answer the resolver-style leaderboards fields (example: `leaderboardTopKingClaimMined(...)`) from durable storage.
- Everything else continues to proxy to the upstream subgraph.

2) Derived REST endpoints
These are required for rank lookup and are also useful for debugging and ops.

Public endpoints:
- `GET /api/leaderboards/board?board=<KEY>&duration=<DURATION>&n=...&offset=...`
- `GET /api/leaderboards/rank?board=<KEY>&duration=<DURATION>&address=<0x...>`

Optional derived-data endpoints:
- `GET /api/derived/leaderboards/board?board=<KEY>&duration=<DURATION>&limit=...&offset=...`
- `GET /api/derived/leaderboards/rank?board=<KEY>&duration=<DURATION>&address=<0x...>`

- `GET /api/derived/leaderboard/topBaronsByVeCurrent?limit=...&offset=...` (allowed compatibility alias; optional if the unified endpoint exists)

Response requirements (minimum):
- MUST include `asOfTimestamp`, `asOfBlockNumber`, and `chainId`.
- Rank endpoint MUST include the viewer’s row plus the row above (rank-1) when `rank > 1` so the UI can compute “Gap to next rank”.

Application routing:
- Current implementation uses same-origin `/api/leaderboards/*` routes exposed by the application, which proxy internally to `/api/derived/*` endpoints.
- The code does not expose a `NEXT_PUBLIC_DERIVED_API_URL` override.

---

## C) Staging and local testing

### C1) Local realism without public deployment

For private end-to-end testing without leaking a public deployment:
- Run an Anvil fork of Base mainnet.
- Run a local graph-node indexing that Anvil chain.

This provides:
- real router/pool behavior (on the fork),
- real event decoding,
- real subgraph query behavior,
without deploying to a public testnet.

### C2) Base Sepolia staging (optional)

Base Sepolia can be used for staging QA (wallet UX, mobile wallets, RPC quirks).

If secrecy is important:
- Treat any Sepolia deployment as disposable.
- Use shadow branding / shadow constants.
- Do not reuse deployer keys intended for mainnet.

---

## D) Monitoring and failure behavior

### D1) Indexing freshness

Required:
- UI MUST poll `_meta` and show a freshness indicator.
- Warn when `now - _meta.block.timestamp > 180 seconds`.

### D2) Derived job freshness

Required:
- Derived responses MUST include `asOfTimestamp` and `asOfBlockNumber`.
- UI MUST label leaderboards as delayed/stale if `now - asOfTimestamp > 15 minutes`.

### D3) Failure behavior

- If GraphQL is down or stale:
  - hide multi-row lists/leaderboards and show a retry/error state.
  - do NOT rebuild leaderboards via RPC.
- If the derived pipeline (D1-backed leaderboards) is down or stale:
  - hide `/leaderboards` (all boards) and show an explicit empty/error state.
  - continue to allow the rest of the UI to function (RPC point lookups and non-leaderboard lists) when possible.

---

## E) Release checklist (indexing layer)

- [ ] `deployments/base_mainnet.json` finalized (addresses + startBlock > 0).
- [ ] `subgraph/subgraph.prod.yaml` addresses + startBlock match the manifest exactly.
- [ ] Production deploy flow copies `subgraph/subgraph.prod.yaml` into the active `subgraph/subgraph.yaml` before build/deploy.
- [ ] Upstream production subgraph deployed.
- [ ] `SUBGRAPH_URL` pinned in the GraphQL facade service (and `SUBGRAPH_AUTH_TOKEN` set if needed).
- [ ] `NEXT_PUBLIC_SUBGRAPH_URL` pinned in the application (`https://<origin>/api/subgraph`).

- [ ] D1 schema current for derived leaderboards tables.
- [ ] Derived pipeline deployed + scheduled.
- [ ] Same-origin `/api/subgraph` and `/api/leaderboards/*` routes are deployed.
- [ ] GraphQL facade serves resolver-style leaderboards fields from D1.
- [ ] Public leaderboard endpoints return `asOfTimestamp` + `asOfBlockNumber`.

- [ ] UI freshness indicator implemented for GraphQL (`_meta`) and derived (`asOfTimestamp`).
- [ ] Alerting configured for:
  - subgraph lag
  - derived pipeline lag
  - elevated query error rates
