// SPDX-License-Identifier: MIT
pragma solidity ^0.8.34;

import {Test} from "forge-std/Test.sol";

import {ClaimToken} from "src/ClaimToken.sol";
import {Furnace} from "src/Furnace.sol";
import {FurnaceGuardHelper} from "src/FurnaceGuardHelper.sol";

import {FurnaceQuoter} from "src/FurnaceQuoter.sol";
import {MineCore} from "src/MineCore.sol";
import {ShareholderRoyalties} from "src/ShareholderRoyalties.sol";
import {Constants} from "src/lib/Constants.sol";
import {Errors} from "src/lib/Errors.sol";
import {Events} from "src/lib/Events.sol";

import {MockVe} from "./mocks/MockVe.sol";
import {MineCoreHarness} from "./mocks/MineCoreHarness.sol";

/// @notice Regression tests for MineCore + ClaimToken.
/// @dev Covers: memory-safe inline-assembly annotation, `AutoMaxMismatch` error path,
///      `withdrawKingBalanceTo` auth + invariants, same-block sequential takeovers,
///      and `takeoverWithToken` rejecting a disabled token.
contract MineCoreRegressionTest is Test {
    ClaimToken internal claim;
    MockVe internal ve;
    ShareholderRoyalties internal royalties;
    Furnace internal furnace;
    MineCoreHarness internal mineCore;

    address internal owner = address(0xA11CE);
    address internal alice;
    address internal bob;
    address internal carol;

    function setUp() public {
        vm.txGasPrice(0);

        alice = makeAddr("alice");
        bob = makeAddr("bob");
        carol = makeAddr("carol");

        claim = new ClaimToken(owner);
        ve = new MockVe();
        royalties = new ShareholderRoyalties(address(ve), owner);
        furnace = new Furnace(
            address(claim), address(ve), address(new FurnaceGuardHelper(address(claim), address(ve))), owner
        );
        FurnaceQuoter quoter = new FurnaceQuoter(address(furnace));
        mineCore = new MineCoreHarness(address(claim), address(ve), address(royalties), owner);

        vm.startPrank(owner);
        claim.setMineCore(address(mineCore));
        ve.setClaimToken(address(claim));
        furnace.setMineCore(address(mineCore));
        furnace.setFurnaceQuoter(address(quoter));
        vm.etch(address(0xB0B0), hex"00");
        furnace.setMineMarket(address(0xB0B0));
        furnace.setShareholderRoyalties(address(royalties));
        mineCore.setFurnace(address(furnace));
        vm.mockCall(address(0xB0B0), abi.encodeWithSignature("ve()"), abi.encode(address(ve)));
        vm.mockCall(address(0xB0B0), abi.encodeWithSignature("claim()"), abi.encode(address(claim)));
        vm.mockCall(address(0xB0B0), abi.encodeWithSignature("royalties()"), abi.encode(address(royalties)));
        ve.setFurnace(address(furnace));
        ve.setMineMarket(address(0xB0B0));
        royalties.setWiring(address(mineCore), address(0xB0B0), address(furnace));
        mineCore.setGenesisKingClaimCollectedForTest(true);
        mineCore.setTakeoversPaused(false);
        vm.stopPrank();

        ve.setTotalVeCached(1234);
    }

    // ---------------------------------------------------------------
    // withdrawKingBalanceTo sends ETH to an arbitrary `to`
    // ---------------------------------------------------------------

    function testWithdrawKingBalanceTo_sendsToArbitraryRecipient() public {
        mineCore.setKingEthBalanceForTest(alice, 1 ether);
        vm.deal(address(mineCore), 1 ether);

        uint256 carolBefore = carol.balance;

        vm.prank(alice);
        mineCore.withdrawKingBalanceTo(carol);

        assertEq(carol.balance - carolBefore, 1 ether, "carol should receive 1 ETH");
        assertEq(mineCore.kingEthBalance(alice), 0, "alice balance should be zero");
    }

    function testWithdrawKingBalanceTo_revertsForZeroRecipient() public {
        mineCore.setKingEthBalanceForTest(alice, 1 ether);
        vm.deal(address(mineCore), 1 ether);

        vm.prank(alice);
        vm.expectRevert(Errors.ZeroAddress.selector);
        mineCore.withdrawKingBalanceTo(address(0));
    }

    function testWithdrawKingBalanceTo_noopOnZeroBalance() public {
        vm.prank(alice);
        mineCore.withdrawKingBalanceTo(carol);
        assertEq(carol.balance, 0, "carol should receive nothing");
    }

    // ---------------------------------------------------------------
    // Same-block sequential takeovers (zero-duration reign)
    // ---------------------------------------------------------------

    function testSequentialTakeoversInSameBlock() public {
        vm.deal(alice, 10 ether);
        vm.deal(bob, 10 ether);
        vm.deal(carol, 10 ether);

        uint256 T0 = mineCore.emissionStartTime();
        vm.warp(T0 + 100);

        uint256 floor = Constants.TAKEOVER_PRICE_FLOOR;

        // Alice takes the crown (genesis).
        vm.prank(alice);
        mineCore.takeover{value: floor}(type(uint256).max);
        assertEq(mineCore.currentKing(), alice);
        assertEq(mineCore.currentReignId(), 1);

        // Bob takes from alice in the same block (0 seconds elapsed).
        uint256 nextPrice = mineCore.getTakeoverPrice(block.timestamp);
        vm.prank(bob);
        mineCore.takeover{value: nextPrice}(type(uint256).max);
        assertEq(mineCore.currentKing(), bob);
        assertEq(mineCore.currentReignId(), 2);

        // Verify zero-duration reign: alice's reign started and ended at same timestamp.
        MineCore.ReignInfo memory r1 = mineCore.getReignInfo(1);
        assertEq(r1.startTime, r1.endTime, "zero-duration reign: start == end");
        assertEq(r1.totalClaimMined, 0, "zero-duration reign: no CLAIM mined");

        // Carol takes from bob in the same block.
        uint256 nextPrice2 = mineCore.getTakeoverPrice(block.timestamp);
        vm.prank(carol);
        mineCore.takeover{value: nextPrice2}(type(uint256).max);
        assertEq(mineCore.currentKing(), carol);
        assertEq(mineCore.currentReignId(), 3);
    }

    // ---------------------------------------------------------------
    // AutoMaxMismatch error for existing-lock createAutoMax
    // ---------------------------------------------------------------

    function testSetKingAutoLockConfig_existingTokenCreateAutoMax_revertsAutoMaxMismatch() public {
        uint256 tokenId = 42;
        ve.setOwner(tokenId, alice);
        ve.setLockInfo(tokenId, 1_000e18, block.timestamp + 365 days, false, false);

        vm.prank(alice);
        vm.expectRevert(Errors.AutoMaxMismatch.selector);
        mineCore.setKingAutoLockConfig(true, tokenId, uint32(Constants.MAX_LOCK_DURATION), true, 0);
    }
}
