// SPDX-License-Identifier: MIT
pragma solidity ^0.8.34;

import {Furnace} from "src/Furnace.sol";
import {FurnaceGuardHelper} from "src/FurnaceGuardHelper.sol";

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

/// @dev Test-only harness to exercise Furnace's internal swap helpers without
///      pulling in the full ve-locking entrypoint.
contract FurnaceSwapHarness is Furnace {
    using SafeERC20 for IERC20;

    constructor(address claim_, address ve_, address initialOwner)
        Furnace(claim_, ve_, address(new FurnaceGuardHelper(claim_, ve_)), initialOwner)
    {}

    /// @dev Pulls `amountIn` from msg.sender, then swaps to CLAIM via the configured registry/router.
    function exposedSwapTokenToClaimFrom(address tokenIn, uint256 amountIn)
        external
        returns (uint256 principalClaimOut)
    {
        IERC20(tokenIn).safeTransferFrom(msg.sender, address(this), amountIn);
        principalClaimOut = _swapTokenToClaim(tokenIn, amountIn);
    }

    /// @dev Directly swaps msg.value ETH to CLAIM via the configured registry/router.
    function exposedSwapEthToClaim() external payable returns (uint256 principalClaimOut) {
        principalClaimOut = _swapEthToClaim(msg.value);
    }
}
