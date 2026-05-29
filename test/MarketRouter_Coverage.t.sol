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

import {MockAerodromeRouter} from "test/mocks/MockAerodromeRouter.sol";
import {MockMineCoreWiringView} from "test/mocks/MockMineCoreWiringView.sol";
import {MockWETH} from "test/mocks/MockWETH.sol";

/// @dev Minimal contract buyer that can create and cancel offers on MarketRouter.
contract ContractBuyer {
    function approveToken(address token, address spender, uint256 amount) external {
        IERC20(token).approve(spender, amount);
    }

    function createOffer(
        MarketRouter market,
        uint256 targetBonusBps,
        uint256 budgetClaim,
        uint256 durationSeconds,
        bool createAutoMax,
        uint256 escrowTtlSeconds,
        uint256 destinationLockId,
        uint256 slippageBps
    ) external returns (uint256) {
        return market.createBonusTargetEscrowWithTarget(
            targetBonusBps,
            budgetClaim,
            durationSeconds,
            createAutoMax,
            escrowTtlSeconds,
            destinationLockId,
            slippageBps
        );
    }

    function cancelOffer(MarketRouter market, uint256 offerId) external {
        market.cancelBonusTargetEscrow(offerId);
    }
}

/// @notice Coverage tests for MarketRouter: swap-and-pop, pagination, contract buyer, escrow solvency.
contract MarketRouterCoverageTest is Test {
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

    function setUp() public {
        vm.txGasPrice(0);

        owner = address(this);
        alice = makeAddr("alice");
        keeper = makeAddr("keeper");

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

        // Alice approvals.
        ve.setApprovalForAllForTest(alice, address(market), true);
        vm.prank(alice);
        claim.approve(address(market), type(uint256).max);

        // Fund alice for offer creation.
        vm.prank(address(core));
        claim.mint(alice, 10_000_000e18);

        // Whitelist keeper.
        market.setSettlementKeeper(keeper, true);
    }

    function _createLockForAlice(uint256 amount, uint256 durationSeconds, bool createAutoMax)
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

    function _listLock(uint256 tokenId) internal {
        vm.prank(alice);
        market.listLock(tokenId, 1, block.timestamp + 30 days);
    }

    function _rollNext(uint256 currentBlock) internal returns (uint256 nextBlock) {
        nextBlock = currentBlock + 1;
        vm.roll(nextBlock);
    }

    function _createAliceOffer() internal returns (uint256 offerId) {
        return _createAliceOfferWithBudget(market.minBonusTargetEscrowBudget());
    }

    function _createAliceOfferWithBudget(uint256 budget) internal returns (uint256 offerId) {
        vm.prank(alice);
        offerId = market.createBonusTargetEscrowWithTarget(1, budget, 30 days, true, 0, 0, 0);
    }

    // =====================================================================
    // Group 1: Swap-and-Pop Array Correctness
    // =====================================================================

    function test_swapAndPop_singleListingRemoval() public {
        uint256 nextBlock = block.number;
        uint256 t1 = _createLockForAlice(Constants.MIN_LOCK_AMOUNT, Constants.MAX_LOCK_DURATION, false);
        nextBlock = _rollNext(nextBlock);
        _listLock(t1);

        assertEq(market.getUserListings(alice).length, 1);

        nextBlock = _rollNext(nextBlock);
        vm.prank(alice);
        market.delistLock(t1);

        assertEq(market.getUserListings(alice).length, 0);
    }

    function test_swapAndPop_removeMiddleListing() public {
        uint256 nextBlock = block.number;
        uint256 t1 = _createLockForAlice(Constants.MIN_LOCK_AMOUNT, Constants.MAX_LOCK_DURATION, false);
        nextBlock = _rollNext(nextBlock);
        uint256 t2 = _createLockForAlice(Constants.MIN_LOCK_AMOUNT, Constants.MAX_LOCK_DURATION, false);
        nextBlock = _rollNext(nextBlock);
        uint256 t3 = _createLockForAlice(Constants.MIN_LOCK_AMOUNT, Constants.MAX_LOCK_DURATION, false);

        nextBlock = _rollNext(nextBlock);
        _listLock(t1);
        nextBlock = _rollNext(nextBlock);
        _listLock(t2);
        nextBlock = _rollNext(nextBlock);
        _listLock(t3);

        uint256[] memory before = market.getUserListings(alice);
        assertEq(before.length, 3);
        assertEq(before[0], t1);
        assertEq(before[1], t2);
        assertEq(before[2], t3);

        // Delist the middle one (t2). Last element (t3) should swap into slot 1.
        nextBlock = _rollNext(nextBlock);
        vm.prank(alice);
        market.delistLock(t2);

        uint256[] memory after_ = market.getUserListings(alice);
        assertEq(after_.length, 2);
        assertEq(after_[0], t1);
        assertEq(after_[1], t3); // t3 swapped into t2's slot

        // Verify t2 listing is cleared.
        MarketRouter.Listing memory lst = market.getListing(t2);
        assertFalse(lst.active);
    }

    function test_swapAndPop_removeLastListing() public {
        uint256 nextBlock = block.number;
        uint256 t1 = _createLockForAlice(Constants.MIN_LOCK_AMOUNT, Constants.MAX_LOCK_DURATION, false);
        nextBlock = _rollNext(nextBlock);
        uint256 t2 = _createLockForAlice(Constants.MIN_LOCK_AMOUNT, Constants.MAX_LOCK_DURATION, false);

        nextBlock = _rollNext(nextBlock);
        _listLock(t1);
        nextBlock = _rollNext(nextBlock);
        _listLock(t2);

        // Delist the last one (t2). No swap needed, just pop.
        nextBlock = _rollNext(nextBlock);
        vm.prank(alice);
        market.delistLock(t2);

        uint256[] memory after_ = market.getUserListings(alice);
        assertEq(after_.length, 1);
        assertEq(after_[0], t1);
    }

    function test_swapAndPop_offerRemovalFromMiddle() public {
        uint256 o1 = _createAliceOffer();
        uint256 o2 = _createAliceOffer();
        uint256 o3 = _createAliceOffer();

        uint256[] memory before = market.getUserBonusTargetEscrows(alice);
        assertEq(before.length, 3);
        assertEq(before[0], o1);
        assertEq(before[1], o2);
        assertEq(before[2], o3);

        // Cancel the middle one (o2). Last element (o3) should swap into slot 1.
        vm.prank(alice);
        market.cancelBonusTargetEscrow(o2);

        uint256[] memory after_ = market.getUserBonusTargetEscrows(alice);
        assertEq(after_.length, 2);
        assertEq(after_[0], o1);
        assertEq(after_[1], o3); // o3 swapped into o2's slot

        // Verify o2 is inactive.
        MarketRouter.BonusTargetEscrow memory offer = market.getBonusTargetEscrow(o2);
        assertFalse(offer.active);
        assertEq(offer.fundsRemaining, 0);
    }

    // =====================================================================
    // Group 2: Pagination Boundary Tests
    // =====================================================================

    function test_pagination_emptyArray() public view {
        (uint256[] memory ids, bool hasMore) = market.getUserListingsPaginated(alice, 0, 10);
        assertEq(ids.length, 0);
        assertFalse(hasMore);
    }

    function test_pagination_fullPage() public {
        uint256 nextBlock = block.number;
        uint256 t1 = _createLockForAlice(Constants.MIN_LOCK_AMOUNT, Constants.MAX_LOCK_DURATION, false);
        nextBlock = _rollNext(nextBlock);
        uint256 t2 = _createLockForAlice(Constants.MIN_LOCK_AMOUNT, Constants.MAX_LOCK_DURATION, false);
        nextBlock = _rollNext(nextBlock);
        uint256 t3 = _createLockForAlice(Constants.MIN_LOCK_AMOUNT, Constants.MAX_LOCK_DURATION, false);

        nextBlock = _rollNext(nextBlock);
        _listLock(t1);
        nextBlock = _rollNext(nextBlock);
        _listLock(t2);
        nextBlock = _rollNext(nextBlock);
        _listLock(t3);

        (uint256[] memory ids, bool hasMore) = market.getUserListingsPaginated(alice, 0, 10);
        assertEq(ids.length, 3);
        assertEq(ids[0], t1);
        assertEq(ids[1], t2);
        assertEq(ids[2], t3);
        assertFalse(hasMore);
    }

    function test_pagination_partialPage() public {
        uint256 o1 = _createAliceOffer();
        uint256 o2 = _createAliceOffer();
        _createAliceOffer();

        (uint256[] memory ids, bool hasMore) = market.getUserBonusTargetEscrowsPaginated(alice, 0, 2);
        assertEq(ids.length, 2);
        assertEq(ids[0], o1);
        assertEq(ids[1], o2);
        assertTrue(hasMore);
    }

    function test_pagination_offsetAtEnd() public {
        _createAliceOffer();
        _createAliceOffer();
        _createAliceOffer();

        (uint256[] memory ids, bool hasMore) = market.getUserBonusTargetEscrowsPaginated(alice, 3, 10);
        assertEq(ids.length, 0);
        assertFalse(hasMore);
    }

    function test_pagination_limitZero() public {
        _createAliceOffer();
        _createAliceOffer();
        _createAliceOffer();

        (uint256[] memory ids, bool hasMore) = market.getUserBonusTargetEscrowsPaginated(alice, 0, 0);
        assertEq(ids.length, 0);
        assertFalse(hasMore);
    }

    // =====================================================================
    // Group 3: Contract Buyer Offer Lifecycle
    // =====================================================================

    function test_contractBuyerCanCreateAndCancelOffer() public {
        ContractBuyer buyer = new ContractBuyer();

        uint256 budget = market.minBonusTargetEscrowBudget();

        // Fund the contract buyer.
        vm.prank(address(core));
        claim.mint(address(buyer), budget);

        // Approve MarketRouter to pull CLAIM.
        buyer.approveToken(address(claim), address(market), budget);

        // Create offer from contract.
        uint256 offerId = buyer.createOffer(market, 1, budget, 30 days, true, 0, 0, 0);

        // Verify escrow.
        MarketRouter.BonusTargetEscrow memory offer = market.getBonusTargetEscrow(offerId);
        assertTrue(offer.active);
        assertEq(offer.fundsRemaining, budget);
        assertEq(offer.buyer, address(buyer));
        assertEq(claim.balanceOf(address(buyer)), 0);

        // Cancel from contract — CLAIM should return to contract.
        buyer.cancelOffer(market, offerId);

        assertEq(claim.balanceOf(address(buyer)), budget);
        offer = market.getBonusTargetEscrow(offerId);
        assertFalse(offer.active);
        assertEq(offer.fundsRemaining, 0);
    }

    // =====================================================================
    // Group 4: CLAIM Escrow Solvency Across Lifecycle
    // =====================================================================

    function test_escrowSolvency_multiOfferLifecycle() public {
        uint256 budgetA = market.minBonusTargetEscrowBudget();
        uint256 budgetB = budgetA * 2;
        uint256 budgetC = budgetA * 3;

        uint256 balanceBefore = claim.balanceOf(address(market));
        assertEq(balanceBefore, 0);

        // Create 3 offers with different budgets.
        uint256 o1 = _createAliceOfferWithBudget(budgetA);
        uint256 o2 = _createAliceOfferWithBudget(budgetB);
        uint256 o3 = _createAliceOfferWithBudget(budgetC);

        // Invariant: balance == sum of all active fundsRemaining.
        assertEq(claim.balanceOf(address(market)), budgetA + budgetB + budgetC);

        // Cancel offer 2.
        vm.prank(alice);
        market.cancelBonusTargetEscrow(o2);
        assertEq(claim.balanceOf(address(market)), budgetA + budgetC);

        // Execute offer 1 (keeper settles).
        vm.roll(block.number + 1);
        vm.prank(keeper);
        market.executeAutoFurnace(o1, block.timestamp + 300);
        assertEq(claim.balanceOf(address(market)), budgetC);

        // Let offer 3 expire, then cancel.
        MarketRouter.BonusTargetEscrow memory offer3 = market.getBonusTargetEscrow(o3);
        vm.warp(offer3.expiresAt);
        market.cancelExpiredBonusTargetEscrow(o3);
        assertEq(claim.balanceOf(address(market)), 0);
    }
}
