// SPDX-License-Identifier: MIT
pragma solidity ^0.8.34;

import {Test} from "forge-std/Test.sol";

import {ClaimToken} from "src/ClaimToken.sol";
import {EntryTokenRegistry} from "src/EntryTokenRegistry.sol";
import {Furnace} from "src/Furnace.sol";
import {FurnaceGuardHelper} from "src/FurnaceGuardHelper.sol";

import {FurnaceQuoter} from "src/FurnaceQuoter.sol";
import {MineCore} from "src/MineCore.sol";
import {ShareholderRoyalties} from "src/ShareholderRoyalties.sol";
import {Constants} from "src/lib/Constants.sol";
import {Errors} from "src/lib/Errors.sol";

import {MockWETH} from "./mocks/MockWETH.sol";
import {MockVe} from "./mocks/MockVe.sol";
import {MockAerodromeRouter} from "./mocks/MockAerodromeRouter.sol";
import {MineCoreHarness} from "./mocks/MineCoreHarness.sol";

contract MineCoreWethEntryTest is Test {
    address internal owner;
    address internal alice;

    ClaimToken internal claim;
    MockVe internal ve;
    ShareholderRoyalties internal royalties;
    Furnace internal furnace;
    MineCoreHarness internal mineCore;

    function setUp() public {
        vm.txGasPrice(0);

        owner = makeAddr("owner");
        alice = makeAddr("alice");

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
        furnace.setMineCore(address(mineCore));
        furnace.setFurnaceQuoter(address(quoter));
        furnace.setShareholderRoyalties(address(royalties));
        mineCore.setFurnace(address(furnace));
        vm.etch(address(0xB0B0), hex"00");
        royalties.setWiring(address(mineCore), address(0xB0B0), address(furnace));
        mineCore.setGenesisKingClaimCollectedForTest(true);
        mineCore.setTakeoversPaused(false);
        vm.stopPrank();

        ve.setClaimToken(address(claim));
        ve.setFurnace(address(furnace));

        vm.warp(mineCore.emissionStartTime() + 1);
    }

    function _wireRegistry(MockWETH weth, MockAerodromeRouter router) internal returns (EntryTokenRegistry reg) {
        reg = new EntryTokenRegistry(owner);
        vm.etch(router.defaultFactory(), hex"00"); // satisfy NotAContract guard
        vm.startPrank(owner);
        reg.setRouterConfig(address(router), router.defaultFactory(), address(weth), address(claim));
        mineCore.setEntryTokenRegistry(address(reg));
        vm.stopPrank();
    }

    function testTakeoverWithTokenWethUnwraps1To1AndBypassesRegistryTokenConfig() public {
        MockWETH weth = new MockWETH();
        MockAerodromeRouter router = new MockAerodromeRouter(address(0xFACADE), address(weth));
        _wireRegistry(weth, router);

        uint256 amountIn = Constants.TAKEOVER_PRICE_FLOOR + 0.5 ether;

        // Acquire WETH by deposit so MockWETH has ETH backing for withdraw().
        vm.deal(alice, 10 ether);
        vm.prank(alice);
        weth.deposit{value: amountIn}();

        vm.prank(alice);
        weth.approve(address(mineCore), amountIn);

        uint256 aliceEthBefore = alice.balance;

        vm.prank(alice);
        mineCore.takeoverWithToken(address(weth), amountIn, Constants.TAKEOVER_PRICE_FLOOR, type(uint256).max);

        // Should not attempt any token swap route.
        assertEq(router.lastRoutesHash(), bytes32(0));
        assertEq(router.lastAmountIn(), 0);

        // WETH transferred in, then burned on withdraw.
        assertEq(weth.balanceOf(alice), 0);
        assertEq(weth.balanceOf(address(mineCore)), 0);

        // New king set.
        assertEq(mineCore.currentKing(), alice);

        // Since creditedEth == amountIn and pricePaid == floor (genesis), refund should arrive as ETH.
        assertGt(alice.balance, aliceEthBefore);
    }

    function testTakeoverWithTokenWethRevertsIfMinEthOutNotMet() public {
        MockWETH weth = new MockWETH();
        MockAerodromeRouter router = new MockAerodromeRouter(address(0xFACADE), address(weth));
        _wireRegistry(weth, router);

        uint256 amountIn = 1 ether;

        vm.deal(alice, 10 ether);
        vm.prank(alice);
        weth.deposit{value: amountIn}();

        vm.prank(alice);
        weth.approve(address(mineCore), amountIn);

        vm.expectRevert(Errors.MinEthOutNotMet.selector);
        vm.prank(alice);
        mineCore.takeoverWithToken(address(weth), amountIn, amountIn + 1, type(uint256).max);
    }
}
