// SPDX-License-Identifier: MIT
pragma solidity ^0.8.34;

import {Test} from "forge-std/Test.sol";

import {ClaimToken} from "src/ClaimToken.sol";
import {Furnace} from "src/Furnace.sol";
import {FurnaceGuardHelper} from "src/FurnaceGuardHelper.sol";

import {Constants} from "src/lib/Constants.sol";
import {Errors} from "src/lib/Errors.sol";
import {Events} from "src/lib/Events.sol";

import {MockVe} from "./mocks/MockVe.sol";
import {MineCoreHarness} from "./mocks/MineCoreHarness.sol";

/// @notice Minimal ShareholderRoyalties mock that always reverts on addPendingShareholderETH.
/// @dev Used to verify MineCore restores shareholderEthPending on royalties-side failure.
contract RevertingRoyalties {
    address public mineCore;
    address public ve;
    address public claimAllHelper;

    function furnace() external pure returns (address) {
        return address(0);
    }

    function setWiring(address _mineCore, address, address) external {
        mineCore = _mineCore;
    }

    function setVe(address _ve) external {
        ve = _ve;
    }

    function setClaimAllHelper(address _helper) external {
        claimAllHelper = _helper;
    }

    function onTakeover(uint256) external payable {}

    function flushPendingShareholderETH() external {}

    function addPendingShareholderETH(uint256) external payable {
        revert();
    }

    function pendingShareholderETH() external pure returns (uint256) {
        return 0;
    }

    function ethPerVe() external pure returns (uint256) {
        return 0;
    }
}

/// @notice retryPushShareholderEth restores pending when royalties-side crediting reverts.
contract MineCore_RetryShareholderRestoreTest is Test {
    address internal owner = makeAddr("owner");

    function testRetryPushShareholderEth_restoresPending_whenRoyaltiesReverts() public {
        // Deploy fresh stack with a royalties mock that always reverts on addPendingShareholderETH.
        ClaimToken claim2 = new ClaimToken(owner);
        MockVe ve2 = new MockVe();
        RevertingRoyalties royalties2 = new RevertingRoyalties();
        royalties2.setVe(address(ve2));

        MineCoreHarness mine2 = new MineCoreHarness(address(claim2), address(ve2), address(royalties2), owner);

        // Wire up Furnace so _isReciprocallyWiredFurnace passes.
        Furnace furnace2 = new Furnace(
            address(claim2), address(ve2), address(new FurnaceGuardHelper(address(claim2), address(ve2))), owner
        );
        vm.startPrank(owner);
        claim2.setMineCore(address(mine2));
        furnace2.setMineCore(address(mine2));
        furnace2.setShareholderRoyalties(address(royalties2));
        mine2.setFurnace(address(furnace2));
        mine2.setGenesisKingClaimCollectedForTest(true);
        mine2.setTakeoversPaused(false);
        vm.stopPrank();

        ve2.setClaimToken(address(claim2));
        ve2.setFurnace(address(furnace2));

        royalties2.setWiring(address(mine2), address(0), address(furnace2));

        // Advance time past the 5-minute retry cooldown so ve checkpoint can be fresh.
        uint256 t1 = mine2.emissionStartTime() + 301;
        vm.warp(t1);
        ve2.setGlobalLastTs(t1);
        ve2.setCheckpointAdvances(true);

        // Seed pending ETH and deal balance to MineCore.
        mine2.setShareholderEthPendingHarness(1 ether);
        vm.deal(address(mine2), 1 ether);

        // Expect the failure event (reignId=0, amountEth=1 ether, empty reason).
        vm.expectEmit(true, false, false, true, address(mine2));
        emit Events.ShareholderRoyaltiesTakeoverFailed(0, 1 ether, bytes(""));

        // Act: retry should catch the royalties revert and restore pending.
        mine2.retryPushShareholderEth();

        // Assert: pending must be fully restored; MineCore still holds the ETH.
        assertEq(mine2.shareholderEthPending(), 1 ether, "pending must be restored on royalties revert");
        assertEq(address(mine2).balance, 1 ether, "ETH must remain in MineCore");
        assertEq(address(royalties2).balance, 0, "reverting royalties call must not retain ETH");
    }
}
