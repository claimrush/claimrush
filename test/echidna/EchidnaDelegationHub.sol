// SPDX-License-Identifier: MIT
pragma solidity ^0.8.34;

import {EchidnaSetup} from "./EchidnaSetup.sol";
import {DelegationPermissions} from "src/lib/DelegationPermissions.sol";

/// @dev EIP-1271 helper used to exercise setSessionBySig without private keys.
contract AlwaysValid1271 {
    function isValidSignature(bytes32, bytes calldata) external pure returns (bytes4) {
        return 0x1626ba7e;
    }
}

/// @title Echidna harness for DelegationHub session and nonce invariants.
/// @dev Targets authorization semantics, nonce monotonicity, and canonical revocation shape.
///
/// @dev Corpus-bounding rationale (2026-05-06 rework):
///      Earlier revisions accepted `uint256 delegateSeed` and
///      `uint256 permsSeed`. After the harness collapses these via
///      `address(uint160(seed))` (160 bits used, 96 bits ignored) and
///      `permsSeed & DelegationPermissions.ALL` (only 18 bits used), the
///      high bits had no semantic effect on the contract under test.
///      Echidna's coverage tracker, however, treated every distinct
///      256-bit input as a candidate corpus entry, so the corpus kept
///      growing with equivalent sequences — this harness OOM-killed at
///      24/30 GB after ~5–7 h on the 9cb72e42 sweep across 3 separate
///      attempts (cumulative ~1.23 B sequences, cov:21037 plateau, 0
///      assertion violations).
///      Narrowing to `uint8 delegateSeed` (256 distinct delegates ≫
///      MAX_TRACKED_DELEGATES = 16) and `uint32 permsSeed` (32 bits ≫
///      the 18-bit `ALL` mask) collapses the corpus to the value ranges
///      that actually exercise distinct branches.
contract EchidnaDelegationHub is EchidnaSetup {
    uint256 internal constant INVALID_PERMISSION_BIT = uint256(1) << 255;
    uint256 internal constant MAX_TRACKED_DELEGATES = 16;

    AlwaysValid1271 internal sigUserWallet;

    uint256 internal expectedHarnessNonce;
    uint256 internal expectedSigUserNonce;
    bool internal sawUnexpectedNonceDelta;

    address[] internal harnessDelegates;
    mapping(address => bool) internal harnessDelegateSeen;
    address[] internal sigUserDelegates;
    mapping(address => bool) internal sigUserDelegateSeen;

    constructor() payable {
        _deployAndWire();
        sigUserWallet = new AlwaysValid1271();
    }

    // ================================================================
    // Actions
    // ================================================================

    function action_setSession(uint8 delegateSeed, uint32 permsSeed, uint64 ttlSeconds, bool includeUnknownBits)
        public
    {
        address user = address(this);
        address delegate = _normalizeDelegate(uint256(delegateSeed), user);
        uint256 perms = uint256(permsSeed) & DelegationPermissions.ALL;
        if (includeUnknownBits && perms != 0) {
            perms |= INVALID_PERMISSION_BIT;
        }
        uint64 expiry = perms == 0 ? 0 : _futureExpiry(ttlSeconds);

        uint256 nonceBefore = delegationHub.nonces(user);
        try delegationHub.setSession(delegate, perms, expiry) {
            expectedHarnessNonce += 1;
            _trackHarnessDelegate(delegate);
            _checkNonceDelta(user, nonceBefore, true);
        } catch {
            _checkNonceDelta(user, nonceBefore, false);
        }
    }

    function action_revokeSession(uint8 idx) public {
        if (harnessDelegates.length == 0) return;
        address user = address(this);
        address delegate = harnessDelegates[uint256(idx) % harnessDelegates.length];

        uint256 nonceBefore = delegationHub.nonces(user);
        try delegationHub.revokeSession(delegate) {
            expectedHarnessNonce += 1;
            _checkNonceDelta(user, nonceBefore, true);
        } catch {
            _checkNonceDelta(user, nonceBefore, false);
        }
    }

    function action_setSessionBySig(
        uint8 delegateSeed,
        uint32 permsSeed,
        uint64 ttlSeconds,
        bool useCurrentNonce,
        bool expiredDeadline,
        bool includeUnknownBits
    ) public {
        address user = address(sigUserWallet);
        address delegate = _normalizeDelegate(uint256(delegateSeed), user);
        uint256 perms = uint256(permsSeed) & DelegationPermissions.ALL;
        if (includeUnknownBits && perms != 0) {
            perms |= INVALID_PERMISSION_BIT;
        }
        uint64 expiry = perms == 0 ? 0 : _futureExpiry(ttlSeconds);

        uint256 nonce = delegationHub.nonces(user);
        if (!useCurrentNonce) {
            nonce = nonce + 1;
        }

        uint256 deadline;
        if (expiredDeadline) {
            deadline = block.timestamp == 0 ? 0 : block.timestamp - 1;
        } else {
            deadline = block.timestamp + uint256(_boundTtl(ttlSeconds));
        }

        bytes memory sig = hex"01";
        uint256 nonceBefore = delegationHub.nonces(user);
        try delegationHub.setSessionBySig(user, delegate, perms, expiry, nonce, deadline, sig) {
            expectedSigUserNonce += 1;
            _trackSigUserDelegate(delegate);
            _checkNonceDelta(user, nonceBefore, true);
        } catch {
            _checkNonceDelta(user, nonceBefore, false);
        }
    }

    // ================================================================
    // Properties
    // ================================================================

    function echidna_nonce_accounting() public view returns (bool) {
        return !sawUnexpectedNonceDelta && delegationHub.nonces(address(this)) == expectedHarnessNonce
            && delegationHub.nonces(address(sigUserWallet)) == expectedSigUserNonce;
    }

    function echidna_self_and_zero_perm_never_authorized() public view returns (bool) {
        if (delegationHub.isAuthorized(address(this), address(this), DelegationPermissions.P_TAKEOVER_FOR)) {
            return false;
        }
        if (delegationHub.isAuthorized(
                address(sigUserWallet), address(sigUserWallet), DelegationPermissions.P_FURNACE_ENTER_CLAIM_FOR
            )) return false;

        for (uint256 i = 0; i < harnessDelegates.length; i++) {
            if (delegationHub.isAuthorized(address(this), harnessDelegates[i], 0)) return false;
        }
        for (uint256 i = 0; i < sigUserDelegates.length; i++) {
            if (delegationHub.isAuthorized(address(sigUserWallet), sigUserDelegates[i], 0)) return false;
        }
        return true;
    }

    function echidna_invalid_required_perms_never_authorized() public view returns (bool) {
        uint256 invalidRequired = DelegationPermissions.P_TAKEOVER_FOR | INVALID_PERMISSION_BIT;
        for (uint256 i = 0; i < harnessDelegates.length; i++) {
            if (delegationHub.isAuthorized(address(this), harnessDelegates[i], invalidRequired)) return false;
        }
        for (uint256 i = 0; i < sigUserDelegates.length; i++) {
            if (delegationHub.isAuthorized(address(sigUserWallet), sigUserDelegates[i], invalidRequired)) return false;
        }
        return true;
    }

    function echidna_canonical_revocation_shape() public view returns (bool) {
        if (!_checkCanonicalShapeForUser(address(this), harnessDelegates)) return false;
        if (!_checkCanonicalShapeForUser(address(sigUserWallet), sigUserDelegates)) return false;
        return true;
    }

    function echidna_authorization_matches_session_predicate() public view returns (bool) {
        if (!_checkAuthorizationPredicateForUser(address(this), harnessDelegates)) return false;
        if (!_checkAuthorizationPredicateForUser(address(sigUserWallet), sigUserDelegates)) return false;
        return true;
    }

    // ================================================================
    // Internal helpers
    // ================================================================

    function _checkCanonicalShapeForUser(address user, address[] storage delegates) internal view returns (bool) {
        for (uint256 i = 0; i < delegates.length; i++) {
            address delegate = delegates[i];
            (uint256 perms, uint256 expiry) = delegationHub.getSession(user, delegate);

            if (perms == 0 && expiry != 0) return false;
            if ((perms & ~DelegationPermissions.ALL) != 0) return false;

            if (
                expiry <= block.timestamp
                    && delegationHub.isAuthorized(user, delegate, DelegationPermissions.P_SET_KING_AUTO_LOCK_CONFIG_FOR)
            ) {
                return false;
            }
        }
        return true;
    }

    function _checkAuthorizationPredicateForUser(address user, address[] storage delegates)
        internal
        view
        returns (bool)
    {
        uint256[3] memory probes = [
            uint256(DelegationPermissions.P_TAKEOVER_FOR),
            uint256(DelegationPermissions.P_CLAIM_ALL_FOR),
            uint256(DelegationPermissions.P_FURNACE_ENTER_TOKEN_FOR)
        ];

        for (uint256 i = 0; i < delegates.length; i++) {
            address delegate = delegates[i];
            (uint256 perms, uint256 expiry) = delegationHub.getSession(user, delegate);
            bool live = expiry != 0 && expiry > block.timestamp && delegate != user;

            for (uint256 j = 0; j < probes.length; j++) {
                uint256 required = probes[j];
                bool expected = live && ((perms & required) == required);
                bool actual = delegationHub.isAuthorized(user, delegate, required);
                if (actual != expected) return false;
            }
        }
        return true;
    }

    function _checkNonceDelta(address user, uint256 nonceBefore, bool shouldHaveIncremented) internal {
        uint256 nonceAfter = delegationHub.nonces(user);
        if (shouldHaveIncremented) {
            if (nonceAfter != nonceBefore + 1) sawUnexpectedNonceDelta = true;
        } else if (nonceAfter != nonceBefore) {
            sawUnexpectedNonceDelta = true;
        }
    }

    function _normalizeDelegate(uint256 seed, address user) internal pure returns (address delegate) {
        delegate = address(uint160(seed));
        if (delegate != address(0) && delegate != user) return delegate;

        delegate = address(uint160(uint256(keccak256(abi.encode(seed, user, uint256(0xD371E6A7))))));
        if (delegate == address(0) || delegate == user) {
            delegate = address(0xBEEF);
        }
    }

    function _trackHarnessDelegate(address delegate) internal {
        if (harnessDelegateSeen[delegate]) return;
        if (harnessDelegates.length >= MAX_TRACKED_DELEGATES) return;
        harnessDelegateSeen[delegate] = true;
        harnessDelegates.push(delegate);
    }

    function _trackSigUserDelegate(address delegate) internal {
        if (sigUserDelegateSeen[delegate]) return;
        if (sigUserDelegates.length >= MAX_TRACKED_DELEGATES) return;
        sigUserDelegateSeen[delegate] = true;
        sigUserDelegates.push(delegate);
    }

    function _boundTtl(uint64 ttlSeconds) internal pure returns (uint64) {
        uint64 ttl = ttlSeconds % uint64(30 days);
        if (ttl == 0) ttl = 1;
        return ttl;
    }

    function _futureExpiry(uint64 ttlSeconds) internal view returns (uint64) {
        uint64 ttl = _boundTtl(ttlSeconds);
        if (block.timestamp >= uint256(type(uint64).max) - uint256(ttl)) {
            return type(uint64).max;
        }
        return uint64(block.timestamp + uint256(ttl));
    }
}
