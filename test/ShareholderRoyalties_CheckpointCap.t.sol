// SPDX-License-Identifier: MIT
pragma solidity ^0.8.34;

import {Test} from "forge-std/Test.sol";

import {ShareholderRoyalties} from "src/ShareholderRoyalties.sol";
import {Constants} from "src/lib/Constants.sol";
import {Errors} from "src/lib/Errors.sol";
import {Events} from "src/lib/Events.sol";

import {MockContract} from "./mocks/MockContract.sol";
import {MockVe} from "./mocks/MockVe.sol";
import {ShareholderRoyaltiesHarness} from "./mocks/ShareholderRoyaltiesHarness.sol";

contract MockFurnaceCapTest {
    address public mineCore;
    address public mineMarket;
    address public shareholderRoyalties;
    address public delegationHub;

    function setWiring(address _mineCore, address _mineMarket, address _shareholderRoyalties) external {
        mineCore = _mineCore;
        mineMarket = _mineMarket;
        shareholderRoyalties = _shareholderRoyalties;
    }

    function setDelegationHub(address v) external {
        delegationHub = v;
    }

    function furnaceQuoter() external view returns (address) {
        return address(this);
    }

    function quoteEnterWithEth(address, uint256, uint256, uint256, bool)
        external
        pure
        returns (uint256, uint256, uint256, uint256)
    {
        return (0, 0, 100e18, 0);
    }

    function lockEthReward(address, uint256, uint256, uint256, bool, uint256) external payable {}
}

contract MockMineCoreCapTest {
    address public furnace;
    address public claimAllHelper;
    address public delegationHub;

    function setWiring(address _furnace, address _claimAllHelper) external {
        furnace = _furnace;
        claimAllHelper = _claimAllHelper;
    }

    function setDelegationHub(address _delegationHub) external {
        delegationHub = _delegationHub;
    }
}

/// @notice Tests for the checkpoint-cap overflow fix in ShareholderRoyalties.
contract ShareholderRoyalties_CheckpointCapTest is Test {
    ShareholderRoyaltiesHarness internal royalties;
    MockVe internal ve;
    MockFurnaceCapTest internal furnace;
    MockMineCoreCapTest internal mineCoreMock;

    address internal owner;
    address internal alice;
    address internal mineCore;
    address internal mineMarket;
    address internal claimToken;

    uint256 internal constant CAP = Constants.MAX_REWARD_CHECKPOINTS; // 50_000

    function setUp() public {
        owner = makeAddr("owner");
        alice = makeAddr("alice");

        ve = new MockVe();
        furnace = new MockFurnaceCapTest();
        mineCoreMock = new MockMineCoreCapTest();
        MockContract mockMarket = new MockContract();
        claimToken = address(new MockContract());
        mineCore = address(mineCoreMock);
        mineMarket = address(mockMarket);

        royalties = new ShareholderRoyaltiesHarness(address(ve), owner);

        furnace.setWiring(mineCore, mineMarket, address(royalties));
        mineCoreMock.setWiring(address(furnace), address(0));
        vm.mockCall(mineCore, abi.encodeWithSignature("ve()"), abi.encode(address(ve)));
        vm.mockCall(mineCore, abi.encodeWithSignature("claim()"), abi.encode(claimToken));
        vm.mockCall(mineCore, abi.encodeWithSignature("royalties()"), abi.encode(address(royalties)));
        vm.mockCall(mineMarket, abi.encodeWithSignature("ve()"), abi.encode(address(ve)));
        vm.mockCall(mineMarket, abi.encodeWithSignature("claim()"), abi.encode(claimToken));
        vm.mockCall(mineMarket, abi.encodeWithSignature("royalties()"), abi.encode(address(royalties)));
        vm.mockCall(address(furnace), abi.encodeWithSignature("ve()"), abi.encode(address(ve)));
        vm.mockCall(address(furnace), abi.encodeWithSignature("claim()"), abi.encode(claimToken));
        vm.mockCall(address(ve), abi.encodeWithSignature("furnace()"), abi.encode(address(furnace)));
        vm.mockCall(address(ve), abi.encodeWithSignature("mineMarket()"), abi.encode(mineMarket));
        vm.mockCall(address(ve), abi.encodeWithSignature("claimToken()"), abi.encode(claimToken));
        vm.mockCall(claimToken, abi.encodeWithSignature("mineCore()"), abi.encode(mineCore));

        vm.prank(owner);
        royalties.setWiring(mineCore, mineMarket, address(furnace));
    }

    // ------------------------------------------------------------------
    // Helpers
    // ------------------------------------------------------------------

    /// @dev Efficiently set up a checkpoint array of exactly `CAP` entries.
    ///      Uses assembly-backed helpers so we never loop 50k SSTOREs.
    ///      Writes real entries only at sentinel positions (first, last two).
    function _setupFullArray() internal {
        royalties.forceSetArrayLength(CAP);

        // Sentinel at index 0 — ensures binary search lower bound works.
        royalties.setCheckpointAt(0, 1000, 1e15, 1e15 * 1000);

        // Sentinel at second-to-last position.
        uint40 ts2 = 50_000;
        uint256 cum2 = 100e18;
        royalties.setCheckpointAt(CAP - 2, ts2, cum2, cum2 * uint256(ts2));

        // Last array entry — the one the old code would have overwritten.
        uint40 ts1 = 60_000;
        uint256 cum1 = 200e18;
        royalties.setCheckpointAt(CAP - 1, ts1, cum1, cum1 * uint256(ts1));
    }

    function _takeover(uint256 amountEth) internal {
        vm.deal(mineCore, amountEth);
        vm.prank(mineCore);
        royalties.onTakeover{value: amountEth}(1);
    }

    // ------------------------------------------------------------------
    // Post-cap history integrity
    // ------------------------------------------------------------------

    /// @dev Once the checkpoint array hits its cap, it is frozen and subsequent flushes land in
    ///      the overflow checkpoint. This test asserts that a lock whose `lockEnd` falls between
    ///      the last pre-cap timestamp and a later post-cap flush resolves via the overflow
    ///      checkpoint rather than stale cumulative values from `checkpoint[len-2]`.
    function testPoC_OverwriteDestroyedHistory_FixedByOverflow() public {
        _setupFullArray();
        assertEq(royalties.rewardCheckpointsLength(), CAP);

        // Snapshot the last array entry BEFORE a post-cap flush.
        (uint40 lastArrayTs, uint256 lastArrayCum,) = royalties.getRewardCheckpoint(CAP - 1);
        assertEq(lastArrayTs, 60_000);
        assertEq(lastArrayCum, 200e18);

        // Flush at a new timestamp — triggers the cap path.
        uint40 flushTs = 70_000;
        royalties.setEthPerVe(300e18);
        royalties.setEthPerVeTimeWeighted(300e18 * uint256(flushTs));
        royalties.exposed_storeRewardCheckpoint(flushTs);

        // CRITICAL: The array's last entry must NOT have been overwritten.
        (uint40 postTs, uint256 postCum,) = royalties.getRewardCheckpoint(CAP - 1);
        assertEq(postTs, lastArrayTs, "array last entry timestamp must be unchanged");
        assertEq(postCum, lastArrayCum, "array last entry cumulative must be unchanged");

        // The overflow array holds the latest values.
        assertEq(royalties.overflowCheckpointsLength(), 1);
        (uint40 ovTs, uint256 ovCum,) = royalties.getOverflowCheckpoint(0);
        assertEq(ovTs, flushTs, "overflow must have newest timestamp");
        assertEq(ovCum, 300e18, "overflow cumulative must match");

        // Query for a timestamp between the preserved array last and overflow.
        // This is the exact range the old code would have corrupted.
        uint256 queryTs = uint256(lastArrayTs) + 1;
        (uint256 idx,) = royalties.exposed_getRewardPrefixBefore(queryTs);
        assertEq(idx, lastArrayCum, "prefix lookup in the gap must return the preserved array value");

        // Query past the overflow should return overflow values.
        (uint256 idxFuture,) = royalties.exposed_getRewardPrefixBefore(uint256(flushTs) + 1);
        assertEq(idxFuture, 300e18, "prefix lookup past overflow must return overflow values");
    }

    // ------------------------------------------------------------------
    // PoC: end-to-end with a decaying lock in the gap
    // ------------------------------------------------------------------

    /// @dev A non-AutoMax lock whose lockEnd falls between the frozen array
    ///      last entry and the overflow checkpoint must still accrue rewards
    ///      up to the array's last snapshot (conservative, never overpays).
    function testPoC_DecayingLockInGap_AccruesFromArray() public {
        // Start at a reasonable timestamp.
        vm.warp(1_000_000);
        ve.setGlobalLastTs(block.timestamp);
        ve.setTotalVeCached(200e18);

        // Prime the index with one flush so Alice's first checkpoint has a base.
        _takeover(0.5 ether);
        royalties.flushPendingShareholderETH();
        uint256 baseEthPerVe = royalties.ethPerVe();
        assertGt(baseEthPerVe, 0);

        // Checkpoint Alice with zero balance so her paid markers advance to
        // the current index without accruing anything.
        royalties.checkpointUser(alice);
        assertEq(royalties.claimableEth(alice), 0, "zero-balance checkpoint must not accrue");

        // Now configure Alice with a decaying lock that expires at +2h.
        uint256 lockEnd = block.timestamp + 2 hours;
        uint256[] memory amounts = new uint256[](1);
        uint256[] memory lockEnds = new uint256[](1);
        bool[] memory autoMaxFlags = new bool[](1);
        amounts[0] = 100e18;
        lockEnds[0] = lockEnd;
        autoMaxFlags[0] = false;
        ve.setShareholderLockParams(alice, amounts, lockEnds, autoMaxFlags);
        ve.setVeBalance(alice, 100e18);

        // Warp forward 1 hour, do a flush that will become the last array entry.
        vm.warp(block.timestamp + 1 hours);
        ve.setGlobalLastTs(block.timestamp);
        _takeover(1 ether);
        royalties.flushPendingShareholderETH();

        royalties.ethPerVe();
        uint256 currentLen = royalties.rewardCheckpointsLength();
        assertGe(currentLen, 2, "should have at least 2 real checkpoints");

        // Force the array to the cap. Write the last entry with current values
        // so the binary search finds the right data for lockEnd.
        (uint40 realLastTs, uint256 realLastCum, uint256 realLastTw) = royalties.getRewardCheckpoint(currentLen - 1);
        royalties.forceSetArrayLength(CAP);
        royalties.setCheckpointAt(CAP - 1, realLastTs, realLastCum, realLastTw);

        // Warp past the lock's expiry, flush again → goes to overflow.
        vm.warp(lockEnd + 1 hours);
        ve.setGlobalLastTs(block.timestamp);
        _takeover(2 ether);
        royalties.flushPendingShareholderETH();

        assertEq(royalties.rewardCheckpointsLength(), CAP, "array must not grow past cap");
        assertGt(royalties.overflowCheckpointsLength(), 0, "overflow must be populated");
        (uint40 ovTs,,) = royalties.getOverflowCheckpoint(royalties.overflowCheckpointsLength() - 1);
        assertGt(ovTs, 0, "overflow must have a nonzero timestamp");

        // Checkpoint Alice. Her lock expired at lockEnd which is between the
        // last array entry timestamp and the overflow timestamp.
        royalties.checkpointUser(alice);
        uint256 aliceClaimable = royalties.claimableEth(alice);
        assertGt(aliceClaimable, 0, "decaying lock in the gap must accrue some reward");
    }

    // ------------------------------------------------------------------
    // Overflow preserves historical array entries.
    // ------------------------------------------------------------------

    function testOverflow_ArrayFrozenAfterCap() public {
        _setupFullArray();

        // Snapshot sentinel entries.
        (uint40 tsFirst, uint256 cumFirst,) = royalties.getRewardCheckpoint(0);
        (uint40 tsLast, uint256 cumLast,) = royalties.getRewardCheckpoint(CAP - 1);

        // Perform multiple post-cap flushes via the exposed helper.
        for (uint256 j = 0; j < 10; j++) {
            // 999_999 + j (j < 10) ≪ type(uint40).max (≈1.1e12).
            // forge-lint: disable-next-line(unsafe-typecast)
            uint40 newTs = uint40(999_999 + j);
            royalties.setEthPerVe((CAP + j + 1) * 1e15);
            royalties.setEthPerVeTimeWeighted((CAP + j + 1) * 1e15 * uint256(newTs));
            royalties.exposed_storeRewardCheckpoint(newTs);
        }

        // Verify sentinel entries are untouched.
        (uint40 tsFirstAfter, uint256 cumFirstAfter,) = royalties.getRewardCheckpoint(0);
        assertEq(tsFirstAfter, tsFirst, "first entry timestamp must be unchanged");
        assertEq(cumFirstAfter, cumFirst, "first entry cumulative must be unchanged");

        (uint40 tsLastAfter, uint256 cumLastAfter,) = royalties.getRewardCheckpoint(CAP - 1);
        assertEq(tsLastAfter, tsLast, "last entry timestamp must be unchanged");
        assertEq(cumLastAfter, cumLast, "last entry cumulative must be unchanged");

        // Array length must not have grown.
        assertEq(royalties.rewardCheckpointsLength(), CAP);
    }

    // ------------------------------------------------------------------
    // Active locks (lockEnd in the future) use the overflow fast-path.
    // ------------------------------------------------------------------

    function testOverflow_ActiveLockGetsOverflowValues() public {
        _setupFullArray();

        // Set overflow with a known timestamp and cumulative.
        uint40 overflowTs = uint40(500_000);
        uint256 overflowCum = 999e18;
        uint256 overflowTw = overflowCum * uint256(overflowTs);

        royalties.setEthPerVe(overflowCum);
        royalties.setEthPerVeTimeWeighted(overflowTw);
        royalties.exposed_storeRewardCheckpoint(overflowTs);

        // Query with ts > overflow → should get overflow values.
        (uint256 idx, uint256 tw) = royalties.exposed_getRewardPrefixBefore(uint256(overflowTs) + 1);
        assertEq(idx, overflowCum, "must return overflow cumulative for future ts");
        assertEq(tw, overflowTw, "must return overflow time-weighted for future ts");
    }

    // ------------------------------------------------------------------
    // Same-block coalescing at the cap.
    // ------------------------------------------------------------------

    function testOverflow_SameBlockCoalescing() public {
        _setupFullArray();

        // Snapshot last array entry for later verification.
        (uint40 origLastTs,,) = royalties.getRewardCheckpoint(CAP - 1);

        uint40 ts = uint40(800_000);

        // First post-cap flush.
        royalties.setEthPerVe(100e18);
        royalties.setEthPerVeTimeWeighted(100e18 * uint256(ts));
        royalties.exposed_storeRewardCheckpoint(ts);

        assertEq(royalties.overflowCheckpointsLength(), 1);
        (uint40 ovTs1, uint256 ovCum1,) = royalties.getOverflowCheckpoint(0);
        assertEq(ovTs1, ts);
        assertEq(ovCum1, 100e18);

        // Second flush, same block/timestamp — should coalesce into overflow.
        royalties.setEthPerVe(200e18);
        royalties.setEthPerVeTimeWeighted(200e18 * uint256(ts));
        royalties.exposed_storeRewardCheckpoint(ts);

        assertEq(royalties.overflowCheckpointsLength(), 1, "must coalesce, not push");
        (uint40 ovTs2, uint256 ovCum2,) = royalties.getOverflowCheckpoint(0);
        assertEq(ovTs2, ts, "timestamp must remain the same");
        assertEq(ovCum2, 200e18, "cumulative must be updated");

        // Array must not have grown.
        assertEq(royalties.rewardCheckpointsLength(), CAP);

        // Last array entry must be untouched.
        (uint40 lastTs,,) = royalties.getRewardCheckpoint(CAP - 1);
        assertEq(lastTs, origLastTs, "array last entry must be unchanged");
    }

    // ------------------------------------------------------------------
    // _latestRewardTimestamp reflects overflow.
    // ------------------------------------------------------------------

    function testLatestRewardTimestamp_ReflectsOverflow() public {
        // Empty state — should return 0.
        assertEq(royalties.exposed_latestRewardTimestamp(), 0);

        // Push one checkpoint.
        royalties.pushCheckpoint(1000, 1e15, 1e15 * 1000);
        assertEq(royalties.exposed_latestRewardTimestamp(), 1000);

        // Fill to cap using assembly.
        royalties.forceSetArrayLength(CAP);
        uint40 lastArrayTs = 90_000;
        royalties.setCheckpointAt(CAP - 1, lastArrayTs, 50e18, 50e18 * uint256(lastArrayTs));
        assertEq(royalties.exposed_latestRewardTimestamp(), lastArrayTs);

        // Post-cap flush → overflow should dominate.
        uint40 overflowTs = lastArrayTs + 5000;
        royalties.setEthPerVe(100e18);
        royalties.setEthPerVeTimeWeighted(100e18 * uint256(overflowTs));
        royalties.exposed_storeRewardCheckpoint(overflowTs);

        assertEq(royalties.exposed_latestRewardTimestamp(), overflowTs, "must return overflow timestamp");
    }

    // ------------------------------------------------------------------
    // Cap-reached event emission.
    // ------------------------------------------------------------------

    function testOverflow_EmitsCapReachedEvent() public {
        _setupFullArray();

        uint40 ts1 = uint40(900_000);
        royalties.setEthPerVe(1e18);
        royalties.setEthPerVeTimeWeighted(1e18 * uint256(ts1));

        // First overflow write — overflow array is empty, so event fires once.
        vm.expectEmit(false, false, false, true);
        emit Events.RewardCheckpointCapReached(CAP);
        royalties.exposed_storeRewardCheckpoint(ts1);

        // Same-block coalesce — should NOT emit (timestamps match).
        vm.recordLogs();
        royalties.exposed_storeRewardCheckpoint(ts1);
        assertEq(vm.getRecordedLogs().length, 0, "same-block coalesce must not emit cap event");

        // New timestamp — overflow array is no longer empty, so no repeat event.
        uint40 ts2 = ts1 + 3600;
        royalties.setEthPerVe(2e18);
        royalties.setEthPerVeTimeWeighted(2e18 * uint256(ts2));
        vm.recordLogs();
        royalties.exposed_storeRewardCheckpoint(ts2);
        assertEq(vm.getRecordedLogs().length, 0, "subsequent overflow push must not re-emit cap event");
    }

    // ------------------------------------------------------------------
    // Pre-cap same-block coalescing remains intact.
    // ------------------------------------------------------------------

    // ------------------------------------------------------------------
    // Query between two distinct post-cap overflow timestamps.
    // ------------------------------------------------------------------

    /// @dev Reproduces the exact scenario that the single-slot overflow lost:
    ///      two post-cap flushes at different timestamps, then a query between them.
    function testOverflow_QueryBetweenTwoDistinctOverflowTimestamps() public {
        _setupFullArray(); // array last entry: ts=60_000, cum=200e18

        // First overflow write at 70_000.
        royalties.setEthPerVe(300e18);
        royalties.setEthPerVeTimeWeighted(300e18 * uint256(70_000));
        royalties.exposed_storeRewardCheckpoint(70_000);

        // Second overflow write at 80_000.
        royalties.setEthPerVe(400e18);
        royalties.setEthPerVeTimeWeighted(400e18 * uint256(80_000));
        royalties.exposed_storeRewardCheckpoint(80_000);

        assertEq(royalties.overflowCheckpointsLength(), 2, "must have two overflow entries");

        // Query between the two overflow timestamps — the old single-slot
        // code would fall through to the array and return 200e18 (wrong).
        (uint256 idx,) = royalties.exposed_getRewardPrefixBefore(75_000);
        assertEq(idx, 300e18, "must return first overflow, not stale array last");

        // Query before first overflow but after array last.
        (uint256 idx2,) = royalties.exposed_getRewardPrefixBefore(65_000);
        assertEq(idx2, 200e18, "must return array last entry");

        // Query after second overflow.
        (uint256 idx3,) = royalties.exposed_getRewardPrefixBefore(85_000);
        assertEq(idx3, 400e18, "must return latest overflow");
    }

    /// @dev Three+ distinct overflow timestamps to exercise the general binary search.
    function testOverflow_QueryAcrossThreeDistinctOverflowTimestamps() public {
        _setupFullArray(); // array last entry: ts=60_000, cum=200e18

        uint40[3] memory ts = [uint40(70_000), uint40(80_000), uint40(90_000)];
        uint256[3] memory cums = [uint256(300e18), uint256(400e18), uint256(500e18)];

        for (uint256 i = 0; i < 3; i++) {
            royalties.setEthPerVe(cums[i]);
            royalties.setEthPerVeTimeWeighted(cums[i] * uint256(ts[i]));
            royalties.exposed_storeRewardCheckpoint(ts[i]);
        }

        assertEq(royalties.overflowCheckpointsLength(), 3);

        // Between first and second overflow.
        (uint256 a,) = royalties.exposed_getRewardPrefixBefore(75_000);
        assertEq(a, 300e18, "must return first overflow snapshot");

        // Between second and third overflow.
        (uint256 b,) = royalties.exposed_getRewardPrefixBefore(85_000);
        assertEq(b, 400e18, "must return second overflow snapshot");

        // After all overflows.
        (uint256 c,) = royalties.exposed_getRewardPrefixBefore(95_000);
        assertEq(c, 500e18, "must return third overflow snapshot");

        // Before any overflow (but after array last).
        (uint256 d,) = royalties.exposed_getRewardPrefixBefore(65_000);
        assertEq(d, 200e18, "must return array last entry");
    }

    // ------------------------------------------------------------------
    // Pre-cap same-block coalescing remains intact.
    // ------------------------------------------------------------------

    function testPreCap_SameBlockCoalescing() public {
        uint40 ts = uint40(5000);

        royalties.setEthPerVe(10e18);
        royalties.setEthPerVeTimeWeighted(10e18 * uint256(ts));
        royalties.exposed_storeRewardCheckpoint(ts);
        assertEq(royalties.rewardCheckpointsLength(), 1);

        // Same timestamp — should coalesce, not push.
        royalties.setEthPerVe(20e18);
        royalties.setEthPerVeTimeWeighted(20e18 * uint256(ts));
        royalties.exposed_storeRewardCheckpoint(ts);
        assertEq(royalties.rewardCheckpointsLength(), 1, "must coalesce same-block");

        (uint40 storedTs, uint256 cum,) = royalties.getRewardCheckpoint(0);
        assertEq(storedTs, ts);
        assertEq(cum, 20e18, "cumulative must be updated by coalesce");

        // Different timestamp — should push.
        uint40 ts2 = ts + 1;
        royalties.setEthPerVe(30e18);
        royalties.setEthPerVeTimeWeighted(30e18 * uint256(ts2));
        royalties.exposed_storeRewardCheckpoint(ts2);
        assertEq(royalties.rewardCheckpointsLength(), 2);
    }

    // ==================================================================
    // Ring-buffer overflow tests (overflow array itself fills up)
    // ==================================================================

    uint256 internal constant OV_CAP = Constants.MAX_OVERFLOW_CHECKPOINTS; // 50_000

    /// @dev Set up main array at cap AND overflow array at cap.
    ///      Overflow entries span [baseTs .. baseTs + (OV_CAP-1)*step].
    ///      `blockTs` is the simulated block.timestamp for the test context.
    function _setupFullOverflow(uint40 baseTs, uint40 step) internal returns (uint40 lastOvTs) {
        _setupFullArray();

        royalties.forceSetOverflowArrayLength(OV_CAP);

        // Write sentinel entries at key positions.
        for (uint256 i = 0; i < 5; i++) {
            // i < 5 ≪ type(uint40).max.
            // forge-lint: disable-next-line(unsafe-typecast)
            uint40 ts = baseTs + uint40(i) * step;
            uint256 cum = (i + 1) * 100e18;
            royalties.setOverflowCheckpointAt(i, ts, cum, cum * uint256(ts));
        }
        // Write the last few entries.
        for (uint256 i = OV_CAP - 3; i < OV_CAP; i++) {
            // i < OV_CAP = 50_000 ≪ type(uint40).max (≈1.1e12).
            // forge-lint: disable-next-line(unsafe-typecast)
            uint40 ts = baseTs + uint40(i) * step;
            uint256 cum = (i + 1) * 100e18;
            royalties.setOverflowCheckpointAt(i, ts, cum, cum * uint256(ts));
            lastOvTs = ts;
        }
    }

    // ------------------------------------------------------------------
    // Ring-buffer: evicts oldest when beyond lock horizon
    // ------------------------------------------------------------------

    function testOverflowCap_RingBufferEvictsOldest() public {
        // Place overflow entries starting at t=1000, step=1000.
        // Warp far enough that entry 0 is older than MAX_LOCK_DURATION.
        uint40 baseTs = 1000;
        uint40 step = 1000;
        _setupFullOverflow(baseTs, step);

        // Warp so oldest entry (ts=1000) is > MAX_LOCK_DURATION old.
        uint256 warpTo = uint256(baseTs) + Constants.MAX_LOCK_DURATION + 1;
        vm.warp(warpTo);

        assertEq(royalties.getOverflowRingHead(), 0, "head starts at 0");

        // Write a new checkpoint — should evict index 0 (oldest, beyond horizon).
        // warpTo = baseTs + MAX_LOCK_DURATION + 1 (1000 + 365 days ≈ 3.15e7) ≪ type(uint40).max.
        // forge-lint: disable-next-line(unsafe-typecast)
        uint40 newTs = uint40(warpTo);
        royalties.setEthPerVe(999e18);
        royalties.setEthPerVeTimeWeighted(999e18 * uint256(newTs));

        vm.expectEmit(false, false, false, true);
        emit Events.OverflowCheckpointCapReached(OV_CAP);
        royalties.exposed_storeRewardCheckpoint(newTs);

        // Head should have advanced.
        assertEq(royalties.getOverflowRingHead(), 1, "head must advance after eviction");

        // The evicted slot (physical 0) now holds the new entry.
        (uint40 evictedTs, uint256 evictedCum,) = royalties.getOverflowCheckpoint(0);
        assertEq(evictedTs, newTs, "evicted slot must hold new timestamp");
        assertEq(evictedCum, 999e18, "evicted slot must hold new cumulative");

        // Overflow length unchanged.
        assertEq(royalties.overflowCheckpointsLength(), OV_CAP);
    }

    // ------------------------------------------------------------------
    // Ring-buffer: distinct timestamps inside the active horizon must defer
    // ------------------------------------------------------------------

    function testOverflowCap_DefersWhenAllWithinHorizon() public {
        // Place overflow entries starting at a recent timestamp.
        uint40 baseTs = uint40(block.timestamp) + 100;
        vm.warp(baseTs + 100);
        _setupFullOverflow(baseTs, 1);

        // Remember the original tail state before the unsafe write attempt.
        (uint40 origTailTs, uint256 origTailCum,) = royalties.getOverflowCheckpoint(OV_CAP - 1);

        // All entries are within MAX_LOCK_DURATION — warp only slightly ahead.
        vm.warp(baseTs + OV_CAP + 10);

        uint40 newTs = uint40(block.timestamp);
        assertFalse(royalties.exposed_canStoreRewardCheckpoint(newTs), "unsafe distinct timestamp must be deferred");

        royalties.setEthPerVe(888e18);
        royalties.setEthPerVeTimeWeighted(888e18 * uint256(newTs));

        vm.expectRevert(Errors.InvariantViolation.selector);
        royalties.exposed_storeRewardCheckpoint(newTs);

        // State must remain unchanged after the reverted unsafe write.
        assertEq(royalties.getOverflowRingHead(), 0, "head must stay unchanged while storage is blocked");

        // Tail must be preserved until the oldest entry ages out.
        (uint40 lastTs, uint256 lastCum,) = royalties.getOverflowCheckpoint(OV_CAP - 1);
        assertEq(lastTs, origTailTs, "tail timestamp must stay pinned while writes are deferred");
        assertEq(lastCum, origTailCum, "tail cumulative must stay unchanged while writes are deferred");
    }

    function testCheckpointUserBatch_OneBadUserDoesNotBrickBatch() public {
        address goodUser = makeAddr("goodUser");
        address badUser = makeAddr("badUser");
        address goodUser2 = makeAddr("goodUser2");

        // Store a checkpoint so ethPerVe > 0 (makes checkpointUser do real work).
        royalties.setEthPerVe(1e18);
        royalties.setEthPerVeTimeWeighted(1e18 * block.timestamp);
        royalties.exposed_storeRewardCheckpoint(uint40(block.timestamp));

        // Make ve revert for badUser only.
        vm.mockCallRevert(
            address(ve), abi.encodeWithSignature("getShareholderLockParams(address)", badUser), "MOCK_REVERT"
        );

        address[] memory users = new address[](3);
        users[0] = goodUser;
        users[1] = badUser;
        users[2] = goodUser2;

        // Must not revert — badUser failure is silently skipped.
        royalties.checkpointUserBatch(users, 3);

        // Good users should have been checkpointed (userEthPerVePaid updated).
        assertEq(royalties.userEthPerVePaid(goodUser), 1e18, "goodUser must be checkpointed");
        assertEq(royalties.userEthPerVePaid(goodUser2), 1e18, "goodUser2 must be checkpointed");
    }

    function testOverflowCap_DefersPreserveQueryBetweenOldTailAndNew() public {
        // When storage is blocked, queries in the pinned gap must keep returning
        // the pre-existing tail snapshot until a safe eviction becomes possible.
        uint40 baseTs = uint40(block.timestamp) + 100;
        vm.warp(baseTs + 100);
        _setupFullOverflow(baseTs, 1);

        (uint40 origTailTs, uint256 origTailCum,) = royalties.getOverflowCheckpoint(OV_CAP - 1);

        // Warp slightly ahead so all entries remain in horizon.
        // OV_CAP = 50_000 ≪ type(uint40).max.
        // forge-lint: disable-next-line(unsafe-typecast)
        uint40 warpTarget = baseTs + uint40(OV_CAP) + 10;
        vm.warp(warpTarget);
        assertFalse(royalties.exposed_canStoreRewardCheckpoint(warpTarget), "unsafe distinct timestamp must be blocked");

        royalties.setEthPerVe(888e18);
        royalties.setEthPerVeTimeWeighted(888e18 * uint256(warpTarget));

        vm.expectRevert(Errors.InvariantViolation.selector);
        royalties.exposed_storeRewardCheckpoint(warpTarget);

        // Query a timestamp strictly between old tail and new flush.
        uint256 queryTs = uint256(origTailTs) + 1;
        assertTrue(queryTs < warpTarget, "query must be between old tail and new ts");
        (uint256 idx,) = royalties.exposed_getRewardPrefixBefore(queryTs);

        assertEq(idx, origTailCum, "blocked write must preserve the historical tail snapshot");
    }

    // ------------------------------------------------------------------
    // Ring-buffer: binary search across wrap boundary
    // ------------------------------------------------------------------

    function testOverflowCap_BinarySearchAcrossWrap() public {
        _setupFullArray();

        // Build a small overflow array manually (5 entries, cap reduced via assembly).
        // Simulate: physical layout after two evictions:
        //   physical: [newest-1, newest, oldest, old+1, old+2]
        //   head = 2
        //   logical order: [oldest, old+1, old+2, newest-1, newest]
        uint256 smallCap = 5;
        royalties.forceSetOverflowArrayLength(smallCap);
        // Physical [0]: ts=500, cum=500e18  (newest-1)
        royalties.setOverflowCheckpointAt(0, 500, 500e18, 500e18 * 500);
        // Physical [1]: ts=600, cum=600e18  (newest)
        royalties.setOverflowCheckpointAt(1, 600, 600e18, 600e18 * 600);
        // Physical [2]: ts=100, cum=100e18  (oldest / head)
        royalties.setOverflowCheckpointAt(2, 100, 100e18, 100e18 * 100);
        // Physical [3]: ts=200, cum=200e18
        royalties.setOverflowCheckpointAt(3, 200, 200e18, 200e18 * 200);
        // Physical [4]: ts=300, cum=300e18
        royalties.setOverflowCheckpointAt(4, 300, 300e18, 300e18 * 300);

        royalties.setOverflowRingHead(2);

        // Query between logical entries:
        // ts=150 → should return oldest (100e18)
        (uint256 a,) = royalties.exposed_getRewardPrefixBefore(150);
        assertEq(a, 100e18, "query 150: must return 100e18 (oldest)");

        // ts=250 → should return 200e18
        (uint256 b,) = royalties.exposed_getRewardPrefixBefore(250);
        assertEq(b, 200e18, "query 250: must return 200e18");

        // ts=450 → should return 300e18
        (uint256 c,) = royalties.exposed_getRewardPrefixBefore(450);
        assertEq(c, 300e18, "query 450: must return 300e18");

        // ts=550 → should return 500e18
        (uint256 d,) = royalties.exposed_getRewardPrefixBefore(550);
        assertEq(d, 500e18, "query 550: must return 500e18");

        // ts=700 → past newest → return 600e18
        (uint256 e,) = royalties.exposed_getRewardPrefixBefore(700);
        assertEq(e, 600e18, "query 700: must return 600e18 (latest)");

        // ts=50 → before oldest → should fall through to main array
        (uint256 f,) = royalties.exposed_getRewardPrefixBefore(50);
        // Main array sentinel at index 0 has ts=1000 which is > 50,
        // so binary search on main array returns (0, 0).
        assertEq(f, 0, "query 50: before all overflow, falls to main array");
    }

    // ------------------------------------------------------------------
    // Ring-buffer: _latestRewardTimestamp tracks the most-recent write
    // ------------------------------------------------------------------

    function testOverflowCap_LatestTimestampTracksRingTail() public {
        _setupFullArray();

        // Small ring: 3 entries, head=1 means physical[1] is oldest,
        // physical[0] is newest (last written).
        royalties.forceSetOverflowArrayLength(3);
        royalties.setOverflowCheckpointAt(0, 300, 300e18, 300e18 * 300); // newest
        royalties.setOverflowCheckpointAt(1, 100, 100e18, 100e18 * 100); // oldest (head)
        royalties.setOverflowCheckpointAt(2, 200, 200e18, 200e18 * 200);
        royalties.setOverflowRingHead(1);

        assertEq(royalties.exposed_latestRewardTimestamp(), 300, "must return newest (physical[0])");
    }

    // ------------------------------------------------------------------
    // Ring-buffer: same-block coalescing at overflow cap
    // ------------------------------------------------------------------

    function testOverflowCap_SameBlockCoalesceAtCap() public {
        uint40 baseTs = 1000;
        _setupFullOverflow(baseTs, 1000);

        vm.warp(uint256(baseTs) + Constants.MAX_LOCK_DURATION + 1);

        uint40 newTs = uint40(block.timestamp);

        // First write evicts oldest.
        royalties.setEthPerVe(100e18);
        royalties.setEthPerVeTimeWeighted(100e18 * uint256(newTs));
        royalties.exposed_storeRewardCheckpoint(newTs);
        uint256 headAfterFirst = royalties.getOverflowRingHead();
        assertEq(headAfterFirst, 1);

        // Second write at same timestamp — should coalesce, not evict again.
        royalties.setEthPerVe(200e18);
        royalties.setEthPerVeTimeWeighted(200e18 * uint256(newTs));
        royalties.exposed_storeRewardCheckpoint(newTs);

        assertEq(royalties.getOverflowRingHead(), 1, "head must not advance on coalesce");

        // The coalesced entry should have the updated value.
        (uint40 coalTs, uint256 coalCum,) = royalties.getOverflowCheckpoint(0);
        assertEq(coalTs, newTs);
        assertEq(coalCum, 200e18, "coalesced entry must have updated cumulative");
    }

    // ------------------------------------------------------------------
    // CR137-01: Repeated blocked writes leave history unchanged until eviction is safe
    // ------------------------------------------------------------------

    function testOverflowCap_RepeatedBlockedWritesLeaveHistoryUnchanged() public {
        uint40 baseTs = uint40(block.timestamp) + 100;
        vm.warp(baseTs + 100);
        _setupFullOverflow(baseTs, 1);

        (uint40 origTailTs, uint256 origTailCum,) = royalties.getOverflowCheckpoint(OV_CAP - 1);

        for (uint256 i = 0; i < 5; i++) {
            // OV_CAP = 50_000, i < 5; both casts ≪ type(uint40).max.
            // forge-lint: disable-next-line(unsafe-typecast)
            uint40 warpTarget = baseTs + uint40(OV_CAP) + 10 + uint40(i) * 100;
            vm.warp(warpTarget);
            uint256 cumVal = (i + 1) * 100e18;
            assertFalse(
                royalties.exposed_canStoreRewardCheckpoint(warpTarget),
                "distinct timestamps inside the active horizon must remain blocked"
            );
            royalties.setEthPerVe(cumVal);
            royalties.setEthPerVeTimeWeighted(cumVal * uint256(warpTarget));

            vm.expectRevert(Errors.InvariantViolation.selector);
            royalties.exposed_storeRewardCheckpoint(warpTarget);

            assertEq(royalties.getOverflowRingHead(), 0, "head must stay 0 while writes are blocked");

            (uint40 tailTs, uint256 tailCum,) = royalties.getOverflowCheckpoint(OV_CAP - 1);
            assertEq(tailTs, origTailTs, "tail timestamp must remain pinned until eviction is safe");
            assertEq(tailCum, origTailCum, "tail cumulative must remain unchanged while writes are blocked");
        }

        (uint256 idx,) = royalties.exposed_getRewardPrefixBefore(uint256(origTailTs) + 1);
        assertEq(idx, origTailCum, "query in the pinned gap must remain on the historical tail snapshot");
    }

    function testOverflowCap_FlushDefersWithoutMutatingIndicesWhenStorageBlocked() public {
        _setupFullArray();

        uint40 baseTs = uint40(block.timestamp) + 100;
        vm.warp(baseTs + 100);
        _setupFullOverflow(baseTs, 1);

        // OV_CAP = 50_000 ≪ type(uint40).max.
        // forge-lint: disable-next-line(unsafe-typecast)
        uint40 blockedTs = baseTs + uint40(OV_CAP) + 10;
        vm.warp(blockedTs);
        ve.setGlobalLastTs(block.timestamp);
        ve.setTotalVeCached(100e18);

        royalties.setEthPerVe(777e18);
        royalties.setEthPerVeTimeWeighted(777e18 * uint256(blockedTs - 1));

        assertFalse(
            royalties.exposed_canStoreRewardCheckpoint(blockedTs), "flush should defer while storage is blocked"
        );

        uint256 ethPerVeBefore = royalties.ethPerVe();
        uint256 twBefore = royalties.exposed_ethPerVeTimeWeighted();
        uint256 pendingBefore = royalties.pendingShareholderETH();
        uint256 headBefore = royalties.getOverflowRingHead();
        (uint40 tailTsBefore, uint256 tailCumBefore,) = royalties.getOverflowCheckpoint(OV_CAP - 1);

        _takeover(1 ether);

        assertEq(royalties.pendingShareholderETH(), pendingBefore + 1 ether, "pending ETH must remain queued");
        assertEq(royalties.ethPerVe(), ethPerVeBefore, "ethPerVe must not advance while storage is blocked");
        assertEq(
            royalties.exposed_ethPerVeTimeWeighted(),
            twBefore,
            "time-weighted index must not advance while storage is blocked"
        );
        assertEq(royalties.getOverflowRingHead(), headBefore, "ring head must not move while storage is blocked");
        (uint40 tailTsAfter, uint256 tailCumAfter,) = royalties.getOverflowCheckpoint(OV_CAP - 1);
        assertEq(tailTsAfter, tailTsBefore, "tail timestamp must stay unchanged while flush is deferred");
        assertEq(tailCumAfter, tailCumBefore, "tail cumulative must stay unchanged while flush is deferred");
    }

    function testOverflowCap_DeferralResolvesWhenOldestExpires() public {
        uint40 baseTs = uint40(block.timestamp) + 100;
        vm.warp(baseTs + 100);
        _setupFullOverflow(baseTs, 1);

        // OV_CAP = 50_000 ≪ type(uint40).max.
        // forge-lint: disable-next-line(unsafe-typecast)
        uint40 blockedTs = baseTs + uint40(OV_CAP) + 10;
        vm.warp(blockedTs);
        assertFalse(royalties.exposed_canStoreRewardCheckpoint(blockedTs), "unsafe write must be blocked");

        royalties.setEthPerVe(111e18);
        royalties.setEthPerVeTimeWeighted(111e18 * uint256(blockedTs));
        vm.expectRevert(Errors.InvariantViolation.selector);
        royalties.exposed_storeRewardCheckpoint(blockedTs);
        assertEq(royalties.getOverflowRingHead(), 0, "head must stay unchanged while storage is blocked");

        // Now warp past MAX_LOCK_DURATION so oldest entry (ts=baseTs) expires.
        uint256 warpTo = uint256(baseTs) + Constants.MAX_LOCK_DURATION + 1;
        vm.warp(warpTo);

        // warpTo = baseTs + MAX_LOCK_DURATION + 1 (≈3.15e7) ≪ type(uint40).max.
        // forge-lint: disable-next-line(unsafe-typecast)
        uint40 evictTs = uint40(warpTo);
        assertTrue(royalties.exposed_canStoreRewardCheckpoint(evictTs), "write must resume once oldest entry ages out");
        royalties.setEthPerVe(222e18);
        royalties.setEthPerVeTimeWeighted(222e18 * uint256(evictTs));
        royalties.exposed_storeRewardCheckpoint(evictTs);

        // Head must have advanced — FIFO eviction resumed.
        assertEq(royalties.getOverflowRingHead(), 1, "FIFO eviction must resume after oldest expires");

        // Evicted slot (physical 0) now holds the new entry.
        (uint40 slot0Ts, uint256 slot0Cum,) = royalties.getOverflowCheckpoint(0);
        assertEq(slot0Ts, evictTs, "evicted slot must hold new timestamp");
        assertEq(slot0Cum, 222e18, "evicted slot must hold new cumulative");
    }
}
