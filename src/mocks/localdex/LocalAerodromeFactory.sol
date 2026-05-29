// SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

/// @notice Minimal Aerodrome-style factory for local testing.
/// @dev Uses an explicit register step so we can deploy pools with distinct
///      contract names (making it easy to parse from Foundry broadcast output).
contract LocalAerodromeFactory {
    mapping(address => mapping(address => mapping(bool => address))) internal _getPool;

    event PoolRegistered(address indexed token0, address indexed token1, bool stable, address pool);

    function getPool(address tokenA, address tokenB, bool stable) external view returns (address) {
        (address a, address b) = _sort(tokenA, tokenB);
        return _getPool[a][b][stable];
    }

    function registerPool(address tokenA, address tokenB, bool stable, address pool) external {
        require(tokenA != address(0) && tokenB != address(0) && pool != address(0), "ZERO_ADDR");
        require(tokenA != tokenB, "SAME_TOKEN");
        (address a, address b) = _sort(tokenA, tokenB);
        require(_getPool[a][b][stable] == address(0), "POOL_EXISTS");
        _getPool[a][b][stable] = pool;
        emit PoolRegistered(a, b, stable, pool);
    }

    function _sort(address tokenA, address tokenB) internal pure returns (address, address) {
        return tokenA < tokenB ? (tokenA, tokenB) : (tokenB, tokenA);
    }
}
