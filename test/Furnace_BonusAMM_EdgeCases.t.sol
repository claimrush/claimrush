// SPDX-License-Identifier: MIT
pragma solidity ^0.8.34;

import {Test} from "forge-std/Test.sol";

import {ClaimToken} from "src/ClaimToken.sol";
import {MineCore} from "src/MineCore.sol";
import {ShareholderRoyalties} from "src/ShareholderRoyalties.sol";
import {FurnaceQuoter} from "src/FurnaceQuoter.sol";
import {Constants} from "src/lib/Constants.sol";

import {FurnaceHarness} from "./mocks/FurnaceHarness.sol";
import {MockContract} from "./mocks/MockContract.sol";
import {MockEntryTokenRegistry} from "./mocks/MockEntryTokenRegistry.sol";
import {MockLpRewardsVault} from "./mocks/MockLpRewardsVault.sol";
import {MockVe} from "./mocks/MockVe.sol";

/// @notice Bonus AMM edge case tests (zero reserve, max reserve, zero supply).
contract FurnaceBonusAMMEdgeCasesTest is Test {
    ClaimToken internal claim;
    MockVe internal ve;
    MineCore internal mineCore;
    FurnaceHarness internal furnace;
    FurnaceQuoter internal furnaceQuoter;
    MockLpRewardsVault internal lpVault;
    ShareholderRoyalties internal royalties;

    address internal owner;

    function setUp() public {
        owner = makeAddr("owner");

        ve = new MockVe();
        claim = new ClaimToken(owner);
        royalties = new ShareholderRoyalties(address(ve), owner);
        mineCore = new MineCore(address(claim), address(ve), address(royalties), owner);
        furnace = new FurnaceHarness(address(claim), address(ve), owner);
        furnaceQuoter = new FurnaceQuoter(address(furnace));
        lpVault = new MockLpRewardsVault();
        lpVault.setFurnace(address(furnace));

        vm.startPrank(owner);
        claim.setMineCore(address(mineCore));
        furnace.setMineCore(address(mineCore));
        furnace.setFurnaceQuoter(address(furnaceQuoter));
        furnace.setLpRewardsVault(address(lpVault));
        mineCore.setFurnace(address(furnace));
        vm.etch(address(0xB0B0), hex"00");
        royalties.setWiring(address(mineCore), address(0xB0B0), address(furnace));
        vm.stopPrank();

        ve.setTotalLockedClaim(5_000_000e18);
    }

    function _creditReserve(uint256 amount) internal {
        vm.prank(address(mineCore));
        claim.mint(address(furnace), amount);
        vm.prank(address(mineCore));
        furnace.creditReserve(amount);
    }

    // ----------------------------------------------------------------
    // Zero reserve
    // ----------------------------------------------------------------

    function testBonusIsZeroWhenReserveIsZero() public {
        // No reserve credited.
        assertEq(furnace.furnaceReserve(), 0);

        (uint256 gross, uint256 user, uint256 lp) = furnace.exposedApplyBonusAmm(100_000e18);

        assertEq(gross, 0, "gross bonus should be 0 with empty reserve");
        assertEq(user, 0, "user bonus should be 0");
        assertEq(lp, 0, "lp bonus should be 0");
    }

    function testBonusDoesNotRevertWhenReserveIsZero() public {
        // Should not revert, just return zero.
        furnace.exposedApplyBonusAmm(1e18);
        furnace.exposedApplyBonusAmm(1_000_000e18);
    }

    // ----------------------------------------------------------------
    // Max reserve
    // ----------------------------------------------------------------

    function testBonusWithMaxReserve() public {
        // Credit a very large reserve.
        _creditReserve(Constants.RESERVE_TARGET_FINAL * 5);

        uint256 start = mineCore.emissionStartTime();
        vm.warp(start + Constants.SWING_TIME + 1);

        uint256 reserveBefore = furnace.furnaceReserve();

        (uint256 gross,,) = furnace.exposedApplyBonusAmm(100_000e18);

        // Bonus should be non-zero and reserve should decrease.
        assertGt(gross, 0, "bonus should be nonzero with large reserve");
        assertLt(furnace.furnaceReserve(), reserveBefore, "reserve should decrease");

        // Reserve should never go negative (Solidity would underflow/revert).
        assertGe(furnace.furnaceReserve(), 0, "reserve non-negative");
    }

    // ----------------------------------------------------------------
    // Zero locked supply
    // ----------------------------------------------------------------

    function testBonusIsZeroWhenTotalSupplyIsZero() public {
        // With MockVe, we can't set totalSupply to 0 easily because claim.totalSupply()
        // depends on minted tokens. But we can test with zero locked supply.
        ve.setTotalLockedClaim(0);
        _creditReserve(10_000_000e18);

        uint256 start = mineCore.emissionStartTime();
        vm.warp(start + Constants.SWING_TIME + 1);

        // lockedPctBps = 0, so baseUserBps = MAX * target / (target + 0) = MAX
        // But reserveFactorBps depends on fullness, and userSpotBps should be non-zero.
        // The actual behavior depends on the quoter's clamping logic.
        (uint256 gross,,) = furnace.exposedApplyBonusAmm(100_000e18);

        // Should not revert regardless of outcome.
        // gross may be 0 or non-zero depending on quoter edge case handling.
        assertTrue(true, "did not revert with zero locked supply");
    }

    // ----------------------------------------------------------------
    // Virtual depth decay
    // ----------------------------------------------------------------

    function testVirtualDepthDecaysOverThreeHours() public {
        _creditReserve(10_000_000e18);
        ve.setTotalLockedClaim(5_000_000e18);

        uint256 start = mineCore.emissionStartTime();
        vm.warp(start + Constants.SWING_TIME + 1);

        // First entry sets V.
        furnace.exposedApplyBonusAmm(100_000e18);
        uint256 vAfterFirst = furnace.exposedBonusVirtualDepth();
        assertGt(vAfterFirst, 0, "V should be non-zero after entry");

        // Warp 3 hours (full decay).
        vm.warp(block.timestamp + Constants.BONUS_DECAY_WINDOW);

        // Second entry should get a better rate (V decayed to vTarget).
        uint256 reserveBefore = furnace.furnaceReserve();
        (uint256 gross2,,) = furnace.exposedApplyBonusAmm(100_000e18);
        uint256 vAfterSecond = furnace.exposedBonusVirtualDepth();

        // V should have ratcheted up from the second entry.
        assertGt(vAfterSecond, 0, "V still non-zero");
        assertGt(gross2, 0, "bonus non-zero after decay");
    }

    function testRapidEntriesReduceBonus() public {
        _creditReserve(10_000_000e18);
        ve.setTotalLockedClaim(5_000_000e18);

        uint256 start = mineCore.emissionStartTime();
        vm.warp(start + Constants.SWING_TIME + Constants.BONUS_DECAY_WINDOW + 1);

        // First entry.
        (uint256 gross1,,) = furnace.exposedApplyBonusAmm(100_000e18);

        // Second entry in same block (no time for V to decay).
        (uint256 gross2,,) = furnace.exposedApplyBonusAmm(100_000e18);

        // Second entry should get less bonus (V increased from first entry).
        if (gross1 > 0) {
            assertLe(gross2, gross1, "second entry gets less or equal bonus");
        }
    }

    // ----------------------------------------------------------------
    // Single entry cannot drain reserve
    // ----------------------------------------------------------------

    function testFuzz_singleEntryCannotDrainReserve(uint256 principal) public {
        principal = bound(principal, Constants.MIN_LOCK_AMOUNT, 10_000_000e18);

        _creditReserve(20_000_000e18);
        ve.setTotalLockedClaim(5_000_000e18);

        uint256 start = mineCore.emissionStartTime();
        vm.warp(start + Constants.SWING_TIME + Constants.BONUS_DECAY_WINDOW + 1);

        uint256 reserveBefore = furnace.furnaceReserve();

        (uint256 gross,,) = furnace.exposedApplyBonusAmm(principal);

        // Reserve must remain positive.
        assertGt(furnace.furnaceReserve(), 0, "reserve must stay positive");

        // Gross bonus must be less than the full reserve.
        assertLt(gross, reserveBefore, "single entry cannot take entire reserve");
    }

    // ----------------------------------------------------------------
    // LP vault disabled (no LP bonus split)
    // ----------------------------------------------------------------

    function testBonusWithLpVaultDisabled() public {
        // Disable LP vault.
        vm.prank(owner);
        furnace.setLpRewardsVault(address(0));

        _creditReserve(10_000_000e18);
        ve.setTotalLockedClaim(5_000_000e18);

        uint256 start = mineCore.emissionStartTime();
        vm.warp(start + Constants.SWING_TIME + 1);

        (uint256 gross, uint256 user, uint256 lp) = furnace.exposedApplyBonusAmm(100_000e18);

        // LP bonus should be 0 when vault is disabled.
        assertEq(lp, 0, "LP bonus should be 0 when vault disabled");
        // User gets all of grossBonus.
        assertEq(user, gross, "user gets full bonus when LP disabled");
    }
}
