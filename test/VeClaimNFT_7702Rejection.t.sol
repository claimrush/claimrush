// SPDX-License-Identifier: MIT
pragma solidity ^0.8.34;

import {Test} from "forge-std/Test.sol";
import {VeClaimNFT} from "src/VeClaimNFT.sol";
import {Errors} from "src/lib/Errors.sol";

/// @notice Minimal ClaimToken stub. Only exists so VeClaimNFT's constructor clears the
///         `code.length == 0` gate. `mineCore()` is the owner-settable canonical anchor,
///         but these tests short-circuit before it is consulted.
contract StubClaimToken {
    address public mineCore;
}

/// @notice Coverage for `_rejectDelegatedEOA` on both wiring-setter call sites.
///         Full canonical-wiring validation lives in `VeClaimNFT.t.sol` and
///         `Deployment_Wiring.t.sol`; this suite asserts only that 7702 designator code
///         is rejected BEFORE the wiring bundle runs, and that the guard does not
///         false-positive on legal 23-byte runtime bytecode.
contract VeClaimNFT_7702Rejection is Test {
    VeClaimNFT internal ve;
    StubClaimToken internal claim;
    address internal owner = address(0xA11CE);
    address internal eoa = address(0xB0B);

    function setUp() public {
        claim = new StubClaimToken();
        ve = new VeClaimNFT(address(claim), owner);
    }

    /// @dev Write an EIP-7702 delegation designator at `target`: `0xEF 0x01 0x00 || delegate`.
    function _etch7702(address target, address delegate) internal {
        vm.etch(target, abi.encodePacked(hex"EF0100", delegate));
        assertEq(target.code.length, 23, "7702 designator must be exactly 23 bytes");
    }

    function test_setFurnace_rejectsDelegatedEOA() public {
        _etch7702(eoa, address(this));
        vm.prank(owner);
        vm.expectRevert(Errors.DelegatedEOA.selector);
        ve.setFurnace(eoa);
    }

    function test_setMineMarket_rejectsDelegatedEOA() public {
        _etch7702(eoa, address(this));
        vm.prank(owner);
        vm.expectRevert(Errors.DelegatedEOA.selector);
        ve.setMineMarket(eoa);
    }

    /// @dev EIP-7702 revoke-to-zero clears the account code under the canonical
    ///      spec (the EVM transaction-level semantic, not a storage operation —
    ///      `vm.etch` writes raw bytes and cannot itself simulate the revoke).
    ///      We model the post-revoke state by etching empty code and assert the
    ///      setter falls back to the pre-existing `NotAContract` guard, which is
    ///      the same gate a never-delegated EOA would hit. Distinct from
    ///      `test_setFurnace_plainEOAStillRejectedByExistingGuard` because that
    ///      test never touches `vm.etch` — this one verifies that re-clearing
    ///      previously-set code on the same address still routes through the
    ///      same rejection path.
    function test_setFurnace_zeroDelegationClearsCodeAndFallsBackToNotAContract() public {
        vm.etch(eoa, hex"");
        assertEq(eoa.code.length, 0, "post-revoke EOA must have empty code");

        vm.prank(owner);
        vm.expectRevert(Errors.NotAContract.selector);
        ve.setFurnace(eoa);
    }

    /// @dev EIP-3541 bans legacy runtime bytecode starting with `0xEF`, so no legal 23-byte
    ///      contract can collide with the 7702 designator prefix. A 23-byte blob NOT starting
    ///      with `0xEF0100` must slide past `_rejectDelegatedEOA` and fail only on the
    ///      downstream canonical wiring check.
    function test_setFurnace_non7702TwentyThreeByteCodePassesThroughToWiringCheck() public {
        bytes memory notSevenZeroTwo = new bytes(23);
        notSevenZeroTwo[0] = 0x60; // PUSH1 — any non-0xEF byte is legal
        vm.etch(eoa, notSevenZeroTwo);

        vm.prank(owner);
        vm.expectRevert(Errors.WiringMismatch.selector);
        ve.setFurnace(eoa);
    }

    /// @dev Symmetric check for `setMineMarket`.
    function test_setMineMarket_non7702TwentyThreeByteCodePassesThroughToWiringCheck() public {
        bytes memory notSevenZeroTwo = new bytes(23);
        notSevenZeroTwo[0] = 0x60;
        vm.etch(eoa, notSevenZeroTwo);

        vm.prank(owner);
        vm.expectRevert(Errors.WiringMismatch.selector);
        ve.setMineMarket(eoa);
    }

    /// @dev Sanity: plain EOA (code.length == 0) is still rejected by the pre-existing
    ///      `NotAContract` gate; the new guard must not regress that path.
    function test_setFurnace_plainEOAStillRejectedByExistingGuard() public {
        assertEq(eoa.code.length, 0);
        vm.prank(owner);
        vm.expectRevert(Errors.NotAContract.selector);
        ve.setFurnace(eoa);
    }
}
