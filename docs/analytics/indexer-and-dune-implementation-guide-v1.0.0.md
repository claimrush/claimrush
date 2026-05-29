# Indexer and Dune implementation guide for v1.0.0

This document is an implementation guide for:
- Subgraph leaderboards (multi-row analytics outputs)
- Subgraph-backed UI lists that show addresses (example: “recent reigns”)

This guide is normative for off-chain analytics in v1.0.0.

Supported analytics backends (v1.0.0 in this repo):
- GraphQL read backend (canonical for the official UI):
  - UI pins `NEXT_PUBLIC_SUBGRAPH_URL` (recommended: same-origin `https://<origin>/api/subgraph`).
  - In production, the application serves the public same-origin `/api/subgraph` endpoint.
  - The facade proxies allowlisted entity queries to the upstream subgraph and serves resolver-style leaderboards from durable storage.
- Upstream subgraph (`subgraph/`) (event/entity index; proxied by the facade).
- Dune dashboards (supported via SQL templates in `analytics/dune/`; informational only).

Dashboard policy (v1.0.0):
- This repo ships and maintains SQL templates only.
- This repo does **not** ship or maintain Dune dashboards (dashboard URLs, visualizations, query IDs) as "the backend".

Unsupported analytics backends (v1.0.0 in this repo):
- Replacing the subgraph as the canonical onchain event ingestion pipeline with a bespoke indexer.

Allowed (v1.0.0; REQUIRED for leaderboards):
- A durable-storage-backed derived pipeline that:
  - mirrors the minimal event/lock state needed for leaderboards, and
  - materializes leaderboard snapshots + rows for fast paging and rank lookup.

Why this is required:
- Standard graph-node GraphQL does not expose the resolver-style leaderboard fields used by the v1 UI.
- Rank lookup (“Find my rank”) requires an indexed `(board, duration, address)` read path.

Reference-only (non-v1 optional):
- These templates are not part of the supported v1.0.0 deliverables and may change without guarantees.

Important policy:
- Trust boundary and analytics security requirements: `docs/analytics/subgraph-schema-v1.0.0.md` and `docs/analytics/indexing-hosting-and-derived-data-reference-v1.0.0.md`
- Hosting + derived-data reference (GraphQL endpoint + derived leaderboards pipeline): `docs/analytics/indexing-hosting-and-derived-data-reference-v1.0.0.md`
- **No address exclusions are applied in v1.0.0 leaderboards.**
- Do not “hide” rows client-side. Compute leaderboards in the backend derived pipeline (D1) and serve them via the canonical GraphQL facade plus the public `/api/leaderboards/*` endpoints so UI payloads match the canonical source.

---

## Required integration artifacts (subgraph)

- Deployment manifest (addresses + start blocks): `deployments/base_mainnet.json`
- Subgraph schema contract (GraphQL): `docs/analytics/subgraph-schema-v1.0.0.md`
- Canonical event decoding contract (events + enums + codebook): `docs/analytics/dune-integration-pack-v1.0.0.md`
- Canonical metric meanings + units + rounding: `docs/analytics/metrics-canon-v1.0.0.md`
- ABI JSON (source of truth for decoding): `abis/base_mainnet/*.abi.json`
- Subgraph package (implementation): `subgraph/`
- Dune SQL templates (REQUIRED deliverable): `analytics/dune/` (SQL templates aligned to `docs/analytics/dune-integration-pack-v1.0.0.md`).

---

## Start block policy (REQUIRED)

Source of truth:
- `deployments/base_mainnet.json` is authoritative for contract addresses and start blocks.

Rules:
- Every indexed contract MUST have `startBlock > 0` in the manifest before deploying the Base mainnet subgraph.
- `subgraph/subgraph.prod.yaml` MUST set each data source `address` and `startBlock` exactly to the manifest values.
- The production deploy flow then copies `subgraph/subgraph.prod.yaml` into the active `subgraph/subgraph.yaml` before build and deploy.
- A zero address or `startBlock = 0` is a BLOCKER for subgraph deploy/runtime readiness.

Update rules:
- When any address or startBlock changes in the deployment manifest, update `subgraph/subgraph.prod.yaml` in the same change and redeploy the subgraph.

---

## Token-entry decoding (enterWithToken)

REQUIRED:
- Indexer MUST decode `tokenIn` and `amountIn` from `Furnace.enterWithToken(address tokenIn, uint256 amountIn, ...)` calldata.
- Indexer MUST parse ERC20 `Transfer` logs in the same transaction to recover the observed amount transferred from `user` to `Furnace` for `tokenIn`.
- Indexer MUST populate `FurnaceEnter.tokenIn` and `FurnaceEnter.amountInWei` per `docs/analytics/subgraph-schema-v1.0.0.md`.
- Constraint (required): The official v1.0.0 UI MUST support a token-entry UX for Furnace when allowlisted tokens exist (token selector + `enterWithToken`).

---

## Scope

Required outputs in v1.0.0:
- The 8 official leaderboards in `docs/analytics/leaderboards-ui-and-dune-compatible-v1.0.0.md` (Dune templates implement 9 families with different numbering -- see `analytics/README.md`)
- “Recent reigns” list (UI list of recent reigns; multi-row)

Protocol boundaries:
- No APY / ROI / net-earned long-horizon dashboards (v1).
- Only basic, trailing-24h annualized estimates are in scope:
  - “Estimated APR (24h)” (LP Staking Vault)
  - “Estimated veAPR (24h)” (ve lockers)
- Do not add additional leaderboards beyond those defined in `docs/analytics/leaderboards-ui-and-dune-compatible-v1.0.0.md` (update that document if the official set changes).

---

## Duration filtering (leaderboards)

Duration filter options (duration-filtered leaderboards only):
- last 24h
- last 7d (default)
- last 30d
- lifetime

Semantics (MUST):
- Rolling trailing windows (not calendar-aligned).
- Timestamp source: use the event block timestamp stored by the subgraph (do not use wall-clock time).
- Filter-before-aggregate: apply the timestamp filter before `GROUP BY` / `ORDER BY` / `LIMIT` / pagination.

Leaderboard-specific notes (MUST):
- Top CLAIM mined as King uses finalized-in-window semantics: include a reign iff its `MineCore.ReignFinalized` event occurred within the window (not prorated).
- Top veCLAIM holders is current snapshot only (no duration filter).
- When materializing a leaderboard generation, capture one upstream head (`asOfBlock` / `asOfTimestamp`) and pin both incremental ingest and current-ve lock scans to that same head. Publishing rows computed from a newer head than the advertised `asOf` metadata is incorrect.

UI mitigation (REQUIRED):
- If duration = last 24h AND returned rows < 10, UI MUST show: “Low activity, switch to 7d/30d.”

Rank lookup ("Find my rank") (REQUIRED for /leaderboards UI)

Why:
- Top-N rows alone do not motivate most users; they need to see their own position.
- "Gap to next rank" requires the value of the row above the viewer.

Implementation recommendation:
- Materialize each leaderboard into a table keyed by (board, duration, rank) with:
  - address
  - value (wei or int, depending on the board)
  - asOf block/timestamp metadata
- Serve a rank lookup endpoint that returns the viewer rank even when outside the first page.

Recommended endpoints (example):
- Public rank endpoint: `GET /api/leaderboards/rank?board=<KEY>&duration=<DURATION>&address=<0x...>`
- Optional derived-data endpoint: `GET /api/derived/leaderboards/rank?board=<KEY>&duration=<DURATION>&address=<0x...>`

Minimum response fields (required):
- `rank`
- `value`
- `above` row (rank-1 value) when `rank > 1`
- `asOf` metadata

Notes:
- Rank lookup MUST use the same canonical computation as the main leaderboard list.

---

## Required config parameters

Use the deployment manifest + subgraph config with:
- deployed contract addresses and start blocks in `deployments/base_mainnet.json`
- matching data source `address` + `startBlock` values in `subgraph/subgraph.prod.yaml` (copied into the active `subgraph/subgraph.yaml` during production deploy)

---

## Address labels (Basename/ENS) for UI lists

This applies to UI leaderboards and any multi-row UI lists that show addresses.

UI display rule:
- Basename (Base primary name) if set
- Else ENS (L1 primary name)
- Else short address (never full)

Implementation options:
- Client-side (direct): resolve names in the UI with caching.
- Server-side (recommended for leaderboards): resolve names in the backend and return `displayName` per row.

If you do server-side resolution:
- Cache `address -> displayName` (TTL 1h to 24h)
- Concurrency limit RPC calls (5 to 10 in parallel)

Required RPCs:
- Base RPC (gameplay)
- Ethereum mainnet RPC (ENS primary name resolution)

Reference:
- `docs/analytics/leaderboards-ui-and-dune-compatible-v1.0.0.md`

---

## UI token discovery (EntryTokenRegistry mirror) — not part of this contract

This endpoint is not implemented in v1.0.0 in this repo. The UI reads `EntryTokenRegistry` state via onchain RPC.

The remainder of this section is reference material for non-v1 deployments.

Purpose:
- Let the UI auto-adapt to multi-token entry without hardcoding tokens.
- Keep FE minimal and deterministic while the on-chain source of truth remains `EntryTokenRegistry`.

Design:
- Backend mirrors the on-chain `EntryTokenRegistry` into a small read-only endpoint.
- UI uses this endpoint to decide whether to show a token selector and which tokens are selectable.
- ETH remains the canonical/native option and is always available.

Constraint (required; v1.0.0 deployment pattern):
- Furnace and MineCore MUST point to different EntryTokenRegistry instances (required for policy split).
- The endpoint MUST specify which registry it mirrors (Furnace entry vs takeover entry).
- Discover the active registry addresses by decoding:
  - `Furnace.EntryTokenRegistrySet(registry)`
  - `MineCore.EntryTokenRegistrySet(registry)`

Endpoint (recommended shape):
- `GET /entry-tokens?surface=furnace`
- `GET /entry-tokens?surface=takeover`

Where:
- `surface=furnace` mirrors the registry wired into **Furnace**.
- `surface=takeover` mirrors the registry wired into **MineCore**.

Response (example):
```json
{
  "chainId": 8453,
  "surface": "furnace",
  "native": { "symbol": "ETH", "decimals": 18 },
  "tokens": [
    {
      "address": "0x…",
      "symbol": "USDC",
      "decimals": 6,
      "enabled": true
    }
  ],
  "source": { "registry": "0x…", "block": 12345678 }
}
```

Constraints (required):
- This endpoint mirrors **registry-managed** ERC20 tokens only.
- It MUST NOT include `CLAIM` or `WETH`:
  - EntryTokenRegistry forbids configuring `tokenIn == claimToken` and `tokenIn == wrappedNative`.

Clarification:
- Furnace still supports `enterWithClaim(...)` even if `tokens` is empty; UIs may expose CLAIM entry as a separate mode.
- Note: `wrappedNative` (WETH) is an implicit option handled in core contracts (not registry-managed). It will not appear in this endpoint’s `tokens` list, but UIs may still show it when the user holds WETH.

Rules (MUST):
- `tokens` MUST include only allowlisted ERC20 entry tokens that are currently enabled in the registry for the requested `surface`.
- ETH MUST NOT be represented as an ERC20 in `tokens`; it is provided via `native`.

UI behavior (MUST):
- `surface=takeover`:
  - UI MUST default to ETH takeover (`takeover(maxPrice)`), even when token payment is available.
  - If `tokens.length == 0` → no registry-token selector (ETH takeover UI; MAY still show WETH as a convenience option when the user holds WETH).
  - If `tokens.length > 0` → show token selector, default ETH.
- `surface=furnace`:
  - UI MUST default to CLAIM entry when the user has `CLAIM` balance > 0; otherwise default to ETH entry.
  - If `tokens.length == 0` → no registry-token selector (but ETH + CLAIM entry modes can still be shown; MAY also show WETH as a convenience option when the user holds WETH).
  - If `tokens.length > 0` → show token selector for ERC20 tokens, default ETH.
- Changing the selected token updates all displayed quotes/prices to that token.

---

## Genesis LP vault analytics (GenesisLPVault24M)

If you expose a UI panel for the genesis LP lock, index these vault fields and events:

Recommended on-chain fields:
- `lockStartTime`
- `unlockTime`
- `lpLockedAmount`

Recommended events:
- `Locked(lpAmount, lockStartTime, unlockTime)`
- `LockExtended(oldUnlockTime, newUnlockTime)`
- `WithdrawLp(to, amount)`
- `ResidualLpSwept(to, amount)` — emitted from the residual-LP branch of `withdrawLp()` when the vault has been fully drained but more LP has been deposited afterwards.
- `FeesClaimedAndForwarded(token0, token1, amount0Forwarded, amount1Forwarded)` — emitted from inside `withdrawLp()` when the vault claims accumulated Aerodrome trading fees from `pool.claimFees()` and forwards both fee tokens to `lpWithdrawRecipient`. Fires only when at least one forwarded amount is non-zero, and always precedes the paired `WithdrawLp` / `ResidualLpSwept` in the same transaction. `token0` and `token1` are pool-defined and Aerodrome-immutable (`token0 < token1` by address).

---

## Query hygiene rules (MUST)

### 1) Apply filters before ranking, ordering, limiting, and pagination

General rule:
- Any filter that changes which rows “exist” MUST be applied in the base dataset CTE, before `ORDER BY`, ranking, `LIMIT`, and pagination.

Examples:
- Filtering out zero-activity rows.
- Filtering to a chain, deployment start block, or “successful-only” rows.

Why:
- Filtering after ranking/limit can change rankings and can return fewer than N rows.

### 2) Canonical source for leaderboards

Leaderboards MUST be computed from:
- Contract events defined in `docs/analytics/dune-integration-pack-v1.0.0.md`.

Unsupported leaderboard sources in v1.0.0:
- Traces / transaction value.
- Contract views (including “RPC spot reads”).

### 3) Pagination happens after aggregation

If you paginate:
- Aggregate first (`GROUP BY`), then order and paginate.
- Never paginate raw event rows and then aggregate; that creates inconsistent totals per page.

---

## Testing checklist (REQUIRED)

- Each leaderboard query returns exactly N rows when N eligible addresses exist.
- Results are stable under pagination (no duplicates or missing rows across pages).
- “Recent reigns” list uses `ReignFinalized` and is ordered by `endTime` descending.
