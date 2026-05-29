// SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

/// @notice MineCore external interface (pinned).
/// @dev MUST match docs/spec/spec-v1.0.0.md and shipped ABIs.
interface IMineCore {
    struct ReignInfo {
        address king;
        uint256 startTime;
        uint256 endTime;
        uint256 pricePaid;
        uint256 referencePrice;
        uint256 totalClaimMined;
        uint256 totalEthToKing;
    }

    function delegationHub() external view returns (address);
    function emissionStartTime() external view returns (uint256);
    function GENESIS_ACCRUAL_DURATION() external view returns (uint256);

    /// @notice Deterministic Furnace emission rate (CLAIM/sec) at an arbitrary timestamp.
    function getFurnaceEmissionRateAt(uint256 timestamp) external view returns (uint256);

    // ------------------------------------------------------------
    // Genesis helpers (used by LaunchController)
    // ------------------------------------------------------------

    function takeoversPaused() external view returns (bool);

    function collectGenesisKingClaim(address to) external returns (uint256 claimMinted);

    function setTakeoversPaused(bool paused) external;

    // ------------------------------------------------------------
    // User actions
    // ------------------------------------------------------------

    function takeover(uint256 maxPrice) external payable;

    function takeoverWithToken(address tokenIn, uint256 amountIn, uint256 minEthOut, uint256 maxPrice) external;

    function takeoverWithTokenAndDeadline(
        address tokenIn,
        uint256 amountIn,
        uint256 minEthOut,
        uint256 maxPrice,
        uint256 deadline
    ) external;

    /// @notice Delegated takeover: caller pays ETH, but `newKing` becomes the king identity.
    function takeoverFor(address newKing, uint256 maxPrice) external payable;

    function withdrawKingBalance() external;

    /// @notice Helper-only entrypoint to withdraw for a user (used by ClaimAllHelper).
    /// @dev MUST preserve `withdrawKingBalance` semantics, but pay out to `user`.
    function withdrawKingBalanceFor(address user) external;

    function withdrawRefundBalance(address to) external;

    function withdrawKingBalanceTo(address to) external;

    function withdrawPendingClaim() external;

    function withdrawPendingClaimTo(address to) external;

    function retryPushShareholderEth() external;

    function getCurrentTakeoverPrice() external view returns (uint256);

    function getTakeoverPrice(uint256 timestamp) external view returns (uint256);

    function getCurrentFurnaceEmissionRate() external view returns (uint256);

    // ------------------------------------------------------------
    // Delegation wiring / reign routing
    // ------------------------------------------------------------

    function setDelegationHub(address _delegationHub) external;

    function setCurrentReignRecipients(address ethRecipient, address claimRecipient) external;

    function getKingReigns(address king, uint256 cursor, uint256 limit)
        external
        view
        returns (uint256[] memory reignIds);

    function getReignInfo(uint256 reignId) external view returns (ReignInfo memory info);

    // ------------------------------------------------------------
    // King auto-lock configuration (optional)
    // ------------------------------------------------------------

    function setKingAutoLockConfig(
        bool enabled,
        uint256 targetTokenId,
        uint32 durationSeconds,
        bool createAutoMax,
        uint256 minVeOut
    ) external;

    function setKingAutoLockConfigForUser(
        address user,
        bool enabled,
        uint256 targetTokenId,
        uint32 durationSeconds,
        bool createAutoMax,
        uint256 minVeOut
    ) external;

    function getKingAutoLockConfig(address user)
        external
        view
        returns (
            bool enabled,
            uint256 targetTokenId,
            uint256 pinnedTokenId,
            uint32 durationSeconds,
            bool createAutoMax,
            uint256 minVeOut
        );

    // ------------------------------------------------------------
    // ve checkpoint maintenance (permissionless)
    // ------------------------------------------------------------

    function advanceVeCheckpoint() external;
}
