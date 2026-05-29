// SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

import {EIP712} from "@openzeppelin/contracts/utils/cryptography/EIP712.sol";
import {DelegationPermissions} from "./lib/DelegationPermissions.sol";
import {SignatureChecker} from "@openzeppelin/contracts/utils/cryptography/SignatureChecker.sol";

import {Errors} from "./lib/Errors.sol";
import {IDelegationHub} from "./interfaces/IDelegationHub.sol";

/// @notice Session-based delegation registry for bots.
/// @dev Users authorize delegates with a permission bitmask and an expiry timestamp.
///      Delegations are verified on-chain by protocol contracts via `isAuthorized(...)`.
contract DelegationHub is EIP712, IDelegationHub {
    // Types

    struct Session {
        uint256 perms;
        uint64 expiry;
    }

    // Storage

    mapping(address user => mapping(address delegate => Session)) internal sessions;
    mapping(address user => uint256) public nonces;

    // EIP-712

    bytes32 internal constant SET_SESSION_TYPEHASH = keccak256(
        "SetSession(address user,address delegate,uint256 perms,uint256 expiry,uint256 nonce,uint256 deadline)"
    );

    // Events

    event SessionSet(address indexed user, address indexed delegate, uint256 perms, uint256 expiry);
    event NonceIncremented(address indexed user, uint256 newNonce);

    constructor() EIP712("ClaimRush DelegationHub", "1") {}

    // Views

    function getSession(address user, address delegate) external view returns (uint256 perms, uint256 expiry) {
        Session storage s = sessions[user][delegate];
        perms = s.perms;
        expiry = s.expiry;
    }

    function isAuthorized(address user, address delegate, uint256 requiredPerms) external view returns (bool) {
        if (user == delegate) return false;
        if (requiredPerms == 0) return false;
        if ((requiredPerms & ~_VALID_PERMS_MASK) != 0) return false;
        Session storage s = sessions[user][delegate];
        if (s.expiry == 0 || uint256(s.expiry) <= block.timestamp) return false;
        // Runtime 7702 reject on the delegate seat. A delegate that was a bare
        // EOA at session-set time can install the `0xEF0100` designator
        // afterward; without this runtime check, every protocol surface that
        // gates on `isAuthorized` would honor the stored session against a
        // public-executor account until expiry.
        if (delegate.code.length == 23) {
            bytes3 prefix;
            assembly ("memory-safe") {
                extcodecopy(delegate, 0x00, 0x00, 0x03)
                prefix := mload(0x00)
            }
            if (prefix == 0xEF0100) return false;
        }
        return (s.perms & requiredPerms) == requiredPerms;
    }

    // User tx flows

    function setSession(address delegate, uint256 perms, uint64 expiry) external {
        _setSession(msg.sender, delegate, perms, expiry);

        // IMPORTANT: bump nonce on any direct (non-signature) update to invalidate
        // outstanding signed SetSession messages that may still be in circulation.
        // Without this, a stale signature can be replayed after a user revokes/updates
        // a session via a regular transaction.
        nonces[msg.sender] = nonces[msg.sender] + 1;
        emit NonceIncremented(msg.sender, nonces[msg.sender]);
    }

    function revokeSession(address delegate) external {
        _setSession(msg.sender, delegate, 0, 0);

        // Invalidate any outstanding signed SetSession messages.
        nonces[msg.sender] = nonces[msg.sender] + 1;
        emit NonceIncremented(msg.sender, nonces[msg.sender]);
    }

    // Gasless (set by signature)

    function setSessionBySig(
        address user,
        address delegate,
        uint256 perms,
        uint64 expiry,
        uint256 nonce,
        uint256 deadline,
        bytes calldata sig
    ) external {
        if (block.timestamp > deadline) revert Errors.DeadlineExpired();
        if (user == address(0) || delegate == address(0)) revert Errors.ZeroAddress();
        if (user == delegate) revert Errors.NotAuthorized();
        if ((perms & ~_VALID_PERMS_MASK) != 0) revert Errors.NotAuthorized();
        if (perms != 0 && (expiry == 0 || uint256(expiry) <= block.timestamp)) revert Errors.DeadlineExpired();
        // Canonical revocation: perms == 0 must pair with expiry == 0 so that
        // only one valid signature encoding exists for a given nonce.
        if (perms == 0 && expiry != 0) revert Errors.DeadlineExpired();

        uint256 expected = nonces[user];
        if (nonce != expected) revert Errors.NotAuthorized();

        bytes32 structHash =
            keccak256(abi.encode(SET_SESSION_TYPEHASH, user, delegate, perms, uint256(expiry), nonce, deadline));

        bytes32 digest = _hashTypedDataV4(structHash);
        if (!SignatureChecker.isValidSignatureNow(user, digest, sig)) revert Errors.NotAuthorized();

        // nonce consumed
        nonces[user] = expected + 1;
        emit NonceIncremented(user, nonces[user]);

        _setSession(user, delegate, perms, expiry);
    }

    // Internal

    /// @notice Bitmask of all defined permission bits (`DelegationPermissions.ALL`).
    /// @dev Rejects sessions that set bits outside `DelegationPermissions.ALL`.
    ///      Only bits defined in that mask are valid; unknown bits cannot be stored on a session.
    uint256 internal constant _VALID_PERMS_MASK = DelegationPermissions.ALL;

    /// @dev Reject EIP-7702 delegation designators on the `delegate` seat when the
    ///      session carries non-zero permissions. A delegated EOA exposes public
    ///      executor code; admitting one as a delegate would let arbitrary callers
    ///      route protocol calls through that address while every downstream
    ///      `isAuthorized` check sees `msg.sender` as the seated delegate.
    ///      Revocations (`perms == 0`) are still allowed against an existing
    ///      delegated address so a user can clear a session that was set before
    ///      the target became delegated.
    ///      The 7702 designator is exactly 23 bytes and starts with `0xEF0100`.
    ///      Bare EOAs (`code.length == 0`) are still permitted; this only catches
    ///      the delegation case.
    function _rejectDelegatedEOA(address account) internal view {
        if (account.code.length != 23) return;
        bytes3 prefix;
        assembly ("memory-safe") {
            extcodecopy(account, 0x00, 0x00, 0x03)
            prefix := mload(0x00)
        }
        if (prefix == 0xEF0100) revert Errors.DelegatedEOA();
    }

    function _setSession(address user, address delegate, uint256 perms, uint64 expiry) internal {
        if (user == address(0)) revert Errors.ZeroAddress();
        if (delegate == address(0)) revert Errors.ZeroAddress();
        // Direct-setter callers (setSession / revokeSession) cannot replay a signed artifact, so
        // the canonical revocation invariant (perms == 0 ⇒ expiry == 0) is enforced via silent
        // coercion here rather than a revert. The signed path (setSessionBySig) strict-rejects
        // the same edge case to guarantee a unique encoding per nonce.
        if (perms == 0) expiry = 0;
        // Self-delegation is useless (isAuthorized always false for user == delegate).
        if (user == delegate) revert Errors.NotAuthorized();

        // Reject perms with unknown/undefined bits set.
        if ((perms & ~_VALID_PERMS_MASK) != 0) revert Errors.NotAuthorized();

        // Reject non-zero perms with a zero or past expiry. expiry == 0 is only valid as an
        // explicit revocation (perms == 0). Non-zero perms with expiry == 0 would create an
        // unreachable session (isAuthorized returns false when expiry == 0), polluting storage
        // and confusing monitoring / UIs.
        if (perms != 0 && expiry == 0) revert Errors.DeadlineExpired();
        if (perms != 0 && uint256(expiry) <= block.timestamp) revert Errors.DeadlineExpired();

        // Reject delegated-EOA delegate seats when seating non-zero permissions.
        // Existing sessions can still be revoked (`perms == 0`) against a target
        // that became delegated after seating.
        if (perms != 0) _rejectDelegatedEOA(delegate);

        sessions[user][delegate] = Session({perms: perms, expiry: expiry});
        emit SessionSet(user, delegate, perms, uint256(expiry));
    }
}
