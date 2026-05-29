// SPDX-License-Identifier: MIT
pragma solidity ^0.8.34;

import {Test} from "forge-std/Test.sol";
import {GenesisLPVault24M} from "src/vault/GenesisLPVault24M.sol";
import {MockERC20} from "./mocks/MockERC20.sol";

/// @title Edge-case and fuzz tests for GenesisLPVault24M.
/// @dev Covers gaps: boundary timing, LP donation post-lock, minimum extension, fuzz durations.
contract GenesisLPVault24MEdgeCasesTest is Test {
    MockERC20 internal lp;
    GenesisLPVault24M internal vault;
    address internal recipient = address(0xCAFE);

    function setUp() public {
        lp = new MockERC20("LP", "LP");
        vault = new GenesisLPVault24M(address(lp), recipient);
    }

    // ── Exact unlock boundary ───────────────────────────────────────

    function testWithdrawAtExactUnlockTime() public {
        lp.mint(address(vault), 100e18);
        vault.startLock();

        uint256 unlockTime = vault.unlockTime();
        vm.warp(unlockTime); // exactly at unlock

        vm.prank(recipient);
        vault.withdrawLp();
        assertEq(lp.balanceOf(recipient), 100e18);
    }

    function testWithdrawOneSecondBeforeUnlockReverts() public {
        lp.mint(address(vault), 100e18);
        vault.startLock();

        uint256 unlockTime = vault.unlockTime();
        vm.warp(unlockTime - 1);

        vm.prank(recipient);
        vm.expectRevert(GenesisLPVault24M.UnlockTimeNotReached.selector);
        vault.withdrawLp();
    }

    // ── LP donations after lock ─────────────────────────────────────

    function testLpDonationAfterStartLockIsIncludedInWithdrawal() public {
        lp.mint(address(vault), 100e18);
        vault.startLock();

        // Donate more LP tokens after lock started
        lp.mint(address(vault), 50e18);

        vm.warp(vault.unlockTime());
        vm.prank(recipient);
        vault.withdrawLp();

        // Should withdraw ALL LP, not just locked amount
        assertEq(lp.balanceOf(recipient), 150e18);
    }

    // ── Minimal extension ───────────────────────────────────────────

    function testExtendLockByOneSecond() public {
        lp.mint(address(vault), 1e18);
        vault.startLock();

        uint256 unlockBefore = vault.unlockTime();

        vm.prank(recipient);
        vault.extendLock(unlockBefore + 1);

        assertEq(vault.unlockTime(), unlockBefore + 1);
    }

    // ── Double withdrawal attempt ───────────────────────────────────

    function testDoubleWithdrawDrainsAllThenZero() public {
        lp.mint(address(vault), 100e18);
        vault.startLock();

        vm.warp(vault.unlockTime());
        vm.prank(recipient);
        vault.withdrawLp();
        assertEq(lp.balanceOf(recipient), 100e18);

        vm.prank(recipient);
        vm.expectRevert(GenesisLPVault24M.AlreadyWithdrawn.selector);
        vault.withdrawLp();
        assertEq(lp.balanceOf(recipient), 100e18);
    }

    // ── Recipient-only withdrawal ──────────────────────────────────

    function testRecipientCanCallWithdrawAndFundsGoToRecipient() public {
        lp.mint(address(vault), 100e18);
        vault.startLock();

        vm.warp(vault.unlockTime());

        vm.prank(recipient);
        vault.withdrawLp();

        assertEq(lp.balanceOf(recipient), 100e18);
    }

    function testNonRecipientCannotCallWithdraw() public {
        lp.mint(address(vault), 100e18);
        vault.startLock();

        vm.warp(vault.unlockTime());

        address attacker = address(0xBAD);
        vm.prank(attacker);
        vm.expectRevert(GenesisLPVault24M.OnlyLpWithdrawRecipient.selector);
        vault.withdrawLp();
    }

    // ── Fuzz tests ──────────────────────────────────────────────────

    function testFuzz_ExtendLockNeverShortens(uint256 newUnlock) public {
        lp.mint(address(vault), 1e18);
        vault.startLock();

        uint256 unlockBefore = vault.unlockTime();
        newUnlock = bound(newUnlock, 0, unlockBefore);

        vm.prank(recipient);
        vm.expectRevert(GenesisLPVault24M.UnlockTimeNotIncreased.selector);
        vault.extendLock(newUnlock);

        assertEq(vault.unlockTime(), unlockBefore, "unlock time must not change");
    }
}
