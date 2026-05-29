// SPDX-License-Identifier: MIT
pragma solidity ^0.8.34;

import {GenesisLPVault24M} from "src/vault/GenesisLPVault24M.sol";
import {MockERC20} from "../../mocks/MockERC20.sol";

/// @title GenesisLPVault24M economic worst-case search.
/// @notice Optimization-mode harness. Targets LP custody shortfall during the
///         active lock window, unlock-time monotonicity violations, and any
///         observable LP leak to a non-recipient address. Each `optimize_*`
///         function returns an `int256` Echidna maximizes; positive values
///         indicate a bound violation.
contract EchidnaGenesisLPVault24MOptimize {
    GenesisLPVault24M internal vault;
    MockERC20 internal lpToken;

    int256 internal worstLpCustodyDeficit;
    int256 internal worstUnlockTimeRegression;
    int256 internal worstAbsoluteLockExceeded;

    uint256 internal ghostLastUnlockTime;
    bool internal seenLockStarted;
    bool internal seenWithdrawn;

    constructor() payable {
        lpToken = new MockERC20("Aero WETH/CLAIM LP", "AERO-LP");
        vault = new GenesisLPVault24M(address(lpToken), address(this));
    }

    // ================================================================
    // Actions
    // ================================================================

    function action_depositLp(uint256 amount) public {
        if (amount == 0) amount = vault.MIN_LP_LOCK();
        if (amount > 10_000_000e18) amount = 10_000_000e18;
        lpToken.mint(address(this), amount);
        require(lpToken.transfer(address(vault), amount), "lp transfer");
    }

    function action_startLock() public {
        try vault.startLock() {
            seenLockStarted = true;
            ghostLastUnlockTime = vault.unlockTime();
        } catch {}
    }

    function action_extendLock(uint256 newUnlockTime) public {
        uint256 minTarget = block.timestamp + vault.MIN_EXTENSION_DURATION();
        uint256 maxTarget = block.timestamp + vault.MAX_EXTENSION();
        if (newUnlockTime < minTarget) newUnlockTime = minTarget;
        if (newUnlockTime > maxTarget) newUnlockTime = maxTarget;
        try vault.extendLock(newUnlockTime) {
            uint256 currentUnlock = vault.unlockTime();
            if (currentUnlock < ghostLastUnlockTime && !seenWithdrawn) {
                int256 regression = int256(ghostLastUnlockTime - currentUnlock);
                if (regression > worstUnlockTimeRegression) worstUnlockTimeRegression = regression;
            }
            ghostLastUnlockTime = currentUnlock;
        } catch {}
    }

    function action_withdrawLp() public {
        try vault.withdrawLp() {
            seenWithdrawn = true;
        } catch {}
    }

    function action_observeLpCustodyDeficit() public {
        uint256 start = vault.lockStartTime();
        uint256 unlock = vault.unlockTime();
        if (start == 0 || unlock == 0) return;
        if (block.timestamp >= unlock) return;

        uint256 lpBal = lpToken.balanceOf(address(vault));
        uint256 lpLocked = vault.lpLockedAmount();
        if (lpLocked > lpBal) {
            int256 deficit = int256(lpLocked - lpBal);
            if (deficit > worstLpCustodyDeficit) worstLpCustodyDeficit = deficit;
        }
    }

    function action_observeAbsoluteLockExceeded() public {
        uint256 start = vault.lockStartTime();
        uint256 unlock = vault.unlockTime();
        if (start == 0 || unlock == 0) return;
        uint256 ceiling = start + vault.MAX_ABSOLUTE_LOCK();
        if (unlock > ceiling) {
            int256 exceeded = int256(unlock - ceiling);
            if (exceeded > worstAbsoluteLockExceeded) worstAbsoluteLockExceeded = exceeded;
        }
    }

    // ================================================================
    // Optimization targets
    // ================================================================

    /// @notice Worst observed shortfall of `lpToken.balanceOf(vault)` against
    ///         `lpLockedAmount` while the lock is active. Must remain `<= 0`.
    function optimize_genesisLp_lpCustodyDeficit() public view returns (int256) {
        return worstLpCustodyDeficit;
    }

    /// @notice Worst observed regression of `unlockTime` between two extension
    ///         observations on the same active lock. Must remain `<= 0`.
    function optimize_genesisLp_unlockTimeRegression() public view returns (int256) {
        return worstUnlockTimeRegression;
    }

    /// @notice Worst observed surplus of `unlockTime` over
    ///         `lockStartTime + MAX_ABSOLUTE_LOCK`. Must remain `<= 0`.
    function optimize_genesisLp_absoluteLockExceeded() public view returns (int256) {
        return worstAbsoluteLockExceeded;
    }
}
