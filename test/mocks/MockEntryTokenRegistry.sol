// SPDX-License-Identifier: MIT
pragma solidity ^0.8.34;

import {IEntryTokenRegistry} from "src/interfaces/IEntryTokenRegistry.sol";

/// @notice Mock registry with no router config (for RouterConfigNotSet tests).
/// @dev Implements minimal IEntryTokenRegistry; getRouterConfig returns zeros.
contract MockEntryTokenRegistry is IEntryTokenRegistry {
    address private _router;
    address private _factory;
    address private _wrappedNative;
    address private _claimToken;
    bool private _wethClaimStable;
    address private _wethClaimPool;
    mapping(address => bool) private _furnaceEntryTokenExactReceiptSafe;

    function setRouterConfig(address router, address factory, address wrappedNative, address claimToken)
        external
        override
    {
        _router = router;
        _factory = factory;
        _wrappedNative = wrappedNative;
        _claimToken = claimToken;
    }

    function getRouterConfig()
        external
        view
        override
        returns (address router, address factory, address wrappedNative, address claimToken)
    {
        return (_router, _factory, _wrappedNative, _claimToken);
    }

    function setWethClaimHop(bool stable, address pool) external override {
        _wethClaimStable = stable;
        _wethClaimPool = pool;
    }

    function getWethClaimHop() external view override returns (bool, address) {
        return (_wethClaimStable, _wethClaimPool);
    }

    function setTokenConfig(address, bool, bool, bool, address, bool, address) external override {}

    function setFurnaceEntryTokenExactReceiptSafe(address tokenIn, bool exactReceiptSafe) external override {
        _furnaceEntryTokenExactReceiptSafe[tokenIn] = exactReceiptSafe;
    }

    function setTokenEnabled(address, bool) external override {}

    function setGuardian(address) external override {}

    function isFurnaceEntryTokenExactReceiptSafe(address tokenIn) external view override returns (bool) {
        return _furnaceEntryTokenExactReceiptSafe[tokenIn];
    }

    function getTokenConfig(address) external pure override returns (TokenConfig memory) {
        return TokenConfig(false, false, false, address(0), false, address(0));
    }

    function resolveFurnaceRoute(address) external pure override returns (RegistryRoute[] memory, uint256) {
        return (new RegistryRoute[](0), 0);
    }

    function resolveTakeoverRoute(address) external pure override returns (RegistryRoute[] memory) {
        return new RegistryRoute[](0);
    }
}
