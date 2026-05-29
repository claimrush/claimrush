// SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

import {LocalAerodromePool} from "../localdex/LocalAerodromePool.sol";

/// @notice Order-agnostic swap pool for Sepolia testing.
/// @dev Constructor takes (tokenA, tokenB) without assuming which is WETH or CLAIM.
///      After CREATE2 deployment, the factory calls `configure()` to set the pricing
///      direction.  Before configuration, quoteOut falls back to the parent's 1:1.
///
///      Also acts as its own LP token (inherited from LocalAerodromePool) so
///      LaunchController.finalizeGenesis() can call pool.mint().
///
///      Includes skim(address) so LaunchController._ensureEmptyOrSkim() can clear
///      pre-genesis donation balances instead of reverting.
contract TestnetSwapPool is LocalAerodromePool {
    using SafeERC20 for IERC20;

    uint256 public claimPerWeth = 100_000;
    address public wethAddr;
    address public deployer;

    event RateChanged(uint256 oldRate, uint256 newRate);

    constructor(address tokenA_, address tokenB_) LocalAerodromePool(tokenA_, tokenB_, false) {
        deployer = msg.sender;
        name = "TestnetSwap vAMM";
        symbol = "tvAMM";
    }

    modifier onlyDeployer() {
        require(msg.sender == deployer, "NOT_DEPLOYER");
        _;
    }

    /// @notice Called by TestnetSwapFactory after CREATE2 deployment.
    /// @param weth_ Which of the two tokens is WETH.
    /// @param rate_  CLAIM units per 1 WETH (e.g. 100_000).
    function configure(address weth_, uint256 rate_) external onlyDeployer {
        require(wethAddr == address(0), "ALREADY_CONFIGURED");
        require(weth_ == token0 || weth_ == token1, "NOT_POOL_TOKEN");
        require(rate_ > 0, "ZERO_RATE");
        wethAddr = weth_;
        claimPerWeth = rate_;
    }

    /// @notice Adjust rate after configuration (deployer only).
    function setClaimPerWeth(uint256 rate_) external onlyDeployer {
        require(rate_ > 0, "ZERO_RATE");
        uint256 old = claimPerWeth;
        claimPerWeth = rate_;
        emit RateChanged(old, rate_);
    }

    // ----------------------------------------------------------------
    // Aerodrome skim surface (required by LaunchController._ensureEmptyOrSkim)
    // ----------------------------------------------------------------

    /// @notice Transfer excess token balances (above tracked reserves) to `to`.
    /// @dev Mirrors Aerodrome v2 skim(). Prevents donation-based DoS on genesis.
    function skim(address to) external {
        require(to != address(0), "ZERO_TO");
        uint256 bal0 = IERC20(token0).balanceOf(address(this));
        uint256 bal1 = IERC20(token1).balanceOf(address(this));
        if (bal0 > reserve0) {
            IERC20(token0).safeTransfer(to, bal0 - reserve0);
        }
        if (bal1 > reserve1) {
            IERC20(token1).safeTransfer(to, bal1 - reserve1);
        }
    }

    // ----------------------------------------------------------------
    // Pricing
    // ----------------------------------------------------------------

    function quoteOut(address tokenIn, uint256 amountIn) public view override returns (uint256) {
        if (wethAddr == address(0)) {
            tokenOut(tokenIn);
            return amountIn;
        }
        if (tokenIn == wethAddr) return amountIn * claimPerWeth;
        address other = tokenOut(tokenIn);
        if (other == wethAddr) return amountIn / claimPerWeth;
        revert NotToken();
    }
}
