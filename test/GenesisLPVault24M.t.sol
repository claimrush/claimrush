// SPDX-License-Identifier: MIT
pragma solidity ^0.8.34;

import {Test} from "forge-std/Test.sol";

import {GenesisLPVault24M} from "src/vault/GenesisLPVault24M.sol";
import {Errors} from "src/lib/Errors.sol";

import {MockERC20} from "./mocks/MockERC20.sol";

contract GenesisLPVault24MTest is Test {
    MockERC20 internal lp;
    GenesisLPVault24M internal vault;

    address internal recipient = address(0xCAFE);
    address internal alice = address(0xA);

    function setUp() public {
        lp = new MockERC20("LP", "LP");
        vault = new GenesisLPVault24M(address(lp), recipient);
    }

    function testStartLockRequiresLpBalanceAndOnlyOnce() public {
        vm.expectRevert(GenesisLPVault24M.NoLp.selector);
        vault.startLock();

        lp.mint(address(vault), 123e18);

        vault.startLock();
        assertGt(vault.lockStartTime(), 0);
        assertEq(vault.lpLockedAmount(), 123e18);
        assertEq(vault.unlockTime(), vault.lockStartTime() + vault.INITIAL_LOCK_DURATION());

        vm.expectRevert(GenesisLPVault24M.LockAlreadyStarted.selector);
        vault.startLock();
    }

    function testExtendLockGuards() public {
        // Guard 1: only the LP withdraw recipient can extend the lock.
        vm.expectRevert(GenesisLPVault24M.OnlyLpWithdrawRecipient.selector);
        vault.extendLock(block.timestamp + 1);

        // Guard 2: lock must be started.
        vm.prank(recipient);
        vm.expectRevert(GenesisLPVault24M.LockNotStarted.selector);
        vault.extendLock(block.timestamp + 1);

        lp.mint(address(vault), 1e18);
        vault.startLock();

        uint256 unlockTime = vault.unlockTime();

        vm.prank(alice);
        vm.expectRevert(GenesisLPVault24M.OnlyLpWithdrawRecipient.selector);
        vault.extendLock(unlockTime + 1);

        vm.prank(recipient);
        vm.expectRevert(GenesisLPVault24M.UnlockTimeNotIncreased.selector);
        vault.extendLock(unlockTime);

        uint256 newUnlock = unlockTime + 7 days;
        vm.prank(recipient);
        vault.extendLock(newUnlock);
        assertEq(vault.unlockTime(), newUnlock);
    }

    function testWithdrawLpRevertsIfLockNotStarted() public {
        lp.mint(address(vault), 1e18);

        // Lock must be started before any withdrawal can occur.
        vm.prank(recipient);
        vm.expectRevert(GenesisLPVault24M.LockNotStarted.selector);
        vault.withdrawLp();
    }

    function testWithdrawLpOnlyAfterUnlockAndOnlyToRecipient() public {
        lp.mint(address(vault), 50e18);
        vault.startLock();

        vm.prank(recipient);
        vm.expectRevert(GenesisLPVault24M.UnlockTimeNotReached.selector);
        vault.withdrawLp();

        vm.warp(vault.unlockTime());

        vm.prank(recipient);
        vault.withdrawLp();

        assertEq(lp.balanceOf(recipient), 50e18);
        assertEq(lp.balanceOf(address(vault)), 0);
    }

    // extendLock rejects absurd newUnlockTime values such as type(uint256).max.
    // This keeps withdrawLp() reachable after the lock expires.
    function testExtendLockMaxUint256BricksWithdrawal() public {
        lp.mint(address(vault), 10e18);
        vault.startLock();

        uint256 absurdUnlock = type(uint256).max;
        vm.prank(recipient);
        vm.expectRevert(GenesisLPVault24M.ExtensionTooLong.selector);
        vault.extendLock(absurdUnlock);
    }

    // withdrawLp is single-use once the full vault balance is withdrawn.
    function testWithdrawLpEmitsZeroWhenVaultEmpty() public {
        lp.mint(address(vault), 1e18);
        vault.startLock();

        vm.warp(vault.unlockTime());
        vm.prank(recipient);
        vault.withdrawLp();
        assertEq(lp.balanceOf(address(vault)), 0);
        assertEq(lp.balanceOf(recipient), 1e18);

        // unlockTime clears after withdraw; the second call reverts with no idempotent zero emit.
        vm.prank(recipient);
        vm.expectRevert(GenesisLPVault24M.AlreadyWithdrawn.selector);
        vault.withdrawLp();
    }

    // startLock snapshots lpLockedAmount at lock start.
    function testStartLockIgnoresPostLockDonation() public {
        lp.mint(address(vault), 10e18);
        vault.startLock();
        assertEq(vault.lpLockedAmount(), 10e18);

        // Donate more LP after lock.
        lp.mint(address(vault), 5e18);
        assertEq(vault.lpLockedAmount(), 10e18);

        // After unlock, ALL LP is sent (including donation).
        vm.warp(vault.unlockTime());
        vm.prank(recipient);
        vault.withdrawLp();
        assertEq(lp.balanceOf(recipient), 15e18);
    }

    // Constructor rejects zero pool / zero recipient.
    function testConstructorRevertsOnZeroPool() public {
        vm.expectRevert();
        new GenesisLPVault24M(address(0), recipient);
    }

    function testConstructorRevertsOnZeroRecipient() public {
        vm.expectRevert();
        new GenesisLPVault24M(address(lp), address(0));
    }

    // -----------------------------------------------------------------
    // -----------------------------------------------------------------

    /// @dev Extend lock to exactly the current unlockTime must revert (strict increase).
    function testExtendLockRevertsOnEqualTime() public {
        lp.mint(address(vault), 1e18);
        vault.startLock();

        uint256 current = vault.unlockTime();
        vm.prank(recipient);
        vm.expectRevert(GenesisLPVault24M.UnlockTimeNotIncreased.selector);
        vault.extendLock(current);
    }

    /// @dev Extend lock to a time *less than* current must also revert.
    function testExtendLockRevertsOnShorterTime() public {
        lp.mint(address(vault), 1e18);
        vault.startLock();

        uint256 current = vault.unlockTime();
        vm.prank(recipient);
        vm.expectRevert(GenesisLPVault24M.UnlockTimeNotIncreased.selector);
        vault.extendLock(current - 1);
    }

    /// @dev Second withdrawLp after a full withdrawal reverts AlreadyWithdrawn.
    function testWithdrawLpIdempotentAfterFullWithdrawal() public {
        lp.mint(address(vault), 50e18);
        vault.startLock();

        vm.warp(vault.unlockTime());
        vm.prank(recipient);
        vault.withdrawLp();
        assertEq(lp.balanceOf(address(vault)), 0);
        assertEq(lp.balanceOf(recipient), 50e18);

        vm.prank(recipient);
        vm.expectRevert(GenesisLPVault24M.AlreadyWithdrawn.selector);
        vault.withdrawLp();
    }

    // ----------------------------------------------------------------
    // rescueEth
    // ----------------------------------------------------------------

    function testRescueEthSendsBalanceToRecipient() public {
        vm.deal(address(vault), 2 ether);

        uint256 before = recipient.balance;
        vm.prank(recipient);
        vault.rescueEth();

        assertEq(recipient.balance - before, 2 ether);
        assertEq(address(vault).balance, 0);
    }

    function testRescueEthEmitsTokenRescued() public {
        vm.deal(address(vault), 1 ether);

        vm.expectEmit(true, true, false, true);
        emit GenesisLPVault24M.TokenRescued(address(0), recipient, 1 ether);

        vm.prank(recipient);
        vault.rescueEth();
    }

    function testRescueEthRevertsForNonRecipient() public {
        vm.deal(address(vault), 1 ether);

        vm.prank(alice);
        vm.expectRevert(GenesisLPVault24M.OnlyLpWithdrawRecipient.selector);
        vault.rescueEth();
    }

    function testRescueEthRevertsWhenNoEth() public {
        vm.prank(recipient);
        vm.expectRevert(GenesisLPVault24M.NoTokenToRescue.selector);
        vault.rescueEth();
    }

    function testRescueEthRevertsWhenRecipientRejectsEth() public {
        EthRejecter rejecter = new EthRejecter();
        GenesisLPVault24M v = new GenesisLPVault24M(address(lp), address(rejecter));
        vm.deal(address(v), 1 ether);

        vm.prank(address(rejecter));
        vm.expectRevert(Errors.EthTransferFailed.selector);
        v.rescueEth();
    }
}

/// @dev Helper that rejects incoming ETH to exercise the transfer-failed path.
contract EthRejecter {
    receive() external payable {
        revert("no ETH");
    }
}
