// SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

import {Errors} from "./lib/Errors.sol";

import {IDexAdapter} from "./interfaces/IDexAdapter.sol";
import {IEntryTokenRegistry} from "./interfaces/IEntryTokenRegistry.sol";

import {IMineCoreQuoter} from "./interfaces/IMineCoreQuoter.sol";

/// @dev Minimal MineCore read surface needed for token takeover quoting.
interface IMineCoreTakeoverRead {
    function takeoversPaused() external view returns (bool);
    function entryTokenRegistry() external view returns (address);
    function claim() external view returns (address);
    function getTakeoverPrice(uint256 timestamp) external view returns (uint256);
}

/// @notice View-only quoting contract for MineCore token takeovers.
/// @dev Mirrors MineCore._swapTokenToEth(...) validation and uses
///      `getAmountsOut` for the token->WETH path and treats the result as ETH-equivalent after unwrap.
contract MineCoreQuoter is IMineCoreQuoter {
    // Immutable wiring

    address public immutable mineCore;

    constructor(address mineCore_) {
        if (mineCore_ == address(0)) revert Errors.ZeroAddress();
        // Reject EOAs (`code.length == 0`) AND EIP-7702 delegated EOAs whose code is
        // exactly the 23-byte `0xEF 0x01 0x00 || delegate` designator. Requiring
        // `> 23` excludes both classes while remaining trivially true for any real
        // deployed contract (typical runtime sizes are KBs).
        if (mineCore_.code.length <= 23) revert Errors.NotAContract();
        bytes32 _codehash;
        assembly ("memory-safe") {
            _codehash := extcodehash(mineCore_)
        }
        if (_codehash == 0 || _codehash == keccak256("")) revert Errors.NotAContract();

        mineCore = mineCore_;
    }

    function _whenTakeoversEnabled() internal view {
        if (IMineCoreTakeoverRead(mineCore).takeoversPaused()) revert Errors.TakeoversPaused();
    }

    function _requireRegistryAndRouterConfig()
        internal
        view
        returns (IEntryTokenRegistry reg, address router, address factory, address wrappedNative)
    {
        address regAddr = IMineCoreTakeoverRead(mineCore).entryTokenRegistry();
        if (regAddr == address(0) || regAddr.code.length == 0) revert Errors.RouterConfigNotSet();

        reg = IEntryTokenRegistry(regAddr);
        address claimToken;
        (router, factory, wrappedNative, claimToken) = reg.getRouterConfig();

        if (router == address(0) || factory == address(0) || wrappedNative == address(0) || claimToken == address(0)) {
            revert Errors.RouterConfigNotSet();
        }

        // Defensive: require contract code for router/factory/tokens to avoid opaque ABI decode reverts.
        if (
            router.code.length == 0 || factory.code.length == 0 || wrappedNative.code.length == 0
                || claimToken.code.length == 0
        ) {
            revert Errors.NotAContract();
        }

        // Governance invariant: registry's CLAIM token must match this MineCore's CLAIM.
        if (claimToken != IMineCoreTakeoverRead(mineCore).claim()) revert Errors.InvalidToken();
    }

    // External view API

    function quoteTakeoverWithToken(address tokenIn, uint256 amountIn)
        external
        view
        returns (uint256 ethOut, uint256 takeoverPrice)
    {
        _whenTakeoversEnabled();

        if (tokenIn == address(0)) revert Errors.ZeroAddress();
        if (amountIn == 0) revert Errors.AmountZero();
        if (tokenIn == IMineCoreTakeoverRead(mineCore).claim()) revert Errors.InvalidToken();

        (IEntryTokenRegistry reg, address router, address factory, address wrappedNative) =
            _requireRegistryAndRouterConfig();

        // Special-case: tokenIn is wrapped native (WETH). Unwrap is 1:1.
        if (tokenIn == wrappedNative) {
            ethOut = amountIn;
        } else {
            IEntryTokenRegistry.RegistryRoute[] memory regRoutes = reg.resolveTakeoverRoute(tokenIn);
            if (regRoutes.length != 1) revert Errors.InvalidToken();

            IEntryTokenRegistry.RegistryRoute memory r = regRoutes[0];
            if (r.tokenIn != tokenIn || r.tokenOut != wrappedNative) revert Errors.InvalidToken();

            // Defensive: registry pool must match router.poolFor.
            address poolFor = IDexAdapter(router).poolFor(r.tokenIn, r.tokenOut, r.stable, factory);
            if (poolFor != r.pool) revert Errors.InvalidPool();

            IDexAdapter.Route[] memory routes = new IDexAdapter.Route[](1);
            routes[0] = IDexAdapter.Route({from: r.tokenIn, to: r.tokenOut, stable: r.stable, factory: factory});
            ethOut = _boundedGetAmountsOut(router, amountIn, routes);
        }

        // Convenience: return current takeover price for side-by-side comparison.
        takeoverPrice = IMineCoreTakeoverRead(mineCore).getTakeoverPrice(block.timestamp);
    }

    function resolveTakeoverRoute(address tokenIn)
        external
        view
        returns (IEntryTokenRegistry.RegistryRoute[] memory route)
    {
        if (tokenIn == address(0)) revert Errors.ZeroAddress();
        if (tokenIn == IMineCoreTakeoverRead(mineCore).claim()) revert Errors.InvalidToken();

        (IEntryTokenRegistry reg, address router, address factory, address wrappedNative) =
            _requireRegistryAndRouterConfig();

        // Special-case: wrapped native has an implicit 1:1 unwrap route.
        if (tokenIn == wrappedNative) {
            return new IEntryTokenRegistry.RegistryRoute[](0);
        }

        route = reg.resolveTakeoverRoute(tokenIn);
        if (route.length != 1) revert Errors.InvalidToken();

        IEntryTokenRegistry.RegistryRoute memory r = route[0];
        if (r.tokenIn != tokenIn || r.tokenOut != wrappedNative) revert Errors.InvalidToken();

        // Defensive: registry pool must match router.poolFor.
        address poolFor = IDexAdapter(router).poolFor(r.tokenIn, r.tokenOut, r.stable, factory);
        if (poolFor != r.pool) revert Errors.InvalidPool();
    }

    /// @dev Bounded-returndata wrapper around IDexAdapter.getAmountsOut.
    ///      Caps returndatacopy to prevent a compromised router from inflating
    ///      memory (return-bomb) inside this view call's gas budget.
    function _boundedGetAmountsOut(address router, uint256 amountIn, IDexAdapter.Route[] memory routes)
        internal
        view
        returns (uint256 amountOut)
    {
        // Reject empty routes — prevents degenerate maxRd and echo-back quotes.
        if (routes.length == 0) revert Errors.QuoteCallFailed();
        bytes memory payload = abi.encodeCall(IDexAdapter.getAmountsOut, (amountIn, routes));
        uint256 maxRd = 64 + 32 * (routes.length + 1);
        bool ok;
        bytes memory rd;
        // Gas cap policy: 500k for DEX quote calls (Aerodrome StablePool Newton
        // iteration is SLOAD-heavy). Identity probes use 100k. The block uses the
        // canonical "memory-safe" pattern: read the free memory pointer at 0x40,
        // bump it by `32 + ceil32(rdLen)` to reserve the bytes blob, then write
        // length + truncated returndata into the reservation. No memory is touched
        // outside this allocation.
        assembly ("memory-safe") {
            let ptr := add(payload, 0x20)
            let len := mload(payload)
            ok := staticcall(500000, router, ptr, len, 0, 0)
            let rdLen := returndatasize()
            if gt(rdLen, maxRd) { rdLen := maxRd }
            rd := mload(0x40)
            mstore(0x40, add(add(rd, 0x20), and(add(rdLen, 0x1f), not(0x1f))))
            mstore(rd, rdLen)
            returndatacopy(add(rd, 0x20), 0, rdLen)
        }
        if (!ok) revert Errors.QuoteCallFailed();
        // Minimum 64 bytes for a valid ABI-encoded uint256[] (32 offset + 32 length).
        if (rd.length < 64) revert Errors.QuoteCallFailed();
        uint256[] memory amounts = abi.decode(rd, (uint256[]));
        if (amounts.length == 0) revert Errors.QuoteCallFailed();
        if (amounts.length != routes.length + 1) revert Errors.QuoteCallFailed();
        // amounts[0] must echo the requested amountIn; reject adapter mis-computation.
        if (amounts[0] != amountIn) revert Errors.QuoteCallFailed();
        // Reject zero output — a DEX returning 0 means "no liquidity" and must
        // not be surfaced as a valid quote (callers may derive minEthOut from it).
        if (amounts[amounts.length - 1] == 0) revert Errors.QuoteCallFailed();
        amountOut = amounts[amounts.length - 1];
    }
}
