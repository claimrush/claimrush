// SPDX-License-Identifier: MIT
pragma solidity ^0.8.34;

import {EchidnaSetup} from "./EchidnaSetup.sol";
import {EntryTokenRegistry} from "src/EntryTokenRegistry.sol";
import {IEntryTokenRegistry} from "src/interfaces/IEntryTokenRegistry.sol";
import {MockAerodromeRouter} from "../mocks/MockAerodromeRouter.sol";
import {MockERC20} from "../mocks/MockERC20.sol";

/// @dev Calls registry functions as an arbitrary external account.
contract RegistryActor {
    function setTokenEnabled(IEntryTokenRegistry registry, address token, bool enabled) external returns (bool ok) {
        (ok,) = address(registry).call(abi.encodeCall(IEntryTokenRegistry.setTokenEnabled, (token, enabled)));
    }
}

/// @title Echidna harness for EntryTokenRegistry route/guardian invariants.
/// @dev Covers route integrity, safety gating, guardian cooldown, and admin hardening.
///
/// @dev Corpus-bounding rationale (2026-05-06 rework):
///      Prior revisions accepted `uint256 idx` arguments that were modulo'd
///      against `trackedTokens.length` (== 2) on entry. The high bits of the
///      input had no effect on the contract under test, but Echidna's
///      coverage tracker treated every distinct 256-bit input as a candidate
///      corpus entry. At assertion-mode saturation (cov:25271-25393) the
///      corpus kept growing with equivalent sequences and eventually
///      OOM-killed the worker at 24/30 GB. Narrowing the index args to
///      `uint8` collapses the input space to 256 distinct values (which
///      already cover both tracked tokens via the `% 2` modulo). The
///      narrowed type is wider than the live `trackedTokens.length`, so
///      growing the registry surface in the future remains supported
///      without re-touching this signature surface.
contract EchidnaEntryTokenRegistry is EchidnaSetup {
    EntryTokenRegistry internal registry;
    RegistryActor internal guardianActor;

    MockERC20 internal tokenA;
    MockERC20 internal tokenB;

    address internal tokenAWethPool;
    address internal tokenAClaimPool;
    address internal tokenBWethPool;
    address internal tokenBClaimPool;
    address internal wrongPool;

    address[] internal trackedTokens;

    mapping(address => bool) internal tokenWethStable;
    mapping(address => bool) internal tokenClaimStable;
    mapping(address => address) internal tokenWethPool;
    mapping(address => address) internal tokenClaimPool;

    bool internal sawGuardianEnableSuccess;
    bool internal sawRouterRewireSuccess;
    bool internal sawRenounceOwnershipSuccess;

    constructor() payable {
        _deployAndWire();
        registry = furnaceRegistry;
        guardianActor = new RegistryActor();

        tokenA = new MockERC20("EntryTokenA", "ETA");
        tokenB = new MockERC20("EntryTokenB", "ETB");

        tokenAWethPool = address(new MockERC20("ETA-WETH Pool", "ETAW"));
        tokenAClaimPool = address(new MockERC20("ETA-CLAIM Pool", "ETAC"));
        tokenBWethPool = address(new MockERC20("ETB-WETH Pool", "ETBW"));
        tokenBClaimPool = address(new MockERC20("ETB-CLAIM Pool", "ETBC"));
        wrongPool = address(new MockERC20("Wrong Pool", "WRNG"));

        trackedTokens.push(address(tokenA));
        trackedTokens.push(address(tokenB));

        tokenWethStable[address(tokenA)] = false;
        tokenClaimStable[address(tokenA)] = false;
        tokenWethPool[address(tokenA)] = tokenAWethPool;
        tokenClaimPool[address(tokenA)] = tokenAClaimPool;

        tokenWethStable[address(tokenB)] = true;
        tokenClaimStable[address(tokenB)] = true;
        tokenWethPool[address(tokenB)] = tokenBWethPool;
        tokenClaimPool[address(tokenB)] = tokenBClaimPool;

        _restoreAllPoolMappings();

        registry.setTokenConfig(
            address(tokenA),
            true, // enabled
            false, // directToClaim
            false,
            address(0),
            tokenWethStable[address(tokenA)],
            tokenWethPool[address(tokenA)]
        );
        registry.setTokenConfig(
            address(tokenB),
            true, // enabled
            true, // directToClaim
            tokenClaimStable[address(tokenB)],
            tokenClaimPool[address(tokenB)],
            tokenWethStable[address(tokenB)],
            tokenWethPool[address(tokenB)]
        );
        registry.setFurnaceEntryTokenExactReceiptSafe(address(tokenA), true);
        registry.setFurnaceEntryTokenExactReceiptSafe(address(tokenB), true);

        // Move guardian to a dedicated external actor so guardian-only branch is exercised.
        registry.setGuardian(address(guardianActor));
    }

    // ================================================================
    // Actions
    // ================================================================

    function action_setTokenConfig(uint8 idx, bool enabled, bool directToClaim) public {
        address token = trackedTokens[uint256(idx) % trackedTokens.length];

        address claimPool = directToClaim ? tokenClaimPool[token] : address(0);
        bool claimStable = directToClaim ? tokenClaimStable[token] : false;

        try registry.setTokenConfig(
            token, enabled, directToClaim, claimStable, claimPool, tokenWethStable[token], tokenWethPool[token]
        ) {}
            catch {}
    }

    function action_setTokenEnabled(uint8 idx, bool enabled) public {
        address token = trackedTokens[uint256(idx) % trackedTokens.length];
        try registry.setTokenEnabled(token, enabled) {} catch {}
    }

    function action_setFurnaceExactReceiptSafe(uint8 idx, bool safe) public {
        address token = trackedTokens[uint256(idx) % trackedTokens.length];
        try registry.setFurnaceEntryTokenExactReceiptSafe(token, safe) {} catch {}
    }

    function action_guardianDisable(uint8 idx) public {
        address token = trackedTokens[uint256(idx) % trackedTokens.length];
        guardianActor.setTokenEnabled(registry, token, false);
    }

    function action_guardianEnableAttempt(uint8 idx) public {
        address token = trackedTokens[uint256(idx) % trackedTokens.length];
        if (guardianActor.setTokenEnabled(registry, token, true)) {
            sawGuardianEnableSuccess = true;
        }
    }

    /// @dev Simulate router mapping drift to test runtime route validation.
    function action_driftRouterMapping(uint8 idx, uint8 mode) public {
        address token = trackedTokens[uint256(idx) % trackedTokens.length];
        bool twStable = tokenWethStable[token];
        bool tcStable = tokenClaimStable[token];

        if (mode % 6 == 0) {
            dexRouter.setPoolFor(token, address(weth), twStable, mockFactory, wrongPool);
        } else if (mode % 6 == 1) {
            dexRouter.setPoolFor(token, address(weth), twStable, mockFactory, tokenWethPool[token]);
        } else if (mode % 6 == 2) {
            dexRouter.setPoolFor(token, address(claim), tcStable, mockFactory, wrongPool);
        } else if (mode % 6 == 3) {
            dexRouter.setPoolFor(token, address(claim), tcStable, mockFactory, tokenClaimPool[token]);
        } else if (mode % 6 == 4) {
            (bool hopStable,) = registry.getWethClaimHop();
            dexRouter.setPoolFor(address(weth), address(claim), hopStable, mockFactory, wrongPool);
        } else {
            (bool hopStable,) = registry.getWethClaimHop();
            dexRouter.setPoolFor(address(weth), address(claim), hopStable, mockFactory, wethClaimPool);
        }
    }

    /// @dev Must fail once pool surfaces are configured (router/factory freeze-by-wiring).
    function action_attemptRouterRewire() public {
        MockERC20 altFactory = new MockERC20("AltFactory", "ALTF");
        MockAerodromeRouter altRouter = new MockAerodromeRouter(address(altFactory), address(weth));
        (,, address wrappedNative, address claimToken) = registry.getRouterConfig();

        try registry.setRouterConfig(address(altRouter), address(altFactory), wrappedNative, claimToken) {
            sawRouterRewireSuccess = true;
        } catch {}
    }

    function action_attemptRenounceOwnership() public {
        (bool ok,) = address(registry).call(abi.encodeWithSignature("renounceOwnership()"));
        if (ok) {
            sawRenounceOwnershipSuccess = true;
        }
    }

    function action_restoreMappings() public {
        _restoreAllPoolMappings();
    }

    // ================================================================
    // Properties
    // ================================================================

    function echidna_guardian_cannot_enable() public view returns (bool) {
        return !sawGuardianEnableSuccess;
    }

    function echidna_router_rewire_blocked_after_config() public view returns (bool) {
        return !sawRouterRewireSuccess;
    }

    function echidna_renounce_ownership_blocked() public view returns (bool) {
        return !sawRenounceOwnershipSuccess;
    }

    function echidna_enabled_token_respects_guardian_cooldown() public view returns (bool) {
        for (uint256 i = 0; i < trackedTokens.length; i++) {
            address token = trackedTokens[i];
            IEntryTokenRegistry.TokenConfig memory cfg = registry.getTokenConfig(token);
            if (cfg.tokenWethPool == address(0)) continue;
            if (cfg.enabled && registry.guardianDisabledUntil(token) > block.timestamp) return false;
        }
        return true;
    }

    function echidna_takeover_route_consistency() public view returns (bool) {
        (,, address wrappedNative,) = registry.getRouterConfig();
        for (uint256 i = 0; i < trackedTokens.length; i++) {
            address token = trackedTokens[i];
            IEntryTokenRegistry.TokenConfig memory cfg = registry.getTokenConfig(token);
            if (cfg.tokenWethPool == address(0)) continue;

            bool expectedOk = cfg.enabled && _poolMatches(token, wrappedNative, cfg.tokenWethStable, cfg.tokenWethPool);
            (bool ok, bytes memory data) =
                address(registry).staticcall(abi.encodeCall(IEntryTokenRegistry.resolveTakeoverRoute, (token)));
            if (expectedOk != ok) return false;
            if (!ok) continue;

            IEntryTokenRegistry.RegistryRoute[] memory route = abi.decode(data, (IEntryTokenRegistry.RegistryRoute[]));
            if (route.length != 1) return false;
            if (route[0].tokenIn != token) return false;
            if (route[0].tokenOut != wrappedNative) return false;
            if (route[0].stable != cfg.tokenWethStable) return false;
            if (route[0].pool != cfg.tokenWethPool) return false;
        }
        return true;
    }

    function echidna_furnace_route_gating_and_shape() public view returns (bool) {
        (,, address wrappedNative, address claimToken) = registry.getRouterConfig();
        (bool hopStable, address hopPool) = registry.getWethClaimHop();

        for (uint256 i = 0; i < trackedTokens.length; i++) {
            address token = trackedTokens[i];
            IEntryTokenRegistry.TokenConfig memory cfg = registry.getTokenConfig(token);
            if (cfg.tokenWethPool == address(0)) continue;

            bool safe = registry.isFurnaceEntryTokenExactReceiptSafe(token);
            bool expectedOk = cfg.enabled && safe;
            if (expectedOk) {
                if (cfg.directToClaimEnabled) {
                    expectedOk = _poolMatches(token, claimToken, cfg.tokenClaimStable, cfg.tokenClaimPool);
                } else {
                    expectedOk = hopPool != address(0)
                        && _poolMatches(token, wrappedNative, cfg.tokenWethStable, cfg.tokenWethPool)
                        && _poolMatches(wrappedNative, claimToken, hopStable, hopPool);
                }
            }

            (bool ok, bytes memory data) =
                address(registry).staticcall(abi.encodeCall(IEntryTokenRegistry.resolveFurnaceRoute, (token)));
            if (expectedOk != ok) return false;
            if (!ok) continue;

            (IEntryTokenRegistry.RegistryRoute[] memory route, uint256 routeTokenId) =
                abi.decode(data, (IEntryTokenRegistry.RegistryRoute[], uint256));
            if (cfg.directToClaimEnabled) {
                if (route.length != 1 || routeTokenId != 0) return false;
                if (route[0].tokenIn != token || route[0].tokenOut != claimToken) return false;
                if (route[0].stable != cfg.tokenClaimStable) return false;
                if (route[0].pool != cfg.tokenClaimPool) return false;
            } else {
                if (route.length != 2 || routeTokenId != 1) return false;
                if (route[0].tokenIn != token || route[0].tokenOut != wrappedNative) return false;
                if (route[0].stable != cfg.tokenWethStable) return false;
                if (route[0].pool != cfg.tokenWethPool) return false;
                if (route[1].tokenIn != wrappedNative || route[1].tokenOut != claimToken) return false;
                if (route[1].stable != hopStable) return false;
                if (route[1].pool != hopPool) return false;
            }
        }
        return true;
    }

    // ================================================================
    // Internal helpers
    // ================================================================

    function _poolMatches(address tokenIn, address tokenOut, bool stable, address expectedPool)
        internal
        view
        returns (bool)
    {
        if (expectedPool == address(0) || expectedPool.code.length == 0) return false;
        address livePool = dexRouter.poolFor(tokenIn, tokenOut, stable, mockFactory);
        return livePool == expectedPool;
    }

    function _restoreAllPoolMappings() internal {
        for (uint256 i = 0; i < trackedTokens.length; i++) {
            address token = trackedTokens[i];
            dexRouter.setPoolFor(token, address(weth), tokenWethStable[token], mockFactory, tokenWethPool[token]);
            dexRouter.setPoolFor(token, address(claim), tokenClaimStable[token], mockFactory, tokenClaimPool[token]);
        }
        (bool hopStable,) = registry.getWethClaimHop();
        dexRouter.setPoolFor(address(weth), address(claim), hopStable, mockFactory, wethClaimPool);
    }
}
