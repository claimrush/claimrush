# Events and Indexing

Solidity events are the primary data source for subgraphs, analytics UIs (Dune), push notifications, and achievement systems. This page lists the canonical event tables by contract and the tooling you need to index them.

## Canonical sources

| What | Where |
|------|-------|
| Event signatures | `src/lib/Events.sol` (plus contract-local events like `DelegationHub.SessionSet`) |
| Decoding rules | `docs/analytics/dune-integration-pack-v1.0.0.md` |
| ABIs | `abis/<network>/*.abi.json` |
| Addresses | `deployments/<network>.json` |
| Runtime watcher set | Event families documented on this page and in `docs/analytics/dune-integration-pack-v1.0.0.md` |

**Rule:** Filter logs by `evt_block_number >= startBlock`.

## Public subgraph endpoint

ClaimRush does not operate a single public subgraph URL. Indexers and analytics consumers run the shipped subgraph against their own The Graph node or self-hosted Graph Node. The canonical manifest, schema, mappings, and deploy commands live under `subgraph/` and are reproducible from this repo. The Dune integration pack at `docs/analytics/dune-integration-pack-v1.0.0.md` is the second source-of-truth for the same event vocabulary.

## Event codebooks (immutable)

| Enum | Values |
|------|--------|
| `ShareholderClaim.mode` | 0=ETH, 1=LOCK_FURNACE |
| `AutoCompoundPaused.reasonCode` | 1=NOT_OWNER, 2=LISTED, 3=EXPIRED, 4=INVALID_TOKEN_ID, 5=FURNACE_REVERT, 6=QUOTE_FAILED, 7=CHECKPOINT_FAILED (also used by `ShareholderAutoCompoundPaused`) |
| `KingAutoLockSkipped.reasonCode` | 1=NOT_OWNER, 2=LISTED, 3=EXPIRED, 4=INVALID_TOKEN_ID, 5=INVALID_DURATION, 0xFF=GAS_PRECHECK |
| `FurnaceEnter.mode` | 0=ENTER_WITH_ETH, 1=ENTER_WITH_CLAIM, 2=LOCK_FURNACE, 3=ENTER_WITH_TOKEN, 4=EXTEND_WITH_BONUS |
| `LockDelisted.reason` | 0=NORMAL, 1=EMERGENCY, 2=SOLD_INTO_OFFER (reserved; not emitted), 3=SOLD_TO_FURNACE, 4=EXPIRED, 5=APPROVAL_REVOKED (reserved; not emitted) |
| `DelegationSessionUsed.actionTypeId` | 1=TAKEOVER_FOR; 2=MINECORE_SET_REIGN_RECIPIENTS (coarse `actionType` enum: `REIGN_RECIPIENTS`); 10-12=CLAIM; 20-22=FURNACE_ENTER; 30-32=VE_LOCK; 40-42=CONFIG (see `docs/manuals/developer/delegationhub.md`) |

## Key event groups

This list is intentionally **not exhaustive**. It highlights the events most commonly consumed by UIs/indexers; treat `src/lib/Events.sol` as the source of truth.

**MineCore:** EntryTokenRegistrySet, FurnaceChanged, Takeover, ReignRecipientsSet, ReignFinalized, TakeoversPausedChanged, KingWithdrawal (+ KingWithdrawalTo), KingEthCredited, KingEthPaid, KingClaimCredited, PendingClaimWithdrawn, Refund* (RefundCredited, RefundWithdrawn), ShareholderRoyaltiesTakeoverFailed, ShareholderRoyaltiesFlushFailed, KingAutoLock*, DelegationSessionUsed

**DelegationHub / Delegation:** SessionSet (covers create, update, and revoke as a single state-transition; revocation is a `SessionSet` with `expiry == 0`), NonceIncremented (paired with every nonce-bumping session transition: `setSession`, `revokeSession`, `setSessionBySig`), DelegationSessionUsed (emitted by the consuming contract — `MineCore`, `Furnace`, `VeClaimNFT`, `LpStakingVault7D`, `ShareholderRoyalties`, `ClaimAllHelper`, `FurnaceGuardHelper` — when a session is actually exercised; this event does NOT live on `DelegationHub`). Indexer note: the same `DelegationSessionUsed` selector is shared across every consuming contract, so any `(topic0)` -> ABI map MUST scope the lookup by `(contract, topic0)` to avoid collapsing the per-surface decode entries into a single row. The shipped event-watcher composite-keys its decode index by `(contract, topic0)` and admits the `ClaimAllHelper` address into its allowlist so the harvest-claim use-side delegation activity (`P_SHAREHOLDER_CLAIM_FOR`, `P_LP_CLAIM_FOR`) is observed alongside the rest.

**VeClaimNFT:** FurnaceChanged, MineMarketChanged, LockCreated, LockExtended, LockAmountIncreased, LockMerged, LockUnlocked, AutoMaxSet, Transfer (burn/transfer tracking), DelegationSessionUsed, SlopeDriftClamped, ShareholderCheckpointFailed

**ShareholderRoyalties:** ShareholderWiringSet, ShareholderTakeoverAllocation, ShareholderFlush, ShareholderClaim (emitted on every ETH/lock collect path), ShareholderAutoCompound*, RewardCheckpointCapReached, OverflowCheckpointCapReached, DelegationSessionUsed (emitted only on the delegated `setAutoCompoundConfigForUser` path; the helper-only `claimShareholderFor` is gated by `onlyClaimAllHelper` rather than delegation and does NOT emit it), DustSwept, OldestObservedNonAutoMaxLockEndSet, ShareholderClaimed

**Furnace:** MineCoreChanged, MineMarketChanged, ShareholderRoyaltiesChanged, FurnaceEnter, NearSlippageLimitEntry†, FurnaceMergeWithBonus†, AutoMaxBonusClaimed, BonusPaid†, LpOverflowDripPaid†, LockSoldToFurnace†, LpStreamFunded, ReserveCredited, ReserveClamped, FurnaceQuoterSet, LpRewardsVaultSet, LpRewardsNotifyFailed, LockingPausedChanged, EmergencyVaultRewireRequested†, EmergencyVaultRewireCancelled†, EmergencyVaultRewireExecuted†, DelegationHubChanged, DelegationSessionUsed (emitted both directly from Furnace and via delegatecall from `FurnaceGuardHelper` on `*For` variants — see †)

> † These events are emitted from the Furnace address via `delegatecall` into `FurnaceGuardHelper` (EIP-170 bytecode relief). They are declared in `IFurnace` (or `Events.sol`) so they appear in Furnace's compiled ABI and can be decoded by block explorers and indexers without merging a secondary ABI. Topic0 hashes match the standard signatures and are pinned in `test/SecurityCriticalConstantsPinned.t.sol`.

> **`NearSlippageLimitEntry(address indexed user, uint256 indexed tokenIdUsed, uint256 minVeOut, uint256 actualVeOut, uint256 marginBps)`** — emitted when a Furnace entry settles within 200 bps (2.00%) of the user-supplied `minVeOut`. Both `user` and `tokenIdUsed` are `indexed`, so MEV / keeper tooling can filter per-user or per-lock without scanning the full event stream. The `tokenIdUsed` topic is the destination veCLAIM lock id — for new locks, the minted token id (after entry); for add-to-lock entries, the existing lock id.

**LpStakingVault7D:** LpStaked, LpUnbondStarted, LpUnbondWithdrawn, LpRewardsNotified, LpRewardsClaimed, LpRewardsLocked, HarvestKeeperSet, AutoCompound*, LpFeesHarvestedToRewards, DelegationSessionUsed

**MarketRouter:** LockListed (limit sell / Market listing: minClaimOut + expiresAtTime), LockDelisted, ListingSettled, MarketSellToFurnace, SettlementKeeperSet, BonusTargetEscrowParamsChanged, TradingPausedChanged, BonusTargetEscrow* (limit buy / Buy intent: Created, Configured, Executed, AutoFurnaceExecuted, Expired, Cancelled, ExpiryExtended)

**MaintenanceHub:** Poked (includes `checkpointOk`, `flushOk`, and `furnaceTickSucceeded` boolean flags indicating whether the ve checkpoint, shareholder flush, and Furnace tick each landed cleanly), TokenRescued

**Genesis:** GenesisFinalized, SkimFailed (bounded revert data from failed pool skim), Locked, LockExtended, WithdrawLp (`to` is `indexed`), ResidualLpSwept (`to` is `indexed`), FeesClaimedAndForwarded (`token0` and `token1` are `indexed`), TokenRescued

## Decoding notes

- **Reign recipients:** `ReignRecipientsSet(reignId, king, ethRecipient, claimRecipient)` can be emitted mid-reign. `king` is the active reign identity whose routing changed, not the transaction caller. Use it to track where the dethroned-King 75% ETH payout and the King-stream CLAIM are routed.
- **Auto-compound pause reasons:** the `reasonCode` codebook is shared across `AutoCompoundPaused` and `ShareholderAutoCompoundPaused`. MineCore’s `KingAutoLockSkipped` uses a separate codebook because reason `5` means `INVALID_DURATION`, not `FURNACE_REVERT`.
- **MineCore king withdrawals:** `KingWithdrawal(user, amount)` is always emitted. `KingWithdrawalTo(user, to, amount)` is emitted only when ETH was successfully delivered to `to` (not on fallback to `user`). If `to` rejects ETH and differs from `user`, MineCore retries delivery to `user`; in that case only `KingWithdrawal` fires.
- **King ETH payout success:** `KingEthPaid(recipient, amount)` fires when the dethroned-King ETH payout push succeeds during a takeover.
- **King ETH payout fallback:** `KingEthCredited(recipient, amount)` fires when the best-effort dethroned-King payout push (bounded gas stipend) fails during a takeover. The ETH is credited to `kingEthBalance[recipient]` for pull withdrawal via `withdrawKingBalance()`.
- **Pending CLAIM withdrawal:** `PendingClaimWithdrawn(user, to, amount)` fires when a user (or ClaimAllHelper on their behalf) withdraws pending CLAIM from `pendingClaimBalance` (credited when the auto-lock path skips or fails during a reign settlement).
- **Furnace reserve credit failure event:** `FurnaceCreditReserveFailed(furnace, amount, reason)` is declared in `src/lib/Events.sol` and exported in the ABI, but MineCore v1.0.0 currently reverts with `Errors.InvariantViolation()` if `Furnace.creditReserve(amount)` fails during a takeover. Do not expect live logs for this event in the shipped runtime.
- **LP Harvest & Lock:** `LpRewardsLocked.tokenId` is the actual destination lock id returned by `Furnace.enterWithClaimFor`. If a new lock is minted, this is the minted token id (not the quote placeholder `0`).
- **LP auto-compound heuristic:** `LpRewardsLockedEvent.autoCompounded` in the subgraph is derived from the top-level `tx.input` selector (matching `compoundFor`/`compoundForMany`). If the auto-compound is routed through an intermediary contract (e.g., MaintenanceHub or another batching proxy), the heuristic returns `false` because the subgraph cannot see internal calldata. Consumers that need reliable auto-compound attribution should cross-reference with the executor address or the upstream `AutoCompoundConfigured` state.
- **Reserved delist reasons:** `SOLD_INTO_OFFER` (`2`) and `APPROVAL_REVOKED` (`5`) exist in the analytics codebook but the strict-mode router does not emit them. Production indexers should expect live `LockDelisted.reason` values of `NORMAL`, `EMERGENCY`, `SOLD_TO_FURNACE`, and `EXPIRED`.
- **Royalties hardening:** If ShareholderRoyalties errors during takeover, MineCore emits:
  - `ShareholderRoyaltiesTakeoverFailed(reignId, amountEth, reason)` when `onTakeover` reverts (ETH is held in MineCore.shareholderEthPending for retry)
  - the same `ShareholderRoyaltiesTakeoverFailed(...)` event is also emitted if `retryPushShareholderEth()` later fails; in that retry path `reignId = 0` and `amountEth` is the retried pending bucket
  - `ShareholderRoyaltiesFlushFailed(reason)` when `flushPendingShareholderETH` reverts (ETH remains in ShareholderRoyalties.pendingShareholderETH for later flush)
  - `reason` contains bounded revert data (up to 128 bytes) via `_boundedRevertData()`. Indexers can decode standard revert selectors from this field.
- **Baron auto-compound failures:** `ShareholderAutoCompoundFailed(user, amountEth, tokenId)` fires when the downstream `Furnace.lockEthReward(...)` call reverts during auto-compound, or when the quote call fails in `compoundForMany`. The user's ETH remains in ShareholderRoyalties (their `claimableEth` balance is unchanged). For Furnace reverts, `ShareholderAutoCompoundPaused` is also emitted with a reason code indicating the failure type. For quote failures in the batch path (`compoundForMany`), the user is **skipped** (not paused), so retry is automatic on the next cadence. Keepers should surface `ShareholderAutoCompoundFailed` events for operator alerting.
- **King auto-lock failures:** `KingAutoLockFailed.revertData` is not generic downstream revert data. MineCore emits selector-encoded `Errors.ZeroAddress` / `Errors.WiringMismatch` for pre-call fail-closed cases. If the downstream Furnace call itself reverts, `revertData` contains bounded revert data (up to 128 bytes) via `_boundedRevertData()`.
- **Furnace LP stream:** `BonusPaid.lpTopupClaim`, `LpOverflowDripPaid.dripAmount`, and sellback `lpReward` all re-fund the stream schedule. Each re-fund emits `LpStreamFunded(amountFunded, newRatePerSec, newPeriodFinish)`. Stream accrual later transfers CLAIM to the LP vault and attempts `notifyRewards(...)`; successful notifies emit `LpRewardsNotified`, while failed notifies emit `LpRewardsNotifyFailed(vault, amountClaim, revertData)`. In v1.0.0 that `revertData` field is emitted as empty bytes for hardening, and the vault can later reconcile the same CLAIM via balance-delta on a successful notify or fee harvest. The subgraph persists immutable `LpStreamFundedEvent` rows and mirrors the latest schedule onto `FurnaceState.lpStreamRatePerSec` / `FurnaceState.lpStreamPeriodFinish`.
- **enterWithToken:** FurnaceEnter doesn't include tokenIn/amountIn; recover from calldata or ERC20 Transfer logs. For internal calls (Safe / smart account / helper / batch) where the top-level `tx.input` is not a Furnace function, calldata decoding returns null. The shipped subgraph mapping in `subgraph/src/mappings/furnace.ts` (function `deriveTokenEntryFromReceipt`) walks the transaction receipt and selects the LATEST ERC20 `Transfer` event into the Furnace address (excluding CLAIM) strictly preceding the `FurnaceEnter` log as the `(tokenIn, amountInWei)` attribution. The "latest preceding" choice is deliberate so a batched transaction containing multiple `FurnaceEnter` calls attributes each event to its own immediately-preceding entry-side `safeTransferFrom`. Third-party indexers reproducing the schema MUST follow the same receipt-derivation rule for `MODE_ENTER_WITH_TOKEN` rows reached through internal calls, or per-token volume aggregates will silently miss those entries.
- **TxFurnaceEnter join key:** the indexer-side join entity that links auto-furnace `BonusTargetEscrowExecuted` receipts back to their underlying `FurnaceEnter` log uses an `id` of `${txHash}-${logIndex}` and carries the `logIndex` field. Per-`(txHash, user)` keying would collapse batched helper / maintenance transactions that emit multiple `FurnaceEnter` events for the same buyer; keying by log identity disambiguates the siblings so the auto-furnace fallback (when `furnaceTokenId == 0` on the execution event) selects the correct preceding `FurnaceEnter` row by largest `logIndex < execution.logIndex`. The auto-furnace handlers in the shipped subgraph (`handleBonusTargetEscrowExecuted`, `handleBonusTargetEscrowAutoFurnaceExecuted`) request `receipt: true` on their event handlers so the receipt walk can resolve the sibling log.
- **EntryTokenRegistry:** MineCore and Furnace emit `EntryTokenRegistrySet` independently.
- **Reserved event names (not declared in v1.0.0):** `MarketLockRetargeted` and `MarketLockAbsorbed` are reserved names for MineMarket lock retargeting/absorption functionality. They are not declared in `src/lib/Events.sol`, not emitted by any contract, not present in shipped ABIs, and not indexed by the subgraph. No indexer or application action is required in v1.0.0.
- **Protocol wiring singleton:** `Protocol.mineCore`, `Protocol.marketRouter`, `Protocol.furnace`, and `Protocol.shareholderRoyalties` represent the latest observed current wiring inside the indexed event surface, not one-time seeds. Canonical update receipts are `MineCore.FurnaceChanged`, `VeClaimNFT.FurnaceChanged`, `VeClaimNFT.MineMarketChanged`, `Furnace.MineCoreChanged`, `Furnace.MineMarketChanged`, `Furnace.ShareholderRoyaltiesChanged`, and `ShareholderRoyalties.ShareholderWiringSet`. Note: `DelegationHub`, `ClaimAllHelper`, `DexAdapter`, `ClaimToken`, `AgentLens`, `FurnaceQuoter`, and `MineCoreQuoter` have no wiring-update events indexed (DexAdapter, ClaimToken, FurnaceQuoter, MineCoreQuoter, and AgentLens are not subgraph datasources at all).
- **ve snapshot semantics:** `User.veBalanceWei` and `VeLock.currentVeWei` in the shipped subgraph are event-driven snapshots. They do not continuously decay between unrelated events. Application/API consumers that need “ve now” MUST recompute from `amountWei`, `lockEnd`, and `autoMax` against the same payload's `_meta.block.timestamp` when available, or use the derived leaderboard/snapshot job. For per-user surfaces, that lock list MUST be the full owner snapshot, fetched via paginated `tokenId` cursor reads at one pinned head, not a capped `first: N` owner query. Wall-clock fallback is acceptable only when `_meta` is unavailable.
- **AutoMax indexing invariant:** `VeClaimNFT.setAutoMax(tokenId, enabled)` rewrites `lockEnd = block.timestamp + MAX_LOCK_DURATION` on every flag-state change AND on the same-state enable refresh path, regardless of direction (enable or disable). The emitted event `AutoMaxSet(address indexed user, uint256 indexed tokenId, bool autoMax)` does not carry the new `lockEnd` in its payload; indexers consuming `AutoMaxSet` MUST refresh both the `autoMax` flag AND the persisted `lockEnd` (set to `event.block.timestamp + MAX_LOCK_DURATION`) on every event — never only on enable, never only on flag-direction transitions. The shipped subgraph mapping in `subgraph/src/mappings/veClaimNFT.ts` (`handleAutoMaxSet`) is the canonical batch-indexer reference; live UI / WebSocket reducers MUST follow the same invariant. Third-party indexers reproducing the schema MUST follow the same rule, or downstream extend / merge calldata generators will compute against stale `lockEnd` and surface as `InvariantViolation` at execution time.
- **Delegation sessions:** `DelegationSessionUsed.actionTypeId` is a numeric code (not an enum). `refId` meaning depends on the action. See `docs/manuals/developer/delegationhub.md`. Raw `actionTypeId` is canonical; the shipped coarse subgraph enum in `subgraph/src/utils/delegation.ts` maps `actionTypeId = 2` (`MINECORE_SET_REIGN_RECIPIENTS`) to `REIGN_RECIPIENTS`. Security-session UIs MUST derive active vs expired from the same payload's `_meta.block.timestamp`, not wall clock. A session is active iff `perms > 0` and `expiry >= _meta.block.timestamp`; `expiry = 0` is immediately expired, not active. Radar-style delegation/reign-recipient alert polling MUST page forward from a pinned `(blockNumber,id)` cursor at one `_meta` head or fail closed; a capped `first: N` recent-events query plus local seen-ID diff is a correctness bug because it can silently miss alerts.
- **Listing state:** veNFTs do not emit dedicated "listed/frozen" events. Use MarketRouter events (`LockListed`, `LockDelisted`, `ListingSettled`) to index listing lifecycle.
- **Auto-furnace execution receipts:** `executeAutoFurnace` emits both `BonusTargetEscrowExecuted` and `BonusTargetEscrowAutoFurnaceExecuted` in the same tx. Treat the generic `BonusTargetEscrowExecuted` receipt as canonical execution accounting; the auto-furnace-specific receipt is a detail companion. The shipped subgraph intentionally emits the `ActivityItem` only from the `BonusTargetEscrowAutoFurnaceExecuted` handler to avoid duplicate activity rows. If a different execution path emits only the generic receipt (without the companion), activity feed consumers would silently miss the event.
- **Offer history rows:** the subgraph writes `BonusTargetEscrowEvent.kind = FILLED` from the generic execution receipt. `AUTO_FURNACE_EXECUTED` is retained as the same-tx companion row for detail consumers, so history UIs SHOULD filter or dedupe companion rows to avoid showing one fill twice.
- **Destination lock fallback:** `DestinationLockIneligible(offerId, destinationLockId)` fires during `executeAutoFurnace` when the buyer's requested destination lock is no longer eligible (expired, transferred, or delisted) and execution falls back to creating a new lock. Indexers should surface this for keeper/buyer alerting.
- **Genesis LP fee forwarding:** `GenesisLPVault24M.FeesClaimedAndForwarded(token0, token1, amount0Forwarded, amount1Forwarded)` is emitted from inside `withdrawLp()` when the vault claims accumulated Aerodrome trading fees from `pool.claimFees()` and forwards them to the immutable `lpWithdrawRecipient` before the LP transfer. Emission semantics for indexers: (a) the event fires **only** when at least one of `amount0Forwarded` / `amount1Forwarded` is strictly greater than zero — a zero-fee withdrawal does not emit it; (b) when emitted, it always precedes the corresponding `WithdrawLp(to, amount)` event (canonical post-unlock branch) or `ResidualLpSwept(to, amount)` event (residual-LP branch) in the same transaction; (c) `token0` and `token1` are pool-defined and Aerodrome-immutable (`token0 < token1` ordering). Subgraph indexers should treat the fee event as a sibling row to `GenesisWithdrawLpEvent` — both belong to the same on-chain withdrawal action and downstream dashboards should aggregate them per `txHash` for "what did the recipient actually receive at unlock".

## Protocol status log

Governance events (pauses, freezes, ownership transfers, guardian changes, genesis finalization) are suitable inputs for a protocol status surface.

Integrators should use the subgraph for event data.

Watched governance events include: `TakeoversPausedChanged`, `LockingPausedChanged`, `TradingPausedChanged`, `ConfigFrozen`, `OwnershipTransferStarted`, `OwnershipTransferred`, `GuardianChanged`, `GenesisFinalized`, and wiring/emergency events.

Filtered events (excluded from the status log):
- `OwnershipTransferred` where `previousOwner` is `address(0)` (initial deployment ownership assignment)
- `GuardianChanged` where `previousGuardian` is `address(0)` (initial guardian setup)
- Any event whose `status` field is set and is not `'confirmed'` (i.e. `pending` or `reorged` deliveries) — only confirmed lifecycle transitions enter the durable status log, so a reorged pause / guardian / ownership / wiring event cannot leave a stale entry behind. Pre-confirmation pending updates are also skipped to keep the status log strictly final.

## Indexing strategy

- Use shipped ABIs as single decoding input; subgraph manifests MUST reference the exported `abis/<network>/*.abi.json` files directly rather than maintaining separate event-only ABI copies alongside the manifests.
- Prefer event-driven state (e.g., LockCreated/Extended/Unlocked for lifecycle)
- Storage reads only for spot UI/API values
- Follow `docs/analytics/metrics-canon-v1.0.0.md` for metrics
- Leaderboards: `docs/analytics/indexer-and-dune-implementation-guide-v1.0.0.md`
- Manifest drift checks: `make subgraph-manifest-sync-check` (or `python3 scripts/sync_subgraph_manifest_from_deployments.py --check ...`)
- Runtime readiness checks: `make subgraph-live-runtime-readiness-check`
- Consumer/API responses MUST use a single indexed head for each response.
- ABI coverage checks: `python3 scripts/check_subgraph_manifest_events_vs_abi.py subgraph/subgraph.yaml ...`
- Mutable wiring semantic checks: `python3 scripts/check_subgraph_protocol_wiring_semantics.py`
- Docs event-checklist parity checks: `python3 scripts/check_subgraph_doc_event_checklist.py`
- Codegen/build layout checks: `python3 scripts/check_subgraph_codegen_layout.py`
- Manifest entity completeness checks: `python3 scripts/check_subgraph_manifest_entities.py subgraph/subgraph.yaml ...`
- Derived event-kind parity checks: `python3 scripts/check_subgraph_derived_event_kinds.py`
- If you maintain a query allowlist for a consumer or proxy, keep it in sync with the deployed query set and review interpolated templates manually.
- Local subgraph caveat: the local/default manifests (`subgraph/subgraph.local.yaml` and `subgraph/subgraph.yaml` when pointed at `deployments/local.json`) intentionally omit the Furnace block handler. On local graph-node setups, bonus quote snapshots only advance on Furnace bonus/reserve-affecting events, so idle-period quote history can look stale until the next relevant event.

## Intentionally unindexed ABI events

The following ABI events are intentionally NOT handled by the subgraph because they are admin/ownership/approval lifecycle events that do not affect the product UI or analytics. Additionally, five ABI-exported contracts (AgentLens, ClaimToken, DexAdapter, FurnaceQuoter, MineCoreQuoter) are not subgraph datasources; their events are not indexed because those contracts either have zero events (AgentLens, FurnaceQuoter, MineCoreQuoter) or only emit admin/ownership events (DexAdapter) or wiring events already redundantly covered by other indexed contracts (ClaimToken.MineCoreChanged):

`ConfigFrozen` (ClaimToken, Furnace, MineCore, VeClaimNFT, ShareholderRoyalties), `GuardianChanged` (Furnace, MineCore, MarketRouter), `OwnershipTransferStarted` / `OwnershipTransferred` (7 contracts), `Approval` / `ApprovalForAll` (VeClaimNFT), `EIP712DomainChanged` (DelegationHub), `ClaimAllHelperChanged` (MineCore, ShareholderRoyalties), `DelegationHubChanged` (MineCore, Furnace), `DustSwept` (ShareholderRoyalties — owner-only sub-wei rounding dust recovery), `RewardCheckpointCapReached` / `OverflowCheckpointCapReached` (ShareholderRoyalties — operational monitoring for checkpoint array growth), `EmergencyVaultRewireCancelled` / `EmergencyVaultRewireExecuted` / `EmergencyVaultRewireRequested` (Furnace — guardian emergency LP vault rewire lifecycle; ops history only), `DestinationLockIneligible` (MarketRouter — swap routing rejects ineligible ve lock destination; no subgraph entity state), `MetadataUpdate` / `BatchMetadataUpdate` / `BaseURISet` / `ContractURISet` / `ContractURIUpdated` (VeClaimNFT — ERC-4906/ERC-7572 metadata signals for wallets and marketplaces; admin-only URI setters). This list is informational and reflects the current subgraph manifest coverage. There is no automated CI gate that enforces "ABI event ⇒ subgraph handler" parity in v1.0.0; `scripts/check_subgraph_manifest_events_vs_abi.py` only validates that manifest event-handler signatures match the ABI, and `scripts/check_subgraph_doc_event_checklist.py` only validates the analytics checklist in `docs/analytics/subgraph-schema-v1.0.0.md` against shipped ABIs and manifests. To verify which ABI events the subgraph indexes, treat the committed `subgraph/subgraph.yaml` (and per-network siblings) as the source of truth.

## Agent tooling

Repo tooling for offchain agents lives in `agents/sdk/`. It includes:
- `getGameStateSnapshot({ publicClient, manifest, ... })` (AgentLens-first, multicall fallback)
- JSONL event streamer (RPC logs, optional subgraph backfill)
- subgraph lag/core event-derived address parity checker

Run the streamer:

```bash
RPC_URL=...
npm -C agents/sdk run example:events
```

Backfill recent history from the subgraph before live RPC logs:

```bash
RPC_URL=...
SUBGRAPH_URL=...
npm -C agents/sdk run example:events -- --backfill --backfill-limit 100
```

Validate subgraph health + core/event-derived address parity:

```bash
RPC_URL=...
SUBGRAPH_URL=...
npm -C agents/sdk run example:subgraph-health -- --pretty
```

## Keeper event-driven cadence

Since v1.1.0 the ClaimRush keeper can subscribe over WebSocket to the on-chain events that invalidate its "hot" task state, so those tasks run almost immediately after the triggering event instead of waiting for a polling cadence. The subscribed set is deliberately narrow — every signature listed here also appears in the matching keeper task, and is the canonical trigger for that task:

| Keeper task       | Contract     | Event signatures                                                                                                                     |
| ----------------- | ------------ | ------------------------------------------------------------------------------------------------------------------------------------ |
| `poke`            | MineCore     | `Takeover`                                                                                                                           |
| `sweep-market`    | MarketRouter | `BonusTargetEscrowConfigured`, `BonusTargetEscrowCancelled`                                                                          |
| `expire-offers`   | MarketRouter | `BonusTargetEscrowExpired`                                                                                                           |
| `sweep-listings`  | MarketRouter | `LockListed`, `LockDelisted`                                                                                                         |

While WS is healthy, the keeper runs these tasks every `KEEPER_SAFETY_NET_INTERVAL_SECS` (default 1h) as a catch-up backstop; while WS is disconnected longer than `KEEPER_WS_DISCONNECTED_GRACE_SECS` (default 5 min) it falls back to polling with a cadence determined by the observed upstream tier: `KEEPER_INTERVAL_SECS_PRIMARY` (default 5 min) when a `tier=primary` header has been observed on the RPC proxy, or `KEEPER_INTERVAL_SECS_FALLBACK` (default 30 min) otherwise — including the common case where no ClaimRush RPC proxy is in front of the keeper (`tier=unknown`). This keeps community operators running the public keeper against a shared public provider on a conservative polling budget by default. Event-driven triggers are additionally debounced by `KEEPER_EVENT_MIN_REPEAT_SECS` (default 5 s) so on-chain event spam on public contracts cannot force the keeper into back-to-back scans. See [keeper README — Adaptive cadence & WebSocket event bus](https://github.com/claimrush/claimrush/blob/main/keeper/README.md#adaptive-cadence--websocket-event-bus-v110) for the full matrix and kill-switches. The proxy exposes `x-rpc-proxy-upstream-tier` on every successful response (`primary` when the highest-capacity upstream is healthy; `fallback` when a secondary upstream is serving) so the keeper can stretch its cadence accordingly.

Integrators building their own indexers or keepers do **not** need to coordinate with these subscriptions — events are the source of truth either way, and nothing on-chain depends on whether a listener is WS or polling. The table above is included only so downstream operators can understand which events matter most to the ClaimRush keeper, in case of WS rate-limiting, provider failover, or analytics correlation against observed keeper activity.

## Dune integration

| Resource | Path |
|----------|------|
| Event decoding + codebooks | `docs/analytics/dune-integration-pack-v1.0.0.md` |
| Metric meanings | `docs/analytics/metrics-canon-v1.0.0.md` |
| Leaderboards | `docs/analytics/leaderboards-ui-and-dune-compatible-v1.0.0.md` |
| SQL templates | `analytics/dune/` |

**Usage:** Get addresses from manifests → decode with ABIs → filter by startBlock → build from templates.

## Achievements engine

Cosmetic badges are computed offchain in the application service.

**Endpoint:** `GET /api/achievements?address=0x...&chainId=8453`

**Response:** adds `updatedAt` (nullable number, seconds-since-epoch max `updated_ts` across the user's rows) so clients can detect stale D1 state and request a synchronous `refresh=1` when the cron backstop hasn't caught up to a recent transaction.

**Consumer config:**
- Subgraph: `SUBGRAPH_URL` (required), `SUBGRAPH_AUTH_TOKEN` (optional).
- Full subgraph-backed sync (Phase 1 scan + Phase 2 queue drain, 5-min cron): `ACHIEVEMENTS_SYNC_ENABLED`, `ACHIEVEMENTS_SYNC_OVERLAP_BLOCKS`, `ACHIEVEMENTS_SYNC_BATCH_SIZE`, `ACHIEVEMENTS_SYNC_LOCK_LEASE_SEC`, `ACHIEVEMENTS_SYNC_MAX_RUNTIME_MS`.
- Minute-cadence drain cron (Phase 2 only; runs even when the full sync is disabled — this is the reliable fallback when WebSockets are down): `ACHIEVEMENTS_DRAIN_MAX_RUNTIME_MS`.
- Server-side game-feed trigger (queue consumer evaluates watcher-confirmed events and upserts `source = 'gamefeed'` rows directly, without an RPC receipt fetch or subgraph query): `ACHIEVEMENTS_GAMEFEED_TRIGGER_ENABLED` (default on).

**Write sources & precedence (D1 `achievements.source` column):**

1. `fast` — provisional row from `POST /api/achievements/fast-unlock`, no receipt/subgraph check.
2. `verified_fast` — `fast` row promoted after the fast-unlock verify step matched an RPC receipt. Protected from canonical purge.
3. `gamefeed` — written by the queue consumer's `evaluateAchievementsFromGameFeed` pass directly from watcher-confirmed `IngestEvent`s. Protected from canonical purge. Supersedes `fast` rows of same or lower tier.
4. `canonical` — written by the subgraph-backed 5-min sync after `_meta`-pinned recompute; cannot be downgraded back to `fast`/`gamefeed`.

**Reliability layers (in ascending order of latency/trust):**

| Layer | Latency | Depends on |
|-------|---------|------------|
| Fast-unlock (`POST /api/achievements/fast-unlock`) | ~1–13s | RPC receipt for verify extras |
| Game-feed trigger (queue consumer) | ~1–3s after watcher confirms | Game-feed WS / queue health |
| Frontend hot-poll (30s window, 1.5s cadence) | picks up the above within one tick | `/api/achievements` reachable |
| 1-min drain cron (Phase 2 queue drain) | ≤60s after enqueue | D1 reachable; subgraph for canonical backfill |
| 5-min full sync (Phase 1 scan + Phase 2 drain) | ≤5m | Subgraph reachable, `ACHIEVEMENTS_SYNC_ENABLED=1` |

**Required subgraph entities:** Takeover, ReignFinalizedEvent, VeLock*Event, ShareholderClaimEvent, FurnaceEnterEvent, FurnaceState, LpStreamFundedEvent, MarketLockListedEvent, MarketSellToFurnaceEvent, BonusTargetEscrowEvent, BonusTargetEscrowExecutedEvent, BonusTargetEscrowAutoFurnaceExecutedEvent, LpStakedEvent, etc. See `subgraph/schema.graphql`.

**Hard rule (background consumers):** any capped subgraph history/event window MUST either paginate (deterministic safe-cursor or degraded-mode) or fail closed.

- **Recent-touch achievement scans** use deterministic safe-cursor pagination — on saturation they advance their cursor only to the largest fully-covered block / timestamp across saturated families and emit an `achievements_sync_recent_touched_saturated` warning, so a high-volume launch window cannot wedge sync forever.
- **Per-user badge-profile history** uses degraded-mode pagination — on saturation the recompute commits the badge set computed from the truncated page so the recompute-queue row drains, and emits an `achievements_profile_for_badges_saturated` warning. To prevent a partial profile from retracting real badges that depend on data past the page cap (dual-mode claims, automation enabled-after-many-disabled, LP long-staker timelines, later furnace modes), the saturated path also reads the user's prior canonical badges and merges any pre-existing canonical id that the truncated recompute did not re-award into the upsert set; `replaceUserAchievements`'s diff-delete path then keeps them in place. This degraded mode is safe only because every count-based badge threshold is well below `PROFILE_EVENT_PAGE_LIMIT`; future badges with thresholds above the page cap MUST add resumable id-cursor pagination.
- **Furnace percentile lookbacks** still reject saturated windows (`FURNACE_PERCENTILE_WINDOW_OVERFLOW`) so percentile rankings cannot silently drift from truncated results.
- **Push-style dispatch families** advance via a deterministic safe-partial cursor. When a per-family event window saturates `PUSH_WINDOW_PAGE_LIMIT`, the dispatcher computes the largest fully-covered timestamp from the truncated rows and clamps `last_dispatch_ts` / `last_unlock_scan_ts` to that ceiling, so a saturated launch window cannot wedge dispatch forever. Saturated event families (`takeovers`, `listingSettledEvents`, `bonusTargetEscrowEvents`) and the unbond family (`lpUnbondStartedEvents`) each track their own ceiling so a saturated event window never advances the unbond cursor past unprocessed `unlockTime` values, and vice versa. Unbond alerts dropped from the post-dedup `BATCH_LIMIT` slice further clamp the unbond ceiling to `min(droppedUnbondMinUnlockTs - 1, asOfTs)` so they survive into the next tick. The `_meta`-pinned head + indexed-timestamp ceiling rules from below still apply — wall-clock fallback is never used.

Dispatch flows also MUST capture `_meta` first, pin their event query to that indexed head, and advance both `last_dispatch_ts` and `last_unlock_scan_ts` to the indexed head timestamp, never to wall clock.

**Hard rule (timestamp-sorted feeds):** if an activity feed is ordered by `timestamp desc`, the cursor MUST carry both the boundary `timestamp` and a stable tie-breaker id. A raw `id_lt` filter is invalid for `ActivityItem` because ids are txHash/logIndex-derived and not monotonic by timestamp. Implementations should enforce this via CI lint checks.

**Hard rule (owner lock sets):** any surface that derives current ve, active lock count, or lock eligibility from an owner's lock set MUST fetch the full owner lock set via paginated `tokenId` cursor reads pinned to one `_meta` head. This applies both to direct `veLocks(where: { owner: ... })` queries and to relation shortcuts like `user(id: ...) { locks(first: N) }`. A capped `first: N` owner-lock query is a correctness bug because it silently undercounts power users. Implementations should enforce this via CI lint checks.

**Hard rule (security session sets):** any surface that shows active delegation-session counts, active delegate cards, or bulk revoke targets MUST fetch the full `delegationSessions` set via paginated `id` cursor reads pinned to one `_meta` head. A capped `delegationSessions(first: N)` query is a correctness bug because it can hide active delegates and make revoke/security surfaces incomplete. Implementations should enforce this via CI lint checks.

**Hard rule (client-derived crown decay):** any client surface that derives Crown takeover price, cost tier, or decay zone from subgraph data MUST use the same payload's `_meta.block.timestamp` as "now", including SSR or prefetched variants. A wall-clock-only derivation can drift ahead of the indexed head under lag and misstate urgency. Implementations should enforce this via CI lint checks.

**Hard rule (multi-query analytics/admin surfaces):** any route that stitches multiple event/entity windows into one payload MUST capture `_meta` first, pin every subsequent read to that same block, and bound every window to that same indexed timestamp. If `_meta` is unavailable, the consumer MUST fail closed instead of mixing wall-clock time with subgraph data. Administrative and system-metrics routes should enforce this in CI.

**Hard rule (public Furnace windows):** any application/API surface that reports Furnace 7d bonus payouts, 24h entry counts, or similar event windows MUST capture `_meta` first, pin the window scan to that block, and paginate with a stable cursor. `skip` pagination on a moving head is invalid for these public metrics because it can silently miss or double-count rows while the indexer advances. Implementations should enforce this via CI lint checks.

**Hard rule (active market order sets):** any surface that shows a user's active listings or active offers MUST page the full active-order set at one pinned head. A capped `marketListings(... first: N)` or `bonusTargetEscrows(... first: N)` query silently undercounts active orders and can hide cancellable positions. Any listing/offer expiry or "expiring soon" urgency derived from that snapshot MUST also use the same payload's `_meta.block.timestamp` as "now"; wall-clock-only expiry math can hide still-active indexed orders while the indexer lags. Implementations should enforce this via CI lint checks.

**Hard rule (reorg-safe block timestamps):** any indexer that resolves block timestamps from RPC and caches the result MUST key the cache by `(blockNumber, blockHash)` and resolve via `eth_getBlockByHash(blockHash)`, not `eth_getBlockByNumber(blockNumber)`. A same-height reorg replaces the canonical block at `blockNumber` with a different hash; a number-only cache then serves the displaced fork's timestamp on every event from the new canonical block until the entry evicts. Hosted subgraph services (Goldsky, The Graph) handle this internally — the rule applies to roll-your-own watchers, materializers, and analytics jobs that pull `eth_getBlock*` from a generic RPC. Pair the canonical lookup with the matching `(blockNumber, blockHash)` extracted from the log itself; do not derive `blockHash` from a separate `eth_getBlockByNumber` call (that re-introduces the displaced-fork race).

## Subgraph hosting and failover

| Provider | Role | Endpoint |
|----------|------|----------|
| **Goldsky** | Primary | `SUBGRAPH_URL` / `SUBGRAPH_DIRECT_URL` (infrastructure pricing, rate-limited) |
| **The Graph** | Failover | `SUBGRAPH_FALLBACK_URL` / `SUBGRAPH_FALLBACK_DIRECT_URL` (query-based pricing) |

A consumer can fall back to The Graph when Goldsky returns HTTP 429 (rate limit) or 5xx errors. The same GraphQL queries work against both providers since they index the same subgraph code and on-chain data.

**Example three-layer failover pattern:**

1. **Proxy layer**: retries 429s with backoff, tries stale cache, then falls back to `SUBGRAPH_FALLBACK_URL`. It can annotate fallback responses with `x-cr-subgraph-fallback: 1` and `x-cr-subgraph-stale-blocks` headers.
2. **Direct bypass path**: used when the proxy is unreachable. Falls back to `SUBGRAPH_FALLBACK_DIRECT_URL` on 429/5xx/timeout.
3. **Shared fetcher**: used by background jobs (achievements sync, leaderboards, push dispatch). Retries with exponential backoff on primary, then tries the fallback URL once.

**Deploying the subgraph to The Graph:**

```bash
cd subgraph
python3 ../scripts/sync_subgraph_manifest_from_deployments.py \
  --manifest subgraph.prod.yaml --deployments ../deployments/base_mainnet.json
cp subgraph.prod.yaml subgraph.yaml
npm ci && npm run build
npx graph auth <DEPLOY_KEY>
npx graph deploy claim-rush-prod \
  --node https://api.studio.thegraph.com/deploy/ \
  --version-label vX.Y.Z
git checkout -- subgraph.yaml   # restore local dev manifest
```

**Env vars:** set graph deploy credentials, node URL, IPFS endpoint, and version label in the deployment environment before publish.

## See also

- [Security, Guardian, Pausing](security-guardian-pausing.md) - pause events and guardian controls
- [Core Mechanics](core-mechanics.md) - takeover and emission events
- [Market (MarketRouter)](marketrouter.md) - listing and escrow events
- Tutorial: [Index takeovers and reigns](tutorials/index-takeovers-and-reigns.md)
- Tutorial: [Index Market listings](tutorials/index-market-orderbook.md)
