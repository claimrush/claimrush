// SPDX-License-Identifier: MIT
pragma solidity ^0.8.34;

import {MockERC20} from "./MockERC20.sol";

/// @notice Minimal WETH-style wrapper for tests.
/// @dev 1:1 mint/burn against native ETH held by this contract.
contract MockWETH is MockERC20 {
    constructor() MockERC20("Wrapped Ether", "WETH") {}

    receive() external payable {}

    function deposit() external payable {
        _mint(msg.sender, msg.value);
    }

    function withdraw(uint256 amount) external {
        _burn(msg.sender, amount);
        (bool ok,) = msg.sender.call{value: amount}("");
        require(ok, "MockWETH: ETH transfer failed");
    }
}
