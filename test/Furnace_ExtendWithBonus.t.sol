// SPDX-License-Identifier: MIT
pragma solidity ^0.8.34;

import {Test} from "forge-std/Test.sol";

import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

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

contract FurnaceExtendWithBonusTest is Test {
    ClaimToken internal claim;
    VeClaimNFTHarness internal ve;
    MineCore internal mineCore;
    FurnaceHarness internal furnace;
    FurnaceQuoter internal furnaceQuoter;
    MockLpRewardsVault internal lpVault;
    ShareholderRoyalties internal royalties;

    address internal owner = address(0xA11CE);
    address internal alice = address(0xA11C3);
    address internal keeper = address(0xBEEF);
    address internal mineMarket;
    address internal registry;
    address internal mineCoreRegistry;
    DelegationHub internal delegationHub;

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

    // ----------------------------------------------------------------
    // extendWithBonus — basic flow
    // ----------------------------------------------------------------

    function testExtendWithBonusBasicFlow() public {
        _seedReserve(10_000_000e18);
        vm.warp(block.timestamp + 1);

        uint256 tokenId = _createLock(alice, 100_000e18, 30 days, false);

        vm.warp(block.timestamp + 1);

        vm.prank(alice);
        uint256 bonus = furnace.extendWithBonus(tokenId, 365 days, 0);

        assertGt(bonus, 0, "should receive a bonus for extending 30d -> 365d");

        (uint256 lockAmount,,,) = ve.getLockInfo(tokenId);
        assertEq(lockAmount, 100_000e18 + bonus, "lock should contain original + bonus");
    }

    function testExtendWithBonusRejectsAutoMax() public {
        _seedReserve(10_000_000e18);
        vm.warp(block.timestamp + 1);

        uint256 tokenId = _createLock(alice, 100_000e18, 365 days, true);

        vm.warp(block.timestamp + 1);

        vm.prank(alice);
        vm.expectRevert(Errors.InvalidDuration.selector);
        furnace.extendWithBonus(tokenId, 365 days, 0);
    }

    function testExtendWithBonusRejectsShorterDuration() public {
        _seedReserve(10_000_000e18);
        vm.warp(block.timestamp + 1);

        uint256 tokenId = _createLock(alice, 100_000e18, 365 days, false);

        vm.warp(block.timestamp + 10 days);

        vm.prank(alice);
        vm.expectRevert(Errors.InvalidDuration.selector);
        furnace.extendWithBonus(tokenId, 30 days, 0);
    }

    function testExtendWithBonusRejectsNonOwner() public {
        _seedReserve(10_000_000e18);
        vm.warp(block.timestamp + 1);

        uint256 tokenId = _createLock(alice, 100_000e18, 30 days, false);

        vm.prank(keeper);
        vm.expectRevert(Errors.NotAuthorized.selector);
        furnace.extendWithBonus(tokenId, 365 days, 0);
    }

    /// @notice Tiny duration deltas can produce a non-zero `userBonus` that is below
    ///         `Constants.MIN_TOPUP_AMOUNT` (1 CLAIM). VeClaimNFT._addToLock would revert with
    ///         `MinLockAmountNotMet()`; Furnace's delegatecall wrapper would surface that as
    ///         `InvariantViolation()`. This test exercises the quiet-skip path: the extension
    ///         must succeed, the user must forfeit the dust, the lock principal must stay flat,
    ///         and the dust must be refunded back to `furnaceReserve` so the AMM debit stays
    ///         balanced against actual CLAIM held by Furnace.
    function testExtendWithBonusSkipsSubMinTopupBonus() public {
        _seedReserve(10_000_000e18);
        vm.warp(block.timestamp + 1);

        // Smallest legal lock + tiny extension so that the user's bonus slice rounds in below
        // MIN_TOPUP_AMOUNT but the AMM still spends something on the LP side.
        uint256 lockAmt = Constants.MIN_LOCK_AMOUNT;
        uint256 tokenId = _createLock(alice, lockAmt, 30 days, false);

        vm.warp(block.timestamp + 1);

        uint256 furnaceBalBefore = claim.balanceOf(address(furnace));

        // Extend by 60s on top of the current ~30d remaining: weight delta is microscopic, so
        // userBonus < 1 CLAIM if it is non-zero at all. Either way, the call MUST NOT revert.
        (, uint256 lockEndBefore,,) = ve.getLockInfo(tokenId);
        uint256 newRemaining = (lockEndBefore - block.timestamp) + 60;

        (, uint256 quotedBonus,) = furnaceQuoter.quoteExtendWithBonus(alice, tokenId, newRemaining);
        assertEq(quotedBonus, 0, "quote must surface actual delivered bonus after sub-min dust skip");

        vm.prank(alice);
        uint256 paidBonus = furnace.extendWithBonus(tokenId, newRemaining, 0);

        // The AMM may have produced 0 < userBonus < MIN_TOPUP_AMOUNT or simply 0; both must
        // resolve to a no-op user payout (the function returns the actual paid amount, which
        // is zero in the skip case because we set userBonus = 0 before assigning bonusClaim).
        assertLt(paidBonus, Constants.MIN_TOPUP_AMOUNT, "non-skipped path would have paid >= 1 CLAIM");

        (uint256 lockAmountAfter,,,) = ve.getLockInfo(tokenId);
        assertEq(lockAmountAfter, lockAmt + paidBonus, "lock principal grew only by paidBonus");

        // Solvency invariant: balance >= furnaceReserve + lpRewardsVault liability. Without the
        // dust refund, reserve would have been debited by `grossBonus` while only `lpBonus` of
        // that became LP-side liability, leaving `userBonus` of unbacked obligation. With the
        // refund, the residual slack must equal what was already in the LP stream pre-call (i.e.
        // zero on a fresh setUp).
        uint256 reserveAfter = furnace.furnaceReserve();
        uint256 lpLiabilityAfter = furnace.exposedLpRewardsVaultLiability();
        uint256 furnaceBalAfter = claim.balanceOf(address(furnace));
        assertEq(furnaceBalAfter, furnaceBalBefore, "Furnace CLAIM balance is untouched on skip path");
        assertGe(furnaceBalAfter, reserveAfter + lpLiabilityAfter, "solvency: balance covers reserve + LP liability");
    }

    function testExtendWithBonusMinBonusGuard() public {
        _seedReserve(10_000_000e18);
        vm.warp(block.timestamp + 1);

        uint256 tokenId = _createLock(alice, 100_000e18, 30 days, false);

        vm.warp(block.timestamp + 1);

        vm.prank(alice);
        vm.expectRevert(Errors.MinVeOutNotMet.selector);
        furnace.extendWithBonus(tokenId, 365 days, type(uint256).max);
    }

    function testExtendWithBonusPathIndependence() public {
        _seedReserve(10_000_000e18);
        vm.warp(block.timestamp + 1);

        // Path A: single extension from 30d to 365d
        uint256 tokenA = _createLock(alice, 100_000e18, 30 days, false);
        vm.warp(block.timestamp + 1);
        vm.prank(alice);
        uint256 bonusA = furnace.extendWithBonus(tokenA, 365 days, 0);

        // Path B: two-step extension from 30d -> 180d -> 365d (different user to not drain AMM)
        address bob = address(0xB0B);
        uint256 tokenB = _createLock(bob, 100_000e18, 30 days, false);
        vm.warp(block.timestamp + 1);
        vm.prank(bob);
        uint256 bonusB1 = furnace.extendWithBonus(tokenB, 180 days, 0);
        vm.warp(block.timestamp + 1);
        vm.prank(bob);
        uint256 bonusB2 = furnace.extendWithBonus(tokenB, 365 days, 0);

        uint256 totalBonusB = bonusB1 + bonusB2;

        // The extend bonus is priced on the fixed user-principal basis, so the two-step path's
        // summed duration-weight delta equals the single-step delta (weight deltas are additive).
        // The concave, state-depleting bonus AMM then makes the split earn slightly LESS than the
        // single extension — never more. The "never more" ceiling is the load-bearing
        // anti-laddering property: fragmenting one commitment into rungs cannot mint excess bonus.
        assertLe(totalBonusB, bonusA + bonusA / 1000, "split path must not out-earn single extension");
        // Sanity floor: a real bonus is still paid across both rungs (not collapsed to ~zero).
        assertGe(totalBonusB, (bonusA * 70) / 100, "split path bonus unexpectedly small vs single extension");
    }

    function testQuoteExtendWithBonusMatchesExecution() public {
        _seedReserve(10_000_000e18);
        vm.warp(block.timestamp + 1);

        uint256 tokenId = _createLock(alice, 100_000e18, 30 days, false);
        vm.warp(block.timestamp + 1);

        (uint256 qAmount, uint256 qBonus, uint256 qNewEnd) =
            furnaceQuoter.quoteExtendWithBonus(alice, tokenId, 365 days);

        assertEq(qAmount, 100_000e18, "quoted lockAmount");
        assertGt(qBonus, 0, "quoted bonus > 0");
        assertGt(qNewEnd, block.timestamp, "new end in future");

        vm.prank(alice);
        uint256 actualBonus = furnace.extendWithBonus(tokenId, 365 days, 0);

        assertEq(actualBonus, qBonus, "actual bonus matches quote");
    }

    // ----------------------------------------------------------------
    // claimAutoMaxBonus — basic flow
    // ----------------------------------------------------------------

    function testClaimAutoMaxBonusInitializesOnFirstCall() public {
        _seedReserve(10_000_000e18);
        vm.warp(block.timestamp + 1);

        uint256 tokenId = _createLock(alice, 100_000e18, 365 days, true);
        assertEq(furnace.lastAutoMaxBonusClaim(tokenId), 0, "should be 0 before init");

        vm.warp(block.timestamp + 1);

        uint256 bonus = furnace.claimAutoMaxBonus(tokenId);
        assertEq(bonus, 0, "first call should return 0");
        assertEq(furnace.lastAutoMaxBonusClaim(tokenId), block.timestamp, "timestamp initialized");
    }

    function testClaimAutoMaxBonusAfter24h() public {
        _seedReserve(10_000_000e18);
        vm.warp(block.timestamp + 1);

        uint256 tokenId = _createLock(alice, 100_000e18, 365 days, true);

        furnace.claimAutoMaxBonus(tokenId);

        vm.warp(block.timestamp + 1 days);

        uint256 bonus = furnace.claimAutoMaxBonus(tokenId);
        assertGt(bonus, 0, "should receive bonus after 24h");

        (uint256 lockAmount,,,) = ve.getLockInfo(tokenId);
        assertEq(lockAmount, 100_000e18 + bonus, "lock grew by bonus");
    }

    function testClaimAutoMaxBonusReturnsZeroBefore24h() public {
        _seedReserve(10_000_000e18);
        vm.warp(block.timestamp + 1);

        uint256 tokenId = _createLock(alice, 100_000e18, 365 days, true);

        furnace.claimAutoMaxBonus(tokenId);

        vm.warp(block.timestamp + 23 hours);

        uint256 bonus = furnace.claimAutoMaxBonus(tokenId);
        assertEq(bonus, 0, "cooldown not elapsed - returns 0");
    }

    function testClaimAutoMaxBonusRejectsNonAutoMax() public {
        _seedReserve(10_000_000e18);
        vm.warp(block.timestamp + 1);

        uint256 tokenId = _createLock(alice, 100_000e18, 365 days, false);

        vm.expectRevert(Errors.InvalidDuration.selector);
        furnace.claimAutoMaxBonus(tokenId);
    }

    function testClaimAutoMaxBonusPermissionless() public {
        _seedReserve(10_000_000e18);
        vm.warp(block.timestamp + 1);

        uint256 tokenId = _createLock(alice, 100_000e18, 365 days, true);

        vm.prank(keeper);
        furnace.claimAutoMaxBonus(tokenId);

        vm.warp(block.timestamp + 1 days);

        vm.prank(keeper);
        uint256 bonus = furnace.claimAutoMaxBonus(tokenId);
        assertGt(bonus, 0, "keeper can trigger automax bonus");

        (uint256 lockAmount,,,) = ve.getLockInfo(tokenId);
        assertEq(lockAmount, 100_000e18 + bonus, "bonus accrued to alice's lock");
    }

    function testClaimAutoMaxBonusAccumulatesOverMultipleDays() public {
        _seedReserve(10_000_000e18);
        vm.warp(block.timestamp + 1);

        uint256 tokenId = _createLock(alice, 100_000e18, 365 days, true);

        furnace.claimAutoMaxBonus(tokenId);

        vm.warp(block.timestamp + 7 days);

        uint256 bonus = furnace.claimAutoMaxBonus(tokenId);
        assertGt(bonus, 0, "7-day accumulated bonus");

        // Compare to single-day claim: 7-day lump should be roughly 7x a 1-day claim
        // (exact due to linear weight region at max duration end, modulo AMM curve)
    }

    function testQuoteAutoMaxBonusMatchesExecution() public {
        _seedReserve(10_000_000e18);
        vm.warp(block.timestamp + 1);

        uint256 tokenId = _createLock(alice, 100_000e18, 365 days, true);

        furnace.claimAutoMaxBonus(tokenId);

        vm.warp(block.timestamp + 1 days);

        (uint256 qAmount, uint256 qBonus) = furnaceQuoter.quoteAutoMaxBonus(tokenId);
        assertEq(qAmount, 100_000e18, "quoted lockAmount");
        assertGt(qBonus, 0, "quoted bonus > 0");

        uint256 actualBonus = furnace.claimAutoMaxBonus(tokenId);
        assertEq(actualBonus, qBonus, "actual matches quote");
    }

    function testQuoteAutoMaxBonusReturnsZeroBeforeInit() public {
        _seedReserve(10_000_000e18);
        vm.warp(block.timestamp + 1);

        uint256 tokenId = _createLock(alice, 100_000e18, 365 days, true);

        (uint256 qAmount, uint256 qBonus) = furnaceQuoter.quoteAutoMaxBonus(tokenId);
        assertEq(qAmount, 100_000e18);
        assertEq(qBonus, 0, "no bonus before initialization");
    }

    function testAutoMaxTopUpDoesNotInheritElapsedWindow() public {
        // enterWithClaim's quote path requires a valid router config in the registry.
        vm.etch(address(0x1234), hex"00");
        vm.etch(address(0x5678), hex"00");
        vm.etch(address(0x9ABC), hex"00");
        MockEntryTokenRegistry(registry)
            .setRouterConfig(address(0x1234), address(0x5678), address(0x9ABC), address(claim));
        _seedReserve(50_000_000e18);
        vm.warp(block.timestamp + 1);

        uint256 tokenId = _createLock(alice, 100_000e18, 365 days, true);

        furnace.claimAutoMaxBonus(tokenId);
        uint256 initializedAt = furnace.lastAutoMaxBonusClaim(tokenId);

        vm.warp(block.timestamp + 7 days);

        uint256 claimIn = 500_000e18;
        vm.prank(address(mineCore));
        claim.mint(alice, claimIn);

        vm.startPrank(alice);
        claim.approve(address(furnace), claimIn);
        (,, uint256 minVeOut, uint256 routeTokenId) =
            furnaceQuoter.quoteEnterWithClaim(alice, claimIn, tokenId, Constants.MAX_LOCK_DURATION, false);
        assertEq(routeTokenId, tokenId, "existing autoMax lock should be reused");
        furnace.enterWithClaim(claimIn, tokenId, Constants.MAX_LOCK_DURATION, false, minVeOut);
        vm.stopPrank();

        assertEq(
            furnace.lastAutoMaxBonusClaim(tokenId),
            initializedAt,
            "lock top-up should not mutate the Furnace claim cursor"
        );

        (uint256 qAmount, uint256 qBonus) = furnaceQuoter.quoteAutoMaxBonus(tokenId);
        assertGt(qAmount, 100_000e18, "top-up increased lock amount");
        assertEq(qBonus, 0, "freshly topped-up principal must not inherit the earlier accrual window");

        uint256 bonusNow = furnace.claimAutoMaxBonus(tokenId);
        assertEq(bonusNow, 0, "immediate claim after top-up must be zero");

        vm.warp(block.timestamp + 1 days);

        (, uint256 qBonusLater) = furnaceQuoter.quoteAutoMaxBonus(tokenId);
        assertGt(qBonusLater, 0, "bonus should accrue again after a fresh day");

        uint256 bonusLater = furnace.claimAutoMaxBonus(tokenId);
        assertEq(bonusLater, qBonusLater, "quote/execution stay aligned after top-up reset");
    }

    function testAutoMaxToggleDoesNotInheritElapsedWindow() public {
        _seedReserve(10_000_000e18);
        vm.warp(block.timestamp + 1);

        uint256 tokenId = _createLock(alice, 100_000e18, 365 days, true);

        furnace.claimAutoMaxBonus(tokenId);
        uint256 initializedAt = furnace.lastAutoMaxBonusClaim(tokenId);

        vm.warp(block.timestamp + 7 days);

        vm.startPrank(alice);
        ve.setAutoMax(tokenId, false);
        ve.setAutoMax(tokenId, true);
        vm.stopPrank();

        assertEq(
            furnace.lastAutoMaxBonusClaim(tokenId),
            initializedAt,
            "autoMax toggle should not mutate the Furnace claim cursor"
        );

        (uint256 qAmount, uint256 qBonus) = furnaceQuoter.quoteAutoMaxBonus(tokenId);
        assertEq(qAmount, 100_000e18, "toggle should not change principal");
        assertEq(qBonus, 0, "re-enabled autoMax lock must start a fresh accrual window");

        uint256 bonusNow = furnace.claimAutoMaxBonus(tokenId);
        assertEq(bonusNow, 0, "immediate claim after toggle must be zero");

        vm.warp(block.timestamp + 1 days);

        (, uint256 qBonusLater) = furnaceQuoter.quoteAutoMaxBonus(tokenId);
        assertGt(qBonusLater, 0, "bonus should accrue again after a fresh day");

        uint256 bonusLater = furnace.claimAutoMaxBonus(tokenId);
        assertEq(bonusLater, qBonusLater, "quote/execution stay aligned after toggle reset");
    }

    // ----------------------------------------------------------------
    // Parity: daily automax bonus ≈ daily manual extension bonus
    // ----------------------------------------------------------------

    function testAutoMaxParityWithDailyExtensions() public {
        _seedReserve(10_000_000e18);
        uint256 ts = block.timestamp + 1;
        vm.warp(ts);

        // AutoMax lock
        uint256 autoMaxToken = _createLock(alice, 100_000e18, 365 days, true);
        furnace.claimAutoMaxBonus(autoMaxToken);

        // Non-AutoMax 365d lock
        address bob = address(0xB0B);
        uint256 manualToken = _createLock(bob, 100_000e18, 365 days, false);

        uint256 totalAutoMaxBonus;
        uint256 totalManualBonus;

        for (uint256 i = 0; i < 7; i++) {
            ts += 1 days;
            vm.warp(ts);

            uint256 autoBonus = furnace.claimAutoMaxBonus(autoMaxToken);
            totalAutoMaxBonus += autoBonus;

            vm.prank(bob);
            uint256 manualBonus = furnace.extendWithBonus(manualToken, 365 days, 0);
            totalManualBonus += manualBonus;
        }

        // Both should be roughly equal (same principal, same incremental weight per day).
        // Allow 10% tolerance for AMM curve effects from different lockAmounts (growing differently).
        uint256 tolerance = totalAutoMaxBonus * 10 / 100;
        assertApproxEqAbs(totalManualBonus, totalAutoMaxBonus, tolerance, "daily extension parity with automax");
    }

    // ----------------------------------------------------------------
    // Event emission
    // ----------------------------------------------------------------

    function testExtendWithBonusEmitsFurnaceEnterEvent() public {
        _seedReserve(10_000_000e18);
        vm.warp(block.timestamp + 1);
        uint256 tokenId = _createLock(alice, 100_000e18, 30 days, false);
        vm.warp(block.timestamp + 1);

        // MODE_EXTEND_WITH_BONUS = 4
        vm.expectEmit(true, false, false, false, address(furnace));
        emit Events.FurnaceEnter(alice, 4, 0, 0, 0, tokenId);

        vm.prank(alice);
        furnace.extendWithBonus(tokenId, 365 days, 0);
    }

    function testClaimAutoMaxBonusEmitsAutoMaxBonusClaimedEvent() public {
        _seedReserve(10_000_000e18);
        vm.warp(block.timestamp + 1);
        uint256 tokenId = _createLock(alice, 100_000e18, 365 days, true);

        furnace.claimAutoMaxBonus(tokenId); // init
        vm.warp(block.timestamp + 1 days);

        vm.expectEmit(true, false, false, false, address(furnace));
        emit Events.AutoMaxBonusClaimed(alice, tokenId, 0);

        furnace.claimAutoMaxBonus(tokenId);
    }

    // ----------------------------------------------------------------
    // Listed lock reverts
    // ----------------------------------------------------------------

    function testExtendWithBonusRevertsWhenListed() public {
        _seedReserve(10_000_000e18);
        vm.warp(block.timestamp + 1);
        uint256 tokenId = _createLock(alice, 100_000e18, 30 days, false);

        vm.prank(mineMarket);
        ve.setListed(tokenId, true);

        vm.prank(alice);
        vm.expectRevert(Errors.LockListedOrFrozen.selector);
        furnace.extendWithBonus(tokenId, 365 days, 0);
    }

    function testClaimAutoMaxBonusRevertsWhenListed() public {
        _seedReserve(10_000_000e18);
        vm.warp(block.timestamp + 1);
        uint256 tokenId = _createLock(alice, 100_000e18, 365 days, true);
        furnace.claimAutoMaxBonus(tokenId);

        vm.prank(mineMarket);
        ve.setListed(tokenId, true);

        vm.warp(block.timestamp + 1 days);
        vm.expectRevert(Errors.LockListedOrFrozen.selector);
        furnace.claimAutoMaxBonus(tokenId);
    }

    // ----------------------------------------------------------------
    // Expired lock reverts
    // ----------------------------------------------------------------

    function testExtendWithBonusRevertsWhenExpired() public {
        _seedReserve(10_000_000e18);
        vm.warp(block.timestamp + 1);
        uint256 tokenId = _createLock(alice, 100_000e18, 30 days, false);

        vm.warp(block.timestamp + 31 days);

        vm.prank(alice);
        vm.expectRevert(Errors.LockExpired.selector);
        furnace.extendWithBonus(tokenId, 365 days, 0);
    }

    function testClaimAutoMaxBonusNeverExpiresWhileAutoMaxActive() public {
        _seedReserve(10_000_000e18);
        vm.warp(block.timestamp + 1);
        uint256 tokenId = _createLock(alice, 100_000e18, 365 days, true);
        furnace.claimAutoMaxBonus(tokenId);

        // AutoMax locks appear perpetual via getLockInfo (effectiveEnd = now + MAX).
        // Even after 2 years, the bonus claim should succeed.
        vm.warp(block.timestamp + 730 days);

        uint256 bonus = furnace.claimAutoMaxBonus(tokenId);
        assertGt(bonus, 0, "automax bonus should work even after long delay");
    }

    // ----------------------------------------------------------------
    // Locking paused reverts
    // ----------------------------------------------------------------

    function testExtendWithBonusRevertsWhenPaused() public {
        _seedReserve(10_000_000e18);
        vm.warp(block.timestamp + 1);
        uint256 tokenId = _createLock(alice, 100_000e18, 30 days, false);

        vm.prank(address(mineCore));
        furnace.setLockingPaused(true);

        vm.prank(alice);
        vm.expectRevert(Errors.LockingPaused.selector);
        furnace.extendWithBonus(tokenId, 365 days, 0);
    }

    function testClaimAutoMaxBonusRevertsWhenPaused() public {
        _seedReserve(10_000_000e18);
        vm.warp(block.timestamp + 1);
        uint256 tokenId = _createLock(alice, 100_000e18, 365 days, true);
        furnace.claimAutoMaxBonus(tokenId);

        vm.warp(block.timestamp + 1 days);

        vm.prank(address(mineCore));
        furnace.setLockingPaused(true);

        vm.expectRevert(Errors.LockingPaused.selector);
        furnace.claimAutoMaxBonus(tokenId);
    }

    // ----------------------------------------------------------------
    // extendWithBonusFor delegation
    // ----------------------------------------------------------------

    function testExtendWithBonusForDelegation() public {
        _seedReserve(10_000_000e18);
        vm.warp(block.timestamp + 1);
        uint256 tokenId = _createLock(alice, 100_000e18, 30 days, false);

        address delegate = address(0xDE1E);
        vm.prank(alice);
        delegationHub.setSession(
            delegate, DelegationPermissions.P_VE_EXTEND_LOCK_FOR, uint64(block.timestamp + 30 days)
        );

        vm.warp(block.timestamp + 1);

        vm.prank(delegate);
        uint256 bonus = furnace.extendWithBonusFor(alice, tokenId, 365 days, 0);

        assertGt(bonus, 0, "delegate should trigger bonus");
        (uint256 lockAmount,,,) = ve.getLockInfo(tokenId);
        assertEq(lockAmount, 100_000e18 + bonus, "lock amount grew");
    }

    function testExtendWithBonusForRejectsUnauthorizedDelegate() public {
        _seedReserve(10_000_000e18);
        vm.warp(block.timestamp + 1);
        uint256 tokenId = _createLock(alice, 100_000e18, 30 days, false);

        address delegate = address(0xDE1E);
        // No session granted

        vm.prank(delegate);
        vm.expectRevert(Errors.NotAuthorized.selector);
        furnace.extendWithBonusFor(alice, tokenId, 365 days, 0);
    }

    // ----------------------------------------------------------------
    // Large elapsed capping for claimAutoMaxBonus
    // ----------------------------------------------------------------

    function testClaimAutoMaxBonusLargeElapsedCapped() public {
        _seedReserve(10_000_000e18);
        vm.warp(block.timestamp + 1);
        uint256 tokenId = _createLock(alice, 100_000e18, 365 days, true);

        furnace.claimAutoMaxBonus(tokenId);

        // Warp 400 days — elapsed > MAX_LOCK_DURATION. Contract caps at MAX_LOCK_DURATION.
        vm.warp(block.timestamp + 400 days);

        uint256 bonus = furnace.claimAutoMaxBonus(tokenId);
        assertGt(bonus, 0, "large-elapsed bonus should still work");
    }

    // ----------------------------------------------------------------
    // Zero bonus emission
    // ----------------------------------------------------------------

    function testClaimAutoMaxBonusFirstCallReturnsZeroNoEvent() public {
        _seedReserve(10_000_000e18);
        vm.warp(block.timestamp + 1);
        uint256 tokenId = _createLock(alice, 100_000e18, 365 days, true);

        // First call initializes the timestamp and returns 0 without emitting.
        uint256 bonus = furnace.claimAutoMaxBonus(tokenId);
        assertEq(bonus, 0, "first call returns 0");
        assertEq(furnace.lastAutoMaxBonusClaim(tokenId), block.timestamp, "timestamp set");
    }

    function testClaimAutoMaxBonusZeroGrossCallDoesNotConsumeAccrualWindow() public {
        uint256 t0 = block.timestamp + 1;
        vm.warp(t0);
        uint256 tokenId = _createLock(alice, 100_000e18, 365 days, true);

        furnace.claimAutoMaxBonus(tokenId); // initialize timestamp
        uint256 initializedAt = t0;

        vm.warp(t0 + 1 days);

        uint256 bonus = furnace.claimAutoMaxBonus(tokenId);
        assertEq(bonus, 0, "empty-reserve claim returns 0");
        assertEq(
            furnace.lastAutoMaxBonusClaim(tokenId),
            initializedAt,
            "zero-gross claim must not burn the accrued cooldown window"
        );

        _seedReserve(10_000_000e18);

        bonus = furnace.claimAutoMaxBonus(tokenId);
        assertGt(bonus, 0, "same accrued window should remain claimable after reserve is restored");
    }

    function testClaimAutoMaxBonusSubMinDoesNotConsumeAccrualWindow() public {
        _seedReserve(1_000e18);
        vm.warp(block.timestamp + 1);
        uint256 tokenId = _createLock(alice, Constants.MIN_LOCK_AMOUNT, 365 days, true);

        furnace.claimAutoMaxBonus(tokenId); // initialize timestamp
        uint256 initializedAt = furnace.lastAutoMaxBonusClaim(tokenId);

        vm.warp(block.timestamp + 1 days);

        (, uint256 quotedBonus) = furnaceQuoter.quoteAutoMaxBonus(tokenId);
        assertEq(quotedBonus, 0, "sub-min AutoMax quote must surface zero delivered bonus");

        uint256 reserveBefore = furnace.furnaceReserve();
        uint256 bonus = furnace.claimAutoMaxBonus(tokenId);
        assertEq(bonus, 0, "sub-min AutoMax claim returns zero");
        assertEq(
            furnace.lastAutoMaxBonusClaim(tokenId),
            initializedAt,
            "sub-min delivered bonus must not burn the accrued cooldown window"
        );
        assertEq(furnace.furnaceReserve(), reserveBefore, "sub-min AutoMax preflight must not spend reserve");

        _seedReserve(10_000_000e18);

        bonus = furnace.claimAutoMaxBonus(tokenId);
        assertGt(bonus, 0, "same accrued window should remain claimable once payout clears dust floor");
    }

    function testRepeatedSubMinAutoMaxKeeperCallsDoNotBurnWindowBeforeReserveRefill() public {
        _seedReserve(1_000e18);
        vm.warp(block.timestamp + 1);
        uint256 tokenId = _createLock(alice, Constants.MIN_LOCK_AMOUNT, 365 days, true);

        furnace.claimAutoMaxBonus(tokenId); // initialize timestamp
        uint256 initializedAt = furnace.lastAutoMaxBonusClaim(tokenId);

        vm.warp(block.timestamp + 1 days);
        uint256 reserveBefore = furnace.furnaceReserve();
        for (uint256 i = 0; i < 3; ++i) {
            (, uint256 quotedBonus) = furnaceQuoter.quoteAutoMaxBonus(tokenId);
            assertEq(quotedBonus, 0, "sub-min quote should remain zero before refill");

            vm.prank(keeper);
            uint256 bonus = furnace.claimAutoMaxBonus(tokenId);
            assertEq(bonus, 0, "sub-min keeper claim returns zero");
            assertEq(furnace.lastAutoMaxBonusClaim(tokenId), initializedAt, "keeper must not burn accrual window");
            assertEq(furnace.furnaceReserve(), reserveBefore, "keeper must not spend reserve");
        }

        _seedReserve(10_000_000e18);
        vm.prank(keeper);
        uint256 paidAfterRefill = furnace.claimAutoMaxBonus(tokenId);
        assertGt(paidAfterRefill, 0, "unburned window should pay after reserve refill");
        assertEq(furnace.lastAutoMaxBonusClaim(tokenId), block.timestamp, "successful payout advances cursor");
    }

    function testBatchDuplicateAutoMaxTokenDoesNotOverpay() public {
        _seedReserve(10_000_000e18);
        vm.warp(block.timestamp + 1);
        uint256 tokenId = _createLock(alice, 100_000e18, 365 days, true);

        furnace.claimAutoMaxBonus(tokenId); // initialize timestamp
        vm.warp(block.timestamp + 1 days);

        (, uint256 quotedBonus) = furnaceQuoter.quoteAutoMaxBonus(tokenId);
        assertGt(quotedBonus, 0, "fixture should produce a payable AutoMax bonus");

        uint256[] memory ids = new uint256[](3);
        ids[0] = tokenId;
        ids[1] = tokenId;
        ids[2] = tokenId;

        (uint256 lockAmountBefore,,,) = ve.getLockInfo(tokenId);
        uint256 reserveBefore = furnace.furnaceReserve();

        uint256 totalBonus = furnace.claimAutoMaxBonusBatch(ids, 3);

        assertEq(totalBonus, quotedBonus, "duplicate batch entries must not multiply payout");
        assertEq(furnace.lastAutoMaxBonusClaim(tokenId), block.timestamp, "cursor advances once");
        assertLt(furnace.furnaceReserve(), reserveBefore, "reserve debited for one processed entry");

        (uint256 lockAmountAfter,,,) = ve.getLockInfo(tokenId);
        assertEq(lockAmountAfter, lockAmountBefore + quotedBonus, "lock receives one quoted bonus");
    }

    function testBatchClaimAutoMaxBonusZeroGrossCallDoesNotConsumeAccrualWindow() public {
        uint256 t0 = block.timestamp + 1;
        vm.warp(t0);
        uint256 tokenId = _createLock(alice, 100_000e18, 365 days, true);

        furnace.claimAutoMaxBonus(tokenId); // initialize timestamp
        uint256 initializedAt = t0;

        vm.warp(t0 + 1 days);

        uint256[] memory ids = new uint256[](1);
        ids[0] = tokenId;

        uint256 totalBonus = furnace.claimAutoMaxBonusBatch(ids, 25);
        assertEq(totalBonus, 0, "empty-reserve batch returns 0");
        assertEq(
            furnace.lastAutoMaxBonusClaim(tokenId),
            initializedAt,
            "zero-gross batch must not burn the accrued cooldown window"
        );

        _seedReserve(10_000_000e18);

        totalBonus = furnace.claimAutoMaxBonusBatch(ids, 25);
        assertGt(totalBonus, 0, "same accrued window should remain claimable after reserve is restored");
    }

    // ----------------------------------------------------------------
    // Integration test (enter -> extend -> sell)
    // ----------------------------------------------------------------

    function testIntegration_CreateExtendVerify() public {
        _seedReserve(10_000_000e18);
        vm.warp(block.timestamp + 1);

        // Create a 30-day lock directly.
        uint256 tokenId = _createLock(alice, 50_000e18, 30 days, false);

        (uint256 lockAmountBefore,,,) = ve.getLockInfo(tokenId);
        assertGt(lockAmountBefore, 0, "lock has funds");

        vm.warp(block.timestamp + 1);

        // Extend: use extendWithBonus to go from 30d to 365d.
        vm.prank(alice);
        uint256 bonus = furnace.extendWithBonus(tokenId, 365 days, 0);
        assertGt(bonus, 0, "bonus received");

        (uint256 lockAmountAfter,,,) = ve.getLockInfo(tokenId);
        assertEq(lockAmountAfter, lockAmountBefore + bonus, "lock grew by bonus");

        // Verify lock end extended.
        (, uint256 lockEnd,,) = ve.getLockInfo(tokenId);
        assertGt(lockEnd, block.timestamp + 364 days, "lock end extended to ~365d");
    }

    // ----------------------------------------------------------------
    // Furnace entry does not extend duration
    // ----------------------------------------------------------------

    function testExtendWithBonusAndAutoMaxBonusPathsSeparate() public {
        _seedReserve(10_000_000e18);
        vm.warp(block.timestamp + 1);

        // extendWithBonus only works on non-AutoMax locks.
        uint256 nonAutoMaxToken = _createLock(alice, 100_000e18, 30 days, false);
        // claimAutoMaxBonus only works on AutoMax locks.
        uint256 autoMaxToken = _createLock(alice, 100_000e18, 365 days, true);

        vm.warp(block.timestamp + 1);

        // extendWithBonus on non-AutoMax: succeeds
        vm.prank(alice);
        uint256 bonus1 = furnace.extendWithBonus(nonAutoMaxToken, 365 days, 0);
        assertGt(bonus1, 0, "extend bonus for non-automax");

        // extendWithBonus on AutoMax: reverts
        vm.prank(alice);
        vm.expectRevert(Errors.InvalidDuration.selector);
        furnace.extendWithBonus(autoMaxToken, 365 days, 0);

        // claimAutoMaxBonus on AutoMax: succeeds (init)
        furnace.claimAutoMaxBonus(autoMaxToken);

        // claimAutoMaxBonus on non-AutoMax: reverts
        vm.expectRevert(Errors.InvalidDuration.selector);
        furnace.claimAutoMaxBonus(nonAutoMaxToken);
    }

    // ----------------------------------------------------------------
    // claimAutoMaxBonusBatch
    // ----------------------------------------------------------------

    function testBatchClaimAutoMaxBonus() public {
        _seedReserve(10_000_000e18);
        vm.warp(block.timestamp + 1);

        uint256 tokenA = _createLock(alice, 100_000e18, 365 days, true);
        address bob = address(0xB0B);
        uint256 tokenB = _createLock(bob, 50_000e18, 365 days, true);
        uint256 tokenNonAuto = _createLock(alice, 20_000e18, 90 days, false);

        // Init both automax locks
        furnace.claimAutoMaxBonus(tokenA);
        furnace.claimAutoMaxBonus(tokenB);

        vm.warp(block.timestamp + 1 days);

        uint256[] memory ids = new uint256[](3);
        ids[0] = tokenA;
        ids[1] = tokenB;
        ids[2] = tokenNonAuto; // non-automax — should be silently skipped

        uint256 totalBonus = furnace.claimAutoMaxBonusBatch(ids, 25);
        assertGt(totalBonus, 0, "batch should yield bonus");

        (uint256 amtA,,,) = ve.getLockInfo(tokenA);
        assertGt(amtA, 100_000e18, "tokenA principal grew");

        (uint256 amtB,,,) = ve.getLockInfo(tokenB);
        assertGt(amtB, 50_000e18, "tokenB principal grew");

        // Non-automax unchanged
        (uint256 amtC,,,) = ve.getLockInfo(tokenNonAuto);
        assertEq(amtC, 20_000e18, "non-automax unchanged");
    }

    function testBatchSkipsIneligibleLocks() public {
        _seedReserve(10_000_000e18);
        vm.warp(block.timestamp + 1);

        uint256 tokenA = _createLock(alice, 100_000e18, 365 days, true);
        furnace.claimAutoMaxBonus(tokenA); // init

        // Don't warp — still on cooldown
        uint256[] memory ids = new uint256[](1);
        ids[0] = tokenA;

        uint256 totalBonus = furnace.claimAutoMaxBonusBatch(ids, 25);
        assertEq(totalBonus, 0, "cooldown - no bonus");
    }

    function testBatchRespectsMaxLocks() public {
        _seedReserve(10_000_000e18);
        vm.warp(block.timestamp + 1);

        uint256 tokenA = _createLock(alice, 100_000e18, 365 days, true);
        address bob = address(0xB0B);
        uint256 tokenB = _createLock(bob, 50_000e18, 365 days, true);

        furnace.claimAutoMaxBonus(tokenA);
        furnace.claimAutoMaxBonus(tokenB);

        vm.warp(block.timestamp + 1 days);

        uint256[] memory ids = new uint256[](2);
        ids[0] = tokenA;
        ids[1] = tokenB;

        // maxLocks = 1 — only first lock processed
        furnace.claimAutoMaxBonusBatch(ids, 1);

        (uint256 amtA,,,) = ve.getLockInfo(tokenA);
        assertGt(amtA, 100_000e18, "tokenA processed");

        (uint256 amtB,,,) = ve.getLockInfo(tokenB);
        assertEq(amtB, 50_000e18, "tokenB skipped by maxLocks cap");
    }

    function testBatchEmitsPerLockEvents() public {
        _seedReserve(10_000_000e18);
        vm.warp(block.timestamp + 1);

        uint256 tokenA = _createLock(alice, 100_000e18, 365 days, true);
        furnace.claimAutoMaxBonus(tokenA);

        vm.warp(block.timestamp + 1 days);

        uint256[] memory ids = new uint256[](1);
        ids[0] = tokenA;

        vm.expectEmit(true, false, false, false, address(furnace));
        emit Events.AutoMaxBonusClaimed(alice, tokenA, 0);

        furnace.claimAutoMaxBonusBatch(ids, 25);
    }
}
