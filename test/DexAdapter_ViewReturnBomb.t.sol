// SPDX-License-Identifier: MIT
pragma solidity ^0.8.34;

import {Test} from "forge-std/Test.sol";

import {DexAdapter} from "src/DexAdapter.sol";
import {IDexAdapter} from "src/interfaces/IDexAdapter.sol";

import {MockAerodromeRouter} from "./mocks/MockAerodromeRouter.sol";
import {MockERC20} from "./mocks/MockERC20.sol";
import {MockViewReturnToken} from "./mocks/MockViewReturnToken.sol";

/// @notice Ensures DexAdapter does not copy large returndata from ERC20 view calls.
contract DexAdapterViewReturnBombTest is Test {
    MockAerodromeRouter internal router;
    DexAdapter internal adapter;

    MockViewReturnToken internal tokenIn;
    MockERC20 internal tokenOut;

    address internal owner = address(0xA11CE);
    address internal alice = address(0xA);
    address internal bob = address(0xB);

    address internal factory = address(0xFACA);
    address internal wrappedNative = address(0xBEEF);

    function setUp() public {
        tokenIn = new MockViewReturnToken();
        tokenOut = new MockERC20("TokenOut", "TOUT");

        vm.etch(factory, hex"00");
        vm.etch(wrappedNative, hex"00");

        router = new MockAerodromeRouter(factory, wrappedNative);
        router.setRateX18(1e18); // 1:1

        adapter = new DexAdapter(address(router), owner);
    }

    function _route(address from, address to, address fact) internal pure returns (IDexAdapter.Route memory r) {
        r = IDexAdapter.Route({from: from, to: to, stable: false, factory: fact});
    }

    function testSwapExactTokensForTokens_ViewReturnBomb_DoesNotOOG() public {
        IDexAdapter.Route[] memory routes = new IDexAdapter.Route[](1);
        routes[0] = _route(address(tokenIn), address(tokenOut), factory);

        tokenIn.mint(alice, 1 ether);
        vm.prank(alice);
        tokenIn.approve(address(adapter), type(uint256).max);

        // Configure large return buffers on balanceOf + allowance.
        tokenIn.setReturnSize(262_144);
        tokenIn.setBalanceMode(MockViewReturnToken.Mode.ReturnLarge);
        tokenIn.setAllowanceMode(MockViewReturnToken.Mode.ReturnLarge);

        vm.prank(alice);
        (bool ok,) = address(adapter).call{gas: 500_000}(
            abi.encodeWithSelector(
                DexAdapter.swapExactTokensForTokens.selector, 1 ether, 0, routes, bob, block.timestamp + 1
            )
        );

        // The swap reverts because the post-swap balanceOf retention check fails.
        // runs multiple bounded-gas staticcalls that each consume up to 100k gas
        // on the return-bomb token, exhausting the 500k budget before the
        // ReentrancyGuard can reset. The adapter safely reverts — no uncontrolled
        // OOG propagation to the caller. Return-bomb tokens are correctly rejected.
        assertFalse(ok, "swap must revert under gas-constrained return-bomb");

        // State rolled back: alice keeps her tokens, bob receives nothing.
        assertEq(tokenOut.balanceOf(bob), 0);
    }
}
