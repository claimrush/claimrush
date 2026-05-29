// SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

/// @notice Centralized event declarations for analytics.
/// @dev Canonical event schema is defined in `docs/analytics/dune-integration-pack-v1.0.0.md`.
///      Contracts MAY emit these events via `emit Events.X(...)` or declare identical events locally.
///      Either way, the emitted event signatures MUST match the canonical schema.
library Events {
    // Common admin / transparency
    event GuardianChanged(address indexed oldGuardian, address indexed newGuardian);
    event MineMarketChanged(address indexed oldMineMarket, address indexed newMineMarket);
    event FurnaceChanged(address indexed oldFurnace, address indexed newFurnace);
    event DelegationHubChanged(address indexed oldDelegationHub, address indexed newDelegationHub);
    event MineCoreChanged(address indexed oldMineCore, address indexed newMineCore);
    event ClaimAllHelperChanged(address indexed oldHelper, address indexed newHelper);
    event ShareholderRoyaltiesChanged(address indexed oldSR, address indexed newSR);
    event ShareholderWiringSet(address indexed mineCore, address indexed mineMarket, address indexed furnace);
    event ConfigFrozen();

    // OpenZeppelin `Ownable2Step` / `Ownable` ownership events (included for completeness).
    event OwnershipTransferStarted(address indexed previousOwner, address indexed newOwner);
    event OwnershipTransferred(address indexed previousOwner, address indexed newOwner);

    // DelegationHub (bot sessions)

    /// @notice Emitted when a session is created or updated for a delegate.
    event SessionSet(address indexed user, address indexed delegate, uint256 perms, uint256 expiry);

    // Furnace (slippage limiter transparency)

    /// @notice Emitted when a Furnace entry is guarded by the slippage limiter.
    /// @dev `tokenIdUsed` is the second indexed topic so keeper / MEV tooling can filter
    ///      per-lock without scanning every entry. ABI consumers are generated against this
    ///      canonical signature (see `abis/`, the Dune integration pack, and
    ///      `test/SecurityCriticalConstantsPinned.t.sol` for the pinned topic0 hash that
    ///      gates further drift).
    event NearSlippageLimitEntry(
        address indexed user, uint256 indexed tokenIdUsed, uint256 minVeOut, uint256 actualVeOut, uint256 marginBps
    );

    /// @notice Emitted when a protocol contract successfully executes a delegated (session-gated) action.
    /// @dev The emitting contract indicates *where* the session was used. Indexers should join this event
    ///      with `DelegationHub.SessionSet` to render a full approvals-like view:
    ///      - who (user) granted the session
    ///      - to whom (delegate)
    ///      - what action occurred (actionType)
    ///      - which permission bits were used (permsUsed)
    ///      - which tx hash (from log metadata)
    ///
    /// Canonical action type ids are defined in `DelegationActionTypes.sol`.
    /// `refId` is action-type specific (e.g. reignId or tokenId) and MAY be 0.
    event DelegationSessionUsed(
        address indexed user,
        address indexed delegate,
        uint8 indexed actionType,
        uint256 permsUsed,
        uint256 refId,
        uint256 timestamp
    );

    // EntryTokenRegistry (allowlist + routing transparency)
    event RouterConfigSet(
        address indexed router, address indexed factory, address indexed wrappedNative, address claimToken
    );

    event WethClaimPoolSet(address indexed pool, bool stable);

    event TokenConfigSet(
        address indexed tokenIn,
        bool enabled,
        bool directToClaimEnabled,
        bool tokenClaimStable,
        address tokenClaimPool,
        bool tokenWethStable,
        address tokenWethPool
    );

    event FurnaceEntryTokenSafetySet(address indexed tokenIn, bool exactReceiptSafe);

    event TokenEnabledChanged(address indexed tokenIn, bool enabled);

    // DexAdapter (rescue transparency)
    event EthRescued(address indexed to, uint256 amount);
    event TokenRescued(address indexed token, address indexed to, uint256 amount);

    // VeClaimNFT lifecycle
    event LockCreated(address indexed user, uint256 indexed tokenId, uint256 amount, uint256 lockEnd, bool autoMax);
    event LockExtended(address indexed user, uint256 indexed tokenId, uint256 oldEnd, uint256 newEnd);
    event LockAmountIncreased(address indexed user, uint256 indexed tokenId, uint256 amountAdded);
    event LockMerged(
        address indexed user, uint256 indexed fromTokenId, uint256 indexed intoTokenId, uint256 amountMoved
    );
    event LockUnlocked(address indexed user, uint256 indexed tokenId, uint256 amountReturned);
    event AutoMaxSet(address indexed user, uint256 indexed tokenId, bool autoMax);

    // MineCore (Kings & takeovers)
    event EntryTokenRegistrySet(address indexed registry);

    /// @notice Furnace quoter wiring (view-only helper).
    event FurnaceQuoterSet(address indexed oldQuoter, address indexed newQuoter);

    event Takeover(
        uint256 indexed reignId,
        address indexed previousKing,
        address indexed newKing,
        uint256 pricePaid,
        uint256 referencePrice,
        uint256 timestamp
    );

    event ReignFinalized(
        uint256 indexed reignId,
        address indexed king,
        uint256 startTime,
        uint256 endTime,
        uint256 totalClaimMined,
        uint256 totalEthToKing
    );

    /// @notice Per-reign routing: where the dethroned king's 75% ETH share and King-stream mined CLAIM are sent.
    /// @dev When a reign starts, MineCore stores recipients for the new reign and emits this event.
    ///      The active king (or an authorized delegate) can update recipients mid-reign via
    ///      `MineCore.setCurrentReignRecipients`.
    event ReignRecipientsSet(
        uint256 indexed reignId, address indexed king, address indexed ethRecipient, address claimRecipient
    );

    event TakeoversPausedChanged(bool paused);
    event KingWithdrawal(address indexed king, uint256 amount);
    event KingWithdrawalTo(address indexed king, address indexed to, uint256 amount);

    /// @notice Emitted when the best-effort king ETH payout during takeover fails and ETH is credited
    ///         to the pull-payment bucket `kingEthBalance[recipient]`.
    event KingEthCredited(address indexed recipient, uint256 amount);

    /// @notice Emitted when a refund ETH transfer fails and the amount is credited to the pull-payment bucket.
    event RefundCredited(address indexed to, uint256 amount);
    /// @notice Emitted when a user withdraws from their refund ETH balance.
    event RefundWithdrawn(address indexed user, address indexed to, uint256 amount);

    /// @notice Per-king opt-in configuration for auto-locking King-stream mined CLAIM into the Furnace.
    event KingAutoLockConfigured(
        address indexed user,
        bool enabled,
        uint256 targetTokenId,
        uint256 pinnedTokenId,
        uint256 durationSeconds,
        bool createAutoMax,
        uint256 minVeOut
    );

    event KingAutoLockExecuted(
        uint256 indexed reignId, address indexed user, uint256 principalClaim, uint256 tokenIdUsed
    );

    event KingAutoLockSkipped(uint256 indexed reignId, address indexed user, uint256 principalClaim, uint8 reasonCode);

    event KingAutoLockFailed(uint256 indexed reignId, address indexed user, uint256 principalClaim, bytes revertData);

    /// @notice Emitted when a user withdraws from their pending CLAIM balance (king auto-lock fallback bucket).
    event PendingClaimWithdrawn(address indexed user, address indexed to, uint256 amount);

    /// @notice Emitted when CLAIM is credited to pendingKingClaim (transfer or auto-lock fallback).
    event KingClaimCredited(address indexed user, uint256 amount);

    // ShareholderRoyalties (Barons' ETH)
    event ShareholderTakeoverAllocation(uint256 indexed reignId, uint256 amountEth);
    event ShareholderFlush(uint256 amountEth, uint256 deltaEthPerVe);
    event ShareholderClaimed(address indexed user, address indexed to, uint256 amount, uint8 mode);
    event ShareholderBatchTerminatedEarly(uint256 indexed processedUpTo, uint256 batchSize);
    /// @notice Emitted when checkpointUser crystallises accrued ETH rewards for a user.
    event UserCheckpointed(address indexed user, uint256 accrued);
    event DustSwept(address indexed to, uint256 amount);
    event RewardCheckpointCapReached(uint256 length);
    event OverflowCheckpointCapReached(uint256 length);

    /// @notice Emitted when royalties.onTakeover reverts during takeover, or when retryPushShareholderEth later
    ///         fails to push the buffered ETH back into ShareholderRoyalties.
    /// @dev The outer takeover flow still succeeds. On the initial failure path ETH is credited to
    ///      MineCore.shareholderEthPending for retry; on retry failure the same event is re-emitted with
    ///      `reignId = 0` and `amountEth` equal to the retried pending bucket. `reason` is bounded
    ///      revert data (capped at 128 bytes).
    event ShareholderRoyaltiesTakeoverFailed(uint256 indexed reignId, uint256 amountEth, bytes reason);

    /// @notice Emitted when royalties.flushPendingShareholderETH reverts during takeover or retryPushShareholderEth.
    /// @dev The outer flow stays live; ETH remains in ShareholderRoyalties.pendingShareholderETH for a later flush.
    ///      `reason` is bounded revert data (capped at 128 bytes).
    event ShareholderRoyaltiesFlushFailed(bytes reason);

    /// @notice Emitted when `Furnace.creditReserve(amount)` reverts during a takeover.
    /// @dev MineCore has already minted and transferred CLAIM to the Furnace address, but
    ///      the internal reserve accounting update failed. `furnaceReserve` is understated
    ///      until a subsequent `_syncFurnaceReserve()` call corrects it.
    event FurnaceCreditReserveFailed(address indexed furnace, uint256 amount, bytes reason);

    event ShareholderClaim(address indexed user, uint8 mode, uint256 amountEth);

    event ShareholderAutoCompoundConfigured(
        address indexed user,
        bool enabled,
        uint256 tokenId,
        uint256 durationSeconds,
        uint32 minCadenceSeconds,
        uint256 minEthToCompound,
        uint32 maxSlippageBps
    );
    event ShareholderAutoCompoundKeeperSet(address indexed keeper, bool allowed);
    event MinAutoCompoundEthSet(uint256 oldFloor, uint256 newFloor);
    event EthPushGasCapSet(uint256 oldCap, uint256 newCap);
    /// @notice Operator raised or narrowed the overflow-eviction watermark on
    ///         `ShareholderRoyalties._oldestObservedNonAutoMaxLockEnd`.
    event OldestObservedNonAutoMaxLockEndSet(uint40 oldValue, uint40 newValue);

    event ShareholderAutoCompoundPaused(address indexed user, uint256 tokenId, uint8 reasonCode);

    event ShareholderAutoCompoundFailed(address indexed user, uint256 amountEth, uint256 tokenId);

    event ShareholderAutoCompoundExecuted(
        address indexed user,
        address indexed executor,
        uint256 amountEth,
        uint256 tokenId,
        uint256 effectiveDurationSeconds
    );

    // Furnace
    event FurnaceEnter(
        address indexed user, uint8 mode, uint256 ethIn, uint256 principalClaim, uint256 bonusClaim, uint256 tokenId
    );

    event AutoMaxBonusClaimed(address indexed user, uint256 tokenId, uint256 bonusClaim);

    /// @notice Emitted when two locks are merged through Furnace and an extension-style
    ///         bonus is settled into the surviving lock.
    /// @dev Distinct from `Events.LockMerged`, which is the ve-level lifecycle peer of
    ///      `LockExtended`. Both are emitted for the same merge — `LockMerged` from
    ///      VeClaimNFT carries the lock-state delta, `FurnaceMergeWithBonus` from Furnace
    ///      carries the economic context (amounts, duration delta, bonus paid).
    /// @param user             Owner of `intoTokenId` (and `fromTokenId`) who receives the bonus.
    /// @param fromTokenId      Lock that is consumed and burned by the merge.
    /// @param intoTokenId      Surviving lock that absorbs `fromAmount` plus any bonus.
    /// @param fromAmount       Pre-merge principal of `fromTokenId`.
    /// @param intoAmount       Pre-merge principal of `intoTokenId`.
    /// @param newPrincipal     Post-merge principal on `intoTokenId` (`fromAmount + intoAmount + bonusClaim`).
    /// @param newEnd           Post-merge unlock timestamp on `intoTokenId` (or 0 sentinel for AutoMax).
    /// @param newAutoMax       Whether the surviving lock is AutoMax after the merge.
    /// @param durationDelta    `longerRemaining - shorterRemaining` (effective remaining seconds at merge time).
    /// @param bonusClaim       CLAIM amount minted/credited to the user as the merge bonus (0 when no extension effect).
    event FurnaceMergeWithBonus(
        address indexed user,
        uint256 indexed fromTokenId,
        uint256 indexed intoTokenId,
        uint256 fromAmount,
        uint256 intoAmount,
        uint256 newPrincipal,
        uint256 newEnd,
        bool newAutoMax,
        uint256 durationDelta,
        uint256 bonusClaim
    );

    event BonusPaid(
        address indexed user,
        uint256 principal,
        uint256 principalEff,
        uint256 grossBonusClaim,
        uint256 userBonusClaim,
        uint256 lpTopupClaim,
        uint256 userSpotBonusBps,
        uint256 lpTopupRateBps,
        uint256 grossSpotBonusBps,
        uint256 quoteUserBonusBps,
        uint256 quoteLpTopupBps,
        uint256 lockDurationSec,
        uint256 reserveBefore,
        uint256 reserveAfter,
        uint256 virtualDepthBefore,
        uint256 virtualDepthAfter
    );

    event LpOverflowDripPaid(
        uint256 dripAmount,
        uint256 reserveBefore,
        uint256 reserveAfter,
        uint256 alphaBps,
        uint256 gateBps,
        uint256 capInflowPerDay,
        uint256 capFixedPerDay,
        uint256 reserveTarget,
        uint256 excessBefore
    );

    event LockSoldToFurnace(
        address indexed seller,
        uint256 indexed tokenId,
        uint256 lockAmount,
        uint256 claimOut,
        uint256 spreadBps,
        uint256 cut,
        uint256 lpSaleShareBps,
        uint256 lpReward,
        uint256 reserveAdd,
        uint256 bonusRefBpsUsed
    );

    /// @notice Emitted when the LP rewards vault address is configured (pre-freeze).
    event LpRewardsVaultSet(address indexed oldVault, address indexed newVault);
    event EmergencyVaultRewireRequested(address indexed vault, uint256 liability, uint256 executeAfter);
    event EmergencyVaultRewireCancelled();
    event EmergencyVaultRewireExecuted(address indexed oldVault, uint256 strandedAmount);
    event PendingSellNFTRescued(uint256 indexed tokenId, address indexed seller, uint256 claimReturned);

    /// @notice Emitted when `LpStakingVault7D.notifyRewards()` reverts and the failure is swallowed.
    /// @dev The CLAIM transfer to the LP vault already succeeded. `revertData` is emitted as empty bytes
    ///      to avoid copying arbitrary LP-vault revert data into memory.
    event LpRewardsNotifyFailed(address indexed vault, uint256 amountClaim, bytes revertData);

    event CarrySettlementFailed(address indexed vault, uint256 carry);

    /// @notice Emitted whenever the Furnace LP rewards stream schedule is re-funded.
    /// @dev Offchain indexers can track the current schedule directly from this event without replaying
    ///      `BonusPaid`, `LpOverflowDripPaid`, and `LockSoldToFurnace` deltas.
    event LpStreamFunded(uint256 amountFunded, uint256 newRatePerSec, uint256 newPeriodFinish);

    /// @notice Emitted when `furnaceReserve` is clamped to the contract's actual CLAIM balance minus
    ///         any remaining LP stream obligation, including unscheduled carry dust.
    /// @dev Field 5 is the total LP stream liability (matured-but-unpaid + scheduled + carry),
    ///      not the scheduled-stream remainder alone.
    event ReserveClamped(
        address indexed caller, uint256 oldReserve, uint256 newReserve, uint256 claimBalance, uint256 lpStreamLiability
    );

    event ReserveCredited(uint256 amount, uint256 newReserve);
    event LockingPausedChanged(bool paused);

    // LpStakingVault7D (LP staking vault)
    event LpStaked(address indexed user, uint256 amount);
    event LpUnbondStarted(address indexed user, uint256 indexed unbondId, uint256 amount, uint256 unlockTime);
    event LpUnbondWithdrawn(address indexed user, uint256 indexed unbondId, uint256 amount);

    event LpRewardsNotified(uint256 amountClaim);
    event LpRewardsClaimed(address indexed user, uint256 amountClaim);
    event LpRewardsLocked(
        address indexed user, uint256 amountClaim, uint256 principalClaim, uint256 bonusClaim, uint256 tokenId
    );

    // LP auto-compound (into Furnace)
    event AutoCompoundConfigured(
        address indexed user,
        bool enabled,
        uint256 tokenId,
        uint256 durationSeconds,
        uint32 maxSlippageBps,
        uint256 minRewardToCompound
    );
    event AutoCompoundPaused(address indexed user, uint256 tokenId, uint8 reasonCode);
    event AutoCompoundUnpaused(address indexed user);
    event HarvestKeeperSet(address indexed keeper, bool allowed);
    event MinHarvestClaimFloorSet(uint256 oldFloor, uint256 newFloor);
    event MinCompoundRewardSet(uint256 oldFloor, uint256 newFloor);

    event LpFeesHarvestedToRewards(address indexed caller, uint256 feeWeth, uint256 feeClaim, uint256 claimToRewards);

    /// @dev Canary: accountedRewardBalance was clamped to zero (requested > available).
    event AccountedRewardBalanceClamped(uint256 requested, uint256 available);

    // LaunchController (genesis finalization)
    event GenesisFinalized(
        uint256 timestamp,
        uint256 claimMinted,
        uint256 claimToLiquidity,
        uint256 lpMinted,
        address pool,
        address genesisLpVault
    );

    // MaintenanceHub (ops / automation)
    event Poked(
        address caller,
        bool checkpointOk,
        bool flushOk,
        uint256 offersAttempted,
        uint256 offersSucceeded,
        bool furnaceTickSucceeded,
        uint256 bountyWethForwarded
    );

    // GenesisLPVault24M (genesis infrastructure)
    event Locked(uint256 lpAmount, uint256 lockStartTime, uint256 unlockTime);

    // Mirrors IGenesisLPVault24M.LockExtended(uint256,uint256) (same topic). VeClaimNFT uses a different signature.
    event LockExtended(uint256 oldUnlockTime, uint256 newUnlockTime);

    event WithdrawLp(address indexed to, uint256 amount);
    event ResidualLpSwept(address indexed to, uint256 amount);
    /// @notice Emitted from inside `GenesisLPVault24M.withdrawLp()` when the
    ///         vault claims accumulated Aerodrome trading fees from
    ///         `pool.claimFees()` and forwards them to immutable
    ///         `lpWithdrawRecipient`. Fired only when at least one of the
    ///         forwarded amounts is strictly greater than zero. Always
    ///         precedes the corresponding `WithdrawLp` / `ResidualLpSwept`
    ///         event in the same transaction. token0/token1 are the pool's
    ///         underlying tokens (WETH/CLAIM ordering is pool-defined,
    ///         `token0 < token1` by address).
    event FeesClaimedAndForwarded(
        address indexed token0, address indexed token1, uint256 amount0Forwarded, uint256 amount1Forwarded
    );
    // MarketRouter (marketplace)
    event LockListed(
        uint256 indexed tokenId,
        address indexed seller,
        uint256 minClaimOut,
        uint256 listedAtTime,
        uint256 expiresAtTime
    );
    event LockDelisted(uint256 indexed tokenId, address indexed seller, uint8 reason);

    /// @notice Listing settled to Furnace (lock sold via sellListedLockToFurnace).
    /// @dev Emitted when an approved listed lock is settled into the Furnace. During the
    ///      keeper-priority grace window, execution is limited to allowlisted keepers or
    ///      the owner; after the boundary it is permissionless. The seller receives
    ///      claimOut CLAIM; `penalty` is the
    ///      total retained cut `lockAmount - claimOut` surfaced by sellback math.
    event ListingSettled(uint256 indexed tokenId, address indexed seller, uint256 claimOut, uint256 penalty);

    /// @notice Market sell (Sell now) executed into the Furnace.
    /// @dev Emitted when a lock is sold directly via MarketRouter.sellLockToFurnace.
    event MarketSellToFurnace(
        uint256 indexed tokenId, address indexed seller, uint256 minClaimOut, uint256 deadline, uint256 claimOut
    );

    event TradingPausedChanged(bool paused);

    event BonusTargetEscrowParamsChanged(
        uint256 oldMinBudget, uint256 newMinBudget, uint256 oldMaxDiscountBps, uint256 newMaxDiscountBps
    );

    /// @notice Bonus target escrow created (entry order into Furnace).
    event BonusTargetEscrowCreated(
        uint256 indexed escrowId,
        address indexed buyer,
        uint256 discountBps,
        uint256 durationSeconds,
        bool createAutoMax,
        uint256 expiresAt,
        uint256 destinationLockId,
        uint256 budgetClaim,
        uint256 createdAt
    );

    /// @notice Bonus target escrow executed (entry into Furnace).
    /// @dev Canonical analytics payload for auto-furnace settlement. The protocol emits
    ///      both this event and BonusTargetEscrowAutoFurnaceExecuted with the same field layout.
    event BonusTargetEscrowExecuted(
        uint256 indexed escrowId,
        address indexed buyer,
        uint256 claimIn,
        uint256 principalClaim,
        uint256 bonusClaim,
        uint256 veOut,
        uint256 routeTokenId,
        uint256 furnaceTokenId
    );

    /// @notice Bonus target escrow expired and was cancelled permissionlessly.
    event BonusTargetEscrowExpired(uint256 indexed escrowId, address indexed buyer, uint256 refundClaim);

    /// @notice Bonus target escrow expiry extended by the buyer.
    event BonusTargetEscrowExpiryExtended(
        uint256 indexed escrowId, address indexed buyer, uint256 oldExpiresAt, uint256 newExpiresAt
    );

    event BonusTargetEscrowCancelled(uint256 indexed escrowId, address indexed buyer, uint256 refundClaim);

    /// @notice Bonus target escrow configured with target bonus percentage and slippage tolerance.
    /// @dev Emitted after BonusTargetEscrowCreated when createBonusTargetEscrowWithTarget is called.
    ///      Raw indexers (Dune) can join this event with BonusTargetEscrowCreated to reconstruct full escrow state.
    event BonusTargetEscrowConfigured(
        uint256 indexed escrowId, address indexed buyer, uint256 targetBonusBps, uint256 slippageBps
    );

    event BonusTargetEscrowAutoFurnaceExecuted(
        uint256 indexed escrowId,
        address indexed buyer,
        uint256 claimIn,
        uint256 principalClaim,
        uint256 bonusClaim,
        uint256 veOut,
        uint256 routeTokenId,
        uint256 furnaceTokenId
    );

    // Settlement keeper priority (MEV protection)
    event SettlementKeeperSet(address indexed keeper, bool allowed);

    // LpStakingVault7D
    event HarvestMinClaimOutIgnored(uint256 minClaimOut);
    event ApprovalClearFailed(address token, address spender);
    event NotifyAmountDivergence(uint256 declared, uint256 actualDelta);

    // ClaimAllHelper
    /// @notice Emitted when king balance withdrawal fails during claimAll (best-effort).
    event KingWithdrawalFailed(address indexed user, bytes reason);

    // VeClaimNFT slope drift monitoring
    event SlopeDriftClamped(uint256 indexed timestamp, uint256 scheduledSlope, uint256 globalSlope);

    // VeClaimNFT best-effort checkpoint failure
    event ShareholderCheckpointFailed(address indexed user, address indexed royalties);

    // MineCore king ETH payout observability
    event KingEthPaid(address indexed recipient, uint256 amount);

    // MarketRouter: auto-furnace destination lock fallback
    event DestinationLockIneligible(uint256 indexed offerId, uint256 indexed destinationLockId);

    // VeClaimNFT metadata (ERC-4906 + admin)
    event MetadataUpdate(uint256 _tokenId);
    event BatchMetadataUpdate(uint256 _fromTokenId, uint256 _toTokenId);
    event BaseURISet(string oldURI, string newURI);
    event ContractURISet(string oldURI, string newURI);
    event ContractURIUpdated();
    event MetadataFrozen();
}
