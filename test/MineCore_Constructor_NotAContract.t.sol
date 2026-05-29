// SPDX-License-Identifier: MIT
pragma solidity ^0.8.34;

import {Test} from "forge-std/Test.sol";

import {ClaimToken} from "src/ClaimToken.sol";
import {MineCore} from "src/MineCore.sol";
import {Errors} from "src/lib/Errors.sol";
import {ShareholderRoyalties} from "src/ShareholderRoyalties.sol";

import {MockVe} from "./mocks/MockVe.sol";
import {MockRoyaltiesRevertBomb} from "./mocks/RevertBombMocks.sol";

/// @notice Regression tests: MineCore MUST refuse non-contract wiring for immutables that are invoked via
///         no-return external calls (e.g. royalties.onTakeover{value: ...}).
contract MineCoreConstructorNotAContractTest is Test {
    address internal owner = address(0xA11CE);

    function testConstructorRevertsWhenClaimIsNotAContract() public {
        MockVe ve = new MockVe();
        MockRoyaltiesRevertBomb royalties = new MockRoyaltiesRevertBomb();
        address nonContract = address(0xBEEF);

        vm.expectRevert(Errors.NotAContract.selector);
        new MineCore(nonContract, address(ve), address(royalties), owner);
    }

    function testConstructorRevertsWhenVeIsNotAContract() public {
        ClaimToken claim = new ClaimToken(owner);
        MockRoyaltiesRevertBomb royalties = new MockRoyaltiesRevertBomb();
        address nonContract = address(0xBEEF);

        vm.expectRevert(Errors.NotAContract.selector);
        new MineCore(address(claim), nonContract, address(royalties), owner);
    }

    function testConstructorRevertsWhenRoyaltiesIsNotAContract() public {
        ClaimToken claim = new ClaimToken(owner);
        MockVe ve = new MockVe();
        address nonContract = address(0xBEEF);

        vm.expectRevert(Errors.NotAContract.selector);
        new MineCore(address(claim), address(ve), nonContract, owner);
    }

    function testConstructorRevertsWhenVeReportsForeignClaimRoot() public {
        ClaimToken claim = new ClaimToken(owner);
        ClaimToken foreignClaim = new ClaimToken(owner);
        MockVe ve = new MockVe();
        ve.setClaimToken(address(foreignClaim));
        ShareholderRoyalties royalties = new ShareholderRoyalties(address(ve), owner);

        vm.expectRevert(Errors.WiringMismatch.selector);
        new MineCore(address(claim), address(ve), address(royalties), owner);
    }

    function testConstructorRevertsWhenRoyaltiesReportsForeignVeRoot() public {
        ClaimToken claim = new ClaimToken(owner);
        MockVe ve = new MockVe();
        ve.setClaimToken(address(claim));

        MockVe foreignVe = new MockVe();
        foreignVe.setClaimToken(address(claim));
        ShareholderRoyalties foreignRoyalties = new ShareholderRoyalties(address(foreignVe), owner);

        vm.expectRevert(Errors.WiringMismatch.selector);
        new MineCore(address(claim), address(ve), address(foreignRoyalties), owner);
    }
}
