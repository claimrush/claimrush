// SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

// MarketRouter ABI are absent from this interface.
//
//   Admin setters (intentionally omitted — acceptable):
//     setGuardian, pauseTrading, setBonusTargetEscrowParams,
//     acceptOwnership, renounceOwnership, transferOwnership
//
//   Public state variable getters (auto-generated — acceptable):
//     claim, ve, royalties, guardian, tradingPaused,
//     nextOfferId, minBonusTargetEscrowBudget, maxBonusTargetEscrowDiscountBps,
//     listings, offers, bonusTargetConfigs, lastListingActionBlock,
//     owner, pendingOwner
//
//   NOTE: tradingPaused() and nextOfferId() are already declared below.
//   MarketRouter does NOT expose a delegationHub state variable.
//

/// @notice Minimal MarketRouter interface for protocol integrations (strict Furnace-only settlement mode).
interface IMarketRouter {
    struct Listing {
        address seller;
        uint256 minClaimOut;
        uint256 listedAtTime;
        uint256 expiresAtTime;
        bool active;
    }

    /// @notice Bonus-target global offer (escrows CLAIM and auto-enters Furnace when target bonus is met).
    struct BonusTargetEscrow {
        address buyer;
        uint256 discountBps;
        uint256 durationSeconds;
        bool createAutoMax;
        uint256 destinationLockId;
        uint256 fundsRemaining;
        uint256 createdAt;
        uint256 expiresAt;
        bool active;
    }

    // Listings
    function listLock(uint256 tokenId, uint256 minClaimOut, uint256 expiresAtTime) external;
    function delistLock(uint256 tokenId) external;
    function cancelExpiredListing(uint256 tokenId) external;
    function cancelExpiredListingBatch(uint256[] calldata tokenIds) external;
    function emergencyDelist(uint256 tokenId) external;

    /// @notice Market sell (unlisted or listed) directly into the Furnace. Market performs the NFT transfer.
    function sellLockToFurnace(uint256 tokenId, uint256 minClaimOut, uint256 deadline)
        external
        returns (uint256 claimOut);

    /// @notice Keeper-priority settlement of a listed lock into the Furnace, respecting Listing.minClaimOut.
    /// @dev During SETTLEMENT_KEEPER_GRACE_SECONDS, only allowlisted settlement keepers or owner may settle
    ///      active listings; after that, settlement is permissionless.
    function sellListedLockToFurnace(uint256 tokenId, uint256 deadline) external returns (uint256 claimOut);

    // Bonus-target offers (escrow + autoFurnace)
    /// @notice Create a global bonus-target offer that auto-furnaces when the target bonus is met.
    /// @dev Escrows `budgetClaim` CLAIM. Caller MUST `approve` MarketRouter for the budget first.
    function createBonusTargetEscrowWithTarget(
        uint256 targetBonusBps,
        uint256 budgetClaim,
        uint256 durationSeconds,
        bool createAutoMax,
        uint256 escrowTtlSeconds,
        uint256 destinationLockId,
        uint256 slippageBps
    ) external returns (uint256 offerId);

    function cancelBonusTargetEscrow(uint256 offerId) external;
    function cancelExpiredBonusTargetEscrow(uint256 offerId) external;
    function cancelExpiredBonusTargetEscrowBatch(uint256[] calldata offerIds) external;
    function extendBonusTargetEscrowExpiry(uint256 offerId, uint256 newExpiresAt) external;

    function getBonusTargetEscrowExpiryBounds(uint256 offerId)
        external
        view
        returns (uint256 createdAt, uint256 expiresAt, uint256 maxExpiresAt);

    /// @notice Keeper-priority bonus-target execution into the Furnace.
    /// @dev During SETTLEMENT_KEEPER_GRACE_SECONDS, only allowlisted settlement keepers or owner may execute;
    ///      after that, execution is permissionless when the target bonus is met.
    function executeAutoFurnace(uint256 offerId, uint256 deadline) external;

    // Settlement keeper priority (MEV protection)
    function setSettlementKeeper(address keeper, bool allowed) external;
    function isSettlementKeeper(address) external view returns (bool);

    // View helpers
    function getListing(uint256 tokenId) external view returns (Listing memory);
    function getUserListings(address user) external view returns (uint256[] memory);
    function getUserListingsPaginated(address user, uint256 offset, uint256 limit)
        external
        view
        returns (uint256[] memory ids, bool hasMore);
    function getBonusTargetEscrow(uint256 offerId) external view returns (BonusTargetEscrow memory);
    function getUserBonusTargetEscrows(address user) external view returns (uint256[] memory);
    function getUserBonusTargetEscrowsPaginated(address user, uint256 offset, uint256 limit)
        external
        view
        returns (uint256[] memory ids, bool hasMore);

    function tradingPaused() external view returns (bool);

    function nextOfferId() external view returns (uint256);
}
