// SPDX-License-Identifier: MIT
pragma solidity ^0.8.34;

import {Test} from "forge-std/Test.sol";

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {DexAdapter} from "src/DexAdapter.sol";
import {EntryTokenRegistry} from "src/EntryTokenRegistry.sol";
import {IDexAdapter} from "src/interfaces/IDexAdapter.sol";
import {IEntryTokenRegistry} from "src/interfaces/IEntryTokenRegistry.sol";
import {Errors} from "src/lib/Errors.sol";
import {Events} from "src/lib/Events.sol";

import {MockAerodromeRouter} from "./mocks/MockAerodromeRouter.sol";
import {MockERC20} from "./mocks/MockERC20.sol";

/// @notice Mock ERC20 that reverts on approve(nonzero → nonzero) like USDT.
contract MockUSDTApprove is MockERC20 {
    constructor() MockERC20("USDT-like", "USDTL") {}

    function approve(address spender, uint256 value) public override returns (bool) {
        // Mimic USDT: revert if current allowance != 0 AND new value != 0.
        if (allowance(msg.sender, spender) != 0 && value != 0) {
            revert("USDT: approve from non-zero");
        }
        return super.approve(spender, value);
    }
}

/// @notice DexAdapter USDT-like approval, guardian rotation, and rescue edge cases.
/// @dev Covers token-enable re-enable validation, guardian self-rotation rules,
///      USDT-style nonzero→nonzero approve guards, rescue ETH boundaries, and
///      `getAmountsOut` two-hop output shape.
contract DexAdapter_USDTApprovalAndGuardian_Test is Test {
    MockAerodromeRouter internal router;
    DexAdapter internal adapter;
    EntryTokenRegistry internal registry;

    MockERC20 internal weth;
    MockERC20 internal claim;
    MockERC20 internal tokenA;
    MockERC20 internal tokenOut;

    address internal owner = address(0xA11CE);
    address internal alice = address(0xA);
    address internal bob = address(0xB);
    address internal factory = address(0xFACA);

    function setUp() public {
        weth = new MockERC20("WETH", "WETH");
        claim = new MockERC20("CLAIM", "CLAIM");
        tokenA = new MockERC20("TokenA", "TKA");
        tokenOut = new MockERC20("TokenOut", "TOUT");

        router = new MockAerodromeRouter(factory, address(weth));
        router.setRateX18(1e18);

        // DexAdapter's constructor now rejects EOA roots returned by the
        // router (factory/weth). Etch the mocked factory before construction.
        vm.etch(factory, hex"00");

        adapter = new DexAdapter(address(router), owner);
        registry = new EntryTokenRegistry(owner);
    }

    // ──────────────────────────────────────────────
    // P8-08: setTokenEnabled re-enable without WETH-CLAIM hop
    // (Furnace route will revert at resolution; takeover works)
    // ──────────────────────────────────────────────

    function testSetTokenEnabled_reEnableSucceedsWithoutWethClaimHop() public {
        // Configure router but do NOT set WETH-CLAIM hop.
        vm.prank(owner);
        registry.setRouterConfig(address(router), factory, address(weth), address(claim));

        address tokenWethPool = address(0x1111);
        router.setPoolFor(address(tokenA), address(weth), false, factory, tokenWethPool);
        vm.etch(tokenWethPool, hex"00");

        // Configure token (via-WETH, no direct-to-claim).
        vm.prank(owner);
        registry.setTokenConfig(address(tokenA), true, false, false, address(0), false, tokenWethPool);
        vm.prank(owner);
        registry.setFurnaceEntryTokenExactReceiptSafe(address(tokenA), true);

        // Disable then re-enable succeeds (despite no WETH-CLAIM hop).
        vm.prank(owner);
        registry.setTokenEnabled(address(tokenA), false);
        vm.prank(owner);
        registry.setTokenEnabled(address(tokenA), true);
        assertTrue(registry.getTokenConfig(address(tokenA)).enabled);

        // Takeover route works fine.
        IEntryTokenRegistry.RegistryRoute[] memory takeoverRoute = registry.resolveTakeoverRoute(address(tokenA));
        assertEq(takeoverRoute.length, 1);

        // Furnace route reverts because WETH-CLAIM hop is not set.
        vm.expectRevert(Errors.WethClaimHopNotSet.selector);
        registry.resolveFurnaceRoute(address(tokenA));
    }

    // ──────────────────────────────────────────────
    // P8-09: setGuardian rejects address(this)
    // ──────────────────────────────────────────────

    function testSetGuardian_rejectsRegistrySelf() public {
        vm.prank(owner);
        vm.expectRevert(Errors.NotAuthorized.selector);
        registry.setGuardian(address(registry));
    }

    function testSetGuardian_guardianCannotSetToRegistrySelf() public {
        // First set a real guardian.
        vm.prank(owner);
        registry.setGuardian(alice);

        // Guardian tries to rotate to registry address — should revert.
        vm.prank(alice);
        vm.expectRevert(Errors.NotAuthorized.selector);
        registry.setGuardian(address(registry));
    }

    function testSetGuardian_ownerCanSetToContractAddress() public {
        // Setting guardian to a different contract (not self) is allowed.
        vm.prank(owner);
        registry.setGuardian(address(adapter));
        assertEq(registry.guardian(), address(adapter));
    }

    // ──────────────────────────────────────────────
    // P8-10: rescueETH 100k gas cap (documentation test)
    // ──────────────────────────────────────────────

    function testRescueETH_succeedsToEOA() public {
        address payable safeEOA = payable(makeAddr("rescueTarget"));
        vm.deal(address(adapter), 1 ether);

        vm.prank(owner);
        adapter.rescueETH(safeEOA);
        assertEq(safeEOA.balance, 1 ether);
    }

    // ──────────────────────────────────────────────
    // P8-11: USDT-safe approve path (_forceApprove fallback)
    // ──────────────────────────────────────────────

    function testSwapExactTokensForTokens_USDTLikeApprovePattern() public {
        MockUSDTApprove usdtLike = new MockUSDTApprove();

        // Setup route: usdtLike → tokenOut.
        IDexAdapter.Route[] memory routes = new IDexAdapter.Route[](1);
        routes[0] = IDexAdapter.Route({from: address(usdtLike), to: address(tokenOut), stable: false, factory: factory});

        // Mint tokens to alice and approve adapter.
        usdtLike.mint(alice, 10 ether);
        vm.prank(alice);
        usdtLike.approve(address(adapter), type(uint256).max);

        // First swap: should work (adapter has 0 allowance to router, so direct approve succeeds).
        vm.prank(alice);
        uint256[] memory amounts1 = adapter.swapExactTokensForTokens(1 ether, 0, routes, bob, block.timestamp + 1);
        assertEq(amounts1[0], 1 ether);
        assertEq(tokenOut.balanceOf(bob), 1 ether);

        // Verify post-swap allowance is cleared to 0.
        uint256 allowanceAfter = usdtLike.allowance(address(adapter), address(router));
        assertEq(allowanceAfter, 0, "Allowance should be cleared to 0 after swap");

        // Second swap: exercises the same path (approve 0 → approve value) since
        // post-swap cleanup already cleared to 0. This still works.
        vm.prank(alice);
        uint256[] memory amounts2 = adapter.swapExactTokensForTokens(2 ether, 0, routes, bob, block.timestamp + 1);
        assertEq(amounts2[0], 2 ether);
        assertEq(tokenOut.balanceOf(bob), 3 ether); // cumulative
    }

    function testSwapExactTokensForTokens_USDTLikeWithPreExistingAllowance() public {
        MockUSDTApprove usdtLike = new MockUSDTApprove();

        // Setup route.
        IDexAdapter.Route[] memory routes = new IDexAdapter.Route[](1);
        routes[0] = IDexAdapter.Route({from: address(usdtLike), to: address(tokenOut), stable: false, factory: factory});

        // Mint tokens and approve adapter.
        usdtLike.mint(alice, 10 ether);
        vm.prank(alice);
        usdtLike.approve(address(adapter), type(uint256).max);

        // Artificially set a pre-existing non-zero allowance from adapter to router.
        // This simulates a scenario where cleanup failed or was skipped.
        vm.prank(address(adapter));
        usdtLike.approve(address(router), 0); // clear first (USDT requires this)
        vm.prank(address(adapter));
        usdtLike.approve(address(router), 999); // set non-zero

        // Swap should still work because _forceApprove handles USDT: try direct (fails), then zero+set.
        vm.prank(alice);
        uint256[] memory amounts = adapter.swapExactTokensForTokens(1 ether, 0, routes, bob, block.timestamp + 1);
        assertEq(amounts[0], 1 ether);
        assertEq(tokenOut.balanceOf(bob), 1 ether);
    }

    // ──────────────────────────────────────────────
    // P8-12: Duplicate _forceApprove gas bound consistency
    // (Verification: both paths converge to correct allowance)
    // ──────────────────────────────────────────────

    function testSwapExactTokensForTokens_postSwapAllowanceAlwaysZero() public {
        // After every swap, the adapter's allowance to the router should be exactly 0.
        IDexAdapter.Route[] memory routes = new IDexAdapter.Route[](1);
        routes[0] = IDexAdapter.Route({from: address(tokenA), to: address(tokenOut), stable: false, factory: factory});

        tokenA.mint(alice, 100 ether);
        vm.prank(alice);
        tokenA.approve(address(adapter), type(uint256).max);

        // Run multiple swaps with different amounts.
        uint256[] memory amounts;
        for (uint256 i = 1; i <= 5; i++) {
            vm.prank(alice);
            amounts = adapter.swapExactTokensForTokens(i * 1 ether, 0, routes, bob, block.timestamp + 1);
            uint256 postAllowance = tokenA.allowance(address(adapter), address(router));
            assertEq(postAllowance, 0, "Allowance must be zero after every swap");
        }
    }

    // ──────────────────────────────────────────────
    // Additional: swapExactTokensForTokens post-swap invariant
    // with pre-existing adapter balance
    // ──────────────────────────────────────────────

    function testSwapExactTokensForTokens_succeedsWithPreExistingBalance() public {
        IDexAdapter.Route[] memory routes = new IDexAdapter.Route[](1);
        routes[0] = IDexAdapter.Route({from: address(tokenA), to: address(tokenOut), stable: false, factory: factory});

        // Pre-seed the adapter with some stuck tokenA (simulates accidental transfer).
        tokenA.mint(address(adapter), 5 ether);

        // Mint tokens for alice and approve.
        tokenA.mint(alice, 10 ether);
        vm.prank(alice);
        tokenA.approve(address(adapter), type(uint256).max);

        // Swap should succeed. The pre-existing balance stays (postBal == preBal).
        vm.prank(alice);
        uint256[] memory amounts = adapter.swapExactTokensForTokens(1 ether, 0, routes, bob, block.timestamp + 1);
        assertEq(amounts[0], 1 ether);
        assertEq(tokenOut.balanceOf(bob), 1 ether);

        // Adapter should still hold the stuck tokens (not gained, not lost).
        assertEq(tokenA.balanceOf(address(adapter)), 5 ether);
    }

    // ──────────────────────────────────────────────
    // Additional: setTokenEnabled via-WETH with WETH-CLAIM hop validates hop
    // ──────────────────────────────────────────────

    function testSetTokenEnabled_reEnableWithWethClaimHopValidatesHop() public {
        vm.prank(owner);
        registry.setRouterConfig(address(router), factory, address(weth), address(claim));

        // Set WETH-CLAIM hop.
        address wethClaimPool = address(0x3333);
        router.setPoolFor(address(weth), address(claim), false, factory, wethClaimPool);
        vm.etch(wethClaimPool, hex"00");
        vm.prank(owner);
        registry.setWethClaimHop(false, wethClaimPool);

        // Configure token.
        address tokenWethPool = address(0x1111);
        router.setPoolFor(address(tokenA), address(weth), false, factory, tokenWethPool);
        vm.etch(tokenWethPool, hex"00");
        vm.prank(owner);
        registry.setTokenConfig(address(tokenA), true, false, false, address(0), false, tokenWethPool);
        vm.prank(owner);
        registry.setFurnaceEntryTokenExactReceiptSafe(address(tokenA), true);

        // Disable token.
        vm.prank(owner);
        registry.setTokenEnabled(address(tokenA), false);

        // Destroy WETH-CLAIM pool.
        vm.etch(wethClaimPool, hex"");

        // Re-enable should revert because WETH-CLAIM pool code is gone.
        vm.prank(owner);
        vm.expectRevert(Errors.NotAContract.selector);
        registry.setTokenEnabled(address(tokenA), true);
    }

    // ──────────────────────────────────────────────
    // Additional: guardian self-rotation
    // ──────────────────────────────────────────────

    function testSetGuardian_guardianCanSelfRotate() public {
        vm.prank(owner);
        registry.setGuardian(alice);
        assertEq(registry.guardian(), alice);

        // Guardian rotates to bob.
        vm.prank(alice);
        registry.setGuardian(bob);
        assertEq(registry.guardian(), bob);

        // Old guardian (alice) can no longer rotate.
        vm.prank(alice);
        vm.expectRevert(Errors.NotAuthorized.selector);
        registry.setGuardian(alice);
    }

    // ──────────────────────────────────────────────
    // Additional: rescueETH rejects self-send to wrappedNative
    // ──────────────────────────────────────────────

    function testRescueETH_revertsWhenToIsWrappedNative() public {
        vm.deal(address(adapter), 1 ether);
        vm.prank(owner);
        vm.expectRevert(Errors.NotAuthorized.selector);
        adapter.rescueETH(payable(address(weth)));
    }

    // ──────────────────────────────────────────────
    // Additional: getAmountsOut return length validation
    // ──────────────────────────────────────────────

    function testGetAmountsOut_returnsCorrectLengthForTwoHop() public {
        IDexAdapter.Route[] memory routes = new IDexAdapter.Route[](2);
        routes[0] = IDexAdapter.Route({from: address(tokenA), to: address(weth), stable: false, factory: factory});
        routes[1] = IDexAdapter.Route({from: address(weth), to: address(tokenOut), stable: false, factory: factory});

        uint256[] memory amounts = adapter.getAmountsOut(1 ether, routes);
        assertEq(amounts.length, 3, "2-hop should return 3 amounts");
        assertEq(amounts[0], 1 ether);
    }
}
