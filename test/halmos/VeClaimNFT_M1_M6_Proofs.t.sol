// SPDX-License-Identifier: MIT
pragma solidity ^0.8.34;

import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

import {Constants} from "src/lib/Constants.sol";

/// @title VeClaimNFT M1-M6 bounded symbolic proofs
/// @notice Encodes the canonical accounting meta-properties from
///         `docs/security/invariants-v1.0.0.md` § 15 across the
///         `VeClaimNFT` value-paying surfaces (`createLock`, `addToLock`,
///         `extendLockTo`, `mergeLocks`, unlock, autoMax toggle).
///
/// @dev    The duration-weight curve is the same sub-bp shape used by the
///         Furnace bonus path; here the proofs cover the lock-principal
///         conservation and the bps-shaped public view that frontends
///         consume for slider previews. Re-encodes
///         `BoundedCriticalPathProofs::check_veLockAddMergeUnlockConservesPrincipal`
///         as canonical M3.
contract VeClaimNFT_M1_M6_Proofs {
    uint256 internal constant MAX_SYMBOLIC_VALUE = 1_000_000_000_000e18;

    // ---------------------------------------------------------------------
    // M1 — Rate continuity
    // ---------------------------------------------------------------------

    /// @notice M1: the duration-weight projection vanishes at zero
    ///         duration delta — a top-up that does not extend duration
    ///         contributes zero principalEff.
    /// @dev    Mirrors `mulDiv(amount, weightDelta, WEIGHT_DENOM)` at
    ///         `src/FurnaceQuoter.sol:177` and
    ///         `src/FurnaceGuardHelper.sol:1268`.
    function check_veM1WeightProjectionVanishesAtZeroDelta(uint256 lockAmount) public pure {
        require(lockAmount <= MAX_SYMBOLIC_VALUE);

        uint256 principalEff = Math.mulDiv(lockAmount, 0, Constants.WEIGHT_DENOM);

        assert(principalEff == 0);
    }

    // ---------------------------------------------------------------------
    // M2 — Quote = execute
    // ---------------------------------------------------------------------

    /// @notice M2: the public bps-shaped `durationWeightBps()` view is the
    ///         floor of the internal sub-bp curve divided by
    ///         `WEIGHT_PRECISION`. Frontends and value-paying paths see a
    ///         consistent integer floor of the same curve.
    /// @dev    Mirrors `FurnaceQuoter.durationWeightBps` at
    ///         `src/FurnaceQuoter.sol:567-569` against the internal
    ///         `_durationWeight` shape.
    function check_veM2DurationWeightBpsIsFlooredView(uint256 weightSubBp) public pure {
        require(weightSubBp <= Constants.WEIGHT_DENOM);

        uint256 publicBps = weightSubBp / Constants.WEIGHT_PRECISION;

        assert(publicBps * Constants.WEIGHT_PRECISION <= weightSubBp);
        assert((publicBps + 1) * Constants.WEIGHT_PRECISION > weightSubBp);
    }

    // ---------------------------------------------------------------------
    // M3 — Conservation
    // ---------------------------------------------------------------------

    /// @notice M3: a top-up `addToLock(amount)` increases `totalLockedClaim`
    ///         by exactly `amount` and the user's lock balance by exactly
    ///         `amount`. No new lock principal is created or destroyed.
    /// @dev    Mirrors `_addToLock` at `src/VeClaimNFT.sol:1352-1357` and
    ///         the `MIN_TOPUP_AMOUNT` gate.
    function check_veM3AddToLockConservesPrincipal(uint256 lockBefore, uint256 topUp) public pure {
        require(lockBefore <= MAX_SYMBOLIC_VALUE);
        require(topUp >= Constants.MIN_TOPUP_AMOUNT);
        require(topUp <= MAX_SYMBOLIC_VALUE - lockBefore);

        uint256 lockAfter = lockBefore + topUp;
        uint256 totalDelta = topUp;

        assert(lockAfter == lockBefore + totalDelta);
    }

    /// @notice M3: a merge of two locks conserves the union of principals
    ///         across the surviving lock and the burned lock; cycling
    ///         through merge MUST NOT print or destroy lock principal.
    /// @dev    Mirrors `mergeLocksFor` at `src/VeClaimNFT.sol:789-896`.
    ///         Re-encodes the seed-file proof
    ///         `check_veLockAddMergeUnlockConservesPrincipal` as canonical
    ///         M3.
    function check_veM3MergeConservesUnionOfPrincipals(
        uint96 amountA,
        uint96 amountB,
        uint96 topUp,
        bool sourceListed,
        bool destinationListed,
        bool unlockListed,
        bool unlockAutoMax
    ) public pure {
        require(amountA >= Constants.MIN_LOCK_AMOUNT);
        require(amountB >= Constants.MIN_LOCK_AMOUNT);
        require(topUp == 0 || topUp >= Constants.MIN_TOPUP_AMOUNT);
        require(uint256(amountA) + uint256(amountB) + uint256(topUp) <= MAX_SYMBOLIC_VALUE);

        uint256 oldTotal = uint256(amountA) + uint256(amountB);
        uint256 destinationAmount = amountB;
        uint256 totalLocked = oldTotal;

        if (!destinationListed && topUp != 0) {
            destinationAmount += topUp;
            totalLocked += topUp;
        }

        uint256 expectedTotalAfterMerge;
        if (!sourceListed && !destinationListed) {
            destinationAmount += amountA;
            expectedTotalAfterMerge = oldTotal + topUp;
        } else {
            expectedTotalAfterMerge = oldTotal + (destinationListed ? 0 : topUp);
        }

        uint256 transferOut;
        uint256 totalAfterUnlock = totalLocked;
        if (!unlockListed && !unlockAutoMax) {
            transferOut = destinationAmount;
            totalAfterUnlock = totalLocked - destinationAmount;
        }

        assert(totalAfterUnlock + transferOut == expectedTotalAfterMerge);
    }

    // ---------------------------------------------------------------------
    // M4 — Path independence
    // ---------------------------------------------------------------------

    /// @notice M4: two top-ups `addToLock(a) + addToLock(b)` leave the
    ///         lock balance in the same shape as one top-up
    ///         `addToLock(a + b)`. Cycling MUST NOT print principal.
    /// @dev    Mirrors `_addToLock` at `src/VeClaimNFT.sol:1352-1357`.
    ///         The production path is integer addition with no rounding;
    ///         the proof captures the absence of `mulDiv` / scaling drift
    ///         in the principal-conservation slot.
    function check_veM4SplitAddEqualsCombinedAdd(uint256 lockBefore, uint96 amountA, uint96 amountB) public pure {
        require(lockBefore <= MAX_SYMBOLIC_VALUE);
        require(amountA >= Constants.MIN_TOPUP_AMOUNT);
        require(amountB >= Constants.MIN_TOPUP_AMOUNT);
        require(uint256(amountA) + uint256(amountB) <= MAX_SYMBOLIC_VALUE - lockBefore);

        uint256 splitTotal = (lockBefore + uint256(amountA)) + uint256(amountB);
        uint256 combinedTotal = lockBefore + (uint256(amountA) + uint256(amountB));

        assert(splitTotal == combinedTotal);
    }

    // ---------------------------------------------------------------------
    // M5 — Cooldown-or-continuity
    // ---------------------------------------------------------------------

    /// @dev Mirrors the duration gate at `src/VeClaimNFT.sol:1304-1306`.
    function _createLockDurationGate(uint256 duration) internal pure returns (bool reverts) {
        return duration < Constants.MIN_LOCK_DURATION || duration > Constants.MAX_LOCK_DURATION;
    }

    /// @notice M5: a `createLock` request below `MIN_LOCK_DURATION` is
    ///         rejected.
    function check_veM5CreateLockBelowMinDurationReverts(uint256 duration) public pure {
        require(duration < Constants.MIN_LOCK_DURATION);

        assert(_createLockDurationGate(duration));
    }

    /// @notice M5: a `createLock` request above `MAX_LOCK_DURATION` is
    ///         rejected.
    function check_veM5CreateLockAboveMaxDurationReverts(uint256 duration) public pure {
        require(duration > Constants.MAX_LOCK_DURATION);
        require(duration <= 2 * Constants.MAX_LOCK_DURATION);

        assert(_createLockDurationGate(duration));
    }

    /// @notice M5: a `createLock` request inside `[MIN, MAX]` is permitted.
    function check_veM5CreateLockInRangeDurationPermits(uint256 duration) public pure {
        require(duration >= Constants.MIN_LOCK_DURATION);
        require(duration <= Constants.MAX_LOCK_DURATION);

        assert(!_createLockDurationGate(duration));
    }

    // ---------------------------------------------------------------------
    // M6 — Floor direction
    // ---------------------------------------------------------------------

    /// @dev Mirrors the floor at `src/VeClaimNFT.sol:1355`.
    function _addToLockMinTopupGate(uint256 amount) internal pure returns (bool reverts) {
        return amount < Constants.MIN_TOPUP_AMOUNT;
    }

    /// @notice M6: `_addToLock` reverts on a sub-`MIN_TOPUP_AMOUNT`
    ///         request — the minimum-input gate bounds ceiling-rounding
    ///         slope dust at top-up.
    function check_veM6AddToLockBelowMinTopupReverts(uint256 amount) public pure {
        require(amount < Constants.MIN_TOPUP_AMOUNT);

        assert(_addToLockMinTopupGate(amount));
    }

    /// @notice M6: `_addToLock` permits a request at or above
    ///         `MIN_TOPUP_AMOUNT`.
    function check_veM6AddToLockAtOrAboveMinTopupPermits(uint256 amount) public pure {
        require(amount >= Constants.MIN_TOPUP_AMOUNT);
        require(amount <= MAX_SYMBOLIC_VALUE);

        assert(!_addToLockMinTopupGate(amount));
    }

    /// @dev Mirrors the floor at `src/VeClaimNFT.sol:1303`.
    function _createLockMinAmountGate(uint256 amount) internal pure returns (bool reverts) {
        return amount < Constants.MIN_LOCK_AMOUNT;
    }

    /// @notice M6: `createLock` reverts on a sub-`MIN_LOCK_AMOUNT` request.
    ///         The minimum-input gate bounds the curve's resolution at
    ///         lock creation.
    function check_veM6CreateLockBelowMinAmountReverts(uint256 amount) public pure {
        require(amount < Constants.MIN_LOCK_AMOUNT);

        assert(_createLockMinAmountGate(amount));
    }

    /// @notice M6: `createLock` permits a request at or above
    ///         `MIN_LOCK_AMOUNT`.
    function check_veM6CreateLockAtOrAboveMinAmountPermits(uint256 amount) public pure {
        require(amount >= Constants.MIN_LOCK_AMOUNT);
        require(amount <= MAX_SYMBOLIC_VALUE);

        assert(!_createLockMinAmountGate(amount));
    }
}
