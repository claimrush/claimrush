// SPDX-License-Identifier: MIT
pragma solidity ^0.8.34;

import {Test} from "forge-std/Test.sol";

import {LpStakingVault7D} from "src/vault/LpStakingVault7D.sol";
import {Constants} from "src/lib/Constants.sol";

import {MockERC20} from "./mocks/MockERC20.sol";
import {MockAerodromePool} from "./mocks/MockAerodromePool.sol";
import {MockAerodromeRouter} from "./mocks/MockAerodromeRouter.sol";
import {MockFurnaceLpRewards} from "./mocks/MockFurnaceLpRewards.sol";
import {MockVe} from "./mocks/MockVe.sol";

/// @title LpStakingVault7D wei-exact preview-vs-execute parity (item #10 from the
///         pre-mainnet readiness assessment).
/// @notice Two preview surfaces are exposed to the front-end:
///           1. `earned(user)` -- "you can claim X CLAIM right now"
///           2. `previewHarvestFeesToRewards()` -- keeper preview of the
///               WETH-fee-to-CLAIM swap output before it lands on the vault
///         For both, this suite asserts that what the user/keeper sees in the
///         preview is EXACTLY what the protocol pays out at execution time
///         (or, in the case of `earned()`, after a `claimRewards()` call). A
///         single-sample point check exists in `LpStakingVault7D.t.sol`; this
///         file adds wide fuzz coverage so we cannot be surprised by a
///         pathological staker mix, queue carry pattern, or fee top-up.
contract LpStakingVault7DPreviewParityTest is Test {
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
    address internal carol = address(0xCA201);

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
        // Test contract is the harvest keeper for the harvest-parity scenarios.
        vault.setHarvestKeeper(address(this), true);
    }

    // -----------------------------------------------------------------------
    // earned() == claimRewards() payout (wei-exact)
    // -----------------------------------------------------------------------

    /// @notice Single staker, single notify -- the simplest preview-equals-payout shape.
    function testFuzz_earnedEqualsClaimPayout_singleStaker(uint128 stakeAmt_, uint96 rewardAmt_) public {
        uint256 stakeAmt = bound(uint256(stakeAmt_), Constants.MIN_UNBOND_AMOUNT, 1_000_000e18);
        uint256 rewardAmt = bound(uint256(rewardAmt_), 0, 10_000_000e18);

        _stake(alice, stakeAmt);
        _notify(rewardAmt);

        uint256 quoted = vault.earned(alice);
        uint256 balBefore = claim.balanceOf(alice);

        vm.prank(alice);
        vault.claimRewards();

        uint256 paid = claim.balanceOf(alice) - balBefore;
        assertEq(paid, quoted, "earned() preview must equal actual claimRewards payout (wei-exact)");
        assertEq(vault.earned(alice), 0, "earned() must drop to 0 after a clean claim");
    }

    /// @notice Two stakers, two notify cycles, claim by each in different orders.
    ///         Verifies that the queue/carry path doesn't leak more than the
    ///         documented 1-wei rounding tolerance.
    /// @dev    Per `LpStakingVault7D.earned()` natspec, the view "closely
    ///         matches" -- not "exactly equals" -- the actual claim payout
    ///         when multiple stakers split a queued amount, because
    ///         `_indexRewardsWithCarry` floor-rounds and the residual is
    ///         carried into the next notify via `queuedRewards`. The bound
    ///         we enforce is +/- 1 wei per notify cycle each staker shared
    ///         (one floor-divide per cycle): two notifies => +/- 2 wei.
    ///         A drift larger than this is a real bug.
    function testFuzz_earnedEqualsClaimPayout_twoStakers(
        uint128 aliceStake_,
        uint128 bobStake_,
        uint96 firstNotify_,
        uint96 secondNotify_,
        bool aliceFirst
    ) public {
        uint256 aliceStake = bound(uint256(aliceStake_), Constants.MIN_UNBOND_AMOUNT, 100_000e18);
        uint256 bobStake = bound(uint256(bobStake_), Constants.MIN_UNBOND_AMOUNT, 100_000e18);
        uint256 firstNotify = bound(uint256(firstNotify_), 0, 1_000_000e18);
        uint256 secondNotify = bound(uint256(secondNotify_), 0, 1_000_000e18);

        _stake(alice, aliceStake);
        _stake(bob, bobStake);

        _notify(firstNotify);
        // Some elapsed time between notifies to prove time-independence of the carry.
        vm.warp(block.timestamp + 7 days);
        _notify(secondNotify);

        uint256 aliceQuote = vault.earned(alice);
        uint256 bobQuote = vault.earned(bob);

        // Tolerance = 2 wei (one floor-rounding residual per notify, summed).
        if (aliceFirst) {
            _assertClaimMatchesQuoteWithinTolerance(alice, aliceQuote, 2);
            _assertClaimMatchesQuoteWithinTolerance(bob, bobQuote, 2);
        } else {
            _assertClaimMatchesQuoteWithinTolerance(bob, bobQuote, 2);
            _assertClaimMatchesQuoteWithinTolerance(alice, aliceQuote, 2);
        }

        // Total payout cannot exceed the CLAIM the vault was funded with
        // (no double-credit). Equality is not guaranteed because of indexer
        // floor-rounding carry; the residual stays in `queuedRewards` for the
        // next notify and IS visible via `earned()` on the next cycle.
        uint256 paid = (claim.balanceOf(alice) + claim.balanceOf(bob));
        assertLe(paid, firstNotify + secondNotify, "total paid must not exceed total funded");
    }

    /// @notice Three stakers with very different stake sizes -- exercises the
    ///         per-staker `_earnedWithRpt(user, rpt)` proportional split.
    function testFuzz_earnedEqualsClaimPayout_threeStakers(
        uint128 aliceStake_,
        uint128 bobStake_,
        uint128 carolStake_,
        uint96 notify_
    ) public {
        uint256 aliceStake = bound(uint256(aliceStake_), Constants.MIN_UNBOND_AMOUNT, 50_000e18);
        uint256 bobStake = bound(uint256(bobStake_), Constants.MIN_UNBOND_AMOUNT, 50_000e18);
        uint256 carolStake = bound(uint256(carolStake_), Constants.MIN_UNBOND_AMOUNT, 50_000e18);
        uint256 notify = bound(uint256(notify_), 1e15, 1_000_000e18);

        _stake(alice, aliceStake);
        _stake(bob, bobStake);
        _stake(carol, carolStake);
        _notify(notify);

        // Same +/- 1 wei tolerance as the two-staker case (documented carry).
        _assertClaimMatchesQuoteWithinTolerance(alice, vault.earned(alice), 1);
        _assertClaimMatchesQuoteWithinTolerance(bob, vault.earned(bob), 1);
        _assertClaimMatchesQuoteWithinTolerance(carol, vault.earned(carol), 1);
    }

    /// @notice Late-staker scenario: alice stakes, notify, bob stakes, claim.
    ///         Verifies bob's `earned()` correctly reports 0 and stays 0.
    function testFuzz_lateStakerEarnedAndClaimAreZero(uint128 aliceStake_, uint96 notify_, uint128 bobStake_) public {
        uint256 aliceStake = bound(uint256(aliceStake_), Constants.MIN_UNBOND_AMOUNT, 100_000e18);
        uint256 bobStake = bound(uint256(bobStake_), Constants.MIN_UNBOND_AMOUNT, 100_000e18);
        uint256 notify = bound(uint256(notify_), 1e15, 1_000_000e18);

        _stake(alice, aliceStake);
        _notify(notify);
        _stake(bob, bobStake);

        assertEq(vault.earned(bob), 0, "late staker must not earn from prior notify");

        uint256 bobBefore = claim.balanceOf(bob);
        vm.prank(bob);
        vault.claimRewards();
        assertEq(claim.balanceOf(bob), bobBefore, "late staker claim must be a no-op (wei-exact)");
    }

    /// @notice Stake-shrink + notify sequence: a staker who unbonds part of
    ///         their stake AFTER a notify must receive exactly what
    ///         `earned()` reports immediately before the claim. This is the
    ///         user-facing "preview must equal payout" guarantee for the
    ///         common stake-shrink-then-claim flow.
    /// @dev    `beginUnbond` calls `_checkpointPendingRewardsBeforeStakeChange`
    ///         + `_updateReward(msg.sender)`, which credits any pending share
    ///         to `rewards[msg.sender]` BEFORE the stake decreases. The
    ///         post-unbond `earned()` therefore reflects the locked-in share
    ///         that `claimRewards` will pay out (wei-exact for a single
    ///         staker, +/- 1 wei when other stakers share the queue).
    function testFuzz_earnedEqualsClaimPayout_stakerUnbondsBeforeClaim(
        uint128 aliceStake_,
        uint128 bobStake_,
        uint96 notify_
    ) public {
        uint256 aliceStake = bound(uint256(aliceStake_), Constants.MIN_UNBOND_AMOUNT * 2, 100_000e18);
        uint256 bobStake = bound(uint256(bobStake_), Constants.MIN_UNBOND_AMOUNT, 100_000e18);
        uint256 notify = bound(uint256(notify_), 1e15, 1_000_000e18);

        _stake(alice, aliceStake);
        _stake(bob, bobStake);
        _notify(notify);

        // Alice begins to unbond half her stake -- this internally calls
        // _updateReward(alice), locking in her accrued share.
        vm.prank(alice);
        vault.beginUnbond(aliceStake / 2);

        // Snapshot earned() AT THE TIME the user clicks "claim" -- the moment
        // that matters for the "you will receive X" frontend promise.
        uint256 aliceQuoteAfterUnbond = vault.earned(alice);
        _assertClaimMatchesQuoteWithinTolerance(alice, aliceQuoteAfterUnbond, 1);
    }

    // -----------------------------------------------------------------------
    // previewHarvestFeesToRewards() vs harvestFeesToRewards() actual outcome
    // -----------------------------------------------------------------------

    /// @notice The preview's `expectedClaimOut` MUST equal the CLAIM amount
    ///         that lands as accrued reward after the swap, when the router
    ///         executes at the previewed rate. Any drift is a frontend lie.
    function testFuzz_previewExpectedClaimOutEqualsActualReward(uint96 feeWeth_, uint64 rateX18_) public {
        uint256 feeWeth = bound(uint256(feeWeth_), 1e15, 100e18);
        uint256 rateX18 = bound(uint256(rateX18_), 1e15, 1_000_000e18);

        // Seed a single staker so accountedRewardBalance can update.
        _stake(alice, Constants.MIN_UNBOND_AMOUNT);

        // Drop fee-WETH onto the vault (no fee-CLAIM, by mock-pool default).
        weth.mint(address(vault), feeWeth);
        router.setRateX18(rateX18);

        (uint256 pvFeeWeth, uint256 pvFeeClaim, uint256 pvExpected) = vault.previewHarvestFeesToRewards();

        assertEq(pvFeeWeth, feeWeth, "preview must surface the exact WETH balance");
        assertEq(pvFeeClaim, 0, "preview cannot observe pool-side fee CLAIM (no claimFees in view)");

        uint256 totalCreditedBefore = vault.totalClaimRewardsFundedFromVaultFees();

        // Strictest possible slippage floor -- if preview is wrong, harvest reverts.
        // This is exactly what a keeper that trusts the preview would do.
        vault.harvestFeesToRewards(block.timestamp + 1, pvExpected);

        uint256 actualSwapped = vault.totalClaimRewardsFundedFromVaultFees() - totalCreditedBefore;
        assertEq(actualSwapped, pvExpected, "preview expectedClaimOut must equal actual rewards credited");
    }

    /// @notice A subsequent earned() preview by the staker MUST equal the
    ///         exact claimRewards payout. Combines the harvest preview with
    ///         the earned() preview to chain wei-exact parity end-to-end.
    function testFuzz_previewHarvestThenEarnedThenClaimAreAllConsistent(uint96 feeWeth_, uint64 rateX18_) public {
        uint256 feeWeth = bound(uint256(feeWeth_), 1e15, 100e18);
        uint256 rateX18 = bound(uint256(rateX18_), 1e16, 100e18);

        _stake(alice, Constants.MIN_UNBOND_AMOUNT);
        weth.mint(address(vault), feeWeth);
        router.setRateX18(rateX18);

        (,, uint256 pvExpected) = vault.previewHarvestFeesToRewards();
        vault.harvestFeesToRewards(block.timestamp + 1, pvExpected);

        // Single staker holds 100% so earned == swapped fees.
        uint256 quoted = vault.earned(alice);
        assertEq(quoted, pvExpected, "earned() must equal previewed expectedClaimOut for sole staker");

        uint256 balBefore = claim.balanceOf(alice);
        vm.prank(alice);
        vault.claimRewards();
        assertEq(claim.balanceOf(alice) - balBefore, pvExpected, "claim payout must equal preview");
    }

    // -----------------------------------------------------------------------
    // Internals
    // -----------------------------------------------------------------------

    function _stake(address user, uint256 amt) internal {
        lp.mint(user, amt);
        vm.startPrank(user);
        lp.approve(address(vault), amt);
        vault.stake(amt);
        vm.stopPrank();
    }

    function _notify(uint256 amount) internal {
        if (amount == 0) return;
        claim.mint(address(vault), amount);
        vm.prank(address(furnace));
        vault.notifyRewards(amount);
    }

    function _assertClaimMatchesQuote(address user, uint256 quoted) internal {
        uint256 before = claim.balanceOf(user);
        vm.prank(user);
        vault.claimRewards();
        assertEq(claim.balanceOf(user) - before, quoted, "earned() preview must equal actual claim payout");
    }

    function _assertClaimMatchesQuoteWithinTolerance(address user, uint256 quoted, uint256 tolerance) internal {
        uint256 before = claim.balanceOf(user);
        vm.prank(user);
        vault.claimRewards();
        uint256 paid = claim.balanceOf(user) - before;
        uint256 diff = quoted > paid ? quoted - paid : paid - quoted;
        assertLe(diff, tolerance, "earned() preview must equal actual claim payout (within tolerance wei)");
    }
}
