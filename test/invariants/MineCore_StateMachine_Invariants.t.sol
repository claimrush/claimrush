// SPDX-License-Identifier: MIT
pragma solidity ^0.8.34;

import {Test} from "forge-std/Test.sol";

import {ClaimToken} from "src/ClaimToken.sol";
import {MineCore} from "src/MineCore.sol";
import {Furnace} from "src/Furnace.sol";
import {FurnaceGuardHelper} from "src/FurnaceGuardHelper.sol";

import {FurnaceQuoter} from "src/FurnaceQuoter.sol";
import {ShareholderRoyalties} from "src/ShareholderRoyalties.sol";

import {MockVe} from "../mocks/MockVe.sol";
import {MineCoreHarness} from "../mocks/MineCoreHarness.sol";
import {MockKingAutoLockFurnace} from "../mocks/MockKingAutoLockFurnace.sol";
import {Errors} from "src/lib/Errors.sol";

/// @dev Reverts on any ETH receive, forcing MineCore refund bucket crediting.
contract InvariantRefundRejector {
    receive() external payable {
        revert("NO_REFUND");
    }
}

/// @dev Consumes >30k gas on receive by writing to two fresh storage slots.
///      This forces MineCore's gas-stipended king payout to fail deterministically,
///      while still allowing full-gas withdrawals to succeed.
contract InvariantGasBombReceiver {
    uint256 internal idx;
    mapping(uint256 => uint256) internal slots;

    receive() external payable {
        uint256 i = idx;
        slots[i] = 1;
        slots[i + 1] = 2;
        idx = i + 2;
    }
}

contract MineCoreStateMachineInvariants is Test {
    ClaimToken internal claim;
    MockVe internal ve;
    ShareholderRoyalties internal royalties;
    Furnace internal furnace;
    MineCoreHarness internal mineCore;

    address internal owner;
    address internal alice;
    address internal bob;
    address internal carol;

    InvariantGasBombReceiver internal gasBomb;
    InvariantRefundRejector internal refundRejector;

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

        // Non-zero cached ve prevents edge-case math in MineCore reign finalization.
        ve.setTotalVeCached(1234);

        gasBomb = new InvariantGasBombReceiver();
        refundRejector = new InvariantRefundRejector();

        actors.push(alice);
        actors.push(bob);
        actors.push(carol);
        actors.push(address(gasBomb));
        actors.push(address(refundRejector));
    }

    /// @notice Stateful fuzz: random takeovers + withdrawals, asserting that all credited ETH
    ///         liabilities are always covered by MineCore's ETH balance.
    function testFuzz_stateMachine_liabilitiesAlwaysCovered(uint256 seed) public {
        _seedNonZeroCredits();

        uint256 steps = 16;
        for (uint256 i = 0; i < steps; i++) {
            bytes32 h = keccak256(abi.encode(seed, i));
            _advanceTime(h);

            uint8 action = uint8(uint256(h) % 6);
            address actor = actors[uint256(uint8(uint256(h >> 8))) % actors.length];

            if (action == 0) {
                _doTakeover(actor, 0);
            } else if (action == 1) {
                // Small overpay to exercise the hybrid refund path.
                uint256 extra = (uint256(uint16(uint256(h >> 16))) % 0.25 ether) + 1;
                _doTakeover(actor, extra);
            } else if (action == 2) {
                _tryWithdrawKing(actor);
            } else if (action == 3) {
                // Withdraw refunds to a known-safe EOA receiver.
                _tryWithdrawRefund(actor, alice);
            } else if (action == 4) {
                _tryWithdrawKing(actor);
                _tryWithdrawRefund(actor, alice);
            } else {
                // noop
            }

            _assertLiabilitiesCovered();
        }

        _assertLiabilitiesCovered();
    }

    function _advanceTime(bytes32 h) internal {
        uint256 dt = uint256(uint16(uint256(h >> 240))) % 3 hours;
        if (dt != 0) vm.warp(block.timestamp + dt);
    }

    function _seedNonZeroCredits() internal {
        // 1) gasBomb becomes first king (genesis takeover => no king payout yet).
        uint256 p0 = mineCore.getCurrentTakeoverPrice();
        vm.deal(address(gasBomb), p0);
        vm.prank(address(gasBomb));
        mineCore.takeover{value: p0}(type(uint256).max);

        // 2) Alice dethrones gasBomb; gas-stipended payout should fail and credit kingEthBalance.
        vm.warp(block.timestamp + 1);
        uint256 p1 = mineCore.getCurrentTakeoverPrice();
        vm.deal(alice, p1);
        vm.prank(alice);
        mineCore.takeover{value: p1}(type(uint256).max);

        // 3) refundRejector overpays; refund attempt fails and credits refundEthBalance.
        vm.warp(block.timestamp + 1);
        uint256 p2 = mineCore.getCurrentTakeoverPrice();
        uint256 extra = 0.123 ether;
        vm.deal(address(refundRejector), p2 + extra);
        vm.prank(address(refundRejector));
        mineCore.takeover{value: p2 + extra}(type(uint256).max);

        assertGt(mineCore.kingEthBalance(address(gasBomb)), 0, "expected king credit");
        assertGt(mineCore.refundEthBalance(address(refundRejector)), 0, "expected refund credit");

        _assertLiabilitiesCovered();
    }

    function _doTakeover(address actor, uint256 extraEth) internal {
        address current = mineCore.currentKing();
        if (current != address(0) && actor == current) {
            // Can't takeover yourself.
            return;
        }

        uint256 price = mineCore.getCurrentTakeoverPrice();
        uint256 value = price + extraEth;

        vm.deal(actor, value);
        vm.prank(actor);
        mineCore.takeover{value: value}(type(uint256).max);
    }

    function _tryWithdrawKing(address actor) internal {
        vm.prank(actor);
        (bool ok,) = address(mineCore).call(abi.encodeWithSignature("withdrawKingBalance()"));
        ok; // ignore
    }

    function _tryWithdrawRefund(address actor, address to) internal {
        vm.prank(actor);
        (bool ok,) = address(mineCore).call(abi.encodeWithSignature("withdrawRefundBalance(address)", to));
        ok; // ignore
    }

    function _assertLiabilitiesCovered() internal view {
        uint256 liability;
        // MC-24: Include shareholderEthPending in the solvency check.
        liability += mineCore.shareholderEthPending();
        for (uint256 i = 0; i < actors.length; i++) {
            address a = actors[i];
            liability += mineCore.kingEthBalance(a);
            liability += mineCore.refundEthBalance(a);
        }

        assertLe(liability, address(mineCore).balance, "liabilities must be covered by ETH balance");
    }

    function testFuzz_takeoverRejectsForeignFurnaceBeforeReserveMint(address badClaimRoot) public {
        vm.assume(badClaimRoot != address(0));
        vm.assume(badClaimRoot != address(claim));

        uint256 price0 = mineCore.getCurrentTakeoverPrice();
        vm.deal(alice, price0);
        vm.prank(alice);
        mineCore.takeover{value: price0}(type(uint256).max);

        MockKingAutoLockFurnace foreignFurnace = new MockKingAutoLockFurnace(
            address(claim), badClaimRoot, address(ve), address(mineCore), address(royalties), makeAddr("thief"), false
        );

        vm.prank(owner);
        mineCore.setFurnace(address(foreignFurnace));

        vm.warp(block.timestamp + 1);
        uint256 price1 = mineCore.getCurrentTakeoverPrice();
        vm.deal(bob, price1);

        vm.prank(bob);
        vm.expectRevert(Errors.WiringMismatch.selector);
        mineCore.takeover{value: price1}(type(uint256).max);

        assertEq(mineCore.currentKing(), alice, "king should remain unchanged");
        assertEq(claim.balanceOf(address(foreignFurnace)), 0, "foreign furnace must not receive emissions");
    }

    function testFuzz_staleVeCheckpointNeverMovesShareholderPending(uint96 seededPending) public {
        uint256 pending = bound(uint256(seededPending), 1, 10 ether);

        MockVe ve2 = new MockVe();
        ClaimToken claim2 = new ClaimToken(owner);
        ShareholderRoyalties royalties2 = new ShareholderRoyalties(address(ve2), owner);
        Furnace furnace2 = new Furnace(
            address(claim2), address(ve2), address(new FurnaceGuardHelper(address(claim2), address(ve2))), owner
        );
        MineCoreHarness mine2 = new MineCoreHarness(address(claim2), address(ve2), address(royalties2), owner);
        FurnaceQuoter quoter2 = new FurnaceQuoter(address(furnace2));

        vm.startPrank(owner);
        claim2.setMineCore(address(mine2));
        furnace2.setMineCore(address(mine2));
        furnace2.setFurnaceQuoter(address(quoter2));
        mine2.setFurnace(address(furnace2));
        vm.etch(address(0xB0B1), hex"00");
        royalties2.setWiring(address(mine2), address(0xB0B1), address(furnace2));
        mine2.setGenesisKingClaimCollectedForTest(true);
        mine2.setTakeoversPaused(false);
        vm.stopPrank();

        vm.warp(mine2.emissionStartTime() + 301);
        ve2.setTotalVeCached(1234);
        ve2.setGlobalLastTs(block.timestamp - 1);
        ve2.setCheckpointAdvances(false);
        mine2.setShareholderEthPendingHarness(pending);

        vm.expectRevert(Errors.VeCheckpointStale.selector);
        mine2.retryPushShareholderEth();

        assertEq(mine2.shareholderEthPending(), pending, "stale checkpoint must preserve MineCore pending ETH");
        assertEq(royalties2.pendingShareholderETH(), 0, "stale checkpoint must not move ETH into royalties pending");
    }
}
