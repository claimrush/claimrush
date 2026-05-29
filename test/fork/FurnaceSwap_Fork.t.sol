// SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {IDexAdapter} from "src/interfaces/IDexAdapter.sol";
import {IWETH} from "src/interfaces/IWETH.sol";

import {AerodromeForkBase} from "./AerodromeForkBase.t.sol";

/// @notice Fork tests validating the swap and quote mechanics that FurnaceGuardHelper
///         and FurnaceQuoter depend on. Tests the real Aerodrome router behavior that
///         underlies the Furnace's enter-with-ETH and enter-with-token paths.
contract FurnaceSwapForkTest is AerodromeForkBase {
    uint256 internal constant SEED_WETH = 100 ether;
    uint256 internal constant SEED_CLAIM = 1_000_000e18;

    function setUp() public override {
        super.setUp();
        _seedPool(SEED_WETH, SEED_CLAIM);
    }

    // --- ETH -> CLAIM swap (same path as FurnaceGuardHelper.executeSwapEthToClaim) ---

    function test_ethToClaimSwap_outputMatchesQuote() public {
        uint256 swapAmount = 1 ether;
        IDexAdapter.Route[] memory routes = _buildRoute(WETH, address(claimToken));

        uint256[] memory quoted = dexAdapter.getAmountsOut(swapAmount, routes);
        uint256 expectedOut = quoted[1];
        assertGt(expectedOut, 0, "quote > 0");

        vm.deal(bob, swapAmount);
        vm.prank(bob);
        uint256[] memory amounts =
            dexAdapter.swapExactETHForTokens{value: swapAmount}(0, routes, bob, block.timestamp + 300);

        assertEq(amounts[amounts.length - 1], expectedOut, "swap output == quoted output");
    }

    function test_ethToClaimSwap_nonZeroAmountOutMin() public {
        uint256 swapAmount = 1 ether;
        IDexAdapter.Route[] memory routes = _buildRoute(WETH, address(claimToken));

        uint256[] memory quoted = dexAdapter.getAmountsOut(swapAmount, routes);
        uint256 minOut = quoted[1]; // exact quote as min — should succeed in same block

        vm.deal(bob, swapAmount);
        vm.prank(bob);
        uint256[] memory amounts =
            dexAdapter.swapExactETHForTokens{value: swapAmount}(minOut, routes, bob, block.timestamp + 300);

        assertGe(amounts[amounts.length - 1], minOut, "output >= minOut");
    }

    // --- Token -> CLAIM (same path as FurnaceGuardHelper.executeSwapTokenToClaim) ---

    function test_tokenToClaimSwap_wethInput() public {
        uint256 swapAmount = 1 ether;
        _dealWeth(bob, swapAmount);

        IDexAdapter.Route[] memory routes = _buildRoute(WETH, address(claimToken));
        uint256[] memory quoted = dexAdapter.getAmountsOut(swapAmount, routes);

        vm.startPrank(bob);
        IERC20(WETH).approve(address(dexAdapter), swapAmount);
        uint256[] memory amounts =
            dexAdapter.swapExactTokensForTokens(swapAmount, 0, routes, bob, block.timestamp + 300);
        vm.stopPrank();

        assertEq(amounts[amounts.length - 1], quoted[1], "token swap matches quote");
        assertEq(claimToken.balanceOf(bob), quoted[1], "bob received quoted CLAIM");
    }

    // --- Quote accuracy: getAmountsOut matches real swap output ---

    function test_quoteAccuracy_smallSwap() public {
        _assertQuoteMatchesSwap(0.01 ether);
    }

    function test_quoteAccuracy_mediumSwap() public {
        _assertQuoteMatchesSwap(1 ether);
    }

    function test_quoteAccuracy_largeSwap() public {
        _assertQuoteMatchesSwap(10 ether);
    }

    function _assertQuoteMatchesSwap(uint256 swapAmount) internal {
        IDexAdapter.Route[] memory routes = _buildRoute(WETH, address(claimToken));
        uint256[] memory quoted = dexAdapter.getAmountsOut(swapAmount, routes);

        vm.deal(bob, swapAmount);
        vm.prank(bob);
        uint256[] memory amounts =
            dexAdapter.swapExactETHForTokens{value: swapAmount}(0, routes, bob, block.timestamp + 300);

        assertEq(
            amounts[amounts.length - 1], quoted[1], string.concat("quote matches swap for ", vm.toString(swapAmount))
        );
    }

    // --- Price impact ---

    function test_priceImpact_largeSwapGetsWorseRate() public view {
        IDexAdapter.Route[] memory routes = _buildRoute(WETH, address(claimToken));

        uint256[] memory small = dexAdapter.getAmountsOut(0.01 ether, routes);
        uint256[] memory large = dexAdapter.getAmountsOut(10 ether, routes);

        // Rate = output / input (scaled to 1e18 for precision)
        uint256 rateSmall = (small[1] * 1e18) / small[0];
        uint256 rateLarge = (large[1] * 1e18) / large[0];

        assertGt(rateSmall, rateLarge, "small swap gets better rate (less price impact)");

        // The difference should be meaningful, not just rounding
        uint256 impactBps = ((rateSmall - rateLarge) * 10_000) / rateSmall;
        assertGt(impactBps, 0, "price impact > 0 bps");
    }

    function test_priceImpact_100ethVs001eth() public view {
        IDexAdapter.Route[] memory routes = _buildRoute(WETH, address(claimToken));

        uint256[] memory tiny = dexAdapter.getAmountsOut(0.001 ether, routes);
        uint256[] memory huge = dexAdapter.getAmountsOut(50 ether, routes);

        uint256 rateTiny = (tiny[1] * 1e18) / tiny[0];
        uint256 rateHuge = (huge[1] * 1e18) / huge[0];

        // 50 ETH into a 100 ETH pool should have severe price impact
        uint256 impactBps = ((rateTiny - rateHuge) * 10_000) / rateTiny;
        assertGt(impactBps, 100, "50% of pool should cause > 1% price impact");
    }

    // --- Fee deduction is real ---

    function test_feeDeducted_outputLessThanNaive() public view {
        IDexAdapter.Route[] memory routes = _buildRoute(WETH, address(claimToken));

        // For a very small swap, price impact is negligible. The difference from
        // naive output is almost entirely the swap fee.
        uint256 swapAmount = 0.001 ether;
        uint256[] memory amounts = dexAdapter.getAmountsOut(swapAmount, routes);

        uint256 naiveOutput = (swapAmount * SEED_CLAIM) / SEED_WETH;
        assertLt(amounts[1], naiveOutput, "real output < naive output (fee deducted)");

        // The gap should be roughly the fee percentage (0.3% for volatile pools)
        uint256 feeEstimateBps = ((naiveOutput - amounts[1]) * 10_000) / naiveOutput;
        // Allow some tolerance for the small amount of price impact
        assertGt(feeEstimateBps, 20, "fee > 0.2%");
        assertLt(feeEstimateBps, 50, "fee < 0.5%");
    }

    // --- Reverse direction (CLAIM -> WETH) ---

    function test_reverseSwap_claimToWeth() public {
        uint256 claimAmount = 10_000e18;
        _dealClaim(bob, claimAmount);

        IDexAdapter.Route[] memory routes = _buildRoute(address(claimToken), WETH);
        uint256[] memory quoted = dexAdapter.getAmountsOut(claimAmount, routes);
        assertGt(quoted[1], 0, "reverse quote > 0");

        vm.startPrank(bob);
        claimToken.approve(address(dexAdapter), claimAmount);
        uint256[] memory amounts =
            dexAdapter.swapExactTokensForTokens(claimAmount, 0, routes, bob, block.timestamp + 300);
        vm.stopPrank();

        assertEq(amounts[amounts.length - 1], quoted[1], "reverse swap matches quote");
    }
}
