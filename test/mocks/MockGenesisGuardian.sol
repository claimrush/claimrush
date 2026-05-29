// SPDX-License-Identifier: MIT
pragma solidity ^0.8.34;

import {MineCore} from "src/MineCore.sol";

/// @dev Minimal LaunchController-like guardian used in MineCore tests.
contract MockGenesisGuardian {
    address public mineCore;
    address public claim;

    function setRoots(address mineCoreRoot, address claimRoot) external {
        mineCore = mineCoreRoot;
        claim = claimRoot;
    }

    function collectGenesisKingClaim(MineCore mineCoreAddr, address to) external returns (uint256 claimMinted) {
        return mineCoreAddr.collectGenesisKingClaim(to);
    }

    function unpauseTakeovers(MineCore mineCoreAddr) external {
        mineCoreAddr.setTakeoversPaused(false);
    }
}
