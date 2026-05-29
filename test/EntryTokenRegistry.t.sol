// SPDX-License-Identifier: MIT
pragma solidity ^0.8.34;

import {Test} from "forge-std/Test.sol";

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";

import {EntryTokenRegistry} from "src/EntryTokenRegistry.sol";
import {IEntryTokenRegistry} from "src/interfaces/IEntryTokenRegistry.sol";
import {Errors} from "src/lib/Errors.sol";

import {MockAerodromeRouter} from "./mocks/MockAerodromeRouter.sol";
import {MockERC20} from "./mocks/MockERC20.sol";

contract EntryTokenRegistryTest is Test {
    EntryTokenRegistry internal registry;
    MockAerodromeRouter internal router;

    MockERC20 internal weth;
    MockERC20 internal claim;
    MockERC20 internal tokenA;

    address internal owner = address(0xA11CE);
    address internal alice = address(0xA);
    address internal factory = address(0xFACA);

    function setUp() public {
        registry = new EntryTokenRegistry(owner);

        weth = new MockERC20("WETH", "WETH");
        claim = new MockERC20("CLAIM", "CLAIM");
        tokenA = new MockERC20("TokenA", "TKA");

        router = new MockAerodromeRouter(factory, address(weth));

        // factory is a bare address (0xFACA); give it bytecode so it passes NotAContract checks.
        vm.etch(factory, hex"00");
    }

    function _setRouterConfig() internal {
        vm.prank(owner);
        registry.setRouterConfig(address(router), factory, address(weth), address(claim));
    }

    function _deployPool(address pool) internal {
        vm.etch(pool, hex"00");
    }

    function _etch7702(address target, address delegate) internal {
        vm.etch(target, abi.encodePacked(hex"ef0100", delegate));
        assertEq(target.code.length, 23, "7702 designator must be exactly 23 bytes");
    }

    function _setFurnaceSafe(address token) internal {
        vm.prank(owner);
        registry.setFurnaceEntryTokenExactReceiptSafe(token, true);
    }

    function testSetRouterConfigOnlyOwner() public {
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, alice));
        registry.setRouterConfig(address(router), factory, address(weth), address(claim));
    }

    function testSetRouterConfigRejectsZeroAddresses() public {
        vm.prank(owner);
        vm.expectRevert(Errors.ZeroAddress.selector);
        registry.setRouterConfig(address(0), factory, address(weth), address(claim));

        vm.prank(owner);
        vm.expectRevert(Errors.ZeroAddress.selector);
        registry.setRouterConfig(address(router), address(0), address(weth), address(claim));

        vm.prank(owner);
        vm.expectRevert(Errors.ZeroAddress.selector);
        registry.setRouterConfig(address(router), factory, address(0), address(claim));

        vm.prank(owner);
        vm.expectRevert(Errors.ZeroAddress.selector);
        registry.setRouterConfig(address(router), factory, address(weth), address(0));
    }

    function testSetRouterConfigValidatesFactoryAndWrappedNative() public {
        // Give 0xBEEF bytecode so it passes the NotAContract gate;
        // we are testing FactoryMismatch / WrappedNativeMismatch, not NotAContract.
        vm.etch(address(0xBEEF), hex"00");

        // Wrong factory.
        vm.prank(owner);
        vm.expectRevert(Errors.FactoryMismatch.selector);
        registry.setRouterConfig(address(router), address(0xBEEF), address(weth), address(claim));

        // Wrong wrapped native.
        vm.prank(owner);
        vm.expectRevert(Errors.WrappedNativeMismatch.selector);
        registry.setRouterConfig(address(router), factory, address(0xBEEF), address(claim));

        // Correct.
        _setRouterConfig();

        (address r, address f, address wn, address c) = registry.getRouterConfig();
        assertEq(r, address(router));
        assertEq(f, factory);
        assertEq(wn, address(weth));
        assertEq(c, address(claim));
    }

    function testSetRouterConfigRejectsDelegatedEOARoots() public {
        address delegatedFactory = address(0x77020001);
        _etch7702(delegatedFactory, address(this));

        vm.prank(owner);
        vm.expectRevert(Errors.DelegatedEOA.selector);
        registry.setRouterConfig(address(router), delegatedFactory, address(weth), address(claim));
    }

    function testSetWethClaimHopRequiresRouterConfigAndValidatesPool() public {
        vm.prank(owner);
        vm.expectRevert(Errors.RouterConfigNotSet.selector);
        registry.setWethClaimHop(true, address(0xBEEF));

        _setRouterConfig();

        vm.prank(owner);
        vm.expectRevert(Errors.ZeroAddress.selector);
        registry.setWethClaimHop(false, address(0));

        // Pool mismatch.
        router.setPoolFor(address(weth), address(claim), false, factory, address(0x1111));
        vm.prank(owner);
        vm.expectRevert(Errors.InvalidPool.selector);
        registry.setWethClaimHop(false, address(0x2222));

        // Success.
        router.setPoolFor(address(weth), address(claim), false, factory, address(0xBEEF));
        _deployPool(address(0xBEEF));
        vm.prank(owner);
        registry.setWethClaimHop(false, address(0xBEEF));

        (bool stable, address pool) = registry.getWethClaimHop();
        assertEq(pool, address(0xBEEF));
        assertEq(stable, false);
    }

    function testSetWethClaimHopRejectsUndeployedPool() public {
        _setRouterConfig();

        address undeployedPool = address(0xBEEF);
        router.setPoolFor(address(weth), address(claim), false, factory, undeployedPool);

        vm.prank(owner);
        vm.expectRevert(Errors.NotAContract.selector);
        registry.setWethClaimHop(false, undeployedPool);
    }

    function testSetWethClaimHopRejectsDelegatedEOAPool() public {
        _setRouterConfig();

        address delegatedPool = address(0x77020002);
        _etch7702(delegatedPool, address(this));
        router.setPoolFor(address(weth), address(claim), false, factory, delegatedPool);

        vm.prank(owner);
        vm.expectRevert(Errors.DelegatedEOA.selector);
        registry.setWethClaimHop(false, delegatedPool);
    }

    function testSetRouterConfigRevertsWhenChangingRouterAfterWethHopConfigured() public {
        _setRouterConfig();

        address wethClaimPool = address(0xBEEF);
        router.setPoolFor(address(weth), address(claim), false, factory, wethClaimPool);
        _deployPool(wethClaimPool);
        vm.prank(owner);
        registry.setWethClaimHop(false, wethClaimPool);

        MockAerodromeRouter router2 = new MockAerodromeRouter(factory, address(weth));
        router2.setPoolFor(address(weth), address(claim), false, factory, wethClaimPool);

        vm.prank(owner);
        vm.expectRevert(Errors.WiringMismatch.selector);
        registry.setRouterConfig(address(router2), factory, address(weth), address(claim));
    }

    function testSetRouterConfigRevertsWhenChangingFactoryAfterTokenConfigConfigured() public {
        _setRouterConfig();

        address tokenWethPool = address(0x1111);
        router.setPoolFor(address(tokenA), address(weth), false, factory, tokenWethPool);
        _deployPool(tokenWethPool);
        vm.prank(owner);
        registry.setTokenConfig(address(tokenA), true, false, false, address(0), false, tokenWethPool);

        address newFactory = address(0xFACA2);
        vm.etch(newFactory, hex"00");
        MockAerodromeRouter router2 = new MockAerodromeRouter(newFactory, address(weth));

        vm.prank(owner);
        vm.expectRevert(Errors.WiringMismatch.selector);
        registry.setRouterConfig(address(router2), newFactory, address(weth), address(claim));
    }

    function testSetTokenEnabledRequiresTokenConfigWhenEnabling() public {
        _setRouterConfig();

        vm.prank(owner);
        vm.expectRevert(Errors.TokenNotConfigured.selector);
        registry.setTokenEnabled(address(tokenA), true);
    }

    function testSetFurnaceEntryTokenExactReceiptSafeOnlyOwner() public {
        _setRouterConfig();

        address tokenWethPool = address(0x1111);
        router.setPoolFor(address(tokenA), address(weth), false, factory, tokenWethPool);
        _deployPool(tokenWethPool);

        vm.prank(owner);
        registry.setTokenConfig(address(tokenA), true, false, false, address(0), false, tokenWethPool);

        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, alice));
        registry.setFurnaceEntryTokenExactReceiptSafe(address(tokenA), true);
    }

    function testResolveFurnaceRouteRevertsWhenTokenNotMarkedExactReceiptSafe() public {
        _setRouterConfig();

        address hopPool = address(0x9999);
        router.setPoolFor(address(weth), address(claim), false, factory, hopPool);
        _deployPool(hopPool);
        vm.prank(owner);
        registry.setWethClaimHop(false, hopPool);

        address tokenWethPool = address(0x1111);
        router.setPoolFor(address(tokenA), address(weth), false, factory, tokenWethPool);
        _deployPool(tokenWethPool);

        vm.prank(owner);
        registry.setTokenConfig(address(tokenA), true, false, false, address(0), false, tokenWethPool);

        assertFalse(registry.isFurnaceEntryTokenExactReceiptSafe(address(tokenA)), "safety bit should default to false");

        vm.expectRevert(Errors.UnsafeEntryToken.selector);
        registry.resolveFurnaceRoute(address(tokenA));
    }

    function testSetTokenEnabledDisableDoesNotClearFurnaceSafety() public {
        _setRouterConfig();

        address tokenWethPool = address(0x1111);
        router.setPoolFor(address(tokenA), address(weth), false, factory, tokenWethPool);
        _deployPool(tokenWethPool);

        vm.prank(owner);
        registry.setTokenConfig(address(tokenA), true, false, false, address(0), false, tokenWethPool);
        _setFurnaceSafe(address(tokenA));

        vm.prank(owner);
        registry.setTokenEnabled(address(tokenA), false);

        assertTrue(
            registry.isFurnaceEntryTokenExactReceiptSafe(address(tokenA)), "disable should not clear Furnace safety bit"
        );
    }

    function testResolveTakeoverRouteIgnoresFurnaceSafetyFlag() public {
        _setRouterConfig();

        address tokenWethPool = address(0x1111);
        router.setPoolFor(address(tokenA), address(weth), false, factory, tokenWethPool);
        _deployPool(tokenWethPool);

        vm.prank(owner);
        registry.setTokenConfig(address(tokenA), true, false, false, address(0), false, tokenWethPool);

        IEntryTokenRegistry.RegistryRoute[] memory takeRoute = registry.resolveTakeoverRoute(address(tokenA));
        assertEq(takeRoute.length, 1);
        assertEq(takeRoute[0].tokenIn, address(tokenA));
        assertEq(takeRoute[0].tokenOut, address(weth));
        assertFalse(registry.isFurnaceEntryTokenExactReceiptSafe(address(tokenA)));
    }

    function testGuardianCanDisableTokenButCannotEnable() public {
        _setRouterConfig();

        address tokenWethPool = address(0x1111);
        router.setPoolFor(address(tokenA), address(weth), false, factory, tokenWethPool);
        _deployPool(tokenWethPool);

        vm.prank(owner);
        registry.setTokenConfig(address(tokenA), true, false, false, address(0), false, tokenWethPool);

        address guardianAddr = address(0x6CA4D);
        vm.prank(owner);
        registry.setGuardian(guardianAddr);

        vm.prank(guardianAddr);
        registry.setTokenEnabled(address(tokenA), false);
        assertFalse(registry.getTokenConfig(address(tokenA)).enabled);

        vm.prank(guardianAddr);
        vm.expectRevert(Errors.NotAuthorized.selector);
        registry.setTokenEnabled(address(tokenA), true);

        // Owner cannot re-enable during the guardian cooldown.
        vm.prank(owner);
        vm.expectRevert(Errors.NotAuthorized.selector);
        registry.setTokenEnabled(address(tokenA), true);

        // Warp past the 1-hour guardian cooldown.
        vm.warp(block.timestamp + 1 hours + 1);
        vm.prank(owner);
        registry.setTokenEnabled(address(tokenA), true);
        assertTrue(registry.getTokenConfig(address(tokenA)).enabled);
    }

    function testSetTokenEnabled_GuardianNoOpDoesNotBumpCooldown() public {
        // A guardian no-op disable (token already disabled) MUST NOT renew
        // `guardianDisabledUntil`. Otherwise a guardian could extend the
        // 1-hour owner-blocking window indefinitely without ever changing
        // token state.
        _setRouterConfig();

        address tokenWethPool = address(0x1111);
        router.setPoolFor(address(tokenA), address(weth), false, factory, tokenWethPool);
        _deployPool(tokenWethPool);

        vm.prank(owner);
        registry.setTokenConfig(address(tokenA), true, false, false, address(0), false, tokenWethPool);

        address guardianAddr = address(0x6CA4D);
        vm.prank(owner);
        registry.setGuardian(guardianAddr);

        vm.prank(guardianAddr);
        registry.setTokenEnabled(address(tokenA), false);
        uint256 firstCooldownEnd = registry.guardianDisabledUntil(address(tokenA));
        assertGt(firstCooldownEnd, block.timestamp);

        // Advance into the cooldown window but stay before it elapses.
        vm.warp(block.timestamp + 30 minutes);

        // Idempotent disable: token already disabled. Cooldown must NOT
        // extend. The call short-circuits before the role gate so a
        // guardian with no role at all could land here without effect.
        vm.prank(guardianAddr);
        registry.setTokenEnabled(address(tokenA), false);
        uint256 secondCooldownEnd = registry.guardianDisabledUntil(address(tokenA));
        assertEq(secondCooldownEnd, firstCooldownEnd);

        // Owner is still blocked from re-enabling until the original
        // cooldown elapses, but the cooldown horizon is the original one.
        vm.warp(firstCooldownEnd + 1);
        vm.prank(owner);
        registry.setTokenEnabled(address(tokenA), true);
        assertTrue(registry.getTokenConfig(address(tokenA)).enabled);
    }

    function testResolveFurnaceRouteRevertsWhenNotEnabled() public {
        _setRouterConfig();

        // Configure pools but keep token disabled.
        address tokenWethPool = address(0x1111);
        router.setPoolFor(address(tokenA), address(weth), false, factory, tokenWethPool);
        _deployPool(tokenWethPool);

        vm.prank(owner);
        registry.setTokenConfig(
            address(tokenA),
            false, // enabled
            false, // directToClaimEnabled
            false, // tokenClaimStable
            address(0), // tokenClaimPool (unused)
            false, // tokenWethStable
            tokenWethPool
        );

        vm.expectRevert(Errors.TokenNotEnabled.selector);
        registry.resolveFurnaceRoute(address(tokenA));
    }

    function testSetTokenConfigValidations() public {
        // Router not set.
        vm.prank(owner);
        vm.expectRevert(Errors.RouterConfigNotSet.selector);
        registry.setTokenConfig(address(tokenA), true, false, false, address(0), false, address(0));

        _setRouterConfig();

        vm.prank(owner);
        vm.expectRevert(Errors.ZeroAddress.selector);
        registry.setTokenConfig(address(0), true, false, false, address(0), false, address(0));

        vm.prank(owner);
        vm.expectRevert(Errors.InvalidToken.selector);
        registry.setTokenConfig(address(weth), true, false, false, address(0), false, address(0));

        vm.prank(owner);
        vm.expectRevert(Errors.InvalidToken.selector);
        registry.setTokenConfig(address(claim), true, false, false, address(0), false, address(0));

        // tokenWethPool required.
        vm.prank(owner);
        vm.expectRevert(Errors.ZeroAddress.selector);
        registry.setTokenConfig(address(tokenA), true, false, false, address(0), false, address(0));

        // tokenWethPool mismatch.
        address tokenWethPool = address(0x1111);
        router.setPoolFor(address(tokenA), address(weth), false, factory, address(0x2222));

        vm.prank(owner);
        vm.expectRevert(Errors.InvalidPool.selector);
        registry.setTokenConfig(address(tokenA), true, false, false, address(0), false, tokenWethPool);

        // Direct-to-CLAIM requires tokenClaimPool.
        router.setPoolFor(address(tokenA), address(weth), false, factory, tokenWethPool);
        vm.prank(owner);
        vm.expectRevert(Errors.NotAContract.selector);
        registry.setTokenConfig(address(tokenA), true, true, true, address(0), false, tokenWethPool);

        // Direct-to-CLAIM pool mismatch.
        router.setPoolFor(address(tokenA), address(claim), true, factory, address(0x3333));
        vm.prank(owner);
        vm.expectRevert(Errors.NotAContract.selector);
        registry.setTokenConfig(address(tokenA), true, true, true, address(0x4444), false, tokenWethPool);
    }

    function testSetTokenConfigRejectsUndeployedTokenWethPool() public {
        _setRouterConfig();

        address undeployedPool = address(0x1111);
        router.setPoolFor(address(tokenA), address(weth), false, factory, undeployedPool);

        vm.prank(owner);
        vm.expectRevert(Errors.NotAContract.selector);
        registry.setTokenConfig(address(tokenA), true, false, false, address(0), false, undeployedPool);
    }

    function testSetTokenConfigRejectsDelegatedEOAToken() public {
        _setRouterConfig();

        address delegatedToken = address(0x77020003);
        _etch7702(delegatedToken, address(this));

        vm.prank(owner);
        vm.expectRevert(Errors.DelegatedEOA.selector);
        registry.setTokenConfig(delegatedToken, true, false, false, address(0), false, address(0x1111));
    }

    function testSetTokenConfigRejectsDelegatedEOATokenWethPool() public {
        _setRouterConfig();

        address delegatedPool = address(0x77020004);
        _etch7702(delegatedPool, address(this));
        router.setPoolFor(address(tokenA), address(weth), false, factory, delegatedPool);

        vm.prank(owner);
        vm.expectRevert(Errors.DelegatedEOA.selector);
        registry.setTokenConfig(address(tokenA), true, false, false, address(0), false, delegatedPool);
    }

    function testSetTokenConfigRejectsUndeployedTokenClaimPool() public {
        _setRouterConfig();

        address tokenWethPool = address(0x1111);
        address undeployedClaimPool = address(0x2222);
        router.setPoolFor(address(tokenA), address(weth), false, factory, tokenWethPool);
        router.setPoolFor(address(tokenA), address(claim), true, factory, undeployedClaimPool);
        _deployPool(tokenWethPool);

        vm.prank(owner);
        vm.expectRevert(Errors.NotAContract.selector);
        registry.setTokenConfig(address(tokenA), true, true, true, undeployedClaimPool, false, tokenWethPool);
    }

    function testSetTokenConfigRejectsDelegatedEOATokenClaimPool() public {
        _setRouterConfig();

        address tokenWethPool = address(0x1111);
        address delegatedClaimPool = address(0x77020005);
        router.setPoolFor(address(tokenA), address(weth), false, factory, tokenWethPool);
        router.setPoolFor(address(tokenA), address(claim), true, factory, delegatedClaimPool);
        _deployPool(tokenWethPool);
        _etch7702(delegatedClaimPool, address(this));

        vm.prank(owner);
        vm.expectRevert(Errors.DelegatedEOA.selector);
        registry.setTokenConfig(address(tokenA), true, true, true, delegatedClaimPool, false, tokenWethPool);
    }

    function testSetTokenConfigAndResolveRoutes_DirectToClaim() public {
        _setRouterConfig();

        // Configure pools.
        address tokenWethPool = address(0x1111);
        address tokenClaimPool = address(0x2222);
        router.setPoolFor(address(tokenA), address(weth), false, factory, tokenWethPool);
        router.setPoolFor(address(tokenA), address(claim), true, factory, tokenClaimPool);
        _deployPool(tokenWethPool);
        _deployPool(tokenClaimPool);

        vm.prank(owner);
        registry.setTokenConfig(
            address(tokenA),
            true, // enabled
            true, // directToClaimEnabled
            true, // tokenClaimStable
            tokenClaimPool,
            false, // tokenWethStable
            tokenWethPool
        );
        _setFurnaceSafe(address(tokenA));

        // Furnace route should be direct.
        (IEntryTokenRegistry.RegistryRoute[] memory route, uint256 routeTokenId) =
            registry.resolveFurnaceRoute(address(tokenA));

        assertEq(routeTokenId, 0);
        assertEq(route.length, 1);
        assertEq(route[0].tokenIn, address(tokenA));
        assertEq(route[0].tokenOut, address(claim));
        assertEq(route[0].stable, true);
        assertEq(route[0].pool, tokenClaimPool);

        // Takeover route should end in WETH.
        IEntryTokenRegistry.RegistryRoute[] memory takeRoute = registry.resolveTakeoverRoute(address(tokenA));
        assertEq(takeRoute.length, 1);
        assertEq(takeRoute[0].tokenIn, address(tokenA));
        assertEq(takeRoute[0].tokenOut, address(weth));
        assertEq(takeRoute[0].stable, false);
        assertEq(takeRoute[0].pool, tokenWethPool);

        // Config is round-trippable.
        IEntryTokenRegistry.TokenConfig memory cfg = registry.getTokenConfig(address(tokenA));
        assertTrue(cfg.enabled);
        assertTrue(cfg.directToClaimEnabled);
        assertEq(cfg.tokenClaimPool, tokenClaimPool);
        assertEq(cfg.tokenWethPool, tokenWethPool);
    }

    function testResolveFurnaceRouteRejectsDelegatedEOAPoolDrift() public {
        _setRouterConfig();

        address tokenWethPool = address(0x1111);
        address tokenClaimPool = address(0x2222);
        router.setPoolFor(address(tokenA), address(weth), false, factory, tokenWethPool);
        router.setPoolFor(address(tokenA), address(claim), true, factory, tokenClaimPool);
        _deployPool(tokenWethPool);
        _deployPool(tokenClaimPool);

        vm.prank(owner);
        registry.setTokenConfig(address(tokenA), true, true, true, tokenClaimPool, false, tokenWethPool);
        _setFurnaceSafe(address(tokenA));

        _etch7702(tokenClaimPool, address(this));

        vm.expectRevert(Errors.DelegatedEOA.selector);
        registry.resolveFurnaceRoute(address(tokenA));
    }

    function testSetTokenConfigAndResolveRoutes_TwoHopViaWeth() public {
        _setRouterConfig();

        // Configure WETH-CLAIM hop.
        address hopPool = address(0x9999);
        router.setPoolFor(address(weth), address(claim), false, factory, hopPool);
        _deployPool(hopPool);
        vm.prank(owner);
        registry.setWethClaimHop(false, hopPool);

        // Configure token->WETH pool.
        address tokenWethPool = address(0x1111);
        router.setPoolFor(address(tokenA), address(weth), false, factory, tokenWethPool);
        _deployPool(tokenWethPool);

        vm.prank(owner);
        registry.setTokenConfig(
            address(tokenA),
            true, // enabled
            false, // directToClaimEnabled
            false, // tokenClaimStable (unused)
            address(0),
            false, // tokenWethStable
            tokenWethPool
        );
        _setFurnaceSafe(address(tokenA));

        (IEntryTokenRegistry.RegistryRoute[] memory route, uint256 routeTokenId) =
            registry.resolveFurnaceRoute(address(tokenA));

        assertEq(routeTokenId, 1);
        assertEq(route.length, 2);

        assertEq(route[0].tokenIn, address(tokenA));
        assertEq(route[0].tokenOut, address(weth));
        assertEq(route[0].stable, false);
        assertEq(route[0].pool, tokenWethPool);

        assertEq(route[1].tokenIn, address(weth));
        assertEq(route[1].tokenOut, address(claim));
        assertEq(route[1].stable, false);
        assertEq(route[1].pool, hopPool);
    }

    function testResolveFurnaceRouteRevertsWhenWethClaimHopNotSet() public {
        _setRouterConfig();

        address tokenWethPool = address(0x1111);
        router.setPoolFor(address(tokenA), address(weth), false, factory, tokenWethPool);
        _deployPool(tokenWethPool);

        vm.prank(owner);
        registry.setTokenConfig(
            address(tokenA),
            true, // enabled
            false, // directToClaimEnabled
            false,
            address(0),
            false,
            tokenWethPool
        );
        _setFurnaceSafe(address(tokenA));

        vm.expectRevert(Errors.WethClaimHopNotSet.selector);
        registry.resolveFurnaceRoute(address(tokenA));
    }

    /// @dev Takeover routing does not require the WETH/CLAIM hop; Furnace via-WETH paths do.
    function testTakeoverOnlyRegistryMayLeaveWethClaimHopUnset() public {
        _setRouterConfig();

        address tokenWethPool = address(0x1111);
        router.setPoolFor(address(tokenA), address(weth), false, factory, tokenWethPool);
        _deployPool(tokenWethPool);

        vm.prank(owner);
        registry.setTokenConfig(address(tokenA), true, false, false, address(0), false, tokenWethPool);

        (, address pool) = registry.getWethClaimHop();
        assertEq(pool, address(0), "takeover-only registry may leave WETH/CLAIM hop unset");
    }

    function testOwnerCanDisableToken() public {
        _setRouterConfig();

        address tokenWethPool = address(0x1111);
        router.setPoolFor(address(tokenA), address(weth), false, factory, tokenWethPool);
        _deployPool(tokenWethPool);
        vm.prank(owner);
        registry.setTokenConfig(address(tokenA), true, false, false, address(0), false, tokenWethPool);

        address hopPool = address(0x9999);
        router.setPoolFor(address(weth), address(claim), false, factory, hopPool);
        _deployPool(hopPool);
        vm.prank(owner);
        registry.setWethClaimHop(false, hopPool);

        address guardianAddr = address(0x6CA4D);
        vm.prank(owner);
        registry.setGuardian(guardianAddr);

        vm.prank(owner);
        registry.setTokenEnabled(address(tokenA), false);

        IEntryTokenRegistry.TokenConfig memory cfg = registry.getTokenConfig(address(tokenA));
        assertFalse(cfg.enabled, "owner should be able to disable token");
    }

    function testOwnerAsGuardianCanDisableToken() public {
        _setRouterConfig();

        address tokenWethPool = address(0x1111);
        router.setPoolFor(address(tokenA), address(weth), false, factory, tokenWethPool);
        _deployPool(tokenWethPool);
        vm.prank(owner);
        registry.setTokenConfig(address(tokenA), true, false, false, address(0), false, tokenWethPool);

        address hopPool = address(0x9999);
        router.setPoolFor(address(weth), address(claim), false, factory, hopPool);
        _deployPool(hopPool);
        vm.prank(owner);
        registry.setWethClaimHop(false, hopPool);

        // Guardian defaults to `owner` in the constructor; do not rotate.
        vm.prank(owner);
        registry.setTokenEnabled(address(tokenA), false);

        IEntryTokenRegistry.TokenConfig memory cfg = registry.getTokenConfig(address(tokenA));
        assertFalse(cfg.enabled);
    }

    function testOwnerCanRotateGuardian() public {
        _setRouterConfig();

        address hopPool = address(0x9999);
        router.setPoolFor(address(weth), address(claim), false, factory, hopPool);
        _deployPool(hopPool);
        vm.prank(owner);
        registry.setWethClaimHop(false, hopPool);

        address guardianAddr = address(0x6CA4D);
        vm.prank(owner);
        registry.setGuardian(guardianAddr);

        address newGuardian = address(0xBEEF);
        vm.prank(owner);
        registry.setGuardian(newGuardian);
        assertEq(registry.guardian(), newGuardian);
    }

    function testCurrentGuardianCanRotateGuardian() public {
        _setRouterConfig();

        address hopPool = address(0x9999);
        router.setPoolFor(address(weth), address(claim), false, factory, hopPool);
        _deployPool(hopPool);
        vm.prank(owner);
        registry.setWethClaimHop(false, hopPool);

        address guardianAddr = address(0x6CA4D);
        vm.prank(owner);
        registry.setGuardian(guardianAddr);

        address newGuardian = address(0xBEEF);
        vm.prank(guardianAddr);
        registry.setGuardian(newGuardian);
        assertEq(registry.guardian(), newGuardian);
    }

    function testSetGuardianRejectsDelegatedEOA() public {
        address delegatedGuardian = address(0x77027702);
        _etch7702(delegatedGuardian, address(this));

        vm.prank(owner);
        vm.expectRevert(Errors.DelegatedEOA.selector);
        registry.setGuardian(delegatedGuardian);
    }

    function testSetGuardianAllowsBareEOA() public {
        address bareEoa = address(0xBA7E);
        assertEq(bareEoa.code.length, 0, "test sentinel must be a bare EOA");

        vm.prank(owner);
        registry.setGuardian(bareEoa);
        assertEq(registry.guardian(), bareEoa);
    }

    /// @dev Guardian must not be able to enable tokens; only owner may enable.
    function testGuardianCannotEnableToken() public {
        _setRouterConfig();

        address tokenWethPool = address(0x1111);
        router.setPoolFor(address(tokenA), address(weth), false, factory, tokenWethPool);
        _deployPool(tokenWethPool);
        vm.prank(owner);
        registry.setTokenConfig(address(tokenA), false, false, false, address(0), false, tokenWethPool);

        address hopPool = address(0x9999);
        router.setPoolFor(address(weth), address(claim), false, factory, hopPool);
        _deployPool(hopPool);
        vm.prank(owner);
        registry.setWethClaimHop(false, hopPool);

        address guardianAddr = address(0x6CA4D);
        vm.prank(owner);
        registry.setGuardian(guardianAddr);

        vm.prank(guardianAddr);
        vm.expectRevert(Errors.NotAuthorized.selector);
        registry.setTokenEnabled(address(tokenA), true);

        IEntryTokenRegistry.TokenConfig memory cfg = registry.getTokenConfig(address(tokenA));
        assertFalse(cfg.enabled, "token must remain disabled after guardian enable attempt");
    }

    function testFuzz_SetWethClaimHopRejectsUndeployedPool(address pool) public {
        vm.assume(pool != address(0));
        vm.assume(uint160(pool) > 9); // avoid precompile addresses
        vm.assume(pool.code.length == 0);

        _setRouterConfig();
        router.setPoolFor(address(weth), address(claim), false, factory, pool);

        vm.prank(owner);
        vm.expectRevert(Errors.NotAContract.selector);
        registry.setWethClaimHop(false, pool);
    }

    function testSetWethClaimHopRevertsOnSecondCall() public {
        _setRouterConfig();

        address hopPool = address(0xBEEF);
        router.setPoolFor(address(weth), address(claim), false, factory, hopPool);
        _deployPool(hopPool);

        vm.prank(owner);
        registry.setWethClaimHop(false, hopPool);

        // Second call must revert — hop is immutable after first set.
        address hopPool2 = address(0xCAFE);
        router.setPoolFor(address(weth), address(claim), true, factory, hopPool2);
        _deployPool(hopPool2);

        vm.prank(owner);
        vm.expectRevert(Errors.WethClaimHopAlreadySet.selector);
        registry.setWethClaimHop(true, hopPool2);

        // Original hop unchanged.
        (bool stable, address pool) = registry.getWethClaimHop();
        assertEq(pool, hopPool);
        assertEq(stable, false);
    }

    function testFuzz_SetTokenConfigRejectsUndeployedTokenPools(address tokenWethPool, address tokenClaimPool) public {
        vm.assume(tokenWethPool != address(0));
        vm.assume(tokenClaimPool != address(0));
        vm.assume(uint160(tokenWethPool) > 1024); // avoid precompile/system addresses
        vm.assume(uint160(tokenClaimPool) > 1024); // avoid precompile/system addresses
        vm.assume(tokenWethPool != tokenClaimPool);
        vm.assume(tokenWethPool.code.length == 0);
        vm.assume(tokenClaimPool.code.length == 0);

        _setRouterConfig();

        router.setPoolFor(address(tokenA), address(weth), false, factory, tokenWethPool);
        vm.prank(owner);
        vm.expectRevert(Errors.NotAContract.selector);
        registry.setTokenConfig(address(tokenA), true, false, false, address(0), false, tokenWethPool);

        _deployPool(tokenWethPool);
        router.setPoolFor(address(tokenA), address(claim), true, factory, tokenClaimPool);
        vm.prank(owner);
        vm.expectRevert(Errors.NotAContract.selector);
        registry.setTokenConfig(address(tokenA), true, true, true, tokenClaimPool, false, tokenWethPool);
    }
}
