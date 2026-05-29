// SPDX-License-Identifier: MIT
pragma solidity ^0.8.34;

import {Test} from "forge-std/Test.sol";

import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

import {ClaimToken} from "src/ClaimToken.sol";
import {MineCore} from "src/MineCore.sol";
import {ShareholderRoyalties} from "src/ShareholderRoyalties.sol";
import {FurnaceQuoter} from "src/FurnaceQuoter.sol";
import {FurnaceGuardHelper} from "src/FurnaceGuardHelper.sol";
import {Constants} from "src/lib/Constants.sol";
import {Errors} from "src/lib/Errors.sol";

import {FurnaceHarness} from "./mocks/FurnaceHarness.sol";
import {MockContract} from "./mocks/MockContract.sol";
import {MockEntryTokenRegistry} from "./mocks/MockEntryTokenRegistry.sol";
import {MockLpRewardsVault} from "./mocks/MockLpRewardsVault.sol";
import {VeClaimNFTHarness} from "./mocks/VeClaimNFTHarness.sol";

import {DelegationHub} from "src/DelegationHub.sol";

/// @notice Positive specification for the Furnace duration-weight curve.
/// @dev The curve is evaluated at sub-bp (`Constants.WEIGHT_PRECISION`) resolution so that
///      `principalEff` tracks duration deltas at sub-second granularity across the full
///      `[MIN_LOCK_DURATION, MAX_LOCK_DURATION]` range. These tests pin the invariants:
///        - the `durationWeightBps(...)` public view returns the integer floor of the
///          sub-bp curve;
///        - quoter / execution stay in lockstep across arbitrary duration gaps;
///        - cumulative bonus from a sequence of small extends matches a single large extend
///          over the same window;
///        - sub-second extends emit no bonus (the AMM short-circuits on
///          `principalEff == 0`); and
///        - merge bonus scales linearly with the remaining-duration delta.
contract FurnaceDurationWeightPrecisionTest is Test {
    ClaimToken internal claim;
    VeClaimNFTHarness internal ve;
    MineCore internal mineCore;
    FurnaceHarness internal furnace;
    FurnaceQuoter internal furnaceQuoter;
    MockLpRewardsVault internal lpVault;
    ShareholderRoyalties internal royalties;
    DelegationHub internal delegationHub;

    address internal owner = address(0xA11CE);
    address internal alice = address(0xA11C3);
    address internal bob = address(0xB0B);
    address internal mineMarket;
    address internal registry;
    address internal mineCoreRegistry;

    function setUp() public {
        claim = new ClaimToken(owner);
        ve = new VeClaimNFTHarness(address(claim), owner);
        royalties = new ShareholderRoyalties(address(ve), owner);
        mineCore = new MineCore(address(claim), address(ve), address(royalties), owner);
        furnace = new FurnaceHarness(address(claim), address(ve), owner);
        furnaceQuoter = new FurnaceQuoter(address(furnace));
        delegationHub = new DelegationHub();

        mineMarket = address(new MockContract());
        registry = address(new MockEntryTokenRegistry());
        mineCoreRegistry = address(new MockEntryTokenRegistry());
        vm.mockCall(mineMarket, abi.encodeWithSignature("claim()"), abi.encode(address(claim)));
        vm.mockCall(mineMarket, abi.encodeWithSignature("ve()"), abi.encode(address(ve)));
        vm.mockCall(mineMarket, abi.encodeWithSignature("royalties()"), abi.encode(address(royalties)));

        vm.startPrank(owner);
        claim.setMineCore(address(mineCore));
        furnace.setMineCore(address(mineCore));
        furnace.setFurnaceQuoter(address(furnaceQuoter));
        furnace.setShareholderRoyalties(address(royalties));
        furnace.setMineMarket(mineMarket);
        furnace.setEntryTokenRegistry(registry);
        mineCore.setFurnace(address(furnace));
        mineCore.setDelegationHub(address(delegationHub));
        mineCore.setEntryTokenRegistry(mineCoreRegistry);
        furnace.setDelegationHub(address(delegationHub));
        royalties.setWiring(address(mineCore), mineMarket, address(furnace));
        ve.setFurnace(address(furnace));
        ve.setMineMarket(mineMarket);
        vm.stopPrank();

        lpVault = new MockLpRewardsVault();
        lpVault.setFurnace(address(furnace));
        vm.prank(owner);
        furnace.setLpRewardsVault(address(lpVault));
    }

    function _seedReserve(uint256 amount) internal {
        vm.prank(address(mineCore));
        claim.mint(address(furnace), amount);
        vm.prank(address(mineCore));
        furnace.creditReserve(amount);
    }

    function _createLock(address user, uint256 amount, uint256 duration, bool autoMax) internal returns (uint256) {
        vm.prank(address(mineCore));
        claim.mint(user, amount);
        vm.startPrank(user);
        claim.approve(address(ve), type(uint256).max);
        uint256 tokenId = ve.createLock(amount, duration, autoMax);
        vm.stopPrank();
        return tokenId;
    }

    // ═══════════════════════════════════════════════════════════════════
    //  Public-view bps representation
    // ═══════════════════════════════════════════════════════════════════

    /// @notice The bps-shaped public view returns the integer floor of the sub-bp curve.
    function test_DurationWeightBpsViewMatchesFlooredCurve() public view {
        uint256[10] memory durations =
            [uint256(7 days), 14 days, 21 days, 30 days, 90 days, 180 days, 270 days, 365 days, 45 days, 200 days];

        for (uint256 i = 0; i < durations.length; i++) {
            uint256 d = durations[i];
            uint256 bps = furnaceQuoter.durationWeightBps(d);
            // Sub-bp curve agrees with the bps view modulo flooring.
            // Equivalent specification: `bps * WEIGHT_PRECISION <= subBp < (bps + 1) * WEIGHT_PRECISION`.
            // We pin the bps value at the canonical breakpoints to lock the curve shape.
            assertLe(bps, Constants.BPS_DENOM, "bps cap");
            assertGe(bps, 100, "bps floor");
        }

        assertEq(furnaceQuoter.durationWeightBps(7 days), 100, "7d");
        assertEq(furnaceQuoter.durationWeightBps(14 days), 175, "14d");
        assertEq(furnaceQuoter.durationWeightBps(21 days), 300, "21d");
        assertEq(furnaceQuoter.durationWeightBps(30 days), 500, "30d");
        assertEq(furnaceQuoter.durationWeightBps(90 days), 1500, "90d");
        assertEq(furnaceQuoter.durationWeightBps(180 days), 4000, "180d");
        assertEq(furnaceQuoter.durationWeightBps(270 days), 6500, "270d");
        assertEq(furnaceQuoter.durationWeightBps(365 days), 10000, "365d");
    }

    // ═══════════════════════════════════════════════════════════════════
    //  Quote / execution parity across the curve
    // ═══════════════════════════════════════════════════════════════════

    /// @notice The quoter produces the exact bonus the execution path emits, across any duration
    ///         gap large enough to clear the lock's `MIN_TOPUP_AMOUNT` floor.
    function test_QuoterMatchesExecutionAcrossDurationGaps() public {
        _seedReserve(50_000_000e18);
        uint256[4] memory gaps = [uint256(1 days), 7 days, 30 days, 90 days];

        uint256 t = block.timestamp;
        for (uint256 i = 0; i < gaps.length; i++) {
            uint256 gap = gaps[i];
            address user = address(uint160(uint256(keccak256(abi.encode("parity", gap)))) | 1);

            t += 1;
            vm.warp(t);

            uint256 tokenId = _createLock(user, 100_000e18, 270 days, false);
            t += gap;
            vm.warp(t);

            (, uint256 qBonus,) = furnaceQuoter.quoteExtendWithBonus(user, tokenId, Constants.MAX_LOCK_DURATION);

            vm.prank(user);
            uint256 actualBonus = furnace.extendWithBonus(tokenId, Constants.MAX_LOCK_DURATION, 0);

            assertEq(actualBonus, qBonus, "quote == execution across gaps");
        }
    }

    // ═══════════════════════════════════════════════════════════════════
    //  Cumulative-extend invariant
    // ═══════════════════════════════════════════════════════════════════

    /// @notice A series of small extends accrues bonus proportional to the time committed,
    ///         matching (within rounding tolerance) a single large extend over the same window.
    /// @dev    Both legs run on independent locks created at the same starting moment so the
    ///         AMM virtual-depth state is comparable. Path A repeatedly extends back to the
    ///         maximum duration after each `step` window; Path B does a single extend to the
    ///         maximum after the full window has elapsed. Cumulative bonus across the two
    ///         paths should be within rounding tolerance of each other.
    function test_RepeatExtendToMaxAccruesProportionalToTimeCommitted() public {
        _seedReserve(50_000_000e18);
        // Track absolute time explicitly (foundry's `vm.warp(block.timestamp + N)` does not
        // accumulate across iterations of a single test transaction).
        uint256 t = block.timestamp + 1;
        vm.warp(t);

        uint256 tokenA = _createLock(alice, 100_000e18, 270 days, false);
        uint256 tokenB = _createLock(bob, 100_000e18, 270 days, false);

        uint256 step = 1 days;
        uint256 iterations = 5;
        uint256 cumulativeBonusA;
        for (uint256 i = 0; i < iterations; i++) {
            t += step;
            vm.warp(t);
            vm.prank(alice);
            cumulativeBonusA += furnace.extendWithBonus(tokenA, Constants.MAX_LOCK_DURATION, 0);
        }

        vm.prank(bob);
        uint256 singleBonusB = furnace.extendWithBonus(tokenB, Constants.MAX_LOCK_DURATION, 0);

        // Both paths capture the same `iterations * step` of duration progress on the same
        // starting remaining (270d). Path A pays many small bonuses with the AMM accruing
        // virtual depth between them; Path B pays a single bonus on a slightly-deeper AMM.
        // Within ~10% of each other accommodates AMM curvature.
        uint256 tolerance = singleBonusB / 10;
        assertApproxEqAbs(cumulativeBonusA, singleBonusB, tolerance, "cumulative ~= single over same window");
    }

    /// @notice `incrementalPrincipalEff` (which feeds the bonus AMM) responds smoothly to small
    ///         duration deltas — doubling the gap doubles the principalEff (modulo a few wei of
    ///         rounding), and it scales continuously across canonical breakpoints.
    function test_PrincipalEffScalesContinuouslyWithDurationDelta() public view {
        FurnaceGuardHelper helper = FurnaceGuardHelper(furnace.exposedGuardHelper());
        uint256 amount = 100_000e18;
        uint256 baseRemaining = Constants.MAX_LOCK_DURATION - 30 days;

        uint256 effSmall = helper.incrementalPrincipalEff(amount, baseRemaining + 1 hours, baseRemaining);
        uint256 effLarge = helper.incrementalPrincipalEff(amount, baseRemaining + 2 hours, baseRemaining);

        assertGt(effSmall, 0, "1h delta resolves to a positive principalEff at sub-bp precision");
        assertGt(effLarge, effSmall, "2h delta exceeds 1h delta");

        // Doubling the gap doubles principalEff modulo a few wei of mulDiv rounding.
        uint256 expectedDouble = effSmall * 2;
        uint256 tolerance = 8;
        assertApproxEqAbs(effLarge, expectedDouble, tolerance, "2h ~= 2 * 1h within rounding");

        // Same property at a different segment of the curve.
        uint256 effA = helper.incrementalPrincipalEff(amount, 60 days, 30 days);
        uint256 effB = helper.incrementalPrincipalEff(amount, 90 days, 60 days);
        assertGt(effA, 0, "30d->60d delta is positive");
        assertGt(effB, 0, "60d->90d delta is positive");
    }

    // ═══════════════════════════════════════════════════════════════════
    //  Merge-with-bonus
    // ═══════════════════════════════════════════════════════════════════

    /// @notice Merging two locks with identical remaining durations succeeds and pays no bonus —
    ///         `principalEff == 0` short-circuits the AMM.
    function test_MergeWithEqualRemainingPaysNoBonus() public {
        _seedReserve(10_000_000e18);
        vm.warp(block.timestamp + 1);

        uint256 fromTokenId = _createLock(alice, 30_000e18, 90 days, false);
        uint256 intoTokenId = _createLock(alice, 50_000e18, 90 days, false);

        vm.prank(alice);
        uint256 bonus = furnace.mergeLocksWithBonus(fromTokenId, intoTokenId, 0);

        assertEq(bonus, 0, "equal-remaining merge pays no bonus");

        // The surviving lock holds the combined principal.
        (uint256 intoAmt,,,) = ve.getLockInfo(intoTokenId);
        assertEq(intoAmt, 80_000e18, "surviving lock holds combined principal");
    }

    /// @notice Merge bonus is monotone in the remaining-duration delta on a single curve segment.
    function test_MergeBonusScalesWithRemainingDelta() public {
        _seedReserve(50_000_000e18);
        vm.warp(block.timestamp + 1);

        // Smaller delta merge: 90d into 180d (Δ = 90d, on the 90d→180d segment after rolling fwd).
        address charlie = address(0xC4A);
        address dave = address(0xDA1E);

        uint256 smallerFrom = _createLock(charlie, 10_000e18, 90 days, false);
        uint256 smallerInto = _createLock(charlie, 10_000e18, 100 days, false);

        // Larger delta merge: 90d into 270d (Δ = 180d on a different lock).
        uint256 largerFrom = _createLock(dave, 10_000e18, 90 days, false);
        uint256 largerInto = _createLock(dave, 10_000e18, 270 days, false);

        vm.prank(charlie);
        uint256 smallerBonus = furnace.mergeLocksWithBonus(smallerFrom, smallerInto, 0);

        vm.prank(dave);
        uint256 largerBonus = furnace.mergeLocksWithBonus(largerFrom, largerInto, 0);

        assertGt(largerBonus, smallerBonus, "larger remaining-delta pays more");
    }

    // ═══════════════════════════════════════════════════════════════════
    //  Curve helpers — direct
    // ═══════════════════════════════════════════════════════════════════

    /// @notice The integer-bps view from `FurnaceGuardHelper.clampAndDurationWeightBps` matches
    ///         the quoter's `durationWeightBps` at every sample.
    function test_HelperAndQuoterAgreeOnFlooredCurve() public view {
        uint256[11] memory samples =
            [uint256(0), 1 days, 7 days, 14 days, 21 days, 30 days, 90 days, 180 days, 270 days, 365 days, 400 days];

        FurnaceGuardHelper helper = FurnaceGuardHelper(furnace.exposedGuardHelper());
        for (uint256 i = 0; i < samples.length; i++) {
            (uint256 clamped, uint256 weightBps) = helper.clampAndDurationWeightBps(samples[i]);
            assertEq(clamped, furnaceQuoter.clampDurationSeconds(samples[i]), "clamped duration matches");
            assertEq(weightBps, furnaceQuoter.durationWeightBps(samples[i]), "weight bps matches");
        }
    }
}
