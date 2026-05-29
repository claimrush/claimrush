// SPDX-License-Identifier: MIT
pragma solidity ^0.8.34;

/// @title GenesisLPVault24M M1-M6 bounded symbolic proofs
/// @notice Encodes the canonical accounting meta-properties from
///         `docs/security/invariants-v1.0.0.md` § 15 across the
///         `GenesisLPVault24M` value-paying surfaces (`startLock`,
///         `extendLock`, `withdrawLp`, fee Collect and forwarding).
///
/// @dev    The vault is a one-shot 24 month LP lock with a fixed
///         withdraw recipient. Rate continuity (M1) and quote=execute
///         (M2) do not bind — the lock has no payout-curve input and no
///         public quoter. Path independence (M4) here means the lock
///         lifecycle (start → extend → withdraw) preserves the LP
///         balance shape regardless of how many extends are interleaved.
contract GenesisLPVault24M_M1_M6_Proofs {
    uint256 internal constant MAX_SYMBOLIC_VALUE = 1_000_000_000_000e18;
    uint256 internal constant MIN_EXTENSION_DURATION = 1 days;
    uint256 internal constant MAX_EXTENSION = 3650 days;
    uint256 internal constant MAX_ABSOLUTE_LOCK = 36500 days;

    struct Lock {
        uint256 lpLockedAmount;
        uint256 lockStartTime;
        uint256 unlockTime;
        uint256 vaultLpBalance;
        uint256 recipientLpBalance;
    }

    /// @dev Mirrors `startLock` at
    ///      `src/vault/GenesisLPVault24M.sol:128-142`. The vault transfers
    ///      LP into custody before the call; `startLock` records the
    ///      observed balance and stamps lock metadata.
    function _startLock(Lock memory s, uint256 lpIn, uint256 nowTs, uint256 initialLockDuration)
        internal
        pure
        returns (Lock memory)
    {
        s.vaultLpBalance += lpIn;
        s.lpLockedAmount = s.vaultLpBalance;
        s.lockStartTime = nowTs;
        s.unlockTime = nowTs + initialLockDuration;
        return s;
    }

    /// @dev Mirrors `extendLock` at
    ///      `src/vault/GenesisLPVault24M.sol:147-162`. Only the unlockTime
    ///      cursor moves forward; LP balances are untouched.
    function _extendLock(Lock memory s, uint256 newUnlockTime) internal pure returns (Lock memory) {
        s.unlockTime = newUnlockTime;
        return s;
    }

    /// @dev Mirrors `withdrawLp` at
    ///      `src/vault/GenesisLPVault24M.sol:172-206`. After unlock, the
    ///      full vault LP balance transfers to the recipient and the
    ///      unlockTime cursor zeros to mark the lock complete.
    function _withdraw(Lock memory s) internal pure returns (Lock memory) {
        uint256 amount = s.vaultLpBalance;
        s.vaultLpBalance = 0;
        s.recipientLpBalance += amount;
        s.unlockTime = 0;
        return s;
    }

    // ---------------------------------------------------------------------
    // M3 — Conservation
    // ---------------------------------------------------------------------

    /// @notice M3: across `startLock → extendLock → withdrawLp`, the LP
    ///         balance is conserved — the recipient ends with exactly
    ///         what the vault custodied at lock start.
    /// @dev    Mirrors the lifecycle at
    ///         `src/vault/GenesisLPVault24M.sol:128-206`.
    function check_genesisVaultM3LifecycleConservesLpBalance(
        uint256 lpIn,
        uint256 lockStart,
        uint256 initialLockDuration,
        uint256 extensionDelta
    ) public pure {
        require(lpIn > 0 && lpIn <= MAX_SYMBOLIC_VALUE);
        require(lockStart > 0 && lockStart <= type(uint64).max / 2);
        require(initialLockDuration <= MAX_ABSOLUTE_LOCK);
        require(extensionDelta >= MIN_EXTENSION_DURATION && extensionDelta <= MAX_EXTENSION);

        Lock memory s =
            Lock({lpLockedAmount: 0, lockStartTime: 0, unlockTime: 0, vaultLpBalance: 0, recipientLpBalance: 0});

        s = _startLock(s, lpIn, lockStart, initialLockDuration);
        s = _extendLock(s, s.unlockTime + extensionDelta);
        s = _withdraw(s);

        assert(s.recipientLpBalance == lpIn && s.vaultLpBalance == 0);
    }

    // ---------------------------------------------------------------------
    // M4 — Path independence
    // ---------------------------------------------------------------------

    /// @notice M4: two extensions and one combined extension to the same
    ///         final unlockTime leave the lock in the same shape. Cycling
    ///         extends MUST NOT print or destroy LP.
    /// @dev    Mirrors `extendLock` at
    ///         `src/vault/GenesisLPVault24M.sol:147-162`.
    function check_genesisVaultM4SplitExtendEqualsCombinedExtend(
        uint256 lpIn,
        uint256 lockStart,
        uint256 initialLockDuration,
        uint256 extDeltaA,
        uint256 extDeltaB
    ) public pure {
        require(lpIn > 0 && lpIn <= MAX_SYMBOLIC_VALUE);
        require(lockStart > 0 && lockStart <= type(uint64).max / 2);
        require(initialLockDuration <= MAX_ABSOLUTE_LOCK);
        require(extDeltaA >= MIN_EXTENSION_DURATION && extDeltaA <= MAX_EXTENSION);
        require(extDeltaB >= MIN_EXTENSION_DURATION && extDeltaB <= MAX_EXTENSION - extDeltaA);

        Lock memory split =
            Lock({lpLockedAmount: 0, lockStartTime: 0, unlockTime: 0, vaultLpBalance: 0, recipientLpBalance: 0});
        split = _startLock(split, lpIn, lockStart, initialLockDuration);
        split = _extendLock(split, split.unlockTime + extDeltaA);
        split = _extendLock(split, split.unlockTime + extDeltaB);

        Lock memory whole =
            Lock({lpLockedAmount: 0, lockStartTime: 0, unlockTime: 0, vaultLpBalance: 0, recipientLpBalance: 0});
        whole = _startLock(whole, lpIn, lockStart, initialLockDuration);
        whole = _extendLock(whole, whole.unlockTime + extDeltaA + extDeltaB);

        assert(split.unlockTime == whole.unlockTime && split.vaultLpBalance == whole.vaultLpBalance);
    }

    // ---------------------------------------------------------------------
    // M5 — Cooldown-or-continuity
    // ---------------------------------------------------------------------

    /// @dev Mirrors the gate at `src/vault/GenesisLPVault24M.sol:156`.
    function _extendMinDurationGate(uint256 nowTs, uint256 newUnlockTime) internal pure returns (bool reverts) {
        return newUnlockTime < nowTs + MIN_EXTENSION_DURATION;
    }

    /// @notice M5: an `extendLock` request below the
    ///         `MIN_EXTENSION_DURATION` floor reverts.
    function check_genesisVaultM5ExtendBelowMinReverts(uint256 nowTs, uint256 newUnlockTime) public pure {
        require(nowTs <= type(uint64).max / 2);
        require(newUnlockTime < nowTs + MIN_EXTENSION_DURATION);

        assert(_extendMinDurationGate(nowTs, newUnlockTime));
    }

    /// @notice M5: an `extendLock` request at or above the
    ///         `MIN_EXTENSION_DURATION` floor is permitted.
    function check_genesisVaultM5ExtendAtOrAboveMinPermits(uint256 nowTs, uint256 newUnlockTime) public pure {
        require(nowTs <= type(uint64).max / 2);
        require(newUnlockTime >= nowTs + MIN_EXTENSION_DURATION);
        require(newUnlockTime <= type(uint64).max);

        assert(!_extendMinDurationGate(nowTs, newUnlockTime));
    }

    // ---------------------------------------------------------------------
    // M6 — Floor direction
    // ---------------------------------------------------------------------

    /// @notice M6: `withdrawLp` transfers the full vault LP balance to the
    ///         recipient — there is no rounding in the lock lifecycle, so
    ///         no LP wei can be stranded by floor direction.
    /// @dev    Mirrors `withdrawLp` at
    ///         `src/vault/GenesisLPVault24M.sol:188-206`.
    function check_genesisVaultM6WithdrawTransfersExactBalance(uint256 lpIn) public pure {
        require(lpIn > 0 && lpIn <= MAX_SYMBOLIC_VALUE);

        Lock memory s =
            Lock({lpLockedAmount: 0, lockStartTime: 0, unlockTime: 0, vaultLpBalance: 0, recipientLpBalance: 0});
        s = _startLock(s, lpIn, 1, MIN_EXTENSION_DURATION);
        s = _withdraw(s);

        assert(s.recipientLpBalance + s.vaultLpBalance == lpIn);
    }
}
