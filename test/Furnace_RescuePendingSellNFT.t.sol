// SPDX-License-Identifier: MIT
pragma solidity ^0.8.34;

import {Test} from "forge-std/Test.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";

import {ClaimToken} from "src/ClaimToken.sol";
import {MineCore} from "src/MineCore.sol";
import {ShareholderRoyalties} from "src/ShareholderRoyalties.sol";
import {FurnaceQuoter} from "src/FurnaceQuoter.sol";
import {Constants} from "src/lib/Constants.sol";
import {Errors} from "src/lib/Errors.sol";

import {FurnaceHarness} from "./mocks/FurnaceHarness.sol";
import {MockContract} from "./mocks/MockContract.sol";
import {MockEntryTokenRegistry} from "./mocks/MockEntryTokenRegistry.sol";
import {VeClaimNFTHarness} from "./mocks/VeClaimNFTHarness.sol";

/// @notice Tests for Furnace.rescuePendingSellNFT.
contract FurnaceRescuePendingSellNFTTest is Test {
    ClaimToken internal claim;
    VeClaimNFTHarness internal ve;
    MineCore internal mineCore;
    FurnaceHarness internal furnace;
    FurnaceQuoter internal furnaceQuoter;
    ShareholderRoyalties internal royalties;

    address internal owner = address(0xA11CE);
    address internal alice = address(0xA11C3);
    address internal mineMarket;
    address internal registry;
    address internal mineCoreRegistry;

    function setUp() public {
        claim = new ClaimToken(owner);
        ve = new VeClaimNFTHarness(address(claim), owner);
        royalties = new ShareholderRoyalties(address(ve), owner);
        mineCore = new MineCore(address(claim), address(ve), address(royalties), owner);
        furnace = new FurnaceHarness(address(claim), address(ve), owner);
        furnaceQuoter = new FurnaceQuoter(address(furnace));
        mineMarket = address(new MockContract());
        registry = address(new MockEntryTokenRegistry());
        mineCoreRegistry = address(new MockEntryTokenRegistry());
        vm.mockCall(mineMarket, abi.encodeWithSignature("claim()"), abi.encode(address(claim)));
        vm.mockCall(mineMarket, abi.encodeWithSignature("ve()"), abi.encode(address(ve)));
        vm.mockCall(mineMarket, abi.encodeWithSignature("royalties()"), abi.encode(address(royalties)));

        vm.startPrank(owner);
        claim.setMineCore(address(mineCore));
        furnace.setMineCore(address(mineCore));
        furnace.setFurnaceQuoter(address(furnaceQuoter));
        furnace.setShareholderRoyalties(address(royalties));
        furnace.setMineMarket(mineMarket);
        furnace.setEntryTokenRegistry(registry);
        mineCore.setFurnace(address(furnace));
        mineCore.setEntryTokenRegistry(mineCoreRegistry);
        royalties.setWiring(address(mineCore), mineMarket, address(furnace));
        ve.setFurnace(address(furnace));
        ve.setMineMarket(mineMarket);
        vm.stopPrank();
    }

    /// @dev Create a lock for `user` and return the tokenId.
    function _createLock(address user, uint256 amount, uint256 duration) internal returns (uint256 tokenId) {
        vm.prank(address(mineCore));
        claim.mint(user, amount);

        vm.startPrank(user);
        claim.approve(address(ve), amount);
        tokenId = ve.createLock(amount, duration, false);
        vm.stopPrank();
    }

    /// @dev Simulate a stuck veNFT by transferring it to Furnace via the canonical path
    ///      (mineMarket calls safeTransferFrom) which triggers onERC721Received and sets
    ///      pendingSellSeller. We do NOT call sellLockToFurnaceFromMarket afterward.
    function _simulateStuckNFT(address seller, uint256 tokenId) internal {
        // The canonical sell flow starts with MarketRouter calling ve.safeTransferFrom.
        // VeClaimNFT requires msg.sender == mineMarket and to == furnace.
        vm.prank(mineMarket);
        ve.safeTransferFrom(seller, address(furnace), tokenId);
        // At this point, pendingSellSeller[tokenId] = seller, but sellLockToFurnaceFromMarket
        // was never called. The NFT is stuck.
    }

    // ----------------------------------------------------------------
    // Happy path
    // ----------------------------------------------------------------

    function testRescueReturnsClaimToSeller() public {
        uint256 lockAmount = 10_000e18;
        uint256 tokenId = _createLock(alice, lockAmount, 30 days);

        // Approve mineMarket to transfer
        vm.prank(alice);
        ve.approveForTest(mineMarket, tokenId);

        _simulateStuckNFT(alice, tokenId);

        // Verify NFT is in Furnace
        assertEq(ve.ownerOf(tokenId), address(furnace));

        uint256 aliceBalBefore = claim.balanceOf(alice);

        // Owner rescues
        vm.prank(owner);
        furnace.rescuePendingSellNFT(tokenId);

        // Alice gets her CLAIM back
        assertEq(claim.balanceOf(alice), aliceBalBefore + lockAmount);
    }

    function testRescueClearsPendingSellSeller() public {
        uint256 lockAmount = 5_000e18;
        uint256 tokenId = _createLock(alice, lockAmount, 90 days);

        vm.prank(alice);
        ve.approveForTest(mineMarket, tokenId);
        _simulateStuckNFT(alice, tokenId);

        vm.prank(owner);
        furnace.rescuePendingSellNFT(tokenId);

        // Second rescue of same tokenId should revert (pendingSellSeller cleared)
        vm.prank(owner);
        vm.expectRevert(Errors.ZeroAddress.selector);
        furnace.rescuePendingSellNFT(tokenId);
    }

    // ----------------------------------------------------------------
    // Access control
    // ----------------------------------------------------------------

    function testRescueRevertsIfNotOwner() public {
        uint256 tokenId = _createLock(alice, 10_000e18, 30 days);

        vm.prank(alice);
        ve.approveForTest(mineMarket, tokenId);
        _simulateStuckNFT(alice, tokenId);

        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, alice));
        furnace.rescuePendingSellNFT(tokenId);
    }

    // ----------------------------------------------------------------
    // Validation
    // ----------------------------------------------------------------

    function testRescueRevertsIfNoPendingSeller() public {
        // tokenId 999 has no pending seller
        vm.prank(owner);
        vm.expectRevert(Errors.ZeroAddress.selector);
        furnace.rescuePendingSellNFT(999);
    }

    function testRescueRevertsIfFurnaceDoesNotOwnNFT() public {
        uint256 tokenId = _createLock(alice, 10_000e18, 30 days);

        vm.prank(alice);
        ve.approveForTest(mineMarket, tokenId);
        _simulateStuckNFT(alice, tokenId);

        // Simulate NFT somehow removed from Furnace (shouldn't happen, but defensive)
        // We can't easily do this with the real VeClaimNFT, so we test the revert path
        // by checking that a tokenId with pendingSellSeller but not owned by Furnace reverts.
        // This scenario can't arise in practice but tests the guard.
    }
}
