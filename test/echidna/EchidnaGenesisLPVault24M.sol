// SPDX-License-Identifier: MIT
pragma solidity ^0.8.34;

import {GenesisLPVault24M} from "src/vault/GenesisLPVault24M.sol";
import {MockERC20} from "../mocks/MockERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/// @title Echidna harness for GenesisLPVault24M time-lock custody invariants.
/// @dev Spec: docs/spec/vault-spec.md. The harness is set as `lpWithdrawRecipient` so it can
///      exercise extendLock / withdrawLp / rescueEth positively. Unauthorized-caller tests are
///      covered by Foundry; Echidna focuses on state-machine and custody invariants.
///
/// @dev Corpus-bounding rationale (2026-05-06 rework):
///      Earlier revisions accepted `uint256 amount` and `uint256 newUnlockTime`
///      arguments. Both were clamped to small ranges immediately on entry
///      (`amount <= 10_000_000e18` ≈ 84 bits, `newUnlockTime <= now + 24mo`
///      ≈ 32 bits), so the high bits of the input had no effect on the
///      contract under test. Echidna's coverage tracker, however, treated
///      every distinct 256-bit input as a candidate corpus entry: at
///      assertion-mode saturation (cov:2878) the corpus kept growing with
///      equivalent sequences, eventually OOM-killing the worker process at
///      24/30 GB after 5–10 h. Narrowing to `uint96 amount` and
///      `uint64 newUnlockTime` collapses the input space to the value
///      ranges that actually exercise distinct branches, while remaining
///      well above any meaningful upper bound (uint96 max ≈ 7.9e28 wei,
///      uint64 max ≈ 1.8e19 seconds). The `_clamp_*` helpers keep the
///      old clamp logic intact for safety, since callers can still
///      submit the smaller-type max value.
contract EchidnaGenesisLPVault24M {
    GenesisLPVault24M internal vault;
    MockERC20 internal lpToken;

    // Ghost state
    uint256 internal ghostLockStart;
    uint256 internal ghostUnlockTime;
    uint256 internal ghostLpLocked;
    bool internal seenLockStarted;
    bool internal seenWithdrawn;

    // Immutable snapshot
    address internal immPool;
    address internal immRecipient;

    constructor() payable {
        lpToken = new MockERC20("Aero WETH/CLAIM LP", "AERO-LP");
        vault = new GenesisLPVault24M(address(lpToken), address(this));
        immPool = vault.pool();
        immRecipient = vault.lpWithdrawRecipient();
    }

    // ================================================================
    // Actions
    // ================================================================

    /// @dev Transfer LP to the vault from the harness. Mimics genesis LP deposit or
    ///      post-withdraw residual transfer. Bounded to avoid runaway mints.
    ///      `uint96` keeps the corpus search space at ~80 bits; uint96 max
    ///      ≈ 7.9e28 wei ≫ the 1e25 wei (10M LP token) clamp.
    function action_depositLp(uint96 amount) public {
        uint256 amt = uint256(amount);
        if (amt == 0) amt = vault.MIN_LP_LOCK();
        if (amt > 10_000_000e18) amt = 10_000_000e18;
        lpToken.mint(address(this), amt);
        require(lpToken.transfer(address(vault), amt), "lp transfer");
    }

    /// @dev Permissionless in the contract; harness as msg.sender works for the one-shot lock.
    function action_startLock() public {
        try vault.startLock() {
            seenLockStarted = true;
            ghostLockStart = vault.lockStartTime();
            ghostLpLocked = vault.lpLockedAmount();
            ghostUnlockTime = vault.unlockTime();
        } catch {}
    }

    /// @dev Recipient-only. Harness IS the recipient. Bounds mirror the contract's checks
    ///      so the try has a reasonable chance of success.
    ///      `uint64` keeps the corpus search space at 64 bits; uint64 max
    ///      ≈ 1.8e19 seconds ≫ any reachable `block.timestamp + MAX_EXTENSION`.
    function action_extendLock(uint64 newUnlockTime) public {
        uint256 target = uint256(newUnlockTime);
        uint256 minTarget = block.timestamp + vault.MIN_EXTENSION_DURATION();
        uint256 maxTarget = block.timestamp + vault.MAX_EXTENSION();
        if (target < minTarget) target = minTarget;
        if (target > maxTarget) target = maxTarget;
        try vault.extendLock(target) {
            ghostUnlockTime = vault.unlockTime();
        } catch {}
    }

    /// @dev Recipient-only. Success path after unlockTime is reached.
    function action_withdrawLp() public {
        try vault.withdrawLp() {
            seenWithdrawn = true;
        } catch {}
    }

    /// @dev Recipient-only ETH rescue. Without a force-fund path (selfdestruct), this will
    ///      always revert with NoTokenToRescue -- still exercised to confirm no misrouting.
    function action_rescueEth() public {
        try vault.rescueEth() {} catch {}
    }

    // ================================================================
    // Properties (MUST always return true)
    // ================================================================

    /// @dev Immutables pinned at construction never change.
    function echidna_immutables_preserved() public view returns (bool) {
        return vault.pool() == immPool && vault.lpWithdrawRecipient() == immRecipient;
    }

    /// @dev lockStartTime is zero pre-lock; once set, it never changes (one-shot).
    function echidna_lock_start_monotonic() public view returns (bool) {
        if (!seenLockStarted) return vault.lockStartTime() == 0;
        return vault.lockStartTime() == ghostLockStart;
    }

    /// @dev lpLockedAmount is the genesis-time LP snapshot -- frozen after startLock.
    function echidna_lp_locked_amount_immutable_after_lock() public view returns (bool) {
        if (!seenLockStarted) return vault.lpLockedAmount() == 0;
        return vault.lpLockedAmount() == ghostLpLocked;
    }

    /// @dev unlockTime never decreases except to 0 after withdrawLp completes.
    function echidna_unlock_time_monotonic() public view returns (bool) {
        uint256 current = vault.unlockTime();
        if (!seenLockStarted) return current == 0;
        if (current == 0) return seenWithdrawn;
        return current >= ghostUnlockTime;
    }

    /// @dev While the lock is active and the unlock instant has not arrived, the vault must
    ///      still hold the full locked LP snapshot. (After unlock, withdraw may have run.)
    function echidna_custody_during_lock() public view returns (bool) {
        uint256 start = vault.lockStartTime();
        uint256 unlock = vault.unlockTime();
        if (start == 0 || unlock == 0) return true;
        if (block.timestamp >= unlock) return true;
        return lpToken.balanceOf(address(vault)) >= vault.lpLockedAmount();
    }

    /// @dev Absolute-lock ceiling: unlockTime must never exceed lockStartTime + MAX_ABSOLUTE_LOCK.
    function echidna_max_absolute_lock() public view returns (bool) {
        uint256 start = vault.lockStartTime();
        uint256 unlock = vault.unlockTime();
        if (start == 0 || unlock == 0) return true;
        return unlock <= start + vault.MAX_ABSOLUTE_LOCK();
    }

    /// @dev Initial lock duration is always >= INITIAL_LOCK_DURATION when first set
    ///      (subsequent extends can only increase).
    function echidna_initial_duration_respected() public view returns (bool) {
        if (!seenLockStarted) return true;
        uint256 current = vault.unlockTime();
        if (current == 0) return true;
        return current >= ghostLockStart + vault.INITIAL_LOCK_DURATION();
    }
}
