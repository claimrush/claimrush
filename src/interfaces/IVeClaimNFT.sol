// SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

import {IVeClaimNFTLockStartView} from "./IVeClaimNFTLockStartView.sol";

/// @notice Minimal external API for VeClaimNFT expected by the rest of the protocol.
/// @dev Inherits the slim `lockStartOf(uint256)` slice so any change to that
///      single-function view is shared between callers that only need the
///      accrual-floor pointer (Furnace AutoMax) and callers that need the full
///      lock surface (Market, ShareholderRoyalties, etc.).
interface IVeClaimNFT is IVeClaimNFTLockStartView {
    // ERC-721 — only ownerOf is needed protocol-wide; for transfers cast to IERC721.
    function ownerOf(uint256 tokenId) external view returns (address);

    /// @notice ID that will be assigned to the next minted lock.
    function nextTokenId() external view returns (uint256);

    // Lock info
    function getLockInfo(uint256 tokenId)
        external
        view
        returns (uint256 amount, uint256 lockEnd, bool autoMax, bool listed);

    // Aggregate ve + principal
    function veBalanceOf(address user) external view returns (uint256);
    function totalLockedClaim() external view returns (uint256);
    function totalVeCached() external view returns (uint256);
    /// @notice Current processed total ve-bias used by ShareholderRoyalties.
    /// @dev Units are "ve * 1e18" and freshness is bounded by `globalLastTs()`.
    function totalVeBiasScaled() external view returns (uint256);
    /// @notice Current total ve (view, no checkpoint). UI denominator with freshness bound to `globalLastTs()`.
    /// @dev Uses ceilDiv (slightly high) vs veBalanceOf's floor rounding, so
    ///      sum(veBalanceOf) <= totalVeCurrent(). The dominant integer gap is the
    ///      per-lock floor term on active non-AutoMax balances; conservative slope
    ///      rounding and residual dust add a tiny tail bounded by active non-AutoMax
    ///      locks plus pending early-removal buckets.
    function totalVeCurrent() external view returns (uint256);

    /// @notice Current lock parameters used by ShareholderRoyalties to reconstruct delayed rewards.
    /// @dev Arrays are parallel and include expired-but-not-yet-unlocked locks so rewards accrued before expiry
    ///      can still be checkpointed correctly.
    function getShareholderLockParams(address user)
        external
        view
        returns (uint256[] memory amounts, uint256[] memory lockEnds, bool[] memory autoMaxFlags);

    // Global checkpointing
    function checkpointGlobalState() external;
    function checkpointTotalVe() external;

    /// @notice Last timestamp fully processed by the global ve checkpoint.
    /// @dev Used by MineCore for gas-guarded checkpoint loops.
    function globalLastTs() external view returns (uint256);

    /// @notice Wired Furnace contract (permissioned minter/locker for veCLAIM).
    function furnace() external view returns (address);

    // Delegated lock maintenance (safe, non-custodial)
    function unlockExpiredForUser(address user, uint256 tokenId) external;

    // Furnace-only merge sibling of `extendLockToFor` / `addToLockFor`.
    /// @notice Merge `fromTokenId` into `intoTokenId` for `user`. Furnace-only.
    /// @dev User-facing merge is `Furnace.mergeLocksWithBonus(...)`, which routes through this
    ///      function so the bonus engine and lock math share a single ownership/auth path.
    function mergeLocksFor(address user, uint256 fromTokenId, uint256 intoTokenId)
        external
        returns (uint256 fromAmt, uint256 newAmt, uint256 newEnd, bool newAutoMax);

    function setAutoMax(uint256 tokenId, bool enabled) external;
    function unlock(uint256 tokenId) external;

    /// @notice Furnace-only: burn a lock held in Furnace custody and withdraw underlying principal.
    function furnaceBurnAndWithdraw(uint256 tokenId, address to) external returns (uint256 amount);

    // Furnace routing helpers
    function createLockFor(address user, uint256 amount, uint256 duration, bool autoMax)
        external
        returns (uint256 tokenId);
    function addToLockFor(address user, uint256 tokenId, uint256 amount) external;
    function extendLockToFor(address user, uint256 tokenId, uint256 newEnd) external;

    // ERC-721 + ERC-7572 metadata views
    function baseURI() external view returns (string memory);
    function contractURI() external view returns (string memory);

    // Marketplace coordination
    function setListed(uint256 tokenId, bool listed) external;
}
