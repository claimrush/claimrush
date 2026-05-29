// SPDX-License-Identifier: MIT
pragma solidity ^0.8.34;

import {Test} from "forge-std/Test.sol";

import {GenesisLPVault24M} from "src/vault/GenesisLPVault24M.sol";
import {MockERC20} from "./mocks/MockERC20.sol";

/// @notice regression tests for GenesisLPVault24M boundary conditions.
contract GenesisLPVault24M_BoundaryConditionsTest is Test {
    MockERC20 internal lp;
    GenesisLPVault24M internal vault;

    address internal recipient = address(0xCAFE);
    address internal caller = address(0xBEEF);

    function setUp() public {
        lp = new MockERC20("LP", "LP");
        vault = new GenesisLPVault24M(address(lp), recipient);
    }

    function test_startLockRevertsBelowMinLpLock() public {
        uint256 minLock = vault.MIN_LP_LOCK();
        lp.mint(address(vault), minLock - 1);

        vm.expectRevert(GenesisLPVault24M.DustLock.selector);
        vault.startLock();
    }

    function test_startLockAcceptsExactlyMinLpLock() public {
        uint256 minLock = vault.MIN_LP_LOCK();
        lp.mint(address(vault), minLock);

        vault.startLock();

        assertEq(vault.lpLockedAmount(), minLock);
        assertEq(vault.lockStartTime(), block.timestamp);
        assertEq(vault.unlockTime(), block.timestamp + vault.INITIAL_LOCK_DURATION());
    }

    function test_extendLockRevertsAfterWithdrawal() public {
        uint256 amount = vault.MIN_LP_LOCK() + 1;
        lp.mint(address(vault), amount);
        vault.startLock();

        vm.warp(vault.unlockTime());
        vm.prank(recipient);
        vault.withdrawLp();

        vm.prank(recipient);
        vm.expectRevert(GenesisLPVault24M.AlreadyWithdrawn.selector);
        vault.extendLock(block.timestamp + 1 days);
    }

    function test_withdrawLpResidualDonationAfterFullWithdrawalStillRoutesToRecipient() public {
        uint256 lockedAmount = vault.MIN_LP_LOCK() + 5e18;
        lp.mint(address(vault), lockedAmount);
        vault.startLock();

        vm.warp(vault.unlockTime());
        vm.prank(recipient);
        vault.withdrawLp();
        assertEq(lp.balanceOf(recipient), lockedAmount);

        uint256 donatedAfterWithdraw = 7e18;
        lp.mint(address(vault), donatedAfterWithdraw);

        vm.prank(recipient);
        vault.withdrawLp();

        assertEq(lp.balanceOf(recipient), lockedAmount + donatedAfterWithdraw);
        assertEq(lp.balanceOf(caller), 0);
        assertEq(lp.balanceOf(address(vault)), 0);
    }
}
