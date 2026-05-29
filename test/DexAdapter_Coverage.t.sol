// SPDX-License-Identifier: MIT
pragma solidity ^0.8.34;

import {Test} from "forge-std/Test.sol";

import {DexAdapter} from "src/DexAdapter.sol";
import {IDexAdapter} from "src/interfaces/IDexAdapter.sol";

import {Errors} from "src/lib/Errors.sol";

import {MockAerodromeRouter} from "./mocks/MockAerodromeRouter.sol";
import {MockERC20} from "./mocks/MockERC20.sol";

// ---------------------------------------------------------------------------
// Test-only mocks (scoped to this file)
// ---------------------------------------------------------------------------

/// @notice Router that does NOT pull input tokens from the adapter during token swaps.
/// @dev Simulates a misbehaving or compromised router that completes without transferring
///      the full amountIn, leaving tokens stranded in the adapter.
contract MockNoPullRouter is MockAerodromeRouter {
    constructor(address f, address w) MockAerodromeRouter(f, w) {}

    function swapExactTokensForTokens(
        uint256 amountIn,
        uint256 amountOutMin,
        Route[] calldata routes,
        address to,
        uint256 deadline
    ) external override returns (uint256[] memory amounts) {
        lastAmountIn = amountIn;
        lastAmountOutMin = amountOutMin;
        lastTo = to;
        lastDeadline = deadline;
        lastRoutesHash = keccak256(abi.encode(routes));

        // Intentionally skip pulling tokens from the adapter.
        // Return amounts as if swap completed normally.
        amounts = this.getAmountsOut(amountIn, routes);
        uint256 out = amounts[amounts.length - 1];

        // Mint output token to recipient.
        Route memory last = routes[routes.length - 1];
        MockERC20(last.to).mint(to, out);
    }
}

/// @notice Router that sends back a partial ETH refund during swapExactETHForTokens.
/// @dev Used to exercise the adapter's ETH refund path and reentrancy guard.
contract MockRefundRouter is MockAerodromeRouter {
    uint256 public refundAmount;

    constructor(address f, address w) MockAerodromeRouter(f, w) {}

    function setRefundAmount(uint256 amt) external {
        refundAmount = amt;
    }

    function swapExactETHForTokens(uint256 amountOutMin, Route[] calldata routes, address to, uint256 deadline)
        external
        payable
        override
        returns (uint256[] memory amounts)
    {
        lastEthValue = msg.value;
        lastAmountOutMin = amountOutMin;
        lastTo = to;
        lastDeadline = deadline;
        lastRoutesHash = keccak256(abi.encode(routes));

        amounts = this.getAmountsOut(msg.value, routes);
        uint256 out = amounts[amounts.length - 1];

        // Mint output token to `to`.
        Route memory last = routes[routes.length - 1];
        MockERC20(last.to).mint(to, out);

        // Send ETH refund back to adapter (adapter's receive() accepts from router).
        if (refundAmount > 0 && refundAmount <= address(this).balance) {
            (bool ok,) = msg.sender.call{value: refundAmount}("");
            require(ok, "MockRefundRouter: refund failed");
        }
    }
}

/// @notice Contract that attempts to re-enter DexAdapter when it receives an ETH refund.
/// @dev Proves the nonReentrant modifier blocks reentrancy during the refund path.
contract ReentrantSwapper {
    DexAdapter public immutable adapter;
    address public immutable wrappedNative;
    address public immutable tokenOutAddr;
    address public immutable factoryAddr;

    bool public attacked;
    bool public reentrancyBlocked;

    constructor(DexAdapter a, address wn, address tout, address f) {
        adapter = a;
        wrappedNative = wn;
        tokenOutAddr = tout;
        factoryAddr = f;
    }

    function doSwapETH(address to, uint256 deadline) external payable {
        IDexAdapter.Route[] memory routes = new IDexAdapter.Route[](1);
        routes[0] = IDexAdapter.Route({from: wrappedNative, to: tokenOutAddr, stable: false, factory: factoryAddr});
        adapter.swapExactETHForTokens{value: msg.value}(0, routes, to, deadline);
    }

    receive() external payable {
        if (!attacked) {
            attacked = true;
            // Attempt re-entry into DexAdapter during ETH refund.
            IDexAdapter.Route[] memory routes = new IDexAdapter.Route[](1);
            routes[0] = IDexAdapter.Route({from: wrappedNative, to: tokenOutAddr, stable: false, factory: factoryAddr});
            try adapter.swapExactETHForTokens{value: msg.value}(0, routes, address(0xBBB), block.timestamp + 100) {
            // Should never succeed — reentrancy guard must block.
            }
            catch {
                reentrancyBlocked = true;
            }
        }
    }
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

/// @notice Coverage tests for DexAdapter route validation, token-retention checks, and refund-path reentrancy protection.
/// @dev Tests:
///      1. Explicit 3-hop route rejection
///      2. Post-swap balance invariant catches token retention
///      3. Reentrancy guard blocks re-entry during ETH refund
contract DexAdapterCoverageTest is Test {
    MockAerodromeRouter internal router;
    DexAdapter internal adapter;

    MockERC20 internal tokenIn;
    MockERC20 internal tokenOut;
    MockERC20 internal tokenMid;

    address internal owner = address(0xA11CE);
    address internal alice = address(0xA);
    address internal bob = address(0xB);
    address internal factory = address(0xFACA);
    address internal wrappedNative = address(0xBEEF);

    function setUp() public {
        tokenIn = new MockERC20("TokenIn", "TIN");
        tokenOut = new MockERC20("TokenOut", "TOUT");
        tokenMid = new MockERC20("TokenMid", "TMID");

        vm.etch(factory, hex"00");
        vm.etch(wrappedNative, hex"00");

        router = new MockAerodromeRouter(factory, wrappedNative);
        router.setRateX18(1e18);

        adapter = new DexAdapter(address(router), owner);
    }

    function _route(address from, address to, address fact) internal pure returns (IDexAdapter.Route memory) {
        return IDexAdapter.Route({from: from, to: to, stable: false, factory: fact});
    }

    // -----------------------------------------------------------------------
    // Explicit 3-hop route rejection
    // -----------------------------------------------------------------------

    /// @notice _validateRoutes MUST reject routes with more than 2 hops.
    function testSwapExactTokensForTokensRevertsOnThreeHopRoute() public {
        IDexAdapter.Route[] memory routes = new IDexAdapter.Route[](3);
        routes[0] = _route(address(tokenIn), address(tokenMid), factory);
        routes[1] = _route(address(tokenMid), address(tokenOut), factory);
        routes[2] = _route(address(tokenOut), address(tokenIn), factory);

        tokenIn.mint(alice, 1 ether);
        vm.prank(alice);
        tokenIn.approve(address(adapter), type(uint256).max);

        vm.prank(alice);
        vm.expectRevert(Errors.InvalidRoute.selector);
        adapter.swapExactTokensForTokens(1 ether, 0, routes, bob, block.timestamp + 1);
    }

    /// @notice Same invariant for ETH swap entry point.
    function testSwapExactETHForTokensRevertsOnThreeHopRoute() public {
        vm.etch(wrappedNative, hex"00");

        IDexAdapter.Route[] memory routes = new IDexAdapter.Route[](3);
        routes[0] = _route(wrappedNative, address(tokenMid), factory);
        routes[1] = _route(address(tokenMid), address(tokenOut), factory);
        routes[2] = _route(address(tokenOut), address(tokenIn), factory);

        vm.deal(alice, 1 ether);
        vm.prank(alice);
        vm.expectRevert(Errors.InvalidRoute.selector);
        adapter.swapExactETHForTokens{value: 1 ether}(0, routes, bob, block.timestamp + 1);
    }

    /// @notice Same invariant for the view-only quote function.
    function testGetAmountsOutRevertsOnThreeHopRoute() public {
        IDexAdapter.Route[] memory routes = new IDexAdapter.Route[](3);
        routes[0] = _route(address(tokenIn), address(tokenMid), factory);
        routes[1] = _route(address(tokenMid), address(tokenOut), factory);
        routes[2] = _route(address(tokenOut), address(tokenIn), factory);

        vm.expectRevert(Errors.InvalidRoute.selector);
        adapter.getAmountsOut(1 ether, routes);
    }

    // -----------------------------------------------------------------------
    // Post-swap balance invariant: adapter MUST NOT retain input tokens
    // -----------------------------------------------------------------------

    /// @notice If the router fails to pull input tokens, the post-swap balance check
    ///         detects the retention and reverts with InvariantViolation.
    function testSwapRevertsWhenAdapterRetainsInputTokens() public {
        // Deploy adapter backed by a router that skips the token pull.
        MockNoPullRouter noPullRouter = new MockNoPullRouter(factory, wrappedNative);
        noPullRouter.setRateX18(1e18);
        DexAdapter noPullAdapter = new DexAdapter(address(noPullRouter), owner);

        IDexAdapter.Route[] memory routes = new IDexAdapter.Route[](1);
        routes[0] = _route(address(tokenIn), address(tokenOut), factory);

        tokenIn.mint(alice, 1 ether);
        vm.prank(alice);
        tokenIn.approve(address(noPullAdapter), type(uint256).max);

        // transferFrom pulls 1 ether into the adapter, but the router never claims it.
        // Post-swap: adapter holds 1 ether of tokenIn (> preBal of 0) → InvariantViolation.
        vm.prank(alice);
        vm.expectRevert(Errors.InvariantViolation.selector);
        noPullAdapter.swapExactTokensForTokens(1 ether, 0, routes, bob, block.timestamp + 1);
    }

    // -----------------------------------------------------------------------
    // Reentrancy: nonReentrant blocks re-entry during ETH refund
    // -----------------------------------------------------------------------

    /// @notice Proves the nonReentrant modifier blocks a contract that attempts to
    ///         re-enter DexAdapter from its receive() callback during the ETH refund.
    function testReentrancyBlockedDuringETHRefund() public {
        // Deploy a router that refunds 0.1 ETH back to the adapter after swapping.
        MockRefundRouter refundRouter = new MockRefundRouter(factory, wrappedNative);
        refundRouter.setRateX18(1e18);
        refundRouter.setRefundAmount(0.1 ether);

        DexAdapter refundAdapter = new DexAdapter(address(refundRouter), owner);

        vm.etch(wrappedNative, hex"00");

        // Deploy a caller contract that will attempt re-entry from receive().
        ReentrantSwapper swapper = new ReentrantSwapper(refundAdapter, wrappedNative, address(tokenOut), factory);

        vm.deal(address(this), 1 ether);

        // Execute swap: adapter forwards 1 ETH → router refunds 0.1 ETH → adapter
        // forwards refund to swapper → swapper.receive() fires and attempts re-entry.
        swapper.doSwapETH{value: 1 ether}(bob, block.timestamp + 1);

        // The outer swap completed, but the reentrancy attempt was blocked.
        assertTrue(swapper.attacked(), "receive() should have fired");
        assertTrue(swapper.reentrancyBlocked(), "Re-entry should have been blocked by nonReentrant");

        // Output still delivered correctly despite the reentrancy attempt.
        assertEq(tokenOut.balanceOf(bob), 1 ether);
    }
}
