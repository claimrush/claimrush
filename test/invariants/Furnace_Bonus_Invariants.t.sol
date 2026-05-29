// SPDX-License-Identifier: MIT
pragma solidity ^0.8.34;

import {Test} from "forge-std/Test.sol";

import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

import {ClaimToken} from "src/ClaimToken.sol";
import {MineCore} from "src/MineCore.sol";
import {Constants} from "src/lib/Constants.sol";

import {FurnaceHarness} from "../mocks/FurnaceHarness.sol";
import {FurnaceQuoter} from "src/FurnaceQuoter.sol";
import {MockLpRewardsVault} from "../mocks/MockLpRewardsVault.sol";
import {MockShareholderRoyaltiesCheckpoint} from "../mocks/MockShareholderRoyaltiesCheckpoint.sol";
import {VeClaimNFTHarness} from "../mocks/VeClaimNFTHarness.sol";

/// @dev Property-style tests for the Furnace bonus AMM math + drip.
contract FurnaceBonusInvariantsTest is Test {
    ClaimToken internal claim;
    VeClaimNFTHarness internal ve;
    MineCore internal mineCore;
    FurnaceHarness internal furnace;
    FurnaceQuoter internal furnaceQuoter;
    MockLpRewardsVault internal lpVault;

    address internal owner = address(0xA11CE);

    function setUp() public {
        claim = new ClaimToken(owner);
        ve = new VeClaimNFTHarness(address(claim), owner);
        address mockSR = address(new MockShareholderRoyaltiesCheckpoint());
        mineCore = new MineCore(address(claim), address(ve), mockSR, owner);
        furnace = new FurnaceHarness(address(claim), address(ve), owner);
        furnaceQuoter = new FurnaceQuoter(address(furnace));
        FurnaceQuoter quoter = furnaceQuoter;
        address mineMarket = address(0xB0B0);
        vm.etch(mineMarket, hex"00");

        lpVault = new MockLpRewardsVault();
        lpVault.setFurnace(address(furnace));

        vm.startPrank(owner);
        claim.setMineCore(address(mineCore));
        mineCore.setFurnace(address(furnace));
        vm.mockCall(mineMarket, abi.encodeWithSignature("ve()"), abi.encode(address(ve)));
        vm.mockCall(mineMarket, abi.encodeWithSignature("claim()"), abi.encode(address(claim)));
        vm.mockCall(mineMarket, abi.encodeWithSignature("royalties()"), abi.encode(mockSR));
        furnace.setMineCore(address(mineCore));
        furnace.setMineMarket(mineMarket);
        furnace.setFurnaceQuoter(address(quoter));
        furnace.setLpRewardsVault(address(lpVault));
        furnace.setShareholderRoyalties(mockSR);
        ve.setMineMarket(mineMarket);
        ve.setFurnace(address(furnace));
        vm.stopPrank();
    }

    function _ceilDiv(uint256 a, uint256 b) internal pure returns (uint256) {
        return a / b + (a % b == 0 ? 0 : 1);
    }

    function _assertLpRateHelperMatchesState(
        uint256 lpRateBps,
        uint256 userSpotBps,
        uint256 lockedSupply,
        uint256 totalSupply,
        uint256 reserve,
        uint256 elapsed
    ) internal view {
        uint256 baseLpRateBps = furnace.exposedLpTopupRateBps(userSpotBps);
        uint256 lpScaleBps = furnace.exposedLpScaleBps(lockedSupply, totalSupply, reserve, elapsed);
        uint256 expectedLpRateBps = Math.mulDiv(baseLpRateBps, lpScaleBps, 10_000);
        assertEq(lpRateBps, expectedLpRateBps, "lpRate helper mismatch");
    }

    // ------------------------------------------------------------
    // Helper-range invariants
    // ------------------------------------------------------------

    function testFuzz_helperRanges(uint128 reserveRaw, uint32 elapsedRaw) public {
        uint256 reserve = bound(uint256(reserveRaw), 0, 1e30);
        uint256 elapsed = bound(uint256(elapsedRaw), 0, 365 days);

        uint256 reserveFullnessBps = furnace.exposedReserveFullnessBps(reserve);
        assertLe(reserveFullnessBps, Constants.RESERVE_FACTOR_MAX_BPS, "reserveFullnessBps > max");

        uint256 alpha = furnace.exposedSwingAlphaBps(elapsed);
        assertLe(alpha, 10_000, "swingAlphaBps > 10000");

        uint256 factor = furnace.exposedReserveFactorBps(reserveFullnessBps, alpha);
        assertLe(factor, Constants.RESERVE_FACTOR_MAX_BPS, "reserveFactorBps > max");

        // alpha=0 must force factor=1.0x regardless of fullness
        assertEq(furnace.exposedReserveFactorBps(reserveFullnessBps, 0), 10_000, "reserveFactor != 1x when alpha=0");
    }

    function testLpTopupRateIsZeroWhenVaultUnset() public {
        vm.prank(owner);
        furnace.setLpRewardsVault(address(0));

        (,, uint256 userSpotBps, uint256 lpRateBps,,,,) = furnaceQuoter.getFurnaceState();
        assertLe(userSpotBps, 10_000);
        assertEq(lpRateBps, 0, "lpRateBps must be 0 when LP vault unset");
    }

    // ------------------------------------------------------------
    // Bonus invariants (drip is off in this range)
    // ------------------------------------------------------------

    function testFuzz_applyBonusAmm_NewModelInvariants(
        uint128 reserveRaw,
        uint128 principalRaw,
        uint128 lockedRaw,
        uint32 warpRaw
    ) public {
        // Seed the system in a tight scope so these locals do not stay live
        // across the state preview tuple destructure below.
        {
            // Keep fuzz values in a realistic range.
            uint256 reserveSeed = bound(uint256(reserveRaw), 0, 1e28);
            uint256 lockedSeed = bound(uint256(lockedRaw), 0, 5e28);

            // Warp forward, but keep within < drip-start so drip stays off.
            uint256 warpSeconds = bound(uint256(warpRaw), 0, 200 days);
            vm.warp(block.timestamp + warpSeconds);

            // Seed lockedSupply by creating a real ve lock (totalLockedClaim tracks lock principals).
            if (lockedSeed != 0) {
                // Protocol locks require a minimum principal; clamp fuzz seeds into a reachable state.
                if (lockedSeed < Constants.MIN_LOCK_AMOUNT) lockedSeed = Constants.MIN_LOCK_AMOUNT;

                address locker = address(0xA);
                vm.prank(address(mineCore));
                claim.mint(locker, lockedSeed);

                vm.startPrank(locker);
                claim.approve(address(ve), lockedSeed);
                ve.createLock(lockedSeed, Constants.MIN_LOCK_DURATION, false);
                vm.stopPrank();
            }

            // Seed reserve.
            if (reserveSeed != 0) {
                vm.prank(address(mineCore));
                claim.mint(address(furnace), reserveSeed);
                vm.prank(address(mineCore));
                furnace.creditReserve(reserveSeed);
            }
        }

        uint256 reserveBefore = furnace.furnaceReserve();

        // Keep only the few values that are needed across later assertions.
        uint256 reserve;
        uint256 lpRateBps;
        uint256 grossSpotBps;
        uint256 virtualDepth;
        uint256 lastUpdate;

        // Fetch state (preview) + helper invariants in a tight scope to avoid stack-too-deep.
        {
            uint256 lockedSupply;
            uint256 userSpotBps;

            // Keep returned values minimal to avoid stack-too-deep.
            (reserve, lockedSupply, userSpotBps, lpRateBps,,, virtualDepth, lastUpdate) =
                furnaceQuoter.getFurnaceState();

            // Locked supply anchor sanity.
            assertEq(lockedSupply, ve.totalLockedClaim(), "lockedSupply mismatch");

            uint256 elapsed = block.timestamp - mineCore.emissionStartTime();

            // Helper views match state.
            uint256 totalSupply = claim.totalSupply();

            uint256 helperUserSpotBps = furnace.exposedUserSpotBonusBps(lockedSupply, totalSupply, reserve, elapsed);
            assertEq(userSpotBps, helperUserSpotBps, "userSpot helper mismatch");
            _assertLpRateHelperMatchesState(lpRateBps, userSpotBps, lockedSupply, totalSupply, reserve, elapsed);

            // Keep reserve-factor helpers in a narrow scope (avoid stack-too-deep).
            {
                uint256 reserveFullness = furnace.exposedReserveFullnessBps(reserve);
                assertLe(reserveFullness, Constants.RESERVE_FACTOR_MAX_BPS, "reserveFullness out of range");
                uint256 alpha = furnace.exposedSwingAlphaBps(elapsed);
                assertLe(alpha, 10_000, "swingAlpha out of range");
                uint256 factor = furnace.exposedReserveFactorBps(reserveFullness, alpha);
                assertLe(factor, Constants.RESERVE_FACTOR_MAX_BPS, "reserveFactor out of range");
                if (elapsed == 0) {
                    assertEq(alpha, 0, "alpha must be 0 at t=0");
                    assertEq(factor, 10_000, "reserveFactor must be 1x at t=0");
                }
            }

            // Bounds.
            assertLe(userSpotBps, 10_000, "userSpotBonusBps > 10000");
            assertLe(lpRateBps, Constants.LP_TOPUP_RATE_MAX_BPS, "lpTopupRateBps > max");

            // Gross cap and formula.
            uint256 lpTopupSpotBps;
            {
                lpTopupSpotBps = Math.mulDiv(userSpotBps, lpRateBps, 10_000); // floor
            }
            grossSpotBps = userSpotBps + lpTopupSpotBps;
            if (grossSpotBps > 12_500) grossSpotBps = 12_500;

            {

                _assertGrossSpotHelper(grossSpotBps, userSpotBps, lpRateBps);
            }
            assertLe(grossSpotBps, 12_500, "grossSpotBonusBps > 12500");

            // Quote shown on website.
            {
                uint256 quoteUserBps;
                uint256 quoteLpTopupBps;
                (,,,, quoteUserBps, quoteLpTopupBps,,) = furnaceQuoter.getFurnaceState();
                uint256 quoteGrossBps = quoteUserBps + quoteLpTopupBps;
                assertLe(quoteUserBps, userSpotBps, "quoteUserBonusBps > userSpotBonusBps");
                _assertQuoteLpTopupBpsFromState();
                assertLe(quoteGrossBps, grossSpotBps, "quoteGrossBps > grossSpotBps");
            }
        }

        // Reserve / time sanity.
        assertEq(reserve, reserveBefore, "reserve state mismatch");
        assertLe(lastUpdate, block.timestamp, "lastUpdate in the future");

        // vTarget uses ceilDiv with grossSpotBonusBps when reserve>0 and grossSpot>0.
        if (reserve > 0 && grossSpotBps > 0) {
            uint256 vTarget = _ceilDiv(reserve * 10_000, grossSpotBps);
            assertGe(virtualDepth, vTarget, "virtualDepth < vTarget");
        } else {
            assertEq(virtualDepth, 0, "virtualDepth must be 0 when reserve==0 or grossSpot==0");
        }

        // Apply bonus and assert reserve safety + split consistency.
        uint256 principal = bound(uint256(principalRaw), 1, 1e28);
        (uint256 grossBonus, uint256 userBonus, uint256 lpBonus) = furnace.exposedApplyBonusAmm(principal);

        assertLe(grossBonus, reserveBefore, "grossBonus > reserveBefore");
        assertEq(furnace.furnaceReserve(), reserveBefore - grossBonus, "reserveAfter mismatch");

        assertEq(userBonus + lpBonus, grossBonus, "userBonus+lpBonus != grossBonus");
        assertLe(userBonus, grossBonus, "userBonus > grossBonus");
        assertLe(lpBonus, grossBonus, "lpBonus > grossBonus");

        // If LP vault is enabled, base lpRateBps is in [min..max], but the effective rate can be scaled down (and reach 0) when reserve is stressed.
        if (grossBonus == 0) {
            assertEq(userBonus, 0, "userBonus must be 0 when grossBonus==0");
            assertEq(lpBonus, 0, "lpBonus must be 0 when grossBonus==0");
        } else {
            uint256 expectedUser = Math.mulDiv(grossBonus, 10_000, 10_000 + lpRateBps);
            assertEq(userBonus, expectedUser, "split user mismatch");
            assertEq(lpBonus, grossBonus - expectedUser, "split lp mismatch");
        }
    }

    function testFuzz_previewVirtualDepth_EnforcesCeilVTarget_GrossCap(
        uint128 reserveRaw,
        uint128 lockedRaw,
        uint32 warpRaw
    ) public {
        uint256 reserveSeed = bound(uint256(reserveRaw), 1, 1e24);
        uint256 lockedSeed = bound(uint256(lockedRaw), 0, 5e24);
        // Protocol locks require a minimum principal; clamp fuzz seeds into a reachable state.
        if (lockedSeed != 0 && lockedSeed < Constants.MIN_LOCK_AMOUNT) lockedSeed = Constants.MIN_LOCK_AMOUNT;
        uint256 warpSeconds = bound(uint256(warpRaw), 0, 120 days);

        vm.warp(block.timestamp + warpSeconds);

        if (lockedSeed != 0) {
            address locker = address(0xA);
            vm.prank(address(mineCore));
            claim.mint(locker, lockedSeed);

            vm.startPrank(locker);
            claim.approve(address(ve), lockedSeed);
            ve.createLock(lockedSeed, Constants.MIN_LOCK_DURATION, false);
            vm.stopPrank();
        }

        vm.prank(address(mineCore));
        claim.mint(address(furnace), reserveSeed);
        vm.prank(address(mineCore));
        furnace.creditReserve(reserveSeed);

        uint256 elapsed = block.timestamp - mineCore.emissionStartTime();

        // Compute grossSpot cap using the same helper views.
        uint256 totalSupply = claim.totalSupply();
        uint256 userSpotBps = furnace.exposedUserSpotBonusBps(lockedSeed, totalSupply, reserveSeed, elapsed);
        uint256 lpRateBps = furnace.exposedLpTopupRateBps(userSpotBps);
        uint256 grossSpotBps = furnace.exposedGrossSpotBonusBps(userSpotBps, lpRateBps);

        if (grossSpotBps == 0) {
            assertEq(furnace.exposedPreviewVirtualDepth(grossSpotBps), 0, "grossSpot=0 must preview depth=0");
            return;
        }

        uint256 vCeil = _ceilDiv(reserveSeed * 10_000, grossSpotBps);

        // Fresh state has stored V=0, so preview must clamp exactly to vTarget (ceil).
        uint256 vPreview = furnace.exposedPreviewVirtualDepth(grossSpotBps);
        assertEq(vPreview, vCeil, "preview depth != ceil(vTarget)");
    }

    // ------------------------------------------------------------
    // Drip invariants
    // ------------------------------------------------------------

    function testDripIsZeroBeforeStartEvenWithExcessReserve() public {
        uint256 t0 = mineCore.emissionStartTime();

        // Warp to just before start.
        vm.warp(t0 + Constants.LP_OVERFLOW_DRIP_START - 1);

        uint256 reserve = Constants.RESERVE_TARGET_FINAL + 50_000_000e18;
        vm.prank(address(mineCore));
        claim.mint(address(furnace), reserve);
        vm.prank(address(mineCore));
        furnace.creditReserve(reserve);

        assertEq(furnace.getLpOverflowDripPerDay(), 0, "drip must be 0 before start");

        // At exactly start: alpha=0
        vm.warp(t0 + Constants.LP_OVERFLOW_DRIP_START);
        assertEq(furnace.getLpOverflowDripPerDay(), 0, "drip must be 0 at start");
    }

    function testDripIsZeroWhenReserveNotAboveTargetFinal() public {
        uint256 t0 = mineCore.emissionStartTime();
        vm.warp(t0 + Constants.LP_OVERFLOW_DRIP_START + Constants.LP_OVERFLOW_DRIP_RAMP + 1);

        // reserve < target
        uint256 snap = vm.snapshot();
        uint256 r1 = Constants.RESERVE_TARGET_FINAL - 1e18;
        vm.prank(address(mineCore));
        claim.mint(address(furnace), r1);
        vm.prank(address(mineCore));
        furnace.creditReserve(r1);
        assertEq(furnace.getLpOverflowDripPerDay(), 0, "drip must be 0 when reserve < target");
        vm.revertTo(snap);

        // reserve == target
        uint256 r2 = Constants.RESERVE_TARGET_FINAL;
        vm.prank(address(mineCore));
        claim.mint(address(furnace), r2);
        vm.prank(address(mineCore));
        furnace.creditReserve(r2);
        assertEq(furnace.getLpOverflowDripPerDay(), 0, "drip must be 0 when reserve == target");
    }

    function testTickWithDtZeroDoesNotChangeState() public {
        uint256 t0 = mineCore.emissionStartTime();
        vm.warp(t0 + Constants.LP_OVERFLOW_DRIP_START + Constants.LP_OVERFLOW_DRIP_RAMP + 1);

        // Seed reserve above target.
        uint256 reserve = Constants.RESERVE_TARGET_FINAL + 10_000e18;
        vm.prank(address(mineCore));
        claim.mint(address(furnace), reserve);
        vm.prank(address(mineCore));
        furnace.creditReserve(reserve);

        // First tick (dt>0 vs deployment) sets the cursor.
        vm.warp(block.timestamp + 1 days);
        furnace.tick();

        uint256 reserveBefore = furnace.furnaceReserve();
        uint256 callsBefore = lpVault.notifyCalls();

        // dt=0: calling again without time passing must do nothing.
        uint256 dripped2 = furnace.tick();
        assertEq(dripped2, 0, "drip must be 0 when dt=0");
        assertEq(furnace.furnaceReserve(), reserveBefore, "reserve must not change when dt=0");
        assertEq(lpVault.notifyCalls(), callsBefore, "notifyCalls must not change when dt=0");
    }

    function testReserveFactorIsOneAtT0() public {
        // At t=0, swingAlpha=0 => reserveFactor==10_000 regardless of reserveFullness.
        uint256 rfLow = 0;
        uint256 rfHigh = 20_000;
        assertEq(furnace.exposedReserveFactorBps(rfLow, 0), 10_000);
        assertEq(furnace.exposedReserveFactorBps(rfHigh, 0), 10_000);
    }

    function _assertGrossSpotHelper(uint256 grossSpotBps, uint256 userSpotBps, uint256 lpRateBps) internal {
        uint256 helperBps = furnace.exposedGrossSpotBonusBps(userSpotBps, lpRateBps);
        assertEq(grossSpotBps, helperBps, "grossSpot helper mismatch");
    }

    function _assertQuoteLpTopupBps(uint256 quoteLpTopupBps, uint256 quoteUserBps, uint256 lpRateBps) internal {
        uint256 expected = Math.mulDiv(quoteUserBps, lpRateBps, 10_000);
        assertEq(quoteLpTopupBps, expected, "quoteLpTopupBps != floor(quoteUser*lpRate/10_000)");
    }

    function _assertQuoteLpTopupBpsFromState() internal {
        (,,, uint256 lpRateBps, uint256 quoteUserBps, uint256 quoteLpTopupBps,,) = furnaceQuoter.getFurnaceState();
        uint256 expected = Math.mulDiv(quoteUserBps, lpRateBps, 10_000);
        assertEq(quoteLpTopupBps, expected, "quoteLpTopupBps != floor(quoteUser*lpRate/10_000)");
    }
}
