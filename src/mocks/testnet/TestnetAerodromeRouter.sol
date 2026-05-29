// SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

import {IDexAdapter} from "../../interfaces/IDexAdapter.sol";
import {TestnetAerodromeFactory} from "./TestnetAerodromeFactory.sol";

/// @notice Minimal Aerodrome router mock for testnet deployments.
/// @dev Implements the IDexAdapter view surface that Deploy.s.sol and
///      DexAdapter require: `defaultFactory()`, `weth()`, `poolFor()`.
///      Swap functions revert — they are not needed for Lock Now testing
///      with direct CLAIM token entries.
contract TestnetAerodromeRouter is IDexAdapter {
    address public immutable defaultFactory;
    address public immutable weth;

    constructor(address factory_, address weth_) {
        require(factory_ != address(0) && weth_ != address(0), "ZERO_ADDR");
        defaultFactory = factory_;
        weth = weth_;
    }

    function poolFor(address tokenA, address tokenB, bool stable, address factory) public view returns (address) {
        return TestnetAerodromeFactory(factory).getPool(tokenA, tokenB, stable);
    }

    function getAmountsOut(uint256, Route[] calldata) external pure returns (uint256[] memory) {
        revert("TestnetRouter: swaps not supported");
    }

    function swapExactETHForTokens(uint256, Route[] calldata, address, uint256)
        external
        payable
        returns (uint256[] memory)
    {
        revert("TestnetRouter: swaps not supported");
    }

    function swapExactTokensForTokens(uint256, uint256, Route[] calldata, address, uint256)
        external
        returns (uint256[] memory)
    {
        revert("TestnetRouter: swaps not supported");
    }
}
