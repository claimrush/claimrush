// SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

import {IPoolFactory} from "../../interfaces/IPoolFactory.sol";
import {TestnetSwapPool} from "./TestnetSwapPool.sol";

/// @notice CREATE2-capable Aerodrome factory mock for Sepolia.
/// @dev Solves the chicken-and-egg problem: Deploy.s.sol needs a non-zero pool
///      address before the pool is deployed.  getPool() returns the CREATE2-
///      predicted address for any pair, and createPool() deploys at exactly
///      that address.
///
///      Implements IPoolFactory (getPool + createPool).
///
///      NOTE: LaunchController.finalizeGenesis() will never call createPool()
///      with this factory because getPool() always returns a non-zero predicted
///      address.  Deploy.s.sol materializes the pool on testnet (chainId 84532)
///      before vaults are deployed, so by finalization time the pool already
///      exists at the predicted address.  createPool() is onlyOwner (the
///      deployer EOA) and is NOT callable by LaunchController.
contract TestnetSwapFactory is IPoolFactory {
    address public immutable wethAddress;
    address public immutable owner;
    /// @dev Matches the post-genesis Sepolia pool ratio so spot price is
    ///      continuous across `LaunchController.finalizeGenesis()`. Sepolia
    ///      genesis seeds 5 ETH against (50 CLAIM/sec * 86400s) = 4.32M CLAIM,
    ///      i.e. 864_000 CLAIM per WETH.
    uint256 public defaultRate = 864_000;

    mapping(address => mapping(address => mapping(bool => address))) internal _pools;

    event PoolCreated(address indexed token0, address indexed token1, bool stable, address pool);

    modifier onlyOwner() {
        require(msg.sender == owner, "NOT_OWNER");
        _;
    }

    constructor(address weth_) {
        require(weth_ != address(0), "ZERO_WETH");
        wethAddress = weth_;
        owner = msg.sender;
    }

    /// @notice Set the default CLAIM-per-WETH rate for newly created pools.
    function setDefaultRate(uint256 rate_) external onlyOwner {
        require(rate_ > 0, "ZERO_RATE");
        defaultRate = rate_;
    }

    // ----------------------------------------------------------------
    // IPoolFactory
    // ----------------------------------------------------------------

    /// @notice Returns registered pool or CREATE2-predicted address.
    ///         Always non-zero for valid token pairs, satisfying Deploy.s.sol.
    function getPool(address tokenA, address tokenB, bool stable) external view override returns (address) {
        (address a, address b) = _sort(tokenA, tokenB);
        address reg = _pools[a][b][stable];
        if (reg != address(0)) return reg;
        return _predictPool(a, b, stable);
    }

    /// @notice Deploy a TestnetSwapPool via CREATE2 at the predicted address.
    function createPool(address tokenA, address tokenB, bool stable)
        external
        override
        onlyOwner
        returns (address pool)
    {
        (address a, address b) = _sort(tokenA, tokenB);
        require(_pools[a][b][stable] == address(0), "POOL_EXISTS");

        bytes32 salt = _salt(a, b, stable);
        pool = address(new TestnetSwapPool{salt: salt}(a, b));
        _pools[a][b][stable] = pool;

        TestnetSwapPool(pool).configure(wethAddress, defaultRate);

        emit PoolCreated(a, b, stable, pool);
    }

    // ----------------------------------------------------------------
    // Manual registration (owner-only, validated)
    // ----------------------------------------------------------------

    /// @dev WARNING: If pool.deployer() != address(this), setPoolRate() will revert
    ///      because the pool's onlyDeployer modifier blocks non-factory callers.
    ///      Prefer createPool() for standard use; registerPool() exists only for
    ///      re-attaching an existing factory-deployed pool.
    function registerPool(address tokenA, address tokenB, bool stable, address pool) external onlyOwner {
        require(tokenA != address(0) && tokenB != address(0) && pool != address(0), "ZERO_ADDR");
        require(tokenA != tokenB, "SAME_TOKEN");
        require(pool.code.length > 0, "POOL_NO_CODE");
        (address a, address b) = _sort(tokenA, tokenB);
        require(_pools[a][b][stable] == address(0), "POOL_EXISTS");

        TestnetSwapPool p = TestnetSwapPool(pool);
        require(p.token0() == a && p.token1() == b, "TOKEN_MISMATCH");
        require(p.stable() == stable, "STABLE_MISMATCH");
        require(p.wethAddr() == wethAddress, "WETH_MISMATCH");
        require(p.claimPerWeth() > 0, "ZERO_RATE");

        _pools[a][b][stable] = pool;
        emit PoolCreated(a, b, stable, pool);
    }

    /// @notice Adjust a deployed pool's CLAIM-per-WETH rate.
    function setPoolRate(address tokenA, address tokenB, bool stable, uint256 rate_) external onlyOwner {
        (address a, address b) = _sort(tokenA, tokenB);
        address pool = _pools[a][b][stable];
        require(pool != address(0), "NO_POOL");
        TestnetSwapPool(pool).setClaimPerWeth(rate_);
    }

    // ----------------------------------------------------------------
    // Internals
    // ----------------------------------------------------------------

    function _predictPool(address a, address b, bool stable) internal view returns (address) {
        bytes32 salt = _salt(a, b, stable);
        bytes32 initHash = keccak256(abi.encodePacked(type(TestnetSwapPool).creationCode, abi.encode(a, b)));
        return address(uint160(uint256(keccak256(abi.encodePacked(hex"ff", address(this), salt, initHash)))));
    }

    function _salt(address a, address b, bool stable) internal pure returns (bytes32) {
        return keccak256(abi.encodePacked(a, b, stable));
    }

    function _sort(address tokenA, address tokenB) internal pure returns (address, address) {
        return tokenA < tokenB ? (tokenA, tokenB) : (tokenB, tokenA);
    }
}
