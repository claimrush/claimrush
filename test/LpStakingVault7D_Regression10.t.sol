// SPDX-License-Identifier: MIT
pragma solidity ^0.8.34;

import {Test} from "forge-std/Test.sol";

import {LpStakingVault7D} from "src/vault/LpStakingVault7D.sol";
import {Constants} from "src/lib/Constants.sol";
import {Errors} from "src/lib/Errors.sol";
import {Events} from "src/lib/Events.sol";

import {MockERC20} from "./mocks/MockERC20.sol";
import {MockAerodromePool} from "./mocks/MockAerodromePool.sol";
import {MockAerodromeRouter} from "./mocks/MockAerodromeRouter.sol";
import {MockFurnaceLpRewards} from "./mocks/MockFurnaceLpRewards.sol";
import {MockVe} from "./mocks/MockVe.sol";

/// @title Regression tests for LpStakingVault7D edge cases.
contract LpStakingVault7D_Regression10Test is Test {
    MockAerodromePool internal lp;
    MockERC20 internal weth;
    MockERC20 internal claim;
    MockFurnaceLpRewards internal furnace;
    MockVe internal ve;
    MockAerodromeRouter internal router;
    LpStakingVault7D internal vault;

    address internal factory = address(0xFACA);
    address internal alice = address(0xA11CE);
    address internal bob = address(0xB0B);
    address internal keeper = address(0xBEEF);

    function setUp() public {
        weth = new MockERC20("WETH", "WETH");
        claim = new MockERC20("CLAIM", "CLAIM");
        lp = new MockAerodromePool(address(weth), address(claim));
        ve = new MockVe();
        router = new MockAerodromeRouter(factory, address(weth));
        router.setPoolFor(address(weth), address(claim), false, factory, address(lp));
        furnace = new MockFurnaceLpRewards(address(claim), address(ve));

        vault = new LpStakingVault7D(
            address(lp),
            address(weth),
            address(claim),
            address(ve),
            address(furnace),
            address(router),
            factory,
            false,
            address(this)
        );

        vault.setHarvestKeeper(keeper, true);
    }

    function _stakeAs(address user, uint256 amount) internal {
        lp.mint(user, amount);
        vm.startPrank(user);
        lp.approve(address(vault), type(uint256).max);
        vault.stake(amount);
        vm.stopPrank();
    }

    function _fundRewards(uint256 amount) internal {
        claim.mint(address(vault), amount);
        vm.prank(address(furnace));
        vault.notifyRewards(amount);
    }

    // ═══════════════════════════════════════════════════════════════════
    // rewardPerTokenStored overflow at minimum stake with large rewards
    // ═══════════════════════════════════════════════════════════════════

    /// @dev At MIN_UNBOND_AMOUNT (1e15) staked with a massive single reward notification,
    ///      the rptIncrement is enormous. Verify the overflow check catches it before wrapping.
    ///      Uses the minimum allowed stake so the overflow boundary matches live staking constraints.
    function test_rewardIndexOverflow_minStakedMassiveReward() public {
        _stakeAs(alice, Constants.MIN_UNBOND_AMOUNT); // 1e15 LP (smallest allowed stake)

        // Fund enough rewards to blow past type(uint128).max in rptIncrement.
        // rptIncrement = amount * ACC / staked = amount * 1e18 / 1e15 = amount * 1e3
        // type(uint128).max ~ 3.4e38. So amount > 3.4e38 / 1e3 = 3.4e35.
        // Use 1e36 CLAIM to reliably trigger overflow.
        uint256 hugeReward = 1e36;
        claim.mint(address(vault), hugeReward);

        vm.prank(address(furnace));
        vm.expectRevert(Errors.RewardIndexOverflow.selector);
        vault.notifyRewards(hugeReward);
    }

    /// @dev With a moderate stake, the same reward should not overflow.
    function test_rewardIndexNoOverflow_normalStake() public {
        _stakeAs(alice, 100e18);

        uint256 reward = 1e21;
        claim.mint(address(vault), reward);

        // Should not revert.
        vm.prank(address(furnace));
        vault.notifyRewards(reward);

        assertGt(vault.earned(alice), 0);
    }

    // ═══════════════════════════════════════════════════════════════════
    // minHarvestClaimFloor blocks harvests when set too high
    // ═══════════════════════════════════════════════════════════════════

    function test_minHarvestClaimFloor_blocksHarvestWhenTooHigh() public {
        _stakeAs(alice, 100e18);

        // Owner sets the floor to its hard MAX — still unreachable by a 1e18-value swap.
        // (The setter is bounded at MAX_MIN_HARVEST_CLAIM_FLOOR = 100_000e18.)
        vault.setMinHarvestClaimFloor(vault.MAX_MIN_HARVEST_CLAIM_FLOOR());

        // Seed fees.
        lp.setNextFees(1e18, 0);
        router.setRateX18(1e18);

        // Harvest should revert because minClaimOut can never satisfy the floor.
        vm.expectRevert(LpStakingVault7D.MinClaimFloorNotMet.selector);
        vault.harvestFeesToRewards(block.timestamp + 1, 1e18);
    }

    function test_minHarvestClaimFloor_succeedsWhenFloorReset() public {
        _stakeAs(alice, 100e18);

        // Set floor to MAX (highest value the setter accepts), then reset to zero.
        vault.setMinHarvestClaimFloor(vault.MAX_MIN_HARVEST_CLAIM_FLOOR());
        vault.setMinHarvestClaimFloor(0);

        lp.setNextFees(1e18, 0);
        router.setRateX18(1e18);

        // Should succeed now.
        vault.harvestFeesToRewards(block.timestamp + 1, 0.99e18);
        assertGt(vault.earned(alice), 0);
    }

    // ═══════════════════════════════════════════════════════════════════
    // Harvest: claimFees() reverts but harvest continues with pre-existing WETH
    // ═══════════════════════════════════════════════════════════════════

    function test_harvestContinuesWhenClaimFeesReverts() public {
        _stakeAs(alice, 100e18);

        // Pre-seed WETH directly into the vault (simulating a prior failed swap leftover).
        weth.mint(address(vault), 2e18);

        // Make claimFees revert.
        lp.setRevertOnClaimFees(true);
        router.setRateX18(1e18);

        // Harvest should still process the pre-existing WETH.
        vault.harvestFeesToRewards(block.timestamp + 1, 1.98e18);

        // Alice should earn from the swapped WETH (minus bounty).
        assertGt(vault.earned(alice), 0);
    }

    // ═══════════════════════════════════════════════════════════════════
    // Harvest: MinClaimOutRequired enforced when WETH is swapped
    // ═══════════════════════════════════════════════════════════════════

    function test_harvestRevertsMinClaimOutRequired() public {
        _stakeAs(alice, 100e18);

        lp.setNextFees(1e18, 0);
        router.setRateX18(1e18);

        // minClaimOut = 0 when WETH > 0 should revert.
        vm.expectRevert(LpStakingVault7D.MinClaimOutRequired.selector);
        vault.harvestFeesToRewards(block.timestamp + 1, 0);
    }

    // ═══════════════════════════════════════════════════════════════════
    // Harvest: CallerQuoteDivergence enforced
    // ═══════════════════════════════════════════════════════════════════

    function test_harvestRevertsCallerQuoteDivergence() public {
        _stakeAs(alice, 100e18);

        lp.setNextFees(10e18, 0);
        router.setRateX18(1e18); // quote: 10e18 CLAIM out for ~10e18 WETH in

        // On-chain floor = 10e18 * 99% = 9.9e18
        // Caller divergence check: minClaimOut < floor * 90% = 9.9e18 * 90% = 8.91e18
        // Pass minClaimOut = 1e18, which is far below the 90% threshold.
        vm.expectRevert(LpStakingVault7D.CallerQuoteDivergence.selector);
        vault.harvestFeesToRewards(block.timestamp + 1, 1e18);
    }

    // ═══════════════════════════════════════════════════════════════════
    // Harvest: deadline validation
    // ═══════════════════════════════════════════════════════════════════

    function test_harvestRevertsDeadlineTooFar() public {
        _stakeAs(alice, 100e18);
        lp.setNextFees(1e18, 0);

        // Deadline more than MAX_HARVEST_DEADLINE in the future.
        vm.expectRevert(LpStakingVault7D.DeadlineTooFar.selector);
        vault.harvestFeesToRewards(block.timestamp + 11 minutes, 1e18);
    }

    function test_harvestRevertsDeadlineInPast() public {
        _stakeAs(alice, 100e18);
        lp.setNextFees(1e18, 0);

        vm.warp(100);
        vm.expectRevert(LpStakingVault7D.DeadlineTooFar.selector);
        vault.harvestFeesToRewards(99, 1e18);
    }

    // ═══════════════════════════════════════════════════════════════════
    // Unbond: residual rounding forces full unbond
    // ═══════════════════════════════════════════════════════════════════

    function test_unbondResidualRoundsUpToFull() public {
        uint256 stakeAmt = Constants.MIN_UNBOND_AMOUNT + 1; // e.g. 1e15 + 1
        _stakeAs(alice, stakeAmt);

        // Unbond MIN_UNBOND_AMOUNT, leaving residual = 1 wei (< MIN_UNBOND_AMOUNT).
        // Contract should round up to full unbond.
        vm.prank(alice);
        vault.beginUnbond(Constants.MIN_UNBOND_AMOUNT);

        assertEq(vault.stakedBalance(alice), 0, "residual should have been rounded up to full unbond");

        // Verify unbond entry has the full amount.
        (, uint256 unbondAmt,) = vault.getUnbondByIndex(alice, 0);
        assertEq(unbondAmt, stakeAmt, "unbond entry should contain the full staked amount");
    }

    function test_unbondExactMinDoesNotRoundUp() public {
        uint256 stakeAmt = Constants.MIN_UNBOND_AMOUNT * 2;
        _stakeAs(alice, stakeAmt);

        // Unbond exactly half — residual = MIN_UNBOND_AMOUNT, which is NOT below threshold.
        vm.prank(alice);
        vault.beginUnbond(Constants.MIN_UNBOND_AMOUNT);

        assertEq(vault.stakedBalance(alice), Constants.MIN_UNBOND_AMOUNT, "residual at MIN should not round up");
    }

    // ═══════════════════════════════════════════════════════════════════
    // Queued rewards: two stakers same block — first captures, second gets nothing from queue
    // ═══════════════════════════════════════════════════════════════════

    function test_queuedRewards_firstStakerCaptures_secondGetsNothing() public {
        // Queue 500 CLAIM while nobody is staked.
        claim.mint(address(vault), 500e18);
        vm.prank(address(furnace));
        vault.notifyRewards(0);
        assertEq(vault.queuedRewards(), 500e18);

        // Alice stakes first (same block) — captures all queued.
        _stakeAs(alice, 100e18);
        assertEq(vault.queuedRewards(), 0);
        assertEq(vault.earned(alice), 500e18);

        // Bob stakes in the same block — gets nothing from the queue.
        _stakeAs(bob, 100e18);
        assertEq(vault.earned(bob), 0);

        // Alice still has 500e18 (her share hasn't diluted because RPT was locked before Bob staked).
        assertEq(vault.earned(alice), 500e18);
    }

    // ═══════════════════════════════════════════════════════════════════
    // compoundForMany: MIN_COMPOUND_INTERVAL enforced per user
    // ═══════════════════════════════════════════════════════════════════

    function test_compoundForMany_respectsMinCompoundInterval() public {
        _stakeAs(alice, 100e18);
        _stakeAs(bob, 100e18);

        uint256 tokenIdAlice = 10;
        uint256 tokenIdBob = 11;

        ve.setOwner(tokenIdAlice, alice);
        ve.setLockInfo(tokenIdAlice, 1, block.timestamp + 60 days, false, false);
        vm.prank(alice);
        vault.setAutoCompoundConfig(true, tokenIdAlice, 30 days, 0, 0);

        ve.setOwner(tokenIdBob, bob);
        ve.setLockInfo(tokenIdBob, 1, block.timestamp + 60 days, false, false);
        vm.prank(bob);
        vault.setAutoCompoundConfig(true, tokenIdBob, 30 days, 0, 0);

        _fundRewards(200e18);

        // First compound — both should succeed.
        vm.warp(block.timestamp + 1 days + 1);

        address[] memory users = new address[](2);
        users[0] = alice;
        users[1] = bob;

        vm.prank(keeper);
        vault.compoundForMany(users, 2);

        // Both rewards consumed.
        assertEq(vault.rewards(alice), 0);
        assertEq(vault.rewards(bob), 0);

        // Fund more rewards.
        _fundRewards(200e18);

        // Try to compound again immediately (within MIN_COMPOUND_INTERVAL).
        vm.prank(keeper);
        vault.compoundForMany(users, 2);

        // Both should be skipped (rewards NOT consumed).
        assertGt(vault.earned(alice), 0, "alice rewards should not be consumed within cooldown");
        assertGt(vault.earned(bob), 0, "bob rewards should not be consumed within cooldown");
    }

    // ═══════════════════════════════════════════════════════════════════
    // Auto-compound: duration clamped to MAX_LOCK_DURATION
    // ═══════════════════════════════════════════════════════════════════

    function test_compoundFor_clampsDurationToMax() public {
        _stakeAs(alice, 100e18);
        _fundRewards(100e18);

        uint256 tokenId = 20;
        // Lock with remaining time far beyond MAX_LOCK_DURATION.
        // MockVe with autoMax=false and a very far lockEnd.
        ve.setOwner(tokenId, alice);
        ve.setLockInfo(tokenId, 1, block.timestamp + 2 * 365 days, false, false);

        // Configure compound with duration = MAX_LOCK_DURATION (valid at config time).
        vm.prank(alice);
        vault.setAutoCompoundConfig(true, tokenId, Constants.MAX_LOCK_DURATION, 0, 0);

        vm.warp(block.timestamp + 1 days + 1);
        vm.prank(keeper);
        vault.compoundFor(alice);

        // Furnace should have been called with effectiveDurationSeconds clamped to MAX_LOCK_DURATION.
        assertEq(furnace.lastDurationSeconds(), Constants.MAX_LOCK_DURATION);
    }

    // ═══════════════════════════════════════════════════════════════════
    // Fuzz: _indexRewardsWithCarry remainder is always non-negative
    // ═══════════════════════════════════════════════════════════════════

    /// @dev For any (amount, staked) pair, earned never exceeds funded (no over-distribution).
    ///      Note: earned() view simulates distributing queuedRewards, so checking
    ///      earned + queuedRewards would double-count. The correct invariant is earned <= funded.
    function testFuzz_indexRewardsWithCarry_neverOverDistributes(uint128 stakeAmt, uint96 rewardAmt) public {
        vm.assume(stakeAmt >= Constants.MIN_UNBOND_AMOUNT);
        vm.assume(rewardAmt > 0);

        _stakeAs(alice, uint256(stakeAmt));

        claim.mint(address(vault), uint256(rewardAmt));
        vm.prank(address(furnace));
        // If rewardPerTokenStored would overflow, the vault reverts. That's fine — skip.
        try vault.notifyRewards(uint256(rewardAmt)) {}
        catch {
            return;
        }

        uint256 earned = vault.earned(alice);

        assertLe(earned, uint256(rewardAmt), "earned must never exceed funded amount");
    }

    /// @dev Edge: staked amount exactly equals reward amount.
    function testFuzz_indexRewardsWithCarry_equalStakeAndReward(uint96 amount) public {
        vm.assume(amount >= Constants.MIN_UNBOND_AMOUNT);

        _stakeAs(alice, uint256(amount));

        claim.mint(address(vault), uint256(amount));
        vm.prank(address(furnace));
        try vault.notifyRewards(uint256(amount)) {}
        catch {
            return;
        }

        uint256 earned = vault.earned(alice);
        uint256 queued = vault.queuedRewards();

        // Total accounted must equal total funded.
        assertEq(earned + queued, uint256(amount), "earned + queued must equal funded");
    }

    // ═══════════════════════════════════════════════════════════════════
    // accountedRewardBalance invariant: always <= claim.balanceOf(vault)
    // ═══════════════════════════════════════════════════════════════════

    function test_accountedRewardBalance_neverExceedsBalance() public {
        _stakeAs(alice, 100e18);

        // Fund rewards.
        _fundRewards(1000e18);

        assertLe(
            vault.accountedRewardBalance(),
            claim.balanceOf(address(vault)),
            "accounted must not exceed balance after notify"
        );

        // Claim some rewards.
        vm.prank(alice);
        vault.claimRewards();

        assertLe(
            vault.accountedRewardBalance(),
            claim.balanceOf(address(vault)),
            "accounted must not exceed balance after claim"
        );

        // Donate extra CLAIM (unaccounted).
        claim.mint(address(vault), 500e18);

        assertLe(
            vault.accountedRewardBalance(),
            claim.balanceOf(address(vault)),
            "accounted must not exceed balance after donation"
        );

        // Checkpoint via a second stake.
        _stakeAs(bob, 50e18);

        assertLe(
            vault.accountedRewardBalance(),
            claim.balanceOf(address(vault)),
            "accounted must not exceed balance after checkpoint"
        );
    }

    // ═══════════════════════════════════════════════════════════════════
    // LP token invariant: lpToken.balanceOf(vault) >= totalStaked + unbonds
    // ═══════════════════════════════════════════════════════════════════

    function test_lpTokenInvariant_balanceCoversStakedAndUnbonds() public {
        _stakeAs(alice, 100e18);
        _stakeAs(bob, 50e18);

        // Alice unbonds half.
        vm.prank(alice);
        vault.beginUnbond(50e18);

        uint256 totalUnbondAmount = 50e18;
        uint256 totalStaked = vault.totalStaked(); // 100 (bob 50 + alice remaining 50)

        assertGe(
            lp.balanceOf(address(vault)), totalStaked + totalUnbondAmount, "LP balance must cover staked + unbonding"
        );

        // Withdraw matured.
        vm.warp(block.timestamp + Constants.UNBONDING_PERIOD);
        vm.prank(alice);
        vault.withdrawMatured();

        assertGe(lp.balanceOf(address(vault)), vault.totalStaked(), "LP balance must cover staked after withdrawal");
    }

    // ═══════════════════════════════════════════════════════════════════
    // renounceOwnership disabled
    // ═══════════════════════════════════════════════════════════════════

    function test_renounceOwnershipReverts() public {
        vm.expectRevert(Errors.NotAuthorized.selector);
        vault.renounceOwnership();
    }
}
