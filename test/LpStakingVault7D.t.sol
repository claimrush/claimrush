// SPDX-License-Identifier: MIT
pragma solidity ^0.8.34;

import {Test} from "forge-std/Test.sol";

import {LpStakingVault7D} from "src/vault/LpStakingVault7D.sol";
import {Constants} from "src/lib/Constants.sol";
import {Errors} from "src/lib/Errors.sol";

import {MockERC20} from "./mocks/MockERC20.sol";
import {MockAerodromePool} from "./mocks/MockAerodromePool.sol";
import {MockAerodromeRouter} from "./mocks/MockAerodromeRouter.sol";
import {MockFurnaceLpRewards} from "./mocks/MockFurnaceLpRewards.sol";
import {MockVe} from "./mocks/MockVe.sol";

contract LpStakingVault7DTest is Test {
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
    }

    function testDeploys() public {
        assertEq(address(vault.lpToken()), address(lp));
        assertEq(address(vault.weth()), address(weth));
        assertEq(address(vault.claim()), address(claim));
        assertEq(address(vault.ve()), address(ve));
        assertEq(vault.furnace(), address(furnace));
        assertEq(vault.aerodromeRouter(), address(router));
        assertEq(vault.aerodromeFactory(), factory);
        assertEq(vault.wethClaimStable(), false);
        assertEq(vault.totalStaked(), 0);
    }

    function testConstructorRevertsWhenLpTokenIsNotCanonicalPool() public {
        MockAerodromePool wrongLp = new MockAerodromePool(address(weth), address(claim));

        vm.expectRevert(Errors.InvalidPool.selector);
        new LpStakingVault7D(
            address(wrongLp),
            address(weth),
            address(claim),
            address(ve),
            address(furnace),
            address(router),
            factory,
            false,
            address(this)
        );
    }

    function testConstructorRevertsWhenCanonicalPoolIsUnset() public {
        MockAerodromeRouter emptyRouter = new MockAerodromeRouter(factory, address(weth));

        vm.expectRevert(Errors.InvalidPool.selector);
        new LpStakingVault7D(
            address(lp),
            address(weth),
            address(claim),
            address(ve),
            address(furnace),
            address(emptyRouter),
            factory,
            false,
            address(this)
        );
    }

    function testConstructorRevertsWhenRouterFactoryDiffers() public {
        router.setDefaultFactory(address(0xBEEF));

        vm.expectRevert(Errors.FactoryMismatch.selector);
        new LpStakingVault7D(
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
    }

    function testConstructorRevertsWhenRouterWethDiffers() public {
        MockERC20 otherWeth = new MockERC20("OTHER", "OWETH");
        router.setWeth(address(otherWeth));

        vm.expectRevert(Errors.WrappedNativeMismatch.selector);
        new LpStakingVault7D(
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
    }

    function testConstructorRevertsWhenStablePoolRequested() public {
        vm.expectRevert(Errors.InvalidPool.selector);
        new LpStakingVault7D(
            address(lp),
            address(weth),
            address(claim),
            address(ve),
            address(furnace),
            address(router),
            factory,
            true,
            address(this)
        );
    }

    function testConstructorRevertsWhenFurnaceClaimRootDiffers() public {
        MockERC20 otherClaim = new MockERC20("OTHER", "OCLAIM");
        MockFurnaceLpRewards wrongFurnace = new MockFurnaceLpRewards(address(otherClaim), address(ve));

        vm.expectRevert(Errors.WiringMismatch.selector);
        new LpStakingVault7D(
            address(lp),
            address(weth),
            address(claim),
            address(ve),
            address(wrongFurnace),
            address(router),
            factory,
            false,
            address(this)
        );
    }

    function testConstructorRevertsWhenFurnaceVeRootDiffers() public {
        MockVe otherVe = new MockVe();
        MockFurnaceLpRewards wrongFurnace = new MockFurnaceLpRewards(address(claim), address(otherVe));

        vm.expectRevert(Errors.WiringMismatch.selector);
        new LpStakingVault7D(
            address(lp),
            address(weth),
            address(claim),
            address(ve),
            address(wrongFurnace),
            address(router),
            factory,
            false,
            address(this)
        );
    }

    function testFuzz_constructorRejectsAnyNonCanonicalPool(address badPool) public {
        vm.assume(badPool != address(0));
        vm.assume(badPool != address(lp));

        vm.expectRevert(Errors.InvalidPool.selector);
        new LpStakingVault7D(
            badPool,
            address(weth),
            address(claim),
            address(ve),
            address(furnace),
            address(router),
            factory,
            false,
            address(this)
        );
    }

    function testFuzz_constructorRejectsAnyFurnaceClaimRootMismatch(address badClaim) public {
        vm.assume(badClaim != address(0));
        vm.assume(badClaim != address(claim));

        MockFurnaceLpRewards wrongFurnace = new MockFurnaceLpRewards(badClaim, address(ve));

        vm.expectRevert(Errors.WiringMismatch.selector);
        new LpStakingVault7D(
            address(lp),
            address(weth),
            address(claim),
            address(ve),
            address(wrongFurnace),
            address(router),
            factory,
            false,
            address(this)
        );
    }

    function testStakeUpdatesAccounting() public {
        uint256 amt = Constants.MIN_UNBOND_AMOUNT;
        lp.mint(alice, amt);

        vm.startPrank(alice);
        lp.approve(address(vault), amt);
        vault.stake(amt);
        vm.stopPrank();

        assertEq(vault.totalStaked(), amt);
        assertEq(vault.stakedBalance(alice), amt);
        assertEq(lp.balanceOf(alice), 0);
        assertEq(lp.balanceOf(address(vault)), amt);
    }

    function testStakeRevertsOnZero() public {
        vm.prank(alice);
        vm.expectRevert(Errors.AmountZero.selector);
        vault.stake(0);
    }

    function testBeginUnbondCreatesEntryAndReducesStake() public {
        lp.mint(alice, 100e18);
        vm.startPrank(alice);
        lp.approve(address(vault), 100e18);
        vault.stake(100e18);
        vault.beginUnbond(40e18);
        vm.stopPrank();

        assertEq(vault.totalStaked(), 60e18);
        assertEq(vault.stakedBalance(alice), 60e18);
        assertEq(vault.getUnbondCount(alice), 1);

        (uint256 id, uint256 amount, uint256 unlockTime) = vault.getUnbondByIndex(alice, 0);
        assertEq(id, 0);
        assertEq(amount, 40e18);
        assertEq(unlockTime, block.timestamp + Constants.UNBONDING_PERIOD);
    }

    function testBeginUnbondRevertsOnInsufficientStake() public {
        lp.mint(alice, 10e18);
        vm.startPrank(alice);
        lp.approve(address(vault), 10e18);
        vault.stake(10e18);
        vm.expectRevert(Errors.InsufficientStake.selector);
        vault.beginUnbond(11e18);
        vm.stopPrank();
    }

    function testWithdrawMaturedTransfersAfterUnlock() public {
        lp.mint(alice, 100e18);
        vm.startPrank(alice);
        lp.approve(address(vault), 100e18);
        vault.stake(100e18);
        vault.beginUnbond(100e18);
        vm.stopPrank();

        // Before unlock: no transfer.
        vm.prank(alice);
        vault.withdrawMatured();
        assertEq(lp.balanceOf(alice), 0);

        // After unlock: withdraw.
        vm.warp(block.timestamp + Constants.UNBONDING_PERIOD);
        vm.prank(alice);
        vault.withdrawMatured();

        assertEq(lp.balanceOf(alice), 100e18);
        assertEq(vault.getUnbondCount(alice), 0);
    }

    function testMaxUnbondsPerUserEnforced() public {
        uint256 perUnbond = Constants.MIN_UNBOND_AMOUNT;
        uint256 totalStake = perUnbond * (Constants.MAX_UNBONDS_PER_USER + 1);
        lp.mint(alice, totalStake);
        vm.startPrank(alice);
        lp.approve(address(vault), type(uint256).max);
        vault.stake(totalStake);

        for (uint256 i = 0; i < Constants.MAX_UNBONDS_PER_USER; i++) {
            vault.beginUnbond(perUnbond);
        }

        vm.expectRevert(Errors.TooManyUnbonds.selector);
        vault.beginUnbond(perUnbond);
        vm.stopPrank();
    }

    function testNotifyRewardsQueuesWhenNoStakers() public {
        claim.mint(address(vault), 1_000e18);

        vm.prank(address(furnace));
        vault.notifyRewards(123);

        assertEq(vault.queuedRewards(), 1_000e18);
        assertEq(vault.rewardPerTokenStored(), 0);
    }

    function testQueuedRewardsDistributedOnFirstStakeAndClaimable() public {
        claim.mint(address(vault), 1_000e18);
        vm.prank(address(furnace));
        vault.notifyRewards(0);

        uint256 stakeAmt = Constants.MIN_UNBOND_AMOUNT;
        lp.mint(alice, stakeAmt);
        vm.startPrank(alice);
        lp.approve(address(vault), stakeAmt);
        vault.stake(stakeAmt);
        vm.stopPrank();

        // With a single staker, all queued rewards are earned by alice.
        assertEq(vault.queuedRewards(), 0);
        assertEq(vault.earned(alice), 1_000e18);

        vm.prank(alice);
        vault.claimRewards();
        assertEq(claim.balanceOf(alice), 1_000e18);
    }

    function testNotifyRewardsDistributesWhenStakersPresent() public {
        uint256 stakeAmt = Constants.MIN_UNBOND_AMOUNT;
        lp.mint(alice, stakeAmt);
        vm.startPrank(alice);
        lp.approve(address(vault), stakeAmt);
        vault.stake(stakeAmt);
        vm.stopPrank();

        claim.mint(address(vault), 500e18);

        vm.prank(address(furnace));
        vault.notifyRewards(123); // ignored

        assertEq(vault.queuedRewards(), 0);
        assertEq(vault.earned(alice), 500e18);
    }

    function testNotifyRewardsCarriesIndexRoundingDustForward() public {
        lp.mint(alice, 1e18);
        lp.mint(bob, 2e18);

        vm.startPrank(alice);
        lp.approve(address(vault), 1e18);
        vault.stake(1e18);
        vm.stopPrank();

        vm.startPrank(bob);
        lp.approve(address(vault), 2e18);
        vault.stake(2e18);
        vm.stopPrank();

        claim.mint(address(vault), 1);
        vm.prank(address(furnace));
        vault.notifyRewards(0);

        assertEq(vault.rewardPerTokenStored(), 0, "sub-index reward should not create phantom rpt");
        assertEq(vault.queuedRewards(), 1, "rounding remainder kept queued");

        claim.mint(address(vault), 2);
        vm.prank(address(furnace));
        vault.notifyRewards(0);

        assertEq(vault.rewardPerTokenStored(), 1, "carried dust becomes claimable once threshold reached");
        assertEq(vault.queuedRewards(), 0, "all dust released once fully indexable");
        assertEq(vault.earned(alice), 1, "alice receives carried dust share");
        assertEq(vault.earned(bob), 2, "bob receives carried dust share");
    }

    function testFirstStakeKeepsQueuedRoundingDustUntilClaimable() public {
        claim.mint(address(vault), 2);
        vm.prank(address(furnace));
        vault.notifyRewards(0);

        assertEq(vault.queuedRewards(), 2, "dust queued while vault has no stakers");

        lp.mint(alice, 3e18);
        vm.startPrank(alice);
        lp.approve(address(vault), 3e18);
        vault.stake(3e18);
        vm.stopPrank();

        assertEq(vault.rewardPerTokenStored(), 0, "first stake should not drop non-indexable dust");
        assertEq(vault.queuedRewards(), 2, "non-indexable queued dust must remain queued");

        claim.mint(address(vault), 1);
        vm.prank(address(furnace));
        vault.notifyRewards(0);

        assertEq(vault.rewardPerTokenStored(), 1, "later rewards release prior queued dust");
        assertEq(vault.queuedRewards(), 0, "all queued dust becomes indexable");
        assertEq(vault.earned(alice), 3, "first staker eventually receives full queued amount");
    }

    function testClaimRewardsCanRecoverRewardsAfterPriorDustOnlyNotify() public {
        lp.mint(alice, 1e18);
        lp.mint(bob, 2e18);

        vm.startPrank(alice);
        lp.approve(address(vault), 1e18);
        vault.stake(1e18);
        vm.stopPrank();

        vm.startPrank(bob);
        lp.approve(address(vault), 2e18);
        vault.stake(2e18);
        vm.stopPrank();

        claim.mint(address(vault), 1);
        vm.prank(address(furnace));
        vault.notifyRewards(0);

        claim.mint(address(vault), 2);
        vm.prank(address(furnace));
        vault.notifyRewards(0);

        vm.prank(bob);
        vault.claimRewards();

        assertEq(claim.balanceOf(bob), 2, "manual claim can withdraw dust carried from earlier notifies");
        assertEq(vault.accountedRewardBalance(), 1, "unclaimed carried share remains accounted for alice");
        assertEq(vault.earned(alice), 1, "alice keeps her remaining carried share");
    }

    function testStakeCheckpointsPendingRewardsBeforeDilutiveStake() public {
        lp.mint(alice, 10e18);
        lp.mint(bob, 10e18);

        vm.startPrank(alice);
        lp.approve(address(vault), 10e18);
        vault.stake(10e18);
        vm.stopPrank();

        // Simulate CLAIM that already arrived in the vault after a prior best-effort notify failure.
        claim.mint(address(vault), 100e18);

        vm.startPrank(bob);
        lp.approve(address(vault), 10e18);
        vault.stake(10e18);
        vm.stopPrank();

        assertEq(vault.rewardPerTokenStored(), 10e18, "pending rewards indexed on old denominator");
        assertEq(vault.earned(alice), 100e18, "existing staker keeps pre-existing rewards");
        assertEq(vault.earned(bob), 0, "late staker cannot capture old rewards");
        assertEq(vault.accountedRewardBalance(), 100e18, "balance delta checkpointed");
    }

    function testFirstStakeStillReceivesPendingRewardsWhenNoOneWasStaked() public {
        claim.mint(address(vault), 100e18);
        lp.mint(alice, 10e18);

        vm.startPrank(alice);
        lp.approve(address(vault), 10e18);
        vault.stake(10e18);
        vm.stopPrank();

        assertEq(vault.queuedRewards(), 0, "queued rewards released on first stake");
        assertEq(vault.rewardPerTokenStored(), 10e18, "first stake picks up pending delta via queue");
        assertEq(vault.earned(alice), 100e18, "sole first staker receives queued pending rewards");
    }

    function testBeginUnbondCheckpointsPendingRewardsBeforeDenominatorShrinks() public {
        lp.mint(alice, 10e18);
        lp.mint(bob, 10e18);

        vm.startPrank(alice);
        lp.approve(address(vault), 10e18);
        vault.stake(10e18);
        vm.stopPrank();

        vm.startPrank(bob);
        lp.approve(address(vault), 10e18);
        vault.stake(10e18);
        vm.stopPrank();

        // Simulate CLAIM that already arrived in the vault after a prior best-effort notify failure.
        claim.mint(address(vault), 100e18);

        vm.prank(alice);
        vault.beginUnbond(10e18);

        assertEq(vault.rewardPerTokenStored(), 5e18, "pending rewards indexed before stake shrinks");
        assertEq(vault.earned(alice), 50e18, "exiting staker keeps accrued share");
        assertEq(vault.earned(bob), 50e18, "remaining staker only receives original pro-rata share");
        assertEq(vault.totalStaked(), 10e18, "unbond still reduces bonded stake after checkpoint");
    }

    function testClaimRewardsCheckpointsPendingRewardsBeforeClaim() public {
        lp.mint(alice, 10e18);

        vm.startPrank(alice);
        lp.approve(address(vault), 10e18);
        vault.stake(10e18);
        vm.stopPrank();

        // Simulate CLAIM that already arrived in the vault after a prior best-effort notify failure.
        claim.mint(address(vault), 100e18);

        vm.prank(alice);
        vault.claimRewards();

        assertEq(vault.rewardPerTokenStored(), 10e18, "pending rewards indexed before manual claim");
        assertEq(claim.balanceOf(alice), 100e18, "manual claimer receives pending rewards immediately");
        assertEq(vault.accountedRewardBalance(), 0, "accounted balance reduced after payout");
    }

    function testClaimRewardsCheckpointsPendingRewardsProRataAcrossExistingStakers() public {
        lp.mint(alice, 10e18);
        lp.mint(bob, 10e18);

        vm.startPrank(alice);
        lp.approve(address(vault), 10e18);
        vault.stake(10e18);
        vm.stopPrank();

        vm.startPrank(bob);
        lp.approve(address(vault), 10e18);
        vault.stake(10e18);
        vm.stopPrank();

        // Simulate CLAIM that already arrived in the vault after a prior best-effort notify failure.
        claim.mint(address(vault), 100e18);

        vm.prank(alice);
        vault.claimRewards();

        assertEq(vault.rewardPerTokenStored(), 5e18, "pending rewards indexed on live denominator");
        assertEq(claim.balanceOf(alice), 50e18, "manual claim receives only caller's pro-rata share");
        assertEq(vault.earned(bob), 50e18, "other stakers keep their pro-rata remainder");
        assertEq(vault.accountedRewardBalance(), 50e18, "unclaimed pro-rata remainder stays accounted");
    }

    function testClaimRewardsAndLockCheckpointsPendingRewardsBeforeLock() public {
        lp.mint(alice, 10e18);

        vm.startPrank(alice);
        lp.approve(address(vault), 10e18);
        vault.stake(10e18);
        vm.stopPrank();

        // Simulate CLAIM that already arrived in the vault after a prior best-effort notify failure.
        claim.mint(address(vault), 100e18);

        furnace.setQuote(100e18, 0, 1, 0);

        vm.warp(block.timestamp + 1 days + 1);
        vm.prank(alice);
        vault.claimRewardsAndLock(0, 30 days, false, 1);

        assertEq(vault.rewardPerTokenStored(), 10e18, "pending rewards indexed before manual lock");
        assertEq(furnace.enterCalls(), 1, "lock path executed");
        assertEq(furnace.lastClaimIn(), 100e18, "manual lock consumes pending rewards immediately");
        assertEq(claim.balanceOf(address(furnace)), 100e18, "pending rewards routed into Furnace");
        assertEq(vault.accountedRewardBalance(), 0, "accounted balance reduced after locking");
    }

    function testNotifyRewardsOnlyFromNotifiers() public {
        claim.mint(address(vault), 1);

        vm.prank(bob);
        vm.expectRevert(Errors.NotRewardNotifier.selector);
        vault.notifyRewards(1);
    }

    function testClaimRewardsAndLockCallsFurnaceAndConsumesClaim() public {
        // Stake.
        uint256 stakeAmt = Constants.MIN_UNBOND_AMOUNT;
        lp.mint(alice, stakeAmt);
        vm.startPrank(alice);
        lp.approve(address(vault), stakeAmt);
        vault.stake(stakeAmt);
        vm.stopPrank();

        // Fund rewards.
        claim.mint(address(vault), 777e18);
        vm.prank(address(furnace));
        vault.notifyRewards(0);

        // Quote output for event fields.
        furnace.setQuote(700e18, 77e18, 1, 0);

        vm.warp(block.timestamp + 1 days + 1);
        vm.prank(alice);
        vault.claimRewardsAndLock(0, 30 days, false, 1);

        assertEq(furnace.enterCalls(), 1);
        assertEq(furnace.lastUser(), alice);
        assertEq(furnace.lastClaimIn(), 777e18);
        assertEq(claim.balanceOf(address(furnace)), 777e18);
        assertEq(claim.balanceOf(address(vault)), 0);
    }

    function testRewardPerTokenVector_FromSpec() public {
        // Spec vector:
        // totalStaked = 100e18, notifyRewards = 1_000e18 -> rewardPerTokenStored = 10e18
        lp.mint(alice, 10e18);
        lp.mint(bob, 90e18);

        vm.startPrank(alice);
        lp.approve(address(vault), 10e18);
        vault.stake(10e18);
        vm.stopPrank();

        vm.startPrank(bob);
        lp.approve(address(vault), 90e18);
        vault.stake(90e18);
        vm.stopPrank();

        claim.mint(address(vault), 1_000e18);
        vm.prank(address(furnace));
        vault.notifyRewards(1_000e18);

        assertEq(vault.rewardPerTokenStored(), 10e18, "rpt");
        assertEq(vault.earned(alice), 100e18, "alice earned");
        assertEq(vault.earned(bob), 900e18, "bob earned");
    }

    function testBeginUnbondStopsEarningOnUnbondedAmount() public {
        // Stake 100, distribute 100, then unbond 40. Subsequent rewards should be earned only on 60.
        lp.mint(alice, 100e18);
        vm.startPrank(alice);
        lp.approve(address(vault), 100e18);
        vault.stake(100e18);
        vm.stopPrank();

        claim.mint(address(vault), 100e18);
        vm.prank(address(furnace));
        vault.notifyRewards(100e18);

        vm.prank(alice);
        vault.beginUnbond(40e18);

        claim.mint(address(vault), 60e18);
        vm.prank(address(furnace));
        vault.notifyRewards(60e18);

        assertEq(vault.rewardPerTokenStored(), 2e18, "rpt after unbond");
        assertEq(vault.earned(alice), 160e18, "earned after unbond");
    }
}
