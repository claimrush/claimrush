// SPDX-License-Identifier: MIT
pragma solidity ^0.8.34;

import {Test} from "forge-std/Test.sol";

import {DexAdapter} from "src/DexAdapter.sol";
import {IDexAdapter} from "src/interfaces/IDexAdapter.sol";
import {Errors} from "src/lib/Errors.sol";

import {MockAerodromeRouter} from "./mocks/MockAerodromeRouter.sol";

contract DexAdapterRescueETHTest is Test {
    MockAerodromeRouter internal router;
    DexAdapter internal adapter;

    address internal owner = address(0xA11CE);
    address internal alice = address(0xA);

    function setUp() public {
        vm.etch(address(0xFACA), hex"00");
        vm.etch(address(0xBEEF), hex"00");
        router = new MockAerodromeRouter(address(0xFACA), address(0xBEEF));
        adapter = new DexAdapter(address(router), owner);
    }

    function testRescueETH_onlyOwner() public {
        vm.deal(address(adapter), 1 ether);

        vm.prank(alice);
        vm.expectRevert();
        adapter.rescueETH(payable(owner));
    }

    function testRescueETH_revertsWhenEmpty() public {
        vm.prank(owner);
        vm.expectRevert(Errors.AmountZero.selector);
        adapter.rescueETH(payable(owner));
    }

    function testRescueETH_sendsBalanceToOwner() public {
        vm.deal(address(adapter), 2 ether);
        uint256 ownerBefore = owner.balance;

        vm.prank(owner);
        adapter.rescueETH(payable(owner));

        assertEq(address(adapter).balance, 0);
        assertEq(owner.balance, ownerBefore + 2 ether);
    }
}
