// SPDX-License-Identifier: MIT
pragma solidity ^0.8.34;

import {Test} from "forge-std/Test.sol";

import {ClaimToken} from "src/ClaimToken.sol";
import {MineCore} from "src/MineCore.sol";

import {FurnaceHarness} from "./mocks/FurnaceHarness.sol";
import {FurnaceQuoter} from "src/FurnaceQuoter.sol";
import {VeClaimNFTHarness} from "./mocks/VeClaimNFTHarness.sol";
import {MockShareholderRoyaltiesCheckpoint} from "./mocks/MockShareholderRoyaltiesCheckpoint.sol";

import {MockLpRewardsVaultRevertBomb} from "./mocks/RevertBombMocks.sol";

/// @notice Regression tests: LP rewards vault revert-data bombs MUST NOT brick Furnace flows.
contract FurnaceLpVaultNotifyRevertBombTest is Test {
    ClaimToken internal claim;
    VeClaimNFTHarness internal ve;
    MineCore internal mineCore;
    FurnaceHarness internal furnace;
    MockLpRewardsVaultRevertBomb internal lpVault;

    address internal owner = address(0xA11CE);
    address internal mineMarket = address(0xB0B0);
    address internal registry = address(0xE777);

    function setUp() public {
        vm.etch(registry, hex"00");
        claim = new ClaimToken(owner);
        ve = new VeClaimNFTHarness(address(claim), owner);
        address mockSR = address(new MockShareholderRoyaltiesCheckpoint());

        mineCore = new MineCore(address(claim), address(ve), mockSR, owner);
        furnace = new FurnaceHarness(address(claim), address(ve), owner);
        FurnaceQuoter quoter = new FurnaceQuoter(address(furnace));

        vm.etch(mineMarket, hex"00");
        vm.startPrank(owner);
        claim.setMineCore(address(mineCore));
        furnace.setMineCore(address(mineCore));
        furnace.setFurnaceQuoter(address(quoter));
        furnace.setShareholderRoyalties(mockSR);
        furnace.setMineMarket(mineMarket);
        furnace.setEntryTokenRegistry(registry);
        vm.stopPrank();

        lpVault = new MockLpRewardsVaultRevertBomb();
        lpVault.setFurnace(address(furnace));
        lpVault.setRevertSize(1_048_576); // 1 MiB

        vm.prank(owner);
        furnace.setLpRewardsVault(address(lpVault));
    }

    function testAccrueLpStreamDoesNotRevertOnRevertDataBomb() public {
        uint256 fundAmount = 1000 ether;
        deal(address(claim), address(furnace), fundAmount);

        furnace.exposedFundLpStream(fundAmount);

        vm.warp(block.timestamp + 1 days);

        uint256 beforeBal = claim.balanceOf(address(lpVault));

        // IMPORTANT: bound the gas so that copying the revert-data buffer would OOG.
        uint256 streamed = furnace.exposedAccrueLpStream{gas: 3_000_000}();

        uint256 afterBal = claim.balanceOf(address(lpVault));

        assertGt(streamed, 0);
        assertEq(afterBal - beforeBal, streamed);
    }
}
