// SPDX-License-Identifier: MIT
pragma solidity ^0.8.34;

import {Test} from "forge-std/Test.sol";
import {GenesisLPVault24M} from "src/vault/GenesisLPVault24M.sol";
import {Errors} from "src/lib/Errors.sol";
import {MockERC20} from "./mocks/MockERC20.sol";

/// @notice Regression tests for GenesisLPVault24M edge cases.
contract GenesisLPVault24M_RegressionTest is Test {
    MockERC20 internal poolToken;
    GenesisLPVault24M internal vault;

    address internal recipient = address(0xBEEF);
    address internal attacker = address(0xDEAD);

    function setUp() public {
        poolToken = new MockERC20("LP", "LP");
        vault = new GenesisLPVault24M(address(poolToken), recipient);
    }

    /// @dev withdrawLp before startLock must revert even though unlockTime == 0.
    ///      Without the lockStartTime guard, unlockTime == 0 means block.timestamp >= 0
    ///      would always be true, bypassing the time-lock entirely.
    function test_withdrawLpRevertsBeforeStartLock() public {
        poolToken.mint(address(vault), 100e18);

        vm.prank(recipient);
        vm.expectRevert(GenesisLPVault24M.LockNotStarted.selector);
        vault.withdrawLp();
    }

    /// @dev startLock is permissionless. Verify that a third party cannot
    ///      grief by calling startLock before LP is deposited.
    function test_startLockRevertsWithZeroLpBalance() public {
        vm.expectRevert(GenesisLPVault24M.NoLp.selector);
        vault.startLock();
    }

    /// @dev Double-call to startLock must revert.
    function test_startLockRevertsIfAlreadyStarted() public {
        poolToken.mint(address(vault), 100e18);
        vault.startLock();

        vm.expectRevert(GenesisLPVault24M.LockAlreadyStarted.selector);
        vault.startLock();
    }

    /// @dev LP donated after startLock is included in withdrawLp but does NOT
    ///      update lpLockedAmount (informational accounting only).
    function test_donatedLpIncludedInWithdrawal() public {
        poolToken.mint(address(vault), 100e18);
        vault.startLock();

        assertEq(vault.lpLockedAmount(), 100e18);

        // Donate additional LP.
        poolToken.mint(address(vault), 50e18);

        // lpLockedAmount unchanged.
        assertEq(vault.lpLockedAmount(), 100e18);

        // Warp past unlock.
        vm.warp(vault.unlockTime());
        vm.prank(recipient);
        vault.withdrawLp();

        // Recipient receives all LP (including donation).
        assertEq(poolToken.balanceOf(recipient), 150e18);
    }

    /// @dev extendLock to type(uint256).max is now rejected with ExtensionTooLong.
    function test_extendLockToMaxBricksWithdrawal() public {
        poolToken.mint(address(vault), 100e18);
        vault.startLock();

        vm.prank(recipient);
        vm.expectRevert(GenesisLPVault24M.ExtensionTooLong.selector);
        vault.extendLock(type(uint256).max);
    }
}
