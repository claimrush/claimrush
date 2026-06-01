# Locks (veCLAIM)

`VeClaimNFT` is the ERC-721 contract that represents locked CLAIM positions. Each lock has an amount, expiry, and optional AutoMax flag. The lock's veCLAIM balance determines its share of Baron royalties via [ShareholderRoyalties](shareholderroyalties-barons.md). In the [CLAIM stream](protocol-overview.md), this is where committed CLAIM earns its yield.

> **TL;DR:** Each veCLAIM token has `(amount, lockEnd, autoMax, listed)`. ve weight = `amount * timeRemaining / 365d` (or rolling max when AutoMax is on). Lock creation and mutation routes through the Furnace; transfers route only via `MarketRouter ↔ Furnace`. AutoMax keeps the lock at max duration and accrues extension bonus permissionlessly.

## Public surface: `/veclaim`

The public app exposes a logged-out-friendly overview at `/veclaim`. It mirrors the user manual's [veCLAIM](https://docs.claimru.sh/veclaim) page and is the canonical entry surface for "what is veCLAIM" without requiring a wallet connect. The personal cockpit (top up, extend, merge, AutoMax) lives at `/locks`. Royalty collection (Collect ETH, Collect & Lock, Auto-compound setup) lives at `/overview`.

Read sources behind each card on `/veclaim`:

| Surface | Source |
|---|---|
| Locked CLAIM (principal across every live lock) | `ProtocolStats.lockedSupplyClaim` (mirrors `VeClaimNFT.totalLockedClaim()` denominated in whole CLAIM) |
| TVL (USD value of locked CLAIM) | `ProtocolStats.tvlUsd` / `tvlEth` |
| Royalties to Barons (7d) | `ProtocolStats.royalties7dEth` / `royalties7dUsd` |
| Royalty APY | `ProtocolStats.royalties7dApyBps` (`(1 + 7d return / 7)^365 − 1`, daily-compounded) |

Integrators that want the same numbers off the indexer should query the equivalents under `TokenPricingSnapshot` and the takeover scan (see `subgraph/schema.graphql`); the public app exposes the canonical aggregation via `/api/stats/protocol`.

## Public API

Lock creation and mutation are Furnace-only entrypoints. Users interact through the [Furnace](furnace.md) and [MarketRouter](marketrouter.md).

| Function | Caller | Purpose |
|---|---|---|
| `balanceOfVe(user) -> uint256` | view | Aggregated ve weight across all locks owned by `user`. |
| `veOf(tokenId) -> uint256` | view | Ve weight of a single lock at the current block. |
| `totalLockedClaim() -> uint256` | view | Sum of `amount` across every live lock. |
| `globalLastTs() -> uint256` | view | Last global checkpoint timestamp; used by royalty freshness gates. |
| `advanceGlobalCheckpoint()` | anyone | Permissionless ve global-state advance (bounded). |
| `tokenURI(tokenId)` | view | ERC-721 metadata. |
| `createLockFor(user, amount, lockEnd, autoMax) -> tokenId` | Furnace only | Mint a new lock; surfaces upstream are `Furnace.enterWith*`. |
| `addToLockFor(tokenId, amount, autoMax)` | Furnace only | Top up an existing lock. |
| `extendLockFor(tokenId, newLockEnd)` | Furnace only | Extend duration (drives extension bonus). |
| `mergeLocksFor(srcTokenId, dstTokenId)` | Furnace only | Concentrate two locks. |
| `setAutoMaxFor(tokenId, autoMax)` | Furnace only | Toggle AutoMax. |
| `transferFrom / safeTransferFrom` | MarketRouter ↔ Furnace only | All other transfers revert `TransfersRestricted`. |

## What a lock is

- veCLAIM is an ERC721 NFT.
- Each tokenId represents a lock:
  - amount (CLAIM principal + any locked bonus)
  - lockEnd (unlock timestamp when autoMax is OFF; when autoMax is ON, reads use an effective end = block.timestamp + MAX_LOCK_DURATION, rolling)
  - autoMax (bool)
  - listed (bool, used by MarketRouter)

Constraints (v1.0.0 constants):
- MIN_LOCK_AMOUNT = 1,000 CLAIM
- MIN_LOCK_DURATION = 7 days
- MAX_LOCK_DURATION = 365 days
- MAX_VE_NFTS_PER_USER = 32

## ve math (linear decay)

For a lock with:
- amount = A
- lockEnd = E
- now = N

ve at time N is:

```text
if N >= E: ve = 0
else:      ve = floor( A * (E - N) / MAX_LOCK_DURATION )
```

Implications:
- more CLAIM => more ve
- more remaining time => more ve (for non-AutoMax locks)
- For non-AutoMax locks, ve decays linearly to 0 at lockEnd
- For AutoMax locks, remaining time is always MAX_LOCK_DURATION, so ve stays equal to amount (no decay) while AutoMax is ON

<!-- SOLID salute to Andre Cronje + Solidly for the ve-lock (vote-escrow) mechanics lineage. -->


## AutoMax

AutoMax is an automatic "keep me at max ve forever" switch.

Rules:
- AutoMax is opt-in per lock. It can be set at creation or toggled later via `setAutoMax(tokenId, enabled)`.
- While autoMax is true:
  - the effective lockEnd is always `block.timestamp + MAX_LOCK_DURATION` (rolling)
  - remaining time is always MAX_LOCK_DURATION, so `ve == amount` (no decay)
  - the lock MUST NOT be treated as expired while autoMax is true
  - the lock never becomes unlockable; `unlock(tokenId)` MUST revert
- Turning AutoMax off sets `lockEnd = block.timestamp + MAX_LOCK_DURATION` (a fresh max-duration *decaying* lock). The user can unlock after 1 year.
  - Explicit path: `setAutoMax(tokenId, false)` → wait until `lockEnd` → `unlock(tokenId)`. No shortcut — the full MAX_LOCK_DURATION cooldown applies.

AutoMax automatic bonus growth:
- A key advantage of AutoMax: the protocol accrues extension bonuses automatically via `Furnace.claimAutoMaxBonus(tokenId)` or `Furnace.claimAutoMaxBonusBatch(tokenIds[], maxLocks)` (permissionless, 24h onchain cooldown per lock, ineligible locks return 0). The official keeper triggers these per settlement period per owner (daily by default), grouping all of a user's locks together. AutoMax lockers receive hands-free compounding — no manual extensions, no gas costs — making AutoMax the most rewarding lock mode. See [Furnace — AutoMax automatic bonus growth](furnace.md#automax-automatic-bonus-growth) for details.

Integrator notes:
- Treat `getLockInfo(tokenId).lockEnd` as an *effective* lockEnd. For AutoMax it is time-dependent.
- `getShareholderLockParams(user)` returns the RAW stored lockEnd, NOT the effective end. For AutoMax locks, callers MUST treat ve == amount directly and ignore `lockEnds[i]`.
- For offchain ve math: if `autoMax == true`, use `ve = amount`.

## Merge locks (Furnace.mergeLocksWithBonus)

All merges route through `Furnace`. The public-facing merge surface is:

- `Furnace.mergeLocksWithBonus(fromTokenId, intoTokenId, minBonusOut)` — owner-only.
- `Furnace.mergeLocksWithBonusFor(user, fromTokenId, intoTokenId, minBonusOut)` — delegated via `P_VE_MERGE_LOCKS_FOR`.

Both wrap `VeClaimNFT.mergeLocksFor` (Furnace-only sibling of `extendLockToFor` /
`addToLockFor`) and reuse the same bonus engine that powers `extendWithBonus` and
`enterWithClaim`:

- The two locks are merged into the longer-duration survivor: `from` is burned, the surviving lock absorbs `fromAmount + intoAmount`.
- When the merge effectively extends the surviving lock, an extension-style bonus
  is paid on the duration delta (`durationDelta = longer.remaining - shorter.remaining`),
  using the shorter-lock principal as the bonus base. When both inputs share the
  same effective remaining duration (including both AutoMax), the bonus is 0.
- The bonus CLAIM is deposited into the surviving lock via `Furnace._approveVeAndAddToLock`
  (no transfer to user, no rebase of `lockEnd`). The lock now holds
  `fromAmount + intoAmount + bonusClaim`.
- `minBonusOut` is the slippage floor on the bonus; pass 0 to skip.
- **Mixed AutoMax / non-AutoMax pairs are accepted.** The survivor's AutoMax flag
  is `from.autoMax || into.autoMax` (OR-rule, resolved inside
  `VeClaimNFT._mergeLocksInternal`). When the survivor is AutoMax, `lockEnd` is
  set to `block.timestamp + MAX_LOCK_DURATION` and the AutoMax side's effective
  `remaining` is treated as `MAX_LOCK_DURATION`, so the bonus is paid on the
  non-AutoMax side's principal at the full `weightDelta(MAX_LOCK_DURATION, remaining)`
  from the sub-bp duration-weight curve. AutoMax is reversible (toggle-off path on `VeClaimNFT`), so the
  survivor's AutoMax state is recoverable by the user at any time.
- Both locks must be owned by the caller (or by `user` for the delegated path),
  not listed, and not expired.

The `FurnaceMergeWithBonus` event captures the full economic context
(`fromAmount, intoAmount, newPrincipal, newEnd, newAutoMax, durationDelta, bonusClaim`).
`LockMerged` is the ve-side state-transition event for VeClaimNFT-level subgraph
parity and does not surface the bonus; downstream indexers should consume
`FurnaceMergeWithBonus` for economic accounting.

## Transfer restrictions (Furnace-only)

Direct transfers are restricted.

**Strict mode invariant:**
- The Furnace is the only counterparty for listing settlement.
- There are no user-to-user lock transfers or sales.

Expected behavior:
- MarketRouter (`mineMarket`) is the only supported transfer gateway for lock management.
- Transfer-based market exits route to the Furnace (listing settlement or instant sellback). Standard expiry unlocks do not: `unlock(...)` / `unlockExpiredForUser(...)` return CLAIM directly from VeClaimNFT to the chosen recipient after burn.
- Strict mode: `mineMarket` may only transfer a lock into the Furnace (`to == furnace`) for settlement/sellback.
  - MarketRouter may transfer a lock into the Furnace during settlement/sellback.
  - The Furnace never transfers veCLAIM NFTs; it burns locks via `furnaceBurnAndWithdraw` after taking custody.
- VeClaimNFT fails closed on caller drift: Furnace-only helpers and MarketRouter-only transfer/listing hooks cross-check the live Furnace, MarketRouter, MineCore, ClaimToken, and wired royalties roots before accepting mutations.
- Locks marked listed = true are considered frozen for mutation until delisted or settled.

## Checkpointing and cached totals

VeClaimNFT exposes global checkpointing to keep aggregates consistent and gas-bounded.

Key views:
- totalLockedClaim()
- totalVeCached()
- totalVeBiasScaled()
- globalLastTs()
- getShareholderLockParams(user)

ABI note:
- keep shipped ABI artifacts in sync with these views
- offchain consumers that rely on generated ABI/type bundles must include both getters after the historical shareholder-reward fix

Key calls:
- checkpointGlobalState()
- checkpointTotalVe()

Where they are used:
- MineCore runs a gas-guarded checkpoint loop before takeover finalization and keeps looping until ve catches up, gas gets low, or no forward progress is made.
- MaintenanceHub.poke(args) runs best-effort checkpointing as general upkeep.

## UI: show Total ve and royalty share (%)

The official UI uses ve data to show players their current power and weight in royalties.

Recommended reads (ordered):
- `userVe = VeClaimNFT.veBalanceOf(user)` (accurate per-user aggregate)
- `totalVe = VeClaimNFT.totalVeCurrent()` (view-only; denom for UI share display)

UI share calculation:
- If `totalVe == 0`: share = 0
- Else: `shareBps = floor(userVe * 10_000 / totalVe)`
- Display `sharePct = shareBps / 100` with 2 decimals (use `<0.01%` for tiny values).

Notes:
- `totalVeCurrent` is view-only (no checkpoint in this call); it is only as fresh as the last global checkpoint.
- If checkpoints lag, share can be stale. Best-effort display.

## Integrator notes

- For onchain rewards accounting, ShareholderRoyalties uses `totalVeBiasScaled()` after `ve.checkpointTotalVe()` so the denominator matches VeClaimNFT's processed bias model exactly.
- ShareholderRoyalties reconstructs delayed rewards from `getShareholderLockParams(user)` plus historical flush timestamps.
- `_checkpointShareholderRoyalties(user)` before **every** ve mutation is correctness-critical. Removing or skipping it reintroduces retroactive capture / under-accrual bugs.
- For user balances, `veBalanceOf(user)` is definitive but can be more expensive than cached reads.
- Never assume tokenIds are sequential per user.
- Lock extensions route through `Furnace.extendWithBonus(tokenId, durationSeconds, minBonusOut)`, which awards a bonus on existing capital for the incremental duration commitment. `VeClaimNFT` does not expose user-facing extension functions; the Furnace-only `extendLockToFor(...)` is used internally by Furnace.

## Operator notes

The remaining section covers deploy-time wiring. Integrators can skip unless instrumenting governance flows.

### Construction

The constructor rejects a delegated-EOA `initialOwner`: a 7702-delegated address reverts `DelegatedEOA`, while bare EOAs and ordinary contracts pass. The same rejection runs on the `_claimToken`, `_mineMarket`, and `_furnace` wiring inputs, and on `transferOwnership`. See [Security, Guardian, Pausing — Initial-owner 7702 guard](security-guardian-pausing.md#initial-owner-7702-guard) for the cross-contract rule.

## ERC-721 metadata

VeClaimNFT implements ERC-721 metadata with ERC-4906 (per-token metadata update signals) and ERC-7572 (collection-level `contractURI`).

### Owner-configurable URIs

| Function | Purpose |
|----------|---------|
| `setBaseURI(string uri)` | Set the base URI used by `tokenURI()`. Wallets fetch `baseURI + tokenId` to resolve per-token JSON metadata. Emits `BaseURISet` + `BatchMetadataUpdate(0, MAX_UINT)`. |
| `setContractURI(string uri)` | Set the collection-level metadata URI (ERC-7572). Emits `ContractURISet` + `ContractURIUpdated`. |
| `freezeMetadata()` | One-way, owner-only kill switch for the two setters above. After this call, `setBaseURI` / `setContractURI` permanently revert with `Errors.MetadataFrozen()`. Orthogonal to `freezeConfig()` — metadata can be frozen independently and intentionally later, once the final endpoint URLs are confirmed stable. Emits `MetadataFrozen()`. |

Both setters accept URIs up to 512 bytes (`_MAX_URI_LENGTH`); longer strings revert with `URITooLong`. Both remain owner-configurable after `freezeConfig()` — metadata is explicitly excluded from the config freeze and is gated on the separate `metadataFrozen` flag instead.

### Read-only

| Function | Purpose |
|----------|---------|
| `tokenURI(uint256 tokenId)` | For minted tokens, defers to OpenZeppelin's default (`baseURI + tokenId`). For the next `_PENDING_MINT_WINDOW = 4` unminted tokenIds starting at `_nextTokenId`, returns the same `baseURI + tokenId` placeholder so wallet signing-previews and batched multicalls resolve to indexer-generated metadata instead of reverting. Any other unminted tokenId (well past the pending window, or below `_nextTokenId` implying a never-minted gap) reverts with `ERC721NonexistentToken`. |
| `baseURI()` | Returns the current base URI |
| `contractURI()` | Returns the collection-level metadata URI |
| `supportsInterface(bytes4)` | Reports ERC-4906 (`0x49064906`) and ERC-7572 (`0xe8a3d485`) in addition to standard ERC-721/165 |

### Metadata update events

- `MetadataUpdate(uint256 tokenId)` — emitted on lock state changes (merge, unlock, etc.) to signal wallets to refresh individual token metadata.
- `BatchMetadataUpdate(uint256 fromTokenId, uint256 toTokenId)` — emitted on base URI changes to signal a global refresh.
- `BaseURISet(string oldURI, string newURI)` / `ContractURISet(string oldURI, string newURI)` — admin history.

### Off-chain metadata API

A metadata service can expose per-token and collection metadata through routes such as:

- `GET /api/nft/veclaim/[tokenId]` — returns ERC-721 metadata JSON (name, description, image, attributes) for a specific lock.
- `GET /api/nft/veclaim/collection` — returns ERC-7572 collection metadata JSON.

Point `setBaseURI` at the token endpoint and `setContractURI` at the collection endpoint.

## See also

- [Furnace](furnace.md) — bonus engine and lock entry
- [ShareholderRoyalties (Barons)](shareholderroyalties-barons.md) — ETH royalty distribution to veCLAIM holders
- [Market (MarketRouter)](marketrouter.md) — listing and selling locks
- [Core Mechanics](core-mechanics.md) — takeover loop and emission schedule
- Tutorial: [Integrate Furnace quotes + enter](tutorials/integrate-furnace-quotes-and-enter.md)
- User manual: [veCLAIM](https://docs.claimru.sh/veclaim) — concept overview, ve weight math, three routes to acquire
- User manual: [Locks](https://docs.claimru.sh/locks) — personal cockpit reference
