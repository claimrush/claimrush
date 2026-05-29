// SPDX-License-Identifier: MIT
pragma solidity ^0.8.34;

import {Test} from "forge-std/Test.sol";

import {EntryTokenRegistry} from "src/EntryTokenRegistry.sol";
import {Errors} from "src/lib/Errors.sol";

import {IEntryTokenRegistry} from "src/interfaces/IEntryTokenRegistry.sol";

import {MockAerodromeRouter} from "test/mocks/MockAerodromeRouter.sol";
import {MockERC20} from "test/mocks/MockERC20.sol";
import {MockWETH} from "test/mocks/MockWETH.sol";

/// @dev Focused state-machine invariants for EntryTokenRegistry's
///      directToClaim wiring:
///      - When directToClaimEnabled=true => 1-hop route token->CLAIM (routeTokenId=0)
///      - When directToClaimEnabled=false => 2-hop route token->WETH->CLAIM (routeTokenId=1)
///      - setTokenConfig must reject token->CLAIM pools that don't match router.poolFor(...)
contract EntryTokenRegistry_DirectToClaim_StateMachine_Invariants is Test {
    address internal constant OWNER = address(0xA11CE);

    address internal constant FACTORY = address(0xFACA7);

    bool internal constant STABLE_TOKEN_WETH = false;
    bool internal constant STABLE_WETH_CLAIM = false;
    bool internal constant STABLE_TOKEN_CLAIM = false;

    address internal constant POOL_TOKEN_WETH = address(0x1111);
    address internal constant POOL_WETH_CLAIM = address(0x2222);
    address internal constant POOL_TOKEN_CLAIM = address(0x3333);
    address internal constant BAD_POOL = address(0xBADD);

    MockWETH internal weth;
    MockERC20 internal claim;
    MockERC20 internal tokenIn;
    MockAerodromeRouter internal router;

    EntryTokenRegistry internal reg;

    // Mirror the intended registry config in simple state vars.
    bool internal tokenEnabled = true;
    bool internal directToClaimEnabled = false;

    bool internal poolOkTW = true;
    bool internal poolOkTC = true;

    function setUp() public {
        weth = new MockWETH();
        claim = new MockERC20("Claim", "CLAIM");
        tokenIn = new MockERC20("TokenIn", "TIN");

        router = new MockAerodromeRouter(FACTORY, address(weth));

        // Pool allowlist must exist before config setters validate poolFor(...)
        _setPoolForTokenWeth(true);
        _setPoolForWethClaim(true);
        _setPoolForTokenClaim(true);

        // FACTORY is a bare address; give it bytecode so it passes NotAContract checks in setRouterConfig.
        vm.etch(FACTORY, hex"00");
        vm.etch(POOL_TOKEN_WETH, hex"00");
        vm.etch(POOL_WETH_CLAIM, hex"00");
        vm.etch(POOL_TOKEN_CLAIM, hex"00");
        vm.etch(BAD_POOL, hex"00");

        reg = new EntryTokenRegistry(OWNER);

        vm.startPrank(OWNER);
        reg.setRouterConfig(address(router), FACTORY, address(weth), address(claim));
        reg.setWethClaimHop(STABLE_WETH_CLAIM, POOL_WETH_CLAIM);

        // Start with via-WETH route (directToClaim disabled), but store tokenClaim fields for later.
        reg.setTokenConfig(
            address(tokenIn),
            true, // enabled
            false, // directToClaim
            STABLE_TOKEN_CLAIM,
            POOL_TOKEN_CLAIM,
            STABLE_TOKEN_WETH,
            POOL_TOKEN_WETH
        );
        reg.setFurnaceEntryTokenExactReceiptSafe(address(tokenIn), true);
        vm.stopPrank();

        _assertRouteShape();
    }

    function testFuzz_stateMachine_registryDirectToClaim(uint256 seed) public {
        uint256 steps = 20;
        for (uint256 i; i < steps; i++) {
            seed = uint256(keccak256(abi.encode(seed, i)));
            uint256 action = seed % 7;

            if (action == 0) {
                _toggleDirectToClaim();
            } else if (action == 1) {
                _toggleTokenEnabled();
            } else if (action == 2) {
                _togglePoolTokenWeth();
            } else if (action == 3) {
                _togglePoolTokenClaim();
            } else if (action == 4) {
                _attemptBadDirectToClaimPool();
            } else if (action == 5) {
                _attemptZeroPoolDirectToClaim();
            } else {
                _assertRouteShape();
            }
        }
    }

    // ------------------------------------------------------------
    // Actions
    // ------------------------------------------------------------

    function _toggleDirectToClaim() internal {
        bool next = !directToClaimEnabled;

        // setTokenConfig validates token->WETH pool always; token->CLAIM only when enabling direct.
        bool expectOk = poolOkTW && (!next || poolOkTC);

        vm.prank(OWNER);
        (bool ok,) = address(reg)
            .call(
                abi.encodeCall(
                    reg.setTokenConfig,
                    (
                        address(tokenIn),
                        tokenEnabled,
                        next,
                        STABLE_TOKEN_CLAIM,
                        POOL_TOKEN_CLAIM,
                        STABLE_TOKEN_WETH,
                        POOL_TOKEN_WETH
                    )
                )
            );

        assertEq(ok, expectOk);
        if (ok) {
            directToClaimEnabled = next;
        }

        _assertRouteShape();
    }

    function _toggleTokenEnabled() internal {
        bool desired = !tokenEnabled;
        // setTokenEnabled(true) re-validates router.poolFor(...) against stored pools.
        bool expectOk = !desired || (poolOkTW && (!directToClaimEnabled || poolOkTC));

        vm.prank(OWNER);
        (bool ok,) = address(reg).call(abi.encodeCall(reg.setTokenEnabled, (address(tokenIn), desired)));

        assertEq(ok, expectOk);
        if (ok) {
            tokenEnabled = desired;
        }

        _assertRouteShape();
    }

    function _togglePoolTokenWeth() internal {
        poolOkTW = !poolOkTW;
        _setPoolForTokenWeth(poolOkTW);
    }

    function _togglePoolTokenClaim() internal {
        poolOkTC = !poolOkTC;
        _setPoolForTokenClaim(poolOkTC);
    }

    function _attemptBadDirectToClaimPool() internal {
        // Choose a pool that is guaranteed to mismatch router.poolFor(...), even if the mock router's
        // poolFor mapping has been flipped (simulating "drift").
        address wrongPool = poolOkTC ? BAD_POOL : POOL_TOKEN_CLAIM;

        // This call should always fail (InvalidPool) when directToClaim=true and tokenClaimPool != router.poolFor(...).
        // It can also fail earlier if token->WETH pool mapping is broken.
        vm.prank(OWNER);
        (bool ok, bytes memory data) = address(reg)
            .call(
                abi.encodeCall(
                    reg.setTokenConfig,
                    (
                        address(tokenIn),
                        tokenEnabled,
                        true, // directToClaim
                        STABLE_TOKEN_CLAIM,
                        wrongPool, // WRONG pool
                        STABLE_TOKEN_WETH,
                        POOL_TOKEN_WETH
                    )
                )
            );

        // If token->WETH mapping is broken, we expect InvalidPool too, just earlier.
        assertFalse(ok);
        if (data.length >= 4) {
            bytes4 sel;
            assembly {
                sel := mload(add(data, 0x20))
            }
            assertTrue(sel == Errors.InvalidPool.selector);
        }

        // Confirm config wasn't mutated.
        _assertRouteShape();
    }

    function _attemptZeroPoolDirectToClaim() internal {
        vm.prank(OWNER);
        (bool ok, bytes memory data) = address(reg)
            .call(
                abi.encodeCall(
                    reg.setTokenConfig,
                    (
                        address(tokenIn),
                        tokenEnabled,
                        true, // directToClaim
                        STABLE_TOKEN_CLAIM,
                        address(0), // ZERO pool
                        STABLE_TOKEN_WETH,
                        POOL_TOKEN_WETH
                    )
                )
            );

        assertFalse(ok);
        if (data.length >= 4) {
            bytes4 sel;
            assembly {
                sel := mload(add(data, 0x20))
            }
            // Either ZeroAddress (pool=0) or InvalidPool (if token->WETH mapping is broken).
            assertTrue(sel == Errors.ZeroAddress.selector || sel == Errors.InvalidPool.selector);
        }

        _assertRouteShape();
    }

    // ------------------------------------------------------------
    // Invariants
    // ------------------------------------------------------------

    function _assertRouteShape() internal {
        if (!tokenEnabled) {
            vm.expectRevert(Errors.TokenNotEnabled.selector);
            reg.resolveFurnaceRoute(address(tokenIn));
            return;
        }

        // resolveFurnaceRoute validates pools at resolution time.
        bool poolsOk = directToClaimEnabled ? poolOkTC : poolOkTW;
        if (!poolsOk) {
            vm.expectRevert(Errors.InvalidPool.selector);
            reg.resolveFurnaceRoute(address(tokenIn));
            return;
        }

        (IEntryTokenRegistry.RegistryRoute[] memory route, uint256 routeTokenId) =
            reg.resolveFurnaceRoute(address(tokenIn));

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

    // ------------------------------------------------------------
    // Pool mapping helpers
    // ------------------------------------------------------------

    function _setPoolForTokenWeth(bool ok) internal {
        router.setPoolFor(address(tokenIn), address(weth), STABLE_TOKEN_WETH, FACTORY, ok ? POOL_TOKEN_WETH : BAD_POOL);
    }

    function _setPoolForWethClaim(bool ok) internal {
        router.setPoolFor(address(weth), address(claim), STABLE_WETH_CLAIM, FACTORY, ok ? POOL_WETH_CLAIM : BAD_POOL);
    }

    function _setPoolForTokenClaim(bool ok) internal {
        router.setPoolFor(
            address(tokenIn), address(claim), STABLE_TOKEN_CLAIM, FACTORY, ok ? POOL_TOKEN_CLAIM : BAD_POOL
        );
    }
}
