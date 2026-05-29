// SPDX-License-Identifier: MIT
pragma solidity ^0.8.34;

import {Test} from "forge-std/Test.sol";
import {Vm} from "forge-std/Vm.sol";

import {ClaimToken} from "src/ClaimToken.sol";
import {Furnace} from "src/Furnace.sol";
import {FurnaceGuardHelper} from "src/FurnaceGuardHelper.sol";

import {FurnaceQuoter} from "src/FurnaceQuoter.sol";
import {MineCore} from "src/MineCore.sol";
import {ShareholderRoyalties} from "src/ShareholderRoyalties.sol";
import {EntryTokenRegistry} from "src/EntryTokenRegistry.sol";
import {DelegationHub} from "src/DelegationHub.sol";
import {Constants} from "src/lib/Constants.sol";
import {DelegationPermissions} from "src/lib/DelegationPermissions.sol";
import {Errors} from "src/lib/Errors.sol";

import {VeClaimNFTHarness} from "./mocks/VeClaimNFTHarness.sol";
import {MockAerodromeRouter} from "./mocks/MockAerodromeRouter.sol";
import {MockWETH} from "./mocks/MockWETH.sol";
import {MineCoreHarness} from "./mocks/MineCoreHarness.sol";
import {MockKingAutoLockFurnace} from "./mocks/MockKingAutoLockFurnace.sol";
import {MockMineCoreFurnaceNoRoyaltiesGetter} from "./mocks/MockMineCoreFurnaceNoRoyaltiesGetter.sol";

contract MineCoreKingAutoLockTakeoverTest is Test {
    ClaimToken internal claim;
    VeClaimNFTHarness internal ve;
    ShareholderRoyalties internal royalties;
    Furnace internal furnace;
    MineCoreHarness internal mineCore;
    EntryTokenRegistry internal registry;

    MockWETH internal weth;
    MockAerodromeRouter internal router;

    address internal owner = address(0xA11CE);
    address internal mineMarket = address(0xBABA);

    address internal alice = address(0xA11C3);
    address internal bob = address(0xB0B);
    address internal charlie = address(0xCA11);
    address internal thief = address(0xD1EA7);

    function setUp() public {
        // Mock addresses must look like contracts for NotAContract guards.
        vm.etch(mineMarket, hex"00");

        // Core deployments.
        claim = new ClaimToken(owner);
        ve = new VeClaimNFTHarness(address(claim), owner);
        royalties = new ShareholderRoyalties(address(ve), owner);
        furnace = new Furnace(
            address(claim), address(ve), address(new FurnaceGuardHelper(address(claim), address(ve))), owner
        );
        FurnaceQuoter quoter = new FurnaceQuoter(address(furnace));
        mineCore = new MineCoreHarness(address(claim), address(ve), address(royalties), owner);

        // Registry + router config (required by Furnace.enterWithClaim*/enterWithClaimFor).
        registry = new EntryTokenRegistry(owner);
        weth = new MockWETH();
        vm.etch(address(0xFAc7), hex"00");
        router = new MockAerodromeRouter(address(0xFAc7), address(weth));

        vm.startPrank(owner);
        // Wire core.
        claim.setMineCore(address(mineCore));
        vm.mockCall(mineMarket, abi.encodeWithSignature("ve()"), abi.encode(address(ve)));
        vm.mockCall(mineMarket, abi.encodeWithSignature("claim()"), abi.encode(address(claim)));
        vm.mockCall(mineMarket, abi.encodeWithSignature("royalties()"), abi.encode(address(royalties)));

        furnace.setMineCore(address(mineCore));
        furnace.setFurnaceQuoter(address(quoter));
        furnace.setMineMarket(mineMarket);
        furnace.setShareholderRoyalties(address(royalties));
        furnace.setEntryTokenRegistry(address(registry));

        mineCore.setFurnace(address(furnace));
        royalties.setWiring(address(mineCore), mineMarket, address(furnace));
        ve.setFurnace(address(furnace));
        ve.setMineMarket(mineMarket);
        EntryTokenRegistry mineCoreRegistry = new EntryTokenRegistry(owner);
        mineCore.setEntryTokenRegistry(address(mineCoreRegistry));
        mineCore.setGenesisKingClaimCollectedForTest(true);
        mineCore.setTakeoversPaused(false);

        registry.setRouterConfig(address(router), router.defaultFactory(), router.weth(), address(claim));
        vm.stopPrank();

        // Seed Furnace reserve to ensure bonus math is non-trivial.
        uint256 seed = 1_000_000e18;
        vm.prank(address(mineCore));
        claim.mint(address(furnace), seed);
        vm.prank(address(mineCore));
        furnace.creditReserve(seed);
    }

    function _takeover(address user) internal {
        uint256 price = mineCore.getTakeoverPrice(block.timestamp);
        vm.deal(user, price);
        vm.prank(user);
        mineCore.takeover{value: price}(type(uint256).max);
    }

    function _findFurnaceEnterBonus(Vm.Log[] memory logs, address user)
        internal
        view
        returns (bool found, uint256 principalClaim, uint256 bonusClaim, uint256 tokenId)
    {
        bytes32 sig = keccak256("FurnaceEnter(address,uint8,uint256,uint256,uint256,uint256)");
        bytes32 userTopic = bytes32(uint256(uint160(user)));

        for (uint256 i = 0; i < logs.length; i++) {
            if (logs[i].emitter != address(furnace)) continue;
            if (logs[i].topics.length != 2) continue;
            if (logs[i].topics[0] != sig) continue;
            if (logs[i].topics[1] != userTopic) continue;

            (uint8 mode, uint256 ethIn, uint256 principal, uint256 bonus, uint256 tokenIdUsed) =
                abi.decode(logs[i].data, (uint8, uint256, uint256, uint256, uint256));

            // Sanity: this path is enter-with-claim.
            assertEq(mode, Constants.FURNACE_MODE_ENTER_WITH_CLAIM, "mode");
            assertEq(ethIn, 0, "ethIn");

            return (true, principal, bonus, tokenIdUsed);
        }

        return (false, 0, 0, 0);
    }

    function _makeAliceKingAndEnableAutoLock(uint32 dur, uint256 minVeOut) internal {
        uint256 t0 = mineCore.emissionStartTime();
        vm.warp(t0 + 1);
        _takeover(alice);

        vm.prank(alice);
        mineCore.setKingAutoLockConfig(true, 0, dur, false, minVeOut);
    }

    function _setForeignAutoLockFurnace(
        address claimRoot,
        address veRoot,
        address mineCoreRoot,
        address royaltiesRoot,
        bool drainOnEnter
    ) internal returns (MockKingAutoLockFurnace foreignFurnace) {
        foreignFurnace = new MockKingAutoLockFurnace(
            address(claim), claimRoot, veRoot, mineCoreRoot, royaltiesRoot, thief, drainOnEnter
        );

        vm.prank(owner);
        mineCore.setFurnace(address(foreignFurnace));
    }

    function testKingAutoLockFallsBackToLiquidClaimWhenFurnaceClaimRootMismatches() public {
        _makeAliceKingAndEnableAutoLock(uint32(Constants.MIN_LOCK_DURATION), 1);
        _setForeignAutoLockFurnace(address(0xDEAD), address(ve), address(mineCore), address(royalties), true);

        vm.warp(block.timestamp + 1000);
        uint256 price = mineCore.getTakeoverPrice(block.timestamp);
        vm.deal(bob, price);
        vm.prank(bob);
        vm.expectRevert(Errors.WiringMismatch.selector);
        mineCore.takeover{value: price}(type(uint256).max);
    }

    function testKingAutoLockFallsBackToLiquidClaimWhenFurnaceMineCoreMismatches() public {
        _makeAliceKingAndEnableAutoLock(uint32(Constants.MIN_LOCK_DURATION), 1);
        MockKingAutoLockFurnace foreignFurnace =
            _setForeignAutoLockFurnace(address(claim), address(ve), address(mineCore), address(royalties), true);
        foreignFurnace.setMineCoreForTest(address(0xBEEF));

        vm.warp(block.timestamp + 1000);
        uint256 price = mineCore.getTakeoverPrice(block.timestamp);
        vm.deal(bob, price);
        vm.prank(bob);
        vm.expectRevert(Errors.WiringMismatch.selector);
        mineCore.takeover{value: price}(type(uint256).max);
    }

    function testKingAutoLockFallsBackToLiquidClaimWhenFurnaceRoyaltiesMismatches() public {
        _makeAliceKingAndEnableAutoLock(uint32(Constants.MIN_LOCK_DURATION), 1);
        _setForeignAutoLockFurnace(address(claim), address(ve), address(mineCore), address(0xDEAD), true);

        vm.warp(block.timestamp + 1000);
        uint256 price = mineCore.getTakeoverPrice(block.timestamp);
        vm.deal(bob, price);
        vm.prank(bob);
        vm.expectRevert(Errors.WiringMismatch.selector);
        mineCore.takeover{value: price}(type(uint256).max);
    }

    function testTakeoverRevertsWhenMineCoreFurnaceOmitsRoyaltiesGetterBeforeReserveAccrual() public {
        uint256 t0 = mineCore.emissionStartTime();
        vm.warp(t0 + 1);
        _takeover(alice);
        assertEq(mineCore.currentKing(), alice);

        MockMineCoreFurnaceNoRoyaltiesGetter foreignFurnace =
            new MockMineCoreFurnaceNoRoyaltiesGetter(address(claim), address(ve), address(mineCore), address(0));

        vm.prank(owner);
        mineCore.setFurnace(address(foreignFurnace));

        vm.warp(block.timestamp + 1000);
        uint256 price = mineCore.getTakeoverPrice(block.timestamp);
        vm.deal(bob, price);

        vm.prank(bob);
        vm.expectRevert(Errors.WiringMismatch.selector);
        mineCore.takeover{value: price}(type(uint256).max);

        assertEq(mineCore.currentKing(), alice, "split-brain furnace must fail closed");
        assertEq(claim.balanceOf(address(foreignFurnace)), 0, "furnace emission must not leak to spoof furnace");
    }

    function testFuzz_kingAutoLockRejectsAnyForeignFurnaceClaimRoot(address badClaimRoot) public {
        vm.assume(badClaimRoot != address(0));
        vm.assume(badClaimRoot != address(claim));

        _makeAliceKingAndEnableAutoLock(uint32(Constants.MIN_LOCK_DURATION), 1);
        _setForeignAutoLockFurnace(badClaimRoot, address(ve), address(mineCore), address(royalties), true);

        vm.warp(block.timestamp + 1000);
        uint256 price = mineCore.getTakeoverPrice(block.timestamp);
        vm.deal(bob, price);
        vm.prank(bob);
        vm.expectRevert(Errors.WiringMismatch.selector);
        mineCore.takeover{value: price}(type(uint256).max);
    }

    function testKingAutoLockCreateOncePinsAndReuses() public {
        uint256 t0 = mineCore.emissionStartTime();
        vm.warp(t0 + 1);

        // Genesis: Alice becomes king.
        _takeover(alice);
        assertEq(mineCore.currentKing(), alice);

        // Alice enables create-once auto-lock with 2x min duration so the lock
        // still has >= MIN_LOCK_DURATION remaining after multiple takeovers.
        uint32 dur = uint32(Constants.MIN_LOCK_DURATION * 2);
        vm.prank(alice);
        mineCore.setKingAutoLockConfig(true, 0, dur, false, 1);

        // Dethrone Alice; her King-stream CLAIM should be routed through Furnace and pinned.
        vm.warp(block.timestamp + 1000);
        _takeover(bob);

        // Liquid CLAIM should not be minted to Alice.
        assertEq(claim.balanceOf(alice), 0, "alice should not receive liquid CLAIM");

        // A pinned veNFT should exist for Alice.
        (,, uint256 pinnedTokenId,,,) = mineCore.getKingAutoLockConfig(alice);
        assertTrue(pinnedTokenId != 0, "pinnedTokenId not set");
        assertEq(ve.ownerOf(pinnedTokenId), alice, "ownerOf(pinned)");
        assertEq(ve.balanceOf(alice), 1, "alice veNFT count");

        (uint256 amount1,,,) = ve.getLockInfo(pinnedTokenId);
        assertGt(amount1, 0, "lock amount");

        // Alice retakes the throne, then gets dethroned again; pinned lock must be topped up (no new NFTs).
        vm.warp(mineCore.currentReignStartTime() + 1);
        _takeover(alice);

        vm.warp(block.timestamp + 500);
        _takeover(charlie);

        (uint256 amount2,,,) = ve.getLockInfo(pinnedTokenId);
        assertGt(amount2, amount1, "pinned lock not topped up");
        assertEq(ve.balanceOf(alice), 1, "should not create extra veNFTs");
    }

    function testKingAutoLockMinVeOutZeroStillLocks() public {
        uint256 t0 = mineCore.emissionStartTime();
        vm.warp(t0 + 1);

        // Genesis: Alice becomes king.
        _takeover(alice);
        assertEq(mineCore.currentKing(), alice);

        // Alice enables create-once auto-lock with `minVeOut = 0` (sentinel "no floor").
        uint32 dur = uint32(Constants.MIN_LOCK_DURATION);
        vm.prank(alice);
        mineCore.setKingAutoLockConfig(true, 0, dur, false, 0);

        // Dethrone Alice; her King-stream CLAIM should still be routed through Furnace (minVeOut clamped to 1).
        vm.warp(block.timestamp + 1000);
        _takeover(bob);

        // Liquid CLAIM should not be minted to Alice.
        assertEq(claim.balanceOf(alice), 0, "alice should not receive liquid CLAIM");

        // A pinned veNFT should exist for Alice.
        (,, uint256 pinnedTokenId,,,) = mineCore.getKingAutoLockConfig(alice);
        assertTrue(pinnedTokenId != 0, "pinnedTokenId not set");
        assertEq(ve.ownerOf(pinnedTokenId), alice, "ownerOf(pinned)");
    }

    function testKingAutoLockSkipWhenPinnedNotOwned() public {
        uint256 t0 = mineCore.emissionStartTime();
        vm.warp(t0 + 1);

        // Alice becomes king.
        _takeover(alice);

        // Enable create-once auto-lock.
        vm.prank(alice);
        mineCore.setKingAutoLockConfig(true, 0, uint32(Constants.MIN_LOCK_DURATION), false, 1);

        // Bob dethrones Alice -> creates pinned lock.
        vm.warp(block.timestamp + 1000);
        _takeover(bob);

        (,, uint256 pinnedTokenId,,,) = mineCore.getKingAutoLockConfig(alice);
        assertTrue(pinnedTokenId != 0, "pinnedTokenId not set");

        // Transfer the pinned lock to Furnace (v1.0.0 strict: mineMarket can only transfer to furnace).
        ve.approveForTest(mineMarket, pinnedTokenId);
        vm.prank(mineMarket);
        ve.transferFrom(alice, address(furnace), pinnedTokenId);
        assertEq(ve.ownerOf(pinnedTokenId), address(furnace), "pinned owner should be furnace");
        assertEq(ve.balanceOf(alice), 0, "alice should own 0 veNFTs after transfer");

        // Alice retakes, then is dethroned again: auto-lock should be skipped and liquid CLAIM minted.
        vm.warp(mineCore.currentReignStartTime() + 1);
        _takeover(alice);

        vm.warp(block.timestamp + 500);
        _takeover(charlie);

        assertGt(claim.balanceOf(alice), 0, "alice should receive liquid CLAIM when pinned not owned");
        assertEq(ve.balanceOf(alice), 0, "should not create new veNFT when pinned invalid");
    }

    function testKingAutoLockFailureFallsBackToLiquidClaim() public {
        uint256 t0 = mineCore.emissionStartTime();
        vm.warp(t0 + 1);

        // Alice becomes king.
        _takeover(alice);

        // Configure with an impossible minVeOut to force a Furnace revert.
        vm.prank(alice);
        mineCore.setKingAutoLockConfig(true, 0, uint32(Constants.MIN_LOCK_DURATION), false, type(uint256).max);

        // Dethrone Alice: MineCore must NOT revert and must pay Alice liquid CLAIM.
        vm.warp(block.timestamp + 1000);
        _takeover(bob);

        assertGt(claim.balanceOf(alice), 0, "alice should receive liquid CLAIM on failure");

        // Since auto-lock failed, no pinned lock should be created.
        (,, uint256 pinnedTokenId,,,) = mineCore.getKingAutoLockConfig(alice);
        assertEq(pinnedTokenId, 0, "pinnedTokenId should remain unset on failure");
    }

    function testKingAutoLockClearsBurnedPinnedIdAndDoesNotAliasManualReplacementLock() public {
        uint256 t0 = mineCore.emissionStartTime();
        vm.warp(t0 + 1);

        _takeover(alice);

        vm.prank(alice);
        mineCore.setKingAutoLockConfig(true, 0, uint32(Constants.MAX_LOCK_DURATION), true, 1);

        vm.warp(block.timestamp + 1000);
        _takeover(bob);

        (,, uint256 burnedPinnedTokenId,,,) = mineCore.getKingAutoLockConfig(alice);
        assertTrue(burnedPinnedTokenId != 0, "initial pinnedTokenId not set");

        (uint256 burnedPinnedAmount,, bool burnedPinnedAutoMax,) = ve.getLockInfo(burnedPinnedTokenId);
        assertGt(burnedPinnedAmount, 0, "initial pinned lock amount");
        assertTrue(burnedPinnedAutoMax, "initial pinned lock should be AutoMax");

        vm.startPrank(alice);
        ve.setAutoMax(burnedPinnedTokenId, false);

        (, uint256 unlockAt, bool autoMaxAfterDisable,) = ve.getLockInfo(burnedPinnedTokenId);
        assertFalse(autoMaxAfterDisable, "pinned lock should now decay");

        vm.warp(unlockAt);
        uint256 claimBeforeUnlock = claim.balanceOf(alice);
        ve.unlock(burnedPinnedTokenId);
        assertEq(
            claim.balanceOf(alice) - claimBeforeUnlock,
            burnedPinnedAmount,
            "unlock should return the old pinned principal"
        );

        vm.expectRevert();
        ve.ownerOf(burnedPinnedTokenId);

        claim.approve(address(ve), Constants.MIN_LOCK_AMOUNT);
        uint256 manualReplacementTokenId = ve.createLock(Constants.MIN_LOCK_AMOUNT, Constants.MIN_LOCK_DURATION, false);
        vm.stopPrank();

        (uint256 manualAmountBefore,, bool manualAutoMaxBefore,) = ve.getLockInfo(manualReplacementTokenId);
        assertEq(manualAmountBefore, Constants.MIN_LOCK_AMOUNT, "manual replacement amount");
        assertFalse(manualAutoMaxBefore, "manual replacement lock should not be AutoMax");

        vm.warp(ve.lockStartOf(manualReplacementTokenId) + 1);
        _takeover(alice);

        vm.warp(mineCore.currentReignStartTime() + 500);
        uint256 liquidClaimBefore = claim.balanceOf(alice);
        _takeover(charlie);
        uint256 liquidClaimAfter = claim.balanceOf(alice);

        assertGt(liquidClaimAfter, liquidClaimBefore, "stale burned pin should fall back to liquid CLAIM");

        (
            bool enabled,
            uint256 targetTokenId,
            uint256 clearedPinnedTokenId,
            uint32 durationSeconds,
            bool createAutoMax,
        ) = mineCore.getKingAutoLockConfig(alice);
        assertTrue(enabled, "create-once config should remain enabled");
        assertEq(targetTokenId, 0, "config should remain in create-once mode");
        assertEq(clearedPinnedTokenId, 0, "burned pin should be cleared after skip");
        assertEq(durationSeconds, uint32(Constants.MAX_LOCK_DURATION), "duration should be preserved");
        assertTrue(createAutoMax, "createAutoMax intent should be preserved");

        (uint256 manualAmountAfter,, bool manualAutoMaxAfter,) = ve.getLockInfo(manualReplacementTokenId);
        assertEq(
            manualAmountAfter, manualAmountBefore, "manual replacement lock must not be mistaken for the stale pin"
        );
        assertEq(manualAutoMaxAfter, manualAutoMaxBefore, "manual replacement lock mode must remain unchanged");
        assertEq(ve.ownerOf(manualReplacementTokenId), alice, "manual replacement lock owner");

        vm.warp(mineCore.currentReignStartTime() + 1);
        _takeover(alice);

        vm.warp(mineCore.currentReignStartTime() + 500);
        _takeover(bob);

        (,, uint256 freshPinnedTokenId,,,) = mineCore.getKingAutoLockConfig(alice);
        assertTrue(freshPinnedTokenId != 0, "fresh create-once pin should be recreated");
        assertTrue(freshPinnedTokenId != burnedPinnedTokenId, "burned token id must never be reused");
        assertTrue(freshPinnedTokenId != manualReplacementTokenId, "manual replacement lock must not be auto-adopted");
        assertEq(ve.ownerOf(freshPinnedTokenId), alice, "fresh pin owner");

        (,, bool freshAutoMax,) = ve.getLockInfo(freshPinnedTokenId);
        assertTrue(freshAutoMax, "fresh create-once lock should honor createAutoMax");
    }

    function testDelegatedKingAutoLockCreateOnceAutoMaxConfigMintsFutureAutoMaxLock() public {
        DelegationHub hub = new DelegationHub();

        vm.startPrank(owner);
        mineCore.setDelegationHub(address(hub));
        furnace.setDelegationHub(address(hub));
        vm.stopPrank();

        vm.prank(alice);
        hub.setSession(bob, DelegationPermissions.P_SET_KING_AUTO_LOCK_CONFIG_FOR, uint64(block.timestamp + 1 days));

        vm.prank(bob);
        mineCore.setKingAutoLockConfigForUser(alice, true, 0, uint32(Constants.MAX_LOCK_DURATION), true, 1);

        (
            bool enabled,
            uint256 targetTokenId,
            uint256 pinnedTokenId,
            uint32 durationSeconds,
            bool createAutoMax,
            uint256 minVeOut
        ) = mineCore.getKingAutoLockConfig(alice);

        assertTrue(enabled, "delegated config should be enabled");
        assertEq(targetTokenId, 0, "delegated config should target create-once mode");
        assertEq(pinnedTokenId, 0, "delegated config should not pre-pin");
        assertEq(durationSeconds, uint32(Constants.MAX_LOCK_DURATION), "delegated config duration");
        assertTrue(createAutoMax, "delegated config should preserve future AutoMax intent");
        assertEq(minVeOut, 1, "delegated config minVeOut");

        uint256 t0 = mineCore.emissionStartTime();
        vm.warp(t0 + 1);
        _takeover(alice);

        vm.warp(block.timestamp + 1000);
        _takeover(charlie);

        (,, uint256 pinnedAfterDethrone,,,) = mineCore.getKingAutoLockConfig(alice);
        assertTrue(pinnedAfterDethrone != 0, "delegated config should create a pinned lock");

        (uint256 lockedAmount, uint256 lockEnd, bool autoMax,) = ve.getLockInfo(pinnedAfterDethrone);
        assertGt(lockedAmount, 0, "delegated-config lock amount");
        assertTrue(autoMax, "delegated create-once config should mint an AutoMax lock");
        assertEq(lockEnd, block.timestamp + Constants.MAX_LOCK_DURATION, "delegated-config lock end");
        assertEq(ve.veBalanceOf(alice), lockedAmount, "AutoMax lock should mint 1:1 ve");
    }

    function testKingAutoLockBonusMatchesManualEnterWithClaim() public {
        uint256 t0 = mineCore.emissionStartTime();
        vm.warp(t0 + 1);

        // Alice becomes king.
        _takeover(alice);

        // Accrue some emissions.
        vm.warp(block.timestamp + 1000);

        uint32 dur = uint32(Constants.MIN_LOCK_DURATION);

        uint256 snap = vm.snapshot();

        // --- Branch A: auto-lock on dethronement ---
        vm.prank(alice);
        mineCore.setKingAutoLockConfig(true, 0, dur, false, 1);

        vm.recordLogs();
        _takeover(bob);
        {
            Vm.Log[] memory logsA = vm.getRecordedLogs();
            (bool foundA, uint256 principalA, uint256 bonusA,) = _findFurnaceEnterBonus(logsA, alice);
            assertTrue(foundA, "FurnaceEnter not found (auto-lock)");
            assertGt(principalA, 0, "principalA");

            // --- Branch B: manual enterWithClaim after receiving liquid CLAIM ---
            vm.revertTo(snap);

            // Dethrone without auto-lock: Alice receives liquid CLAIM.
            _takeover(bob);
            uint256 principal = claim.balanceOf(alice);
            assertGt(principal, 0, "principal liquid");

            // Alice manually enters Furnace with exactly the same principal.
            vm.prank(alice);
            claim.approve(address(furnace), principal);

            vm.recordLogs();
            vm.prank(alice);
            furnace.enterWithClaim(principal, 0, dur, false, 1);

            Vm.Log[] memory logsB = vm.getRecordedLogs();
            (bool foundB, uint256 principalB, uint256 bonusB,) = _findFurnaceEnterBonus(logsB, alice);
            assertTrue(foundB, "FurnaceEnter not found (manual)");
            assertEq(principalB, principal, "principalB");

            assertEq(bonusA, bonusB, "bonus mismatch vs manual enterWithClaim");
        }
    }
}
