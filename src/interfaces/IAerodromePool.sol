// SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

/// @notice Minimal Aerodrome v2 pool interface used by LpStakingVault7D (fee harvest)
///         and GenesisLPVault24M (fee claim + forward at LP unlock).
/// @dev Aerodrome v2 pools expose claimFees() on Base. token0() / token1() are
///      Aerodrome-immutable; safe to read repeatedly without staleness concerns.
/// @dev v2 commitment — any future Aerodrome v3 pool deployment with a
///      different fee-claim ABI requires a coordinated update.
interface IAerodromePool {
    function claimFees() external returns (uint256 claimed0, uint256 claimed1);

    function token0() external view returns (address);

    function token1() external view returns (address);
}
