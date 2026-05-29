// SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

/// @notice Minimal view surface for reading a ve lock's last mutation timestamp.
/// @dev Furnace AutoMax bonus accrual uses this as a floor so newly added principal
///      or autoMax mode changes cannot inherit an earlier accrual window.
interface IVeClaimNFTLockStartView {
    function lockStartOf(uint256 tokenId) external view returns (uint256);
}
