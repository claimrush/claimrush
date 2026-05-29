// SPDX-License-Identifier: MIT
pragma solidity ^0.8.34;

import {Test} from "forge-std/Test.sol";

import {MarketRouter} from "src/MarketRouter.sol";
import {ClaimToken} from "src/ClaimToken.sol";
import {Furnace} from "src/Furnace.sol";
import {FurnaceGuardHelper} from "src/FurnaceGuardHelper.sol";

import {MineCore} from "src/MineCore.sol";
import {ShareholderRoyalties} from "src/ShareholderRoyalties.sol";
import {Errors} from "src/lib/Errors.sol";

import {VeClaimNFTHarness} from "../mocks/VeClaimNFTHarness.sol";
import {MockGenesisGuardian} from "../mocks/MockGenesisGuardian.sol";
import {MockContract} from "../mocks/MockContract.sol";

/// @dev Pause / gating checks that should always hold.
contract PauseInvariants is Test {
    address internal owner = address(0xA11CE);
    address internal alice = address(0xA);

    ClaimToken internal claim;
    VeClaimNFTHarness internal ve;
    ShareholderRoyalties internal royalties;
    Furnace internal furnace;
    MarketRouter internal market;
    MineCore internal mineCore;
    MockGenesisGuardian internal launchController;

    function setUp() public {
        vm.startPrank(owner);
        claim = new ClaimToken(owner);
        ve = new VeClaimNFTHarness(address(claim), owner);
        royalties = new ShareholderRoyalties(address(ve), owner);
        furnace = new Furnace(
            address(claim), address(ve), address(new FurnaceGuardHelper(address(claim), address(ve))), owner
        );
        market = new MarketRouter(address(claim), address(ve), address(royalties), owner);
        mineCore = new MineCore(address(claim), address(ve), address(royalties), owner);
        launchController = new MockGenesisGuardian();
        launchController.setRoots(address(mineCore), address(claim));
        claim.setMineCore(address(mineCore));
        furnace.setShareholderRoyalties(address(royalties));
        furnace.setMineCore(address(mineCore));
        mineCore.setFurnace(address(furnace));
        ve.setFurnace(address(furnace));
        royalties.setWiring(address(mineCore), address(market), address(furnace));
        furnace.setGuardian(address(mineCore));
        vm.stopPrank();
    }

    function testMineCoreStartsPausedPreGenesis() public {
        assertTrue(mineCore.takeoversPaused());
    }

    function testOwnerCannotUnpauseBeforeGenesisKingClaimCollected() public {
        vm.prank(owner);
        vm.expectRevert(Errors.GenesisKingClaimNotCollected.selector);
        mineCore.setTakeoversPaused(false);
        assertTrue(mineCore.takeoversPaused());
    }

    function testOwnerCanUnpauseAfterGenesisKingClaimCollected() public {
        uint256 end = mineCore.emissionStartTime() + mineCore.GENESIS_ACCRUAL_DURATION();
        vm.prank(owner);
        mineCore.setGuardian(address(launchController));
        vm.warp(end);

        launchController.collectGenesisKingClaim(mineCore, owner);
        launchController.unpauseTakeovers(mineCore);
        assertFalse(mineCore.takeoversPaused());
    }

    function testPreGenesisGuardianMustBeContract() public {
        vm.prank(owner);
        vm.expectRevert(Errors.NotAContract.selector);
        mineCore.setGuardian(alice);
    }

    function testPreGenesisCurrentGuardianCannotInstallContractGuardianWhenOwnerDiffers() public {
        address newOwner = address(0xBEEF);

        vm.prank(owner);
        mineCore.transferOwnership(newOwner);

        vm.prank(newOwner);
        mineCore.acceptOwnership();

        assertEq(mineCore.owner(), newOwner);
        assertEq(mineCore.guardian(), owner);

        vm.prank(owner);
        vm.expectRevert(Errors.NotAuthorized.selector);
        mineCore.setGuardian(address(launchController));

        vm.prank(newOwner);
        mineCore.setGuardian(address(launchController));
        assertEq(mineCore.guardian(), address(launchController));
    }

    function testPreGenesisContractInitialOwnerCanInstallContractGuardian() public {
        MockContract contractOwner = new MockContract();
        ClaimToken splitClaim = new ClaimToken(owner);
        VeClaimNFTHarness splitVe = new VeClaimNFTHarness(address(splitClaim), owner);
        ShareholderRoyalties splitRoyalties = new ShareholderRoyalties(address(splitVe), owner);
        MineCore splitOwnerCore =
            new MineCore(address(splitClaim), address(splitVe), address(splitRoyalties), address(contractOwner));
        MockGenesisGuardian splitOwnerLaunchController = new MockGenesisGuardian();
        splitOwnerLaunchController.setRoots(address(splitOwnerCore), address(splitClaim));

        vm.prank(owner);
        splitClaim.setMineCore(address(splitOwnerCore));

        assertEq(splitOwnerCore.owner(), address(contractOwner));
        assertEq(splitOwnerCore.guardian(), address(contractOwner));

        vm.prank(address(contractOwner));
        splitOwnerCore.setGuardian(address(splitOwnerLaunchController));
        assertEq(splitOwnerCore.guardian(), address(splitOwnerLaunchController));
    }

    function testEOAGuardianCannotCollectGenesisKingClaim() public {
        uint256 end = mineCore.emissionStartTime() + mineCore.GENESIS_ACCRUAL_DURATION();
        vm.warp(end);

        vm.prank(owner);
        vm.expectRevert(Errors.NotAContract.selector);
        mineCore.collectGenesisKingClaim(owner);
    }

    function testContractInitialOwnerCannotCollectGenesisKingClaimBeforeCanonicalHandoff() public {
        MockContract contractOwner = new MockContract();
        ClaimToken splitClaim = new ClaimToken(owner);
        VeClaimNFTHarness splitVe = new VeClaimNFTHarness(address(splitClaim), owner);
        ShareholderRoyalties splitRoyalties = new ShareholderRoyalties(address(splitVe), owner);
        MineCore splitOwnerCore =
            new MineCore(address(splitClaim), address(splitVe), address(splitRoyalties), address(contractOwner));
        MockGenesisGuardian splitOwnerLaunchController = new MockGenesisGuardian();
        splitOwnerLaunchController.setRoots(address(splitOwnerCore), address(splitClaim));

        vm.prank(owner);
        splitClaim.setMineCore(address(splitOwnerCore));

        uint256 end = splitOwnerCore.emissionStartTime() + splitOwnerCore.GENESIS_ACCRUAL_DURATION();
        vm.warp(end);

        vm.expectRevert(Errors.WiringMismatch.selector);
        contractOwner.collectGenesisKingClaim(splitOwnerCore, owner);

        vm.prank(address(contractOwner));
        splitOwnerCore.setGuardian(address(splitOwnerLaunchController));

        uint256 minted = splitOwnerLaunchController.collectGenesisKingClaim(splitOwnerCore, owner);
        assertGt(minted, 0);
        assertTrue(splitOwnerCore.genesisKingClaimCollected());
    }

    function testContractGuardianMustMatchCanonicalRoots() public {
        MockGenesisGuardian wrongMineCore = new MockGenesisGuardian();
        wrongMineCore.setRoots(address(0xBEEF), address(claim));

        vm.prank(owner);
        vm.expectRevert(Errors.WiringMismatch.selector);
        mineCore.setGuardian(address(wrongMineCore));

        MockGenesisGuardian wrongClaim = new MockGenesisGuardian();
        wrongClaim.setRoots(address(mineCore), address(0xCAFE));

        vm.prank(owner);
        vm.expectRevert(Errors.WiringMismatch.selector);
        mineCore.setGuardian(address(wrongClaim));
    }

    function testContractGuardianCannotRotateAgainBeforeGenesisCollection() public {
        vm.prank(owner);
        mineCore.setGuardian(address(launchController));

        MockGenesisGuardian anotherGuardian = new MockGenesisGuardian();
        vm.prank(owner);
        vm.expectRevert(Errors.GenesisGuardianLocked.selector);
        mineCore.setGuardian(address(anotherGuardian));
    }

    function testFuzzPreGenesisOnlyOwnerCanInstallContractGuardian(address newOwner) public {
        vm.assume(newOwner != address(0));
        vm.assume(newOwner != owner);
        vm.assume(newOwner != address(launchController));

        vm.prank(owner);
        mineCore.transferOwnership(newOwner);

        vm.prank(newOwner);
        mineCore.acceptOwnership();

        vm.prank(owner);
        vm.expectRevert(Errors.NotAuthorized.selector);
        mineCore.setGuardian(address(launchController));

        vm.prank(newOwner);
        mineCore.setGuardian(address(launchController));
        assertEq(mineCore.guardian(), address(launchController));
    }

    function testFuzzContractGuardianRejectsAnyWrongRoot(bool wrongMineCore, bool wrongClaim) public {
        vm.assume(wrongMineCore || wrongClaim);

        MockGenesisGuardian badGuardian = new MockGenesisGuardian();
        badGuardian.setRoots(
            wrongMineCore ? address(0xBEEF) : address(mineCore), wrongClaim ? address(0xCAFE) : address(claim)
        );

        vm.prank(owner);
        vm.expectRevert(Errors.WiringMismatch.selector);
        mineCore.setGuardian(address(badGuardian));
    }

    function testFuzzContractGuardianRemainsLockedThroughoutGenesisWindow(uint40 warpBy) public {
        vm.prank(owner);
        mineCore.setGuardian(address(launchController));

        vm.warp(block.timestamp + (uint256(warpBy) % mineCore.GENESIS_ACCRUAL_DURATION()));

        MockGenesisGuardian anotherGuardian = new MockGenesisGuardian();
        vm.prank(owner);
        vm.expectRevert(Errors.GenesisGuardianLocked.selector);
        mineCore.setGuardian(address(anotherGuardian));
    }

    function testFuzzOwnerCannotUnpauseBeforeGenesisKingClaimCollected(uint40 warpBy) public {
        vm.warp(block.timestamp + (uint256(warpBy) % 365 days));

        vm.prank(owner);
        vm.expectRevert(Errors.GenesisKingClaimNotCollected.selector);
        mineCore.setTakeoversPaused(false);
        assertTrue(mineCore.takeoversPaused());
    }

    function testFuzzTakeoverRevertsWhilePaused(uint96 extraValue) public {
        uint256 floor = mineCore.getCurrentTakeoverPrice();
        uint256 value = floor + (uint256(extraValue) % 10 ether);
        vm.deal(alice, value);

        vm.prank(alice);
        vm.expectRevert(Errors.TakeoversPaused.selector);
        mineCore.takeover{value: value}(type(uint256).max);
    }

    function testTradingPauseGatesMarketplaceEntrypoints() public {
        // When paused: guarded entrypoints must revert with TradingPaused.
        vm.prank(owner);
        market.pauseTrading(true);
        assertTrue(market.tradingPaused());

        vm.expectRevert(Errors.TradingPaused.selector);
        market.listLock(1, 1, block.timestamp + 1);
    }

    function testTakeoversPauseOnlyGuardian() public {
        vm.prank(alice);
        vm.expectRevert(Errors.OnlyGuardian.selector);
        mineCore.setTakeoversPaused(true);

        vm.prank(owner);
        mineCore.setTakeoversPaused(true);
        assertTrue(mineCore.takeoversPaused());
    }

    /// @dev P10-06: Both takeoversPaused and tradingPaused active simultaneously.
    ///      Verifies that each pause domain is independent and both block their respective entrypoints.
    function testCombinedTakeoverAndTradingPause() public {
        // Activate both pauses.
        vm.prank(owner);
        mineCore.setTakeoversPaused(true);
        assertTrue(mineCore.takeoversPaused());

        vm.prank(owner);
        market.pauseTrading(true);
        assertTrue(market.tradingPaused());

        // Takeover is blocked.
        uint256 price = mineCore.getCurrentTakeoverPrice();
        vm.deal(alice, price);
        vm.prank(alice);
        vm.expectRevert(Errors.TakeoversPaused.selector);
        mineCore.takeover{value: price}(type(uint256).max);

        // Trading (market listing) is blocked.
        vm.prank(alice);
        vm.expectRevert(Errors.TradingPaused.selector);
        market.listLock(1, 1, block.timestamp + 1);

        // Locking pause via MineCore->Furnace forwarding.
        vm.prank(owner);
        mineCore.setLockingPaused(true);
        assertTrue(furnace.lockingPaused());

        // All three pauses active — each reverts with its own error.
        vm.prank(alice);
        vm.expectRevert(Errors.TakeoversPaused.selector);
        mineCore.takeover{value: price}(type(uint256).max);

        vm.prank(alice);
        vm.expectRevert(Errors.TradingPaused.selector);
        market.listLock(1, 1, block.timestamp + 1);
    }

    /// @dev P10-06: Selective unpause — unpause takeovers while trading is still paused.
    ///      Verifies that unpausing one domain does not affect the other.
    function testUnpauseTakeoverWhileTradingStillPaused() public {
        // Setup: collect genesis claim and activate both pauses.
        vm.prank(owner);
        mineCore.setGuardian(address(launchController));
        uint256 end = mineCore.emissionStartTime() + mineCore.GENESIS_ACCRUAL_DURATION();
        vm.warp(end);
        launchController.collectGenesisKingClaim(mineCore, owner);

        vm.prank(owner);
        market.pauseTrading(true);
        assertTrue(market.tradingPaused());
        assertTrue(mineCore.takeoversPaused());

        // Unpause takeovers only.
        launchController.unpauseTakeovers(mineCore);
        assertFalse(mineCore.takeoversPaused());

        // Trading must still be paused.
        assertTrue(market.tradingPaused());
        vm.prank(alice);
        vm.expectRevert(Errors.TradingPaused.selector);
        market.listLock(1, 1, block.timestamp + 1);
    }
}
