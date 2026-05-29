// SPDX-License-Identifier: MIT
pragma solidity ^0.8.34;

import {Test} from "forge-std/Test.sol";

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";

import {DexAdapter} from "src/DexAdapter.sol";
import {Errors} from "src/lib/Errors.sol";
import {Events} from "src/lib/Events.sol";

import {MockAerodromeRouter} from "./mocks/MockAerodromeRouter.sol";
import {MockERC20} from "./mocks/MockERC20.sol";

/// @notice Comprehensive rescueToken coverage for DexAdapter.
contract DexAdapterRescueTokenTest is Test {
    MockAerodromeRouter internal router;
    DexAdapter internal adapter;
    MockERC20 internal stuckToken;

    address internal owner = address(0xA11CE);
    address internal alice = address(0xA);
    address internal factory = address(0xFACA);
    address internal wrappedNative = address(0xBEEF);

    function setUp() public {
        vm.etch(factory, hex"00");
        vm.etch(wrappedNative, hex"00");
        router = new MockAerodromeRouter(factory, wrappedNative);
        adapter = new DexAdapter(address(router), owner);
        stuckToken = new MockERC20("Stuck", "STK");
    }

    function testRescueToken_onlyOwner() public {
        stuckToken.mint(address(adapter), 1 ether);

        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, alice));
        adapter.rescueToken(IERC20(address(stuckToken)), owner);
    }

    function testRescueToken_revertsWhenZeroBalance() public {
        vm.prank(owner);
        vm.expectRevert(Errors.AmountZero.selector);
        adapter.rescueToken(IERC20(address(stuckToken)), owner);
    }

    function testRescueToken_revertsWhenToIsZero() public {
        stuckToken.mint(address(adapter), 1 ether);

        vm.prank(owner);
        vm.expectRevert(Errors.ZeroAddress.selector);
        adapter.rescueToken(IERC20(address(stuckToken)), address(0));
    }

    function testRescueToken_revertsWhenToIsSelf() public {
        stuckToken.mint(address(adapter), 1 ether);

        vm.prank(owner);
        vm.expectRevert(Errors.NotAuthorized.selector);
        adapter.rescueToken(IERC20(address(stuckToken)), address(adapter));
    }

    function testRescueToken_revertsWhenToIsRouter() public {
        stuckToken.mint(address(adapter), 1 ether);

        vm.prank(owner);
        vm.expectRevert(Errors.NotAuthorized.selector);
        adapter.rescueToken(IERC20(address(stuckToken)), address(router));
    }

    function testRescueToken_revertsWhenToIsFactory() public {
        stuckToken.mint(address(adapter), 1 ether);

        vm.prank(owner);
        vm.expectRevert(Errors.NotAuthorized.selector);
        adapter.rescueToken(IERC20(address(stuckToken)), factory);
    }

    function testRescueToken_revertsWhenToIsWrappedNative() public {
        stuckToken.mint(address(adapter), 1 ether);

        vm.prank(owner);
        vm.expectRevert(Errors.NotAuthorized.selector);
        adapter.rescueToken(IERC20(address(stuckToken)), wrappedNative);
    }

    function testRescueToken_revertsWhenTokenIsZeroAddress() public {
        vm.prank(owner);
        vm.expectRevert(Errors.ZeroAddress.selector);
        adapter.rescueToken(IERC20(address(0)), owner);
    }

    function testRescueToken_revertsWhenTokenIsNotAContract() public {
        address notAContract = address(0x1234);

        vm.prank(owner);
        vm.expectRevert(Errors.NotAContract.selector);
        adapter.rescueToken(IERC20(notAContract), owner);
    }

    function testRescueToken_sendsFullBalanceToRecipient() public {
        uint256 amount = 5 ether;
        stuckToken.mint(address(adapter), amount);
        assertEq(stuckToken.balanceOf(address(adapter)), amount);

        vm.prank(owner);
        vm.expectEmit(true, true, false, true, address(adapter));
        emit Events.TokenRescued(address(stuckToken), owner, amount);
        adapter.rescueToken(IERC20(address(stuckToken)), owner);

        assertEq(stuckToken.balanceOf(address(adapter)), 0);
        assertEq(stuckToken.balanceOf(owner), amount);
    }

    function testFuzz_RescueToken_sendsExactBalance(uint256 amount) public {
        amount = bound(amount, 1, type(uint128).max);

        stuckToken.mint(address(adapter), amount);

        vm.prank(owner);
        adapter.rescueToken(IERC20(address(stuckToken)), alice);

        assertEq(stuckToken.balanceOf(address(adapter)), 0);
        assertEq(stuckToken.balanceOf(alice), amount);
    }
}
