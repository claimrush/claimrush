// SPDX-License-Identifier: MIT
pragma solidity ^0.8.34;

import {Test} from "forge-std/Test.sol";

import {ClaimToken} from "src/ClaimToken.sol";
import {MineCore} from "src/MineCore.sol";
import {ShareholderRoyalties} from "src/ShareholderRoyalties.sol";
import {Constants} from "src/lib/Constants.sol";
import {Errors} from "src/lib/Errors.sol";

import {FurnaceHarness} from "../mocks/FurnaceHarness.sol";
import {FurnaceQuoter} from "src/FurnaceQuoter.sol";
import {MockVe} from "../mocks/MockVe.sol";
import {MockLpRewardsVault} from "../mocks/MockLpRewardsVault.sol";

/// @notice Stateful fuzz for Furnace reserve + LP overflow drip + bonus AMM routing.
/// @dev This focuses on "balance sheet" safety:
///      - furnaceReserve must always be covered by the Furnace's CLAIM balance
///      - all minted CLAIM must remain within {Furnace, lpRewardsVault} in this harness
///      - update cursors must be monotonic
contract FurnaceReserveStateMachineInvariants is Test {
    ClaimToken internal claim;
    MockVe internal ve;
    ShareholderRoyalties internal royalties;
    MineCore internal mineCore;
    FurnaceHarness internal furnace;
    MockLpRewardsVault internal lpVault;

    address internal owner;

    uint256 internal lastBonusUpdate;
    uint256 internal lastDripUpdate;

    function setUp() public {
        vm.txGasPrice(0);

        owner = makeAddr("owner");

        ve = new MockVe();
        claim = new ClaimToken(owner);
        royalties = new ShareholderRoyalties(address(ve), owner);
        mineCore = new MineCore(address(claim), address(ve), address(royalties), owner);
        furnace = new FurnaceHarness(address(claim), address(ve), owner);
        FurnaceQuoter quoter = new FurnaceQuoter(address(furnace));
        lpVault = new MockLpRewardsVault();
        lpVault.setFurnace(address(furnace));

        // Wiring
        vm.startPrank(owner);
        claim.setMineCore(address(mineCore));
        furnace.setMineCore(address(mineCore));
        furnace.setFurnaceQuoter(address(quoter));
        furnace.setLpRewardsVault(address(lpVault));
        mineCore.setFurnace(address(furnace));
        vm.etch(address(0xB0B0), hex"00");
        royalties.setWiring(address(mineCore), address(0xB0B0), address(furnace));
        vm.stopPrank();

        // Locked supply seed influences bonus curve.
        ve.setTotalLockedClaim(5_000_000e18);

        // Jump forward to the drip-enabled regime.
        uint256 start = mineCore.emissionStartTime();
        vm.warp(start + Constants.LP_OVERFLOW_DRIP_START + Constants.LP_OVERFLOW_DRIP_RAMP + 1);

        // Seed reserve safely above the final target so dripping is possible.
        _creditReserve(Constants.RESERVE_TARGET_FINAL + 50_000_000e18);

        lastBonusUpdate = furnace.lastBonusUpdate();
        lastDripUpdate = furnace.lastLpOverflowDripUpdate();
    }

    function testFuzz_stateMachine_reserveAlwaysBackedAndNoClaimLeak(uint256 seed) public {
        uint256 steps = 16;

        for (uint256 i = 0; i < steps; i++) {
            bytes32 h = keccak256(abi.encode(seed, i));
            _advanceTime(h);

            uint8 action = uint8(uint256(h) % 4);
            if (action == 0) {
                _creditReserve(_randAmount(h, 2_000_000e18));
            } else if (action == 1) {
                _applyBonus(_randAmount(h, 1_000_000e18));
            } else if (action == 2) {
                furnace.tick();
            } else {
                // noop
            }

            _assertInvariants();
        }

        _assertInvariants();
    }

    function testFuzz_lpStreamCarryIsNeverLostAcrossSuccessiveFundings(uint256 first, uint256 second) public {
        first = bound(first, 1, Constants.LP_STREAM_WINDOW * 4);
        second = bound(second, 1, Constants.LP_STREAM_WINDOW * 4);
        uint256 total = first + second;

        vm.prank(address(mineCore));
        claim.mint(address(furnace), total);

        furnace.exposedFundLpStream(first);
        assertEq(furnace.exposedLpStreamLiability(), first, "first funding liability");

        furnace.exposedFundLpStream(second);
        assertEq(furnace.exposedLpStreamLiability(), total, "successive funding liability");
        assertLt(furnace.exposedLpStreamCarry(), Constants.LP_STREAM_WINDOW, "carry bound");
    }

    function testFuzz_syncReserveClampCountsLpStreamCarry(uint256 reserve, uint256 carry, uint256 loss) public {
        reserve = bound(reserve, 1e18, 1_000_000e18);
        carry = bound(carry, 1, Constants.LP_STREAM_WINDOW - 1);
        loss = bound(loss, 1, carry);

        uint256 reserveBefore = furnace.furnaceReserve();
        _creditReserve(reserve);

        vm.prank(address(mineCore));
        claim.mint(address(furnace), carry);
        furnace.exposedFundLpStream(carry);

        vm.prank(address(furnace));
        assertTrue(claim.transfer(address(lpVault), loss), "loss transfer");

        furnace.exposedSyncFurnaceReserve();
        assertEq(furnace.furnaceReserve(), reserveBefore + reserve - loss, "reserve clamp includes carry");
        _assertInvariants();
    }

    function testFuzz_lpStreamLiabilityCountsMaturedButUnaccruedSchedule(uint256 amount, uint256 dt) public {
        amount = bound(amount, 1, Constants.LP_STREAM_WINDOW * 4);
        dt = bound(dt, 0, Constants.LP_STREAM_WINDOW * 2);

        vm.prank(address(mineCore));
        claim.mint(address(furnace), amount);
        furnace.exposedFundLpStream(amount);

        if (dt != 0) vm.warp(block.timestamp + dt);

        assertEq(
            furnace.exposedLpStreamLiability(),
            amount,
            "parked LP stream liability must persist until accrual transfers it out"
        );
        _assertInvariants();
    }

    function testFuzz_pendingOverflowDripLiabilityBlocksVaultRewire(uint256 dt) public {
        dt = bound(dt, 1 hours, 30 days);

        MockLpRewardsVault newVault = new MockLpRewardsVault();
        newVault.setFurnace(address(furnace));

        vm.warp(block.timestamp + dt);
        assertGt(furnace.exposedPendingLpOverflowDripLiability(), 0, "pending overflow drip liability");

        vm.prank(owner);
        vm.expectRevert(Errors.LpRewardsStreamActive.selector);
        furnace.setLpRewardsVault(address(newVault));
    }

    function testFuzz_setLpRewardsVaultRejectsAnyVeRootMismatch(address badVe) public {
        vm.assume(badVe != address(0));
        vm.assume(badVe != address(ve));

        MockLpRewardsVault badVault = new MockLpRewardsVault();
        badVault.setFurnace(address(furnace));
        badVault.setVeOverride(badVe);

        vm.prank(owner);
        vm.expectRevert(Errors.WiringMismatch.selector);
        furnace.setLpRewardsVault(address(badVault));
    }

    // ------------------------------------------------------------
    // Actions
    // ------------------------------------------------------------

    function _advanceTime(bytes32 h) internal {
        uint256 dt = uint256(uint16(uint256(h >> 240))) % 10 days;
        if (dt != 0) vm.warp(block.timestamp + dt);
    }

    function _randAmount(bytes32 h, uint256 max) internal pure returns (uint256) {
        return (uint256(h) % max) + 1;
    }

    function _creditReserve(uint256 amount) internal {
        vm.prank(address(mineCore));
        claim.mint(address(furnace), amount);

        vm.prank(address(mineCore));
        furnace.creditReserve(amount);
    }

    function _applyBonus(uint256 principal) internal {
        // Only meaningful when there's some reserve.
        if (furnace.furnaceReserve() == 0) return;
        furnace.exposedApplyBonusAmm(principal);
    }

    // ------------------------------------------------------------
    // Invariants
    // ------------------------------------------------------------

    function _assertInvariants() internal {
        // 1) Reserve must always be covered by the Furnace's CLAIM balance.
        assertLe(furnace.furnaceReserve(), claim.balanceOf(address(furnace)), "reserve not backed");

        // 1b) LP stream liabilities (scheduled + carry dust) are also funded from the Furnace balance.
        uint256 liab = furnace.furnaceReserve() + furnace.exposedLpStreamLiability();
        assertLe(liab, claim.balanceOf(address(furnace)), "reserve+stream not backed");

        // 2) In this harness, CLAIM can only exist in {furnace, lpVault}.
        uint256 sum = claim.balanceOf(address(furnace)) + claim.balanceOf(address(lpVault));
        assertEq(claim.totalSupply(), sum, "CLAIM leaked outside harness");

        // 3) Update cursors are monotonic.
        uint256 b = furnace.lastBonusUpdate();
        uint256 d = furnace.lastLpOverflowDripUpdate();
        assertGe(b, lastBonusUpdate, "lastBonusUpdate decreased");
        assertGe(d, lastDripUpdate, "lastLpOverflowDripUpdate decreased");
        lastBonusUpdate = b;
        lastDripUpdate = d;
    }
}
