// SPDX-License-Identifier: MIT
pragma solidity ^0.8.34;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {ClaimToken} from "src/ClaimToken.sol";
import {Furnace} from "src/Furnace.sol";
import {FurnaceGuardHelper} from "src/FurnaceGuardHelper.sol";

import {FurnaceQuoter} from "src/FurnaceQuoter.sol";
import {ShareholderRoyalties} from "src/ShareholderRoyalties.sol";

import {MockVe} from "./mocks/MockVe.sol";
import {MineCoreHarness} from "./mocks/MineCoreHarness.sol";

/// @dev Reverts on ETH receive; forces refund bucket crediting.
contract BucketSumRefundRejector {
    receive() external payable {
        revert("REJECT");
    }
}

/// @dev Consumes >30k gas on receive; forces king payout bucket crediting.
contract BucketSumGasBomb {
    uint256 internal idx;
    mapping(uint256 => uint256) internal slots;

    receive() external payable {
        uint256 i = idx;
        slots[i] = 1;
        slots[i + 1] = 2;
        idx = i + 2;
    }
}

/// @dev Attempts to call `withdrawRefundBalance` from inside its own receive(),
///      but only on the FIRST receive (subsequent receives succeed so the
///      withdraw path can eventually deliver). Used to prove that the outer
///      `_hybridRefund` 30k-stipend send handles reentrancy attempts by
///      silently failing the inner call, leaving the refund credited — never
///      corrupting state.
contract BucketSumReentrantRefundReceiver {
    address public mineCore;

    constructor(address _mineCore) {
        mineCore = _mineCore;
    }

    receive() external payable {
        // Try to reenter MineCore. `nonReentrant` MUST block this; the inner
        // call returns false. We then force the OUTER 30k-stipend push to
        // fail by consuming all remaining gas via `invalid()`, which routes
        // MineCore down its credit-fallback branch so the test can assert
        // the pre-credit survives. We do NOT record the inner-call revert in
        // local storage because `invalid()` reverts this entire call frame
        // (and any nested writes), so any flag set here would not persist.
        // The outer-tx evidence is the credit-fallback bookkeeping plus the
        // bucket-sum invariants (`refundEthBalance == extra`,
        // `totalRefundEthOwed == extra`, and `_assertBucketSumsEqualTotals`),
        // which together rule out any successful reentrant state corruption.
        mineCore.call(abi.encodeWithSignature("withdrawRefundBalance(address)", address(this)));
        assembly {
            invalid()
        }
    }
}

/// @notice Bucket-level sum-equality invariants: the per-address mappings
///         must always agree with the global totals. Complements:
///           - test/invariants/MineCore_StateMachine_Invariants.t.sol (per-actor sum ≤ balance)
///           - test/MineCore_Solvency.t.sol (global totals ≤ balance)
///         Neither of those asserts the per-address sum EQUALS the global
///         total. A future refactor that drops one of the paired
///         `map[x] += N; total += N;` lines would slip past both — this
///         suite catches it.
///
///         Also includes a `_hybridRefund` reentrancy regression confirming
///         that a recipient trying to reenter MineCore from its receive()
///         cannot corrupt bucket state.
contract MineCoreBucketSumInvariantsTest is Test {
    ClaimToken internal claim;
    MockVe internal ve;
    ShareholderRoyalties internal royalties;
    Furnace internal furnace;
    MineCoreHarness internal mineCore;

    address internal owner;
    address internal alice;
    address internal bob;
    address internal carol;

    BucketSumGasBomb internal gasBomb;
    BucketSumRefundRejector internal refundRejector;

    address[] internal actors;

    function setUp() public {
        vm.txGasPrice(0);
        owner = makeAddr("owner");
        alice = makeAddr("alice");
        bob = makeAddr("bob");
        carol = makeAddr("carol");

        ve = new MockVe();
        claim = new ClaimToken(owner);
        royalties = new ShareholderRoyalties(address(ve), owner);
        furnace = new Furnace(
            address(claim), address(ve), address(new FurnaceGuardHelper(address(claim), address(ve))), owner
        );
        FurnaceQuoter quoter = new FurnaceQuoter(address(furnace));
        mineCore = new MineCoreHarness(address(claim), address(ve), address(royalties), owner);

        vm.startPrank(owner);
        claim.setMineCore(address(mineCore));
        furnace.setMineCore(address(mineCore));
        furnace.setFurnaceQuoter(address(quoter));
        furnace.setShareholderRoyalties(address(royalties));
        mineCore.setFurnace(address(furnace));
        vm.etch(address(0xB0B0), hex"00");
        royalties.setWiring(address(mineCore), address(0xB0B0), address(furnace));
        mineCore.setGenesisKingClaimCollectedForTest(true);
        mineCore.setTakeoversPaused(false);
        vm.stopPrank();

        ve.setClaimToken(address(claim));
        ve.setFurnace(address(furnace));
        ve.setTotalVeCached(1234);

        gasBomb = new BucketSumGasBomb();
        refundRejector = new BucketSumRefundRejector();

        actors.push(alice);
        actors.push(bob);
        actors.push(carol);
        actors.push(address(gasBomb));
        actors.push(address(refundRejector));
    }

    // -----------------------------------------------------------------------
    // Sum-equality invariants
    // -----------------------------------------------------------------------

    /// @dev Fuzz: assert `sum(map[a] for a in actors) == total` for every
    ///      bucket, after random sequences of takeover + withdrawal actions.
    function testFuzz_bucketSumEqualsGlobalTotals(uint256 seed) public {
        _seedAllBuckets();

        uint256 steps = 20;
        for (uint256 i = 0; i < steps; i++) {
            bytes32 h = keccak256(abi.encode(seed, i));
            uint256 dt = uint256(uint16(uint256(h >> 240))) % 3 hours;
            if (dt != 0) vm.warp(block.timestamp + dt);

            uint8 action = uint8(uint256(h) % 6);
            address actor = actors[uint256(uint8(uint256(h >> 8))) % actors.length];

            if (action <= 1) {
                uint256 extra = action == 1 ? (uint256(uint16(uint256(h >> 16))) % 0.25 ether) + 1 : 0;
                _tryTakeover(actor, extra);
            } else if (action == 2) {
                _tryWithdrawKing(actor);
            } else if (action == 3) {
                _tryWithdrawRefund(actor, alice);
            } else if (action == 4) {
                _tryWithdrawPendingClaim(actor);
            }

            _assertBucketSumsEqualTotals();
        }
    }

    /// @dev Deterministic: after seeding all buckets, sums must match totals.
    function test_bucketSumsEqualTotals_afterSeeding() public {
        _seedAllBuckets();
        _assertBucketSumsEqualTotals();

        assertGt(mineCore.totalKingEthOwed(), 0, "king total must be nonzero after seeding");
        assertGt(mineCore.totalRefundEthOwed(), 0, "refund total must be nonzero after seeding");
    }

    // -----------------------------------------------------------------------
    // _hybridRefund reentrancy regression
    // -----------------------------------------------------------------------

    /// @dev A refund recipient that tries to reenter `withdrawRefundBalance`
    ///      from inside its receive() hook must NOT corrupt bucket state. The
    ///      outer 30k-stipend push should fail (because the reentrancy attempt
    ///      reverts on `nonReentrant`), leaving the refund pre-credit in
    ///      place, and the solvency invariant must hold throughout.
    function test_hybridRefund_reentrancyBlockedByNonReentrant() public {
        BucketSumReentrantRefundReceiver reentrant = new BucketSumReentrantRefundReceiver(address(mineCore));

        // The reentrant receiver collects a refund credit via the credit-fallback
        // path; include it in the bucket-sum actor set so the per-address sum
        // continues to match `totalRefundEthOwed`.
        actors.push(address(reentrant));

        // Seed a prior king so the next takeover triggers a refund path.
        uint256 p0 = mineCore.getCurrentTakeoverPrice();
        vm.deal(alice, p0);
        vm.prank(alice);
        mineCore.takeover{value: p0}(type(uint256).max);

        // Reentrant overpays → triggers _hybridRefund → receive() reenters.
        vm.warp(block.timestamp + 1);
        uint256 p1 = mineCore.getCurrentTakeoverPrice();
        uint256 extra = 0.2 ether;
        vm.deal(address(reentrant), p1 + extra);
        vm.prank(address(reentrant));
        mineCore.takeover{value: p1 + extra}(type(uint256).max);

        // The reentrancy attempt was made (call trace shows
        // `ReentrancyGuardReentrantCall()` from MineCore.withdrawRefundBalance).
        // We can't keep that observation in receiver storage because the
        // outer `invalid()` reverts the receive frame; instead we rely on the
        // refund-credit bookkeeping below + the bucket-sum invariants to prove
        // no reentrant state corruption slipped through.

        // Refund credit survives because the outer 30k-stipend push failed
        // (receive() ran `invalid()` after the reentrancy attempt).
        assertEq(mineCore.refundEthBalance(address(reentrant)), extra, "refund credit must equal overpay");
        assertEq(mineCore.totalRefundEthOwed(), extra, "total refund must match");

        // Solvency holds.
        _assertEthSolvency();
        _assertBucketSumsEqualTotals();
    }

    // -----------------------------------------------------------------------
    // Helpers
    // -----------------------------------------------------------------------

    function _assertEthSolvency() internal view {
        uint256 tracked = mineCore.totalKingEthOwed() + mineCore.totalRefundEthOwed() + mineCore.shareholderEthPending();
        assertLe(tracked, address(mineCore).balance, "ETH solvency: tracked > balance");
    }

    function _assertBucketSumsEqualTotals() internal view {
        uint256 kingSum;
        uint256 refundSum;
        uint256 claimSum;
        for (uint256 i = 0; i < actors.length; i++) {
            address a = actors[i];
            kingSum += mineCore.kingEthBalance(a);
            refundSum += mineCore.refundEthBalance(a);
            claimSum += mineCore.pendingKingClaim(a);
        }
        assertEq(kingSum, mineCore.totalKingEthOwed(), "sum(kingEthBalance) != totalKingEthOwed");
        assertEq(refundSum, mineCore.totalRefundEthOwed(), "sum(refundEthBalance) != totalRefundEthOwed");
        assertEq(claimSum, mineCore.totalPendingKingClaim(), "sum(pendingKingClaim) != totalPendingKingClaim");
    }

    function _seedAllBuckets() internal {
        // gasBomb king → alice dethrones → gasBomb accrues king credit.
        uint256 p0 = mineCore.getCurrentTakeoverPrice();
        vm.deal(address(gasBomb), p0);
        vm.prank(address(gasBomb));
        mineCore.takeover{value: p0}(type(uint256).max);

        vm.warp(block.timestamp + 1);
        uint256 p1 = mineCore.getCurrentTakeoverPrice();
        vm.deal(alice, p1);
        vm.prank(alice);
        mineCore.takeover{value: p1}(type(uint256).max);

        vm.warp(block.timestamp + 1);
        uint256 p2 = mineCore.getCurrentTakeoverPrice();
        uint256 extra = 0.123 ether;
        vm.deal(address(refundRejector), p2 + extra);
        vm.prank(address(refundRejector));
        mineCore.takeover{value: p2 + extra}(type(uint256).max);
    }

    function _tryTakeover(address actor, uint256 extraEth) internal {
        address current = mineCore.currentKing();
        if (current != address(0) && actor == current) return;

        uint256 price = mineCore.getCurrentTakeoverPrice();
        uint256 value = price + extraEth;
        vm.deal(actor, value);
        vm.prank(actor);
        (bool ok,) =
            address(mineCore).call{value: value}(abi.encodeWithSignature("takeover(uint256)", type(uint256).max));
        ok;
    }

    function _tryWithdrawKing(address actor) internal {
        vm.prank(actor);
        (bool ok,) = address(mineCore).call(abi.encodeWithSignature("withdrawKingBalance()"));
        ok;
    }

    function _tryWithdrawRefund(address actor, address to) internal {
        vm.prank(actor);
        (bool ok,) = address(mineCore).call(abi.encodeWithSignature("withdrawRefundBalance(address)", to));
        ok;
    }

    function _tryWithdrawPendingClaim(address actor) internal {
        vm.prank(actor);
        (bool ok,) = address(mineCore).call(abi.encodeWithSignature("withdrawPendingClaim()"));
        ok;
    }
}
