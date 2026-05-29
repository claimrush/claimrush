// SPDX-License-Identifier: MIT
pragma solidity ^0.8.34;

import {Test} from "forge-std/Test.sol";

import {ClaimToken} from "src/ClaimToken.sol";
import {Errors} from "src/lib/Errors.sol";

/// @notice transferOwnership rejects self-nomination,
///         pending-owner re-nomination, and protocol-owned restricted recipients.
contract ClaimToken_TransferOwnership is Test {
    address internal constant OWNER = address(0xA11CE);
    address internal constant ALICE = address(0xA);

    function test_transferOwnership_claimTokenSelfNomination_reverts() public {
        ClaimToken token = new ClaimToken(OWNER);

        vm.prank(OWNER);
        vm.expectRevert(Errors.InvariantViolation.selector);
        token.transferOwnership(address(token));
    }

    function test_transferOwnership_wiringProbeNomination_reverts() public {
        ClaimToken token = new ClaimToken(OWNER);
        address wiringProbe = _computeCreateNonce1Address(address(token));
        assertGt(wiringProbe.code.length, 0, "computed probe address mismatch");

        vm.prank(OWNER);
        vm.expectRevert(Errors.InvariantViolation.selector);
        token.transferOwnership(wiringProbe);
    }

    function test_transferOwnership_sameOwner_reverts() public {
        ClaimToken token = new ClaimToken(OWNER);

        vm.prank(OWNER);
        vm.expectRevert(Errors.InvariantViolation.selector);
        token.transferOwnership(OWNER);
    }

    function test_transferOwnership_pendingOwner_reverts() public {
        ClaimToken token = new ClaimToken(OWNER);

        vm.prank(OWNER);
        token.transferOwnership(ALICE);
        assertEq(token.pendingOwner(), ALICE);

        vm.prank(OWNER);
        vm.expectRevert(Errors.InvariantViolation.selector);
        token.transferOwnership(ALICE);
    }

    function test_transferOwnership_validNewOwner_succeeds() public {
        ClaimToken token = new ClaimToken(OWNER);

        vm.prank(OWNER);
        token.transferOwnership(ALICE);
        assertEq(token.pendingOwner(), ALICE);
    }

    /// @dev transferOwnership to mineCore must revert InvariantViolation.
    ///      Prevents MineCore from gaining owner role, which pre-freeze could allow
    ///      it to call setMineCore and redirect the minter.
    function test_transferOwnership_mineCore_reverts() public {
        ClaimToken token = new ClaimToken(OWNER);
        _Pass02MockMineCore mockCore = new _Pass02MockMineCore(address(token));

        vm.prank(OWNER);
        token.setMineCore(address(mockCore));

        vm.prank(OWNER);
        vm.expectRevert(Errors.InvariantViolation.selector);
        token.transferOwnership(address(mockCore));
    }

    /// @dev renounceOwnership must revert NotAuthorized pre-freeze.
    ///      Abandoning ownership before freezeConfig() would leave setMineCore
    ///      and freezeConfig permanently unreachable (onlyOwner with no owner),
    ///      locking the protocol in a non-minting state with no recovery path.
    function test_renounceOwnership_preFreeze_reverts_NotAuthorized() public {
        ClaimToken token = new ClaimToken(OWNER);

        vm.prank(OWNER);
        vm.expectRevert(Errors.NotAuthorized.selector);
        token.renounceOwnership();
    }

    /// @dev renounceOwnership succeeds once freezeConfig has locked the
    ///      wiring. After renounce, owner() returns address(0) and ClaimToken
    ///      operates autonomously (only MineCore can mint; no further config
    ///      changes are possible).
    function test_renounceOwnership_postFreeze_succeeds() public {
        ClaimToken token = new ClaimToken(OWNER);
        _Pass02MockMineCore mockCore = new _Pass02MockMineCore(address(token));

        vm.prank(OWNER);
        token.setMineCore(address(mockCore));

        vm.prank(OWNER);
        token.freezeConfig();
        assertTrue(token.configFrozen(), "config not frozen");

        vm.prank(OWNER);
        token.renounceOwnership();

        assertEq(token.owner(), address(0), "owner not zeroed after renounce");
    }

    function _computeCreateNonce1Address(address deployer) internal pure returns (address) {
        return
            address(uint160(uint256(keccak256(abi.encodePacked(bytes1(0xd6), bytes1(0x94), deployer, bytes1(0x01))))));
    }
}

/// @dev Minimal mock that satisfies ClaimToken wiring checks.
contract _Pass02MockMineCore {
    address public immutable claim;

    constructor(address _claim) {
        claim = _claim;
    }

    function emissionStartTime() external pure returns (uint256) {
        return 1;
    }

    function GENESIS_ACCRUAL_DURATION() external pure returns (uint256) {
        return 1 days;
    }
}
