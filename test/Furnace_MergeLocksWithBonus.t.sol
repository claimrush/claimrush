// SPDX-License-Identifier: MIT
pragma solidity ^0.8.34;

import {Test} from "forge-std/Test.sol";

import {ClaimToken} from "src/ClaimToken.sol";
import {MineCore} from "src/MineCore.sol";
import {ShareholderRoyalties} from "src/ShareholderRoyalties.sol";
import {FurnaceQuoter} from "src/FurnaceQuoter.sol";
import {Constants} from "src/lib/Constants.sol";
import {DelegationPermissions} from "src/lib/DelegationPermissions.sol";
import {Errors} from "src/lib/Errors.sol";
import {Events} from "src/lib/Events.sol";

import {FurnaceHarness} from "./mocks/FurnaceHarness.sol";
import {MockContract} from "./mocks/MockContract.sol";
import {MockEntryTokenRegistry} from "./mocks/MockEntryTokenRegistry.sol";
import {MockLpRewardsVault} from "./mocks/MockLpRewardsVault.sol";
import {VeClaimNFTHarness} from "./mocks/VeClaimNFTHarness.sol";

import {DelegationHub} from "src/DelegationHub.sol";

/// @title Furnace.mergeLocksWithBonus / mergeLocksWithBonusFor — v1.0.0 launch tests
/// @notice In v1.0.0 the raw `VeClaimNFT.mergeLocks{,ForUser}` externals are removed;
///         all merges flow through `Furnace.mergeLocksWithBonus{,For}`. Furnace runs
///         pre-validation in `FurnaceGuardHelper.resolveMergeWithBonus` (ownership,
///         listed/expired), pays an extension-style bonus on the duration delta via
///         `_applyBonusAmm`, deposits it into the surviving lock via
///         `_approveVeAndAddToLock`, then defers the lock-math to the Furnace-only
///         sibling `VeClaimNFT.mergeLocksFor`. Mixed AutoMax / non-AutoMax pairs
///         succeed: the survivor's AutoMax flag is `from.autoMax || into.autoMax`
///         (OR-rule from `_mergeLocksInternal`) and the bonus is paid on the
///         non-AutoMax side at the full `BPS_AT_MAX` weight delta.
///
/// @dev    Scenarios cover the four bonus regimes (from-shorter, into-shorter,
///         equal, AutoMax mixes), the slippage gate, the delegation gate,
///         listed/expired/paused reverts, and the reserve-zero edge.
contract FurnaceMergeLocksWithBonusTest is Test {
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
    address internal delegate = address(0xDE1E);
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

    // ──────────────────────────────────────────────────────────────
    //  Helpers
    // ──────────────────────────────────────────────────────────────

    function _seedReserve(uint256 amount) internal {
        if (amount == 0) return;
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

    // ──────────────────────────────────────────────────────────────
    //  From-shorter, into-longer (canonical bonus regime)
    // ──────────────────────────────────────────────────────────────

    /// @dev `from(30d, X)` merged into `into(365d, Y)`. The shorter side gains
    ///      ~`(weight(365d) - weight(30d))` of effective duration, so the bonus
    ///      AMM yields a strictly positive `bonusClaim`. Surviving lock holds
    ///      `X + Y + bonus` and inherits the longer end. The burned `from`
    ///      lock is no longer ownable.
    function test_FromShorter_BonusPositive_PrincipalAndEndCorrect() public {
        _seedReserve(10_000_000e18);
        vm.warp(block.timestamp + 1);

        uint256 fromAmt = 50_000e18;
        uint256 intoAmt = 100_000e18;
        uint256 fromTokenId = _createLock(alice, fromAmt, 30 days, false);
        uint256 intoTokenId = _createLock(alice, intoAmt, 365 days, false);
        (, uint256 longerEndBefore,,) = ve.getLockInfo(intoTokenId);

        vm.warp(block.timestamp + 1);

        // Reserve-delta bound integration check (merge-bonus-bound invariant from
        // `Furnace_ReserveAccounting_Invariants.applyBonus`): the user-facing
        // `bonusClaim` must never exceed the reserve drop produced by the same
        // merge call. Any divergence here would imply `_applyBonusAmm` mis-split
        // gross into a user share larger than the gross AMM payout.
        uint256 reserveBefore = furnace.furnaceReserve();
        vm.prank(alice);
        uint256 bonus = furnace.mergeLocksWithBonus(fromTokenId, intoTokenId, 0);
        uint256 reserveAfter = furnace.furnaceReserve();

        assertGt(bonus, 0, "bonus should be > 0 when shorter side extends to longer");
        assertLe(bonus, reserveBefore - reserveAfter, "bonusClaim must be <= reserveBefore - reserveAfter");

        (uint256 mergedAmt, uint256 mergedEnd, bool mergedAuto, bool mergedListed) = ve.getLockInfo(intoTokenId);
        assertEq(mergedAmt, fromAmt + intoAmt + bonus, "into = X + Y + bonus");
        assertEq(mergedEnd, longerEndBefore, "into end stays at longer's end");
        assertFalse(mergedAuto, "into stays non-auto");
        assertFalse(mergedListed, "into stays unlisted");

        vm.expectRevert();
        ve.ownerOf(fromTokenId);
    }

    // ──────────────────────────────────────────────────────────────
    //  From-longer, into-shorter (reverse direction)
    // ──────────────────────────────────────────────────────────────

    /// @dev `from(365d, X)` merged into `into(30d, Y)`. The shorter side is
    ///      now `into`, but the surviving lock is still `into` — its end is
    ///      bumped up to `from`'s end and its principal absorbs `X` plus
    ///      bonus on the shorter (Y) side's effective extension.
    function test_IntoShorter_BonusPositive_IntoEndExtendsToLonger() public {
        _seedReserve(10_000_000e18);
        vm.warp(block.timestamp + 1);

        uint256 fromAmt = 100_000e18;
        uint256 intoAmt = 60_000e18;
        uint256 fromTokenId = _createLock(alice, fromAmt, 365 days, false);
        uint256 intoTokenId = _createLock(alice, intoAmt, 30 days, false);
        (, uint256 longerEndBefore,,) = ve.getLockInfo(fromTokenId);

        vm.warp(block.timestamp + 1);

        vm.prank(alice);
        uint256 bonus = furnace.mergeLocksWithBonus(fromTokenId, intoTokenId, 0);

        assertGt(bonus, 0, "bonus > 0 when into is shorter");

        (uint256 mergedAmt, uint256 mergedEnd,,) = ve.getLockInfo(intoTokenId);
        assertEq(mergedAmt, fromAmt + intoAmt + bonus, "into = X + Y + bonus");
        assertEq(mergedEnd, longerEndBefore, "into end == longer's end");

        vm.expectRevert();
        ve.ownerOf(fromTokenId);
    }

    // ──────────────────────────────────────────────────────────────
    //  Equal duration, both non-AutoMax (no bonus, merge ok)
    // ──────────────────────────────────────────────────────────────

    /// @dev Equal remaining duration → `durationDelta = 0` →
    ///      `principalEff = 0` → bonus = 0. Merge still succeeds; surviving
    ///      lock holds `X + Y` (no bonus) and end stays at the shared end.
    function test_EqualDuration_BonusZero_PrincipalConserved() public {
        _seedReserve(10_000_000e18);
        vm.warp(block.timestamp + 1);

        uint256 fromAmt = 40_000e18;
        uint256 intoAmt = 40_000e18;
        uint256 fromTokenId = _createLock(alice, fromAmt, 180 days, false);
        uint256 intoTokenId = _createLock(alice, intoAmt, 180 days, false);
        (, uint256 endBefore,,) = ve.getLockInfo(intoTokenId);

        vm.prank(alice);
        uint256 bonus = furnace.mergeLocksWithBonus(fromTokenId, intoTokenId, 0);

        assertEq(bonus, 0, "no duration delta -> no bonus");

        (uint256 mergedAmt, uint256 mergedEnd,,) = ve.getLockInfo(intoTokenId);
        assertEq(mergedAmt, fromAmt + intoAmt, "into = X + Y, no bonus");
        assertEq(mergedEnd, endBefore, "end unchanged");
    }

    // ──────────────────────────────────────────────────────────────
    //  Sub-MIN_TOPUP user-side dust (skip + reserve refund)
    // ──────────────────────────────────────────────────────────────

    /// @notice Tiny `durationDelta` on small principals can produce a non-zero `userBonus`
    ///         that is below `Constants.MIN_TOPUP_AMOUNT` (1 CLAIM). The wrapping
    ///         `_addToLock` would revert with `MinLockAmountNotMet`; Furnace's delegatecall
    ///         wrapper would surface that as `InvariantViolation`. Symmetric with
    ///         `Furnace._extendWithBonus`, the merge body refunds the dust to
    ///         `furnaceReserve` so the AMM debit (`reserveBefore - grossBonus`) stays
    ///         balanced against actual CLAIM held by Furnace, then completes the merge.
    function test_SubMinTopupBonus_Skips_ReserveRefunded_MergeSucceeds() public {
        _seedReserve(10_000_000e18);
        vm.warp(block.timestamp + 1);

        // Smallest legal locks + 60-second duration delta. The 30d→90d weight segment
        // has a slope of ~19,290 sub-bp units per second, so a 60s gap on
        // `MIN_LOCK_AMOUNT` (1,000 CLAIM) principals produces `principalEff` on the
        // order of 10^9 wei and a `userBonus` orders of magnitude below
        // `MIN_TOPUP_AMOUNT` (1 CLAIM = 1e18 wei).
        uint256 fromAmt = Constants.MIN_LOCK_AMOUNT;
        uint256 intoAmt = Constants.MIN_LOCK_AMOUNT;
        uint256 fromTokenId = _createLock(alice, fromAmt, 30 days, false);
        // `into` is the longer side by exactly 60 seconds so `durationDelta = 60s` and
        // the shorter (`from`) side gets the bonus on the merge.
        uint256 intoTokenId = _createLock(alice, intoAmt, 30 days + 60, false);
        (, uint256 longerEndBefore,,) = ve.getLockInfo(intoTokenId);

        uint256 furnaceBalBefore = claim.balanceOf(address(furnace));
        uint256 reserveBefore = furnace.furnaceReserve();
        uint256 lpLiabilityBefore = furnace.exposedLpRewardsVaultLiability();

        // Merge MUST NOT revert.
        vm.prank(alice);
        uint256 paidBonus = furnace.mergeLocksWithBonus(fromTokenId, intoTokenId, 0);

        // The AMM may have produced 0 < userBonus < MIN_TOPUP_AMOUNT or simply 0; both
        // resolve to a no-op user payout because the body sets `userBonus = 0` before
        // assigning `bonusClaim` on the skip branch.
        assertLt(paidBonus, Constants.MIN_TOPUP_AMOUNT, "non-skip path would have paid >= 1 CLAIM");

        (uint256 mergedAmt, uint256 mergedEnd,, bool mergedListed) = ve.getLockInfo(intoTokenId);
        assertEq(mergedAmt, fromAmt + intoAmt + paidBonus, "into = X + Y + paidBonus (paidBonus = 0 on skip)");
        assertEq(mergedEnd, longerEndBefore, "into end stays at the longer end");
        assertFalse(mergedListed, "into stays unlisted");
        vm.expectRevert();
        ve.ownerOf(fromTokenId);

        // Solvency invariant: balance >= furnaceReserve + lpRewardsVault liability.
        // Without the dust refund, reserve would have been debited by `grossBonus`
        // while only `lpBonus` of that became LP-side liability, leaving `userBonus` of
        // unbacked obligation. With the refund, residual slack equals the LP stream's
        // pre-call carry — bounded above by the LP liability delta.
        uint256 reserveAfter = furnace.furnaceReserve();
        uint256 lpLiabilityAfter = furnace.exposedLpRewardsVaultLiability();
        uint256 furnaceBalAfter = claim.balanceOf(address(furnace));

        assertEq(furnaceBalAfter, furnaceBalBefore, "Furnace CLAIM balance untouched on skip path");
        assertGe(furnaceBalAfter, reserveAfter + lpLiabilityAfter, "solvency: balance covers reserve + LP liability");

        // Reserve net delta == LP-side accrual (everything debited from reserve became
        // either LP liability or was refunded back as dust). Equivalent to "no
        // user-side leakage past the AMM split".
        uint256 lpDelta = lpLiabilityAfter - lpLiabilityBefore;
        uint256 reserveDelta = reserveBefore - reserveAfter;
        assertEq(reserveDelta, lpDelta, "reserve drop equals LP liability rise (no user leak)");
    }

    // ──────────────────────────────────────────────────────────────
    //  Both AutoMax (no bonus, AutoMax preserved)
    // ──────────────────────────────────────────────────────────────

    /// @dev AutoMax → `remaining = MAX_LOCK_DURATION` for both sides →
    ///      `durationDelta = 0` → bonus = 0. Surviving lock retains AutoMax.
    function test_BothAutoMax_BonusZero_AutoMaxPreserved() public {
        _seedReserve(10_000_000e18);
        vm.warp(block.timestamp + 1);

        uint256 fromAmt = 75_000e18;
        uint256 intoAmt = 25_000e18;
        uint256 fromTokenId = _createLock(alice, fromAmt, 365 days, true);
        uint256 intoTokenId = _createLock(alice, intoAmt, 365 days, true);

        vm.prank(alice);
        uint256 bonus = furnace.mergeLocksWithBonus(fromTokenId, intoTokenId, 0);

        assertEq(bonus, 0, "both AutoMax -> no duration delta -> no bonus");

        (uint256 mergedAmt,, bool mergedAuto,) = ve.getLockInfo(intoTokenId);
        assertTrue(mergedAuto, "AutoMax preserved on survivor");
        assertEq(mergedAmt, fromAmt + intoAmt, "into = X + Y");
    }

    // ──────────────────────────────────────────────────────────────
    //  Mixed AutoMax / non-AutoMax (succeed, OR-rule)
    // ──────────────────────────────────────────────────────────────

    /// @dev v1.0.0: mixed AutoMax / non-AutoMax merges are accepted.
    ///      `_mergeLocksInternal` resolves the survivor's `autoMax` via OR-rule
    ///      (`from.autoMax || into.autoMax`) and `lockEnd` to
    ///      `block.timestamp + MAX_LOCK_DURATION` whenever the survivor is
    ///      AutoMax. The bonus is paid on the non-AutoMax side's principal at
    ///      the full `BPS_AT_MAX − weightBps(remaining)` weight delta. AutoMax
    ///      is reversible by the user, so no perpetual lock-in concern.
    function test_FromAuto_IntoNonAuto_Succeeds_SurvivorAutoMax_BonusOnIntoSide() public {
        _seedReserve(10_000_000e18);
        vm.warp(block.timestamp + 1);

        uint256 fromAmt = 50_000e18;
        uint256 intoAmt = 60_000e18;
        uint256 fromTokenId = _createLock(alice, fromAmt, 365 days, true);
        uint256 intoTokenId = _createLock(alice, intoAmt, 30 days, false);

        uint256 reserveBefore = furnace.furnaceReserve();
        vm.warp(block.timestamp + 1);

        vm.prank(alice);
        uint256 bonus = furnace.mergeLocksWithBonus(fromTokenId, intoTokenId, 0);
        uint256 reserveAfter = furnace.furnaceReserve();

        assertGt(bonus, 0, "non-AutoMax (into) side gets bonus on full BPS_AT_MAX weight delta");
        assertLe(bonus, reserveBefore - reserveAfter, "bonusClaim must be <= reserve drop");

        (uint256 mergedAmt, uint256 mergedEnd, bool mergedAuto, bool mergedListed) = ve.getLockInfo(intoTokenId);
        assertTrue(mergedAuto, "OR-rule: survivor is AutoMax when either side is AutoMax");
        assertEq(
            mergedEnd,
            block.timestamp + Constants.MAX_LOCK_DURATION,
            "AutoMax survivor: lockEnd == now + MAX_LOCK_DURATION"
        );
        assertEq(mergedAmt, fromAmt + intoAmt + bonus, "into = X + Y + bonus");
        assertFalse(mergedListed, "into stays unlisted");

        vm.expectRevert();
        ve.ownerOf(fromTokenId);
    }

    function test_FromNonAuto_IntoAuto_Succeeds_SurvivorAutoMax_BonusOnFromSide() public {
        _seedReserve(10_000_000e18);
        vm.warp(block.timestamp + 1);

        uint256 fromAmt = 60_000e18;
        uint256 intoAmt = 50_000e18;
        uint256 fromTokenId = _createLock(alice, fromAmt, 30 days, false);
        uint256 intoTokenId = _createLock(alice, intoAmt, 365 days, true);

        uint256 reserveBefore = furnace.furnaceReserve();
        vm.warp(block.timestamp + 1);

        vm.prank(alice);
        uint256 bonus = furnace.mergeLocksWithBonus(fromTokenId, intoTokenId, 0);
        uint256 reserveAfter = furnace.furnaceReserve();

        assertGt(bonus, 0, "non-AutoMax (from) side gets bonus on full BPS_AT_MAX weight delta");
        assertLe(bonus, reserveBefore - reserveAfter, "bonusClaim must be <= reserve drop");

        (uint256 mergedAmt, uint256 mergedEnd, bool mergedAuto, bool mergedListed) = ve.getLockInfo(intoTokenId);
        assertTrue(mergedAuto, "OR-rule: survivor is AutoMax (into-side already was)");
        assertEq(
            mergedEnd,
            block.timestamp + Constants.MAX_LOCK_DURATION,
            "AutoMax survivor: lockEnd == now + MAX_LOCK_DURATION"
        );
        assertEq(mergedAmt, fromAmt + intoAmt + bonus, "into = X + Y + bonus");
        assertFalse(mergedListed, "into stays unlisted");

        vm.expectRevert();
        ve.ownerOf(fromTokenId);
    }

    // ──────────────────────────────────────────────────────────────
    //  Slippage gate (minBonusOut over-quotes -> revert)
    // ──────────────────────────────────────────────────────────────

    /// @dev `minBonusOut > bonusClaim` reverts with `MinVeOutNotMet` (shared
    ///      with `extendWithBonus`). `minBonusOut = 0` opts out of the guard.
    function test_SlippageGate_TooHigh_Reverts() public {
        _seedReserve(10_000_000e18);
        vm.warp(block.timestamp + 1);

        uint256 fromTokenId = _createLock(alice, 50_000e18, 30 days, false);
        uint256 intoTokenId = _createLock(alice, 50_000e18, 365 days, false);

        vm.warp(block.timestamp + 1);

        vm.prank(alice);
        vm.expectRevert(Errors.MinVeOutNotMet.selector);
        furnace.mergeLocksWithBonus(fromTokenId, intoTokenId, type(uint256).max);
    }

    // ──────────────────────────────────────────────────────────────
    //  Same tokenId reverts (NotAuthorized)
    // ──────────────────────────────────────────────────────────────

    /// @dev `fromTokenId == intoTokenId` is rejected by the helper before any
    ///      ownership/state lookups (`Errors.NotAuthorized`).
    function test_SameTokenId_Reverts() public {
        _seedReserve(10_000_000e18);
        vm.warp(block.timestamp + 1);

        uint256 tokenId = _createLock(alice, 50_000e18, 30 days, false);

        vm.prank(alice);
        vm.expectRevert(Errors.NotAuthorized.selector);
        furnace.mergeLocksWithBonus(tokenId, tokenId, 0);
    }

    // ──────────────────────────────────────────────────────────────
    //  Listed-lock reverts (source + destination)
    // ──────────────────────────────────────────────────────────────

    function test_ListedSource_Reverts() public {
        _seedReserve(10_000_000e18);
        vm.warp(block.timestamp + 1);

        uint256 fromTokenId = _createLock(alice, 50_000e18, 30 days, false);
        uint256 intoTokenId = _createLock(alice, 50_000e18, 365 days, false);

        vm.prank(mineMarket);
        ve.setListed(fromTokenId, true);

        vm.prank(alice);
        vm.expectRevert(Errors.LockListedOrFrozen.selector);
        furnace.mergeLocksWithBonus(fromTokenId, intoTokenId, 0);
    }

    function test_ListedDestination_Reverts() public {
        _seedReserve(10_000_000e18);
        vm.warp(block.timestamp + 1);

        uint256 fromTokenId = _createLock(alice, 50_000e18, 30 days, false);
        uint256 intoTokenId = _createLock(alice, 50_000e18, 365 days, false);

        vm.prank(mineMarket);
        ve.setListed(intoTokenId, true);

        vm.prank(alice);
        vm.expectRevert(Errors.LockListedOrFrozen.selector);
        furnace.mergeLocksWithBonus(fromTokenId, intoTokenId, 0);
    }

    // ──────────────────────────────────────────────────────────────
    //  Expired source reverts
    // ──────────────────────────────────────────────────────────────

    function test_ExpiredSource_Reverts() public {
        _seedReserve(10_000_000e18);
        vm.warp(block.timestamp + 1);

        uint256 fromTokenId = _createLock(alice, 50_000e18, Constants.MIN_LOCK_DURATION, false);
        uint256 intoTokenId = _createLock(alice, 50_000e18, 365 days, false);

        vm.warp(block.timestamp + Constants.MIN_LOCK_DURATION + 1);

        vm.prank(alice);
        vm.expectRevert(Errors.LockExpired.selector);
        furnace.mergeLocksWithBonus(fromTokenId, intoTokenId, 0);
    }

    // ──────────────────────────────────────────────────────────────
    //  Locking paused reverts (whenLockingEnabled)
    // ──────────────────────────────────────────────────────────────

    function test_LockingPaused_Reverts() public {
        _seedReserve(10_000_000e18);
        vm.warp(block.timestamp + 1);

        uint256 fromTokenId = _createLock(alice, 50_000e18, 30 days, false);
        uint256 intoTokenId = _createLock(alice, 50_000e18, 365 days, false);

        vm.prank(address(mineCore));
        furnace.setLockingPaused(true);

        vm.prank(alice);
        vm.expectRevert(Errors.LockingPaused.selector);
        furnace.mergeLocksWithBonus(fromTokenId, intoTokenId, 0);
    }

    // ──────────────────────────────────────────────────────────────
    //  Non-owner caller reverts (NotAuthorized)
    // ──────────────────────────────────────────────────────────────

    /// @dev If the merge submitter does not own both locks, the helper's
    ///      `tokenOwner != user` guard fires (`Errors.NotAuthorized`). This
    ///      is the same gate the delegated `_For` variant relies on after
    ///      `_requireDelegated` confirms `user` is the canonical recipient.
    function test_NonOwnerCaller_Reverts() public {
        _seedReserve(10_000_000e18);
        vm.warp(block.timestamp + 1);

        uint256 fromTokenId = _createLock(alice, 50_000e18, 30 days, false);
        uint256 intoTokenId = _createLock(alice, 50_000e18, 365 days, false);

        vm.prank(bob);
        vm.expectRevert(Errors.NotAuthorized.selector);
        furnace.mergeLocksWithBonus(fromTokenId, intoTokenId, 0);
    }

    // ──────────────────────────────────────────────────────────────
    //  Reserve-zero edge (bonus=0, merge still succeeds)
    // ──────────────────────────────────────────────────────────────

    /// @dev With an empty Furnace reserve the bonus AMM yields 0 gross. The
    ///      merge must still complete; the surviving lock holds exactly
    ///      `X + Y` and `FurnaceMergeWithBonus` is emitted with `bonusClaim = 0`.
    function test_ReserveZero_BonusZero_MergeSucceeds_EventEmitted() public {
        // Skip _seedReserve — Furnace starts at 0.
        vm.warp(block.timestamp + 1);

        uint256 fromAmt = 25_000e18;
        uint256 intoAmt = 75_000e18;
        uint256 fromTokenId = _createLock(alice, fromAmt, 30 days, false);
        uint256 intoTokenId = _createLock(alice, intoAmt, 365 days, false);
        (, uint256 longerEndBefore,,) = ve.getLockInfo(intoTokenId);

        vm.warp(block.timestamp + 1);

        // Verify the canonical event topology — pin user/from/into in the indexed
        // topics; non-indexed body is checked structurally via `getLockInfo`
        // assertions below to keep the test resilient to AMM-internal precision.
        vm.expectEmit(true, true, true, false, address(furnace));
        emit Events.FurnaceMergeWithBonus(
            alice, fromTokenId, intoTokenId, fromAmt, intoAmt, fromAmt + intoAmt, longerEndBefore, false, 0, 0
        );

        vm.prank(alice);
        uint256 bonus = furnace.mergeLocksWithBonus(fromTokenId, intoTokenId, 0);

        assertEq(bonus, 0, "empty reserve -> bonus 0");

        (uint256 mergedAmt, uint256 mergedEnd,,) = ve.getLockInfo(intoTokenId);
        assertEq(mergedAmt, fromAmt + intoAmt, "principal conserved exactly");
        assertEq(mergedEnd, longerEndBefore, "end == longer's end");

        vm.expectRevert();
        ve.ownerOf(fromTokenId);
    }

    // ──────────────────────────────────────────────────────────────
    //  Delegated merge succeeds with P_VE_MERGE_LOCKS_FOR
    // ──────────────────────────────────────────────────────────────

    /// @dev `mergeLocksWithBonusFor` accepts a delegated session bearing
    ///      `P_VE_MERGE_LOCKS_FOR`. Bonus + merged principal stay with `user`;
    ///      the delegate cannot redirect value.
    function test_Delegated_Succeeds_BonusToUser() public {
        _seedReserve(10_000_000e18);
        vm.warp(block.timestamp + 1);

        uint256 fromTokenId = _createLock(alice, 50_000e18, 30 days, false);
        uint256 intoTokenId = _createLock(alice, 50_000e18, 365 days, false);

        vm.prank(alice);
        delegationHub.setSession(delegate, DelegationPermissions.P_VE_MERGE_LOCKS_FOR, uint64(block.timestamp + 1 days));

        vm.warp(block.timestamp + 1);

        vm.prank(delegate);
        uint256 bonus = furnace.mergeLocksWithBonusFor(alice, fromTokenId, intoTokenId, 0);

        assertGt(bonus, 0, "delegate triggers bonus on user's locks");

        (uint256 mergedAmt,,,) = ve.getLockInfo(intoTokenId);
        assertEq(mergedAmt, 50_000e18 + 50_000e18 + bonus, "principal+bonus accrue to user's surviving lock");
        assertEq(ve.ownerOf(intoTokenId), alice, "ownership stays with user, not delegate");
    }

    // ──────────────────────────────────────────────────────────────
    //  Delegated merge without session reverts
    // ──────────────────────────────────────────────────────────────

    /// @dev No active session → `_requireDelegated` reverts `NotAuthorized`
    ///      before the merge math runs. The same selector also covers the
    ///      "wrong-permission-bit" case (e.g. extend-only session without
    ///      P_VE_MERGE_LOCKS_FOR), since the hub treats both as unauthorized.
    function test_Delegated_NoSession_Reverts() public {
        _seedReserve(10_000_000e18);
        vm.warp(block.timestamp + 1);

        uint256 fromTokenId = _createLock(alice, 50_000e18, 30 days, false);
        uint256 intoTokenId = _createLock(alice, 50_000e18, 365 days, false);

        vm.prank(delegate);
        vm.expectRevert(Errors.NotAuthorized.selector);
        furnace.mergeLocksWithBonusFor(alice, fromTokenId, intoTokenId, 0);
    }

    // ──────────────────────────────────────────────────────────────
    //  Post-freeze self-call merge succeeds (intentional NOT-frozen gating)
    // ──────────────────────────────────────────────────────────────

    /// @dev `mergeLocksWithBonus` is gated by `whenLockingEnabled` (emergency
    ///      pause), NOT by `whenNotFrozen` (permanent config-freeze). This
    ///      test asserts the positive invariant: a frozen Furnace must still
    ///      service user merges.
    function test_PostFreeze_SelfCall_Succeeds() public {
        _seedReserve(10_000_000e18);
        vm.warp(block.timestamp + 1);

        uint256 fromAmt = 50_000e18;
        uint256 intoAmt = 100_000e18;
        uint256 fromTokenId = _createLock(alice, fromAmt, 30 days, false);
        uint256 intoTokenId = _createLock(alice, intoAmt, 365 days, false);

        // Freeze ALL Furnace owner-only configuration. Subsequent owner
        // setter calls would now revert `Frozen()`. User paths must keep
        // functioning across this boundary.
        vm.prank(owner);
        furnace.freezeConfig();
        assertTrue(furnace.configFrozen(), "freezeConfig must flip the flag");

        vm.warp(block.timestamp + 1);

        vm.prank(alice);
        uint256 bonus = furnace.mergeLocksWithBonus(fromTokenId, intoTokenId, 0);

        assertGt(bonus, 0, "post-freeze merge must still pay a bonus on duration delta");

        (uint256 mergedAmt,,,) = ve.getLockInfo(intoTokenId);
        assertEq(mergedAmt, fromAmt + intoAmt + bonus, "post-freeze merge principal = X + Y + bonus");

        vm.expectRevert();
        ve.ownerOf(fromTokenId);
    }

    // ──────────────────────────────────────────────────────────────
    //  Post-freeze delegated merge still services delegated session
    // ──────────────────────────────────────────────────────────────

    /// @dev The delegated `For` variant inherits the same `whenLockingEnabled`
    ///      gating; freezing config must not silently revoke active
    ///      `P_VE_MERGE_LOCKS_FOR` sessions.
    function test_PostFreeze_Delegated_Succeeds() public {
        _seedReserve(10_000_000e18);
        vm.warp(block.timestamp + 1);

        uint256 fromTokenId = _createLock(alice, 50_000e18, 30 days, false);
        uint256 intoTokenId = _createLock(alice, 50_000e18, 365 days, false);

        vm.prank(alice);
        delegationHub.setSession(delegate, DelegationPermissions.P_VE_MERGE_LOCKS_FOR, uint64(block.timestamp + 1 days));

        vm.prank(owner);
        furnace.freezeConfig();
        assertTrue(furnace.configFrozen(), "freezeConfig must flip the flag");

        vm.warp(block.timestamp + 1);

        vm.prank(delegate);
        uint256 bonus = furnace.mergeLocksWithBonusFor(alice, fromTokenId, intoTokenId, 0);

        assertGt(bonus, 0, "post-freeze delegated merge must still pay a bonus");

        (uint256 mergedAmt,,,) = ve.getLockInfo(intoTokenId);
        assertEq(mergedAmt, 50_000e18 + 50_000e18 + bonus, "post-freeze delegated merge: principal+bonus to user");
        assertEq(ve.ownerOf(intoTokenId), alice, "ownership stays with user post-freeze");
    }
}
