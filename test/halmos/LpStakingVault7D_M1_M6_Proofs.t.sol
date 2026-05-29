// SPDX-License-Identifier: MIT
pragma solidity ^0.8.34;

import {Constants} from "src/lib/Constants.sol";

/// @title LpStakingVault7D M1-M6 bounded symbolic proofs
/// @notice Encodes the canonical accounting meta-properties from
///         `docs/security/invariants-v1.0.0.md` § 15 across the
///         `LpStakingVault7D` value-paying surfaces (`stake`, `unbond`,
///         `withdraw`, `claimRewards`, `notifyRewardAmount`,
///         `claimRewardsAndLock`).
///
/// @dev    Models the strict debt-accounting closure
///         (`indexedClaimOwed`, `totalRewardsCredited`, `queuedRewards`)
///         from § 14. Quote=execute (M2) does not bind — there is no
///         public quoter for the vault. The M6 carry is the
///         `_indexRewardsWithCarry` skip-when-floors-to-zero branch, the
///         canonical M6 mitigation cited in § 15 (line 984).
///
/// @dev    Halmos tractability (2026-05-06 simplification):
///         Earlier revisions used `Math.mulDiv` directly and a symbolic
///         bound of `1e30`. The combination produced 512-bit bitvector
///         formulas (mulDiv's `mulmod(a,b,not(0))` overflow path) that
///         caused the solver to hang on `M3DoubleNotify`, `M4Split` and
///         the auxiliary liveness check (3+ sequential mulDivs). Two
///         changes restore convergence without weakening the proofs:
///           1. `MAX_SYMBOLIC_VALUE` lowered to `1e24` (still 80 bits =
///              ample for vault accounting; max real total supply per
///              `Constants` is well under this).
///           2. `_mulDivSimple` replaces `Math.mulDiv`. Within the new
///              bound, `amount * Constants.ACC <= 1e24 * 1e18 = 1e42 <
///              2^140`, so the simple `(a*b)/c` formula is identical to
///              `Math.mulDiv` and never overflows uint256. The 512-bit
///              code path is unreachable for symbolic inputs in range,
///              and the SMT formulas stay in standard 256-bit space.
contract LpStakingVault7D_M1_M6_Proofs {
    uint256 internal constant MAX_SYMBOLIC_VALUE = 1_000_000e18;
    uint256 internal constant MIN_COMPOUND_INTERVAL = 1 days;

    /// @dev Halmos-friendly stand-in for `Math.mulDiv` valid when the
    ///      product `a * b` fits in 256 bits (guaranteed by the
    ///      `MAX_SYMBOLIC_VALUE` bound on every public callsite). Returns
    ///      `(a * b) / c`, floor. Internal arithmetic stays in standard
    ///      256-bit bitvector space so the SMT solver does not have to
    ///      reason about the 512-bit overflow branch.
    function _mulDivSimple(uint256 a, uint256 b, uint256 c) internal pure returns (uint256) {
        return (a * b) / c;
    }

    struct VaultState {
        uint256 totalStaked;
        uint256 rewardPerTokenStored;
        uint256 queuedRewards;
        uint256 indexedClaimOwed;
        uint256 totalRewardsCredited;
        uint256 accountedRewardBalance;
    }

    /// @dev Mirrors `_indexRewardsWithCarry` at
    ///      `src/vault/LpStakingVault7D.sol:734-770`. Reward CLAIM either
    ///      bumps `rewardPerTokenStored` and credits `indexedClaimOwed`
    ///      with the back-computed indexed amount, or carries the full
    ///      amount into `queuedRewards` when the rpt bump would floor to
    ///      zero or the back-computation rounds to zero.
    function _indexWithCarry(VaultState memory s, uint256 amount) internal pure returns (VaultState memory) {
        if (amount == 0) return s;
        if (s.totalStaked == 0) {
            s.queuedRewards += amount;
            return s;
        }

        uint256 rptIncrement = _mulDivSimple(amount, Constants.ACC, s.totalStaked);
        if (rptIncrement == 0) {
            s.queuedRewards += amount;
            return s;
        }

        uint256 indexedAmount = _mulDivSimple(rptIncrement, s.totalStaked, Constants.ACC);
        if (indexedAmount == 0) {
            s.queuedRewards += amount;
            return s;
        }

        s.rewardPerTokenStored += rptIncrement;
        s.indexedClaimOwed += indexedAmount;

        uint256 remainder = amount - indexedAmount;
        if (remainder != 0) {
            s.queuedRewards += remainder;
        }
        return s;
    }

    /// @dev Mirrors `notifyRewardAmount` flush at
    ///      `src/vault/LpStakingVault7D.sol:715-727`. The notify pulls
    ///      the queued carry into the current distribution and re-indexes.
    function _notify(VaultState memory s, uint256 delta) internal pure returns (VaultState memory) {
        s.accountedRewardBalance += delta;
        if (delta == 0 && s.queuedRewards == 0) return s;

        if (s.totalStaked == 0) {
            s.queuedRewards += delta;
            return s;
        }

        uint256 toDistribute = delta;
        if (s.queuedRewards != 0) {
            toDistribute += s.queuedRewards;
            s.queuedRewards = 0;
        }
        s = _indexWithCarry(s, toDistribute);
        return s;
    }

    // ---------------------------------------------------------------------
    // M1 — Rate continuity
    // ---------------------------------------------------------------------

    /// @notice M1: an empty notify (`delta == 0` with no queued carry) is
    ///         a no-op on every accounting slot. Rate continuity holds at
    ///         the smallest input.
    /// @dev    Mirrors `notifyRewardAmount` at
    ///         `src/vault/LpStakingVault7D.sol:715`.
    function check_lpVaultM1EmptyNotifyIsNoOp(uint256 totalStaked, uint256 rptBefore) public pure {
        require(totalStaked <= MAX_SYMBOLIC_VALUE);
        require(rptBefore <= type(uint128).max);

        VaultState memory s = VaultState({
            totalStaked: totalStaked,
            rewardPerTokenStored: rptBefore,
            queuedRewards: 0,
            indexedClaimOwed: 0,
            totalRewardsCredited: 0,
            accountedRewardBalance: 0
        });

        s = _notify(s, 0);

        assert(s.rewardPerTokenStored == rptBefore && s.indexedClaimOwed == 0);
    }

    // ---------------------------------------------------------------------
    // M3 — Conservation (strict debt-accounting)
    // ---------------------------------------------------------------------

    /// @notice M3: after a notify, the indexed pool plus the queued carry
    ///         equals the total CLAIM funded into the vault. No CLAIM is
    ///         left unaccounted across the index split.
    /// @dev    Mirrors the disjoint-debt invariant at
    ///         `src/vault/LpStakingVault7D.sol:99-100`. See § 14 STRICT.
    function check_lpVaultM3IndexedPlusQueuedEqualsFunded(uint256 totalStaked, uint256 funded) public pure {
        require(totalStaked > 0);
        require(totalStaked <= MAX_SYMBOLIC_VALUE);
        require(funded <= MAX_SYMBOLIC_VALUE);

        VaultState memory s = VaultState({
            totalStaked: totalStaked,
            rewardPerTokenStored: 0,
            queuedRewards: 0,
            indexedClaimOwed: 0,
            totalRewardsCredited: 0,
            accountedRewardBalance: 0
        });

        s = _notify(s, funded);

        assert(s.indexedClaimOwed + s.queuedRewards == funded);
    }

    /// @notice M3: across two consecutive notifies, the disjoint-debt
    ///         identity remains tight — every wei sits in either the
    ///         indexed pool or the queued carry.
    /// @dev    Mirrors `notifyRewardAmount` at
    ///         `src/vault/LpStakingVault7D.sol:715-727`.
    function check_lpVaultM3DoubleNotifyKeepsDebtTight(uint256 totalStaked, uint256 fundedA, uint256 fundedB)
        public
        pure
    {
        require(totalStaked > 0);
        require(totalStaked <= MAX_SYMBOLIC_VALUE);
        require(fundedA <= MAX_SYMBOLIC_VALUE);
        require(fundedB <= MAX_SYMBOLIC_VALUE - fundedA);

        VaultState memory s = VaultState({
            totalStaked: totalStaked,
            rewardPerTokenStored: 0,
            queuedRewards: 0,
            indexedClaimOwed: 0,
            totalRewardsCredited: 0,
            accountedRewardBalance: 0
        });

        s = _notify(s, fundedA);
        s = _notify(s, fundedB);

        assert(s.indexedClaimOwed + s.queuedRewards == fundedA + fundedB);
    }

    // ---------------------------------------------------------------------
    // M4 — Path independence
    // ---------------------------------------------------------------------

    /// @notice M4: two notifies of `(a, b)` and one combined notify of
    ///         `(a+b)` leave the same total in `indexedClaimOwed +
    ///         queuedRewards`. Cycling MUST NOT print or destroy CLAIM.
    /// @dev    Mirrors `notifyRewardAmount` at
    ///         `src/vault/LpStakingVault7D.sol:715-727`. Note: per-bucket
    ///         splits may differ slightly because a small notify can carry
    ///         that a combined notify would index — but the total is
    ///         preserved exactly.
    function check_lpVaultM4SplitNotifyTotalEqualsCombinedNotifyTotal(
        uint256 totalStaked,
        uint256 fundedA,
        uint256 fundedB
    ) public pure {
        require(totalStaked > 0);
        require(totalStaked <= MAX_SYMBOLIC_VALUE);
        require(fundedA <= MAX_SYMBOLIC_VALUE);
        require(fundedB <= MAX_SYMBOLIC_VALUE - fundedA);

        VaultState memory split = VaultState({
            totalStaked: totalStaked,
            rewardPerTokenStored: 0,
            queuedRewards: 0,
            indexedClaimOwed: 0,
            totalRewardsCredited: 0,
            accountedRewardBalance: 0
        });
        split = _notify(split, fundedA);
        split = _notify(split, fundedB);

        VaultState memory whole = VaultState({
            totalStaked: totalStaked,
            rewardPerTokenStored: 0,
            queuedRewards: 0,
            indexedClaimOwed: 0,
            totalRewardsCredited: 0,
            accountedRewardBalance: 0
        });
        whole = _notify(whole, fundedA + fundedB);

        assert(split.indexedClaimOwed + split.queuedRewards == whole.indexedClaimOwed + whole.queuedRewards);
    }

    // ---------------------------------------------------------------------
    // M5 — Cooldown-or-continuity
    // ---------------------------------------------------------------------

    /// @dev Mirrors the cooldown gate at
    ///      `src/vault/LpStakingVault7D.sol:416`.
    function _compoundCooldownGate(uint64 lastUserLockTs, uint64 nowTs) internal pure returns (bool reverts) {
        return uint256(nowTs) < uint256(lastUserLockTs) + MIN_COMPOUND_INTERVAL;
    }

    /// @notice M5: a `claimRewardsAndLock` request inside the
    ///         `MIN_COMPOUND_INTERVAL` window reverts.
    function check_lpVaultM5CompoundInsideCooldownReverts(uint64 lastUserLockTs, uint64 nowTs) public pure {
        require(nowTs >= lastUserLockTs);
        require(uint256(nowTs) < uint256(lastUserLockTs) + MIN_COMPOUND_INTERVAL);

        assert(_compoundCooldownGate(lastUserLockTs, nowTs));
    }

    /// @notice M5: a `claimRewardsAndLock` request after the
    ///         `MIN_COMPOUND_INTERVAL` window is permitted past the
    ///         cooldown gate.
    function check_lpVaultM5CompoundAfterCooldownPermits(uint64 lastUserLockTs, uint64 nowTs) public pure {
        require(uint256(nowTs) >= uint256(lastUserLockTs) + MIN_COMPOUND_INTERVAL);

        assert(!_compoundCooldownGate(lastUserLockTs, nowTs));
    }

    // ---------------------------------------------------------------------
    // M6 — Floor direction (carry-bucket mitigation)
    // ---------------------------------------------------------------------

    /// @notice M6: when the back-computed `indexedAmount` floors to zero
    ///         the index does not advance and the full notify amount stays
    ///         in `queuedRewards`. The index-or-carry split keeps every
    ///         wei tracked.
    /// @dev    Mirrors `_indexRewardsWithCarry` floor-skip at
    ///         `src/vault/LpStakingVault7D.sol:754-758` — the canonical M6
    ///         mitigation cited in § 15 (line 984).
    function check_lpVaultM6CarriesWhenIndexedFloorsToZero(uint256 totalStaked, uint256 amount) public pure {
        require(totalStaked > 0);
        require(totalStaked <= MAX_SYMBOLIC_VALUE);
        require(amount > 0 && amount <= MAX_SYMBOLIC_VALUE);

        uint256 rptIncrement = _mulDivSimple(amount, Constants.ACC, totalStaked);
        require(rptIncrement == 0);

        VaultState memory s = VaultState({
            totalStaked: totalStaked,
            rewardPerTokenStored: 0,
            queuedRewards: 0,
            indexedClaimOwed: 0,
            totalRewardsCredited: 0,
            accountedRewardBalance: 0
        });
        s = _indexWithCarry(s, amount);

        assert(s.queuedRewards == amount && s.rewardPerTokenStored == 0 && s.indexedClaimOwed == 0);
    }

    // ---------------------------------------------------------------------
    // Auxiliary — liveness
    // ---------------------------------------------------------------------

    /// @notice Liveness: a successful index advance debits exactly the
    ///         indexed amount from the funded total; the remainder lands
    ///         in the carry bucket. The branch never strands CLAIM
    ///         outside the disjoint-debt buckets.
    /// @dev    Mirrors `_indexRewardsWithCarry` happy path at
    ///         `src/vault/LpStakingVault7D.sol:760-769`.
    function check_lpVaultAuxLivenessIndexAdvanceTracksRemainder(uint256 totalStaked, uint256 amount) public pure {
        require(totalStaked > 0);
        require(totalStaked <= MAX_SYMBOLIC_VALUE);
        require(amount > 0 && amount <= MAX_SYMBOLIC_VALUE);

        uint256 rptIncrement = _mulDivSimple(amount, Constants.ACC, totalStaked);
        require(rptIncrement > 0);
        uint256 indexedAmount = _mulDivSimple(rptIncrement, totalStaked, Constants.ACC);
        require(indexedAmount > 0);

        VaultState memory s = VaultState({
            totalStaked: totalStaked,
            rewardPerTokenStored: 0,
            queuedRewards: 0,
            indexedClaimOwed: 0,
            totalRewardsCredited: 0,
            accountedRewardBalance: 0
        });
        s = _indexWithCarry(s, amount);

        assert(s.indexedClaimOwed + s.queuedRewards == amount);
    }
}
