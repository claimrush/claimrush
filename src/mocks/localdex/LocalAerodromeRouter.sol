// SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {IDexAdapter} from "../../interfaces/IDexAdapter.sol";
import {IWETH} from "../../interfaces/IWETH.sol";

import {LocalAerodromeFactory} from "./LocalAerodromeFactory.sol";
import {LocalAerodromePool} from "./LocalAerodromePool.sol";

/// @notice Minimal Aerodrome router mock for local testing.
/// @dev Uses each pool's deterministic `quoteOut(...)` pricing.
contract LocalAerodromeRouter is IDexAdapter {
    address public immutable defaultFactory;
    address public immutable weth;

    error DeadlineExpired();
    error EmptyRoute();
    error PoolNotFound();
    error OutputTooLow();
    error EthRouteMustStartWithWeth();
    error InsufficientPoolLiquidity();

    constructor(address factory_, address weth_) {
        require(factory_ != address(0) && weth_ != address(0), "ZERO_ADDR");
        defaultFactory = factory_;
        weth = weth_;
    }

    function poolFor(address tokenA, address tokenB, bool stable, address factory) public view returns (address pool) {
        pool = LocalAerodromeFactory(factory).getPool(tokenA, tokenB, stable);
    }

    function getAmountsOut(uint256 amountIn, Route[] memory routes) external view returns (uint256[] memory amounts) {
        if (routes.length == 0) revert EmptyRoute();
        amounts = new uint256[](routes.length + 1);
        amounts[0] = amountIn;
        for (uint256 i = 0; i < routes.length; i++) {
            address pool = poolFor(routes[i].from, routes[i].to, routes[i].stable, routes[i].factory);
            if (pool == address(0)) {
                revert PoolNotFound();
            }
            amounts[i + 1] = LocalAerodromePool(pool).quoteOut(routes[i].from, amounts[i]);
            if (IERC20(routes[i].to).balanceOf(pool) < amounts[i + 1]) revert InsufficientPoolLiquidity();
        }
    }

    function swapExactTokensForTokens(
        uint256 amountIn,
        uint256 amountOutMin,
        Route[] calldata routes,
        address to,
        uint256 deadline
    ) external returns (uint256[] memory amounts) {
        if (routes.length == 0) revert EmptyRoute();
        if (block.timestamp > deadline) revert DeadlineExpired();

        amounts = new uint256[](routes.length + 1);
        amounts[0] = amountIn;

        for (uint256 i = 0; i < routes.length; i++) {
            Route calldata r = routes[i];
            address pool = poolFor(r.from, r.to, r.stable, r.factory);
            if (pool == address(0)) revert PoolNotFound();

            uint256 inAmt = amounts[i];

            // Move input tokens into the pool.
            if (i == 0) {
                require(IERC20(r.from).transferFrom(msg.sender, pool, inAmt), "ERC20_TRANSFER_FROM_FAILED");
            } else {
                // Intermediate hops: the router holds the intermediate token.
                require(IERC20(r.from).transfer(pool, inAmt), "ERC20_TRANSFER_FAILED");
            }

            address recipient = (i == routes.length - 1) ? to : address(this);
            uint256 outAmt = LocalAerodromePool(pool).swap(r.from, inAmt, recipient);
            amounts[i + 1] = outAmt;
        }

        if (amounts[amounts.length - 1] < amountOutMin) revert OutputTooLow();
    }

    function swapExactETHForTokens(uint256 amountOutMin, Route[] calldata routes, address to, uint256 deadline)
        external
        payable
        returns (uint256[] memory amounts)
    {
        if (routes.length == 0) revert EmptyRoute();
        if (block.timestamp > deadline) revert DeadlineExpired();
        if (routes[0].from != weth) revert EthRouteMustStartWithWeth();

        // Wrap ETH into WETH held by the router.
        IWETH(weth).deposit{value: msg.value}();

        amounts = new uint256[](routes.length + 1);
        amounts[0] = msg.value;

        for (uint256 i = 0; i < routes.length; i++) {
            Route calldata r = routes[i];
            address pool = poolFor(r.from, r.to, r.stable, r.factory);
            if (pool == address(0)) revert PoolNotFound();

            uint256 inAmt = amounts[i];

            // Input tokens are always held by router in ETH path.
            require(IERC20(r.from).transfer(pool, inAmt), "ERC20_TRANSFER_FAILED");

            address recipient = (i == routes.length - 1) ? to : address(this);
            uint256 outAmt = LocalAerodromePool(pool).swap(r.from, inAmt, recipient);
            amounts[i + 1] = outAmt;
        }

        if (amounts[amounts.length - 1] < amountOutMin) revert OutputTooLow();
    }
}
