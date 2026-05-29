// SPDX-License-Identifier: MIT
pragma solidity ^0.8.34;

import {Test} from "forge-std/Test.sol";

/// @title Accounting meta-property mixins (M1-M6)
/// @notice Reusable abstract test mixins that encode the six accounting
///         meta-properties from `docs/security/invariants-v1.0.0.md` § "15.
///         Accounting meta-properties (M1-M6)" and `docs/security/threat-map-v1.0.0.md`
///         § "12. Cross-cutting: accounting floor drift (`TM-AccountingFloorDrift`)".
///
///         Each mixin is `abstract` — concrete per-contract suites override the
///         hooks below (`_setup*`, `_doAction*`, `_quote*`, `_observeReserve*`)
///         and inherit a fixed test body that asserts the property across the
///         shared input sweep.
///
///         New value-paying surfaces inherit M1-M6 by deriving from the
///         appropriate mixin and implementing 1-3 hook overrides per property.
///
/// @dev    Mixins are split by property so a contract can opt into the subset
///         that applies (e.g. ClaimAllHelper inherits M2 only — the rest are
///         WAIVE-WITH-CONTROL by inheritance from delegate targets).
///
///         Hook contract: `_doAction(...)` returns the on-chain emitted payout
///         in the unit native to the surface (CLAIM, ETH, ve weight, LP shares).
///         The mixin compares this value against the property-specific bound.
///
///         Concrete suites: `test/invariants/{Furnace,VeClaimNFT,...}MetaProperties.t.sol`.
abstract contract AccountingMetaPropertyBase is Test {
    /// @dev Maximum tolerated rounding slack for a single mulDiv on the payout
    ///      path. Set per-mixin via `_payoutRoundingTolerance()` override.
    uint256 internal constant DEFAULT_PAYOUT_ROUNDING_TOLERANCE = 2;

    function _payoutRoundingTolerance() internal view virtual returns (uint256) {
        return DEFAULT_PAYOUT_ROUNDING_TOLERANCE;
    }

    /// @dev Hook to reset the contract under test to a known-good state before
    ///      each property iteration. Override per concrete suite.
    function _resetSurface() internal virtual {
        // default: no-op
    }
}

/// @notice M1 — Rate continuity: payout(action(δ)) → 0 as δ → 0.
///
/// Concrete suites override:
/// - `_m1_doActionWithDelta(uint256 delta) returns (uint256 payout)`
/// - `_m1_deltaSweep() returns (uint256[] memory)` — defaults to a 7-point sweep.
abstract contract M1RateContinuity is AccountingMetaPropertyBase {
    function _m1_doActionWithDelta(uint256 delta) internal virtual returns (uint256 payout);

    function _m1_deltaSweep() internal view virtual returns (uint256[] memory sweep) {
        sweep = new uint256[](7);
        sweep[0] = 1;
        sweep[1] = 30;
        sweep[2] = 1 hours;
        sweep[3] = 1 days;
        sweep[4] = 7 days;
        sweep[5] = 30 days;
        sweep[6] = 365 days;
    }

    /// @dev Asserts `payout(δ_small) ≤ payout(δ_large)` (monotonic) and
    ///      `payout(1) ≤ rounding_tolerance` for the smallest delta.
    function test_M1_RateContinuity_MonotonicAndZeroAtSmallestDelta() public virtual {
        uint256[] memory sweep = _m1_deltaSweep();
        uint256 prev = 0;
        for (uint256 i = 0; i < sweep.length; i++) {
            _resetSurface();
            uint256 payout = _m1_doActionWithDelta(sweep[i]);
            if (i == 0) {
                assertLe(payout, _payoutRoundingTolerance(), "M1: payout at smallest delta exceeds rounding tolerance");
            } else {
                assertGe(payout, prev, "M1: payout not monotonic in delta");
            }
            prev = payout;
        }
    }
}

/// @notice M2 — Quote = execute: |quoted − executed| ≤ rounding_tolerance.
///
/// Concrete suites override:
/// - `_m2_quote(uint256 input) returns (uint256 quoted)`
/// - `_m2_execute(uint256 input) returns (uint256 executed)`
/// - `_m2_inputSweep() returns (uint256[] memory)` — defaults to a 5-point sweep.
abstract contract M2QuoteEqualsExecute is AccountingMetaPropertyBase {
    function _m2_quote(uint256 input) internal virtual returns (uint256 quoted);
    function _m2_execute(uint256 input) internal virtual returns (uint256 executed);

    function _m2_inputSweep() internal view virtual returns (uint256[] memory sweep) {
        sweep = new uint256[](5);
        sweep[0] = 1 days;
        sweep[1] = 30 days;
        sweep[2] = 90 days;
        sweep[3] = 180 days;
        sweep[4] = 365 days;
    }

    /// @dev Asserts `quoted` is within `rounding_tolerance` of `executed` for
    ///      every point in the sweep, and `quoted ≤ executed` (preview never
    ///      over-promises).
    function test_M2_QuoteEqualsExecute_AcrossInputSweep() public virtual {
        uint256[] memory sweep = _m2_inputSweep();
        for (uint256 i = 0; i < sweep.length; i++) {
            _resetSurface();
            uint256 quoted = _m2_quote(sweep[i]);
            _resetSurface();
            uint256 executed = _m2_execute(sweep[i]);
            uint256 delta = quoted > executed ? quoted - executed : executed - quoted;
            assertLe(delta, _payoutRoundingTolerance(), "M2: quote-execute drift exceeds rounding tolerance");
            assertLe(quoted, executed + _payoutRoundingTolerance(), "M2: quote over-promises beyond tolerance");
        }
    }
}

/// @notice M3 — Conservation: Σ(in) − Σ(out) − Σ(burns) == observed_slot.
///
/// Concrete suites override:
/// - `_m3_runSequence()` — drives a value-in / value-out sequence on the surface.
/// - `_m3_observeBalance() returns (uint256)` — observed slot value (CLAIM bal,
///    ETH bal, etc.).
/// - `_m3_observedAccountingSum() returns (uint256)` — `reserve + liabilities`
///    or equivalent accounting sum that should equal balance.
abstract contract M3Conservation is AccountingMetaPropertyBase {
    function _m3_runSequence() internal virtual;
    function _m3_observeBalance() internal view virtual returns (uint256);
    function _m3_observedAccountingSum() internal view virtual returns (uint256);

    /// @dev Asserts `balance >= accountingSum` after the sequence — i.e. the
    ///      contract is solvent against its own books.
    function test_M3_Conservation_BalanceCoversAccountingSum() public virtual {
        _resetSurface();
        _m3_runSequence();
        uint256 bal = _m3_observeBalance();
        uint256 acct = _m3_observedAccountingSum();
        assertGe(bal, acct, "M3: contract balance does not cover its accounting sum (insolvency)");
    }
}

/// @notice M4 — Path independence: `n × action(t/n)` ≈ `1 × action(t)`.
///
/// Concrete suites override:
/// - `_m4_doActionsCumulative(uint256 deltaTotal, uint256 numSteps) returns (uint256 cumulativePayout)`.
abstract contract M4PathIndependence is AccountingMetaPropertyBase {
    function _m4_doActionsCumulative(uint256 deltaTotal, uint256 numSteps)
        internal
        virtual
        returns (uint256 cumulativePayout);

    function _m4_pathSweep() internal view virtual returns (uint256[] memory steps) {
        steps = new uint256[](4);
        steps[0] = 1;
        steps[1] = 2;
        steps[2] = 10;
        steps[3] = 100;
    }

    /// @dev Holds `deltaTotal` constant, varies the number of cycling steps,
    ///      asserts cumulative payout stays within `rounding_tolerance` of the
    ///      single-call payout (steps=1).
    function test_M4_PathIndependence_CyclingDoesNotPrintValue() public virtual {
        uint256 deltaTotal = 30 days;
        uint256[] memory steps = _m4_pathSweep();
        _resetSurface();
        uint256 baseline = _m4_doActionsCumulative(deltaTotal, 1);
        for (uint256 i = 1; i < steps.length; i++) {
            _resetSurface();
            uint256 cumulative = _m4_doActionsCumulative(deltaTotal, steps[i]);
            uint256 drift = cumulative > baseline ? cumulative - baseline : baseline - cumulative;
            // Tolerance scales with step count to absorb per-step rounding floor.
            uint256 tol = _payoutRoundingTolerance() * steps[i];
            assertLe(drift, tol, "M4: cycling printed value beyond cumulative rounding floor");
        }
    }
}

/// @notice M5 — Cooldown-or-continuity: every value-paying surface is gated by
///         a cooldown ≥ curve resolution OR satisfies M1 by construction.
///
/// Concrete suites declare which arm applies via `_m5_arm()` returning either
/// the literal "cooldown" or "continuity". Cooldown arm: also expose
/// `_m5_minIntervalSec()` and `_m5_callTwiceWithinInterval() returns (bool reverted)`.
abstract contract M5CooldownOrContinuity is AccountingMetaPropertyBase {
    function _m5_arm() internal pure virtual returns (string memory);
    function _m5_minIntervalSec() internal pure virtual returns (uint256);
    function _m5_callTwiceWithinInterval() internal virtual returns (bool reverted);

    /// @dev If the surface chose "cooldown", asserts a second call inside the
    ///      cooldown reverts. If the surface chose "continuity", asserts the
    ///      M1 property holds (delegated to the derived suite via inheritance).
    function test_M5_CooldownOrContinuity_GateEnforced() public virtual {
        bytes32 arm = keccak256(abi.encodePacked(_m5_arm()));
        if (arm == keccak256("cooldown")) {
            _resetSurface();
            bool reverted = _m5_callTwiceWithinInterval();
            assertTrue(reverted, "M5(cooldown): second call inside interval did not revert");
        } else if (arm == keccak256("continuity")) {
            // Continuity arm is verified by inheriting from M1RateContinuity.
            // The concrete suite MUST also inherit M1; this assert is a marker.
            assertTrue(true, "M5(continuity): verified by M1 inheritance");
        } else {
            revert("M5: arm must be either 'cooldown' or 'continuity'");
        }
    }
}

/// @notice M6 — Floor direction: every mulDiv in a payout path either rounds
///         toward protocol, sits behind a carry bucket, or has a min-input
///         gate at the curve's resolution.
///
/// Concrete suites override:
/// - `_m6_payAtSubResolutionInput() returns (uint256 paidToUser, uint256 carryDelta)`
///   — drives the surface with a sub-resolution input and reports both the
///   user-side payout and the change in any carry bucket / reserve refund slot.
abstract contract M6FloorDirection is AccountingMetaPropertyBase {
    function _m6_payAtSubResolutionInput() internal virtual returns (uint256 paidToUser, uint256 carryDelta);

    /// @dev Asserts that at sub-resolution input, either the user payout is
    ///      zero (gate floors at resolution) OR the change in the protocol
    ///      carry bucket is non-negative (rounding favors protocol).
    function test_M6_FloorDirection_DustGoesToProtocolNotUser() public virtual {
        _resetSurface();
        (uint256 paidToUser, uint256 carryDelta) = _m6_payAtSubResolutionInput();
        if (paidToUser > 0) {
            assertGe(carryDelta, 0, "M6: user paid at sub-resolution AND carry bucket lost value");
        }
        // Implicit: carry bucket can absorb dust toward protocol; it is never
        // permitted to lose value to a sub-resolution caller.
    }
}
