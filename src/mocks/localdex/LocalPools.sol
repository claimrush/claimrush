// SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

import {LocalAerodromePool} from "./LocalAerodromePool.sol";

/// @notice Named pool wrappers to make Foundry broadcast parsing deterministic.

contract LocalClaimWethPool is LocalAerodromePool {
    uint256 internal constant CLAIM_PER_WETH = 500_000;

    address public immutable claimToken;
    address public immutable wethToken;

    constructor(address claim, address weth) LocalAerodromePool(claim, weth, false) {
        claimToken = claim;
        wethToken = weth;
    }

    function quoteOut(address tokenIn, uint256 amountIn) public view override returns (uint256 amountOut) {
        if (tokenIn == wethToken) return amountIn * CLAIM_PER_WETH;
        if (tokenIn == claimToken) return amountIn / CLAIM_PER_WETH;
        revert NotToken();
    }
}

contract LocalEntryWethPool is LocalAerodromePool {
    constructor(address entry, address weth) LocalAerodromePool(entry, weth, false) {}
}

contract LocalEntryClaimPool is LocalAerodromePool {
    constructor(address entry, address claim) LocalAerodromePool(entry, claim, false) {}
}
