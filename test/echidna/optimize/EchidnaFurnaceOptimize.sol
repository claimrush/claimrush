// SPDX-License-Identifier: MIT
pragma solidity ^0.8.34;

import {EchidnaSetup} from "../EchidnaSetup.sol";
import {Constants} from "src/lib/Constants.sol";

/// @title Furnace economic worst-case search.
/// @notice Optimization-mode harness. Each `optimize_*` function returns an
///         `int256` that Echidna maximizes over its sequence search. Positive
///         values indicate a deviation from the intended economic envelope and
///         must be triaged. Zero and negative values are within tolerance.
/// @dev    Mirrors the action set of `EchidnaFurnace` for state coverage.
///         Properties (`echidna_*`) are intentionally absent — assertion and
///         property mode live in the standard harness suite. This file exists
///         to drive the fuzzer toward the worst observed extraction across a
///         multi-call sequence rather than to assert a specific bound.
///
///         Run with:
///           echidna test/echidna/optimize/EchidnaFurnaceOptimize.sol \
///             --contract EchidnaFurnaceOptimize \
///             --config echidna-optimize.yaml
contract EchidnaFurnaceOptimize is EchidnaSetup {
    int256 internal worstReserveDrainPerPrincipalBps;
    int256 internal worstBonusBpsAboveCap;
    int256 internal worstQuoteExecuteAbsDelta;
    int256 internal worstBalanceDeficit;

    constructor() payable {
        _deployAndWire();
    }

    // ================================================================
    // Actions — drive state changes for the optimizer
    // ================================================================

    function action_takeover() public payable {
        uint256 price = mineCore.getCurrentTakeoverPrice();
        if (msg.value < price) return;
        try mineCore.takeover{value: price}(type(uint256).max) {} catch {}
    }

    function action_enterWithClaim(uint256 amount, uint256 durationSeconds) public {
        if (amount < Constants.MIN_LOCK_AMOUNT) amount = Constants.MIN_LOCK_AMOUNT;
        if (amount > 10_000_000e18) amount = 10_000_000e18;
        if (durationSeconds < Constants.MIN_LOCK_DURATION) durationSeconds = Constants.MIN_LOCK_DURATION;
        if (durationSeconds > Constants.MAX_LOCK_DURATION) durationSeconds = Constants.MAX_LOCK_DURATION;

        if (claim.balanceOf(msg.sender) < amount) return;

        uint256 reserveBefore = furnace.furnaceReserve();
        uint256 quotedVe = 0;
        try quoter.quoteEnterWithClaim(msg.sender, amount, 0, durationSeconds, false) returns (
            uint256, uint256, uint256 q, uint256
        ) {
            quotedVe = q;
        } catch {}

        uint256 veBefore = ve.veBalanceOf(msg.sender);
        try furnace.enterWithClaim(amount, 0, durationSeconds, false, 0) returns (uint256) {
            uint256 reserveAfter = furnace.furnaceReserve();
            if (reserveBefore > reserveAfter) {
                _recordReserveDrainPerPrincipal(reserveBefore - reserveAfter, amount);
            }
            uint256 veDelta = ve.veBalanceOf(msg.sender) - veBefore;
            _recordQuoteExecuteAbsDelta(quotedVe, veDelta);
        } catch {}
    }

    function action_enterWithEth(uint256 durationSeconds) public payable {
        if (msg.value == 0) return;
        if (durationSeconds < Constants.MIN_LOCK_DURATION) durationSeconds = Constants.MIN_LOCK_DURATION;
        if (durationSeconds > Constants.MAX_LOCK_DURATION) durationSeconds = Constants.MAX_LOCK_DURATION;

        uint256 reserveBefore = furnace.furnaceReserve();
        try furnace.enterWithEth{value: msg.value}(0, durationSeconds, false, 0) returns (uint256) {
            uint256 reserveAfter = furnace.furnaceReserve();
            // ETH→CLAIM swap landed in the reserve; estimate principal as the
            // post-call reserve credit by treating msg.value as the upper bound
            // proxy. The drain ratio is bonus-out vs principal-in.
            if (reserveBefore > reserveAfter) {
                _recordReserveDrainPerPrincipal(reserveBefore - reserveAfter, msg.value);
            }
        } catch {}
    }

    function action_extendWithBonus(uint256 tokenId, uint256 newDuration) public {
        if (tokenId == 0) return;
        if (newDuration < Constants.MIN_LOCK_DURATION) newDuration = Constants.MIN_LOCK_DURATION;
        if (newDuration > Constants.MAX_LOCK_DURATION) newDuration = Constants.MAX_LOCK_DURATION;

        // For extend we have no fresh principal; use the lock's current
        // amount as the denominator for the drain-ratio calculation.
        uint256 lockedAmount = _safeLockedAmount(tokenId);
        uint256 reserveBefore = furnace.furnaceReserve();
        try furnace.extendWithBonus(tokenId, newDuration, 0) {
            uint256 reserveAfter = furnace.furnaceReserve();
            if (reserveBefore > reserveAfter && lockedAmount > 0) {
                _recordReserveDrainPerPrincipal(reserveBefore - reserveAfter, lockedAmount);
            }
        } catch {}
    }

    function action_claimAutoMaxBonus(uint256 tokenId) public {
        uint256 lockedAmount = _safeLockedAmount(tokenId);
        uint256 reserveBefore = furnace.furnaceReserve();
        try furnace.claimAutoMaxBonus(tokenId) {
            uint256 reserveAfter = furnace.furnaceReserve();
            if (reserveBefore > reserveAfter && lockedAmount > 0) {
                _recordReserveDrainPerPrincipal(reserveBefore - reserveAfter, lockedAmount);
            }
        } catch {}
    }

    function _safeLockedAmount(uint256 tokenId) internal view returns (uint256) {
        try ve.getLockInfo(tokenId) returns (uint256 amount, uint256, bool, bool) {
            return amount;
        } catch {
            return 0;
        }
    }

    function action_observeBonusBps(uint256 userBonusBps, uint256 lpTopupBps) public {
        if (userBonusBps > Constants.MAX_USER_BONUS_BPS) userBonusBps = Constants.MAX_USER_BONUS_BPS;
        if (lpTopupBps > Constants.LP_TOPUP_RATE_MAX_BPS) lpTopupBps = Constants.LP_TOPUP_RATE_MAX_BPS;
        try quoter.grossSpotBonusBps(userBonusBps, lpTopupBps) returns (uint256 grossBps) {
            int256 above = int256(grossBps) - int256(uint256(Constants.MAX_GROSS_BONUS_BPS));
            if (above > worstBonusBpsAboveCap) worstBonusBpsAboveCap = above;
        } catch {}
    }

    function action_observeBalanceDeficit() public {
        uint256 reserve = furnace.furnaceReserve();
        uint256 lpRemaining = furnace.getLpStreamRemaining();
        uint256 bal = claim.balanceOf(address(furnace));
        int256 deficit = int256(reserve + lpRemaining) - int256(bal);
        if (deficit > worstBalanceDeficit) worstBalanceDeficit = deficit;
    }

    // ================================================================
    // Optimization targets — Echidna maximizes these
    // ================================================================

    /// @notice Worst observed reserve drain expressed in bps of the principal
    ///         that drove it (drain * 10_000 / principal). Bonus payouts are
    ///         expected up to `MAX_GROSS_BONUS_BPS`. Values above that cap
    ///         indicate bonus-overdraft on the bonus-AMM side.
    function optimize_furnace_reserveDrainPerPrincipalBpsAboveCap() public view returns (int256) {
        return worstReserveDrainPerPrincipalBps - int256(uint256(Constants.MAX_GROSS_BONUS_BPS));
    }

    /// @notice Largest observed `grossSpotBonusBps` above the protocol cap.
    ///         Must remain `<= 0`.
    function optimize_furnace_bonusBpsAboveCap() public view returns (int256) {
        return worstBonusBpsAboveCap;
    }

    /// @notice Largest observed absolute delta between the quoted ve weight
    ///         and the executed ve weight. Bounded by sub-bp rounding under M2.
    function optimize_furnace_quoteExecuteAbsDelta() public view returns (int256) {
        return worstQuoteExecuteAbsDelta;
    }

    /// @notice Largest observed shortfall of `claim.balanceOf(furnace)` against
    ///         `furnaceReserve + lpStreamRemaining`. Must remain `<= 0`.
    function optimize_furnace_balanceDeficit() public view returns (int256) {
        return worstBalanceDeficit;
    }

    // ================================================================
    // Internal recorders
    // ================================================================

    function _recordReserveDrainPerPrincipal(uint256 drainWei, uint256 principalWei) internal {
        if (principalWei == 0) return;
        // Bonus envelope is bps-of-principal; track the worst observed ratio.
        uint256 ratioBps = (drainWei * 10_000) / principalWei;
        int256 r = int256(ratioBps);
        if (r > worstReserveDrainPerPrincipalBps) worstReserveDrainPerPrincipalBps = r;
    }

    function _recordQuoteExecuteAbsDelta(uint256 quoted, uint256 actual) internal {
        uint256 absDelta = quoted >= actual ? quoted - actual : actual - quoted;
        int256 abs = int256(absDelta);
        if (abs > worstQuoteExecuteAbsDelta) worstQuoteExecuteAbsDelta = abs;
    }
}
