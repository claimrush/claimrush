// SPDX-License-Identifier: MIT
pragma solidity ^0.8.34;

import {MineCore} from "src/MineCore.sol";

/// @notice Minimal contract with bytecode for wiring validation tests.
/// @dev Used when setter functions require addresses to be contracts (code.length > 0).
contract MockContract {
    function noop() external pure {}

    function collectGenesisKingClaim(MineCore mineCoreAddr, address to) external returns (uint256 claimMinted) {
        return mineCoreAddr.collectGenesisKingClaim(to);
    }
}
