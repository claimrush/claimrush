// SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

/// @notice Minimal DEX adapter surface used by EntryTokenRegistry.
/// @dev This interface intentionally matches the subset documented in:
///      - docs/architecture/aerodrome-integration-appendix-v1.0.0.md
///      - docs/spec/entry-token-registry-v1.0.0.md
///
/// poolFor(tokenA, tokenB, stable, factory) resolves the pool for the hop;
/// callers pass the factory address (typically the adapter's defaultFactory()).
interface IDexAdapter {
    /// @dev Aerodrome-style swap route.
    /// @dev ABI-isolation — byte-identical to `IAerodromeRouter.Route` BY
    ///      DESIGN. The duplicate declaration isolates IDexAdapter's pinned
    ///      ABI from upstream Aerodrome changes; if Aerodrome ships a v3
    ///      router with a different Route shape, only IAerodromeRouter
    ///      changes (DexAdapter's implementation handles the conversion).
    ///      Any change here MUST be coordinated with IAerodromeRouter.Route.
    struct Route {
        address from;
        address to;
        bool stable;
        address factory;
    }

    function defaultFactory() external view returns (address);

    function weth() external view returns (address);

    /// @notice Resolve the canonical pool address for the (tokenA, tokenB, stable) hop on `factory`.
    function poolFor(address tokenA, address tokenB, bool stable, address factory) external view returns (address pool);

    /// @notice Aerodrome v2-style swap quote: walks `routes[]` and returns per-hop output amounts.
    function getAmountsOut(uint256 amountIn, Route[] calldata routes) external view returns (uint256[] memory amounts);

    /// @notice Swap native ETH along `routes[]` (wraps to WETH internally) with deadline + min-out guarding.
    function swapExactETHForTokens(uint256 amountOutMin, Route[] calldata routes, address to, uint256 deadline)
        external
        payable
        returns (uint256[] memory amounts);

    /// @notice Swap an ERC-20 along `routes[]` with deadline + min-out guarding.
    /// @dev Caller MUST `approve` the adapter for `amountIn` of `routes[0].from`.
    function swapExactTokensForTokens(
        uint256 amountIn,
        uint256 amountOutMin,
        Route[] calldata routes,
        address to,
        uint256 deadline
    ) external returns (uint256[] memory amounts);
}
