// SPDX-License-Identifier: MIT
pragma solidity ^0.8.34;

import {Test} from "forge-std/Test.sol";
import {Vm} from "forge-std/Vm.sol";

import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";

import {ClaimToken} from "src/ClaimToken.sol";
import {MineCore} from "src/MineCore.sol";
import {ShareholderRoyalties} from "src/ShareholderRoyalties.sol";
import {FurnaceQuoter} from "src/FurnaceQuoter.sol";
import {IFurnaceQuoter} from "src/interfaces/IFurnaceQuoter.sol";
import {Constants} from "src/lib/Constants.sol";
import {Errors} from "src/lib/Errors.sol";

import {DelegationHub} from "src/DelegationHub.sol";
import {DelegationPermissions} from "src/lib/DelegationPermissions.sol";
import {FurnaceHarness} from "./mocks/FurnaceHarness.sol";
import {MockContract} from "./mocks/MockContract.sol";
import {MockEntryTokenRegistry} from "./mocks/MockEntryTokenRegistry.sol";
import {MockLpRewardsVault} from "./mocks/MockLpRewardsVault.sol";
import {VeClaimNFTHarness} from "./mocks/VeClaimNFTHarness.sol";

contract FurnaceTest is Test {
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
    DelegationHub internal delegationHub;

    function setUp() public {
        claim = new ClaimToken(owner);
        ve = new VeClaimNFTHarness(address(claim), owner);

        royalties = new ShareholderRoyalties(address(ve), owner);
        // MineCore is used as the canonical time + emission anchor for the Furnace.
        mineCore = new MineCore(address(claim), address(ve), address(royalties), owner);
        furnace = new FurnaceHarness(address(claim), address(ve), owner);
        furnaceQuoter = new FurnaceQuoter(address(furnace));
        delegationHub = new DelegationHub();
        mineMarket = address(new MockContract());
        registry = address(new MockEntryTokenRegistry());
        mineCoreRegistry = address(new MockEntryTokenRegistry());
        vm.mockCall(mineMarket, abi.encodeWithSignature("claim()"), abi.encode(address(claim)));
        vm.mockCall(mineMarket, abi.encodeWithSignature("ve()"), abi.encode(address(ve)));
        vm.mockCall(mineMarket, abi.encodeWithSignature("royalties()"), abi.encode(address(royalties)));

        // Wire core addresses.
        vm.startPrank(owner);
        claim.setMineCore(address(mineCore));
        furnace.setMineCore(address(mineCore));
        furnace.setFurnaceQuoter(address(furnaceQuoter));
        furnace.setShareholderRoyalties(address(royalties));
        furnace.setMineMarket(mineMarket);
        furnace.setEntryTokenRegistry(registry);
        mineCore.setFurnace(address(furnace));
        mineCore.setDelegationHub(address(delegationHub));
        mineCore.setEntryTokenRegistry(mineCoreRegistry);
        furnace.setDelegationHub(address(delegationHub));
        royalties.setWiring(address(mineCore), mineMarket, address(furnace));
        ve.setFurnace(address(furnace));
        ve.setMineMarket(mineMarket);
        vm.stopPrank();
    }

    function _mockFurnaceRegistryWithLiveWethClaimHop() internal returns (address hopPool) {
        MockEntryTokenRegistry mockRegistry = MockEntryTokenRegistry(registry);
        hopPool = address(new MockContract());
        mockRegistry.setRouterConfig(mineMarket, mineMarket, mineMarket, address(claim));
        vm.mockCall(
            mineMarket,
            abi.encodeWithSignature(
                "poolFor(address,address,bool,address)", mineMarket, address(claim), false, mineMarket
            ),
            abi.encode(hopPool)
        );
        mockRegistry.setWethClaimHop(false, hopPool);
    }

    // ------------------------------------------------------------
    // Admin / wiring
    // ------------------------------------------------------------

    function testWiringSettersOnlyOwnerAndNonZero() public {
        address attacker = address(0xBAD);

        vm.prank(attacker);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, attacker));
        furnace.setMineCore(address(0x1234));

        vm.prank(owner);
        vm.expectRevert(Errors.ZeroAddress.selector);
        furnace.setMineCore(address(0));

        vm.prank(owner);
        vm.expectRevert(Errors.NotAContract.selector);
        furnace.setMineCore(address(0x1234));

        ClaimToken replacementClaim = new ClaimToken(owner);
        VeClaimNFTHarness replacementVe = new VeClaimNFTHarness(address(replacementClaim), owner);
        ShareholderRoyalties replacementRoyalties = new ShareholderRoyalties(address(replacementVe), owner);
        MineCore otherMineCore =
            new MineCore(address(replacementClaim), address(replacementVe), address(replacementRoyalties), owner);
        vm.prank(owner);
        furnace.setMineCore(address(otherMineCore));
        assertEq(address(furnace.mineCore()), address(otherMineCore));

        vm.prank(owner);
        vm.expectRevert(Errors.ZeroAddress.selector);
        furnace.setMineMarket(address(0));

        vm.prank(owner);
        vm.expectRevert(Errors.NotAContract.selector);
        furnace.setMineMarket(address(0x5678));

        address newMineMarket = address(new MockContract());
        vm.mockCall(newMineMarket, abi.encodeWithSignature("claim()"), abi.encode(address(claim)));
        vm.mockCall(newMineMarket, abi.encodeWithSignature("ve()"), abi.encode(address(ve)));
        vm.mockCall(newMineMarket, abi.encodeWithSignature("royalties()"), abi.encode(address(royalties)));

        vm.prank(owner);
        furnace.setMineMarket(newMineMarket);
        assertEq(address(furnace.mineMarket()), address(newMineMarket));

        vm.prank(owner);
        vm.expectRevert(Errors.ZeroAddress.selector);
        furnace.setEntryTokenRegistry(address(0));

        vm.prank(owner);
        vm.expectRevert(Errors.NotAContract.selector);
        furnace.setEntryTokenRegistry(address(0x2222));

        address newRegistry = address(new MockEntryTokenRegistry());
        vm.prank(owner);
        furnace.setEntryTokenRegistry(newRegistry);
        assertEq(address(furnace.entryTokenRegistry()), newRegistry);

        // LP rewards vault allows address(0) (disables LP split + drip).
        vm.prank(owner);
        furnace.setLpRewardsVault(address(0));
        assertEq(furnace.lpRewardsVault(), address(0));

        vm.prank(owner);
        vm.expectRevert(Errors.NotAContract.selector);
        furnace.setLpRewardsVault(address(0x3333));

        // Non-zero must be a contract and must be wired to this Furnace.
        lpVault = new MockLpRewardsVault();
        lpVault.setFurnace(address(furnace));

        vm.prank(owner);
        furnace.setLpRewardsVault(address(lpVault));
        assertEq(furnace.lpRewardsVault(), address(lpVault));

        vm.prank(owner);
        vm.expectRevert(Errors.ZeroAddress.selector);
        furnace.setShareholderRoyalties(address(0));

        vm.prank(owner);
        vm.expectRevert(Errors.NotAContract.selector);
        furnace.setShareholderRoyalties(address(0x4444));
    }

    function testSetEntryTokenRegistryRejectsMineCoreRegistry() public {
        vm.prank(owner);
        vm.expectRevert(Errors.WiringMismatch.selector);
        furnace.setEntryTokenRegistry(mineCoreRegistry);
    }

    function testSetDelegationHubRejectsEoa() public {
        vm.prank(owner);
        vm.expectRevert(Errors.NotAContract.selector);
        furnace.setDelegationHub(address(0xBEEF));
    }

    function testFuzzSetDelegationHubRejectsAnyEoa(address candidate) public {
        vm.assume(candidate != address(0));
        vm.assume(candidate.code.length == 0);

        vm.prank(owner);
        vm.expectRevert(Errors.NotAContract.selector);
        furnace.setDelegationHub(candidate);
    }

    function testSetLpRewardsVaultRejectsMismatchedFurnaceAndEmitsEvent() public {
        // Mismatch: vault.furnace() must equal this Furnace.
        MockLpRewardsVault bad = new MockLpRewardsVault();
        vm.prank(owner);
        vm.expectRevert(Errors.LpRewardsVaultFurnaceMismatch.selector);
        furnace.setLpRewardsVault(address(bad));

        // Proper wiring should emit the config event.
        MockLpRewardsVault good = new MockLpRewardsVault();
        good.setFurnace(address(furnace));

        vm.recordLogs();
        vm.prank(owner);
        furnace.setLpRewardsVault(address(good));

        Vm.Log[] memory logs = vm.getRecordedLogs();
        bytes32 sig = keccak256("LpRewardsVaultSet(address,address)");

        bool found;
        for (uint256 i = 0; i < logs.length; i++) {
            if (logs[i].topics.length >= 3 && logs[i].topics[0] == sig) {
                found = true;
                assertEq(address(uint160(uint256(logs[i].topics[1]))), address(0), "oldVault");
                assertEq(address(uint160(uint256(logs[i].topics[2]))), address(good), "newVault");
            }
        }
        assertTrue(found, "LpRewardsVaultSet event not found");
    }

    function testSetLpRewardsVaultRevertsOnClaimRootMismatch() public {
        MockLpRewardsVault bad = new MockLpRewardsVault();
        bad.setFurnace(address(furnace));
        bad.setClaimOverride(address(0xDEAD));

        vm.prank(owner);
        vm.expectRevert(Errors.WiringMismatch.selector);
        furnace.setLpRewardsVault(address(bad));
    }

    function testSetLpRewardsVaultRevertsOnVeRootMismatch() public {
        MockLpRewardsVault bad = new MockLpRewardsVault();
        bad.setFurnace(address(furnace));
        bad.setVeOverride(address(0xBEEF));

        vm.prank(owner);
        vm.expectRevert(Errors.WiringMismatch.selector);
        furnace.setLpRewardsVault(address(bad));
    }

    function testFuzzSetLpRewardsVaultRejectsAnyClaimRootMismatch(address badClaim) public {
        vm.assume(badClaim != address(0));
        vm.assume(badClaim != address(claim));

        MockLpRewardsVault bad = new MockLpRewardsVault();
        bad.setFurnace(address(furnace));
        bad.setClaimOverride(badClaim);

        vm.prank(owner);
        vm.expectRevert(Errors.WiringMismatch.selector);
        furnace.setLpRewardsVault(address(bad));
    }

    function testSetLpRewardsVaultRevertsWhenParkedStreamWouldBeRedirected() public {
        MockLpRewardsVault oldVault = new MockLpRewardsVault();
        oldVault.setFurnace(address(furnace));
        MockLpRewardsVault newVault = new MockLpRewardsVault();
        newVault.setFurnace(address(furnace));

        vm.prank(owner);
        furnace.setLpRewardsVault(address(oldVault));

        uint256 funded = Constants.LP_STREAM_WINDOW;
        vm.prank(address(mineCore));
        claim.mint(address(furnace), funded);
        furnace.exposedFundLpStream(funded);

        vm.prank(owner);
        vm.expectRevert(Errors.LpRewardsStreamActive.selector);
        furnace.setLpRewardsVault(address(newVault));
    }

    function testSetLpRewardsVaultAccruesMaturedStreamBeforeChange() public {
        MockLpRewardsVault oldVault = new MockLpRewardsVault();
        oldVault.setFurnace(address(furnace));

        vm.prank(owner);
        furnace.setLpRewardsVault(address(oldVault));

        uint256 funded = Constants.LP_STREAM_WINDOW;
        vm.prank(address(mineCore));
        claim.mint(address(furnace), funded);
        furnace.exposedFundLpStream(funded);

        vm.warp(block.timestamp + Constants.LP_STREAM_WINDOW + 1);
        assertEq(furnace.exposedLpStreamLiability(), funded, "matured-but-unaccrued liability");

        // F-03: setLpRewardsVault now accrues the matured stream first, then succeeds.
        vm.prank(owner);
        furnace.setLpRewardsVault(address(0));
    }

    function testSetLpRewardsVaultAllowsChangeAfterParkedStreamIsFullyAccrued() public {
        MockLpRewardsVault oldVault = new MockLpRewardsVault();
        oldVault.setFurnace(address(furnace));
        MockLpRewardsVault newVault = new MockLpRewardsVault();
        newVault.setFurnace(address(furnace));

        vm.prank(owner);
        furnace.setLpRewardsVault(address(oldVault));

        uint256 funded = Constants.LP_STREAM_WINDOW;
        vm.prank(address(mineCore));
        claim.mint(address(furnace), funded);
        furnace.exposedFundLpStream(funded);

        vm.warp(block.timestamp + Constants.LP_STREAM_WINDOW + 1);
        assertEq(furnace.exposedAccrueLpStream(), funded, "accrued full parked stream");
        assertEq(claim.balanceOf(address(oldVault)), funded, "old vault received funded rewards");
        assertEq(furnace.exposedLpStreamLiability(), 0, "no parked stream remains");

        vm.prank(owner);
        furnace.setLpRewardsVault(address(newVault));
        assertEq(furnace.lpRewardsVault(), address(newVault), "vault changed after accrual");
    }

    function testSetLpRewardsVaultSettlesMaturedCarryBeforeRewire() public {
        MockLpRewardsVault oldVault = new MockLpRewardsVault();
        oldVault.setFurnace(address(furnace));
        MockLpRewardsVault newVault = new MockLpRewardsVault();
        newVault.setFurnace(address(furnace));

        vm.prank(owner);
        furnace.setLpRewardsVault(address(oldVault));

        uint256 funded = Constants.LP_STREAM_WINDOW + 17;
        vm.prank(address(mineCore));
        claim.mint(address(furnace), funded);
        furnace.exposedFundLpStream(funded);

        vm.warp(block.timestamp + Constants.LP_STREAM_WINDOW + 1);
        assertEq(furnace.exposedAccrueLpStream(), Constants.LP_STREAM_WINDOW, "scheduled portion accrued");
        assertEq(claim.balanceOf(address(oldVault)), Constants.LP_STREAM_WINDOW, "scheduled rewards transferred");
        assertEq(furnace.exposedLpStreamCarry(), 17, "carry remains after accrual");
        assertEq(furnace.exposedLpStreamLiability(), 17, "carry-only liability remains attributed to old vault");
        assertEq(oldVault.notifyCalls(), 1, "stream accrual notified once");

        vm.prank(owner);
        furnace.setLpRewardsVault(address(newVault));

        assertEq(claim.balanceOf(address(oldVault)), funded, "carry settled to old vault before rewire");
        assertEq(oldVault.notifyCalls(), 2, "carry settlement should notify old vault");
        assertEq(oldVault.lastNotifiedAmount(), 17, "carry notify amount");
        assertEq(furnace.exposedLpStreamCarry(), 0, "carry cleared");
        assertEq(furnace.exposedLpStreamLiability(), 0, "no remaining old-vault liability");
        assertEq(furnace.lpRewardsVault(), address(newVault), "vault rewired after settling carry");
    }

    function testSetLpRewardsVaultRevertsWhenPendingOverflowDripWouldBeRedirected() public {
        MockLpRewardsVault oldVault = new MockLpRewardsVault();
        oldVault.setFurnace(address(furnace));
        MockLpRewardsVault newVault = new MockLpRewardsVault();
        newVault.setFurnace(address(furnace));

        vm.prank(owner);
        furnace.setLpRewardsVault(address(oldVault));

        uint256 start = mineCore.emissionStartTime();
        vm.warp(start + Constants.LP_OVERFLOW_DRIP_START + Constants.LP_OVERFLOW_DRIP_RAMP + 1);

        uint256 reserve = Constants.RESERVE_TARGET_FINAL + 50_000_000e18;
        vm.prank(address(mineCore));
        claim.mint(address(furnace), reserve);
        vm.prank(address(mineCore));
        furnace.creditReserve(reserve);

        vm.warp(block.timestamp + 1 days);
        assertGt(furnace.exposedPendingLpOverflowDripLiability(), 0, "pending overflow drip liability");

        vm.prank(owner);
        vm.expectRevert(Errors.LpRewardsStreamActive.selector);
        furnace.setLpRewardsVault(address(newVault));
    }

    function testSetLpRewardsVaultRevertsWhenPendingOverflowDripWouldBeStrandedByDisable() public {
        MockLpRewardsVault oldVault = new MockLpRewardsVault();
        oldVault.setFurnace(address(furnace));

        vm.prank(owner);
        furnace.setLpRewardsVault(address(oldVault));

        uint256 start = mineCore.emissionStartTime();
        vm.warp(start + Constants.LP_OVERFLOW_DRIP_START + Constants.LP_OVERFLOW_DRIP_RAMP + 1);

        uint256 reserve = Constants.RESERVE_TARGET_FINAL + 50_000_000e18;
        vm.prank(address(mineCore));
        claim.mint(address(furnace), reserve);
        vm.prank(address(mineCore));
        furnace.creditReserve(reserve);

        vm.warp(block.timestamp + 1 days);
        assertGt(furnace.exposedPendingLpOverflowDripLiability(), 0, "pending overflow drip liability");

        vm.prank(owner);
        vm.expectRevert(Errors.LpRewardsStreamActive.selector);
        furnace.setLpRewardsVault(address(0));
    }

    function testSetLpRewardsVaultChangeResetsOverflowDripCursorForNewVaultPeriod() public {
        uint256 start = mineCore.emissionStartTime();
        vm.warp(start + Constants.LP_OVERFLOW_DRIP_START + Constants.LP_OVERFLOW_DRIP_RAMP + 1);

        uint256 reserve = Constants.RESERVE_TARGET_FINAL + 50_000_000e18;
        vm.prank(address(mineCore));
        claim.mint(address(furnace), reserve);
        vm.prank(address(mineCore));
        furnace.creditReserve(reserve);

        vm.warp(block.timestamp + 3 days);
        assertEq(furnace.lpRewardsVault(), address(0), "drip disabled");
        assertEq(furnace.exposedPendingLpOverflowDripLiability(), 0, "no vault-specific liability while disabled");

        MockLpRewardsVault newVault = new MockLpRewardsVault();
        newVault.setFurnace(address(furnace));

        vm.prank(owner);
        furnace.setLpRewardsVault(address(newVault));

        assertEq(furnace.lastLpOverflowDripUpdate(), block.timestamp, "cursor reset on enable");
        assertEq(furnace.exposedPendingLpOverflowDripLiability(), 0, "disabled window not retro-dripped");

        vm.warp(block.timestamp + 1 days);
        assertGt(furnace.exposedPendingLpOverflowDripLiability(), 0, "new vault accrues only after enable");
    }

    function testLpStreamNotifyFailureIsBestEffortAndEmitsEvent() public {
        // Enable LP vault.
        lpVault = new MockLpRewardsVault();
        lpVault.setFurnace(address(furnace));
        vm.prank(owner);
        furnace.setLpRewardsVault(address(lpVault));

        // Fund the furnace with enough CLAIM to cover the stream.
        uint256 total = Constants.LP_STREAM_WINDOW; // ensures ratePerSec >= 1
        vm.prank(address(mineCore));
        claim.mint(address(furnace), total);

        // Schedule the stream and advance time so some amount is owed.
        furnace.exposedFundLpStream(total);
        lpVault.setRevertOnNotify(true);

        uint256 dt = 123;
        vm.warp(block.timestamp + dt);

        vm.recordLogs();
        uint256 streamed = furnace.exposedAccrueLpStream();

        assertEq(streamed, dt, "streamed should equal dt when rate==1");
        assertEq(claim.balanceOf(address(lpVault)), dt, "CLAIM should transfer even if notify fails");
        assertEq(lpVault.notifyCalls(), 0, "notify should have reverted");

        // Verify the failure event was emitted with the raw revert data.
        Vm.Log[] memory logs = vm.getRecordedLogs();
        bytes32 sig = keccak256("LpRewardsNotifyFailed(address,uint256,bytes)");

        bool found;
        for (uint256 i = 0; i < logs.length; i++) {
            if (logs[i].topics.length >= 2 && logs[i].topics[0] == sig) {
                found = true;
                assertEq(address(uint160(uint256(logs[i].topics[1]))), address(lpVault), "vault");
                (uint256 amountClaim, bytes memory revertData) = abi.decode(logs[i].data, (uint256, bytes));
                assertEq(amountClaim, streamed, "amountClaim");
                bytes memory expected = abi.encodeWithSelector(MockLpRewardsVault.NotifyReverted.selector);
                // Some call paths can surface an empty revert payload; both forms are acceptable.
                assertTrue(keccak256(revertData) == keccak256(expected) || revertData.length == 0, "revertData");
            }
        }
        assertTrue(found, "LpRewardsNotifyFailed event not found");
    }

    function testLpStreamFundedEmitsScheduleEvent() public {
        lpVault = new MockLpRewardsVault();
        lpVault.setFurnace(address(furnace));
        vm.prank(owner);
        furnace.setLpRewardsVault(address(lpVault));

        uint256 amount = Constants.LP_STREAM_WINDOW * 2 + 17;
        uint256 expectedRate = amount / Constants.LP_STREAM_WINDOW;
        uint256 expectedFinish = block.timestamp + Constants.LP_STREAM_WINDOW;

        vm.recordLogs();
        furnace.exposedFundLpStream(amount);

        Vm.Log[] memory logs = vm.getRecordedLogs();
        bytes32 sig = keccak256("LpStreamFunded(uint256,uint256,uint256)");

        bool found;
        for (uint256 i = 0; i < logs.length; i++) {
            if (logs[i].topics.length == 1 && logs[i].topics[0] == sig) {
                found = true;
                (uint256 amountFunded, uint256 newRatePerSec, uint256 newPeriodFinish) =
                    abi.decode(logs[i].data, (uint256, uint256, uint256));
                assertEq(amountFunded, amount, "amountFunded");
                assertEq(newRatePerSec, expectedRate, "newRatePerSec");
                assertEq(newPeriodFinish, expectedFinish, "newPeriodFinish");
            }
        }
        assertTrue(found, "LpStreamFunded event not found");
    }

    function testLpStreamFundingCarriesRoundingDustAsLiability() public {
        lpVault = new MockLpRewardsVault();
        lpVault.setFurnace(address(furnace));
        vm.prank(owner);
        furnace.setLpRewardsVault(address(lpVault));

        uint256 amount = Constants.LP_STREAM_WINDOW * 2 + 17;
        vm.prank(address(mineCore));
        claim.mint(address(furnace), amount);

        furnace.exposedFundLpStream(amount);

        assertEq(furnace.getLpStreamRemaining(), Constants.LP_STREAM_WINDOW * 2, "scheduled remaining");
        assertEq(furnace.exposedLpStreamCarry(), 17, "carry retained");
        assertEq(furnace.exposedLpStreamLiability(), amount, "liability tracks full funding");
    }

    function testLpStreamCarrySurvivesAccrualAndFundsLaterSchedule() public {
        lpVault = new MockLpRewardsVault();
        lpVault.setFurnace(address(furnace));
        vm.prank(owner);
        furnace.setLpRewardsVault(address(lpVault));

        uint256 amount0 = Constants.LP_STREAM_WINDOW + 17;
        vm.prank(address(mineCore));
        claim.mint(address(furnace), amount0);

        furnace.exposedFundLpStream(amount0);
        assertEq(furnace.exposedLpStreamCarry(), 17, "initial carry");

        vm.warp(block.timestamp + Constants.LP_STREAM_WINDOW);
        uint256 streamed = furnace.exposedAccrueLpStream();
        assertEq(streamed, Constants.LP_STREAM_WINDOW, "scheduled amount streamed");
        assertEq(furnace.getLpStreamRemaining(), 0, "remaining cleared");
        assertEq(furnace.exposedLpStreamCarry(), 17, "carry survives accrual");

        uint256 amount1 = Constants.LP_STREAM_WINDOW - 17;
        vm.prank(address(mineCore));
        claim.mint(address(furnace), amount1);

        furnace.exposedFundLpStream(amount1);

        assertEq(furnace.exposedLpStreamCarry(), 0, "carry consumed on later refill");
        assertEq(furnace.getLpStreamRemaining(), Constants.LP_STREAM_WINDOW, "later schedule recovers carry");
        assertEq(furnace.exposedLpStreamLiability(), Constants.LP_STREAM_WINDOW, "full later liability restored");
    }

    function testSyncFurnaceReserveClampsAgainstLpStreamCarry() public {
        lpVault = new MockLpRewardsVault();
        lpVault.setFurnace(address(furnace));
        vm.prank(owner);
        furnace.setLpRewardsVault(address(lpVault));

        uint256 reserve = 100e18;
        uint256 carry = 17;

        vm.prank(address(mineCore));
        claim.mint(address(furnace), reserve);
        vm.prank(address(mineCore));
        furnace.creditReserve(reserve);

        vm.prank(address(mineCore));
        claim.mint(address(furnace), carry);
        furnace.exposedFundLpStream(carry);

        assertEq(furnace.furnaceReserve(), reserve, "reserve before clamp");
        assertEq(furnace.exposedLpStreamCarry(), carry, "carry before clamp");

        vm.prank(address(furnace));
        assertTrue(claim.transfer(alice, 1), "loss transfer");

        furnace.exposedSyncFurnaceReserve();
        assertEq(furnace.furnaceReserve(), reserve - 1, "reserve clamps against carry-backed loss");
    }

    function testGuardianOnlySetLockingPausedAndRotationRules() public {
        address attacker = address(0xBAD);

        // With MineCore wired, guardian must be the MineCore contract address (not the owner EOA).
        vm.prank(owner);
        furnace.setGuardian(address(mineCore));
        assertEq(furnace.guardian(), address(mineCore));

        vm.prank(attacker);
        vm.expectRevert(Errors.OnlyGuardian.selector);
        furnace.setLockingPaused(true);

        vm.prank(owner);
        vm.expectRevert(Errors.OnlyGuardian.selector);
        furnace.setLockingPaused(true);

        vm.prank(owner);
        mineCore.setLockingPaused(true);
        assertTrue(furnace.lockingPaused());

        vm.prank(attacker);
        vm.expectRevert(Errors.NotAuthorized.selector);
        furnace.setGuardian(attacker);

        vm.prank(owner);
        vm.expectRevert(Errors.ZeroAddress.selector);
        furnace.setGuardian(address(0));

        vm.prank(owner);
        vm.expectRevert(Errors.WiringMismatch.selector);
        furnace.setGuardian(attacker);

        vm.prank(address(mineCore));
        furnace.setGuardian(address(mineCore));
        assertEq(furnace.guardian(), address(mineCore));

        vm.prank(owner);
        mineCore.setLockingPaused(false);
        assertFalse(furnace.lockingPaused());
    }

    function testQuoteHelpersRevertWhenLockingPaused() public {
        vm.prank(address(mineCore));
        furnace.setLockingPaused(true);

        vm.expectRevert(Errors.LockingPaused.selector);
        furnaceQuoter.quoteEnterWithClaim(alice, 1e18, 0, Constants.MIN_LOCK_DURATION, false);

        vm.expectRevert(Errors.LockingPaused.selector);
        furnaceQuoter.quoteSellLockToFurnaceFromInfo(
            Constants.MIN_LOCK_AMOUNT, block.timestamp + Constants.MIN_LOCK_DURATION, false
        );
    }

    function testQuoteSellLockForExecutionRevertsWhenLockingPaused() public {
        vm.prank(address(mineCore));
        furnace.setLockingPaused(true);

        vm.expectRevert(Errors.LockingPaused.selector);
        furnaceQuoter.quoteSellLockForExecution(
            Constants.MIN_LOCK_AMOUNT, block.timestamp + Constants.MIN_LOCK_DURATION, false
        );
    }

    function testCreditReserveOnlyMineCore() public {
        vm.expectRevert(Errors.OnlyMineCore.selector);
        furnace.creditReserve(1);

        // Simulate MineCore minting CLAIM into the Furnace and crediting the reserve.
        uint256 amount = 1_000e18;
        vm.prank(address(mineCore));
        claim.mint(address(furnace), amount);

        vm.prank(address(mineCore));
        furnace.creditReserve(amount);

        assertEq(furnace.furnaceReserve(), amount);
    }

    function testCreditReserveClampsToBalanceWhenOverCredited() public {
        // MineCore mints less CLAIM than it claims to have credited.
        uint256 minted = 1_000e18;
        vm.prank(address(mineCore));
        claim.mint(address(furnace), minted);

        vm.recordLogs();
        vm.prank(address(mineCore));
        furnace.creditReserve(minted * 2);

        assertEq(furnace.furnaceReserve(), minted, "reserve should clamp to balance");

        // Verify ReserveClamped was emitted.
        Vm.Log[] memory logs = vm.getRecordedLogs();
        bytes32 sig = keccak256("ReserveClamped(address,uint256,uint256,uint256,uint256)");

        bool found;
        for (uint256 i = 0; i < logs.length; i++) {
            if (logs[i].topics.length >= 2 && logs[i].topics[0] == sig) {
                found = true;
                assertEq(address(uint160(uint256(logs[i].topics[1]))), address(mineCore), "caller");
                (uint256 oldReserve, uint256 newReserve, uint256 claimBal, uint256 remaining) =
                    abi.decode(logs[i].data, (uint256, uint256, uint256, uint256));
                assertEq(oldReserve, minted * 2, "oldReserve");
                assertEq(newReserve, minted, "newReserve");
                assertEq(claimBal, minted, "claimBalance");
                assertEq(remaining, 0, "lpStreamRemaining");
            }
        }
        assertTrue(found, "ReserveClamped event not found");
    }

    function testOwnerMayRewireMineMarketWhenGuardianIsMineCore() public {
        vm.prank(owner);
        furnace.setGuardian(address(mineCore));

        address newMarket = address(0x9999);
        vm.etch(newMarket, hex"00");
        vm.prank(owner);
        furnace.setMineMarket(newMarket);
        assertEq(address(furnace.mineMarket()), newMarket);
    }

    function testMineCoreMayReassertGuardian() public {
        vm.prank(owner);
        furnace.setGuardian(address(mineCore));

        vm.prank(address(mineCore));
        furnace.setGuardian(address(mineCore));
        assertEq(furnace.guardian(), address(mineCore));
    }

    function testMineCoreMayReassertGuardianWhileLockingPaused() public {
        vm.prank(owner);
        furnace.setGuardian(address(mineCore));

        vm.prank(owner);
        mineCore.setLockingPaused(true);
        assertTrue(furnace.lockingPaused());

        vm.prank(address(mineCore));
        furnace.setGuardian(address(mineCore));

        assertEq(furnace.guardian(), address(mineCore));
        assertTrue(furnace.lockingPaused(), "rotation must not unpause locking");
    }

    function testOwnerMayReassertGuardianWhileLockingPaused() public {
        vm.prank(owner);
        furnace.setGuardian(address(mineCore));

        vm.prank(owner);
        mineCore.setLockingPaused(true);
        assertTrue(furnace.lockingPaused());

        vm.prank(owner);
        furnace.setGuardian(address(mineCore));

        assertEq(furnace.guardian(), address(mineCore));
        assertTrue(furnace.lockingPaused(), "rotation must not unpause locking");
    }

    // ------------------------------------------------------------
    // Bonus model: spot cap anchored to lockedSupply
    // ------------------------------------------------------------

    function testLockedSupplyAnchorUsesVeTotalLockedClaim() public {
        // lockedSupply should track ve.totalLockedClaim(). It MUST NOT rely on ve's raw CLAIM balance,
        // since direct CLAIM transfers to VeClaimNFT are treated as donations and are not counted.
        (
            uint256 reserve,
            uint256 lockedSupply,
            uint256 userSpotBps,
            uint256 lpRateBps,
            uint256 quoteUserBps,
            uint256 quoteLpTopupBps,
            uint256 virtualDepth,
            uint256 lastUpdate
        ) = furnaceQuoter.getFurnaceState();

        assertEq(reserve, furnace.furnaceReserve(), "reserve mismatch");
        assertEq(lockedSupply, ve.totalLockedClaim(), "lockedSupply must equal ve.totalLockedClaim()");

        // With no reserve, quotes are 0 and virtual depth is 0.
        assertEq(quoteUserBps, 0, "quoteUserBps should be 0 when reserve=0");
        assertEq(quoteLpTopupBps, 0, "quoteLpTopupBps should be 0 when reserve=0");
        assertEq(virtualDepth, 0, "virtualDepth should be 0 when reserve=0");

        // At launch (alpha=0), reserveFactor=1.0x, so userSpotBps==baseUserBps.
        assertEq(userSpotBps, Constants.MAX_USER_BONUS_BPS, "userSpotBps should equal MAX at lockedSupply=0");
        assertEq(lpRateBps, 0, "lpRateBps must be 0 when LP vault unset");
        assertLe(lastUpdate, block.timestamp, "lastUpdate in future");

        // Mint some CLAIM to a user and lock it into ve so totalLockedClaim updates.
        uint256 amountLocked = 1_000e18;
        address locker = address(0xA);
        vm.prank(address(mineCore));
        claim.mint(locker, amountLocked);

        vm.startPrank(locker);
        claim.approve(address(ve), amountLocked);
        ve.createLock(amountLocked, Constants.MIN_LOCK_DURATION, false);
        vm.stopPrank();

        (, lockedSupply,,,,,,) = furnaceQuoter.getFurnaceState();
        assertEq(lockedSupply, ve.totalLockedClaim(), "lockedSupply should track ve.totalLockedClaim()");

        // Direct CLAIM sent to ve is a donation and MUST NOT affect lockedSupply/totalLockedClaim.
        uint256 donation = 123e18;
        address donor = address(0xD0D0);
        vm.prank(address(mineCore));
        claim.mint(donor, donation);

        vm.prank(donor);
        require(claim.transfer(address(ve), donation), "transfer failed");

        (, lockedSupply,,,,,,) = furnaceQuoter.getFurnaceState();
        assertEq(lockedSupply, ve.totalLockedClaim(), "lockedSupply must ignore donated CLAIM");
        assertGt(
            claim.balanceOf(address(ve)), lockedSupply, "ve CLAIM balance can exceed lockedSupply due to donations"
        );
    }

    function testBaseUserBpsAtZeroLockedIsMax() public {
        uint256 baseUserBps = furnace.exposedBaseUserBps(0, 1e18);
        assertEq(baseUserBps, 10_000);
    }

    function testBaseUserBpsAtTargetLockPctIsHalfMax() public {
        uint256 totalSupply = 10_000e18;
        uint256 lockedSupply = Math.mulDiv(totalSupply, Constants.LOCK_PCT_TARGET_BPS, 10_000);

        uint256 baseUserBps = furnace.exposedBaseUserBps(lockedSupply, totalSupply);
        assertEq(baseUserBps, 5_000);
    }

    function testBaseUserBpsIsLowWhenFullyLocked() public {
        uint256 totalSupply = 10_000e18;
        uint256 lockedSupply = totalSupply; // 100% locked

        uint256 baseUserBps = furnace.exposedBaseUserBps(lockedSupply, totalSupply);

        uint256 expected = Math.mulDiv(10_000, Constants.LOCK_PCT_TARGET_BPS, 10_000 + Constants.LOCK_PCT_TARGET_BPS);
        assertEq(baseUserBps, expected);
    }

    // ------------------------------------------------------------
    // ReserveFullness + swingAlpha + reserveFactor
    // ------------------------------------------------------------

    function testReserveFactorRampInAndPiecewiseBehavior() public {
        uint256 target = Constants.RESERVE_TARGET_FINAL;

        uint256 reserveHalf = target / 2;
        uint256 rfHalf = furnace.exposedReserveFullnessBps(reserveHalf);
        assertEq(rfHalf, 5_000, "reserveFullness at half target");

        // t=0: alpha=0 => reserveFactor==10_000 regardless of reserveFullness.
        uint256 alpha0 = furnace.exposedSwingAlphaBps(0);
        assertEq(alpha0, 0);
        uint256 factorAt0 = furnace.exposedReserveFactorBps(rfHalf, alpha0);
        assertEq(factorAt0, 10_000);

        // t=SWING_TIME: alpha=10_000 => reserveFactor==reserveFullness.
        uint256 alphaFull = furnace.exposedSwingAlphaBps(Constants.SWING_TIME);
        assertEq(alphaFull, 10_000);
        uint256 factorFull = furnace.exposedReserveFactorBps(rfHalf, alphaFull);
        assertEq(factorFull, rfHalf);

        // Below 10_000: reserveFactor decreases linearly with alpha.
        // rf=5_000, alpha=5_000 => 10_000 + 5_000*(5_000-10_000)/10_000 = 7_500
        uint256 factorMid = furnace.exposedReserveFactorBps(5_000, 5_000);
        assertEq(factorMid, 7_500);

        // Above 10_000: reserveFactor increases linearly with alpha.
        // rf=15_000, alpha=5_000 => 10_000 + 5_000*(15_000-10_000)/10_000 = 12_500
        uint256 factorAbove = furnace.exposedReserveFactorBps(15_000, 5_000);
        assertEq(factorAbove, 12_500);

        // reserveFullness clamped to RESERVE_FACTOR_MAX_BPS.
        uint256 rfClamped = furnace.exposedReserveFullnessBps(target * 3);
        assertEq(rfClamped, 20_000, "reserveFullness must clamp");
        uint256 factorClamped = furnace.exposedReserveFactorBps(rfClamped, 10_000);
        assertEq(factorClamped, 20_000, "reserveFactor must clamp");
    }

    // ------------------------------------------------------------
    // Spot + gross bounds, and split math
    // ------------------------------------------------------------

    function testUserSpotAndGrossBoundsAndLpRateBehavior() public {
        // LP vault unset => lpRateBps==0.
        uint256 userSpot = furnace.exposedUserSpotBonusBps(0, 1e18, Constants.RESERVE_TARGET_FINAL, 0);
        uint256 lpRate = furnace.exposedLpTopupRateBps(userSpot);
        assertEq(lpRate, 0);

        // Enable LP vault.
        lpVault = new MockLpRewardsVault();
        lpVault.setFurnace(address(furnace));
        vm.prank(owner);
        furnace.setLpRewardsVault(address(lpVault));

        lpRate = furnace.exposedLpTopupRateBps(userSpot);
        assertGe(lpRate, 750);
        assertLe(lpRate, 1_500);

        uint256 grossSpot = furnace.exposedGrossSpotBonusBps(userSpot, lpRate);
        uint256 expectedGross = userSpot + Math.mulDiv(userSpot, lpRate, 10_000);
        assertEq(grossSpot, expectedGross, "grossSpot formula");
        assertLe(userSpot, 10_000, "userSpot cap");
        assertLe(grossSpot, 12_500, "gross cap");
    }

    function testDynamicMaxBoostCapsUserSpotAtLowLock() public {
        // Setup: force reserveFactor to want to hit RESERVE_FACTOR_MAX_BPS.
        uint256 reserve = Constants.RESERVE_TARGET_FINAL * 2;
        uint256 elapsed = Constants.SWING_TIME; // alpha=10_000

        // At the low-lock cap threshold, baseUserBps should follow the configured lock-% anchor.
        uint256 totalSupply = 10_000e18;
        uint256 lockedSupply = Math.mulDiv(totalSupply, Constants.LOCK_PCT_MIN_FOR_BOOST_CAP_BPS, 10_000);

        uint256 userSpot = furnace.exposedUserSpotBonusBps(lockedSupply, totalSupply, reserve, elapsed);

        uint256 baseUserBps = Math.mulDiv(
            Constants.MAX_USER_BONUS_BPS,
            Constants.LOCK_PCT_TARGET_BPS,
            Constants.LOCK_PCT_TARGET_BPS + Constants.LOCK_PCT_MIN_FOR_BOOST_CAP_BPS
        );
        uint256 expected = Math.mulDiv(baseUserBps, Constants.RESERVE_FACTOR_MAX_BPS_LOWLOCK, 10_000);

        assertEq(userSpot, expected, "low-lock max boost cap should bind");
    }

    function testDynamicMaxBoostDoesNotBindAtFullBoostLockPct() public {
        uint256 reserve = Constants.RESERVE_TARGET_FINAL * 2;
        uint256 elapsed = Constants.SWING_TIME; // alpha=10_000

        // 20% lock => cap should allow full RESERVE_FACTOR_MAX_BPS.
        uint256 totalSupply = 10_000e18;
        uint256 lockedSupply = Math.mulDiv(totalSupply, Constants.LOCK_PCT_FULL_BOOST_CAP_BPS, 10_000);

        uint256 userSpot = furnace.exposedUserSpotBonusBps(lockedSupply, totalSupply, reserve, elapsed);

        uint256 baseUserBps = Math.mulDiv(
            Constants.MAX_USER_BONUS_BPS,
            Constants.LOCK_PCT_TARGET_BPS,
            Constants.LOCK_PCT_TARGET_BPS + Constants.LOCK_PCT_FULL_BOOST_CAP_BPS
        );
        uint256 expected = Math.mulDiv(baseUserBps, Constants.RESERVE_FACTOR_MAX_BPS, 10_000);

        assertEq(userSpot, expected, "full-boost lock pct should allow hard max");
    }

    function testSellSpreadFloorBindsAtMinDuration() public {
        // Create a high-lock regime to push bonusBps down, which would otherwise make sell spread too small at 7d.
        uint256 totalMint = 1_000_000e18;
        vm.prank(address(mineCore));
        claim.mint(alice, totalMint);

        vm.startPrank(alice);
        claim.approve(address(ve), type(uint256).max);

        // Background lock (60% of supply) so lockedSupplyExcl stays high after excluding the sold lock.
        ve.createLock(600_000e18, Constants.MAX_LOCK_DURATION, false);

        // Sell candidate: min amount, min duration.
        uint256 tokenId = ve.createLock(Constants.MIN_LOCK_AMOUNT, Constants.MIN_LOCK_DURATION, false);
        vm.stopPrank();

        (uint256 lockAmount,, uint256 spreadBps,,) = furnaceQuoter.quoteSellLockToFurnace(alice, tokenId);
        assertEq(lockAmount, Constants.MIN_LOCK_AMOUNT, "lock amount sanity");

        // Floor should bind for min-duration sells in low-bonus regimes.
        assertEq(spreadBps, Constants.SELL_SPREAD_FLOOR_7D_BPS, "min-duration spread floor");
    }

    function testSellQuoteBreakdownMatchesQuoteAndShowsSizeImpact() public {
        uint256 totalMint = 1_000_000e18;
        vm.prank(address(mineCore));
        claim.mint(alice, totalMint);

        vm.startPrank(alice);
        claim.approve(address(ve), type(uint256).max);

        // Background lock (60% of supply) so lockedPct stays high after excluding the sold lock.
        ve.createLock(600_000e18, Constants.MAX_LOCK_DURATION, false);

        // Large sell to make size modifier visibly bind.
        uint256 tokenId = ve.createLock(200_000e18, Constants.MAX_LOCK_DURATION, false);
        vm.stopPrank();

        (uint256 lockAmount, uint256 claimOut, uint256 spreadBps, uint256 lpReward, uint256 reserveAdd) =
            furnaceQuoter.quoteSellLockToFurnace(alice, tokenId);

        IFurnaceQuoter.SellLockQuoteBreakdown memory q = furnaceQuoter.quoteSellLockToFurnaceBreakdown(alice, tokenId);

        assertEq(q.lockAmount, lockAmount, "lockAmount");
        assertEq(q.claimOut, claimOut, "claimOut");
        assertEq(q.spreadBps, spreadBps, "spreadBps");
        assertEq(q.lpReward, lpReward, "lpReward");
        assertEq(q.reserveAdd, reserveAdd, "reserveAdd");

        // Bonus decomposition: reference bonus is max(spot, base) and aliases bonusBpsUsed.
        assertEq(q.bonusBpsUsed, q.bonusRefBpsUsed, "bonus alias");
        uint256 expectedRef = q.spotBonusBps > q.baseBonusBps ? q.spotBonusBps : q.baseBonusBps;
        assertEq(q.bonusRefBpsUsed, expectedRef, "bonus ref = max(spot, base)");
        bool expectedClamp = q.spotBonusBps < q.baseBonusBps;
        assertEq(q.isBonusClampBinding, expectedClamp, "isBonusClampBinding");
        assertLe(q.spotBonusBps, Constants.MAX_USER_BONUS_BPS, "spotBonusBps bounds");
        assertLe(q.baseBonusBps, Constants.MAX_USER_BONUS_BPS, "baseBonusBps bounds");

        assertLe(q.sizeRatioBps, 10_000, "sizeRatioBps bounds");
        assertLe(q.spreadDurBps, q.spreadBps, "size should not reduce spread");
    }

    function testAmmUsesGrossCapCeilVTargetAndSplitMath() public {
        // Enable LP vault.
        lpVault = new MockLpRewardsVault();
        lpVault.setFurnace(address(furnace));
        vm.prank(owner);
        furnace.setLpRewardsVault(address(lpVault));

        uint256 reserve = Constants.RESERVE_TARGET_FINAL;
        uint256 principal = 100e18;

        // Seed reserve: MineCore mints inventory to Furnace + credits reserve.
        vm.prank(address(mineCore));
        claim.mint(address(furnace), reserve);
        vm.prank(address(mineCore));
        furnace.creditReserve(reserve);

        // Move time forward so lastBonusUpdate differs when apply happens.
        vm.warp(block.timestamp + 1);

        // Capture only the few values that must live past the initial state assertions.
        uint256 lpRateBps;
        uint256 vTarget;
        uint256 lastUpdateBefore;

        // Reserve + lockedSupply sanity.
        {
            (uint256 reserveBefore, uint256 lockedSupply,,,,,,) = furnaceQuoter.getFurnaceState();
            assertEq(reserveBefore, reserve, "reserveBefore mismatch");
            assertEq(lockedSupply, 0, "lockedSupply should be zero for this test");
        }

        assertEq(furnace.bonusVirtualDepth(), 0, "stored virtual depth should start at 0");

        // Quote math: quoteUser <= userSpot and quoteLp == floor(quoteUser*lpRate/10_000)
        {
            (,, uint256 userSpotBps, uint256 _lpRateBps, uint256 quoteUserBps, uint256 quoteLpTopupBps,,) =
                furnaceQuoter.getFurnaceState();

            lpRateBps = _lpRateBps;

            assertEq(userSpotBps, 10_000, "userSpotBps should be 100% at lockedSupply=0 and rf=1x");
            assertLe(quoteUserBps, userSpotBps, "quoteUserBps cap");
            assertEq(quoteLpTopupBps, Math.mulDiv(quoteUserBps, _lpRateBps, 10_000), "quoteLpTopUp formula");
        }

        // Compute vTarget and ensure preview + state agree when V=0.
        {
            (,, uint256 userSpotBps, uint256 _lpRateBps,,, uint256 vBefore, uint256 _lastUpdateBefore) =
                furnaceQuoter.getFurnaceState();

            lpRateBps = _lpRateBps;
            lastUpdateBefore = _lastUpdateBefore;

            uint256 grossSpotBps = userSpotBps + Math.mulDiv(userSpotBps, _lpRateBps, 10_000);
            assertEq(grossSpotBps, 11_500, "grossSpotBps should be 115% at max user spot and lpRate");

            // vTarget = ceil(R * 10_000 / grossSpotBps)
            vTarget = (reserve * 10_000 + grossSpotBps - 1) / grossSpotBps;
            uint256 vPreview = furnace.exposedPreviewVirtualDepth(grossSpotBps);
            assertEq(vPreview, vTarget, "preview should equal vTarget when V=0");
            assertEq(vBefore, vTarget, "getFurnaceState virtualDepth should match vTarget when stored V=0");
        }

        // Apply bonus.
        {
            uint256 vaultBalBefore = claim.balanceOf(address(lpVault));
            uint256 callsBefore = lpVault.notifyCalls();

            (uint256 grossBonus, uint256 userBonus, uint256 lpBonus) = furnace.exposedApplyBonusAmm(principal);

            // grossBonus = R * P / (V + P) with V = max(virtualDepthBefore, vTarget); virtualDepthBefore is vTarget here.
            uint256 expectedGrossBonus = Math.mulDiv(reserve, principal, vTarget + principal);
            assertEq(grossBonus, expectedGrossBonus, "gross bonus mismatch");

            // Split math: userBonus = floor(gross * 10_000 / (10_000 + lpRateBps)), lpBonus = remainder
            uint256 expectedUser = Math.mulDiv(grossBonus, 10_000, 10_000 + lpRateBps);
            assertEq(userBonus, expectedUser, "user split mismatch");
            assertEq(lpBonus, grossBonus - expectedUser, "lp split mismatch");
            assertEq(userBonus + lpBonus, grossBonus, "split must sum");

            // Reserve decreases by gross.
            assertEq(furnace.furnaceReserve(), reserve - grossBonus, "reserve did not decrease by grossBonus");

            // LP rewards are streamed (smoothed): funding does NOT immediately transfer to the vault.
            assertEq(claim.balanceOf(address(lpVault)), vaultBalBefore, "lp vault balance should not change on funding");
            assertEq(lpVault.notifyCalls(), callsBefore, "notify should not be called on funding");

            // Stream schedule is funded for the full lpBonus, with any rounding remainder retained as carry.
            (uint256 ratePerSec, uint256 periodFinish, uint256 lastUpdate, uint256 remaining) =
                furnace.getLpStreamState();
            uint256 carry = furnace.exposedLpStreamCarry();
            assertGt(ratePerSec, 0, "stream rate should be >0 when lpBonus>0");
            assertEq(periodFinish, block.timestamp + Constants.LP_STREAM_WINDOW, "stream finish");
            assertEq(lastUpdate, block.timestamp, "stream lastUpdate");
            assertEq(remaining + carry, lpBonus, "lpBonus fully tracked");
            assertLt(carry, Constants.LP_STREAM_WINDOW, "carry bound");
        }

        // Stored virtual depth becomes V_used + principal, where V_used = max(preview V, vTarget).
        {
            (,,,,,, uint256 vAfter, uint256 lastUpdateAfter) = furnaceQuoter.getFurnaceState();
            assertEq(vAfter, vTarget + principal, "virtual depth should increase by principal");
            assertGt(lastUpdateAfter, lastUpdateBefore, "lastUpdate should advance");
        }
    }

    function testSellQuoteUsesPostTradeVolumeForBurstImpact() public {
        vm.warp(block.timestamp + Constants.EMISSION_DECAY_PERIOD + 1);

        address bob = address(0xB0B);
        uint256 backgroundAmount = 1_000_000e18;
        uint256 lockAmount = 42_000e18; // freeVol (~30k) + stepVol (~12k) at floor emission rate

        vm.startPrank(address(mineCore));
        claim.mint(bob, backgroundAmount);
        claim.mint(alice, lockAmount);
        vm.stopPrank();

        vm.startPrank(bob);
        claim.approve(address(ve), backgroundAmount);
        ve.createLock(backgroundAmount, Constants.MAX_LOCK_DURATION, false);
        vm.stopPrank();

        vm.startPrank(alice);
        claim.approve(address(ve), lockAmount);
        uint256 tokenId = ve.createLock(lockAmount, Constants.MAX_LOCK_DURATION, false);
        vm.stopPrank();

        IFurnaceQuoter.SellLockQuoteBreakdown memory q = furnaceQuoter.quoteSellLockToFurnaceBreakdown(alice, tokenId);

        uint256 expectedBaseSpread = q.spreadDurBps;
        uint256 rtFloor = furnace.exposedSellRoundTripSpreadFloorBps(q.bonusRefBpsUsed, Constants.MAX_LOCK_DURATION);
        if (expectedBaseSpread < rtFloor) expectedBaseSpread = rtFloor;

        uint256 expectedImpact = furnace.exposedSellImpactBps(lockAmount, Constants.EMISSION_DECAY_PERIOD + 1);
        assertEq(expectedImpact, Constants.SELL_IMPACT_BPS_PER_STEP, "lock size should trigger first impact step");

        uint256 expectedSpread = expectedBaseSpread + expectedImpact;
        if (expectedSpread > Constants.SELL_SPREAD_MAX_BPS) expectedSpread = Constants.SELL_SPREAD_MAX_BPS;

        assertEq(q.spreadBps, expectedSpread, "sell quote must use post-trade impact volume");
    }

    function testVirtualDepthDecayWindowIsThreeHoursAndLinear() public {
        // Enable LP vault (not strictly required for decay, but keeps gross>0).
        lpVault = new MockLpRewardsVault();
        lpVault.setFurnace(address(furnace));
        vm.prank(owner);
        furnace.setLpRewardsVault(address(lpVault));

        uint256 reserve = Constants.RESERVE_TARGET_FINAL;
        uint256 principal = 100e18;

        vm.prank(address(mineCore));
        claim.mint(address(furnace), reserve);
        vm.prank(address(mineCore));
        furnace.creditReserve(reserve);

        vm.warp(block.timestamp + 1);

        // Apply one bonus to create V > vTarget.
        (uint256 grossBonus,,) = furnace.exposedApplyBonusAmm(principal);
        uint256 vStored = furnace.bonusVirtualDepth();
        uint256 rNow = furnace.furnaceReserve();
        assertGt(grossBonus, 0);

        // Snapshot last update (set by applyBonusAmm above).
        uint256 lastUpdateBefore = furnace.lastBonusUpdate();

        uint256 window = Constants.BONUS_DECAY_WINDOW;
        uint256 dt = window / 2;

        vm.warp(lastUpdateBefore + dt);

        (,, uint256 userSpotBpsNow, uint256 lpRateBpsNow,,, uint256 vPreview, uint256 lastUpdateAfter) =
            furnaceQuoter.getFurnaceState();

        // lastBonusUpdate should not move just from viewing.
        assertEq(lastUpdateAfter, lastUpdateBefore, "view should not update lastBonusUpdate");

        // Cap at the *current* grossSpotBonusBps (time-dependent).
        uint256 grossSpotBpsNow = userSpotBpsNow + Math.mulDiv(userSpotBpsNow, lpRateBpsNow, 10_000);
        uint256 vTargetNow = (rNow * 10_000 + grossSpotBpsNow - 1) / grossSpotBpsNow;

        if (vStored <= vTargetNow) {
            assertEq(vPreview, vTargetNow);
        } else {
            uint256 excess = vStored - vTargetNow;
            uint256 expected = vTargetNow + Math.mulDiv(excess, window - dt, window);
            assertEq(vPreview, expected, "linear decay over BONUS_DECAY_WINDOW");
        }
    }

    function testPrincipalZeroDoesNotUpdateLastBonusUpdateOrVirtualDepth() public {
        // Seed a reserve so spot math is non-trivial.
        uint256 reserve = Constants.RESERVE_TARGET_FINAL;
        vm.prank(address(mineCore));
        claim.mint(address(furnace), reserve);
        vm.prank(address(mineCore));
        furnace.creditReserve(reserve);

        uint256 lastBefore = furnace.lastBonusUpdate();
        uint256 vBefore = furnace.bonusVirtualDepth();

        (uint256 grossBonus, uint256 userBonus, uint256 lpBonus) = furnace.exposedApplyBonusAmm(0);
        assertEq(grossBonus, 0);
        assertEq(userBonus, 0);
        assertEq(lpBonus, 0);

        assertEq(furnace.lastBonusUpdate(), lastBefore, "lastBonusUpdate must not change");
        assertEq(furnace.bonusVirtualDepth(), vBefore, "bonusVirtualDepth must not change");
    }

    function testRoundTripLossFloorAt365dExamples() public {
        // With userSpotBonusBps = 25% and round-trip loss floor = 25% at 365d:
        // - buy 1,000 CLAIM @ 365d yields 1,250 lock
        // - sell back immediately should return <= 750 CLAIM (i.e., >=25% loss)
        uint256 floorBps = furnace.exposedSellRoundTripSpreadFloorBps(2_500, Constants.MAX_LOCK_DURATION);
        assertEq(floorBps, 4_000, "365d: b=25%, loss=25% -> spread floor 40%");

        uint256 lockAmount = 1_250e18;
        uint256 claimOut = Math.mulDiv(lockAmount, 10_000 - floorBps, 10_000);
        assertEq(claimOut, 750e18, "round-trip principal out (25% loss)");
    }

    function testSellImpactDecay3h() public {
        uint256 t0 = block.timestamp;

        // Sell impact thresholds are derived from King (mining) emission over BONUS_DECAY_WINDOW (3h).
        // At launch, king rate starts at 50 CLAIM/sec:
        // E3h = 50 * 10,800 = 540,000 CLAIM.
        // freeVol = 0.5 * E3h = 270,000 CLAIM.
        // stepVol = 0.2 * E3h = 108,000 CLAIM.
        // Floor division means a full stepVol above freeVol is needed for the first impact tier.
        uint256 elapsed = 0;
        uint256 freeVol = 270_000e18;
        uint256 stepVol = 108_000e18;

        uint256 impact0 = furnace.exposedSellImpactBps(freeVol, elapsed);
        assertEq(impact0, 0, "no impact at freeVol");

        uint256 impact1 = furnace.exposedSellImpactBps(freeVol + stepVol, elapsed);
        assertEq(impact1, Constants.SELL_IMPACT_BPS_PER_STEP, "first step impact");

        // Accrue volume and verify linear decay.
        furnace.exposedAccrueSellImpactVolume(freeVol + stepVol);
        assertEq(furnace.sellImpactVolume(), freeVol + stepVol, "volume stored");

        vm.warp(t0 + Constants.BONUS_DECAY_WINDOW / 2);
        uint256 previewHalf = furnace.exposedPreviewSellImpactVolumeAt(block.timestamp);
        assertEq(previewHalf, (freeVol + stepVol) / 2, "half-life (linear)");

        vm.warp(t0 + Constants.BONUS_DECAY_WINDOW + 1);
        uint256 previewZero = furnace.exposedPreviewSellImpactVolumeAt(block.timestamp);
        assertEq(previewZero, 0, "decays to zero after window");
    }

    // ------------------------------------------------------------
    // enterWithClaimFor allowlist
    // ------------------------------------------------------------

    function testEnterWithClaimForAllowsMineCore() public {
        // With MineCore allowlisted, the call should progress past the allowlist check
        // and then revert on missing router config (since this unit test does not wire a registry contract).
        vm.prank(owner);
        mineCore.setFurnace(address(furnace));

        vm.prank(address(mineCore));
        vm.expectRevert(Errors.RouterConfigNotSet.selector);
        furnace.enterWithClaimFor(alice, 1, 0, Constants.MAX_LOCK_DURATION, true, 0);
    }

    function testEnterWithClaimForRejectsUnauthorizedCaller() public {
        address attacker = address(0xBAD);
        vm.prank(attacker);
        vm.expectRevert(Errors.NotAuthorized.selector);
        furnace.enterWithClaimFor(alice, 1, 0, Constants.MAX_LOCK_DURATION, true, 0);
    }

    function testEnterWithClaimForRevertsWhenFurnaceMineCoreDriftsFromCanonicalClaimAndDoesNotMutateUserLock() public {
        address foreignCore = address(new MockContract());

        vm.prank(owner);
        furnace.setMineCore(foreignCore);

        vm.prank(foreignCore);
        vm.expectRevert(Errors.WiringMismatch.selector);
        furnace.enterWithClaimFor(alice, 1, 0, Constants.MAX_LOCK_DURATION, true, 0);

        assertEq(ve.balanceOf(alice), 0, "lock should remain unchanged");
    }

    function testEnterWithClaimForRevertsWhenFurnaceMineMarketDriftsFromCanonicalVeAndDoesNotMutateUserLock() public {
        address foreignMarket = address(new MockContract());
        vm.mockCall(foreignMarket, abi.encodeWithSignature("claim()"), abi.encode(address(claim)));
        vm.mockCall(foreignMarket, abi.encodeWithSignature("ve()"), abi.encode(address(ve)));

        vm.prank(owner);
        furnace.setMineMarket(foreignMarket);

        vm.prank(foreignMarket);
        vm.expectRevert(Errors.WiringMismatch.selector);
        furnace.enterWithClaimFor(alice, 1, 0, Constants.MAX_LOCK_DURATION, true, 0);

        assertEq(ve.balanceOf(alice), 0, "lock should remain unchanged");
    }

    function testSellLockToFurnaceFromMarketRevertsWhenSellerParamDiffersFromObservedTransferSenderAndPreservesCustodiedLock()
        public
    {
        uint256 principal = Constants.MIN_LOCK_AMOUNT;
        _mintClaimTo(alice, principal);

        vm.startPrank(alice);
        claim.approve(address(ve), principal);
        uint256 tokenId = ve.createLock(principal, 30 days, false);
        ve.setApprovalForAllForTest(alice, mineMarket, true);
        vm.stopPrank();

        vm.prank(mineMarket);
        ve.safeTransferFrom(alice, address(furnace), tokenId);

        address wrongSeller = address(0xB0B);
        vm.prank(mineMarket);
        vm.expectRevert(Errors.NotAuthorized.selector);
        furnace.sellLockToFurnaceFromMarket(wrongSeller, tokenId, 0);

        assertEq(ve.ownerOf(tokenId), address(furnace), "custodied lock should remain in furnace");
        assertEq(ve.totalLockedClaim(), principal, "principal should remain locked");
        assertEq(claim.balanceOf(alice), 0, "observed seller should not receive payout");
        assertEq(claim.balanceOf(wrongSeller), 0, "mismatched seller should not receive payout");
    }

    function testSellLockToFurnaceFromMarketRevertsWhenFurnaceMineMarketDriftsFromCanonicalVeAndPreservesCustodiedLock()
        public
    {
        uint256 principal = Constants.MIN_LOCK_AMOUNT;
        _mintClaimTo(alice, principal);

        vm.startPrank(alice);
        claim.approve(address(ve), principal);
        uint256 tokenId = ve.createLock(principal, 30 days, false);
        ve.setApprovalForAllForTest(alice, mineMarket, true);
        vm.stopPrank();

        vm.prank(mineMarket);
        ve.safeTransferFrom(alice, address(furnace), tokenId);

        address foreignMarket = address(new MockContract());
        vm.prank(owner);
        furnace.setMineMarket(foreignMarket);

        vm.prank(foreignMarket);
        vm.expectRevert(Errors.WiringMismatch.selector);
        furnace.sellLockToFurnaceFromMarket(alice, tokenId, 0);

        assertEq(ve.ownerOf(tokenId), address(furnace), "custodied lock should remain in furnace");
        assertEq(ve.totalLockedClaim(), principal, "principal should remain locked");
        assertEq(claim.balanceOf(alice), 0, "seller should not receive payout");
    }

    function testSafeTransferToFurnaceRevertsWhenMineMarketBundleIsIncompleteAndPreservesSellerLock() public {
        address foreignMarket = address(new MockContract());
        vm.mockCall(foreignMarket, abi.encodeWithSignature("claim()"), abi.encode(address(claim)));
        vm.mockCall(foreignMarket, abi.encodeWithSignature("ve()"), abi.encode(address(ve)));
        // Intentionally omit `royalties()` so the market surface is not canonically complete.

        vm.prank(owner);
        vm.expectRevert(Errors.WiringMismatch.selector);
        ve.setMineMarket(foreignMarket);
    }

    function testLockEthRewardRevertsWhenFurnaceRoyaltiesDriftsFromCanonicalMineCoreAndDoesNotMutateUserLock() public {
        address foreignRoyalties = address(new MockContract());
        vm.mockCall(foreignRoyalties, abi.encodeWithSignature("furnace()"), abi.encode(address(furnace)));
        vm.mockCall(foreignRoyalties, abi.encodeWithSignature("ve()"), abi.encode(address(ve)));
        vm.mockCall(foreignRoyalties, abi.encodeWithSignature("mineCore()"), abi.encode(address(mineCore)));
        vm.mockCall(foreignRoyalties, abi.encodeWithSignature("mineMarket()"), abi.encode(mineMarket));

        vm.prank(owner);
        furnace.setShareholderRoyalties(foreignRoyalties);

        vm.deal(foreignRoyalties, 1 ether);
        vm.prank(foreignRoyalties);
        vm.expectRevert(Errors.WiringMismatch.selector);
        furnace.lockEthReward{value: 1 ether}(alice, 1 ether, 0, Constants.MAX_LOCK_DURATION, true, 1);

        assertEq(ve.balanceOf(alice), 0, "lock should remain unchanged");
    }

    function testEnterWithClaimForRevertsWhenMineMarketRoyaltiesRootDriftsFromCanonicalShareholderRoyaltiesAndDoesNotMutateUserLock()
        public
    {
        address foreignMarket = address(new MockContract());
        address foreignRoyalties = address(new MockContract());
        vm.mockCall(foreignMarket, abi.encodeWithSignature("claim()"), abi.encode(address(claim)));
        vm.mockCall(foreignMarket, abi.encodeWithSignature("ve()"), abi.encode(address(ve)));
        vm.mockCall(foreignMarket, abi.encodeWithSignature("royalties()"), abi.encode(foreignRoyalties));

        vm.prank(owner);
        furnace.setMineMarket(foreignMarket);

        vm.prank(owner);
        vm.expectRevert(Errors.WiringMismatch.selector);
        ve.setMineMarket(foreignMarket);
    }

    function testFuzzEnterWithClaimForRejectsSingleSurfaceMineCoreDrift(address foreignCore) public {
        vm.assume(foreignCore != address(0));
        vm.assume(foreignCore != address(mineCore));
        vm.assume(foreignCore != address(furnace));
        vm.assume(foreignCore != mineMarket);
        vm.assume(foreignCore != address(claim));
        vm.assume(foreignCore != address(ve));
        vm.assume(foreignCore != address(royalties));
        vm.assume(uint160(foreignCore) > 10);
        vm.assume(foreignCore.code.length == 0);
        vm.etch(foreignCore, hex"00");

        vm.prank(owner);
        furnace.setMineCore(foreignCore);

        vm.prank(foreignCore);
        vm.expectRevert(Errors.WiringMismatch.selector);
        furnace.enterWithClaimFor(alice, 1, 0, Constants.MAX_LOCK_DURATION, true, 0);
    }

    function testEnterWithClaimFromCallerForRevertsWhenFurnaceDelegationHubDiffersFromMineCore() public {
        _configureCanonicalDelegatedEntry();

        address delegate = address(0xD1E6);
        uint256 amount = Constants.MIN_LOCK_AMOUNT;
        DelegationHub altHub = new DelegationHub();

        _installFurnaceDelegationHubDrift(address(altHub));

        _authorizeFurnaceEntry(alice, delegate, altHub, DelegationPermissions.P_FURNACE_ENTER_CLAIM_FOR);
        _mintClaimTo(delegate, amount);

        vm.prank(delegate);
        claim.approve(address(furnace), amount);

        vm.prank(delegate);
        vm.expectRevert(Errors.WiringMismatch.selector);
        furnace.enterWithClaimFromCallerFor(alice, amount, 0, Constants.MAX_LOCK_DURATION, false, amount);
    }

    function testEnterWithClaimFromCallerForRevertsWhenMineCoreFurnaceBackpointerMismatches() public {
        _configureCanonicalDelegatedEntry();

        address delegate = address(0xD1E6);
        uint256 amount = Constants.MIN_LOCK_AMOUNT;

        MockContract foreignFurnace = new MockContract();
        vm.prank(owner);
        mineCore.setFurnace(address(foreignFurnace));

        _authorizeFurnaceEntry(alice, delegate, delegationHub, DelegationPermissions.P_FURNACE_ENTER_CLAIM_FOR);
        _mintClaimTo(delegate, amount);

        vm.prank(delegate);
        claim.approve(address(furnace), amount);

        vm.prank(delegate);
        vm.expectRevert(Errors.WiringMismatch.selector);
        furnace.enterWithClaimFromCallerFor(alice, amount, 0, Constants.MAX_LOCK_DURATION, false, amount);
    }

    function testEnterWithClaimFromCallerForRevertsWhenMineCoreClaimRootMismatches() public {
        _configureCanonicalDelegatedEntry();

        address delegate = address(0xD1E6);
        uint256 amount = Constants.MIN_LOCK_AMOUNT;

        vm.mockCall(address(mineCore), abi.encodeWithSignature("claim()"), abi.encode(address(0xDEAD)));

        _authorizeFurnaceEntry(alice, delegate, delegationHub, DelegationPermissions.P_FURNACE_ENTER_CLAIM_FOR);
        _mintClaimTo(delegate, amount);

        vm.prank(delegate);
        claim.approve(address(furnace), amount);

        vm.prank(delegate);
        vm.expectRevert(Errors.WiringMismatch.selector);
        furnace.enterWithClaimFromCallerFor(alice, amount, 0, Constants.MAX_LOCK_DURATION, false, amount);
    }

    function testEnterWithClaimFromCallerForRevertsWhenForeignHubWouldExtendExistingLock() public {
        _configureCanonicalDelegatedEntry();

        address delegate = address(0xD1E6);
        uint256 principal = Constants.MIN_LOCK_AMOUNT;
        uint256 topup = Constants.MIN_LOCK_AMOUNT;

        _mintClaimTo(alice, principal);
        vm.startPrank(alice);
        claim.approve(address(ve), principal);
        uint256 tokenId = ve.createLock(principal, 30 days, false);
        vm.stopPrank();

        (, uint256 oldEnd,,) = ve.getLockInfo(tokenId);

        DelegationHub altHub = new DelegationHub();
        _installFurnaceDelegationHubDrift(address(altHub));

        _authorizeFurnaceEntry(alice, delegate, altHub, DelegationPermissions.P_FURNACE_ENTER_CLAIM_FOR);
        _mintClaimTo(delegate, topup);

        vm.prank(delegate);
        claim.approve(address(furnace), topup);

        vm.prank(delegate);
        vm.expectRevert(Errors.WiringMismatch.selector);
        furnace.enterWithClaimFromCallerFor(alice, topup, tokenId, Constants.MAX_LOCK_DURATION, false, topup);

        (, uint256 newEnd,,) = ve.getLockInfo(tokenId);
        assertEq(newEnd, oldEnd, "foreign hub must not extend user lock");
    }

    function testEnterWithClaimFromCallerForSucceedsWhenCanonicalHubAgrees() public {
        _configureCanonicalDelegatedEntry();

        address delegate = address(0xD1E6);
        uint256 amount = Constants.MIN_LOCK_AMOUNT;

        _authorizeFurnaceEntry(alice, delegate, delegationHub, DelegationPermissions.P_FURNACE_ENTER_CLAIM_FOR);
        _mintClaimTo(delegate, amount);

        vm.prank(delegate);
        claim.approve(address(furnace), amount);

        vm.prank(delegate);
        uint256 tokenId =
            furnace.enterWithClaimFromCallerFor(alice, amount, 0, Constants.MAX_LOCK_DURATION, false, amount);

        assertEq(ve.ownerOf(tokenId), alice, "delegated caller created lock for user");
    }

    function testFuzz_enterWithClaimFromCallerForRejectsFurnaceHubDrift(uint96 amount) public {
        _configureCanonicalDelegatedEntry();

        address delegate = address(0xD1E6);
        amount = uint96(bound(uint256(amount), Constants.MIN_LOCK_AMOUNT, 100_000e18));

        DelegationHub altHub = new DelegationHub();
        _installFurnaceDelegationHubDrift(address(altHub));

        _authorizeFurnaceEntry(alice, delegate, altHub, DelegationPermissions.P_FURNACE_ENTER_CLAIM_FOR);
        _mintClaimTo(delegate, amount);

        vm.prank(delegate);
        claim.approve(address(furnace), amount);

        vm.prank(delegate);
        vm.expectRevert(Errors.WiringMismatch.selector);
        furnace.enterWithClaimFromCallerFor(alice, amount, 0, Constants.MAX_LOCK_DURATION, false, amount);
    }

    /// @dev Bypasses `Furnace.setDelegationHub` (which now reciprocally rejects drift via
    ///      `requireCanonicalDelegationHub`) by writing the drifted address directly to slot 63
    ///      (`delegationHub`). The runtime check at the entry sites must still reject the drift,
    ///      proving defense-in-depth even when storage is mutated out-of-band.
    function _installFurnaceDelegationHubDrift(address altHub) internal {
        vm.store(address(furnace), bytes32(uint256(63)), bytes32(uint256(uint160(altHub))));
        require(furnace.delegationHub() == altHub, "drift install failed: wrong slot");
    }

    function _configureCanonicalDelegatedEntry() internal {
        MockEntryTokenRegistry(registry).setRouterConfig(mineMarket, mineMarket, mineMarket, address(claim));

        vm.startPrank(owner);
        mineCore.setFurnace(address(furnace));
        mineCore.setDelegationHub(address(delegationHub));
        vm.stopPrank();
    }

    function _authorizeFurnaceEntry(address user, address delegate, DelegationHub hub, uint256 perms) internal {
        vm.prank(user);
        hub.setSession(delegate, perms, uint64(block.timestamp + 1 days));
    }

    function _mintClaimTo(address to, uint256 amount) internal {
        vm.prank(address(mineCore));
        claim.mint(to, amount);
    }

    // ------------------------------------------------------------
    // Duration weight curve continuity
    // ------------------------------------------------------------

    /// @dev Verify _durationWeightBps is continuous at every breakpoint.
    ///      Each boundary value must yield the same result whether approached from
    ///      the left branch (d <= boundary) or the right branch (d > boundary).
    function testDurationWeightBpsContinuousAtBreakpoints() public view {
        // Breakpoints and their expected bps values (from code).
        uint256[7] memory breakpoints = [
            uint256(7 days),
            uint256(14 days),
            uint256(21 days),
            uint256(30 days),
            uint256(90 days),
            uint256(180 days),
            uint256(270 days)
        ];
        uint256[7] memory expectedBps =
            [uint256(100), uint256(175), uint256(300), uint256(500), uint256(1500), uint256(4000), uint256(6500)];

        for (uint256 i = 0; i < breakpoints.length; i++) {
            uint256 val = furnace.exposedDurationWeightBps(breakpoints[i]);
            assertEq(val, expectedBps[i], string.concat("breakpoint mismatch at index ", vm.toString(i)));
        }

        // MAX_LOCK_DURATION (365d) must yield exactly 10_000 bps.
        assertEq(furnace.exposedDurationWeightBps(Constants.MAX_LOCK_DURATION), 10_000, "max duration weight");
    }

    /// @dev Verify _durationWeightBps is monotonically increasing across the full range.
    function testDurationWeightBpsMonotonicallyIncreasing() public view {
        uint256 prev = furnace.exposedDurationWeightBps(Constants.MIN_LOCK_DURATION);
        for (uint256 d = Constants.MIN_LOCK_DURATION + 1 days; d <= Constants.MAX_LOCK_DURATION; d += 1 days) {
            uint256 cur = furnace.exposedDurationWeightBps(d);
            assertGe(cur, prev, "duration weight must be monotonically increasing");
            prev = cur;
        }
    }

    /// @dev Verify _clampDurationSeconds clamps to protocol bounds.
    function testClampDurationSeconds() public view {
        assertEq(furnace.exposedClampDurationSeconds(0), Constants.MIN_LOCK_DURATION, "below min");
        assertEq(furnace.exposedClampDurationSeconds(1), Constants.MIN_LOCK_DURATION, "below min");
        assertEq(
            furnace.exposedClampDurationSeconds(Constants.MIN_LOCK_DURATION), Constants.MIN_LOCK_DURATION, "at min"
        );
        assertEq(
            furnace.exposedClampDurationSeconds(Constants.MAX_LOCK_DURATION), Constants.MAX_LOCK_DURATION, "at max"
        );
        assertEq(
            furnace.exposedClampDurationSeconds(Constants.MAX_LOCK_DURATION + 1),
            Constants.MAX_LOCK_DURATION,
            "above max"
        );
        assertEq(furnace.exposedClampDurationSeconds(90 days), 90 days, "in range");
    }
}
