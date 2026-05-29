// SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

import {LocalAerodromePool} from "./LocalAerodromePool.sol";

/// @notice USDT/WETH pool mock with realistic pricing (~2500 USDT per WETH).
contract LocalUsdtWethPool is LocalAerodromePool {
    address public immutable usdtToken;
    address public immutable wethToken;

    constructor(address usdt, address weth) LocalAerodromePool(usdt, weth, false) {
        usdtToken = usdt;
        wethToken = weth;
    }

    function quoteOut(address tokenIn, uint256 amountIn) public view override returns (uint256 amountOut) {
        if (tokenIn == usdtToken) {
            // USDT (6 dec) -> WETH (18 dec): 2500 USDT = 1 WETH
            return (amountIn * 1e12) / 2500;
        }
        if (tokenIn == wethToken) {
            // WETH (18 dec) -> USDT (6 dec): 1 WETH = 2500 USDT
            return (amountIn * 2500) / 1e12;
        }
        revert NotToken();
    }
}
