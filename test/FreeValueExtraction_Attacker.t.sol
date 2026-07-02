// SPDX-License-Identifier: MIT
pragma solidity ^0.8.34;

import {Test} from "forge-std/Test.sol";

import {Constants} from "src/lib/Constants.sol";
import {DelegationPermissions} from "src/lib/DelegationPermissions.sol";
import {EchidnaSetup} from "test/echidna/EchidnaSetup.sol";
import {MineCoreHarness} from "test/mocks/MineCoreHarness.sol";

contract RefundRejectingAttacker {
    MineCoreHarness internal immutable mineCore;

    constructor(MineCoreHarness mineCore_) {
        mineCore = mineCore_;
    }

    receive() external payable {
        revert("NO_ETH");
    }

    function takeoverFromBalance(uint256 value) external {
        mineCore.takeover{value: value}(type(uint256).max);
    }

    function withdrawRefund(address to) external {
        mineCore.withdrawRefundBalance(to);
    }
}

/// @notice Adversarial value-extraction replays for launch audit.
/// @dev These tests are intentionally profit-oriented: each cycle snapshots the attacker's liquid
///      ETH or CLAIM before the cycle and fails if protocol accounting lets them finish richer.
contract FreeValueExtractionAttackerTest is Test, EchidnaSetup {
    address internal attacker;
    address internal victim;
    address internal delegate;
    address internal keeper;
    address internal bob;

    uint256 internal constant SEED_CLAIM = 5_000_000e18;
    uint256 internal constant SEED_RESERVE = 25_000_000e18;
    uint256 internal constant ATTACK_AMOUNT = 50_000e18;

    function setUp() public {
        vm.txGasPrice(0);

        attacker = makeAddr("attacker");
        victim = makeAddr("victim");
        delegate = makeAddr("delegate");
        keeper = makeAddr("keeper");
        bob = makeAddr("bob");

        _deployAndWire();
        market.setSettlementKeeper(keeper, true);

        mineCore.mintClaimForTest(attacker, SEED_CLAIM);
        mineCore.mintClaimForTest(victim, SEED_CLAIM);
        mineCore.mintClaimForTest(bob, SEED_CLAIM);
        mineCore.creditFurnaceReserveForTest(SEED_RESERVE);

        vm.deal(attacker, 100 ether);
        vm.deal(victim, 100 ether);
        vm.deal(delegate, 100 ether);
        vm.deal(bob, 100 ether);

        _approve(attacker);
        _approve(victim);
        _approve(bob);
    }

    function test_noFreeClaim_enterSellRoundTrip_acrossDurations() public {
        _assertEnterSellRoundTripCannotPrintClaim(Constants.MIN_LOCK_DURATION, false);
        _assertEnterSellRoundTripCannotPrintClaim(30 days, false);
        _assertEnterSellRoundTripCannotPrintClaim(180 days, false);
        _assertEnterSellRoundTripCannotPrintClaim(Constants.MAX_LOCK_DURATION, false);
        _assertEnterSellRoundTripCannotPrintClaim(Constants.MAX_LOCK_DURATION, true);
    }

    function test_noFreeClaim_extendBonusThenSellCannotExtract() public {
        uint256 beforeClaim = claim.balanceOf(attacker);
        uint256 tokenId = _enter(attacker, ATTACK_AMOUNT, Constants.MIN_LOCK_DURATION, false);

        (, uint256 quotedBonus,) = quoter.quoteExtendWithBonus(attacker, tokenId, Constants.MAX_LOCK_DURATION);

        vm.prank(attacker);
        furnace.extendWithBonus(tokenId, Constants.MAX_LOCK_DURATION, quotedBonus);

        _sellOwnedLock(attacker, tokenId);
        assertLe(claim.balanceOf(attacker), beforeClaim, "extend bonus + sellback printed liquid CLAIM");
    }

    function test_noFreeClaim_autoMaxBonusThenSellCannotExtract() public {
        uint256 beforeClaim = claim.balanceOf(attacker);
        uint256 tokenId = _enter(attacker, ATTACK_AMOUNT, Constants.MAX_LOCK_DURATION, true);

        vm.prank(keeper);
        assertEq(furnace.claimAutoMaxBonus(tokenId), 0, "first AutoMax touch should only initialize cursor");

        vm.warp(block.timestamp + 30 days);
        vm.roll(block.number + 1);

        vm.prank(keeper);
        furnace.claimAutoMaxBonus(tokenId);

        _sellOwnedLock(attacker, tokenId);
        assertLe(claim.balanceOf(attacker), beforeClaim, "AutoMax claim + sellback printed liquid CLAIM");
    }

    function test_noFreeClaim_mergeBonusThenSellCannotExtract() public {
        uint256 beforeClaim = claim.balanceOf(attacker);
        uint256 shortLock = _enter(attacker, ATTACK_AMOUNT, Constants.MIN_LOCK_DURATION, false);
        uint256 longLock = _enter(attacker, ATTACK_AMOUNT, Constants.MAX_LOCK_DURATION, false);

        vm.prank(attacker);
        furnace.mergeLocksWithBonus(shortLock, longLock, 0);

        _sellOwnedLock(attacker, longLock);
        assertLe(claim.balanceOf(attacker), beforeClaim, "merge bonus + sellback printed liquid CLAIM");
    }

    function test_noFreeClaim_listedKeeperSettlementCannotPrintClaim() public {
        uint256 beforeClaim = claim.balanceOf(attacker);
        uint256 tokenId = _enter(attacker, ATTACK_AMOUNT, Constants.MAX_LOCK_DURATION, false);

        (uint256 lockAmount, uint256 lockEnd, bool autoMax,) = ve.getLockInfo(tokenId);
        (uint256 quoteOut,,,) = quoter.quoteSellLockToFurnaceFromInfo(lockAmount, lockEnd, autoMax);

        vm.prank(attacker);
        market.listLock(tokenId, quoteOut, block.timestamp + 30 days);

        vm.roll(block.number + 1);
        vm.prank(keeper);
        market.sellListedLockToFurnace(tokenId, block.timestamp + Constants.SWAP_DEADLINE_SECONDS);

        assertLe(claim.balanceOf(attacker), beforeClaim, "listed keeper settlement printed liquid CLAIM");
    }

    function test_noFreeClaim_bonusEscrowCancelExpireAndExecuteSellCannotPrintClaim() public {
        uint256 budget = market.minBonusTargetEscrowBudget();
        uint256 beforeClaim = claim.balanceOf(attacker);

        uint256 cancelOffer = _createBonusEscrow(attacker, budget, 30 days, false);
        vm.prank(attacker);
        market.cancelBonusTargetEscrow(cancelOffer);
        assertEq(claim.balanceOf(attacker), beforeClaim, "escrow cancel should refund exactly");

        uint256 expireOffer = _createBonusEscrow(attacker, budget, 30 days, false);
        vm.warp(block.timestamp + 31 days);
        vm.prank(keeper);
        market.cancelExpiredBonusTargetEscrow(expireOffer);
        assertEq(claim.balanceOf(attacker), beforeClaim, "expired escrow should refund exactly");

        uint256 nextTokenId = ve.nextTokenId();
        uint256 executeOffer = _createBonusEscrow(attacker, budget, Constants.MAX_LOCK_DURATION, false);
        vm.prank(keeper);
        market.executeAutoFurnace(executeOffer, block.timestamp + Constants.SWAP_DEADLINE_SECONDS);
        assertEq(ve.ownerOf(nextTokenId), attacker, "escrow execution should mint to buyer");

        _sellOwnedLock(attacker, nextTokenId);
        assertLe(claim.balanceOf(attacker), beforeClaim, "escrow execute + sellback printed liquid CLAIM");
    }

    function test_noFreeEth_takeoverOverpayDirectRefundCannotProfit() public {
        uint256 price = mineCore.getCurrentTakeoverPrice();
        uint256 startEth = attacker.balance;
        uint256 overpay = 1 ether;

        vm.prank(attacker);
        mineCore.takeover{value: price + overpay}(type(uint256).max);

        assertEq(mineCore.refundEthBalance(attacker), 0, "direct refund should not leave a bucket");
        assertEq(attacker.balance, startEth - price, "overpay refund path created free ETH");
    }

    function test_noFreeEth_takeoverOverpayRefundBucketCannotProfit() public {
        RefundRejectingAttacker bot = new RefundRejectingAttacker(mineCore);
        address sink = makeAddr("refundSink");

        uint256 price = mineCore.getCurrentTakeoverPrice();
        uint256 overpay = 1 ether;
        vm.deal(address(bot), 10 ether);
        uint256 combinedBefore = address(bot).balance + sink.balance;

        bot.takeoverFromBalance(price + overpay);
        assertEq(mineCore.refundEthBalance(address(bot)), overpay, "rejecting payer should get exact refund bucket");

        bot.withdrawRefund(sink);
        assertEq(address(bot).balance + sink.balance, combinedBefore - price, "refund bucket created free ETH");
    }

    function test_noFreeEth_claimAllForCannotRedirectUserRewardsToDelegate() public {
        uint256 victimLock = _enter(victim, 100_000e18, Constants.MAX_LOCK_DURATION, true);
        assertEq(ve.ownerOf(victimLock), victim, "setup lock owner");

        mineCore.setKingEthBalanceForTest(victim, 0.25 ether);
        vm.deal(address(mineCore), address(mineCore).balance + 1.25 ether);

        vm.prank(address(mineCore));
        royalties.onTakeover{value: 1 ether}(1);
        royalties.checkpointUser(victim);

        uint256 claimable = royalties.claimableEth(victim);
        uint256 kingBucket = mineCore.kingEthBalance(victim);
        assertGt(claimable, 0, "setup should create shareholder ETH");
        assertGt(kingBucket, 0, "setup should create king ETH bucket");

        vm.prank(victim);
        delegationHub.setSession(delegate, DelegationPermissions.P_CLAIM_ALL_FOR, uint64(block.timestamp + 1 days));

        uint256 victimEthBefore = victim.balance;
        uint256 delegateEthBefore = delegate.balance;

        vm.prank(delegate);
        claimAllHelper.claimAllFor(victim, Constants.SHAREHOLDER_MODE_ETH, 0, 0, false, 0);

        assertEq(delegate.balance, delegateEthBefore, "claimAllFor delegate received user ETH");
        assertEq(victim.balance, victimEthBefore + claimable + kingBucket, "user did not receive all claimable ETH");
    }

    function test_noFreeClaim_delegatedTakeoverWithoutRoutePermissionPaysMinedClaimToUser() public {
        uint256 delegateClaimBefore = claim.balanceOf(delegate);
        uint256 victimClaimBefore = claim.balanceOf(victim);

        vm.prank(victim);
        delegationHub.setSession(delegate, DelegationPermissions.P_TAKEOVER_FOR, uint64(block.timestamp + 2 days));

        uint256 price = mineCore.getCurrentTakeoverPrice();
        vm.prank(delegate);
        mineCore.takeoverFor{value: price}(victim, type(uint256).max);

        vm.warp(block.timestamp + 1 days);
        vm.roll(block.number + 1);

        uint256 mined = mineCore.kingEmittedExposed(mineCore.currentReignLastAccrualTime(), block.timestamp);
        assertGt(mined, 0, "setup should accrue king emissions");

        uint256 victimReign = mineCore.currentReignId();
        uint256 dethronePrice = mineCore.getCurrentTakeoverPrice();
        vm.prank(bob);
        mineCore.takeover{value: dethronePrice}(type(uint256).max);

        assertEq(claim.balanceOf(delegate), delegateClaimBefore, "delegate received CLAIM without route permission");

        // King-stream CLAIM accrues to the reign's claim recipient (the victim): a takeover-window
        // liquid slice plus a force-locked remainder. The delegate gains nothing; the victim keeps the
        // full value (split liquid + lock), so this is not a free-value-extraction path.
        uint256 minedSettled = mineCore.getReignInfo(victimReign).totalClaimMined;
        uint256 expLiquid = (minedSettled * mineCore.kingLiquidShareBps(victim)) / 10_000;
        assertEq(
            claim.balanceOf(victim) - victimClaimBefore,
            expLiquid,
            "victim receives only the takeover-window liquid slice"
        );

        (,, uint256 victimPin,,,) = mineCore.getKingAutoLockConfig(victim);
        assertGt(victimPin, 0, "victim should receive a locked position");
        assertEq(ve.ownerOf(victimPin), victim, "victim owns the locked position");
        (uint256 lockedAmt,,,) = ve.getLockInfo(victimPin);
        assertGe(lockedAmt, minedSettled - expLiquid, "victim's lock should hold the force-locked principal");
    }

    function _assertEnterSellRoundTripCannotPrintClaim(uint256 duration, bool autoMax) internal {
        uint256 beforeClaim = claim.balanceOf(attacker);
        uint256 tokenId = _enter(attacker, ATTACK_AMOUNT, duration, autoMax);
        _sellOwnedLock(attacker, tokenId);
        assertLe(claim.balanceOf(attacker), beforeClaim, "enter + sellback printed liquid CLAIM");
    }

    function _enter(address user, uint256 amount, uint256 duration, bool autoMax) internal returns (uint256 tokenId) {
        (,, uint256 veOut,) = quoter.quoteEnterWithClaim(user, amount, 0, duration, autoMax);
        vm.prank(user);
        tokenId = furnace.enterWithClaim(amount, 0, duration, autoMax, veOut);
    }

    function _sellOwnedLock(address user, uint256 tokenId) internal returns (uint256 claimOut) {
        (uint256 lockAmount, uint256 lockEnd, bool autoMax,) = ve.getLockInfo(tokenId);
        (uint256 quoteOut,,,) = quoter.quoteSellLockToFurnaceFromInfo(lockAmount, lockEnd, autoMax);
        vm.prank(user);
        claimOut = market.sellLockToFurnace(tokenId, quoteOut, block.timestamp + Constants.SWAP_DEADLINE_SECONDS);
    }

    function _createBonusEscrow(address user, uint256 budget, uint256 duration, bool createAutoMax)
        internal
        returns (uint256 offerId)
    {
        vm.prank(user);
        offerId = market.createBonusTargetEscrowWithTarget(1, budget, duration, createAutoMax, 30 days, 0, 0);
    }

    function _approve(address user) internal {
        vm.startPrank(user);
        claim.approve(address(furnace), type(uint256).max);
        claim.approve(address(market), type(uint256).max);
        vm.stopPrank();
    }
}
