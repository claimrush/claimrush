// SPDX-License-Identifier: MIT
pragma solidity ^0.8.34;

import {DexAdapter} from "src/DexAdapter.sol";
import {IDexAdapter} from "src/interfaces/IDexAdapter.sol";
import {MockAerodromeRouter} from "../mocks/MockAerodromeRouter.sol";
import {MockERC20} from "../mocks/MockERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/// @title Echidna harness for DexAdapter -- token/ETH custody, immutability, and allowance hygiene.
/// @dev Target contract. Echidna invokes all `action_*` functions from the configured sender list;
///      because those calls bounce through `this`, the harness IS the msg.sender seen by DexAdapter
///      (and hence the DexAdapter owner for rescue surfaces).
contract EchidnaDexAdapter {
    DexAdapter internal adapter;
    MockAerodromeRouter internal router;
    MockERC20 internal weth;
    MockERC20 internal claim;
    address internal factory;
    address internal pool;

    // Immutable snapshot for invariant checks
    address internal immRouter;
    address internal immFactory;
    address internal immWeth;
    address internal immOwner;

    constructor() payable {
        // Factory just needs non-empty code for DexAdapter's `NotAContract` guard.
        factory = address(new MockERC20("Factory", "FAC"));
        weth = new MockERC20("Wrapped Ether", "WETH");
        claim = new MockERC20("Claim Token", "CLAIM");

        router = new MockAerodromeRouter(factory, address(weth));
        adapter = new DexAdapter(address(router), address(this));

        immRouter = adapter.aerodromeRouter();
        immFactory = adapter.aerodromeFactory();
        immWeth = adapter.wrappedNative();
        immOwner = adapter.owner();

        pool = address(new MockERC20("WETH-CLAIM Pool", "POOL"));
        router.setPoolFor(address(weth), address(claim), false, factory, pool);
    }

    // ================================================================
    // Internal route builder -- keeps actions concise and within the
    // validation rules enforced by DexAdapter._validateRoutes.
    // ================================================================

    function _wethClaimRoute() internal view returns (IDexAdapter.Route[] memory routes) {
        routes = new IDexAdapter.Route[](1);
        routes[0] = IDexAdapter.Route({from: address(weth), to: address(claim), stable: false, factory: factory});
    }

    // ================================================================
    // Actions
    // ================================================================

    /// @dev Swap ETH -> CLAIM via the adapter's WETH-first route.
    function action_swapExactETHForTokens(uint256 amountOutMin) public payable {
        if (msg.value == 0) return;
        if (amountOutMin > msg.value) amountOutMin = msg.value;
        IDexAdapter.Route[] memory routes = _wethClaimRoute();
        try adapter.swapExactETHForTokens{value: msg.value}(
            amountOutMin, routes, msg.sender, block.timestamp + 1 hours
        ) {}
            catch {}
    }

    /// @dev Swap WETH -> CLAIM. Mints WETH to the harness so the adapter's transferFrom succeeds.
    function action_swapExactTokensForTokens(uint256 amountIn, uint256 amountOutMin) public {
        if (amountIn == 0) return;
        if (amountIn > 1_000_000e18) amountIn = 1_000_000e18;
        if (amountOutMin > amountIn) amountOutMin = amountIn;

        weth.mint(address(this), amountIn);
        weth.approve(address(adapter), amountIn);

        IDexAdapter.Route[] memory routes = _wethClaimRoute();
        try adapter.swapExactTokensForTokens(amountIn, amountOutMin, routes, msg.sender, block.timestamp + 1 hours) {}
            catch {}
    }

    /// @dev Probe the route-validation view surface with arbitrary inputs.
    function action_poolFor_probe(address tokenA, address tokenB, bool stable) public view {
        try adapter.poolFor(tokenA, tokenB, stable, factory) returns (address) {} catch {}
    }

    /// @dev getAmountsOut probe with the canonical route.
    function action_getAmountsOut_probe(uint256 amountIn) public view {
        IDexAdapter.Route[] memory routes = _wethClaimRoute();
        try adapter.getAmountsOut(amountIn, routes) returns (uint256[] memory) {} catch {}
    }

    /// @dev Attempt ETH rescue to arbitrary recipient. Owner checks pass (harness is owner);
    ///      destination guards (self / router / factory / wrappedNative / zero) must still fire.
    function action_rescueEth(address to) public {
        try adapter.rescueETH(payable(to)) {} catch {}
    }

    /// @dev Attempt token rescue to arbitrary recipient.
    function action_rescueToken(uint256 tokenSel, address to) public {
        address tokenAddr = (tokenSel % 2 == 0) ? address(weth) : address(claim);
        try adapter.rescueToken(IERC20(tokenAddr), to) {} catch {}
    }

    /// @dev Try to send ETH to the adapter directly. The `receive()` hook must reject
    ///      any sender other than `aerodromeRouter`, so this always fails when called from
    ///      the harness -- the call returns ok=false and msg.value stays with the harness.
    function action_sendEthDirect() public payable {
        if (msg.value == 0) return;
        (bool ok,) = address(adapter).call{value: msg.value}("");
        ok;
    }

    /// @dev Exercise the `renounceOwnership` revert guard.
    function action_try_renounce() public {
        try adapter.renounceOwnership() {} catch {}
    }

    // ================================================================
    // Properties (MUST always return true)
    // ================================================================

    /// @dev Immutables pinned at construction never change.
    function echidna_immutables_preserved() public view returns (bool) {
        return adapter.aerodromeRouter() == immRouter && adapter.aerodromeFactory() == immFactory
            && adapter.wrappedNative() == immWeth;
    }

    /// @dev Owner is never address(0): renounceOwnership() reverts by design.
    function echidna_owner_never_zero() public view returns (bool) {
        return adapter.owner() != address(0);
    }

    /// @dev DexAdapter never holds input or output tokens between calls
    ///      (post-swap balance check is enforced inside the swap function).
    function echidna_no_residual_tokens() public view returns (bool) {
        return weth.balanceOf(address(adapter)) == 0 && claim.balanceOf(address(adapter)) == 0;
    }

    /// @dev Allowance to the underlying router is cleared after every swap.
    function echidna_no_residual_allowance() public view returns (bool) {
        return weth.allowance(address(adapter), address(router)) == 0
            && claim.allowance(address(adapter), address(router)) == 0;
    }

    /// @dev DexAdapter never retains ETH across calls -- any refund path must forward to msg.sender
    ///      or route-only receive() via the pinned router. Since the mock never refunds and direct
    ///      sends from non-router are rejected, balance must stay 0.
    function echidna_no_ethbalance() public view returns (bool) {
        return address(adapter).balance == 0;
    }
}
