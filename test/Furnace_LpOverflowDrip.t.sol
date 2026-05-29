// SPDX-License-Identifier: MIT
pragma solidity ^0.8.34;

import {Test} from "forge-std/Test.sol";

import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

import {ClaimToken} from "src/ClaimToken.sol";
import {MineCore} from "src/MineCore.sol";
import {Constants} from "src/lib/Constants.sol";

import {FurnaceHarness} from "./mocks/FurnaceHarness.sol";
import {FurnaceQuoter} from "src/FurnaceQuoter.sol";
import {MockLpRewardsVault} from "./mocks/MockLpRewardsVault.sol";
import {MockShareholderRoyaltiesCheckpoint} from "./mocks/MockShareholderRoyaltiesCheckpoint.sol";
import {VeClaimNFTHarness} from "./mocks/VeClaimNFTHarness.sol";

contract FurnaceLpOverflowDripTest is Test {
    ClaimToken internal claim;
    VeClaimNFTHarness internal ve;
    MineCore internal mineCore;
    FurnaceHarness internal furnace;
    MockLpRewardsVault internal lpVault;

    address internal owner = address(0xA11CE);

    function setUp() public {
        claim = new ClaimToken(owner);
        ve = new VeClaimNFTHarness(address(claim), owner);
        address mockSR = address(new MockShareholderRoyaltiesCheckpoint());
        mineCore = new MineCore(address(claim), address(ve), mockSR, owner);
        furnace = new FurnaceHarness(address(claim), address(ve), owner);
        FurnaceQuoter quoter = new FurnaceQuoter(address(furnace));

        lpVault = new MockLpRewardsVault();
        lpVault.setFurnace(address(furnace));

        vm.startPrank(owner);
        claim.setMineCore(address(mineCore));
        furnace.setMineCore(address(mineCore));
        furnace.setFurnaceQuoter(address(quoter));
        furnace.setLpRewardsVault(address(lpVault));
        vm.stopPrank();
    }

    function _seedReserve(uint256 amount) internal {
        vm.prank(address(mineCore));
        claim.mint(address(furnace), amount);
        vm.prank(address(mineCore));
        furnace.creditReserve(amount);
    }

    function _expectedFurnaceRateAt(uint256 tSinceStartSeconds) internal pure returns (uint256) {
        uint256 decayPeriod = Constants.EMISSION_DECAY_PERIOD;
        uint256 launchRate = Constants.FURNACE_EMISSION_LAUNCH_RATE;
        uint256 floorRate = Constants.FURNACE_EMISSION_FLOOR;
        if (tSinceStartSeconds >= decayPeriod) return floorRate;

        uint256 diff = launchRate - floorRate;
        uint256 dec = Math.mulDiv(diff, tSinceStartSeconds, decayPeriod); // floor
        uint256 rate = launchRate - dec;
        if (rate < floorRate) rate = floorRate;
        return rate;
    }

    // ------------------------------------------------------------
    // Schedule: alpha
    // ------------------------------------------------------------

    function testDripAlphaSchedule() public {
        uint256 start = Constants.LP_OVERFLOW_DRIP_START;
        uint256 ramp = Constants.LP_OVERFLOW_DRIP_RAMP;

        assertEq(furnace.exposedDripAlphaBps(0), 0, "before start");
        assertEq(furnace.exposedDripAlphaBps(start - 1), 0, "just before start");
        assertEq(furnace.exposedDripAlphaBps(start), 0, "at start");

        // Mid ramp: 50%
        assertEq(furnace.exposedDripAlphaBps(start + ramp / 2), 5_000, "mid ramp");

        // After ramp: 100%
        assertEq(furnace.exposedDripAlphaBps(start + ramp), 10_000, "end ramp");
        assertEq(furnace.exposedDripAlphaBps(start + ramp + 1), 10_000, "after ramp");
    }

    function testDripPerDayIsZeroBeforeAndAtStartEvenWithExcessReserve() public {
        uint256 t0 = mineCore.emissionStartTime();
        uint256 start = Constants.LP_OVERFLOW_DRIP_START;

        // Seed reserve above target.
        uint256 reserve = Constants.RESERVE_TARGET_FINAL + 50_000_000e18;

        // Before start.
        vm.warp(t0 + start - 1);
        _seedReserve(reserve);
        assertEq(furnace.getLpOverflowDripPerDay(), 0, "before start drip=0");

        // At exactly start.
        vm.warp(t0 + start);
        assertEq(furnace.getLpOverflowDripPerDay(), 0, "at start drip=0");
    }

    // ------------------------------------------------------------
    // Emission schedule + inflow/day + capInflow/day
    // ------------------------------------------------------------

    function testInflowScheduleAndCapInflowPerDayAtKeyTimes() public {
        uint256 t0 = mineCore.emissionStartTime();

        // Times to check: 1y, 18m, 2y, 3y.
        uint256[] memory offsets = new uint256[](4);
        offsets[0] = 365 days;
        offsets[1] = Constants.LP_OVERFLOW_DRIP_START;
        offsets[2] = 2 * 365 days;
        offsets[3] = 3 * 365 days;

        for (uint256 i = 0; i < offsets.length; i++) {
            uint256 ts = t0 + offsets[i];

            uint256 expectedRate = _expectedFurnaceRateAt(offsets[i]);
            uint256 rate = mineCore.getFurnaceEmissionRateAt(ts);
            assertEq(rate, expectedRate, "rate mismatch");

            uint256 expectedInflowPerDay = expectedRate * 1 days;
            uint256 inflowPerDay = furnace.exposedFurnaceInflowPerDayAt(ts);
            assertEq(inflowPerDay, expectedInflowPerDay, "inflow/day mismatch");

            uint256 expectedCapInflow =
                Math.mulDiv(expectedInflowPerDay, Constants.LP_OVERFLOW_DRIP_INFLOW_SHARE_CAP_BPS, 10_000);
            uint256 capInflow = furnace.exposedCapInflowPerDayAt(ts);
            assertEq(capInflow, expectedCapInflow, "capInflow/day mismatch");
        }
    }

    // ------------------------------------------------------------
    // Gate g
    // ------------------------------------------------------------

    function testGateBpsBehaviorSmallVsHugeExcess() public {
        uint256 target = Constants.RESERVE_TARGET_FINAL;

        // Excess = K => g = 50%
        uint256 reserveHalfGate = target + Constants.LP_OVERFLOW_DRIP_GATE_K;
        uint256 gateHalf = furnace.exposedGateBpsFromReserve(reserveHalfGate);
        assertEq(gateHalf, 5_000, "gate at excess=K should be 50%");

        // Huge excess => g approaches 100%
        uint256 reserveHuge = target + 100_000_000e18;
        uint256 gateHuge = furnace.exposedGateBpsFromReserve(reserveHuge);
        assertGt(gateHuge, 9_500, "gate should be near 100% for huge excess");

        // At/below target => g = 0
        assertEq(furnace.exposedGateBpsFromReserve(target), 0);
        assertEq(furnace.exposedGateBpsFromReserve(target - 1), 0);
    }

    // ------------------------------------------------------------
    // Drip per-day formula + caps
    // ------------------------------------------------------------

    function testDripPerDayIsZeroUnlessReserveAboveTargetFinal() public {
        // Move time past ramp.
        uint256 t0 = mineCore.emissionStartTime();
        vm.warp(t0 + Constants.LP_OVERFLOW_DRIP_START + Constants.LP_OVERFLOW_DRIP_RAMP + 1);

        uint256 snap = vm.snapshot();

        // reserve == target => drip 0
        _seedReserve(Constants.RESERVE_TARGET_FINAL);
        assertEq(furnace.getLpOverflowDripPerDay(), 0);

        vm.revertTo(snap);

        // reserve < target => drip 0
        _seedReserve(Constants.RESERVE_TARGET_FINAL - 1e18);
        assertEq(furnace.getLpOverflowDripPerDay(), 0);
    }

    function testDripPerDayMatchesSpecFormulaWithGateAlphaAndCaps() public {
        // Set reserve comfortably above target so g is non-trivial.
        uint256 reserve = Constants.RESERVE_TARGET_FINAL + 50_000_000e18;
        _seedReserve(reserve);

        // Warp to mid ramp (alpha=50%)
        uint256 t0 = mineCore.emissionStartTime();
        uint256 ts = t0 + Constants.LP_OVERFLOW_DRIP_START + (Constants.LP_OVERFLOW_DRIP_RAMP / 2);
        vm.warp(ts);

        uint256 elapsed = ts - t0;
        uint256 alpha = furnace.exposedDripAlphaBps(elapsed);
        assertEq(alpha, 5_000);

        uint256 inflowPerDay = furnace.getFurnaceInflowPerDay();
        uint256 capInflow = furnace.getCapInflowPerDay();
        uint256 baseCap = capInflow;
        if (baseCap > Constants.LP_OVERFLOW_DRIP_FIXED_CAP_PER_DAY) {
            baseCap = Constants.LP_OVERFLOW_DRIP_FIXED_CAP_PER_DAY;
        }

        uint256 gateBps = furnace.exposedGateBpsFromReserve(reserve);
        assertGt(gateBps, 0);

        // expected = floor( floor(baseCap * gate / 10_000) * alpha / 10_000 )
        uint256 expected = Math.mulDiv(baseCap, gateBps, 10_000);
        expected = Math.mulDiv(expected, alpha, 10_000);

        uint256 perDay = furnace.getLpOverflowDripPerDay();
        assertEq(perDay, expected, "dripPerDay formula");

        // Hard bound: drip <= baseCap
        assertLe(perDay, baseCap, "drip must be <= baseCap");

        // capInflow correctness (inflow-share cap)
        uint256 expectedCapInflow = Math.mulDiv(inflowPerDay, Constants.LP_OVERFLOW_DRIP_INFLOW_SHARE_CAP_BPS, 10_000);
        assertEq(capInflow, expectedCapInflow, "capInflow formula");
    }

    // ------------------------------------------------------------
    // Execution: tick() safety + idempotence
    // ------------------------------------------------------------

    function testTickAccruesDripFundsStreamAndStreamsToVaultOverTime() public {
        uint256 t0 = mineCore.emissionStartTime();

        // Warp to after ramp.
        uint256 t1 = t0 + Constants.LP_OVERFLOW_DRIP_START + Constants.LP_OVERFLOW_DRIP_RAMP + 1;
        vm.warp(t1);

        // Seed reserve well above target.
        uint256 reserve = Constants.RESERVE_TARGET_FINAL + 50_000_000e18;
        _seedReserve(reserve);

        // Move time forward so dt>0 for tick.
        uint256 t2 = t1 + 1 days;
        vm.warp(t2);

        uint256 reserveBefore = furnace.furnaceReserve();
        uint256 vaultBalBefore = claim.balanceOf(address(lpVault));
        uint256 callsBefore = lpVault.notifyCalls();

        // First tick: accrues stream (none scheduled yet) and funds overflow drip into the stream.
        uint256 streamed0 = furnace.tick();
        assertEq(streamed0, 0, "no stream scheduled yet");

        uint256 dripped0 = reserveBefore - furnace.furnaceReserve();
        assertGt(dripped0, 0, "drip should fund stream");

        // Reserve decreases, but never below target.
        assertGe(furnace.furnaceReserve(), Constants.RESERVE_TARGET_FINAL, "reserve floor");

        // No immediate transfer to the vault when funding the stream.
        assertEq(claim.balanceOf(address(lpVault)), vaultBalBefore, "vault balance should not change on funding");
        assertEq(lpVault.notifyCalls(), callsBefore, "notify should not be called on funding");

        // Stream now tracks the full dripped amount: scheduled remainder plus unscheduled carry dust.
        uint256 remaining0 = furnace.getLpStreamRemaining();
        uint256 carry0 = furnace.exposedLpStreamCarry();
        assertEq(remaining0 + carry0, dripped0, "drip fully tracked");
        assertLt(carry0, Constants.LP_STREAM_WINDOW, "carry bound");

        // Advance time and tick again: stream transfers to vault.
        vm.warp(t2 + 1 days);
        uint256 vaultBalMid = claim.balanceOf(address(lpVault));
        uint256 callsMid = lpVault.notifyCalls();

        uint256 streamed1 = furnace.tick();
        assertGt(streamed1, 0, "streamed should be >0 after time passes");
        assertEq(claim.balanceOf(address(lpVault)), vaultBalMid + streamed1, "vault balance tracks streamed");
        assertEq(lpVault.notifyCalls(), callsMid + 1, "notify called for stream accrual");

        // Idempotence: calling again without time passing yields 0.
        uint256 streamed2 = furnace.tick();
        assertEq(streamed2, 0, "second tick must be 0");
        assertEq(lpVault.notifyCalls(), callsMid + 1, "no extra notify");
    }

    function testTickCannotDrainReserveBelowTargetFinal() public {
        uint256 t0 = mineCore.emissionStartTime();

        // Warp to after ramp.
        vm.warp(t0 + Constants.LP_OVERFLOW_DRIP_START + Constants.LP_OVERFLOW_DRIP_RAMP + 1);

        // Initialize drip cursor while reserve is at/below target (so no spend occurs).
        furnace.tick();

        // Only a small excess above target.
        uint256 reserve = Constants.RESERVE_TARGET_FINAL + 10_000e18;
        _seedReserve(reserve);

        // Advance a long time to try to over-drip.
        vm.warp(block.timestamp + 365 days);

        uint256 reserveBefore = furnace.furnaceReserve();
        uint256 perDay = furnace.getLpOverflowDripPerDay();

        // expectedSpend = min(excess, perDay * dt / 1 day)
        uint256 expectedSpend = Math.mulDiv(perDay, 365 days, 1 days);
        if (expectedSpend > 10_000e18) expectedSpend = 10_000e18;

        furnace.tick();

        uint256 reserveAfter = furnace.furnaceReserve();
        uint256 spent = reserveBefore - reserveAfter;
        assertEq(spent, expectedSpend, "must not drip below target");
        assertGe(reserveAfter, Constants.RESERVE_TARGET_FINAL, "reserve floor");

        // Dripped amount is fully tracked via the stream schedule plus carry dust.
        uint256 remaining = furnace.getLpStreamRemaining();
        uint256 carry = furnace.exposedLpStreamCarry();
        assertEq(remaining + carry, spent, "stream liability == funded");
    }

    function testSetMineCoreRewireResetsOverflowDripCursor() public {
        uint256 t0 = mineCore.emissionStartTime();

        // Create the replacement core early so its schedule is already mature when the rewire happens.
        // MineCore now validates canonical claim/ve/royalties roots at construction, so the
        // replacement core must use its own fresh bundle instead of reusing the active protocol roots.
        ClaimToken replacementClaim = new ClaimToken(owner);
        VeClaimNFTHarness replacementVe = new VeClaimNFTHarness(address(replacementClaim), owner);
        address replacementSr = address(new MockShareholderRoyaltiesCheckpoint());
        MineCore newCore = new MineCore(address(replacementClaim), address(replacementVe), replacementSr, owner);
        vm.startPrank(owner);
        furnace.setMineCore(address(newCore));
        newCore.setFurnace(address(furnace));
        furnace.setMineCore(address(mineCore));
        // Disable LP vault so the setMineCore LP-liability guard doesn't block the rewire.
        // This test verifies cursor reset, not LP stream handling.
        furnace.setLpRewardsVault(address(0));
        vm.stopPrank();

        vm.warp(t0 + Constants.LP_OVERFLOW_DRIP_START + Constants.LP_OVERFLOW_DRIP_RAMP + 30 days);
        _seedReserve(Constants.RESERVE_TARGET_FINAL + 50_000_000e18);

        // Leave the old cursor stale so an un-reset rewire would spend immediately.
        vm.warp(block.timestamp + 2 days);
        assertGt(furnace.getLpOverflowDripPerDay(), 0, "precondition: old core drip active");
        assertGt(newCore.getFurnaceEmissionRateAt(block.timestamp), 0, "precondition: replacement core live");

        vm.prank(owner);
        furnace.setMineCore(address(newCore));

        assertEq(furnace.lastLpOverflowDripUpdate(), block.timestamp, "cursor reset on MineCore rewire");
        assertGt(furnace.getLpOverflowDripPerDay(), 0, "replacement core drip should already be active");

        uint256 reserveBefore = furnace.furnaceReserve();
        furnace.tick();
        assertEq(furnace.furnaceReserve(), reserveBefore, "replacement core must not inherit an elapsed daily window");

        // Re-enable LP vault so drip can actually transfer CLAIM and reduce reserve.
        vm.prank(owner);
        furnace.setLpRewardsVault(address(lpVault));

        vm.warp(block.timestamp + 1 days);
        uint256 reserveBeforeLater = furnace.furnaceReserve();
        furnace.tick();
        assertLt(furnace.furnaceReserve(), reserveBeforeLater, "drip resumes after a fresh day on the new wiring");
    }
}
