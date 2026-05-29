// SPDX-License-Identifier: MIT
pragma solidity ^0.8.34;

import {
    TransparentUpgradeableProxy
} from "lib/openzeppelin-contracts/contracts/proxy/transparent/TransparentUpgradeableProxy.sol";

/// @notice EIP-7702 delegation rejection shared across every named runtime proxy.
///         The 7702 designator is exactly 23 bytes prefixed by `0xEF0100`. A delegated
///         EOA holding the proxy admin role can expose public-executor code that lets
///         arbitrary callers perform proxy admin upgrades. Bare EOAs (`code.length == 0`)
///         and normal contracts pass through unchanged.
library DelegatedEOAGuard {
    error DelegatedEOAOwner(address account);

    function reject(address account) internal view {
        if (account.code.length != 23) return;
        bytes3 prefix;
        assembly ("memory-safe") {
            extcodecopy(account, 0x00, 0x00, 0x03)
            prefix := mload(0x00)
        }
        if (prefix == 0xEF0100) revert DelegatedEOAOwner(account);
    }
}

/// @notice Named transparent proxy for the canonical MineCore runtime address.
contract MineCoreProxy is TransparentUpgradeableProxy {
    constructor(address implementation, address initialOwner, bytes memory data)
        TransparentUpgradeableProxy(implementation, _validatedOwner(initialOwner), data)
    {}

    function _validatedOwner(address initialOwner) private view returns (address) {
        DelegatedEOAGuard.reject(initialOwner);
        return initialOwner;
    }
}

/// @notice Named transparent proxy for the canonical Furnace runtime address.
contract FurnaceProxy is TransparentUpgradeableProxy {
    constructor(address implementation, address initialOwner, bytes memory data)
        TransparentUpgradeableProxy(implementation, _validatedOwner(initialOwner), data)
    {}

    function _validatedOwner(address initialOwner) private view returns (address) {
        DelegatedEOAGuard.reject(initialOwner);
        return initialOwner;
    }
}

/// @notice Named transparent proxy for the canonical MarketRouter runtime address.
contract MarketRouterProxy is TransparentUpgradeableProxy {
    constructor(address implementation, address initialOwner, bytes memory data)
        TransparentUpgradeableProxy(implementation, _validatedOwner(initialOwner), data)
    {}

    function _validatedOwner(address initialOwner) private view returns (address) {
        DelegatedEOAGuard.reject(initialOwner);
        return initialOwner;
    }
}

/// @notice Named transparent proxy for the canonical ShareholderRoyalties runtime address.
contract ShareholderRoyaltiesProxy is TransparentUpgradeableProxy {
    constructor(address implementation, address initialOwner, bytes memory data)
        TransparentUpgradeableProxy(implementation, _validatedOwner(initialOwner), data)
    {}

    function _validatedOwner(address initialOwner) private view returns (address) {
        DelegatedEOAGuard.reject(initialOwner);
        return initialOwner;
    }
}
