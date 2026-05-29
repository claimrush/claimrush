// SPDX-License-Identifier: MIT
pragma solidity ^0.8.34;

import {ClaimToken} from "src/ClaimToken.sol";
import {MockAerodromeRouter} from "./MockAerodromeRouter.sol";
import {MockERC20} from "./MockERC20.sol";

/// @dev Aerodrome-style router mock that is also a valid `ClaimToken` MineCore root for tests:
///      real `claim()` / `ve()` / `furnace()` / `royalties()` + freeze-time getters, and `mint` on
///      ETH→CLAIM swap via `onlyMineCore` (this contract address).
contract MockAerodromeRouterMineCore is MockAerodromeRouter {
    address public immutable claimToken;
    address public immutable veAddr;
    address public immutable furnaceAddr;
    address public immutable royaltiesAddr;

    constructor(address factory_, address weth_, address claimToken_, address ve_, address furnace_, address royalties_)
        MockAerodromeRouter(factory_, weth_)
    {
        claimToken = claimToken_;
        veAddr = ve_;
        furnaceAddr = furnace_;
        royaltiesAddr = royalties_;
    }

    function claim() external view returns (address) {
        return claimToken;
    }

    function ve() external view returns (address) {
        return veAddr;
    }

    function furnace() external view returns (address) {
        return furnaceAddr;
    }

    function royalties() external view returns (address) {
        return royaltiesAddr;
    }

    function emissionStartTime() external pure returns (uint256) {
        return 1;
    }

    function GENESIS_ACCRUAL_DURATION() external pure returns (uint256) {
        return 604800;
    }

    /// @dev Furnace `setEntryTokenRegistry` staticcalls MineCore; return zero so registry != MineCore’s (unset).
    function entryTokenRegistry() external pure returns (address) {
        return address(0);
    }

    function getFurnaceEmissionRateAt(uint256) external pure returns (uint256) {
        return 0;
    }

    /// @inheritdoc MockAerodromeRouter
    function swapExactETHForTokens(uint256 amountOutMin, Route[] calldata routes, address to, uint256 deadline)
        external
        payable
        override
        returns (uint256[] memory amounts)
    {
        lastEthValue = msg.value;
        lastAmountOutMin = amountOutMin;
        lastTo = to;
        lastDeadline = deadline;
        lastRoutesHash = keccak256(abi.encode(routes));

        amounts = this.getAmountsOut(msg.value, routes);
        uint256 out = amounts[amounts.length - 1];
        require(out >= amountOutMin, "MockAerodromeRouter: slippage");

        Route memory last = routes[routes.length - 1];
        if (last.to == claimToken) {
            ClaimToken(claimToken).mint(to, out);
        } else {
            MockERC20(last.to).mint(to, out);
        }
    }
}
