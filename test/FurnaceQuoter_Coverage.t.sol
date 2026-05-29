// SPDX-License-Identifier: MIT
pragma solidity ^0.8.34;

import {Test} from "forge-std/Test.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

import {ClaimToken} from "src/ClaimToken.sol";
import {EntryTokenRegistry} from "src/EntryTokenRegistry.sol";
import {Furnace} from "src/Furnace.sol";
import {FurnaceGuardHelper} from "src/FurnaceGuardHelper.sol";

import {FurnaceQuoter} from "src/FurnaceQuoter.sol";
import {IFurnaceQuoter} from "src/interfaces/IFurnaceQuoter.sol";
import {Constants} from "src/lib/Constants.sol";
import {Errors} from "src/lib/Errors.sol";

import {MockAerodromeRouterMineCore} from "./mocks/MockAerodromeRouterMineCore.sol";
import {MockShareholderRoyaltiesCheckpoint} from "./mocks/MockShareholderRoyaltiesCheckpoint.sol";
import {MockWETH} from "./mocks/MockWETH.sol";
import {VeClaimNFTHarness} from "./mocks/VeClaimNFTHarness.sol";

/// @notice Coverage tests for FurnaceQuoter.sol.
///         Covers: piecewise curve boundaries, fuzz continuity, zero-input edges,
///         sell quote/execute differential, same-block multi-entry, sell impact accumulation.
contract FurnaceQuoter_Coverage_Test is Test {
    address internal owner;
    address internal alice;
    address internal bob;
    address internal mineMarket;

    ClaimToken public claim;
    VeClaimNFTHarness internal ve;
    Furnace internal furnace;
    FurnaceQuoter internal quoter;

    MockWETH internal weth;
    MockAerodromeRouterMineCore internal router;
    EntryTokenRegistry internal reg;
    MockShareholderRoyaltiesCheckpoint internal mockSR;

    function setUp() public {
        vm.txGasPrice(0);

        owner = makeAddr("owner");
        alice = makeAddr("alice");
        bob = makeAddr("bob");

        claim = new ClaimToken(owner);
        ve = new VeClaimNFTHarness(address(claim), owner);
        furnace = new Furnace(
            address(claim), address(ve), address(new FurnaceGuardHelper(address(claim), address(ve))), owner
        );

        weth = new MockWETH();

        vm.etch(address(0xFACADE), hex"01");
        vm.etch(address(0xBEEF), hex"01");

        mockSR = new MockShareholderRoyaltiesCheckpoint();

        router = new MockAerodromeRouterMineCore(
            address(0xFACADE), address(weth), address(claim), address(ve), address(furnace), address(mockSR)
        );
        reg = new EntryTokenRegistry(owner);

        mineMarket = address(0xBABA);
        vm.etch(mineMarket, hex"01");
        vm.mockCall(mineMarket, abi.encodeWithSignature("ve()"), abi.encode(address(ve)));
        vm.mockCall(mineMarket, abi.encodeWithSignature("claim()"), abi.encode(address(claim)));
        vm.mockCall(mineMarket, abi.encodeWithSignature("royalties()"), abi.encode(address(mockSR)));

        vm.startPrank(owner);
        claim.setMineCore(address(router));
        furnace.setMineCore(address(router));
        furnace.setMineMarket(mineMarket);
        furnace.setShareholderRoyalties(address(mockSR));
        mockSR.setWiring(address(router), mineMarket, address(furnace), address(ve));
        ve.setFurnace(address(furnace));
        ve.setMineMarket(mineMarket);

        reg.setRouterConfig(address(router), router.defaultFactory(), address(weth), address(claim));
        router.setPoolFor(address(weth), address(claim), false, router.defaultFactory(), address(0xBEEF));
        reg.setWethClaimHop(false, address(0xBEEF));
        furnace.setEntryTokenRegistry(address(reg));
        quoter = new FurnaceQuoter(address(furnace));
        furnace.setFurnaceQuoter(address(quoter));
        vm.stopPrank();

        // Seed reserve.
        uint256 reserve = 5_000_000e18;
        deal(address(claim), address(furnace), reserve);
        vm.prank(address(router));
        furnace.creditReserve(reserve);

        deal(address(claim), alice, 2_000_000e18);
        deal(address(claim), bob, 2_000_000e18);
    }

    // ═══════════════════════════════════════════════════════════════════
    //  Duration Weight Curve: Boundary + Fuzz
    // ═══════════════════════════════════════════════════════════════════

    function test_durationWeight_exactBreakpoints() public view {
        // 8 breakpoints: 7d→100, 14d→175, 21d→300, 30d→500, 90d→1500, 180d→4000, 270d→6500, 365d→10000
        assertEq(quoter.durationWeightBps(7 days), 100, "7d");
        assertEq(quoter.durationWeightBps(14 days), 175, "14d");
        assertEq(quoter.durationWeightBps(21 days), 300, "21d");
        assertEq(quoter.durationWeightBps(30 days), 500, "30d");
        assertEq(quoter.durationWeightBps(90 days), 1500, "90d");
        assertEq(quoter.durationWeightBps(180 days), 4000, "180d");
        assertEq(quoter.durationWeightBps(270 days), 6500, "270d");
        assertEq(quoter.durationWeightBps(365 days), 10000, "365d");
    }

    function test_durationWeight_belowMinClamps() public view {
        // Durations below 7d should clamp to 7d weight (100).
        assertEq(quoter.durationWeightBps(0), 100, "0");
        assertEq(quoter.durationWeightBps(1), 100, "1s");
        assertEq(quoter.durationWeightBps(7 days - 1), 100, "7d-1");
    }

    function test_durationWeight_aboveMaxClamps() public view {
        // Durations above 365d should clamp to 365d weight (10000).
        assertEq(quoter.durationWeightBps(365 days + 1), 10000, "365d+1");
        assertEq(quoter.durationWeightBps(730 days), 10000, "730d");
    }

    function testFuzz_durationWeight_monotonicallyIncreasing(uint256 d1, uint256 d2) public view {
        d1 = bound(d1, Constants.MIN_LOCK_DURATION, Constants.MAX_LOCK_DURATION);
        d2 = bound(d2, Constants.MIN_LOCK_DURATION, Constants.MAX_LOCK_DURATION);
        if (d1 <= d2) {
            assertLe(quoter.durationWeightBps(d1), quoter.durationWeightBps(d2), "not monotonic");
        } else {
            assertGe(quoter.durationWeightBps(d1), quoter.durationWeightBps(d2), "not monotonic");
        }
    }

    function testFuzz_durationWeight_bounded(uint256 d) public view {
        d = bound(d, 0, 1000 days);
        uint256 w = quoter.durationWeightBps(d);
        assertGe(w, 100, "below floor");
        assertLe(w, 10000, "above cap");
    }

    // ═══════════════════════════════════════════════════════════════════
    //  Sell Duration Factor: Boundary via Breakdown
    // ═══════════════════════════════════════════════════════════════════

    /// @dev Test sell duration factor breakpoints indirectly through the sell breakdown.
    ///      Each test case uses vm.snapshot/revert to isolate time warps.
    function test_sellBreakdown_durFactorBps_at7d() public {
        _assertDurFactorAtRemaining(7 days, 500);
    }

    function test_sellBreakdown_durFactorBps_at30d() public {
        _assertDurFactorAtRemaining(30 days, 1500);
    }

    function test_sellBreakdown_durFactorBps_at90d() public {
        _assertDurFactorAtRemaining(90 days, 3500);
    }

    function test_sellBreakdown_durFactorBps_at180d() public {
        _assertDurFactorAtRemaining(180 days, 6000);
    }

    function test_sellBreakdown_durFactorBps_at365d() public {
        _assertDurFactorAtRemaining(365 days, 10000);
    }

    function _assertDurFactorAtRemaining(uint256 remaining, uint256 expectedFactor) internal {
        uint256 lockAmount = 50_000e18;
        address user = address(uint160(uint256(keccak256(abi.encode("durFactor", remaining))) | 1));
        _mintClaimTo(user, lockAmount);

        vm.startPrank(user);
        claim.approve(address(ve), lockAmount);
        uint256 tokenId = ve.createLock(lockAmount, Constants.MAX_LOCK_DURATION, false);
        vm.stopPrank();

        // Warp so remaining = desired.
        vm.warp(block.timestamp + Constants.MAX_LOCK_DURATION - remaining);

        IFurnaceQuoter.SellLockQuoteBreakdown memory q = quoter.quoteSellLockToFurnaceBreakdown(user, tokenId);
        assertEq(q.durFactorBps, expectedFactor, "durFactorBps mismatch");
    }

    // ═══════════════════════════════════════════════════════════════════
    //  Sell Spread Curves: Boundary Tests
    // ═══════════════════════════════════════════════════════════════════

    function test_sellRoundTripLossBps_boundaries() public view {
        // At MIN_LOCK_DURATION (7d): ceil(2500 * 7 / 365) = ceil(47.945) = 48
        uint256 lossAt7d = quoter.sellRoundTripLossBps(7 days);
        assertEq(lossAt7d, 48, "7d loss");

        // At MAX_LOCK_DURATION (365d): ceil(2500 * 365 / 365) = 2500
        uint256 lossAt365d = quoter.sellRoundTripLossBps(365 days);
        assertEq(lossAt365d, 2500, "365d loss");
    }

    function testFuzz_sellRoundTripLossBps_monotonic(uint256 d1, uint256 d2) public view {
        d1 = bound(d1, Constants.MIN_LOCK_DURATION, Constants.MAX_LOCK_DURATION);
        d2 = bound(d2, Constants.MIN_LOCK_DURATION, Constants.MAX_LOCK_DURATION);
        if (d1 <= d2) {
            assertLe(quoter.sellRoundTripLossBps(d1), quoter.sellRoundTripLossBps(d2), "loss not monotonic");
        }
    }

    function test_lpSaleShareBps_boundaries() public view {
        // At bonus = 0: should be LP_SALE_MIN_BPS = 500
        assertEq(quoter.lpSaleShareBps(0), Constants.LP_SALE_MIN_BPS, "min");
        // At bonus = MAX_USER_BONUS_BPS: should be LP_SALE_MAX_BPS = 1500
        assertEq(quoter.lpSaleShareBps(Constants.MAX_USER_BONUS_BPS), Constants.LP_SALE_MAX_BPS, "max");
    }

    function testFuzz_lpSaleShareBps_bounded(uint256 bonus) public view {
        bonus = bound(bonus, 0, Constants.MAX_USER_BONUS_BPS);
        uint256 share = quoter.lpSaleShareBps(bonus);
        assertGe(share, Constants.LP_SALE_MIN_BPS, "below floor");
        assertLe(share, Constants.LP_SALE_MAX_BPS, "above cap");
    }

    function testFuzz_lpSaleShareBps_monotonic(uint256 b1, uint256 b2) public view {
        b1 = bound(b1, 0, Constants.MAX_USER_BONUS_BPS);
        b2 = bound(b2, 0, Constants.MAX_USER_BONUS_BPS);
        if (b1 <= b2) {
            assertLe(quoter.lpSaleShareBps(b1), quoter.lpSaleShareBps(b2), "not monotonic");
        }
    }

    // ═══════════════════════════════════════════════════════════════════
    //  Edge Cases: Zero Inputs
    // ═══════════════════════════════════════════════════════════════════

    function test_zeroReserve_quoteReturnsZeroBonus() public {
        // Deploy fresh quoter with zero-reserve furnace, reusing the main claim/ve/furnace
        // but without crediting any reserve.
        ClaimToken claim2 = new ClaimToken(owner);
        VeClaimNFTHarness ve2 = new VeClaimNFTHarness(address(claim2), owner);
        Furnace furnace2 = new Furnace(
            address(claim2), address(ve2), address(new FurnaceGuardHelper(address(claim2), address(ve2))), owner
        );
        MockShareholderRoyaltiesCheckpoint mockSR2 = new MockShareholderRoyaltiesCheckpoint();
        MockAerodromeRouterMineCore router2 = new MockAerodromeRouterMineCore(
            address(0xFACADE), address(weth), address(claim2), address(ve2), address(furnace2), address(mockSR2)
        );
        address mineMarket2 = address(0xBAB2);
        vm.etch(mineMarket2, hex"01");
        vm.mockCall(mineMarket2, abi.encodeWithSignature("ve()"), abi.encode(address(ve2)));
        vm.mockCall(mineMarket2, abi.encodeWithSignature("claim()"), abi.encode(address(claim2)));
        vm.mockCall(mineMarket2, abi.encodeWithSignature("royalties()"), abi.encode(address(mockSR2)));

        // Create a fresh registry that uses claim2.
        EntryTokenRegistry reg2 = new EntryTokenRegistry(owner);

        vm.startPrank(owner);
        claim2.setMineCore(address(router2));
        furnace2.setMineCore(address(router2));
        furnace2.setMineMarket(mineMarket2);
        furnace2.setShareholderRoyalties(address(mockSR2));
        mockSR2.setWiring(address(router2), mineMarket2, address(furnace2), address(ve2));
        ve2.setFurnace(address(furnace2));
        ve2.setMineMarket(mineMarket2);
        reg2.setRouterConfig(address(router2), router2.defaultFactory(), address(weth), address(claim2));
        furnace2.setEntryTokenRegistry(address(reg2));
        FurnaceQuoter quoter2 = new FurnaceQuoter(address(furnace2));
        furnace2.setFurnaceQuoter(address(quoter2));
        vm.stopPrank();

        // No reserve credited -> bonus must be 0.
        deal(address(claim2), alice, 100_000e18);
        vm.startPrank(alice);
        claim2.approve(address(furnace2), 100_000e18);

        (uint256 principal, uint256 bonus, uint256 veOut,) =
            quoter2.quoteEnterWithClaim(alice, 10_000e18, 0, Constants.MAX_LOCK_DURATION, false);
        assertEq(principal, 10_000e18, "principal");
        assertEq(bonus, 0, "bonus must be 0 with no reserve");
        assertGt(veOut, 0, "veOut should still be positive (from principal)");
        vm.stopPrank();
    }

    function test_spotBonusMath_zeroElapsed() public view {
        // At elapsed = 0: swingAlpha = 0, reserveFactor = BPS_DENOM (1.0x).
        uint256 spot = quoter.userSpotBonusBps(0, 1_000_000e18, 5_000_000e18, 0);
        uint256 base = quoter.baseUserBps(0, 1_000_000e18);
        // With 0 locked, lockedPctBps=0, baseUserBps = MAX. reserveFactor = 1.0x. spot = base.
        assertEq(spot, base, "at elapsed=0 spot should equal base");
    }

    function test_spotBonusMath_zeroLockedSupply() public view {
        // With 0 locked supply, lockedPctBps = 0, base = MAX_USER_BONUS_BPS * target / target = MAX.
        uint256 base = quoter.baseUserBps(0, 1_000_000e18);
        assertEq(base, Constants.MAX_USER_BONUS_BPS, "0 locked -> max base");
    }

    function test_spotBonusMath_zeroTotalSupply() public view {
        // With 0 total supply, lockedPctBps = 0, base = MAX.
        uint256 base = quoter.baseUserBps(0, 0);
        assertEq(base, Constants.MAX_USER_BONUS_BPS, "0 supply -> max base");
    }

    function test_reserveFullness_zero() public view {
        assertEq(quoter.reserveFullnessBps(0), 0, "zero reserve -> zero fullness");
    }

    function test_reserveFullness_atTarget() public view {
        assertEq(quoter.reserveFullnessBps(Constants.RESERVE_TARGET_FINAL), Constants.BPS_DENOM, "at target -> 1.0x");
    }

    function test_swingAlpha_zero() public view {
        assertEq(quoter.swingAlphaBps(0), 0, "zero elapsed -> zero alpha");
    }

    function test_swingAlpha_atSwingTime() public view {
        assertEq(quoter.swingAlphaBps(Constants.SWING_TIME), Constants.BPS_DENOM, "at swing time -> 1.0x");
    }

    function test_swingAlpha_beyondSwingTime() public view {
        assertEq(quoter.swingAlphaBps(Constants.SWING_TIME + 1 days), Constants.BPS_DENOM, "past swing -> capped 1.0x");
    }

    // ═══════════════════════════════════════════════════════════════════
    //  Quote/Execute Differential: Sell Path
    // ═══════════════════════════════════════════════════════════════════

    function test_sellQuoteExecute_differential() public {
        uint256 principal = 50_000e18;
        _mintClaimTo(alice, principal);

        vm.startPrank(alice);
        claim.approve(address(ve), principal);
        uint256 tokenId = ve.createLock(principal, 30 days, false);
        ve.setApprovalForAllForTest(alice, mineMarket, true);
        vm.stopPrank();

        // Quote the sell.
        (
            uint256 lockAmount,
            uint256 claimOutQuoted,
            uint256 spreadBpsQuoted,
            uint256 lpRewardQuoted,
            uint256 reserveAddQuoted
        ) = quoter.quoteSellLockToFurnace(alice, tokenId);
        assertGt(claimOutQuoted, 0, "quoted claimOut > 0");
        assertEq(lockAmount, principal, "lockAmount matches principal");

        // Execute: transfer lock to Furnace then sell.
        uint256 aliceBalBefore = claim.balanceOf(alice);
        uint256 reserveBefore = furnace.furnaceReserve();

        vm.prank(mineMarket);
        ve.safeTransferFrom(alice, address(furnace), tokenId);
        vm.prank(mineMarket);
        furnace.sellLockToFurnaceFromMarket(alice, tokenId, 0);

        uint256 aliceBalAfter = claim.balanceOf(alice);
        uint256 reserveAfter = furnace.furnaceReserve();
        uint256 actualClaimOut = aliceBalAfter - aliceBalBefore;

        // Quoted claimOut must match executed claimOut (no state change between quote and execute).
        assertEq(actualClaimOut, claimOutQuoted, "sell claimOut quote != execution");

        // Reserve should increase by reserveAdd (LP vault is not set in this fixture).
        assertEq(reserveAfter - reserveBefore, reserveAddQuoted, "reserve delta mismatch");
    }

    function testFuzz_sellQuoteExecute_differential(uint256 principal, uint256 duration) public {
        principal = bound(principal, Constants.MIN_LOCK_AMOUNT, 200_000e18);
        duration = bound(duration, Constants.MIN_LOCK_DURATION, Constants.MAX_LOCK_DURATION);

        address user = address(uint160(uint256(keccak256(abi.encode(principal, duration))) | 1));
        _mintClaimTo(user, principal);

        vm.startPrank(user);
        claim.approve(address(ve), principal);
        uint256 tokenId = ve.createLock(principal, duration, false);
        ve.setApprovalForAllForTest(user, mineMarket, true);
        vm.stopPrank();

        (, uint256 claimOutQuoted,,,) = quoter.quoteSellLockToFurnace(user, tokenId);

        uint256 balBefore = claim.balanceOf(user);

        vm.prank(mineMarket);
        ve.safeTransferFrom(user, address(furnace), tokenId);
        vm.prank(mineMarket);
        furnace.sellLockToFurnaceFromMarket(user, tokenId, 0);

        uint256 actualClaimOut = claim.balanceOf(user) - balBefore;
        assertEq(actualClaimOut, claimOutQuoted, "fuzz sell differential mismatch");
    }

    // ═══════════════════════════════════════════════════════════════════
    //  Same-Block Multi-Entry Differential
    // ═══════════════════════════════════════════════════════════════════

    function test_sameBlock_secondEntry_quoteIsConservative() public {
        uint256 claimIn = 50_000e18;

        // First entry by Alice.
        vm.startPrank(alice);
        claim.approve(address(furnace), claimIn);
        (,, uint256 veOut1,) = quoter.quoteEnterWithClaim(alice, claimIn, 0, Constants.MAX_LOCK_DURATION, false);
        furnace.enterWithClaim(claimIn, 0, Constants.MAX_LOCK_DURATION, false, veOut1);
        vm.stopPrank();

        // Same block: second entry by Bob.
        // The quoter should see the post-mutation V from Alice's entry, yielding a lower (conservative) quote.
        vm.startPrank(bob);
        claim.approve(address(furnace), claimIn);
        (uint256 principal2, uint256 bonus2, uint256 veOut2,) =
            quoter.quoteEnterWithClaim(bob, claimIn, 0, Constants.MAX_LOCK_DURATION, false);

        // Execute with the quoted minVeOut — must succeed (quote was conservative).
        furnace.enterWithClaim(claimIn, 0, Constants.MAX_LOCK_DURATION, false, veOut2);
        vm.stopPrank();

        // Bob's actual ve should be >= quoted (conservative underquote or exact match).
        uint256 bobActualVe = ve.veBalanceOf(bob);
        assertGe(bobActualVe, veOut2, "same-block second entry: actual ve must be >= quoted");

        // Verify second entry got less bonus than first (V increased after first entry).
        (,, uint256 veOut1Fresh,) = quoter.quoteEnterWithClaim(alice, claimIn, 0, Constants.MAX_LOCK_DURATION, false);
        // After both entries, a new quote should be lower than the first entry's quote.
        assertLe(veOut1Fresh, veOut1, "third quote should be <= first (V accumulated)");
    }

    // ═══════════════════════════════════════════════════════════════════
    //  Sell Breakdown: Consistency + Invariants
    // ═══════════════════════════════════════════════════════════════════

    function test_sellBreakdown_matchesSimpleQuote() public {
        uint256 principal = 50_000e18;
        _mintClaimTo(alice, principal);

        vm.startPrank(alice);
        claim.approve(address(ve), principal);
        uint256 tokenId = ve.createLock(principal, 90 days, false);
        vm.stopPrank();

        // Simple quote.
        (uint256 lockAmount1, uint256 claimOut1, uint256 spreadBps1, uint256 lpReward1, uint256 reserveAdd1) =
            quoter.quoteSellLockToFurnace(alice, tokenId);

        // Breakdown quote.
        IFurnaceQuoter.SellLockQuoteBreakdown memory q = quoter.quoteSellLockToFurnaceBreakdown(alice, tokenId);

        // Core outputs must match.
        assertEq(q.lockAmount, lockAmount1, "lockAmount");
        assertEq(q.claimOut, claimOut1, "claimOut");
        assertEq(q.spreadBps, spreadBps1, "spreadBps");
        assertEq(q.lpReward, lpReward1, "lpReward");
        assertEq(q.reserveAdd, reserveAdd1, "reserveAdd");

        // Backward-compat alias.
        assertEq(q.bonusBpsUsed, q.bonusRefBpsUsed, "bonusBpsUsed == bonusRefBpsUsed");

        // Conservation invariant: claimOut + lpReward + reserveAdd == lockAmount.
        assertEq(q.claimOut + q.lpReward + q.reserveAdd, q.lockAmount, "conservation violated");
    }

    function test_sellBreakdown_isBonusClampBinding_flag() public {
        // With a large reserve, spot bonus includes reserve factor > 1.0x.
        // Base bonus is anchor-only (no reserve factor). spot > base -> clamp not binding.
        uint256 principal = 50_000e18;
        _mintClaimTo(alice, principal);

        vm.startPrank(alice);
        claim.approve(address(ve), principal);
        uint256 tokenId = ve.createLock(principal, 90 days, false);
        vm.stopPrank();

        // With healthy reserve (5M > 20M target is 25%), spot could be > or < base depending on reserve factor.
        IFurnaceQuoter.SellLockQuoteBreakdown memory q = quoter.quoteSellLockToFurnaceBreakdown(alice, tokenId);

        // Verify flag consistency.
        if (q.spotBonusBps < q.baseBonusBps) {
            assertTrue(q.isBonusClampBinding, "should be binding when spot < base");
            assertEq(q.bonusRefBpsUsed, q.baseBonusBps, "ref should be base when clamped");
        } else {
            assertFalse(q.isBonusClampBinding, "should not bind when spot >= base");
            assertEq(q.bonusRefBpsUsed, q.spotBonusBps, "ref should be spot when not clamped");
        }
    }

    function testFuzz_sellBreakdown_conservation(uint256 principal, uint256 duration) public {
        principal = bound(principal, Constants.MIN_LOCK_AMOUNT, 200_000e18);
        duration = bound(duration, Constants.MIN_LOCK_DURATION, Constants.MAX_LOCK_DURATION);

        address user = address(uint160(uint256(keccak256(abi.encode("conservation", principal, duration))) | 1));
        _mintClaimTo(user, principal);

        vm.startPrank(user);
        claim.approve(address(ve), principal);
        uint256 tokenId = ve.createLock(principal, duration, false);
        vm.stopPrank();

        IFurnaceQuoter.SellLockQuoteBreakdown memory q = quoter.quoteSellLockToFurnaceBreakdown(user, tokenId);
        assertEq(q.claimOut + q.lpReward + q.reserveAdd, q.lockAmount, "conservation invariant");
    }

    // ═══════════════════════════════════════════════════════════════════
    //  Sell Impact: Volume Accumulation
    // ═══════════════════════════════════════════════════════════════════

    function test_sellImpact_multiSellSameBlock_impactRatchets() public {
        // Create two locks.
        uint256 lockAmount = 100_000e18;
        _mintClaimTo(alice, lockAmount);
        _mintClaimTo(bob, lockAmount);

        vm.startPrank(alice);
        claim.approve(address(ve), lockAmount);
        uint256 tokenIdA = ve.createLock(lockAmount, 90 days, false);
        ve.setApprovalForAllForTest(alice, mineMarket, true);
        vm.stopPrank();

        vm.startPrank(bob);
        claim.approve(address(ve), lockAmount);
        uint256 tokenIdB = ve.createLock(lockAmount, 90 days, false);
        ve.setApprovalForAllForTest(bob, mineMarket, true);
        vm.stopPrank();

        // Quote both sells before any execution.
        (, uint256 claimOutA_pre,,,) = quoter.quoteSellLockToFurnace(alice, tokenIdA);
        (, uint256 claimOutB_pre,,,) = quoter.quoteSellLockToFurnace(bob, tokenIdB);

        // Execute Alice's sell first.
        vm.prank(mineMarket);
        ve.safeTransferFrom(alice, address(furnace), tokenIdA);
        vm.prank(mineMarket);
        furnace.sellLockToFurnaceFromMarket(alice, tokenIdA, 0);

        // After Alice's sell, sell impact volume has increased.
        // Bob's post-execution quote should show higher spread (lower claimOut) due to impact.
        // Note: we can't directly quote for Bob's token anymore since tokenIdB is still owned by Bob
        // and not transferred yet. Instead we use quoteSellLockToFurnaceFromInfo with same params.
        (uint256 claimOutB_post,,,) =
            quoter.quoteSellLockToFurnaceFromInfo(lockAmount, block.timestamp + 90 days, false);

        // Post-sell quote for equivalent lock should have equal or higher spread (lower claimOut)
        // because sellImpactVolume accumulated from Alice's sell.
        assertLe(claimOutB_post, claimOutB_pre, "post-first-sell quote should have >= spread (impact ratchet)");
    }

    // ═══════════════════════════════════════════════════════════════════
    //  No-Arb Floor: Mathematical Verification
    // ═══════════════════════════════════════════════════════════════════

    function testFuzz_noArbFloor_buyThenSellNeverProfitable(uint256 bonus) public view {
        bonus = bound(bonus, 0, Constants.MAX_USER_BONUS_BPS);

        // Compute no-arb floor: Ceil(BPS * b / (BPS + b)).
        uint256 noArb =
            bonus == 0 ? 0 : Math.mulDiv(Constants.BPS_DENOM, bonus, Constants.BPS_DENOM + bonus, Math.Rounding.Ceil);

        // Round-trip: buy at bonus b, sell at spread noArb.
        // lockAmount = P * (1 + b/BPS) = P * (BPS + b) / BPS
        // claimOut = lockAmount * (BPS - noArb) / BPS
        // Profit = claimOut - P

        // With principal P = BPS_DENOM (to avoid fractions):
        uint256 P = Constants.BPS_DENOM;
        uint256 lockAmt = P * (Constants.BPS_DENOM + bonus) / Constants.BPS_DENOM;
        uint256 claimOut = lockAmt * (Constants.BPS_DENOM - noArb) / Constants.BPS_DENOM;

        assertLe(claimOut, P, "round-trip must not be profitable");
    }

    // ═══════════════════════════════════════════════════════════════════
    //  Bonus Math: Spot Bonus Chain Fuzz
    // ═══════════════════════════════════════════════════════════════════

    function testFuzz_userSpotBonusBps_capped(
        uint256 lockedSupply,
        uint256 totalSupply,
        uint256 reserve,
        uint256 elapsed
    ) public view {
        lockedSupply = bound(lockedSupply, 0, 500_000_000e18);
        totalSupply = bound(totalSupply, 1, 500_000_000e18); // nonzero to avoid division edge
        if (lockedSupply > totalSupply) lockedSupply = totalSupply;
        reserve = bound(reserve, 0, 100_000_000e18);
        elapsed = bound(elapsed, 0, 365 days);

        uint256 spot = quoter.userSpotBonusBps(lockedSupply, totalSupply, reserve, elapsed);
        assertLe(spot, Constants.MAX_USER_BONUS_BPS, "spot must be capped");
    }

    function testFuzz_grossSpotBonusBps_capped(uint256 userSpot, uint256 lpRate) public view {
        userSpot = bound(userSpot, 0, Constants.MAX_USER_BONUS_BPS);
        lpRate = bound(lpRate, 0, Constants.LP_TOPUP_RATE_MAX_BPS);
        uint256 gross = quoter.grossSpotBonusBps(userSpot, lpRate);
        assertLe(gross, Constants.MAX_GROSS_BONUS_BPS, "gross must be capped");
    }

    // ═══════════════════════════════════════════════════════════════════
    //  Helpers
    // ═══════════════════════════════════════════════════════════════════

    function _mintClaimTo(address to, uint256 amount) internal {
        vm.prank(address(router));
        claim.mint(to, amount);
    }
}
