// SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

/// @notice Minimal Aerodrome v2 pool interface for skimming unexpected token balances.
/// @dev Aerodrome/Velodrome-style pools expose `skim(address)` to transfer any token balances
///      held in excess of the pool's tracked reserves.
/// @dev v2 commitment — LaunchController uses `skim` to recover stranded tokens.
///      A future v3 skim signature requires a coordinated update.
interface IAerodromePoolSkim {
    function skim(address to) external;
}
