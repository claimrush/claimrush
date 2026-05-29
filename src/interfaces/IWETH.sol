// SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

/// @notice Minimal WETH interface used by protocol contracts.
/// @dev External dependency interface.
/// @dev IWETH covers only wrap/unwrap (the WETH9-specific surface). For
///      ERC-20 ops on WETH (`balanceOf`, `transfer`, `transferFrom`,
///      `approve`, `allowance`, `totalSupply`), consumers cast to OZ
///      `IERC20(weth)`. This minimal slice avoids dragging the full WETH9
///      ABI into every consumer's import list when OZ's `IERC20` covers
///      the standard surface.
interface IWETH {
    function deposit() external payable;

    /// @notice Unwrap WETH into native ETH.
    function withdraw(uint256 amount) external;
}
