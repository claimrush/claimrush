// SPDX-License-Identifier: MIT
pragma solidity ^0.8.34;

import {Test} from "forge-std/Test.sol";

import {DexAdapter} from "src/DexAdapter.sol";
import {IDexAdapter} from "src/interfaces/IDexAdapter.sol";
import {Errors} from "src/lib/Errors.sol";

import {MockAerodromeRouter} from "./mocks/MockAerodromeRouter.sol";
import {MockERC20} from "./mocks/MockERC20.sol";

/// @notice Ensures swap outputs cannot be routed back into the adapter itself.
contract DexAdapterSelfRoutingTest is Test {
    MockAerodromeRouter internal router;
    DexAdapter internal adapter;
    MockERC20 internal tokenIn;
    MockERC20 internal tokenOut;

    address internal owner = address(0xA11CE);
    address internal alice = address(0xA);

    address internal factory = address(0xFACA);
    address internal wrappedNative = address(0xBEEF);

    function setUp() public {
        tokenIn = new MockERC20("TokenIn", "TIN");
        tokenOut = new MockERC20("TokenOut", "TOUT");

        vm.etch(factory, hex"00");
        vm.etch(wrappedNative, hex"00");

        router = new MockAerodromeRouter(factory, wrappedNative);
        router.setRateX18(1e18);

        adapter = new DexAdapter(address(router), owner);
    }

    function testSwapExactTokensForTokensRevertsWhenToIsAdapter() public {
        IDexAdapter.Route[] memory routes = new IDexAdapter.Route[](1);
        routes[0] = IDexAdapter.Route({from: address(tokenIn), to: address(tokenOut), stable: false, factory: factory});

        tokenIn.mint(alice, 1 ether);
        vm.prank(alice);
        tokenIn.approve(address(adapter), type(uint256).max);

        vm.prank(alice);
        vm.expectRevert(Errors.InvalidRoute.selector);
        adapter.swapExactTokensForTokens(1 ether, 0, routes, address(adapter), block.timestamp + 1);
    }

    function testSwapExactETHForTokensRevertsWhenToIsAdapter() public {
        IDexAdapter.Route[] memory routes = new IDexAdapter.Route[](1);
        routes[0] = IDexAdapter.Route({from: wrappedNative, to: address(tokenOut), stable: false, factory: factory});

        vm.deal(alice, 1 ether);
        vm.prank(alice);
        vm.expectRevert(Errors.InvalidRoute.selector);
        adapter.swapExactETHForTokens{value: 1 ether}(0, routes, address(adapter), block.timestamp + 1);
    }
}
