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

contract Furnace_LpSaleShare_Curve_Hardening_Test is Test {
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
        _mintClaimTo(address(furnace), amount);
        vm.prank(address(mineCore));
        furnace.creditReserve(amount);
    }

    function testLpSaleShareCurve_boundsAndClamps() public {
        assertEq(furnace.exposedLpSaleShareBps(0), Constants.LP_SALE_MIN_BPS, "min share mismatch");
        assertEq(
            furnace.exposedLpSaleShareBps(Constants.MAX_USER_BONUS_BPS), Constants.LP_SALE_MAX_BPS, "max share mismatch"
        );

        // Above the max user bonus bps should still clamp to the max share.
        assertEq(
            furnace.exposedLpSaleShareBps(Constants.MAX_USER_BONUS_BPS * 2),
            Constants.LP_SALE_MAX_BPS,
            "share should clamp above MAX_USER_BONUS_BPS"
        );
    }

    function testLpSaleShareCurve_monotonicSample() public {
        uint256 maxBps = Constants.MAX_USER_BONUS_BPS;

        uint256 prev = furnace.exposedLpSaleShareBps(0);

        uint256[4] memory fracs = [uint256(2_500), 5_000, 7_500, 10_000];
        for (uint256 i = 0; i < fracs.length; i++) {
            uint256 spot = Math.mulDiv(maxBps, fracs[i], 10_000);
            uint256 cur = furnace.exposedLpSaleShareBps(spot);
            assertGe(cur, prev, "lpSaleShare must be monotonic non-decreasing");
            prev = cur;
        }

        // Also assert bounds on the last point.
        assertEq(prev, Constants.LP_SALE_MAX_BPS, "last sample should hit max share");
    }

    function testSellbackLpReward_matchesCutTimesEffectiveShare_withLpScaleDown() public {
        // Force lpScale = 0.5x by setting reserve to 50% and waiting for SWING_TIME.
        uint256 reserve = Constants.RESERVE_TARGET_FINAL / 2;
        _creditReserve(reserve);
        vm.warp(block.timestamp + Constants.SWING_TIME);

        // Create a single lock so lockedSupplyExcl == 0 during sellback.
        uint256 lockAmt = 100_000e18;
        _mintClaimTo(alice, lockAmt);

        vm.startPrank(alice);
        claim.approve(address(ve), lockAmt);
        uint256 tokenId = ve.createLock(lockAmt, Constants.MAX_LOCK_DURATION, false);
        ve.setApprovalForAllForTest(alice, address(furnace), true);
        vm.stopPrank();

        // Quote the sellback.
        (uint256 lockAmountQ, uint256 claimOutQ,, uint256 lpRewardQ, uint256 reserveAddQ) =
            furnaceQuoter.quoteSellLockToFurnace(alice, tokenId);

        uint256 cut = lockAmountQ - claimOutQ;
        assertEq(lpRewardQ + reserveAddQ, cut, "cut must split into lpReward + reserveAdd");

        // With lockedSupplyExcl == 0, baseUserBps == MAX_USER_BONUS_BPS, and bonusRef = max(spot, base) == base.
        uint256 bonusRefBpsUsed = Constants.MAX_USER_BONUS_BPS;

        uint256 totalSupply = claim.totalSupply();
        uint256 elapsed = block.timestamp - mineCore.emissionStartTime();

        uint256 lpScaleBps = furnace.exposedLpScaleBps(0, totalSupply, reserve, elapsed);
        assertEq(lpScaleBps, 5_000, "lpScale should be 0.5x");

        uint256 baseShareBps = furnace.exposedLpSaleShareBps(bonusRefBpsUsed);
        assertEq(baseShareBps, Constants.LP_SALE_MAX_BPS, "base share should be max at bonusRef=MAX");

        uint256 effectiveShareBps = Math.mulDiv(baseShareBps, lpScaleBps, Constants.BPS_DENOM);

        // Expected LP reward is floor(cut * effectiveShare / 10_000), before any cap binds.
        uint256 expectedLpReward = Math.mulDiv(cut, effectiveShareBps, Constants.BPS_DENOM);

        // This test is designed so the daily cap does NOT bind (lpRewardRaw << cap).
        assertEq(lpRewardQ, expectedLpReward, "lpReward should match cut * effectiveShare");
    }

    function testLpSaleRewardCapPerDay_defaultsToFixedCapWhenMineCoreUnset() public {
        // A furnace with mineCore unset returns a fixed cap (defensive behavior).
        FurnaceHarness f2 = new FurnaceHarness(address(claim), address(ve), owner);
        uint256 cap = f2.getLpSaleRewardCapPerDay();
        assertEq(cap, Constants.LP_SALE_REWARD_CAP_FIXED_CAP_PER_DAY, "cap should default to fixed when inflow=0");
    }
}
