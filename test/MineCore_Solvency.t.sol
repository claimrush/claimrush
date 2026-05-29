// SPDX-License-Identifier: MIT
pragma solidity ^0.8.34;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {ClaimToken} from "src/ClaimToken.sol";
import {Furnace} from "src/Furnace.sol";
import {FurnaceGuardHelper} from "src/FurnaceGuardHelper.sol";

import {FurnaceQuoter} from "src/FurnaceQuoter.sol";
import {ShareholderRoyalties} from "src/ShareholderRoyalties.sol";
import {Errors} from "src/lib/Errors.sol";

import {MockVe} from "./mocks/MockVe.sol";
import {MineCoreHarness} from "./mocks/MineCoreHarness.sol";

/// @dev Reverts on ETH receive, forcing refund bucket crediting.
contract SolvencyRefundRejector {
    receive() external payable {
        revert("REJECT");
    }
}

/// @dev Consumes >30k gas on receive, forcing king payout bucket crediting.
contract SolvencyGasBomb {
    uint256 internal idx;
    mapping(uint256 => uint256) internal slots;

    receive() external payable {
        uint256 i = idx;
        slots[i] = 1;
        slots[i + 1] = 2;
        idx = i + 2;
    }
}

/// @notice ETH and CLAIM solvency invariants using global totals.
/// @dev Uses aggregate-total counters (`totalKingEthOwed`, `totalRefundEthOwed`,
///      `totalPendingKingClaim`) rather than per-actor sums, so the invariants
///      hold under adversarial state distributions.
contract MineCoreSolvencyTest is Test {
    ClaimToken internal claim;
    MockVe internal ve;
    ShareholderRoyalties internal royalties;
    Furnace internal furnace;
    MineCoreHarness internal mineCore;

    address internal owner;
    address internal alice;
    address internal bob;
    address internal carol;

    SolvencyGasBomb internal gasBomb;
    SolvencyRefundRejector internal refundRejector;

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

        gasBomb = new SolvencyGasBomb();
        refundRejector = new SolvencyRefundRejector();

        actors.push(alice);
        actors.push(bob);
        actors.push(carol);
        actors.push(address(gasBomb));
        actors.push(address(refundRejector));
    }

    // -----------------------------------------------------------------------
    // ETH solvency: global totals invariant
    // -----------------------------------------------------------------------

    /// @notice Fuzz: ETH solvency using global totals across random takeovers + withdrawals.
    function testFuzz_ethSolvency_globalTotals(uint256 seed) public {
        _seedNonZeroCredits();

        uint256 steps = 20;
        for (uint256 i = 0; i < steps; i++) {
            bytes32 h = keccak256(abi.encode(seed, i));
            uint256 dt = uint256(uint16(uint256(h >> 240))) % 3 hours;
            if (dt != 0) vm.warp(block.timestamp + dt);

            uint8 action = uint8(uint256(h) % 7);
            address actor = actors[uint256(uint8(uint256(h >> 8))) % actors.length];

            if (action <= 1) {
                uint256 extra = action == 1 ? (uint256(uint16(uint256(h >> 16))) % 0.25 ether) + 1 : 0;
                _doTakeover(actor, extra);
            } else if (action == 2) {
                _tryWithdrawKing(actor);
            } else if (action == 3) {
                _tryWithdrawRefund(actor, alice);
            } else if (action == 4) {
                _tryWithdrawPendingClaim(actor);
            } else if (action == 5) {
                _tryWithdrawKing(actor);
                _tryWithdrawRefund(actor, alice);
                _tryWithdrawPendingClaim(actor);
            }
            // action == 6: noop

            _assertEthSolvency();
            _assertClaimSolvency();
        }

        _assertEthSolvency();
        _assertClaimSolvency();
    }

    /// @notice Deterministic: verify solvency after seeding all three ETH buckets.
    function test_ethSolvency_allBucketsSeeded() public {
        _seedNonZeroCredits();

        assertGt(mineCore.totalKingEthOwed(), 0, "king bucket should be nonzero");
        assertGt(mineCore.totalRefundEthOwed(), 0, "refund bucket should be nonzero");
        // shareholderEthPending may or may not be nonzero depending on royalties behavior.

        _assertEthSolvency();
    }

    /// @notice Direct unsolicited ETH sends MUST revert. The only legitimate receive() entry is
    ///         `IWETH.withdraw(...)` from the configured wrappedNative during takeoverWithToken
    ///         flows.
    function test_ethSolvency_directEthSend_reverts() public {
        _seedNonZeroCredits();

        vm.deal(address(this), 5 ether);
        (bool ok,) = address(mineCore).call{value: 5 ether}("");
        assertFalse(ok, "unsolicited ETH send must revert");

        // Invariant still holds; untracked surplus has not grown.
        _assertEthSolvency();
    }

    // -----------------------------------------------------------------------
    // CLAIM solvency: global totals invariant
    // -----------------------------------------------------------------------

    /// @notice Deterministic: verify CLAIM solvency across multiple takeovers.
    function test_claimSolvency_afterMultipleTakeovers() public {
        _doTakeover(alice, 0);
        vm.warp(block.timestamp + 30 minutes);
        _doTakeover(bob, 0);
        vm.warp(block.timestamp + 30 minutes);
        _doTakeover(carol, 0);

        _assertClaimSolvency();
    }

    // -----------------------------------------------------------------------
    // Helpers
    // -----------------------------------------------------------------------

    function _assertEthSolvency() internal view {
        uint256 tracked = mineCore.totalKingEthOwed() + mineCore.totalRefundEthOwed() + mineCore.shareholderEthPending();
        assertLe(tracked, address(mineCore).balance, "ETH SOLVENCY VIOLATED: tracked > balance");
    }

    function _assertClaimSolvency() internal view {
        uint256 tracked = mineCore.totalPendingKingClaim();
        uint256 balance = IERC20(address(claim)).balanceOf(address(mineCore));
        assertLe(tracked, balance, "CLAIM SOLVENCY VIOLATED: tracked > balance");
    }

    function _seedNonZeroCredits() internal {
        // gasBomb becomes first king.
        uint256 p0 = mineCore.getCurrentTakeoverPrice();
        vm.deal(address(gasBomb), p0);
        vm.prank(address(gasBomb));
        mineCore.takeover{value: p0}(type(uint256).max);

        // Alice dethrones gasBomb; payout fails → kingEthBalance credited.
        vm.warp(block.timestamp + 1);
        uint256 p1 = mineCore.getCurrentTakeoverPrice();
        vm.deal(alice, p1);
        vm.prank(alice);
        mineCore.takeover{value: p1}(type(uint256).max);

        // refundRejector overpays; refund fails → refundEthBalance credited.
        vm.warp(block.timestamp + 1);
        uint256 p2 = mineCore.getCurrentTakeoverPrice();
        uint256 extra = 0.123 ether;
        vm.deal(address(refundRejector), p2 + extra);
        vm.prank(address(refundRejector));
        mineCore.takeover{value: p2 + extra}(type(uint256).max);

        assertGt(mineCore.kingEthBalance(address(gasBomb)), 0, "expected king credit");
        assertGt(mineCore.refundEthBalance(address(refundRejector)), 0, "expected refund credit");
    }

    function _doTakeover(address actor, uint256 extraEth) internal {
        address current = mineCore.currentKing();
        if (current != address(0) && actor == current) return;

        uint256 price = mineCore.getCurrentTakeoverPrice();
        uint256 value = price + extraEth;
        vm.deal(actor, value);
        vm.prank(actor);
        mineCore.takeover{value: value}(type(uint256).max);
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
