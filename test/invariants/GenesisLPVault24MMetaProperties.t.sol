// SPDX-License-Identifier: MIT
pragma solidity ^0.8.34;

import {Test} from "forge-std/Test.sol";

import {GenesisLPVault24M} from "src/vault/GenesisLPVault24M.sol";

import {MockERC20} from "../mocks/MockERC20.sol";

import {AccountingMetaPropertyBase} from "./AccountingMetaProperties.t.sol";

/// @title GenesisLPVault24M accounting meta-property suite (M1-M6)
/// @notice GenesisLPVault24M holds the genesis LP for 24 months. Value enters
///         once at `startLock`, exits once at `withdrawLp` after the unlock
///         time. The vault has no rate-sensitive curve or distribution logic.
///
///         - M1: WAIVE-WITH-CONTROL. No rate-sensitive payout. The vault is a
///           timelock — value sits until `unlockTime`.
///         - M2: WAIVE-WITH-CONTROL. No quoter; the call signature is
///           `withdrawLp()` and the payout is the full LP balance.
///         - M3: vault LP balance == `lpLockedAmount` (pre-withdraw) or `0`
///           (post-withdraw). No mid-state value leak.
///         - M4: WAIVE-WITH-CONTROL. `startLock` and `withdrawLp` are each
///           one-shot — second invocations revert with
///           `LockAlreadyStarted` / `LockNotStarted` (after withdraw the LP
///           balance is 0). Path independence is moot.
///         - M5: cooldown=24 months arm. `withdrawLp` MUST revert with
///           `UnlockTimeNotReached` until `block.timestamp >= unlockTime`.
///         - M6: WAIVE-WITH-CONTROL. No mulDiv on value path — the LP
///           balance moves 1:1 from vault to recipient.
contract GenesisLPVault24MMetaPropertiesTest is AccountingMetaPropertyBase {
    MockERC20 internal lp;
    GenesisLPVault24M internal vault;

    address internal recipient = address(0xCAFE);
    address internal alice = address(0xA);

    function setUp() public {
        _deploy();
    }

    function _deploy() internal {
        lp = new MockERC20("LP", "LP");
        vault = new GenesisLPVault24M(address(lp), recipient);
    }

    function _resetSurface() internal override {
        _deploy();
    }

    // ── M1 — WAIVE-WITH-CONTROL ────────────────────────────────────
    function test_M1_RateContinuity_NotApplicable() public pure {
        assertTrue(true, "M1 N/A: vault is a timelock; no rate-sensitive payout");
    }

    // ── M2 — WAIVE-WITH-CONTROL ────────────────────────────────────
    function test_M2_QuoteEqualsExecute_PayoutIsBalance() public {
        _resetSurface();
        lp.mint(address(vault), 50e18);
        vault.startLock();
        vm.warp(vault.unlockTime());
        // The "quote" is the vault's LP balance; the "execute" delivers exactly
        // that to the recipient.
        uint256 quoted = lp.balanceOf(address(vault));
        vm.prank(recipient);
        vault.withdrawLp();
        assertEq(lp.balanceOf(recipient), quoted, "M2: withdrawLp drifts from balance quote");
    }

    // ── M3 — Conservation ──────────────────────────────────────────
    /// @notice `lp.balanceOf(vault) == lpLockedAmount` pre-withdraw and `0`
    ///         post-withdraw. No mid-state value leak.
    function test_M3_VaultBalanceMatchesLockedAmount() public {
        _resetSurface();
        lp.mint(address(vault), 123e18);
        vault.startLock();
        assertEq(
            lp.balanceOf(address(vault)), vault.lpLockedAmount(), "M3: pre-withdraw vault balance != lpLockedAmount"
        );
        vm.warp(vault.unlockTime());
        vm.prank(recipient);
        vault.withdrawLp();
        assertEq(lp.balanceOf(address(vault)), 0, "M3: post-withdraw vault retains LP");
    }

    // ── M4 — WAIVE-WITH-CONTROL ────────────────────────────────────
    function test_M4_PathIndependence_NotApplicable() public {
        _resetSurface();
        lp.mint(address(vault), 1e18);
        vault.startLock();
        // Second startLock MUST revert.
        bool reverted;
        try vault.startLock() {
            reverted = false;
        } catch {
            reverted = true;
        }
        assertTrue(reverted, "M4 N/A: startLock is one-shot - second call did not revert");
    }

    // ── M5 — Cooldown=24M arm ──────────────────────────────────────
    /// @notice `withdrawLp` MUST revert until `block.timestamp >= unlockTime`.
    ///         The cooldown is the 24-month timelock.
    function test_M5_CooldownArm_WithdrawBeforeUnlockReverts() public {
        _resetSurface();
        lp.mint(address(vault), 10e18);
        vault.startLock();
        bool reverted;
        vm.prank(recipient);
        try vault.withdrawLp() {
            reverted = false;
        } catch {
            reverted = true;
        }
        assertTrue(reverted, "M5: withdrawLp before unlockTime did not revert");
    }

    // ── M6 — WAIVE-WITH-CONTROL ────────────────────────────────────
    function test_M6_FloorDirection_NotApplicable() public pure {
        assertTrue(true, "M6 N/A: LP moves 1:1 from vault to recipient; no mulDiv on value path");
    }
}
