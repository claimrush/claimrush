// SPDX-License-Identifier: MIT
pragma solidity ^0.8.34;

import {Test} from "forge-std/Test.sol";

import {ClaimAllHelper} from "src/ClaimAllHelper.sol";
import {ShareholderRoyalties} from "src/ShareholderRoyalties.sol";
import {Constants} from "src/lib/Constants.sol";
import {Errors} from "src/lib/Errors.sol";

import {MockVe} from "../mocks/MockVe.sol";

contract MockFurnaceAutoCompoundDuration {
    address public mineCore;
    address public mineMarket;
    address public shareholderRoyalties;
    uint256 public lastDurationSeconds;

    function setWiring(address _mineCore, address _mineMarket, address _shareholderRoyalties) external {
        mineCore = _mineCore;
        mineMarket = _mineMarket;
        shareholderRoyalties = _shareholderRoyalties;
    }

    function furnaceQuoter() external view returns (address) {
        return address(this);
    }

    function quoteEnterWithEth(address, uint256, uint256, uint256, bool)
        external
        pure
        returns (uint256, uint256, uint256 veOut, uint256)
    {
        veOut = 1e18;
        return (0, 0, veOut, 0);
    }

    function lockEthReward(address, uint256 ethAmount, uint256, uint256 durationSeconds, bool, uint256)
        external
        payable
    {
        require(msg.value == ethAmount, "value mismatch");
        lastDurationSeconds = durationSeconds;
    }
}

/// @dev Lightweight properties for shareholder allocation bookkeeping.
contract ShareholderIndexInvariantsTest is Test {
    MockVe internal ve;
    ShareholderRoyalties internal royalties;

    address internal owner;
    address internal mineCore;
    address internal mineMarket;
    address internal claimToken;
    address internal alice;
    address internal bob;
    address internal keeper;

    MockFurnaceAutoCompoundDuration internal furnace;

    function setUp() public {
        owner = makeAddr("owner");
        mineCore = makeAddr("mineCore");
        mineMarket = makeAddr("mineMarket");
        claimToken = makeAddr("claimToken");
        alice = makeAddr("alice");
        bob = makeAddr("bob");
        keeper = makeAddr("keeper");

        ve = new MockVe();
        royalties = new ShareholderRoyalties(address(ve), owner);
        furnace = new MockFurnaceAutoCompoundDuration();
        furnace.setWiring(mineCore, mineMarket, address(royalties));
        vm.mockCall(address(furnace), abi.encodeWithSignature("ve()"), abi.encode(address(ve)));
        vm.mockCall(address(furnace), abi.encodeWithSignature("claim()"), abi.encode(claimToken));

        vm.etch(mineCore, hex"00");
        vm.etch(mineMarket, hex"00");
        vm.etch(claimToken, hex"00");
        vm.mockCall(mineCore, abi.encodeWithSignature("furnace()"), abi.encode(address(furnace)));
        vm.mockCall(mineCore, abi.encodeWithSignature("royalties()"), abi.encode(address(royalties)));
        vm.mockCall(mineCore, abi.encodeWithSignature("ve()"), abi.encode(address(ve)));
        vm.mockCall(mineCore, abi.encodeWithSignature("claim()"), abi.encode(claimToken));
        vm.mockCall(mineMarket, abi.encodeWithSignature("royalties()"), abi.encode(address(royalties)));
        vm.mockCall(mineMarket, abi.encodeWithSignature("ve()"), abi.encode(address(ve)));
        vm.mockCall(mineMarket, abi.encodeWithSignature("claim()"), abi.encode(claimToken));
        vm.mockCall(address(ve), abi.encodeWithSignature("furnace()"), abi.encode(address(furnace)));
        vm.mockCall(address(ve), abi.encodeWithSignature("mineMarket()"), abi.encode(mineMarket));
        vm.mockCall(address(ve), abi.encodeWithSignature("claimToken()"), abi.encode(claimToken));
        vm.mockCall(claimToken, abi.encodeWithSignature("mineCore()"), abi.encode(mineCore));
        vm.prank(owner);
        royalties.setWiring(mineCore, mineMarket, address(furnace));

        vm.prank(owner);
        royalties.setAutoCompoundKeeper(keeper, true);
    }

    function testFuzz_pendingShareholderETHAccumulates(uint96 v1, uint96 v2, uint96 v3) public {
        // Bound to keep sums small and avoid running into gas-heavy edge cases.
        uint256 a = bound(uint256(v1), 0, 10 ether);
        uint256 b = bound(uint256(v2), 0, 10 ether);
        uint256 c = bound(uint256(v3), 0, 10 ether);

        uint256 total = a + b + c;
        vm.deal(mineCore, total);

        vm.prank(mineCore);
        royalties.onTakeover{value: a}(1);

        vm.prank(mineCore);
        royalties.onTakeover{value: b}(2);

        vm.prank(mineCore);
        royalties.onTakeover{value: c}(3);

        assertEq(royalties.pendingShareholderETH(), total);
    }

    function testFuzz_onTakeoverRejectsMineMarketRoyaltiesRootDriftAndPreservesPending(uint96 takeoverEth) public {
        uint256 ethAmount = bound(uint256(takeoverEth), 1, 10 ether);

        vm.mockCall(mineMarket, abi.encodeWithSignature("royalties()"), abi.encode(address(0xDEAD)));

        vm.deal(mineCore, ethAmount);
        vm.prank(mineCore);
        vm.expectRevert(Errors.WiringMismatch.selector);
        royalties.onTakeover{value: ethAmount}(1);

        assertEq(royalties.pendingShareholderETH(), 0, "runtime drift must not enqueue takeover ETH");
    }

    function testFuzz_flushRejectsClaimTokenMineCoreRootDriftAndPreservesPending(uint96 takeoverEth) public {
        uint256 ethAmount = bound(uint256(takeoverEth), 1, 10 ether);

        vm.deal(mineCore, ethAmount);
        vm.prank(mineCore);
        royalties.onTakeover{value: ethAmount}(1);
        assertEq(royalties.pendingShareholderETH(), ethAmount, "canonical takeover should enqueue pending ETH");

        vm.mockCall(claimToken, abi.encodeWithSignature("mineCore()"), abi.encode(address(0xDEAD)));

        vm.expectRevert(Errors.WiringMismatch.selector);
        royalties.flushPendingShareholderETH();

        assertEq(royalties.pendingShareholderETH(), ethAmount, "flush drift revert must preserve pending ETH");
    }

    /// @dev Invariant: repeated random sequences of takeover, flush, checkpoint, claim;
    ///      sum(claimable) + pending <= balance and pending >= 0.
    ///      Denominator set >= total ve to avoid stale-low.
    function testFuzz_RepeatedFlushAndClaims_SumClaimableLeqBalanceAndPendingNonNegative(
        uint8 rounds,
        uint96 takeoverEth,
        uint96 veAlice,
        uint96 veBob,
        uint8 doFlush,
        uint8 claimAlice,
        uint8 claimBob
    ) public {
        rounds = uint8(bound(rounds, 1, 6));
        uint256 eth = bound(uint256(takeoverEth), 0, 10 ether);
        uint256 va = bound(uint256(veAlice), 10e18, 300e18);
        uint256 vb = bound(uint256(veBob), 10e18, 300e18);
        uint256 veTotal = va + vb;
        if (veTotal < Constants.MIN_VE_FLUSH) veTotal = Constants.MIN_VE_FLUSH;

        ve.setTotalVeCached(veTotal);
        vm.deal(mineCore, eth * uint256(rounds));

        for (uint256 r = 0; r < rounds; r++) {
            vm.prank(mineCore);
            royalties.onTakeover{value: eth}(r + 1);

            if (doFlush % 2 == 0) {
                royalties.flushPendingShareholderETH();
            }

            ve.setVeBalance(alice, va);
            ve.setVeBalance(bob, vb);
            royalties.checkpointUser(alice);
            royalties.checkpointUser(bob);

            if (claimAlice % 2 == 0 && royalties.claimableEth(alice) > 0) {
                vm.prank(alice);
                try royalties.claimShareholder(Constants.SHAREHOLDER_MODE_ETH, 0, 0, false, 0) {} catch {}
            }
            if (claimBob % 2 == 0 && royalties.claimableEth(bob) > 0) {
                vm.prank(bob);
                try royalties.claimShareholder(Constants.SHAREHOLDER_MODE_ETH, 0, 0, false, 0) {} catch {}
            }
        }

        royalties.flushPendingShareholderETH();
        royalties.checkpointUser(alice);
        royalties.checkpointUser(bob);

        uint256 totalClaimable = royalties.claimableEth(alice) + royalties.claimableEth(bob);
        uint256 pendingShareholder = royalties.pendingShareholderETH();
        assertLe(
            totalClaimable + pendingShareholder, address(royalties).balance + 16, "sum(claimable) + pending <= balance"
        );
        assertGe(royalties.pendingShareholderETH(), 0, "pending non-negative");
    }

    function testFuzz_compoundUsesMaxOfConfiguredAndRemainingDuration(uint40 remainingRaw, uint40 configuredRaw)
        public
    {
        uint256 remaining = bound(uint256(remainingRaw), Constants.MIN_LOCK_DURATION, Constants.MAX_LOCK_DURATION);
        uint256 configured = bound(uint256(configuredRaw), Constants.MIN_LOCK_DURATION, Constants.MAX_LOCK_DURATION);

        ve.setTotalVeCached(200e18);
        ve.setVeBalance(alice, 100e18);
        ve.setOwner(1, alice);
        ve.setLockInfo(1, 1e18, block.timestamp + remaining, false, false);

        vm.deal(mineCore, 1 ether);
        vm.prank(mineCore);
        royalties.onTakeover{value: 1 ether}(1);
        royalties.flushPendingShareholderETH();

        vm.prank(alice);
        royalties.setAutoCompoundConfig(true, 1, configured, 0, 0, 500);

        vm.prank(keeper);
        royalties.compoundFor(alice);

        uint256 expected = configured;
        if (remaining > expected) expected = remaining;
        assertEq(furnace.lastDurationSeconds(), expected, "compound uses max(config, remaining)");
    }

    function testFuzz_StaleCheckpointFlush_DoesNotAdvanceIndexOrConsumePending(uint96 takeoverEth, uint96 totalVe)
        public
    {
        uint256 ethAmount = bound(uint256(takeoverEth), 1, 10 ether);
        uint256 veTotal = bound(uint256(totalVe), Constants.MIN_VE_FLUSH, 500e18);

        ve.setTotalVeCached(veTotal);
        ve.setGlobalLastTs(block.timestamp - 1);
        ve.setCheckpointAdvances(false);

        vm.deal(mineCore, ethAmount);
        vm.prank(mineCore);
        royalties.onTakeover{value: ethAmount}(1);

        uint256 pendingBefore = royalties.pendingShareholderETH();
        uint256 indexBefore = royalties.ethPerVe();

        royalties.flushPendingShareholderETH();

        assertEq(royalties.ethPerVe(), indexBefore, "stale checkpoint must not advance index");
        assertEq(
            royalties.pendingShareholderETH(),
            pendingBefore,
            "stale checkpoint must not consume pending shareholder ETH"
        );
    }

    function testFuzz_compoundRejectsFurnaceVeMismatchAndPreservesClaimable(uint40 remainingRaw, uint40 configuredRaw)
        public
    {
        uint256 remaining = bound(uint256(remainingRaw), Constants.MIN_LOCK_DURATION, Constants.MAX_LOCK_DURATION);
        uint256 configured = bound(uint256(configuredRaw), Constants.MIN_LOCK_DURATION, Constants.MAX_LOCK_DURATION);

        ve.setTotalVeCached(200e18);
        ve.setVeBalance(alice, 100e18);
        ve.setOwner(1, alice);
        ve.setLockInfo(1, 1e18, block.timestamp + remaining, false, false);

        vm.deal(mineCore, 1 ether);
        vm.prank(mineCore);
        royalties.onTakeover{value: 1 ether}(1);
        royalties.flushPendingShareholderETH();

        vm.prank(alice);
        royalties.setAutoCompoundConfig(true, 1, configured, 0, 0, 500);

        royalties.checkpointUser(alice);
        uint256 claimableBefore = royalties.claimableEth(alice);
        assertGt(claimableBefore, 0, "setup must accrue claimable ETH before mismatch test");

        vm.mockCall(address(furnace), abi.encodeWithSignature("ve()"), abi.encode(address(0xDEAD)));

        vm.prank(keeper);
        vm.expectRevert(Errors.WiringMismatch.selector);
        royalties.compoundFor(alice);

        assertEq(royalties.claimableEth(alice), claimableBefore, "ve mismatch must not consume claimable ETH");
        (,,,,,,, uint40 lastTs) = royalties.getAutoCompoundConfig(alice);
        assertEq(lastTs, 0, "ve mismatch must not advance cadence");
    }

    function testFuzz_compoundRejectsMineCoreFurnaceBackpointerMismatchAndPreservesClaimable(
        uint40 remainingRaw,
        uint40 configuredRaw
    ) public {
        uint256 remaining = bound(uint256(remainingRaw), Constants.MIN_LOCK_DURATION, Constants.MAX_LOCK_DURATION);
        uint256 configured = bound(uint256(configuredRaw), Constants.MIN_LOCK_DURATION, Constants.MAX_LOCK_DURATION);

        ve.setTotalVeCached(200e18);
        ve.setVeBalance(alice, 100e18);
        ve.setOwner(1, alice);
        ve.setLockInfo(1, 1e18, block.timestamp + remaining, false, false);

        vm.deal(mineCore, 1 ether);
        vm.prank(mineCore);
        royalties.onTakeover{value: 1 ether}(1);
        royalties.flushPendingShareholderETH();

        vm.prank(alice);
        royalties.setAutoCompoundConfig(true, 1, configured, 0, 0, 500);

        royalties.checkpointUser(alice);
        uint256 claimableBefore = royalties.claimableEth(alice);
        assertGt(claimableBefore, 0, "setup must accrue claimable ETH before mismatch test");

        vm.mockCall(mineCore, abi.encodeWithSignature("furnace()"), abi.encode(address(0xDEAD)));

        vm.prank(keeper);
        vm.expectRevert(Errors.WiringMismatch.selector);
        royalties.compoundFor(alice);

        assertEq(
            royalties.claimableEth(alice), claimableBefore, "core backpointer mismatch must not consume claimable ETH"
        );
        (,,,,,,, uint40 lastTs) = royalties.getAutoCompoundConfig(alice);
        assertEq(lastTs, 0, "core backpointer mismatch must not advance cadence");
    }

    function testFuzz_checkpointUserRejectsMineMarketRoyaltiesRootDrift(uint96 takeoverEth, uint96 veAlice) public {
        uint256 ethAmount = bound(uint256(takeoverEth), 1, 10 ether);
        uint256 aliceVe = bound(uint256(veAlice), 10e18, 300e18);
        uint256 veTotal = aliceVe * 2;
        if (veTotal < Constants.MIN_VE_FLUSH) veTotal = Constants.MIN_VE_FLUSH;

        ve.setTotalVeCached(veTotal);
        ve.setVeBalance(alice, aliceVe);

        vm.deal(mineCore, ethAmount);
        vm.prank(mineCore);
        royalties.onTakeover{value: ethAmount}(1);
        royalties.flushPendingShareholderETH();

        vm.mockCall(mineMarket, abi.encodeWithSignature("royalties()"), abi.encode(address(0xDEAD)));

        vm.expectRevert(Errors.WiringMismatch.selector);
        royalties.checkpointUser(alice);

        assertEq(royalties.claimableEthStored(alice), 0, "market royalties drift must not crystallise claimable ETH");
        assertEq(royalties.userEthPerVePaid(alice), 0, "market royalties drift must not advance paid index");
    }

    function testFuzz_checkpointUserRejectsMineCoreRoyaltiesRootDrift(uint96 takeoverEth, uint96 veAlice) public {
        uint256 ethAmount = bound(uint256(takeoverEth), 1, 10 ether);
        uint256 aliceVe = bound(uint256(veAlice), 10e18, 300e18);
        uint256 veTotal = aliceVe * 2;
        if (veTotal < Constants.MIN_VE_FLUSH) veTotal = Constants.MIN_VE_FLUSH;

        ve.setTotalVeCached(veTotal);
        ve.setVeBalance(alice, aliceVe);

        vm.deal(mineCore, ethAmount);
        vm.prank(mineCore);
        royalties.onTakeover{value: ethAmount}(1);
        royalties.flushPendingShareholderETH();

        vm.mockCall(mineCore, abi.encodeWithSignature("royalties()"), abi.encode(address(0xDEAD)));

        vm.expectRevert(Errors.WiringMismatch.selector);
        royalties.checkpointUser(alice);

        assertEq(royalties.claimableEthStored(alice), 0, "core royalties drift must not crystallise claimable ETH");
        assertEq(royalties.userEthPerVePaid(alice), 0, "core royalties drift must not advance paid index");
    }

    function testFuzz_claimShareholderRejectsMineMarketRoyaltiesRootDriftAndPreservesClaimable(
        uint96 takeoverEth,
        uint96 veAlice
    ) public {
        uint256 ethAmount = bound(uint256(takeoverEth), 1, 10 ether);
        uint256 aliceVe = bound(uint256(veAlice), 10e18, 300e18);
        uint256 veTotal = aliceVe * 2;
        if (veTotal < Constants.MIN_VE_FLUSH) veTotal = Constants.MIN_VE_FLUSH;

        ve.setTotalVeCached(veTotal);
        ve.setVeBalance(alice, aliceVe);

        vm.deal(mineCore, ethAmount);
        vm.prank(mineCore);
        royalties.onTakeover{value: ethAmount}(1);
        royalties.flushPendingShareholderETH();
        royalties.checkpointUser(alice);

        uint256 claimableBefore = royalties.claimableEth(alice);
        if (claimableBefore == 0) return;

        vm.mockCall(mineMarket, abi.encodeWithSignature("royalties()"), abi.encode(address(0xDEAD)));

        vm.prank(alice);
        vm.expectRevert(Errors.WiringMismatch.selector);
        royalties.claimShareholder(Constants.SHAREHOLDER_MODE_ETH, 0, 0, false, 0);

        assertEq(
            royalties.claimableEth(alice),
            claimableBefore,
            "market royalties drift must not consume claimable Baron ETH"
        );
    }

    function testFuzz_claimShareholderForRejectsSingleSurfaceHelperDriftAndPreservesClaimable(
        uint96 takeoverEth,
        uint96 veAlice
    ) public {
        uint256 ethAmount = bound(uint256(takeoverEth), 1, 10 ether);
        uint256 aliceVe = bound(uint256(veAlice), 10e18, 300e18);
        uint256 veTotal = aliceVe * 2;
        if (veTotal < Constants.MIN_VE_FLUSH) veTotal = Constants.MIN_VE_FLUSH;

        ClaimAllHelper canonicalHelper = new ClaimAllHelper(address(royalties), mineCore);
        ClaimAllHelper rogueHelper = new ClaimAllHelper(address(royalties), mineCore);

        vm.prank(owner);
        royalties.setClaimAllHelper(address(rogueHelper));
        vm.mockCall(mineCore, abi.encodeWithSignature("claimAllHelper()"), abi.encode(address(canonicalHelper)));

        ve.setTotalVeCached(veTotal);
        ve.setVeBalance(alice, aliceVe);

        vm.deal(mineCore, ethAmount);
        vm.prank(mineCore);
        royalties.onTakeover{value: ethAmount}(1);
        royalties.flushPendingShareholderETH();
        royalties.checkpointUser(alice);

        uint256 claimableBefore = royalties.claimableEth(alice);
        if (claimableBefore == 0) return;

        vm.prank(address(rogueHelper));
        vm.expectRevert(Errors.WiringMismatch.selector);
        royalties.claimShareholderFor(alice, Constants.SHAREHOLDER_MODE_LOCK_FURNACE, 1, 30 days, false, 0);

        assertEq(
            royalties.claimableEth(alice),
            claimableBefore,
            "single-surface helper drift must not consume claimable Baron ETH"
        );
    }
}
