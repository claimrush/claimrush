// SPDX-License-Identifier: MIT
pragma solidity ^0.8.34;

import {Test} from "forge-std/Test.sol";
import {Vm} from "forge-std/Vm.sol";

import {MarketRouter} from "src/MarketRouter.sol";
import {ClaimToken} from "src/ClaimToken.sol";
import {EntryTokenRegistry} from "src/EntryTokenRegistry.sol";
import {Furnace} from "src/Furnace.sol";
import {FurnaceGuardHelper} from "src/FurnaceGuardHelper.sol";

import {FurnaceQuoter} from "src/FurnaceQuoter.sol";
import {ShareholderRoyalties} from "src/ShareholderRoyalties.sol";
import {VeClaimNFT} from "src/VeClaimNFT.sol";
import {VeClaimNFTHarness} from "test/mocks/VeClaimNFTHarness.sol";
import {Constants} from "src/lib/Constants.sol";
import {Errors} from "src/lib/Errors.sol";
import {Events} from "src/lib/Events.sol";

import {MockAerodromeRouter} from "test/mocks/MockAerodromeRouter.sol";
import {MockMarketSettlementFurnace} from "test/mocks/MockMarketSettlementFurnace.sol";
import {MockMineCoreWiringView} from "test/mocks/MockMineCoreWiringView.sol";
import {MockWETH} from "test/mocks/MockWETH.sol";
import {MockLpRewardsVault} from "test/mocks/MockLpRewardsVault.sol";

contract MarketRouterKeeperSettlementTest is Test {
    address internal constant FACTORY = address(0xFACADE);

    ClaimToken public claim;
    MockWETH internal weth;
    MockAerodromeRouter internal router;
    EntryTokenRegistry internal registry;

    VeClaimNFTHarness internal ve;
    ShareholderRoyalties internal royalties;
    Furnace internal furnace;
    FurnaceQuoter internal furnaceQuoter;
    MarketRouter internal market;
    MockMineCoreWiringView internal core;

    address internal owner;
    address internal alice;
    address internal keeper;
    address internal randomUser;

    uint256 internal aliceTokenId;

    function setUp() public {
        vm.txGasPrice(0);

        owner = address(this);
        alice = makeAddr("alice");
        keeper = makeAddr("keeper");
        randomUser = makeAddr("randomUser");

        claim = new ClaimToken(owner);

        weth = new MockWETH();
        router = new MockAerodromeRouter(FACTORY, address(weth));

        registry = new EntryTokenRegistry(owner);
        vm.etch(FACTORY, hex"00");
        registry.setRouterConfig(address(router), FACTORY, address(weth), address(claim));

        ve = new VeClaimNFTHarness(address(claim), owner);
        royalties = new ShareholderRoyalties(address(ve), owner);
        furnace = new Furnace(
            address(claim), address(ve), address(new FurnaceGuardHelper(address(claim), address(ve))), owner
        );
        market = new MarketRouter(address(claim), address(ve), address(royalties), owner);
        core = new MockMineCoreWiringView(address(claim), address(ve), address(royalties));

        claim.setMineCore(address(core));

        furnace.setMineCore(address(core));
        furnace.setMineMarket(address(market));
        furnace.setShareholderRoyalties(address(royalties));
        furnace.setEntryTokenRegistry(address(registry));
        furnaceQuoter = new FurnaceQuoter(address(furnace));
        furnace.setFurnaceQuoter(address(furnaceQuoter));

        royalties.setWiring(address(core), address(market), address(furnace));
        core.setFurnace(address(furnace));
        ve.setFurnace(address(furnace));
        ve.setMineMarket(address(market));

        uint256 reserveSeed = 50_000_000e18;
        vm.startPrank(address(core));
        claim.mint(address(furnace), reserveSeed);
        furnace.creditReserve(reserveSeed);
        vm.stopPrank();

        // Create a lock for alice (via furnace as authorized caller).
        aliceTokenId = _createAliceLock(Constants.MIN_LOCK_AMOUNT, Constants.MAX_LOCK_DURATION, false);

        // Alice approvals.
        ve.setApprovalForAllForTest(alice, address(market), true);
        vm.prank(alice);
        claim.approve(address(market), type(uint256).max);

        // Fund alice for offer creation.
        vm.prank(address(core));
        claim.mint(alice, 1_000_000e18);

        // Whitelist keeper.
        market.setSettlementKeeper(keeper, true);
    }

    function _createAliceLock(uint256 amount, uint256 durationSeconds, bool createAutoMax)
        internal
        returns (uint256 tokenId)
    {
        vm.prank(address(core));
        claim.mint(address(furnace), amount);
        vm.prank(address(furnace));
        claim.approve(address(ve), amount);
        vm.prank(address(furnace));
        tokenId = ve.createLockFor(alice, amount, durationSeconds, createAutoMax);
    }

    // =====================================================================
    // setSettlementKeeper: access control
    // =====================================================================

    function test_setSettlementKeeper_onlyOwner() public {
        vm.prank(randomUser);
        vm.expectRevert();
        market.setSettlementKeeper(randomUser, true);
    }

    function test_setSettlementKeeper_zeroAddress_reverts() public {
        vm.expectRevert(Errors.ZeroAddress.selector);
        market.setSettlementKeeper(address(0), true);
    }

    function test_setSettlementKeeper_emitsEvent() public {
        address newKeeper = makeAddr("newKeeper");
        vm.expectEmit(true, false, false, true);
        emit Events.SettlementKeeperSet(newKeeper, true);
        market.setSettlementKeeper(newKeeper, true);
    }

    function test_setSettlementKeeper_canRevoke() public {
        assertTrue(market.isSettlementKeeper(keeper));
        market.setSettlementKeeper(keeper, false);
        assertFalse(market.isSettlementKeeper(keeper));
    }

    function test_setGuardian_rejectsSelf() public {
        vm.expectRevert(Errors.NotAuthorized.selector);
        market.setGuardian(address(market));
    }

    function test_renounceOwnership_reverts() public {
        vm.expectRevert(Errors.NotAuthorized.selector);
        market.renounceOwnership();
        assertEq(market.owner(), owner, "owner path must remain live");
    }

    function test_tradingPaused_gatesDirectAndKeeperTradingWrites() public {
        _listAliceLock();
        uint256 offerId = _createAliceOffer();

        market.pauseTrading(true);
        assertTrue(market.tradingPaused());

        vm.prank(alice);
        vm.expectRevert(Errors.TradingPaused.selector);
        market.listLock(aliceTokenId, 1, block.timestamp + 1);

        vm.prank(alice);
        vm.expectRevert(Errors.TradingPaused.selector);
        market.sellLockToFurnace(aliceTokenId, 1, block.timestamp + 1);

        vm.prank(keeper);
        vm.expectRevert(Errors.TradingPaused.selector);
        market.sellListedLockToFurnace(aliceTokenId, block.timestamp + 300);

        uint256 minEscrowBudget = market.minBonusTargetEscrowBudget();
        vm.prank(alice);
        vm.expectRevert(Errors.TradingPaused.selector);
        market.createBonusTargetEscrowWithTarget(1, minEscrowBudget, 30 days, true, 0, 0, 0);

        vm.prank(keeper);
        vm.expectRevert(Errors.TradingPaused.selector);
        market.executeAutoFurnace(offerId, block.timestamp + 300);
    }

    function test_tradingPaused_stillAllowsDelistLock() public {
        _listAliceLock();

        vm.roll(block.number + 1);
        market.pauseTrading(true);

        vm.prank(alice);
        market.delistLock(aliceTokenId);

        (,,,, bool active) = market.listings(aliceTokenId);
        assertFalse(active, "listing should be cleared while paused");

        (,,, bool listed) = ve.getLockInfo(aliceTokenId);
        assertFalse(listed, "ve listed flag should clear while paused");
        assertTrue(market.tradingPaused(), "cleanup must not unpause trading");
    }

    function test_tradingPaused_stillAllowsCancelExpiredListing() public {
        uint256 expiresAtTime = block.timestamp + 30 days;
        _listAliceLockWithExpiry(expiresAtTime);

        vm.warp(expiresAtTime);
        vm.roll(block.number + 1);
        market.pauseTrading(true);

        vm.prank(randomUser);
        market.cancelExpiredListing(aliceTokenId);

        (,,,, bool active) = market.listings(aliceTokenId);
        assertFalse(active, "expired listing should be clearable while paused");

        (,,, bool listed) = ve.getLockInfo(aliceTokenId);
        assertFalse(listed, "ve listed flag should clear while paused");
        assertTrue(market.tradingPaused(), "cleanup must not unpause trading");
    }

    function test_tradingPaused_stillAllowsCancelBonusTargetEscrow() public {
        uint256 offerId = _createAliceOfferWithTtl(30 days);
        MarketRouter.BonusTargetEscrow memory offer = market.getBonusTargetEscrow(offerId);
        uint256 buyerClaimBefore = claim.balanceOf(alice);
        uint256 fundsRemainingBefore = offer.fundsRemaining;

        market.pauseTrading(true);

        vm.prank(alice);
        market.cancelBonusTargetEscrow(offerId);

        offer = market.getBonusTargetEscrow(offerId);
        assertFalse(offer.active, "buyer cancellation should remain live while paused");
        assertEq(offer.fundsRemaining, 0, "escrow funds should be refunded");
        assertEq(claim.balanceOf(alice), buyerClaimBefore + fundsRemainingBefore);
        assertTrue(market.tradingPaused(), "cleanup must not unpause trading");
    }

    function test_tradingPaused_gatesExtendBonusTargetEscrowExpiry() public {
        uint256 offerId = _createAliceOfferWithTtl(30 days);
        MarketRouter.BonusTargetEscrow memory offer = market.getBonusTargetEscrow(offerId);
        uint256 newExpiresAt = offer.expiresAt + 1 days;

        market.pauseTrading(true);

        vm.prank(alice);
        vm.expectRevert(Errors.TradingPaused.selector);
        market.extendBonusTargetEscrowExpiry(offerId, newExpiresAt);
    }

    function test_tradingPaused_stillAllowsCancelExpiredBonusTargetEscrow() public {
        uint256 offerId = _createAliceOfferWithTtl(30 days);
        MarketRouter.BonusTargetEscrow memory offer = market.getBonusTargetEscrow(offerId);
        uint256 buyerClaimBefore = claim.balanceOf(offer.buyer);
        uint256 fundsRemainingBefore = offer.fundsRemaining;

        vm.warp(offer.expiresAt + 1);
        market.pauseTrading(true);

        vm.prank(randomUser);
        market.cancelExpiredBonusTargetEscrow(offerId);

        offer = market.getBonusTargetEscrow(offerId);
        assertFalse(offer.active, "expired offer should be clearable while paused");
        assertEq(offer.fundsRemaining, 0, "remaining funds should be refunded");
        assertEq(claim.balanceOf(alice), buyerClaimBefore + fundsRemainingBefore);
        assertTrue(market.tradingPaused(), "cleanup must not unpause trading");
    }

    function test_tradingPaused_stillAllowsEmergencyDelist() public {
        _listAliceLock();

        vm.warp(block.timestamp + Constants.EMERGENCY_DELIST_MIN_AGE);
        vm.roll(block.number + 1);
        market.pauseTrading(true);

        vm.prank(alice);
        market.emergencyDelist(aliceTokenId);

        (,,,, bool active) = market.listings(aliceTokenId);
        assertFalse(active, "listing should be emergency-delistable while paused");

        (,,, bool listed) = ve.getLockInfo(aliceTokenId);
        assertFalse(listed, "ve listed flag should clear while paused");
        assertTrue(market.tradingPaused(), "cleanup must not unpause trading");
    }

    // =====================================================================
    // sellListedLockToFurnace: keeper-priority gate
    // =====================================================================

    function _listAliceLock() internal returns (uint256) {
        return _listAliceLockWithExpiry(block.timestamp + 30 days);
    }

    function _listAliceLockWithExpiry(uint256 expiresAtTime) internal returns (uint256) {
        vm.prank(alice);
        market.listLock(aliceTokenId, 1, expiresAtTime);
        return aliceTokenId;
    }

    function test_listing_keeperCanSettleDuringGrace() public {
        _listAliceLock();

        vm.roll(block.number + 1);
        vm.prank(keeper);
        uint256 claimOut = market.sellListedLockToFurnace(aliceTokenId, block.timestamp + 300);
        assertGt(claimOut, 0);
    }

    function test_listing_ownerCanSettleDuringGrace() public {
        _listAliceLock();

        vm.roll(block.number + 1);
        uint256 claimOut = market.sellListedLockToFurnace(aliceTokenId, block.timestamp + 300);
        assertGt(claimOut, 0);
    }

    function test_listing_randomUserRevertsDuringGrace() public {
        _listAliceLock();

        vm.roll(block.number + 1);
        vm.prank(randomUser);
        vm.expectRevert(Errors.SettlementKeeperGracePeriod.selector);
        market.sellListedLockToFurnace(aliceTokenId, block.timestamp + 300);
    }

    function test_listing_randomUserSucceedsAfterGrace() public {
        _listAliceLock();

        vm.roll(block.number + 1);
        uint256 warpTarget = block.timestamp + Constants.SETTLEMENT_KEEPER_GRACE_SECONDS + 1;
        vm.warp(warpTarget);

        vm.prank(randomUser);
        uint256 claimOut = market.sellListedLockToFurnace(aliceTokenId, warpTarget + 300);
        assertGt(claimOut, 0);
    }

    function test_listing_randomUserSucceedsAtExactGraceBoundary() public {
        _listAliceLock();

        vm.roll(block.number + 1);
        // At exactly listedAtTime + SETTLEMENT_KEEPER_GRACE_SECONDS, block.timestamp < anchor + grace
        // is false (equal, not less-than), so it should succeed.
        vm.warp(block.timestamp + Constants.SETTLEMENT_KEEPER_GRACE_SECONDS);

        vm.prank(randomUser);
        uint256 claimOut = market.sellListedLockToFurnace(aliceTokenId, block.timestamp + 300);
        assertGt(claimOut, 0);
    }

    // NOTE: VeClaimNFT disables standard ERC-721 approvals entirely, so strict-mode
    // MarketRouter settlement does not depend on approval revocation paths.

    function test_listing_stillSettlesWhenDirectApprovalRemainsAfterOperatorRevoke() public {
        _listAliceLock();

        vm.roll(block.number + 1);
        ve.approveForTest(address(market), aliceTokenId);
        ve.setApprovalForAllForTest(alice, address(market), false);

        vm.prank(keeper);
        uint256 claimOut = market.sellListedLockToFurnace(aliceTokenId, block.timestamp + 300);
        assertGt(claimOut, 0);
    }

    function test_listing_keeperCannotSettleAtExactExpiry() public {
        uint256 expiresAtTime = block.timestamp + 30 days;
        _listAliceLockWithExpiry(expiresAtTime);

        vm.roll(block.number + 1);
        vm.warp(expiresAtTime);

        vm.prank(keeper);
        vm.expectRevert(Errors.ListingExpired.selector);
        market.sellListedLockToFurnace(aliceTokenId, block.timestamp + 300);
    }

    function test_listingSettlement_eventPenaltyTracksTotalCutWhileReserveDeltaCanBeLower() public {
        MockLpRewardsVault lpVault = new MockLpRewardsVault();
        lpVault.setFurnace(address(furnace));
        furnace.setLpRewardsVault(address(lpVault));

        _listAliceLock();

        vm.roll(block.number + 1);
        (uint256 lockAmount, uint256 lockEnd, bool autoMax,) = ve.getLockInfo(aliceTokenId);
        (uint256 claimOutQ,, uint256 lpRewardQ, uint256 reserveAddQ) =
            furnaceQuoter.quoteSellLockToFurnaceFromInfo(lockAmount, lockEnd, autoMax);

        uint256 penaltyQ = lockAmount - claimOutQ;
        assertEq(lpRewardQ + reserveAddQ, penaltyQ, "penalty should equal the full retained cut");
        assertGt(lpRewardQ, 0, "expected non-zero LP sell share");
        assertLt(reserveAddQ, penaltyQ, "reserve delta should exclude the LP split");

        uint256 sellerClaimBefore = claim.balanceOf(alice);
        uint256 reserveBefore = furnace.furnaceReserve();
        uint256 lpRemainingBefore = furnace.getLpStreamRemaining();

        vm.recordLogs();
        vm.prank(keeper);
        uint256 claimOut = market.sellListedLockToFurnace(aliceTokenId, block.timestamp + 300);
        Vm.Log[] memory logs = vm.getRecordedLogs();

        assertEq(claimOut, claimOutQ, "execution should match quote");
        assertEq(claim.balanceOf(alice) - sellerClaimBefore, claimOutQ, "seller should receive full claimOut");
        assertEq(
            furnace.furnaceReserve(), reserveBefore + reserveAddQ, "reserve increases by reserveAdd after settlement"
        );
        assertGt(furnace.getLpStreamRemaining(), lpRemainingBefore, "LP stream should receive the LP split");

        bytes32 listingSettledTopic = keccak256("ListingSettled(uint256,address,uint256,uint256)");
        bool found;
        for (uint256 i = 0; i < logs.length; ++i) {
            if (logs[i].topics.length == 3 && logs[i].topics[0] == listingSettledTopic) {
                found = true;
                assertEq(logs[i].topics[1], bytes32(aliceTokenId), "tokenId topic mismatch");
                assertEq(logs[i].topics[2], bytes32(uint256(uint160(alice))), "seller topic mismatch");

                (uint256 claimOutEvt, uint256 penaltyEvt) = abi.decode(logs[i].data, (uint256, uint256));
                assertEq(claimOutEvt, claimOutQ, "event claimOut mismatch");
                assertEq(penaltyEvt, penaltyQ, "event penalty should equal the full retained cut");
                break;
            }
        }

        assertTrue(found, "ListingSettled log not found");
    }

    function test_sellLockToFurnaceRevertsWhenVeFurnaceClaimRootMismatches() public {
        ClaimToken wrongClaim = new ClaimToken(owner);
        MockMarketSettlementFurnace foreignFurnace =
            new MockMarketSettlementFurnace(address(wrongClaim), address(ve), address(market), address(royalties));

        vm.expectRevert(Errors.WiringMismatch.selector);
        ve.setFurnace(address(foreignFurnace));
    }

    function test_sellListedLockToFurnaceRevertsWhenVeFurnaceMineMarketMismatches() public {
        MockMarketSettlementFurnace foreignFurnace =
            new MockMarketSettlementFurnace(address(claim), address(ve), makeAddr("wrongMarket"), address(royalties));

        vm.expectRevert(Errors.WiringMismatch.selector);
        ve.setFurnace(address(foreignFurnace));
    }

    function test_sellLockToFurnaceRevertsWhenVeAndRoyaltiesPointToForeignFurnaceButMineCoreDoesNot() public {
        MockMarketSettlementFurnace foreignFurnace =
            new MockMarketSettlementFurnace(address(claim), address(ve), address(market), address(royalties));
        foreignFurnace.setMineCore(makeAddr("foreignCore"));

        vm.expectRevert(Errors.WiringMismatch.selector);
        ve.setFurnace(address(foreignFurnace));
    }

    function test_listing_randomUserCanCancelAtExactExpiry() public {
        uint256 expiresAtTime = block.timestamp + 30 days;
        _listAliceLockWithExpiry(expiresAtTime);

        vm.warp(expiresAtTime);
        vm.roll(block.number + 1);

        vm.prank(randomUser);
        market.cancelExpiredListing(aliceTokenId);

        (,,,, bool active) = market.listings(aliceTokenId);
        assertFalse(active, "listing should be cleared");

        (,,, bool listed) = ve.getLockInfo(aliceTokenId);
        assertFalse(listed, "ve listed flag should be cleared");
    }

    function test_listing_delistAtExactExpiryEmitsExpiredReason() public {
        uint256 expiresAtTime = block.timestamp + 30 days;
        _listAliceLockWithExpiry(expiresAtTime);

        vm.warp(expiresAtTime);
        vm.roll(block.number + 1);

        vm.expectEmit(true, true, false, true);
        emit Events.LockDelisted(aliceTokenId, alice, Constants.LOCK_DELIST_REASON_EXPIRED);

        vm.prank(alice);
        market.delistLock(aliceTokenId);
    }

    function testFuzz_listingCannotSettleAtOrAfterExpiry(uint40 delaySeconds) public {
        delaySeconds = uint40(bound(uint256(delaySeconds), 0, 30 days));

        uint256 expiresAtTime = block.timestamp + 30 days;
        _listAliceLockWithExpiry(expiresAtTime);

        vm.roll(block.number + 1);
        vm.warp(expiresAtTime + delaySeconds);

        vm.prank(keeper);
        vm.expectRevert(Errors.ListingExpired.selector);
        market.sellListedLockToFurnace(aliceTokenId, block.timestamp + 300);
    }

    // =====================================================================
    // executeAutoFurnace: keeper-priority gate
    // =====================================================================

    function _createAliceOffer() internal returns (uint256 offerId) {
        return _createAliceOfferWithTtl(0);
    }

    function _createAliceOfferWithTtl(uint256 escrowTtlSeconds) internal returns (uint256 offerId) {
        uint256 budget = market.minBonusTargetEscrowBudget();
        vm.prank(alice);
        offerId = market.createBonusTargetEscrowWithTarget(
            1, // targetBonusBps (minimum non-zero — fillable immediately)
            budget,
            30 days,
            true, // createAutoMax
            escrowTtlSeconds,
            0, // no destination lock
            0 // slippageBps
        );
    }

    function _rewireCanonicalMarket(address newMarketAddr) internal {
        furnace.setMineMarket(newMarketAddr);
        royalties.setWiring(address(core), newMarketAddr, address(furnace));
        ve.setMineMarket(newMarketAddr);
    }

    function _assertEscrowBackedClaimBalance(uint256 offerId) internal view {
        MarketRouter.BonusTargetEscrow memory offer = market.getBonusTargetEscrow(offerId);
        uint256 expectedBalance = offer.active ? offer.fundsRemaining : 0;
        assertEq(
            claim.balanceOf(address(market)), expectedBalance, "router CLAIM balance should match active escrow funds"
        );
    }

    function testEscrowConservation_CreateCancelExpireExecute() public {
        uint256 offerId = _createAliceOfferWithTtl(30 days);
        _assertEscrowBackedClaimBalance(offerId);

        vm.prank(alice);
        market.cancelBonusTargetEscrow(offerId);
        _assertEscrowBackedClaimBalance(offerId);

        offerId = _createAliceOfferWithTtl(30 days);
        _assertEscrowBackedClaimBalance(offerId);

        MarketRouter.BonusTargetEscrow memory offer = market.getBonusTargetEscrow(offerId);
        vm.warp(offer.expiresAt + 1);

        vm.prank(randomUser);
        market.cancelExpiredBonusTargetEscrow(offerId);
        _assertEscrowBackedClaimBalance(offerId);

        offerId = _createAliceOffer();
        _assertEscrowBackedClaimBalance(offerId);

        vm.prank(keeper);
        market.executeAutoFurnace(offerId, block.timestamp + 300);
        _assertEscrowBackedClaimBalance(offerId);
    }

    function test_offer_keeperCanExecuteDuringGrace() public {
        uint256 offerId = _createAliceOffer();

        vm.prank(keeper);
        market.executeAutoFurnace(offerId, block.timestamp + 300);

        (,,,,, uint256 fundsRemaining,,, bool active) = market.offers(offerId);
        assertFalse(active);
        assertEq(fundsRemaining, 0);
    }

    function test_offer_ownerCanExecuteDuringGrace() public {
        uint256 offerId = _createAliceOffer();

        market.executeAutoFurnace(offerId, block.timestamp + 300);

        (,,,,, uint256 fundsRemaining,,, bool active) = market.offers(offerId);
        assertFalse(active);
        assertEq(fundsRemaining, 0);
    }

    function test_offer_randomUserRevertsDuringGrace() public {
        uint256 offerId = _createAliceOffer();

        vm.prank(randomUser);
        vm.expectRevert(Errors.SettlementKeeperGracePeriod.selector);
        market.executeAutoFurnace(offerId, block.timestamp + 300);
    }

    function test_offer_randomUserSucceedsAfterGrace() public {
        uint256 offerId = _createAliceOffer();

        uint256 warpTarget = block.timestamp + Constants.SETTLEMENT_KEEPER_GRACE_SECONDS + 1;
        vm.warp(warpTarget);

        vm.prank(randomUser);
        market.executeAutoFurnace(offerId, warpTarget + 300);

        (,,,,, uint256 fundsRemaining,,, bool active) = market.offers(offerId);
        assertFalse(active);
        assertEq(fundsRemaining, 0);
    }

    function test_offer_randomUserSucceedsAtExactGraceBoundary() public {
        uint256 offerId = _createAliceOffer();

        vm.warp(block.timestamp + Constants.SETTLEMENT_KEEPER_GRACE_SECONDS);

        vm.prank(randomUser);
        market.executeAutoFurnace(offerId, block.timestamp + 300);

        (,,,,, uint256 fundsRemaining,,, bool active) = market.offers(offerId);
        assertFalse(active);
        assertEq(fundsRemaining, 0);
    }

    function test_offer_keeperCanExecuteJustBeforeExpiry() public {
        uint256 offerId = _createAliceOfferWithTtl(30 days);
        MarketRouter.BonusTargetEscrow memory offer = market.getBonusTargetEscrow(offerId);
        assertTrue(offer.active);
        assertEq(offer.expiresAt, offer.createdAt + 30 days);

        vm.warp(offer.expiresAt - 1);

        vm.prank(keeper);
        market.executeAutoFurnace(offerId, block.timestamp + 300);

        (,,,,, uint256 fundsRemaining,,, bool active) = market.offers(offerId);
        assertFalse(active);
        assertEq(fundsRemaining, 0);
    }

    function test_offer_executeAutoFurnaceEmitsCanonicalAndAliasEvents() public {
        uint256 offerId = _createAliceOffer();

        vm.expectEmit(true, true, false, false);
        emit Events.BonusTargetEscrowExecuted(offerId, alice, 0, 0, 0, 0, 0, 0);
        vm.expectEmit(true, true, false, false);
        emit Events.BonusTargetEscrowAutoFurnaceExecuted(offerId, alice, 0, 0, 0, 0, 0, 0);

        vm.prank(keeper);
        market.executeAutoFurnace(offerId, block.timestamp + 300);
    }

    function test_offchainParity_executeAutoFurnaceEventsMatchQuoteAndExecution() public {
        uint256 offerId = _createAliceOffer();
        MarketRouter.BonusTargetEscrow memory offer = market.getBonusTargetEscrow(offerId);
        (uint256 principal, uint256 bonus, uint256 veOut, uint256 routeTokenId) =
            furnaceQuoter.quoteEnterWithClaim(alice, offer.fundsRemaining, 0, Constants.MAX_LOCK_DURATION, true);

        vm.recordLogs();
        vm.prank(keeper);
        market.executeAutoFurnace(offerId, block.timestamp + 300);
        Vm.Log[] memory logs = vm.getRecordedLogs();

        bytes32 canonicalTopic =
            keccak256("BonusTargetEscrowExecuted(uint256,address,uint256,uint256,uint256,uint256,uint256,uint256)");
        bytes32 aliasTopic = keccak256(
            "BonusTargetEscrowAutoFurnaceExecuted(uint256,address,uint256,uint256,uint256,uint256,uint256,uint256)"
        );
        bool foundCanonical;
        bool foundAlias;
        uint256 canonicalTokenId;
        uint256 aliasTokenId;

        for (uint256 i = 0; i < logs.length; ++i) {
            if (logs[i].topics.length == 3 && (logs[i].topics[0] == canonicalTopic || logs[i].topics[0] == aliasTopic))
            {
                assertEq(logs[i].topics[1], bytes32(offerId), "offer id topic");
                assertEq(logs[i].topics[2], bytes32(uint256(uint160(alice))), "buyer topic");
                (
                    uint256 claimInEvent,
                    uint256 principalEvent,
                    uint256 bonusEvent,
                    uint256 veOutEvent,
                    uint256 routeTokenIdEvent,
                    uint256 furnaceTokenIdEvent
                ) = abi.decode(logs[i].data, (uint256, uint256, uint256, uint256, uint256, uint256));

                assertEq(claimInEvent, offer.fundsRemaining, "claimIn");
                assertEq(principalEvent, principal, "principal");
                assertEq(bonusEvent, bonus, "bonus");
                assertEq(veOutEvent, veOut, "veOut");
                assertEq(routeTokenIdEvent, routeTokenId, "route token id");
                assertGt(furnaceTokenIdEvent, 0, "executed token id");

                if (logs[i].topics[0] == canonicalTopic) {
                    foundCanonical = true;
                    canonicalTokenId = furnaceTokenIdEvent;
                } else {
                    foundAlias = true;
                    aliasTokenId = furnaceTokenIdEvent;
                }
            }
        }

        assertTrue(foundCanonical, "canonical auto-furnace event not found");
        assertTrue(foundAlias, "alias auto-furnace event not found");
        assertEq(canonicalTokenId, aliasTokenId, "canonical and alias token ids must match");
        (uint256 locked,,,) = ve.getLockInfo(canonicalTokenId);
        assertEq(locked, principal + bonus, "event quote must equal minted lock amount");
        assertEq(claim.balanceOf(address(market)), 0, "execution must spend escrowed CLAIM");
    }

    function test_executeAutoFurnaceExistingLockUsesLiveRemainingDurationForQuoteAndExecution() public {
        uint256 shortLockId = _createAliceLock(Constants.MIN_LOCK_AMOUNT, Constants.MIN_LOCK_DURATION, false);
        (, uint256 shortLockEnd,,) = ve.getLockInfo(shortLockId);
        uint256 shortRemaining = shortLockEnd - block.timestamp;
        uint256 budget = market.minBonusTargetEscrowBudget();

        uint256 principalShort;
        uint256 bonusShort;
        uint256 veOutShort;
        {
            uint256 routeShort;
            (principalShort, bonusShort, veOutShort, routeShort) =
                furnaceQuoter.quoteEnterWithClaim(alice, budget, shortLockId, shortRemaining, false);

            assertEq(routeShort, shortLockId, "quote should route into the existing lock");
        }

        // Use MIN_LOCK_DURATION so the existing lock (which has >= MIN_LOCK_DURATION remaining) is eligible.
        vm.prank(alice);
        uint256 offerId =
            market.createBonusTargetEscrowWithTarget(1, budget, Constants.MIN_LOCK_DURATION, false, 0, shortLockId, 0);

        (uint256 lockAmountBefore,,,) = ve.getLockInfo(shortLockId);

        vm.prank(keeper);
        market.executeAutoFurnace(offerId, block.timestamp + 300);

        (uint256 lockAmountAfter, uint256 lockEndAfter,,) = ve.getLockInfo(shortLockId);
        assertEq(
            lockAmountAfter - lockAmountBefore,
            principalShort + bonusShort,
            "execution should use the live remaining duration"
        );
        assertEq(lockEndAfter, shortLockEnd, "entry into an existing lock must not extend duration");
    }

    function test_executeAutoFurnaceRevertsWhenVeFurnaceRoyaltiesRootMismatchesAndPreservesOffer() public {
        MockMarketSettlementFurnace foreignFurnace =
            new MockMarketSettlementFurnace(address(claim), address(ve), address(market), makeAddr("wrongRoyalties"));

        vm.expectRevert(Errors.WiringMismatch.selector);
        ve.setFurnace(address(foreignFurnace));
    }

    function test_executeAutoFurnaceRevertsWhenVeAndRoyaltiesPointToForeignFurnaceButMineCoreDoesNot() public {
        MockMarketSettlementFurnace foreignFurnace =
            new MockMarketSettlementFurnace(address(claim), address(ve), address(market), address(royalties));
        foreignFurnace.setMineCore(makeAddr("foreignCore"));

        vm.expectRevert(Errors.WiringMismatch.selector);
        ve.setFurnace(address(foreignFurnace));
    }

    function test_executeAutoFurnaceRevertsWhenCanonicalFurnaceRoyaltiesRootDriftsAndPreservesOffer() public {
        ShareholderRoyalties foreignRoyalties = new ShareholderRoyalties(address(ve), owner);
        MockMarketSettlementFurnace foreignFurnace =
            new MockMarketSettlementFurnace(address(claim), address(ve), address(market), address(foreignRoyalties));
        foreignFurnace.setMineCore(address(core));

        vm.expectRevert(Errors.WiringMismatch.selector);
        ve.setFurnace(address(foreignFurnace));
    }

    function test_offer_randomUserCanCancelAtExactExpiry() public {
        uint256 offerId = _createAliceOfferWithTtl(30 days);
        MarketRouter.BonusTargetEscrow memory offer = market.getBonusTargetEscrow(offerId);
        assertTrue(offer.active);
        assertEq(offer.expiresAt, offer.createdAt + 30 days);

        uint256 buyerClaimBefore = claim.balanceOf(offer.buyer);
        uint256 fundsRemainingBefore = offer.fundsRemaining;

        vm.warp(offer.expiresAt);

        vm.prank(randomUser);
        market.cancelExpiredBonusTargetEscrow(offerId);

        offer = market.getBonusTargetEscrow(offerId);
        assertFalse(offer.active, "offer should be cancelled at exact expiry");
        assertEq(offer.fundsRemaining, 0);
        assertEq(claim.balanceOf(alice), buyerClaimBefore + fundsRemainingBefore);
    }

    function test_offer_randomUserCanCancelAfterExpiry() public {
        uint256 offerId = _createAliceOfferWithTtl(30 days);
        MarketRouter.BonusTargetEscrow memory offer = market.getBonusTargetEscrow(offerId);
        assertTrue(offer.active);
        assertEq(offer.expiresAt, offer.createdAt + 30 days);

        uint256 buyerClaimBefore = claim.balanceOf(offer.buyer);
        uint256 fundsRemainingBefore = offer.fundsRemaining;

        vm.warp(offer.expiresAt + 1);

        vm.expectEmit(true, true, false, true);
        emit Events.BonusTargetEscrowExpired(offerId, offer.buyer, offer.fundsRemaining);

        vm.prank(randomUser);
        market.cancelExpiredBonusTargetEscrow(offerId);

        offer = market.getBonusTargetEscrow(offerId);
        assertFalse(offer.active);
        assertEq(offer.fundsRemaining, 0);
        assertEq(claim.balanceOf(offer.buyer), buyerClaimBefore + fundsRemainingBefore);
    }

    function test_offer_buyerCanExtendAtExactExpiry() public {
        uint256 offerId = _createAliceOfferWithTtl(30 days);
        MarketRouter.BonusTargetEscrow memory offer = market.getBonusTargetEscrow(offerId);
        assertTrue(offer.active);
        assertEq(offer.expiresAt, offer.createdAt + 30 days);

        vm.warp(offer.expiresAt - 1);

        vm.prank(alice);
        market.extendBonusTargetEscrowExpiry(offerId, offer.expiresAt + 1 days);

        offer = market.getBonusTargetEscrow(offerId);
        assertEq(offer.expiresAt, offer.createdAt + 31 days);
        assertTrue(offer.active);
    }

    function testFuzz_offerCannotExecuteOnlyAfterExpiry(uint40 delaySeconds) public {
        delaySeconds = uint40(bound(uint256(delaySeconds), 1, 30 days));

        uint256 offerId = _createAliceOfferWithTtl(30 days);
        MarketRouter.BonusTargetEscrow memory offer = market.getBonusTargetEscrow(offerId);

        vm.warp(offer.expiresAt + delaySeconds);

        vm.prank(keeper);
        vm.expectRevert(Errors.OfferExpired.selector);
        market.executeAutoFurnace(offerId, block.timestamp + 300);
    }

    function testFuzz_sellLockToFurnaceRejectsAnyForeignFurnaceRoot(
        bool badClaim,
        bool badVe,
        bool badMineMarket,
        bool badRoyalties
    ) public {
        vm.assume(badClaim || badVe || badMineMarket || badRoyalties);

        address claimRoot = badClaim ? address(new ClaimToken(owner)) : address(claim);
        address veRoot = badVe ? address(new VeClaimNFT(address(claim), owner)) : address(ve);
        address marketRoot = badMineMarket ? makeAddr("foreignMarket") : address(market);
        address royaltiesRoot = badRoyalties ? makeAddr("foreignRoyalties") : address(royalties);

        MockMarketSettlementFurnace foreignFurnace =
            new MockMarketSettlementFurnace(claimRoot, veRoot, marketRoot, royaltiesRoot);

        vm.expectRevert(Errors.WiringMismatch.selector);
        ve.setFurnace(address(foreignFurnace));
    }

    function testFuzz_sellLockToFurnaceRejectsForeignFurnaceMineCoreAnchor(address foreignCore) public {
        vm.assume(foreignCore != address(0));
        vm.assume(foreignCore != address(core));

        MockMarketSettlementFurnace foreignFurnace =
            new MockMarketSettlementFurnace(address(claim), address(ve), address(market), address(royalties));
        foreignFurnace.setMineCore(foreignCore);

        vm.expectRevert(Errors.WiringMismatch.selector);
        ve.setFurnace(address(foreignFurnace));
    }

    // =====================================================================
    // lockingPaused gates MarketRouter sell paths (end-to-end)
    // =====================================================================
    // Documented in developer manual: "sellLockToFurnaceFromMarket and the
    // MarketRouter sell paths that depend on it also revert with
    // Errors.LockingPaused" when lockingPaused is true.  The Furnace
    // modifier enforces this, but an end-to-end test through the
    // MarketRouter sell path was missing (noted in security-test-matrix
    // INV-2).

    function test_lockingPaused_gatesSellLockToFurnace() public {
        vm.prank(address(core));
        furnace.setLockingPaused(true);
        assertTrue(furnace.lockingPaused());

        vm.prank(alice);
        vm.expectRevert(Errors.LockingPaused.selector);
        market.sellLockToFurnace(aliceTokenId, 1, block.timestamp + 1);

        // Verify alice still owns the lock.
        assertEq(ve.ownerOf(aliceTokenId), alice, "seller should retain the lock when locking paused");
    }

    function test_lockingPaused_gatesSellListedLockToFurnace() public {
        _listAliceLock();

        vm.roll(block.number + 1);
        vm.prank(address(core));
        furnace.setLockingPaused(true);
        assertTrue(furnace.lockingPaused());

        vm.prank(keeper);
        vm.expectRevert(Errors.QuoteCallFailed.selector);
        market.sellListedLockToFurnace(aliceTokenId, block.timestamp + 300);
    }

    // =====================================================================
    // Grace constant sanity
    // =====================================================================

    function test_graceConstant_is300Seconds() public pure {
        assertEq(Constants.SETTLEMENT_KEEPER_GRACE_SECONDS, 1800);
    }

    /// @notice listLock MUST set the VeClaimNFT listed flag.
    function test_listLockSetsListedFlag() public {
        (,,, bool listedBefore) = ve.getLockInfo(aliceTokenId);
        assertFalse(listedBefore, "should start unlisted");

        vm.prank(alice);
        market.listLock(aliceTokenId, 1, block.timestamp + 30 days);

        (,,, bool listedAfter) = ve.getLockInfo(aliceTokenId);
        assertTrue(listedAfter, "listed flag should be set after listLock");

        (address seller, uint256 minClaimOut, uint256 listedAtTime, uint256 expiresAtTime, bool active) =
            market.listings(aliceTokenId);
        assertTrue(active, "listing should be active");
        assertEq(seller, alice, "seller should be alice");
        assertEq(minClaimOut, 1, "minClaimOut mismatch");
        assertEq(listedAtTime, block.timestamp, "listedAtTime should be current timestamp");
    }

    /// @notice delistLock MUST clear the VeClaimNFT listed flag.
    function test_delistLockClearsListedFlag() public {
        _listAliceLock();

        vm.roll(block.number + 1);
        vm.prank(alice);
        market.delistLock(aliceTokenId);

        (,,, bool listed) = ve.getLockInfo(aliceTokenId);
        assertFalse(listed, "listed flag should be cleared after delistLock");

        (,,,, bool active) = market.listings(aliceTokenId);
        assertFalse(active, "listing should be inactive after delistLock");
    }

    function test_delistLockOnNewRouterClearsStaleListedFlagAfterRewire() public {
        uint256 shortLockId = _createAliceLock(Constants.MIN_LOCK_AMOUNT, Constants.MIN_LOCK_DURATION + 1 days, false);
        (, uint256 shortLockEnd,,) = ve.getLockInfo(shortLockId);

        vm.prank(alice);
        market.listLock(shortLockId, 1, shortLockEnd - 1);

        vm.roll(block.number + 1);

        MarketRouter newMarket = new MarketRouter(address(claim), address(ve), address(royalties), owner);
        _rewireCanonicalMarket(address(newMarket));

        vm.prank(alice);
        vm.expectRevert(Errors.OnlyMineMarket.selector);
        market.delistLock(shortLockId);

        MarketRouter.Listing memory listing = newMarket.getListing(shortLockId);
        assertFalse(listing.active, "new router should start without inherited local listing state");

        (,,, bool listedBeforeRescue) = ve.getLockInfo(shortLockId);
        assertTrue(listedBeforeRescue, "ve listed flag stays stranded after rewire without rescue path");

        vm.prank(alice);
        newMarket.delistLock(shortLockId);

        (,,, bool listedAfterRescue) = ve.getLockInfo(shortLockId);
        assertFalse(listedAfterRescue, "new router should clear stale ve listed flag");

        vm.warp(shortLockEnd);
        uint256 aliceClaimBefore = claim.balanceOf(alice);
        vm.prank(alice);
        ve.unlock(shortLockId);
        assertEq(claim.balanceOf(alice), aliceClaimBefore + Constants.MIN_LOCK_AMOUNT, "unlock should succeed");
    }

    function test_oldRouterStaleListingCannotResurrectSettlementAfterRollback() public {
        uint256 shortLockId = _createAliceLock(Constants.MIN_LOCK_AMOUNT, Constants.MIN_LOCK_DURATION + 1 days, false);
        (, uint256 shortLockEnd,,) = ve.getLockInfo(shortLockId);

        vm.prank(alice);
        market.listLock(shortLockId, 1, shortLockEnd - 1);

        MarketRouter.Listing memory originalListing = market.getListing(shortLockId);
        uint256 originalListedAt = originalListing.listedAtTime;
        vm.roll(block.number + 1);

        MarketRouter newMarket = new MarketRouter(address(claim), address(ve), address(royalties), owner);
        _rewireCanonicalMarket(address(newMarket));

        vm.prank(alice);
        newMarket.delistLock(shortLockId);

        (,,, bool listedAfterRescue) = ve.getLockInfo(shortLockId);
        assertFalse(listedAfterRescue, "replacement rescue should clear ve listed flag");
        MarketRouter.Listing memory staleOldListing = market.getListing(shortLockId);
        assertTrue(staleOldListing.active, "old router should still retain its stale local listing slot");

        _rewireCanonicalMarket(address(market));

        vm.roll(block.number + 1);
        vm.warp(originalListedAt + Constants.SETTLEMENT_KEEPER_GRACE_SECONDS + 1);

        vm.prank(randomUser);
        vm.expectRevert(Errors.ListingNotActive.selector);
        market.sellListedLockToFurnace(shortLockId, block.timestamp + 300);

        vm.prank(alice);
        market.delistLock(shortLockId);
        MarketRouter.Listing memory clearedListing = market.getListing(shortLockId);
        assertFalse(clearedListing.active, "seller should be able to clear stale local listing state");
    }

    function test_offer_randomUserCannotCancelBeforeExpiryWhileCanonical() public {
        uint256 offerId = _createAliceOfferWithTtl(30 days);

        vm.prank(randomUser);
        vm.expectRevert(Errors.NotAuthorized.selector);
        market.cancelBonusTargetEscrow(offerId);
    }

    function test_offer_staleRouterCreateRevertsAfterRewire() public {
        MarketRouter newMarket = new MarketRouter(address(claim), address(ve), address(royalties), owner);
        _rewireCanonicalMarket(address(newMarket));

        uint256 budget = market.minBonusTargetEscrowBudget();
        vm.prank(alice);
        vm.expectRevert(Errors.WiringMismatch.selector);
        market.createBonusTargetEscrowWithTarget(1, budget, 30 days, true, 0, 0, 0);
    }

    function test_offer_randomUserCanCancelOnStaleRouterAfterRewire() public {
        uint256 offerId = _createAliceOfferWithTtl(30 days);
        MarketRouter.BonusTargetEscrow memory offer = market.getBonusTargetEscrow(offerId);
        uint256 buyerClaimBefore = claim.balanceOf(alice);
        uint256 refundClaim = offer.fundsRemaining;

        MarketRouter newMarket = new MarketRouter(address(claim), address(ve), address(royalties), owner);
        _rewireCanonicalMarket(address(newMarket));

        vm.prank(randomUser);
        market.cancelBonusTargetEscrow(offerId);

        offer = market.getBonusTargetEscrow(offerId);
        assertFalse(offer.active, "stale-router offer should be cancellable before expiry");
        assertEq(offer.fundsRemaining, 0, "refund should zero remaining funds");
        assertEq(claim.balanceOf(alice), buyerClaimBefore + refundClaim, "buyer should receive full refund");
        assertEq(claim.balanceOf(randomUser), 0, "caller should not receive CLAIM");
    }

    function test_offer_randomUserCanCancelWhenClaimMineCoreDrifts() public {
        uint256 offerId = _createAliceOfferWithTtl(30 days);
        MarketRouter.BonusTargetEscrow memory offer = market.getBonusTargetEscrow(offerId);
        uint256 buyerClaimBefore = claim.balanceOf(alice);
        uint256 refundClaim = offer.fundsRemaining;

        MockMineCoreWiringView foreignCore = new MockMineCoreWiringView(address(claim), address(ve), address(royalties));
        claim.setMineCore(address(foreignCore));

        vm.prank(randomUser);
        market.cancelBonusTargetEscrow(offerId);

        offer = market.getBonusTargetEscrow(offerId);
        assertFalse(offer.active, "bundle drift should open stale-offer cancellation");
        assertEq(offer.fundsRemaining, 0, "refund should zero remaining funds");
        assertEq(claim.balanceOf(alice), buyerClaimBefore + refundClaim, "buyer should receive full refund");
        assertEq(claim.balanceOf(randomUser), 0, "caller should not receive CLAIM");
    }

    function test_offer_extendRevertsOnStaleRouterAfterRewire() public {
        uint256 offerId = _createAliceOfferWithTtl(30 days);
        MarketRouter.BonusTargetEscrow memory offer = market.getBonusTargetEscrow(offerId);

        MarketRouter newMarket = new MarketRouter(address(claim), address(ve), address(royalties), owner);
        _rewireCanonicalMarket(address(newMarket));

        vm.prank(alice);
        vm.expectRevert(Errors.WiringMismatch.selector);
        market.extendBonusTargetEscrowExpiry(offerId, offer.expiresAt + 1 days);
    }

    /// @notice Settlement MUST call checkpointTransfer BEFORE the veNFT transfer.
    function test_listingSettlementCallsCheckpointTransferBeforeTransfer() public {
        _listAliceLock();

        vm.roll(block.number + 1);

        assertEq(ve.ownerOf(aliceTokenId), alice, "alice should own the token");

        vm.prank(keeper);
        uint256 claimOut = market.sellListedLockToFurnace(aliceTokenId, block.timestamp + 300);
        assertGt(claimOut, 0, "settlement should produce non-zero claimOut");

        vm.expectRevert();
        ve.ownerOf(aliceTokenId);
    }

    /// @notice Settlement MUST clear internal listing state after settlement.
    function test_listingSettlementClearsListing() public {
        _listAliceLock();

        vm.roll(block.number + 1);

        vm.prank(keeper);
        market.sellListedLockToFurnace(aliceTokenId, block.timestamp + 300);

        (,,,, bool active) = market.listings(aliceTokenId);
        assertFalse(active, "listing should be cleared after settlement");

        uint256[] memory aliceListings = market.getUserListings(alice);
        assertEq(aliceListings.length, 0, "alice should have no active listings after settlement");
    }

    /// @notice executeAutoFurnace MUST revert if bonusBpsVsPrincipalClaim < targetBonusBps.
    function test_executeAutoFurnaceRevertsIfBonusNotMet() public {
        uint256 budget = market.minBonusTargetEscrowBudget();
        vm.prank(alice);
        uint256 offerId = market.createBonusTargetEscrowWithTarget(9999, budget, 30 days, true, 0, 0, 0);

        vm.prank(keeper);
        vm.expectRevert(Errors.BonusTargetNotMet.selector);
        market.executeAutoFurnace(offerId, block.timestamp + 300);

        MarketRouter.BonusTargetEscrow memory offer = market.getBonusTargetEscrow(offerId);
        assertTrue(offer.active, "offer should remain active after BonusTargetNotMet revert");
        assertEq(offer.fundsRemaining, budget, "funds should remain escrowed");
    }

    /// @notice extendBonusTargetEscrowExpiry MUST revert if newExpiresAt > createdAt + MAX_TTL.
    function test_extendBonusTargetEscrowExpiryBoundedByMaxTTL() public {
        uint256 offerId = _createAliceOfferWithTtl(30 days);
        MarketRouter.BonusTargetEscrow memory offer = market.getBonusTargetEscrow(offerId);

        uint256 tooFar = offer.createdAt + Constants.MAX_BONUS_TARGET_ESCROW_TTL_SECONDS + 1;

        vm.prank(alice);
        vm.expectRevert(Errors.InvalidOfferExpiry.selector);
        market.extendBonusTargetEscrowExpiry(offerId, tooFar);

        uint256 exactMax = offer.createdAt + Constants.MAX_BONUS_TARGET_ESCROW_TTL_SECONDS;

        vm.prank(alice);
        market.extendBonusTargetEscrowExpiry(offerId, exactMax);

        offer = market.getBonusTargetEscrow(offerId);
        assertEq(offer.expiresAt, exactMax, "expiry should be set to exact max");
    }

    /// @notice extendBonusTargetEscrowExpiry MUST revert if newExpiresAt <= current expiresAt.
    function test_extendBonusTargetEscrowExpiryRevertsIfNotIncreasing() public {
        uint256 offerId = _createAliceOfferWithTtl(30 days);
        MarketRouter.BonusTargetEscrow memory offer = market.getBonusTargetEscrow(offerId);

        vm.prank(alice);
        vm.expectRevert(Errors.InvalidOfferExpiry.selector);
        market.extendBonusTargetEscrowExpiry(offerId, offer.expiresAt);

        vm.prank(alice);
        vm.expectRevert(Errors.InvalidOfferExpiry.selector);
        market.extendBonusTargetEscrowExpiry(offerId, offer.expiresAt - 1);
    }

    /// @notice executeAutoFurnace MUST revert if budget < MIN_LOCK_AMOUNT for new lock.
    function test_executeAutoFurnaceRevertsIfBudgetBelowMinLockAmountForNewLock() public {
        assertTrue(
            Constants.DEFAULT_MIN_BONUS_TARGET_ESCROW_BUDGET >= Constants.MIN_LOCK_AMOUNT,
            "anti-spam minimum should exceed MIN_LOCK_AMOUNT"
        );
    }

    /// @notice sellLockToFurnace with auto-delist emits LockDelisted then MarketSellToFurnace.
    function test_sellLockToFurnace_autoDelistEmitsCorrectEvents() public {
        _listAliceLock();

        vm.roll(block.number + 1);

        vm.expectEmit(true, true, false, true);
        emit Events.LockDelisted(aliceTokenId, alice, Constants.LOCK_DELIST_REASON_SOLD_TO_FURNACE);

        vm.prank(alice);
        uint256 claimOut = market.sellLockToFurnace(aliceTokenId, 1, block.timestamp + 300);
        assertGt(claimOut, 0, "should receive CLAIM payout");
    }

    function test_offchainParity_marketSellEventMatchesQuoteAndPayout() public {
        (uint256 lockAmount, uint256 claimOutQuote,,,) = furnaceQuoter.quoteSellLockToFurnace(alice, aliceTokenId);
        assertGt(lockAmount, 0, "quote lock amount");

        uint256 deadline = block.timestamp + 300;
        uint256 sellerClaimBefore = claim.balanceOf(alice);

        vm.recordLogs();
        vm.prank(alice);
        uint256 claimOut = market.sellLockToFurnace(aliceTokenId, 1, deadline);
        Vm.Log[] memory logs = vm.getRecordedLogs();

        assertEq(claimOut, claimOutQuote, "return value must match quote");
        assertEq(claim.balanceOf(alice) - sellerClaimBefore, claimOutQuote, "seller payout must match quote");

        bytes32 marketSellTopic = keccak256("MarketSellToFurnace(uint256,address,uint256,uint256,uint256)");
        bool found;
        for (uint256 i = 0; i < logs.length; ++i) {
            if (logs[i].topics.length == 3 && logs[i].topics[0] == marketSellTopic) {
                found = true;
                assertEq(logs[i].topics[1], bytes32(aliceTokenId), "tokenId topic");
                assertEq(logs[i].topics[2], bytes32(uint256(uint160(alice))), "seller topic");
                (uint256 minClaimOutEvent, uint256 deadlineEvent, uint256 claimOutEvent) =
                    abi.decode(logs[i].data, (uint256, uint256, uint256));
                assertEq(minClaimOutEvent, 1, "minClaimOut");
                assertEq(deadlineEvent, deadline, "deadline");
                assertEq(claimOutEvent, claimOutQuote, "event claimOut");
                break;
            }
        }

        assertTrue(found, "MarketSellToFurnace event not found");
    }

    /// @notice Listing created in the current block cannot be settled in the same block.
    function test_listingCooldownPreventsSettlementInSameBlock() public {
        _listAliceLock();

        vm.prank(keeper);
        vm.expectRevert(Errors.ListingCooldown.selector);
        market.sellListedLockToFurnace(aliceTokenId, block.timestamp + 300);
    }

    /// @notice Offer execution at exact expiry MUST revert, not succeed.
    function test_offer_executeRevertsAtExactExpiry() public {
        uint256 offerId = _createAliceOfferWithTtl(30 days);
        MarketRouter.BonusTargetEscrow memory offer = market.getBonusTargetEscrow(offerId);

        vm.warp(offer.expiresAt);

        vm.prank(keeper);
        vm.expectRevert(Errors.OfferExpired.selector);
        market.executeAutoFurnace(offerId, block.timestamp + 300);
    }

    /// @notice createBonusTargetEscrowWithTarget MUST escrow CLAIM from buyer.
    function test_createBonusTargetEscrowEscrowsClaim() public {
        uint256 budget = market.minBonusTargetEscrowBudget();
        uint256 aliceBalBefore = claim.balanceOf(alice);
        uint256 routerBalBefore = claim.balanceOf(address(market));

        vm.prank(alice);
        uint256 offerId = market.createBonusTargetEscrowWithTarget(1, budget, 30 days, true, 0, 0, 0);

        assertEq(claim.balanceOf(alice), aliceBalBefore - budget, "buyer CLAIM should decrease by budget");
        assertEq(claim.balanceOf(address(market)), routerBalBefore + budget, "router CLAIM should increase by budget");

        MarketRouter.BonusTargetEscrow memory offer = market.getBonusTargetEscrow(offerId);
        assertEq(offer.fundsRemaining, budget, "fundsRemaining should equal budget");
        assertTrue(offer.active, "offer should be active");
    }

    /// @notice cancelBonusTargetEscrow MUST refund remaining CLAIM to buyer.
    function test_cancelBonusTargetEscrowRefundsEscrow() public {
        uint256 budget = market.minBonusTargetEscrowBudget();
        vm.prank(alice);
        uint256 offerId = market.createBonusTargetEscrowWithTarget(1, budget, 30 days, true, 0, 0, 0);

        uint256 aliceBalBefore = claim.balanceOf(alice);

        vm.prank(alice);
        market.cancelBonusTargetEscrow(offerId);

        assertEq(claim.balanceOf(alice), aliceBalBefore + budget, "buyer should receive full refund");
        assertEq(claim.balanceOf(address(market)), 0, "router should have zero CLAIM after refund");

        MarketRouter.BonusTargetEscrow memory offer = market.getBonusTargetEscrow(offerId);
        assertFalse(offer.active, "offer should be inactive");
        assertEq(offer.fundsRemaining, 0, "fundsRemaining should be zero");
    }

    function test_listingDelistRelistSellbackCycleClearsIndexesAndCannotDoubleSettle() public {
        uint256 aliceClaimBefore = claim.balanceOf(alice);
        uint256 blockCursor = block.number;

        vm.prank(alice);
        market.listLock(aliceTokenId, 1, block.timestamp + 30 days);
        uint256[] memory aliceListings = market.getUserListings(alice);
        assertEq(aliceListings.length, 1, "listed token should enter seller index");
        assertEq(aliceListings[0], aliceTokenId, "seller index token mismatch");

        vm.roll(++blockCursor);
        vm.prank(alice);
        market.delistLock(aliceTokenId);
        aliceListings = market.getUserListings(alice);
        assertEq(aliceListings.length, 0, "delist should clear seller index");

        vm.roll(++blockCursor);
        vm.prank(alice);
        market.listLock(aliceTokenId, 1, block.timestamp + 30 days);
        aliceListings = market.getUserListings(alice);
        assertEq(aliceListings.length, 1, "relist should add exactly one index entry");
        assertEq(aliceListings[0], aliceTokenId, "relist token mismatch");

        vm.roll(++blockCursor);
        vm.prank(alice);
        uint256 claimOut = market.sellLockToFurnace(aliceTokenId, 1, block.timestamp + 300);
        assertGt(claimOut, 0, "sellback should pay CLAIM");
        assertEq(claim.balanceOf(alice), aliceClaimBefore + claimOut, "cycle should not leak seller CLAIM");

        (,,,, bool active) = market.listings(aliceTokenId);
        assertFalse(active, "sellback auto-delist should clear listing");
        aliceListings = market.getUserListings(alice);
        assertEq(aliceListings.length, 0, "sellback should clear seller index");

        vm.prank(keeper);
        vm.expectRevert(Errors.ListingNotActive.selector);
        market.sellListedLockToFurnace(aliceTokenId, block.timestamp + 300);
    }

    function test_escrowCancelExpireExecuteCycleKeepsRouterBalanceAndIndexesClean() public {
        uint256 budget = market.minBonusTargetEscrowBudget();

        vm.prank(alice);
        uint256 offerId = market.createBonusTargetEscrowWithTarget(1, budget, 30 days, true, 30 days, 0, 0);
        assertEq(claim.balanceOf(address(market)), budget, "active offer should be fully escrowed");
        uint256[] memory aliceOffers = market.getUserBonusTargetEscrows(alice);
        assertEq(aliceOffers.length, 1, "offer should enter buyer index");

        vm.prank(alice);
        market.cancelBonusTargetEscrow(offerId);
        assertEq(claim.balanceOf(address(market)), 0, "cancel should refund escrow");
        aliceOffers = market.getUserBonusTargetEscrows(alice);
        assertEq(aliceOffers.length, 0, "cancel should clear buyer index");
        MarketRouter.BonusTargetEscrow memory offer = market.getBonusTargetEscrow(offerId);
        assertFalse(offer.active, "cancelled offer inactive");
        assertEq(offer.fundsRemaining, 0, "cancelled offer has no funds");

        vm.prank(alice);
        offerId = market.createBonusTargetEscrowWithTarget(1, budget, 30 days, true, 30 days, 0, 0);
        offer = market.getBonusTargetEscrow(offerId);
        vm.warp(offer.expiresAt);

        vm.prank(randomUser);
        market.cancelExpiredBonusTargetEscrow(offerId);
        assertEq(claim.balanceOf(address(market)), 0, "expired cancel should refund escrow");
        aliceOffers = market.getUserBonusTargetEscrows(alice);
        assertEq(aliceOffers.length, 0, "expired cancel should clear buyer index");
        offer = market.getBonusTargetEscrow(offerId);
        assertFalse(offer.active, "expired offer inactive");
        assertEq(offer.fundsRemaining, 0, "expired offer has no funds");

        vm.prank(alice);
        offerId = market.createBonusTargetEscrowWithTarget(1, budget, 30 days, true, 0, 0, 0);
        assertEq(claim.balanceOf(address(market)), budget, "execution offer should be fully escrowed");

        vm.prank(keeper);
        market.executeAutoFurnace(offerId, block.timestamp + 300);
        assertEq(claim.balanceOf(address(market)), 0, "execution should spend exactly the escrowed budget");
        aliceOffers = market.getUserBonusTargetEscrows(alice);
        assertEq(aliceOffers.length, 0, "execution should clear buyer index");
        offer = market.getBonusTargetEscrow(offerId);
        assertFalse(offer.active, "executed offer inactive");
        assertEq(offer.fundsRemaining, 0, "executed offer has no funds");
    }
}
