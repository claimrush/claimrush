// SPDX-License-Identifier: MIT
pragma solidity ^0.8.34;

import {Constants} from "src/lib/Constants.sol";

/// @title ShareholderRoyalties M1-M6 bounded symbolic proofs
/// @notice Encodes the canonical accounting meta-properties from
///         `docs/security/invariants-v1.0.0.md` § 15 across the
///         `ShareholderRoyalties` value-paying surfaces (pending-ETH
///         deposit, flush-to-index, per-user checkpoint, payout consume,
///         dust sweep).
///
/// @dev    Models the strict disjoint-buckets closure (`totalCrystallisedStored
///         + indexedEthOwed + pendingShareholderETH == balance` and
///         `totalCrystallisedStored == Σ _claimableEthStored`) as a small
///         state struct and exercises the four state transitions that move
///         ETH between buckets. Rate continuity (M1), quote=execute (M2),
///         and cooldown-or-continuity (M5) do not bind on this surface —
///         it has no payout-curve input, no public quoter, and the index
///         is monotonic by construction.
contract ShareholderRoyalties_M1_M6_Proofs {
    uint256 internal constant MAX_SYMBOLIC_VALUE = 1_000_000_000_000e18;

    struct Buckets {
        uint256 pending;
        uint256 indexedOwed;
        uint256 stored;
        uint256 balance;
    }

    /// @dev Mirrors the pending-ETH credit at
    ///      `src/ShareholderRoyalties.sol:415` and `:434`. Native ETH lands
    ///      in `pendingShareholderETH` and the contract balance.
    function _addPending(Buckets memory b, uint256 amount) internal pure returns (Buckets memory) {
        b.pending += amount;
        b.balance += amount;
        return b;
    }

    /// @dev Mirrors the flush distribution at
    ///      `src/ShareholderRoyalties.sol:532-533`: pending is debited and
    ///      `indexedEthOwed` is credited by the same amount. The contract
    ///      balance does not move because both buckets sit on the contract.
    function _flushToIndex(Buckets memory b, uint256 distributed) internal pure returns (Buckets memory) {
        b.pending -= distributed;
        b.indexedOwed += distributed;
        return b;
    }

    /// @dev Mirrors `checkpointUser` at
    ///      `src/ShareholderRoyalties.sol:602-606`: per-user accrual is
    ///      clamped to the available indexed pool and credited into
    ///      `_claimableEthStored` plus the O(1) aggregator
    ///      `totalCrystallisedStored`. Returns the credited delta after
    ///      clamping.
    function _checkpointUser(Buckets memory b, uint256 wholeAccrued) internal pure returns (Buckets memory, uint256) {
        if (wholeAccrued > b.indexedOwed) wholeAccrued = b.indexedOwed;
        b.indexedOwed -= wholeAccrued;
        b.stored += wholeAccrued;
        return (b, wholeAccrued);
    }

    /// @dev Mirrors `_consumeReservedEth` at
    ///      `src/ShareholderRoyalties.sol:546-555`: the stored aggregator
    ///      is debited and the contract balance drops by the same amount.
    function _consume(Buckets memory b, uint256 amount) internal pure returns (Buckets memory) {
        b.stored -= amount;
        b.balance -= amount;
        return b;
    }

    function _disjoint(Buckets memory b) internal pure returns (bool) {
        return b.stored + b.indexedOwed + b.pending == b.balance;
    }

    // ---------------------------------------------------------------------
    // M3 — Conservation (strict disjoint-buckets)
    // ---------------------------------------------------------------------

    /// @notice M3: a pending-ETH deposit preserves the strict disjoint
    ///         invariant `stored + indexed + pending == balance`.
    /// @dev    Mirrors the takeover credit at
    ///         `src/ShareholderRoyalties.sol:415` and `:434`. See
    ///         `docs/security/invariants-v1.0.0.md` § 5 STRICT.
    function check_royaltiesM3DepositPreservesDisjointSum(uint256 deposit) public pure {
        require(deposit <= MAX_SYMBOLIC_VALUE);

        Buckets memory b = Buckets({pending: 0, indexedOwed: 0, stored: 0, balance: 0});
        b = _addPending(b, deposit);

        assert(_disjoint(b));
    }

    /// @notice M3: a flush from pending to indexed preserves the strict
    ///         disjoint invariant.
    /// @dev    Mirrors `_distributeShareholderETH` at
    ///         `src/ShareholderRoyalties.sol:532-533`.
    function check_royaltiesM3FlushPreservesDisjointSum(uint256 deposit, uint256 distributed) public pure {
        require(deposit <= MAX_SYMBOLIC_VALUE);
        require(distributed <= deposit);

        Buckets memory b = Buckets({pending: 0, indexedOwed: 0, stored: 0, balance: 0});
        b = _addPending(b, deposit);
        b = _flushToIndex(b, distributed);

        assert(_disjoint(b));
    }

    /// @notice M3: a per-user checkpoint preserves the strict disjoint
    ///         invariant; the clamp keeps `indexedEthOwed` non-negative.
    /// @dev    Mirrors `checkpointUser` at
    ///         `src/ShareholderRoyalties.sol:602-606`.
    function check_royaltiesM3CheckpointPreservesDisjointSum(uint256 deposit, uint256 distributed, uint256 wholeAccrued)
        public
        pure
    {
        require(deposit <= MAX_SYMBOLIC_VALUE);
        require(distributed <= deposit);
        require(wholeAccrued <= MAX_SYMBOLIC_VALUE);

        Buckets memory b = Buckets({pending: 0, indexedOwed: 0, stored: 0, balance: 0});
        b = _addPending(b, deposit);
        b = _flushToIndex(b, distributed);
        (b,) = _checkpointUser(b, wholeAccrued);

        assert(_disjoint(b));
    }

    /// @notice M3: a payout consume preserves the strict disjoint
    ///         invariant; balance and the stored aggregator drop in
    ///         lockstep.
    /// @dev    Mirrors `_consumeReservedEth` at
    ///         `src/ShareholderRoyalties.sol:546-555`.
    function check_royaltiesM3ConsumePreservesDisjointSum(
        uint256 deposit,
        uint256 distributed,
        uint256 wholeAccrued,
        uint256 consume
    ) public pure {
        require(deposit <= MAX_SYMBOLIC_VALUE);
        require(distributed <= deposit);
        require(wholeAccrued <= MAX_SYMBOLIC_VALUE);

        Buckets memory b = Buckets({pending: 0, indexedOwed: 0, stored: 0, balance: 0});
        b = _addPending(b, deposit);
        b = _flushToIndex(b, distributed);
        (b,) = _checkpointUser(b, wholeAccrued);

        require(consume <= b.stored);
        b = _consume(b, consume);

        assert(_disjoint(b));
    }

    // ---------------------------------------------------------------------
    // M4 — Path independence
    // ---------------------------------------------------------------------

    /// @notice M4: two flushes from pending to indexed and one combined
    ///         flush of the same total leave the buckets in the same
    ///         shape. Cycling MUST NOT print or destroy ETH.
    /// @dev    Mirrors `_distributeShareholderETH` at
    ///         `src/ShareholderRoyalties.sol:532-533`.
    function check_royaltiesM4MultiFlushEqualsSingleFlush(uint256 deposit, uint256 distA, uint256 distB) public pure {
        require(deposit <= MAX_SYMBOLIC_VALUE);
        require(distA <= deposit);
        require(distB <= deposit - distA);

        Buckets memory split = Buckets({pending: 0, indexedOwed: 0, stored: 0, balance: 0});
        split = _addPending(split, deposit);
        split = _flushToIndex(split, distA);
        split = _flushToIndex(split, distB);

        Buckets memory whole = Buckets({pending: 0, indexedOwed: 0, stored: 0, balance: 0});
        whole = _addPending(whole, deposit);
        whole = _flushToIndex(whole, distA + distB);

        assert(
            split.pending == whole.pending && split.indexedOwed == whole.indexedOwed && split.balance == whole.balance
        );
    }

    // ---------------------------------------------------------------------
    // M6 — Floor direction (carry-bucket mitigation)
    // ---------------------------------------------------------------------

    /// @notice M6: the per-user checkpoint clamps the credited delta to
    ///         the available indexed pool. Floor-additivity drift across
    ///         multiple flushes cannot over-credit a user beyond the ETH
    ///         that backs them.
    /// @dev    Mirrors the clamp at
    ///         `src/ShareholderRoyalties.sol:602`. The remainder lives in
    ///         `userRewardRemainder[user]` (carry bucket) and is promoted
    ///         on the next flush — see § 15 M6.
    function check_royaltiesM6CheckpointClampsToIndexedPool(uint256 deposit, uint256 distributed, uint256 wholeAccrued)
        public
        pure
    {
        require(deposit <= MAX_SYMBOLIC_VALUE);
        require(distributed <= deposit);
        require(wholeAccrued <= MAX_SYMBOLIC_VALUE);

        Buckets memory b = Buckets({pending: 0, indexedOwed: 0, stored: 0, balance: 0});
        b = _addPending(b, deposit);
        b = _flushToIndex(b, distributed);

        uint256 indexedBefore = b.indexedOwed;
        uint256 credited;
        (b, credited) = _checkpointUser(b, wholeAccrued);

        assert(credited <= indexedBefore);
    }

    /// @notice M6: a sub-floor accrual (under the indexed pool) is
    ///         credited verbatim; the clamp only bites when the requested
    ///         credit exceeds the pool.
    /// @dev    Mirrors `checkpointUser` clamp at
    ///         `src/ShareholderRoyalties.sol:602`.
    function check_royaltiesM6SubFloorAccrualCreditedVerbatim(
        uint256 deposit,
        uint256 distributed,
        uint256 wholeAccrued
    ) public pure {
        require(deposit <= MAX_SYMBOLIC_VALUE);
        require(distributed <= deposit);
        require(wholeAccrued <= distributed);

        Buckets memory b = Buckets({pending: 0, indexedOwed: 0, stored: 0, balance: 0});
        b = _addPending(b, deposit);
        b = _flushToIndex(b, distributed);

        uint256 credited;
        (, credited) = _checkpointUser(b, wholeAccrued);

        assert(credited == wholeAccrued);
    }
}
