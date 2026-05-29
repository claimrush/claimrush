// SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

/// @notice Aerodrome-compatible factory mock for testnet deployments.
/// @dev Returns deterministic pool addresses for any token pair via CREATE2
///      hashing, even before the pool contract exists on-chain. This satisfies
///      Deploy.s.sol's `require(poolFor(...) != address(0))` without needing
///      pre-registered pools.
///      Registered pools take priority over computed addresses.
contract TestnetAerodromeFactory {
    mapping(address => mapping(address => mapping(bool => address))) internal _pools;

    event PoolRegistered(address indexed token0, address indexed token1, bool stable, address pool);

    function getPool(address tokenA, address tokenB, bool stable) external view returns (address) {
        (address a, address b) = _sort(tokenA, tokenB);
        address registered = _pools[a][b][stable];
        if (registered != address(0)) return registered;
        return _computeDeterministicPool(a, b, stable);
    }

    function registerPool(address tokenA, address tokenB, bool stable, address pool) external {
        require(tokenA != address(0) && tokenB != address(0) && pool != address(0), "ZERO_ADDR");
        require(tokenA != tokenB, "SAME_TOKEN");
        (address a, address b) = _sort(tokenA, tokenB);
        require(_pools[a][b][stable] == address(0), "POOL_EXISTS");
        _pools[a][b][stable] = pool;
        emit PoolRegistered(a, b, stable, pool);
    }

    function _computeDeterministicPool(address token0, address token1, bool stable) internal view returns (address) {
        return address(
            uint160(
                uint256(
                    keccak256(
                        abi.encodePacked(
                            hex"ff",
                            address(this),
                            keccak256(abi.encodePacked(token0, token1, stable)),
                            bytes32(uint256(0xdeadbeef))
                        )
                    )
                )
            )
        );
    }

    function _sort(address tokenA, address tokenB) internal pure returns (address, address) {
        return tokenA < tokenB ? (tokenA, tokenB) : (tokenB, tokenA);
    }
}
