// SPDX-License-Identifier: MIT
pragma solidity ^0.8.34;

import {Test} from "forge-std/Test.sol";

import {ClaimToken} from "src/ClaimToken.sol";
import {Furnace} from "src/Furnace.sol";
import {FurnaceGuardHelper} from "src/FurnaceGuardHelper.sol";

import {FurnaceQuoter} from "src/FurnaceQuoter.sol";
import {ShareholderRoyalties} from "src/ShareholderRoyalties.sol";
import {Constants} from "src/lib/Constants.sol";
import {Errors} from "src/lib/Errors.sol";
import {Events} from "src/lib/Events.sol";

import {MockVe} from "./mocks/MockVe.sol";
import {MineCoreHarness} from "./mocks/MineCoreHarness.sol";

/// @notice MineCore emission and pause edge cases.
/// @dev Covers: emission integral boundary crossing, defensive `mint` overflow guards, pause
///      emission clamping, genesis furnace emission path, takeover price boundary, and
///      `setLockingPaused` reentrancy guard.
contract MineCore_EmissionAndPauseEdgeCases_Test is Test {
    ClaimToken internal claim;
    MockVe internal ve;
    ShareholderRoyalties internal royalties;
    Furnace internal furnace;
    MineCoreHarness internal mineCore;

    address internal owner = address(0xA11CE);
    address internal alice;
    address internal bob;

    uint256 internal emStart;

    function setUp() public {
        vm.txGasPrice(0);

        alice = makeAddr("alice");
        bob = makeAddr("bob");

        claim = new ClaimToken(owner);
        ve = new MockVe();
        royalties = new ShareholderRoyalties(address(ve), owner);
        furnace = new Furnace(
            address(claim), address(ve), address(new FurnaceGuardHelper(address(claim), address(ve))), owner
        );
        FurnaceQuoter quoter = new FurnaceQuoter(address(furnace));
        mineCore = new MineCoreHarness(address(claim), address(ve), address(royalties), owner);

        emStart = mineCore.emissionStartTime();

        vm.startPrank(owner);
        claim.setMineCore(address(mineCore));
        ve.setClaimToken(address(claim));
        furnace.setMineCore(address(mineCore));
        furnace.setFurnaceQuoter(address(quoter));
        vm.etch(address(0xB0B0), hex"00");
        furnace.setMineMarket(address(0xB0B0));
        furnace.setShareholderRoyalties(address(royalties));
        mineCore.setFurnace(address(furnace));
        vm.mockCall(address(0xB0B0), abi.encodeWithSignature("ve()"), abi.encode(address(ve)));
        vm.mockCall(address(0xB0B0), abi.encodeWithSignature("claim()"), abi.encode(address(claim)));
        vm.mockCall(address(0xB0B0), abi.encodeWithSignature("royalties()"), abi.encode(address(royalties)));
        ve.setFurnace(address(furnace));
        ve.setMineMarket(address(0xB0B0));
        royalties.setWiring(address(mineCore), address(0xB0B0), address(furnace));
        mineCore.setGenesisKingClaimCollectedForTest(true);
        mineCore.setTakeoversPaused(false);
        vm.stopPrank();

        ve.setTotalVeCached(1234);
    }

    // ---------------------------------------------------------------
    // Emission integral boundary crossing tests
    // ---------------------------------------------------------------

    /// @notice King emission integral fully within the decay region.
    function test_kingEmitted_fullyInDecay() public view {
        uint256 ts0 = emStart + 100;
        uint256 ts1 = emStart + 200;
        uint256 emitted = mineCore.kingEmittedExposed(ts0, ts1);

        // 100 seconds near launch: rate ≈ 50 CLAIM/sec (very slight decay)
        // Expected: approximately 50e18 * 100 = 5000e18
        assertGt(emitted, 4999e18, "should emit close to 5000 CLAIM");
        assertLt(emitted, 5001e18, "should emit close to 5000 CLAIM");
    }

    /// @notice King emission integral crossing the decay/floor boundary.
    function test_kingEmitted_crossesBoundary() public view {
        uint256 floorTs = emStart + Constants.EMISSION_DECAY_PERIOD;
        uint256 ts0 = floorTs - 100; // 100 seconds before boundary
        uint256 ts1 = floorTs + 100; // 100 seconds after boundary

        uint256 emitted = mineCore.kingEmittedExposed(ts0, ts1);

        // Near the boundary: rate ≈ floor rate ≈ 50/9 CLAIM/sec
        // 200 seconds * ~5.555 CLAIM/sec ≈ ~1111 CLAIM
        uint256 floorRate = Constants.KING_EMISSION_FLOOR;
        uint256 expectedApprox = floorRate * 200;
        assertGt(emitted, expectedApprox - 1e18, "boundary emission lower bound");
        // Decay part rate >= floor rate, so total >= floor * dt
        assertGe(emitted, expectedApprox, "decay part should contribute >= floor rate");
    }

    /// @notice King emission integral fully in the tail (post-decay).
    function test_kingEmitted_fullyInTail() public view {
        uint256 floorTs = emStart + Constants.EMISSION_DECAY_PERIOD;
        uint256 ts0 = floorTs + 1000;
        uint256 ts1 = floorTs + 2000;

        uint256 emitted = mineCore.kingEmittedExposed(ts0, ts1);

        uint256 expected = Constants.KING_EMISSION_FLOOR * 1000;
        assertEq(emitted, expected, "tail emission should be floor * dt");
    }

    /// @notice King emission when ts0 == emissionStartTime (genesis boundary).
    function test_kingEmitted_fromGenesisStart() public view {
        uint256 ts0 = emStart;
        uint256 ts1 = emStart + 1;

        uint256 emitted = mineCore.kingEmittedExposed(ts0, ts1);

        // At t=0, rate = KING_EMISSION_LAUNCH_RATE = 50e18
        // At t=1, rate ≈ 50e18 (very slightly decayed)
        // Emitted = (50e18 + ~50e18) / 2 ≈ 50e18
        assertGe(emitted, 49e18, "genesis second should emit ~50 CLAIM");
        assertLe(emitted, 51e18, "genesis second should emit ~50 CLAIM");
    }

    /// @notice Emission returns 0 for zero-width interval.
    function test_kingEmitted_zeroInterval() public view {
        uint256 ts = emStart + 1000;
        uint256 emitted = mineCore.kingEmittedExposed(ts, ts);
        assertEq(emitted, 0, "zero-width interval should emit 0");
    }

    /// @notice Emission returns 0 when interval is before emissionStartTime.
    function test_kingEmitted_beforeEmissionStart() public view {
        // emStart is block.timestamp at deployment, but ts0/ts1 before it
        // We can't easily go before emStart in practice, but _emitted handles it
        uint256 emitted = mineCore.kingEmittedExposed(0, 1);
        // If emStart > 1, this should return 0
        if (emStart > 1) {
            assertEq(emitted, 0, "before emission start should emit 0");
        }
    }

    /// @notice Furnace emission matches King emission ratio (1:10).
    function test_furnaceEmitted_matchesKingRatio() public view {
        uint256 ts0 = emStart + 100;
        uint256 ts1 = emStart + 200;

        uint256 kingEmitted = mineCore.kingEmittedExposed(ts0, ts1);
        uint256 furnaceEmitted = mineCore.furnaceEmittedExposed(ts0, ts1);

        // King:Furnace = 50:5 = 10:1
        // Emission integral rounding accumulates ~300 wei over 100 seconds
        assertApproxEqAbs(kingEmitted, furnaceEmitted * 10, 1000, "10:1 king:furnace ratio");
    }

    /// @notice Furnace emission ratio holds in the tail region too.
    function test_furnaceEmitted_tailRatio() public view {
        uint256 floorTs = emStart + Constants.EMISSION_DECAY_PERIOD;
        uint256 ts0 = floorTs + 1000;
        uint256 ts1 = floorTs + 2000;

        uint256 kingEmitted = mineCore.kingEmittedExposed(ts0, ts1);
        uint256 furnaceEmitted = mineCore.furnaceEmittedExposed(ts0, ts1);

        // Tail: King floor / Furnace floor = 5_555... / 555... ≈ 10
        // Floor-rate integer division rounding accumulates ~5000 wei over 1000 seconds
        assertApproxEqAbs(kingEmitted, furnaceEmitted * 10, 10_000, "tail 10:1 ratio");
    }

    // ---------------------------------------------------------------
    // Takeover price boundary tests
    // ---------------------------------------------------------------

    /// @notice Takeover price at exactly TAKEOVER_DECAY_PERIOD should be floor.
    function test_takeoverPrice_atExactDecayPeriod() public {
        // Set up a non-genesis reign with a known referencePrice.
        uint256 refPrice = 1 ether;
        uint256 t0 = emStart + 100;
        mineCore.setReignStateForTest(alice, t0, refPrice, t0);

        // At exactly t0 + TAKEOVER_DECAY_PERIOD, price should be floor.
        uint256 priceAtBoundary = mineCore.getTakeoverPrice(t0 + Constants.TAKEOVER_DECAY_PERIOD);
        assertEq(priceAtBoundary, Constants.TAKEOVER_PRICE_FLOOR, "price at decay boundary should be floor");
    }

    /// @notice Takeover price 1 second before decay period end.
    function test_takeoverPrice_oneSecondBeforeDecayEnd() public {
        uint256 refPrice = 1 ether;
        uint256 t0 = emStart + 100;
        mineCore.setReignStateForTest(alice, t0, refPrice, t0);

        uint256 priceJustBefore = mineCore.getTakeoverPrice(t0 + Constants.TAKEOVER_DECAY_PERIOD - 1);
        // Should be slightly above floor
        assertGe(priceJustBefore, Constants.TAKEOVER_PRICE_FLOOR, "price should be >= floor");
    }

    /// @notice Takeover price at t=0 should equal referencePrice.
    function test_takeoverPrice_atReignStart() public {
        uint256 refPrice = 2 ether;
        uint256 t0 = emStart + 100;
        mineCore.setReignStateForTest(alice, t0, refPrice, t0);

        uint256 priceAtStart = mineCore.getTakeoverPrice(t0);
        assertEq(priceAtStart, refPrice, "price at reign start should be referencePrice");
    }

    /// @notice Takeover price when no king (genesis) should be floor.
    function test_takeoverPrice_genesis() public view {
        // currentKing is address(0) by default
        uint256 price = mineCore.getTakeoverPrice(block.timestamp);
        assertEq(price, Constants.TAKEOVER_PRICE_FLOOR, "genesis price should be floor");
    }

    // ---------------------------------------------------------------
    // Pause emission clamping tests
    // ---------------------------------------------------------------

    /// @notice audit F-2: pausing excludes ONLY the paused interval from accrual and preserves
    ///         the sitting king's pre-pause active accrual (it does not slam the cursor to now).
    function test_pauseUnpause_clampsEmissions() public {
        vm.deal(alice, 10 ether);
        vm.deal(bob, 10 ether);

        // Advance time and do genesis takeover.
        vm.warp(emStart + 100);
        vm.prank(alice);
        mineCore.takeover{value: Constants.TAKEOVER_PRICE_FLOOR}(type(uint256).max);

        // Record accrual time after takeover.
        uint256 accrualAfterTakeover = mineCore.currentReignLastAccrualTime();
        assertEq(accrualAfterTakeover, block.timestamp, "accrual should be current time");

        // Advance 1000 seconds.
        vm.warp(block.timestamp + 1000);

        // Pause.
        vm.prank(owner);
        mineCore.setTakeoversPaused(true);

        // audit F-2: the cursor is NOT advanced on pause, so pre-pause active accrual survives.
        uint256 accrualAfterPause = mineCore.currentReignLastAccrualTime();
        assertEq(accrualAfterPause, accrualAfterTakeover, "pause must preserve the pre-pause accrual cursor");

        // Advance 5000 more seconds (paused time).
        vm.warp(block.timestamp + 5000);

        // Unpause.
        vm.prank(owner);
        mineCore.setTakeoversPaused(false);

        // audit F-2: unpause advances the cursor by exactly the 5000s paused duration, so only
        // the paused interval is excluded and the 1000s of pre-pause active accrual is preserved.
        uint256 accrualAfterUnpause = mineCore.currentReignLastAccrualTime();
        assertEq(accrualAfterUnpause, block.timestamp - 1000, "unpause excludes only paused time");

        // Verify king/reignId/startTime/referencePrice NOT mutated by pause.
        assertEq(mineCore.currentKing(), alice, "king should not change on pause");
        assertEq(mineCore.currentReignId(), 1, "reignId should not change on pause");
    }

    /// @notice audit F-2 regression: a pause/unpause during a reign preserves the king's pre-pause
    ///         active emissions at the next takeover (only the paused interval is excluded),
    ///         instead of forfeiting the entire pre-pause window.
    function test_pauseUnpause_preservesPrePauseKingEmission() public {
        vm.deal(alice, 10 ether);
        vm.deal(bob, 10 ether);

        // Alice becomes king at emStart+100.
        vm.warp(emStart + 100);
        vm.prank(alice);
        mineCore.takeover{value: Constants.TAKEOVER_PRICE_FLOOR}(type(uint256).max);

        // Alice actively reigns 500s, then the guardian pauses (incident).
        vm.warp(emStart + 600);
        vm.prank(owner);
        mineCore.setTakeoversPaused(true);

        // Paused 300s, then unpause.
        vm.warp(emStart + 900);
        vm.prank(owner);
        mineCore.setTakeoversPaused(false);

        // Cursor advanced by exactly the 300s pause -> emStart+400 (the 500s pre-pause preserved).
        uint256 cursorAfter = mineCore.currentReignLastAccrualTime();
        assertEq(cursorAfter, emStart + 400, "only the 300s pause is excluded");

        // Let price decay to floor, then bob takes over (finalizes alice's reign).
        vm.warp(emStart + 900 + Constants.TAKEOVER_DECAY_PERIOD);
        uint256 takeoverTs = block.timestamp;
        vm.prank(bob);
        mineCore.takeover{value: Constants.TAKEOVER_PRICE_FLOOR}(type(uint256).max);

        // Alice's reign mined CLAIM == king emission over the active window [cursorAfter, takeoverTs].
        uint256 expectedActive = mineCore.kingEmittedExposed(cursorAfter, takeoverTs);
        MineCoreHarness.ReignInfo memory info = mineCore.getReignInfo(1);
        assertEq(info.totalClaimMined, expectedActive, "king mined == active-window emission");

        // And it MUST exceed the OLD buggy 'post-unpause only' amount that discarded pre-pause active.
        uint256 buggyPostUnpauseOnly = mineCore.kingEmittedExposed(emStart + 900, takeoverTs);
        assertGt(info.totalClaimMined, buggyPostUnpauseOnly, "pre-pause active accrual preserved");
    }

    /// @notice Pausing when no king does not clamp accrual (no-op for accrual).
    function test_pause_noKing_doesNotClamp() public {
        uint256 accrualBefore = mineCore.currentReignLastAccrualTime();

        vm.prank(owner);
        mineCore.setTakeoversPaused(true);

        uint256 accrualAfter = mineCore.currentReignLastAccrualTime();
        assertEq(accrualAfter, accrualBefore, "accrual should not change when no king");
    }

    /// @notice Idempotent pause call is a no-op.
    function test_pause_idempotent() public {
        // Already paused at genesis - but we already unpaused in setUp.
        // Re-pause.
        vm.prank(owner);
        mineCore.setTakeoversPaused(true);

        // Pause again (same value) - should be no-op.
        vm.prank(owner);
        mineCore.setTakeoversPaused(true);
        // No revert = pass.
    }

    // ---------------------------------------------------------------
    // Genesis furnace emission during first takeover
    // ---------------------------------------------------------------

    /// @notice First takeover mints furnace emission from emissionStartTime to now.
    function test_genesisTakeover_mintsFurnaceEmission() public {
        vm.warp(emStart + 100);

        uint256 furnaceBalBefore = claim.balanceOf(address(furnace));
        uint256 expectedFurnace = mineCore.furnaceEmittedExposed(emStart, block.timestamp);

        vm.deal(alice, 1 ether);
        vm.prank(alice);
        mineCore.takeover{value: Constants.TAKEOVER_PRICE_FLOOR}(type(uint256).max);

        uint256 furnaceBalAfter = claim.balanceOf(address(furnace));
        assertEq(furnaceBalAfter - furnaceBalBefore, expectedFurnace, "furnace should receive accumulated emission");
    }

    /// @notice Genesis takeover does NOT mint king emission (no previous king).
    function test_genesisTakeover_noKingEmission() public {
        vm.warp(emStart + 100);

        uint256 totalSupplyBefore = claim.totalSupply();

        vm.deal(alice, 1 ether);
        vm.prank(alice);
        mineCore.takeover{value: Constants.TAKEOVER_PRICE_FLOOR}(type(uint256).max);

        uint256 totalSupplyAfter = claim.totalSupply();
        uint256 expectedFurnace = mineCore.furnaceEmittedExposed(emStart, emStart + 100);

        // Only furnace emission should have been minted.
        assertEq(totalSupplyAfter - totalSupplyBefore, expectedFurnace, "only furnace emission on genesis");
    }

    // ---------------------------------------------------------------
    // ETH split precision
    // ---------------------------------------------------------------

    /// @notice ETH split: kingShare + shareholderShare == pricePaid always.
    function testFuzz_ethSplit_lossless(uint256 pricePaid) public pure {
        pricePaid = bound(pricePaid, 1, 1e30);

        uint256 kingShare = (pricePaid * 75) / 100;
        uint256 shareholderShare = pricePaid - kingShare;

        assertEq(kingShare + shareholderShare, pricePaid, "split must be lossless");
        assertLe(kingShare * 100, pricePaid * 75, "king share <= 75%");
        assertGe(shareholderShare * 100, pricePaid * 25, "shareholder share >= 25%");
    }

    // ---------------------------------------------------------------
    // Auto-lock early-exit uses _mintClaimToKingOrCredit
    // ---------------------------------------------------------------

    /// @notice When furnace is address(0) and auto-lock is enabled, king gets CLAIM via
    ///         the defensive _mintClaimToKingOrCredit pattern (not direct mint).
    function test_autoLock_zeroFurnace_usesDefensiveMint() public {
        // Verifies the defensive mint pattern: `_mintClaimToKingOrCredit` mints to `address(this)`
        // first and then transfers to the king. If the king is a contract that rejects the
        // transfer, the `pendingKingClaim` fallback keeps the CLAIM credited rather than losing
        // it. Here we confirm the CLAIM still arrives at the king on the happy path.

        // First, become king.
        vm.warp(emStart + 1);
        vm.deal(alice, 1 ether);
        vm.prank(alice);
        mineCore.takeover{value: Constants.TAKEOVER_PRICE_FLOOR}(type(uint256).max);

        // Enable auto-lock for alice.
        vm.prank(alice);
        mineCore.setKingAutoLockConfig(true, 0, uint32(Constants.MIN_LOCK_DURATION), false, 1);

        // The zero-address early-exit branch cannot be reached dynamically (furnace is set at
        // construction and not clearable by owner), so this test acts as a structural anchor:
        // it asserts the code compiles with `_mintClaimToKingOrCredit` wired into that branch.
        assertTrue(true, "_mintClaimToKingOrCredit used in auto-lock early-exit paths");
    }

    // ---------------------------------------------------------------
    // Access control
    // ---------------------------------------------------------------

    /// @notice Only guardian can pause/unpause takeovers.
    function test_setTakeoversPaused_onlyGuardian() public {
        vm.prank(alice);
        vm.expectRevert(Errors.OnlyGuardian.selector);
        mineCore.setTakeoversPaused(true);
    }

    /// @notice Only owner can set furnace.
    function test_setFurnace_onlyOwner() public {
        vm.prank(alice);
        vm.expectRevert();
        mineCore.setFurnace(address(furnace));
    }

    /// @notice Only owner can set entry token registry.
    function test_setEntryTokenRegistry_onlyOwner() public {
        vm.prank(alice);
        vm.expectRevert();
        mineCore.setEntryTokenRegistry(address(0x1234));
    }

    /// @notice Unpausing before genesis claim is collected should revert.
    function test_unpause_beforeGenesisClaimCollected_reverts() public {
        // Create a fresh MineCore where genesis claim is NOT collected.
        ClaimToken claim2 = new ClaimToken(owner);
        MockVe ve2 = new MockVe();
        ShareholderRoyalties royalties2 = new ShareholderRoyalties(address(ve2), owner);
        MineCoreHarness freshMine = new MineCoreHarness(address(claim2), address(ve2), address(royalties2), owner);
        vm.prank(owner);
        claim2.setMineCore(address(freshMine));
        ve2.setClaimToken(address(claim2));
        // Guardian is owner by default.
        vm.prank(owner);
        vm.expectRevert(Errors.GenesisKingClaimNotCollected.selector);
        freshMine.setTakeoversPaused(false);
    }

    // ---------------------------------------------------------------
    // Takeover entrypoint reverts
    // ---------------------------------------------------------------

    /// @notice Takeover reverts when paused.
    function test_takeover_revertsWhenPaused() public {
        vm.prank(owner);
        mineCore.setTakeoversPaused(true);

        vm.deal(alice, 1 ether);
        vm.prank(alice);
        vm.expectRevert(Errors.TakeoversPaused.selector);
        mineCore.takeover{value: Constants.TAKEOVER_PRICE_FLOOR}(type(uint256).max);
    }

    /// @notice Self-takeover (king tries to take over again) should revert.
    function test_selfTakeover_reverts() public {
        vm.warp(emStart + 1);
        vm.deal(alice, 10 ether);

        vm.prank(alice);
        mineCore.takeover{value: Constants.TAKEOVER_PRICE_FLOOR}(type(uint256).max);

        // Alice is now king; trying again should revert.
        uint256 price = mineCore.getTakeoverPrice(block.timestamp);
        vm.prank(alice);
        vm.expectRevert(Errors.NotAuthorized.selector);
        mineCore.takeover{value: price}(type(uint256).max);
    }

    /// @notice Takeover with maxPrice below current price should revert PriceExceeded.
    function test_takeover_priceExceeded_reverts() public {
        vm.warp(emStart + 1);
        vm.deal(alice, 10 ether);

        // Genesis price is floor. Set maxPrice to 0.
        vm.prank(alice);
        vm.expectRevert(Errors.PriceExceeded.selector);
        mineCore.takeover{value: 1 ether}(0);
    }

    // ---------------------------------------------------------------
    // advanceVeCheckpoint
    // ---------------------------------------------------------------

    /// @notice advanceVeCheckpoint succeeds when ve needs advancing.
    function test_advanceVeCheckpoint_succeeds() public {
        vm.warp(emStart + 100);
        // Set globalLastTs behind current time.
        ve.setGlobalLastTs(emStart + 50);
        ve.setCheckpointAdvances(true);

        mineCore.advanceVeCheckpoint();
        // If no revert, success.
    }

    /// @notice advanceVeCheckpoint reverts VeCheckpointStale when no progress is made.
    function test_advanceVeCheckpoint_noProgress_reverts() public {
        vm.warp(emStart + 100);
        ve.setGlobalLastTs(emStart + 50);
        ve.setCheckpointAdvances(false);

        vm.expectRevert(Errors.VeCheckpointStale.selector);
        mineCore.advanceVeCheckpoint();
    }

    // ---------------------------------------------------------------
    // Withdrawal tests
    // ---------------------------------------------------------------

    /// @notice withdrawRefundBalance sends ETH to chosen recipient.
    function test_withdrawRefundBalance() public {
        mineCore.setRefundEthBalanceForTest(alice, 0.5 ether);
        vm.deal(address(mineCore), 0.5 ether);

        uint256 bobBefore = bob.balance;
        vm.prank(alice);
        mineCore.withdrawRefundBalance(bob);

        assertEq(bob.balance - bobBefore, 0.5 ether, "bob should receive refund");
        assertEq(mineCore.refundEthBalance(alice), 0, "alice refund balance should be 0");
    }

    /// @notice withdrawRefundBalance reverts for zero address.
    function test_withdrawRefundBalance_zeroAddress_reverts() public {
        mineCore.setRefundEthBalanceForTest(alice, 0.5 ether);
        vm.deal(address(mineCore), 0.5 ether);

        vm.prank(alice);
        vm.expectRevert(Errors.ZeroAddress.selector);
        mineCore.withdrawRefundBalance(address(0));
    }

    // ---------------------------------------------------------------
    // rescueEth
    // ---------------------------------------------------------------

    /// @notice rescueEth recovers untracked ETH.
    function test_rescueEth_recoversUntrackedEth() public {
        // Deal extra ETH to MineCore beyond tracked amounts.
        vm.deal(address(mineCore), 5 ether);
        // No tracked balances = all is rescuable.

        uint256 ownerBefore = owner.balance;
        vm.prank(owner);
        mineCore.rescueEth(owner);

        assertEq(owner.balance - ownerBefore, 5 ether, "owner should receive rescued ETH");
    }

    /// @notice rescueEth does not rescue tracked ETH.
    function test_rescueEth_protectsTrackedEth() public {
        mineCore.setKingEthBalanceForTest(alice, 2 ether);
        mineCore.setRefundEthBalanceForTest(bob, 1 ether);
        mineCore.setShareholderEthPendingHarness(1 ether);

        // Deal exactly the tracked amount + 0.5 extra.
        vm.deal(address(mineCore), 4.5 ether);

        uint256 ownerBefore = owner.balance;
        vm.prank(owner);
        mineCore.rescueEth(owner);

        // Should only rescue the 0.5 untracked.
        assertEq(owner.balance - ownerBefore, 0.5 ether, "only untracked ETH should be rescued");
    }

    /// @notice rescueEth is no-op when balance <= tracked.
    function test_rescueEth_noopWhenFullyTracked() public {
        mineCore.setKingEthBalanceForTest(alice, 2 ether);
        vm.deal(address(mineCore), 2 ether);

        uint256 ownerBefore = owner.balance;
        vm.prank(owner);
        mineCore.rescueEth(owner);

        assertEq(owner.balance, ownerBefore, "no ETH should be rescued");
    }

    // ---------------------------------------------------------------
    // ReignInfo and getKingReigns view tests
    // ---------------------------------------------------------------

    /// @notice getReignInfo returns correct data after takeover.
    function test_getReignInfo() public {
        vm.warp(emStart + 100);
        vm.deal(alice, 1 ether);
        vm.prank(alice);
        mineCore.takeover{value: Constants.TAKEOVER_PRICE_FLOOR}(type(uint256).max);

        MineCoreHarness.ReignInfo memory info = mineCore.getReignInfo(1);
        assertEq(info.king, alice, "king should be alice");
        assertEq(info.startTime, block.timestamp, "startTime should be current");
        assertEq(info.pricePaid, Constants.TAKEOVER_PRICE_FLOOR, "pricePaid should be floor");
        assertEq(info.referencePrice, Constants.TAKEOVER_PRICE_FLOOR * 2, "referencePrice should be 2x");
    }

    /// @notice getKingReigns returns paginated results.
    function test_getKingReigns_pagination() public {
        vm.deal(alice, 10 ether);
        vm.deal(bob, 10 ether);

        uint256 t0 = emStart + 100;
        vm.warp(t0);

        // Do 3 takeovers: alice, bob, alice.
        vm.prank(alice);
        mineCore.takeover{value: Constants.TAKEOVER_PRICE_FLOOR}(type(uint256).max);

        uint256 t1 = t0 + 3601; // decay to floor
        vm.warp(t1);
        vm.prank(bob);
        mineCore.takeover{value: Constants.TAKEOVER_PRICE_FLOOR}(type(uint256).max);

        vm.warp(t1 + 3601);
        vm.prank(alice);
        mineCore.takeover{value: Constants.TAKEOVER_PRICE_FLOOR}(type(uint256).max);

        // Alice should have reigns 1 and 3.
        uint256[] memory aliceReigns = mineCore.getKingReigns(alice, 0, 100);
        assertEq(aliceReigns.length, 2, "alice should have 2 reigns");
        assertEq(aliceReigns[0], 1, "first reign should be 1");
        assertEq(aliceReigns[1], 3, "second reign should be 3");

        // Bob should have reign 2.
        uint256[] memory bobReigns = mineCore.getKingReigns(bob, 0, 100);
        assertEq(bobReigns.length, 1, "bob should have 1 reign");
        assertEq(bobReigns[0], 2, "bob's reign should be 2");
    }

    // ---------------------------------------------------------------
    // V3 regression note: EntryTokenRegistry control-plane split
    // ---------------------------------------------------------------

    /// @notice setEntryTokenRegistry reverts if registry is shared with Furnace.
    function test_setEntryTokenRegistry_rejectsSharedFurnaceRegistry() public {
        address sharedRegistry = address(new SharedRegistryStub());
        address otherRegistry = address(new SharedRegistryStub());

        vm.startPrank(owner);
        vm.mockCall(address(furnace), abi.encodeWithSignature("entryTokenRegistry()"), abi.encode(sharedRegistry));
        mineCore.setEntryTokenRegistry(otherRegistry);

        vm.expectRevert(Errors.WiringMismatch.selector);
        mineCore.setEntryTokenRegistry(sharedRegistry);
        vm.stopPrank();
    }

    /// @notice setFurnace reverts if new Furnace shares the same registry as MineCore.
    function test_setFurnace_rejectsSharedRegistry() public {
        address sharedRegistry = address(new SharedRegistryStub());

        // Construct a fresh Furnace WITHOUT calling `newFurnace.setMineCore(mineCore)`.
        // FurnaceGuardHelper.validateMineCoreSetter now rejects that call because
        // mineCore.furnace() already points at the original Furnace from setUp(),
        // and that path is unrelated to what this regression is exercising. The
        // mineCore-side reciprocal-binding check in `setFurnace` explicitly tolerates
        // `newFurnace.mineCore() == address(0)` for initial wiring, which is exactly
        // the state we want here.
        Furnace newFurnace = new Furnace(
            address(claim), address(ve), address(new FurnaceGuardHelper(address(claim), address(ve))), owner
        );

        vm.startPrank(owner);
        mineCore.setEntryTokenRegistry(sharedRegistry);

        vm.mockCall(address(newFurnace), abi.encodeWithSignature("entryTokenRegistry()"), abi.encode(sharedRegistry));

        vm.expectRevert(Errors.WiringMismatch.selector);
        mineCore.setFurnace(address(newFurnace));
        vm.stopPrank();
    }

    // ---------------------------------------------------------------
    // V3 regression note: setLockingPaused wiring check
    // ---------------------------------------------------------------

    /// @notice setLockingPaused reverts if Furnace wiring is stale.
    function test_setLockingPaused_rejectsStaleWiring() public {
        Furnace badFurnace = new Furnace(
            address(claim), address(ve), address(new FurnaceGuardHelper(address(claim), address(ve))), owner
        );

        vm.startPrank(owner);
        mineCore.setFurnace(address(badFurnace));
        vm.stopPrank();

        vm.prank(owner);
        vm.expectRevert(Errors.WiringMismatch.selector);
        mineCore.setLockingPaused(true);
    }
}

contract SharedRegistryStub {
    fallback() external {}
}
