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

import {MockVe} from "../mocks/MockVe.sol";
import {MineCoreHarness} from "../mocks/MineCoreHarness.sol";

contract GameLoopEndToEndIT is Test {
    ClaimToken internal claim;
    MockVe internal ve;
    ShareholderRoyalties internal royalties;
    Furnace internal furnace;
    MineCoreHarness internal mineCore;

    address internal owner;
    address internal alice;
    address internal bob;

    function setUp() public {
        vm.txGasPrice(0);

        owner = makeAddr("owner");
        alice = makeAddr("alice");
        bob = makeAddr("bob");

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

        // Ensure ShareholderRoyalties.flushPendingShareholderETH() can make progress.
        ve.setTotalVeCached(Constants.MIN_VE_FLUSH);
    }

    // ------------------------------------------------------------
    // Helpers: deterministic emission integrals (mirrors MineCore)
    // ------------------------------------------------------------

    struct Reign1Snapshot {
        uint256 t1;
        uint256 price1;
        uint256 delta1;
        uint256 pending1;
    }

    function _flushDeltaAndRemainder(uint256 pending, uint256 veTotal)
        internal
        pure
        returns (uint256 delta, uint256 remainder)
    {
        // Equivalent harness math for this test fixture:
        // MockVe reports totalVeBiasScaled() = veTotal * 1e18, so the runtime
        // formula floor(pending * 1e36 / totalVeBiasScaled) reduces here to
        // floor(pending * ACC / veTotal).
        delta = (pending * Constants.ACC) / veTotal;
        uint256 distributed = (delta * veTotal) / Constants.ACC;
        remainder = pending - distributed;
    }

    function _runGenesisTakeover(uint256 T0, uint256 veTotal) internal returns (Reign1Snapshot memory s1) {
        // Reign 1 (genesis takeover): 100% of ETH -> shareholders.
        uint256 t1 = T0 + 100;
        vm.warp(t1);

        uint256 price1 = mineCore.getCurrentTakeoverPrice();
        assertEq(price1, Constants.TAKEOVER_PRICE_FLOOR);

        uint256 aliceEthBefore = alice.balance;
        vm.prank(alice);
        mineCore.takeover{value: price1}(type(uint256).max);
        assertEq(alice.balance, aliceEthBefore - price1);

        assertEq(mineCore.currentKing(), alice);
        assertEq(mineCore.currentReignId(), 1);

        // MineCore immediately calls ShareholderRoyalties.flushPendingShareholderETH() during takeover.
        // So pendingShareholderETH is whatever remainder couldn't be distributed due to floor division.
        (uint256 delta1, uint256 pending1) = _flushDeltaAndRemainder(price1, veTotal);
        assertEq(royalties.ethPerVe(), delta1);
        assertEq(royalties.pendingShareholderETH(), pending1);

        uint256 expectedFurnaceAfter1 = _emitted(0, t1, T0, false);
        assertEq(claim.balanceOf(address(furnace)), expectedFurnaceAfter1);
        assertEq(furnace.furnaceReserve(), expectedFurnaceAfter1);

        s1 = Reign1Snapshot({t1: t1, price1: price1, delta1: delta1, pending1: pending1});
    }

    function _runSecondTakeoverAndAssert(uint256 T0, uint256 veTotal, Reign1Snapshot memory s1) internal {
        // Reign 2: dethrone -> finalize reign1, split ETH, mint king + furnace emissions.
        uint256 t2 = s1.t1 + 50;
        vm.warp(t2);

        uint256 price2 = mineCore.getCurrentTakeoverPrice();
        uint256 aliceEthBeforeDethrone = alice.balance;

        vm.prank(bob);
        mineCore.takeover{value: price2}(type(uint256).max);

        assertEq(mineCore.currentKing(), bob);
        assertEq(mineCore.currentReignId(), 2);

        uint256 kingShare = (price2 * 75) / 100;
        uint256 shareholderShare = price2 - kingShare;

        // Best-effort king payout succeeds for EOA.
        assertEq(alice.balance, aliceEthBeforeDethrone + kingShare);

        // Shareholder ETH bucket: MineCore adds `shareholderShare` then immediately flushes again.
        (uint256 delta2, uint256 expectedPending2) = _flushDeltaAndRemainder(s1.pending1 + shareholderShare, veTotal);
        assertEq(royalties.ethPerVe(), s1.delta1 + delta2);
        assertEq(royalties.pendingShareholderETH(), expectedPending2);

        // Reign 1 finalized metadata and king emissions minted.
        MineCore.ReignInfo memory r1 = mineCore.getReignInfo(1);
        assertEq(r1.king, alice);
        assertEq(r1.startTime, s1.t1);
        assertEq(r1.endTime, t2);
        assertEq(r1.totalEthToKing, kingShare);

        uint256 expectedKingClaim = _emitted(s1.t1, t2, T0, true);
        assertEq(r1.totalClaimMined, expectedKingClaim);
        assertEq(claim.balanceOf(alice), expectedKingClaim);

        // Furnace stream is always mined and credited to reserve.
        uint256 expectedFurnaceTotal = _emitted(0, t2, T0, false);
        assertEq(claim.balanceOf(address(furnace)), expectedFurnaceTotal);
        assertEq(furnace.furnaceReserve(), expectedFurnaceTotal);

        // Shareholder distribution index should make progress once ve.totalVeCached is above MIN_VE_FLUSH.
        uint256 pendingBefore = royalties.pendingShareholderETH();
        royalties.flushPendingShareholderETH();
        assertGt(royalties.ethPerVe(), 0);
        assertLe(royalties.pendingShareholderETH(), pendingBefore);
    }

    function _kingRateAt(uint256 t) internal pure returns (uint256) {
        uint256 D = Constants.EMISSION_DECAY_PERIOD;
        uint256 R0 = Constants.KING_EMISSION_LAUNCH_RATE;
        uint256 RF = Constants.KING_EMISSION_FLOOR;
        if (t >= D) return RF;
        uint256 diff = R0 - RF;
        uint256 dec = (diff * t) / D;
        uint256 rate = R0 - dec;
        if (rate < RF) rate = RF;
        return rate;
    }

    function _furnaceRateAt(uint256 t) internal pure returns (uint256) {
        uint256 D = Constants.EMISSION_DECAY_PERIOD;
        uint256 R0 = Constants.FURNACE_EMISSION_LAUNCH_RATE;
        uint256 RF = Constants.FURNACE_EMISSION_FLOOR;
        if (t >= D) return RF;
        uint256 diff = R0 - RF;
        uint256 dec = (diff * t) / D;
        uint256 rate = R0 - dec;
        if (rate < RF) rate = RF;
        return rate;
    }

    function _emitted(uint256 ts0, uint256 ts1, uint256 T0, bool isKing) internal pure returns (uint256) {
        if (ts1 <= ts0) return 0;
        if (ts1 <= T0) return 0;
        if (ts0 < T0) ts0 = T0;

        uint256 D = Constants.EMISSION_DECAY_PERIOD;
        uint256 RF = isKing ? Constants.KING_EMISSION_FLOOR : Constants.FURNACE_EMISSION_FLOOR;
        uint256 floorTs = T0 + D;

        if (ts0 >= floorTs) {
            return RF * (ts1 - ts0);
        }

        if (ts1 <= floorTs) {
            uint256 t0 = ts0 - T0;
            uint256 t1 = ts1 - T0;
            uint256 r0 = isKing ? _kingRateAt(t0) : _furnaceRateAt(t0);
            uint256 r1 = isKing ? _kingRateAt(t1) : _furnaceRateAt(t1);
            return (r0 + r1) * (ts1 - ts0) / 2;
        }

        uint256 t0b = ts0 - T0;
        uint256 r0b = isKing ? _kingRateAt(t0b) : _furnaceRateAt(t0b);
        uint256 decayPart = (r0b + RF) * (floorTs - ts0) / 2;
        uint256 floorPart = RF * (ts1 - floorTs);
        return decayPart + floorPart;
    }

    function testEndToEnd_takeoverFinalize_ethSplit_emissions_reserve() public {
        vm.deal(alice, 10 ether);
        vm.deal(bob, 10 ether);

        uint256 T0 = mineCore.emissionStartTime();
        uint256 veTotal = ve.totalVeCached();
        assertGe(veTotal, Constants.MIN_VE_FLUSH);
        Reign1Snapshot memory s1 = _runGenesisTakeover(T0, veTotal);
        _runSecondTakeoverAndAssert(T0, veTotal, s1);
    }

    /// @dev P10-13: Assert global ETH and CLAIM conservation after two takeovers.
    function testEndToEnd_ethAndClaimConservation() public {
        uint256 aliceStart = 10 ether;
        uint256 bobStart = 10 ether;
        vm.deal(alice, aliceStart);
        vm.deal(bob, bobStart);

        uint256 totalEthBefore = alice.balance + bob.balance + address(mineCore).balance + address(royalties).balance
            + address(furnace).balance + address(ve).balance;

        uint256 T0 = mineCore.emissionStartTime();
        uint256 veTotal = ve.totalVeCached();
        assertGe(veTotal, Constants.MIN_VE_FLUSH);

        Reign1Snapshot memory s1 = _runGenesisTakeover(T0, veTotal);
        _runSecondTakeoverAndAssert(T0, veTotal, s1);

        // ETH conservation: sum of all ETH across actors and contracts is unchanged.
        uint256 totalEthAfter = alice.balance + bob.balance + address(mineCore).balance + address(royalties).balance
            + address(furnace).balance + address(ve).balance;
        assertEq(totalEthAfter, totalEthBefore, "ETH conservation violated");

        // CLAIM conservation: totalSupply == sum of all holder balances.
        uint256 totalSupply = claim.totalSupply();
        uint256 balanceSum = claim.balanceOf(alice) + claim.balanceOf(bob) + claim.balanceOf(address(mineCore))
            + claim.balanceOf(address(royalties)) + claim.balanceOf(address(furnace)) + claim.balanceOf(address(ve));
        assertEq(totalSupply, balanceSum, "CLAIM conservation violated: totalSupply != sum(balances)");
    }
}
