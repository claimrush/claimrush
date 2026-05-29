// SPDX-License-Identifier: MIT
pragma solidity ^0.8.34;

import {Test} from "forge-std/Test.sol";

import {ClaimToken} from "src/ClaimToken.sol";
import {Furnace} from "src/Furnace.sol";
import {FurnaceGuardHelper} from "src/FurnaceGuardHelper.sol";

import {FurnaceQuoter} from "src/FurnaceQuoter.sol";
import {MineCore} from "src/MineCore.sol";
import {ShareholderRoyalties} from "src/ShareholderRoyalties.sol";
import {Constants} from "src/lib/Constants.sol";
import {Errors} from "src/lib/Errors.sol";

import {VeClaimNFTHarness} from "../mocks/VeClaimNFTHarness.sol";
import {MockGenesisGuardian} from "../mocks/MockGenesisGuardian.sol";

contract GameLoopReignsIT is Test {
    address internal owner = address(0xA11CE);
    address internal alice = address(0xA);

    ClaimToken internal claim;
    VeClaimNFTHarness internal ve;
    ShareholderRoyalties internal royalties;
    Furnace internal furnace;
    MineCore internal mineCore;
    MockGenesisGuardian internal launchController;

    function setUp() public {
        claim = new ClaimToken(owner);
        ve = new VeClaimNFTHarness(address(claim), owner);
        royalties = new ShareholderRoyalties(address(ve), owner);
        mineCore = new MineCore(address(claim), address(ve), address(royalties), owner);
        furnace = new Furnace(
            address(claim), address(ve), address(new FurnaceGuardHelper(address(claim), address(ve))), owner
        );
        launchController = new MockGenesisGuardian();
        launchController.setRoots(address(mineCore), address(claim));
        FurnaceQuoter quoter = new FurnaceQuoter(address(furnace));

        vm.startPrank(owner);
        claim.setMineCore(address(mineCore));
        mineCore.setFurnace(address(furnace));
        mineCore.setGuardian(address(launchController));
        furnace.setFurnaceQuoter(address(quoter));
        furnace.setMineCore(address(mineCore));
        furnace.setShareholderRoyalties(address(royalties));
        vm.etch(address(0xB0B0), hex"00");
        royalties.setWiring(address(mineCore), address(0xB0B0), address(furnace));
        ve.setFurnace(address(furnace));

        // Allow MineCore to forward locking pause to Furnace.
        furnace.setGuardian(address(mineCore));
        vm.stopPrank();
    }

    function testGenesisClaimMintsClaimToken() public {
        uint256 end = mineCore.emissionStartTime() + mineCore.GENESIS_ACCRUAL_DURATION();
        vm.warp(end);

        uint256 minted = launchController.collectGenesisKingClaim(mineCore, alice);

        assertEq(claim.balanceOf(alice), minted);
        assertEq(claim.totalSupply(), minted);
    }

    function testMineCoreCanPauseLockingViaFurnaceGuardianWiring() public {
        vm.prank(address(launchController));
        mineCore.setLockingPaused(true);
        assertTrue(furnace.lockingPaused());

        vm.prank(address(launchController));
        mineCore.setLockingPaused(false);
        assertFalse(furnace.lockingPaused());
    }

    function testNonGuardianCannotPauseTakeovers() public {
        vm.prank(alice);
        vm.expectRevert(Errors.OnlyGuardian.selector);
        mineCore.setTakeoversPaused(true);
    }

    /// @dev P10-05: Multi-reign sequence — 3 consecutive takeovers after genesis.
    ///      Validates reign IDs increment, king rotation, and CLAIM supply increases monotonically.
    function testMultiReignSequence() public {
        address bob = address(0xB);
        address charlie = address(0xC);
        address[3] memory challengers = [alice, bob, charlie];
        for (uint256 i = 0; i < challengers.length; i++) {
            vm.deal(challengers[i], 10 ether);
        }

        // Wire furnace and royalties minimally so takeover emission crediting works.
        vm.startPrank(owner);
        furnace.setMineCore(address(mineCore));
        furnace.setShareholderRoyalties(address(royalties));

        // Use a mock market address so royalties wiring check can pass.
        address mockMarket = address(0xB0B0);
        vm.etch(mockMarket, hex"00");
        vm.mockCall(mockMarket, abi.encodeWithSignature("ve()"), abi.encode(address(ve)));
        vm.mockCall(mockMarket, abi.encodeWithSignature("claim()"), abi.encode(address(claim)));
        vm.mockCall(mockMarket, abi.encodeWithSignature("royalties()"), abi.encode(address(royalties)));
        furnace.setMineMarket(mockMarket);
        royalties.setWiring(address(mineCore), mockMarket, address(furnace));
        ve.setMineMarket(mockMarket);
        ve.setFurnace(address(furnace));
        vm.stopPrank();

        // Collect genesis king claim to unlock takeovers.
        uint256 end = mineCore.emissionStartTime() + mineCore.GENESIS_ACCRUAL_DURATION();
        vm.warp(end);
        launchController.collectGenesisKingClaim(mineCore, owner);
        launchController.unpauseTakeovers(mineCore);

        uint256 prevSupply = claim.totalSupply();
        assertGt(prevSupply, 0, "genesis claim should mint > 0");

        // Perform 3 consecutive takeovers.
        for (uint256 i = 0; i < 3; i++) {
            vm.warp(block.timestamp + 2 hours);

            uint256 price = mineCore.getCurrentTakeoverPrice();
            address challenger = challengers[i];

            vm.prank(challenger);
            mineCore.takeover{value: price}(type(uint256).max);

            uint256 expectedReignId = i + 1;
            assertEq(mineCore.currentReignId(), expectedReignId, "reign ID should increment");
            assertEq(mineCore.currentKing(), challenger, "king should be the latest challenger");

            uint256 newSupply = claim.totalSupply();
            assertGe(newSupply, prevSupply, "CLAIM supply must increase monotonically");
            prevSupply = newSupply;
        }

        assertEq(mineCore.currentReignId(), 3, "final reign ID should be 3");
        assertEq(mineCore.currentKing(), charlie, "final king should be charlie");
    }
}
