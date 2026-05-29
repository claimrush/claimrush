// SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

import {Ownable2Step} from "@openzeppelin/contracts/access/Ownable2Step.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";

import {Errors} from "./lib/Errors.sol";
import {Events} from "./lib/Events.sol";

import {IDexAdapter} from "./interfaces/IDexAdapter.sol";
import {IEntryTokenRegistry} from "./interfaces/IEntryTokenRegistry.sol";

/// @notice EntryTokenRegistry (v1.0.0)
/// @dev Implements the normative interface pinned by docs/spec/entry-token-registry-v1.0.0.md.
///
/// This contract is governance-controlled through live `owner()` / `guardian` addresses (production deployments are expected to put `owner()` behind a timelock; guardian remains disable-only token response plus emergency self-rotation) and is the canonical allowlist + deterministic routing table for
/// token-based entry.
///
/// TOKEN SAFETY:
/// - Fee-on-transfer tokens MUST NOT be allowlisted. The DexAdapter custody hop causes amount
///   mismatches that will either revert the swap or produce incorrect accounting.
/// - Rebasing / elastic-supply tokens MUST NOT be allowlisted. Balance changes between pull and
///   swap break amount invariants across the protocol.
/// - Furnace token entry additionally requires an explicit exact-receipt-safe opt-in before
///   non-WETH tokens become quotable or executable on Furnace routes.
contract EntryTokenRegistry is Ownable2Step, IEntryTokenRegistry {
    // ------------------------------------------------------------
    // Storage
    // ------------------------------------------------------------

    /// @notice Guardian role for emergency token disables plus emergency guardian rotation.
    /// @dev Guardian MUST NOT be able to enable tokens or change router/config surfaces.
    address public guardian;

    uint256 public constant GUARDIAN_DISABLE_COOLDOWN = 1 hours;
    mapping(address => uint256) public guardianDisabledUntil;

    address internal _router;
    address internal _factory;
    address internal _wrappedNative;
    address internal _claimToken;

    bool internal _wethClaimStable;
    address internal _wethClaimPool;

    mapping(address => TokenConfig) internal _tokenConfig;
    // Once "seen", a token is never removed and _configuredTokenCount never decreases.
    // If any token is configured (even with enabled=false) and the operator later wants to
    // change the router/factory, the call reverts because _configuredTokenCount > 0 or
    // _wethClaimPool != address(0) triggers the WiringMismatch guard.
    mapping(address => bool) internal _configuredTokenSeen;
    uint256 internal _configuredTokenCount;
    mapping(address => bool) internal _furnaceEntryTokenExactReceiptSafe;

    constructor(address initialOwner) Ownable(initialOwner) {
        if (initialOwner == address(0)) revert Errors.ZeroAddress();
        // The runtime guardian seat rejects EIP-7702 delegated EOAs via
        // `setGuardian()`. The constructor seat applies the same rule so a
        // delegated `initialOwner` cannot ship as the genesis guardian.
        _rejectDelegatedEOA(initialOwner);

        // Default to owner for safety during local/dev; rotate in production.
        guardian = initialOwner;
        // Emit so indexers can track the initial guardian from genesis.
        emit Events.GuardianChanged(address(0), initialOwner);
    }

    /// @dev Prevent accidental permanent lock-out from admin and config surfaces.
    function renounceOwnership() public pure override {
        revert Errors.NotAuthorized();
    }

    /// @dev Reject EIP-7702 delegated EOAs from acquiring the owner role. A delegated
    ///      owner can expose public-executor code and let arbitrary callers exercise
    ///      `setGuardian`, `setRouterConfig`, `setTokenConfig`, and the freeze surface
    ///      after acceptance.
    function transferOwnership(address newOwner) public override onlyOwner {
        if (newOwner == address(0)) revert Errors.ZeroAddress();
        _rejectDelegatedEOA(newOwner);
        super.transferOwnership(newOwner);
    }

    /// @dev Acceptance-time re-validation. The 7702 designator can land on the
    ///      nominee between nomination and acceptance; rejecting at acceptance
    ///      keeps the owner seat off any delegated EOA.
    function acceptOwnership() public override {
        _rejectDelegatedEOA(msg.sender);
        super.acceptOwnership();
    }

    /// @dev Re-runs the EIP-7702 designator guard on `msg.sender` for every
    ///      `onlyOwner` call. A clean owner that installs `0xEF0100…` after
    ///      acceptance cannot expose owner-only surfaces (`setGuardian`,
    ///      `setRouterConfig`, `setTokenConfig`, the freeze surface) through
    ///      public-executor code. The OZ `Ownable._checkOwner` parent does not
    ///      apply this guard; the override fills that gap.
    function _checkOwner() internal view override {
        super._checkOwner();
        _rejectDelegatedEOA(msg.sender);
    }

    // ------------------------------------------------------------
    // Modifiers
    // ------------------------------------------------------------

    // ------------------------------------------------------------
    // Guardian
    // ------------------------------------------------------------
    function setGuardian(address _guardian) external {
        // Owner or current guardian may set a new guardian (incident response and key rotation).
        // guardian == owner is allowed (weaker separation of duties; common in dev/test setups).
        address sender = msg.sender;
        if (sender == owner()) {
            // Runtime 7702 reject on the caller seat. The owner branch does not
            // route through `onlyOwner`, so apply the same guard the override on
            // `_checkOwner` runs for owner-only entry points.
            _rejectDelegatedEOA(sender);
        } else if (sender == guardian) {
            // guardian self-rotation path: re-run the runtime delegate guard so a
            // post-seating 7702 install on the guardian seat cannot route a
            // self-rotation through the guardian role.
            _rejectDelegatedEOA(sender);
        } else {
            revert Errors.NotAuthorized();
        }
        if (_guardian == address(0)) revert Errors.ZeroAddress();
        // Guardian address must be an externally governed account, not this registry.
        if (_guardian == address(this)) revert Errors.NotAuthorized();
        // Bare EOAs remain valid guardians (the helper short-circuits on
        // `code.length == 0`); only EIP-7702 delegated EOAs are rejected so the
        // signer cannot rotate the role or call the guardian pause surfaces
        // through public executor code.
        _rejectDelegatedEOA(_guardian);
        address oldGuardian = guardian;
        guardian = _guardian;
        emit Events.GuardianChanged(oldGuardian, _guardian);
    }

    // ------------------------------------------------------------
    // Router config
    // ------------------------------------------------------------

    function setRouterConfig(address router, address factory, address wrappedNative, address claimToken)
        external
        override
        // wrappedNative and claimToken are effectively immutable after first set.
        // Router/factory cannot change once any pool has been configured (_configuredTokenCount > 0
        // or _wethClaimPool != 0). This forms a one-way ratchet.
        onlyOwner
    {
        if (router == address(0) || factory == address(0) || wrappedNative == address(0) || claimToken == address(0)) {
            revert Errors.ZeroAddress();
        }

        // Defensive: require contract code for router/factory/tokens to avoid opaque ABI decode reverts.
        if (
            router.code.length == 0 || factory.code.length == 0 || wrappedNative.code.length == 0
                || claimToken.code.length == 0
        ) {
            revert Errors.NotAContract();
        }
        _rejectDelegatedEOA(router);
        _rejectDelegatedEOA(factory);
        _rejectDelegatedEOA(wrappedNative);
        _rejectDelegatedEOA(claimToken);

        if (router == factory || router == wrappedNative || router == claimToken) revert Errors.WiringMismatch();
        if (factory == wrappedNative || factory == claimToken) revert Errors.WiringMismatch();
        if (wrappedNative == claimToken) revert Errors.InvalidToken();

        // Governance invariant: after first successful initialization, wrappedNative and claimToken cannot change.
        // This blocks silent WETH/CLAIM rewiring once routing surfaces depend on those roots.
        if (_wrappedNative != address(0) && wrappedNative != _wrappedNative) revert Errors.WrappedNativeImmutable();
        if (_claimToken != address(0) && claimToken != _claimToken) revert Errors.ClaimTokenImmutable();

        // Once any pool surface is configured, router/factory cannot change without invalidating the
        // recorded expectedPool addresses. Redeploy a fresh registry instead of rewiring in place.
        if (_router != address(0) && (router != _router || factory != _factory)) {
            if (_wethClaimPool != address(0) || _configuredTokenCount != 0) revert Errors.WiringMismatch();
        }

        // Canonical rule: factory MUST equal router.defaultFactory().
        address df = IDexAdapter(router).defaultFactory();
        if (factory != df) revert Errors.FactoryMismatch();

        // Optional but safety-hardening: wrappedNative SHOULD match router.weth().
        address w = IDexAdapter(router).weth();
        if (wrappedNative != w) revert Errors.WrappedNativeMismatch();

        _router = router;
        _factory = factory;
        _wrappedNative = wrappedNative;
        _claimToken = claimToken;

        emit Events.RouterConfigSet(router, factory, wrappedNative, claimToken);
    }

    function getRouterConfig()
        external
        view
        override
        returns (address router, address factory, address wrappedNative, address claimToken)
    {
        return (_router, _factory, _wrappedNative, _claimToken);
    }

    // ------------------------------------------------------------
    // WETH/CLAIM hop
    // ------------------------------------------------------------

    function setWethClaimHop(bool stable, address expectedPool) external override onlyOwner {
        if (_wethClaimPool != address(0)) revert Errors.WethClaimHopAlreadySet();
        if (expectedPool == address(0)) revert Errors.ZeroAddress();
        _requireRouterConfig();
        // expectedPool.code.length is also checked as defense-in-depth against
        // CREATE2 ghost addresses (deterministic address with no code deployed yet).

        // Validate the allowlisted pool matches router.poolFor(...) using the canonical signature.
        address pool = IDexAdapter(_router).poolFor(_wrappedNative, _claimToken, stable, _factory);
        if (pool != expectedPool) revert Errors.InvalidPool();
        // Freeze-time integrity: the canonical hop must point at a live pool contract, not merely a
        // deterministic CREATE2 address that has not been deployed yet.
        if (expectedPool.code.length == 0) revert Errors.NotAContract();
        _rejectDelegatedEOA(expectedPool);

        _wethClaimStable = stable;
        _wethClaimPool = expectedPool;

        emit Events.WethClaimPoolSet(expectedPool, stable);
    }

    function getWethClaimHop() external view override returns (bool stable, address pool) {
        return (_wethClaimStable, _wethClaimPool);
    }

    // ------------------------------------------------------------
    // Token config
    // ------------------------------------------------------------

    function setTokenConfig(
        address tokenIn,
        bool enabled,
        bool directToClaimEnabled,
        bool tokenClaimStable,
        address tokenClaimPool,
        bool tokenWethStable,
        address tokenWethPool
    ) external override onlyOwner {
        _requireRouterConfig();

        // Respect guardian disable cooldown even on full reconfiguration.
        if (enabled && guardianDisabledUntil[tokenIn] > block.timestamp) revert Errors.NotAuthorized();

        if (tokenIn == address(0)) revert Errors.ZeroAddress();
        if (tokenIn.code.length == 0) revert Errors.NotAContract();
        _rejectDelegatedEOA(tokenIn);
        if (
            tokenIn == _claimToken || tokenIn == _wrappedNative || tokenIn == address(this) || tokenIn == _router
                || tokenIn == _factory
        ) revert Errors.InvalidToken();

        // tokenIn -> WETH hop is always required (takeover route, and Furnace via-WETH path).
        if (tokenWethPool == address(0)) revert Errors.ZeroAddress();
        address poolW = IDexAdapter(_router).poolFor(tokenIn, _wrappedNative, tokenWethStable, _factory);
        if (poolW != tokenWethPool) revert Errors.InvalidPool();
        if (tokenWethPool.code.length == 0) revert Errors.NotAContract();
        _rejectDelegatedEOA(tokenWethPool);

        // Optional direct tokenIn -> CLAIM hop (Furnace-only).
        if (directToClaimEnabled) {
            if (tokenClaimPool == address(0)) revert Errors.ZeroAddress();
            address poolC = IDexAdapter(_router).poolFor(tokenIn, _claimToken, tokenClaimStable, _factory);
            if (poolC != tokenClaimPool) revert Errors.InvalidPool();
            if (tokenClaimPool.code.length == 0) revert Errors.NotAContract();
            _rejectDelegatedEOA(tokenClaimPool);
        } else {
            tokenClaimPool = address(0);
            tokenClaimStable = false;
        }

        if (!_configuredTokenSeen[tokenIn]) {
            _configuredTokenSeen[tokenIn] = true;
            _configuredTokenCount += 1;
        }

        _tokenConfig[tokenIn] = TokenConfig({
            enabled: enabled,
            directToClaimEnabled: directToClaimEnabled,
            tokenClaimStable: tokenClaimStable,
            tokenClaimPool: tokenClaimPool,
            tokenWethStable: tokenWethStable,
            tokenWethPool: tokenWethPool
        });

        emit Events.TokenConfigSet(
            tokenIn, enabled, directToClaimEnabled, tokenClaimStable, tokenClaimPool, tokenWethStable, tokenWethPool
        );
    }

    function setFurnaceEntryTokenExactReceiptSafe(address tokenIn, bool exactReceiptSafe) external override onlyOwner {
        _requireConfigurableToken(tokenIn);
        if (!_configuredTokenSeen[tokenIn]) revert Errors.TokenNotConfigured();
        _furnaceEntryTokenExactReceiptSafe[tokenIn] = exactReceiptSafe;
        emit Events.FurnaceEntryTokenSafetySet(tokenIn, exactReceiptSafe);
    }

    function setTokenEnabled(address tokenIn, bool enabled) external override {
        if (tokenIn == address(0)) revert Errors.ZeroAddress();
        if (tokenIn == _claimToken || tokenIn == _wrappedNative) revert Errors.InvalidToken();
        if (tokenIn == address(this) || tokenIn == _router || tokenIn == _factory) revert Errors.InvalidToken();
        if (enabled && tokenIn.code.length == 0) revert Errors.NotAContract();
        if (enabled) _rejectDelegatedEOA(tokenIn);

        if (!_configuredTokenSeen[tokenIn]) revert Errors.TokenNotConfigured();
        TokenConfig memory cfg = _tokenConfig[tokenIn];
        if (enabled && cfg.tokenWethPool == address(0)) revert Errors.TokenNotConfigured();

        // Authorize first. The idempotent no-op below MUST sit beneath this branch
        // so an unauthorized caller cannot probe state by receiving a successful
        // return on a no-op; integrations that key off call success vs revert see
        // the correct permissioned semantic. The role decision is recorded as a
        // local bool so the cooldown bump below distinguishes "owner acting as
        // guardian during dev setups" from a real guardian-initiated disable.
        address sender = msg.sender;
        bool senderIsOwner = sender == owner();
        bool senderIsGuardian = !senderIsOwner && sender == guardian;
        if (senderIsOwner) {
            if (enabled && guardianDisabledUntil[tokenIn] > block.timestamp) {
                revert Errors.NotAuthorized();
            }
            // Runtime 7702 reject on the caller seat. The owner branch does not
            // route through `onlyOwner`, so apply the same guard the override on
            // `_checkOwner` runs for owner-only entry points.
            _rejectDelegatedEOA(sender);
        } else if (senderIsGuardian) {
            if (enabled) revert Errors.NotAuthorized();
            // Defense-in-depth: re-run the runtime delegate guard so a
            // post-seating 7702 install on the guardian seat cannot route a
            // disable through the guardian's emergency surface.
            _rejectDelegatedEOA(sender);
        } else {
            revert Errors.NotAuthorized();
        }

        // Idempotency: skip storage write, event emission, AND the guardian
        // cooldown bump when the requested state matches current state. Placed
        // BELOW the auth branch so a guardian calling `setTokenEnabled(token, false)`
        // against an already-disabled token does NOT renew `guardianDisabledUntil`,
        // and unauthorized callers always see `NotAuthorized()`.
        if (cfg.enabled == enabled) return;

        // Only the first guardian-as-guardian disable in a window moves the
        // cooldown expiry forward. Owner calls (including dev setups where
        // `guardian == owner`) MUST NOT bump the cooldown — otherwise an owner
        // disable would lock out the owner's own re-enable. A compromised
        // guardian still cannot extend the lock-out indefinitely: the cooldown
        // is gated on `<= block.timestamp` so repeat disables inside the window
        // do not push the expiry further.
        if (senderIsGuardian) {
            if (guardianDisabledUntil[tokenIn] <= block.timestamp) {
                guardianDisabledUntil[tokenIn] = block.timestamp + GUARDIAN_DISABLE_COOLDOWN;
            }
        }

        if (enabled) {
            _requireRouterConfig();
            // For via-WETH tokens (directToClaimEnabled == false), Furnace routes
            // require the global WETH→CLAIM hop (_wethClaimPool). If it is not yet set,
            // Furnace resolution reverts with WethClaimHopNotSet at call time. Takeover
            // routes (token→WETH only) remain functional. Governance should ensure
            // setWethClaimHop is called before enabling via-WETH tokens for Furnace entry.
            if (cfg.tokenWethPool.code.length == 0) revert Errors.NotAContract();
            _rejectDelegatedEOA(cfg.tokenWethPool);
            address poolW = IDexAdapter(_router).poolFor(tokenIn, _wrappedNative, cfg.tokenWethStable, _factory);
            if (poolW != cfg.tokenWethPool) revert Errors.InvalidPool();
            if (cfg.directToClaimEnabled) {
                if (cfg.tokenClaimPool == address(0)) revert Errors.InvalidPool();
                if (cfg.tokenClaimPool.code.length == 0) revert Errors.NotAContract();
                _rejectDelegatedEOA(cfg.tokenClaimPool);
                address poolC = IDexAdapter(_router).poolFor(tokenIn, _claimToken, cfg.tokenClaimStable, _factory);
                if (poolC != cfg.tokenClaimPool) revert Errors.InvalidPool();
            } else if (_wethClaimPool != address(0)) {
                if (_wethClaimPool.code.length == 0) revert Errors.NotAContract();
                _rejectDelegatedEOA(_wethClaimPool);
                address poolC = IDexAdapter(_router).poolFor(_wrappedNative, _claimToken, _wethClaimStable, _factory);
                if (poolC != _wethClaimPool) revert Errors.InvalidPool();
            }
        }

        cfg.enabled = enabled;
        _tokenConfig[tokenIn] = cfg;

        emit Events.TokenEnabledChanged(tokenIn, enabled);
    }

    function isFurnaceEntryTokenExactReceiptSafe(address tokenIn) external view override returns (bool) {
        return _furnaceEntryTokenExactReceiptSafe[tokenIn];
    }

    function getTokenConfig(address tokenIn) external view override returns (TokenConfig memory) {
        return _tokenConfig[tokenIn];
    }

    // ------------------------------------------------------------
    // Route resolution
    // ------------------------------------------------------------

    function resolveFurnaceRoute(address tokenIn)
        external
        view
        override
        returns (RegistryRoute[] memory route, uint256 routeTokenId)
    {
        if (tokenIn == address(0)) revert Errors.ZeroAddress();
        if (tokenIn == _claimToken || tokenIn == _wrappedNative) revert Errors.InvalidToken();
        if (tokenIn == address(this) || tokenIn == _router || tokenIn == _factory) revert Errors.InvalidToken();
        if (tokenIn.code.length == 0) revert Errors.NotAContract();
        _rejectDelegatedEOA(tokenIn);
        TokenConfig memory cfg = _tokenConfig[tokenIn];
        // If no config has ever been set, treat as "not configured" (distinct from "disabled").
        if (cfg.tokenWethPool == address(0)) revert Errors.TokenNotConfigured();
        if (!cfg.enabled) revert Errors.TokenNotEnabled();
        if (!_furnaceEntryTokenExactReceiptSafe[tokenIn]) revert Errors.UnsafeEntryToken();
        _requireRouterConfig();

        if (cfg.directToClaimEnabled) {
            if (cfg.tokenClaimPool.code.length == 0) revert Errors.NotAContract();
            _rejectDelegatedEOA(cfg.tokenClaimPool);
            if (
                IDexAdapter(_router).poolFor(tokenIn, _claimToken, cfg.tokenClaimStable, _factory) != cfg.tokenClaimPool
            ) {
                revert Errors.InvalidPool();
            }
            route = new RegistryRoute[](1);
            route[0] = RegistryRoute({
                tokenIn: tokenIn, tokenOut: _claimToken, stable: cfg.tokenClaimStable, pool: cfg.tokenClaimPool
            });
            routeTokenId = 0;
            return (route, routeTokenId);
        }

        if (_wethClaimPool == address(0)) revert Errors.WethClaimHopNotSet();

        if (cfg.tokenWethPool.code.length == 0) revert Errors.NotAContract();
        if (_wethClaimPool.code.length == 0) revert Errors.NotAContract();
        _rejectDelegatedEOA(cfg.tokenWethPool);
        _rejectDelegatedEOA(_wethClaimPool);
        if (IDexAdapter(_router).poolFor(tokenIn, _wrappedNative, cfg.tokenWethStable, _factory) != cfg.tokenWethPool) {
            revert Errors.InvalidPool();
        }
        if (IDexAdapter(_router).poolFor(_wrappedNative, _claimToken, _wethClaimStable, _factory) != _wethClaimPool) {
            revert Errors.InvalidPool();
        }
        route = new RegistryRoute[](2);
        route[0] = RegistryRoute({
            tokenIn: tokenIn, tokenOut: _wrappedNative, stable: cfg.tokenWethStable, pool: cfg.tokenWethPool
        });
        route[1] = RegistryRoute({
            tokenIn: _wrappedNative, tokenOut: _claimToken, stable: _wethClaimStable, pool: _wethClaimPool
        });
        routeTokenId = 1;
    }

    function resolveTakeoverRoute(address tokenIn) external view override returns (RegistryRoute[] memory route) {
        if (tokenIn == address(0)) revert Errors.ZeroAddress();
        if (tokenIn == _claimToken || tokenIn == _wrappedNative) revert Errors.InvalidToken();
        if (tokenIn == address(this) || tokenIn == _router || tokenIn == _factory) revert Errors.InvalidToken();
        if (tokenIn.code.length == 0) revert Errors.NotAContract();
        _rejectDelegatedEOA(tokenIn);
        TokenConfig memory cfg = _tokenConfig[tokenIn];
        // If no config has ever been set, treat as "not configured" (distinct from "disabled").
        if (cfg.tokenWethPool == address(0)) revert Errors.TokenNotConfigured();
        if (!cfg.enabled) revert Errors.TokenNotEnabled();
        _requireRouterConfig();

        if (cfg.tokenWethPool.code.length == 0) revert Errors.NotAContract();
        _rejectDelegatedEOA(cfg.tokenWethPool);
        if (IDexAdapter(_router).poolFor(tokenIn, _wrappedNative, cfg.tokenWethStable, _factory) != cfg.tokenWethPool) {
            revert Errors.InvalidPool();
        }
        route = new RegistryRoute[](1);
        route[0] = RegistryRoute({
            tokenIn: tokenIn, tokenOut: _wrappedNative, stable: cfg.tokenWethStable, pool: cfg.tokenWethPool
        });
    }

    // ------------------------------------------------------------
    // Internal helpers
    // ------------------------------------------------------------

    function _requireRouterConfig() internal view {
        if (
            _router == address(0) || _factory == address(0) || _wrappedNative == address(0) || _claimToken == address(0)
        ) {
            revert Errors.RouterConfigNotSet();
        }
    }

    function _requireConfigurableToken(address tokenIn) internal view {
        if (tokenIn == address(0)) revert Errors.ZeroAddress();
        if (tokenIn.code.length == 0) revert Errors.NotAContract();
        _rejectDelegatedEOA(tokenIn);
        if (
            tokenIn == _claimToken || tokenIn == _wrappedNative || tokenIn == address(this) || tokenIn == _router
                || tokenIn == _factory
        ) revert Errors.InvalidToken();
    }

    function _rejectDelegatedEOA(address addr) internal view {
        if (addr.code.length != 23) return;
        bytes32 head;
        assembly ("memory-safe") {
            let ptr := mload(0x40)
            extcodecopy(addr, ptr, 0, 3)
            head := mload(ptr)
        }
        if (uint256(head) >> 232 == 0xEF0100) revert Errors.DelegatedEOA();
    }
}
