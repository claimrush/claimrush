// SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

/// @notice Minimal lens interface used by FurnaceQuoter to read the
///         current LP overflow drip rate from Furnace.
/// @dev Furnace `is IFurnaceDripLens` so this interface is part of the pinned ABI.
interface IFurnaceDripLens {
    function getLpOverflowDripPerDay() external view returns (uint256);
}
