// SPDX-License-Identifier: MIT
pragma solidity ^0.8.34;

import {Test} from "forge-std/Test.sol";

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";

import {DexAdapter} from "src/DexAdapter.sol";
import {IDexAdapter} from "src/interfaces/IDexAdapter.sol";

import {Errors} from "src/lib/Errors.sol";

import {MockAerodromeRouter} from "./mocks/MockAerodromeRouter.sol";
import {MockERC20} from "./mocks/MockERC20.sol";

contract DexAdapterTest is Test {
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

        // DexAdapter's constructor enforces that the router's defaultFactory() / weth() return
        // real deployed contracts. Give the placeholder pin addresses non-empty bytecode so the
        // adapter accepts the mock router; size != 23 keeps them outside the EIP-7702 prefix path.
        vm.etch(factory, hex"00");
        vm.etch(wrappedNative, hex"00");

        router = new MockAerodromeRouter(factory, wrappedNative);
        router.setRateX18(1_000e18);

        adapter = new DexAdapter(address(router), owner);
    }

    function testConstructorRejectsZeroAddress() public {
        vm.expectRevert(Errors.ZeroAddress.selector);
        new DexAdapter(address(0), owner);

        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableInvalidOwner.selector, address(0)));
        new DexAdapter(address(router), address(0));
    }

    function testConstructorRejectsNonContractRouter() public {
        vm.expectRevert(Errors.NotAContract.selector);
        new DexAdapter(address(0xDEAD), owner);
    }

    function testSetAerodromeRouterNotCallable() public {
        // Policy: DexAdapter MUST NOT expose a governance setter for swapping the underlying DEX router.
        // Verify the selector is not callable (no fallback function is defined, so this should fail).
        vm.prank(owner);
        (bool ok,) = address(adapter).call(abi.encodeWithSignature("setAerodromeRouter(address)", address(0x1234)));
        assertTrue(!ok);
        assertEq(adapter.aerodromeRouter(), address(router));
    }

    function testViewPassthroughs() public {
        assertEq(adapter.defaultFactory(), factory);
        assertEq(adapter.weth(), wrappedNative);

        address expectedPool = address(0xCAFE);
        router.setPoolFor(address(tokenIn), address(tokenOut), false, factory, expectedPool);

        assertEq(adapter.poolFor(address(tokenIn), address(tokenOut), false, factory), expectedPool);

        IDexAdapter.Route[] memory routes = new IDexAdapter.Route[](1);
        routes[0] = IDexAdapter.Route({from: address(tokenIn), to: address(tokenOut), stable: false, factory: factory});

        uint256[] memory amts = adapter.getAmountsOut(1 ether, routes);
        assertEq(amts.length, 2);
        assertEq(amts[0], 1 ether);
        assertEq(amts[1], 1 ether * 1_000);
    }

    function testSwapExactETHForTokensForwardsValueAndRoutes() public {
        IDexAdapter.Route[] memory routes = new IDexAdapter.Route[](1);
        // ETH swaps are encoded as WETH-based routes (router wraps ETH -> WETH internally).
        routes[0] = IDexAdapter.Route({from: wrappedNative, to: address(tokenOut), stable: false, factory: factory});

        vm.etch(wrappedNative, hex"00");
        vm.deal(alice, 1 ether);
        vm.prank(alice);
        uint256[] memory amts = adapter.swapExactETHForTokens{value: 1 ether}(0, routes, bob, block.timestamp + 1);

        assertEq(amts.length, 2);
        assertEq(amts[0], 1 ether);
        assertEq(router.lastEthValue(), 1 ether);
        assertEq(router.lastTo(), bob);
        assertEq(tokenOut.balanceOf(bob), 1 ether * 1_000);
    }

    function testSwapRevertsOnDeadline() public {
        IDexAdapter.Route[] memory routes = new IDexAdapter.Route[](1);
        routes[0] = IDexAdapter.Route({from: wrappedNative, to: address(tokenOut), stable: false, factory: factory});

        vm.deal(alice, 1 ether);
        vm.prank(alice);
        vm.expectRevert(Errors.DeadlineExpired.selector);
        adapter.swapExactETHForTokens{value: 1 ether}(0, routes, bob, block.timestamp - 1);
    }

    function testSwapRevertsOnInvalidRouteFactory() public {
        IDexAdapter.Route[] memory routes = new IDexAdapter.Route[](1);
        routes[0] =
            IDexAdapter.Route({from: wrappedNative, to: address(tokenOut), stable: false, factory: address(0xBADC0DE)});

        vm.deal(alice, 1 ether);
        vm.prank(alice);
        vm.expectRevert(Errors.InvalidRoute.selector);
        adapter.swapExactETHForTokens{value: 1 ether}(0, routes, bob, block.timestamp + 1);
    }

    function testSwapExactETHForTokensRevertsIfFirstHopNotWeth() public {
        IDexAdapter.Route[] memory routes = new IDexAdapter.Route[](1);
        routes[0] = IDexAdapter.Route({from: address(tokenIn), to: address(tokenOut), stable: false, factory: factory});

        vm.deal(alice, 1 ether);
        vm.prank(alice);
        vm.expectRevert(Errors.InvalidRoute.selector);
        adapter.swapExactETHForTokens{value: 1 ether}(0, routes, bob, block.timestamp + 1);
    }

    function testGetAmountsOutRevertsOnInvalidRouteLength() public {
        IDexAdapter.Route[] memory routes = new IDexAdapter.Route[](0);
        vm.expectRevert(Errors.InvalidRoute.selector);
        adapter.getAmountsOut(1 ether, routes);
    }

    function testGetAmountsOutRevertsOnBrokenChainForTwoHopRoute() public {
        address mid = address(0x1111);
        vm.etch(mid, hex"00");

        IDexAdapter.Route[] memory routes = new IDexAdapter.Route[](2);
        routes[0] = IDexAdapter.Route({from: address(tokenIn), to: mid, stable: false, factory: factory});
        routes[1] = IDexAdapter.Route({from: address(tokenIn), to: address(tokenOut), stable: false, factory: factory});

        vm.expectRevert(Errors.InvalidRoute.selector);
        adapter.getAmountsOut(1 ether, routes);
    }

    function testSwapExactTokensForTokensPullsFromCallerAndForwards() public {
        IDexAdapter.Route[] memory routes = new IDexAdapter.Route[](1);
        routes[0] = IDexAdapter.Route({from: address(tokenIn), to: address(tokenOut), stable: false, factory: factory});

        uint256 amountIn = 2 ether;

        // Fund caller and approve adapter. Adapter should pull from caller then forward into router.
        tokenIn.mint(alice, amountIn);
        vm.prank(alice);
        tokenIn.approve(address(adapter), amountIn);

        vm.prank(alice);
        adapter.swapExactTokensForTokens(amountIn, 0, routes, bob, block.timestamp + 1);

        assertEq(tokenOut.balanceOf(bob), amountIn * 1_000);
        assertEq(router.lastAmountIn(), amountIn);
        assertEq(router.lastTo(), bob);
    }

    // ---- poolFor code.length parity with _validateRoutes ----

    function testPoolFor_revertsOnEoaTokenA() public {
        address eoa = address(0xDEAD);
        assertEq(eoa.code.length, 0, "precondition: eoa has no code");

        vm.expectRevert(Errors.NotAContract.selector);
        adapter.poolFor(eoa, address(tokenOut), false, factory);
    }

    function testPoolFor_revertsOnEoaTokenB() public {
        address eoa = address(0xDEAD);

        vm.expectRevert(Errors.NotAContract.selector);
        adapter.poolFor(address(tokenIn), eoa, false, factory);
    }

    function testPoolFor_revertsWhenBothTokensEoa() public {
        address eoaA = address(0xDEAD1);
        address eoaB = address(0xDEAD2);

        vm.expectRevert(Errors.NotAContract.selector);
        adapter.poolFor(eoaA, eoaB, false, factory);
    }

    function testPoolFor_succeedsOnContractTokens() public {
        // Control case: both arguments are real contracts (from setUp).
        address expectedPool = address(0xCAFE01);
        router.setPoolFor(address(tokenIn), address(tokenOut), false, factory, expectedPool);

        assertEq(adapter.poolFor(address(tokenIn), address(tokenOut), false, factory), expectedPool);
    }

    function testPoolFor_zeroAddressStillPrecedesCodeLengthCheck() public {
        // Zero-address check must still take precedence so error semantics don't drift.
        vm.expectRevert(Errors.ZeroAddress.selector);
        adapter.poolFor(address(0), address(tokenOut), false, factory);

        vm.expectRevert(Errors.ZeroAddress.selector);
        adapter.poolFor(address(tokenIn), address(0), false, factory);
    }
}
