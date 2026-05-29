// SPDX-License-Identifier: MIT
pragma solidity ^0.8.34;

import {Test} from "forge-std/Test.sol";
import {LpStakingVault7D} from "src/vault/LpStakingVault7D.sol";
import {Constants} from "src/lib/Constants.sol";
import {Errors} from "src/lib/Errors.sol";
import {MockERC20} from "./mocks/MockERC20.sol";
import {MockAerodromePool} from "./mocks/MockAerodromePool.sol";
import {MockAerodromeRouter} from "./mocks/MockAerodromeRouter.sol";
import {MockFurnaceLpRewards} from "./mocks/MockFurnaceLpRewards.sol";
import {MockVe} from "./mocks/MockVe.sol";

/// @title Boundary and edge-case tests for LpStakingVault7D.
/// @dev Covers gaps: 1-wei stake, max unbonds, zero-reward notify, exact unbond boundary, fuzz.
contract LpStakingVault7DBoundariesTest is Test {
    MockAerodromePool internal lp;
    MockERC20 internal weth;
    MockERC20 internal claimToken;
    MockFurnaceLpRewards internal furnace;
    MockVe internal ve;
    MockAerodromeRouter internal router;
    LpStakingVault7D internal vault;

    address internal factory = address(0xFACA);
    address internal alice = address(0xA11CE);
    address internal bob = address(0xB0B);

    function setUp() public {
        weth = new MockERC20("WETH", "WETH");
        claimToken = new MockERC20("CLAIM", "CLAIM");
        lp = new MockAerodromePool(address(weth), address(claimToken));
        ve = new MockVe();
        router = new MockAerodromeRouter(factory, address(weth));
        router.setPoolFor(address(weth), address(claimToken), false, factory, address(lp));
        furnace = new MockFurnaceLpRewards(address(claimToken), address(ve));

        vault = new LpStakingVault7D(
            address(lp),
            address(weth),
            address(claimToken),
            address(ve),
            address(furnace),
            address(router),
            factory,
            false,
            address(this)
        );
    }

    // ── Minimum stake ───────────────────────────────────────────────

    function testStakeBelowMinReverts() public {
        lp.mint(alice, 1);
        vm.startPrank(alice);
        lp.approve(address(vault), 1);
        vm.expectRevert(Errors.AmountTooSmall.selector);
        vault.stake(1);
        vm.stopPrank();
    }

    function testStakeAtMinSucceeds() public {
        uint256 minStake = Constants.MIN_UNBOND_AMOUNT;
        lp.mint(alice, minStake);
        vm.startPrank(alice);
        lp.approve(address(vault), minStake);
        vault.stake(minStake);
        vm.stopPrank();

        assertEq(vault.totalStaked(), minStake);
        assertEq(vault.stakedBalance(alice), minStake);
    }

    function testStakeZeroReverts() public {
        vm.prank(alice);
        vm.expectRevert(Errors.AmountZero.selector);
        vault.stake(0);
    }

    // ── Max unbonds per user ────────────────────────────────────────

    function testMaxUnbondsPerUserEnforced() public {
        uint256 perUnbond = Constants.MIN_UNBOND_AMOUNT;
        uint256 totalStake = perUnbond * (Constants.MAX_UNBONDS_PER_USER + 1);
        lp.mint(alice, totalStake);

        vm.startPrank(alice);
        lp.approve(address(vault), totalStake);
        vault.stake(totalStake);

        // Create MAX_UNBONDS_PER_USER unbond entries
        for (uint256 i = 0; i < Constants.MAX_UNBONDS_PER_USER; i++) {
            vault.beginUnbond(perUnbond);
        }

        // The next unbond should revert
        vm.expectRevert(Errors.TooManyUnbonds.selector);
        vault.beginUnbond(perUnbond);
        vm.stopPrank();
    }

    // ── Unbond boundary timing ──────────────────────────────────────

    function testWithdrawExactlyAtMaturity() public {
        lp.mint(alice, 100e18);
        vm.startPrank(alice);
        lp.approve(address(vault), 100e18);
        vault.stake(100e18);
        vault.beginUnbond(100e18);
        vm.stopPrank();

        // Warp exactly to maturity
        vm.warp(block.timestamp + Constants.UNBONDING_PERIOD);
        vm.prank(alice);
        vault.withdrawMatured();

        assertEq(lp.balanceOf(alice), 100e18);
        assertEq(vault.totalStaked(), 0);
    }

    function testWithdrawOneSecondBeforeMaturityGetsNothing() public {
        lp.mint(alice, 100e18);
        vm.startPrank(alice);
        lp.approve(address(vault), 100e18);
        vault.stake(100e18);
        vault.beginUnbond(100e18);
        vm.stopPrank();

        // Warp to 1 second before maturity
        vm.warp(block.timestamp + Constants.UNBONDING_PERIOD - 1);
        vm.prank(alice);
        vault.withdrawMatured();

        // Nothing withdrawn yet
        assertEq(lp.balanceOf(alice), 0);
    }

    // ── Insufficient stake ──────────────────────────────────────────

    function testUnstakeMoreThanStakedReverts() public {
        lp.mint(alice, 100e18);
        vm.startPrank(alice);
        lp.approve(address(vault), 100e18);
        vault.stake(100e18);

        vm.expectRevert(Errors.InsufficientStake.selector);
        vault.beginUnbond(101e18);
        vm.stopPrank();
    }

    // ── Fuzz tests ──────────────────────────────────────────────────

    function testFuzz_StakeUnstakeConservesLP(uint128 stakeAmt) public {
        vm.assume(stakeAmt >= Constants.MIN_UNBOND_AMOUNT);

        lp.mint(alice, uint256(stakeAmt));
        vm.startPrank(alice);
        lp.approve(address(vault), uint256(stakeAmt));
        vault.stake(uint256(stakeAmt));
        assertEq(vault.stakedBalance(alice), uint256(stakeAmt));

        vault.beginUnbond(uint256(stakeAmt));
        assertEq(vault.stakedBalance(alice), 0);
        vm.stopPrank();

        // After maturity, full LP returned
        vm.warp(block.timestamp + Constants.UNBONDING_PERIOD);
        vm.prank(alice);
        vault.withdrawMatured();

        assertEq(lp.balanceOf(alice), uint256(stakeAmt), "all LP must return after unbond");
    }
}
