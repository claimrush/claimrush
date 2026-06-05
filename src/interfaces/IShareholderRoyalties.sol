// SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

// ShareholderRoyalties ABI functions intentionally absent from this interface:
//
//   Admin/owner setters (intentionally omitted — acceptable):
//     freezeConfig, setWiring, setClaimAllHelper, setAutoCompoundKeeper,
//     acceptOwnership, renounceOwnership, transferOwnership,
//     sweepDust (owner-only dust recovery for rounding remainders)
//
//   Public state variable getters (auto-generated — acceptable):
//     configFrozen, mineCore, mineMarket, claimAllHelper,
//     ethPerVe, furnace, isAutoCompoundKeeper, owner, pendingOwner,
//     pendingShareholderETH, userEthPerVePaid, ve
//

/// @notice ShareholderRoyalties external interface (pinned).
/// @dev MUST match docs/spec/spec-v1.0.0.md and shipped ABIs.
interface IShareholderRoyalties {
    /// @notice Takeover allocation entrypoint.
    /// @dev Canonical path: records `msg.value` and immediately attempts shareholder indexing
    ///      against the current processed ve denominator so later entrants cannot dilute older
    ///      takeover allocations.
    function onTakeover(uint256 reignId) external payable;

    /// @notice Fallback for when onTakeover fails during takeover (best-effort royalties).
    /// @dev Also attempts immediate indexing on retry.
    function addPendingShareholderETH(uint256 reignId) external payable;

    function flushPendingShareholderETH() external;
    function checkpointUser(address user) external;
    function checkpointUserBatch(address[] calldata users, uint256 maxUsers) external;
    function checkpointTransfer(address from, address to) external;

    // mode: 0 = ETH, 1 = LOCK_FURNACE
    function claimShareholder(
        uint8 mode,
        uint256 targetTokenId,
        uint256 durationSeconds,
        bool createAutoMax,
        uint256 minVeOut
    ) external;

    /// @notice Helper-only entrypoint to claim for a user (used by ClaimAllHelper).
    /// @dev MUST preserve `claimShareholder` semantics, but attribute the claim to `user`.
    function claimShareholderFor(
        address user,
        uint8 mode,
        uint256 targetTokenId,
        uint256 durationSeconds,
        bool createAutoMax,
        uint256 minVeOut
    ) external;

    /// @notice Helper-only entrypoint to collect `user`'s Baron ETH and route it to `to`.
    /// @dev ETH-only looping-bot routing path; delegation + caller-only gate enforced in ClaimAllHelper.
    function claimShareholderForTo(address user, address payable to) external;

    /// @notice Live shareholder claim preview.
    /// @dev `claimable` is authoritative and already includes any uncheckpointed rewards implied by
    ///      historical reward checkpoints. Offchain clients MUST NOT derive a separate
    ///      `currentVe * (ethPerVe - paid)` term for decaying locks.
    function getShareholderState(address user) external view returns (uint256 claimable, uint256 userVe, uint256 paid);

    // ------------------------------------------------------------
    // Keeper-allowlisted auto-compound with owner break-glass (SPEC v1.0.0 §6.7)
    // ------------------------------------------------------------

    function setAutoCompoundConfig(
        bool enabled,
        uint256 tokenId,
        uint256 durationSeconds,
        uint32 minCadenceSeconds,
        uint256 minEthToCompound,
        uint32 maxSlippageBps
    ) external;

    function setAutoCompoundConfigForUser(
        address user,
        bool enabled,
        uint256 tokenId,
        uint256 durationSeconds,
        uint32 minCadenceSeconds,
        uint256 minEthToCompound,
        uint32 maxSlippageBps
    ) external;

    function getAutoCompoundConfig(address user)
        external
        view
        returns (
            bool enabled,
            bool paused,
            uint256 tokenId,
            uint256 durationSeconds,
            uint32 minCadenceSeconds,
            uint256 minEthToCompound,
            uint32 maxSlippageBps,
            uint40 lastCompoundTs
        );

    function minAutoCompoundEth() external view returns (uint256);

    function setMinAutoCompoundEth(uint256 floor) external;

    function compoundFor(address user) external;

    function compoundForMany(address[] calldata users, uint256 maxUsers) external;

    function claimShareholderTo(
        address payable to,
        uint8 mode,
        uint256 targetTokenId,
        uint256 durationSeconds,
        bool createAutoMax,
        uint256 minVeOut
    ) external;

    function claimableEth(address user) external view returns (uint256);

    /// @notice Refresh the per-user observed-min for `user` against the live ve
    ///         lock set; narrows the global watermark when the observation
    ///         reveals a tighter floor.
    /// @dev Permissionless. The `_createLock` and `_extendLock` paths in
    ///      VeClaimNFT call this immediately after the lock change so a fresh
    ///      shorter non-AutoMax lock is observed before the next reward delta.
    function pinUserObservedMin(address user) external;
}

