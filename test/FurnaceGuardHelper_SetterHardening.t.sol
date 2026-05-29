// SPDX-License-Identifier: MIT
pragma solidity ^0.8.34;

import {Test} from "forge-std/Test.sol";

import {ClaimToken} from "src/ClaimToken.sol";
import {FurnaceGuardHelper} from "src/FurnaceGuardHelper.sol";
import {Errors} from "src/lib/Errors.sol";

import {MockContract} from "./mocks/MockContract.sol";
import {VeClaimNFTHarness} from "./mocks/VeClaimNFTHarness.sol";

/// @title FurnaceGuardHelper Setter Hardening
/// @notice Pins the precise EIP-7702 delegated-EOA rejection on six helper-side
///         validation entrypoints used by Furnace's setter and emergency-rewire paths:
///
///         - validateShareholderRoyaltiesSetter
///         - validateDistinctEntryTokenRegistry
///         - requireFurnaceQuoterCompatible
///         - requireLpRewardsVaultCompatible (covers _requireLpRewardsVaultCompatibleInternal)
///         - validateMineCoreSetter
///         - validateMineMarketSetter
///
///         Each entrypoint enforces a two-step gate:
///           1. `code.length == 0`             → revert NotAContract  (bare EOA)
///           2. 23-byte runtime + `0xEF0100`   → revert DelegatedEOA  (EIP-7702 designator)
///
///         Tests below pin BOTH selectors so any future change that conflates
///         bare-EOA rejection with 7702 rejection (e.g. by reverting to the
///         coarser `<= 23 bytes` check) fails immediately at this boundary.
contract FurnaceGuardHelper_SetterHardeningTest is Test {
    address internal owner = address(0xA11CE);

    ClaimToken internal claim;
    VeClaimNFTHarness internal ve;
    FurnaceGuardHelper internal helper;

    function setUp() public {
        claim = new ClaimToken(owner);
        ve = new VeClaimNFTHarness(address(claim), owner);
        helper = new FurnaceGuardHelper(address(claim), address(ve));
    }

    // --- 7702-shaped fixture --------------------------------------------------

    /// @dev Install a 23-byte EIP-7702-shaped runtime at `who`. The first three
    ///      bytes are the 7702 delegation magic (`0xEF0100`) followed by 20
    ///      bytes of arbitrary "delegate" payload. Total length = 23.
    function _etchDelegatedEOA(address who, address delegate) internal {
        bytes memory rt = new bytes(23);
        rt[0] = 0xEF;
        rt[1] = 0x01;
        rt[2] = 0x00;
        for (uint256 i = 0; i < 20; i++) {
            rt[3 + i] = bytes1(uint8(uint160(delegate) >> (8 * (19 - i))));
        }
        vm.etch(who, rt);
        require(who.code.length == 23, "fixture must be 23 bytes");
    }

    /// @dev Install a 23-byte runtime that is NOT a 7702 designator (no `0xEF0100`
    ///      prefix). The new precise gate must let this through to the next
    ///      check (typically the staticcall wiring check).
    function _etchNon7702_23Bytes(address who) internal {
        bytes memory rt = new bytes(23);
        rt[0] = 0x60;
        rt[1] = 0x00;
        rt[2] = 0x60;
        for (uint256 i = 3; i < 23; i++) {
            rt[i] = bytes1(uint8(i));
        }
        vm.etch(who, rt);
        require(who.code.length == 23, "fixture must be 23 bytes");
    }

    function _etchEmpty(address who) internal {
        vm.etch(who, hex"");
        require(who.code.length == 0, "fixture must be empty");
    }

    // --- validateShareholderRoyaltiesSetter ----------------------------------

    function test_validateShareholderRoyalties_rejectsDelegatedEOA() public {
        address fakeSr = address(0xBEEF1);
        _etchDelegatedEOA(fakeSr, address(claim));
        vm.expectRevert(Errors.DelegatedEOA.selector);
        helper.validateShareholderRoyaltiesSetter(address(0xCAFE), fakeSr);
    }

    function test_validateShareholderRoyalties_rejectsBareEOA() public {
        address bare = address(0xBEEF2);
        _etchEmpty(bare);
        vm.expectRevert(Errors.NotAContract.selector);
        helper.validateShareholderRoyaltiesSetter(address(0xCAFE), bare);
    }

    function test_validateShareholderRoyalties_rejectsZero() public {
        vm.expectRevert(Errors.ZeroAddress.selector);
        helper.validateShareholderRoyaltiesSetter(address(0xCAFE), address(0));
    }

    /// @notice Precision pin: a 23-byte runtime that is NOT a 7702 designator must
    ///         pass the `_rejectDelegatedEOA` gate. (It will then fail later for
    ///         unrelated wiring reasons; we only assert the gate did not trigger.)
    function test_validateShareholderRoyalties_non7702_23Bytes_passesGate() public {
        address fake = address(0xBEEFA);
        _etchNon7702_23Bytes(fake);
        // The DelegatedEOA selector MUST NOT match because head != 0xEF0100.
        try helper.validateShareholderRoyaltiesSetter(address(0xCAFE), fake) {
        // If no revert, the gate passed and downstream succeeded (acceptable).
        }
        catch (bytes memory reason) {
            bytes4 sel;
            assembly {
                sel := mload(add(reason, 0x20))
            }
            assertTrue(sel != Errors.DelegatedEOA.selector, "non-7702 23-byte must NOT trigger DelegatedEOA");
        }
    }

    /// @notice Reciprocal `sr.ve()` mismatch edge. If `sr` exposes
    ///         a `ve()` getter that points away from the canonical ve, the helper
    ///         MUST revert WiringMismatch; otherwise streamed bonuses or royalty
    ///         splits could route against a sibling ve tree.
    function test_validateShareholderRoyalties_srVe_reciprocalMismatch() public {
        // A real, code-bearing `sr` candidate that returns a wrong `ve`.
        address fakeSr = address(0xBEEFB);
        vm.etch(fakeSr, type(MockContract).runtimeCode);
        vm.mockCall(fakeSr, abi.encodeWithSignature("furnace()"), abi.encode(address(0xCAFE)));
        vm.mockCall(fakeSr, abi.encodeWithSignature("ve()"), abi.encode(address(0xDEADBEEF)));

        vm.expectRevert(Errors.WiringMismatch.selector);
        helper.validateShareholderRoyaltiesSetter(address(0xCAFE), fakeSr);
    }

    function test_validateShareholderRoyalties_srVe_matchingPasses() public {
        address fakeSr = address(0xBEEFC);
        vm.etch(fakeSr, type(MockContract).runtimeCode);
        vm.mockCall(fakeSr, abi.encodeWithSignature("furnace()"), abi.encode(address(0xCAFE)));
        vm.mockCall(fakeSr, abi.encodeWithSignature("ve()"), abi.encode(address(ve)));

        helper.validateShareholderRoyaltiesSetter(address(0xCAFE), fakeSr);
    }

    // --- validateDistinctEntryTokenRegistry ----------------------------------

    function test_validateDistinctEntryTokenRegistry_rejectsDelegatedEOA() public {
        address fakeRegistry = address(0xBEEF3);
        _etchDelegatedEOA(fakeRegistry, address(claim));
        vm.expectRevert(Errors.DelegatedEOA.selector);
        helper.validateDistinctEntryTokenRegistry(address(0), fakeRegistry);
    }

    function test_validateDistinctEntryTokenRegistry_rejectsBareEOA() public {
        address bare = address(0xBEEF4);
        _etchEmpty(bare);
        vm.expectRevert(Errors.NotAContract.selector);
        helper.validateDistinctEntryTokenRegistry(address(0), bare);
    }

    // --- requireFurnaceQuoterCompatible --------------------------------------

    function test_requireFurnaceQuoterCompatible_rejectsDelegatedEOA() public {
        address fakeQuoter = address(0xBEEF5);
        _etchDelegatedEOA(fakeQuoter, address(claim));
        vm.expectRevert(Errors.DelegatedEOA.selector);
        helper.requireFurnaceQuoterCompatible(address(0xCAFE), fakeQuoter);
    }

    function test_requireFurnaceQuoterCompatible_rejectsBareEOA() public {
        address bare = address(0xBEEF6);
        _etchEmpty(bare);
        vm.expectRevert(Errors.NotAContract.selector);
        helper.requireFurnaceQuoterCompatible(address(0xCAFE), bare);
    }

    function test_requireFurnaceQuoterCompatible_rejectsZero() public {
        vm.expectRevert(Errors.ZeroAddress.selector);
        helper.requireFurnaceQuoterCompatible(address(0xCAFE), address(0));
    }

    // --- requireLpRewardsVaultCompatible -------------------------------------

    function test_requireLpRewardsVaultCompatible_rejectsDelegatedEOA() public {
        address fakeVault = address(0xBEEF7);
        _etchDelegatedEOA(fakeVault, address(claim));
        vm.expectRevert(Errors.DelegatedEOA.selector);
        helper.requireLpRewardsVaultCompatible(address(0xCAFE), address(claim), address(ve), fakeVault, false);
    }

    function test_requireLpRewardsVaultCompatible_rejectsBareEOA() public {
        address bare = address(0xBEEF8);
        _etchEmpty(bare);
        vm.expectRevert(Errors.NotAContract.selector);
        helper.requireLpRewardsVaultCompatible(address(0xCAFE), address(claim), address(ve), bare, false);
    }

    // --- validateMineCoreSetter ----------------------------------------------

    function test_validateMineCoreSetter_rejectsZero() public {
        vm.expectRevert(Errors.ZeroAddress.selector);
        helper.validateMineCoreSetter(address(0xCAFE), address(0));
    }

    function test_validateMineCoreSetter_rejectsBareEOA() public {
        address bare = address(0xBEEFD);
        _etchEmpty(bare);
        vm.expectRevert(Errors.NotAContract.selector);
        helper.validateMineCoreSetter(address(0xCAFE), bare);
    }

    function test_validateMineCoreSetter_rejectsDelegatedEOA() public {
        address fakeCore = address(0xBEEFE);
        _etchDelegatedEOA(fakeCore, address(claim));
        vm.expectRevert(Errors.DelegatedEOA.selector);
        helper.validateMineCoreSetter(address(0xCAFE), fakeCore);
    }

    /// @notice Reciprocal binding: if `core.furnace()` returns a non-zero address
    ///         that disagrees with the calling Furnace, that's a deploy-time
    ///         wiring error and must revert.
    function test_validateMineCoreSetter_furnaceMismatch() public {
        address fakeCore = address(0xBEEFF);
        vm.etch(fakeCore, type(MockContract).runtimeCode);
        vm.mockCall(fakeCore, abi.encodeWithSignature("furnace()"), abi.encode(address(0xDEADBEEF)));

        vm.expectRevert(Errors.WiringMismatch.selector);
        helper.validateMineCoreSetter(address(0xCAFE), fakeCore);
    }

    function test_validateMineCoreSetter_furnaceMatchPasses() public {
        address fakeCore = address(0xC0FFEE);
        vm.etch(fakeCore, type(MockContract).runtimeCode);
        vm.mockCall(fakeCore, abi.encodeWithSignature("furnace()"), abi.encode(address(0xCAFE)));

        helper.validateMineCoreSetter(address(0xCAFE), fakeCore);
    }

    function test_validateMineCoreSetter_noFurnaceGetterPasses() public {
        // A code-bearing core with no `furnace()` getter must pass — the staticcall
        // returns zero on revert and the helper treats zero as "not yet wired".
        address fakeCore = address(0xC0FFE1);
        vm.etch(fakeCore, type(MockContract).runtimeCode);
        helper.validateMineCoreSetter(address(0xCAFE), fakeCore);
    }

    // --- validateMineMarketSetter --------------------------------------------

    function test_validateMineMarketSetter_rejectsZero() public {
        vm.expectRevert(Errors.ZeroAddress.selector);
        helper.validateMineMarketSetter(address(0));
    }

    function test_validateMineMarketSetter_rejectsBareEOA() public {
        address bare = address(0xC0DEC);
        _etchEmpty(bare);
        vm.expectRevert(Errors.NotAContract.selector);
        helper.validateMineMarketSetter(bare);
    }

    function test_validateMineMarketSetter_rejectsDelegatedEOA() public {
        address fakeMarket = address(0xC0DED);
        _etchDelegatedEOA(fakeMarket, address(claim));
        vm.expectRevert(Errors.DelegatedEOA.selector);
        helper.validateMineMarketSetter(fakeMarket);
    }

    function test_validateMineMarketSetter_codeBearingPasses() public {
        address fakeMarket = address(0xC0DEE);
        vm.etch(fakeMarket, type(MockContract).runtimeCode);
        helper.validateMineMarketSetter(fakeMarket);
    }
}
