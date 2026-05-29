// SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

/// @notice Minimal pool factory interface used by LaunchController.
/// @dev External dependency interface (Aerodrome-style pool factory: getPool / createPool).
/// @dev v2 commitment — Aerodrome v2 PoolFactory on Base. v3 factories may
///      add a fee-tier parameter to `getPool` / `createPool`; any such
///      migration requires a coordinated interface + EntryTokenRegistry +
///      LaunchController update.
interface IPoolFactory {
    function getPool(address tokenA, address tokenB, bool stable) external view returns (address pool);

    function createPool(address tokenA, address tokenB, bool stable) external returns (address pool);
}
