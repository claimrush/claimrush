# Dune integration pack for ClaimRush v1.0.0 (Base mainnet)

This document defines the canonical **event decoding contract** for ClaimRush v1.0.0 (Base mainnet).

Supported analytics backends (v1.0.0 in this repo):
- The Graph subgraph (canonical backend for the official UI + leaderboards).
- Dune dashboards (supported via the SQL templates shipped in `analytics/dune/`; informational only).

Dashboard policy (v1.0.0):
- This repo ships and maintains **SQL templates only** (queries).
- This repo does **not** ship or maintain Dune dashboards (dashboard URLs, visualizations, query IDs) as "the backend".

Unsupported analytics backends (v1.0.0 in this repo):
- Replacing the subgraph as the canonical onchain event ingestion pipeline with a bespoke indexer.

Allowed (v1.0.0):
- A small auxiliary derived-data job that reads from the subgraph and materializes sortable views that are not safely computable inside subgraph queries (example: “Top veCLAIM holders (current)”).

Reference-only (non-v1 optional):
- These templates are not part of the supported v1.0.0 deliverables and may change without guarantees.

Decoding inputs (MUST):
- Decoded event logs.
- ERC20/ERC721 transfers only when explicitly required by a spec.
- Traces are not part of this decoding contract.

## Required inputs (and where they are)

- Deployment manifest (addresses + start blocks)
  - `deployments/base_mainnet.json`
  - `deployments/base_mainnet.md`
- ABI / decoding source
  - ABI JSON: `abis/base_mainnet/*.abi.json`
  - Export helper: `scripts/export_abis.py`
  - Subgraph manifests MUST consume the same exported `abis/<network>/*.abi.json` files directly (no separate event-only ABI duplicates alongside the manifests)
- Official leaderboard definitions (these 8; Dune templates implement them with matching numbering 01–08)
  - `docs/analytics/leaderboards-ui-and-dune-compatible-v1.0.0.md`
- Canonical metric meanings + units + rounding
  - `docs/analytics/metrics-canon-v1.0.0.md`
- Canonical enum/codebook mappings (pinned below; MUST NOT change)

Reference templates (REQUIRED deliverables in this repo for v1.0.0):
- Dune SQL templates: `analytics/dune/`

Optional reference templates (non-v1):

Implementation notes (subgraph):
- `docs/analytics/indexer-and-dune-implementation-guide-v1.0.0.md`
- `docs/analytics/indexing-hosting-and-derived-data-reference-v1.0.0.md`

## Duration filtering (leaderboards)

Duration filter options (duration-filtered leaderboards only):
- last 24h
- last 7d (default)
- last 30d
- lifetime

Semantics (MUST):
- Rolling trailing windows (not calendar-aligned).
- Timestamp source: use the block timestamp stored on the subgraph event entity.
- Filter-before-aggregate: apply the timestamp filter before `GROUP BY` / `ORDER BY` / `LIMIT` / pagination.

Leaderboard-specific notes (MUST):
- Top CLAIM mined as King uses finalized-in-window semantics: include a reign iff its `MineCore.ReignFinalized` event occurred within the window (not prorated).
- Top veCLAIM holders is current snapshot only (no duration filter).

UI mitigation (MUST):
- If duration = last 24h AND returned rows < 10, show: “Low activity, switch to 7d/30d.”

## Deployment manifest (required)

External devs need concrete addresses + start blocks for:
- ClaimToken
- VeClaimNFT
- MineCore
- ShareholderRoyalties
- Furnace
- LpStakingVault7D
- MarketRouter (marketplace; emits marketplace events)
- EntryTokenRegistry (one or more; at minimum the registry addresses wired into Furnace and MineCore)
- DexAdapter (DEX routing adapter used by EntryTokenRegistry)
- LaunchController (genesis controller; `finalizeGenesis`)
- DelegationHub (bot sessions / approvals; emits `SessionSet`)
- ClaimAllHelper
- MaintenanceHub (permissionless maintenance entrypoint; emits keeper/ops events)
- Aerodrome CLAIM/WETH pool + router + WETH (router is used internally by DexAdapter)
- GenesisLPVault24M + LP token

Source of truth:
- `deployments/base_mainnet.json`

Dune performance rule:
- Always filter decoded event tables by start block:
  - `WHERE evt_block_number >= <startBlock from deployments/base_mainnet.json>`

## ABI decoding (MUST)

- Use `abis/base_mainnet/*.abi.json` from this repo as the ABI input for any decoder.
- A deployment with a missing required ABI file is invalid.
- `scripts/export_abis.py` is the repo’s ABI export mechanism for regenerating these files.

## Enum/codebook (canonical)

These numeric mappings MUST be immutable once deployed.

### ShareholderClaim.mode
- `0` = `ETH`
- `1` = `LOCK_FURNACE`

### ShareholderAutoCompoundPaused.reasonCode
- `1` = `NOT_OWNER`
- `2` = `LISTED`
- `3` = `EXPIRED`
- `4` = `INVALID_TOKEN_ID`
- `5` = `FURNACE_REVERT`
- `6` = `QUOTE_FAILED`
- `7` = `CHECKPOINT_FAILED`

### AutoCompoundPaused.reasonCode
- `1` = `NOT_OWNER`
- `2` = `LISTED`
- `3` = `EXPIRED`
- `4` = `INVALID_TOKEN_ID`
- `5` = `FURNACE_REVERT`
- `6` = `QUOTE_FAILED`
- `7` = `CHECKPOINT_FAILED`

### KingAutoLockSkipped.reasonCode
- `1` = `NOT_OWNER`
- `2` = `LISTED`
- `3` = `EXPIRED`
- `4` = `INVALID_TOKEN_ID`
- `5` = `INVALID_DURATION`
- `0xFF` = `GAS_PRECHECK` (insufficient gas to attempt Furnace lock)

### FurnaceEnter.mode
- `0` = `ENTER_WITH_ETH`
- `1` = `ENTER_WITH_CLAIM`
- `2` = `LOCK_FURNACE`
- `3` = `ENTER_WITH_TOKEN`
- `4` = `EXTEND_WITH_BONUS`

> AutoMax automatic bonus growth uses a separate `AutoMaxBonusClaimed(user, tokenId, bonusClaim)` event (not `FurnaceEnter`) to avoid activity-feed spam from keeper calls.

### LockDelisted.reason
- `0` = `NORMAL`
- `1` = `EMERGENCY` (seller-only emergency delist)
- `2` = `SOLD_INTO_OFFER` (reserved compatibility analytics code; not emitted by the strict-mode router)
- `3` = `SOLD_TO_FURNACE` (listing auto-cleared because the lock was sold to the Furnace)
- `4` = `EXPIRED` (listing auto-cleared because its listing TTL elapsed before settlement)
- `5` = `APPROVAL_REVOKED` (reserved compatibility analytics code; not emitted by the strict-mode router)

### DelegationSessionUsed.actionType
Canonical numeric action ids (same values surfaced as subgraph `actionTypeId`; see contracts: `src/lib/DelegationActionTypes.sol`):
- `1` = `TAKEOVER_FOR`
- `2` = `MINECORE_SET_REIGN_RECIPIENTS`
- `10` = `CLAIM_SHAREHOLDER_FOR`
- `11` = `WITHDRAW_KING_BUCKET_FOR`
- `12` = `CLAIM_ALL_FOR`
- `13` = `CLAIM_SHAREHOLDER_TO_CALLER_FOR`
- `20` = `FURNACE_ENTER_WITH_ETH_FOR`
- `21` = `FURNACE_ENTER_WITH_CLAIM_FOR`
- `22` = `FURNACE_ENTER_WITH_TOKEN_FOR`
- `30` = `VE_EXTEND_LOCK_FOR`
- `31` = `VE_MERGE_LOCKS_FOR`
- `32` = `VE_UNLOCK_EXPIRED_FOR`
- `40` = `MINECORE_SET_KING_AUTO_LOCK_CONFIG_FOR`
- `41` = `SHAREHOLDER_SET_AUTOCOMPOUND_CONFIG_FOR`
- `42` = `LP_STAKING_SET_AUTOCOMPOUND_CONFIG_FOR`

Convenience grouping (recommended; used by the shipped coarse subgraph/UI enum):
- `1` → `TAKEOVER`
- `2` → `REIGN_RECIPIENTS`
- `10–13` → `CLAIM`
- `20–22` → `FURNACE_ENTER`
- `30–32` → `VE_LOCK`
- `40–42` → `CONFIG`
- Dune decoders should persist the raw `actionTypeId` rather than inferring exact semantics from the coarse bucket alone.

## Events (what to decode)

Events are the primary source for analytics outputs.

Canonical signature rule (MUST):
- The event signatures listed in this section are the single source of truth for offchain decoding (Dune, indexers, achievements, alerts).
- If any other doc lists a different argument ordering/naming, treat this document as authoritative and update the other doc.

Typed signature rule (MUST):
- For v1.0.0, the canonical parameter **types** and **indexed** flags are pinned in:
  - `docs/spec/spec-v1.0.0.md` (§11.2 Events for analytics)
  - `docs/spec/maintenance-hub-spec-v1.0.0.md` (MaintenanceHub.Poked)
- `abis/base_mainnet/*.abi.json` MUST match those typed signatures.
- Repo guardrail: `python3 scripts/check_abi_event_schema.py --network base_mainnet` verifies ABI ↔ spec alignment.


### EntryTokenRegistry

Constraint (required; v1.0.0 deployment pattern):
- Furnace and MineCore registries MUST be treated as independent addresses (do not assume they are equal).
- Discover the active registry addresses by decoding:
  - `Furnace.EntryTokenRegistrySet(registry)`
  - `MineCore.EntryTokenRegistrySet(registry)`
- Decode `TokenConfigSet` / `TokenEnabledChanged` / `FurnaceEntryTokenSafetySet` from the registry addresses that are wired.

- `RouterConfigSet(router, factory, wrappedNative, claimToken)`
- `WethClaimPoolSet(pool, stable)`
- `TokenConfigSet(tokenIn, enabled, directToClaimEnabled, tokenClaimStable, tokenClaimPool, tokenWethStable, tokenWethPool)`
- `TokenEnabledChanged(tokenIn, enabled)`
- `FurnaceEntryTokenSafetySet(tokenIn, exactReceiptSafe)`

### VeClaimNFT
- `FurnaceChanged(oldFurnace, newFurnace)`
- `MineMarketChanged(oldMineMarket, newMineMarket)`
- `LockCreated(user, tokenId, amount, lockEnd, autoMax)`
- `LockExtended(user, tokenId, oldEnd, newEnd)`
- `LockAmountIncreased(user, tokenId, amountAdded)`
- `LockMerged(user, fromTokenId, intoTokenId, amountMoved)`
- `LockUnlocked(user, tokenId, amountReturned)`
- `AutoMaxSet(user, tokenId, autoMax)`
- `SlopeDriftClamped(timestamp, scheduledSlope, globalSlope)`
  - Emitted when the global ve bias drifts negative and is clamped to zero during a checkpoint.
- `ShareholderCheckpointFailed(user, royalties)`
  - Emitted when the best-effort ShareholderRoyalties checkpoint fails during a ve mutation.
- `DelegationSessionUsed(user, delegate, actionType, permsUsed, refId, timestamp)`
  - Emitted when delegated lock maintenance is used (see `DelegationActionTypes`: 30–32).
- `MetadataUpdate(_tokenId)`
  - ERC-4906: emitted on lock mutations (add, extend, merge, setAutoMax) to signal wallets to refresh cached metadata.
- `BatchMetadataUpdate(_fromTokenId, _toTokenId)`
  - ERC-4906: emitted by `setBaseURI()` with range `(0, type(uint256).max)` to signal all token metadata changed.
- `MetadataFrozen()`
  - Admin: emitted once when the owner permanently freezes the token metadata surface (`setBaseURI`/`setContractURI` paths become unavailable thereafter). Marketplaces and indexers MAY treat this as the authoritative signal that the cached `tokenURI()` and `contractURI()` snapshots are now permanent.
- `BaseURISet(oldURI, newURI)`
  - Admin: emitted when the owner updates the base URI used by `tokenURI()`.
- `ContractURISet(oldURI, newURI)`
  - Admin: emitted when the owner updates the collection-level metadata URI (ERC-7572 `contractURI`).
- `ContractURIUpdated()`
  - ERC-7572: parameterless signal emitted alongside `ContractURISet` for marketplace compliance.

### MineCore

All signatures below mark `indexed` args explicitly; topic ordering is binding for raw-log decoders and subgraph handlers. The canonical source of truth is `abis/base_mainnet/MineCore.abi.json`.

- `EntryTokenRegistrySet(address indexed registry)`
- `FurnaceChanged(address indexed oldFurnace, address indexed newFurnace)`
- `Takeover(uint256 indexed reignId, address indexed previousKing, address indexed newKing, uint256 pricePaid, uint256 referencePrice, uint256 timestamp)`
- `ReignRecipientsSet(uint256 indexed reignId, address indexed king, address indexed ethRecipient, address claimRecipient)`
- `KingEthPaid(address indexed recipient, uint256 amount)` — emitted when the dethroned reign's 75% share pushes successfully to `reignEthRecipient[reignId]` (falls back to `prevKing`). Indexers MUST key payout tracking on `recipient`, not the king identity.
- `KingEthCredited(address indexed recipient, uint256 amount)` — emitted when the push failed and the amount was credited to `kingEthBalance[recipient]` for pull-based withdrawal.
- `DelegationSessionUsed(address indexed user, address indexed delegate, uint8 indexed actionType, uint256 permsUsed, uint256 refId, uint256 timestamp)`
- `ReignFinalized(uint256 indexed reignId, address indexed king, uint256 startTime, uint256 endTime, uint256 totalClaimMined, uint256 totalEthToKing)`
- `TakeoversPausedChanged(bool paused)`
- `KingWithdrawal(address indexed king, uint256 amount)`
- `KingWithdrawalTo(address indexed king, address indexed to, uint256 amount)`
  - Variant of `KingWithdrawal` that routes the withdrawal to a different recipient (`to`). Analytics MUST track both events for complete withdrawal accounting.
- `KingAutoLockConfigured(user, enabled, targetTokenId, pinnedTokenId, durationSeconds, createAutoMax, minVeOut)`
- `KingAutoLockExecuted(reignId, user, principalClaim, tokenIdUsed)`
- `KingAutoLockSkipped(reignId, user, principalClaim, reasonCode)`
- `KingAutoLockFailed(reignId, user, principalClaim, revertData)`
  - Clarification: on each pause toggle, if a King exists, MineCore clamps `currentReignLastAccrualTime = block.timestamp` (paused time is never mined later).
- `RefundCredited(to, amount)`
  - Emitted when an overpayment refund is credited to a pull bucket.
- `RefundWithdrawn(user, to, amount)`
  - Emitted when a user withdraws a credited refund.
- `ShareholderRoyaltiesFlushFailed(reason)`
  - Emitted when the best-effort `ShareholderRoyalties.flush()` call reverts during a takeover.
- `ShareholderRoyaltiesTakeoverFailed(reignId, amountEth, reason)`
  - Emitted when the takeover-time royalties transfer to ShareholderRoyalties reverts and is suppressed.
- `KingEthPaid(recipient, amount)`
  - Emitted when the dethroned-King ETH payout push succeeds during a takeover.
- `KingEthCredited(recipient, amount)`
  - Emitted when the best-effort dethroned-King ETH payout push fails and the amount is credited to `kingEthBalance[recipient]` for pull withdrawal.
- `PendingClaimWithdrawn(user, to, amount)`
  - Emitted when a user (or ClaimAllHelper) withdraws pending CLAIM from `pendingClaimBalance`.
- `KingClaimCredited(user, amount)`
  - Emitted when pending CLAIM is credited to a user's `pendingClaimBalance` bucket (e.g. during auto-lock or reign finalization).
- `DelegationHubChanged(oldDelegationHub, newDelegationHub)`
  - Admin: emitted when the DelegationHub wiring is updated.
- `ClaimAllHelperChanged(oldHelper, newHelper)`
  - Admin: emitted when the ClaimAllHelper wiring is updated.

### ShareholderRoyalties
- `ShareholderWiringSet(mineCore, mineMarket, furnace)`
  - Operational note: indexers can use this receipt to seed and refresh the protocol wiring singleton before or between Baron business events.
- `ShareholderTakeoverAllocation(reignId, amountEth)`
- `ShareholderFlush(amountEth, deltaEthPerVe)`
- `ShareholderClaim(user, mode, amountEth)`
- `ShareholderAutoCompoundConfigured(user, enabled, tokenId, durationSeconds, minCadenceSeconds, minEthToCompound, maxSlippageBps)`
- `ShareholderAutoCompoundPaused(user, tokenId, reasonCode)`
- `ShareholderAutoCompoundExecuted(user, executor, amountEth, tokenId, effectiveDurationSeconds)`
- `ShareholderAutoCompoundFailed(user, amountEth, tokenId)`
  - Emitted when the downstream `Furnace.lockEthReward(...)` reverts during auto-compound. User ETH remains claimable. Always accompanied by `ShareholderAutoCompoundPaused`.
- `ShareholderAutoCompoundKeeperSet(keeper, allowed)`
  - Emitted when the auto-compound keeper allowlist is updated. Operational transparency event.
- `DelegationSessionUsed(user, delegate, actionType, permsUsed, refId, timestamp)`
  - Emitted when delegated config setters are used (see `DelegationActionTypes`: 41).
- `ShareholderClaimed(user, to, amount, mode)`
  - Emitted when a shareholder claim routes to an explicit recipient (`to`). Analytics MUST track both `ShareholderClaim` and `ShareholderClaimed` for complete claim accounting.
- `ShareholderBatchTerminatedEarly(processedUpTo, batchSize)`
  - Emitted when `compoundForMany` terminates before processing all users in a batch (insufficient gas for the next Furnace call).
- `UserCheckpointed(user, accrued)`
  - Emitted when a user's reward checkpoint is updated (accrued ETH recalculated).
- `DustSwept(to, amount)`
  - Emitted when accumulated dust ETH below the claimable threshold is swept.
- `RewardCheckpointCapReached(length)`
  - Emitted when the main reward checkpoint array reaches its 50,000-entry capacity and subsequent checkpoints begin routing to the overflow array.
- `OverflowCheckpointCapReached(length)`
  - Emitted when the overflow checkpoint array reaches its 50,000-entry capacity and begins operating as a ring buffer with FIFO eviction.
- `MinAutoCompoundEthSet(oldFloor, newFloor)`
  - Admin: emitted when the protocol-wide minimum auto-compound ETH floor is updated.
- `EthPushGasCapSet(oldCap, newCap)`
  - Admin: emitted when the per-call gas cap used by the ETH push payout path is updated. Operational transparency event; the cap bounds the gas forwarded into recipient `receive()` / `fallback()` to prevent griefing of the push step.
- `ClaimAllHelperChanged(oldHelper, newHelper)`
  - Admin: emitted when the ClaimAllHelper wiring is updated.

### Furnace

> **Delegatecall-emitted events:** `BonusPaid`, `LpOverflowDripPaid`, `LockSoldToFurnace`, `FurnaceMergeWithBonus`, and the three `EmergencyVaultRewire{Requested,Cancelled,Executed}` events are emitted from the Furnace address via `delegatecall` into `FurnaceGuardHelper` (EIP-170 bytecode relief). These events are declared in `IFurnace` (and additionally in `Events.sol` and `FurnaceGuardHelper` for `EmergencyVaultRewire*`) so they appear in Furnace's compiled ABI. Indexers decoding from the Furnace ABI will see them without needing to merge the `FurnaceGuardHelper` ABI. Topic0 parity across redeclarations is pinned in `test/InterfaceEventParity.t.sol`.

- `EntryTokenRegistrySet(registry)`
- `MineCoreChanged(oldMineCore, newMineCore)`
- `MineMarketChanged(oldMineMarket, newMineMarket)`
- `ShareholderRoyaltiesChanged(oldSR, newSR)`
- `LpRewardsVaultSet(oldVault, newVault)`
- `FurnaceQuoterSet(oldQuoter, newQuoter)`
  - Emitted when the Furnace quoter contract is changed. Administrative wiring event.
- `DelegationSessionUsed(user, delegate, actionType, permsUsed, refId, timestamp)`
- `FurnaceEnter(user, mode, ethIn, principalClaim, bonusClaim, tokenId)`
  - Clarification: in v1.0.0, `bonusClaim` is the **net** bonus the user receives (after the LP bonus split).
  - Dune chart helper (optional):
    - `impliedUserBonusBps = bonusClaim / principalClaim * 10_000` (realized net bonus rate per entry)
    - Used by `analytics/dune/panels/06_furnace_bonus_levels_7d.sql`
  - Calldata decoding required for token-entry:
    - For `FurnaceEnter` where `mode = ENTER_WITH_TOKEN`, decoders MUST recover `tokenIn` and `amountIn` from `Furnace.enterWithToken(address tokenIn, uint256 amountIn, ...)` calldata.
    - Decoders MUST join ERC20 `Transfer` logs in the same transaction and compute `amountInObserved` as the sum of transfers where `contract_address = tokenIn`, `from = user`, and `to = Furnace`.
    - Canonical value: `amountIn = amountInObserved` when `amountInObserved > 0`, else use the `amountIn` value from calldata.
- `BonusPaid(user, principal, principalEff, grossBonusClaim, userBonusClaim, lpTopupClaim, userSpotBonusBps, lpTopupRateBps, grossSpotBonusBps, quoteUserBonusBps, quoteLpTopupBps, lockDurationSec, reserveBefore, reserveAfter, virtualDepthBefore, virtualDepthAfter)`
  - Emitted when the bonus engine draws from `furnaceReserve` (one per entry that pays a bonus).
  - `principalEff` is the duration-weighted effective principal used in the AMM math (may differ from `principal`).
  - `lpTopupClaim` is the portion **funded into the Furnace LP rewards stream** (0 when LP split is disabled).
- `LpOverflowDripPaid(dripAmount, reserveBefore, reserveAfter, alphaBps, gateBps, capInflowPerDay, capFixedPerDay, reserveTarget, excessBefore)`
  - Emitted when the overflow drip **funds the Furnace LP rewards stream** (reserve accounting decreases; stream schedule increases).
  - The stream then drips to `LpStakingVault7D` over time; actual distribution pulses are visible via `LpStakingVault7D.LpRewardsNotified`.
- `LockSoldToFurnace(seller, tokenId, lockAmount, claimOut, spreadBps, cut, lpSaleShareBps, lpReward, reserveAdd, bonusRefBpsUsed)`
  - Emitted when a user sells a veCLAIM lock to the Furnace (sellback).
  - `lockAmount` is the underlying CLAIM principal withdrawn from the NFT.
  - `lpReward` is funded into the Furnace LP rewards stream (0 if LP rewards disabled).
  - `reserveAdd` is credited into `furnaceReserve`.

- `FurnaceMergeWithBonus(user, fromTokenId, intoTokenId, fromAmount, intoAmount, newPrincipal, newEnd, newAutoMax, durationDelta, bonusClaim)`
  - Emitted by `Furnace.mergeLocksWithBonus[For]` when two veCLAIM locks are combined.
  - **Indexed topics**: `user`, `fromTokenId`, `intoTokenId` (topic0 + 3 topics).
  - `fromTokenId` is burned; `intoTokenId` is the surviving lock and absorbs `fromAmount + intoAmount + bonusClaim`.
  - `newPrincipal == fromAmount + intoAmount + bonusClaim` (post-merge balance of the surviving lock).
  - `newEnd` is the survivor's `lockEnd` after merge: `block.timestamp + MAX_LOCK_DURATION` if `newAutoMax == true`, else `max(fromLockEnd, intoLockEnd)`.
  - `newAutoMax` follows the OR-rule (`fromAutoMax || intoAutoMax`); mixed AutoMax pairs are accepted (no `AutoMaxMismatch` revert on this path).
  - `durationDelta = longerRemaining - shorterRemaining`. When `durationDelta == 0` (both AutoMax, or both share the same effective remaining), `bonusClaim == 0` and the merge still goes through.
  - `bonusClaim` is the **net** user bonus deposited into `intoTokenId` via `addToLockFor` (after the LP-stream split applied inside `_applyBonusAmm`); the LP top-up portion is visible separately on the paired `BonusPaid` log.
  - Pairs with `BonusPaid` (one log per merge that pays a bonus) and with `VeClaimNFT.LockMerged(owner, fromTokenId, intoTokenId, amountMoved)` for ve-side state-transition tracking. `LockMerged` is the ve-side state-transition event; its `amountMoved` field reflects only `fromAmount` (not the bonus), so indexers MUST consume `FurnaceMergeWithBonus` for full economic context.

- `LpRewardsNotifyFailed(vault, amountClaim, revertData)`
  - Emitted when a `LpStakingVault7D.notifyRewards(amountClaim)` call reverts and is suppressed.
  - The CLAIM transfer still occurs; a later successful notify can reconcile via balance-delta.

- `LpStreamFunded(amountFunded, newRatePerSec, newPeriodFinish)`
  - Emitted on every LP stream re-fund after accrual rolls the remaining schedule forward.
  - Use this event to track the live Furnace LP stream schedule without replaying every `BonusPaid`, `LpOverflowDripPaid`, and `LockSoldToFurnace` delta.

- `ReserveCredited(amount, newReserve)`
- `ReserveClamped(caller, oldReserve, newReserve, claimBalance, lpStreamLiability)`
  - Emitted when reserve accounting would exceed the Furnace's backing CLAIM balance (excluding any remaining LP stream liability).
- `LockingPausedChanged(paused)`
- `AutoMaxBonusClaimed(user, tokenId, bonusClaim)`
  - Emitted by keeper calls that auto-extend ve locks with accrued bonus (mode 4 `EXTEND_WITH_BONUS`). Uses a separate event from `FurnaceEnter` to avoid activity-feed spam from keeper calls.
- `NearSlippageLimitEntry(user, tokenIdUsed, minVeOut, actualVeOut, marginBps)`
  - Emitted when a Furnace entry completes within a narrow margin (200 bps / 2.00%) of the user's `minVeOut`. Useful for monitoring slippage risk.
  - **Indexed topics**: `user`, `tokenIdUsed` (both indexed; topic0 + 2 topics).
  - **Canonical signature**: `tokenIdUsed` is the second indexed topic so per-lock filtering does not require scanning every entry. Pin against `test/SecurityCriticalConstantsPinned.t.sol::testNearSlippageLimitEntryTopic0Pinned`.
- `EmergencyVaultRewireRequested(vault, liability, executeAfter)`
  - Admin: emitted when an emergency LP vault rewire is requested (starts a timelock).
- `EmergencyVaultRewireCancelled()`
  - Admin: emitted when a pending emergency vault rewire is cancelled before execution.
- `EmergencyVaultRewireExecuted(oldVault, strandedAmount)`
  - Admin: emitted when an emergency vault rewire executes after the timelock elapses.
- `CarrySettlementFailed(vault, carry)`
  - Emitted when the carry settlement (accrued LP stream liability) to the LP vault reverts and is suppressed.
- `DelegationHubChanged(oldDelegationHub, newDelegationHub)`
  - Admin: emitted when the DelegationHub wiring is updated.

### LpStakingVault7D
- `LpStaked(user, amount)`
- `LpUnbondStarted(user, unbondId, amount, unlockTime)`
- `LpUnbondWithdrawn(user, unbondId, amount)`
- `LpRewardsNotified(amountClaim)`
  - Note: upstream funders may swallow `notifyRewards` reverts to avoid DoS. In that case you can observe CLAIM `Transfer` logs (Furnace → LP vault) without a matching `LpRewardsNotified` in the same tx; rewards will be accounted once a later notify succeeds (balance-delta accounting).
- `LpRewardsClaimed(user, amountClaim)`
- `LpRewardsLocked(user, amountClaim, principalClaim, bonusClaim, tokenId)`
  - Clarification: `bonusClaim` here refers to the Furnace net bonus (after LP cut), same as `FurnaceEnter.bonusClaim`.
- `AutoCompoundConfigured(user, enabled, tokenId, durationSeconds, maxSlippageBps, minRewardToCompound)`
- `AutoCompoundPaused(user, tokenId, reasonCode)`
- `HarvestKeeperSet(keeper, allowed)`
  - Emitted when the harvest keeper allowlist is updated. Administrative transparency event.
- `LpFeesHarvestedToRewards(caller, feeWeth, feeClaim, claimToRewards)`
- `DelegationSessionUsed(user, delegate, actionType, permsUsed, refId, timestamp)`
  - Emitted when delegated vault config setters are used (see `DelegationActionTypes`: 42).
- `NotifyAmountDivergence(declared, actualDelta)`
  - Emitted when `notifyRewards` detects a mismatch between the declared `amountClaim` and the actual balance delta. Indicates a possible accounting discrepancy from a prior suppressed notify.
- `AutoCompoundUnpaused(user)`
  - Emitted when a user's auto-compound is unpaused after a prior `AutoCompoundPaused`.
- `MinHarvestClaimFloorSet(oldFloor, newFloor)`
  - Admin: emitted when the minimum CLAIM output floor for harvest is updated.
- `MinCompoundRewardSet(oldFloor, newFloor)`
  - Admin: emitted when the minimum compound reward threshold is updated.
- `AccountedRewardBalanceClamped(requested, available)`
  - Emitted when the accounted reward balance is clamped to the actual CLAIM balance (defensive accounting).
- `HarvestMinClaimOutIgnored(minClaimOut)`
  - Emitted when a harvest skips the WETH→CLAIM swap because no WETH is available but a non-zero `minClaimOut` was specified.

### LaunchController (genesis finalization)
- `GenesisFinalized(timestamp, claimMinted, claimToLiquidity, lpMinted, pool, genesisLpVault)`
- `DeploymentValidated(claim, mineCore, genesisLpVault, guardian, expectedPool)`
  - Emitted when the deployment sanity checks pass during genesis setup.
- `SkimFailed(pool, reason)`
  - Emitted when the Aerodrome pool skim operation reverts during genesis finalization (suppressed; LP accounting proceeds).
- `SweepFailed(token, reason)`
  - Emitted when the post-genesis residual sweep transfer reverts, returns `false`, or returns malformed payload for the given token. The sweep is best-effort: a failed sweep does not block finalization or affect LP accounting. The `reason` payload is bounded to the first 128 bytes of the captured revert data via the controller's `_boundBytes` helper. Treat this as a benign post-genesis signal, not a payout-path event.
- `TokenSwept(token, to, amount)`
  - Emitted when residual tokens are swept from the LaunchController post-genesis.

### GenesisLPVault24M (required, genesis infrastructure)
- `Locked(lpAmount, lockStartTime, unlockTime)`
- `LockExtended(oldUnlockTime, newUnlockTime)`
- `WithdrawLp(to, amount)`
- `TokenRescued(token, to, amount)`
  - Emitted when `rescueEth()` recovers force-sent ETH from the vault (uses `address(0)` as token for ETH).
- `ResidualLpSwept(to, amount)`
  - Emitted when residual LP tokens (above the locked amount) are swept to the LP withdraw recipient.
- `FeesClaimedAndForwarded(address indexed token0, address indexed token1, uint256 amount0Forwarded, uint256 amount1Forwarded)`
  - Emitted from inside `withdrawLp()` when the vault claims accumulated Aerodrome trading fees from `pool.claimFees()` and forwards them to the immutable `lpWithdrawRecipient` before the LP transfer.
  - Fired only when at least one of `amount0Forwarded` / `amount1Forwarded` is strictly greater than zero.
  - Always precedes the corresponding `WithdrawLp(to, amount)` (canonical post-unlock branch) or `ResidualLpSwept(to, amount)` (residual-LP branch) in the same transaction.
  - `token0` / `token1` are pool-defined and Aerodrome-immutable (`token0 < token1` ordering by address); resolve which side is CLAIM vs WETH by comparing against the pinned CLAIM token address.

### DelegationHub (bot sessions)
- `SessionSet(user, delegate, perms, expiry)`
  - `perms` is the delegated permission bitmask.
  - `expiry` is a unix timestamp in seconds. `expiry = 0` is immediately expired, not active.
  - Revoke is represented by `perms = 0` and `expiry = 0`.
- `NonceIncremented(user, newNonce)`
  - Emitted when a user increments their delegation nonce (mass-revoke of all outstanding off-chain signatures).

### ClaimAllHelper
- `DelegationSessionUsed(user, delegate, actionType, permsUsed, refId, timestamp)`
  - Emitted when delegated claim helpers are used (see `DelegationActionTypes`: 10–12).
- `KingWithdrawalFailed(user, reason)`
  - Emitted when a king ETH withdrawal fails during a claim-all operation (suppressed; remaining claims proceed).

### MaintenanceHub (ops / automation)
- `Poked(caller, checkpointOk, flushOk, offersAttempted, offersSucceeded, furnaceTickSucceeded, bountyWethForwarded)`
- `TokenRescued(token, to, amount)`
  - Emitted when a stuck ERC20 token is rescued from the MaintenanceHub.

Clarification (non-binding):
- Decode from the **MaintenanceHub** address in `deployments/base_mainnet.json`.
- `checkpointOk` is true when `checkpointGlobalState()` succeeded.
- `flushOk` is true when `flushPendingShareholderETH()` succeeded.
- `furnaceTickSucceeded` is true if the Furnace tick call succeeded.
- `bountyWethForwarded` is denominated in WETH wei.

### MarketRouter (lock management)

**Strict mode invariant (Furnace-only lock trading):**
- The **Furnace is the only counterparty** for lock purchases.
- There are **no user-to-user lock sales**.

Events:
- `LockListed(tokenId, seller, minClaimOut, listedAtTime, expiresAtTime)` — listing created (limit sell to Furnace)
- `LockDelisted(tokenId, seller, reason)` — listing removed
- `ListingSettled(tokenId, seller, claimOut, penalty)` — Furnace settled a listing (spec-required event)
- `BonusTargetEscrowCreated(escrowId, buyer, discountBps, durationSeconds, createAutoMax, expiresAt, destinationLockId, budgetClaim, createdAt)`
- `BonusTargetEscrowConfigured(escrowId, buyer, targetBonusBps, slippageBps)` — bonus target configured for escrow execution (includes slippage tolerance)
- `BonusTargetEscrowCancelled(escrowId, buyer, refundClaim)`
- `BonusTargetEscrowExpired(escrowId, buyer, refundClaim)`
- `BonusTargetEscrowExpiryExtended(escrowId, buyer, oldExpiresAt, newExpiresAt)`
- `BonusTargetEscrowExecuted(escrowId, buyer, claimIn, principalClaim, bonusClaim, veOut, routeTokenId, furnaceTokenId)` — canonical generic execution receipt
- `BonusTargetEscrowAutoFurnaceExecuted(escrowId, buyer, claimIn, principalClaim, bonusClaim, veOut, routeTokenId, furnaceTokenId)` — back-compat/detail companion receipt
- `MarketSellToFurnace(tokenId, seller, minClaimOut, deadline, claimOut)`
  - Emitted when a lock is sold directly to the Furnace via the MarketRouter (non-listing path). Analytics MUST include this alongside `ListingSettled` for complete market volume accounting.
- `BonusTargetEscrowParamsChanged(oldMinBudget, newMinBudget, oldMaxDiscountBps, newMaxDiscountBps)`
  - Emitted when bonus target escrow parameters are changed. Administrative transparency event.
- `SettlementKeeperSet(keeper, allowed)`
  - Emitted when the settlement keeper allowlist is updated. Administrative transparency event.
- `TradingPausedChanged(paused)`
- `DestinationLockIneligible(offerId, destinationLockId)`
  - Emitted when a bonus target escrow's destination lock is no longer eligible at execution time (expired, transferred, etc.).

Note:
- All settlements are Furnace settlements. There are no user-to-user fill events.
- Bonus target escrow execution routes into the Furnace, not into buying user locks.
- `executeAutoFurnace` emits both execution receipts in the same tx. Canonical execution accounting SHOULD key off `BonusTargetEscrowExecuted` and treat `BonusTargetEscrowAutoFurnaceExecuted` as a companion join/detail receipt to avoid double counting.

Constraints (required):
- Indexers MUST decode Market events from the **MarketRouter** proxy address (stable across upgrades).
- Bonus target escrow executions MUST be reflected as a normal `FurnaceEnter` with `mode = ENTER_WITH_CLAIM` (no new enum value required).
- Indexers MUST use the MarketRouter ABI on the MarketRouter address for decoding.

### Common admin transparency (required)
- `GuardianChanged(oldGuardian, newGuardian)`
- `ConfigFrozen()`
- `OwnershipTransferStarted(previousOwner, newOwner)` (OpenZeppelin `Ownable2Step`)
- `OwnershipTransferred(previousOwner, newOwner)` (OpenZeppelin `Ownable`)

Clarification:
- `GuardianChanged` and `ConfigFrozen` are declared in `src/lib/Events.sol`.
- `OwnershipTransferStarted` and `OwnershipTransferred` are standard OpenZeppelin ownership events (emitted by contracts that use `Ownable2Step`).

Constraint (required):
- Implementations MUST emit the relevant events from the relevant functions.

## Dune reality check: views are not a data source

Dune dashboards should not rely on calling view functions like `getFurnaceState()`.

If you need “current state” style panels:
- Use “latest event” patterns (pause toggles, routing/registry config set, guardian changed).
- Use deterministic formulas driven by events (example: takeover price from last `Takeover`).

## Reward and royalty datasets (off-chain)

These off-chain (UI/indexer/Dune) datasets describe reward and royalty flows in native terms. The official UI does not surface APR/veAPR/APY.

LP Staking Vault reward inputs:
- LP vault reward funding events:
  - `LpRewardsNotified(amountClaim)`
  - Note: upstream funders may swallow `notifyRewards` reverts to avoid DoS. In that case you can observe CLAIM `Transfer` logs (Furnace → LP vault) without a matching `LpRewardsNotified` in the same tx; rewards will be accounted once a later notify succeeds (balance-delta accounting).
- LP vault stake state events:
  - `LpStaked`, `LpUnbondStarted` (and `LpUnbondWithdrawn` for unbond tracking)
- Canonical CLAIM/WETH pool:
  - reserves snapshots (`Sync` events or periodic `getReserves()` snapshots)
  - `totalSupply()` snapshots
- Pricing primitives:
  - ETH/USD (Chainlink)
  - CLAIM/ETH TWAP (30m) from canonical CLAIM/WETH pool (to derive CLAIM/USD)

Baron royalty inputs:
- `shareholderEthAllocated24h` uses `ShareholderTakeoverAllocation.amountEth` summed over the last 24h.
- Total locked CLAIM is derived from ve lock events (`LockCreated` / `LockAmountIncreased` / `LockUnlocked`).
