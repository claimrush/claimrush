// SPDX-License-Identifier: MIT
pragma solidity ^0.8.34;

import {Test} from "forge-std/Test.sol";

import {ClaimToken} from "src/ClaimToken.sol";
import {MarketRouter} from "src/MarketRouter.sol";
import {Errors} from "src/lib/Errors.sol";

import {MockVe} from "./mocks/MockVe.sol";
import {MockRoyaltiesRevertBomb} from "./mocks/RevertBombMocks.sol";

/// @notice Regression tests: MarketRouter MUST refuse non-contract wiring for immutables.
///         MarketRouter calls royalties.checkpointTransfer(...) (no-return external call) before veNFT custody
///         transfers, so wiring an EOA can succeed silently and break ShareholderRoyalties accounting.
contract MarketRouterConstructorNotAContractTest is Test {
    address internal owner = address(0xA11CE);

    function testConstructorRevertsWhenClaimIsNotAContract() public {
        MockVe ve = new MockVe();
        MockRoyaltiesRevertBomb royalties = new MockRoyaltiesRevertBomb();
        address nonContract = address(0xBEEF);

        vm.expectRevert(Errors.NotAContract.selector);
        new MarketRouter(nonContract, address(ve), address(royalties), owner);
    }

    function testConstructorRevertsWhenVeIsNotAContract() public {
        ClaimToken claim = new ClaimToken(owner);
        MockRoyaltiesRevertBomb royalties = new MockRoyaltiesRevertBomb();
        address nonContract = address(0xBEEF);

        vm.expectRevert(Errors.NotAContract.selector);
        new MarketRouter(address(claim), nonContract, address(royalties), owner);
    }

    function testConstructorRevertsWhenRoyaltiesIsNotAContract() public {
        ClaimToken claim = new ClaimToken(owner);
        MockVe ve = new MockVe();
        address nonContract = address(0xBEEF);

        vm.expectRevert(Errors.NotAContract.selector);
        new MarketRouter(address(claim), address(ve), nonContract, owner);
    }
}
