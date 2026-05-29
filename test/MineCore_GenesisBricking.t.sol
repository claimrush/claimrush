// SPDX-License-Identifier: MIT
pragma solidity ^0.8.34;

import {Test} from "forge-std/Test.sol";

import {ClaimToken} from "src/ClaimToken.sol";
import {Furnace} from "src/Furnace.sol";
import {FurnaceGuardHelper} from "src/FurnaceGuardHelper.sol";

import {FurnaceQuoter} from "src/FurnaceQuoter.sol";
import {ShareholderRoyalties} from "src/ShareholderRoyalties.sol";
import {Errors} from "src/lib/Errors.sol";

import {MockVe} from "./mocks/MockVe.sol";
import {MineCoreHarness} from "./mocks/MineCoreHarness.sol";
import {MockGenesisGuardian} from "./mocks/MockGenesisGuardian.sol";

/// @dev Genesis guardian whose collectGenesisKingClaim always reverts (bricked controller).
contract BrickedGenesisGuardian {
    address public mineCore;
    address public claim;

    constructor(address mineCore_, address claim_) {
        mineCore = mineCore_;
        claim = claim_;
    }

    function finalizeGenesis() external pure {
        revert("PERMANENTLY_BRICKED");
    }
}

/// @notice Genesis bricking scenarios.
/// @dev Verifies:
///   1. Normal genesis flow works end-to-end.
///   2. Bricked LaunchController permanently prevents game start.
///   3. GenesisGuardianLocked prevents guardian replacement after canonical guardian is set.
///   4. collectGenesisKingClaim is one-shot (cannot be called twice).
///   5. Takeovers cannot unpause without genesis collection.
contract MineCoreGenesisBrickingTest is Test {
    ClaimToken internal claim;
    MockVe internal ve;
    ShareholderRoyalties internal royalties;
    Furnace internal furnace;
    MineCoreHarness internal mineCore;

    address internal owner = makeAddr("owner");
    address internal alice = makeAddr("alice");

    function setUp() public {
        ve = new MockVe();
        claim = new ClaimToken(owner);
        royalties = new ShareholderRoyalties(address(ve), owner);
        furnace = new Furnace(
            address(claim), address(ve), address(new FurnaceGuardHelper(address(claim), address(ve))), owner
        );
        FurnaceQuoter quoter = new FurnaceQuoter(address(furnace));
        mineCore = new MineCoreHarness(address(claim), address(ve), address(royalties), owner);

        vm.startPrank(owner);
        claim.setMineCore(address(mineCore));
        furnace.setMineCore(address(mineCore));
        furnace.setFurnaceQuoter(address(quoter));
        furnace.setShareholderRoyalties(address(royalties));
        mineCore.setFurnace(address(furnace));
        vm.etch(address(0xB0B0), hex"00");
        royalties.setWiring(address(mineCore), address(0xB0B0), address(furnace));
        vm.stopPrank();

        ve.setClaimToken(address(claim));
        ve.setFurnace(address(furnace));
        ve.setTotalVeCached(1234);
    }

    // -----------------------------------------------------------------------
    // Normal genesis flow
    // -----------------------------------------------------------------------

    /// @notice Happy path: guardian collects genesis CLAIM, unpauses takeovers.
    function test_genesis_happyPath() public {
        MockGenesisGuardian guardian = new MockGenesisGuardian();
        guardian.setRoots(address(mineCore), address(claim));

        vm.prank(owner);
        mineCore.setGuardian(address(guardian));

        // Warp past genesis window.
        vm.warp(mineCore.emissionStartTime() + mineCore.GENESIS_ACCRUAL_DURATION() + 1);

        // Collect genesis CLAIM.
        guardian.collectGenesisKingClaim(mineCore, address(guardian));
        assertTrue(mineCore.genesisKingClaimCollected(), "genesis should be collected");
        assertGt(mineCore.genesisKingClaimMinted(), 0, "genesis CLAIM should be nonzero");

        // Now takeovers can be unpaused.
        guardian.unpauseTakeovers(mineCore);
        assertFalse(mineCore.takeoversPaused(), "takeovers should be unpaused");

        // Takeover should work.
        uint256 price = mineCore.getCurrentTakeoverPrice();
        vm.deal(alice, price);
        vm.prank(alice);
        mineCore.takeover{value: price}(type(uint256).max);
        assertEq(mineCore.currentKing(), alice);
    }

    // -----------------------------------------------------------------------
    // Bricking scenarios
    // -----------------------------------------------------------------------

    /// @notice Cannot unpause takeovers before genesis collection.
    function test_genesis_cannotUnpauseBeforeCollection() public {
        vm.prank(owner);
        vm.expectRevert(Errors.GenesisKingClaimNotCollected.selector);
        mineCore.setTakeoversPaused(false);
    }

    /// @notice Cannot collect genesis CLAIM before window ends.
    function test_genesis_cannotCollectBeforeWindowEnds() public {
        MockGenesisGuardian guardian = new MockGenesisGuardian();
        guardian.setRoots(address(mineCore), address(claim));

        vm.prank(owner);
        mineCore.setGuardian(address(guardian));

        // Still within genesis window.
        vm.warp(mineCore.emissionStartTime() + mineCore.GENESIS_ACCRUAL_DURATION() - 1);

        vm.expectRevert(Errors.GenesisWindowNotEnded.selector);
        guardian.collectGenesisKingClaim(mineCore, address(guardian));
    }

    /// @notice One-shot: genesis collection cannot be called twice.
    function test_genesis_cannotCollectTwice() public {
        MockGenesisGuardian guardian = new MockGenesisGuardian();
        guardian.setRoots(address(mineCore), address(claim));

        vm.prank(owner);
        mineCore.setGuardian(address(guardian));

        vm.warp(mineCore.emissionStartTime() + mineCore.GENESIS_ACCRUAL_DURATION() + 1);
        guardian.collectGenesisKingClaim(mineCore, address(guardian));

        vm.expectRevert(Errors.GenesisKingClaimAlreadyCollected.selector);
        guardian.collectGenesisKingClaim(mineCore, address(guardian));
    }

    /// @notice GenesisGuardianLocked: once canonical guardian is set, owner cannot replace pre-genesis.
    function test_genesis_guardianLockedAfterCanonicalSet() public {
        MockGenesisGuardian guardian1 = new MockGenesisGuardian();
        guardian1.setRoots(address(mineCore), address(claim));

        vm.prank(owner);
        mineCore.setGuardian(address(guardian1));

        // Try to set a different canonical guardian.
        MockGenesisGuardian guardian2 = new MockGenesisGuardian();
        guardian2.setRoots(address(mineCore), address(claim));

        vm.prank(owner);
        vm.expectRevert(Errors.GenesisGuardianLocked.selector);
        mineCore.setGuardian(address(guardian2));
    }

    /// @notice A bricked guardian permanently prevents game start.
    function test_genesis_brickedGuardianPermanentlyBricksGame() public {
        BrickedGenesisGuardian bricked = new BrickedGenesisGuardian(address(mineCore), address(claim));

        vm.prank(owner);
        mineCore.setGuardian(address(bricked));

        // Guardian is now locked.
        assertEq(mineCore.guardian(), address(bricked));

        // Owner cannot replace guardian (locked).
        MockGenesisGuardian replacement = new MockGenesisGuardian();
        replacement.setRoots(address(mineCore), address(claim));

        vm.prank(owner);
        vm.expectRevert(Errors.GenesisGuardianLocked.selector);
        mineCore.setGuardian(address(replacement));

        // The bricked guardian cannot collect genesis CLAIM (it doesn't even call MineCore).
        // Even if someone manually calls collectGenesisKingClaim on MineCore, it would
        // need to come from the guardian address.
        vm.warp(mineCore.emissionStartTime() + mineCore.GENESIS_ACCRUAL_DURATION() + 1);

        // Non-guardian cannot collect.
        vm.prank(owner);
        vm.expectRevert(Errors.OnlyGuardian.selector);
        mineCore.collectGenesisKingClaim(alice);

        // Takeovers permanently stuck.
        assertFalse(mineCore.genesisKingClaimCollected());
        assertTrue(mineCore.takeoversPaused());

        vm.prank(address(bricked));
        vm.expectRevert(Errors.GenesisKingClaimNotCollected.selector);
        mineCore.setTakeoversPaused(false);
    }

    /// @notice Genesis CLAIM amount is deterministic and cannot be manipulated.
    function test_genesis_claimAmountDeterministic() public {
        MockGenesisGuardian guardian = new MockGenesisGuardian();
        guardian.setRoots(address(mineCore), address(claim));

        vm.prank(owner);
        mineCore.setGuardian(address(guardian));

        uint256 start = mineCore.emissionStartTime();
        uint256 duration = mineCore.GENESIS_ACCRUAL_DURATION();
        uint256 expectedAmount = mineCore.kingEmittedExposed(start, start + duration);

        vm.warp(start + duration + 1);
        uint256 minted = guardian.collectGenesisKingClaim(mineCore, address(guardian));

        assertEq(minted, expectedAmount, "genesis CLAIM should match deterministic integral");
        assertEq(mineCore.genesisKingClaimMinted(), expectedAmount);
    }
}
