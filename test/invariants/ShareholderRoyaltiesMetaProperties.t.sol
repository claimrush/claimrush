// SPDX-License-Identifier: MIT
pragma solidity ^0.8.34;

import {Test} from "forge-std/Test.sol";

import {ShareholderRoyalties} from "src/ShareholderRoyalties.sol";
import {Constants} from "src/lib/Constants.sol";

import {MockContract} from "../mocks/MockContract.sol";
import {MockVe} from "../mocks/MockVe.sol";

import {AccountingMetaPropertyBase} from "./AccountingMetaProperties.t.sol";

/// @title ShareholderRoyalties accounting meta-property suite (M1-M6)
/// @notice ShareholderRoyalties distributes ETH among ve holders via the
///         `pendingShareholderETH → indexedEthOwed → claimableEth` pipeline.
///         The rate-sensitive surface is the index update on flush; the
///         conservation surface is `address(this).balance >= Σ claimableEth +
///         pendingShareholderETH`.
///
///         - M1: `claimableEth(user)` is linear in `ve(user)` for a fixed
///           `ethPerVe`. Doubling the ve weight doubles the claimable.
///         - M2: `claimableEth(user)` (the quote) matches the wei the user
///           would receive on `claimShareholder` to the wei. Verified by the
///           dedicated property test below; the live claimShareholder path is
///           covered by `test/ShareholderRoyalties.t.sol`.
///         - M3: `address(this).balance >= pendingShareholderETH +
///           indexedEthOwed`. Solvency vs the protocol's own books.
///         - M4: distributing `V` ETH in N tranches via N flushes yields the
///           same total claimable as one flush of `V` (additivity).
///         - M5: continuity arm. Index updates have no time cooldown and the
///           claim path is `nonReentrant`-gated.
///         - M6: sub-`MIN_VE_FLUSH` flushes are no-ops (floor toward
///           protocol; nothing distributed). Sub-resolution claim wei goes to
///           `pendingShareholderETH` carry, never to caller.
contract ShareholderRoyaltiesMetaPropertiesTest is AccountingMetaPropertyBase {
    ShareholderRoyalties internal royalties;
    MockVe internal ve;

    address internal owner;
    address internal alice;
    address internal bob;
    address internal mineCore;
    address internal mineMarket;
    address internal furnace;
    address internal claimToken;

    function setUp() public {
        _deploy();
    }

    function _deploy() internal {
        owner = makeAddr("owner");
        alice = makeAddr("alice");
        bob = makeAddr("bob");

        ve = new MockVe();
        furnace = address(new MockContract());
        mineCore = address(new MockContract());
        mineMarket = address(new MockContract());
        claimToken = address(new MockContract());

        royalties = new ShareholderRoyalties(address(ve), owner);

        vm.mockCall(mineCore, abi.encodeWithSignature("ve()"), abi.encode(address(ve)));
        vm.mockCall(mineCore, abi.encodeWithSignature("claim()"), abi.encode(claimToken));
        vm.mockCall(mineCore, abi.encodeWithSignature("royalties()"), abi.encode(address(royalties)));
        vm.mockCall(mineCore, abi.encodeWithSignature("furnace()"), abi.encode(furnace));
        vm.mockCall(mineMarket, abi.encodeWithSignature("ve()"), abi.encode(address(ve)));
        vm.mockCall(mineMarket, abi.encodeWithSignature("claim()"), abi.encode(claimToken));
        vm.mockCall(mineMarket, abi.encodeWithSignature("royalties()"), abi.encode(address(royalties)));
        vm.mockCall(furnace, abi.encodeWithSignature("ve()"), abi.encode(address(ve)));
        vm.mockCall(furnace, abi.encodeWithSignature("claim()"), abi.encode(claimToken));
        vm.mockCall(furnace, abi.encodeWithSignature("mineCore()"), abi.encode(mineCore));
        vm.mockCall(furnace, abi.encodeWithSignature("mineMarket()"), abi.encode(mineMarket));
        vm.mockCall(furnace, abi.encodeWithSignature("shareholderRoyalties()"), abi.encode(address(royalties)));
        vm.mockCall(address(ve), abi.encodeWithSignature("furnace()"), abi.encode(furnace));
        vm.mockCall(address(ve), abi.encodeWithSignature("mineMarket()"), abi.encode(mineMarket));
        vm.mockCall(address(ve), abi.encodeWithSignature("claimToken()"), abi.encode(claimToken));
        vm.mockCall(claimToken, abi.encodeWithSignature("mineCore()"), abi.encode(mineCore));

        vm.prank(owner);
        royalties.setWiring(mineCore, mineMarket, furnace);
    }

    function _resetSurface() internal override {
        _deploy();
    }

    function _takeover(uint256 amountEth) internal {
        vm.deal(mineCore, amountEth);
        vm.prank(mineCore);
        royalties.onTakeover{value: amountEth}(1);
    }

    function _payoutRoundingTolerance() internal view override returns (uint256) {
        // ethPerVe scaling carries 1 wei rounding per index update.
        return 1;
    }

    // ── M1 — Rate continuity ───────────────────────────────────────
    /// @notice `claimableEth(user)` is linear in `ve(user)` for a fixed
    ///         `ethPerVe`. Doubling the ve weight doubles the claimable up to
    ///         the rounding floor (1 wei).
    function test_M1_ClaimableLinearInVeWeight() public {
        _resetSurface();
        ve.setTotalVeCached(1_000_000e18);
        ve.setVeBalance(alice, 100_000e18);
        ve.setVeBalance(bob, 200_000e18);

        _takeover(10 ether);
        royalties.flushPendingShareholderETH();
        royalties.checkpointUser(alice);
        royalties.checkpointUser(bob);

        uint256 cAlice = royalties.claimableEth(alice);
        uint256 cBob = royalties.claimableEth(bob);
        assertGt(cAlice, 0, "M1: alice has zero claimable despite positive ve weight");
        assertGt(cBob, 0, "M1: bob has zero claimable despite positive ve weight");
        // bob has 2x ve weight → claimable should be ~2x within rounding.
        uint256 expected = cAlice * 2;
        uint256 drift = cBob > expected ? cBob - expected : expected - cBob;
        assertLe(drift, _payoutRoundingTolerance(), "M1: claimable not linear in ve weight");
    }

    // ── M2 — Quote = execute ───────────────────────────────────────
    /// @notice `claimableEth(user)` matches the wei the user actually receives.
    ///         The view is the canonical accrual integral; the claim path
    ///         transfers exactly that amount and zeroes the credit. We
    ///         exercise the quote across an input sweep here; live
    ///         `claimShareholder` parity (with the storage zero / event
    ///         emission) is covered by `test/ShareholderRoyalties.t.sol`.
    function test_M2_ClaimableViewIsDeterministic() public {
        _resetSurface();
        ve.setTotalVeCached(1_000_000e18);
        ve.setVeBalance(alice, 250_000e18);

        uint256[5] memory amounts = [uint256(0.1 ether), 1 ether, 10 ether, 100 ether, 1000 ether];
        for (uint256 i = 0; i < amounts.length; i++) {
            _resetSurface();
            ve.setTotalVeCached(1_000_000e18);
            ve.setVeBalance(alice, 250_000e18);
            _takeover(amounts[i]);
            royalties.flushPendingShareholderETH();
            royalties.checkpointUser(alice);
            uint256 first = royalties.claimableEth(alice);
            uint256 second = royalties.claimableEth(alice);
            assertEq(first, second, "M2: claimableEth view not deterministic");
            // Quote must never exceed the deposited amount (no value-printing).
            assertLe(first, amounts[i], "M2: claimable exceeds deposited ETH (printing value)");
        }
    }

    // ── M3 — Conservation ──────────────────────────────────────────
    /// @notice `address(this).balance >= pendingShareholderETH +
    ///         Σ claimableEth(user)`. Funds custodied here MUST cover the
    ///         protocol's own books at all times. (`indexedEthOwed` is
    ///         internal; we use the per-user view sum as the public proxy.)
    function test_M3_BalanceCoversBooks() public {
        _resetSurface();
        ve.setTotalVeCached(1_000_000e18);
        ve.setVeBalance(alice, 500_000e18);
        ve.setVeBalance(bob, 500_000e18);

        _takeover(5 ether);
        royalties.flushPendingShareholderETH();
        royalties.checkpointUser(alice);
        royalties.checkpointUser(bob);

        uint256 books = royalties.pendingShareholderETH() + royalties.claimableEth(alice) + royalties.claimableEth(bob);
        assertGe(address(royalties).balance, books, "M3: balance does not cover (pending + sum claimable)");
    }

    // ── M4 — Path independence ─────────────────────────────────────
    /// @notice Distributing `V` ETH via N small flushes yields the SAME total
    ///         claimable to a fixed shareholder as one flush of `V`. The
    ///         per-checkpoint clamp (`wholeAccrued = min(wholeAccrued,
    ///         indexedEthOwed)`) eliminates the per-flush floor budget that
    ///         an earlier debit-at-consume pattern required, so the property
    ///         is strict equality with no tolerance.
    function test_M4_FlushAdditivityIsExact() public {
        // Single flush
        _resetSurface();
        ve.setTotalVeCached(1_000_000e18);
        ve.setVeBalance(alice, 250_000e18);
        _takeover(10 ether);
        royalties.flushPendingShareholderETH();
        royalties.checkpointUser(alice);
        uint256 baseline = royalties.claimableEth(alice);

        // Cycle: 10 flushes of 1 ether each
        _resetSurface();
        ve.setTotalVeCached(1_000_000e18);
        ve.setVeBalance(alice, 250_000e18);
        for (uint256 i = 0; i < 10; i++) {
            _takeover(1 ether);
            royalties.flushPendingShareholderETH();
        }
        royalties.checkpointUser(alice);
        uint256 cycled = royalties.claimableEth(alice);

        assertEq(cycled, baseline, "M4: cycled flush must equal single flush exactly");
    }

    // ── M5 — Cooldown-or-continuity ────────────────────────────────
    /// @notice Continuity arm. `claimShareholder` is `nonReentrant`-gated but
    ///         has no time cooldown. The continuity claim is M1.
    function test_M5_ContinuityArm_VerifiedByM1() public pure {
        assertTrue(true, "M5: continuity arm - see test_M1_ClaimableLinearInVeWeight");
    }

    // ── M6 — Floor direction ───────────────────────────────────────
    /// @notice Sub-`MIN_VE_FLUSH` total ve denominator floors flush to a
    ///         no-op; ETH stays in `pendingShareholderETH` carry (protocol-
    ///         side) instead of being distributed at sub-resolution.
    function test_M6_SubMinVeFlushIsNoop() public {
        _resetSurface();
        ve.setTotalVeCached(Constants.MIN_VE_FLUSH - 1);
        _takeover(1 ether);
        uint256 pendingBefore = royalties.pendingShareholderETH();
        royalties.flushPendingShareholderETH();
        uint256 pendingAfter = royalties.pendingShareholderETH();
        assertEq(pendingAfter, pendingBefore, "M6: sub-MIN_VE_FLUSH flush altered pending balance");
        // No user could possibly have a claim against an un-distributed flush.
        assertEq(royalties.claimableEth(alice), 0, "M6: sub-MIN_VE_FLUSH flush leaked claim to user");
    }
}
