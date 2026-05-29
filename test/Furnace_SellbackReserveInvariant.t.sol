// SPDX-License-Identifier: MIT
pragma solidity ^0.8.34;

import {Test} from "forge-std/Test.sol";

import {ClaimToken} from "src/ClaimToken.sol";
import {MineCore} from "src/MineCore.sol";
import {ShareholderRoyalties} from "src/ShareholderRoyalties.sol";
import {FurnaceQuoter} from "src/FurnaceQuoter.sol";
import {Constants} from "src/lib/Constants.sol";
import {Errors} from "src/lib/Errors.sol";

import {FurnaceHarness} from "./mocks/FurnaceHarness.sol";
import {MockContract} from "./mocks/MockContract.sol";
import {MockEntryTokenRegistry} from "./mocks/MockEntryTokenRegistry.sol";
import {MockLpRewardsVault} from "./mocks/MockLpRewardsVault.sol";
import {VeClaimNFTHarness} from "./mocks/VeClaimNFTHarness.sol";

/// @notice Sellback reserve invariant tests.
///         Verifies that furnaceReserve <= CLAIM.balanceOf(furnace) - lpStreamLiability holds
///         throughout the sellback flow.
contract FurnaceSellbackReserveInvariantTest is Test {
    ClaimToken internal claim;
    VeClaimNFTHarness internal ve;
    MineCore internal mineCore;
    FurnaceHarness internal furnace;
    FurnaceQuoter internal furnaceQuoter;
    MockLpRewardsVault internal lpVault;
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
        lpVault = new MockLpRewardsVault();
        lpVault.setFurnace(address(furnace));
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
        furnace.setLpRewardsVault(address(lpVault));
        mineCore.setFurnace(address(furnace));
        mineCore.setEntryTokenRegistry(mineCoreRegistry);
        royalties.setWiring(address(mineCore), mineMarket, address(furnace));
        ve.setFurnace(address(furnace));
        ve.setMineMarket(mineMarket);
        vm.stopPrank();
    }

    function _creditReserve(uint256 amount) internal {
        vm.prank(address(mineCore));
        claim.mint(address(furnace), amount);
        vm.prank(address(mineCore));
        furnace.creditReserve(amount);
    }

    function _createLock(address user, uint256 amount, uint256 duration) internal returns (uint256 tokenId) {
        vm.prank(address(mineCore));
        claim.mint(user, amount);
        vm.startPrank(user);
        claim.approve(address(ve), amount);
        tokenId = ve.createLock(amount, duration, false);
        vm.stopPrank();
    }

    function _assertReserveInvariant() internal view {
        uint256 reserve = furnace.furnaceReserve();
        uint256 bal = claim.balanceOf(address(furnace));
        uint256 liability = furnace.exposedLpStreamLiability();
        uint256 cap = bal > liability ? bal - liability : 0;
        assertLe(reserve, cap, "reserve exceeds available balance minus LP liability");
    }

    // ----------------------------------------------------------------
    // Sellback reserve invariant
    // ----------------------------------------------------------------

    function testSellbackMaintainsReserveInvariant() public {
        // Seed reserve so bonus AMM has something to work with.
        _creditReserve(10_000_000e18);
        _assertReserveInvariant();

        // Advance time so bonus curve stabilizes.
        uint256 start = mineCore.emissionStartTime();
        vm.warp(start + 60 days + 1);

        // Create a lock to sell.
        uint256 lockAmount = 50_000e18;
        uint256 tokenId = _createLock(alice, lockAmount, 90 days);

        // Approve mineMarket to transfer the lock.
        vm.prank(alice);
        ve.approveForTest(mineMarket, tokenId);

        // Step 1: MarketRouter transfers veNFT to Furnace.
        vm.prank(mineMarket);
        ve.safeTransferFrom(alice, address(furnace), tokenId);

        // Reserve invariant must still hold after onERC721Received.
        _assertReserveInvariant();

        // Step 2: MarketRouter calls sellLockToFurnaceFromMarket.
        vm.prank(mineMarket);
        uint256 claimOut = furnace.sellLockToFurnaceFromMarket(alice, tokenId, 0);

        // Reserve invariant must hold after sellback completes.
        _assertReserveInvariant();

        // Alice received CLAIM payout.
        assertGt(claimOut, 0, "seller should receive CLAIM");
        assertEq(claim.balanceOf(alice), claimOut, "alice balance matches payout");
    }

    function testFuzz_sellbackReserveInvariantWithVaryingReserve(uint256 reserveSeed, uint256 lockSeed) public {
        // Bound reserve to reasonable range.
        uint256 reserveAmount = bound(reserveSeed, 1_000_000e18, 100_000_000e18);
        uint256 lockAmount = bound(lockSeed, Constants.MIN_LOCK_AMOUNT, 500_000e18);

        _creditReserve(reserveAmount);

        uint256 start = mineCore.emissionStartTime();
        vm.warp(start + 60 days + 1);

        uint256 tokenId = _createLock(alice, lockAmount, 30 days);

        vm.prank(alice);
        ve.approveForTest(mineMarket, tokenId);

        // Sell flow
        vm.prank(mineMarket);
        ve.safeTransferFrom(alice, address(furnace), tokenId);

        _assertReserveInvariant();

        vm.prank(mineMarket);
        furnace.sellLockToFurnaceFromMarket(alice, tokenId, 0);

        _assertReserveInvariant();
    }

    function testSellbackAfterCreditReserveMaintainsInvariant() public {
        // Seed initial reserve.
        _creditReserve(5_000_000e18);

        uint256 start = mineCore.emissionStartTime();
        vm.warp(start + 60 days + 1);

        // Create and sell a lock.
        uint256 lockAmount = 100_000e18;
        uint256 tokenId = _createLock(alice, lockAmount, 180 days);

        vm.prank(alice);
        ve.approveForTest(mineMarket, tokenId);

        // Credit more reserve in the same block (simulates MineCore takeover + sell).
        _creditReserve(2_000_000e18);
        _assertReserveInvariant();

        // Sell
        vm.prank(mineMarket);
        ve.safeTransferFrom(alice, address(furnace), tokenId);
        vm.prank(mineMarket);
        furnace.sellLockToFurnaceFromMarket(alice, tokenId, 0);

        _assertReserveInvariant();
    }

    function testSellbackBalanceConservation() public {
        _creditReserve(10_000_000e18);

        uint256 start = mineCore.emissionStartTime();
        vm.warp(start + 60 days + 1);

        uint256 lockAmount = 50_000e18;
        uint256 tokenId = _createLock(alice, lockAmount, 90 days);

        vm.prank(alice);
        ve.approveForTest(mineMarket, tokenId);

        // Snapshot total supply before sell.
        uint256 supplyBefore = claim.totalSupply();

        vm.prank(mineMarket);
        ve.safeTransferFrom(alice, address(furnace), tokenId);
        vm.prank(mineMarket);
        furnace.sellLockToFurnaceFromMarket(alice, tokenId, 0);

        // Total CLAIM supply should not change (no mint/burn of CLAIM itself).
        assertEq(claim.totalSupply(), supplyBefore, "CLAIM supply unchanged by sellback");
    }
}
