// SPDX-License-Identifier: MIT
pragma solidity ^0.8.34;

import {Test} from "forge-std/Test.sol";
import {Vm} from "forge-std/Vm.sol";

import {ClaimToken} from "src/ClaimToken.sol";
import {MineCore} from "src/MineCore.sol";
import {Constants} from "src/lib/Constants.sol";
import {FurnaceQuoter} from "src/FurnaceQuoter.sol";

import {FurnaceHarness} from "./mocks/FurnaceHarness.sol";
import {MockLpRewardsVault} from "./mocks/MockLpRewardsVault.sol";
import {MockShareholderRoyaltiesCheckpoint} from "./mocks/MockShareholderRoyaltiesCheckpoint.sol";
import {VeClaimNFTHarness} from "./mocks/VeClaimNFTHarness.sol";

/// @notice Regression test: ReserveClamped event emits the full lpStreamLiability
///         (matured + scheduled + carry), which is >= getLpStreamRemaining().
///         Verifies that furnaceReserve is clamped to (balance - lpStreamLiability) when
///         creditReserve over-credits, and the emitted event fields match.
contract Furnace_ReserveClamped_Liability_Test is Test {
    ClaimToken internal claim;
    VeClaimNFTHarness internal ve;
    MineCore internal mineCore;
    FurnaceHarness internal furnace;
    FurnaceQuoter internal quoter;
    MockLpRewardsVault internal lpVault;

    address internal owner = address(0xA11CE);

    function setUp() public {
        claim = new ClaimToken(owner);
        ve = new VeClaimNFTHarness(address(claim), owner);
        address mockSR = address(new MockShareholderRoyaltiesCheckpoint());
        mineCore = new MineCore(address(claim), address(ve), mockSR, owner);
        furnace = new FurnaceHarness(address(claim), address(ve), owner);
        quoter = new FurnaceQuoter(address(furnace));

        lpVault = new MockLpRewardsVault();
        lpVault.setFurnace(address(furnace));

        vm.startPrank(owner);
        claim.setMineCore(address(mineCore));
        furnace.setMineCore(address(mineCore));
        furnace.setFurnaceQuoter(address(quoter));
        furnace.setLpRewardsVault(address(lpVault));
        vm.stopPrank();
    }

    function _mintClaimToFurnace(uint256 amount) internal {
        vm.prank(address(mineCore));
        claim.mint(address(furnace), amount);
    }

    /// @dev Verifies that when an LP stream is active and creditReserve over-credits,
    ///      the reserve is clamped to (balance - lpStreamLiability) and the
    ///      ReserveClamped event emits liability (not just remaining).
    function test_reserveClampedEmitsLiabilityNotRemaining() public {
        uint256 streamAmount = 100_000e18;

        _mintClaimToFurnace(streamAmount);
        furnace.exposedFundLpStream(streamAmount);
        assertGt(furnace.exposedLpStreamLiability(), 0, "LP stream should create non-zero liability");

        vm.warp(block.timestamp + Constants.LP_STREAM_WINDOW / 2);

        uint256 remainingSnap = furnace.getLpStreamRemaining();
        assertGe(furnace.exposedLpStreamLiability(), remainingSnap, "liability >= remaining");

        {
            uint256 balance = claim.balanceOf(address(furnace));
            uint256 liability = furnace.exposedLpStreamLiability();
            uint256 cap = balance > liability ? balance - liability : 0;
            uint256 overCredit = cap + 50_000e18;

            vm.recordLogs();
            vm.prank(address(mineCore));
            furnace.creditReserve(overCredit);
        }

        {
            uint256 balAfter = claim.balanceOf(address(furnace));
            uint256 liabilityAfter = furnace.exposedLpStreamLiability();
            uint256 expectedCap = balAfter > liabilityAfter ? balAfter - liabilityAfter : 0;
            assertLe(furnace.furnaceReserve(), expectedCap, "reserve must be <= balance - liability");
        }

        _assertReserveClampedEmitted(remainingSnap);
    }

    function _assertReserveClampedEmitted(uint256 remainingSnap) internal {
        Vm.Log[] memory logs = vm.getRecordedLogs();
        bytes32 sig = keccak256("ReserveClamped(address,uint256,uint256,uint256,uint256)");
        bool found = false;
        for (uint256 i = 0; i < logs.length; i++) {
            if (logs[i].topics[0] == sig) {
                (uint256 oldReserve, uint256 newReserve,, uint256 emittedLiability) =
                    abi.decode(logs[i].data, (uint256, uint256, uint256, uint256));
                assertGt(oldReserve, newReserve, "old > new when clamped");
                assertGe(emittedLiability, remainingSnap, "event liability >= remaining");
                found = true;
                break;
            }
        }
        assertTrue(found, "ReserveClamped event must be emitted");
    }

    /// @dev With no LP stream (zero liability), over-credit clamps reserve to raw balance.
    function test_reserveClampedNoStream_clampsToBalance() public {
        uint256 minted = 1_000e18;
        _mintClaimToFurnace(minted);

        vm.recordLogs();
        vm.prank(address(mineCore));
        furnace.creditReserve(minted * 2);

        assertEq(furnace.furnaceReserve(), minted, "reserve should clamp to balance when no stream");

        Vm.Log[] memory logs = vm.getRecordedLogs();
        bytes32 sig = keccak256("ReserveClamped(address,uint256,uint256,uint256,uint256)");
        bool found = false;
        for (uint256 i = 0; i < logs.length; i++) {
            if (logs[i].topics[0] == sig) {
                (,, uint256 claimBalance, uint256 emittedLiability) =
                    abi.decode(logs[i].data, (uint256, uint256, uint256, uint256));
                assertEq(claimBalance, minted, "event balance");
                assertEq(emittedLiability, 0, "no stream means zero liability");
                found = true;
                break;
            }
        }
        assertTrue(found, "ReserveClamped event must be emitted");
    }
}
