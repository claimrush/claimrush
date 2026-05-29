// SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

// Intentionally omitted from this interface (present in ABI only):
//
//   Freeze-locked setters (blocked after freezeConfig):
//     freezeConfig, setShareholderRoyalties, setMineCore, setMineMarket,
//     setFurnaceQuoter, setLpRewardsVault
//
//   Post-freeze operational setters (remain owner-configurable after freeze):
//     setEntryTokenRegistry, setGuardian, setDelegationHub,
//     acceptOwnership, renounceOwnership, transferOwnership
//
//   ERC-721 hook:
//     onERC721Received
//
//   Public state variable getters (Solidity auto-generated):
//     claim, ve, deploymentTime, configFrozen, guardian, shareholderRoyalties,
//     mineCore, mineMarket, lpRewardsVault, entryTokenRegistry,
//     bonusVirtualDepth, lastBonusUpdate, sellImpactVolume, lastSellImpactUpdate,
//     lastLpOverflowDripUpdate, furnaceReserve, lastAutoMaxBonusClaim,
//     owner, pendingOwner
//
//   Internal state (no auto-generated getter; readable via Furnace.getLpStreamState()):
//     lpStreamRatePerSec, lpStreamPeriodFinish, lpStreamLastUpdate,
//     lpSaleFundedDay, lpSaleFundedToday
//

/// @notice Furnace external interface (pinned).
/// @dev MUST match docs/spec/spec-v1.0.0.md and shipped ABIs.
interface IFurnace {
    // ------------------------------------------------------------
    // Delegatecall-emitted events (SPEC v1.0.0 §7.2 / §7.6)
    // ------------------------------------------------------------
    // These events are emitted from the Furnace address via delegatecall
    // into FurnaceGuardHelper (EIP-170 size relief). Declaring them here
    // ensures they appear in Furnace's compiled ABI so block explorers
    // and indexers can decode them without merging a secondary ABI.
    // Canonical signatures MUST match src/lib/Events.sol.

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

    /// @notice Mirrors the canonical `Events.FurnaceMergeWithBonus` declaration so the
    ///         event is visible in `Furnace.abi.json` (the actual emit site is
    ///         `FurnaceGuardHelper`, which runs in Furnace's storage context via
    ///         `delegatecall` — see `docs/manuals/developer/events-and-indexing.md`).
    ///         Topic0 parity is pinned in `test/InterfaceEventParity.t.sol` and
    ///         `test/snapshots/abi/events_topics.json`.
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

    /// @notice Emergency vault rewire lifecycle, emitted from the Furnace address
    ///         via delegatecall into `FurnaceGuardHelper.{request,cancel,execute}`
    ///         EmergencyVaultRewire. Re-declared here (third declaration alongside
    ///         `lib/Events.sol` and `FurnaceGuardHelper.sol`) so that
    ///         `Furnace.abi.json` exposes them to Dune / subgraph indexers without
    ///         requiring a secondary ABI merge. Topic0 parity is pinned in
    ///         `test/InterfaceEventParity.t.sol`.
    event EmergencyVaultRewireRequested(address indexed vault, uint256 liability, uint256 executeAfter);
    event EmergencyVaultRewireCancelled();
    event EmergencyVaultRewireExecuted(address indexed oldVault, uint256 strandedAmount);

    // ------------------------------------------------------------
    // Entry paths (SPEC v1.0.0 §7.2)
    // ------------------------------------------------------------

    function enterWithEth(uint256 targetTokenId, uint256 durationSeconds, bool createAutoMax, uint256 minVeOut)
        external
        payable
        returns (uint256 tokenIdUsed);

    /// @notice Delegated ETH entry: caller pays ETH, `user` receives the ve lock.
    function enterWithEthFor(
        address user,
        uint256 targetTokenId,
        uint256 durationSeconds,
        bool createAutoMax,
        uint256 minVeOut
    ) external payable returns (uint256 tokenIdUsed);

    function enterWithClaim(
        uint256 claimAmount,
        uint256 targetTokenId,
        uint256 durationSeconds,
        bool createAutoMax,
        uint256 minVeOut
    ) external returns (uint256 tokenIdUsed);

    /// @notice Delegated CLAIM entry: caller provides CLAIM, `user` receives the ve lock.
    function enterWithClaimFromCallerFor(
        address user,
        uint256 claimAmount,
        uint256 targetTokenId,
        uint256 durationSeconds,
        bool createAutoMax,
        uint256 minVeOut
    ) external returns (uint256 tokenIdUsed);

    function enterWithClaimFor(
        address user,
        uint256 claimAmount,
        uint256 targetTokenId,
        uint256 durationSeconds,
        bool createAutoMax,
        uint256 minVeOut
    ) external returns (uint256 tokenIdUsed);

    function enterWithToken(
        address tokenIn,
        uint256 amountIn,
        uint256 targetTokenId,
        uint256 durationSeconds,
        bool createAutoMax,
        uint256 minVeOut
    ) external returns (uint256 tokenIdUsed);

    /// @notice Delegated token entry: caller provides `tokenIn`, `user` receives the ve lock.
    function enterWithTokenFromCallerFor(
        address user,
        address tokenIn,
        uint256 amountIn,
        uint256 targetTokenId,
        uint256 durationSeconds,
        bool createAutoMax,
        uint256 minVeOut
    ) external returns (uint256 tokenIdUsed);

    // Extension with bonus (non-AutoMax locks)
    function extendWithBonus(uint256 tokenId, uint256 durationSeconds, uint256 minBonusOut)
        external
        returns (uint256 bonusClaim);

    function extendWithBonusFor(address user, uint256 tokenId, uint256 durationSeconds, uint256 minBonusOut)
        external
        returns (uint256 bonusClaim);

    // Merge with bonus (Furnace-only path)
    /// @notice Merge two existing locks owned by the caller and pay an extension-style bonus
    ///         to the surviving lock when the merge effectively extends its remaining duration.
    /// @dev `bonusClaim = 0` when both inputs share the same effective remaining duration
    ///      (including both AutoMax). `minBonusOut > 0` enforces a slippage floor on the bonus.
    function mergeLocksWithBonus(uint256 fromTokenId, uint256 intoTokenId, uint256 minBonusOut)
        external
        returns (uint256 bonusClaim);

    /// @notice Delegated merge: caller submits, `user` is the lock owner and bonus recipient.
    /// @dev Requires a delegation session with `P_VE_MERGE_LOCKS_FOR` and emits
    ///      `DelegationSessionUsed` (actionType `VE_MERGE_LOCKS_FOR = 31`).
    function mergeLocksWithBonusFor(address user, uint256 fromTokenId, uint256 intoTokenId, uint256 minBonusOut)
        external
        returns (uint256 bonusClaim);

    // AutoMax bonus accrual (keeper, 24h cooldown)
    function claimAutoMaxBonus(uint256 tokenId) external returns (uint256 bonusClaim);
    function claimAutoMaxBonusBatch(uint256[] calldata tokenIds, uint256 maxLocks) external returns (uint256 totalBonus);
    function lastAutoMaxBonusClaim(uint256 tokenId) external view returns (uint256);

    // Pause: onlyGuardian (in production, guardian is MineCore)
    function setLockingPaused(bool paused) external;

    // ------------------------------------------------------------
    // Wiring views
    // ------------------------------------------------------------

    /// @notice Address of the FurnaceQuoter used for quoteEnterWith*, quoteSellLock*, getFurnaceState.
    function furnaceQuoter() external view returns (address);

    // Delegation wiring
    function delegationHub() external view returns (address);
    function setDelegationHub(address hub) external;

    // Public state getter (used by router/tests for gating)
    function lockingPaused() external view returns (bool);

    // Called only by ShareholderRoyalties (LOCK_FURNACE)
    function lockEthReward(
        address user,
        uint256 ethAmount,
        uint256 targetTokenId,
        uint256 durationSeconds,
        bool createAutoMax,
        uint256 minVeOut
    ) external payable;

    // Called only by MineCore after minting the Furnace emission stream
    function creditReserve(uint256 amount) external;

    // Permissionless maintenance
    // - Accrues any owed LP stream amount to the LP vault
    // - Optionally funds the overflow drip into the LP stream (once-per-day)
    // Returns the amount transferred to the LP vault by the stream in this call.
    function tick() external returns (uint256 streamed);

    // ------------------------------------------------------------
    // LP rewards stream (SPEC v1.0.0 §7.3.6)
    // ------------------------------------------------------------

    function getLpStreamRemaining() external view returns (uint256 remaining);

    function getLpStreamState()
        external
        view
        returns (uint256 ratePerSec, uint256 periodFinish, uint256 lastUpdate, uint256 remaining);

    // ------------------------------------------------------------
    // Sellback (lock → liquid CLAIM) (SPEC v1.0.0 §7.6)
    // ------------------------------------------------------------

    /// @notice Sell a lock to the Furnace via the canonically wired MineMarket (MarketRouter) bundle.
    /// @dev Used by MarketRouter Market Sell routing to avoid requiring users to approve the Furnace.
    ///      MarketRouter MUST move the lock with `safeTransferFrom(...)` first so Furnace can bind
    ///      `seller` to the observed prior owner during custody transfer.
    function sellLockToFurnaceFromMarket(address seller, uint256 tokenId, uint256 minClaimOut)
        external
        returns (uint256 claimOut);

    // SellLockQuoteBreakdown, quoteEnterWith*, quoteSellLock*, and getFurnaceState are declared
    // on IFurnaceQuoter; use furnaceQuoter() for the quoter address.

    function getLpSaleRewardCapPerDay() external view returns (uint256);

    function getLpSaleRewardFundedToday() external view returns (uint256);

    function getLpSaleRewardCapRemaining() external view returns (uint256);

    function getFurnaceInflowPerDay() external view returns (uint256);

    function getCapInflowPerDay() external view returns (uint256);

    function getLpOverflowDripPerDay() external view returns (uint256);
}
