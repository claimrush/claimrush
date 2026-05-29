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

/// @notice Regression tests for reward-carry accounting and queued reward
///         distribution edge cases.
contract LpStakingVault7DRewardCarryTest is Test {
    MockAerodromePool internal lp;
    MockERC20 internal weth;
    MockERC20 internal claim;
    MockFurnaceLpRewards internal furnace;
    MockVe internal ve;
    MockAerodromeRouter internal router;
    LpStakingVault7D internal vault;

    address internal factory = address(0xFACA);
    address internal alice = address(0xA11CE);
    address internal bob = address(0xB0B);

    function setUp() public {
        weth = new MockERC20("WETH", "WETH");
        claim = new MockERC20("CLAIM", "CLAIM");
        lp = new MockAerodromePool(address(weth), address(claim));
        ve = new MockVe();
        router = new MockAerodromeRouter(factory, address(weth));
        router.setPoolFor(address(weth), address(claim), false, factory, address(lp));
        furnace = new MockFurnaceLpRewards(address(claim), address(ve));

        vault = new LpStakingVault7D(
            address(lp),
            address(weth),
            address(claim),
            address(ve),
            address(furnace),
            address(router),
            factory,
            false,
            address(this)
        );
    }

    // Queued rewards distribute correctly on first stake.
    function testQueuedRewardsDistributeOnFirstStake() public {
        // Fund rewards while nobody is staked => queued.
        claim.mint(address(vault), 500e18);
        vm.prank(address(furnace));
        vault.notifyRewards(0);

        assertEq(vault.queuedRewards(), 500e18);
        assertEq(vault.totalStaked(), 0);

        // Alice stakes — queued rewards should be distributed.
        lp.mint(alice, 100e18);
        vm.startPrank(alice);
        lp.approve(address(vault), type(uint256).max);
        vault.stake(100e18);
        vm.stopPrank();

        // All queued rewards should now be indexed.
        assertEq(vault.queuedRewards(), 0);
        assertEq(vault.earned(alice), 500e18);
    }

    // Rounding remainder carry: tiny notify does not strand CLAIM.
    function testTinyNotifyCarriesRemainder() public {
        // Stake a large amount so rptIncrement rounds to 0 for small amounts.
        lp.mint(alice, type(uint128).max);
        vm.startPrank(alice);
        lp.approve(address(vault), type(uint256).max);
        vault.stake(type(uint128).max);
        vm.stopPrank();

        // Notify 1 wei of CLAIM — rptIncrement should be 0, carried to queued.
        claim.mint(address(vault), 1);
        vm.prank(address(furnace));
        vault.notifyRewards(0);

        // Must not be lost: carried into queuedRewards.
        assertEq(vault.queuedRewards(), 1);
    }

    // Balance-delta checkpoint before stake prevents dilution.
    function testCheckpointBeforeStakePreventsDilution() public {
        lp.mint(alice, 100e18);
        vm.startPrank(alice);
        lp.approve(address(vault), type(uint256).max);
        vault.stake(100e18);
        vm.stopPrank();

        // Furnace transfers CLAIM but notify reverts (simulated: just transfer).
        claim.mint(address(vault), 1000e18);

        // Bob stakes after unnotified CLAIM arrives.
        lp.mint(bob, 100e18);
        vm.startPrank(bob);
        lp.approve(address(vault), type(uint256).max);
        vault.stake(100e18);
        vm.stopPrank();

        // Alice should have earned the 1000e18 (checkpoint runs before Bob's
        // stake changes totalStaked).
        assertEq(vault.earned(alice), 1000e18);
        assertEq(vault.earned(bob), 0);
    }
}
