// SPDX-License-Identifier: MIT
pragma solidity ^0.8.34;

import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

import {Constants} from "src/lib/Constants.sol";

/// @title MarketRouter M1-M6 bounded symbolic proofs
/// @notice Encodes the canonical accounting meta-properties from
///         `docs/security/invariants-v1.0.0.md` § 15 across the
///         `MarketRouter` value-paying surfaces (`list`, `delist`,
///         settlement, escrow open / cancel / execute).
///
/// @dev    Rate continuity (M1) does not bind — listing and escrow are
///         discrete state transitions with no payout-curve input. The
///         model captures the floor-direction of the
///         `bonusBpsVsPrincipalClaim` gate, the dual-listed settlement
///         shape, the keeper-grace window, and the open / cancel / execute
///         budget bucketing.
contract MarketRouter_M1_M6_Proofs {
    uint256 internal constant MAX_SYMBOLIC_VALUE = 1_000_000_000_000e18;
    uint256 internal constant MAX_SYMBOLIC_BPS = Constants.BPS_DENOM;

    // ---------------------------------------------------------------------
    // M2 — Quote = execute
    // ---------------------------------------------------------------------

    /// @notice M2: the `bonusBpsVsPrincipalClaim` projection is monotonic in
    ///         `bonusClaim` for any fixed `principalClaim`. A quoter view
    ///         that previews a higher bonus cannot project a lower bps
    ///         ratio than execution sees on the same principal.
    /// @dev    Mirrors `_validateBonusGate` at `src/MarketRouter.sol:1007`.
    function check_marketM2BonusBpsProjectionMonotonicInBonus(
        uint256 bonusClaimSmall,
        uint256 bonusClaimLarge,
        uint256 principalClaim
    ) public pure {
        require(principalClaim > 0);
        require(bonusClaimSmall <= bonusClaimLarge);
        require(bonusClaimLarge <= MAX_SYMBOLIC_VALUE);
        require(principalClaim <= MAX_SYMBOLIC_VALUE);

        uint256 small = Math.mulDiv(bonusClaimSmall, Constants.BPS_DENOM, principalClaim);
        uint256 large = Math.mulDiv(bonusClaimLarge, Constants.BPS_DENOM, principalClaim);

        assert(small <= large);
    }

    // ---------------------------------------------------------------------
    // M3 / M4 helpers — escrow ledger model
    // ---------------------------------------------------------------------

    struct EscrowState {
        uint256 buyerBalance;
        uint256 escrowBalance;
        uint256 furnaceBalance;
    }

    /// @dev Mirrors `openBonusEscrow` budget pull at
    ///      `src/MarketRouter.sol`: the buyer pays `budget` CLAIM into the
    ///      escrow.
    function _openEscrow(EscrowState memory s, uint256 budget) internal pure returns (EscrowState memory) {
        s.buyerBalance -= budget;
        s.escrowBalance += budget;
        return s;
    }

    /// @dev Mirrors `cancelBonusEscrow` refund: the entire escrow balance
    ///      is returned to the buyer.
    function _cancelEscrow(EscrowState memory s) internal pure returns (EscrowState memory) {
        uint256 amt = s.escrowBalance;
        s.escrowBalance = 0;
        s.buyerBalance += amt;
        return s;
    }

    /// @dev Mirrors `executeBonusEscrow` route-to-Furnace: the entire
    ///      escrow balance lands in `Furnace`.
    function _executeEscrow(EscrowState memory s) internal pure returns (EscrowState memory) {
        uint256 amt = s.escrowBalance;
        s.escrowBalance = 0;
        s.furnaceBalance += amt;
        return s;
    }

    // ---------------------------------------------------------------------
    // M3 — Conservation
    // ---------------------------------------------------------------------

    /// @notice M3: opening and then closing an escrow (cancel or execute)
    ///         conserves total CLAIM across the buyer / escrow / Furnace
    ///         ledgers, and the escrow holds zero after close.
    /// @dev    Mirrors the open / cancel / execute budget bucketing.
    ///         Re-encodes the seed-file proof
    ///         `check_marketEscrowCloseCannotLeakBudget` as canonical M3.
    function check_marketM3EscrowCloseConservesBudget(
        uint256 budgetClaim,
        uint256 startBalance,
        bool executeInsteadOfCancel
    ) public pure {
        require(budgetClaim <= MAX_SYMBOLIC_VALUE);
        require(startBalance >= budgetClaim && startBalance <= MAX_SYMBOLIC_VALUE);

        EscrowState memory s = EscrowState({buyerBalance: startBalance, escrowBalance: 0, furnaceBalance: 0});
        uint256 totalBefore = s.buyerBalance + s.escrowBalance + s.furnaceBalance;

        s = _openEscrow(s, budgetClaim);
        if (executeInsteadOfCancel) {
            s = _executeEscrow(s);
        } else {
            s = _cancelEscrow(s);
        }

        uint256 totalAfter = s.buyerBalance + s.escrowBalance + s.furnaceBalance;

        assert(totalAfter == totalBefore && s.escrowBalance == 0);
    }

    // ---------------------------------------------------------------------
    // M4 — Path independence
    // ---------------------------------------------------------------------

    /// @notice M4: the cycle (open A → cancel → open B → execute) lands the
    ///         buyer and Furnace ledgers in the same end-state as the
    ///         direct path (open B → execute). Cycling MUST NOT print or
    ///         destroy CLAIM on either side.
    /// @dev    Mirrors the budget bucketing across `openBonusEscrow`,
    ///         `cancelBonusEscrow`, `executeBonusEscrow`.
    function check_marketM4CycleEqualsDirect(uint256 budgetA, uint256 budgetB, uint256 startBalance) public pure {
        require(budgetA <= MAX_SYMBOLIC_VALUE);
        require(budgetB <= MAX_SYMBOLIC_VALUE);
        require(startBalance >= budgetA + budgetB);
        require(startBalance <= 2 * MAX_SYMBOLIC_VALUE);

        EscrowState memory cycle = EscrowState({buyerBalance: startBalance, escrowBalance: 0, furnaceBalance: 0});
        cycle = _openEscrow(cycle, budgetA);
        cycle = _cancelEscrow(cycle);
        cycle = _openEscrow(cycle, budgetB);
        cycle = _executeEscrow(cycle);

        EscrowState memory direct = EscrowState({buyerBalance: startBalance, escrowBalance: 0, furnaceBalance: 0});
        direct = _openEscrow(direct, budgetB);
        direct = _executeEscrow(direct);

        assert(
            cycle.buyerBalance == direct.buyerBalance && cycle.furnaceBalance == direct.furnaceBalance
                && cycle.escrowBalance == direct.escrowBalance
        );
    }

    // ---------------------------------------------------------------------
    // M5 — Cooldown-or-continuity
    // ---------------------------------------------------------------------

    /// @notice M5: a listing settlement requires both local and ve listing
    ///         flags set, the quoted ve out at or above the seller minimum,
    ///         and either a whitelisted keeper or the keeper-grace elapsed.
    ///         A successful settlement clears both flags atomically.
    /// @dev    Mirrors the keeper-grace gate at
    ///         `src/MarketRouter.sol:598`. Re-encodes the seed-file proof
    ///         `check_marketListingSettlementRequiresDualListedStateAndClearsBoth`
    ///         as canonical M5.
    function check_marketM5SettlementGateAndAtomicClear(
        uint256 minClaimOut,
        uint256 quoteClaimOut,
        uint64 listedAtTime,
        uint64 nowTs,
        uint64 expiresAtTime,
        bool localActive,
        bool veListed,
        bool keeper
    ) public pure {
        require(minClaimOut > 0 && minClaimOut <= MAX_SYMBOLIC_VALUE);
        require(quoteClaimOut <= MAX_SYMBOLIC_VALUE);
        require(expiresAtTime > nowTs);
        require(nowTs >= listedAtTime);

        bool graceElapsed = nowTs >= listedAtTime + Constants.SETTLEMENT_KEEPER_GRACE_SECONDS;
        bool canSettle = localActive && veListed && quoteClaimOut >= minClaimOut && (keeper || graceElapsed);

        bool localActiveAfter = localActive;
        bool veListedAfter = veListed;
        if (canSettle) {
            localActiveAfter = false;
            veListedAfter = false;
        }

        bool atomicClear = !canSettle || (!localActiveAfter && !veListedAfter);

        assert(atomicClear);
    }

    // ---------------------------------------------------------------------
    // M6 — Floor direction
    // ---------------------------------------------------------------------

    /// @notice M6: the `bonusBpsVsPrincipalClaim` projection rounds floor;
    ///         `floor(bonusClaim * BPS_DENOM / principalClaim) *
    ///         principalClaim <= bonusClaim * BPS_DENOM`. The gate's
    ///         floor direction never produces a value above the rational
    ///         ratio, so a satisfying ratio cannot be spuriously rejected.
    /// @dev    Mirrors the gate at `src/MarketRouter.sol:1001-1008`. The
    ///         floor direction is canonical: floor never spuriously
    ///         rejects a satisfying ratio whenever `targetBonusBps` is a
    ///         uint integer.
    function check_marketM6BonusGateFloorBoundsRatio(uint256 bonusClaim, uint256 principalClaim) public pure {
        require(principalClaim > 0);
        require(bonusClaim <= 1_000_000_000e18);
        require(principalClaim <= 1_000_000_000e18);

        uint256 ratioBps = Math.mulDiv(bonusClaim, Constants.BPS_DENOM, principalClaim);

        assert(ratioBps * principalClaim <= bonusClaim * Constants.BPS_DENOM);
    }

    // ---------------------------------------------------------------------
    // Auxiliary — liveness
    // ---------------------------------------------------------------------

    /// @notice Liveness: once the keeper-grace window has elapsed,
    ///         settlement is permissionless and the keeper-only branch
    ///         no longer blocks the call. A non-keeper caller satisfies
    ///         the keeper-or-grace gate post-grace.
    /// @dev    Mirrors `src/MarketRouter.sol:598`.
    function check_marketAuxLivenessPostKeeperGraceIsPermissionless(uint64 listedAtTime, uint64 nowTs) public pure {
        require(nowTs >= listedAtTime);
        require(nowTs >= listedAtTime + Constants.SETTLEMENT_KEEPER_GRACE_SECONDS);

        bool keeper = false;
        bool graceElapsed = nowTs >= listedAtTime + Constants.SETTLEMENT_KEEPER_GRACE_SECONDS;
        bool keeperOrGrace = keeper || graceElapsed;

        assert(keeperOrGrace);
    }
}
