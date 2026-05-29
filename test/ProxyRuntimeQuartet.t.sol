// SPDX-License-Identifier: MIT
pragma solidity ^0.8.34;

import {Test} from "forge-std/Test.sol";

import {ProxyAdmin} from "lib/openzeppelin-contracts/contracts/proxy/transparent/ProxyAdmin.sol";
import {
    ITransparentUpgradeableProxy,
    TransparentUpgradeableProxy
} from "lib/openzeppelin-contracts/contracts/proxy/transparent/TransparentUpgradeableProxy.sol";

import {ClaimAllHelper} from "src/ClaimAllHelper.sol";
import {ClaimToken} from "src/ClaimToken.sol";
import {Constants} from "src/lib/Constants.sol";
import {DelegationHub} from "src/DelegationHub.sol";
import {FurnaceQuoter} from "src/FurnaceQuoter.sol";
import {IMarketRouter} from "src/interfaces/IMarketRouter.sol";
import {MarketRouter} from "src/MarketRouter.sol";
import {MockEntryTokenRegistry} from "test/mocks/MockEntryTokenRegistry.sol";
import {FurnaceHarness} from "test/mocks/FurnaceHarness.sol";
import {MineCoreHarness} from "test/mocks/MineCoreHarness.sol";
import {ShareholderRoyaltiesHarness} from "test/mocks/ShareholderRoyaltiesHarness.sol";
import {VeClaimNFTHarness} from "test/mocks/VeClaimNFTHarness.sol";

interface IVersionedRuntime {
    function version() external view returns (uint256);
}

contract MineCoreProxyV2 is MineCoreHarness {
    constructor(address claim_, address ve_, address royalties_) MineCoreHarness(claim_, ve_, royalties_, address(0)) {}

    function version() external pure returns (uint256) {
        return 2;
    }
}

contract FurnaceProxyV2 is FurnaceHarness {
    constructor(address claim_, address ve_) FurnaceHarness(claim_, ve_, address(0)) {}

    function version() external pure returns (uint256) {
        return 2;
    }
}

contract MarketRouterProxyV2 is MarketRouter {
    constructor(address claim_, address ve_, address royalties_) MarketRouter(claim_, ve_, royalties_, address(0)) {}

    function version() external pure returns (uint256) {
        return 2;
    }
}

contract ShareholderRoyaltiesProxyV2 is ShareholderRoyaltiesHarness {
    constructor(address ve_) ShareholderRoyaltiesHarness(ve_, address(0)) {}

    function version() external pure returns (uint256) {
        return 2;
    }
}

contract ProxyRuntimeQuartetTest is Test {
    bytes32 internal constant _IMPLEMENTATION_SLOT = 0x360894a13ba1a3210667c828492db98dca3e2076cc3735a920a3ca505d382bbc;
    bytes32 internal constant _ADMIN_SLOT = 0xb53127684a568b3173ae13b9f8a6016e243e63b6e8ee1178d6a717850b5d6103;

    address internal owner = makeAddr("owner");
    address internal alice = makeAddr("alice");
    address internal bob = makeAddr("bob");
    address internal keeper = makeAddr("keeper");

    ClaimToken internal claim;
    VeClaimNFTHarness internal ve;
    MineCoreHarness internal mineCore;
    FurnaceHarness internal furnace;
    MarketRouter internal market;
    ShareholderRoyaltiesHarness internal royalties;

    ProxyAdmin internal mineCoreAdmin;
    ProxyAdmin internal furnaceAdmin;
    ProxyAdmin internal marketAdmin;
    ProxyAdmin internal royaltiesAdmin;

    DelegationHub internal hub;
    ClaimAllHelper internal claimAllHelper;
    FurnaceQuoter internal furnaceQuoter;
    MockEntryTokenRegistry internal furnaceRegistry;
    MockEntryTokenRegistry internal mineCoreRegistry;

    uint256 internal listedTokenId;
    uint256 internal offerId;

    function setUp() public {
        claim = new ClaimToken(owner);
        ve = new VeClaimNFTHarness(address(claim), owner);

        (address royaltiesProxy, ProxyAdmin royaltiesProxyAdmin) = _deployRoyaltiesProxy();
        royalties = ShareholderRoyaltiesHarness(royaltiesProxy);
        royaltiesAdmin = royaltiesProxyAdmin;

        (address marketProxy, ProxyAdmin marketProxyAdmin) = _deployMarketProxy(royaltiesProxy);
        market = MarketRouter(marketProxy);
        marketAdmin = marketProxyAdmin;

        (address furnaceProxy, ProxyAdmin furnaceProxyAdmin) = _deployFurnaceProxy();
        furnace = FurnaceHarness(payable(furnaceProxy));
        furnaceAdmin = furnaceProxyAdmin;

        (address mineCoreProxy, ProxyAdmin mineCoreProxyAdmin) = _deployMineCoreProxy(royaltiesProxy);
        mineCore = MineCoreHarness(payable(mineCoreProxy));
        mineCoreAdmin = mineCoreProxyAdmin;

        _wireRuntimeQuartet();
        _seedRuntimeState();
    }

    function testTransparentProxyRuntimeQuartetPreservesStateAcrossUpgrades() public {
        address oldMineCoreImpl = _implementationOf(address(mineCore));
        address oldFurnaceImpl = _implementationOf(address(furnace));
        address oldMarketImpl = _implementationOf(address(market));
        address oldRoyaltiesImpl = _implementationOf(address(royalties));

        IMarketRouter.Listing memory listingBefore = market.getListing(listedTokenId);
        IMarketRouter.BonusTargetEscrow memory offerBefore = market.getBonusTargetEscrow(offerId);
        (uint256 claimableBefore, uint256 userVeBefore, uint256 paidBefore) = royalties.getShareholderState(alice);
        uint256 checkpointLenBefore = royalties.rewardCheckpointsLength();
        (uint40 checkpointTsBefore, uint256 checkpointCumBefore, uint256 checkpointTwBefore) =
            royalties.getRewardCheckpoint(checkpointLenBefore - 1);

        assertGt(claimableBefore, 0, "seeded shareholder claimable should be non-zero");
        assertGt(checkpointLenBefore, 0, "seeded royalties checkpoints should exist");

        address newMineCoreImpl = address(new MineCoreProxyV2(address(claim), address(ve), address(royalties)));
        address newFurnaceImpl = address(new FurnaceProxyV2(address(claim), address(ve)));
        address newMarketImpl = address(new MarketRouterProxyV2(address(claim), address(ve), address(royalties)));
        address newRoyaltiesImpl = address(new ShareholderRoyaltiesProxyV2(address(ve)));

        vm.startPrank(owner);
        mineCoreAdmin.upgradeAndCall(ITransparentUpgradeableProxy(payable(address(mineCore))), newMineCoreImpl, "");
        furnaceAdmin.upgradeAndCall(ITransparentUpgradeableProxy(payable(address(furnace))), newFurnaceImpl, "");
        marketAdmin.upgradeAndCall(ITransparentUpgradeableProxy(payable(address(market))), newMarketImpl, "");
        royaltiesAdmin.upgradeAndCall(ITransparentUpgradeableProxy(payable(address(royalties))), newRoyaltiesImpl, "");
        vm.stopPrank();

        assertEq(_implementationOf(address(mineCore)), newMineCoreImpl, "MineCore impl should change");
        assertEq(_implementationOf(address(furnace)), newFurnaceImpl, "Furnace impl should change");
        assertEq(_implementationOf(address(market)), newMarketImpl, "MarketRouter impl should change");
        assertEq(_implementationOf(address(royalties)), newRoyaltiesImpl, "Royalties impl should change");

        assertEq(oldMineCoreImpl == newMineCoreImpl, false, "MineCore impl must rotate");
        assertEq(oldFurnaceImpl == newFurnaceImpl, false, "Furnace impl must rotate");
        assertEq(oldMarketImpl == newMarketImpl, false, "MarketRouter impl must rotate");
        assertEq(oldRoyaltiesImpl == newRoyaltiesImpl, false, "Royalties impl must rotate");

        assertEq(IVersionedRuntime(address(mineCore)).version(), 2, "MineCore proxy should run v2 code");
        assertEq(IVersionedRuntime(address(furnace)).version(), 2, "Furnace proxy should run v2 code");
        assertEq(IVersionedRuntime(address(market)).version(), 2, "MarketRouter proxy should run v2 code");
        assertEq(IVersionedRuntime(address(royalties)).version(), 2, "Royalties proxy should run v2 code");

        assertEq(claim.mineCore(), address(mineCore), "ClaimToken should still point at MineCore proxy");
        assertEq(ve.furnace(), address(furnace), "VeClaimNFT should still point at Furnace proxy");
        assertEq(ve.mineMarket(), address(market), "VeClaimNFT should still point at MarketRouter proxy");

        assertEq(mineCore.currentKing(), alice, "MineCore currentKing should survive");
        assertEq(mineCore.currentReignStartTime(), 10 days, "MineCore currentReignStartTime should survive");
        assertEq(mineCore.referencePrice(), 2 ether, "MineCore referencePrice should survive");
        assertEq(mineCore.currentReignLastAccrualTime(), 9 days, "MineCore accrual cursor should survive");
        assertEq(mineCore.kingEthBalance(alice), 1 ether, "MineCore king bucket should survive");
        assertEq(mineCore.refundEthBalance(bob), 0.25 ether, "MineCore refund bucket should survive");
        assertEq(mineCore.pendingKingClaim(alice), 123e18, "MineCore pending CLAIM should survive");
        assertTrue(mineCore.genesisKingClaimCollected(), "MineCore genesis flag should survive");
        assertEq(mineCore.claimAllHelper(), address(claimAllHelper), "MineCore helper wiring should survive");
        assertEq(mineCore.entryTokenRegistry(), address(mineCoreRegistry), "MineCore registry should survive");
        assertEq(mineCore.delegationHub(), address(hub), "MineCore hub should survive");

        assertEq(furnace.furnaceReserve(), 500e18, "Furnace reserve should survive");
        assertEq(furnace.mineCore(), address(mineCore), "Furnace mineCore pointer should survive");
        assertEq(furnace.mineMarket(), address(market), "Furnace mineMarket pointer should survive");
        assertEq(furnace.shareholderRoyalties(), address(royalties), "Furnace royalties pointer should survive");
        assertEq(furnace.furnaceQuoter(), address(furnaceQuoter), "Furnace quoter should survive");
        assertEq(furnace.entryTokenRegistry(), address(furnaceRegistry), "Furnace registry should survive");
        assertEq(furnace.delegationHub(), address(hub), "Furnace hub should survive");
        assertEq(furnace.guardian(), address(mineCore), "Furnace guardian should survive");
        assertTrue(furnace.lockingPaused(), "Furnace pause flag should survive");

        IMarketRouter.Listing memory listingAfter = market.getListing(listedTokenId);
        assertEq(listingAfter.seller, listingBefore.seller, "listing seller should survive");
        assertEq(listingAfter.minClaimOut, listingBefore.minClaimOut, "listing floor should survive");
        assertEq(listingAfter.listedAtTime, listingBefore.listedAtTime, "listing timestamp should survive");
        assertEq(listingAfter.expiresAtTime, listingBefore.expiresAtTime, "listing expiry should survive");
        assertEq(listingAfter.active, listingBefore.active, "listing active flag should survive");

        uint256[] memory userListings = market.getUserListings(alice);
        assertEq(userListings.length, 1, "user listing index should survive");
        assertEq(userListings[0], listedTokenId, "listed token id should survive");

        IMarketRouter.BonusTargetEscrow memory offerAfter = market.getBonusTargetEscrow(offerId);
        assertEq(offerAfter.buyer, offerBefore.buyer, "offer buyer should survive");
        assertEq(offerAfter.discountBps, offerBefore.discountBps, "offer discount should survive");
        assertEq(offerAfter.durationSeconds, offerBefore.durationSeconds, "offer duration should survive");
        assertEq(offerAfter.destinationLockId, offerBefore.destinationLockId, "offer destination should survive");
        assertEq(offerAfter.fundsRemaining, offerBefore.fundsRemaining, "offer balance should survive");
        assertEq(offerAfter.createdAt, offerBefore.createdAt, "offer creation timestamp should survive");
        assertEq(offerAfter.expiresAt, offerBefore.expiresAt, "offer expiry should survive");
        assertEq(offerAfter.active, offerBefore.active, "offer active flag should survive");
        assertEq(market.nextOfferId(), 2, "nextOfferId should survive");
        assertTrue(market.isSettlementKeeper(keeper), "settlement keeper allowlist should survive");

        uint256[] memory userOffers = market.getUserBonusTargetEscrows(bob);
        assertEq(userOffers.length, 1, "user offer index should survive");
        assertEq(userOffers[0], offerId, "offer id should survive");

        (uint256 claimableAfter, uint256 userVeAfter, uint256 paidAfter) = royalties.getShareholderState(alice);
        assertEq(claimableAfter, claimableBefore, "royalties claimable should survive");
        assertEq(userVeAfter, userVeBefore, "royalties user ve should survive");
        assertEq(paidAfter, paidBefore, "royalties paid index should survive");
        assertEq(royalties.rewardCheckpointsLength(), checkpointLenBefore, "checkpoint length should survive");
        (uint40 checkpointTsAfter, uint256 checkpointCumAfter, uint256 checkpointTwAfter) =
            royalties.getRewardCheckpoint(checkpointLenBefore - 1);
        assertEq(checkpointTsAfter, checkpointTsBefore, "checkpoint timestamp should survive");
        assertEq(checkpointCumAfter, checkpointCumBefore, "checkpoint accumulator should survive");
        assertEq(checkpointTwAfter, checkpointTwBefore, "checkpoint TW accumulator should survive");
        assertEq(royalties.claimAllHelper(), address(claimAllHelper), "royalties helper should survive");
        assertEq(royalties.mineCore(), address(mineCore), "royalties mineCore should survive");
        assertEq(royalties.mineMarket(), address(market), "royalties market should survive");
        assertEq(address(royalties.furnace()), address(furnace), "royalties furnace should survive");
    }

    function _deployRoyaltiesProxy() internal returns (address proxy, ProxyAdmin admin) {
        ShareholderRoyaltiesHarness impl = new ShareholderRoyaltiesHarness(address(ve), address(0));
        return _deployProxy(address(impl), abi.encodeWithSignature("initialize(address)", owner));
    }

    function _deployMarketProxy(address royaltiesProxy) internal returns (address proxy, ProxyAdmin admin) {
        MarketRouter impl = new MarketRouter(address(claim), address(ve), royaltiesProxy, address(0));
        return _deployProxy(address(impl), abi.encodeWithSignature("initialize(address)", owner));
    }

    function _deployFurnaceProxy() internal returns (address proxy, ProxyAdmin admin) {
        FurnaceHarness impl = new FurnaceHarness(address(claim), address(ve), address(0));
        return _deployProxy(address(impl), abi.encodeWithSignature("initialize(address)", owner));
    }

    function _deployMineCoreProxy(address royaltiesProxy) internal returns (address proxy, ProxyAdmin admin) {
        MineCoreHarness impl = new MineCoreHarness(address(claim), address(ve), royaltiesProxy, address(0));
        return _deployProxy(address(impl), abi.encodeWithSignature("initialize(address)", owner));
    }

    function _deployProxy(address implementation, bytes memory initData)
        internal
        returns (address proxy, ProxyAdmin admin)
    {
        proxy = address(new TransparentUpgradeableProxy(implementation, owner, initData));
        admin = ProxyAdmin(_readAddressSlot(proxy, _ADMIN_SLOT));
        assertEq(admin.owner(), owner, "proxy admin owner should be the protocol owner");
    }

    function _wireRuntimeQuartet() internal {
        hub = new DelegationHub();
        claimAllHelper = new ClaimAllHelper(address(royalties), address(mineCore));
        furnaceQuoter = new FurnaceQuoter(address(furnace));
        furnaceRegistry = new MockEntryTokenRegistry();
        mineCoreRegistry = new MockEntryTokenRegistry();

        vm.startPrank(owner);
        claim.setMineCore(address(mineCore));

        furnace.setMineCore(address(mineCore));
        furnace.setMineMarket(address(market));
        furnace.setShareholderRoyalties(address(royalties));
        furnace.setFurnaceQuoter(address(furnaceQuoter));

        // The canonical-hub check requires `mineCore.furnace()` and
        // `mineCore.delegationHub()` to be set before the furnace-side hub
        // pointer is bound; wire MineCore-side first.
        mineCore.setFurnace(address(furnace));
        mineCore.setDelegationHub(address(hub));

        furnace.setDelegationHub(address(hub));
        furnace.setEntryTokenRegistry(address(furnaceRegistry));

        mineCore.setEntryTokenRegistry(address(mineCoreRegistry));
        mineCore.setClaimAllHelper(address(claimAllHelper));

        royalties.setWiring(address(mineCore), address(market), address(furnace));
        royalties.setClaimAllHelper(address(claimAllHelper));

        market.setSettlementKeeper(keeper, true);

        ve.setFurnace(address(furnace));
        ve.setMineMarket(address(market));
        vm.stopPrank();
    }

    function _seedRuntimeState() internal {
        vm.warp(10 days);

        mineCore.setReignStateForTest(alice, 10 days, 2 ether, 9 days);
        mineCore.setGenesisKingClaimCollectedForTest(true);
        mineCore.setKingEthBalanceForTest(alice, 1 ether);
        mineCore.setRefundEthBalanceForTest(bob, 0.25 ether);
        mineCore.setPendingKingClaimForTest(alice, 123e18);

        vm.prank(address(mineCore));
        claim.mint(address(furnace), 500e18);
        vm.prank(address(mineCore));
        furnace.creditReserve(500e18);
        vm.prank(address(mineCore));
        furnace.setLockingPaused(true);

        vm.startPrank(address(mineCore));
        claim.mint(alice, 50_000e18);
        claim.mint(bob, 50_000e18);
        vm.stopPrank();

        vm.startPrank(alice);
        claim.approve(address(ve), type(uint256).max);
        listedTokenId = ve.createLock(2_000e18, Constants.MIN_LOCK_DURATION, false);
        market.listLock(listedTokenId, 1_500e18, block.timestamp + 2 days);
        vm.stopPrank();

        vm.startPrank(bob);
        claim.approve(address(market), type(uint256).max);
        uint256 budget = market.minBonusTargetEscrowBudget() + 1e18;
        offerId = market.createBonusTargetEscrowWithTarget(500, budget, Constants.MIN_LOCK_DURATION, true, 2 days, 0, 0);
        vm.stopPrank();

        vm.warp(block.timestamp + 1);
        vm.deal(address(mineCore), 2 ether);
        vm.prank(address(mineCore));
        royalties.onTakeover{value: 1 ether}(1);
        royalties.checkpointUser(alice);
    }

    function _implementationOf(address proxy) internal view returns (address) {
        return _readAddressSlot(proxy, _IMPLEMENTATION_SLOT);
    }

    function _readAddressSlot(address target, bytes32 slot) internal view returns (address value) {
        value = address(uint160(uint256(vm.load(target, slot))));
    }
}
