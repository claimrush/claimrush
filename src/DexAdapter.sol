// SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

import {Ownable2Step} from "@openzeppelin/contracts/access/Ownable2Step.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {IDexAdapter} from "./interfaces/IDexAdapter.sol";

import {Errors} from "./lib/Errors.sol";
import {Events} from "./lib/Events.sol";
import {SafeApprove} from "./lib/SafeApprove.sol";
import {SafeTransfer} from "./lib/SafeTransfer.sol";
import {SafeERC20View} from "./lib/SafeERC20View.sol";

/// @notice DexAdapter.
/// @dev A thin adapter around an underlying Aerodrome-style router.
///      This exists to decouple core protocol contracts from a specific DEX implementation.
///
///      - All swap paths rely on downstream minVeOut/minClaimOut/minEthOut for slippage protection.
///      - Fee-on-transfer and rebasing tokens are NOT supported (see TOKEN SAFETY below).
///      - Route validation pins factory to aerodromeFactory — no alternate factory injection possible.
///      v1.0.0 deploys DexAdapter directly (no proxy / no UUPS surface).
///      The router, factory, and wrapped native roots are pinned at deployment; changing them requires
///      redeploy + rewire, not an in-place setter on this contract.
///
/// Notes:
/// - This contract is intentionally minimal. Bounded owner-only recovery surfaces
///   (rescueETH, rescueToken) exist for accidentally stranded assets; both are
///   nonReentrant + onlyOwner with destination guards (no self/router/factory/WETH).
/// - Swap functions validate routes, manage a transient custody hop (caller → adapter → router),
///   enforce post-swap balance invariants, and clear residual allowances before returning.
///
/// TOKEN SAFETY:
/// - Fee-on-transfer tokens are NOT supported. The adapter's custody hop (caller → adapter → router)
///   means the actual amount received by the router may be less than `amountIn`, causing the swap
///   to revert or produce incorrect output. EntryTokenRegistry MUST NOT allowlist fee-on-transfer tokens.
/// - Rebasing tokens are NOT supported. Balance changes between the pull and the swap forward would
///   break amount accounting. Do not allowlist elastic-supply / rebasing tokens.
contract DexAdapter is ReentrancyGuard, Ownable2Step, IDexAdapter {
    /// @notice Underlying router implementation (Aerodrome-style).
    address public immutable aerodromeRouter;

    /// @notice Pinned Aerodrome default factory at deployment time.
    /// @dev Hardening: avoids relying on a mutable router implementation for invariants.
    address public immutable aerodromeFactory;

    /// @notice Pinned wrapped native (WETH) at deployment time.
    /// @dev Hardening: ETH routes MUST start with this token.
    address public immutable wrappedNative;

    /// @dev Minimal router subset used by the adapter.
    ///      Uses IDexAdapter.Route to avoid struct type collisions.

    constructor(address _aerodromeRouter, address initialOwner) Ownable(initialOwner) {
        if (_aerodromeRouter == address(0) || initialOwner == address(0)) revert Errors.ZeroAddress();
        // The runtime `transferOwnership` surface rejects EIP-7702 delegated EOAs.
        // The constructor enforces the same rule on `initialOwner` so the genesis
        // owner cannot expose route-allowlist or freeze surfaces through public
        // executor code before the first hardened transfer. Bare EOAs are still
        // permitted as the owner seat (matches the rest of the protocol's
        // owner-seat policy); only the 7702 designator case is rejected.
        _rejectDelegated7702Owner(initialOwner);
        // Router and the values it returns must be real deployed contracts, not EOAs and not
        // EIP-7702-delegated EOAs. The adapter's roots are immutable, so a bricked deployment
        // requires a full redeploy; reject every contract-shape ambiguity at construction time.
        _rejectDelegatedEOA(_aerodromeRouter);
        aerodromeRouter = _aerodromeRouter;

        // Pin key router constants at deployment time for deterministic behavior.
        address df = IDexAdapter(_aerodromeRouter).defaultFactory();
        address w = IDexAdapter(_aerodromeRouter).weth();
        if (df == address(0) || w == address(0)) revert Errors.ZeroAddress();
        _rejectDelegatedEOA(df);
        _rejectDelegatedEOA(w);
        aerodromeFactory = df;
        wrappedNative = w;
    }

    /// @dev Prevent accidental permanent lock-out from rescueETH and admin surfaces.
    function renounceOwnership() public pure override {
        revert Errors.NotAuthorized();
    }

    /// @dev Reject EIP-7702 delegated EOAs from acquiring the owner role. A delegated
    ///      owner can let arbitrary callers exercise the route-allowlist and freeze
    ///      surfaces after acceptance. Bare EOAs and contracts are both valid owner
    ///      seats; only the 7702 designator case is rejected.
    function transferOwnership(address newOwner) public override onlyOwner {
        if (newOwner == address(0)) revert Errors.ZeroAddress();
        _rejectDelegated7702Owner(newOwner);
        super.transferOwnership(newOwner);
    }

    /// @dev Acceptance-time re-validation. The 7702 designator can land on the
    ///      nominee between nomination and acceptance; rejecting at acceptance
    ///      keeps the owner seat off any delegated EOA.
    function acceptOwnership() public override {
        _rejectDelegated7702Owner(msg.sender);
        super.acceptOwnership();
    }

    /// @dev Owner-seat 7702 rejection. Mirrors the standard `_rejectDelegatedEOA`
    ///      helper used by `MarketRouter` / `ShareholderRoyalties` / `VeClaimNFT`
    ///      / `LpStakingVault7D`: only the 23-byte `0xEF0100`-prefixed designator
    ///      reverts, bare EOAs and ordinary contracts are both accepted as owner.
    ///      Distinct from this contract's stricter `_rejectDelegatedEOA`, which
    ///      additionally rejects bare EOAs because the swap-side roots (token,
    ///      router, factory, pool) MUST be real deployed contracts.
    function _rejectDelegated7702Owner(address account) internal view {
        if (account.code.length != 23) return;
        bytes3 prefix;
        assembly ("memory-safe") {
            extcodecopy(account, 0x00, 0x00, 0x03)
            prefix := mload(0x00)
        }
        if (prefix == 0xEF0100) revert Errors.DelegatedEOA();
    }

    /// @dev Only the router may send ETH here; typical case is swap refunds.
    ///      No `fallback` means non-empty calldata to unknown selectors reverts.
    receive() external payable {
        if (msg.sender != aerodromeRouter) revert Errors.NotAuthorized();
    }

    /// @notice Rescue ETH accidentally sent to this contract.
    /// @dev Only callable by owner. DexAdapter should never hold ETH long-term;
    ///      the only legitimate receive path is refunds from failed router swaps.
    function rescueETH(address payable to) external nonReentrant onlyOwner {
        if (to == address(0)) revert Errors.ZeroAddress();
        if (to == address(this)) revert Errors.NotAuthorized();
        if (to == payable(aerodromeRouter) || to == payable(aerodromeFactory) || to == payable(wrappedNative)) {
            revert Errors.NotAuthorized();
        }
        uint256 bal = address(this).balance;
        if (bal == 0) revert Errors.AmountZero();
        (bool ok,) = to.call{value: bal, gas: 100_000}("");
        if (!ok) revert Errors.EthTransferFailed();
        emit Events.EthRescued(to, bal);
    }

    /// @notice Rescue ERC-20 tokens accidentally sent to this contract.
    /// @dev Only callable by owner.  Uses bounded-gas balanceOf to resist return-bomb tokens.
    function rescueToken(IERC20 token, address to) external nonReentrant onlyOwner {
        if (to == address(0)) revert Errors.ZeroAddress();
        if (to == address(this)) revert Errors.NotAuthorized();
        if (to == aerodromeRouter || to == aerodromeFactory || to == wrappedNative) revert Errors.NotAuthorized();
        address tokenAddr = address(token);
        if (tokenAddr == address(0)) revert Errors.ZeroAddress();
        if (tokenAddr.code.length == 0) revert Errors.NotAContract();
        (uint256 bal, bool balOk) = _callBalanceOfLimited(token, address(this));
        if (!balOk) revert Errors.TransferFailed();
        if (bal == 0) revert Errors.AmountZero();
        if (!SafeTransfer.callTransfer(token, to, bal)) revert Errors.TransferFailed();
        emit Events.TokenRescued(address(token), to, bal);
    }

    // Internal route validation (hardening)

    /// @dev Reject EIP-7702-delegated EOAs (23-byte code with `0xEF0100` prefix).
    ///      A 7702-delegated EOA's ERC-20 calls execute on the delegation target under EOA
    ///      storage, which cannot faithfully represent an ERC-20 ledger. Token roles, the
    ///      router root, and router-returned roots (factory, WETH) MUST be real deployed
    ///      contracts. Reverts `NotAContract` on bare-EOA (`size == 0`) and `DelegatedEOA`
    ///      on the 7702 case (matches `EntryTokenRegistry`'s mirror so off-chain consumers
    ///      can distinguish the two failure modes by selector).
    function _rejectDelegatedEOA(address a) internal view {
        uint256 size = a.code.length;
        if (size == 0) revert Errors.NotAContract();
        if (size != 23) return;
        bytes3 prefix;
        assembly ("memory-safe") {
            let ptr := mload(0x40)
            extcodecopy(a, ptr, 0, 3)
            prefix := mload(ptr)
        }
        if (prefix == 0xEF0100) revert Errors.DelegatedEOA();
    }

    /// @dev Enforces v1.0.0 invariants:
    /// - routes length is 1 or 2
    /// - each hop has non-zero from/to/factory
    /// - hop chaining holds for 2-hop routes
    /// - factory is pinned to `aerodromeFactory` (no alternate factories)
    function _validateRoutes(IDexAdapter.Route[] calldata routes) internal view {
        uint256 n = routes.length;

        if (n == 0 || n > 2) revert Errors.InvalidRoute();

        for (uint256 i = 0; i < n; i++) {
            IDexAdapter.Route calldata r = routes[i];
            if (r.from == address(0) || r.to == address(0) || r.factory == address(0)) revert Errors.InvalidRoute();
            if (r.from == r.to) revert Errors.InvalidRoute();
            if (r.factory != aerodromeFactory) revert Errors.InvalidRoute();
            if (i > 0 && routes[i - 1].to != r.from) revert Errors.InvalidRoute();
            if (r.from == address(this) || r.to == address(this)) revert Errors.InvalidRoute();
            if (r.from == aerodromeRouter || r.to == aerodromeRouter) revert Errors.InvalidRoute();
            if (r.from == aerodromeFactory || r.to == aerodromeFactory) revert Errors.InvalidRoute();
            _rejectDelegatedEOA(r.from);
            _rejectDelegatedEOA(r.to);
        }
        if (n > 1 && routes[0].from == routes[n - 1].to) revert Errors.InvalidRoute();
    }

    // IDexAdapter passthroughs

    function defaultFactory() external view override returns (address) {
        return aerodromeFactory;
    }

    function weth() external view override returns (address) {
        return wrappedNative;
    }

    function poolFor(address tokenA, address tokenB, bool stable, address factory)
        external
        view
        override
        returns (address pool)
    {
        if (tokenA == address(0) || tokenB == address(0)) revert Errors.ZeroAddress();
        if (tokenA == tokenB) revert Errors.InvalidRoute();
        if (factory != aerodromeFactory) revert Errors.InvalidRoute();
        if (tokenA == address(this) || tokenB == address(this)) revert Errors.InvalidRoute();
        if (tokenA == aerodromeRouter || tokenB == aerodromeRouter) revert Errors.InvalidRoute();
        // Defense-in-depth — factory address is never a valid token.
        if (tokenA == aerodromeFactory || tokenB == aerodromeFactory) revert Errors.InvalidRoute();
        // Symmetry with `_validateRoutes`: reject EOAs / non-contracts (and 7702-delegated EOAs)
        // so callers cannot quote-route through a bait address that only becomes a contract later.
        _rejectDelegatedEOA(tokenA);
        _rejectDelegatedEOA(tokenB);
        return IDexAdapter(aerodromeRouter).poolFor(tokenA, tokenB, stable, factory);
    }

    function getAmountsOut(uint256 amountIn, IDexAdapter.Route[] calldata routes)
        external
        view
        override
        returns (uint256[] memory amounts)
    {
        if (amountIn == 0) revert Errors.AmountZero();
        _validateRoutes(routes);
        amounts = IDexAdapter(aerodromeRouter).getAmountsOut(amountIn, routes);
        if (amounts.length != routes.length + 1) revert Errors.ReturnDataTooLarge();
        return amounts;
    }

    function swapExactETHForTokens(
        uint256 amountOutMin,
        IDexAdapter.Route[] calldata routes,
        address to,
        uint256 deadline
    ) external payable override nonReentrant returns (uint256[] memory amounts) {
        if (msg.value == 0) revert Errors.AmountZero();
        if (deadline < block.timestamp) revert Errors.DeadlineExpired();
        if (to == address(0)) revert Errors.ZeroAddress();
        // Deadline uses strict `<` (deadline == block.timestamp is allowed), which matches
        // Aerodrome's own `require(deadline >= block.timestamp)`.
        if (to == address(this) || to == aerodromeRouter || to == aerodromeFactory || to == wrappedNative) {
            revert Errors.InvalidRoute();
        }
        _validateRoutes(routes);

        // ETH entry must be encoded as a WETH-based route.
        if (routes[0].from != wrappedNative) revert Errors.InvalidRoute();

        // ETH-entry swap must not end at wrappedNative (economically pointless round-trip).
        if (routes[routes.length - 1].to == wrappedNative) revert Errors.InvalidRoute();

        // Snapshot pre-swap balance (excluding msg.value already deposited) for refund calc.
        uint256 preSwapBal = address(this).balance - msg.value;

        amounts =
            IDexAdapter(aerodromeRouter).swapExactETHForTokens{value: msg.value}(amountOutMin, routes, to, deadline);
        if (amounts.length != routes.length + 1) revert Errors.ReturnDataTooLarge();
        if (amounts[0] != msg.value) revert Errors.InvariantViolation();
        if (amounts[amounts.length - 1] < amountOutMin) revert Errors.MinAmountOutNotMet();

        // Refund any ETH returned by the router to the original caller.
        uint256 refund = address(this).balance - preSwapBal;
        if (refund > 0) {
            (bool refundOk,) = msg.sender.call{value: refund, gas: 100_000}("");
            if (!refundOk) revert Errors.EthTransferFailed();
        }
    }

    function swapExactTokensForTokens(
        uint256 amountIn,
        uint256 amountOutMin,
        IDexAdapter.Route[] calldata routes,
        address to,
        uint256 deadline
    ) external override nonReentrant returns (uint256[] memory amounts) {
        if (amountIn == 0) revert Errors.AmountZero();
        if (deadline < block.timestamp) revert Errors.DeadlineExpired();
        // Slippage policy is caller-owned. Furnace may use amountOutMin = 0 and rely on
        // end-to-end minVeOut on the lock; other callers pass explicit minEthOut/minClaimOut.
        // DexAdapter stays a thin passthrough and does not impose a global minimum output.
        if (to == address(0)) revert Errors.ZeroAddress();
        // amountOutMin may be zero for callers that intentionally rely on a downstream guard.
        // Callers that require swap-level protection MUST pass a meaningful minimum and, where
        // documented by the calling surface, use private relay submission.
        if (to == address(this) || to == aerodromeRouter || to == aerodromeFactory || to == wrappedNative) {
            revert Errors.InvalidRoute();
        }
        _validateRoutes(routes);

        // Token sanity: routes[0].from / routes[routes.length-1].to are already covered by
        // _validateRoutes' per-hop `_rejectDelegatedEOA` calls, which revert on bare EOAs and on
        // EIP-7702 delegated EOAs. The only non-redundant check that remains here is the
        // circular-route guard below.
        address tokenInAddr = routes[0].from;
        // Block circular routes (input == output token).
        if (tokenInAddr == routes[routes.length - 1].to) revert Errors.InvalidRoute();

        IERC20 tokenIn = IERC20(tokenInAddr);
        _ensureCallerCanSpend(tokenIn, amountIn);

        (uint256 preBal, bool preBalOk) = _callBalanceOfLimited(tokenIn, address(this));
        // Pull tokens in, approve the underlying router, then forward.
        if (!SafeTransfer.callTransferFrom(tokenIn, msg.sender, address(this), amountIn)) {
            revert Errors.TransferFailed();
        }
        // _forceApprove handles USDT-style approve-to-zero-first tokens.
        // Post-swap _forceApproveExact(..., 0) clears leftover allowance.
        // Fee-on-transfer tokens can make amountIn differ from the balance delta;
        // such tokens are unsupported (see contract header and EntryTokenRegistry).
        _forceApprove(tokenIn, aerodromeRouter, amountIn);

        amounts = IDexAdapter(aerodromeRouter).swapExactTokensForTokens(amountIn, amountOutMin, routes, to, deadline);
        if (amounts.length != routes.length + 1) revert Errors.ReturnDataTooLarge();
        if (amounts[0] != amountIn) revert Errors.InvariantViolation();
        if (amounts[amounts.length - 1] < amountOutMin) revert Errors.MinAmountOutNotMet();

        // Post-swap hardening: clear any leftover allowance (e.g., fee-on-transfer tokens or partial spends).
        _forceApproveExact(tokenIn, aerodromeRouter, 0);
        if (preBalOk) {
            (uint256 postBal, bool postBalOk) = _callBalanceOfLimited(tokenIn, address(this));
            if (!postBalOk || postBal > preBal) revert Errors.InvariantViolation();
        } else {
            // Pre-probe failed (token has expensive balanceOf). Fallback is intentionally strict:
            // if the adapter holds ANY tokenIn after the swap, treat it as an invariant break.
            // This rejects legitimate owner pre-donations on such tokens; owner must `rescueToken`
            // first. The path is reachable only when balanceOf cost crosses the SafeERC20View 240k
            // gas cap during the swap (rare; both probes share the same cap).
            (uint256 postBal, bool postBalOk) = _callBalanceOfLimited(tokenIn, address(this));
            if (!postBalOk || postBal > 0) revert Errors.InvariantViolation();
        }

        return amounts;
    }

    /// @dev Pre-swap hardening:
    /// - caller must have enough balance
    /// - caller must have approved this adapter (core contracts do this via _forceApprove)
    function _ensureCallerCanSpend(IERC20 tokenIn, uint256 amountIn) internal view {
        // If gasleft() < 700000 at entry, skip probes and rely on transferFrom revert path.
        // The actual security enforcement is in transferFrom (which reverts on insufficient
        // balance or allowance); these probes only provide friendlier error messages.
        if (gasleft() < 700000) return;

        (uint256 bal, bool balOk) = _callBalanceOfLimited(tokenIn, msg.sender);
        if (balOk && bal < amountIn) revert Errors.InsufficientTokenBalance();

        (uint256 allow, bool allowOk) = _callAllowanceLimited(tokenIn, msg.sender, address(this));
        if (allowOk && allow < amountIn) revert Errors.InsufficientTokenAllowance();
    }

    /// @dev Best-effort bounded-gas balanceOf probe for pre-swap checks. Delegates to
    ///      `SafeERC20View` so the gas budget and return-bomb handling stay consistent with every
    ///      other balance-probe site. On failure returns `(0, false)` and the caller falls back to
    ///      transferFrom enforcement.
    function _callBalanceOfLimited(IERC20 token, address account) private view returns (uint256 value, bool ok) {
        return SafeERC20View.callBalanceOf(token, account);
    }

    /// @dev Best-effort bounded-gas allowance probe for pre-swap checks. Delegates to
    ///      `SafeERC20View.callAllowance` for identical gas + return-bomb semantics. On failure
    ///      returns `(0, false)` and the caller falls back to transferFrom enforcement.
    function _callAllowanceLimited(IERC20 token, address owner, address spender)
        private
        view
        returns (uint256 value, bool ok)
    {
        return SafeERC20View.callAllowance(token, owner, spender);
    }

    /// @dev Some tokens (e.g. USDT) require setting allowance to zero before setting a new value.
    ///      This helper sets allowance to exactly `value`.
    ///      Defense-in-depth: always re-approve to the exact required amount even if the
    ///      current allowance is higher, to avoid leaving stale elevated allowances on
    ///      the router between the approve and the post-swap cleanup.
    function _forceApprove(IERC20 token, address spender, uint256 value) internal {
        // Under tight gas, skip allowance probe and attempt direct approve first.
        if (gasleft() < 300000) {
            if (_callApprove(token, spender, value)) return;
            if (!_callApprove(token, spender, 0)) revert Errors.ApprovalFailed();
            if (!_callApprove(token, spender, value)) revert Errors.ApprovalFailed();
            return;
        }

        (uint256 current, bool ok) = _callAllowanceLimited(token, address(this), spender);
        if (ok && current == value) return;

        // Try to set directly; if it fails, fall back to the "set to 0 then set" pattern.
        if (_callApprove(token, spender, value)) return;

        if (!_callApprove(token, spender, 0)) revert Errors.ApprovalFailed();
        if (!_callApprove(token, spender, value)) revert Errors.ApprovalFailed();
    }

    /// @dev Force-set allowance to an exact value (including decreasing), using the same hardening pattern.
    function _forceApproveExact(IERC20 token, address spender, uint256 value) internal {
        // Under tight gas, skip allowance probe and attempt direct approve first.
        if (gasleft() < 300000) {
            if (_callApprove(token, spender, value)) return;
            if (!_callApprove(token, spender, 0)) revert Errors.ApprovalFailed();
            if (value == 0) return;
            if (!_callApprove(token, spender, value)) revert Errors.ApprovalFailed();
            return;
        }

        (uint256 current, bool ok) = _callAllowanceLimited(token, address(this), spender);
        if (ok && current == value) return;

        if (_callApprove(token, spender, value)) return;

        if (!_callApprove(token, spender, 0)) revert Errors.ApprovalFailed();
        if (value == 0) return;
        if (!_callApprove(token, spender, value)) revert Errors.ApprovalFailed();
    }

    /// @dev Low-level approve wrapper:
    /// - Returns true on success (including tokens that return no data).
    /// - Returns false on failure or on non-standard return sizes.
    function _callApprove(IERC20 token, address spender, uint256 value) private returns (bool) {
        return SafeApprove.callApprove(token, spender, value);
    }
}
