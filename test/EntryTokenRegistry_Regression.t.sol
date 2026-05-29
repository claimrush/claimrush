// SPDX-License-Identifier: MIT
pragma solidity ^0.8.34;

import {Test, Vm} from "forge-std/Test.sol";

import {EntryTokenRegistry} from "src/EntryTokenRegistry.sol";
import {IEntryTokenRegistry} from "src/interfaces/IEntryTokenRegistry.sol";
import {Errors} from "src/lib/Errors.sol";

import {MockAerodromeRouter} from "./mocks/MockAerodromeRouter.sol";
import {MockERC20} from "./mocks/MockERC20.sol";

/// @notice Regression tests for EntryTokenRegistry edge cases not covered by the main test file.
contract EntryTokenRegistryRegressionTest is Test {
    EntryTokenRegistry internal registry;
    MockAerodromeRouter internal router;

    MockERC20 internal weth;
    MockERC20 internal claim;
    MockERC20 internal tokenA;

    address internal owner = address(0xA11CE);
    address internal factory = address(0xFACA);

    function setUp() public {
        registry = new EntryTokenRegistry(owner);
        weth = new MockERC20("WETH", "WETH");
        claim = new MockERC20("CLAIM", "CLAIM");
        tokenA = new MockERC20("TokenA", "TKA");
        router = new MockAerodromeRouter(factory, address(weth));
        vm.etch(factory, hex"00");

        vm.prank(owner);
        registry.setRouterConfig(address(router), factory, address(weth), address(claim));
    }

    // resolveTakeoverRoute reverts for an unconfigured token.
    function testResolveTakeoverRouteRevertsForUnconfiguredToken() public {
        vm.expectRevert(Errors.TokenNotConfigured.selector);
        registry.resolveTakeoverRoute(address(tokenA));
    }

    // resolveTakeoverRoute reverts for a disabled token.
    function testResolveTakeoverRouteRevertsForDisabledToken() public {
        address tokenWethPool = address(0x1111);
        router.setPoolFor(address(tokenA), address(weth), false, factory, tokenWethPool);
        vm.etch(tokenWethPool, hex"00");

        vm.prank(owner);
        registry.setTokenConfig(address(tokenA), false, false, false, address(0), false, tokenWethPool);

        vm.expectRevert(Errors.TokenNotEnabled.selector);
        registry.resolveTakeoverRoute(address(tokenA));
    }

    // setTokenConfig rejects a tokenIn address without contract code.
    function testSetTokenConfigRejectsEOAToken() public {
        address eoaToken = address(0xDEAD);

        vm.prank(owner);
        vm.expectRevert(Errors.NotAContract.selector);
        registry.setTokenConfig(eoaToken, true, false, false, address(0), false, address(0x1111));
    }

    // wrappedNative and claimToken remain immutable after the first set.
    function testWrappedNativeAndClaimImmutableAfterSet() public {
        MockERC20 newWeth = new MockERC20("NEWWETH", "NWETH");
        MockERC20 newClaim = new MockERC20("NEWCLAIM", "NCLM");
        MockAerodromeRouter router2 = new MockAerodromeRouter(factory, address(newWeth));

        // Changing wrappedNative should fail.
        vm.prank(owner);
        vm.expectRevert(Errors.WrappedNativeImmutable.selector);
        registry.setRouterConfig(address(router2), factory, address(newWeth), address(claim));

        // Changing claimToken should fail.
        vm.prank(owner);
        vm.expectRevert(Errors.ClaimTokenImmutable.selector);
        registry.setRouterConfig(address(router), factory, address(weth), address(newClaim));
    }

    // ----------------------------------------------------------------
    // ----------------------------------------------------------------
    function testGuardianCanDisablePreFreeze() public {
        address tokenWethPool = address(0x2222);
        router.setPoolFor(address(tokenA), address(weth), false, factory, tokenWethPool);
        vm.etch(tokenWethPool, hex"00");

        vm.prank(owner);
        registry.setTokenConfig(address(tokenA), true, false, false, address(0), false, tokenWethPool);

        // Guardian (defaults to owner/initialOwner in constructor) disables.
        address guardianAddr = registry.guardian();
        vm.prank(guardianAddr);
        registry.setTokenEnabled(address(tokenA), false);

        IEntryTokenRegistry.TokenConfig memory cfg = registry.getTokenConfig(address(tokenA));
        assertFalse(cfg.enabled, "guardian should be able to disable pre-freeze");
    }

    // setTokenConfig cannot re-enable a token during guardian cooldown.
    function testSetTokenConfigRevertsWhenEnabledDuringGuardianCooldown() public {
        address tokenWethPool = address(0x4444);
        router.setPoolFor(address(tokenA), address(weth), false, factory, tokenWethPool);
        vm.etch(tokenWethPool, hex"00");

        // Configure token and enable it.
        vm.prank(owner);
        registry.setTokenConfig(address(tokenA), true, false, false, address(0), false, tokenWethPool);

        // Guardian disables the token (sets 1-hour cooldown).
        address guardianAddr = address(0xBEEF);
        vm.prank(owner);
        registry.setGuardian(guardianAddr);
        vm.prank(guardianAddr);
        registry.setTokenEnabled(address(tokenA), false);

        // Owner attempts setTokenConfig with enabled=true during cooldown — MUST revert.
        vm.prank(owner);
        vm.expectRevert(Errors.NotAuthorized.selector);
        registry.setTokenConfig(address(tokenA), true, false, false, address(0), false, tokenWethPool);

        // Warp past cooldown — should succeed.
        vm.warp(block.timestamp + 1 hours + 1);
        vm.prank(owner);
        registry.setTokenConfig(address(tokenA), true, false, false, address(0), false, tokenWethPool);
        assertTrue(registry.getTokenConfig(address(tokenA)).enabled);
    }

    // Guardian disabling a never-configured token reverts.
    function testGuardianDisableUnconfiguredTokenReverts() public {
        address guardianAddr = address(0xBEEF);
        vm.prank(owner);
        registry.setGuardian(guardianAddr);

        // tokenA was never configured via setTokenConfig.
        vm.prank(guardianAddr);
        vm.expectRevert(Errors.TokenNotConfigured.selector);
        registry.setTokenEnabled(address(tokenA), false);
    }

    // ----------------------------------------------------------------
    // ----------------------------------------------------------------
    function testGuardianCannotEnablePreFreeze() public {
        address tokenWethPool = address(0x3333);
        router.setPoolFor(address(tokenA), address(weth), false, factory, tokenWethPool);
        vm.etch(tokenWethPool, hex"00");

        vm.prank(owner);
        registry.setTokenConfig(address(tokenA), false, false, false, address(0), false, tokenWethPool);

        // Set a dedicated guardian distinct from owner so the owner-path
        // does not shadow the guardian access-control branch.
        address dedicatedGuardian = address(0xBEEF);
        vm.prank(owner);
        registry.setGuardian(dedicatedGuardian);

        // Guardian trying to enable must revert.
        vm.prank(dedicatedGuardian);
        vm.expectRevert(Errors.NotAuthorized.selector);
        registry.setTokenEnabled(address(tokenA), true);
    }

    // A repeated guardian disable inside an already-active cooldown window must not
    // push the cooldown expiry forward. Without this guard a compromised guardian
    // could indefinitely extend the disable window with each call until the owner
    // rotates the guardian. The window is bounded to the original 1-hour cooldown.
    function testGuardianCannotExtendActiveCooldown() public {
        address tokenWethPool = address(0x6666);
        router.setPoolFor(address(tokenA), address(weth), false, factory, tokenWethPool);
        vm.etch(tokenWethPool, hex"00");

        vm.prank(owner);
        registry.setTokenConfig(address(tokenA), true, false, false, address(0), false, tokenWethPool);

        address guardianAddr = address(0xBEEF);
        vm.prank(owner);
        registry.setGuardian(guardianAddr);

        // Pin the start time so all expected values are explicit literals.
        uint256 t0 = 100_000;
        vm.warp(t0);

        vm.prank(guardianAddr);
        registry.setTokenEnabled(address(tokenA), false);
        uint256 firstExpiry = registry.guardianDisabledUntil(address(tokenA));
        assertEq(firstExpiry, t0 + 1 hours, "first disable seeds cooldown to t0 + 1h");

        // Halfway into the window: expiry MUST NOT move.
        vm.warp(t0 + 30 minutes);
        vm.prank(guardianAddr);
        registry.setTokenEnabled(address(tokenA), false);
        assertEq(
            registry.guardianDisabledUntil(address(tokenA)),
            firstExpiry,
            "second disable inside cooldown must not extend expiry"
        );

        // One second before expiry: expiry MUST NOT move.
        vm.warp(firstExpiry - 1);
        vm.prank(guardianAddr);
        registry.setTokenEnabled(address(tokenA), false);
        assertEq(
            registry.guardianDisabledUntil(address(tokenA)),
            firstExpiry,
            "disable one second before expiry must not extend"
        );

        // Past expiry: a fresh disable seeds a new window from now.
        // Owner re-enables in between to clear the idempotency guard, then
        // guardian disables again. Re-enable requires warping past expiry first.
        vm.warp(firstExpiry + 1);
        vm.prank(owner);
        registry.setTokenEnabled(address(tokenA), true);

        uint256 t2 = firstExpiry + 2;
        vm.warp(t2);
        vm.prank(guardianAddr);
        registry.setTokenEnabled(address(tokenA), false);
        assertEq(
            registry.guardianDisabledUntil(address(tokenA)), t2 + 1 hours, "post-expiry disable seeds a fresh cooldown"
        );
    }

    // Owner re-enabling an already-enabled token (or guardian re-disabling an
    // already-disabled token) is a no-op: no event emitted, no storage write.
    // Operators wanting to re-validate pools should call setTokenConfig.
    function testSetTokenEnabledIsIdempotent() public {
        address tokenWethPool = address(0x7777);
        router.setPoolFor(address(tokenA), address(weth), false, factory, tokenWethPool);
        vm.etch(tokenWethPool, hex"00");

        vm.prank(owner);
        registry.setTokenConfig(address(tokenA), true, false, false, address(0), false, tokenWethPool);
        assertTrue(registry.getTokenConfig(address(tokenA)).enabled);

        vm.recordLogs();
        vm.prank(owner);
        registry.setTokenEnabled(address(tokenA), true);
        Vm.Log[] memory entries = vm.getRecordedLogs();
        assertEq(entries.length, 0, "owner re-enable on already-enabled token must not emit");

        address guardianAddr = address(0xBEEF);
        vm.prank(owner);
        registry.setGuardian(guardianAddr);

        vm.prank(guardianAddr);
        registry.setTokenEnabled(address(tokenA), false);
        assertFalse(registry.getTokenConfig(address(tokenA)).enabled);

        vm.recordLogs();
        vm.warp(block.timestamp + 30 minutes);
        vm.prank(guardianAddr);
        registry.setTokenEnabled(address(tokenA), false);
        Vm.Log[] memory entries2 = vm.getRecordedLogs();
        assertEq(entries2.length, 0, "guardian re-disable on already-disabled token must not emit");
    }
}
