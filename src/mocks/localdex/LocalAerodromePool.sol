// SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/// @notice Extremely small pool mock used for local end-to-end testing.
/// @dev Implements deterministic, pool-defined pricing via `quoteOut(...)` with
///      simple balance-based liquidity checks.
///
///      IMPORTANT: This mock also acts as its own LP token so genesis flows can run locally:
///      - `LaunchController.finalizeGenesis()` calls `IERC20(pool).totalSupply()` and `pool.mint(...)`
///      - LP vaults use `safeTransfer{From}` on the LP token
contract LocalAerodromePool {
    address public immutable token0;
    address public immutable token1;
    bool public immutable stable;

    error NotToken();
    error InsufficientLiquidity();

    // ------------------------------------------------------------
    // Minimal ERC20 (LP token)
    // ------------------------------------------------------------

    string public name;
    string public symbol;
    uint8 public immutable decimals;

    uint256 public totalSupply;
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;

    event Transfer(address indexed from, address indexed to, uint256 value);
    event Approval(address indexed owner, address indexed spender, uint256 value);

    // Simple reserve tracking so `mint()` can compute deltas.
    uint256 internal reserve0;
    uint256 internal reserve1;

    constructor(address _token0, address _token1, bool _stable) {
        require(_token0 != address(0) && _token1 != address(0), "ZERO_TOKEN");
        require(_token0 != _token1, "SAME_TOKEN");
        // Store in deterministic order.
        (address a, address b) = _token0 < _token1 ? (_token0, _token1) : (_token1, _token0);
        token0 = a;
        token1 = b;
        stable = _stable;

        // Cosmetic; helps when inspecting local state.
        name = "LocalAerodrome LP";
        symbol = "LALP";
        decimals = 18;
    }

    function tokenOut(address tokenIn) public view returns (address) {
        if (tokenIn == token0) return token1;
        if (tokenIn == token1) return token0;
        revert NotToken();
    }

    /// @notice Deterministic output quote for the mock pool.
    /// @dev Base implementation is 1:1 and can be overridden by named wrappers.
    function quoteOut(address tokenIn, uint256 amountIn) public view virtual returns (uint256 amountOut) {
        tokenOut(tokenIn); // validates tokenIn
        return amountIn;
    }

    /// @dev Caller must transfer amountIn of tokenIn to this pool before calling.
    ///      Verified via balance-delta check (mirrors Aerodrome/Uniswap v2).
    function swap(address tokenIn, uint256 amountIn, address to) external virtual returns (uint256 amountOut) {
        address out = tokenOut(tokenIn);

        uint256 reserveIn = tokenIn == token0 ? reserve0 : reserve1;
        uint256 balIn = IERC20(tokenIn).balanceOf(address(this));
        require(balIn >= reserveIn + amountIn, "INSUFFICIENT_INPUT");

        amountOut = quoteOut(tokenIn, amountIn);
        if (IERC20(out).balanceOf(address(this)) < amountOut) revert InsufficientLiquidity();
        require(IERC20(out).transfer(to, amountOut), "ERC20_TRANSFER_FAILED");

        reserve0 = IERC20(token0).balanceOf(address(this));
        reserve1 = IERC20(token1).balanceOf(address(this));
    }

    // ------------------------------------------------------------
    // Aerodrome-style hooks (minimal)
    // ------------------------------------------------------------

    /// @notice Mint LP tokens to `to` based on newly deposited balances.
    /// @dev Ratio-aware (Uniswap v2-style): first mint uses geometric mean,
    ///      subsequent mints are proportional to existing reserves.  This prevents
    ///      imbalanced deposits from minting outsized LP on public testnets.
    function mint(address to) external returns (uint256 liquidity) {
        if (to == address(0)) revert("ZERO_TO");

        uint256 bal0 = IERC20(token0).balanceOf(address(this));
        uint256 bal1 = IERC20(token1).balanceOf(address(this));

        uint256 d0 = bal0 > reserve0 ? (bal0 - reserve0) : 0;
        uint256 d1 = bal1 > reserve1 ? (bal1 - reserve1) : 0;

        if (totalSupply == 0) {
            liquidity = _sqrt(d0 * d1);
        } else {
            uint256 liq0 = d0 * totalSupply / reserve0;
            uint256 liq1 = d1 * totalSupply / reserve1;
            liquidity = liq0 < liq1 ? liq0 : liq1;
        }
        require(liquidity > 0, "NO_LIQUIDITY");

        reserve0 = bal0;
        reserve1 = bal1;

        _mint(to, liquidity);
    }

    /// @notice Claim fees (no-op for local mock).
    function claimFees() external returns (uint256 claimed0, uint256 claimed1) {
        return (0, 0);
    }

    // ------------------------------------------------------------
    // ERC20 impl (minimal)
    // ------------------------------------------------------------

    function approve(address spender, uint256 value) external returns (bool) {
        allowance[msg.sender][spender] = value;
        emit Approval(msg.sender, spender, value);
        return true;
    }

    function transfer(address to, uint256 value) external returns (bool) {
        _transfer(msg.sender, to, value);
        return true;
    }

    function transferFrom(address from, address to, uint256 value) external returns (bool) {
        uint256 allowed = allowance[from][msg.sender];
        if (allowed != type(uint256).max) {
            require(allowed >= value, "ALLOWANCE");
            allowance[from][msg.sender] = allowed - value;
            emit Approval(from, msg.sender, allowance[from][msg.sender]);
        }
        _transfer(from, to, value);
        return true;
    }

    function _transfer(address from, address to, uint256 value) internal {
        require(to != address(0), "ZERO_TO");
        uint256 bal = balanceOf[from];
        require(bal >= value, "BALANCE");
        unchecked {
            balanceOf[from] = bal - value;
            balanceOf[to] += value;
        }
        emit Transfer(from, to, value);
    }

    function _mint(address to, uint256 value) internal {
        totalSupply += value;
        unchecked {
            balanceOf[to] += value;
        }
        emit Transfer(address(0), to, value);
    }

    /// @dev Babylonian integer square root (Uniswap v2 Math).
    function _sqrt(uint256 y) internal pure returns (uint256 z) {
        if (y > 3) {
            z = y;
            uint256 x = y / 2 + 1;
            while (x < z) {
                z = x;
                x = (y / x + x) / 2;
            }
        } else if (y != 0) {
            z = 1;
        }
    }
}
