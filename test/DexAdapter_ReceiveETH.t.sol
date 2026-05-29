// SPDX-License-Identifier: MIT
pragma solidity ^0.8.34;

import {Test} from "forge-std/Test.sol";

import {DexAdapter} from "src/DexAdapter.sol";
import {Errors} from "src/lib/Errors.sol";

import {MockAerodromeRouter} from "./mocks/MockAerodromeRouter.sol";

/// @notice DexAdapter.receive() must only accept ETH from the Aerodrome router.
///         Unrestricted receive() would strand ETH permanently (no sweep surface).
contract DexAdapterReceiveETHTest is Test {
    MockAerodromeRouter internal router;
    DexAdapter internal adapter;

    address internal owner = address(0xA11CE);
    address internal alice = address(0xA);

    function setUp() public {
        address factory = address(0xFACA);
        address wrappedNative = address(0xBEEF);

        vm.etch(factory, hex"00");
        vm.etch(wrappedNative, hex"00");

        router = new MockAerodromeRouter(factory, wrappedNative);
        adapter = new DexAdapter(address(router), owner);
    }

    function testReceiveRevertsFromNonRouter() public {
        vm.deal(alice, 1 ether);
        vm.prank(alice);
        vm.expectRevert(Errors.NotAuthorized.selector);
        (bool ok,) = address(adapter).call{value: 1 ether}("");
        // expectRevert checks above; ok is always true after expectRevert
        ok; // silence unused variable warning
    }

    function testReceiveAcceptsFromRouter() public {
        vm.deal(address(router), 1 ether);
        vm.prank(address(router));
        (bool ok,) = address(adapter).call{value: 1 ether}("");
        assertTrue(ok, "adapter must accept ETH from the underlying router");
    }
}
