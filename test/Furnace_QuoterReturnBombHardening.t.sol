// SPDX-License-Identifier: MIT
pragma solidity ^0.8.34;

import {Test} from "forge-std/Test.sol";

import {ClaimToken} from "src/ClaimToken.sol";
import {Furnace} from "src/Furnace.sol";
import {FurnaceGuardHelper} from "src/FurnaceGuardHelper.sol";

import {FurnaceQuoter} from "src/FurnaceQuoter.sol";
import {Errors} from "src/lib/Errors.sol";

import {MockVe} from "./mocks/MockVe.sol";
import {MockFurnaceQuoterReturnBomb} from "./mocks/RevertBombMocks.sol";

/// @notice FurnaceQuoter return-data-bomb protection.
///         Quote functions are called on FurnaceQuoter directly. The mock bomb
///         implements a fallback that returns/reverts with oversized data;
///         calling it through the IFurnaceQuoter interface exercises the same
///         surface that callers would use.
contract FurnaceQuoterReturnBombHardeningTest is Test {
    address internal owner = address(0xA11CE);

    ClaimToken internal claim;
    MockVe internal ve;
    Furnace internal furnace;

    function setUp() public {
        claim = new ClaimToken(owner);
        ve = new MockVe();
        furnace = new Furnace(
            address(claim), address(ve), address(new FurnaceGuardHelper(address(claim), address(ve))), owner
        );
    }

    function _setQuoterBomb(bool revertOnCall) internal returns (MockFurnaceQuoterReturnBomb bomb) {
        bomb = new MockFurnaceQuoterReturnBomb();
        bomb.setFurnace(address(furnace));
        bomb.setDataSize(5_000);
        bomb.setRevertOnCall(revertOnCall);

        vm.prank(owner);
        furnace.setFurnaceQuoter(address(bomb));
    }

    function testQuoteBombReturnsOversizedData_onReturnBomb() public {
        MockFurnaceQuoterReturnBomb bomb = _setQuoterBomb(false);

        (bool ok, bytes memory ret) = address(bomb)
            .staticcall(
                abi.encodeWithSignature(
                    "quoteEnterWithEth(address,uint256,uint256,uint256,bool)", address(this), 1 ether, 0, 1, false
                )
            );
        assertTrue(ok, "staticcall should succeed (return bomb, not revert bomb)");
        assertGt(ret.length, 4096, "return data should exceed 4KB cap");
    }

    function testQuoteBombRevertsWithOversizedData_onRevertBomb() public {
        MockFurnaceQuoterReturnBomb bomb = _setQuoterBomb(true);

        (bool ok, bytes memory ret) = address(bomb)
            .staticcall(
                abi.encodeWithSignature(
                    "quoteEnterWithEth(address,uint256,uint256,uint256,bool)", address(this), 1 ether, 0, 1, false
                )
            );
        assertFalse(ok, "staticcall should revert (revert bomb)");
        assertGt(ret.length, 4096, "revert data should exceed 4KB cap");
    }
}
