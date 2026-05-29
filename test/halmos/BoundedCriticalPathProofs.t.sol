// SPDX-License-Identifier: MIT
pragma solidity ^0.8.34;

import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

import {Constants} from "src/lib/Constants.sol";

/// @notice Bounded symbolic proofs for launch-critical value-flow transitions.
/// @dev These are intentionally small models of the production state transitions.
///      Foundry unit/invariant tests exercise the deployed contracts; Halmos explores
///      all values inside the bounded domains below and proves the accounting
///      obligations cannot be violated inside those domains.
contract BoundedCriticalPathProofs {
    uint256 internal constant MAX_SYMBOLIC_VALUE = 1_000_000_000_000e18;
    uint256 internal constant MAX_SYMBOLIC_BPS = Constants.BPS_DENOM;

    struct BonusSplit {
        uint256 gross;
        uint256 user;
        uint256 lp;
        uint256 deliveredUser;
        uint256 refundedDust;
    }

    function _boundedBonusSplit(uint256 reserve, uint256 principalEff, uint256 virtualDepth, uint256 lpRateBps)
        internal
        pure
        returns (BonusSplit memory s)
    {
        if (principalEff == 0 || reserve == 0 || virtualDepth == 0) return s;

        s.gross = Math.mulDiv(reserve, principalEff, virtualDepth + principalEff);
        if (s.gross > reserve) s.gross = reserve;

        if (lpRateBps == 0 || s.gross == 0) {
            s.user = s.gross;
        } else {
            s.user = Math.mulDiv(s.gross, Constants.BPS_DENOM, Constants.BPS_DENOM + lpRateBps);
            s.lp = s.gross - s.user;
        }

        if (s.user >= Constants.MIN_TOPUP_AMOUNT) {
            s.deliveredUser = s.user;
        } else {
            s.refundedDust = s.user;
        }
    }

    function check_furnaceBonusFloorPreservesReserveSolvency(
        uint256 reserve,
        uint256 principalEff,
        uint256 virtualDepth,
        uint256 lpRateBps
    ) public pure {
        require(reserve <= MAX_SYMBOLIC_VALUE);
        require(principalEff <= MAX_SYMBOLIC_VALUE);
        require(virtualDepth > 0 && virtualDepth <= MAX_SYMBOLIC_VALUE);
        require(lpRateBps <= MAX_SYMBOLIC_BPS);

        BonusSplit memory s = _boundedBonusSplit(reserve, principalEff, virtualDepth, lpRateBps);

        assert(s.gross <= reserve);
        assert(s.user + s.lp == s.gross);
        assert(s.deliveredUser == 0 || s.deliveredUser >= Constants.MIN_TOPUP_AMOUNT);

        uint256 reserveAfter = reserve - s.gross + s.refundedDust;
        uint256 furnaceBalanceAfter = reserve - s.deliveredUser;

        assert(furnaceBalanceAfter >= reserveAfter + s.lp);
        if (s.deliveredUser == 0) {
            assert(furnaceBalanceAfter == reserve);
            assert(reserveAfter + s.lp == reserve);
        }
    }

    function check_autoMaxSubMinPreflightCannotConsumeCursor(
        uint256 reserve,
        uint256 principalEff,
        uint256 virtualDepth,
        uint256 lpRateBps,
        uint64 lastClaim,
        uint64 nowTs
    ) public pure {
        require(reserve <= MAX_SYMBOLIC_VALUE);
        require(principalEff <= MAX_SYMBOLIC_VALUE);
        require(virtualDepth > 0 && virtualDepth <= MAX_SYMBOLIC_VALUE);
        require(lpRateBps <= MAX_SYMBOLIC_BPS);
        require(lastClaim > 0);
        require(nowTs >= lastClaim + 1 days);

        BonusSplit memory s = _boundedBonusSplit(reserve, principalEff, virtualDepth, lpRateBps);

        uint256 reserveSpent;
        uint256 nextCursor;
        if (s.deliveredUser == 0) {
            reserveSpent = 0;
            nextCursor = lastClaim;
        } else {
            reserveSpent = s.gross;
            nextCursor = nowTs;
        }

        assert(s.deliveredUser != 0 || reserveSpent == 0);
        assert(s.deliveredUser != 0 || nextCursor == lastClaim);
        assert(s.deliveredUser == 0 || nextCursor == nowTs);
        assert(reserveSpent <= reserve);
    }

    function check_veLockAddMergeUnlockConservesPrincipal(
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

        if (!sourceListed && !destinationListed) {
            destinationAmount += amountA;
            assert(totalLocked == oldTotal + topUp);
            assert(destinationAmount == uint256(amountA) + uint256(amountB) + topUp);
        } else {
            assert(totalLocked == oldTotal + (destinationListed ? 0 : topUp));
        }

        uint256 transferOut;
        uint256 totalAfterUnlock = totalLocked;
        if (!unlockListed && !unlockAutoMax) {
            transferOut = destinationAmount;
            totalAfterUnlock = totalLocked - destinationAmount;
        }

        assert(transferOut <= totalLocked);
        assert(totalAfterUnlock + transferOut == totalLocked);
    }

    function check_marketListingSettlementRequiresDualListedStateAndClearsBoth(
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
        uint256 claimOut;
        if (canSettle) {
            localActiveAfter = false;
            veListedAfter = false;
            claimOut = quoteClaimOut;
        }

        assert(!canSettle || claimOut >= minClaimOut);
        assert(!canSettle || (!localActiveAfter && !veListedAfter));
        assert(canSettle || (localActiveAfter == localActive && veListedAfter == veListed));
        assert(canSettle == false || (localActive && veListed));
    }

    function check_marketEscrowCloseCannotLeakBudget(uint256 budgetClaim, bool executeInsteadOfCancel) public pure {
        require(budgetClaim <= MAX_SYMBOLIC_VALUE);

        bool active = true;
        uint256 fundsRemaining = budgetClaim;
        uint256 claimIntoFurnace;
        uint256 refundToBuyer;

        active = false;
        fundsRemaining = 0;
        if (executeInsteadOfCancel) {
            claimIntoFurnace = budgetClaim;
        } else {
            refundToBuyer = budgetClaim;
        }

        assert(!active);
        assert(fundsRemaining == 0);
        assert(claimIntoFurnace + refundToBuyer == budgetClaim);
    }

    function check_mineCoreTakeoverPaymentBucketsConserveCreditedEth(
        uint256 creditedEth,
        uint256 pricePaid,
        bool kingPushSucceeds,
        bool refundPushSucceeds
    ) public pure {
        require(pricePaid > 0);
        require(pricePaid <= creditedEth);
        require(creditedEth <= MAX_SYMBOLIC_VALUE);

        uint256 kingShare = (pricePaid * Constants.KING_ETH_SHARE_PCT) / Constants.KING_ETH_SHARE_DENOM;
        uint256 shareholderShare = pricePaid - kingShare;
        uint256 refund = creditedEth - pricePaid;

        uint256 directKingPaid = kingPushSucceeds ? kingShare : 0;
        uint256 kingOwed = kingPushSucceeds ? 0 : kingShare;
        uint256 directRefundPaid = refundPushSucceeds ? refund : 0;
        uint256 refundOwed = refundPushSucceeds ? 0 : refund;

        assert(kingShare + shareholderShare == pricePaid);
        assert(directKingPaid + kingOwed == kingShare);
        assert(directRefundPaid + refundOwed == refund);
        assert(directKingPaid + kingOwed + shareholderShare + directRefundPaid + refundOwed == creditedEth);
    }

    function check_mineCorePauseTransitionClampsAccrualCursor(
        uint64 lastAccrual,
        uint64 nowTs,
        bool hasKing,
        bool pausedBefore,
        bool requestedPaused,
        bool genesisCollected
    ) public pure {
        require(nowTs >= lastAccrual);

        bool reverts = !requestedPaused && !genesisCollected && pausedBefore != requestedPaused;
        bool changes = pausedBefore != requestedPaused && !reverts;
        uint256 nextAccrual = lastAccrual;
        bool pausedAfter = pausedBefore;

        if (changes) {
            pausedAfter = requestedPaused;
            if (hasKing) nextAccrual = nowTs;
        }

        assert(reverts || pausedAfter == requestedPaused || pausedBefore == requestedPaused);
        assert(!changes || !hasKing || nextAccrual == nowTs);
        assert(!changes || hasKing || nextAccrual == lastAccrual);
        assert(changes || nextAccrual == lastAccrual);
    }
}
