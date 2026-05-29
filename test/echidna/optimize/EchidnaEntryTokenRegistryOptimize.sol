// SPDX-License-Identifier: MIT
pragma solidity ^0.8.34;

import {EchidnaSetup} from "../EchidnaSetup.sol";
import {EntryTokenRegistry} from "src/EntryTokenRegistry.sol";
import {IEntryTokenRegistry} from "src/interfaces/IEntryTokenRegistry.sol";
import {MockAerodromeRouter} from "../../mocks/MockAerodromeRouter.sol";
import {MockERC20} from "../../mocks/MockERC20.sol";

/// @title EntryTokenRegistry route-mismatch worst-case search.
/// @notice Optimization-mode harness. Targets route resolution divergence
///         between the registry's view and the live router pool mapping, plus
///         guardian-cooldown excess. Each `optimize_*` function returns an
///         `int256` Echidna maximizes; positive values indicate a routing
///         consistency violation.
contract EchidnaEntryTokenRegistryOptimize is EchidnaSetup {
    EntryTokenRegistry internal registry;
    MockERC20 internal tokenA;
    address internal tokenAWethPool;
    address internal tokenAClaimPool;
    address internal wrongPool;

    int256 internal worstRouteMismatchCount;
    int256 internal worstRouterRewireAfterFreeze;

    constructor() payable {
        _deployAndWire();
        registry = furnaceRegistry;

        tokenA = new MockERC20("EntryTokenA", "ETA");
        tokenAWethPool = address(new MockERC20("ETA-WETH Pool", "ETAW"));
        tokenAClaimPool = address(new MockERC20("ETA-CLAIM Pool", "ETAC"));
        wrongPool = address(new MockERC20("Wrong Pool", "WRNG"));

        dexRouter.setPoolFor(address(tokenA), address(weth), false, mockFactory, tokenAWethPool);
        dexRouter.setPoolFor(address(tokenA), address(claim), false, mockFactory, tokenAClaimPool);

        registry.setTokenConfig(address(tokenA), true, false, false, address(0), false, tokenAWethPool);
        registry.setFurnaceEntryTokenExactReceiptSafe(address(tokenA), true);
    }

    // ================================================================
    // Actions
    // ================================================================

    function action_driftPoolMapping(uint8 mode) public {
        if (mode % 4 == 0) {
            dexRouter.setPoolFor(address(tokenA), address(weth), false, mockFactory, wrongPool);
        } else if (mode % 4 == 1) {
            dexRouter.setPoolFor(address(tokenA), address(weth), false, mockFactory, tokenAWethPool);
        } else if (mode % 4 == 2) {
            dexRouter.setPoolFor(address(tokenA), address(claim), false, mockFactory, wrongPool);
        } else {
            dexRouter.setPoolFor(address(tokenA), address(claim), false, mockFactory, tokenAClaimPool);
        }
    }

    function action_attemptRouterRewire() public {
        MockERC20 altFactory = new MockERC20("AltFactory", "ALTF");
        MockAerodromeRouter altRouter = new MockAerodromeRouter(address(altFactory), address(weth));
        (,, address wrappedNative, address claimToken) = registry.getRouterConfig();
        try registry.setRouterConfig(address(altRouter), address(altFactory), wrappedNative, claimToken) {
            int256 v = int256(uint256(1));
            if (v > worstRouterRewireAfterFreeze) worstRouterRewireAfterFreeze = v;
        } catch {}
    }

    function action_observeRouteMismatch() public {
        IEntryTokenRegistry.TokenConfig memory cfg = registry.getTokenConfig(address(tokenA));
        if (cfg.tokenWethPool == address(0)) return;

        (,, address wrappedNative,) = registry.getRouterConfig();
        bool expectedOk =
            cfg.enabled && _poolMatches(address(tokenA), wrappedNative, cfg.tokenWethStable, cfg.tokenWethPool);

        (bool ok,) =
            address(registry).staticcall(abi.encodeCall(IEntryTokenRegistry.resolveTakeoverRoute, (address(tokenA))));

        if (expectedOk != ok) {
            int256 mismatch = int256(uint256(1));
            if (mismatch > worstRouteMismatchCount) worstRouteMismatchCount = mismatch;
        }
    }

    // ================================================================
    // Optimization targets
    // ================================================================

    /// @notice Worst observed mismatch between expected route resolution (per
    ///         live pool mapping) and the registry's resolution. Must remain
    ///         `<= 0` — drift here means a routing-trust break.
    function optimize_registry_routeMismatchCount() public view returns (int256) {
        return worstRouteMismatchCount;
    }

    /// @notice Worst observed surplus of "router rewire after freeze". The
    ///         router config freezes once pool surfaces are configured; any
    ///         successful rewire after that point is a violation.
    function optimize_registry_routerRewireAfterFreeze() public view returns (int256) {
        return worstRouterRewireAfterFreeze;
    }

    function _poolMatches(address tokenIn, address tokenOut, bool stable, address expectedPool)
        internal
        view
        returns (bool)
    {
        if (expectedPool == address(0) || expectedPool.code.length == 0) return false;
        address livePool = dexRouter.poolFor(tokenIn, tokenOut, stable, mockFactory);
        return livePool == expectedPool;
    }
}
