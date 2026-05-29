// SPDX-License-Identifier: MIT
pragma solidity ^0.8.34;

import {Test} from "forge-std/Test.sol";

import {ClaimToken} from "src/ClaimToken.sol";
import {Errors} from "src/lib/Errors.sol";

contract ClaimToken7702MockCore {
    address public immutable claim;

    constructor(address claim_) {
        claim = claim_;
    }

    function emissionStartTime() external pure returns (uint256) {
        return 1;
    }

    function GENESIS_ACCRUAL_DURATION() external pure returns (uint256) {
        return 1 days;
    }
}

contract ClaimToken_7702Rejection is Test {
    address internal owner = address(0xA11CE);
    address internal eoa = address(0xB0B);

    function _etch7702(address target, address delegate) internal {
        vm.etch(target, abi.encodePacked(hex"EF0100", delegate));
        assertEq(target.code.length, 23, "7702 designator must be exactly 23 bytes");
    }

    function _etchNon7702TwentyThreeByteCode(address target) internal {
        bytes memory code = new bytes(23);
        code[0] = 0x60;
        vm.etch(target, code);
        assertEq(target.code.length, 23, "test code must be exactly 23 bytes");
    }

    function test_setMineCore_rejectsDelegatedEOA() public {
        ClaimToken token = new ClaimToken(owner);
        _etch7702(eoa, address(this));

        vm.prank(owner);
        vm.expectRevert(Errors.DelegatedEOA.selector);
        token.setMineCore(eoa);
    }

    function test_freezeConfig_rejectsDelegatedEOA() public {
        ClaimToken token = new ClaimToken(owner);
        ClaimToken7702MockCore core = new ClaimToken7702MockCore(address(token));

        vm.prank(owner);
        token.setMineCore(address(core));

        _etch7702(address(core), address(this));

        vm.prank(owner);
        vm.expectRevert(Errors.DelegatedEOA.selector);
        token.freezeConfig();
    }

    function test_setMineCore_plainEOAStillRejectedByExistingGuard() public {
        ClaimToken token = new ClaimToken(owner);
        assertEq(eoa.code.length, 0);

        vm.prank(owner);
        vm.expectRevert(Errors.NotAContract.selector);
        token.setMineCore(eoa);
    }

    function test_setMineCore_non7702TwentyThreeByteCodePassesThroughToWiringCheck() public {
        ClaimToken token = new ClaimToken(owner);
        _etchNon7702TwentyThreeByteCode(eoa);

        vm.prank(owner);
        vm.expectRevert(Errors.WiringMismatch.selector);
        token.setMineCore(eoa);
    }

    function test_setMineCore_plainContractStillPasses() public {
        ClaimToken token = new ClaimToken(owner);
        ClaimToken7702MockCore core = new ClaimToken7702MockCore(address(token));

        vm.prank(owner);
        token.setMineCore(address(core));

        assertEq(token.mineCore(), address(core));
    }
}
