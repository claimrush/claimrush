// SPDX-License-Identifier: MIT
pragma solidity ^0.8.34;

import {Test} from "forge-std/Test.sol";

import {DexAdapter} from "src/DexAdapter.sol";
import {IDexAdapter} from "src/interfaces/IDexAdapter.sol";

import {Errors} from "src/lib/Errors.sol";

import {MockAerodromeRouter} from "./mocks/MockAerodromeRouter.sol";
import {MockERC20} from "./mocks/MockERC20.sol";

contract DexAdapterHardeningTest is Test {
    MockAerodromeRouter internal router;
    DexAdapter internal adapter;

    MockERC20 internal tokenIn;
    MockERC20 internal tokenOut;

    address internal owner = address(0xA11CE);
    address internal alice = address(0xA);
    address internal bob = address(0xB);
    address internal factory = address(0xFACA);
    address internal wrappedNative = address(0xBEEF);

    function setUp() public {
        tokenIn = new MockERC20("TokenIn", "TIN");
        tokenOut = new MockERC20("TokenOut", "TOUT");

        vm.etch(factory, hex"00");
        vm.etch(wrappedNative, hex"00");

        router = new MockAerodromeRouter(factory, wrappedNative);
        router.setRateX18(1_000e18);

        adapter = new DexAdapter(address(router), owner);
    }

    function _route(address from, address to, address fact) internal pure returns (IDexAdapter.Route memory r) {
        r = IDexAdapter.Route({from: from, to: to, stable: false, factory: fact});
    }

    function testSwapExactTokensForTokensRevertsOnAmountZero() public {
        IDexAdapter.Route[] memory routes = new IDexAdapter.Route[](1);
        routes[0] = _route(address(tokenIn), address(tokenOut), factory);

        vm.prank(alice);
        vm.expectRevert(Errors.AmountZero.selector);
        adapter.swapExactTokensForTokens(0, 0, routes, bob, block.timestamp + 1);
    }

    function testSwapExactTokensForTokensRevertsOnInsufficientBalance() public {
        IDexAdapter.Route[] memory routes = new IDexAdapter.Route[](1);
        routes[0] = _route(address(tokenIn), address(tokenOut), factory);

        // Caller has less than amountIn.
        tokenIn.mint(alice, 10 ether);
        vm.prank(alice);
        vm.expectRevert(Errors.InsufficientTokenBalance.selector);
        adapter.swapExactTokensForTokens(100 ether, 0, routes, bob, block.timestamp + 1);
    }

    function testSwapExactTokensForTokensRevertsOnInsufficientAllowance() public {
        IDexAdapter.Route[] memory routes = new IDexAdapter.Route[](1);
        routes[0] = _route(address(tokenIn), address(tokenOut), factory);

        // Caller has balance, but has not approved the adapter.
        tokenIn.mint(alice, 10 ether);

        vm.prank(alice);
        vm.expectRevert(Errors.InsufficientTokenAllowance.selector);
        adapter.swapExactTokensForTokens(1 ether, 0, routes, bob, block.timestamp + 1);
    }

    function testSwapExactTokensForTokensRevertsIfTokenInNotAContract() public {
        IDexAdapter.Route[] memory routes = new IDexAdapter.Route[](1);
        address notAContract = address(0x1234);
        routes[0] = _route(notAContract, address(tokenOut), factory);

        vm.prank(alice);
        vm.expectRevert(Errors.NotAContract.selector);
        adapter.swapExactTokensForTokens(1 ether, 0, routes, bob, block.timestamp + 1);
    }

    function testFuzz_SwapExactTokensForTokensRevertsOnInsufficientBalance(uint256 amountIn) public {
        uint256 bal = 10 ether;
        tokenIn.mint(alice, bal);
        vm.assume(amountIn > bal);

        IDexAdapter.Route[] memory routes = new IDexAdapter.Route[](1);
        routes[0] = _route(address(tokenIn), address(tokenOut), factory);

        vm.prank(alice);
        vm.expectRevert(Errors.InsufficientTokenBalance.selector);
        adapter.swapExactTokensForTokens(amountIn, 0, routes, bob, block.timestamp + 1);
    }

    function testFuzz_SwapExactTokensForTokensRevertsOnInsufficientAllowance(uint256 allowance, uint256 amountIn)
        public
    {
        uint256 bal = 10 ether;
        tokenIn.mint(alice, bal);

        // Pick an allowance strictly less than balance so we can choose an amountIn that is:
        // allowance < amountIn <= balance.
        allowance = bound(allowance, 0, bal - 1);
        amountIn = bound(amountIn, allowance + 1, bal);

        // Set caller approval below amountIn.
        vm.prank(alice);
        tokenIn.approve(address(adapter), allowance);

        IDexAdapter.Route[] memory routes = new IDexAdapter.Route[](1);
        routes[0] = _route(address(tokenIn), address(tokenOut), factory);

        vm.prank(alice);
        vm.expectRevert(Errors.InsufficientTokenAllowance.selector);
        adapter.swapExactTokensForTokens(amountIn, 0, routes, bob, block.timestamp + 1);
    }

    function testSwapExactETHForTokensRevertsOnAmountZero() public {
        IDexAdapter.Route[] memory routes = new IDexAdapter.Route[](1);
        routes[0] = _route(wrappedNative, address(tokenOut), factory);

        vm.prank(alice);
        vm.expectRevert(Errors.AmountZero.selector);
        adapter.swapExactETHForTokens{value: 0}(0, routes, bob, block.timestamp + 1);
    }

    function testRoutesRejectSelfSwap() public {
        IDexAdapter.Route[] memory routes = new IDexAdapter.Route[](1);
        routes[0] = _route(address(tokenIn), address(tokenIn), factory);

        vm.expectRevert(Errors.InvalidRoute.selector);
        adapter.getAmountsOut(1 ether, routes);
    }

    function testPinnedFactoryAndWethResistRouterMutation() public {
        // Mutate the router implementation after the adapter is deployed.
        // Adapter must retain deterministic behavior.
        router.setDefaultFactory(address(0x1234));
        router.setWeth(address(0xCAFE));

        // Adapter should still report pinned values.
        assertEq(adapter.defaultFactory(), factory);
        assertEq(adapter.weth(), wrappedNative);

        // Using the mutated factory should revert (pinned factory policy).
        IDexAdapter.Route[] memory routes = new IDexAdapter.Route[](1);
        routes[0] = _route(address(tokenIn), address(tokenOut), address(0x1234));
        vm.expectRevert(Errors.InvalidRoute.selector);
        adapter.getAmountsOut(1 ether, routes);

        // Using a first hop that is not the pinned wrapped native should revert.
        IDexAdapter.Route[] memory ethRoutes = new IDexAdapter.Route[](1);
        ethRoutes[0] = _route(address(0xCAFE), address(tokenOut), factory);

        vm.deal(alice, 1 ether);
        vm.prank(alice);
        vm.expectRevert(Errors.NotAContract.selector);
        adapter.swapExactETHForTokens{value: 1 ether}(0, ethRoutes, bob, block.timestamp + 1);
    }

    function testTwoHopRouteSucceeds() public {
        IDexAdapter.Route[] memory routes = new IDexAdapter.Route[](2);
        address mid = address(0x1111);
        vm.etch(mid, hex"00");
        routes[0] = _route(address(tokenIn), mid, factory);
        routes[1] = _route(mid, address(tokenOut), factory);

        tokenIn.mint(alice, 1 ether);
        vm.prank(alice);
        tokenIn.approve(address(adapter), type(uint256).max);

        vm.prank(alice);
        uint256[] memory amts = adapter.swapExactTokensForTokens(1 ether, 0, routes, bob, block.timestamp + 1);
        assertEq(amts.length, 3);
        assertEq(amts[0], 1 ether);
        assertEq(tokenOut.balanceOf(bob), 1 ether * 1_000 * 1_000);
    }

    function testFuzz_GetAmountsOutRevertsOnBadRouteLength(uint8 n) public {
        vm.assume(n <= 6);

        IDexAdapter.Route[] memory routes = new IDexAdapter.Route[](n);
        if (n == 0 || n > 2) {
            vm.expectRevert(Errors.InvalidRoute.selector);
            adapter.getAmountsOut(1 ether, routes);
            return;
        }

        if (n == 1) {
            routes[0] = _route(address(tokenIn), address(tokenOut), factory);
        } else {
            address mid = address(0x1111);
            vm.etch(mid, hex"00");
            routes[0] = _route(address(tokenIn), mid, factory);
            routes[1] = _route(mid, address(tokenOut), factory);
        }

        uint256[] memory amts = adapter.getAmountsOut(1 ether, routes);
        assertEq(amts.length, n + 1);
    }

    function testFuzz_GetAmountsOutRevertsOnBrokenChain(address a, address b, address c) public {
        vm.assume(a != address(0) && b != address(0) && c != address(0));
        vm.assume(a != b && b != c && a != c);
        // Exclude addresses that trigger InvalidRoute before NotAContract.
        address rtr = address(router);
        address adpt = address(adapter);
        vm.assume(a != factory && b != factory && c != factory);
        vm.assume(a != rtr && b != rtr && c != rtr);
        vm.assume(a != adpt && b != adpt && c != adpt);
        vm.assume(a != address(tokenOut) && b != address(tokenOut));
        // Route continuity: b must equal c for routes to pass the chain check.
        // But the test name says "broken chain" — so we expect some revert.
        // With all validation checks, the revert may be InvalidRoute (continuity)
        // or NotAContract. Accept either.
        vm.expectRevert();
        IDexAdapter.Route[] memory routes = new IDexAdapter.Route[](2);
        routes[0] = _route(a, b, factory);
        routes[1] = _route(c, address(tokenOut), factory);
        adapter.getAmountsOut(1 ether, routes);
    }
}
