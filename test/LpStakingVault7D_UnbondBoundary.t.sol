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

/// @notice Wired regression tests for unbond boundary and
///         matured-withdrawal timing edge cases in LpStakingVault7D.
contract LpStakingVault7D_UnbondBoundaryTest is Test {
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

        // Fund Alice with LP tokens.
        uint256 aliceLp = 200e18;
        lp.mint(alice, aliceLp);
        vm.prank(alice);
        lp.approve(address(vault), type(uint256).max);
    }

    /// @dev Withdraw at exactly unlockTime (boundary, inclusive) must succeed.
    function test_withdrawMaturedExactlyAtUnlockTime() public {
        // Alice stakes 100e18 LP.
        vm.prank(alice);
        vault.stake(100e18);

        // Alice begins unbonding 50e18.
        vm.prank(alice);
        vault.beginUnbond(50e18);

        // Record the unlock time.
        (,, uint256 unlockTime) = vault.getUnbondByIndex(alice, 0);

        // Warp to exactly unlockTime.
        vm.warp(unlockTime);

        uint256 balBefore = lp.balanceOf(alice);

        vm.prank(alice);
        vault.withdrawMatured();

        uint256 balAfter = lp.balanceOf(alice);

        // Alice receives 50e18 LP.
        assertEq(balAfter - balBefore, 50e18, "should receive unbonded LP at exact unlockTime");
        // Unbond entry is removed.
        assertEq(vault.getUnbondCount(alice), 0, "unbond entry should be removed");
    }

    /// @dev Withdraw one second before unlockTime must leave entry intact.
    function test_withdrawMaturedOneSecondBeforeUnlockTime() public {
        vm.prank(alice);
        vault.stake(100e18);

        vm.prank(alice);
        vault.beginUnbond(50e18);

        (,, uint256 unlockTime) = vault.getUnbondByIndex(alice, 0);

        // Warp to one second before unlockTime.
        vm.warp(unlockTime - 1);

        uint256 balBefore = lp.balanceOf(alice);

        vm.prank(alice);
        vault.withdrawMatured();

        uint256 balAfter = lp.balanceOf(alice);

        // Alice receives 0 LP.
        assertEq(balAfter - balBefore, 0, "should receive 0 LP before unlockTime");
        // Unbond entry is still present.
        assertEq(vault.getUnbondCount(alice), 1, "unbond entry should still exist");
    }

    /// @dev After hitting MAX_UNBONDS_PER_USER, maturing one entry and
    ///      withdrawing it must free a slot for a new beginUnbond.
    function test_maxUnbondSlotFreedAfterWithdrawal() public {
        uint256 maxUnbonds = Constants.MAX_UNBONDS_PER_USER; // 25
        uint256 totalNeeded = (maxUnbonds + 1) * 1e18;

        // Give Alice more LP if needed.
        if (lp.balanceOf(alice) < totalNeeded) {
            lp.mint(alice, totalNeeded - lp.balanceOf(alice));
        }

        // Stake enough for MAX+1 unbonds.
        vm.prank(alice);
        vault.stake(totalNeeded);

        // Create MAX_UNBONDS_PER_USER unbonds of 1e18 each.
        for (uint256 i = 0; i < maxUnbonds; i++) {
            vm.prank(alice);
            vault.beginUnbond(1e18);
        }

        assertEq(vault.getUnbondCount(alice), maxUnbonds, "should have MAX unbonds");

        // Attempt #(MAX+1) must revert with TooManyUnbonds.
        vm.prank(alice);
        vm.expectRevert(Errors.TooManyUnbonds.selector);
        vault.beginUnbond(1e18);

        // Warp past the first unlock to mature at least one entry.
        (,, uint256 firstUnlockTime) = vault.getUnbondByIndex(alice, 0);
        vm.warp(firstUnlockTime + 1);

        vm.prank(alice);
        vault.withdrawMatured();

        // At least one slot freed (could be more if all have same unlockTime).
        assertTrue(vault.getUnbondCount(alice) < maxUnbonds, "should have freed slots");

        // Now a new beginUnbond(1e18) succeeds.
        vm.prank(alice);
        vault.beginUnbond(1e18);
    }
}
