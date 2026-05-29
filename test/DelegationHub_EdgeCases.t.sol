// SPDX-License-Identifier: MIT
pragma solidity ^0.8.34;

import {Test} from "forge-std/Test.sol";
import {DelegationHub} from "src/DelegationHub.sol";
import {DelegationPermissions} from "src/lib/DelegationPermissions.sol";
import {Errors} from "src/lib/Errors.sol";

/// @dev Minimal EIP-1271 smart wallet for testing SignatureChecker support.
contract MockEIP1271Wallet {
    address public owner;

    constructor(address _owner) {
        owner = _owner;
    }

    function isValidSignature(bytes32 hash, bytes calldata sig) external view returns (bytes4) {
        (uint8 v, bytes32 r, bytes32 s) = _splitSig(sig);
        address recovered = ecrecover(hash, v, r, s);
        return recovered == owner ? bytes4(0x1626ba7e) : bytes4(0xffffffff);
    }

    function _splitSig(bytes calldata sig) internal pure returns (uint8 v, bytes32 r, bytes32 s) {
        r = bytes32(sig[0:32]);
        s = bytes32(sig[32:64]);
        v = uint8(bytes1(sig[64:65]));
    }
}

contract RevertingEIP1271Wallet {
    function isValidSignature(bytes32, bytes calldata) external pure returns (bytes4) {
        revert("invalid signature");
    }
}

/// @title Edge-case, negative, and fuzz tests for DelegationHub.
/// @dev Covers gaps: invalid signatures, replay, max-expiry, zero-perms, fuzz bitmasks.
contract DelegationHubEdgeCasesTest is Test {
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

    // ── Invalid signature tests ─────────────────────────────────────

    function testSetSessionBySigRevertsWithWrongSigner() public {
        uint256 wrongPk = 0xBEEF;
        uint64 expiry = uint64(block.timestamp + 7 days);
        uint256 deadline = block.timestamp + 1 hours;

        bytes memory badSig = _signSetSession(wrongPk, user, delegate, perms, expiry, 0, deadline);

        vm.expectRevert();
        hub.setSessionBySig(user, delegate, perms, expiry, 0, deadline, badSig);
    }

    function testSetSessionBySigRevertsWithCorruptedSignature() public {
        uint64 expiry = uint64(block.timestamp + 7 days);
        uint256 deadline = block.timestamp + 1 hours;

        bytes memory sig = _signSetSession(userPk, user, delegate, perms, expiry, 0, deadline);
        // Corrupt the last byte
        sig[sig.length - 1] = bytes1(uint8(sig[sig.length - 1]) ^ 0xFF);

        vm.expectRevert();
        hub.setSessionBySig(user, delegate, perms, expiry, 0, deadline, sig);
    }

    function testSetSessionBySigRevertsWithExpiredDeadline() public {
        uint64 expiry = uint64(block.timestamp + 7 days);
        uint256 deadline = block.timestamp - 1; // expired

        bytes memory sig = _signSetSession(userPk, user, delegate, perms, expiry, 0, deadline);

        vm.expectRevert();
        hub.setSessionBySig(user, delegate, perms, expiry, 0, deadline, sig);
    }

    // ── Replay protection ───────────────────────────────────────────

    function testSetSessionBySigCannotReplayAfterUse() public {
        uint64 expiry = uint64(block.timestamp + 7 days);
        uint256 deadline = block.timestamp + 1 hours;
        bytes memory sig = _signSetSession(userPk, user, delegate, perms, expiry, 0, deadline);

        // First use succeeds
        hub.setSessionBySig(user, delegate, perms, expiry, 0, deadline, sig);
        assertEq(hub.nonces(user), 1);

        // Replay reverts (nonce consumed)
        vm.expectRevert();
        hub.setSessionBySig(user, delegate, perms, expiry, 0, deadline, sig);
    }

    // ── Zero-permission session ─────────────────────────────────────

    function testZeroPermsSessionIsNeverAuthorized() public {
        uint64 expiry = uint64(block.timestamp + 1 days);

        vm.prank(user);
        hub.setSession(delegate, 0, expiry);

        (uint256 storedPerms, uint256 storedExpiry) = hub.getSession(user, delegate);
        assertEq(storedPerms, 0);
        // Zero-perms updates normalize expiry to 0 (same storage shape as revoke).
        assertEq(storedExpiry, 0);

        // requiredPerms == 0 is never authorized; zero stored perms also fail any non-zero check.
        assertFalse(hub.isAuthorized(user, delegate, 0));
        assertFalse(hub.isAuthorized(user, delegate, DelegationPermissions.P_TAKEOVER_FOR));
        assertFalse(hub.isAuthorized(user, delegate, DelegationPermissions.P_FURNACE_ENTER_CLAIM_FOR));
        assertFalse(hub.isAuthorized(user, delegate, DelegationPermissions.P_CLAIM_ALL_FOR));
    }

    // ── Max-expiry boundary ─────────────────────────────────────────

    function testMaxExpirySessionIsLongLived() public {
        uint64 maxExpiry = type(uint64).max;

        vm.prank(user);
        hub.setSession(delegate, perms, maxExpiry);

        // At current time, should be authorized
        assertTrue(hub.isAuthorized(user, delegate, DelegationPermissions.P_TAKEOVER_FOR));

        // At far future (but before uint64 max), still authorized
        vm.warp(uint256(maxExpiry) - 1);
        assertTrue(hub.isAuthorized(user, delegate, DelegationPermissions.P_TAKEOVER_FOR));
    }

    // ── Self-delegation ─────────────────────────────────────────────

    function testSelfDelegationReverts() public {
        uint64 expiry = uint64(block.timestamp + 1 days);

        vm.prank(user);
        vm.expectRevert(Errors.NotAuthorized.selector);
        hub.setSession(user, perms, expiry);
    }

    // ── Multiple delegates per user ─────────────────────────────────

    function testMultipleDelegatesAreIndependent() public {
        address delegate2 = address(0xC0C0);
        uint64 expiry = uint64(block.timestamp + 1 days);

        vm.startPrank(user);
        hub.setSession(delegate, DelegationPermissions.P_TAKEOVER_FOR, expiry);
        hub.setSession(delegate2, DelegationPermissions.P_FURNACE_ENTER_CLAIM_FOR, expiry);
        vm.stopPrank();

        assertTrue(hub.isAuthorized(user, delegate, DelegationPermissions.P_TAKEOVER_FOR));
        assertFalse(hub.isAuthorized(user, delegate, DelegationPermissions.P_FURNACE_ENTER_CLAIM_FOR));

        assertTrue(hub.isAuthorized(user, delegate2, DelegationPermissions.P_FURNACE_ENTER_CLAIM_FOR));
        assertFalse(hub.isAuthorized(user, delegate2, DelegationPermissions.P_TAKEOVER_FOR));
    }

    // ── Fuzz tests ──────────────────────────────────────────────────

    function testFuzz_ExpiryBoundary(uint64 expiry) public {
        vm.assume(expiry > block.timestamp);

        vm.prank(user);
        hub.setSession(delegate, perms, expiry);

        assertTrue(hub.isAuthorized(user, delegate, DelegationPermissions.P_TAKEOVER_FOR));

        vm.warp(uint256(expiry) + 1);
        assertFalse(hub.isAuthorized(user, delegate, DelegationPermissions.P_TAKEOVER_FOR));
    }

    function testFuzz_PermsBitmaskChecksIndividualFlags(uint256 storedPerms_, uint256 queryFlag) public {
        uint256 validMask = DelegationPermissions.ALL;
        storedPerms_ = bound(storedPerms_, 1, validMask) & validMask;
        vm.assume(storedPerms_ != 0);
        queryFlag = bound(queryFlag, 1, validMask) & validMask;
        vm.assume(queryFlag != 0);

        uint64 expiry = uint64(block.timestamp + 1 days);

        vm.prank(user);
        hub.setSession(delegate, storedPerms_, expiry);

        bool authorized = hub.isAuthorized(user, delegate, queryFlag);
        assertEq(authorized, (storedPerms_ & queryFlag) == queryFlag);
    }

    function testFuzz_NonceBumpsSequentially(uint8 sessionCount) public {
        sessionCount = uint8(bound(sessionCount, 1, 20));
        uint64 expiry = uint64(block.timestamp + 1 days);

        for (uint256 i = 0; i < sessionCount; i++) {
            vm.prank(user);
            hub.setSession(delegate, perms, expiry);
        }

        assertEq(hub.nonces(user), uint256(sessionCount));
    }

    // ── Gasless revocation via signature ──────────────────────────

    function testSetSessionBySigRevokesWithZeroPermsZeroExpiry() public {
        uint64 expiry = uint64(block.timestamp + 7 days);
        uint256 deadline = block.timestamp + 1 hours;

        // First: grant a session via signature
        bytes memory grantSig = _signSetSession(userPk, user, delegate, perms, expiry, 0, deadline);
        hub.setSessionBySig(user, delegate, perms, expiry, 0, deadline, grantSig);
        assertTrue(hub.isAuthorized(user, delegate, DelegationPermissions.P_TAKEOVER_FOR));
        assertEq(hub.nonces(user), 1);

        // Now: revoke via signature (perms=0, expiry=0, nonce=1)
        bytes memory revokeSig = _signSetSession(userPk, user, delegate, 0, 0, 1, deadline);
        hub.setSessionBySig(user, delegate, 0, 0, 1, deadline, revokeSig);

        // Session cleared
        (uint256 storedPerms, uint256 storedExpiry) = hub.getSession(user, delegate);
        assertEq(storedPerms, 0);
        assertEq(storedExpiry, 0);
        assertFalse(hub.isAuthorized(user, delegate, DelegationPermissions.P_TAKEOVER_FOR));
        assertEq(hub.nonces(user), 2);
    }

    // ── EIP-1271 smart wallet signature ─────────────────────────

    function testSetSessionBySigAcceptsEIP1271SmartWalletSignature() public {
        // Deploy a smart wallet owned by userPk
        MockEIP1271Wallet wallet = new MockEIP1271Wallet(user);
        address walletAddr = address(wallet);

        uint64 expiry = uint64(block.timestamp + 7 days);
        uint256 deadline = block.timestamp + 1 hours;

        // Sign as the EOA owner, but the "user" is the smart wallet contract
        bytes memory sig = _signSetSession(userPk, walletAddr, delegate, perms, expiry, 0, deadline);

        // Submit: user = smart wallet address (SignatureChecker calls isValidSignature)
        hub.setSessionBySig(walletAddr, delegate, perms, expiry, 0, deadline, sig);

        // Session stored for the wallet address
        (uint256 storedPerms, uint256 storedExpiry) = hub.getSession(walletAddr, delegate);
        assertEq(storedPerms, perms);
        assertEq(storedExpiry, expiry);
        assertTrue(hub.isAuthorized(walletAddr, delegate, DelegationPermissions.P_TAKEOVER_FOR));
        assertEq(hub.nonces(walletAddr), 1);
    }

    function testSetSessionBySigRejectsEIP1271WithWrongOwner() public {
        // Deploy a smart wallet owned by a DIFFERENT key
        address wrongOwner = vm.addr(0xBEEF);
        MockEIP1271Wallet wallet = new MockEIP1271Wallet(wrongOwner);
        address walletAddr = address(wallet);

        uint64 expiry = uint64(block.timestamp + 7 days);
        uint256 deadline = block.timestamp + 1 hours;

        // Sign with userPk, but the wallet's owner is wrongOwner
        bytes memory sig = _signSetSession(userPk, walletAddr, delegate, perms, expiry, 0, deadline);

        vm.expectRevert(Errors.NotAuthorized.selector);
        hub.setSessionBySig(walletAddr, delegate, perms, expiry, 0, deadline, sig);
    }

    function testSetSessionBySigRejectsEIP1271WalletThatReverts() public {
        RevertingEIP1271Wallet wallet = new RevertingEIP1271Wallet();
        address walletAddr = address(wallet);

        uint64 expiry = uint64(block.timestamp + 7 days);
        uint256 deadline = block.timestamp + 1 hours;
        bytes memory sig = _signSetSession(userPk, walletAddr, delegate, perms, expiry, 0, deadline);

        vm.expectRevert(Errors.NotAuthorized.selector);
        hub.setSessionBySig(walletAddr, delegate, perms, expiry, 0, deadline, sig);
    }

    function testSetSessionBySigAcceptsDelegatedEoaWithEcdsaSignature() public {
        vm.etch(user, abi.encodePacked(hex"EF0100", address(this)));
        assertEq(user.code.length, 23, "delegation designator shape");

        uint64 expiry = uint64(block.timestamp + 7 days);
        uint256 deadline = block.timestamp + 1 hours;
        bytes memory sig = _signSetSession(userPk, user, delegate, perms, expiry, 0, deadline);

        hub.setSessionBySig(user, delegate, perms, expiry, 0, deadline, sig);

        assertTrue(hub.isAuthorized(user, delegate, DelegationPermissions.P_TAKEOVER_FOR));
        assertEq(hub.nonces(user), 1);
    }

    // ── Cross-chain replay protection ─────────────────────────────

    function testDomainSeparatorChangesWithChainId() public {
        // Capture domain separator on current chain (31337)
        bytes32 sep1 = _computeDomainSeparator(block.chainid);

        // Compute what it would be on a different chain
        bytes32 sep2 = _computeDomainSeparator(8453); // Base mainnet

        // Domain separators must differ across chains
        assertNotEq(sep1, sep2, "domain separator must change with chainId");
    }

    function testSetSessionBySigRevertsOnCrossChainReplay() public {
        uint64 expiry = uint64(block.timestamp + 7 days);
        uint256 deadline = block.timestamp + 1 hours;

        // Sign on current chain (31337)
        bytes memory sig = _signSetSession(userPk, user, delegate, perms, expiry, 0, deadline);

        // Succeeds on current chain
        hub.setSessionBySig(user, delegate, perms, expiry, 0, deadline, sig);
        assertEq(hub.nonces(user), 1);

        // Revoke and reset nonce state for clean replay attempt
        vm.prank(user);
        hub.revokeSession(delegate);
        // nonce is now 2

        // Sign a fresh message on the original chain with nonce=2
        bytes memory sigChain1 = _signSetSession(userPk, user, delegate, perms, expiry, 2, deadline);

        // Switch to a different chain
        vm.chainId(8453); // Base mainnet

        // Replay must fail: the digest changes because domain separator includes chainId
        vm.expectRevert();
        hub.setSessionBySig(user, delegate, perms, expiry, 2, deadline, sigChain1);
    }

    // ── Helper ──────────────────────────────────────────────────────

    function _computeDomainSeparator(uint256 chainId_) internal view returns (bytes32) {
        return keccak256(
            abi.encode(DOMAIN_TYPEHASH, keccak256("ClaimRush DelegationHub"), keccak256("1"), chainId_, address(hub))
        );
    }

    function _signSetSession(
        uint256 pk,
        address user_,
        address delegate_,
        uint256 perms_,
        uint256 expiry_,
        uint256 nonce_,
        uint256 deadline_
    ) internal view returns (bytes memory) {
        bytes32 domainSeparator = keccak256(
            abi.encode(
                DOMAIN_TYPEHASH, keccak256("ClaimRush DelegationHub"), keccak256("1"), block.chainid, address(hub)
            )
        );
        bytes32 structHash =
            keccak256(abi.encode(SET_SESSION_TYPEHASH, user_, delegate_, perms_, expiry_, nonce_, deadline_));
        bytes32 digest = keccak256(abi.encodePacked("\x19\x01", domainSeparator, structHash));
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(pk, digest);
        return abi.encodePacked(r, s, v);
    }
}
