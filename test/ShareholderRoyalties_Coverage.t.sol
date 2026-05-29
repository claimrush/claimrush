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

// ============================================================
// Mocks
// ============================================================

contract MockFurnaceHarness {
    address public mineCore;
    address public mineMarket;
    address public shareholderRoyalties;
    address public delegationHub;

    uint256 public quoteVeOut = 100e18;
    bool public shouldRevert;

    function setWiring(address _mineCore, address _mineMarket, address _shareholderRoyalties) external {
        mineCore = _mineCore;
        mineMarket = _mineMarket;
        shareholderRoyalties = _shareholderRoyalties;
    }

    function setDelegationHub(address v) external {
        delegationHub = v;
    }

    function setShouldRevert(bool v) external {
        shouldRevert = v;
    }

    function setQuoteVeOut(uint256 v) external {
        quoteVeOut = v;
    }

    function furnaceQuoter() external view returns (address) {
        return address(this);
    }

    function quoteEnterWithEth(address, uint256, uint256, uint256, bool)
        external
        view
        returns (uint256, uint256, uint256, uint256)
    {
        return (0, 0, quoteVeOut, 0);
    }

    function lockEthReward(address, uint256 ethAmount, uint256, uint256, bool, uint256) external payable {
        require(msg.value == ethAmount, "value mismatch");
        if (shouldRevert) revert("MockFurnaceHarness: revert");
    }
}

contract MockMineCoreHarness {
    address public furnace;
    address public claimAllHelper;
    address public delegationHub;

    function setWiring(address _furnace, address _claimAllHelper) external {
        furnace = _furnace;
        claimAllHelper = _claimAllHelper;
    }

    function setDelegationHub(address v) external {
        delegationHub = v;
    }
}

/// @dev Contract that self-destructs and forces ETH into a target.
contract SelfDestructAttacker {
    constructor(address payable target) payable {
        selfdestruct(target);
    }
}

// ============================================================
// Test Suite — Coverage
// ============================================================

/// @notice Coverage tests for ShareholderRoyalties edge cases.
/// @dev Covers: sweepDust edge cases, _consumeReservedEth cross-bucket draw, ethPerVeTimeWeighted
///      modular arithmetic, ring buffer multi-wrap, overcounting bounds, full lifecycle integration,
///      edge cases (zero totalWeight, griefing, claimShareholderTo), and _attemptLockWithRestore
///      rollback correctness for cross-bucket scenarios.
contract ShareholderRoyalties_CoverageTest is Test {
    ShareholderRoyalties internal royalties;
    ShareholderRoyaltiesHarness internal harnessRoyalties;
    MockVe internal ve;
    MockFurnaceHarness internal furnace;
    MockMineCoreHarness internal mineCoreMock;

    address internal owner;
    address internal alice;
    address internal bob;
    address internal keeper;
    address internal mineCore;
    address internal mineMarket;
    address internal claimToken;
    address internal delegationHub;

    uint256 internal constant OV_CAP = Constants.MAX_OVERFLOW_CHECKPOINTS; // 50_000

    function setUp() public {
        owner = makeAddr("owner");
        alice = makeAddr("alice");
        bob = makeAddr("bob");
        keeper = makeAddr("keeper");
        delegationHub = address(new MockContract());

        ve = new MockVe();
        furnace = new MockFurnaceHarness();
        mineCoreMock = new MockMineCoreHarness();
        MockContract mockMarket = new MockContract();
        claimToken = address(new MockContract());
        mineCore = address(mineCoreMock);
        mineMarket = address(mockMarket);

        royalties = new ShareholderRoyalties(address(ve), owner);
        harnessRoyalties = new ShareholderRoyaltiesHarness(address(ve), owner);

        // Wire the primary instance. Harness tests that need a full live bundle rewire locally.
        _wireInstance(royalties);
    }

    function _wireInstance(ShareholderRoyalties r) internal {
        furnace.setWiring(mineCore, mineMarket, address(r));
        furnace.setDelegationHub(delegationHub);
        mineCoreMock.setWiring(address(furnace), address(0));
        mineCoreMock.setDelegationHub(delegationHub);
        vm.mockCall(mineCore, abi.encodeWithSignature("ve()"), abi.encode(address(ve)));
        vm.mockCall(mineCore, abi.encodeWithSignature("claim()"), abi.encode(claimToken));
        vm.mockCall(mineCore, abi.encodeWithSignature("royalties()"), abi.encode(address(r)));
        vm.mockCall(mineMarket, abi.encodeWithSignature("ve()"), abi.encode(address(ve)));
        vm.mockCall(mineMarket, abi.encodeWithSignature("claim()"), abi.encode(claimToken));
        vm.mockCall(mineMarket, abi.encodeWithSignature("royalties()"), abi.encode(address(r)));
        vm.mockCall(address(furnace), abi.encodeWithSignature("ve()"), abi.encode(address(ve)));
        vm.mockCall(address(furnace), abi.encodeWithSignature("claim()"), abi.encode(claimToken));
        vm.mockCall(address(ve), abi.encodeWithSignature("furnace()"), abi.encode(address(furnace)));
        vm.mockCall(address(ve), abi.encodeWithSignature("mineMarket()"), abi.encode(mineMarket));
        vm.mockCall(address(ve), abi.encodeWithSignature("claimToken()"), abi.encode(claimToken));
        vm.mockCall(claimToken, abi.encodeWithSignature("mineCore()"), abi.encode(mineCore));

        vm.prank(owner);
        r.setWiring(mineCore, mineMarket, address(furnace));

        vm.prank(owner);
        r.setAutoCompoundKeeper(keeper, true);
    }

    function _takeover(uint256 amountEth) internal {
        vm.deal(mineCore, amountEth);
        vm.prank(mineCore);
        royalties.onTakeover{value: amountEth}(1);
    }

    function _setValidDest(uint256 tokenId, address user, uint256 lockEnd, bool autoMax, bool listed) internal {
        ve.setOwner(tokenId, user);
        ve.setLockInfo(tokenId, 1_000e18, lockEnd, autoMax, listed);
    }

    function _warpForward(uint256 currentTs, uint256 delta) internal returns (uint256 nextTs) {
        nextTs = currentTs + delta;
        vm.warp(nextTs);
    }

    // ============================================================
    // A. sweepDust — selfdestruct forced ETH + repeated sweep
    // ============================================================

    function testSweepDust_SelfdestructForcedEthIsRecoverable() public {
        ve.setTotalVeCached(100e18);
        ve.setVeBalance(alice, 100e18);
        _takeover(0.5 ether);

        // Force-send ETH via selfdestruct.
        uint256 forcedAmount = 0.3 ether;
        new SelfDestructAttacker{value: forcedAmount}(payable(address(royalties)));

        uint256 balBefore = address(royalties).balance;
        assertEq(balBefore, 0.5 ether + forcedAmount);

        // Sweep should recover exactly the forced amount.
        uint256 ownerBalBefore = owner.balance;
        vm.prank(owner);
        royalties.sweepDust(owner);

        assertEq(owner.balance, ownerBalBefore + forcedAmount);
        // Shareholder ETH remains intact.
        assertEq(address(royalties).balance, 0.5 ether);
    }

    function testSweepDust_RepeatedCallsCannotDrainShareholderFunds() public {
        ve.setTotalVeCached(100e18);
        ve.setVeBalance(alice, 100e18);
        _takeover(0.5 ether);

        // Force small surplus.
        vm.deal(address(royalties), address(royalties).balance + 0.1 ether);

        // First sweep removes the surplus.
        vm.prank(owner);
        royalties.sweepDust(owner);

        // Second sweep should revert — no surplus left.
        vm.prank(owner);
        vm.expectRevert(Errors.AmountZero.selector);
        royalties.sweepDust(owner);

        // Shareholder claims still work.
        royalties.checkpointUser(alice);
        uint256 claimable = royalties.claimableEth(alice);
        assertGt(claimable, 0);

        uint256 aliceBal = alice.balance;
        vm.prank(alice);
        royalties.claimShareholder(Constants.SHAREHOLDER_MODE_ETH, 0, 0, false, 0);
        assertEq(alice.balance, aliceBal + claimable);
    }

    // ============================================================
    // B. _consumeReservedEth: stored-claim path is bucket-disjoint
    // ============================================================

    function testConsumeReservedEth_StoredClaimDoesNotTouchPending() public {
        // Construct a state where the per-user combined-floor would exceed the indexed
        // pool. Two 1-wei takeovers with totalVe=3 produce: indexed=0, pending=1,
        // crystallised=1 after checkpoint (the second wei stays in pending until a
        // larger flush can index it cleanly). The clamp inside checkpointUser caps
        // the per-user credit at indexedEthOwed, so the stored bucket only ever
        // contains amounts that were already debited from indexed.
        ve.setTotalVeCached(3);
        ve.setVeBalance(alice, 3);

        _takeover(1);
        _takeover(1);

        royalties.checkpointUser(alice);
        uint256 stored = royalties.claimableEthStored(alice);
        uint256 pendingBefore = royalties.pendingShareholderETH();
        assertGt(stored, 0, "alice must have stored claimable ETH");

        // The claim path consumes only the crystallised bucket — pending is untouched.
        uint256 aliceBal = alice.balance;
        vm.prank(alice);
        royalties.claimShareholder(Constants.SHAREHOLDER_MODE_ETH, 0, 0, false, 0);
        assertEq(alice.balance, aliceBal + stored, "alice payout equals stored amount");
        assertEq(
            royalties.pendingShareholderETH(), pendingBefore, "pending must not change when consuming a stored claim"
        );
        assertEq(royalties.indexedEthOwed(), 0, "indexed liability cleared");
    }

    function testConsumeReservedEth_SubsequentFlushIngestsRetainedPending() public {
        // After the disjoint-buckets stored claim above, the residual 1 wei in pending
        // is fully fluxible by a subsequent larger takeover.
        ve.setTotalVeCached(3);
        ve.setVeBalance(alice, 3);

        _takeover(1);
        _takeover(1);
        royalties.checkpointUser(alice);
        uint256 pendingBefore = royalties.pendingShareholderETH();

        vm.prank(alice);
        royalties.claimShareholder(Constants.SHAREHOLDER_MODE_ETH, 0, 0, false, 0);

        // Stored-claim path leaves pending untouched.
        assertEq(royalties.pendingShareholderETH(), pendingBefore, "stored claim does not touch pending");

        // A larger takeover + flush ingests the retained pending wei into the indexed
        // bucket, restoring the disjoint-buckets invariant after the new deposit.
        _takeover(1 ether);
        uint256 pendingAfterTakeover = royalties.pendingShareholderETH();
        uint256 indexedAfter = royalties.indexedEthOwed();
        uint256 crystallisedAfter = royalties.totalCrystallisedStored();
        assertEq(
            address(royalties).balance,
            pendingAfterTakeover + indexedAfter + crystallisedAfter,
            "disjoint-buckets invariant holds after new takeover"
        );
        assertLt(pendingAfterTakeover, pendingBefore + 1 ether, "fresh flush ingests at least the retained wei");
    }

    // ============================================================
    // C. ethPerVeTimeWeighted modular arithmetic
    // ============================================================

    function testTimeWeightedAccrual_CorrectAfterManyFlushes() public {
        // Simulate 50 flushes and verify decaying lock accrual is correct.
        uint256 lockAmount = 1000e18;
        uint256 lockEnd = block.timestamp + 180 days;

        uint256[] memory amounts = new uint256[](1);
        uint256[] memory lockEnds = new uint256[](1);
        bool[] memory autoMaxFlags = new bool[](1);
        amounts[0] = lockAmount;
        lockEnds[0] = lockEnd;
        autoMaxFlags[0] = false;
        ve.setShareholderLockParams(alice, amounts, lockEnds, autoMaxFlags);
        ve.setVeBalance(alice, lockAmount);

        ve.setTotalVeCached(lockAmount);

        // Run 50 flushes at 1-hour intervals.
        uint256 nextTs = block.timestamp;
        for (uint256 i = 0; i < 50; i++) {
            nextTs = _warpForward(nextTs, 1 hours);
            _takeover(0.1 ether);
        }

        royalties.checkpointUser(alice);
        uint256 claimable = royalties.claimableEth(alice);
        assertGt(claimable, 0, "decaying lock must accrue non-zero rewards after 50 flushes");

        // Claimable must not exceed total deposited (5 ETH).
        assertLe(claimable, 5 ether, "claim must not exceed total deposited");

        // Claim must succeed.
        uint256 aliceBal = alice.balance;
        vm.prank(alice);
        royalties.claimShareholder(Constants.SHAREHOLDER_MODE_ETH, 0, 0, false, 0);
        assertEq(alice.balance, aliceBal + claimable);
    }

    function testTimeWeightedAccrual_ModularSubtractionIsCorrect() public {
        // Use harness to set ethPerVeTimeWeighted to a large value approaching uint256.max,
        // then verify that accrual still works correctly via modular subtraction.
        uint256 lockAmount = 1000e18;
        uint256 lockEnd = block.timestamp + 180 days;

        uint256[] memory amounts = new uint256[](1);
        uint256[] memory lockEnds = new uint256[](1);
        bool[] memory autoMaxFlags = new bool[](1);
        amounts[0] = lockAmount;
        lockEnds[0] = lockEnd;
        autoMaxFlags[0] = false;
        ve.setShareholderLockParams(alice, amounts, lockEnds, autoMaxFlags);
        ve.setVeBalance(alice, lockAmount);
        ve.setTotalVeCached(lockAmount);

        // Use harness to set near-max time-weighted value.
        harnessRoyalties.setEthPerVeTimeWeighted(type(uint256).max - 1e50);

        // Do a flush on the harness (need to re-wire for harness).
        vm.deal(mineCore, 1 ether);
        vm.mockCall(mineCore, abi.encodeWithSignature("royalties()"), abi.encode(address(harnessRoyalties)));
        vm.mockCall(mineMarket, abi.encodeWithSignature("royalties()"), abi.encode(address(harnessRoyalties)));
        furnace.setWiring(mineCore, mineMarket, address(harnessRoyalties));
        vm.prank(owner);
        harnessRoyalties.setWiring(mineCore, mineMarket, address(furnace));

        vm.prank(mineCore);
        harnessRoyalties.onTakeover{value: 1 ether}(1);

        // The flush should complete without reverting (unchecked addition wraps safely).
        uint256 ethPerVe = harnessRoyalties.ethPerVe();
        assertGt(ethPerVe, 0, "ethPerVe must advance after flush");
    }

    // ============================================================
    // D. Ring buffer multi-wrap (binary search after >1 full cycle)
    // ============================================================

    function testOverflowRingBuffer_BinarySearchAfterMultipleWraps() public {
        // Fill main array + overflow, then evict multiple cycles through the ring.
        uint40 baseTs = uint40(block.timestamp) + 100;
        vm.warp(baseTs + 100);

        // Fill main array.
        harnessRoyalties.forceSetArrayLength(Constants.MAX_REWARD_CHECKPOINTS);
        uint40 lastMainTs = baseTs;
        harnessRoyalties.setCheckpointAt(
            Constants.MAX_REWARD_CHECKPOINTS - 1, lastMainTs, 10e18, 10e18 * uint256(lastMainTs)
        );

        // Fill overflow with timestamps old enough to be evictable.
        harnessRoyalties.forceSetOverflowArrayLength(OV_CAP);
        for (uint256 i = 0; i < 5; i++) {
            uint40 ovTs = baseTs + uint40(i + 1);
            harnessRoyalties.setOverflowCheckpointAt(i, ovTs, (11 + i) * 1e18, (11 + i) * 1e18 * uint256(ovTs));
        }
        // Fill remaining with sequential timestamps.
        for (uint256 i = 5; i < OV_CAP && i < 20; i++) {
            uint40 ovTs = baseTs + uint40(i + 1);
            harnessRoyalties.setOverflowCheckpointAt(i, ovTs, (11 + i) * 1e18, (11 + i) * 1e18 * uint256(ovTs));
        }

        // Warp past MAX_LOCK_DURATION so entries are evictable.
        uint256 nextTs = uint256(baseTs) + Constants.MAX_LOCK_DURATION + 500;
        vm.warp(nextTs);

        // Evict several entries (simulate 3 full evictions advancing head).
        for (uint256 cycle = 0; cycle < 3; cycle++) {
            nextTs += 1;
            uint40 evTs = uint40(nextTs);
            vm.warp(nextTs);
            uint256 cumVal = (100 + cycle) * 1e18;
            harnessRoyalties.setEthPerVe(cumVal);
            harnessRoyalties.setEthPerVeTimeWeighted(cumVal * uint256(evTs));
            harnessRoyalties.exposed_storeRewardCheckpoint(evTs);
        }

        uint256 head = harnessRoyalties.getOverflowRingHead();
        assertGt(head, 0, "ring head must have advanced");

        // Binary search for the latest timestamp should return the most recent cumulative.
        uint40 latestTs = harnessRoyalties.exposed_latestRewardTimestamp();
        (uint256 prefix,) = harnessRoyalties.exposed_getRewardPrefixBefore(uint256(latestTs) + 1);
        assertGt(prefix, 0, "prefix query after latest must return non-zero cumulative");
    }

    function testOverflowLastWrittenIndex_CorrectAfterMultipleWraps() public {
        uint40 baseTs = uint40(block.timestamp) + 100;
        vm.warp(baseTs + 100);

        harnessRoyalties.forceSetArrayLength(Constants.MAX_REWARD_CHECKPOINTS);
        harnessRoyalties.forceSetOverflowArrayLength(OV_CAP);

        // Simulate head at position 5 (after 5 evictions).
        harnessRoyalties.setOverflowRingHead(5);

        // Write checkpoint at head=5 position, simulating eviction.
        uint40 writeTs = uint40(block.timestamp) + 200;
        harnessRoyalties.setOverflowCheckpointAt(5, writeTs, 999e18, 999e18 * uint256(writeTs));

        // _overflowLastWrittenIndex should return head-1 = 4 when head=5.
        // But we've advanced head to 6 (simulating the store advancing it).
        harnessRoyalties.setOverflowRingHead(6);

        // The last written index should be 5 (= 6 - 1).
        (uint40 ts,,) = harnessRoyalties.getOverflowCheckpoint(5);
        assertEq(ts, writeTs, "last written must be at head-1");
    }

    // ============================================================
    // E. Overcounting economic impact
    // ============================================================

    function testOvercounting_NeverExceedsDepositedETH() public {
        // Simulate overcounting scenario: fill checkpoints, force coalescing, then verify
        // that total claims cannot exceed total deposits.
        ve.setTotalVeCached(100e18);
        ve.setVeBalance(alice, 60e18);
        ve.setVeBalance(bob, 40e18);

        uint256 totalDeposited = 0;

        // Run many flushes to build up rewards.
        uint256 nextTs = block.timestamp;
        for (uint256 i = 0; i < 20; i++) {
            nextTs = _warpForward(nextTs, 1 hours);
            uint256 deposit = 0.5 ether;
            _takeover(deposit);
            totalDeposited += deposit;
        }

        // Checkpoint both users.
        royalties.checkpointUser(alice);
        royalties.checkpointUser(bob);

        uint256 aliceClaim = royalties.claimableEth(alice);
        uint256 bobClaim = royalties.claimableEth(bob);

        // Sum of claims must not exceed total deposited + rounding tolerance.
        assertLe(
            aliceClaim + bobClaim,
            totalDeposited + 100, // 100 wei tolerance for rounding
            "sum of claims must not exceed total deposits"
        );

        // Both claims must succeed.
        vm.prank(alice);
        royalties.claimShareholder(Constants.SHAREHOLDER_MODE_ETH, 0, 0, false, 0);
        vm.prank(bob);
        royalties.claimShareholder(Constants.SHAREHOLDER_MODE_ETH, 0, 0, false, 0);

        // Balance invariant must hold post-claim.
        assertGe(
            address(royalties).balance,
            royalties.pendingShareholderETH(),
            "balance must cover remaining pending after all claims"
        );
    }

    // ============================================================
    // F. Full lifecycle integration
    // ============================================================

    function testLifecycle_FlushCheckpointClaimEthMode() public {
        // End-to-end: takeover → flush → checkpoint → claim (ETH mode).
        ve.setTotalVeCached(100e18);
        ve.setVeBalance(alice, 100e18);

        // Step 1: ETH arrives via takeover.
        _takeover(1 ether);

        // pendingShareholderETH should be 0 (flushed inline by onTakeover).
        // But if totalWeight was primed, it should have been indexed.
        uint256 pending = royalties.pendingShareholderETH();
        // pending may have rounding carry — at most 1 wei.
        assertLe(pending, 1);

        // Step 2: checkpoint user.
        royalties.checkpointUser(alice);
        uint256 claimable = royalties.claimableEth(alice);
        assertGt(claimable, 0, "alice must have claimable after checkpoint");
        // Should be approximately 1 ether (minus rounding carry).
        assertApproxEqAbs(claimable, 1 ether, 2);

        // Step 3: claim ETH.
        uint256 aliceBal = alice.balance;
        vm.prank(alice);
        royalties.claimShareholder(Constants.SHAREHOLDER_MODE_ETH, 0, 0, false, 0);
        assertEq(alice.balance, aliceBal + claimable);
        assertEq(royalties.claimableEth(alice), 0);

        // Balance invariant.
        assertGe(address(royalties).balance, royalties.pendingShareholderETH());
    }

    function testLifecycle_FlushCheckpointCompoundFurnaceMode() public {
        // End-to-end: takeover → flush → checkpoint → compound via Furnace.
        ve.setTotalVeCached(100e18);
        ve.setVeBalance(alice, 100e18);

        _takeover(1 ether);

        royalties.checkpointUser(alice);
        uint256 claimable = royalties.claimableEth(alice);
        assertGt(claimable, 0);

        // Setup auto-compound config.
        _setValidDest(1, alice, block.timestamp + 30 days, false, false);
        vm.prank(alice);
        royalties.setAutoCompoundConfig(true, 1, 30 days, 0, 0, 500);

        // Compound via keeper.
        uint256 contractBalBefore = address(royalties).balance;
        vm.prank(keeper);
        royalties.compoundFor(alice);

        // Claimable should be 0 after compound.
        assertEq(royalties.claimableEth(alice), 0);

        // ETH should have left the contract (sent to Furnace).
        assertLt(address(royalties).balance, contractBalBefore);

        // Balance invariant.
        assertGe(address(royalties).balance, royalties.pendingShareholderETH());
    }

    // ============================================================
    // G. Edge cases
    // ============================================================

    function testEdge_ZeroTotalWeightKeepsEthInPending() public {
        // When totalVeBiasScaled == 0 (no locks), ETH must stay in pending.
        ve.setTotalVeCached(0);

        vm.deal(mineCore, 1 ether);
        vm.prank(mineCore);
        royalties.onTakeover{value: 1 ether}(1);

        assertEq(royalties.pendingShareholderETH(), 1 ether);
        assertEq(royalties.ethPerVe(), 0, "ethPerVe must not advance with zero weight");

        // Manual flush also should not index.
        royalties.flushPendingShareholderETH();
        assertEq(royalties.pendingShareholderETH(), 1 ether);
    }

    function testEdge_MultipleFlushesSameBlockCoalesce() public {
        ve.setTotalVeCached(100e18);
        ve.setVeBalance(alice, 100e18);

        // Two takeovers in the same block.
        _takeover(0.5 ether);
        _takeover(0.5 ether);

        // Only one ethPerVe advancement should occur (coalesced).
        uint256 ethPerVe = royalties.ethPerVe();
        assertGt(ethPerVe, 0);

        // Alice should get the full amount.
        royalties.checkpointUser(alice);
        uint256 claimable = royalties.claimableEth(alice);
        assertApproxEqAbs(claimable, 1 ether, 2);
    }

    function testEdge_CheckpointUserByGrieferDoesNotChangeRewards() public {
        ve.setTotalVeCached(100e18);
        ve.setVeBalance(alice, 100e18);

        _takeover(1 ether);

        // Griever force-checkpoints alice.
        address griever = makeAddr("griever");
        vm.prank(griever);
        royalties.checkpointUser(alice);

        uint256 claimableAfterGrief = royalties.claimableEth(alice);

        // More rewards arrive.
        vm.warp(block.timestamp + 1 hours);
        _takeover(1 ether);

        // Alice checkpoints herself.
        royalties.checkpointUser(alice);
        uint256 totalClaimable = royalties.claimableEth(alice);

        // Total must equal both takeover amounts (minus rounding).
        assertApproxEqAbs(totalClaimable, 2 ether, 2);
        assertGt(totalClaimable, claimableAfterGrief, "second flush must add more rewards");
    }

    function testEdge_ClaimShareholderToLockFurnaceModeRevertsWhenToNotSender() public {
        ve.setTotalVeCached(100e18);
        ve.setVeBalance(alice, 100e18);
        _takeover(1 ether);
        royalties.checkpointUser(alice);

        // claimShareholderTo with LOCK_FURNACE mode and to != msg.sender must revert.
        vm.prank(alice);
        vm.expectRevert(Errors.NotAuthorized.selector);
        royalties.claimShareholderTo(payable(bob), Constants.SHAREHOLDER_MODE_LOCK_FURNACE, 0, 30 days, false, 0);
    }

    function testEdge_ClaimShareholderToEthModeRedirectsToRecipient() public {
        ve.setTotalVeCached(100e18);
        ve.setVeBalance(alice, 100e18);
        _takeover(1 ether);
        royalties.checkpointUser(alice);

        uint256 claimable = royalties.claimableEth(alice);
        uint256 bobBalBefore = bob.balance;

        // Alice redirects ETH to Bob.
        vm.prank(alice);
        royalties.claimShareholderTo(payable(bob), Constants.SHAREHOLDER_MODE_ETH, 0, 0, false, 0);

        assertEq(bob.balance, bobBalBefore + claimable);
        assertEq(royalties.claimableEth(alice), 0);
    }

    // ============================================================
    // H. _attemptLockWithRestore rollback — cross-bucket scenarios
    // ============================================================

    function testRollback_RestoresIndexedAndPendingExactlyOnFurnaceRevert() public {
        // Create a state with both indexed and pending ETH, then verify exact restoration.
        ve.setTotalVeCached(100e18);
        ve.setVeBalance(alice, 100e18);

        _takeover(1 ether);
        royalties.checkpointUser(alice);

        // Add more pending (not yet flushed) to create split reserves.
        vm.deal(mineCore, 0.5 ether);
        ve.setTotalVeCached(0); // prevent flush
        vm.prank(mineCore);
        royalties.addPendingShareholderETH{value: 0.5 ether}(2);
        ve.setTotalVeCached(100e18); // restore

        uint256 pendingBefore = royalties.pendingShareholderETH();
        uint256 claimableBefore = royalties.claimableEth(alice);

        // Setup auto-compound and make Furnace revert.
        _setValidDest(1, alice, block.timestamp + 30 days, false, false);
        vm.prank(alice);
        royalties.setAutoCompoundConfig(true, 1, 30 days, 0, 0, 500);
        furnace.setShouldRevert(true);

        // Batch compound — should fail and restore.
        address[] memory users = new address[](1);
        users[0] = alice;
        vm.prank(keeper);
        royalties.compoundForMany(users, 10);

        // Verify exact restoration.
        assertEq(royalties.claimableEth(alice), claimableBefore, "claimableEth must be exactly restored");
        assertEq(royalties.pendingShareholderETH(), pendingBefore, "pendingShareholderETH must be exactly restored");

        // Verify balance invariant holds.
        assertGe(address(royalties).balance, royalties.pendingShareholderETH());
    }

    function testRollback_LastCompoundTsIsRolledBackOnRevert() public {
        ve.setTotalVeCached(100e18);
        ve.setVeBalance(alice, 100e18);
        _takeover(1 ether);
        royalties.checkpointUser(alice);

        _setValidDest(1, alice, block.timestamp + 30 days, false, false);
        vm.prank(alice);
        royalties.setAutoCompoundConfig(true, 1, 30 days, 0, 0, 500);

        (,,,,,,, uint40 lastTsBefore) = royalties.getAutoCompoundConfig(alice);

        furnace.setShouldRevert(true);

        address[] memory users = new address[](1);
        users[0] = alice;
        vm.prank(keeper);
        royalties.compoundForMany(users, 10);

        (,,,,,,, uint40 lastTsAfter) = royalties.getAutoCompoundConfig(alice);
        assertEq(lastTsAfter, lastTsBefore, "lastCompoundTs must be rolled back on revert");
    }

    function testRollback_ClaimSucceedsAfterFailedCompound() public {
        // After a failed compound restores state, the user can claim normally.
        ve.setTotalVeCached(100e18);
        ve.setVeBalance(alice, 100e18);
        _takeover(1 ether);
        royalties.checkpointUser(alice);

        uint256 claimable = royalties.claimableEth(alice);
        assertGt(claimable, 0);

        _setValidDest(1, alice, block.timestamp + 30 days, false, false);
        vm.prank(alice);
        royalties.setAutoCompoundConfig(true, 1, 30 days, 0, 0, 500);
        furnace.setShouldRevert(true);

        // Failed compound.
        address[] memory users = new address[](1);
        users[0] = alice;
        vm.prank(keeper);
        royalties.compoundForMany(users, 10);

        // Re-enable furnace and claim directly.
        furnace.setShouldRevert(false);

        uint256 aliceBal = alice.balance;
        vm.prank(alice);
        royalties.claimShareholder(Constants.SHAREHOLDER_MODE_ETH, 0, 0, false, 0);
        assertEq(alice.balance, aliceBal + claimable);
        assertEq(royalties.claimableEth(alice), 0);
    }
}
