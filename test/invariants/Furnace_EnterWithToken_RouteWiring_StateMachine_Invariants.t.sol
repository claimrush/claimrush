// SPDX-License-Identifier: MIT
pragma solidity ^0.8.34;

import {Test} from "forge-std/Test.sol";

import {EntryTokenRegistry} from "src/EntryTokenRegistry.sol";
import {FurnaceQuoter} from "src/FurnaceQuoter.sol";
import {ShareholderRoyalties} from "src/ShareholderRoyalties.sol";
import {ClaimAllHelper} from "src/ClaimAllHelper.sol";
import {MineCoreHarness} from "test/mocks/MineCoreHarness.sol";
import {FurnaceSwapHarness} from "test/mocks/FurnaceSwapHarness.sol";

import {Constants} from "src/lib/Constants.sol";
import {Errors} from "src/lib/Errors.sol";

import {IDexAdapter} from "src/interfaces/IDexAdapter.sol";
import {IEntryTokenRegistry} from "src/interfaces/IEntryTokenRegistry.sol";

import {DelegationHub} from "src/DelegationHub.sol";
import {MockAerodromeRouter} from "test/mocks/MockAerodromeRouter.sol";
import {MockContract} from "test/mocks/MockContract.sol";
import {MockERC20} from "test/mocks/MockERC20.sol";
import {MockVe} from "test/mocks/MockVe.sol";
import {MockWETH} from "test/mocks/MockWETH.sol";

/// @dev State-machine tests around the most brittle wiring assumptions for
///      Furnace token-entry swaps:
///      - Registry-resolved route shape (directToClaim vs via WETH)
///      - Onchain allowlist enforcement via poolFor(...) checks
///      - WETH special-case path (unwrap + swapExactETHForTokens)
///      - Split-registry invariant: Furnace registry MUST differ from MineCore registry
contract Furnace_EnterWithToken_RouteWiring_StateMachine_Invariants is Test {
    address internal constant OWNER = address(0xA11CE);

    // --- Core components
    MockERC20 internal claim;
    MockVe internal ve;
    ShareholderRoyalties internal royalties;
    MineCoreHarness internal mineCore;
    FurnaceSwapHarness internal furnace;

    EntryTokenRegistry internal furnaceRegistry;
    EntryTokenRegistry internal mineCoreRegistry;

    MockWETH internal weth;
    MockERC20 internal tokenIn;
    MockAerodromeRouter internal router;

    // --- Router config
    address internal constant FACTORY = address(0xFACA7);

    bool internal constant STABLE_TOKEN_WETH = false;
    bool internal constant STABLE_WETH_CLAIM = false;
    bool internal constant STABLE_TOKEN_CLAIM = false;

    address internal constant POOL_TOKEN_WETH = address(0x1111);
    address internal constant POOL_WETH_CLAIM = address(0x2222);
    address internal constant POOL_TOKEN_CLAIM = address(0x3333);

    // --- Mutable state tracked for expectations (mirrors registry + router mapping)
    bool internal tokenEnabled;
    bool internal directToClaimEnabled;

    bool internal poolOkTokenWeth;
    bool internal poolOkWethClaim;
    bool internal poolOkTokenClaim;

    address[] internal actors;

    function setUp() public {
        // Tokens + router
        weth = new MockWETH();
        tokenIn = new MockERC20("TokenIn", "TIN");

        router = new MockAerodromeRouter(FACTORY, address(weth));

        // Mintable mock CLAIM keeps the state machine focused on routing and allowlisting.
        claim = new MockERC20("ClaimRush", "CLAIM");
        vm.mockCall(address(router), abi.encodeWithSignature("claim()"), abi.encode(address(claim)));
        vm.mockCall(address(router), abi.encodeWithSignature("emissionStartTime()"), abi.encode(uint256(1)));
        vm.mockCall(address(router), abi.encodeWithSignature("GENESIS_ACCRUAL_DURATION()"), abi.encode(uint256(604800)));
        // Router allowlist mapping must exist before registry setters validate poolFor(...).
        _setPoolForTokenWeth(true);
        _setPoolForWethClaim(true);
        _setPoolForTokenClaim(true);

        // FACTORY is a bare address; give it bytecode so it passes NotAContract checks in setRouterConfig.
        vm.etch(FACTORY, hex"00");
        vm.etch(POOL_TOKEN_WETH, hex"00");
        vm.etch(POOL_WETH_CLAIM, hex"00");
        vm.etch(POOL_TOKEN_CLAIM, hex"00");

        // Registry instances
        furnaceRegistry = new EntryTokenRegistry(OWNER);
        mineCoreRegistry = new EntryTokenRegistry(OWNER);

        // Router config (same router, but different registry instances)
        vm.startPrank(OWNER);
        furnaceRegistry.setRouterConfig(address(router), FACTORY, address(weth), address(claim));
        mineCoreRegistry.setRouterConfig(address(router), FACTORY, address(weth), address(claim));

        // Furnace registry gets the extra WETH->CLAIM hop needed for token-entry swaps.
        furnaceRegistry.setWethClaimHop(STABLE_WETH_CLAIM, POOL_WETH_CLAIM);

        // Token config is present in both registries (MineCore uses token->WETH, Furnace may use directToClaim or via WETH).
        furnaceRegistry.setTokenConfig(
            address(tokenIn),
            true, // enabled
            false, // directToClaim (default)
            STABLE_TOKEN_CLAIM,
            POOL_TOKEN_CLAIM,
            STABLE_TOKEN_WETH,
            POOL_TOKEN_WETH
        );
        furnaceRegistry.setFurnaceEntryTokenExactReceiptSafe(address(tokenIn), true);

        mineCoreRegistry.setTokenConfig(
            address(tokenIn),
            true, // enabled
            false, // directToClaim (unused in MineCore)
            STABLE_TOKEN_CLAIM,
            POOL_TOKEN_CLAIM,
            STABLE_TOKEN_WETH,
            POOL_TOKEN_WETH
        );
        mineCoreRegistry.setFurnaceEntryTokenExactReceiptSafe(address(tokenIn), true);
        vm.stopPrank();

        // Protocol contracts
        ve = new MockVe();
        royalties = new ShareholderRoyalties(address(ve), OWNER);
        mineCore = new MineCoreHarness(address(claim), address(ve), address(royalties), OWNER);
        furnace = new FurnaceSwapHarness(address(claim), address(ve), OWNER);
        FurnaceQuoter quoter = new FurnaceQuoter(address(furnace));
        ClaimAllHelper claimAllHelper = new ClaimAllHelper(address(royalties), address(mineCore));

        // Split wiring: wire all dependencies so Furnace and MineCore use distinct registries.
        DelegationHub hub = new DelegationHub();
        MockContract marketMock = new MockContract();
        vm.mockCall(address(marketMock), abi.encodeWithSignature("claim()"), abi.encode(address(claim)));
        vm.mockCall(address(marketMock), abi.encodeWithSignature("ve()"), abi.encode(address(ve)));
        vm.mockCall(address(marketMock), abi.encodeWithSignature("royalties()"), abi.encode(address(royalties)));

        vm.startPrank(OWNER);
        royalties.setWiring(address(mineCore), address(marketMock), address(furnace));
        royalties.setClaimAllHelper(address(claimAllHelper));
        mineCore.setEntryTokenRegistry(address(mineCoreRegistry));
        mineCore.setFurnace(address(furnace));
        mineCore.setClaimAllHelper(address(claimAllHelper));
        mineCore.setDelegationHub(address(hub));
        furnace.setEntryTokenRegistry(address(furnaceRegistry));
        furnace.setFurnaceQuoter(address(quoter));
        furnace.setShareholderRoyalties(address(royalties));
        furnace.setMineCore(address(mineCore));
        furnace.setMineMarket(address(marketMock));
        furnace.setDelegationHub(address(hub));
        vm.stopPrank();

        // Furnace guardian for this harness; MineCore stays configured so router-driven
        // swap mocks keep ClaimToken.minter pointed at the router mock.
        vm.startPrank(OWNER);
        furnace.setGuardian(address(mineCore));
        vm.stopPrank();

        // Expectation state
        tokenEnabled = true;
        directToClaimEnabled = false;

        poolOkTokenWeth = true;
        poolOkWethClaim = true;
        poolOkTokenClaim = true;

        // Actors
        actors = new address[](3);
        actors[0] = address(0xB0B);
        actors[1] = address(0xCAFE);
        actors[2] = address(0xD00D);

        // Split-registry assertion (the wiring script must maintain this invariant)
        _assertSplitRegistries();
    }

    function test_furnaceMiswiredToMineCoreRegistry_revertsSafely() public {
        // MineCore registry intentionally has no WETH->CLAIM hop; Furnace swaps must fail safe if miswired.
        FurnaceSwapHarness badFurnace = new FurnaceSwapHarness(address(claim), address(ve), OWNER);
        vm.prank(OWNER);
        badFurnace.setEntryTokenRegistry(address(mineCoreRegistry));

        address actor = address(0xBEEF);
        uint256 amountIn = 1e18;

        tokenIn.mint(actor, amountIn);
        vm.prank(actor);
        tokenIn.approve(address(badFurnace), amountIn);

        vm.prank(actor);
        vm.expectRevert(Errors.WethClaimHopNotSet.selector);
        badFurnace.exposedSwapTokenToClaimFrom(address(tokenIn), amountIn);
    }

    function testFuzz_stateMachine_furnaceTokenEntry_swapRouteWiring(uint256 seed) public {
        _assertSplitRegistries();

        uint256 steps = 20;
        for (uint256 i = 0; i < steps; i++) {
            seed = uint256(keccak256(abi.encode(seed, i)));
            uint256 action = seed % 9;

            if (action == 0) {
                _toggleDirectToClaim();
            } else if (action == 1) {
                _toggleTokenEnabled();
            } else if (action == 2) {
                _togglePoolTokenWeth();
            } else if (action == 3) {
                _togglePoolWethClaim();
            } else if (action == 4) {
                _togglePoolTokenClaim();
            } else if (action == 5) {
                _assertRegistryRouteShape();
            } else if (action == 6) {
                _attemptSwapToken(seed);
            } else if (action == 7) {
                _attemptSwapWeth(seed);
            } else {
                // Extra: MineCore registry should always resolve takeover routes for enabled tokens even without WETH->CLAIM hop.
                _assertMineCoreRegistryTakeoverRouteShape();
            }
        }
    }

    // ----------------------------
    // Actions
    // ----------------------------

    function _toggleDirectToClaim() internal {
        // Attempt to flip directToClaimEnabled via setTokenConfig.
        bool desired = !directToClaimEnabled;

        bytes memory callData = abi.encodeWithSelector(
            EntryTokenRegistry.setTokenConfig.selector,
            address(tokenIn),
            tokenEnabled,
            desired,
            STABLE_TOKEN_CLAIM,
            POOL_TOKEN_CLAIM,
            STABLE_TOKEN_WETH,
            POOL_TOKEN_WETH
        );

        vm.prank(OWNER);
        (bool ok,) = address(furnaceRegistry).call(callData);

        // setTokenConfig always validates token->WETH pool, and validates token->CLAIM pool when enabling directToClaim.
        bool expectOk = poolOkTokenWeth && (!desired || poolOkTokenClaim);

        if (expectOk) {
            assertTrue(ok);
            directToClaimEnabled = desired;
        } else {
            assertFalse(ok);
        }

        _assertRegistryRouteShape();
    }

    function _toggleTokenEnabled() internal {
        bool desired = !tokenEnabled;
        // setTokenEnabled(true) re-validates router.poolFor(...) against stored pools.
        // Non-direct routes also require WETH->CLAIM poolFor to match _wethClaimPool when the hop is set.
        bool expectOk = !desired || (poolOkTokenWeth && (directToClaimEnabled ? poolOkTokenClaim : poolOkWethClaim));

        vm.prank(OWNER);
        (bool ok,) =
            address(furnaceRegistry).call(abi.encodeCall(furnaceRegistry.setTokenEnabled, (address(tokenIn), desired)));

        assertEq(ok, expectOk);
        if (ok) {
            tokenEnabled = desired;
        }

        _assertRegistryRouteShape();
    }

    function _togglePoolTokenWeth() internal {
        _setPoolForTokenWeth(!poolOkTokenWeth);
        poolOkTokenWeth = !poolOkTokenWeth;
    }

    function _togglePoolWethClaim() internal {
        _setPoolForWethClaim(!poolOkWethClaim);
        poolOkWethClaim = !poolOkWethClaim;
    }

    function _togglePoolTokenClaim() internal {
        _setPoolForTokenClaim(!poolOkTokenClaim);
        poolOkTokenClaim = !poolOkTokenClaim;
    }

    // ----------------------------
    // Assertions
    // ----------------------------

    function _assertSplitRegistries() internal view {
        assertTrue(address(furnaceRegistry) != address(mineCoreRegistry));
        assertEq(furnace.entryTokenRegistry(), address(furnaceRegistry));
        assertEq(mineCore.entryTokenRegistry(), address(mineCoreRegistry));
        assertTrue(furnace.entryTokenRegistry() != mineCore.entryTokenRegistry());
    }

    function _assertRegistryRouteShape() internal {
        if (!tokenEnabled) {
            vm.expectRevert(Errors.TokenNotEnabled.selector);
            furnaceRegistry.resolveFurnaceRoute(address(tokenIn));
            return;
        }

        // resolveFurnaceRoute validates pools at resolution time.
        bool poolsOk = directToClaimEnabled ? poolOkTokenClaim : (poolOkTokenWeth && poolOkWethClaim);
        if (!poolsOk) {
            vm.expectRevert(Errors.InvalidPool.selector);
            furnaceRegistry.resolveFurnaceRoute(address(tokenIn));
            return;
        }

        (IEntryTokenRegistry.RegistryRoute[] memory route, uint256 routeTokenId) =
            furnaceRegistry.resolveFurnaceRoute(address(tokenIn));

        if (directToClaimEnabled) {
            assertEq(route.length, 1);
            assertEq(routeTokenId, 0);
            assertEq(route[0].tokenIn, address(tokenIn));
            assertEq(route[0].tokenOut, address(claim));
            assertEq(route[0].stable, STABLE_TOKEN_CLAIM);
            assertEq(route[0].pool, POOL_TOKEN_CLAIM);
        } else {
            assertEq(route.length, 2);
            assertEq(routeTokenId, 1);
            assertEq(route[0].tokenIn, address(tokenIn));
            assertEq(route[0].tokenOut, address(weth));
            assertEq(route[0].stable, STABLE_TOKEN_WETH);
            assertEq(route[0].pool, POOL_TOKEN_WETH);

            assertEq(route[1].tokenIn, address(weth));
            assertEq(route[1].tokenOut, address(claim));
            assertEq(route[1].stable, STABLE_WETH_CLAIM);
            assertEq(route[1].pool, POOL_WETH_CLAIM);
        }
    }

    function _assertMineCoreRegistryTakeoverRouteShape() internal {
        // MineCore registry has token config but no WETH->CLAIM hop, and should still resolve takeover routes.
        // However, the shared router's poolFor mapping may be broken if poolOkTokenWeth was toggled.
        if (!poolOkTokenWeth) {
            vm.expectRevert(Errors.InvalidPool.selector);
            mineCoreRegistry.resolveTakeoverRoute(address(tokenIn));
            return;
        }

        IEntryTokenRegistry.RegistryRoute[] memory route = mineCoreRegistry.resolveTakeoverRoute(address(tokenIn));

        assertEq(route.length, 1);
        assertEq(route[0].tokenIn, address(tokenIn));
        assertEq(route[0].tokenOut, address(weth));
        assertEq(route[0].stable, STABLE_TOKEN_WETH);
        assertEq(route[0].pool, POOL_TOKEN_WETH);
    }

    // ----------------------------
    // Swap attempts
    // ----------------------------

    function _attemptSwapToken(uint256 seed) internal {
        address actor = actors[seed % actors.length];
        uint256 amountIn = (seed % 1e18) + 1;

        tokenIn.mint(actor, amountIn);
        vm.prank(actor);
        tokenIn.approve(address(furnace), amountIn);

        uint256 preClaim = claim.balanceOf(address(furnace));

        // Expected success conditions:
        // - token must be enabled
        // - if directToClaim: token->CLAIM poolFor must match
        // - else: token->WETH and WETH->CLAIM poolFor must match
        bool expectOk;
        if (tokenEnabled) {
            if (directToClaimEnabled) {
                expectOk = poolOkTokenClaim;
            } else {
                expectOk = poolOkTokenWeth && poolOkWethClaim;
            }
        } else {
            expectOk = false;
        }

        vm.prank(actor);
        (bool ok, bytes memory ret) = address(furnace)
            .call(
                abi.encodeWithSelector(
                    FurnaceSwapHarness.exposedSwapTokenToClaimFrom.selector, address(tokenIn), amountIn
                )
            );

        if (!expectOk) {
            assertFalse(ok);
            return;
        }

        assertTrue(ok);
        uint256 out = abi.decode(ret, (uint256));
        assertEq(out, amountIn);

        // Input tokens should not remain stuck in the Furnace.
        assertEq(tokenIn.balanceOf(address(furnace)), 0);
        assertGt(claim.balanceOf(address(furnace)), preClaim);

        // Router call should be deterministic.
        _assertLastRouterCall(amountIn, false);
    }

    function _attemptSwapWeth(uint256 seed) internal {
        address actor = actors[(seed >> 8) % actors.length];
        uint256 amountIn = ((seed >> 16) % 1e18) + 1;

        // Backed WETH via deposit.
        vm.deal(actor, amountIn);
        vm.prank(actor);
        weth.deposit{value: amountIn}();
        vm.prank(actor);
        weth.approve(address(furnace), amountIn);

        uint256 preClaim = claim.balanceOf(address(furnace));

        // WETH path only depends on WETH->CLAIM poolFor allowlisting.
        bool expectOk = poolOkWethClaim;

        vm.prank(actor);
        (bool ok, bytes memory ret) = address(furnace)
            .call(
                abi.encodeWithSelector(FurnaceSwapHarness.exposedSwapTokenToClaimFrom.selector, address(weth), amountIn)
            );

        if (!expectOk) {
            assertFalse(ok);
            return;
        }

        assertTrue(ok);
        uint256 out = abi.decode(ret, (uint256));
        assertEq(out, amountIn);

        // Input WETH should not remain stuck in the Furnace.
        assertEq(weth.balanceOf(address(furnace)), 0);
        assertGt(claim.balanceOf(address(furnace)), preClaim);

        // Router call should be deterministic (ETH swap path).
        _assertLastRouterCall(amountIn, true);
    }

    function _assertLastRouterCall(uint256 amountIn, bool ethSwap) internal view {
        uint256 expectedDeadline = block.timestamp + Constants.SWAP_DEADLINE_SECONDS;

        if (ethSwap) {
            assertEq(router.lastEthValue(), amountIn);
        } else {
            assertEq(router.lastAmountIn(), amountIn);
        }
        assertEq(router.lastDeadline(), expectedDeadline);
        assertEq(router.lastTo(), address(furnace));

        IDexAdapter.Route[] memory expectedRoutes;
        if (ethSwap) {
            expectedRoutes = new IDexAdapter.Route[](1);
            expectedRoutes[0] = IDexAdapter.Route({
                from: address(weth), to: address(claim), stable: STABLE_WETH_CLAIM, factory: FACTORY
            });
        } else if (directToClaimEnabled) {
            expectedRoutes = new IDexAdapter.Route[](1);
            expectedRoutes[0] = IDexAdapter.Route({
                from: address(tokenIn), to: address(claim), stable: STABLE_TOKEN_CLAIM, factory: FACTORY
            });
        } else {
            expectedRoutes = new IDexAdapter.Route[](2);
            expectedRoutes[0] = IDexAdapter.Route({
                from: address(tokenIn), to: address(weth), stable: STABLE_TOKEN_WETH, factory: FACTORY
            });
            expectedRoutes[1] = IDexAdapter.Route({
                from: address(weth), to: address(claim), stable: STABLE_WETH_CLAIM, factory: FACTORY
            });
        }

        assertEq(router.lastRoutesHash(), keccak256(abi.encode(expectedRoutes)));
    }

    // ----------------------------
    // Pool mapping helpers
    // ----------------------------

    function _setPoolForTokenWeth(bool ok) internal {
        router.setPoolFor(
            address(tokenIn),
            address(weth),
            STABLE_TOKEN_WETH,
            FACTORY,
            ok ? POOL_TOKEN_WETH : address(uint160(uint256(keccak256("bad-pool-token-weth"))))
        );
    }

    function _setPoolForWethClaim(bool ok) internal {
        router.setPoolFor(
            address(weth),
            address(claim),
            STABLE_WETH_CLAIM,
            FACTORY,
            ok ? POOL_WETH_CLAIM : address(uint160(uint256(keccak256("bad-pool-weth-claim"))))
        );
    }

    function _setPoolForTokenClaim(bool ok) internal {
        router.setPoolFor(
            address(tokenIn),
            address(claim),
            STABLE_TOKEN_CLAIM,
            FACTORY,
            ok ? POOL_TOKEN_CLAIM : address(uint160(uint256(keccak256("bad-pool-token-claim"))))
        );
    }
}
