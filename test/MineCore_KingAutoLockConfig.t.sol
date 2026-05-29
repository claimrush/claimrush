// SPDX-License-Identifier: MIT
pragma solidity ^0.8.34;

import {Test} from "forge-std/Test.sol";

import {ClaimToken} from "src/ClaimToken.sol";
import {DelegationHub} from "src/DelegationHub.sol";
import {Furnace} from "src/Furnace.sol";
import {FurnaceGuardHelper} from "src/FurnaceGuardHelper.sol";

import {ShareholderRoyalties} from "src/ShareholderRoyalties.sol";
import {Events} from "src/lib/Events.sol";
import {Errors} from "src/lib/Errors.sol";
import {Constants} from "src/lib/Constants.sol";
import {DelegationPermissions} from "src/lib/DelegationPermissions.sol";

import {MineCoreHarness} from "./mocks/MineCoreHarness.sol";
import {MockContract} from "./mocks/MockContract.sol";
import {MockVe} from "./mocks/MockVe.sol";

contract MineCore_KingAutoLockConfigTest is Test {
    ClaimToken internal claim;
    MockVe internal ve;
    ShareholderRoyalties internal royalties;
    MineCoreHarness internal mineCore;

    address internal owner = address(0xA11CE);
    address internal alice = address(0xA);
    address internal bob = address(0xB);

    function setUp() public {
        claim = new ClaimToken(owner);
        ve = new MockVe();
        royalties = new ShareholderRoyalties(address(ve), owner);
        mineCore = new MineCoreHarness(address(claim), address(ve), address(royalties), owner);
        ve.setClaimToken(address(claim));

        vm.prank(owner);
        claim.setMineCore(address(mineCore));
    }

    function _wireCanonicalFurnaceWithHub(address hub) internal returns (Furnace furnace) {
        furnace = new Furnace(
            address(claim), address(ve), address(new FurnaceGuardHelper(address(claim), address(ve))), owner
        );
        MockContract mineMarket = new MockContract();

        vm.startPrank(owner);
        furnace.setMineCore(address(mineCore));
        furnace.setMineMarket(address(mineMarket));
        furnace.setShareholderRoyalties(address(royalties));
        ve.setMineMarket(address(mineMarket));
        ve.setFurnace(address(furnace));
        royalties.setWiring(address(mineCore), address(mineMarket), address(furnace));
        // MineCore must learn about the furnace and the canonical hub BEFORE we wire
        // the furnace-side hub pointer (see FurnaceGuardHelper.requireCanonicalDelegationHub).
        mineCore.setFurnace(address(furnace));
        mineCore.setDelegationHub(hub);
        furnace.setDelegationHub(hub);
        vm.stopPrank();
    }

    function _authorize(DelegationHub hub, address user, address delegate, uint256 perms) internal {
        vm.prank(user);
        hub.setSession(delegate, perms, uint64(block.timestamp + 1 days));
    }

    function testSetKingAutoLockConfig_DisableClearsAllFields() public {
        // Prime a pinned token id via harness.
        mineCore.setKingAutoLockPinnedTokenIdForTest(alice, 123);

        vm.prank(alice);
        mineCore.setKingAutoLockConfig(false, 0, 0, false, 0);

        (
            bool enabled,
            uint256 targetTokenId,
            uint256 pinnedTokenId,
            uint32 durationSeconds,
            bool createAutoMax,
            uint256 minVeOut
        ) = mineCore.getKingAutoLockConfig(alice);

        assertFalse(enabled);
        assertEq(targetTokenId, 0);
        assertEq(pinnedTokenId, 0);
        assertEq(durationSeconds, 0);
        assertFalse(createAutoMax);
        assertEq(minVeOut, 0);
    }

    function testSetKingAutoLockConfig_CreateOnceModeStoresAndEmits() public {
        uint32 duration = uint32(Constants.MIN_LOCK_DURATION);

        vm.expectEmit(true, false, false, true);
        emit Events.KingAutoLockConfigured(alice, true, 0, 0, duration, false, 0);

        vm.prank(alice);
        mineCore.setKingAutoLockConfig(true, 0, duration, false, 0);

        (
            bool enabled,
            uint256 targetTokenId,
            uint256 pinnedTokenId,
            uint32 durationSeconds,
            bool createAutoMax,
            uint256 minVeOut
        ) = mineCore.getKingAutoLockConfig(alice);

        assertTrue(enabled);
        assertEq(targetTokenId, 0);
        assertEq(pinnedTokenId, 0);
        assertEq(durationSeconds, duration);
        assertFalse(createAutoMax);
        assertEq(minVeOut, 0);
    }

    function testSetKingAutoLockConfig_CreateOnceMode_AutoMaxRequiresMaxDuration() public {
        vm.prank(alice);
        vm.expectRevert(Errors.InvalidDuration.selector);
        mineCore.setKingAutoLockConfig(true, 0, uint32(Constants.MIN_LOCK_DURATION), true, 0);

        vm.prank(alice);
        mineCore.setKingAutoLockConfig(true, 0, uint32(Constants.MAX_LOCK_DURATION), true, 0);

        (bool enabled,,,, bool createAutoMax,) = mineCore.getKingAutoLockConfig(alice);
        assertTrue(enabled);
        assertTrue(createAutoMax);
    }

    function testSetKingAutoLockConfig_ExistingModeValidatesOwnershipAndLockState() public {
        uint256 tokenId = 777;
        ve.setOwner(tokenId, alice);
        ve.setLockInfo(tokenId, 100e18, block.timestamp + 30 days, false, false);

        vm.prank(alice);
        mineCore.setKingAutoLockConfig(true, tokenId, uint32(0), false, 123);

        (
            bool enabled,
            uint256 targetTokenId,
            uint256 pinnedTokenId,
            uint32 durationSeconds,
            bool createAutoMax,
            uint256 minVeOut
        ) = mineCore.getKingAutoLockConfig(alice);

        assertTrue(enabled);
        assertEq(targetTokenId, tokenId);
        assertEq(pinnedTokenId, 0);
        assertEq(durationSeconds, 0);
        assertFalse(createAutoMax);
        assertEq(minVeOut, 123);
    }

    function testSetKingAutoLockConfig_ExistingModePreservesPinnedTokenId() public {
        uint256 pinned = 123;
        mineCore.setKingAutoLockPinnedTokenIdForTest(alice, pinned);

        uint256 tokenId = 777;
        ve.setOwner(tokenId, alice);
        ve.setLockInfo(tokenId, 100e18, block.timestamp + 30 days, false, false);

        vm.expectEmit(true, false, false, true);
        emit Events.KingAutoLockConfigured(alice, true, tokenId, pinned, 0, false, 0);

        vm.prank(alice);
        mineCore.setKingAutoLockConfig(true, tokenId, uint32(0), false, 0);

        (,, uint256 pinnedTokenId,,,) = mineCore.getKingAutoLockConfig(alice);
        assertEq(pinnedTokenId, pinned);
    }

    function testSetKingAutoLockConfig_ExistingModeRevertsIfInvalidToken() public {
        vm.prank(alice);
        vm.expectRevert(Errors.InvalidToken.selector);
        mineCore.setKingAutoLockConfig(true, 999, uint32(0), false, 0);
    }

    function testSetKingAutoLockConfig_ExistingModeRevertsIfNotOwner() public {
        uint256 tokenId = 888;
        ve.setOwner(tokenId, bob);
        ve.setLockInfo(tokenId, 100e18, block.timestamp + 30 days, false, false);

        vm.prank(alice);
        vm.expectRevert(Errors.NotAuthorized.selector);
        mineCore.setKingAutoLockConfig(true, tokenId, uint32(0), false, 0);
    }

    function testSetKingAutoLockConfig_ExistingModeRevertsIfListedOrExpired() public {
        uint256 tokenId = 1234;
        ve.setOwner(tokenId, alice);

        // Listed
        ve.setLockInfo(tokenId, 100e18, block.timestamp + 30 days, false, true);
        vm.prank(alice);
        vm.expectRevert(Errors.LockListedOrFrozen.selector);
        mineCore.setKingAutoLockConfig(true, tokenId, uint32(0), false, 0);

        // Expired
        ve.setLockInfo(tokenId, 100e18, block.timestamp - 1, false, false);
        vm.prank(alice);
        vm.expectRevert(Errors.LockExpired.selector);
        mineCore.setKingAutoLockConfig(true, tokenId, uint32(0), false, 0);
    }

    function testSetKingAutoLockConfig_ExistingMode_AutoMaxAllowsZeroOrMaxDuration() public {
        uint256 tokenId = 4321;
        ve.setOwner(tokenId, alice);
        ve.setLockInfo(tokenId, 100e18, block.timestamp + 30 days, true, false);

        // durationSeconds == 0 allowed (UI convenience)
        vm.prank(alice);
        mineCore.setKingAutoLockConfig(true, tokenId, uint32(0), false, 0);

        // durationSeconds == MAX allowed
        vm.prank(alice);
        mineCore.setKingAutoLockConfig(true, tokenId, uint32(Constants.MAX_LOCK_DURATION), false, 0);

        // Other duration must revert
        vm.prank(alice);
        vm.expectRevert(Errors.InvalidDuration.selector);
        mineCore.setKingAutoLockConfig(true, tokenId, uint32(Constants.MIN_LOCK_DURATION), false, 0);
    }

    function testSetKingAutoLockConfigForUserRevertsWhenMineCoreDelegationHubDiffersFromCanonicalFurnaceHub() public {
        DelegationHub canonicalHub = new DelegationHub();
        DelegationHub evilHub = new DelegationHub();

        _wireCanonicalFurnaceWithHub(address(canonicalHub));

        vm.prank(owner);
        mineCore.setDelegationHub(address(evilHub));

        _authorize(evilHub, alice, bob, DelegationPermissions.P_SET_KING_AUTO_LOCK_CONFIG_FOR);

        vm.prank(bob);
        vm.expectRevert(Errors.WiringMismatch.selector);
        mineCore.setKingAutoLockConfigForUser(alice, true, 0, uint32(Constants.MIN_LOCK_DURATION), false, 0);

        (bool enabled,,,,,) = mineCore.getKingAutoLockConfig(alice);
        assertFalse(enabled);
    }

    function testSetKingAutoLockConfigForUserSucceedsWhenCanonicalHubAgrees() public {
        DelegationHub canonicalHub = new DelegationHub();

        _wireCanonicalFurnaceWithHub(address(canonicalHub));

        vm.prank(owner);
        mineCore.setDelegationHub(address(canonicalHub));

        _authorize(canonicalHub, alice, bob, DelegationPermissions.P_SET_KING_AUTO_LOCK_CONFIG_FOR);

        vm.prank(bob);
        mineCore.setKingAutoLockConfigForUser(alice, true, 0, uint32(Constants.MIN_LOCK_DURATION), false, 0);

        (
            bool enabled,
            uint256 targetTokenId,
            uint256 pinnedTokenId,
            uint32 durationSeconds,
            bool createAutoMax,
            uint256 minVeOut
        ) = mineCore.getKingAutoLockConfig(alice);

        assertTrue(enabled);
        assertEq(targetTokenId, 0);
        assertEq(pinnedTokenId, 0);
        assertEq(durationSeconds, uint32(Constants.MIN_LOCK_DURATION));
        assertFalse(createAutoMax);
        assertEq(minVeOut, 0);
    }

    function testSetKingAutoLockConfigForUserRejectsAtExactSessionExpiry() public {
        DelegationHub canonicalHub = new DelegationHub();

        _wireCanonicalFurnaceWithHub(address(canonicalHub));

        vm.prank(owner);
        mineCore.setDelegationHub(address(canonicalHub));

        vm.prank(alice);
        canonicalHub.setSession(
            bob, DelegationPermissions.P_SET_KING_AUTO_LOCK_CONFIG_FOR, uint64(block.timestamp + 1 hours)
        );

        vm.warp(block.timestamp + 1 hours);

        vm.prank(bob);
        vm.expectRevert(Errors.NotAuthorized.selector);
        mineCore.setKingAutoLockConfigForUser(alice, true, 0, uint32(Constants.MIN_LOCK_DURATION), false, 0);
    }

    function testFuzz_setKingAutoLockConfigForUserRejectsMineCoreHubDrift(uint64 expiryDelta) public {
        expiryDelta = uint64(bound(expiryDelta, 1, 30 days));

        DelegationHub canonicalHub = new DelegationHub();
        DelegationHub evilHub = new DelegationHub();

        _wireCanonicalFurnaceWithHub(address(canonicalHub));

        vm.prank(owner);
        mineCore.setDelegationHub(address(evilHub));

        vm.prank(alice);
        evilHub.setSession(
            bob, DelegationPermissions.P_SET_KING_AUTO_LOCK_CONFIG_FOR, uint64(block.timestamp + expiryDelta)
        );

        vm.prank(bob);
        vm.expectRevert(Errors.WiringMismatch.selector);
        mineCore.setKingAutoLockConfigForUser(alice, true, 0, uint32(Constants.MIN_LOCK_DURATION), false, 0);
    }
}
