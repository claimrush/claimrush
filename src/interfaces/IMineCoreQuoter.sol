// SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

import {IEntryTokenRegistry} from "./IEntryTokenRegistry.sol";

/// @notice View-only quoting helper for MineCore.
/// @dev Deployed once; intended for offchain quoting (safe for onchain `staticcall` as well) to compute `minEthOut` for
///      `MineCore.takeoverWithToken(tokenIn, amountIn, minEthOut, maxPrice)`.
///
/// Design goals:
/// - Keep MineCore runtime bytecode small by placing DEX quote + route validation here.
/// - Mirror MineCore's `_swapTokenToEth` validation exactly:
///   - registry must be set
///   - routes are registry-resolved (no user-supplied routes)
///   - allowlisted pool must match `router.poolFor(...)`
///   - tokenIn == wrappedNative is special-cased (unwrap 1:1)
interface IMineCoreQuoter {
    /// @notice The MineCore this quoter is bound to.
    function mineCore() external view returns (address);

    /// @notice Quote the expected ETH output for `takeoverWithToken`.
    /// @dev Returns:
    /// - ethOut: expected post-swap native ETH credited to the takeover flow
    /// - takeoverPrice: current takeover price at `block.timestamp` (for convenience)
    function quoteTakeoverWithToken(address tokenIn, uint256 amountIn)
        external
        view
        returns (uint256 ethOut, uint256 takeoverPrice);

    /// @notice Resolve and validate the allowlisted takeover route for `tokenIn`.
    /// @dev Special-case: if tokenIn == wrappedNative, returns an empty route (unwrap path).
    function resolveTakeoverRoute(address tokenIn) external view returns (IEntryTokenRegistry.RegistryRoute[] memory);
}
