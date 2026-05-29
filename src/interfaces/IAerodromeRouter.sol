// SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

/// @notice Minimal Aerodrome v2 router interface used by LpStakingVault7D.
/// @dev Matches the subset referenced in docs/architecture/aerodrome-integration-appendix-v1.0.0.md.
/// @dev v2 commitment — Aerodrome v2 router on Base. If Aerodrome ships a v3
///      deployment with a different `Route` shape (e.g., tick-spacing /
///      fee-tier fields), our consumers (LpStakingVault7D fee-harvest swaps)
///      will revert when pointed at a v3 router address. A coordinated
///      interface + adapter update is required for any future Aerodrome
///      version migration. See scripts/ci/check-aerodrome-abi.mjs (proposed)
///      for an ABI sync guard.
interface IAerodromeRouter {
    /// @dev ABI-isolation — byte-identical to `IDexAdapter.Route` BY DESIGN.
    ///      DexAdapter's implementation converts between the two; the
    ///      separate declarations prevent v3 ripple into IDexAdapter's ABI.
    struct Route {
        address from;
        address to;
        bool stable;
        address factory;
    }

    function getAmountsOut(uint256 amountIn, Route[] calldata routes) external view returns (uint256[] memory amounts);

    function swapExactTokensForTokens(
        uint256 amountIn,
        uint256 amountOutMin,
        Route[] calldata routes,
        address to,
        uint256 deadline
    ) external returns (uint256[] memory amounts);
}
