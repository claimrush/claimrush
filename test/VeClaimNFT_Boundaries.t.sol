// SPDX-License-Identifier: MIT
pragma solidity ^0.8.34;

import {Test} from "forge-std/Test.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {ClaimToken} from "src/ClaimToken.sol";
import {Errors} from "src/lib/Errors.sol";
import {Constants} from "src/lib/Constants.sol";
import {VeClaimNFTHarness} from "./mocks/VeClaimNFTHarness.sol";
import {MockShareholderRoyaltiesCheckpoint} from "./mocks/MockShareholderRoyaltiesCheckpoint.sol";

/// @title Boundary-condition and edge-case tests for VeClaimNFT.
/// @dev Covers gaps: min/max duration, min amount, per-user cap, AutoMax semantics,
///      listed lock mutations, ve balance decay, fuzz lock params.
contract VeClaimNFTBoundariesTest is Test {
    ClaimToken internal claim;
    VeClaimNFTHarness internal ve;
    MockShareholderRoyaltiesCheckpoint internal srMock;

    address internal owner = address(0xA11CE);
    address internal mineCore = address(0xC0DE);
    address internal mineMarket = address(0xB0B0);
    address internal furnace = address(0xF00D);
    address internal alice = address(0xA);

    function setUp() public {
        vm.etch(owner, hex"00");
        vm.etch(mineCore, hex"00");
        vm.etch(mineMarket, hex"00");
        vm.etch(furnace, hex"00");

        claim = new ClaimToken(owner);
        ve = new VeClaimNFTHarness(address(claim), owner);
        srMock = new MockShareholderRoyaltiesCheckpoint();

        vm.mockCall(owner, abi.encodeWithSignature("claim()"), abi.encode(address(claim)));
        vm.mockCall(furnace, abi.encodeWithSignature("shareholderRoyalties()"), abi.encode(address(srMock)));
        vm.mockCall(mineMarket, abi.encodeWithSignature("royalties()"), abi.encode(address(srMock)));
        vm.mockCall(furnace, abi.encodeWithSignature("ve()"), abi.encode(address(ve)));
        vm.mockCall(furnace, abi.encodeWithSignature("mineMarket()"), abi.encode(mineMarket));
        vm.mockCall(furnace, abi.encodeWithSignature("mineCore()"), abi.encode(mineCore));
        vm.mockCall(furnace, abi.encodeWithSignature("claim()"), abi.encode(address(claim)));
        vm.mockCall(mineMarket, abi.encodeWithSignature("ve()"), abi.encode(address(ve)));
        vm.mockCall(mineMarket, abi.encodeWithSignature("claim()"), abi.encode(address(claim)));
        vm.mockCall(mineCore, abi.encodeWithSignature("ve()"), abi.encode(address(ve)));
        vm.mockCall(mineCore, abi.encodeWithSignature("claim()"), abi.encode(address(claim)));
        vm.mockCall(mineCore, abi.encodeWithSignature("furnace()"), abi.encode(furnace));
        vm.mockCall(mineCore, abi.encodeWithSignature("royalties()"), abi.encode(address(srMock)));
        vm.mockCall(address(srMock), abi.encodeWithSignature("ve()"), abi.encode(address(ve)));
        vm.mockCall(address(srMock), abi.encodeWithSignature("furnace()"), abi.encode(furnace));
        vm.mockCall(address(srMock), abi.encodeWithSignature("mineMarket()"), abi.encode(mineMarket));
        vm.mockCall(address(srMock), abi.encodeWithSignature("mineCore()"), abi.encode(mineCore));
        vm.mockCall(mineCore, abi.encodeWithSignature("emissionStartTime()"), abi.encode(uint256(1)));
        vm.mockCall(mineCore, abi.encodeWithSignature("GENESIS_ACCRUAL_DURATION()"), abi.encode(uint256(604800)));

        vm.prank(owner);
        claim.setMineCore(mineCore);

        vm.startPrank(owner);
        ve.setMineMarket(mineMarket);
        ve.setFurnace(furnace);
        vm.stopPrank();

        // Mint CLAIM to alice for lock creation
        vm.prank(mineCore);
        claim.mint(alice, 10_000_000e18);

        vm.prank(alice);
        claim.approve(address(ve), type(uint256).max);
    }

    // ── MIN_LOCK_AMOUNT boundary ────────────────────────────────────

    function testCreateLockAtExactMinAmount() public {
        vm.prank(alice);
        uint256 tokenId = ve.createLock(Constants.MIN_LOCK_AMOUNT, Constants.MIN_LOCK_DURATION, false);
        assertGt(tokenId, 0);
    }

    function testCreateLockBelowMinAmountReverts() public {
        vm.prank(alice);
        vm.expectRevert();
        ve.createLock(Constants.MIN_LOCK_AMOUNT - 1, Constants.MIN_LOCK_DURATION, false);
    }

    // ── MIN_LOCK_DURATION / MAX_LOCK_DURATION boundary ──────────────

    function testCreateLockAtExactMinDuration() public {
        vm.prank(alice);
        uint256 tokenId = ve.createLock(Constants.MIN_LOCK_AMOUNT, Constants.MIN_LOCK_DURATION, false);
        assertGt(tokenId, 0);
    }

    function testCreateLockBelowMinDurationReverts() public {
        vm.prank(alice);
        vm.expectRevert(Errors.InvalidDuration.selector);
        ve.createLock(Constants.MIN_LOCK_AMOUNT, Constants.MIN_LOCK_DURATION - 1, false);
    }

    function testCreateLockAtExactMaxDuration() public {
        vm.prank(alice);
        uint256 tokenId = ve.createLock(Constants.MIN_LOCK_AMOUNT, Constants.MAX_LOCK_DURATION, false);
        assertGt(tokenId, 0);
    }

    function testCreateLockAboveMaxDurationReverts() public {
        vm.prank(alice);
        vm.expectRevert(Errors.InvalidDuration.selector);
        ve.createLock(Constants.MIN_LOCK_AMOUNT, Constants.MAX_LOCK_DURATION + 1, false);
    }

    // ── MAX_VE_NFTS_PER_USER cap ────────────────────────────────────

    function testCannotExceedMaxVeNFTsPerUser() public {
        uint256 amt = Constants.MIN_LOCK_AMOUNT;
        uint256 dur = Constants.MIN_LOCK_DURATION;

        vm.startPrank(alice);
        for (uint256 i = 0; i < Constants.MAX_VE_NFTS_PER_USER; i++) {
            ve.createLock(amt, dur, false);
        }

        // The 33rd lock should revert
        vm.expectRevert(Errors.TooManyVeNFTs.selector);
        ve.createLock(amt, dur, false);
        vm.stopPrank();
    }

    // ── AutoMax semantics ───────────────────────────────────────────

    function testAutoMaxLockCannotUnlock() public {
        vm.prank(alice);
        uint256 tokenId = ve.createLock(Constants.MIN_LOCK_AMOUNT, Constants.MAX_LOCK_DURATION, true);

        // Even after max duration passes, autoMax prevents unlock
        vm.warp(block.timestamp + Constants.MAX_LOCK_DURATION + 1);

        vm.prank(alice);
        vm.expectRevert(); // AutoMax lock never expires
        ve.unlock(tokenId);
    }

    function testDisableAutoMaxThenUnlockAfterExpiry() public {
        vm.startPrank(alice);
        uint256 tokenId = ve.createLock(Constants.MIN_LOCK_AMOUNT, Constants.MAX_LOCK_DURATION, true);

        // Disable autoMax
        ve.setAutoMax(tokenId, false);
        vm.stopPrank();

        // Wait for lock to expire
        vm.warp(block.timestamp + Constants.MAX_LOCK_DURATION + 1);

        vm.prank(alice);
        ve.unlock(tokenId);

        assertEq(claim.balanceOf(alice), 10_000_000e18); // all CLAIM returned
    }

    // ── Listed lock mutation bans ───────────────────────────────────

    function testListedLockCannotExtend() public {
        vm.prank(alice);
        uint256 tokenId = ve.createLock(Constants.MIN_LOCK_AMOUNT, Constants.MAX_LOCK_DURATION / 2, false);

        vm.prank(mineMarket);
        ve.setListed(tokenId, true);

        vm.prank(furnace);
        vm.expectRevert(Errors.LockListedOrFrozen.selector);
        ve.extendLockToFor(alice, tokenId, block.timestamp + Constants.MAX_LOCK_DURATION);
    }

    function testListedLockCannotSetAutoMax() public {
        vm.prank(alice);
        uint256 tokenId = ve.createLock(Constants.MIN_LOCK_AMOUNT, Constants.MAX_LOCK_DURATION / 2, false);

        vm.prank(mineMarket);
        ve.setListed(tokenId, true);

        vm.prank(alice);
        vm.expectRevert(Errors.LockListedOrFrozen.selector);
        ve.setAutoMax(tokenId, true);
    }

    function testListedLockCannotUnlock() public {
        vm.prank(alice);
        uint256 tokenId = ve.createLock(Constants.MIN_LOCK_AMOUNT, Constants.MIN_LOCK_DURATION, false);

        vm.prank(mineMarket);
        ve.setListed(tokenId, true);

        vm.warp(block.timestamp + Constants.MIN_LOCK_DURATION + 1);

        vm.prank(alice);
        vm.expectRevert(Errors.LockListedOrFrozen.selector);
        ve.unlock(tokenId);
    }

    // ── Ve balance decay ────────────────────────────────────────────

    function testVeBalanceDecaysMonotonically() public {
        vm.prank(alice);
        ve.createLock(Constants.MIN_LOCK_AMOUNT, Constants.MAX_LOCK_DURATION, false);

        uint256 prevVe = ve.veBalanceOf(alice);
        assertGt(prevVe, 0, "initial ve must be > 0");

        for (uint256 i = 1; i <= 10; i++) {
            vm.warp(block.timestamp + Constants.MAX_LOCK_DURATION / 10);
            uint256 currentVe = ve.veBalanceOf(alice);
            assertLe(currentVe, prevVe, "ve must not increase over time");
            prevVe = currentVe;
        }
    }

    function testVeBalanceIsZeroAfterExpiry() public {
        vm.prank(alice);
        ve.createLock(Constants.MIN_LOCK_AMOUNT, Constants.MIN_LOCK_DURATION, false);

        vm.warp(block.timestamp + Constants.MIN_LOCK_DURATION + 1);
        assertEq(ve.veBalanceOf(alice), 0, "ve must be 0 after lock expiry");
    }

    // ── Fuzz tests ──────────────────────────────────────────────────

    function testFuzz_CreateLockBoundsEnforced(uint256 amount, uint256 duration) public {
        amount = bound(amount, 0, Constants.MIN_LOCK_AMOUNT - 1);
        duration = bound(duration, Constants.MIN_LOCK_DURATION, Constants.MAX_LOCK_DURATION);

        vm.prank(alice);
        vm.expectRevert(); // below MIN_LOCK_AMOUNT
        ve.createLock(amount, duration, false);
    }

    function testFuzz_CreateLockDurationBoundsEnforced(uint256 duration) public {
        duration = bound(duration, 0, Constants.MIN_LOCK_DURATION - 1);

        vm.prank(alice);
        vm.expectRevert(Errors.InvalidDuration.selector);
        ve.createLock(Constants.MIN_LOCK_AMOUNT, duration, false);
    }

    function testFuzz_ValidLockCreation(uint256 amount, uint256 duration) public {
        amount = bound(amount, Constants.MIN_LOCK_AMOUNT, 1_000_000e18);
        duration = bound(duration, Constants.MIN_LOCK_DURATION, Constants.MAX_LOCK_DURATION);

        vm.prank(alice);
        uint256 tokenId = ve.createLock(amount, duration, false);
        assertGt(tokenId, 0);
        (uint256 lockAmt,,,) = ve.getLockInfo(tokenId);
        assertGt(lockAmt, 0);
    }
}
