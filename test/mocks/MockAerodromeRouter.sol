// SPDX-License-Identifier: MIT
pragma solidity ^0.8.34;

import {IDexAdapter} from "src/interfaces/IDexAdapter.sol";
import {MockERC20} from "./MockERC20.sol";

/// @notice Minimal Aerodrome-style router mock.
/// @dev Implements the subset used by DexAdapter, EntryTokenRegistry, and GenesisLPVault24M.
contract MockAerodromeRouter is IDexAdapter {
    address public override defaultFactory;
    address public override weth;

    // 1e18-scaled output rate per hop (amountOut = amountIn * rate / 1e18)
    uint256 public rateX18 = 1e18;

    // Optional failure injection.
    bool public revertGetAmountsOut;

    // poolFor mapping: keccak256(tokenA, tokenB, stable, factory) -> pool
    mapping(bytes32 => address) internal _poolFor;

    // call tracking (for assertions)
    uint256 public lastEthValue;
    uint256 public lastAmountIn;
    uint256 public lastAmountOutMin;
    address public lastTo;
    uint256 public lastDeadline;
    bytes32 public lastRoutesHash;

    constructor(address factory_, address weth_) {
        defaultFactory = factory_;
        weth = weth_;
    }

    receive() external payable {}

    function setDefaultFactory(address factory_) external {
        defaultFactory = factory_;
    }

    function setWeth(address weth_) external {
        weth = weth_;
    }

    function setRateX18(uint256 newRateX18) external {
        rateX18 = newRateX18;
    }

    function setRevertGetAmountsOut(bool shouldRevert) external {
        revertGetAmountsOut = shouldRevert;
    }

    function setPoolFor(address tokenA, address tokenB, bool stable, address factory, address pool) external {
        _poolFor[_key(tokenA, tokenB, stable, factory)] = pool;
    }

    function poolFor(address tokenA, address tokenB, bool stable, address factory)
        external
        view
        override
        returns (address pool)
    {
        return _poolFor[_key(tokenA, tokenB, stable, factory)];
    }

    function getAmountsOut(uint256 amountIn, Route[] calldata routes)
        external
        view
        override
        returns (uint256[] memory amounts)
    {
        if (revertGetAmountsOut) revert("MockAerodromeRouter: getAmountsOut");

        // Simple linear quote per hop.
        uint256 n = routes.length;
        amounts = new uint256[](n + 1);
        amounts[0] = amountIn;
        uint256 out = amountIn;
        for (uint256 i = 0; i < n; i++) {
            out = (out * rateX18) / 1e18;
            amounts[i + 1] = out;
        }
    }

    function swapExactETHForTokens(uint256 amountOutMin, Route[] calldata routes, address to, uint256 deadline)
        external
        payable
        virtual
        override
        returns (uint256[] memory amounts)
    {
        lastEthValue = msg.value;
        lastAmountOutMin = amountOutMin;
        lastTo = to;
        lastDeadline = deadline;
        lastRoutesHash = keccak256(abi.encode(routes));

        amounts = this.getAmountsOut(msg.value, routes);
        uint256 out = amounts[amounts.length - 1];
        require(out >= amountOutMin, "MockAerodromeRouter: slippage");

        // Mint output token to `to`.
        Route memory last = routes[routes.length - 1];
        MockERC20(last.to).mint(to, out);
    }

    function swapExactTokensForTokens(
        uint256 amountIn,
        uint256 amountOutMin,
        Route[] calldata routes,
        address to,
        uint256 deadline
    ) external virtual override returns (uint256[] memory amounts) {
        lastAmountIn = amountIn;
        lastAmountOutMin = amountOutMin;
        lastTo = to;
        lastDeadline = deadline;
        lastRoutesHash = keccak256(abi.encode(routes));

        // Pull input tokens from caller.
        Route memory first = routes[0];
        require(
            MockERC20(first.from).transferFrom(msg.sender, address(this), amountIn), "MockAerodromeRouter: transferFrom"
        );

        amounts = this.getAmountsOut(amountIn, routes);
        uint256 out = amounts[amounts.length - 1];
        require(out >= amountOutMin, "MockAerodromeRouter: slippage");

        // Mint output token to `to`.
        Route memory last = routes[routes.length - 1];
        MockERC20(last.to).mint(to, out);
    }

    /// @dev Match canonical DEX behavior: pool identity is unordered in (tokenA, tokenB).
    function _key(address tokenA, address tokenB, bool stable, address factory) internal pure returns (bytes32) {
        (address a, address b) = tokenA < tokenB ? (tokenA, tokenB) : (tokenB, tokenA);
        return keccak256(abi.encode(a, b, stable, factory));
    }
}
