// SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

/// @notice EntryTokenRegistry external interface.
/// @dev Core contracts MUST treat this interface as the ABI surface.
interface IEntryTokenRegistry {
    // ------------------------------------------------------------
    // ABI-visible structs
    // ------------------------------------------------------------

    struct TokenConfig {
        bool enabled; // If true, the token is enabled for takeover and Furnace entry routing
        bool directToClaimEnabled; // Furnace-only: if true, use tokenIn -> CLAIM hop
        bool tokenClaimStable; // hop stable flag for tokenIn -> CLAIM
        address tokenClaimPool; // allowlisted pool for tokenIn -> CLAIM
        bool tokenWethStable; // hop stable flag for tokenIn -> WETH
        address tokenWethPool; // allowlisted pool for tokenIn -> WETH
    }

    struct RegistryRoute {
        address tokenIn;
        address tokenOut;
        bool stable;
        address pool; // must equal router.poolFor(tokenIn, tokenOut, stable, factory)
    }

    // ------------------------------------------------------------
    // Guardian
    // ------------------------------------------------------------

    /// @notice Rotate the guardian address. Callable by owner or current guardian.
    function setGuardian(address guardian) external;

    // ------------------------------------------------------------
    // Router config (global)
    // ------------------------------------------------------------

    /// @notice Set the global router/factory/wrappedNative/claimToken wiring (owner only, pre-freeze).
    function setRouterConfig(address router, address factory, address wrappedNative, address claimToken) external;

    function getRouterConfig()
        external
        view
        returns (address router, address factory, address wrappedNative, address claimToken);

    // ------------------------------------------------------------
    // Canonical WETH/CLAIM hop (global)
    // ------------------------------------------------------------

    function setWethClaimHop(bool stable, address expectedPool) external;

    function getWethClaimHop() external view returns (bool stable, address pool);

    // ------------------------------------------------------------
    // Per-token config
    // ------------------------------------------------------------

    /// @notice Set the (enabled, directToClaim, hop pools) configuration for `tokenIn`.
    /// @dev Used by Furnace and MineCore route resolvers; pool addresses MUST match `defaultFactory.getPool`.
    function setTokenConfig(
        address tokenIn,
        bool enabled,
        bool directToClaimEnabled,
        bool tokenClaimStable,
        address tokenClaimPool,
        bool tokenWethStable,
        address tokenWethPool
    ) external;

    function setFurnaceEntryTokenExactReceiptSafe(address tokenIn, bool exactReceiptSafe) external;

    function setTokenEnabled(address tokenIn, bool enabled) external;

    function isFurnaceEntryTokenExactReceiptSafe(address tokenIn) external view returns (bool);

    function getTokenConfig(address tokenIn) external view returns (TokenConfig memory);

    // ------------------------------------------------------------
    // Route resolution
    // ------------------------------------------------------------

    /// @notice Resolve the Furnace entry route for `tokenIn`.
    /// @return route One-hop (tokenIn->CLAIM) when `directToClaimEnabled`, otherwise
    ///         two-hop (tokenIn->WETH->CLAIM) using the canonical WETH/CLAIM hop.
    /// @return routeTokenId 0 when the route is direct-to-CLAIM (single hop), and
    ///         1 when the route is via-WETH (two hops). The encoding is stable for
    ///         v1.0.0 and is provided for off-chain clarity / forward-compat with
    ///         additional route shapes. On-chain consumers MAY equivalently branch
    ///         on `route.length`.
    function resolveFurnaceRoute(address tokenIn)
        external
        view
        returns (RegistryRoute[] memory route, uint256 routeTokenId);

    /// @notice Resolve the allowlisted Takeover route for `tokenIn`. Reverts if not configured.
    function resolveTakeoverRoute(address tokenIn) external view returns (RegistryRoute[] memory route);
}
