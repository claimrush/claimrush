// SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

/// @notice Minimal pool mint interface used by LaunchController to mint LP.
/// @dev External dependency interface (Aerodrome v2 pool style).
/// @dev v2 commitment — LaunchController calls `mint(to)` once during genesis.
///      A future Aerodrome v3 mint signature requires a coordinated update.
interface IAerodromePoolMint {
    function mint(address to) external returns (uint256 liquidity);
}
