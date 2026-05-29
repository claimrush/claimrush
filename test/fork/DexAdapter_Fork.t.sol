// SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {IDexAdapter} from "src/interfaces/IDexAdapter.sol";
import {IPoolFactory} from "src/interfaces/IPoolFactory.sol";
import {Errors} from "src/lib/Errors.sol";

import {AerodromeForkBase} from "./AerodromeForkBase.t.sol";

contract DexAdapterForkTest is AerodromeForkBase {
    uint256 internal constant SEED_WETH = 100 ether;
    uint256 internal constant SEED_CLAIM = 1_000_000e18;

    function setUp() public override {
        super.setUp();
        _seedPool(SEED_WETH, SEED_CLAIM);
    }

    // --- poolFor ---

    function test_poolFor_matchesFactoryGetPool() public view {
        address fromFactory = IPoolFactory(AERODROME_FACTORY).getPool(WETH, address(claimToken), false);
        address fromAdapter = dexAdapter.poolFor(WETH, address(claimToken), false, AERODROME_FACTORY);
        assertEq(fromAdapter, fromFactory, "poolFor must match factory.getPool");
        assertEq(fromAdapter, pool, "poolFor must match our created pool");
    }

    function test_poolFor_reverseTokenOrder() public view {
        address forward = dexAdapter.poolFor(WETH, address(claimToken), false, AERODROME_FACTORY);
        address reverse = dexAdapter.poolFor(address(claimToken), WETH, false, AERODROME_FACTORY);
        assertEq(forward, reverse, "poolFor must be order-independent");
    }

    // --- getAmountsOut ---

    function test_getAmountsOut_returnsNonZero() public view {
        IDexAdapter.Route[] memory routes = _buildRoute(WETH, address(claimToken));
        uint256[] memory amounts = dexAdapter.getAmountsOut(1 ether, routes);

        assertEq(amounts.length, 2, "amounts length");
        assertEq(amounts[0], 1 ether, "amounts[0] = input");
        assertGt(amounts[1], 0, "amounts[1] > 0");
    }

    function test_getAmountsOut_priceImpactIncreasesWithSize() public view {
        IDexAdapter.Route[] memory routes = _buildRoute(WETH, address(claimToken));

        uint256[] memory smallAmounts = dexAdapter.getAmountsOut(0.1 ether, routes);
        uint256[] memory medAmounts = dexAdapter.getAmountsOut(1 ether, routes);
        uint256[] memory largeAmounts = dexAdapter.getAmountsOut(10 ether, routes);

        uint256 rateSmall = (smallAmounts[1] * 1e18) / smallAmounts[0];
        uint256 rateMed = (medAmounts[1] * 1e18) / medAmounts[0];
        uint256 rateLarge = (largeAmounts[1] * 1e18) / largeAmounts[0];

        assertGt(rateSmall, rateMed, "small swap should get better rate than medium");
        assertGt(rateMed, rateLarge, "medium swap should get better rate than large");
    }

    function test_getAmountsOut_revertsOnZeroInput() public {
        IDexAdapter.Route[] memory routes = _buildRoute(WETH, address(claimToken));
        vm.expectRevert(Errors.AmountZero.selector);
        dexAdapter.getAmountsOut(0, routes);
    }

    // --- swapExactETHForTokens ---

    function test_swapExactETHForTokens_realSwap() public {
        uint256 swapAmount = 1 ether;
        IDexAdapter.Route[] memory routes = _buildRoute(WETH, address(claimToken));

        uint256[] memory quoted = dexAdapter.getAmountsOut(swapAmount, routes);
        uint256 expectedOut = quoted[1];

        vm.deal(bob, swapAmount);
        vm.prank(bob);
        uint256[] memory amounts =
            dexAdapter.swapExactETHForTokens{value: swapAmount}(0, routes, bob, block.timestamp + 300);

        assertEq(amounts[0], swapAmount, "input matches");
        assertEq(amounts[amounts.length - 1], expectedOut, "output matches quote");
        assertEq(claimToken.balanceOf(bob), expectedOut, "bob received CLAIM");
    }

    function test_swapExactETHForTokens_slippageReverts() public {
        uint256 swapAmount = 1 ether;
        IDexAdapter.Route[] memory routes = _buildRoute(WETH, address(claimToken));

        uint256[] memory quoted = dexAdapter.getAmountsOut(swapAmount, routes);
        uint256 tooHigh = quoted[1] + 1;

        vm.deal(bob, swapAmount);
        vm.prank(bob);
        vm.expectRevert();
        dexAdapter.swapExactETHForTokens{value: swapAmount}(tooHigh, routes, bob, block.timestamp + 300);
    }

    function test_swapExactETHForTokens_poolReservesChange() public {
        uint256 wethBefore = IERC20(WETH).balanceOf(pool);
        uint256 claimBefore = claimToken.balanceOf(pool);

        uint256 swapAmount = 1 ether;
        IDexAdapter.Route[] memory routes = _buildRoute(WETH, address(claimToken));

        vm.deal(bob, swapAmount);
        vm.prank(bob);
        dexAdapter.swapExactETHForTokens{value: swapAmount}(0, routes, bob, block.timestamp + 300);

        uint256 wethAfter = IERC20(WETH).balanceOf(pool);
        uint256 claimAfter = claimToken.balanceOf(pool);

        assertGt(wethAfter, wethBefore, "pool WETH increased");
        assertLt(claimAfter, claimBefore, "pool CLAIM decreased");
    }

    // --- swapExactTokensForTokens ---

    function test_swapExactTokensForTokens_claimToWeth() public {
        uint256 claimAmount = 10_000e18;
        _dealClaim(bob, claimAmount);

        IDexAdapter.Route[] memory routes = _buildRoute(address(claimToken), WETH);
        uint256[] memory quoted = dexAdapter.getAmountsOut(claimAmount, routes);

        vm.startPrank(bob);
        claimToken.approve(address(dexAdapter), claimAmount);
        uint256[] memory amounts =
            dexAdapter.swapExactTokensForTokens(claimAmount, 0, routes, bob, block.timestamp + 300);
        vm.stopPrank();

        assertEq(amounts[0], claimAmount, "input matches");
        assertEq(amounts[amounts.length - 1], quoted[quoted.length - 1], "output matches quote");
        assertGt(IERC20(WETH).balanceOf(bob), 0, "bob received WETH");
    }

    // --- Route validation ---

    function test_revert_wrongFactory() public {
        IDexAdapter.Route[] memory routes = new IDexAdapter.Route[](1);
        routes[0] = IDexAdapter.Route({from: WETH, to: address(claimToken), stable: false, factory: address(0xdead)});

        vm.expectRevert(Errors.InvalidRoute.selector);
        dexAdapter.getAmountsOut(1 ether, routes);
    }

    function test_revert_threeHopRoute() public {
        IDexAdapter.Route[] memory routes = new IDexAdapter.Route[](3);
        routes[0] = IDexAdapter.Route({from: WETH, to: address(claimToken), stable: false, factory: AERODROME_FACTORY});
        routes[1] = IDexAdapter.Route({from: address(claimToken), to: WETH, stable: false, factory: AERODROME_FACTORY});
        routes[2] = IDexAdapter.Route({from: WETH, to: address(claimToken), stable: false, factory: AERODROME_FACTORY});

        vm.expectRevert(Errors.InvalidRoute.selector);
        dexAdapter.getAmountsOut(1 ether, routes);
    }

    function test_revert_circularRoute() public {
        IDexAdapter.Route[] memory routes = new IDexAdapter.Route[](2);
        routes[0] = IDexAdapter.Route({from: WETH, to: address(claimToken), stable: false, factory: AERODROME_FACTORY});
        routes[1] = IDexAdapter.Route({from: address(claimToken), to: WETH, stable: false, factory: AERODROME_FACTORY});

        vm.expectRevert(Errors.InvalidRoute.selector);
        dexAdapter.getAmountsOut(1 ether, routes);
    }

    // --- Swap fees are real ---

    function test_swapFeeIsDeducted() public view {
        IDexAdapter.Route[] memory routes = _buildRoute(WETH, address(claimToken));
        uint256[] memory amounts = dexAdapter.getAmountsOut(10 ether, routes);

        // With x*y=k and a 0.3% fee: output < input * (reserves_claim / reserves_weth)
        // The naive ratio would be 10 ether * SEED_CLAIM / SEED_WETH = 100_000e18
        // Real output must be less due to fee + price impact
        uint256 naiveOutput = (10 ether * SEED_CLAIM) / SEED_WETH;
        assertLt(amounts[1], naiveOutput, "real output < naive (fee + impact deducted)");
    }
}
