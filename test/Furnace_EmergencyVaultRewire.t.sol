// SPDX-License-Identifier: MIT
pragma solidity ^0.8.34;

import {Test} from "forge-std/Test.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";

import {ClaimToken} from "src/ClaimToken.sol";
import {MineCore} from "src/MineCore.sol";
import {ShareholderRoyalties} from "src/ShareholderRoyalties.sol";
import {FurnaceQuoter} from "src/FurnaceQuoter.sol";
import {Errors} from "src/lib/Errors.sol";

import {FurnaceHarness} from "./mocks/FurnaceHarness.sol";
import {MockContract} from "./mocks/MockContract.sol";
import {MockEntryTokenRegistry} from "./mocks/MockEntryTokenRegistry.sol";
import {MockLpRewardsVault} from "./mocks/MockLpRewardsVault.sol";
import {VeClaimNFTHarness} from "./mocks/VeClaimNFTHarness.sol";

/// @notice Tests for the emergency vault rewire lifecycle.
contract FurnaceEmergencyVaultRewireTest is Test {
    ClaimToken internal claim;
    VeClaimNFTHarness internal ve;
    MineCore internal mineCore;
    FurnaceHarness internal furnace;
    FurnaceQuoter internal furnaceQuoter;
    MockLpRewardsVault internal lpVault;
    ShareholderRoyalties internal royalties;

    address internal owner = address(0xA11CE);
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

    /// @dev Fund the LP stream to create non-zero liability.
    function _fundLpStream(uint256 amount) internal {
        vm.prank(address(mineCore));
        claim.mint(address(furnace), amount);
        furnace.exposedFundLpStream(amount);
    }

    /// @dev Credit reserve to seed furnaceReserve.
    function _creditReserve(uint256 amount) internal {
        vm.prank(address(mineCore));
        claim.mint(address(furnace), amount);
        vm.prank(address(mineCore));
        furnace.creditReserve(amount);
    }

    function _makeReplacementVault() internal returns (MockLpRewardsVault replacement) {
        replacement = new MockLpRewardsVault();
        replacement.setFurnace(address(furnace));
    }

    // ----------------------------------------------------------------
    // Full lifecycle: request -> wait -> execute
    // ----------------------------------------------------------------

    function testFullLifecycle_RequestWaitExecute() public {
        _fundLpStream(100_000e18);
        assertGt(furnace.exposedLpStreamLiability(), 0, "should have LP liability");

        MockLpRewardsVault replacement = _makeReplacementVault();

        vm.prank(owner);
        furnace.requestEmergencyVaultRewire(address(replacement));
        uint256 executeAfter = furnace.emergencyVaultRewireExecuteAfter();
        assertGt(executeAfter, 0, "executeAfter should be set");
        assertEq(executeAfter, block.timestamp + 7 days, "7-day delay");
        assertEq(furnace.emergencyVaultRewireTargetVault(), address(replacement), "target should be stored");

        vm.prank(owner);
        vm.expectRevert(Errors.EmergencyRewireDelayNotMet.selector);
        furnace.executeEmergencyVaultRewire();

        vm.warp(executeAfter);

        vm.prank(owner);
        furnace.executeEmergencyVaultRewire();

        assertEq(furnace.exposedLpStreamRatePerSec(), 0, "rate zeroed");
        assertEq(furnace.exposedLpStreamPeriodFinish(), 0, "finish zeroed");
        assertEq(furnace.exposedLpStreamCarry(), 0, "carry zeroed");
        assertEq(furnace.emergencyVaultRewireExecuteAfter(), 0, "request cleared");
        assertEq(furnace.emergencyVaultRewireTargetVault(), address(0), "target cleared");
        assertEq(furnace.lpRewardsVault(), address(replacement), "vault rewired");
    }

    // ----------------------------------------------------------------
    // Request guards
    // ----------------------------------------------------------------

    function testRequestRevertsIfNoLiability() public {
        MockLpRewardsVault replacement = _makeReplacementVault();

        vm.prank(owner);
        vm.expectRevert(Errors.LpRewardsStreamActive.selector);
        furnace.requestEmergencyVaultRewire(address(replacement));
    }

    function testRequestRevertsIfAlreadyRequested() public {
        _fundLpStream(50_000e18);

        MockLpRewardsVault replacement = _makeReplacementVault();
        MockLpRewardsVault replacement2 = _makeReplacementVault();

        vm.prank(owner);
        furnace.requestEmergencyVaultRewire(address(replacement));

        vm.prank(owner);
        vm.expectRevert(Errors.EmergencyRewireAlreadyRequested.selector);
        furnace.requestEmergencyVaultRewire(address(replacement2));
    }

    function testRequestRevertsIfNotOwner() public {
        _fundLpStream(50_000e18);
        MockLpRewardsVault replacement = _makeReplacementVault();

        vm.prank(address(0xBAD));
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, address(0xBAD)));
        furnace.requestEmergencyVaultRewire(address(replacement));
    }

    function testRequestRevertsIfTargetIsCurrentVault() public {
        _fundLpStream(50_000e18);

        vm.prank(owner);
        vm.expectRevert(Errors.WiringMismatch.selector);
        furnace.requestEmergencyVaultRewire(address(lpVault));
    }

    // ----------------------------------------------------------------
    // Cancel
    // ----------------------------------------------------------------

    function testCancelClearsRequest() public {
        _fundLpStream(50_000e18);
        MockLpRewardsVault replacement = _makeReplacementVault();

        vm.prank(owner);
        furnace.requestEmergencyVaultRewire(address(replacement));
        assertGt(furnace.emergencyVaultRewireExecuteAfter(), 0);
        assertEq(furnace.emergencyVaultRewireTargetVault(), address(replacement));

        vm.prank(owner);
        furnace.cancelEmergencyVaultRewire();
        assertEq(furnace.emergencyVaultRewireExecuteAfter(), 0, "request should be cleared");
        assertEq(furnace.emergencyVaultRewireTargetVault(), address(0), "target should be cleared");
    }

    function testCancelRevertsIfNoPendingRequest() public {
        vm.prank(owner);
        vm.expectRevert(Errors.EmergencyRewireNotRequested.selector);
        furnace.cancelEmergencyVaultRewire();
    }

    function testCancelThenReRequest() public {
        _fundLpStream(50_000e18);

        MockLpRewardsVault replacement = _makeReplacementVault();
        MockLpRewardsVault replacement2 = _makeReplacementVault();

        vm.startPrank(owner);
        furnace.requestEmergencyVaultRewire(address(replacement));
        furnace.cancelEmergencyVaultRewire();
        furnace.requestEmergencyVaultRewire(address(replacement2));
        vm.stopPrank();

        assertEq(
            furnace.emergencyVaultRewireExecuteAfter(), block.timestamp + 7 days, "new 7-day delay from re-request"
        );
        assertEq(furnace.emergencyVaultRewireTargetVault(), address(replacement2), "new target should be stored");
    }

    // ----------------------------------------------------------------
    // Execute guards
    // ----------------------------------------------------------------

    function testExecuteRevertsIfNotRequested() public {
        vm.prank(owner);
        vm.expectRevert(Errors.EmergencyRewireNotRequested.selector);
        furnace.executeEmergencyVaultRewire();
    }

    function testExecuteRevertsIfDelayNotMet() public {
        _fundLpStream(50_000e18);
        MockLpRewardsVault replacement = _makeReplacementVault();

        vm.prank(owner);
        furnace.requestEmergencyVaultRewire(address(replacement));

        vm.warp(furnace.emergencyVaultRewireExecuteAfter() - 1);

        vm.prank(owner);
        vm.expectRevert(Errors.EmergencyRewireDelayNotMet.selector);
        furnace.executeEmergencyVaultRewire();
    }

    // ----------------------------------------------------------------
    // Post-execute state
    // ----------------------------------------------------------------

    function testExecuteAllowsNewVaultWiring() public {
        _fundLpStream(100_000e18);

        MockLpRewardsVault newVault = _makeReplacementVault();

        vm.prank(owner);
        vm.expectRevert(Errors.LpRewardsStreamActive.selector);
        furnace.setLpRewardsVault(address(newVault));

        vm.prank(owner);
        furnace.requestEmergencyVaultRewire(address(newVault));
        vm.warp(furnace.emergencyVaultRewireExecuteAfter());
        vm.prank(owner);
        furnace.executeEmergencyVaultRewire();

        assertEq(furnace.lpRewardsVault(), address(newVault));
    }

    function testExecutePreservesReserveAccounting() public {
        _creditReserve(1_000_000e18);
        _fundLpStream(100_000e18);
        MockLpRewardsVault replacement = _makeReplacementVault();

        uint256 reserveBefore = furnace.furnaceReserve();

        vm.prank(owner);
        furnace.requestEmergencyVaultRewire(address(replacement));
        vm.warp(furnace.emergencyVaultRewireExecuteAfter());
        vm.prank(owner);
        furnace.executeEmergencyVaultRewire();

        assertEq(furnace.furnaceReserve(), reserveBefore, "reserve unchanged by rewire");
        assertGt(claim.balanceOf(address(furnace)), reserveBefore, "balance includes stranded CLAIM");
        assertEq(furnace.lpRewardsVault(), address(replacement), "vault rewired");
    }

    function testRequestAndExecuteStillWorkAfterFreeze() public {
        _fundLpStream(100_000e18);
        MockLpRewardsVault replacement = _makeReplacementVault();

        vm.prank(owner);
        furnace.freezeConfig();

        vm.prank(owner);
        furnace.requestEmergencyVaultRewire(address(replacement));
        assertEq(furnace.emergencyVaultRewireTargetVault(), address(replacement), "target should be stored post-freeze");

        vm.warp(furnace.emergencyVaultRewireExecuteAfter());

        vm.prank(owner);
        furnace.executeEmergencyVaultRewire();

        assertEq(furnace.lpRewardsVault(), address(replacement), "post-freeze rewire should update vault");
    }

    function testCancelStillWorksAfterFreeze() public {
        _fundLpStream(50_000e18);
        MockLpRewardsVault replacement = _makeReplacementVault();

        vm.prank(owner);
        furnace.freezeConfig();

        vm.prank(owner);
        furnace.requestEmergencyVaultRewire(address(replacement));

        vm.prank(owner);
        furnace.cancelEmergencyVaultRewire();

        assertEq(furnace.emergencyVaultRewireExecuteAfter(), 0, "request should be cleared");
        assertEq(furnace.emergencyVaultRewireTargetVault(), address(0), "target should be cleared");
    }
}
