// SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

/// @notice Canonical permission bitmask for DelegationHub sessions.
/// @dev Bit positions are ABI/stability sensitive once deployed.
library DelegationPermissions {
    // MineCore

    /// @notice Delegate may execute a takeover on behalf of the king identity.
    uint256 internal constant P_TAKEOVER_FOR = 1 << 0;

    /// @notice When a delegated takeover starts a reign, allow routing the reign's King-stream CLAIM
    ///         to the delegate (caller) instead of the king identity.
    /// @dev High risk: routes mined CLAIM away from the user.
    uint256 internal constant P_ROUTE_REIGN_CLAIM_TO_CALLER = 1 << 1;

    /// @notice Delegate may change the current reign's ETH recipient to an arbitrary address.
    /// @dev High risk: can redirect the dethroned-King 75% ETH share.
    uint256 internal constant P_SET_REIGN_ETH_RECIPIENT = 1 << 2;

    /// @notice Constrained variant: delegate may set the current reign's ETH recipient only to themselves.
    /// @dev Allows a "looping" bot (msg.sender) but not arbitrary third parties.
    uint256 internal constant P_SET_REIGN_ETH_RECIPIENT_TO_CALLER_ONLY = 1 << 3;

    /// @notice Delegate may change the current reign's CLAIM recipient to an arbitrary address.
    /// @dev High risk: can redirect mined King-stream CLAIM.
    uint256 internal constant P_SET_REIGN_CLAIM_RECIPIENT = 1 << 4;

    /// @notice Constrained variant: delegate may set the current reign's CLAIM recipient only to the king identity.
    /// @dev Prevents CLAIM diversion while still allowing a delegate to restore routing to the user.
    uint256 internal constant P_SET_REIGN_CLAIM_RECIPIENT_TO_USER_ONLY = 1 << 5;

    // ClaimAllHelper (harvest wrappers)

    /// @notice Delegate may withdraw the king ETH bucket on behalf of a user.
    uint256 internal constant P_WITHDRAW_KING_BUCKET_FOR = 1 << 6;

    /// @notice Delegate may claim shareholder ETH on behalf of a user.
    uint256 internal constant P_CLAIM_SHAREHOLDER_FOR = 1 << 7;

    /// @notice Delegate may run a bundled "claim all" flow on behalf of a user.
    uint256 internal constant P_CLAIM_ALL_FOR = 1 << 8;

    // Furnace

    /// @notice Delegate may enter the Furnace for a user using ETH paid by the delegate.
    uint256 internal constant P_FURNACE_ENTER_ETH_FOR = 1 << 9;

    /// @notice Delegate may enter the Furnace for a user using CLAIM paid by the delegate.
    uint256 internal constant P_FURNACE_ENTER_CLAIM_FOR = 1 << 10;

    /// @notice Delegate may enter the Furnace for a user using an allowlisted token paid by the delegate.
    uint256 internal constant P_FURNACE_ENTER_TOKEN_FOR = 1 << 11;

    // VeClaimNFT lock maintenance
    // (bit 12 is enforced in Furnace.extendWithBonusFor, which calls VeClaimNFT.extendLockToFor;
    //  bit 13 is enforced in Furnace.mergeLocksWithBonusFor, which calls VeClaimNFT.mergeLocksFor;
    //  bit 14 is enforced directly in VeClaimNFT.)

    /// @notice Delegate may extend an existing ve lock on behalf of the lock owner.
    /// @dev Enforced in Furnace (extendWithBonusFor); the permission gates the
    ///      Furnace-orchestrated extend-with-bonus flow, which ultimately calls
    ///      VeClaimNFT.extendLockToFor.
    /// @dev Safe/non-custodial: does not transfer tokens and cannot redirect value.
    uint256 internal constant P_VE_EXTEND_LOCK_FOR = 1 << 12;

    /// @notice Delegate may merge two locks on behalf of the lock owner.
    /// @dev Enforced in Furnace (mergeLocksWithBonusFor); the permission gates the
    ///      Furnace-orchestrated merge-with-bonus flow, which ultimately calls
    ///      VeClaimNFT.mergeLocksFor. The bonus accrues to the surviving lock — the
    ///      delegate cannot redirect value.
    /// @dev Safe/non-custodial: does not transfer tokens and cannot redirect value.
    uint256 internal constant P_VE_MERGE_LOCKS_FOR = 1 << 13;

    /// @notice Delegate may unlock an expired lock on behalf of the lock owner (CLAIM returns to the owner).
    /// @dev Safe/non-custodial: CLAIM is returned to the lock owner, not the delegate.
    uint256 internal constant P_VE_UNLOCK_EXPIRED_FOR = 1 << 14;

    // Settings / config (safe, non-custodial)

    /// @notice Delegate may set MineCore king auto-lock config for a user.
    /// @dev Safe/non-custodial: config-only and enforces user-owned veNFTs.
    uint256 internal constant P_SET_KING_AUTO_LOCK_CONFIG_FOR = 1 << 15;

    /// @notice Delegate may set ShareholderRoyalties auto-compound config for a user.
    /// @dev Safe/non-custodial: config-only and enforces user-owned veNFTs.
    uint256 internal constant P_SET_SHAREHOLDER_AUTOCOMPOUND_CONFIG_FOR = 1 << 16;

    /// @notice Delegate may set LpStakingVault7D auto-compound config for a user.
    /// @dev Safe/non-custodial: config-only and enforces user-owned veNFTs.
    uint256 internal constant P_SET_LP_AUTOCOMPOUND_CONFIG_FOR = 1 << 17;

    // ClaimAllHelper (value routing)

    /// @notice Constrained variant: when a delegate collects shareholder ETH for a user, allow
    ///         routing that ETH to the delegate (caller) instead of the user.
    /// @dev High risk: redirects the user's Baron ETH to the caller. Caller-only by construction
    ///      (the helper routes to `msg.sender`), mirroring the constrained `*_TO_CALLER_ONLY`
    ///      reign precedent — there is no arbitrary-recipient variant.
    uint256 internal constant P_ROUTE_SHAREHOLDER_ETH_TO_CALLER = 1 << 18;

    // Helpers

    /// @notice Canonical mask of all defined permission bits.
    /// @dev Used on-chain by DelegationHub._setSession() to reject unknown bits.
    ///      Also used off-chain by UI/SDK for convenience.
    ///
    ///      IMPORTANT: When adding a new permission bit, you MUST update this mask.
    ///      Failure to do so will cause DelegationHub to reject sessions requesting
    ///      the new permission. Add a test that asserts ALL == (1 << 19) - 1.
    uint256 internal constant ALL = P_TAKEOVER_FOR | P_ROUTE_REIGN_CLAIM_TO_CALLER | P_SET_REIGN_ETH_RECIPIENT
        | P_SET_REIGN_ETH_RECIPIENT_TO_CALLER_ONLY | P_SET_REIGN_CLAIM_RECIPIENT
        | P_SET_REIGN_CLAIM_RECIPIENT_TO_USER_ONLY | P_WITHDRAW_KING_BUCKET_FOR | P_CLAIM_SHAREHOLDER_FOR
        | P_CLAIM_ALL_FOR | P_FURNACE_ENTER_ETH_FOR | P_FURNACE_ENTER_CLAIM_FOR | P_FURNACE_ENTER_TOKEN_FOR
        | P_VE_EXTEND_LOCK_FOR | P_VE_MERGE_LOCKS_FOR | P_VE_UNLOCK_EXPIRED_FOR | P_SET_KING_AUTO_LOCK_CONFIG_FOR
        | P_SET_SHAREHOLDER_AUTOCOMPOUND_CONFIG_FOR | P_SET_LP_AUTOCOMPOUND_CONFIG_FOR
        | P_ROUTE_SHAREHOLDER_ETH_TO_CALLER;
}
