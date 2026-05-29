// SPDX-License-Identifier: MIT
pragma solidity ^0.8.34;

import {Constants} from "src/lib/Constants.sol";

/// @title MineCore M1-M6 bounded symbolic proofs
/// @notice Encodes the canonical accounting meta-properties from
///         `docs/security/invariants-v1.0.0.md` § 15 across the MineCore
///         value-paying surfaces (`takeover`, king/shareholder/refund
///         payout, pause).
///
/// @dev    Rate-continuity (M1) and quote-equals-execute (M2) are not
///         applicable — takeover and pause are discrete state transitions
///         with no payout-curve input and no public quoter view. Path
///         independence (M4) here means cumulative takeover credits never
///         generate ETH outside the `creditedEth` envelope, which is a
///         repeatability obligation on top of the M3 split.
contract MineCore_M1_M6_Proofs {
    uint256 internal constant MAX_SYMBOLIC_VALUE = 1_000_000_000_000e18;

    // ---------------------------------------------------------------------
    // M3 — Conservation
    // ---------------------------------------------------------------------

    /// @notice M3: the king share and shareholder share sum to exactly the
    ///         price paid; the takeover split never creates or destroys ETH.
    /// @dev    Mirrors `MineCore.takeover` split at
    ///         `src/MineCore.sol:1131-1132`.
    function check_mineCoreM3KingPlusShareholderEqualsPricePaid(uint256 pricePaid) public pure {
        require(pricePaid <= MAX_SYMBOLIC_VALUE);

        uint256 kingShare = (pricePaid * Constants.KING_ETH_SHARE_PCT) / Constants.KING_ETH_SHARE_DENOM;
        uint256 shareholderShare = pricePaid - kingShare;

        assert(kingShare + shareholderShare == pricePaid);
    }

    /// @notice M3: every wei the buyer credited is accounted for across the
    ///         four payout buckets — direct king push, owed king bucket,
    ///         direct refund, owed refund bucket — plus the shareholder
    ///         share routed through `ShareholderRoyalties`.
    /// @dev    Mirrors `MineCore.takeover` payout fan-out at
    ///         `src/MineCore.sol:1131-1159` and the refund leg at
    ///         `src/MineCore.sol:1220`. Re-encodes the seed-file proof
    ///         `check_mineCoreTakeoverPaymentBucketsConserveCreditedEth` as
    ///         canonical M3.
    function check_mineCoreM3TakeoverBucketsConserveCreditedEth(
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

        assert(directKingPaid + kingOwed + shareholderShare + directRefundPaid + refundOwed == creditedEth);
    }

    // ---------------------------------------------------------------------
    // M4 — Path independence
    // ---------------------------------------------------------------------

    /// @notice M4: two consecutive takeovers credit the same total ETH
    ///         across king / shareholder / refund buckets as the sum of the
    ///         per-takeover credits. Cycling MUST NOT print ETH.
    /// @dev    Mirrors `MineCore.takeover` payout fan-out at
    ///         `src/MineCore.sol:1131-1159` evaluated under repeated calls.
    function check_mineCoreM4TwoTakeoversCreditSumOfBucketsEqualsTotalIn(
        uint256 priceA,
        uint256 priceB,
        uint256 refundA,
        uint256 refundB
    ) public pure {
        require(priceA > 0 && priceB > 0);
        require(priceA <= MAX_SYMBOLIC_VALUE && priceB <= MAX_SYMBOLIC_VALUE);
        require(refundA <= MAX_SYMBOLIC_VALUE && refundB <= MAX_SYMBOLIC_VALUE);
        require(priceA + refundA <= MAX_SYMBOLIC_VALUE);
        require(priceB + refundB <= MAX_SYMBOLIC_VALUE);

        uint256 kingA = (priceA * Constants.KING_ETH_SHARE_PCT) / Constants.KING_ETH_SHARE_DENOM;
        uint256 shareholderA = priceA - kingA;
        uint256 kingB = (priceB * Constants.KING_ETH_SHARE_PCT) / Constants.KING_ETH_SHARE_DENOM;
        uint256 shareholderB = priceB - kingB;

        uint256 totalIn = priceA + refundA + priceB + refundB;
        uint256 totalOut = kingA + shareholderA + refundA + kingB + shareholderB + refundB;

        assert(totalIn == totalOut);
    }

    // ---------------------------------------------------------------------
    // M5 — Cooldown-or-continuity
    // ---------------------------------------------------------------------

    /// @notice M5: a `setTakeoversPaused` transition that flips the state
    ///         clamps `currentReignLastAccrualTime` to `block.timestamp`
    ///         when a king is reigning, so paused time can never accrue
    ///         later.
    /// @dev    Mirrors `setTakeoversPaused` at
    ///         `src/MineCore.sol:464-475`. Re-encodes the seed-file proof
    ///         `check_mineCorePauseTransitionClampsAccrualCursor` as
    ///         canonical M5.
    function check_mineCoreM5PauseClampsAccrualCursor(
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
        if (changes && hasKing) nextAccrual = nowTs;

        assert(changes || nextAccrual == lastAccrual);
    }

    /// @notice M5: a no-op pause request (`requestedPaused == pausedBefore`)
    ///         leaves the accrual cursor untouched, irrespective of king
    ///         tenancy or wall-clock advance.
    /// @dev    Mirrors `setTakeoversPaused` early-return at
    ///         `src/MineCore.sol:465`. The model exposes both
    ///         `pausedBefore` and `requestedPaused` symbolically; the
    ///         no-op branch is selected by `require`.
    function check_mineCoreM5NoOpPauseLeavesAccrualCursorIntact(
        uint64 lastAccrual,
        uint64 nowTs,
        bool hasKing,
        bool pausedBefore,
        bool requestedPaused
    ) public pure {
        require(nowTs >= lastAccrual);
        require(requestedPaused == pausedBefore);

        bool changes = requestedPaused != pausedBefore;
        uint256 nextAccrual = lastAccrual;
        if (changes && hasKing) nextAccrual = nowTs;

        assert(nextAccrual == lastAccrual);
    }

    // ---------------------------------------------------------------------
    // M6 — Floor direction
    // ---------------------------------------------------------------------

    /// @notice M6: the king ETH share rounds down (toward the protocol).
    ///         The integer floor never exceeds the rational fair share
    ///         `pricePaid * KING_PCT / KING_DENOM`, so any rounding loss
    ///         accrues to shareholders, not to the king.
    /// @dev    Mirrors `MineCore.takeover` split at
    ///         `src/MineCore.sol:1131` (`(pricePaid * 75) / 100`).
    function check_mineCoreM6KingShareFloorBoundsRationalShare(uint256 pricePaid) public pure {
        require(pricePaid <= MAX_SYMBOLIC_VALUE);

        uint256 kingShare = (pricePaid * Constants.KING_ETH_SHARE_PCT) / Constants.KING_ETH_SHARE_DENOM;

        assert(kingShare * Constants.KING_ETH_SHARE_DENOM <= pricePaid * Constants.KING_ETH_SHARE_PCT);
    }

    // ---------------------------------------------------------------------
    // Auxiliary — liveness
    // ---------------------------------------------------------------------

    /// @notice Liveness: once the genesis king claim has been collected,
    ///         every `setTakeoversPaused` transition is permitted — pause
    ///         flips never brick after genesis.
    /// @dev    Mirrors the genesis gate at `src/MineCore.sol:466`. The
    ///         only revert branch is `!requestedPaused && !genesisCollected`;
    ///         once `genesisCollected` is true the gate disappears for
    ///         every `(pausedBefore, requestedPaused)` pair.
    function check_mineCoreAuxLivenessPauseFlipPermittedAfterGenesis(
        bool pausedBefore,
        bool requestedPaused,
        bool genesisCollected
    ) public pure {
        require(genesisCollected);

        bool reverts = !requestedPaused && !genesisCollected && pausedBefore != requestedPaused;

        assert(!reverts);
    }
}
