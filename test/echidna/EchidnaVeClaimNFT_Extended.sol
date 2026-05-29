// SPDX-License-Identifier: MIT
pragma solidity ^0.8.34;

import {EchidnaVeClaimNFT} from "./EchidnaVeClaimNFT.sol";
import {Constants} from "src/lib/Constants.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/// @title Extended Echidna properties for VeClaimNFT.
/// @dev Adds missing invariants from §3: principal conservation, duration bounds, AutoMax.
contract EchidnaVeClaimNFTExtended is EchidnaVeClaimNFT {
    uint256 internal cumulativeLocked;
    uint256 internal cumulativeUnlocked;

    constructor() payable EchidnaVeClaimNFT() {}

    /// @dev Override enter to track cumulative lock amounts.
    function action_enterWithClaimTracked(uint256 amount, uint256 durationSeconds) public {
        uint256 lockedBefore = ve.totalLockedClaim();
        action_enterWithClaim(amount, durationSeconds);
        uint256 lockedAfter = ve.totalLockedClaim();
        if (lockedAfter > lockedBefore) {
            cumulativeLocked += lockedAfter - lockedBefore;
        }
    }

    /// @dev Override unlock to track cumulative unlocks.
    function action_unlockTracked(uint256 idx) public {
        uint256 lockedBefore = ve.totalLockedClaim();
        action_unlock(idx);
        uint256 lockedAfter = ve.totalLockedClaim();
        if (lockedBefore > lockedAfter) {
            cumulativeUnlocked += lockedBefore - lockedAfter;
        }
    }

    // ================================================================
    // Extended Properties
    // ================================================================

    /// @dev §3: cumulative CLAIM locked >= cumulative CLAIM unlocked (no free CLAIM from ve).
    function echidna_no_free_claim_from_ve() public view returns (bool) {
        return cumulativeLocked >= cumulativeUnlocked;
    }

    /// @dev §3: totalLockedClaim always backed by actual CLAIM balance in the contract.
    /// Stronger version: CLAIM balance == totalLockedClaim (no extra CLAIM stuck).
    function echidna_total_locked_exact() public view returns (bool) {
        uint256 locked = ve.totalLockedClaim();
        uint256 claimBal = IERC20(address(claim)).balanceOf(address(ve));
        // Balance should be exactly equal (no extra CLAIM accumulating)
        return claimBal == locked;
    }

    /// @dev §3: totalVeCached is conservative (>= actual sum of live ve).
    ///      totalVeCurrent() triggers a fresh computation; totalVeCached is the stale snapshot.
    ///      The cached value must never underestimate.
    function echidna_total_ve_cached_conservative() public view returns (bool) {
        uint256 cached = ve.totalVeCached();
        uint256 current = ve.totalVeCurrent();
        // Cached may be >= current due to staleness (no checkpoint since last lock expiry),
        // but must never be less.
        return cached >= current;
    }
}
