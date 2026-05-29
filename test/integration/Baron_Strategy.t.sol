// SPDX-License-Identifier: MIT
pragma solidity ^0.8.34;

import {Test} from "forge-std/Test.sol";

import {GenesisLPVault24M} from "src/vault/GenesisLPVault24M.sol";

import {MockERC20} from "test/mocks/MockERC20.sol";

contract BaronStrategyIT is Test {
    address internal recipient = address(0xBEEF);

    MockERC20 internal lp;
    GenesisLPVault24M internal vault;

    function setUp() public {
        lp = new MockERC20("LP", "LP");
        vault = new GenesisLPVault24M(address(lp), recipient);
    }

    function testLockAndWithdrawDoesNotBreakInvariants() public {
        // Lock some LP.
        lp.mint(address(vault), 1e18);
        vault.startLock();

        assertTrue(vault.lockStartTime() != 0);
        assertTrue(vault.unlockTime() > block.timestamp);

        vm.warp(vault.unlockTime());
        vm.prank(recipient);
        vault.withdrawLp();

        assertEq(lp.balanceOf(recipient), 1e18);
        assertEq(lp.balanceOf(address(vault)), 0);
    }
}
