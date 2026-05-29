// SPDX-License-Identifier: MIT
pragma solidity ^0.8.34;

import {MockERC20} from "./MockERC20.sol";

/// @notice Aerodrome pool mock used by GenesisLPVault24M tests.
/// @dev Also acts as the LP token (ERC20) that the vault locks.
contract MockAerodromePool is MockERC20 {
    MockERC20 public immutable WETH;
    MockERC20 public immutable CLAIM;

    uint256 public nextWethFee;
    uint256 public nextClaimFee;
    bool public revertOnClaimFees;

    constructor(address weth_, address claim_) MockERC20("MockLP", "MLP") {
        WETH = MockERC20(weth_);
        CLAIM = MockERC20(claim_);
    }

    function setNextFees(uint256 wethFee, uint256 claimFee) external {
        nextWethFee = wethFee;
        nextClaimFee = claimFee;
    }

    function setRevertOnClaimFees(bool shouldRevert) external {
        revertOnClaimFees = shouldRevert;
    }

    /// @notice Mimics Aerodrome BasePool.claimFees().
    /// @dev Mints the configured fee amounts to the caller.
    function claimFees() external returns (uint256 claimed0, uint256 claimed1) {
        if (revertOnClaimFees) revert("MockAerodromePool: claimFees revert");

        claimed0 = nextWethFee;
        claimed1 = nextClaimFee;

        if (claimed0 != 0) WETH.mint(msg.sender, claimed0);
        if (claimed1 != 0) CLAIM.mint(msg.sender, claimed1);

        // Reset to make repeated harvests explicit in tests.
        nextWethFee = 0;
        nextClaimFee = 0;
    }
}
