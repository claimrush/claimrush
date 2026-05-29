// SPDX-License-Identifier: MIT
pragma solidity ^0.8.34;

import {Test} from "forge-std/Test.sol";
import {ClaimToken} from "src/ClaimToken.sol";
import {VeClaimNFTHarness} from "../mocks/VeClaimNFTHarness.sol";
import {Furnace} from "src/Furnace.sol";
import {FurnaceGuardHelper} from "src/FurnaceGuardHelper.sol";

import {FurnaceQuoter} from "src/FurnaceQuoter.sol";
import {MineCore} from "src/MineCore.sol";
import {ShareholderRoyalties} from "src/ShareholderRoyalties.sol";
import {MarketRouter} from "src/MarketRouter.sol";
import {DelegationHub} from "src/DelegationHub.sol";
import {ClaimAllHelper} from "src/ClaimAllHelper.sol";
import {EntryTokenRegistry} from "src/EntryTokenRegistry.sol";
import {Constants} from "src/lib/Constants.sol";
import {Errors} from "src/lib/Errors.sol";
import {MineCoreHarness} from "../mocks/MineCoreHarness.sol";
import {MockAerodromeRouter} from "../mocks/MockAerodromeRouter.sol";
import {MockERC20} from "../mocks/MockERC20.sol";

/// @title Integration test for MarketRouter listing/settlement.
/// @dev Covers the missing Marketplace_Trading.t.sol from the test plan.
///      Tests multi-contract flow: lock creation → listing → settlement.
contract MarketplaceTradingIT is Test {
    ClaimToken internal claim;
    VeClaimNFTHarness internal ve;
    Furnace internal furnace;
    FurnaceQuoter internal quoter;
    MineCoreHarness internal mineCore;
    ShareholderRoyalties internal royalties;
    MarketRouter internal market;
    DelegationHub internal delegationHub;
    ClaimAllHelper internal helper;
    EntryTokenRegistry internal furnaceRegistry;
    EntryTokenRegistry internal mineCoreRegistry;

    address internal deployer;
    address internal seller;
    address internal keeper;

    function setUp() public {
        deployer = address(this);
        seller = makeAddr("seller");
        keeper = makeAddr("keeper");

        // Deploy full stack (mirrors EchidnaSetup)
        claim = new ClaimToken(deployer);
        ve = new VeClaimNFTHarness(address(claim), deployer);
        royalties = new ShareholderRoyalties(address(ve), deployer);
        furnace = new Furnace(
            address(claim), address(ve), address(new FurnaceGuardHelper(address(claim), address(ve))), deployer
        );
        quoter = new FurnaceQuoter(address(furnace));
        market = new MarketRouter(address(claim), address(ve), address(royalties), deployer);
        mineCore = new MineCoreHarness(address(claim), address(ve), address(royalties), deployer);
        delegationHub = new DelegationHub();
        helper = new ClaimAllHelper(address(royalties), address(mineCore));
        furnaceRegistry = new EntryTokenRegistry(deployer);
        mineCoreRegistry = new EntryTokenRegistry(deployer);

        // Mock DEX infrastructure for EntryTokenRegistry
        address factory = address(0xFAC);
        vm.etch(factory, hex"00");
        MockERC20 weth = new MockERC20("Wrapped ETH", "WETH");
        MockAerodromeRouter dexRouter = new MockAerodromeRouter(factory, address(weth));
        address mockPool = address(0xBEEF);
        vm.etch(mockPool, hex"00");
        dexRouter.setPoolFor(address(weth), address(claim), false, factory, mockPool);
        furnaceRegistry.setRouterConfig(address(dexRouter), factory, address(weth), address(claim));
        furnaceRegistry.setWethClaimHop(false, mockPool);
        mineCoreRegistry.setRouterConfig(address(dexRouter), factory, address(weth), address(claim));

        // Wire
        claim.setMineCore(address(mineCore));
        furnace.setShareholderRoyalties(address(royalties));
        furnace.setMineCore(address(mineCore));
        furnace.setMineMarket(address(market));
        furnace.setFurnaceQuoter(address(quoter));
        // The canonical-hub check requires MineCore-side bindings before
        // the furnace-side hub pointer is set.
        mineCore.setFurnace(address(furnace));
        mineCore.setDelegationHub(address(delegationHub));
        furnace.setDelegationHub(address(delegationHub));
        furnace.setEntryTokenRegistry(address(furnaceRegistry));
        mineCore.setClaimAllHelper(address(helper));
        mineCore.setEntryTokenRegistry(address(mineCoreRegistry));
        mineCore.setGenesisKingClaimCollectedForTest(true);
        mineCore.setTakeoversPaused(false);
        royalties.setWiring(address(mineCore), address(market), address(furnace));
        royalties.setClaimAllHelper(address(helper));
        ve.setFurnace(address(furnace));
        ve.setMineMarket(address(market));
        furnace.setGuardian(address(mineCore));

        // Settlement keeper for listing/settlement flows
        market.setSettlementKeeper(keeper, true);

        // ClaimToken still supports config freeze (e.g. mine core wiring)
        claim.freezeConfig();
    }

    // ── Lock creation via Furnace ───────────────────────────────────

    function testSellerCanCreateLockAndListOnMarket() public {
        // Generate CLAIM for seller via takeover emissions
        _generateClaimForSeller(50_000e18);

        // Create a lock
        vm.startPrank(seller);
        claim.approve(address(furnace), 50_000e18);
        uint256 tokenId = furnace.enterWithClaim(50_000e18, 0, Constants.MAX_LOCK_DURATION, false, 1);
        assertGt(tokenId, 0, "lock must be created");

        // Approve MarketRouter to transfer the NFT
        ve.approveForTest(address(market), tokenId);

        // List the lock
        market.listLock(tokenId, 60_000e18, block.timestamp + 30 days);
        vm.stopPrank();

        // Verify lock is listed
        (,,, bool listed) = ve.getLockInfo(tokenId);
        assertTrue(listed, "lock must be listed");
    }

    function testListedLockMutationsBlocked() public {
        _generateClaimForSeller(50_000e18);

        vm.startPrank(seller);
        claim.approve(address(furnace), 50_000e18);
        uint256 tokenId = furnace.enterWithClaim(50_000e18, 0, Constants.MAX_LOCK_DURATION / 2, false, 1);
        ve.approveForTest(address(market), tokenId);
        market.listLock(tokenId, 60_000e18, block.timestamp + 30 days);
        vm.stopPrank();

        // All mutations should revert
        vm.prank(address(furnace));
        vm.expectRevert(Errors.LockListedOrFrozen.selector);
        ve.extendLockToFor(seller, tokenId, block.timestamp + Constants.MAX_LOCK_DURATION);

        vm.prank(seller);
        vm.expectRevert(Errors.LockListedOrFrozen.selector);
        ve.setAutoMax(tokenId, true);
    }

    function testEmergencyDelistAfterMinAge() public {
        _generateClaimForSeller(50_000e18);

        vm.startPrank(seller);
        claim.approve(address(furnace), 50_000e18);
        uint256 tokenId = furnace.enterWithClaim(50_000e18, 0, Constants.MAX_LOCK_DURATION, false, 1);
        ve.approveForTest(address(market), tokenId);
        market.listLock(tokenId, 60_000e18, block.timestamp + 30 days);
        vm.stopPrank();

        // Advance past the listing cooldown block
        vm.roll(block.number + 1);

        // Emergency delist too soon
        vm.prank(seller);
        vm.expectRevert(Errors.EmergencyDelistTooSoon.selector);
        market.emergencyDelist(tokenId);

        // After min age
        vm.warp(block.timestamp + Constants.EMERGENCY_DELIST_MIN_AGE + 1);
        vm.prank(seller);
        market.emergencyDelist(tokenId);

        (,,, bool listed) = ve.getLockInfo(tokenId);
        assertFalse(listed, "lock must be delisted");
    }

    // ── Helper ──────────────────────────────────────────────────────

    function _generateClaimForSeller(uint256 amount) internal {
        // Direct mint via harness (post-genesis state)
        vm.prank(address(mineCore));
        claim.mint(seller, amount);
    }
}
