// SPDX-License-Identifier: MIT
pragma solidity ^0.8.34;

import {Test} from "forge-std/Test.sol";
import {Vm} from "forge-std/Vm.sol";

import {ClaimToken} from "src/ClaimToken.sol";
import {EntryTokenRegistry} from "src/EntryTokenRegistry.sol";
import {Furnace} from "src/Furnace.sol";
import {FurnaceGuardHelper} from "src/FurnaceGuardHelper.sol";

import {FurnaceQuoter} from "src/FurnaceQuoter.sol";
import {Constants} from "src/lib/Constants.sol";
import {Errors} from "src/lib/Errors.sol";

import {MockAerodromeRouterMineCore} from "./mocks/MockAerodromeRouterMineCore.sol";
import {MockShareholderRoyaltiesCheckpoint} from "./mocks/MockShareholderRoyaltiesCheckpoint.sol";
import {MockWETH} from "./mocks/MockWETH.sol";
import {VeClaimNFTHarness} from "./mocks/VeClaimNFTHarness.sol";

contract FurnaceQuoteExecuteMinVeOutTest is Test {
    address internal owner;
    address internal alice;

    ClaimToken public claim;
    VeClaimNFTHarness internal ve;
    Furnace internal furnace;
    FurnaceQuoter internal furnaceQuoter;

    MockWETH internal weth;
    MockAerodromeRouterMineCore internal router;
    EntryTokenRegistry internal reg;

    function setUp() public {
        vm.txGasPrice(0);

        owner = makeAddr("owner");
        alice = makeAddr("alice");

        claim = new ClaimToken(owner);
        ve = new VeClaimNFTHarness(address(claim), owner);
        furnace = new Furnace(
            address(claim), address(ve), address(new FurnaceGuardHelper(address(claim), address(ve))), owner
        );

        weth = new MockWETH();

        // Give the factory address code so EntryTokenRegistry accepts it.
        vm.etch(address(0xFACADE), hex"01");
        vm.etch(address(0xBEEF), hex"01");

        address mockSR = address(new MockShareholderRoyaltiesCheckpoint());

        router = new MockAerodromeRouterMineCore(
            address(0xFACADE), address(weth), address(claim), address(ve), address(furnace), mockSR
        );
        reg = new EntryTokenRegistry(owner);

        vm.startPrank(owner);
        claim.setMineCore(address(router));
        furnace.setMineCore(address(router));

        // Wire Furnace <-> ve.
        address market = address(0xBABA);
        vm.etch(market, hex"01");
        vm.mockCall(market, abi.encodeWithSignature("ve()"), abi.encode(address(ve)));
        vm.mockCall(market, abi.encodeWithSignature("claim()"), abi.encode(address(claim)));
        vm.mockCall(market, abi.encodeWithSignature("royalties()"), abi.encode(mockSR));
        furnace.setMineMarket(market);
        furnace.setShareholderRoyalties(mockSR);
        MockShareholderRoyaltiesCheckpoint(mockSR).setWiring(address(router), market, address(furnace), address(ve));
        ve.setFurnace(address(furnace));
        ve.setMineMarket(market);

        // Minimal router config required by SPEC precondition checks.
        reg.setRouterConfig(address(router), router.defaultFactory(), address(weth), address(claim));
        router.setPoolFor(address(weth), address(claim), false, router.defaultFactory(), address(0xBEEF));
        reg.setWethClaimHop(false, address(0xBEEF));
        furnace.setEntryTokenRegistry(address(reg));
        furnaceQuoter = new FurnaceQuoter(address(furnace));
        furnace.setFurnaceQuoter(address(furnaceQuoter));
        vm.stopPrank();

        // Seed reserve so bonus math is exercised (router is MineCore — use `deal`, not test `mint`).
        uint256 reserve = 1_000_000e18;
        deal(address(claim), address(furnace), reserve);
        vm.prank(address(router));
        furnace.creditReserve(reserve);

        deal(address(claim), alice, 1_000_000e18);
    }

    function testQuoteAndExecute_enterWithClaim_matches_and_honorsMinVeOut() public {
        uint256 claimIn = 10_000e18;
        uint256 duration = Constants.MIN_LOCK_DURATION;

        vm.startPrank(alice);
        claim.approve(address(furnace), claimIn);

        (uint256 principal, uint256 bonus, uint256 veOut, uint256 routeTokenId) =
            furnaceQuoter.quoteEnterWithClaim(alice, claimIn, 0, duration, false);

        assertEq(principal, claimIn);
        assertEq(routeTokenId, 0);
        assertGt(veOut, 0);

        uint256 reserveBefore = furnace.furnaceReserve();

        // Exact minVeOut from quote MUST succeed.
        furnace.enterWithClaim(claimIn, 0, duration, false, veOut);
        vm.stopPrank();

        // New lock minted to Alice (first lock id is 1).
        assertEq(ve.ownerOf(1), alice);

        (uint256 locked,,,) = ve.getLockInfo(1);
        assertEq(locked, principal + bonus);

        // veBalanceOf should match the quoted veOut when no state changes occurred between quote + execute.
        assertEq(ve.veBalanceOf(alice), veOut);

        // Reserve should be debited by the user bonus (LP vault is unset in this fixture).
        assertEq(furnace.furnaceReserve(), reserveBefore - bonus);
    }

    function testOffchainParity_furnaceEnterEventMatchesQuoteAndExecution() public {
        uint256 claimIn = 10_000e18;
        uint256 duration = Constants.MIN_LOCK_DURATION;

        vm.startPrank(alice);
        claim.approve(address(furnace), claimIn);
        (uint256 principal, uint256 bonus, uint256 veOut, uint256 routeTokenId) =
            furnaceQuoter.quoteEnterWithClaim(alice, claimIn, 0, duration, false);
        assertEq(routeTokenId, 0, "new lock route placeholder");

        vm.recordLogs();
        furnace.enterWithClaim(claimIn, 0, duration, false, veOut);
        Vm.Log[] memory logs = vm.getRecordedLogs();
        vm.stopPrank();

        bytes32 enterTopic = keccak256("FurnaceEnter(address,uint8,uint256,uint256,uint256,uint256)");
        bool found;
        for (uint256 i = 0; i < logs.length; ++i) {
            if (logs[i].topics.length == 2 && logs[i].topics[0] == enterTopic) {
                found = true;
                assertEq(logs[i].topics[1], bytes32(uint256(uint160(alice))), "user topic");
                (uint8 mode, uint256 ethIn, uint256 principalEvent, uint256 bonusEvent, uint256 tokenIdEvent) =
                    abi.decode(logs[i].data, (uint8, uint256, uint256, uint256, uint256));
                assertEq(mode, Constants.FURNACE_MODE_ENTER_WITH_CLAIM, "mode");
                assertEq(ethIn, 0, "ethIn");
                assertEq(principalEvent, principal, "principal");
                assertEq(bonusEvent, bonus, "bonus");
                assertEq(tokenIdEvent, 1, "minted token id");
                break;
            }
        }

        assertTrue(found, "FurnaceEnter event not found");
        (uint256 locked,,,) = ve.getLockInfo(1);
        assertEq(locked, principal + bonus, "event quote must equal lock principal delta");
        assertEq(ve.veBalanceOf(alice), veOut, "quote must equal executed ve");
    }

    /// @dev `enterWithEth` swaps via `MockAerodromeRouterMineCore` (MineCore + router); mint uses `onlyMineCore`.
    function testQuoteAndExecute_enterWithEth_matches_and_honorsMinVeOut() public {
        router.setRateX18(2000e18);

        uint256 ethIn = 1 ether;
        uint256 duration = Constants.MIN_LOCK_DURATION;

        vm.deal(alice, 10 ether);

        (uint256 principal, uint256 bonus, uint256 veOut, uint256 routeTokenId) =
            furnaceQuoter.quoteEnterWithEth(alice, ethIn, 0, duration, false);

        assertGt(principal, 0);
        assertEq(routeTokenId, 0);
        assertGt(veOut, 0);

        uint256 reserveBefore = furnace.furnaceReserve();

        vm.prank(alice);
        furnace.enterWithEth{value: ethIn}(0, duration, false, veOut);

        assertEq(ve.ownerOf(1), alice);
        (uint256 locked,,,) = ve.getLockInfo(1);
        assertEq(locked, principal + bonus);
        assertEq(ve.veBalanceOf(alice), veOut);
        assertEq(furnace.furnaceReserve(), reserveBefore - bonus);
    }

    function testEnterWithClaim_revertsIfMinVeOutNotMet() public {
        uint256 claimIn = 10_000e18;
        uint256 duration = Constants.MIN_LOCK_DURATION;

        vm.startPrank(alice);
        claim.approve(address(furnace), claimIn);

        (,, uint256 veOut,) = furnaceQuoter.quoteEnterWithClaim(alice, claimIn, 0, duration, false);

        vm.expectRevert(Errors.MinVeOutNotMet.selector);
        furnace.enterWithClaim(claimIn, 0, duration, false, veOut + 1);

        vm.stopPrank();
    }

    function testEnterWithClaim_revertsIfMinVeOutIsZero() public {
        uint256 claimIn = 10_000e18;
        uint256 duration = Constants.MIN_LOCK_DURATION;

        vm.startPrank(alice);
        claim.approve(address(furnace), claimIn);

        vm.expectRevert(Errors.MinVeOutRequired.selector);
        furnace.enterWithClaim(claimIn, 0, duration, false, 0);

        vm.stopPrank();
    }

    function testFuzz_quoteExecute_minVeOut_exact(uint256 claimIn, uint256 duration) public {
        // Keep fuzz bounded and within spec constraints.
        // IMPORTANT: use `bound` instead of `assume` so fuzzing doesn't exhaust itself rejecting inputs.
        claimIn = bound(claimIn, Constants.MIN_LOCK_AMOUNT, 500_000e18);
        duration = bound(duration, Constants.MIN_LOCK_DURATION, Constants.MAX_LOCK_DURATION);

        // Fresh user per fuzz input to avoid hitting MAX_VE_NFTS_PER_USER.
        // Force non-zero address deterministically.
        address user = address(uint160(uint256(keccak256(abi.encode(claimIn, duration))) | 1));

        deal(address(claim), user, claimIn);

        vm.startPrank(user);
        claim.approve(address(furnace), claimIn);

        (uint256 p, uint256 b, uint256 veOut,) = furnaceQuoter.quoteEnterWithClaim(user, claimIn, 0, duration, false);
        assertEq(p, claimIn);
        furnace.enterWithClaim(claimIn, 0, duration, false, veOut);

        // Locked principal+bonus must match quote for a non-racing state.
        assertEq(ve.totalLockedClaim(), p + b);
        assertEq(ve.veBalanceOf(user), veOut);

        // Aggregate accounting should always be consistent.
        assertEq(claim.balanceOf(address(ve)), ve.totalLockedClaim());
        assertGe(claim.balanceOf(address(furnace)), furnace.furnaceReserve());

        vm.stopPrank();
    }

    function testQuoteAndExecute_enterWithClaim_createAutoMax_matches_and_mintsAutoMax() public {
        uint256 claimIn = 10_000e18;
        uint256 duration = Constants.MAX_LOCK_DURATION;

        vm.startPrank(alice);
        claim.approve(address(furnace), claimIn);

        (uint256 principal, uint256 bonus, uint256 veOut, uint256 routeTokenId) =
            furnaceQuoter.quoteEnterWithClaim(alice, claimIn, 0, duration, true);

        assertEq(principal, claimIn);
        assertEq(routeTokenId, 0);

        // For a new AutoMax lock at max duration, the ve increase is 1:1 with the amount locked.
        assertEq(veOut, principal + bonus);

        uint256 reserveBefore = furnace.furnaceReserve();

        // Exact minVeOut from quote MUST succeed.
        furnace.enterWithClaim(claimIn, 0, duration, true, veOut);
        vm.stopPrank();

        assertEq(ve.ownerOf(1), alice);

        (uint256 locked, uint256 lockEnd, bool autoMax,) = ve.getLockInfo(1);
        assertEq(locked, principal + bonus);
        assertTrue(autoMax);
        assertEq(lockEnd, block.timestamp + Constants.MAX_LOCK_DURATION);

        // ve == amount for AutoMax.
        assertEq(ve.veBalanceOf(alice), locked);

        // Reserve should be debited by the user bonus (LP vault is unset in this fixture).
        assertEq(furnace.furnaceReserve(), reserveBefore - bonus);
    }

    function testEnterWithClaim_createAutoMax_revertsIfDurationNotMax() public {
        uint256 claimIn = 10_000e18;

        vm.startPrank(alice);
        claim.approve(address(furnace), claimIn);

        vm.expectRevert(Errors.InvalidDuration.selector);
        furnace.enterWithClaim(claimIn, 0, Constants.MAX_LOCK_DURATION - 1, true, 1);

        vm.stopPrank();
    }

    function testQuoteAndExecute_enterWithClaim_intoExistingAutoMax_matches_and_honorsMinVeOut() public {
        // Seed an AutoMax lock directly.
        uint256 seedLock = Constants.MIN_LOCK_AMOUNT;

        vm.startPrank(alice);
        claim.approve(address(ve), seedLock);
        uint256 tokenId = ve.createLock(seedLock, Constants.MAX_LOCK_DURATION, true);

        // Now enter via Furnace into the existing AutoMax lock.
        uint256 claimIn = 10_000e18;
        claim.approve(address(furnace), claimIn);

        (uint256 principal, uint256 bonus, uint256 veOut, uint256 routeTokenId) =
            furnaceQuoter.quoteEnterWithClaim(alice, claimIn, tokenId, Constants.MAX_LOCK_DURATION, false);

        assertEq(principal, claimIn);
        assertEq(routeTokenId, tokenId);

        // For an existing AutoMax lock, delta-ve must equal the amount locked.
        assertEq(veOut, principal + bonus);

        uint256 totalBefore = ve.totalLockedClaim();

        // Exact minVeOut from quote MUST succeed.
        furnace.enterWithClaim(claimIn, tokenId, Constants.MAX_LOCK_DURATION, false, veOut);
        vm.stopPrank();

        // Lock amount increased by principal+bonus and remains AutoMax.
        (uint256 locked, uint256 lockEnd, bool autoMax,) = ve.getLockInfo(tokenId);
        assertTrue(autoMax);
        assertEq(lockEnd, block.timestamp + Constants.MAX_LOCK_DURATION);
        assertEq(locked, seedLock + principal + bonus);

        // With AutoMax, ve == amount.
        assertEq(ve.veBalanceOf(alice), locked);

        // Aggregate accounting remains consistent.
        assertEq(ve.totalLockedClaim(), totalBefore + principal + bonus);
        assertEq(claim.balanceOf(address(ve)), ve.totalLockedClaim());
    }

    function testEnterWithClaim_intoExistingAutoMax_revertsIfDurationNotMax() public {
        uint256 seedLock = Constants.MIN_LOCK_AMOUNT;

        vm.startPrank(alice);
        claim.approve(address(ve), seedLock);
        uint256 tokenId = ve.createLock(seedLock, Constants.MAX_LOCK_DURATION, true);

        uint256 claimIn = 10_000e18;
        claim.approve(address(furnace), claimIn);

        // Quote should revert (same validation as execution).
        vm.expectRevert(Errors.InvalidDuration.selector);
        furnaceQuoter.quoteEnterWithClaim(alice, claimIn, tokenId, Constants.MIN_LOCK_DURATION, false);

        vm.expectRevert(Errors.InvalidDuration.selector);
        furnace.enterWithClaim(claimIn, tokenId, Constants.MIN_LOCK_DURATION, false, 1);

        vm.stopPrank();
    }

    function testQuoteAndExecute_existingLockTopUp_durationNotExtended() public {
        // Seed a non-AutoMax lock with short remaining time.
        uint256 seedLock = 20_000e18;
        vm.startPrank(alice);
        claim.approve(address(ve), seedLock);
        uint256 tokenId = ve.createLock(seedLock, Constants.MIN_LOCK_DURATION, false);

        (, uint256 lockEndBefore,,) = ve.getLockInfo(tokenId);

        uint256 claimIn = 10_000e18;
        claim.approve(address(furnace), claimIn);

        // Quote into existing lock — durationSeconds is ignored for existing non-AutoMax locks.
        // veOut reflects oldRemaining, not the passed durationSeconds.
        (,, uint256 veOutQuoted, uint256 routeTokenId) =
            furnaceQuoter.quoteEnterWithClaim(alice, claimIn, tokenId, Constants.MAX_LOCK_DURATION, false);
        assertEq(routeTokenId, tokenId);
        assertGt(veOutQuoted, 0);

        // Guard is strict on this quoted value.
        vm.expectRevert(Errors.MinVeOutNotMet.selector);
        furnace.enterWithClaim(claimIn, tokenId, Constants.MAX_LOCK_DURATION, false, veOutQuoted + 1);

        furnace.enterWithClaim(claimIn, tokenId, Constants.MAX_LOCK_DURATION, false, veOutQuoted);
        vm.stopPrank();

        // Lock end must NOT have changed — entry does not extend duration.
        (, uint256 lockEndAfter,,) = ve.getLockInfo(tokenId);
        assertEq(lockEndAfter, lockEndBefore, "lock end must not change on top-up");
    }

    function testQuoteAndExecute_existingLockTopUp_bonusUsesEffectiveRemainingDuration() public {
        uint256 seedLock = 20_000e18;
        vm.startPrank(alice);
        claim.approve(address(ve), seedLock);
        uint256 tokenId = ve.createLock(seedLock, Constants.MIN_LOCK_DURATION, false);

        (uint256 lockedBefore, uint256 lockEndBefore,,) = ve.getLockInfo(tokenId);

        uint256 claimIn = 10_000e18;
        claim.approve(address(furnace), claimIn);

        (uint256 principalShort, uint256 bonusShort, uint256 veOutShort,) =
            furnaceQuoter.quoteEnterWithClaim(alice, claimIn, tokenId, Constants.MIN_LOCK_DURATION, false);
        (uint256 principalLong, uint256 bonusLong, uint256 veOutLong,) =
            furnaceQuoter.quoteEnterWithClaim(alice, claimIn, tokenId, Constants.MAX_LOCK_DURATION, false);

        assertEq(principalShort, claimIn, "principalShort");
        assertEq(principalLong, claimIn, "principalLong");
        assertEq(bonusLong, bonusShort, "bonus must use the lock's actual remaining duration");
        assertEq(veOutLong, veOutShort, "veOut must not depend on an ignored requested duration");

        furnace.enterWithClaim(claimIn, tokenId, Constants.MAX_LOCK_DURATION, false, veOutLong);
        vm.stopPrank();

        (uint256 lockedAfter, uint256 lockEndAfter,,) = ve.getLockInfo(tokenId);
        assertEq(lockedAfter - lockedBefore, principalShort + bonusShort, "top-up delta mismatch");
        assertEq(lockEndAfter, lockEndBefore, "entry must not extend the existing lock");
    }

    // ── Near-expiry guard: existing locks with < MIN_LOCK_DURATION remaining ──

    function test_revert_enterWithClaim_existingLock_belowMinDuration() public {
        uint256 seedLock = 20_000e18;
        vm.startPrank(alice);
        claim.approve(address(ve), seedLock);
        uint256 tokenId = ve.createLock(seedLock, Constants.MIN_LOCK_DURATION, false);

        // Warp to 1 second before MIN_LOCK_DURATION remaining (so remaining = 6d 23h 59m 59s).
        vm.warp(block.timestamp + 1);

        uint256 claimIn = 10_000e18;
        claim.approve(address(furnace), claimIn);

        vm.expectRevert(Errors.InvalidDuration.selector);
        furnace.enterWithClaim(claimIn, tokenId, Constants.MIN_LOCK_DURATION, false, 1);
        vm.stopPrank();
    }

    function test_revert_quoteEnterWithClaim_existingLock_belowMinDuration() public {
        uint256 seedLock = 20_000e18;
        vm.startPrank(alice);
        claim.approve(address(ve), seedLock);
        uint256 tokenId = ve.createLock(seedLock, Constants.MIN_LOCK_DURATION, false);

        vm.warp(block.timestamp + 1);

        uint256 claimIn = 10_000e18;

        vm.expectRevert(Errors.InvalidDuration.selector);
        furnaceQuoter.quoteEnterWithClaim(alice, claimIn, tokenId, Constants.MIN_LOCK_DURATION, false);
        vm.stopPrank();
    }

    function test_enterWithClaim_existingLock_exactlyMinDuration_succeeds() public {
        uint256 seedLock = 20_000e18;
        vm.startPrank(alice);
        claim.approve(address(ve), seedLock);
        uint256 tokenId = ve.createLock(seedLock, Constants.MIN_LOCK_DURATION, false);

        // Remaining == exactly MIN_LOCK_DURATION: should succeed.
        uint256 claimIn = 10_000e18;
        claim.approve(address(furnace), claimIn);

        (,, uint256 veOut,) =
            furnaceQuoter.quoteEnterWithClaim(alice, claimIn, tokenId, Constants.MIN_LOCK_DURATION, false);
        assertGt(veOut, 0, "quote must succeed at exactly MIN_LOCK_DURATION");

        furnace.enterWithClaim(claimIn, tokenId, Constants.MIN_LOCK_DURATION, false, 1);
        vm.stopPrank();
    }
}
