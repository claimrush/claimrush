# Leaderboards for ClaimRush v1.0.0

This document defines the ONLY official v1.0.0 leaderboards for:
- UI (application)
- Dune and other off-chain analytics

Constraint (required): The official UI MUST match the leaderboard set defined in this document. Do not add, remove, or rename leaderboards in the UI without updating this document (and the Dune templates).

UI presentation spec (subtitles, rules line, 'Your rank', row actions, share):
- This document is the canonical presentation rule set for shipped v1.0.0 leaderboards.

## Backend implementation reference (v1.0.0)

Important:
- The resolver-style leaderboard fields (example: `leaderboardTopKingClaimMined`) are part of the v1 GraphQL contract.
- A standard graph-node subgraph schema does **not** provide these fields out of the box.

v1.0.0 backend surface (REQUIRED):
- Upstream indexing: managed subgraph host serves canonical event/entity data.
- Read facade: the application serves `https://<origin>/api/subgraph` and the facade:
  - proxies standard entity queries to the upstream subgraph
  - serves all leaderboard resolver fields from durable storage (materialized leaderboard tables)
- Rank lookup (required for the UI): public same-origin endpoints are:
  - `GET /api/leaderboards/board?board=<KEY>&duration=<DURATION>&n=...&offset=...`
  - `GET /api/leaderboards/rank?board=<KEY>&duration=<DURATION>&address=<0x...>`
- Internal implementation endpoints remain under `https://<origin>/api/derived/...`, including:
  - `GET /api/derived/leaderboards/board?board=<KEY>&duration=<DURATION>&limit=...&offset=...`
  - `GET /api/derived/leaderboards/rank?board=<KEY>&duration=<DURATION>&address=<0x...>`

Reference:
- Canonical hosting/derived reference: `docs/analytics/indexing-hosting-and-derived-data-reference-v1.0.0.md`
- GraphQL contract (leaderboards section): `docs/analytics/subgraph-schema-v1.0.0.md`

## For Dune builders
- Deployment + start blocks: `deployments/base_mainnet.json`
- Enum/codebook + event list: `docs/analytics/dune-integration-pack-v1.0.0.md`
- Canonical metric meanings + units + rounding: `docs/analytics/metrics-canon-v1.0.0.md`
- Query templates: `analytics/dune/leaderboards/`
- Indexer/Dune implementation notes: `docs/analytics/indexer-and-dune-implementation-guide-v1.0.0.md`

## Common rules
- Sort: descending by metric
- Timeframe:
  - Duration filter (duration-filtered leaderboards only):
    - last 24h
    - last 7d (default)
    - last 30d
    - lifetime
  - Duration semantics (duration-filtered leaderboards):
    - Trailing windows (rolling): relative to query time (not calendar-aligned).
    - Timestamp source: use the block timestamp from the event row (`evt_block_time` on Dune).
    - Filter-before-aggregate: apply the timestamp filter before `GROUP BY` / `ORDER BY` / `LIMIT` / pagination.
  - Current: computed at the latest block (snapshot). Duration does NOT apply.
- UI (low activity hint):
  - If duration = last 24 hours AND returned rows < N (recommended N = 10), show: “Low activity, switch to 7d/30d.”
- Genesis: the 10d genesis accrual + finalization step is not counted as a takeover or reign (no `Takeover`/`ReignFinalized`), so these leaderboards start with the first player takeover.
- Exclusions (do not add):
  - No APY
  - No ROI
  - No net "earned"
  - No concentration or share-of-total metrics
  - No profit projections

## Address labels in the official UI (MUST)

Leaderboards are address-heavy.

UI display rule:
- Basename (Base primary name) if set
- Else ENS (L1 primary name)
- Else short address (never full)

Canonical display rule:
- Use the order above exactly.

## Canonical on-chain sources
Leaderboards are computed off-chain from:
- Contract events (preferred, Dune-friendly)
- Traces / transaction value (fallback only, chain support dependent)
- Read-only views (for per-address UI views and for indexer verification)

Required event sources (see `src/lib/Events.sol` and SPEC §11.2):
- MineCore:
  - `Takeover(reignId, previousKing, newKing, pricePaid, referencePrice, timestamp)`
  - `ReignFinalized(reignId, king, startTime, endTime, totalClaimMined, totalEthToKing)`
- ShareholderRoyalties:
  - `ShareholderClaim(user, mode, amountEth)`
  - `ShareholderAutoCompoundConfigured(user, enabled, tokenId, durationSeconds, minCadenceSeconds, minEthToCompound, maxSlippageBps)` (emitted when a user updates auto-compound config)
  - `ShareholderAutoCompoundPaused(user, tokenId, reasonCode)` (emitted when an attempt finds an invalid destination and pauses config)
  - `ShareholderAutoCompoundExecuted(user, executor, amountEth, tokenId, effectiveDurationSeconds)` (emitted on successful auto-compound; can be used to tag `ShareholderClaim` as auto-compounded)
- Furnace:
  - `FurnaceEnter(user, mode, ethIn, principalClaim, bonusClaim, tokenId)`
- VeClaimNFT:
  - `LockCreated`, `LockExtended`, `LockAmountIncreased`, `LockMerged`, `LockUnlocked`
  - ERC721 `Transfer` events (ownership changes)
- ClaimToken (CLAIM):
  - ERC20 `Transfer` events

### Mode codes (MUST be stable)
These codes are for analytics only. They MUST be treated as stable constants in v1.0.0.

- `ShareholderClaim.mode`
  - `0` = ETH
  - `1` = LOCK_FURNACE

Clarification (UI/analytics):
- `ShareholderClaim` covers both manual claims and keeper-executed auto-compounds.
- To tag a claim as “auto-compounded”, look for `ShareholderAutoCompoundExecuted` in the same transaction.

- `FurnaceEnter.mode`
  - `0` = ENTER_WITH_ETH (`enterWithEth`)
  - `1` = ENTER_WITH_CLAIM (`enterWithClaim`)
  - `2` = LOCK_FURNACE (`lockEthReward`, called by ShareholderRoyalties on behalf of user)
  - `3` = ENTER_WITH_TOKEN (`enterWithToken`)
  - `4` = EXTEND_WITH_BONUS (`extendWithBonus`, bonus-only lock extension)

## Leaderboards index (UI + Dune compatible)

### Crown (Mine Game)

1) Top CLAIM mined as King
- Duration filter: last 7d (default), last 24h, last 30d, lifetime
- Metric: `SUM(totalClaimMined)`
- Attribution: `king` (beneficiary)
- Source:
  - Preferred: `MineCore.ReignFinalized.totalClaimMined`
- Clarification (non-binding):
  - Duration semantics: include a reign iff its `MineCore.ReignFinalized` event occurred within the window (filter by `ReignFinalized.evt_block_time`). Reigns are not prorated.
  - The current King is counted only after their reign is finalized (emitted when dethroned).

2) Longest reign
- Duration filter: last 7d (default), last 24h, last 30d, lifetime
- Metric: `MAX(endTime - startTime)` per user (longest single reign, in seconds)
- Attribution: `king` (beneficiary)
- Source:
  - `MineCore.ReignFinalized.endTime - MineCore.ReignFinalized.startTime`
- Subgraph: `User.longestReignSeconds` (lifetime aggregate, updated on each finalization)

3) Most takeovers executed
- Duration filter: last 7d (default), last 24h, last 30d, lifetime
- Metric: `COUNT(takeover events)`
- Attribution: `newKing` (the takeover executor)
- Source:
  - `MineCore.Takeover`

4) Top ETH spent on takeovers
- Duration filter: last 7d (default), last 24h, last 30d, lifetime
- Metric: `SUM(pricePaid)`
- Attribution: `newKing` (the takeover executor)
- Source:
  - Preferred: `MineCore.Takeover.pricePaid`
  - No tx.value fallback: ETH sent is a max cap and may exceed spend. Use `MineCore.Takeover.pricePaid` only.

### Furnace (includes Barons)

5) Top royalties claimed
- Duration filter: last 7d (default), last 24h, last 30d, lifetime
- Metric: `SUM(amountEth)`
- Attribution: `user` (claimer/beneficiary)
- Source:
  - `ShareholderRoyalties.ShareholderClaim.amountEth`
- Include:
  - Both modes (ETH withdrawals and LOCK_FURNACE reinvests).

6) Top veCLAIM holders (current)
- Metric: `veBalance` per address at the latest block (snapshot)
- Timeframe: current (snapshot only). Duration does NOT apply.
- Attribution: current ve holder address
- Source:
  - Preferred: a ve snapshot table produced by an indexer
  - Alternative: reconstruct from events (if feasible)
- Event reconstruction recipe (indexer):
  - Maintain an "active locks" table keyed by `tokenId` with:
    - current `owner` from ERC721 `Transfer` events
    - `amount` and `lockEnd` from VeClaimNFT lifecycle events
  - Compute per-lock ve at query time:
    - `ve(tokenId) = amount * max(0, lockEnd - now) / MAX_LOCK_DURATION`
  - Aggregate:
    - `veBalance(owner) = SUM(ve(tokenId))` over all tokenIds currently owned
- UI note:
  - For a single address view, the UI can call `VeClaimNFT.veBalanceOf(user)` directly.
  - For a global leaderboard, an indexer is required to enumerate addresses and tokenIds.

7) Top CLAIM sent to Furnace
- Duration filter: last 7d (default), last 24h, last 30d, lifetime
- Metric: `SUM(principalClaim)` for successful Furnace entry calls
- Attribution: `user` (beneficiary)
- Source:
  - Preferred: `Furnace.FurnaceEnter.principalClaim`
- Subgraph: `User.furnacePrincipalClaimInWei` (lifetime aggregate)

8) Top ETH sent to Furnace
- Duration filter: last 7d (default), last 24h, last 30d, lifetime
- Metric: `SUM(ethIn)` for successful Furnace entry calls
- Attribution: `user` (beneficiary)
- Source:
  - Preferred: `Furnace.FurnaceEnter.ethIn`
  - Fallback: traces of successful transactions with `to = Furnace` and `value > 0`
    - Warning: this misattributes `lockEthReward` calls to ShareholderRoyalties if you rely only on traces.
- Include:
  - `enterWithEth` deposits (mode 0)
  - `lockEthReward` deposits (mode 2)

## Implementation templates
- Indexer/Dune hygiene rules: `docs/analytics/indexer-and-dune-implementation-guide-v1.0.0.md`
- Reference SQL templates:
  - Dune: `analytics/dune/leaderboards/*.sql`
  - File numbers `01`–`08` map 1:1 to spec leaderboards #1–#8 in this document.
