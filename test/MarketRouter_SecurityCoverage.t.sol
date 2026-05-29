// SPDX-License-Identifier: MIT
pragma solidity ^0.8.34;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

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
import {MockMineCoreWiringView} from "test/mocks/MockMineCoreWiringView.sol";
import {MockWETH} from "test/mocks/MockWETH.sol";
import {MockERC20} from "test/mocks/MockERC20.sol";

/// @notice Exhaustive security coverage tests for MarketRouter.
///         Covers function coverage, boundary cases, and guardian rotation.
contract MarketRouterSecurityCoverageTest is Test {
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
    address internal bob;
    address internal keeper;
    address internal guardian;
    address internal randomUser;

    function setUp() public {
        vm.txGasPrice(0);

        owner = address(this);
        alice = makeAddr("alice");
        bob = makeAddr("bob");
        keeper = makeAddr("keeper");
        guardian = makeAddr("guardian");
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

        // Seed Furnace reserve.
        uint256 reserveSeed = 50_000_000e18;
        vm.startPrank(address(core));
        claim.mint(address(furnace), reserveSeed);
        furnace.creditReserve(reserveSeed);
        vm.stopPrank();

        // Alice approvals + funding.
        ve.setApprovalForAllForTest(alice, address(market), true);
        vm.prank(alice);
        claim.approve(address(market), type(uint256).max);
        vm.prank(address(core));
        claim.mint(alice, 10_000_000e18);

        // Bob approvals + funding.
        ve.setApprovalForAllForTest(bob, address(market), true);
        vm.prank(bob);
        claim.approve(address(market), type(uint256).max);
        vm.prank(address(core));
        claim.mint(bob, 10_000_000e18);

        // Set guardian (distinct from owner).
        market.setGuardian(guardian);

        // Whitelist keeper.
        market.setSettlementKeeper(keeper, true);
    }

    // =====================================================================
    // Internal helpers
    // =====================================================================

    function _createLockFor(address user, uint256 amount, uint256 durationSeconds, bool autoMax)
        internal
        returns (uint256 tokenId)
    {
        vm.prank(address(core));
        claim.mint(address(furnace), amount);
        vm.prank(address(furnace));
        claim.approve(address(ve), amount);
        vm.prank(address(furnace));
        tokenId = ve.createLockFor(user, amount, durationSeconds, autoMax);
    }

    function _listLock(address user, uint256 tokenId) internal {
        vm.prank(user);
        market.listLock(tokenId, 1, block.timestamp + 30 days);
    }

    function _rollNext() internal {
        vm.roll(block.number + 1);
    }

    function _createOffer(address user, uint256 budget) internal returns (uint256 offerId) {
        vm.prank(user);
        offerId = market.createBonusTargetEscrowWithTarget(1, budget, 30 days, true, 0, 0, 0);
    }

    function _minBudget() internal view returns (uint256) {
        return market.minBonusTargetEscrowBudget();
    }

    // =====================================================================
    // Group 1: setBonusTargetEscrowParams
    // =====================================================================

    function test_setBonusTargetEscrowParams_onlyOwner_reverts() public {
        vm.prank(randomUser);
        vm.expectRevert();
        market.setBonusTargetEscrowParams(20_000e18, 8_000);
    }

    function test_setBonusTargetEscrowParams_zeroBudget_reverts() public {
        vm.expectRevert(Errors.BudgetTooSmall.selector);
        market.setBonusTargetEscrowParams(0, 8_000);
    }

    function test_setBonusTargetEscrowParams_discountOverBPS_reverts() public {
        uint256 currentMin = _minBudget();
        vm.expectRevert(Errors.DiscountTooHigh.selector);
        market.setBonusTargetEscrowParams(currentMin, 10_001);
    }

    function test_setBonusTargetEscrowParams_decreaseBudget_reverts() public {
        // Current default is 10_000e18. Trying to set lower should revert.
        uint256 currentMin = market.minBonusTargetEscrowBudget();
        vm.expectRevert(Errors.DecreaseNotAllowed.selector);
        market.setBonusTargetEscrowParams(currentMin - 1, 8_000);
    }

    function test_setBonusTargetEscrowParams_aboveCap_reverts() public {
        // Cap is 1_000_000e18.
        vm.expectRevert(Errors.BudgetTooHigh.selector);
        market.setBonusTargetEscrowParams(1_000_001e18, 8_000);
    }

    function test_setBonusTargetEscrowParams_happyPath() public {
        uint256 newBudget = 20_000e18;
        uint256 newDiscount = 9_000;

        vm.expectEmit(true, true, false, true);
        emit Events.BonusTargetEscrowParamsChanged(
            _minBudget(), newBudget, market.maxBonusTargetEscrowDiscountBps(), newDiscount
        );
        market.setBonusTargetEscrowParams(newBudget, newDiscount);

        assertEq(market.minBonusTargetEscrowBudget(), newBudget);
        assertEq(market.maxBonusTargetEscrowDiscountBps(), newDiscount);
    }

    function test_setBonusTargetEscrowParams_sameBudget_succeeds() public {
        // Setting to the same value should succeed (not a decrease).
        uint256 currentMin = market.minBonusTargetEscrowBudget();
        market.setBonusTargetEscrowParams(currentMin, 8_000);
        assertEq(market.minBonusTargetEscrowBudget(), currentMin);
    }

    function test_setBonusTargetEscrowParams_discountExact10000_succeeds() public {
        // 10_000 means "disable extra cap", should succeed.
        market.setBonusTargetEscrowParams(_minBudget(), 10_000);
        assertEq(market.maxBonusTargetEscrowDiscountBps(), 10_000);
    }

    // =====================================================================
    // Group 2: recoverToken
    // =====================================================================

    function test_recoverToken_onlyOwner_reverts() public {
        vm.prank(randomUser);
        vm.expectRevert();
        market.recoverToken(address(claim), randomUser, 1);
    }

    function test_recoverToken_blocksClaim_reverts() public {
        vm.expectRevert(Errors.NotAuthorized.selector);
        market.recoverToken(address(claim), owner, 1);
    }

    function test_recoverToken_zeroRecipient_reverts() public {
        MockERC20 junkToken = new MockERC20("Junk", "JUNK");
        junkToken.mint(address(market), 1000e18);

        vm.expectRevert(Errors.ZeroAddress.selector);
        market.recoverToken(address(junkToken), address(0), 1000e18);
    }

    function test_recoverToken_recoversOtherToken() public {
        MockERC20 junkToken = new MockERC20("Junk", "JUNK");
        junkToken.mint(address(market), 1000e18);

        assertEq(junkToken.balanceOf(address(market)), 1000e18);
        assertEq(junkToken.balanceOf(owner), 0);

        market.recoverToken(address(junkToken), owner, 1000e18);

        assertEq(junkToken.balanceOf(address(market)), 0);
        assertEq(junkToken.balanceOf(owner), 1000e18);
    }

    // =====================================================================
    // Group 3: cancelExpiredListingBatch
    // =====================================================================

    function test_cancelExpiredListingBatch_happyPath() public {
        uint256 t1 = _createLockFor(alice, Constants.MIN_LOCK_AMOUNT, Constants.MAX_LOCK_DURATION, false);
        _rollNext();
        uint256 t2 = _createLockFor(alice, Constants.MIN_LOCK_AMOUNT, Constants.MAX_LOCK_DURATION, false);
        _rollNext();
        uint256 t3 = _createLockFor(alice, Constants.MIN_LOCK_AMOUNT, Constants.MAX_LOCK_DURATION, false);

        // List all three with 1-day expiry.
        _rollNext();
        vm.prank(alice);
        market.listLock(t1, 1, block.timestamp + 1 days);
        _rollNext();
        vm.prank(alice);
        market.listLock(t2, 1, block.timestamp + 1 days);
        _rollNext();
        vm.prank(alice);
        market.listLock(t3, 1, block.timestamp + 1 days);

        // Warp past expiry.
        vm.warp(block.timestamp + 1 days + 1);
        _rollNext();

        // Batch cancel.
        uint256[] memory tokenIds = new uint256[](3);
        tokenIds[0] = t1;
        tokenIds[1] = t2;
        tokenIds[2] = t3;
        market.cancelExpiredListingBatch(tokenIds);

        // All listings should be cleared.
        (,,,, bool a1) = market.listings(t1);
        (,,,, bool a2) = market.listings(t2);
        (,,,, bool a3) = market.listings(t3);
        assertFalse(a1);
        assertFalse(a2);
        assertFalse(a3);

        // Ve listed flags should be cleared.
        (,,, bool listed1) = ve.getLockInfo(t1);
        (,,, bool listed2) = ve.getLockInfo(t2);
        (,,, bool listed3) = ve.getLockInfo(t3);
        assertFalse(listed1);
        assertFalse(listed2);
        assertFalse(listed3);

        // User listings array should be empty.
        assertEq(market.getUserListings(alice).length, 0);
    }

    function test_cancelExpiredListingBatch_skipsIneligible() public {
        uint256 t1 = _createLockFor(alice, Constants.MIN_LOCK_AMOUNT, Constants.MAX_LOCK_DURATION, false);
        _rollNext();
        uint256 t2 = _createLockFor(alice, Constants.MIN_LOCK_AMOUNT, Constants.MAX_LOCK_DURATION, false);

        // List t1 with 1-day expiry, t2 with 30-day expiry.
        _rollNext();
        vm.prank(alice);
        market.listLock(t1, 1, block.timestamp + 1 days);
        _rollNext();
        vm.prank(alice);
        market.listLock(t2, 1, block.timestamp + 30 days);

        // Warp past t1's expiry but not t2's.
        vm.warp(block.timestamp + 1 days + 1);
        _rollNext();

        // Batch cancel — should cancel t1, skip t2.
        uint256[] memory tokenIds = new uint256[](2);
        tokenIds[0] = t1;
        tokenIds[1] = t2;
        market.cancelExpiredListingBatch(tokenIds);

        (,,,, bool a1) = market.listings(t1);
        (,,,, bool a2) = market.listings(t2);
        assertFalse(a1, "expired listing should be cancelled");
        assertTrue(a2, "non-expired listing should remain active");
    }

    // =====================================================================
    // Group 4: cancelExpiredBonusTargetEscrowBatch
    // =====================================================================

    function test_cancelExpiredBonusTargetEscrowBatch_happyPath() public {
        uint256 budget = _minBudget();
        // Create 3 offers with short TTL.
        vm.prank(alice);
        uint256 o1 = market.createBonusTargetEscrowWithTarget(
            1, budget, 30 days, true, Constants.MIN_BONUS_TARGET_ESCROW_TTL_SECONDS, 0, 0
        );
        vm.prank(alice);
        uint256 o2 = market.createBonusTargetEscrowWithTarget(
            1, budget, 30 days, true, Constants.MIN_BONUS_TARGET_ESCROW_TTL_SECONDS, 0, 0
        );
        vm.prank(alice);
        uint256 o3 = market.createBonusTargetEscrowWithTarget(
            1, budget, 30 days, true, Constants.MIN_BONUS_TARGET_ESCROW_TTL_SECONDS, 0, 0
        );

        uint256 aliceBalanceBefore = claim.balanceOf(alice);

        // Warp past TTL expiry.
        vm.warp(block.timestamp + Constants.MIN_BONUS_TARGET_ESCROW_TTL_SECONDS + 1);

        // Batch cancel.
        uint256[] memory offerIds = new uint256[](3);
        offerIds[0] = o1;
        offerIds[1] = o2;
        offerIds[2] = o3;
        market.cancelExpiredBonusTargetEscrowBatch(offerIds);

        // All offers should be inactive.
        assertFalse(market.getBonusTargetEscrow(o1).active);
        assertFalse(market.getBonusTargetEscrow(o2).active);
        assertFalse(market.getBonusTargetEscrow(o3).active);

        // CLAIM refunded to alice.
        assertEq(claim.balanceOf(alice), aliceBalanceBefore + budget * 3);
        assertEq(claim.balanceOf(address(market)), 0);
    }

    function test_cancelExpiredBonusTargetEscrowBatch_skipsIneligible() public {
        uint256 budget = _minBudget();
        // o1 with short TTL, o2 with long TTL.
        vm.prank(alice);
        uint256 o1 = market.createBonusTargetEscrowWithTarget(
            1, budget, 30 days, true, Constants.MIN_BONUS_TARGET_ESCROW_TTL_SECONDS, 0, 0
        );
        vm.prank(alice);
        uint256 o2 = market.createBonusTargetEscrowWithTarget(
            1, budget, 30 days, true, Constants.MAX_BONUS_TARGET_ESCROW_TTL_SECONDS, 0, 0
        );

        // Warp past o1's expiry but not o2's.
        vm.warp(block.timestamp + Constants.MIN_BONUS_TARGET_ESCROW_TTL_SECONDS + 1);

        uint256[] memory offerIds = new uint256[](2);
        offerIds[0] = o1;
        offerIds[1] = o2;
        market.cancelExpiredBonusTargetEscrowBatch(offerIds);

        assertFalse(market.getBonusTargetEscrow(o1).active, "expired offer should be cancelled");
        assertTrue(market.getBonusTargetEscrow(o2).active, "non-expired offer should remain active");
    }

    // =====================================================================
    // Group 5: totalEscrowedClaim / totalEscrowedClaimPaginated
    // =====================================================================

    function test_totalEscrowedClaim_matchesActiveOfferSum() public {
        uint256 budget = _minBudget();

        assertEq(market.totalEscrowedClaim(), 0);

        uint256 o1 = _createOffer(alice, budget);
        assertEq(market.totalEscrowedClaim(), budget);

        uint256 o2 = _createOffer(alice, budget * 2);
        assertEq(market.totalEscrowedClaim(), budget * 3);

        // Cancel o1.
        vm.prank(alice);
        market.cancelBonusTargetEscrow(o1);
        assertEq(market.totalEscrowedClaim(), budget * 2);

        // Cancel o2.
        vm.prank(alice);
        market.cancelBonusTargetEscrow(o2);
        assertEq(market.totalEscrowedClaim(), 0);
    }

    function test_totalEscrowedClaimPaginated_correctRanges() public {
        uint256 budget = _minBudget();

        // Create 5 offers (IDs 1-5).
        for (uint256 i = 0; i < 5; i++) {
            _createOffer(alice, budget);
        }

        // Full range.
        assertEq(market.totalEscrowedClaimPaginated(1, 6), budget * 5);

        // Partial range [2, 4).
        assertEq(market.totalEscrowedClaimPaginated(2, 4), budget * 2);

        // startId < 1 clamps to 1.
        assertEq(market.totalEscrowedClaimPaginated(0, 6), budget * 5);

        // endId > nextOfferId clamps.
        assertEq(market.totalEscrowedClaimPaginated(1, 100), budget * 5);

        // Empty range.
        assertEq(market.totalEscrowedClaimPaginated(6, 6), 0);
        assertEq(market.totalEscrowedClaimPaginated(10, 6), 0);
    }

    // =====================================================================
    // Group 6: getBonusTargetEscrowExpiryBounds
    // =====================================================================

    function test_getBonusTargetEscrowExpiryBounds_returnsCorrectValues() public {
        uint256 budget = _minBudget();
        uint256 ttl = 14 days;

        uint256 startTime = block.timestamp;
        vm.prank(alice);
        uint256 offerId = market.createBonusTargetEscrowWithTarget(1, budget, 30 days, true, ttl, 0, 0);

        (uint256 createdAt, uint256 expiresAt, uint256 maxExpiresAt) = market.getBonusTargetEscrowExpiryBounds(offerId);
        assertEq(createdAt, startTime);
        assertEq(expiresAt, startTime + ttl);
        assertEq(maxExpiresAt, startTime + Constants.MAX_BONUS_TARGET_ESCROW_TTL_SECONDS);
    }

    // =====================================================================
    // Group 7: cleanupStaleListing
    // =====================================================================

    function test_cleanupStaleListing_clearsZombie() public {
        uint256 tokenId = _createLockFor(alice, Constants.MIN_LOCK_AMOUNT, Constants.MAX_LOCK_DURATION, false);
        _rollNext();
        _listLock(alice, tokenId);

        // Verify listing is active.
        (,,,, bool active) = market.listings(tokenId);
        assertTrue(active);
        (,,, bool listed) = ve.getLockInfo(tokenId);
        assertTrue(listed);

        // Simulate stale state: ve flag cleared externally (e.g., by new router after rewire).
        // We can do this via the harness by setting ve.mineMarket to a new address, clearing the flag,
        // then rewiring back. Since we can't easily do that, use the harness to directly set listed = false.
        // The VeClaimNFTHarness should support this.
        _rollNext();
        ve.setListedForTest(tokenId, false);

        // Now local listing is active but ve flag is false — zombie state.
        (,,, bool listedAfter) = ve.getLockInfo(tokenId);
        assertFalse(listedAfter);

        // Anyone can cleanup the stale listing.
        _rollNext();
        vm.prank(randomUser);
        market.cleanupStaleListing(tokenId);

        // Local listing should be cleared.
        (,,,, bool activeAfter) = market.listings(tokenId);
        assertFalse(activeAfter);
        assertEq(market.getUserListings(alice).length, 0);
    }

    function test_cleanupStaleListing_revertsIfStillListed() public {
        uint256 tokenId = _createLockFor(alice, Constants.MIN_LOCK_AMOUNT, Constants.MAX_LOCK_DURATION, false);
        _rollNext();
        _listLock(alice, tokenId);

        // Both local listing and ve flag are active — not a zombie.
        _rollNext();
        vm.expectRevert(Errors.LockListedOrFrozen.selector);
        market.cleanupStaleListing(tokenId);
    }

    function test_cleanupStaleListing_revertsIfNotActive() public {
        uint256 tokenId = _createLockFor(alice, Constants.MIN_LOCK_AMOUNT, Constants.MAX_LOCK_DURATION, false);

        // Never listed — local listing is inactive.
        vm.expectRevert(Errors.ListingNotActive.selector);
        market.cleanupStaleListing(tokenId);
    }

    // =====================================================================
    // Group 8: Guardian Rotation
    // =====================================================================

    function test_setGuardian_byOwner_succeeds() public {
        address newGuardian = makeAddr("newGuardian");
        market.setGuardian(newGuardian);
        assertEq(market.guardian(), newGuardian);
    }

    function test_setGuardian_byGuardian_succeeds() public {
        address newGuardian = makeAddr("newGuardian");
        vm.prank(guardian);
        market.setGuardian(newGuardian);
        assertEq(market.guardian(), newGuardian);
    }

    function test_setGuardian_byRandom_reverts() public {
        vm.prank(randomUser);
        vm.expectRevert(Errors.NotAuthorized.selector);
        market.setGuardian(makeAddr("x"));
    }

    function test_setGuardian_toZero_reverts() public {
        vm.expectRevert(Errors.ZeroAddress.selector);
        market.setGuardian(address(0));
    }

    function test_setGuardian_toSelf_reverts() public {
        vm.expectRevert(Errors.NotAuthorized.selector);
        market.setGuardian(address(market));
    }

    function test_setGuardian_emitsEvent() public {
        address newGuardian = makeAddr("newGuardian");
        vm.expectEmit(true, true, false, false);
        emit Events.GuardianChanged(guardian, newGuardian);
        market.setGuardian(newGuardian);
    }

    function test_pauseTrading_onlyGuardian_reverts() public {
        vm.prank(randomUser);
        vm.expectRevert(Errors.OnlyGuardian.selector);
        market.pauseTrading(true);
    }

    function test_pauseTrading_idempotent() public {
        vm.prank(guardian);
        market.pauseTrading(true);
        assertTrue(market.tradingPaused());

        // Pausing again with same value is a no-op (returns silently).
        vm.prank(guardian);
        market.pauseTrading(true);
        assertTrue(market.tradingPaused());
    }

    function test_pauseTrading_unpause() public {
        vm.prank(guardian);
        market.pauseTrading(true);
        assertTrue(market.tradingPaused());

        vm.prank(guardian);
        market.pauseTrading(false);
        assertFalse(market.tradingPaused());
    }

    // =====================================================================
    // Group 9: Offer Creation Boundary Cases
    // =====================================================================

    function test_createOffer_exactMinBudget_succeeds() public {
        uint256 budget = _minBudget();
        uint256 offerId = _createOffer(alice, budget);
        assertTrue(market.getBonusTargetEscrow(offerId).active);
    }

    function test_createOffer_belowMinBudget_reverts() public {
        uint256 budget = _minBudget() - 1;
        vm.prank(alice);
        vm.expectRevert(Errors.BudgetTooSmall.selector);
        market.createBonusTargetEscrowWithTarget(1, budget, 30 days, true, 0, 0, 0);
    }

    function test_createOffer_targetBonusBpsZero_reverts() public {
        uint256 budget = _minBudget();
        vm.prank(alice);
        vm.expectRevert(Errors.AmountZero.selector);
        market.createBonusTargetEscrowWithTarget(0, budget, 30 days, true, 0, 0, 0);
    }

    function test_createOffer_slippageBps10000_reverts() public {
        uint256 budget = _minBudget();
        vm.prank(alice);
        vm.expectRevert(Errors.SlippageTooHigh.selector);
        market.createBonusTargetEscrowWithTarget(1, budget, 30 days, true, 0, 0, 10_000);
    }

    function test_createOffer_ttlTooShort_reverts() public {
        uint256 budget = _minBudget();
        vm.prank(alice);
        vm.expectRevert(Errors.InvalidOfferTtl.selector);
        market.createBonusTargetEscrowWithTarget(
            1, budget, 30 days, true, Constants.MIN_BONUS_TARGET_ESCROW_TTL_SECONDS - 1, 0, 0
        );
    }

    function test_createOffer_ttlTooLong_reverts() public {
        uint256 budget = _minBudget();
        vm.prank(alice);
        vm.expectRevert(Errors.InvalidOfferTtl.selector);
        market.createBonusTargetEscrowWithTarget(
            1, budget, 30 days, true, Constants.MAX_BONUS_TARGET_ESCROW_TTL_SECONDS + 1, 0, 0
        );
    }

    function test_createOffer_durationTooShort_reverts() public {
        uint256 budget = _minBudget();
        vm.prank(alice);
        vm.expectRevert(Errors.InvalidDuration.selector);
        market.createBonusTargetEscrowWithTarget(1, budget, Constants.MIN_LOCK_DURATION - 1, false, 0, 0, 0);
    }

    function test_createOffer_durationTooLong_reverts() public {
        uint256 budget = _minBudget();
        vm.prank(alice);
        vm.expectRevert(Errors.InvalidDuration.selector);
        market.createBonusTargetEscrowWithTarget(1, budget, Constants.MAX_LOCK_DURATION + 1, false, 0, 0, 0);
    }

    // =====================================================================
    // Group 10: Cooldown Enforcement
    // =====================================================================

    function test_listing_cannotRelist_sameBlock() public {
        uint256 tokenId = _createLockFor(alice, Constants.MIN_LOCK_AMOUNT, Constants.MAX_LOCK_DURATION, false);
        _rollNext();
        _listLock(alice, tokenId);

        // Delist in same block would fail due to cooldown.
        vm.prank(alice);
        vm.expectRevert(Errors.ListingCooldown.selector);
        market.delistLock(tokenId);
    }

    function test_listing_canDelist_nextBlock() public {
        uint256 tokenId = _createLockFor(alice, Constants.MIN_LOCK_AMOUNT, Constants.MAX_LOCK_DURATION, false);
        _rollNext();
        _listLock(alice, tokenId);

        _rollNext();
        vm.prank(alice);
        market.delistLock(tokenId);

        (,,,, bool active) = market.listings(tokenId);
        assertFalse(active);
    }

    function test_emergencyDelist_tooSoon_reverts() public {
        uint256 tokenId = _createLockFor(alice, Constants.MIN_LOCK_AMOUNT, Constants.MAX_LOCK_DURATION, false);
        _rollNext();
        _listLock(alice, tokenId);
        _rollNext();

        // Emergency delist requires EMERGENCY_DELIST_MIN_AGE (7 days).
        vm.prank(alice);
        vm.expectRevert(Errors.EmergencyDelistTooSoon.selector);
        market.emergencyDelist(tokenId);
    }

    function test_emergencyDelist_afterMinAge_succeeds() public {
        uint256 tokenId = _createLockFor(alice, Constants.MIN_LOCK_AMOUNT, Constants.MAX_LOCK_DURATION, false);
        _rollNext();
        _listLock(alice, tokenId);
        _rollNext();

        // Warp past EMERGENCY_DELIST_MIN_AGE.
        vm.warp(block.timestamp + Constants.EMERGENCY_DELIST_MIN_AGE);
        _rollNext();

        vm.prank(alice);
        market.emergencyDelist(tokenId);

        (,,,, bool active) = market.listings(tokenId);
        assertFalse(active);
    }

    // =====================================================================
    // Group 11: Offer Extension Edge Cases
    // =====================================================================

    function test_offer_cannotExtend_afterExpiry() public {
        uint256 budget = _minBudget();
        vm.prank(alice);
        uint256 offerId = market.createBonusTargetEscrowWithTarget(
            1, budget, 30 days, true, Constants.MIN_BONUS_TARGET_ESCROW_TTL_SECONDS, 0, 0
        );

        // Warp past expiry.
        vm.warp(block.timestamp + Constants.MIN_BONUS_TARGET_ESCROW_TTL_SECONDS);

        vm.prank(alice);
        vm.expectRevert(Errors.OfferExpired.selector);
        market.extendBonusTargetEscrowExpiry(offerId, block.timestamp + 1 days);
    }

    function test_offer_cannotExtend_pastMaxTTL() public {
        uint256 budget = _minBudget();
        vm.prank(alice);
        uint256 offerId = market.createBonusTargetEscrowWithTarget(1, budget, 30 days, true, 30 days, 0, 0);

        uint256 createdAt = market.getBonusTargetEscrow(offerId).createdAt;
        uint256 maxExpiry = createdAt + Constants.MAX_BONUS_TARGET_ESCROW_TTL_SECONDS;

        vm.prank(alice);
        vm.expectRevert(Errors.InvalidOfferExpiry.selector);
        market.extendBonusTargetEscrowExpiry(offerId, maxExpiry + 1);
    }

    function test_offer_cannotExtend_toSameOrEarlier() public {
        uint256 budget = _minBudget();
        vm.prank(alice);
        uint256 offerId = market.createBonusTargetEscrowWithTarget(1, budget, 30 days, true, 30 days, 0, 0);

        uint256 currentExpiry = market.getBonusTargetEscrow(offerId).expiresAt;

        vm.prank(alice);
        vm.expectRevert(Errors.InvalidOfferExpiry.selector);
        market.extendBonusTargetEscrowExpiry(offerId, currentExpiry);
    }

    function test_offer_extend_happyPath() public {
        uint256 budget = _minBudget();
        vm.prank(alice);
        uint256 offerId = market.createBonusTargetEscrowWithTarget(1, budget, 30 days, true, 30 days, 0, 0);

        uint256 newExpiry = market.getBonusTargetEscrow(offerId).expiresAt + 1 days;

        vm.prank(alice);
        market.extendBonusTargetEscrowExpiry(offerId, newExpiry);
        assertEq(market.getBonusTargetEscrow(offerId).expiresAt, newExpiry);
    }

    function test_offer_extend_onlyBuyer() public {
        uint256 budget = _minBudget();
        uint256 offerId = _createOffer(alice, budget);

        uint256 newExpiry = market.getBonusTargetEscrow(offerId).expiresAt + 1 days;

        vm.prank(randomUser);
        vm.expectRevert(Errors.NotAuthorized.selector);
        market.extendBonusTargetEscrowExpiry(offerId, newExpiry);
    }

    // =====================================================================
    // Group 12: CLAIM Escrow Invariant — Multi-User Stress
    // =====================================================================

    function test_escrowInvariant_multiUser() public {
        uint256 budget = _minBudget();

        // Alice creates 2 offers, Bob creates 1.
        uint256 o1 = _createOffer(alice, budget);
        uint256 o2 = _createOffer(alice, budget * 2);
        uint256 o3 = _createOffer(bob, budget * 3);

        // Invariant check.
        uint256 expectedEscrow = budget + budget * 2 + budget * 3;
        assertEq(claim.balanceOf(address(market)), expectedEscrow);
        assertEq(market.totalEscrowedClaim(), expectedEscrow);

        // Cancel Alice's first offer.
        vm.prank(alice);
        market.cancelBonusTargetEscrow(o1);
        expectedEscrow -= budget;
        assertEq(claim.balanceOf(address(market)), expectedEscrow);
        assertEq(market.totalEscrowedClaim(), expectedEscrow);

        // Execute Bob's offer via keeper.
        _rollNext();
        vm.prank(keeper);
        market.executeAutoFurnace(o3, block.timestamp + 300);
        expectedEscrow -= budget * 3;
        assertEq(claim.balanceOf(address(market)), expectedEscrow);
        assertEq(market.totalEscrowedClaim(), expectedEscrow);

        // Expire Alice's second offer.
        MarketRouter.BonusTargetEscrow memory offer2 = market.getBonusTargetEscrow(o2);
        vm.warp(offer2.expiresAt);
        market.cancelExpiredBonusTargetEscrow(o2);
        assertEq(claim.balanceOf(address(market)), 0);
        assertEq(market.totalEscrowedClaim(), 0);
    }

    // =====================================================================
    // Group 13: Double-Execution Prevention
    // =====================================================================

    function test_doubleExecution_reverts() public {
        uint256 budget = _minBudget();
        uint256 offerId = _createOffer(alice, budget);

        _rollNext();
        vm.prank(keeper);
        market.executeAutoFurnace(offerId, block.timestamp + 300);

        // Second execution should revert.
        vm.prank(keeper);
        vm.expectRevert(Errors.OfferNotActive.selector);
        market.executeAutoFurnace(offerId, block.timestamp + 300);
    }

    function test_doubleCancel_reverts() public {
        uint256 budget = _minBudget();
        uint256 offerId = _createOffer(alice, budget);

        vm.prank(alice);
        market.cancelBonusTargetEscrow(offerId);

        vm.prank(alice);
        vm.expectRevert(Errors.OfferNotActive.selector);
        market.cancelBonusTargetEscrow(offerId);
    }

    // =====================================================================
    // Group 14: Listing Expiry Boundary
    // =====================================================================

    function test_listing_cannotSettle_afterExpiry() public {
        uint256 tokenId = _createLockFor(alice, Constants.MIN_LOCK_AMOUNT, Constants.MAX_LOCK_DURATION, false);
        _rollNext();
        _listLock(alice, tokenId);
        _rollNext();

        // Warp past listing expiry.
        (,,, uint256 expiresAt,) = market.listings(tokenId);
        vm.warp(expiresAt);

        vm.prank(keeper);
        vm.expectRevert(Errors.ListingExpired.selector);
        market.sellListedLockToFurnace(tokenId, block.timestamp + 300);
    }

    // =====================================================================
    // Group 15: recoverToken Does Not Affect CLAIM Escrow
    // =====================================================================

    function test_recoverToken_cannotDrainEscrow() public {
        // Create an offer to put CLAIM in escrow.
        uint256 budget = _minBudget();
        _createOffer(alice, budget);
        assertEq(claim.balanceOf(address(market)), budget);

        // recoverToken must block CLAIM extraction.
        vm.expectRevert(Errors.NotAuthorized.selector);
        market.recoverToken(address(claim), owner, budget);

        // Escrow is untouched.
        assertEq(claim.balanceOf(address(market)), budget);
    }
}
