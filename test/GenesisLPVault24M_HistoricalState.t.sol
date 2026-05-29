// SPDX-License-Identifier: MIT
pragma solidity ^0.8.34;

import {Test} from "forge-std/Test.sol";

import {GenesisLPVault24M} from "src/vault/GenesisLPVault24M.sol";
import {MockERC20} from "./mocks/MockERC20.sol";

/// @notice regression tests for GenesisLPVault24M historical state semantics.
contract GenesisLPVault24M_HistoricalStateTest is Test {
    MockERC20 internal lp;
    GenesisLPVault24M internal vault;

    address internal recipient = address(0xCAFE);

    function setUp() public {
        lp = new MockERC20("LP", "LP");
        vault = new GenesisLPVault24M(address(lp), recipient);
    }

    function test_withdrawLp_preservesOriginalLpLockedAmountSnapshot() public {
        uint256 initialLocked = 42e18;
        lp.mint(address(vault), initialLocked);
        vault.startLock();

        vm.warp(vault.unlockTime());
        vm.prank(recipient);
        vault.withdrawLp();

        assertEq(lp.balanceOf(recipient), initialLocked, "recipient receives the locked LP");
        assertEq(vault.lpLockedAmount(), initialLocked, "historical snapshot must remain readable");
        assertEq(vault.unlockTime(), 0, "withdraw sentinel still clears unlockTime");
    }

    function test_postWithdrawResidualSweep_keepsOriginalSnapshot() public {
        uint256 initialLocked = 7e18;
        lp.mint(address(vault), initialLocked);
        vault.startLock();

        vm.warp(vault.unlockTime());
        vm.prank(recipient);
        vault.withdrawLp();

        uint256 donatedAfterWithdraw = 3e18;
        lp.mint(address(vault), donatedAfterWithdraw);
        vm.prank(recipient);
        vault.withdrawLp();

        assertEq(lp.balanceOf(recipient), initialLocked + donatedAfterWithdraw, "recipient receives residual sweep");
        assertEq(vault.lpLockedAmount(), initialLocked, "residual sweep must not overwrite genesis snapshot");
    }
}
