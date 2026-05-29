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

/// @notice claimRewardsAndLock input-validation edge cases.
contract LpStakingVault7D_ClaimAndLockInputValidation_Test is Test {
    MockAerodromePool internal lp;
    MockERC20 internal weth;
    MockERC20 internal claim;
    MockFurnaceLpRewards internal furnace;
    MockVe internal ve;
    MockAerodromeRouter internal router;
    LpStakingVault7D internal vault;

    address internal factory = address(0xFACA);
    address internal alice = address(0xA11CE);

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

        lp.mint(alice, 100e18);
        vm.startPrank(alice);
        lp.approve(address(vault), type(uint256).max);
        vault.stake(100e18);
        vm.stopPrank();

        ve.setOwner(1, alice);
        ve.setLockInfo(1, 1e18, block.timestamp + 90 days, false, false);
    }

    function _fundRewards(uint256 amount) internal {
        claim.mint(address(vault), amount);
        vm.prank(address(furnace));
        vault.notifyRewards(0);

        vm.warp(block.timestamp + 1 days + 1);
    }

    function test_claimRewardsAndLock_revertsWhenMinVeOutZero() public {
        _fundRewards(2_000e18);

        vm.prank(alice);
        vm.expectRevert(Errors.MinVeOutRequired.selector);
        vault.claimRewardsAndLock(0, 30 days, false, 0);

        assertEq(furnace.enterCalls(), 0, "must revert before Furnace call");
        assertEq(vault.lastCompoundTs(alice), 0, "cooldown must not advance on validation revert");
    }

    function test_claimRewardsAndLock_revertsWhenDurationBelowMin() public {
        _fundRewards(2_000e18);

        vm.prank(alice);
        vm.expectRevert(Errors.InvalidDuration.selector);
        vault.claimRewardsAndLock(0, Constants.MIN_LOCK_DURATION - 1, false, 1);

        assertEq(furnace.enterCalls(), 0, "must revert before Furnace call");
        assertEq(vault.lastCompoundTs(alice), 0, "cooldown must not advance on validation revert");
    }

    function test_claimRewardsAndLock_revertsWhenDurationAboveMax() public {
        _fundRewards(2_000e18);

        vm.prank(alice);
        vm.expectRevert(Errors.InvalidDuration.selector);
        vault.claimRewardsAndLock(0, Constants.MAX_LOCK_DURATION + 1, false, 1);

        assertEq(furnace.enterCalls(), 0, "must revert before Furnace call");
        assertEq(vault.lastCompoundTs(alice), 0, "cooldown must not advance on validation revert");
    }

    function test_claimRewardsAndLock_revertsWhenCreateAutoMaxTargetsExistingLock() public {
        _fundRewards(2_000e18);

        vm.prank(alice);
        vm.expectRevert(Errors.AutoMaxMismatch.selector);
        vault.claimRewardsAndLock(1, Constants.MAX_LOCK_DURATION, true, 1);

        assertEq(furnace.enterCalls(), 0, "must revert before Furnace call");
        assertEq(vault.lastCompoundTs(alice), 0, "cooldown must not advance on validation revert");
    }

    function test_claimRewardsAndLock_revertsWhenCreateAutoMaxUsesNonMaxDuration() public {
        _fundRewards(2_000e18);

        vm.prank(alice);
        vm.expectRevert(Errors.InvalidDuration.selector);
        vault.claimRewardsAndLock(0, 30 days, true, 1);

        assertEq(furnace.enterCalls(), 0, "must revert before Furnace call");
        assertEq(vault.lastCompoundTs(alice), 0, "cooldown must not advance on validation revert");
    }

    function test_claimRewardsAndLock_revertsWhenCreateAutoMaxUsesClampedHighDuration() public {
        _fundRewards(2_000e18);

        vm.prank(alice);
        vm.expectRevert(Errors.InvalidDuration.selector);
        vault.claimRewardsAndLock(0, Constants.MAX_LOCK_DURATION + 1, true, 1);

        assertEq(furnace.enterCalls(), 0, "must revert before Furnace call");
        assertEq(vault.lastCompoundTs(alice), 0, "cooldown must not advance on validation revert");
    }

    function test_claimRewardsAndLock_allowsStandardValidLockPath() public {
        _fundRewards(2_000e18);
        furnace.setQuote(2_000e18, 0, 1, 0);

        vm.prank(alice);
        vault.claimRewardsAndLock(0, 30 days, false, 1);

        assertEq(furnace.enterCalls(), 1, "valid standard path should reach Furnace");
        assertEq(furnace.lastUser(), alice);
        assertEq(furnace.lastClaimIn(), 2_000e18);
        assertEq(furnace.lastDurationSeconds(), 30 days);
        assertEq(furnace.lastMinVeOut(), 1);
        assertEq(vault.lastUserLockTs(alice), block.timestamp, "successful lock updates cooldown");
    }

    function test_claimRewardsAndLock_allowsCreateAutoMaxOnlyForNewMaxLock() public {
        _fundRewards(2_000e18);
        furnace.setQuote(2_000e18, 0, 1, 0);

        vm.prank(alice);
        vault.claimRewardsAndLock(0, Constants.MAX_LOCK_DURATION, true, 1);

        assertEq(furnace.enterCalls(), 1, "valid createAutoMax path should reach Furnace");
        assertEq(furnace.lastUser(), alice);
        assertEq(furnace.lastClaimIn(), 2_000e18);
        assertEq(furnace.lastDurationSeconds(), Constants.MAX_LOCK_DURATION);
        assertEq(vault.lastUserLockTs(alice), block.timestamp, "successful lock updates cooldown");
    }
}
