# Subgraph schema for ClaimRush v1.0.0

This document defines the **GraphQL data contract** required for ClaimRush v1.0.0 (Base mainnet).

Canonical supported analytics path for the official UI (v1.0.0 in this repo):
- The Graph subgraph that serves this schema.

Supported analytics backend (informational dashboards; optional):
- Dune dashboards, built from the SQL templates shipped in `analytics/dune/`.

Dashboard policy (v1.0.0):
- This repo ships and maintains SQL templates only.
- This repo does **not** ship or maintain Dune dashboards (dashboard URLs, visualizations, query IDs) as "the backend".

Unsupported analytics paths (v1.0.0 in this repo):
- Using Dune dashboards as the production backend for the official UI or leaderboards (the UI MUST NOT query Dune).
- Replacing the subgraph as the canonical onchain event ingestion pipeline with a bespoke indexer.

Supported derived-data path (v1.0.0):
- A small auxiliary derived-data job that reads from the subgraph and materializes sortable views that are not safely computable inside subgraph queries (example: “Top veCLAIM holders (current)”).

Hard rule (UI):
- The official UI MUST NOT query Base RPC to power lists and leaderboards.
- Lists and leaderboards MUST be served by this GraphQL contract.
- Clarification (non-binding): The GraphQL contract can be implemented as the deployed subgraph endpoint or as an approved backend facade backed by indexed or derived data.

References:
- UI-facing leaderboard rules: `docs/analytics/leaderboards-ui-and-dune-compatible-v1.0.0.md`
- Leaderboards: `docs/analytics/leaderboards-ui-and-dune-compatible-v1.0.0.md`
- Event list + enums: `docs/analytics/dune-integration-pack-v1.0.0.md`
- Indexing hosting + derived-data reference: `docs/analytics/indexing-hosting-and-derived-data-reference-v1.0.0.md`
- Deployment addresses + start blocks: `deployments/base_mainnet.json`

---

## A) Indexing freshness (required)

The UI MUST be able to detect whether indexing is behind.

Required query:
```graphql
query Meta {
  _meta {
    block {
      number
      timestamp
    }
  }
}
```

UI rule (MUST):
- If `now - _meta.block.timestamp > 180 seconds`, show: “Indexing is catching up. Some stats may be delayed.”

---

## B) Canonical IDs (required)

Use deterministic IDs so pagination and joins are stable.

- `Address` IDs: lowercase hex string (example: `"0xabc..."`)
- `Reign` ID: decimal string of `reignId` (example: `"42"`)
- `VeLock` ID: decimal string of `tokenId`
- `TxEvent` ID: `{txHash}-{logIndex}` (example: `"0x1234...-17"`)
- `BonusTargetEscrow` ID: decimal string of `escrowId`

---

## C) Required GraphQL types

This section defines the **minimum** objects required to power `/`, `/crown`, `/crown/reign/[reignId]`, `/locks`, `/furnace` (includes the Market section), `/leaderboards`, `/overview`, `/security`, `/activity`, `/activity/[id]`, `/claim`, `/lp-vault`, `/u/[address]`.

Notation:
- Fields marked **Computed** may be implemented as:
  - A GraphQL resolver (custom backend), or
  - A stored field updated by the indexer
- If a field is computed, it MUST be computed using `_meta.block.timestamp` as “now” (not wall-clock), so results are self-consistent.

### C1) Protocol singleton

```graphql
type Protocol {
  id: ID!                    # always "1"
  chainId: Int!
  version: String!           # "v1.0.0"
  deployedAtBlock: BigInt!

  # Core addresses (from deployments manifest and canonical wiring events)
  claimToken: Bytes!
  veClaimNft: Bytes!
  mineCore: Bytes!
  shareholderRoyalties: Bytes!
  furnace: Bytes!
  marketRouter: Bytes!

  # EntryTokenRegistry wiring (discover from EntryTokenRegistrySet events)
  furnaceEntryTokenRegistry: Bytes
  mineCoreEntryTokenRegistry: Bytes

  # Back-compat alias (required). MUST equal furnaceEntryTokenRegistry.
  entryTokenRegistry: Bytes
  dexAdapter: Bytes
  lpStakingVault: Bytes
  launchController: Bytes
  genesisLpVault24m: Bytes
  maintenanceHub: Bytes

  # Optional wiring / infra
  furnaceQuoter: Bytes

  # Latest known flags (from events)
  takeoversPaused: Boolean!
  lockingPaused: Boolean!
  tradingPaused: Boolean!
}
```

Constraints (required; EntryTokenRegistry wiring):
- Indexers MUST populate `furnaceEntryTokenRegistry` from `Furnace.EntryTokenRegistrySet(registry)`.
- Indexers MUST populate `mineCoreEntryTokenRegistry` from `MineCore.EntryTokenRegistrySet(registry)`.
- `furnaceEntryTokenRegistry` and `mineCoreEntryTokenRegistry` MUST be treated as independent addresses (do not assume they are equal).

Clarifications:
- `mineCore`, `marketRouter`, `furnace`, and `shareholderRoyalties` are the latest observed current addresses within the indexed event surface, not write-once deployment seeds.
- Canonical rewiring receipts that update those fields include `MineCore.FurnaceChanged`, `VeClaimNFT.FurnaceChanged`, `VeClaimNFT.MineMarketChanged`, `Furnace.MineCoreChanged`, `Furnace.MineMarketChanged`, `Furnace.ShareholderRoyaltiesChanged`, and `ShareholderRoyalties.ShareholderWiringSet`.
- `shareholderRoyalties` MAY be discovered from `ShareholderRoyalties.ShareholderWiringSet(mineCore, mineMarket, furnace)` before any Baron claim/flush/allocation activity occurs.
- `dexAdapter` is optional/informational. The current v1.0.0 indexed event surface does not emit it directly, so pure event-driven subgraphs MAY leave it null unless an approved enrichment path is added.



### C1b) Info surfaces (pricing) (required)

These singletons power the read-only price info surfaces used across:
- `/claim` (price + FDV)

IDs:
- `TokenPricingSnapshot.id` MUST always be `"1"`.
- `AprSnapshot.id` MUST always be `"1"`.

```graphql
# Clarification: `BigDecimal` is the standard decimal scalar in The Graph.
# If your GraphQL server does not support `BigDecimal`, you may use `String` here
# as long as the returned values are parseable as base-10 decimals by the consuming client.

type TokenPricingSnapshot {
  id: ID!                 # always "1"

  # When this snapshot was last successfully updated by the indexing layer.
  # Unix seconds.
  updatedAt: BigInt

  # ETH per 1 CLAIM (30m TWAP) for the canonical CLAIM/WETH pool.
  claimEthTwap30m: BigDecimal

  # USD per 1 ETH from Chainlink (normalized to 1e0, not 1e8).
  ethUsd: BigDecimal

  # Chainlink feed updatedAt (unix seconds from latestRoundData()).
  ethUsdUpdatedAt: BigInt

  # CLAIM total supply (wei).
  totalSupplyWei: BigInt
}

type AprSnapshot {
  id: ID!                 # always "1"

  # When this snapshot was last successfully updated by the indexing layer.
  # Unix seconds.
  updatedAt: BigInt

  # Trailing 24h annualized LP APR in basis points.
  lpAprBps24h: BigInt

  # Average LP TVL over the same 24h window, in USD.
  lpAvgTvl24hUsd: BigDecimal

  # Trailing 24h annualized veAPR in basis points.
  veAprBps24h: BigInt
}
```

Semantics (MUST):
- `claimEthTwap30m` uses the canonical CLAIM/WETH pool pinned in the deployment manifest.
- `ethUsd` and `ethUsdUpdatedAt` use the pinned Chainlink ETH/USD feed on Base.
  - If `chainlink.ethUsdFeed.address` is zero in the active deployment manifest, both fields MUST be null.
  - If `ethUsdUpdatedAt` is older than `MAX_ETH_USD_FEED_AGE_SECONDS` (see `src/lib/Constants.sol`), both fields MUST be treated as unsafe and set to null.
- `totalSupplyWei` is `ClaimToken.totalSupply()`.

Nullability (MUST):
- Any field may be null early in indexing or during degraded mode.
- The UI MUST treat null as “unavailable” and hide the affected price surfaces accordingly.

### C2) Users and aggregated stats

This object is the primary building block for:
- `/leaderboards`
- user panels in `/crown`, `/locks`, `/furnace` (including the Market section)

```graphql
type User {
  id: ID!                    # address lowercase
  address: Bytes!

  # Display labels (cached; nullable)
  basename: String
  ens: String
  displayName: String        # basename else ens else short address

  # Aggregates for official leaderboards (lifetime)
  takeoverCount: Int!
  ethSpentOnTakeoversWei: BigInt!
  kingClaimMinedWei: BigInt!
  longestReignSeconds: Int!

  shareholderEthClaimedWei: BigInt!     # includes ETH + LOCK_FURNACE modes
  furnaceEthInWei: BigInt!              # sum FurnaceEnter.ethIn
  furnacePrincipalClaimInWei: BigInt!   # sum FurnaceEnter.principalClaim

  # Current ve state (see note below)
  veBalanceWei: BigInt                  # Event-driven snapshot at last lock activity; does not decay between unrelated events
  totalLockedClaimWei: BigInt           # Event-driven aggregate principal
}
```

Clarification (non-binding): `veBalanceWei` and `totalLockedClaimWei`
- In a pure event-driven store, `totalLockedClaimWei` stays current from lock lifecycle events.
- In the shipped ClaimRush subgraph, `veBalanceWei` is the latest event-driven snapshot at lock activity time. It does **not** continuously decay between unrelated events.
A wall-clock fallback is only approximate and should be reserved for offline cases.
- The same rule applies to Crown decay consumers that derive takeover price, cost tier, or urgency zone from subgraph rows. They MUST use the same payload's `_meta.block.timestamp` as “now”, including SSR/prefetched variants, rather than `Date.now()`.
- “Top veCLAIM holders (current)” therefore uses the backend-computed leaderboard endpoint described below rather than a naive sort on stale snapshot fields.

#### REQUIRED: ve snapshot/leaderboard indexer job (v1 UI)

Because ve decays continuously and GraphQL sorts are field-based, you cannot safely compute “top ve now” purely inside a subgraph query. Any downstream API that computes time-windowed aggregates (for example 7d royalties) must also pin its window to one captured `_meta` head and page through the full event set instead of relying on a single hard-capped query.

The GraphQL facade/backend MUST implement a small indexer job that:
- Ingests lock state (from the subgraph or RPC) for all addresses with active locks.
- Computes `veBalanceCurrentWei` at a single consistent `asOfTimestamp` (and records `asOfBlockNumber`).
- Stores results in a durable store (D1/Postgres/etc) for fast sorting.
- Serves `leaderboardTopBaronsByVeCurrent(limit, offset)` from this store.

Recommended implementation details:
- Persist each lock with `owner`, `amountWei`, `lockEnd`, and `autoMax`.
- Capture the upstream subgraph `_meta { block { number timestamp } }` once at the start of the run and treat it as the authoritative snapshot head for that generation.
- Bound every incremental ingest query to that same head (`blockNumber_lte: asOfBlockNumber` or `timestamp_lte: asOfTimestamp`, depending on the entity shape) so the mirrored event set cannot run ahead of the published snapshot metadata.
- When scanning lock rows for `Top veCLAIM holders (current)`, pin the query itself to `block: { number: asOfBlockNumber }` so the lock state and the reported `asOf` metadata come from the same head.
- Compute `veBalanceCurrentWei` using the v1 spec’s linear decay rule, with AutoMax semantics:

  - Define an **effective end**:

    `effectiveLockEnd = autoMax ? (asOfTimestamp + MAX_LOCK_DURATION) : lockEnd`

  - Then compute:

    `ve = amountWei * max(0, effectiveLockEnd - asOfTimestamp) / MAX_LOCK_DURATION`

  (This simplifies to `ve = amountWei` when `autoMax == true`.)

- Recompute on a cadence (example: every 5–15 minutes) and also on-demand after large lock events.
- Include `asOfTimestamp` and `asOfBlockNumber` in the API response so the UI can label freshness.
- If `_meta` is unavailable, skip snapshot materialization instead of emitting a mixed-head leaderboard generation with placeholder `asOf` metadata.


### C2b) Delegation sessions (bots) (required for `/security` + Radar alerts)

These entities make bot sessions **observable and traceable** (approvals-like UX):

- Show the delegate address, expiry, and permission mask.
- Show **last used** timestamp + last action type + last tx hash.
- Show an immutable **session activity feed** (uses) with tx hashes.
- Show an immutable **session changes feed** (grants/updates/revokes) with tx hashes.
- Power per-permission warnings (example: “This permission can redirect your mined CLAIM.”).

Minimum required entities:

```graphql
enum DelegationActionType {
  UNKNOWN
  TAKEOVER
  REIGN_RECIPIENTS
  CLAIM
  FURNACE_ENTER
  VE_LOCK
  CONFIG
}
```

Note (current shipped behavior): this coarse enum is range-based. Raw `DelegationSessionUse.actionTypeId` remains canonical. `actionTypeId = 2` (`MINECORE_SET_REIGN_RECIPIENTS`) maps to `REIGN_RECIPIENTS`.

```graphql
type DelegationSession {
  id: ID! # "{user}-{delegate}"
  user: User!
  delegate: User!

  perms: BigInt!
  expiry: BigInt!

  createdAt: BigInt!
  updatedAt: BigInt!
  revokedAt: BigInt

  lastUsedAt: BigInt
  lastActionType: DelegationActionType
  lastTxHash: Bytes

  uses: [DelegationSessionUse!]! @derivedFrom(field: "session")
}

type DelegationSessionUse {
  id: ID! # txHash-logIndex
  session: DelegationSession!
  user: User!
  delegate: User!

  actionType: DelegationActionType!
  actionTypeId: Int!     # canonical ids: `src/lib/DelegationActionTypes.sol`
  permsUsed: BigInt!
  refId: BigInt!

  timestamp: BigInt!
  blockNumber: BigInt!
  txHash: Bytes!
  emitter: Bytes!
}

type DelegationSessionSetEvent {
  id: ID! # txHash-logIndex
  session: DelegationSession!
  user: User!
  delegate: User!

  perms: BigInt!
  expiry: BigInt!
  isRevocation: Boolean!

  timestamp: BigInt!
  blockNumber: BigInt!
  txHash: Bytes!
}
```

Indexing rules (required):
- Session state MUST be sourced from `DelegationHub.SessionSet(user, delegate, perms, expiry)` events.
- Session uses MUST be sourced from `Events.DelegationSessionUsed(...)` events emitted by all current protocol emitters: MineCore, Furnace, ClaimAllHelper, VeClaimNFT, ShareholderRoyalties, and LpStakingVault7D.
- `DelegationSessionUse.actionTypeId` is canonical. The shipped coarse mapper in `subgraph/src/utils/delegation.ts` maps ids `1`, `2`, `10-13`, `20-22`, `30-32`, and `40-42`; raw id `2` (`MINECORE_SET_REIGN_RECIPIENTS`) maps to `actionType = REIGN_RECIPIENTS`.
- Persist the raw `actionTypeId` exactly as emitted by contracts (`src/lib/DelegationActionTypes.sol`).
- Current shipped nuance: the coarse `DelegationActionType` enum is range-based in `subgraph/src/utils/delegation.ts`. Raw `actionTypeId = 2` (`MINECORE_SET_REIGN_RECIPIENTS`) maps to `REIGN_RECIPIENTS`; consumers that need exact semantics MUST key off `actionTypeId`.
- `DelegationSession.lastUsedAt/lastActionType/lastTxHash` MUST be updated whenever a use is observed.
- Revocation semantics:
  - `perms = 0` and `expiry = 0` represent “revoked”.
  - `revokedAt` SHOULD be set to the revoke timestamp (nullable while active).
- Active session rule (UI; required):
  - session is active iff `perms > 0` AND `expiry >= _meta.block.timestamp`.
  - `expiry = 0` is immediately expired, not active.



### C3) Reigns and takeovers

```graphql
type Reign {
  id: ID!                    # reignId as string
  reignId: BigInt!
  king: User!
  startTime: BigInt!
  endTime: BigInt            # null if ongoing (nullable)
  totalClaimMinedWei: BigInt # set at finalization only
  totalEthToKingWei: BigInt  # set at finalization only

  # Convenience links
  startedByTakeover: Takeover!
  finalizedBy: ReignFinalizedEvent

  # For `/crown` timeline
  previousReign: Reign
}

type Takeover {
  id: ID!                    # txHash-logIndex
  reign: Reign!
  previousKing: User
  newKing: User!
  pricePaidWei: BigInt!
  referencePriceWei: BigInt!
  timestamp: BigInt!
  blockNumber: BigInt!
  txHash: Bytes!
}

type ReignFinalizedEvent {
  id: ID!                    # txHash-logIndex
  reign: Reign!
  king: User!
  startTime: BigInt!
  endTime: BigInt!
  totalClaimMinedWei: BigInt!
  totalEthToKingWei: BigInt!
  timestamp: BigInt!
  blockNumber: BigInt!
  txHash: Bytes!
}
```

### C3b) Reign recipients routing (security / review) (required)

MineCore supports per-reign recipient routing for:
- the dethroned king’s **75% ETH share**, and
- King-stream **mined CLAIM**.

Recipients are set when a reign starts and can be updated mid-reign (by the king, or by an authorized delegate session).

Minimum required entities:

```graphql
type ReignRecipientsState {
  id: ID! # reignId as string
  reignId: BigInt!
  king: User!
  ethRecipient: Bytes!
  claimRecipient: Bytes!

  updateCount: Int!

  createdAt: BigInt!
  updatedAt: BigInt!

  firstSetTxHash: Bytes
  firstSetTimestamp: BigInt
  lastSetTxHash: Bytes
  lastSetTimestamp: BigInt
}

type ReignRecipientsSetEvent {
  id: ID! # txHash-logIndex
  reignId: BigInt!
  king: User!
  ethRecipient: Bytes!
  claimRecipient: Bytes!
  isMidReignUpdate: Boolean!
  timestamp: BigInt!
  blockNumber: BigInt!
  txHash: Bytes!
}
```

Indexing rules (required):
- Source event: `MineCore.ReignRecipientsSet(reignId, king, ethRecipient, claimRecipient)`.
- `ReignRecipientsState.updateCount` MUST increment once per event.
- `ReignRecipientsSetEvent.isMidReignUpdate` MUST be `true` iff `updateCount > 1` for that reign (used for “Recipients changed mid-reign” alerts).

### C3c) King CLAIM settlement events (required)

On dethrone, a King's mined CLAIM is split: a liquid slice is minted directly to the
recipient and the remainder is force-locked into veCLAIM. MineCore emits
`KingClaimLiquidPaid` for the liquid slice, and `KingAutoLockConfigured`,
`KingAutoLockExecuted`, `KingAutoLockSkipped`, and `KingAutoLockFailed` for the
keeper-driven lock automation of the remainder.

These events do **not** have dedicated `*Event` entity types in v1.0.0. They are normalized into `ActivityItem` entities with `kind` values:
- `KING_AUTOLOCK_CONFIGURED`
- `KING_AUTOLOCK_EXECUTED`
- `KING_AUTOLOCK_SKIPPED`
- `KING_AUTOLOCK_FAILED`
- `KING_CLAIM_LIQUID_PAID`

For `KING_CLAIM_LIQUID_PAID`, `ActivityItem.amountClaimWei` is the liquid CLAIM paid and
`ActivityItem.bps` is the applied liquid fraction (basis points). The same values are
mirrored onto the dethroned `Reign` as `liquidClaimPaidWei` and `liquidBpsApplied`
(null until settlement, and when the liquid slice is zero). Note that
`KingAutoLockExecuted.principalClaim` (and the `Skipped`/`Failed` analogues) carry the
**locked** slice only, not total mined CLAIM — `ReignFinalized.totalClaimMined` remains
the authoritative reign total.

Consumers querying auto-lock status should filter `ActivityItem.kind` rather than looking for a standalone event entity. The full config payload (duration, minVeOut, etc.) is not stored as a dedicated entity in v1.0.0.

### C4) veCLAIM locks (ERC721)

```graphql
type VeLock {
  id: ID!                    # tokenId as string
  tokenId: BigInt!
  owner: User!

  amountWei: BigInt!
  lockEnd: BigInt!
  autoMax: Boolean!
  listed: Boolean!

  createdAt: BigInt!
  updatedAt: BigInt!

  # Convenience
  currentVeWei: BigInt        # Event-driven per-lock snapshot at last lock activity; live consumers MUST recompute from amountWei + lockEnd (+ autoMax)
}
```

Minimum sources:
- VeClaimNFT lifecycle events: `LockCreated`, `LockExtended`, `LockAmountIncreased`, `LockMerged`, `LockUnlocked`, `AutoMaxSet`
- ERC721 `Transfer` events to maintain `owner`

### C5) Shareholder (Barons) flows

```graphql
type ShareholderAllocation {
  id: ID!                    # txHash-logIndex
  reign: Reign!
  amountEthWei: BigInt!
  timestamp: BigInt!
  txHash: Bytes!
}

type ShareholderClaimEvent {
  id: ID!
  user: User!
  mode: Int!                 # 0 ETH, 1 LOCK_FURNACE
  amountEthWei: BigInt!
  timestamp: BigInt!
  txHash: Bytes!
}

type ShareholderFlushEvent {
  id: ID!
  amountEthWei: BigInt!
  deltaEthPerVeWei: BigInt!
  timestamp: BigInt!
  txHash: Bytes!
}

# Required (Barons auto-compound; SPEC §6.7)

type ShareholderAutoCompoundConfiguredEvent {
  id: ID!
  user: User!
  enabled: Boolean!
  tokenId: BigInt!
  durationSeconds: BigInt!
  minCadenceSeconds: BigInt!
  minEthToCompoundWei: BigInt!
  maxSlippageBps: BigInt!
  timestamp: BigInt!
  txHash: Bytes!
}

type ShareholderAutoCompoundPausedEvent {
  id: ID!
  user: User!
  tokenId: BigInt!
  reasonCode: Int!
  timestamp: BigInt!
  txHash: Bytes!
}

type ShareholderAutoCompoundExecutedEvent {
  id: ID!
  user: User!
  executor: User!
  amountEthWei: BigInt!
  tokenId: BigInt!
  effectiveDurationSeconds: BigInt!
  timestamp: BigInt!
  txHash: Bytes!
}
```

### C6) Furnace events

```graphql
type FurnaceEnterEvent {
  id: ID!                    # txHash-logIndex
  user: User!
  mode: Int!                 # 0 ETH, 1 CLAIM, 2 LOCK_FURNACE, 3 TOKEN, 4 EXTEND_WITH_BONUS
  ethInWei: BigInt!
  principalClaimWei: BigInt!
  bonusClaimWei: BigInt!
  tokenId: BigInt!

  # Token entry (mode=3): populated by calldata + ERC20 Transfer decoding
  tokenIn: Bytes
  amountInWei: BigInt

  timestamp: BigInt!
  txHash: Bytes!
}
```

Token-entry decoding constraints (required):
- Token entry decoding is IN SCOPE in v1.0.0.
- `tokenIn` and `amountInWei` MUST be non-null for `FurnaceEnter.mode = ENTER_WITH_TOKEN` (3) and MUST be null for all other modes (0, 1, 2, 4).
- Indexer MUST decode `tokenIn` and `amountIn` from the `Furnace.enterWithToken(address tokenIn, uint256 amountIn, ...)` call input.
- Indexer MUST parse ERC20 `Transfer` logs in the same transaction and compute `amountInObservedWei` as the sum of transfers where:
  - `evt.address == tokenIn`
  - `from == FurnaceEnter.user`
  - `to == Furnace`
- Canonical value selection:
  - if `amountInObservedWei > 0`, set `amountInWei = amountInObservedWei`
  - else set `amountInWei = amountIn` from calldata
- UI requirement:
  - v1.0.0 UI MUST support a token-entry UX for Furnace (`enterWithToken`) when allowlisted tokens exist; indexers MUST populate `tokenIn` and `amountInWei`.

AutoMax bonus extension (mode 4):
- Mode 4 (`EXTEND_WITH_BONUS`) entries are emitted by keeper calls that auto-extend ve locks with accrued bonus.
- A separate event is also emitted for activity-feed tracking:

```graphql
type AutoMaxBonusClaimedEvent {
  id: ID!                    # txHash-logIndex
  timestamp: BigInt!
  blockNumber: BigInt!
  txHash: Bytes!
  user: User!
  tokenId: BigInt!
  bonusClaimWei: BigInt!
}
```

Merge-with-bonus receipts:

```graphql
type FurnaceMergeWithBonusEvent {
  id: ID!                    # txHash-logIndex
  timestamp: BigInt!
  blockNumber: BigInt!
  txHash: Bytes!
  user: User!
  fromTokenId: BigInt!
  intoTokenId: BigInt!
  fromAmount: BigInt!
  intoAmount: BigInt!
  newPrincipal: BigInt!
  newEnd: BigInt!
  newAutoMax: Boolean!
  durationDelta: BigInt!
  bonusClaimWei: BigInt!
}
```

Bonus rollup rule:
- `BonusPaidEvent.userBonusClaim` is the raw AMM user split before sub-`MIN_TOPUP_AMOUNT` dust can be refunded to reserve.
- `DailyFurnaceAgg.totalUserBonus` MUST sum actual delivered receipt bonuses from `FurnaceEnterEvent.bonusClaimWei`, `FurnaceMergeWithBonusEvent.bonusClaimWei`, and `AutoMaxBonusClaimedEvent.bonusClaimWei`.
- `DailyFurnaceAgg.totalGrossBonus`, `totalLpTopup`, and `totalLpFromFurnace` are sourced from `BonusPaidEvent`, because those fields describe AMM gross spend and LP funding.

### C6a) Furnace sellback events (optional)

If the protocol supports selling a veCLAIM lock back to the Furnace (instant liquidity), indexers SHOULD capture it for:
- Activity feeds
- LP funding analytics (sellbacks can route a share of the cut to LP stakers)

```graphql
type LockSoldToFurnaceEvent {
  id: ID!                     # txHash-logIndex
  timestamp: BigInt!
  blockNumber: BigInt!
  txHash: Bytes!

  seller: User!
  tokenId: BigInt!
  lockAmountWei: BigInt!
  claimOutWei: BigInt!
  spreadBps: Int!
  cutWei: BigInt!
  lpSaleShareBps: Int!
  lpRewardWei: BigInt!
  reserveAddWei: BigInt!
  bonusRefBpsUsed: Int!
}
```

Required indexing rules:
- `seller` MUST reference a `User` entity keyed by the seller address.
- `tokenId` MUST be the veCLAIM NFT tokenId sold.
- Amount fields are raw token wei units from the event.

Activity feed normalization (recommended):
- Create an `ActivityItem` with:
  - `kind = "FURNACE_SELLBACK"`
  - `user = seller`
  - `tokenId = tokenId`
  - `amountClaimWei = claimOutWei`

### C6b) Furnace bonus snapshot and history series (required for Furnace card)

Furnace bonus hunting requires:
- A current bonus tier (Low/Mid/High)
- Min/max bonus range over 24h, 7d, and 30d windows
- A last 7d history chart (to make timing learnable)

Important:
- `quoteUserBonusBps` is a **view-derived quote** (not emitted in events).
- The indexer/subgraph MUST periodically sample the Furnace view and store these values.
- Public 7d / 24h Furnace surfaces that still scan raw `FurnaceEnterEvent` rows (for example bonus-payout totals or entry-count windows) MUST capture `_meta` first, pin the scan to that block, and page with a stable cursor (`id_gt` or equivalent). `skip` pagination on a moving head is not acceptable for shipped public metrics.

Minimum required entities:

```graphql
type FurnaceBonusSnapshot {
  id: ID!                    # always "1"
  updatedAt: BigInt!          # timestamp of the latest sample included

  # Rolling 24h context (used for tiers)
  currentBps: Int!
  min24hBps: Int!
  max24hBps: Int!
  min7dBps: Int!
  max7dBps: Int!
  min30dBps: Int!
  max30dBps: Int!
  q33Bps: Int!
  q66Bps: Int!
  q95Bps: Int                 # optional
}

type FurnaceBonusSample {
  id: ID!                     # "{bucketSeconds}-{bucketStart}" (example: "3600-1735065600")
  bucketStart: BigInt!        # unix seconds (aligned to bucketSeconds)
  bucketSeconds: Int!         # 300 for 5m samples, 3600 for 1h rollups
  quoteUserBonusBps: Int!
}
```

Sampling rules (required):
- Sample cadence for tiering: every 5 minutes (`bucketSeconds = 300`).
- Rollup cadence for the 7d bonus history chart: 1 hour (`bucketSeconds = 3600`).
- Retention: keep at least 7 days of hourly points (168 rows) and at least 24 hours of 5m points (288 rows).
- Snapshot computation (24h): compute `min24h/max24h/q33/q66` over the trailing 24h 5m sample window.
- Snapshot computation (7d/30d): compute `min7d/max7d/min30d/max30d` from `DailyFurnaceAgg.quoteBonusMinBps/quoteBonusMaxBps` over 7 and 30 calendar days respectively (see below).

Daily bonus tracking (required for 7d/30d ranges):

```graphql
type DailyFurnaceAgg {
  id: ID!                    # dayId (timestamp / 86400)
  dayStartTimestamp: BigInt!
  bonusPaidCount: Int!
  dripCount: Int!
  totalGrossBonus: BigInt!
  totalUserBonus: BigInt!
  totalLpTopup: BigInt!
  totalLpDrip: BigInt!
  totalLpFromFurnace: BigInt!
  sellCount: Int!
  totalSellLockAmount: BigInt!
  totalSellClaimOut: BigInt!
  totalSellLpReward: BigInt!
  totalSellReserveAdd: BigInt!
  reserveEnd: BigInt!
  quoteBonusMinBps: Int!
  quoteBonusMaxBps: Int!
}
```

- `DailyFurnaceAgg` MUST include `quoteBonusMinBps` and `quoteBonusMaxBps` fields, updated by the Furnace block handler every block on staging/prod with the running min/max of `quoteUserBonusBps` for that calendar day.
- The local/default manifests (`subgraph/subgraph.local.yaml` and `subgraph/subgraph.yaml` when pointed at `deployments/local.json`) intentionally omit the Furnace block handler for local graph-node workflows; on local, these ranges only advance on Furnace bonus/reserve-affecting events, so idle-period quote history can look stale.
- 7d/30d snapshot fields are fully recomputed from daily aggregates on day boundaries (iterating 7 or 30 `DailyFurnaceAgg` records). Between day boundaries, the snapshot uses a fast-path monotonic widen (new data can only expand the range).

### C6c) LpStakingVault7D auto-compound events (required)

These events make LP reward auto-compound observable offchain (spec: `docs/spec/lp-staking-vault-spec.md`).

```graphql
type AutoCompoundConfiguredEvent {
  id: ID!                    # txHash-logIndex
  user: User!
  enabled: Boolean!
  tokenId: BigInt!
  durationSeconds: BigInt!
  timestamp: BigInt!
  txHash: Bytes!
}

type AutoCompoundPausedEvent {
  id: ID!                    # txHash-logIndex
  user: User!
  tokenId: BigInt!
  reasonCode: Int!
  timestamp: BigInt!
  txHash: Bytes!
}
```

Reason codes (MUST, canonical; matches `docs/analytics/dune-integration-pack-v1.0.0.md`):
- `1` = `NOT_OWNER`
- `2` = `LISTED`
- `3` = `EXPIRED`
- `4` = `INVALID_TOKEN_ID`
- `5` = `FURNACE_REVERT`
- `6` = `QUOTE_FAILED`
- `7` = `CHECKPOINT_FAILED`

### C6d) LP staking and Furnace LP stream (required)

#### C6d.1 Furnace LP rewards stream schedule

The subgraph must expose both the latest live stream schedule and every schedule reset emitted by Furnace.

```graphql
type FurnaceState {
  id: ID!                    # always "current"
  updatedAt: BigInt!
  reserve: BigInt!
  lpStreamRatePerSec: BigInt!
  lpStreamPeriodFinish: BigInt!

  # Rolling 24h LP rewards totals (CLAIM wei), computed from 1h buckets.
  lpRewardsClaim24h: BigInt!
  lpRewardsTopupClaim24h: BigInt!
  lpRewardsDripClaim24h: BigInt!
  lpRewardsSellRewardClaim24h: BigInt!
}

type LpStreamFundedEvent {
  id: ID!                    # txHash-logIndex
  timestamp: BigInt!
  blockNumber: BigInt!
  txHash: Bytes!
  amountFunded: BigInt!
  newRatePerSec: BigInt!
  newPeriodFinish: BigInt!
}
```

Required indexing rules:
- Source event: `Furnace.LpStreamFunded(amountFunded, newRatePerSec, newPeriodFinish)`.
- `FurnaceState.lpStreamRatePerSec` and `FurnaceState.lpStreamPeriodFinish` MUST reflect the latest observed schedule.
- Each emitted schedule reset MUST also be preserved as an immutable `LpStreamFundedEvent`.

#### C6d.2 Reserve monitoring events

```graphql
type ReserveClampedEvent {
  id: ID!                    # txHash-logIndex
  timestamp: BigInt!
  blockNumber: BigInt!
  txHash: Bytes!
  caller: User!
  oldReserve: BigInt!
  newReserve: BigInt!
  claimBalance: BigInt!
  lpStreamRemaining: BigInt!
}

type ReserveCreditedEvent {
  id: ID!                    # txHash-logIndex
  timestamp: BigInt!
  blockNumber: BigInt!
  txHash: Bytes!
  amount: BigInt!
  newReserve: BigInt!
}
```

Cross-layer naming note:
- The Solidity event parameter is `lpStreamLiability`. The subgraph maps this to the GraphQL field `lpStreamRemaining` for API compatibility. Dune decoded tables use the ABI parameter name `lpStreamLiability`. Consumers switching between the subgraph and Dune must account for this rename.

#### C6d.3 LP vault staking and rewards events

These events power the LP vault UI + achievements and make rewards flows observable offchain.

```graphql
type LpStakedEvent {
  id: ID!                    # txHash-logIndex
  user: User!
  amount: BigInt!
  timestamp: BigInt!
  txHash: Bytes!
}

type LpUnbondStartedEvent {
  id: ID!                    # txHash-logIndex
  user: User!
  unbondId: BigInt!
  amount: BigInt!
  unlockTime: BigInt!
  timestamp: BigInt!
  txHash: Bytes!
}

type LpUnbondWithdrawnEvent {
  id: ID!                    # txHash-logIndex
  user: User!
  unbondId: BigInt!
  amount: BigInt!
  timestamp: BigInt!
  txHash: Bytes!
}

type LpRewardsNotifiedEvent {
  id: ID!                    # txHash-logIndex
  amountClaim: BigInt!
  timestamp: BigInt!
  txHash: Bytes!
}

type LpRewardsClaimedEvent {
  id: ID!                    # txHash-logIndex
  user: User!
  amountClaim: BigInt!
  timestamp: BigInt!
  txHash: Bytes!
}

type LpRewardsLockedEvent {
  id: ID!                    # txHash-logIndex
  user: User!
  amountClaim: BigInt!
  principalClaim: BigInt!
  bonusClaim: BigInt!
  tokenId: BigInt!
  timestamp: BigInt!
  txHash: Bytes!
}

type LpFeesHarvestedToRewardsEvent {
  id: ID!                    # txHash-logIndex
  caller: User!
  feeWeth: BigInt!
  feeClaim: BigInt!
  claimToRewards: BigInt!
  timestamp: BigInt!
  txHash: Bytes!
}
```

### C7) MarketRouter (strict mode: Furnace-only lock trading)

**Field naming convention:**
- `MarketListing.minClaimOutWei` — minimum CLAIM the seller will accept (matches smart contract parameter)
- `MarketTradeEvent.priceInClaimWei` — actual CLAIM paid in a completed trade
- Frontend queries MUST use `minClaimOutWei` for listings (not `priceInClaimWei`)

```graphql
type MarketListing {
  id: ID!                    # tokenId as string
  tokenId: BigInt!
  lock: VeLock!
  seller: User!
  minClaimOutWei: BigInt!    # price floor for Furnace settlement (DO NOT confuse with priceInClaimWei)
  priceBps: BigInt!          # normalized ask = minClaimOutWei / lock.amountWei, in bps (for orderbook sorting)
  listedAtTime: BigInt!
  expiresAtTime: BigInt!     # unix timestamp (seconds); UI MUST filter expired listings client-side
  active: Boolean!
  updatedAt: BigInt!
}

# ListingSettled event entity (Furnace settled a listing)
type ListingSettledEvent {
  id: ID!                    # txHash-logIndex
  tokenId: BigInt!
  seller: User!
  claimOutWei: BigInt!       # CLAIM paid to the seller
  penaltyWei: BigInt!        # Total retained cut surfaced as `lockAmount - claimOut`; use Furnace sellback events to recover reserveAdd vs lpReward
  timestamp: BigInt!
  blockNumber: BigInt!
  txHash: Bytes!
}

type MarketTradeEvent {
  id: ID!                    # txHash-logIndex
  kind: String!              # "BUY" (strict mode: derived from Furnace.LockSoldToFurnace)
  tokenId: BigInt!
  seller: User!
  buyer: User!
  offer: BonusTargetEscrow   # Reserved for compatibility trade joins; null in strict-mode subgraph
  priceInClaimWei: BigInt!
  feeToFurnaceWei: BigInt    # Compatibility market-trade field; strict-mode listing settlement reserve/LP splits come from Furnace sellback events
  lockAmountWei: BigInt      # lock principal (nullable)
  discountBps: Int           # computed discount to principal PAR (nullable; 0 for premiums)
  timestamp: BigInt!
  txHash: Bytes!
}

# Note: In strict mode, Furnace is the only counterparty for lock trading.
# BonusTargetEscrow represents an entry order into the Furnace, NOT a bid to acquire user locks.

type BonusTargetEscrow {
  id: ID!                    # offerId as string
  offerId: BigInt!
  buyer: User!
  discountBps: Int!

  # Normalized bid price, expressed in bps (scaled by 10_000).
  #
  # - For compatibility discount offers: priceBps = (10_000 - discountBps)
  # - For bonus-target offers:    priceBps = 10_000 - floor(targetBonusBps * 10_000 / (10_000 + targetBonusBps))
#   NOTE: This can differ from floor(10_000^2 / (10_000 + targetBonusBps)) by up to 1 bps due to integer rounding.
  #
  # This is intended for server-side ordering in an orderbook view.
  priceBps: BigInt!

  # (reserved for compatibility)
  minLockSizeWei: BigInt

  budgetClaimWei: BigInt!
  fundsRemainingWei: BigInt  # tracked; for active offers: onchain remaining. For CANCELLED/EXPIRED: refunded remainder (unspent at close).
  createdAt: BigInt!
  updatedAt: BigInt!
  active: Boolean!

  # AutoFill v2 settings
  durationSeconds: BigInt
  createAutoMax: Boolean!
  expiresAt: BigInt!                 # unix timestamp (seconds); UI MUST filter expired offers client-side (see note below)
  destinationLockId: BigInt          # null when not set / unknown
  destinationLock: VeLock            # null until known

  # Bonus target config (required; v1.0.0 uses it)
  targetBonusBps: Int!               # 0 when disabled

  # Slippage protection in bps (0 if unknown / not configured).
  slippageBps: Int!
}
```

**Important: Client-side expiry filtering**

Offers can remain `active = true` onchain but be expired (non-executable) until someone calls `cancelExpiredBonusTargetEscrow`. The subgraph reflects onchain state, so it returns these offers as active.

**Orderbook UIs MUST filter expired offers client-side:**
- Query includes `expiresAt` field
- Filter: `expiresAt > currentTimestamp` (only show non-expired offers as valid depth)
- Stale expired offers near the top of the book will poison spread display if not filtered

This is important as "tight spread" develops because expired offers would appear as valid bids/asks.

```graphql
type BonusTargetEscrowEvent {
  id: ID!                    # txHash-logIndex
  offer: BonusTargetEscrow!
  kind: String!              # "CREATED" | "CANCELLED" | "EXPIRED" | "EXPIRY_EXTENDED" | "FILLED" | "BONUS_CONFIGURED" | "AUTO_FURNACE_EXECUTED"
  timestamp: BigInt!
  txHash: Bytes!
}
```

- Canonical fill history uses `BonusTargetEscrowEvent.kind = "FILLED"`, written from the generic `MarketRouter.BonusTargetEscrowExecuted` receipt.
- `AUTO_FURNACE_EXECUTED` is the same-tx companion row for detail and compatibility consumers and MUST NOT be double-counted as a second fill in history surfaces.

Canonical execution receipt (required):

```graphql
type BonusTargetEscrowExecutedEvent {
  id: ID!                    # txHash-logIndex
  offer: BonusTargetEscrow!
  buyer: User!
  claimInWei: BigInt!
  principalClaimWei: BigInt!
  bonusClaimWei: BigInt!
  veOutWei: BigInt!
  # Realized bonus rate in bps relative to principalClaim (the gross amount the
  # buyer paid in). Mirrors the on-chain MarketRouter BonusTarget gate. NOT the
  # bps ratio against principalEff (the duration-weighted effective principal that
  # feeds the Furnace AMM curve); for shorter durations the two diverge.
  bonusBpsVsPrincipalClaim: Int!
  routeTokenId: BigInt!
  furnaceTokenId: BigInt
  timestamp: BigInt!
  blockNumber: BigInt!
  txHash: Bytes!
}

type BonusTargetEscrowAutoFurnaceExecutedEvent {
  id: ID!                    # txHash-logIndex
  offer: BonusTargetEscrow!
  buyer: User!
  claimInWei: BigInt!
  principalClaimWei: BigInt!
  bonusClaimWei: BigInt!
  veOutWei: BigInt!
  bonusBpsVsPrincipalClaim: Int!
  routeTokenId: BigInt!
  furnaceTokenId: BigInt
  timestamp: BigInt!
  blockNumber: BigInt!
  txHash: Bytes!
}
```

### C8) Genesis infrastructure state (for `/overview`)

```graphql
type GenesisState {
  id: ID!                    # always "1"

  # LaunchController finalize
  genesisFinalized: Boolean!
  finalizedAt: BigInt
  finalizedTxHash: Bytes

  # LP lock
  genesisLpVaultLockStart: BigInt
  genesisLpVaultUnlockTime: BigInt

}
```

Minimum sources (once contracts exist):
- `LaunchController.GenesisFinalized(...)`
- `GenesisLPVault24M.Locked(...)` and `LockExtended(...)`

---

## D) Required top-level queries

### D0) Shared info surfaces (pricing)

These surfaces are consumed by:
- `/claim` (price + FDV)

The `aprSnapshot` entity remains in the schema for indexer/Dune consumers; the official UI does not surface APR/veAPR.

Query (example):
```graphql
query InfoSurfaces {
  _meta { block { number timestamp } }

  pricing: tokenPricingSnapshot(id: "1") {
    updatedAt
    claimEthTwap30m
    ethUsd
    ethUsdUpdatedAt
    totalSupplyWei
  }

  apr: aprSnapshot(id: "1") {
    updatedAt
    lpAprBps24h
    lpAvgTvl24hUsd
    veAprBps24h
  }
}
```

Rules (required):
- `claimEthTwap30m` is **ETH per CLAIM** (not wei-scaled).
- `ethUsd` is **USD per ETH** (normalized).
- `updatedAt` / `ethUsdUpdatedAt` are unix seconds.

### D1) Index dashboard (`/`)

UI needs:
- Protocol flags (pause states)
- Current king + reign start time
- Last takeover price and reference price (for client-side takeover price computation)
- Furnace card:
  - current Furnace bonus tier inputs (snapshot)
  - last 7d Furnace bonus history (hourly series)
- Minimal leaderboards preview (top 5 per board)

Query (example):
```graphql
query Home($since7d: BigInt!) {
  protocol(id: "1") {
    chainId
    version
    takeoversPaused
    tradingPaused
    lockingPaused
  }

  currentReign: reign(id: "current") {
    reignId
    king { id displayName }
    startTime
    startedByTakeover { pricePaidWei referencePriceWei timestamp }
  }

  furnaceBonusSnapshot(id: "1") {
    currentBps
    q33Bps
    q66Bps
  }

  furnaceBonus7d: furnaceBonusSamples(
    where: { bucketSeconds: 3600, bucketStart_gte: $since7d }
    orderBy: bucketStart
    orderDirection: asc
    first: 168
  ) {
    bucketStart
    quoteUserBonusBps
  }
}
```

Implementation note:
- If you prefer not to maintain `reign(id:"current")`, expose a dedicated query like `currentReign` in your GraphQL server.

### D2) Crown page (`/crown`)

UI needs:
- Current reign
- Recent reign history (last N finalized reigns)
- Current king’s lifetime stats (for side panel)

Query (example):
```graphql
query CrownPage($limit: Int!) {
  currentReign {
    reignId
    king { id displayName takeoverCount kingClaimMinedWei }
    startTime
    startedByTakeover { pricePaidWei referencePriceWei timestamp }
  }

  recentReigns: reigns(
    first: $limit
    orderBy: endTime
    orderDirection: desc
    where: { endTime_not: null }
  ) {
    reignId
    king { id displayName }
    startTime
    endTime
    totalClaimMinedWei
    totalEthToKingWei
  }
}
```

### D3) Locks page (`/locks`)

UI needs:
- Current ve leaderboard (top N)
- Recent shareholder allocations and claims (activity)
- Per-user panel when connected (claimable may still require RPC fallback if not indexed)

Query (example):
```graphql
query Locks($limit: Int!) {
  topBarons: leaderboardTopBaronsByVe(n: $limit) {
    user { id displayName }
    valueWei
  }

  recentShareholderClaims: shareholderClaimEvents(orderBy: timestamp, orderDirection: desc, first: 25) {
    user { id displayName }
    mode
    amountEthWei
    timestamp
    txHash
  }
}
```

`Top veCLAIM holders (current)` MUST come from a dedicated derived resolver. A naive sort on stale snapshot fields such as `users(orderBy: veBalanceWei, ...)` is incorrect for the shipped event-driven subgraph.

### D4) Furnace page (`/furnace`)

UI needs:
- Furnace bonus snapshot (current + last 24h context for tiers)
- Bonus history series:
  - last 7d hourly series (7d bonus history chart)
  - optional 24h 5m series (sparkline)
- Recent Furnace entries
- Top Furnace contributors leaderboards (ETH in, CLAIM in)
- LP stakers (last 24h CLAIM routed): `furnaceState.lpRewardsClaim24h` (+ optional split fields)
- Optional: reserve and pause flags (from protocol singleton)

Query (example):
```graphql
query Furnace($limit: Int!, $since7d: BigInt!, $since24h: BigInt!) {
  furnaceBonusSnapshot(id: "1") {
    updatedAt
    currentBps
    min24hBps
    max24hBps
    min7dBps
    max7dBps
    min30dBps
    max30dBps
    q33Bps
    q66Bps
  }

  furnaceBonus7d: furnaceBonusSamples(
    where: { bucketSeconds: 3600, bucketStart_gte: $since7d }
    orderBy: bucketStart
    orderDirection: asc
    first: 168
  ) {
    bucketStart
    quoteUserBonusBps
  }

  furnaceBonus24h: furnaceBonusSamples(
    where: { bucketSeconds: 300, bucketStart_gte: $since24h }
    orderBy: bucketStart
    orderDirection: asc
    first: 288
  ) {
    bucketStart
    quoteUserBonusBps
  }


  furnaceState(id: "current") {
    lpRewardsClaim24h
    lpRewardsTopupClaim24h
    lpRewardsDripClaim24h
    lpRewardsSellRewardClaim24h
  }

  recentFurnace: furnaceEnterEvents(orderBy: timestamp, orderDirection: desc, first: 25) {
    user { id displayName }
    mode
    ethInWei
    principalClaimWei
    bonusClaimWei
    tokenId
    timestamp
    txHash
  }

  topFurnaceEth: users(orderBy: furnaceEthInWei, orderDirection: desc, first: $limit) {
    id displayName furnaceEthInWei
  }
}
```

### D5) Furnace Market section (`/furnace`)

UI needs (Market section on the Furnace page):
- Active listings (paginated)
- Bonus target escrows (paginated)
- Recent trades

Query (example):
```graphql
query Market($first: Int!, $skip: Int!) {
  _meta {
    block {
      timestamp
    }
  }

  # Listings (limit sells to Furnace)
  listings(first: $first, skip: $skip, where: { active: true }, orderBy: listedAtTime, orderDirection: desc) {
    tokenId
    minClaimOutWei    # price floor for Furnace settlement
    seller { id displayName }
    lock { tokenId amountWei lockEnd autoMax }
  }

  # Bonus target escrows (entry orders into Furnace)
  bonusTargetEscrows(first: 50, where: { active: true }, orderBy: createdAt, orderDirection: desc) {
    offerId
    buyer { id displayName }
    targetBonusBps
    budgetClaimWei
    fundsRemainingWei
    durationSeconds
    createAutoMax
    expiresAt
    destinationLockId
    slippageBps
  }

  # Recent listing settlements
  recentListingSettlements: listingSettledEvents(first: 25, orderBy: timestamp, orderDirection: desc) {
    tokenId
    seller { id displayName }
    claimOutWei
    penaltyWei
    timestamp
    txHash
  }

  # Recent offer executions
  recentOfferExecutions: bonusTargetEscrowExecutedEvents(first: 25, orderBy: timestamp, orderDirection: desc) {
    offer { offerId }
    buyer { id displayName }
    claimInWei
    principalClaimWei
    bonusClaimWei
    bonusBpsVsPrincipalClaim
    routeTokenId
    furnaceTokenId
    timestamp
    txHash
  }
}
```

Constraints (required; Market valuation metrics):

- No schema change is required for listing valuation metrics.
- UI MUST derive the standardized listing metrics from the returned fields using `now = _meta.block.timestamp`:
  - **Time remaining** from the effective current end (`autoMax ? now + MAX_LOCK_DURATION : lockEnd`) minus `now`.
  - **Price per ve** from `minClaimOutWei / veNowWei`, where `veNowWei = floor(lock.amountWei * effectiveRemainingSec / MAX_LOCK_DURATION)`.
    - If computed `veNowWei == 0`, UI MUST display “N/A” and MUST treat the listing as not buyable (defensive).
  - **Discount to principal (PAR)** where principal (PAR) = `lock.amountWei`:
    - `discountToPar = 1 - (price / principal)`.

### D6) Leaderboards page (`/leaderboards`)

UI needs all 8 official leaderboards (per `docs/analytics/leaderboards-ui-and-dune-compatible-v1.0.0.md`):
- Top CLAIM mined as King
- Longest reign
- Most takeovers executed
- Top ETH spent on takeovers
- Top royalties claimed
- Top veCLAIM holders (current)
- Top CLAIM sent to Furnace
- Top ETH sent to Furnace

NOTE: The Dune SQL templates under `analytics/dune/leaderboards/` implement a different set of 9
boards with different numbering. See `analytics/README.md` for the Dune-vs-spec cross-reference.

Implementation rules:
- Leaderboards MUST follow the canonical definitions in `docs/analytics/leaderboards-ui-and-dune-compatible-v1.0.0.md`.
- Duration-filtered leaderboards MUST accept a `duration` enum:
  - `LAST_24H`
  - `LAST_7D` (default)
  - `LAST_30D`
  - `LIFETIME`
- `Top veCLAIM holders (current)` is snapshot-only and MUST NOT accept duration.

Definition notes:
- `Top CLAIM mined as King` uses finalized-in-window semantics:
  - Include a reign iff its `ReignFinalizedEvent.timestamp` is within the selected duration window (not prorated).

UI behavior (recommended):
- Default `duration = LAST_7D`.
- Low activity hint: if `duration = LAST_24H` and returned rows < N (recommended N = 10), show: “Low activity, switch to 7d/30d.”

UI requirements (REQUIRED): My rank + gap to next rank

The leaderboards UI is not complete with only top-N tables.

- When the viewer is connected, UI MUST show:
  - "Your rank" for the selected board + timeframe
  - "Gap to next rank" (value needed to pass the rank above you)
  - A "Find my rank" action when the viewer is not in the returned top N rows

Canonical UI reference:
- `docs/analytics/leaderboards-ui-and-dune-compatible-v1.0.0.md`

Backend requirement (recommended): rank lookup endpoint
- Computing an address rank outside the first page is expensive in naive GraphQL.
- Prefer a small derived-data endpoint backed by materialized leaderboard tables.

Recommended endpoint shape (example):
- `GET /api/leaderboards/rank?board=<KEY>&duration=<DURATION>&address=<0x...>`

Response (example):
```json
{
  "board": "TOP_KING_CLAIM_MINED",
  "duration": "LAST_24H",
  "address": "0x...",
  "asOf": { "block": 12345678, "timestamp": 1710000000 },
  "rank": 245,
  "valueWei": "123000000000000000",
  "above": { "rank": 244, "address": "0x...", "valueWei": "130000000000000000" }
}
```

Gap computation (UI):
- If `rank == 1`: show "You’re #1".
- If `rank > 1` and `above` exists: `gap = above.value - my.value`.
- Units:
  - ETH/CLAIM boards: use wei values
  - Count boards: use integers
  - Longest reign: use `valueInt` in seconds

Privacy/trust constraints (required):
- Rank lookup MUST use the same canonical leaderboard computation path as the displayed top N rows.
- Rank lookup SHOULD include `asOf` metadata so UI can show freshness and avoid mixed snapshots.
- Rank lookup MUST NOT change leaderboard ordering via client-side filtering.

Query paths:
- Direct query path: query `users` ordered by aggregate fields.
- Resolver query path: expose explicit resolver queries per leaderboard so the UI contract is stable.

Duration enum (example):
```graphql
enum LeaderboardDuration {
  LAST_24H
  LAST_7D
  LAST_30D
  LIFETIME
}
```

Example resolver-style query:
```graphql
query Leaderboards($duration: LeaderboardDuration!, $n: Int!) {
  # Crown
  topKingClaimMined: leaderboardTopKingClaimMined(duration: $duration, n: $n) { user { id displayName } valueWei }
  longestReign: leaderboardLongestReign(duration: $duration, n: $n) { user { id displayName } valueInt }
  mostTakeovers: leaderboardMostTakeovers(duration: $duration, n: $n) { user { id displayName } valueInt }
  topTakeoverSpend: leaderboardTopEthSpentOnTakeovers(duration: $duration, n: $n) { user { id displayName } valueWei }

  # Furnace (includes Barons)
  topBaronsEthClaimed: leaderboardTopBaronsByEthClaimed(duration: $duration, n: $n) { user { id displayName } valueWei }
  topBaronsVe: leaderboardTopBaronsByVe(n: $n) { user { id displayName } valueWei }
  topFurnaceClaim: leaderboardTopFurnaceClaimIn(duration: $duration, n: $n) { user { id displayName } valueWei }
  topFurnaceEth: leaderboardTopFurnaceEthIn(duration: $duration, n: $n) { user { id displayName } valueWei }
}
```

### D7) Overview page (`/overview`)

UI needs:
- Genesis state (finalized or not)
- Addresses (from manifest / latest protocol singleton wiring)
- Pause flags (from protocol singleton)

Query (example):
```graphql
query Ops {
  protocol(id: "1") {
    chainId
    version
    mineCore
    furnace
    marketRouter
    furnaceEntryTokenRegistry
    mineCoreEntryTokenRegistry
    entryTokenRegistry
    launchController
    genesisLpVault24m
    takeoversPaused
    lockingPaused
    tradingPaused
  }

  genesis(id: "1") {
    genesisFinalized
    finalizedAt
    genesisLpVaultUnlockTime
  }
}
```

### D8) Activity list and detail (`/activity`, `/activity/[id]`)

Define an “Activity” union in GraphQL, or expose a normalized list:

Minimum requirement:
- A single query that returns a mixed feed of:
  - Takeovers
  - Reign finalizations
  - Shareholder claims
  - Furnace enters
  - Market trades
  - Escrow events (create, cancel, execute)

Example normalized type:
```graphql
type ActivityItem {
  id: ID!                    # txHash-logIndex (stable tie-breaker, not time-monotonic)
  kind: String!
  timestamp: BigInt!
  txHash: Bytes!

  # Optional payload fields (nullable)
  reignId: BigInt
  tokenId: BigInt
  user: User
  otherUser: User
  amountEthWei: BigInt
  amountClaimWei: BigInt
}
```

Cursor rule (required):
- If the feed is ordered by `timestamp desc`, `nextCursor` MUST be derived from both the boundary `timestamp` and a stable tie-breaker `id`.
- Do not paginate a timestamp-sorted `ActivityItem` feed with a raw `id_lt` filter. `ActivityItem.id` is txHash/logIndex-derived and is not monotonic by timestamp.

Query (example):
```graphql
query Activity($first: Int!, $lastTs: BigInt!, $lastId: ID!) {
  activityItems(
    first: $first
    orderBy: timestamp
    orderDirection: desc
    where: {
      or: [
        { timestamp_lt: $lastTs }
        { timestamp: $lastTs, id_lt: $lastId }
      ]
    }
  ) {
    id
    kind
    timestamp
    txHash
    reignId
    tokenId
    amountEthWei
    amountClaimWei
    user { id displayName }
  }
}
```

Detail query (required):
```graphql
query ActivityEvent($id: ID!) {
  activityEventById(id: $id) {
    id
    kind
    timestamp
    txHash
    reignId
    tokenId
    amountEthWei
    amountClaimWei
    user { id displayName }
    otherUser { id displayName }
  }
  _meta {
    block { number timestamp }
  }
}
```

Semantics (MUST):
- `activityEventById(id)` MUST return `null` when no event exists for the given ID.
- The backend MUST accept any ID that has been emitted in `activityFeed.items[].id` (permalink stability).


### D9) Player profile pages (`/u/[address]`)

UI needs:
- Profile header:
  - Display label: `displayName` / `basename` / `ens` (in that order, else short address).
  - `takeoverCount` for badge progress.
- Ongoing King indicator:
  - If a user is the current King, `/u/[address]` shows “King of Reign #X”.
- Recent history panels:
  - Reigns as King (last 12).
  - Market buys and sells (last 12 each).
  - Furnace enters (last 12).
- Name resolution (when the route param is not a hex address):
  - Resolve a `.base.eth` basename or ENS name to a `User.id`.

Name resolution query (required, example):
```graphql
query ResolveUser($name: String!) {
  byBasename: users(where: { basename: $name }, first: 1) { id }
  byEns: users(where: { ens: $name }, first: 1) { id }
}
```

Profile query (required, example):
```graphql
query Profile($id: ID!) {
  _meta { block { timestamp } }

  user: user(id: $id) {
    id
    displayName
    basename
    ens
    takeoverCount
  }

  ongoing: reigns(where: { king: $id, endTime: null }, first: 1) { reignId }

  reignsAsKing: reigns(
    where: { king: $id }
    orderBy: startTime
    orderDirection: desc
    first: 12
  ) {
    reignId
    startTime
    endTime
  }

  dethrones: takeovers(
    where: { newKing: $id }
    orderBy: timestamp
    orderDirection: desc
    first: 12
  ) {
    timestamp
    reign {
      previousReign {
        reignId
        king { id displayName basename ens }
      }
    }
  }

  listingSettlements: listingSettledEvents(
    where: { seller: $id }
    orderBy: timestamp
    orderDirection: desc
    first: 12
  ) {
    id
    tokenId
    claimOutWei
    penaltyWei
    timestamp
    seller { id displayName basename ens }
  }

  furnaceEnters: furnaceEnterEvents(
    where: { user: $id }
    orderBy: timestamp
    orderDirection: desc
    first: 12
  ) {
    id
    timestamp
    mode
    ethInWei
    principalClaimWei
    bonusClaimWei
    tokenId
  }
}
```

Badge computation (required for `/u/[address]` and profile OpenGraph images):

- The current UI computes badges by scanning up to 1000 historical takeovers for the profile user.
- Backend MUST support the following query shape.
- Clarification (non-binding): A dedicated resolver requires UI changes and is not part of the current query contract.

```graphql
query ProfileBadges($id: ID!) {
  takeoversForBadges: takeovers(
    where: { newKing: $id }
    orderBy: timestamp
    orderDirection: asc
    first: 1000
  ) {
    id
    timestamp
    previousKing { id }
    reign {
      endTime
      previousReign {
        startTime
        king { id }
        previousReign { king { id } }
      }
    }
  }
}
```

Constraints (required):
- `User.id` MUST be the lowercase hex address. The UI will checksum the address in the URL, but GraphQL IDs remain lowercase.
- Name resolution MUST search `basename` and `ens` as exact matches (case-sensitive in the stored schema; normalize in the indexer if needed).
- If no `User` exists for the resolved address yet, the UI will still render a minimal profile shell.


### D10) Reign recap pages (`/crown/reign/[reignId]`)

UI needs:
- A single reign recap page that can render both:
  - Finalized reigns (with `endTime` set), and
  - Ongoing reigns (with `endTime == null`).
- “Pending finalization” handling:
  - If `endTime == null` but the next reign exists, the UI treats the reign as ended and shows a “pending finalization” state.

Query (required, example):
```graphql
query ReignRecap($id: ID!, $nextId: ID!) {
  _meta { block { timestamp } }

  reign: reign(id: $id) {
    id
    reignId
    startTime
    endTime
    totalClaimMinedWei
    king { id displayName basename ens }

    startedByTakeover {
      timestamp
      pricePaidWei
    }

    previousReign {
      startedByTakeover { timestamp }
    }
  }

  nextReign: reign(id: $nextId) {
    id
    startTime
    startedByTakeover { timestamp }
    king { id displayName basename ens }
  }
}
```

Semantics (required):
- `reign(id)` MUST return `null` when no reign exists for the given ID.
- `previousReign` MUST be `null` for reign `0` (no negative reign IDs).
- `startedByTakeover.timestamp` MUST reflect the actual takeover timestamp (not `startTime` if they differ).


---

### D11) Security page (`/security`)

This page presents bot sessions like approvals (delegate, expiry, permissions) plus a session-activity feed.

UI needs:
- Sessions list (approvals-like)
- Session activity feed (uses, tx hashes)
- Session changes feed (grants/updates/revokes, tx hashes)
- Mid-reign recipients change feed (for “Recipients changed mid-reign” alerts)

Query (example):

```graphql
query Security($user: ID!, $first: Int!) {
  _meta { block { number timestamp } }

  sessions: delegationSessions(
    where: { user: $user }
    orderBy: updatedAt
    orderDirection: desc
    first: $first
  ) {
    id
    delegate { id displayName }
    perms
    expiry
    createdAt
    updatedAt
    revokedAt
    lastUsedAt
    lastActionType
    lastTxHash
  }

  sessionUses: delegationSessionUses(
    where: { user: $user }
    orderBy: timestamp
    orderDirection: desc
    first: 50
  ) {
    timestamp
    actionType
    actionTypeId
    permsUsed
    refId
    txHash
    emitter
    delegate { id displayName }
  }

  sessionChanges: delegationSessionSetEvents(
    where: { user: $user }
    orderBy: timestamp
    orderDirection: desc
    first: 50
  ) {
    timestamp
    isRevocation
    perms
    expiry
    txHash
    delegate { id displayName }
  }

  midReignRecipientChanges: reignRecipientsSetEvents(
    where: { king: $user, isMidReignUpdate: true }
    orderBy: timestamp
    orderDirection: desc
    first: 20
  ) {
    reignId
    ethRecipient
    claimRecipient
    timestamp
    txHash
  }
}
```

Notes (required):
- Consider sessions active iff `perms > 0` AND `expiry >= _meta.block.timestamp`. `expiry = 0` is immediately expired, not active. Application/API consumers MUST derive this against the same payload's `_meta.block.timestamp`, not wall clock.
- Use `perms` for “what could this session do?” warnings, and `permsUsed` for “what did this tx do?” session-use labels.
- Active-session counts/cards and bulk-revoke surfaces MUST page the full `delegationSessions` set at one pinned `_meta` head. A capped `delegationSessions(first: N)` query is not sufficient for shipped security UIs.
- Radar security polling for `delegationSessionUses`, `delegationSessionSetEvents`, and mid-reign `reignRecipientsSetEvents` MUST NOT rely on a single capped `first: N` recent-events query plus local seen-ID diffing. The shipped Radar path now primes to the current head once, then pages forward from a pinned `(blockNumber,id)` cursor at one `_meta` head, and MUST fail closed on cursor overflow.

## E) Event-to-entity mapping checklist (required)

Index these events (minimum):

EntryTokenRegistry:
- `RouterConfigSet`
- `WethClaimPoolSet`
- `TokenConfigSet`
- `TokenEnabledChanged`

MineCore:
- `EntryTokenRegistrySet`
- `FurnaceChanged`
- `Takeover`
- `ReignFinalized`
- `ReignRecipientsSet` (receipt: true)
- `TakeoversPausedChanged`
- `KingWithdrawal`
- `KingWithdrawalTo`
- `KingEthPaid`
- `KingEthCredited`
- `RefundCredited`
- `RefundWithdrawn`
- `KingAutoLockConfigured` (stored as `ActivityItem.kind = KING_AUTOLOCK_CONFIGURED`)
- `KingAutoLockExecuted` (stored as `ActivityItem.kind = KING_AUTOLOCK_EXECUTED`)
- `KingAutoLockSkipped` (stored as `ActivityItem.kind = KING_AUTOLOCK_SKIPPED`)
- `KingAutoLockFailed` (stored as `ActivityItem.kind = KING_AUTOLOCK_FAILED`)
- `KingClaimLiquidPaid` (stored as `ActivityItem.kind = KING_CLAIM_LIQUID_PAID`)
- `ShareholderRoyaltiesTakeoverFailed`
- `ShareholderRoyaltiesFlushFailed`
- `DelegationSessionUsed`

ShareholderRoyalties:
- `ShareholderWiringSet`
- `ShareholderTakeoverAllocation`
- `ShareholderFlush`
- `ShareholderClaim`
- `ShareholderAutoCompoundConfigured`
- `ShareholderAutoCompoundPaused`
- `ShareholderAutoCompoundExecuted`
- `ShareholderAutoCompoundKeeperSet`
- `DelegationSessionUsed`

Furnace (`BonusPaid`, `LpOverflowDripPaid`, and `LockSoldToFurnace` are emitted via delegatecall into FurnaceGuardHelper; declared in IFurnace for ABI presence):
- `EntryTokenRegistrySet`
- `MineCoreChanged`
- `MineMarketChanged`
- `ShareholderRoyaltiesChanged`
- `LpRewardsVaultSet`
- `FurnaceQuoterSet`
- `FurnaceEnter` (receipt: true for token-entry calldata decoding)
- `BonusPaid`
- `LpOverflowDripPaid`
- `LockSoldToFurnace`
- `AutoMaxBonusClaimed`
- `LpRewardsNotifyFailed`
- `LpStreamFunded`
- `ReserveCredited`
- `ReserveClamped`
- `LockingPausedChanged`
- `DelegationSessionUsed`

LpStakingVault7D:
- `LpStaked`
- `LpUnbondStarted`
- `LpUnbondWithdrawn`
- `LpRewardsNotified`
- `LpRewardsClaimed`
- `LpRewardsLocked`
- `AutoCompoundConfigured`
- `AutoCompoundPaused`
- `HarvestKeeperSet`
- `LpFeesHarvestedToRewards`
- `DelegationSessionUsed`

VeClaimNFT:
- `LockCreated`
- `LockExtended`
- `LockAmountIncreased`
- `LockMerged`
- `LockUnlocked`
- `AutoMaxSet`
- `FurnaceChanged`
- `MineMarketChanged`
- ERC721 `Transfer`
- `DelegationSessionUsed`
- `SlopeDriftClamped`
- `ShareholderCheckpointFailed`

MarketRouter (strict mode: Furnace-only lock trading):
- `LockListed` (limit sell to Furnace created)
- `LockDelisted` (listing removed)
- `ListingSettled` (Furnace settled a listing)
- `MarketSellToFurnace`
- `BonusTargetEscrowCreated` (entry order into Furnace created)
- `BonusTargetEscrowCancelled`
- `BonusTargetEscrowExpired`
- `BonusTargetEscrowExpiryExtended`
- `BonusTargetEscrowConfigured`
- `BonusTargetEscrowExecuted` (canonical generic execution receipt)
- `BonusTargetEscrowAutoFurnaceExecuted` (back-compat companion receipt emitted in the same tx)
- `BonusTargetEscrowParamsChanged`
- `SettlementKeeperSet`
- `TradingPausedChanged`

GenesisLPVault24M:
- `Locked`
- `LockExtended`
- `WithdrawLp` (`to` is now `indexed`)
- `ResidualLpSwept` (`to` is `indexed`)
- `FeesClaimedAndForwarded` (`token0` and `token1` are `indexed`; emitted only on non-zero fee withdrawals; always precedes the paired `WithdrawLp` / `ResidualLpSwept` in the same tx)
- `TokenRescued`

LaunchController:
- `GenesisFinalized`

DelegationHub:
- `SessionSet`

ClaimAllHelper:
- `DelegationSessionUsed`

MaintenanceHub:
- `Poked` (includes `checkpointOk` and `flushOk` boolean flags)

---

## F) Pagination rules (required)

- Always order and paginate **after aggregation**.
- For list endpoints:
  - Prefer `createdAt` / `timestamp` desc with a stable cursor.
  - When ordering by `timestamp`, the cursor MUST include the boundary timestamp plus a deterministic tie-breaker id. A naked `id_lt` cursor is only valid when the list itself is ordered by `id`.
- Never paginate raw events and then aggregate totals.

Reference:
- `docs/analytics/indexer-and-dune-implementation-guide-v1.0.0.md`


When a consumer needs a live value such as “ve now”, Crown decay, or a public time-window aggregate, it must anchor that derivation to the same response `_meta.block.timestamp`.
Live Crown hall and reign recap APIs must also derive their response `nowSec` and range windows from the captured `_meta` head so the payload remains self-consistent under indexer lag.
