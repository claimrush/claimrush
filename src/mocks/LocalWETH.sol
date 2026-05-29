// SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IWETH} from "../interfaces/IWETH.sol";

/// @notice Minimal WETH-style wrapper for local testing.
/// @dev Not intended for production.
contract LocalWETH is ERC20, IWETH {
    constructor() ERC20("Wrapped Ether", "WETH") {}

    function deposit() external payable {
        _mint(msg.sender, msg.value);
    }

    function withdraw(uint256 amount) external {
        _burn(msg.sender, amount);
        (bool ok,) = msg.sender.call{value: amount}("");
        require(ok, "WETH_WITHDRAW_FAILED");
    }

    receive() external payable {
        _mint(msg.sender, msg.value);
    }
}
