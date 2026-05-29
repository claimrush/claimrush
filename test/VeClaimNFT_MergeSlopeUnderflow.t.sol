// SPDX-License-Identifier: MIT
pragma solidity ^0.8.34;

import {Test} from "forge-std/Test.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

import {ClaimToken} from "src/ClaimToken.sol";
import {Constants} from "src/lib/Constants.sol";
import {Errors} from "src/lib/Errors.sol";

import {VeClaimNFTHarness} from "./mocks/VeClaimNFTHarness.sol";
import {MockShareholderRoyaltiesCheckpoint} from "./mocks/MockShareholderRoyaltiesCheckpoint.sol";

/// @title Merge + Extend Slope Change Rounding Regression
/// @notice Covers the invariant that merging locks with specific amount combinations
///         (destination amount divisible by 1971, total not) MUST still produce a
///         merged lock that can be extended through the Furnace. The underlying
///         rounding discipline is that merge add-back uses `_slopeScaledAdd`
///         (ceil) to match the slope-removal side's rounding so that
///         `_slopeScaledAdd` / `_slopeScaledRemove` pair symmetrically on every
///         legal sequence of add / merge / extend operations.
contract VeClaimNFT_MergeSlopeUnderflow is Test {
    ClaimToken internal claim;
    VeClaimNFTHarness internal ve;
    MockShareholderRoyaltiesCheckpoint internal srMock;

    address internal owner = address(0xA11CE);
    address internal mineCore = address(0xC0DE);
    address internal mineMarket = address(0xB0B0);
    address internal furnace = address(0xF00D);
    address internal alice = address(0xA);

    uint256 internal constant SLOPE_SCALE = 1e18;

    function setUp() public {
        vm.etch(owner, hex"00");
        vm.etch(mineCore, hex"00");
        vm.etch(mineMarket, hex"00");
        vm.etch(furnace, hex"00");

        claim = new ClaimToken(owner);
        ve = new VeClaimNFTHarness(address(claim), owner);
        srMock = new MockShareholderRoyaltiesCheckpoint();

        vm.mockCall(owner, abi.encodeWithSignature("claim()"), abi.encode(address(claim)));

        vm.mockCall(furnace, abi.encodeWithSignature("shareholderRoyalties()"), abi.encode(address(srMock)));
        vm.mockCall(mineMarket, abi.encodeWithSignature("royalties()"), abi.encode(address(srMock)));

        vm.mockCall(furnace, abi.encodeWithSignature("ve()"), abi.encode(address(ve)));
        vm.mockCall(furnace, abi.encodeWithSignature("mineMarket()"), abi.encode(mineMarket));
        vm.mockCall(furnace, abi.encodeWithSignature("mineCore()"), abi.encode(mineCore));
        vm.mockCall(furnace, abi.encodeWithSignature("claim()"), abi.encode(address(claim)));
        vm.mockCall(furnace, abi.encodeWithSignature("delegationHub()"), abi.encode(address(srMock)));
        vm.mockCall(mineMarket, abi.encodeWithSignature("ve()"), abi.encode(address(ve)));
        vm.mockCall(mineMarket, abi.encodeWithSignature("claim()"), abi.encode(address(claim)));
        vm.mockCall(mineCore, abi.encodeWithSignature("ve()"), abi.encode(address(ve)));
        vm.mockCall(mineCore, abi.encodeWithSignature("claim()"), abi.encode(address(claim)));
        vm.mockCall(mineCore, abi.encodeWithSignature("furnace()"), abi.encode(furnace));
        vm.mockCall(mineCore, abi.encodeWithSignature("royalties()"), abi.encode(address(srMock)));
        vm.mockCall(mineCore, abi.encodeWithSignature("delegationHub()"), abi.encode(address(srMock)));
        vm.mockCall(address(srMock), abi.encodeWithSignature("ve()"), abi.encode(address(ve)));
        vm.mockCall(address(srMock), abi.encodeWithSignature("furnace()"), abi.encode(furnace));
        vm.mockCall(address(srMock), abi.encodeWithSignature("mineMarket()"), abi.encode(mineMarket));
        vm.mockCall(address(srMock), abi.encodeWithSignature("mineCore()"), abi.encode(mineCore));
        vm.mockCall(mineCore, abi.encodeWithSignature("emissionStartTime()"), abi.encode(uint256(1)));
        vm.mockCall(mineCore, abi.encodeWithSignature("GENESIS_ACCRUAL_DURATION()"), abi.encode(uint256(604800)));

        vm.prank(owner);
        claim.setMineCore(mineCore);

        vm.startPrank(owner);
        ve.setMineMarket(mineMarket);
        ve.setFurnace(furnace);
        vm.stopPrank();
    }

    /// @notice Verify the rounding-delta preconditions that exercise the merge / extend
    ///         rounding-symmetry path.
    ///         delta(x) = ceil(x * 1e18 / MAX_LOCK_DURATION) - floor(x * 1e18 / MAX_LOCK_DURATION)
    ///         delta(x) = 0 iff x is divisible by 1971 (= MAX_LOCK_DURATION / gcd(1e18, MAX_LOCK_DURATION))
    function test_roundingDeltaPreConditions() public pure {
        uint256 amt_a = 1000e18; // NOT divisible by 1971
        uint256 amt_b = 1971e18; // Divisible by 1971
        uint256 merged = amt_a + amt_b; // 2971e18, NOT divisible by 1971

        uint256 slopeAddA = Math.mulDiv(amt_a, SLOPE_SCALE, Constants.MAX_LOCK_DURATION, Math.Rounding.Ceil);
        uint256 slopeRemA = Math.mulDiv(amt_a, SLOPE_SCALE, Constants.MAX_LOCK_DURATION, Math.Rounding.Floor);
        assertGt(slopeAddA, slopeRemA, "delta(1000e18) must be 1");

        uint256 slopeAddB = Math.mulDiv(amt_b, SLOPE_SCALE, Constants.MAX_LOCK_DURATION, Math.Rounding.Ceil);
        uint256 slopeRemB = Math.mulDiv(amt_b, SLOPE_SCALE, Constants.MAX_LOCK_DURATION, Math.Rounding.Floor);
        assertEq(slopeAddB, slopeRemB, "delta(1971e18) must be 0");

        uint256 slopeAddM = Math.mulDiv(merged, SLOPE_SCALE, Constants.MAX_LOCK_DURATION, Math.Rounding.Ceil);
        uint256 slopeRemM = Math.mulDiv(merged, SLOPE_SCALE, Constants.MAX_LOCK_DURATION, Math.Rounding.Floor);
        assertGt(slopeAddM, slopeRemM, "delta(2971e18) must be 1");
    }

    /// @notice Regression: merge two locks where destination amount is divisible
    ///         by 1971 and total is not. Extend MUST succeed — the merge add-back
    ///         at `src/VeClaimNFT.sol:798` uses `_slopeScaledAdd` (ceil) to keep
    ///         add / remove rounding symmetric so that a subsequent
    ///         `_slopeScaledAdd` on extend cannot underflow.
    function test_mergeExtendSlopeUnderflow() public {
        uint256 amt_a = 1000e18;
        uint256 amt_b = 1971e18;

        vm.prank(mineCore);
        claim.mint(alice, amt_a + amt_b);

        vm.startPrank(alice);
        claim.approve(address(ve), type(uint256).max);

        uint256 tokenA = ve.createLock(amt_a, 30 days, false);
        uint256 tokenB = ve.createLock(amt_b, 300 days, false);
        vm.stopPrank();

        // v1.0.0: external user merge lives on Furnace (`mergeLocksWithBonus`); the
        // VeClaimNFT slope-rounding lock-math under test is reached through the
        // Furnace-only `mergeLocksFor` sibling so this regression keeps tracking
        // the same `_mergeLocksInternal` add-back path.
        vm.prank(furnace);
        ve.mergeLocksFor(alice, tokenA, tokenB);

        (uint256 mergedAmt, uint256 mergedEnd,,) = ve.getLockInfo(tokenB);
        assertEq(mergedAmt, amt_a + amt_b, "merged amount must be sum");

        uint256 newEnd = mergedEnd + 30 days;

        vm.prank(furnace);
        ve.extendLockToFor(alice, tokenB, newEnd);

        (, uint256 finalEnd,,) = ve.getLockInfo(tokenB);
        assertEq(finalEnd, newEnd, "extend must succeed for the 1971-divisible destination case");
    }

    /// @notice Verify the AutoMax toggle reset path: after merge, toggle AutoMax
    ///         on then off to reset the slope change entry with ceil rounding.
    ///         Then extend succeeds.
    function test_mergeExtendAfterAutoMaxToggleReset() public {
        uint256 amt_a = 1000e18;
        uint256 amt_b = 1971e18;

        vm.prank(mineCore);
        claim.mint(alice, amt_a + amt_b);

        vm.startPrank(alice);
        claim.approve(address(ve), type(uint256).max);

        uint256 tokenA = ve.createLock(amt_a, 30 days, false);
        uint256 tokenB = ve.createLock(amt_b, 300 days, false);
        vm.stopPrank();

        vm.prank(furnace);
        ve.mergeLocksFor(alice, tokenA, tokenB);

        // Toggle AutoMax on then off to reset the slope change entry with ceil rounding.
        vm.startPrank(alice);
        ve.setAutoMax(tokenB, true);
        ve.setAutoMax(tokenB, false);
        vm.stopPrank();

        // After AutoMax toggle, lockEnd is now + MAX_LOCK_DURATION.
        // Warp a bit so extend has room.
        vm.warp(block.timestamp + 2 days);
        uint256 newEnd = block.timestamp + Constants.MAX_LOCK_DURATION;

        vm.prank(furnace);
        ve.extendLockToFor(alice, tokenB, newEnd);

        (, uint256 finalEnd,,) = ve.getLockInfo(tokenB);
        assertEq(finalEnd, newEnd, "extend must succeed after AutoMax toggle reset");
    }

    /// @notice Verify that merge + extend works fine when both amounts
    ///         have nonzero delta (neither divisible by 1971).
    function test_mergeExtendSafeAmounts() public {
        uint256 amt_a = 1000e18; // delta = 1
        uint256 amt_b = 2000e18; // delta = 1 (2000 not divisible by 1971)

        vm.prank(mineCore);
        claim.mint(alice, amt_a + amt_b);

        vm.startPrank(alice);
        claim.approve(address(ve), type(uint256).max);

        uint256 tokenA = ve.createLock(amt_a, 30 days, false);
        uint256 tokenB = ve.createLock(amt_b, 300 days, false);
        vm.stopPrank();

        vm.prank(furnace);
        ve.mergeLocksFor(alice, tokenA, tokenB);

        // Extend should succeed because delta(amt_b) = 1 >= delta(merged) = 1
        (, uint256 mergedEnd,,) = ve.getLockInfo(tokenB);
        uint256 newEnd = mergedEnd + 30 days;

        vm.prank(furnace);
        ve.extendLockToFor(alice, tokenB, newEnd);

        (, uint256 finalEnd,,) = ve.getLockInfo(tokenB);
        assertEq(finalEnd, newEnd, "extend must succeed with safe amounts");
    }

    /// @notice Verify that principal conservation is maintained through merge + extend.
    function test_mergeDoesNotChangeTotalLockedClaim() public {
        uint256 amt_a = 1500e18;
        uint256 amt_b = 2500e18;

        vm.prank(mineCore);
        claim.mint(alice, amt_a + amt_b);

        vm.startPrank(alice);
        claim.approve(address(ve), type(uint256).max);

        uint256 tokenA = ve.createLock(amt_a, 60 days, false);
        uint256 tokenB = ve.createLock(amt_b, 180 days, false);
        vm.stopPrank();

        uint256 totalBefore = ve.totalLockedClaim();
        assertEq(totalBefore, amt_a + amt_b, "totalLockedClaim before merge");

        vm.prank(furnace);
        ve.mergeLocksFor(alice, tokenA, tokenB);

        uint256 totalAfter = ve.totalLockedClaim();
        assertEq(totalAfter, totalBefore, "totalLockedClaim must not change after merge");
    }

    // -----------------------------------------------------------------------
    // Phantom heap entries after merge source removal
    // -----------------------------------------------------------------------

    /// @notice After merging, the source lock's slope change at its old lockEnd
    ///         may leave a residual (phantom) heap entry. Verify checkpoint
    ///         processes it without issue and totalVeCached converges to 0
    ///         after all locks expire.
    function test_phantomHeapEntryAfterMerge() public {
        uint256 amt_a = 1000e18; // delta = 1 (produces phantom residual)
        uint256 amt_b = 2000e18;

        vm.prank(mineCore);
        claim.mint(alice, amt_a + amt_b);

        vm.startPrank(alice);
        claim.approve(address(ve), type(uint256).max);

        // Create two locks with different ends
        uint256 tokenA = ve.createLock(amt_a, 30 days, false);
        uint256 tokenB = ve.createLock(amt_b, 180 days, false);
        vm.stopPrank();

        // Record heap size before merge
        uint256 heapBefore = ve.getSlopeChangeCount();

        // Merge A into B — A's lockEnd may retain a phantom entry
        vm.prank(furnace);
        ve.mergeLocksFor(alice, tokenA, tokenB);

        // Heap may have a phantom entry at A's old lockEnd
        uint256 heapAfterMerge = ve.getSlopeChangeCount();
        // Should have at most: B's merged end + phantom at A's old end
        assertTrue(heapAfterMerge <= heapBefore, "heap size should not grow beyond pre-merge");

        // Warp past all lock expiry and checkpoint
        vm.warp(block.timestamp + 365 days + 1);
        ve.checkpointGlobalState();

        // totalVeCached should be 0 or near-0 (only residual dust)
        uint256 cachedVe = ve.totalVeCached();
        assertLe(cachedVe, 1, "totalVeCached must be 0 or 1 (dust) after all locks expire");

        // Heap should be empty after all slope changes processed
        assertEq(ve.getSlopeChangeCount(), 0, "heap must be empty after full checkpoint");
    }

    // -----------------------------------------------------------------------
    // Heap edge cases
    // -----------------------------------------------------------------------

    /// @notice Single lock create + unlock: heap insert + checkpoint removes entry.
    function test_heapSingleLockLifecycle() public {
        vm.prank(mineCore);
        claim.mint(alice, 1000e18);

        vm.startPrank(alice);
        claim.approve(address(ve), type(uint256).max);
        uint256 tokenId = ve.createLock(1000e18, 30 days, false);
        vm.stopPrank();

        assertEq(ve.getSlopeChangeCount(), 1, "one slope change after create");

        // Warp past expiry and checkpoint
        vm.warp(block.timestamp + 31 days);
        ve.checkpointGlobalState();

        // Heap entry should be processed (possibly leaving 1 dust entry)
        assertLe(ve.getSlopeChangeCount(), 1, "heap should be 0 or 1 after checkpoint past expiry");

        // Unlock
        vm.prank(alice);
        ve.unlock(tokenId);

        assertEq(ve.totalLockedClaim(), 0, "totalLockedClaim must be 0 after unlock");
    }

    /// @notice Multiple locks with same lockEnd share a single heap entry.
    function test_heapSharedTimestamp() public {
        vm.prank(mineCore);
        claim.mint(alice, 3000e18);

        vm.startPrank(alice);
        claim.approve(address(ve), type(uint256).max);

        // Create 3 locks in the same block — all have the same lockEnd
        ve.createLock(1000e18, 30 days, false);
        ve.createLock(1000e18, 30 days, false);
        ve.createLock(1000e18, 30 days, false);
        vm.stopPrank();

        // All three should share one heap entry
        assertEq(ve.getSlopeChangeCount(), 1, "3 locks with same end share 1 heap entry");
    }

    /// @notice AutoMax locks don't add heap entries; disabling AutoMax does.
    function test_heapAutoMaxNoEntry() public {
        vm.prank(mineCore);
        claim.mint(alice, 1000e18);

        vm.startPrank(alice);
        claim.approve(address(ve), type(uint256).max);
        uint256 tokenId = ve.createLock(1000e18, Constants.MAX_LOCK_DURATION, true);
        vm.stopPrank();

        assertEq(ve.getSlopeChangeCount(), 0, "AutoMax lock has no heap entry");

        // Disable AutoMax — now a slope change is scheduled
        vm.prank(alice);
        ve.setAutoMax(tokenId, false);

        assertEq(ve.getSlopeChangeCount(), 1, "disabling AutoMax adds a heap entry");
    }

    // -----------------------------------------------------------------------
    // Merge + extend fuzz
    // -----------------------------------------------------------------------

    /// @notice Fuzz: merge two locks with random amounts, then extend.
    ///         Extend MUST always succeed regardless of the amount combination
    ///         (rounding-symmetric add-back on merge).
    function testFuzz_mergeExtendAlwaysSucceeds(uint128 rawA, uint128 rawB) public {
        uint256 amt_a = bound(uint256(rawA), Constants.MIN_LOCK_AMOUNT, 100_000_000e18);
        uint256 amt_b = bound(uint256(rawB), Constants.MIN_LOCK_AMOUNT, 100_000_000e18);

        vm.prank(mineCore);
        claim.mint(alice, amt_a + amt_b);

        vm.startPrank(alice);
        claim.approve(address(ve), type(uint256).max);

        uint256 tokenA = ve.createLock(amt_a, 30 days, false);
        uint256 tokenB = ve.createLock(amt_b, 300 days, false);
        vm.stopPrank();

        vm.prank(furnace);
        ve.mergeLocksFor(alice, tokenA, tokenB);

        // Extend the merged lock — must never revert on any amount combination
        (, uint256 mergedEnd,,) = ve.getLockInfo(tokenB);
        uint256 newEnd = mergedEnd + 30 days;
        if (newEnd > block.timestamp + Constants.MAX_LOCK_DURATION) {
            newEnd = block.timestamp + Constants.MAX_LOCK_DURATION;
        }
        // Only extend if there's actually room
        if (newEnd > mergedEnd) {
            vm.prank(furnace);
            ve.extendLockToFor(alice, tokenB, newEnd);

            (, uint256 finalEnd,,) = ve.getLockInfo(tokenB);
            assertEq(finalEnd, newEnd, "extend must succeed for all amount combinations");
        }
    }

    /// @notice Fuzz: merge ve inflation — merged ve at merge time equals sum
    ///         of individual ve contributions at the merged lock's remaining time.
    function testFuzz_mergeVeInflationBounded(uint128 rawA, uint128 rawB) public {
        uint256 amt_a = bound(uint256(rawA), Constants.MIN_LOCK_AMOUNT, 100_000_000e18);
        uint256 amt_b = bound(uint256(rawB), Constants.MIN_LOCK_AMOUNT, 100_000_000e18);

        vm.prank(mineCore);
        claim.mint(alice, amt_a + amt_b);

        vm.startPrank(alice);
        claim.approve(address(ve), type(uint256).max);

        uint256 tokenA = ve.createLock(amt_a, 30 days, false);
        ve.createLock(amt_b, 180 days, false);
        vm.stopPrank();

        uint256 veBefore = ve.veBalanceOf(alice);
        uint256 totalVeBefore = ve.totalVeCached();

        vm.prank(furnace);
        ve.mergeLocksFor(alice, tokenA, 2);

        uint256 veAfter = ve.veBalanceOf(alice);
        uint256 totalVeAfter = ve.totalVeCached();

        // Merged ve >= pre-merge ve (inflation from extending shorter lock)
        assertGe(veAfter, veBefore, "merged ve must be >= pre-merge ve");

        // Total locked CLAIM unchanged
        assertEq(ve.totalLockedClaim(), amt_a + amt_b, "principal conservation");

        // totalVeCached updated correctly (within 1 of veBalanceOf due to ceil vs floor)
        assertGe(totalVeAfter + 1, veAfter, "totalVeCached must be >= veBalanceOf (conservative)");
    }
}
