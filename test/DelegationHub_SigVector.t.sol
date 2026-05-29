// SPDX-License-Identifier: MIT
pragma solidity ^0.8.34;

import {Test} from "forge-std/Test.sol";

import {DelegationHub} from "src/DelegationHub.sol";
import {DelegationPermissions} from "src/lib/DelegationPermissions.sol";
import {Errors} from "src/lib/Errors.sol";

contract DelegationHubSigVectorTest is Test {
    bytes32 internal constant DOMAIN_TYPEHASH =
        keccak256("EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)");
    bytes32 internal constant SET_SESSION_TYPEHASH = keccak256(
        "SetSession(address user,address delegate,uint256 perms,uint256 expiry,uint256 nonce,uint256 deadline)"
    );
    bytes32 internal constant EXPECTED_SET_SESSION_TYPEHASH =
        0x50b6e4a9265d095be32b7ef5ddb40d67cabb32012b206bc379154841585221d4;

    uint256 internal constant USER_PK = 0xA11CE;
    address internal delegate = address(0xB07);

    function testCanonicalSetSessionSignatureVectorAccepted() public {
        vm.chainId(8453);
        vm.warp(1_750_000_000);
        DelegationHub hub = new DelegationHub();

        address user = vm.addr(USER_PK);
        uint256 perms = DelegationPermissions.P_TAKEOVER_FOR | DelegationPermissions.P_CLAIM_ALL_FOR;
        uint64 expiry = 1_893_456_000;
        uint256 nonce = 0;
        uint256 deadline = 1_780_000_000;

        assertEq(SET_SESSION_TYPEHASH, EXPECTED_SET_SESSION_TYPEHASH, "canonical typehash");

        bytes32 structHash = _structHash(user, delegate, perms, expiry, nonce, deadline);
        bytes32 digest = _digest(address(hub), block.chainid, structHash);
        bytes memory sig = _signDigest(USER_PK, digest);

        hub.setSessionBySig(user, delegate, perms, expiry, nonce, deadline, sig);

        (uint256 storedPerms, uint256 storedExpiry) = hub.getSession(user, delegate);
        assertEq(storedPerms, perms);
        assertEq(storedExpiry, expiry);
        assertEq(hub.nonces(user), 1);
        assertTrue(hub.isAuthorized(user, delegate, DelegationPermissions.P_TAKEOVER_FOR));
        assertTrue(hub.isAuthorized(user, delegate, DelegationPermissions.P_CLAIM_ALL_FOR));
    }

    function testSignatureUsingUint64ExpiryTypehashIsRejected() public {
        vm.chainId(8453);
        vm.warp(1_750_000_000);
        DelegationHub hub = new DelegationHub();

        address user = vm.addr(USER_PK);
        uint256 perms = DelegationPermissions.P_TAKEOVER_FOR;
        uint64 expiry = 1_893_456_000;
        uint256 nonce = 0;
        uint256 deadline = 1_780_000_000;
        bytes32 wrongTypehash = keccak256(
            "SetSession(address user,address delegate,uint256 perms,uint64 expiry,uint256 nonce,uint256 deadline)"
        );
        bytes32 structHash = keccak256(abi.encode(wrongTypehash, user, delegate, perms, expiry, nonce, deadline));
        bytes memory sig = _signDigest(USER_PK, _digest(address(hub), block.chainid, structHash));

        vm.expectRevert(Errors.NotAuthorized.selector);
        hub.setSessionBySig(user, delegate, perms, expiry, nonce, deadline, sig);
    }

    function testBaseMainnetSignatureCannotReplayOnBaseSepolia() public {
        vm.chainId(8453);
        vm.warp(1_750_000_000);
        DelegationHub hub = new DelegationHub();

        address user = vm.addr(USER_PK);
        uint256 perms = DelegationPermissions.P_TAKEOVER_FOR;
        uint64 expiry = 1_893_456_000;
        uint256 nonce = 0;
        uint256 deadline = 1_780_000_000;
        bytes32 structHash = _structHash(user, delegate, perms, expiry, nonce, deadline);
        bytes memory sig = _signDigest(USER_PK, _digest(address(hub), 8453, structHash));

        vm.chainId(84532);
        vm.expectRevert(Errors.NotAuthorized.selector);
        hub.setSessionBySig(user, delegate, perms, expiry, nonce, deadline, sig);
    }

    function testSignatureIsBoundToVerifyingContract() public {
        vm.chainId(8453);
        vm.warp(1_750_000_000);
        DelegationHub signedHub = new DelegationHub();
        DelegationHub otherHub = new DelegationHub();

        address user = vm.addr(USER_PK);
        uint256 perms = DelegationPermissions.P_TAKEOVER_FOR;
        uint64 expiry = 1_893_456_000;
        uint256 nonce = 0;
        uint256 deadline = 1_780_000_000;
        bytes32 structHash = _structHash(user, delegate, perms, expiry, nonce, deadline);
        bytes memory sig = _signDigest(USER_PK, _digest(address(signedHub), block.chainid, structHash));

        vm.expectRevert(Errors.NotAuthorized.selector);
        otherHub.setSessionBySig(user, delegate, perms, expiry, nonce, deadline, sig);
    }

    function _structHash(address user, address delegate_, uint256 perms, uint64 expiry, uint256 nonce, uint256 deadline)
        internal
        pure
        returns (bytes32)
    {
        return keccak256(abi.encode(SET_SESSION_TYPEHASH, user, delegate_, perms, uint256(expiry), nonce, deadline));
    }

    function _digest(address hub, uint256 chainId, bytes32 structHash) internal pure returns (bytes32) {
        bytes32 domainSeparator =
            keccak256(abi.encode(DOMAIN_TYPEHASH, keccak256("ClaimRush DelegationHub"), keccak256("1"), chainId, hub));
        return keccak256(abi.encodePacked("\x19\x01", domainSeparator, structHash));
    }

    function _signDigest(uint256 pk, bytes32 digest) internal view returns (bytes memory) {
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(pk, digest);
        return abi.encodePacked(r, s, v);
    }
}
