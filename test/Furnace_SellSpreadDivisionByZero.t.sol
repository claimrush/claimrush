// SPDX-License-Identifier: MIT
pragma solidity ^0.8.34;

import {Test} from "forge-std/Test.sol";

import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

import {ClaimToken} from "src/ClaimToken.sol";
import {MineCore} from "src/MineCore.sol";
import {Constants} from "src/lib/Constants.sol";
import {IFurnaceQuoter} from "src/interfaces/IFurnaceQuoter.sol";
import {FurnaceQuoter} from "src/FurnaceQuoter.sol";

import {FurnaceHarness} from "./mocks/FurnaceHarness.sol";
import {MockContract} from "./mocks/MockContract.sol";
import {MockEntryTokenRegistry} from "./mocks/MockEntryTokenRegistry.sol";
import {MockLpRewardsVault} from "./mocks/MockLpRewardsVault.sol";
import {MockShareholderRoyaltiesCheckpoint} from "./mocks/MockShareholderRoyaltiesCheckpoint.sol";
import {VeClaimNFTHarness} from "./mocks/VeClaimNFTHarness.sol";

/// @title Furnace_SellSpreadDivisionByZero
/// @notice Integration test: when the ONLY remaining lock is sold, lockedSupplyExcl == 0.
///         sizeRatioBps degenerates to 10_000 (100%), spreadBps == SELL_SPREAD_MAX_BPS.
///         Verifies no division-by-zero revert and the seller still receives claimOut > 0.
contract Furnace_SellSpreadDivisionByZero_Test is Test {
    ClaimToken internal claim;
    VeClaimNFTHarness internal ve;
    MineCore internal mineCore;
    FurnaceHarness internal furnace;
    FurnaceQuoter internal furnaceQuoter;
    MockLpRewardsVault internal lpVault;
    MockShareholderRoyaltiesCheckpoint internal royalties;

    address internal owner = address(0xA11CE);
    address internal alice = address(0xA11C3);
    address internal mineMarket;
    address internal registry;

    function setUp() public {
        mineMarket = address(new MockContract());
        registry = address(new MockEntryTokenRegistry());

        claim = new ClaimToken(owner);
        ve = new VeClaimNFTHarness(address(claim), owner);
        royalties = new MockShareholderRoyaltiesCheckpoint();

        mineCore = new MineCore(address(claim), address(ve), address(royalties), owner);
        furnace = new FurnaceHarness(address(claim), address(ve), owner);
        furnaceQuoter = new FurnaceQuoter(address(furnace));
        lpVault = new MockLpRewardsVault();
        lpVault.setFurnace(address(furnace));

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
        royalties.setWiring(address(mineCore), mineMarket, address(furnace), address(ve));
        ve.setFurnace(address(furnace));
        ve.setMineMarket(mineMarket);
        vm.stopPrank();
    }

    function _mintClaimTo(address to, uint256 amount) internal {
        vm.prank(address(mineCore));
        claim.mint(to, amount);
    }

    function _creditReserve(uint256 amount) internal {
        _mintClaimTo(address(furnace), amount);
        vm.prank(address(mineCore));
        furnace.creditReserve(amount);
    }

    /// @dev When lockedSupplyExcl == 0 (selling the only lock), no division-by-zero occurs,
    ///      sizeRatioBps == 10_000, and the seller still receives claimOut > 0.
    function test_sellSpread_lastLock_maxSpread() public {
        uint256 lockAmt = 100_000e18;
        _mintClaimTo(alice, lockAmt);

        vm.startPrank(alice);
        claim.approve(address(ve), lockAmt);
        uint256 tokenId = ve.createLock(lockAmt, Constants.MAX_LOCK_DURATION, false);
        vm.stopPrank();

        // Only one lock exists — selling it makes lockedSupplyExcl == 0.
        (uint256 lockAmount, uint256 claimOut, uint256 spreadBps,,) =
            furnaceQuoter.quoteSellLockToFurnace(alice, tokenId);

        assertEq(lockAmount, lockAmt, "lock amount sanity");
        assertGt(claimOut, 0, "seller must receive claimOut > 0");
        assertLe(spreadBps, Constants.SELL_SPREAD_MAX_BPS, "spread cannot exceed MAX");

        // Breakdown: verify sizeRatioBps == 10_000 when lockedSupplyExcl == 0.
        IFurnaceQuoter.SellLockQuoteBreakdown memory q = furnaceQuoter.quoteSellLockToFurnaceBreakdown(alice, tokenId);

        assertEq(q.sizeRatioBps, 10_000, "sizeRatioBps should be 10_000 when selling the only lock");
        assertEq(q.spreadBps, spreadBps, "breakdown spreadBps must match simple quote");
    }

    /// @dev With a funded reserve, selling the last lock still succeeds.
    function test_sellSpread_lastLock_withReserve_noRevert() public {
        _creditReserve(500_000e18);

        uint256 lockAmt = Constants.MIN_LOCK_AMOUNT;
        _mintClaimTo(alice, lockAmt);

        vm.startPrank(alice);
        claim.approve(address(ve), lockAmt);
        uint256 tokenId = ve.createLock(lockAmt, Constants.MAX_LOCK_DURATION, false);
        vm.stopPrank();

        (uint256 lockAmount, uint256 claimOut, uint256 spreadBps,,) =
            furnaceQuoter.quoteSellLockToFurnace(alice, tokenId);

        assertEq(lockAmount, lockAmt, "lock amount");
        assertGt(claimOut, 0, "seller receives payout");
        assertLe(spreadBps, Constants.SELL_SPREAD_MAX_BPS, "spread bounded");
    }
}
