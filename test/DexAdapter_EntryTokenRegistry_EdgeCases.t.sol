// SPDX-License-Identifier: MIT
pragma solidity ^0.8.34;

import {Test} from "forge-std/Test.sol";

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";

import {DexAdapter} from "src/DexAdapter.sol";
import {EntryTokenRegistry} from "src/EntryTokenRegistry.sol";
import {IDexAdapter} from "src/interfaces/IDexAdapter.sol";
import {IEntryTokenRegistry} from "src/interfaces/IEntryTokenRegistry.sol";
import {Errors} from "src/lib/Errors.sol";
import {Events} from "src/lib/Events.sol";

import {MockAerodromeRouter} from "./mocks/MockAerodromeRouter.sol";
import {MockERC20} from "./mocks/MockERC20.sol";

/// @notice DexAdapter and EntryTokenRegistry edge cases.
/// @dev Covers DexAdapter pool-validation, swap recipient guards, ownership
///      hardening, and EntryTokenRegistry re-enable validation paths.
contract DexAdapter_EntryTokenRegistry_EdgeCases_Test is Test {
    // ──────────────────────────────────────────────
    // Shared state
    // ──────────────────────────────────────────────
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
        // router (factory/weth). The factory address is mocked, so etch
        // before constructing the adapter.
        vm.etch(factory, hex"00");

        adapter = new DexAdapter(address(router), owner);
        registry = new EntryTokenRegistry(owner);
    }

    // ──────────────────────────────────────────────
    // P8-01: DexAdapter.poolFor rejects factory-as-token
    // ──────────────────────────────────────────────

    function testPoolFor_revertsWhenTokenAIsFactory() public {
        vm.expectRevert(Errors.InvalidRoute.selector);
        adapter.poolFor(factory, address(tokenA), false, factory);
    }

    function testPoolFor_revertsWhenTokenBIsFactory() public {
        vm.expectRevert(Errors.InvalidRoute.selector);
        adapter.poolFor(address(tokenA), factory, false, factory);
    }

    // ──────────────────────────────────────────────
    // P8-02: EntryTokenRegistry constructor emits GuardianChanged
    // ──────────────────────────────────────────────

    function testConstructor_emitsGuardianChanged() public {
        vm.expectEmit(true, true, false, false);
        emit Events.GuardianChanged(address(0), owner);
        new EntryTokenRegistry(owner);
    }

    // ──────────────────────────────────────────────
    // P8-04: renounceOwnership always reverts (both contracts)
    // ──────────────────────────────────────────────

    function testDexAdapter_renounceOwnershipReverts() public {
        vm.prank(owner);
        vm.expectRevert(Errors.NotAuthorized.selector);
        adapter.renounceOwnership();
    }

    function testDexAdapter_renounceOwnershipRevertsFromAnyone() public {
        vm.prank(alice);
        vm.expectRevert(Errors.NotAuthorized.selector);
        adapter.renounceOwnership();
    }

    function testEntryTokenRegistry_renounceOwnershipReverts() public {
        vm.prank(owner);
        vm.expectRevert(Errors.NotAuthorized.selector);
        registry.renounceOwnership();
    }

    function testEntryTokenRegistry_renounceOwnershipRevertsFromAnyone() public {
        vm.prank(alice);
        vm.expectRevert(Errors.NotAuthorized.selector);
        registry.renounceOwnership();
    }

    // ──────────────────────────────────────────────
    // P8-05: 2-hop swapExactETHForTokens
    // ──────────────────────────────────────────────

    function testSwapExactETHForTokens_twoHop() public {
        address mid = address(tokenA);
        IDexAdapter.Route[] memory routes = new IDexAdapter.Route[](2);
        routes[0] = IDexAdapter.Route({from: address(weth), to: mid, stable: false, factory: factory});
        routes[1] = IDexAdapter.Route({from: mid, to: address(tokenOut), stable: false, factory: factory});

        vm.etch(address(weth), hex"00");
        vm.deal(alice, 1 ether);
        vm.prank(alice);
        uint256[] memory amts = adapter.swapExactETHForTokens{value: 1 ether}(0, routes, bob, block.timestamp + 1);

        assertEq(amts.length, 3, "2-hop should return 3 amounts");
        assertEq(amts[0], 1 ether);
        assertEq(tokenOut.balanceOf(bob), 1 ether, "bob should receive output at 1:1 rate");
    }

    // ──────────────────────────────────────────────
    // P8-06: setTokenEnabled re-enable rejects destroyed pool
    // ──────────────────────────────────────────────

    function testSetTokenEnabled_reEnableRejectsDestroyedPool() public {
        // Setup registry with router config.
        vm.prank(owner);
        registry.setRouterConfig(address(router), factory, address(weth), address(claim));

        // Configure and enable a token.
        address tokenWethPool = address(0x1111);
        router.setPoolFor(address(tokenA), address(weth), false, factory, tokenWethPool);
        vm.etch(tokenWethPool, hex"00");

        vm.prank(owner);
        registry.setTokenConfig(address(tokenA), true, false, false, address(0), false, tokenWethPool);

        // Disable the token.
        vm.prank(owner);
        registry.setTokenEnabled(address(tokenA), false);
        assertFalse(registry.getTokenConfig(address(tokenA)).enabled);

        // Simulate pool destruction (remove code).
        vm.etch(tokenWethPool, hex"");

        // Re-enable should revert because the pool no longer has code.
        vm.prank(owner);
        vm.expectRevert(Errors.NotAContract.selector);
        registry.setTokenEnabled(address(tokenA), true);
    }

    function testSetTokenEnabled_reEnableRevalidatesPoolFor() public {
        // Setup registry with router config.
        vm.prank(owner);
        registry.setRouterConfig(address(router), factory, address(weth), address(claim));

        // Configure and enable a token.
        address tokenWethPool = address(0x1111);
        router.setPoolFor(address(tokenA), address(weth), false, factory, tokenWethPool);
        vm.etch(tokenWethPool, hex"00");

        vm.prank(owner);
        registry.setTokenConfig(address(tokenA), true, false, false, address(0), false, tokenWethPool);

        // Disable the token.
        vm.prank(owner);
        registry.setTokenEnabled(address(tokenA), false);

        // Change the poolFor mapping (simulates the DEX returning a different pool).
        address newPool = address(0x2222);
        vm.etch(newPool, hex"00");
        router.setPoolFor(address(tokenA), address(weth), false, factory, newPool);

        // Re-enable should revert because poolFor no longer matches stored pool.
        vm.prank(owner);
        vm.expectRevert(Errors.InvalidPool.selector);
        registry.setTokenEnabled(address(tokenA), true);
    }

    // ──────────────────────────────────────────────
    // P8-07: Swap to-address guards (router, factory, wrappedNative)
    // ──────────────────────────────────────────────

    function testSwapExactTokensForTokens_revertsWhenToIsRouter() public {
        IDexAdapter.Route[] memory routes = new IDexAdapter.Route[](1);
        routes[0] = IDexAdapter.Route({from: address(tokenA), to: address(tokenOut), stable: false, factory: factory});

        tokenA.mint(alice, 1 ether);
        vm.prank(alice);
        tokenA.approve(address(adapter), type(uint256).max);

        vm.prank(alice);
        vm.expectRevert(Errors.InvalidRoute.selector);
        adapter.swapExactTokensForTokens(1 ether, 0, routes, address(router), block.timestamp + 1);
    }

    function testSwapExactTokensForTokens_revertsWhenToIsFactory() public {
        IDexAdapter.Route[] memory routes = new IDexAdapter.Route[](1);
        routes[0] = IDexAdapter.Route({from: address(tokenA), to: address(tokenOut), stable: false, factory: factory});

        tokenA.mint(alice, 1 ether);
        vm.prank(alice);
        tokenA.approve(address(adapter), type(uint256).max);

        vm.prank(alice);
        vm.expectRevert(Errors.InvalidRoute.selector);
        adapter.swapExactTokensForTokens(1 ether, 0, routes, factory, block.timestamp + 1);
    }

    function testSwapExactTokensForTokens_revertsWhenToIsWrappedNative() public {
        IDexAdapter.Route[] memory routes = new IDexAdapter.Route[](1);
        routes[0] = IDexAdapter.Route({from: address(tokenA), to: address(tokenOut), stable: false, factory: factory});

        tokenA.mint(alice, 1 ether);
        vm.prank(alice);
        tokenA.approve(address(adapter), type(uint256).max);

        vm.prank(alice);
        vm.expectRevert(Errors.InvalidRoute.selector);
        adapter.swapExactTokensForTokens(1 ether, 0, routes, address(weth), block.timestamp + 1);
    }

    function testSwapExactETHForTokens_revertsWhenToIsRouter() public {
        IDexAdapter.Route[] memory routes = new IDexAdapter.Route[](1);
        routes[0] = IDexAdapter.Route({from: address(weth), to: address(tokenOut), stable: false, factory: factory});

        vm.etch(address(weth), hex"00");
        vm.deal(alice, 1 ether);
        vm.prank(alice);
        vm.expectRevert(Errors.InvalidRoute.selector);
        adapter.swapExactETHForTokens{value: 1 ether}(0, routes, address(router), block.timestamp + 1);
    }

    function testSwapExactETHForTokens_revertsWhenToIsFactory() public {
        IDexAdapter.Route[] memory routes = new IDexAdapter.Route[](1);
        routes[0] = IDexAdapter.Route({from: address(weth), to: address(tokenOut), stable: false, factory: factory});

        vm.etch(address(weth), hex"00");
        vm.deal(alice, 1 ether);
        vm.prank(alice);
        vm.expectRevert(Errors.InvalidRoute.selector);
        adapter.swapExactETHForTokens{value: 1 ether}(0, routes, factory, block.timestamp + 1);
    }

    function testSwapExactETHForTokens_revertsWhenToIsWrappedNative() public {
        IDexAdapter.Route[] memory routes = new IDexAdapter.Route[](1);
        routes[0] = IDexAdapter.Route({from: address(weth), to: address(tokenOut), stable: false, factory: factory});

        vm.etch(address(weth), hex"00");
        vm.deal(alice, 1 ether);
        vm.prank(alice);
        vm.expectRevert(Errors.InvalidRoute.selector);
        adapter.swapExactETHForTokens{value: 1 ether}(0, routes, address(weth), block.timestamp + 1);
    }

    // ──────────────────────────────────────────────
    // Additional: setTokenEnabled re-enable with directToClaim validates CLAIM pool
    // ──────────────────────────────────────────────

    function testSetTokenEnabled_reEnableWithDirectToClaimValidatesClaimPool() public {
        vm.prank(owner);
        registry.setRouterConfig(address(router), factory, address(weth), address(claim));

        address tokenWethPool = address(0x1111);
        address tokenClaimPool = address(0x2222);
        router.setPoolFor(address(tokenA), address(weth), false, factory, tokenWethPool);
        router.setPoolFor(address(tokenA), address(claim), true, factory, tokenClaimPool);
        vm.etch(tokenWethPool, hex"00");
        vm.etch(tokenClaimPool, hex"00");

        vm.prank(owner);
        registry.setTokenConfig(address(tokenA), true, true, true, tokenClaimPool, false, tokenWethPool);

        // Disable.
        vm.prank(owner);
        registry.setTokenEnabled(address(tokenA), false);

        // Destroy claim pool.
        vm.etch(tokenClaimPool, hex"");

        // Re-enable should revert.
        vm.prank(owner);
        vm.expectRevert(Errors.NotAContract.selector);
        registry.setTokenEnabled(address(tokenA), true);
    }

    // ──────────────────────────────────────────────
    // Additional: EntryTokenRegistry setTokenConfig rejects self, router, factory
    // ──────────────────────────────────────────────

    function testSetTokenConfig_rejectsRegistryAddressAsToken() public {
        vm.prank(owner);
        registry.setRouterConfig(address(router), factory, address(weth), address(claim));

        vm.prank(owner);
        vm.expectRevert(Errors.InvalidToken.selector);
        registry.setTokenConfig(address(registry), true, false, false, address(0), false, address(0x1111));
    }

    function testSetTokenConfig_rejectsRouterAsToken() public {
        vm.prank(owner);
        registry.setRouterConfig(address(router), factory, address(weth), address(claim));

        vm.prank(owner);
        vm.expectRevert(Errors.InvalidToken.selector);
        registry.setTokenConfig(address(router), true, false, false, address(0), false, address(0x1111));
    }

    function testSetTokenConfig_rejectsFactoryAsToken() public {
        vm.prank(owner);
        registry.setRouterConfig(address(router), factory, address(weth), address(claim));

        vm.prank(owner);
        vm.expectRevert(Errors.InvalidToken.selector);
        registry.setTokenConfig(factory, true, false, false, address(0), false, address(0x1111));
    }

    // ──────────────────────────────────────────────
    // Additional: setTokenEnabled rejects forbidden tokenIn addresses
    // ──────────────────────────────────────────────

    function testSetTokenEnabled_rejectsClaimToken() public {
        vm.prank(owner);
        registry.setRouterConfig(address(router), factory, address(weth), address(claim));

        vm.prank(owner);
        vm.expectRevert(Errors.InvalidToken.selector);
        registry.setTokenEnabled(address(claim), false);
    }

    function testSetTokenEnabled_rejectsWrappedNative() public {
        vm.prank(owner);
        registry.setRouterConfig(address(router), factory, address(weth), address(claim));

        vm.prank(owner);
        vm.expectRevert(Errors.InvalidToken.selector);
        registry.setTokenEnabled(address(weth), false);
    }

    function testSetTokenEnabled_rejectsRegistrySelf() public {
        vm.prank(owner);
        registry.setRouterConfig(address(router), factory, address(weth), address(claim));

        vm.prank(owner);
        vm.expectRevert(Errors.InvalidToken.selector);
        registry.setTokenEnabled(address(registry), false);
    }

    // ──────────────────────────────────────────────
    // Additional: resolve route rejects forbidden tokenIn
    // ──────────────────────────────────────────────

    function testResolveFurnaceRoute_rejectsZeroAddress() public {
        vm.prank(owner);
        registry.setRouterConfig(address(router), factory, address(weth), address(claim));

        vm.expectRevert(Errors.ZeroAddress.selector);
        registry.resolveFurnaceRoute(address(0));
    }

    function testResolveTakeoverRoute_rejectsZeroAddress() public {
        vm.prank(owner);
        registry.setRouterConfig(address(router), factory, address(weth), address(claim));

        vm.expectRevert(Errors.ZeroAddress.selector);
        registry.resolveTakeoverRoute(address(0));
    }

    function testResolveFurnaceRoute_rejectsClaim() public {
        vm.prank(owner);
        registry.setRouterConfig(address(router), factory, address(weth), address(claim));

        vm.expectRevert(Errors.InvalidToken.selector);
        registry.resolveFurnaceRoute(address(claim));
    }

    function testResolveTakeoverRoute_rejectsClaim() public {
        vm.prank(owner);
        registry.setRouterConfig(address(router), factory, address(weth), address(claim));

        vm.expectRevert(Errors.InvalidToken.selector);
        registry.resolveTakeoverRoute(address(claim));
    }

    function testResolveFurnaceRoute_rejectsWrappedNative() public {
        vm.prank(owner);
        registry.setRouterConfig(address(router), factory, address(weth), address(claim));

        vm.expectRevert(Errors.InvalidToken.selector);
        registry.resolveFurnaceRoute(address(weth));
    }

    function testResolveFurnaceRoute_rejectsEOA() public {
        vm.prank(owner);
        registry.setRouterConfig(address(router), factory, address(weth), address(claim));

        address eoa = address(0xDEAD);
        vm.expectRevert(Errors.NotAContract.selector);
        registry.resolveFurnaceRoute(eoa);
    }

    function testResolveTakeoverRoute_rejectsEOA() public {
        vm.prank(owner);
        registry.setRouterConfig(address(router), factory, address(weth), address(claim));

        address eoa = address(0xDEAD);
        vm.expectRevert(Errors.NotAContract.selector);
        registry.resolveTakeoverRoute(eoa);
    }

    // ──────────────────────────────────────────────
    // Additional: guardian rotation edge cases
    // ──────────────────────────────────────────────

    function testSetGuardian_rejectsZeroAddress() public {
        vm.prank(owner);
        vm.expectRevert(Errors.ZeroAddress.selector);
        registry.setGuardian(address(0));
    }

    function testSetGuardian_rejectsUnauthorizedCaller() public {
        vm.prank(alice);
        vm.expectRevert(Errors.NotAuthorized.selector);
        registry.setGuardian(alice);
    }

    // ──────────────────────────────────────────────
    // Additional: DexAdapter.getAmountsOut rejects amountIn == 0
    // ──────────────────────────────────────────────

    function testGetAmountsOut_revertsOnZeroAmount() public {
        IDexAdapter.Route[] memory routes = new IDexAdapter.Route[](1);
        routes[0] = IDexAdapter.Route({from: address(tokenA), to: address(tokenOut), stable: false, factory: factory});

        vm.expectRevert(Errors.AmountZero.selector);
        adapter.getAmountsOut(0, routes);
    }

    // ──────────────────────────────────────────────
    // Additional: DexAdapter.poolFor rejects same token pair
    // ──────────────────────────────────────────────

    function testPoolFor_rejectsSameToken() public {
        vm.expectRevert(Errors.InvalidRoute.selector);
        adapter.poolFor(address(tokenA), address(tokenA), false, factory);
    }

    function testPoolFor_rejectsWrongFactory() public {
        vm.expectRevert(Errors.InvalidRoute.selector);
        adapter.poolFor(address(tokenA), address(tokenOut), false, address(0xBAD));
    }

    function testPoolFor_rejectsAdapterAsToken() public {
        vm.expectRevert(Errors.InvalidRoute.selector);
        adapter.poolFor(address(adapter), address(tokenOut), false, factory);
    }

    function testPoolFor_rejectsRouterAsToken() public {
        vm.expectRevert(Errors.InvalidRoute.selector);
        adapter.poolFor(address(router), address(tokenOut), false, factory);
    }
}
