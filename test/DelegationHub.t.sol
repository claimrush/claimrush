// SPDX-License-Identifier: MIT
pragma solidity ^0.8.34;

import {Test} from "forge-std/Test.sol";

import {DelegationHub} from "src/DelegationHub.sol";
import {DelegationPermissions} from "src/lib/DelegationPermissions.sol";
import {Errors} from "src/lib/Errors.sol";

contract DelegationHubTest is Test {
    bytes32 internal constant DOMAIN_TYPEHASH =
        keccak256("EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)");
    bytes32 internal constant SET_SESSION_TYPEHASH = keccak256(
        "SetSession(address user,address delegate,uint256 perms,uint256 expiry,uint256 nonce,uint256 deadline)"
    );

    DelegationHub internal hub;

    uint256 internal userPk;
    address internal user;
    address internal delegate = address(0xB07);
    uint256 internal perms = DelegationPermissions.P_TAKEOVER_FOR | DelegationPermissions.P_FURNACE_ENTER_CLAIM_FOR;

    function setUp() public {
        hub = new DelegationHub();
        userPk = 0xA11CE;
        user = vm.addr(userPk);
    }

    function testSetSessionDirectBumpsNonceAndAuthorizationExpires() public {
        uint64 expiry = uint64(block.timestamp + 1 days);

        vm.prank(user);
        hub.setSession(delegate, perms, expiry);

        (uint256 storedPerms, uint256 storedExpiry) = hub.getSession(user, delegate);
        assertEq(storedPerms, perms);
        assertEq(storedExpiry, expiry);
        assertEq(hub.nonces(user), 1);
        assertTrue(hub.isAuthorized(user, delegate, DelegationPermissions.P_TAKEOVER_FOR));
        assertFalse(hub.isAuthorized(user, delegate, DelegationPermissions.P_CLAIM_ALL_FOR));

        vm.warp(uint256(expiry) + 1);
        assertFalse(hub.isAuthorized(user, delegate, DelegationPermissions.P_TAKEOVER_FOR));
    }

    function testRevokeSessionClearsAuthorizationAndBumpsNonce() public {
        uint64 expiry = uint64(block.timestamp + 1 days);

        vm.startPrank(user);
        hub.setSession(delegate, perms, expiry);
        hub.revokeSession(delegate);
        vm.stopPrank();

        (uint256 storedPerms, uint256 storedExpiry) = hub.getSession(user, delegate);
        assertEq(storedPerms, 0);
        assertEq(storedExpiry, 0);
        assertEq(hub.nonces(user), 2);
        assertFalse(hub.isAuthorized(user, delegate, DelegationPermissions.P_TAKEOVER_FOR));
    }

    function testSetSessionBySigConsumesNonceAndSetsSession() public {
        uint64 expiry = uint64(block.timestamp + 7 days);
        uint256 deadline = block.timestamp + 1 hours;
        bytes memory sig = _signSetSession(userPk, user, delegate, perms, expiry, 0, deadline);

        hub.setSessionBySig(user, delegate, perms, expiry, 0, deadline, sig);

        (uint256 storedPerms, uint256 storedExpiry) = hub.getSession(user, delegate);
        assertEq(storedPerms, perms);
        assertEq(storedExpiry, expiry);
        assertEq(hub.nonces(user), 1);
        assertTrue(hub.isAuthorized(user, delegate, DelegationPermissions.P_FURNACE_ENTER_CLAIM_FOR));
    }

    function testSetSessionBySigRevertsAfterDirectRevokeInvalidatesStaleNonce() public {
        uint64 expiry = uint64(block.timestamp + 7 days);
        uint256 deadline = block.timestamp + 1 hours;
        bytes memory staleSig = _signSetSession(userPk, user, delegate, perms, expiry, 0, deadline);

        vm.prank(user);
        hub.revokeSession(delegate);
        assertEq(hub.nonces(user), 1);

        vm.expectRevert(Errors.NotAuthorized.selector);
        hub.setSessionBySig(user, delegate, perms, expiry, 0, deadline, staleSig);
    }

    // ---- Past-expiry session is rejected ----

    function testSetSessionRevertsPastExpiry() public {
        vm.warp(1000);
        uint64 pastExpiry = uint64(block.timestamp - 1);
        vm.prank(user);
        vm.expectRevert(Errors.DeadlineExpired.selector);
        hub.setSession(delegate, perms, pastExpiry);
    }

    function testSetSessionAllowsZeroExpiryRevocation() public {
        // First set a valid session.
        vm.prank(user);
        hub.setSession(delegate, perms, uint64(block.timestamp + 1 days));
        assertTrue(hub.isAuthorized(user, delegate, DelegationPermissions.P_TAKEOVER_FOR));

        // Revoke via setSession with perms=0, expiry=0.
        vm.prank(user);
        hub.setSession(delegate, 0, 0);
        assertFalse(hub.isAuthorized(user, delegate, DelegationPermissions.P_TAKEOVER_FOR));
    }

    function testSetSessionBySigRevertsPastExpiry() public {
        vm.warp(1000);
        uint64 pastExpiry = uint64(block.timestamp - 1);
        uint256 deadline = block.timestamp + 1 hours;
        bytes memory sig = _signSetSession(userPk, user, delegate, perms, pastExpiry, 0, deadline);

        vm.expectRevert(Errors.DeadlineExpired.selector);
        hub.setSessionBySig(user, delegate, perms, pastExpiry, 0, deadline, sig);
    }

    function testSetSessionAllowsCurrentTimestampExpiry() public {
        uint64 futureExpiry = uint64(block.timestamp + 1);
        vm.prank(user);
        hub.setSession(delegate, perms, futureExpiry);
        assertTrue(hub.isAuthorized(user, delegate, DelegationPermissions.P_TAKEOVER_FOR));
    }

    // ---- Reject non-zero perms with zero expiry (dead session) ----

    function testSetSessionRevertsNonZeroPermsZeroExpiry() public {
        vm.prank(user);
        vm.expectRevert(Errors.DeadlineExpired.selector);
        hub.setSession(delegate, perms, 0);
    }

    function testSetSessionBySigRevertsNonZeroPermsZeroExpiry() public {
        uint256 deadline = block.timestamp + 1 hours;
        bytes memory sig = _signSetSession(userPk, user, delegate, perms, 0, 0, deadline);

        vm.expectRevert(Errors.DeadlineExpired.selector);
        hub.setSessionBySig(user, delegate, perms, 0, 0, deadline, sig);
    }

    // ---- Expired deadline on setSessionBySig ----

    function testSetSessionBySigRevertsExpiredDeadline() public {
        vm.warp(1000);
        uint64 expiry = uint64(block.timestamp + 7 days);
        uint256 deadline = block.timestamp - 1; // already expired
        bytes memory sig = _signSetSession(userPk, user, delegate, perms, expiry, 0, deadline);

        vm.expectRevert(Errors.DeadlineExpired.selector);
        hub.setSessionBySig(user, delegate, perms, expiry, 0, deadline, sig);
    }

    // ---- Zero-address validation on setSessionBySig ----

    function testSetSessionBySigRevertsZeroUser() public {
        uint64 expiry = uint64(block.timestamp + 7 days);
        uint256 deadline = block.timestamp + 1 hours;
        bytes memory sig = _signSetSession(userPk, address(0), delegate, perms, expiry, 0, deadline);

        vm.expectRevert(Errors.ZeroAddress.selector);
        hub.setSessionBySig(address(0), delegate, perms, expiry, 0, deadline, sig);
    }

    function testSetSessionBySigRevertsZeroDelegate() public {
        uint64 expiry = uint64(block.timestamp + 7 days);
        uint256 deadline = block.timestamp + 1 hours;
        bytes memory sig = _signSetSession(userPk, user, address(0), perms, expiry, 0, deadline);

        vm.expectRevert(Errors.ZeroAddress.selector);
        hub.setSessionBySig(user, address(0), perms, expiry, 0, deadline, sig);
    }

    // ---- isAuthorized with requiredPerms == 0 is always true for an active session ----

    function testIsAuthorizedZeroPermsReturnsFalseForActiveSession() public {
        uint64 expiry = uint64(block.timestamp + 1 days);
        vm.prank(user);
        hub.setSession(delegate, perms, expiry);

        assertFalse(hub.isAuthorized(user, delegate, 0));
    }

    // ---- Self-delegation is rejected ----

    function testSelfDelegationReverts() public {
        uint64 expiry = uint64(block.timestamp + 1 days);
        vm.prank(user);
        vm.expectRevert(Errors.NotAuthorized.selector);
        hub.setSession(user, perms, expiry);
    }

    function _domainSeparator() internal view returns (bytes32) {
        return keccak256(
            abi.encode(
                DOMAIN_TYPEHASH,
                keccak256(bytes("ClaimRush DelegationHub")),
                keccak256(bytes("1")),
                block.chainid,
                address(hub)
            )
        );
    }

    function _signSetSession(
        uint256 pk,
        address sessionUser,
        address sessionDelegate,
        uint256 sessionPerms,
        uint64 sessionExpiry,
        uint256 nonce,
        uint256 deadline
    ) internal view returns (bytes memory sig) {
        bytes32 structHash = keccak256(
            abi.encode(
                SET_SESSION_TYPEHASH,
                sessionUser,
                sessionDelegate,
                sessionPerms,
                uint256(sessionExpiry),
                nonce,
                deadline
            )
        );
        bytes32 digest = keccak256(abi.encodePacked("\x19\x01", _domainSeparator(), structHash));
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(pk, digest);
        sig = abi.encodePacked(r, s, v);
    }
}
