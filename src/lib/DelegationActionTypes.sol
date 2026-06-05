// SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

/// @notice Canonical action type ids for delegated (session-gated) protocol actions.
/// @dev Used by `Events.DelegationSessionUsed` for indexing, reviews, and alerts.
library DelegationActionTypes {
    // MineCore

    /// @notice Delegated MineCore takeover for a user identity.
    /// @dev Risk mirrors `P_TAKEOVER_FOR`; if paired with `P_ROUTE_REIGN_CLAIM_TO_CALLER`,
    ///      the emitted `permsUsed` includes the higher-risk CLAIM-routing bit.
    uint8 internal constant TAKEOVER_FOR = 1;

    /// @notice Delegated update of current-reign ETH and/or CLAIM recipients.
    /// @dev Risk depends on `permsUsed`: broad recipient bits are high risk, while constrained
    ///      caller/user-only variants are lower risk and enforced by MineCore.
    uint8 internal constant MINECORE_SET_REIGN_RECIPIENTS = 2;

    // ClaimAllHelper

    /// @notice Delegated shareholder reward claim through ClaimAllHelper.
    /// @dev Medium risk: harvest action is performed by a delegate but value routes through
    ///      the protocol's existing user-owned claim path.
    uint8 internal constant CLAIM_SHAREHOLDER_FOR = 10;

    /// @notice Delegated withdrawal of a user's King ETH bucket through ClaimAllHelper.
    /// @dev Medium risk: harvest action is performed by a delegate; ETH is withdrawn using
    ///      MineCore's user-directed helper path.
    uint8 internal constant WITHDRAW_KING_BUCKET_FOR = 11;

    /// @notice Delegated bundled shareholder claim and King bucket withdrawal.
    /// @dev Medium risk: combines the delegated harvest surfaces represented by IDs 10 and 11.
    uint8 internal constant CLAIM_ALL_FOR = 12;

    /// @notice Delegated shareholder reward claim routed to the caller (looping bot).
    /// @dev High risk: redirects the user's Baron ETH to the delegate (`msg.sender`). Gated by
    ///      `P_CLAIM_SHAREHOLDER_FOR | P_ROUTE_SHAREHOLDER_ETH_TO_CALLER`.
    uint8 internal constant CLAIM_SHAREHOLDER_TO_CALLER_FOR = 13;

    // Furnace

    /// @notice Delegated Furnace entry where the delegate supplies ETH.
    /// @dev Safe/non-custodial: the resulting veCLAIM position is owned by the user.
    uint8 internal constant FURNACE_ENTER_WITH_ETH_FOR = 20;

    /// @notice Delegated Furnace entry where the delegate supplies CLAIM.
    /// @dev Safe/non-custodial: the resulting veCLAIM position is owned by the user.
    uint8 internal constant FURNACE_ENTER_WITH_CLAIM_FOR = 21;

    /// @notice Delegated Furnace entry where the delegate supplies an allowlisted token.
    /// @dev Safe/non-custodial: the resulting veCLAIM position is owned by the user.
    uint8 internal constant FURNACE_ENTER_WITH_TOKEN_FOR = 22;

    // VeClaimNFT lock maintenance
    // (ids 30-31 are emitted by Furnace.{extendWithBonusFor, mergeLocksWithBonusFor};
    //  id 32 is emitted by VeClaimNFT directly.)

    /// @notice Delegated ve lock extension via Furnace bonus extension flow.
    /// @dev Safe/non-custodial: does not transfer lock ownership or redirect value.
    uint8 internal constant VE_EXTEND_LOCK_FOR = 30;

    /// @notice Delegated merge of two user-owned ve locks via Furnace bonus merge flow.
    /// @dev Safe/non-custodial: both locks must belong to the delegated user; bonus accrues
    ///      to the surviving lock (still owned by `user`).
    uint8 internal constant VE_MERGE_LOCKS_FOR = 31;

    /// @notice Delegated unlock of an expired user-owned ve lock.
    /// @dev Safe/non-custodial: unlocked CLAIM returns to the user, not the delegate.
    uint8 internal constant VE_UNLOCK_EXPIRED_FOR = 32;

    // Settings / config (safe, non-custodial)

    /// @notice Delegated MineCore king auto-lock config update.
    /// @dev Safe/non-custodial: config-only and still enforces user-owned veNFTs.
    uint8 internal constant MINECORE_SET_KING_AUTO_LOCK_CONFIG_FOR = 40;

    /// @notice Delegated ShareholderRoyalties autocompound config update.
    /// @dev Safe/non-custodial: config-only and still enforces user-owned veNFTs.
    uint8 internal constant SHAREHOLDER_SET_AUTOCOMPOUND_CONFIG_FOR = 41;

    /// @notice Delegated LP staking vault autocompound config update.
    /// @dev Safe/non-custodial: config-only and still enforces user-owned veNFTs.
    uint8 internal constant LP_STAKING_SET_AUTOCOMPOUND_CONFIG_FOR = 42;
}
