// SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

import {MintableERC20} from "../MintableERC20.sol";

/// @notice Default entry token used for local Path B end-to-end testing.
contract LocalEntryToken is MintableERC20 {
    constructor() MintableERC20("Local Entry Token", "LENT", 18) {}
}
