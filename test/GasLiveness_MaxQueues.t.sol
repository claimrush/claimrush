// SPDX-License-Identifier: MIT
pragma solidity ^0.8.34;

import {Test} from "forge-std/Test.sol";

import {ClaimToken} from "src/ClaimToken.sol";
import {EntryTokenRegistry} from "src/EntryTokenRegistry.sol";
import {Furnace} from "src/Furnace.sol";
import {FurnaceGuardHelper} from "src/FurnaceGuardHelper.sol";
import {FurnaceQuoter} from "src/FurnaceQuoter.sol";
import {MarketRouter} from "src/MarketRouter.sol";
import {ShareholderRoyalties} from "src/ShareholderRoyalties.sol";
import {Constants} from "src/lib/Constants.sol";
import {LpStakingVault7D} from "src/vault/LpStakingVault7D.sol";

import {MockAerodromePool} from "./mocks/MockAerodromePool.sol";
import {MockAerodromeRouter} from "./mocks/MockAerodromeRouter.sol";
import {MockERC20} from "./mocks/MockERC20.sol";
import {MockFurnaceLpRewards} from "./mocks/MockFurnaceLpRewards.sol";
import {MockMineCoreWiringView} from "./mocks/MockMineCoreWiringView.sol";
import {MockVe} from "./mocks/MockVe.sol";
import {MockWETH} from "./mocks/MockWETH.sol";
import {VeClaimNFTHarness} from "./mocks/VeClaimNFTHarness.sol";

/// @notice Max-size liveness checks for user/keeper cleanup loops.
contract GasLivenessMaxQueuesTest is Test {
    address internal constant FACTORY = address(0xFACADE);

    address internal alice = makeAddr("alice");
    address internal keeper = makeAddr("keeper");

    ClaimToken internal claim;
    MockWETH internal weth;
    MockAerodromeRouter internal router;
    EntryTokenRegistry internal registry;
    VeClaimNFTHarness internal ve;
    ShareholderRoyalties internal royalties;
    Furnace internal furnace;
    FurnaceQuoter internal furnaceQuoter;
    MarketRouter internal market;
    MockMineCoreWiringView internal core;

    function test_cancelExpiredListingBatchHandlesMaxUserLockSetWithinBlockGas() public {
        _deployMarketSurface();
        uint256 count = Constants.MAX_VE_NFTS_PER_USER;
        uint256[] memory tokenIds = new uint256[](count);

        for (uint256 i = 0; i < count; ++i) {
            tokenIds[i] = _createAliceLock(Constants.MIN_LOCK_AMOUNT, Constants.MAX_LOCK_DURATION, false);
            vm.prank(alice);
            market.listLock(tokenIds[i], 1, block.timestamp + 1 days);
        }

        vm.warp(block.timestamp + 1 days);
        uint256 gasBefore = gasleft();
        market.cancelExpiredListingBatch(tokenIds);
        uint256 gasUsed = gasBefore - gasleft();

        assertLt(gasUsed, 25_000_000, "expired listing batch gas headroom");
        assertEq(market.getUserListings(alice).length, 0, "seller listing index cleared");
        for (uint256 i = 0; i < count; ++i) {
            (,,,, bool active) = market.listings(tokenIds[i]);
            assertFalse(active, "listing active after batch cancel");
            (,,, bool listed) = ve.getLockInfo(tokenIds[i]);
            assertFalse(listed, "ve listed flag after batch cancel");
        }
    }

    function test_cancelExpiredBonusTargetEscrowBatchHandlesMaintenanceCapWithinBlockGas() public {
        _deployMarketSurface();
        uint256 count = Constants.MAX_MAINTENANCE_OFFERS_PER_CALL;
        uint256[] memory offerIds = new uint256[](count);
        uint256 budget = market.minBonusTargetEscrowBudget();

        vm.prank(address(core));
        claim.mint(alice, budget * count);
        vm.prank(alice);
        claim.approve(address(market), type(uint256).max);

        for (uint256 i = 0; i < count; ++i) {
            vm.prank(alice);
            offerIds[i] = market.createBonusTargetEscrowWithTarget(
                1, budget, 30 days, true, Constants.MIN_BONUS_TARGET_ESCROW_TTL_SECONDS, 0, 0
            );
        }

        assertEq(claim.balanceOf(address(market)), budget * count, "escrowed offer funds");
        vm.warp(block.timestamp + Constants.MIN_BONUS_TARGET_ESCROW_TTL_SECONDS);

        uint256 gasBefore = gasleft();
        market.cancelExpiredBonusTargetEscrowBatch(offerIds);
        uint256 gasUsed = gasBefore - gasleft();

        assertLt(gasUsed, 25_000_000, "expired offer batch gas headroom");
        assertEq(claim.balanceOf(address(market)), 0, "all offer funds refunded");
        assertEq(market.getUserBonusTargetEscrows(alice).length, 0, "buyer offer index cleared");
        for (uint256 i = 0; i < count; ++i) {
            MarketRouter.BonusTargetEscrow memory offer = market.getBonusTargetEscrow(offerIds[i]);
            assertFalse(offer.active, "offer active after batch cancel");
            assertEq(offer.fundsRemaining, 0, "offer funds after batch cancel");
        }
    }

    function test_lpCompoundForManyProcessesMaxConfiguredUsersWithinBlockGas() public {
        MockERC20 localWeth = new MockERC20("WETH", "WETH");
        MockERC20 localClaim = new MockERC20("CLAIM", "CLAIM");
        MockAerodromePool lp = new MockAerodromePool(address(localWeth), address(localClaim));
        MockVe localVe = new MockVe();
        MockAerodromeRouter localRouter = new MockAerodromeRouter(address(0xFACA), address(localWeth));
        localRouter.setPoolFor(address(localWeth), address(localClaim), false, address(0xFACA), address(lp));
        MockFurnaceLpRewards localFurnace = new MockFurnaceLpRewards(address(localClaim), address(localVe));
        LpStakingVault7D vault = new LpStakingVault7D(
            address(lp),
            address(localWeth),
            address(localClaim),
            address(localVe),
            address(localFurnace),
            address(localRouter),
            address(0xFACA),
            false,
            address(this)
        );

        uint256 count = Constants.MAX_LP_COMPOUND_USERS_PER_CALL;
        address[] memory users = new address[](count);
        uint256 stakeAmount = Constants.MIN_UNBOND_AMOUNT;
        uint256 rewardPerUser = 10e18;

        for (uint256 i = 0; i < count; ++i) {
            address user = address(uint160(0x1000 + i));
            users[i] = user;
            uint256 tokenId = i + 1;
            localVe.setOwner(tokenId, user);
            localVe.setLockInfo(tokenId, stakeAmount, block.timestamp + Constants.MAX_LOCK_DURATION, false, false);
            lp.mint(user, stakeAmount);
            vm.startPrank(user);
            lp.approve(address(vault), stakeAmount);
            vault.stake(stakeAmount);
            vault.setAutoCompoundConfig(true, tokenId, Constants.MAX_LOCK_DURATION, 300, 0);
            vm.stopPrank();
        }

        localClaim.mint(address(vault), rewardPerUser * count);
        vm.prank(address(localFurnace));
        vault.notifyRewards(rewardPerUser * count);

        vm.warp(block.timestamp + 1 days);

        uint256 gasBefore = gasleft();
        vault.compoundForMany(users, type(uint256).max);
        uint256 gasUsed = gasBefore - gasleft();

        assertLt(gasUsed, 30_000_000, "LP max compound batch gas headroom");
        assertEq(localFurnace.enterCalls(), count, "all max batch users processed");
        assertEq(vault.accountedRewardBalance(), 0, "all accounted rewards consumed");
        assertEq(localClaim.balanceOf(address(vault)), 0, "vault reward custody cleared");
        assertEq(localClaim.balanceOf(address(localFurnace)), rewardPerUser * count, "furnace received rewards");
    }

    function _deployMarketSurface() internal {
        vm.txGasPrice(0);
        claim = new ClaimToken(address(this));
        weth = new MockWETH();
        router = new MockAerodromeRouter(FACTORY, address(weth));
        registry = new EntryTokenRegistry(address(this));
        vm.etch(FACTORY, hex"01");
        registry.setRouterConfig(address(router), FACTORY, address(weth), address(claim));

        ve = new VeClaimNFTHarness(address(claim), address(this));
        royalties = new ShareholderRoyalties(address(ve), address(this));
        furnace = new Furnace(
            address(claim), address(ve), address(new FurnaceGuardHelper(address(claim), address(ve))), address(this)
        );
        market = new MarketRouter(address(claim), address(ve), address(royalties), address(this));
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

        ve.setApprovalForAllForTest(alice, address(market), true);
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
}
