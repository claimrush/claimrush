// SPDX-License-Identifier: MIT
pragma solidity ^0.8.34;

import {Test} from "forge-std/Test.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

import {ClaimToken} from "src/ClaimToken.sol";
import {DelegationHub} from "src/DelegationHub.sol";
import {Constants} from "src/lib/Constants.sol";
import {DelegationPermissions} from "src/lib/DelegationPermissions.sol";
import {DelegationActionTypes} from "src/lib/DelegationActionTypes.sol";
import {Errors} from "src/lib/Errors.sol";
import {Events} from "src/lib/Events.sol";

import {VeClaimNFTHarness} from "./mocks/VeClaimNFTHarness.sol";
import {MockShareholderRoyaltiesCheckpoint} from "./mocks/MockShareholderRoyaltiesCheckpoint.sol";

/// @notice VeClaimNFT bundle, delegation, and lock-math edge cases.
/// @dev Coverage areas:
///   - canonical ClaimToken.mineCore root enforcement on Furnace + Market hot paths
///   - MarketRouter listing fail-closed on MineCore.royalties drift
///   - Furnace receiver-side veNFT cap enforcement
///   - setter-time canonical bundle validation on setMineMarket / setFurnace
///   - furnaceBurnAndWithdraw event emission
///   - selector consistency guardrails
///   - MAX_SLOPE_CHANGES_PER_CALL boundary
///   - totalVeCached conservative rounding property
///   - ve-math precision test vectors
///   - delegation edge cases (isAuthorized zero perms, expiry boundary, undefined bits)
///   - unlockExpiredForUser CLAIM routing
///   - addToLockFor zero amount / lockEnd immutability
///   - extendLockToFor boundaries
///   - setAutoMax on expired lock / no-op / disable semantics
///   - transfer restriction (approve/setApprovalForAll)
///   - unlock guards (autoMax, listed, before expiry)
///   - setListed edge cases
///   - mergeLocks edge cases (OR logic, max end, same id, principal conservation)
///   - DelegationPermissions / ActionTypes guardrails
contract VeClaimNFT_EdgeCases_Test is Test {
    ClaimToken internal claim;
    VeClaimNFTHarness internal ve;
    MockShareholderRoyaltiesCheckpoint internal srMock;
    DelegationHub internal hub;

    address internal owner = address(0xA11CE);
    address internal mineCore = address(0xC0DE);
    address internal mineMarket = address(0xB0B0);
    address internal furnace = address(0xF00D);
    address internal alice = address(0xA);
    address internal bob = address(0xB);
    address internal delegate = address(0xD1E6);

    function setUp() public {
        vm.etch(owner, hex"00");
        vm.etch(mineCore, hex"00");
        vm.etch(mineMarket, hex"00");
        vm.etch(furnace, hex"00");

        hub = new DelegationHub();

        claim = new ClaimToken(owner);
        ve = new VeClaimNFTHarness(address(claim), owner);
        srMock = new MockShareholderRoyaltiesCheckpoint();

        vm.mockCall(owner, abi.encodeWithSignature("claim()"), abi.encode(address(claim)));
        vm.mockCall(furnace, abi.encodeWithSignature("shareholderRoyalties()"), abi.encode(address(srMock)));
        vm.mockCall(mineMarket, abi.encodeWithSignature("royalties()"), abi.encode(address(srMock)));
        vm.mockCall(furnace, abi.encodeWithSignature("ve()"), abi.encode(address(ve)));
        vm.mockCall(furnace, abi.encodeWithSignature("mineMarket()"), abi.encode(mineMarket));
        vm.mockCall(furnace, abi.encodeWithSignature("mineCore()"), abi.encode(mineCore));
        vm.mockCall(furnace, abi.encodeWithSignature("claim()"), abi.encode(address(claim)));
        vm.mockCall(furnace, abi.encodeWithSignature("delegationHub()"), abi.encode(address(hub)));
        vm.mockCall(mineMarket, abi.encodeWithSignature("ve()"), abi.encode(address(ve)));
        vm.mockCall(mineMarket, abi.encodeWithSignature("claim()"), abi.encode(address(claim)));
        vm.mockCall(mineCore, abi.encodeWithSignature("ve()"), abi.encode(address(ve)));
        vm.mockCall(mineCore, abi.encodeWithSignature("claim()"), abi.encode(address(claim)));
        vm.mockCall(mineCore, abi.encodeWithSignature("furnace()"), abi.encode(furnace));
        vm.mockCall(mineCore, abi.encodeWithSignature("royalties()"), abi.encode(address(srMock)));
        vm.mockCall(mineCore, abi.encodeWithSignature("delegationHub()"), abi.encode(address(hub)));
        vm.mockCall(address(srMock), abi.encodeWithSignature("ve()"), abi.encode(address(ve)));
        vm.mockCall(address(srMock), abi.encodeWithSignature("furnace()"), abi.encode(furnace));
        vm.mockCall(address(srMock), abi.encodeWithSignature("mineMarket()"), abi.encode(mineMarket));
        vm.mockCall(address(srMock), abi.encodeWithSignature("mineCore()"), abi.encode(mineCore));
        vm.mockCall(mineCore, abi.encodeWithSignature("emissionStartTime()"), abi.encode(uint256(1)));
        vm.mockCall(mineCore, abi.encodeWithSignature("GENESIS_ACCRUAL_DURATION()"), abi.encode(uint256(604800)));
        vm.mockCall(owner, abi.encodeWithSignature("emissionStartTime()"), abi.encode(uint256(1)));
        vm.mockCall(owner, abi.encodeWithSignature("GENESIS_ACCRUAL_DURATION()"), abi.encode(uint256(604800)));

        vm.prank(owner);
        claim.setMineCore(mineCore);

        vm.startPrank(owner);
        ve.setMineMarket(mineMarket);
        ve.setFurnace(furnace);
        vm.stopPrank();
    }

    // ──────────────────────────────────────────────────────────────
    //  Helpers
    // ──────────────────────────────────────────────────────────────

    function _mintClaim(address to, uint256 amount) internal {
        vm.prank(owner);
        claim.setMineCore(owner);
        vm.prank(owner);
        claim.mint(to, amount);
        vm.prank(owner);
        claim.setMineCore(mineCore);
    }

    function _createLockViaFurnace(address user, uint256 amount, uint256 duration, bool autoMax)
        internal
        returns (uint256 tokenId)
    {
        _mintClaim(furnace, amount);
        vm.startPrank(furnace);
        claim.approve(address(ve), amount);
        tokenId = ve.createLockFor(user, amount, duration, autoMax);
        vm.stopPrank();
    }

    function _transferToFurnace(uint256 tokenId) internal {
        ve.approveForTest(mineMarket, tokenId);
        address tokenOwner = ve.ownerOf(tokenId);
        vm.prank(mineMarket);
        ve.transferFrom(tokenOwner, furnace, tokenId);
    }

    // ══════════════════════════════════════════════════════════════
    //  furnaceBurnAndWithdraw emits LockUnlocked
    // ══════════════════════════════════════════════════════════════

    function test_furnaceBurnAndWithdraw_emitsLockUnlocked() public {
        uint256 amt = Constants.MIN_LOCK_AMOUNT;
        uint256 tokenId = _createLockViaFurnace(alice, amt, Constants.MIN_LOCK_DURATION, false);

        _transferToFurnace(tokenId);

        vm.expectEmit(true, true, false, true);
        emit Events.LockUnlocked(furnace, tokenId, amt);

        vm.prank(furnace);
        ve.furnaceBurnAndWithdraw(tokenId, alice);
    }

    // ══════════════════════════════════════════════════════════════
    //  ClaimToken.mineCore root must remain canonical
    // ══════════════════════════════════════════════════════════════

    function test_createLockFor_revertsWhenClaimTokenMineCoreDrifts() public {
        uint256 amt = Constants.MIN_LOCK_AMOUNT;
        _mintClaim(furnace, amt);

        vm.prank(owner);
        claim.setMineCore(owner);

        vm.startPrank(furnace);
        claim.approve(address(ve), amt);
        vm.expectRevert(Errors.WiringMismatch.selector);
        ve.createLockFor(alice, amt, Constants.MIN_LOCK_DURATION, false);
        vm.stopPrank();
    }

    function test_setListed_revertsWhenClaimTokenMineCoreDrifts() public {
        uint256 tokenId = _createLockViaFurnace(alice, Constants.MIN_LOCK_AMOUNT, Constants.MIN_LOCK_DURATION, false);

        vm.prank(owner);
        claim.setMineCore(owner);

        vm.prank(mineMarket);
        vm.expectRevert(Errors.WiringMismatch.selector);
        ve.setListed(tokenId, true);

        (,,, bool listed) = ve.getLockInfo(tokenId);
        assertFalse(listed, "listing state must remain unchanged");
    }

    // ══════════════════════════════════════════════════════════════
    //  Market-only listing must bind canonical royalties root
    // ══════════════════════════════════════════════════════════════

    function test_setListed_revertsWhenMineCoreRoyaltiesDrifts() public {
        uint256 tokenId = _createLockViaFurnace(alice, Constants.MIN_LOCK_AMOUNT, Constants.MIN_LOCK_DURATION, false);

        vm.mockCall(mineCore, abi.encodeWithSignature("royalties()"), abi.encode(address(0xDEAD)));

        vm.prank(mineMarket);
        vm.expectRevert(Errors.WiringMismatch.selector);
        ve.setListed(tokenId, true);

        (,,, bool listed) = ve.getLockInfo(tokenId);
        assertFalse(listed, "split-brain royalties root must not freeze the lock");
    }

    // ══════════════════════════════════════════════════════════════
    //  Furnace must not bypass the per-address veNFT cap
    // ══════════════════════════════════════════════════════════════

    function test_transferToFurnace_revertsWhenFurnaceIsAtCap() public {
        uint256 cap = Constants.MAX_VE_NFTS_PER_USER;
        for (uint256 i = 0; i < cap; i++) {
            ve.mintForTest(furnace, 10_000 + i);
        }

        uint256 tokenId = _createLockViaFurnace(alice, Constants.MIN_LOCK_AMOUNT, Constants.MIN_LOCK_DURATION, false);
        ve.approveForTest(mineMarket, tokenId);

        vm.prank(mineMarket);
        vm.expectRevert(Errors.TooManyVeNFTs.selector);
        ve.transferFrom(alice, furnace, tokenId);

        assertEq(ve.ownerOf(tokenId), alice, "ownership must remain unchanged on revert");
    }

    // ══════════════════════════════════════════════════════════════
    //  Wiring setters must reject split-brain candidates
    // ══════════════════════════════════════════════════════════════

    function test_setFurnace_revertsWhenCandidateDoesNotShareCanonicalMineCore() public {
        address foreignFurnace = address(0xF1A1);
        address foreignCore = address(0xC0F1);
        vm.etch(foreignFurnace, hex"00");
        vm.etch(foreignCore, hex"00");

        vm.mockCall(foreignFurnace, abi.encodeWithSignature("ve()"), abi.encode(address(ve)));
        vm.mockCall(foreignFurnace, abi.encodeWithSignature("claim()"), abi.encode(address(claim)));
        vm.mockCall(foreignFurnace, abi.encodeWithSignature("mineMarket()"), abi.encode(mineMarket));
        vm.mockCall(foreignFurnace, abi.encodeWithSignature("mineCore()"), abi.encode(foreignCore));
        vm.mockCall(foreignFurnace, abi.encodeWithSignature("shareholderRoyalties()"), abi.encode(address(srMock)));

        vm.mockCall(foreignCore, abi.encodeWithSignature("ve()"), abi.encode(address(ve)));
        vm.mockCall(foreignCore, abi.encodeWithSignature("claim()"), abi.encode(address(claim)));
        vm.mockCall(foreignCore, abi.encodeWithSignature("furnace()"), abi.encode(foreignFurnace));
        vm.mockCall(foreignCore, abi.encodeWithSignature("royalties()"), abi.encode(address(srMock)));

        vm.prank(owner);
        vm.expectRevert(Errors.WiringMismatch.selector);
        ve.setFurnace(foreignFurnace);

        assertEq(ve.furnace(), furnace, "stored furnace must remain unchanged");
    }

    function test_setMineMarket_revertsWhenCandidateConflictsWithLiveFurnaceRoot() public {
        address foreignMarket = address(0xBAA1);
        vm.etch(foreignMarket, hex"00");

        vm.mockCall(foreignMarket, abi.encodeWithSignature("ve()"), abi.encode(address(ve)));
        vm.mockCall(foreignMarket, abi.encodeWithSignature("claim()"), abi.encode(address(claim)));
        vm.mockCall(foreignMarket, abi.encodeWithSignature("royalties()"), abi.encode(address(srMock)));

        vm.prank(owner);
        vm.expectRevert(Errors.WiringMismatch.selector);
        ve.setMineMarket(foreignMarket);

        assertEq(ve.mineMarket(), mineMarket, "stored market must remain unchanged");
    }

    // ══════════════════════════════════════════════════════════════
    //  Selector consistency guardrails
    // ══════════════════════════════════════════════════════════════

    function test_selectorConsistency() public pure {
        assertEq(
            bytes32(bytes4(keccak256("shareholderRoyalties()"))),
            bytes32(bytes4(0xb7d91a2f)),
            "shareholderRoyalties() selector mismatch"
        );
        assertEq(
            bytes32(bytes4(keccak256("royalties()"))), bytes32(bytes4(0xf053dc5c)), "royalties() selector mismatch"
        );
    }

    // ══════════════════════════════════════════════════════════════
    //  MAX_SLOPE_CHANGES_PER_CALL boundary
    // ══════════════════════════════════════════════════════════════

    function test_checkpointBoundedAtMaxSlopeChanges() public {
        uint256 count = Constants.MAX_SLOPE_CHANGES_PER_CALL + 5;
        uint256 amt = Constants.MIN_LOCK_AMOUNT;

        uint256 perUser = Constants.MAX_VE_NFTS_PER_USER;
        for (uint256 i = 0; i < count; i++) {
            uint256 duration = Constants.MIN_LOCK_DURATION + (i * 1 days);
            if (duration > Constants.MAX_LOCK_DURATION) duration = Constants.MAX_LOCK_DURATION;
            address user = address(uint160(0xF000 + i / perUser));
            _createLockViaFurnace(user, amt, duration, false);
        }

        vm.warp(block.timestamp + Constants.MAX_LOCK_DURATION + 30 days);

        ve.checkpointGlobalState();

        assertLt(
            ve.globalLastTsForTest(),
            block.timestamp,
            "globalLastTs should lag when backlog exceeds MAX_SLOPE_CHANGES_PER_CALL"
        );
    }

    // ══════════════════════════════════════════════════════════════
    //  totalVeCached >= sum(veBalanceOf individual locks)
    // ══════════════════════════════════════════════════════════════

    function test_totalVeCached_conservativeAfterMixedLocks() public {
        uint256 amt = Constants.MIN_LOCK_AMOUNT;

        _createLockViaFurnace(alice, amt, Constants.MAX_LOCK_DURATION, true);
        _createLockViaFurnace(alice, amt * 2, Constants.MIN_LOCK_DURATION, false);
        _createLockViaFurnace(bob, amt * 3, 180 days, false);

        vm.warp(block.timestamp + 30 days);
        ve.checkpointGlobalState();

        uint256 totalCached = ve.totalVeCached();
        uint256 sumVe = ve.veBalanceOf(alice) + ve.veBalanceOf(bob);

        assertGe(totalCached, sumVe, "totalVeCached must be >= sum of individual ve balances");
    }

    // ══════════════════════════════════════════════════════════════
    //  Ve math precision test vector
    // ══════════════════════════════════════════════════════════════

    function test_veMath_precisionTestVector() public {
        uint256 amt = 100_000e18;
        uint256 duration = Constants.MAX_LOCK_DURATION;

        _createLockViaFurnace(alice, amt, duration, false);

        // At creation, ve should equal amount (duration == MAX_LOCK_DURATION → ratio == 1).
        uint256 veNow = ve.veBalanceOf(alice);
        assertEq(veNow, amt, "ve at max duration should equal locked amount");

        vm.warp(block.timestamp + duration / 2);

        uint256 veHalf = ve.veBalanceOf(alice);
        uint256 expectedHalf = amt / 2;
        assertApproxEqAbs(veHalf, expectedHalf, 1e18, "ve at half duration should be ~50% of amount");

        vm.warp(block.timestamp + duration / 2);

        uint256 veExpired = ve.veBalanceOf(alice);
        assertEq(veExpired, 0, "ve after full duration should be zero");
    }

    // ══════════════════════════════════════════════════════════════
    //  isAuthorized with zero requiredPerms returns false
    // ══════════════════════════════════════════════════════════════

    function test_isAuthorized_zeroRequiredPermsReturnsFalse() public {
        vm.prank(alice);
        hub.setSession(delegate, DelegationPermissions.ALL, uint64(block.timestamp + 1 hours));

        bool result = hub.isAuthorized(alice, delegate, 0);
        assertFalse(result, "isAuthorized must return false for zero requiredPerms");
    }

    // ══════════════════════════════════════════════════════════════
    //  unlockExpiredForUser sends CLAIM to user (not delegate)
    // ══════════════════════════════════════════════════════════════

    function test_unlockExpiredForUser_claimGoesToUser() public {
        uint256 amt = Constants.MIN_LOCK_AMOUNT;
        uint256 tokenId = _createLockViaFurnace(alice, amt, Constants.MIN_LOCK_DURATION, false);

        vm.prank(alice);
        hub.setSession(delegate, DelegationPermissions.P_VE_UNLOCK_EXPIRED_FOR, uint64(block.timestamp + 30 days));

        vm.warp(block.timestamp + Constants.MIN_LOCK_DURATION + 1);

        uint256 balBefore = claim.balanceOf(alice);

        vm.prank(delegate);
        ve.unlockExpiredForUser(alice, tokenId);

        uint256 balAfter = claim.balanceOf(alice);
        assertEq(balAfter - balBefore, amt, "CLAIM must go to user, not delegate");
    }

    // ══════════════════════════════════════════════════════════════
    //  addToLockFor: zero amount reverts
    // ══════════════════════════════════════════════════════════════

    function test_addToLockFor_zeroAmountReverts() public {
        uint256 tokenId = _createLockViaFurnace(alice, Constants.MIN_LOCK_AMOUNT, Constants.MIN_LOCK_DURATION, false);

        vm.prank(furnace);
        vm.expectRevert(Errors.AmountZero.selector);
        ve.addToLockFor(alice, tokenId, 0);
    }

    // ══════════════════════════════════════════════════════════════
    //  extendLockToFor: exact boundary values
    // ══════════════════════════════════════════════════════════════

    function test_extendLockToFor_exactBoundaries() public {
        uint256 amt = Constants.MIN_LOCK_AMOUNT;
        uint256 tokenId = _createLockViaFurnace(alice, amt, Constants.MIN_LOCK_DURATION, false);

        uint256 maxEnd = block.timestamp + Constants.MAX_LOCK_DURATION;

        vm.prank(furnace);
        ve.extendLockToFor(alice, tokenId, maxEnd);

        (, uint256 lockEnd,,) = ve.getLockInfo(tokenId);
        assertEq(lockEnd, maxEnd, "lockEnd should be exactly maxEnd");
    }

    function test_extendLockToFor_beyondMaxReverts() public {
        uint256 amt = Constants.MIN_LOCK_AMOUNT;
        uint256 tokenId = _createLockViaFurnace(alice, amt, Constants.MIN_LOCK_DURATION, false);

        uint256 tooFar = block.timestamp + Constants.MAX_LOCK_DURATION + 1;

        vm.prank(furnace);
        vm.expectRevert(Errors.InvalidDuration.selector);
        ve.extendLockToFor(alice, tokenId, tooFar);
    }

    function test_extendLockToFor_sameEndReverts() public {
        uint256 amt = Constants.MIN_LOCK_AMOUNT;
        uint256 duration = 30 days;
        uint256 tokenId = _createLockViaFurnace(alice, amt, duration, false);

        (, uint256 currentEnd,,) = ve.getLockInfo(tokenId);

        vm.prank(furnace);
        vm.expectRevert(Errors.InvalidDuration.selector);
        ve.extendLockToFor(alice, tokenId, currentEnd);
    }

    // ══════════════════════════════════════════════════════════════
    //  setAutoMax edge cases
    // ══════════════════════════════════════════════════════════════

    function test_setAutoMax_noOp() public {
        uint256 tokenId = _createLockViaFurnace(alice, Constants.MIN_LOCK_AMOUNT, Constants.MAX_LOCK_DURATION, true);

        vm.prank(alice);
        ve.setAutoMax(tokenId, true);

        (,, bool autoMax,) = ve.getLockInfo(tokenId);
        assertTrue(autoMax, "autoMax should still be true");
    }

    function test_setAutoMax_disable() public {
        uint256 tokenId = _createLockViaFurnace(alice, Constants.MIN_LOCK_AMOUNT, Constants.MAX_LOCK_DURATION, true);

        vm.prank(alice);
        ve.setAutoMax(tokenId, false);

        (,, bool autoMax,) = ve.getLockInfo(tokenId);
        assertFalse(autoMax, "autoMax should be disabled");
    }

    // ══════════════════════════════════════════════════════════════
    //  Unlock guards
    // ══════════════════════════════════════════════════════════════

    function test_unlock_beforeExpiryReverts() public {
        uint256 tokenId = _createLockViaFurnace(alice, Constants.MIN_LOCK_AMOUNT, Constants.MIN_LOCK_DURATION, false);

        vm.prank(alice);
        vm.expectRevert(Errors.InvalidDuration.selector);
        ve.unlock(tokenId);
    }

    function test_unlock_autoMaxReverts() public {
        uint256 tokenId = _createLockViaFurnace(alice, Constants.MIN_LOCK_AMOUNT, Constants.MAX_LOCK_DURATION, true);

        vm.warp(block.timestamp + Constants.MAX_LOCK_DURATION + 1);

        vm.prank(alice);
        vm.expectRevert(Errors.InvalidDuration.selector);
        ve.unlock(tokenId);
    }

    // ══════════════════════════════════════════════════════════════
    //  mergeLocks: principal conservation
    // ══════════════════════════════════════════════════════════════

    function test_mergeLocks_principalConservation() public {
        // v1.0.0: principal-conservation property of `_mergeLocksInternal` is reached
        // through the Furnace-only `mergeLocksFor` sibling.
        uint256 amt1 = Constants.MIN_LOCK_AMOUNT;
        uint256 amt2 = Constants.MIN_LOCK_AMOUNT * 2;
        uint256 tid1 = _createLockViaFurnace(alice, amt1, 30 days, false);
        uint256 tid2 = _createLockViaFurnace(alice, amt2, 60 days, false);

        uint256 totalBefore = ve.totalLockedClaim();

        vm.prank(furnace);
        ve.mergeLocksFor(alice, tid1, tid2);

        (uint256 mergedAmount,,,) = ve.getLockInfo(tid2);
        assertEq(mergedAmount, amt1 + amt2, "merged amount must equal sum of both locks");
        assertEq(ve.totalLockedClaim(), totalBefore, "totalLockedClaim must be conserved");
    }

    function test_mergeLocks_sameIdReverts() public {
        // v1.0.0: same-id revert lives on `_mergeLocksInternal`; reachable via the
        // Furnace-only `mergeLocksFor` sibling.
        uint256 tokenId = _createLockViaFurnace(alice, Constants.MIN_LOCK_AMOUNT, 30 days, false);

        vm.prank(furnace);
        vm.expectRevert(Errors.NotAuthorized.selector);
        ve.mergeLocksFor(alice, tokenId, tokenId);
    }

    // ══════════════════════════════════════════════════════════════
    //  DelegationPermissions / ActionTypes guardrails
    // ══════════════════════════════════════════════════════════════

    function test_delegationPermissions_allMaskCoverage() public pure {
        uint256 expected = (1 << 19) - 1;
        assertEq(DelegationPermissions.ALL, expected, "ALL mask must equal (1<<19)-1");
    }

    function test_isAuthorized_undefinedBitsReturnsFalse() public {
        uint256 undefinedBit = 1 << 19;

        vm.prank(alice);
        hub.setSession(delegate, DelegationPermissions.ALL, uint64(block.timestamp + 1 hours));

        bool result = hub.isAuthorized(alice, delegate, undefinedBit);
        assertFalse(result, "isAuthorized must reject undefined permission bits");
    }

    function test_isAuthorized_expiredSessionReturnsFalse() public {
        vm.prank(alice);
        hub.setSession(delegate, DelegationPermissions.ALL, uint64(block.timestamp + 1 hours));

        vm.warp(block.timestamp + 1 hours + 1);

        bool result = hub.isAuthorized(alice, delegate, DelegationPermissions.P_TAKEOVER_FOR);
        assertFalse(result, "isAuthorized must return false for expired session");
    }

    function test_isAuthorized_selfDelegationReturnsFalse() public view {
        // DelegationHub.setSession reverts on self-delegation (user == delegate),
        // so we verify the view-level guard directly: isAuthorized returns false
        // when user == delegate regardless of session state.
        bool result = hub.isAuthorized(alice, alice, DelegationPermissions.P_TAKEOVER_FOR);
        assertFalse(result, "isAuthorized must return false for self-delegation");
    }

    function test_actionTypeConstants_areDistinct() public pure {
        uint8[13] memory types = [
            DelegationActionTypes.TAKEOVER_FOR,
            DelegationActionTypes.MINECORE_SET_REIGN_RECIPIENTS,
            DelegationActionTypes.CLAIM_SHAREHOLDER_FOR,
            DelegationActionTypes.WITHDRAW_KING_BUCKET_FOR,
            DelegationActionTypes.CLAIM_ALL_FOR,
            DelegationActionTypes.FURNACE_ENTER_WITH_ETH_FOR,
            DelegationActionTypes.FURNACE_ENTER_WITH_CLAIM_FOR,
            DelegationActionTypes.FURNACE_ENTER_WITH_TOKEN_FOR,
            DelegationActionTypes.VE_EXTEND_LOCK_FOR,
            DelegationActionTypes.VE_MERGE_LOCKS_FOR,
            DelegationActionTypes.VE_UNLOCK_EXPIRED_FOR,
            DelegationActionTypes.MINECORE_SET_KING_AUTO_LOCK_CONFIG_FOR,
            DelegationActionTypes.SHAREHOLDER_SET_AUTOCOMPOUND_CONFIG_FOR
        ];

        for (uint256 i = 0; i < types.length; i++) {
            for (uint256 j = i + 1; j < types.length; j++) {
                assertTrue(types[i] != types[j], "action type ids must be distinct");
            }
        }
    }
}
