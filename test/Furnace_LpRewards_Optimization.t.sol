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

contract Furnace_LpRewards_Optimization_Test is Test {
    ClaimToken internal claim;
    VeClaimNFTHarness internal ve;
    MineCore internal mineCore;
    FurnaceHarness internal furnace;
    FurnaceQuoter internal furnaceQuoter;
    MockLpRewardsVault internal lpVault;
    MockShareholderRoyaltiesCheckpoint internal royalties;

    address internal owner = address(0xA11CE);
    address internal alice = address(0xA11C3);
    address internal mineMarket = address(0xB0B0);
    address internal registry = address(0xE777);

    function setUp() public {
        // Mock addresses must look like contracts for NotAContract guards.
        vm.etch(mineMarket, hex"00");
        vm.etch(registry, hex"00");

        claim = new ClaimToken(owner);
        ve = new VeClaimNFTHarness(address(claim), owner);
        royalties = new MockShareholderRoyaltiesCheckpoint();

        mineCore = new MineCore(address(claim), address(ve), address(royalties), owner);
        furnace = new FurnaceHarness(address(claim), address(ve), owner);
        furnaceQuoter = new FurnaceQuoter(address(furnace));
        FurnaceQuoter quoter = furnaceQuoter;

        // Wire core addresses.
        vm.startPrank(owner);
        claim.setMineCore(address(mineCore));
        vm.mockCall(mineMarket, abi.encodeWithSignature("ve()"), abi.encode(address(ve)));
        vm.mockCall(mineMarket, abi.encodeWithSignature("claim()"), abi.encode(address(claim)));
        vm.mockCall(mineMarket, abi.encodeWithSignature("royalties()"), abi.encode(address(royalties)));
        mineCore.setFurnace(address(furnace));
        furnace.setMineCore(address(mineCore));
        furnace.setFurnaceQuoter(address(quoter));
        furnace.setShareholderRoyalties(address(royalties));
        furnace.setMineMarket(mineMarket);
        furnace.setEntryTokenRegistry(registry);
        royalties.setWiring(address(mineCore), mineMarket, address(furnace), address(ve));

        // Wire VeClaimNFT so Furnace can burn & withdraw on sellback.
        ve.setFurnace(address(furnace));
        ve.setMineMarket(mineMarket);

        // Enable LP vault.
        lpVault = new MockLpRewardsVault();
        lpVault.setFurnace(address(furnace));
        furnace.setLpRewardsVault(address(lpVault));

        vm.stopPrank();
    }

    function _mintClaimTo(address to, uint256 amount) internal {
        vm.prank(address(mineCore));
        claim.mint(to, amount);
    }

    function _creditReserve(uint256 amount) internal {
        // Furnace.reserve is internal accounting; crediting reserve also mints/escrows CLAIM in the Furnace.
        _mintClaimTo(address(furnace), amount);
        vm.prank(address(mineCore));
        furnace.creditReserve(amount);
    }

    struct SellQuote {
        uint256 lockAmount;
        uint256 claimOut;
        uint256 lpReward;
        uint256 reserveAdd;
    }

    function _quoteSellLock(address owner_, uint256 tokenId) internal returns (SellQuote memory q) {
        (q.lockAmount, q.claimOut,, q.lpReward, q.reserveAdd) = furnaceQuoter.quoteSellLockToFurnace(owner_, tokenId);
    }

    function testLpScaleDown_appliesToGetFurnaceStateLpTopupRateBps() public {
        // Set reserve to 50% of target and advance to full swing-in time so reserve-factor is active.
        uint256 reserve = Constants.RESERVE_TARGET_FINAL / 2;
        _creditReserve(reserve);

        vm.warp(block.timestamp + Constants.SWING_TIME);

        (
            uint256 reserveNow,
            uint256 lockedSupply,
            uint256 userSpotBps,
            uint256 lpRateBps,,,,
            /* lastUpdate */
        ) = furnaceQuoter.getFurnaceState();

        assertEq(reserveNow, reserve, "reserve mismatch");
        assertEq(lockedSupply, 0, "lockedSupply should be 0 in this test");

        uint256 totalSupply = claim.totalSupply();
        uint256 elapsed = block.timestamp - mineCore.emissionStartTime();

        // Helper equivalence.
        uint256 expectedUserSpotBps = furnace.exposedUserSpotBonusBps(lockedSupply, totalSupply, reserveNow, elapsed);
        assertEq(userSpotBps, expectedUserSpotBps, "userSpot helper mismatch");

        uint256 baseLpRateBps = furnace.exposedLpTopupRateBps(userSpotBps);
        uint256 lpScaleBps = furnace.exposedLpScaleBps(lockedSupply, totalSupply, reserveNow, elapsed);

        // Half-full reserve at full swing should produce a 0.5x scaling factor.
        assertEq(lpScaleBps, 5_000, "lpScale should be 0.5x");

        uint256 expectedLpRateBps = Math.mulDiv(baseLpRateBps, lpScaleBps, Constants.BPS_DENOM);
        assertEq(lpRateBps, expectedLpRateBps, "lpRate should be scaled down");
        assertLt(lpRateBps, baseLpRateBps, "scaled lpRate should be < base");
    }

    function testGetFurnaceState_previewsPendingOverflowDripReserve() public {
        uint256 reserve = Constants.RESERVE_TARGET_FINAL + 50_000_000e18;
        _creditReserve(reserve);

        uint256 t0 = mineCore.emissionStartTime();
        vm.warp(t0 + Constants.LP_OVERFLOW_DRIP_START + Constants.LP_OVERFLOW_DRIP_RAMP + 7 days);

        uint256 pending = furnace.exposedPendingLpOverflowDripLiability();
        assertGt(pending, 0, "expected pending overflow drip");

        (uint256 reserveNow,,,,,,,) = furnaceQuoter.getFurnaceState();
        assertEq(reserveNow, reserve - pending, "state lens must preview post-drip reserve");
    }

    function testLpSaleRewardCap_clampsSellbackFunding_andResetsNextDay() public {
        // Create 2 very large locks so a single sellback would exceed the per-day LP reward cap.
        uint256 lockAmt1 = 1_000_000_000e18; // 1B CLAIM
        uint256 lockAmt2 = 1_000_000_000e18; // 1B CLAIM

        _mintClaimTo(alice, lockAmt1 + lockAmt2);

        vm.startPrank(alice);
        claim.approve(address(ve), lockAmt1 + lockAmt2);

        uint256 tokenId1 = ve.createLock(lockAmt1, Constants.MAX_LOCK_DURATION, false);
        uint256 tokenId2 = ve.createLock(lockAmt2, Constants.MAX_LOCK_DURATION, false);

        // Strict mode: only MineMarket can transfer veNFTs into Furnace custody for sellback.
        ve.setApprovalForAllForTest(alice, mineMarket, true);
        vm.stopPrank();

        uint256 capPerDay = furnace.getLpSaleRewardCapPerDay();
        // Cap/day at the current timestamp should match the deterministic formula.
        {
            uint256 ratePerSec = mineCore.getFurnaceEmissionRateAt(block.timestamp);
            uint256 inflowPerDay = ratePerSec * 1 days;
            uint256 capInflow =
                Math.mulDiv(inflowPerDay, Constants.LP_SALE_REWARD_CAP_INFLOW_SHARE_BPS, Constants.BPS_DENOM);
            uint256 expectedCap = capInflow < Constants.LP_SALE_REWARD_CAP_FIXED_CAP_PER_DAY
                ? capInflow
                : Constants.LP_SALE_REWARD_CAP_FIXED_CAP_PER_DAY;
            assertEq(capPerDay, expectedCap, "cap/day mismatch");
        }

        uint256 lockAmountQ;
        uint256 claimOutQ;
        uint256 lpRewardQ;
        uint256 reserveAddQ;
        uint256 cutQ;
        // Quote should already clamp the LP reward to the cap.
        (lockAmountQ, claimOutQ,, lpRewardQ, reserveAddQ) = furnaceQuoter.quoteSellLockToFurnace(alice, tokenId1);
        assertEq(lpRewardQ, capPerDay, "lpReward should be capped in quote");

        cutQ = lockAmountQ - claimOutQ;
        assertEq(lpRewardQ + reserveAddQ, cutQ, "cut must split into lpReward + reserveAdd");

        // Execute the sellback. Funding should track exactly the capped amount.
        // Sell via strict Market-only path: MineMarket transfers the NFT into Furnace custody, then executes sellback.
        vm.prank(mineMarket);
        ve.safeTransferFrom(alice, address(furnace), tokenId1);

        vm.prank(mineMarket);
        furnace.sellLockToFurnaceFromMarket(alice, tokenId1, 0);

        assertEq(furnace.getLpSaleRewardFundedToday(), capPerDay, "fundedToday should equal cap");
        assertEq(furnace.getLpSaleRewardCapRemaining(), 0, "capRemaining should be 0");

        // With no remaining cap today, the second lock's quote should show 0 LP funding.
        (lockAmountQ, claimOutQ,, lpRewardQ, reserveAddQ) = furnaceQuoter.quoteSellLockToFurnace(alice, tokenId2);
        assertEq(lpRewardQ, 0, "lpReward should be 0 when cap is exhausted");

        cutQ = lockAmountQ - claimOutQ;
        assertEq(reserveAddQ, cutQ, "when cap is exhausted, all cut should go to reserve");

        // Advance to the next day: cap should be available again (view should treat fundedToday as 0).
        vm.warp(block.timestamp + 1 days);

        assertEq(furnace.getLpSaleRewardFundedToday(), 0, "fundedToday should reset in view on day rollover");
        assertGt(furnace.getLpSaleRewardCapRemaining(), 0, "capRemaining should be > 0 after day rollover");

        // Quote again: should now be capped to the new day's cap.
        uint256 capNextDay = furnace.getLpSaleRewardCapPerDay();
        (lockAmountQ, claimOutQ,, lpRewardQ, reserveAddQ) = furnaceQuoter.quoteSellLockToFurnace(alice, tokenId2);
        assertEq(lpRewardQ, capNextDay, "lpReward should be capped again on new day");

        cutQ = lockAmountQ - claimOutQ;
        assertEq(lpRewardQ + reserveAddQ, cutQ, "cut split must hold on new day quote");
    }

    function testLpScaleDown_clampsAtOneX_whenReserveAboveTarget() public {
        // Seed reserve above target final and advance to full swing so reserve-factor wants to boost (>1.0x).
        uint256 reserve = Constants.RESERVE_TARGET_FINAL * 2;
        _creditReserve(reserve);

        vm.warp(block.timestamp + Constants.SWING_TIME);

        uint256 totalSupply = claim.totalSupply();
        uint256 elapsed = block.timestamp - mineCore.emissionStartTime();

        // Raw reserveFactor (pre-dynamic cap) should be > 10_000 when reserve is above target.
        uint256 reserveFullnessBps = furnace.exposedReserveFullnessBps(reserve);
        uint256 alphaBps = furnace.exposedSwingAlphaBps(elapsed);
        uint256 rawReserveFactorBps = furnace.exposedReserveFactorBps(reserveFullnessBps, alphaBps);
        assertGt(rawReserveFactorBps, Constants.BPS_DENOM, "reserveFactor should be > 1.0x here");

        // LP scale is down-only: must clamp to 1.0x (10_000) even if reserveFactor is > 10_000.
        uint256 lpScaleBps = furnace.exposedLpScaleBps(0, totalSupply, reserve, elapsed);
        assertEq(lpScaleBps, Constants.BPS_DENOM, "lpScale must clamp to 1.0x");
    }

    function testLpSaleRewardCap_partialUsage_thenClampToRemaining() public {
        // Create two locks: a huge one and a small one.
        // Sell the small one first (should partially consume cap), then sell the huge one (should clamp to remaining).
        uint256 lockAmtBig = 1_000_000_000e18; // 1B CLAIM
        uint256 lockAmtSmall = 100_000e18; // 100k CLAIM

        _mintClaimTo(alice, lockAmtBig + lockAmtSmall);

        vm.startPrank(alice);
        claim.approve(address(ve), lockAmtBig + lockAmtSmall);

        uint256 tokenIdBig = ve.createLock(lockAmtBig, Constants.MAX_LOCK_DURATION, false);
        uint256 tokenIdSmall = ve.createLock(lockAmtSmall, Constants.MAX_LOCK_DURATION, false);

        // Strict mode: only MineMarket can transfer veNFTs into Furnace custody for sellback.
        ve.setApprovalForAllForTest(alice, mineMarket, true);
        vm.stopPrank();

        uint256 capPerDay = furnace.getLpSaleRewardCapPerDay();

        // First, quote + sell the SMALL lock.
        SellQuote memory qSmall = _quoteSellLock(alice, tokenIdSmall);

        uint256 cutSmall = qSmall.lockAmount - qSmall.claimOut;
        assertEq(qSmall.lpReward + qSmall.reserveAdd, cutSmall, "cut must split (small)");

        // This test is constructed so small sell should NOT hit the cap.
        assertGt(qSmall.lpReward, 0, "small sell should fund some LP reward");
        assertLt(qSmall.lpReward, capPerDay, "small sell should be below cap");

        // Sell via strict Market-only path: MineMarket transfers the NFT into Furnace custody, then executes sellback.
        vm.prank(mineMarket);
        ve.safeTransferFrom(alice, address(furnace), tokenIdSmall);

        vm.prank(mineMarket);
        furnace.sellLockToFurnaceFromMarket(alice, tokenIdSmall, 0);

        uint256 usedAfterSmall = furnace.getLpSaleRewardFundedToday();
        assertEq(usedAfterSmall, qSmall.lpReward, "fundedToday should equal small lpReward");

        uint256 remainingAfterSmall = furnace.getLpSaleRewardCapRemaining();
        assertEq(remainingAfterSmall, capPerDay - qSmall.lpReward, "remaining cap should be reduced");

        // Now quote the BIG lock: lpReward should clamp to the remaining cap.
        SellQuote memory qBig = _quoteSellLock(alice, tokenIdBig);

        uint256 cutBig = qBig.lockAmount - qBig.claimOut;
        assertEq(qBig.lpReward + qBig.reserveAdd, cutBig, "cut must split (big)");
        assertEq(qBig.lpReward, remainingAfterSmall, "big sell should clamp to remaining cap");

        // Execute big sell: fundedToday should reach full cap.
        // Sell via strict Market-only path: MineMarket transfers the NFT into Furnace custody, then executes sellback.
        vm.prank(mineMarket);
        ve.safeTransferFrom(alice, address(furnace), tokenIdBig);

        vm.prank(mineMarket);
        furnace.sellLockToFurnaceFromMarket(alice, tokenIdBig, 0);

        assertEq(furnace.getLpSaleRewardFundedToday(), capPerDay, "fundedToday should reach full cap");
        assertEq(furnace.getLpSaleRewardCapRemaining(), 0, "capRemaining should be 0");
    }
}
