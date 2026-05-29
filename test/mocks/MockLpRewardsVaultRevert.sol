// SPDX-License-Identifier: MIT
pragma solidity ^0.8.34;

/// @notice LP rewards vault mock that always reverts on notify.
/// @dev Used to assert Furnace does not brick locking when LP vault notify fails.
contract MockLpRewardsVaultRevert {
    error NotifyReverted();

    function notifyRewards(uint256) external pure {
        revert NotifyReverted();
    }
}

