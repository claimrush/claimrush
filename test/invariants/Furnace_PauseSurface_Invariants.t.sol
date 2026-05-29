// SPDX-License-Identifier: MIT
pragma solidity ^0.8.34;

import {Test} from "forge-std/Test.sol";

import {ClaimToken} from "src/ClaimToken.sol";
import {MineCore} from "src/MineCore.sol";
import {ShareholderRoyalties} from "src/ShareholderRoyalties.sol";
import {MarketRouter} from "src/MarketRouter.sol";
import {Furnace} from "src/Furnace.sol";
import {FurnaceGuardHelper} from "src/FurnaceGuardHelper.sol";

import {FurnaceQuoter} from "src/FurnaceQuoter.sol";
import {DelegationHub} from "src/DelegationHub.sol";
import {Errors} from "src/lib/Errors.sol";

import {VeClaimNFTHarness} from "../mocks/VeClaimNFTHarness.sol";
import {MockEntryTokenRegistry} from "../mocks/MockEntryTokenRegistry.sol";
import {MockAerodromeRouter} from "../mocks/MockAerodromeRouter.sol";
import {MockWETH} from "../mocks/MockWETH.sol";

/// @dev Furnace must keep MineCore as the locking-pause surface: `setGuardian` rejects any
///      non-MineCore guardian whenever `mineCore` is wired, and `lockingPaused` follows MineCore.
contract FurnacePauseSurfaceInvariants is Test {
    address internal owner = address(0xA11CE);

    ClaimToken internal claim;
    VeClaimNFTHarness internal ve;
    ShareholderRoyalties internal royalties;
    MarketRouter internal market;
    MineCore internal mineCore;
    Furnace internal furnace;
    FurnaceQuoter internal quoter;
    DelegationHub internal hub;
    MockEntryTokenRegistry internal furnaceRegistry;
    MockEntryTokenRegistry internal mineCoreRegistry;

    function setUp() public {
        vm.startPrank(owner);
        claim = new ClaimToken(owner);
        ve = new VeClaimNFTHarness(address(claim), owner);
        royalties = new ShareholderRoyalties(address(ve), owner);
        market = new MarketRouter(address(claim), address(ve), address(royalties), owner);
        mineCore = new MineCore(address(claim), address(ve), address(royalties), owner);
        furnace = new Furnace(
            address(claim), address(ve), address(new FurnaceGuardHelper(address(claim), address(ve))), owner
        );
        quoter = new FurnaceQuoter(address(furnace));
        hub = new DelegationHub();
        furnaceRegistry = new MockEntryTokenRegistry();
        mineCoreRegistry = new MockEntryTokenRegistry();

        claim.setMineCore(address(mineCore));

        furnace.setMineCore(address(mineCore));
        furnace.setFurnaceQuoter(address(quoter));
        furnace.setShareholderRoyalties(address(royalties));
        furnace.setMineMarket(address(market));
        furnace.setEntryTokenRegistry(address(furnaceRegistry));

        mineCore.setFurnace(address(furnace));
        mineCore.setDelegationHub(address(hub));
        mineCore.setEntryTokenRegistry(address(mineCoreRegistry));

        furnace.setDelegationHub(address(hub));

        royalties.setWiring(address(mineCore), address(market), address(furnace));
        ve.setFurnace(address(furnace));
        ve.setMineMarket(address(market));

        MockWETH weth = new MockWETH();
        address factory = address(0xFACADE);
        vm.etch(factory, hex"00");
        MockAerodromeRouter router = new MockAerodromeRouter(factory, address(weth));
        address canonicalPool = address(0xBEEF);
        vm.etch(canonicalPool, hex"00");
        router.setPoolFor(address(weth), address(claim), false, factory, canonicalPool);
        furnaceRegistry.setRouterConfig(address(router), factory, address(weth), address(claim));
        furnaceRegistry.setWethClaimHop(false, canonicalPool);

        furnace.setGuardian(address(mineCore));
        vm.stopPrank();
    }

    function testFuzzFurnaceGuardianCannotDriftFromMineCore(address newGuardian) public {
        vm.assume(newGuardian != address(0));
        vm.assume(newGuardian != address(mineCore));
        vm.assume(newGuardian != address(furnace));

        vm.prank(owner);
        vm.expectRevert(Errors.WiringMismatch.selector);
        furnace.setGuardian(newGuardian);

        assertEq(furnace.guardian(), address(mineCore));
    }

    function testFurnacePauseSurfaceRoutesThroughMineCore() public {
        vm.prank(owner);
        mineCore.setLockingPaused(true);
        assertTrue(furnace.lockingPaused());

        vm.prank(owner);
        mineCore.setLockingPaused(false);
        assertFalse(furnace.lockingPaused());
    }
}
