// SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

/// @notice DelegationHub external interface.
/// @dev Protocol-internal callers (Furnace, MineCore, MarketRouter,
///      ShareholderRoyalties, VeClaimNFT, ClaimAllHelper) check delegation via
///      `isAuthorized(user, delegate, perms)`.
///
///      User/admin-facing actions (session set, revoke, EIP-712 signed set)
///      are part of the pinned ABI surface and are consumed by the frontend.
interface IDelegationHub {
    function nonces(address user) external view returns (uint256);

    function getSession(address user, address delegate) external view returns (uint256 perms, uint256 expiry);

    /// @notice Returns true if `delegate` is authorized to act for `user` with all `requiredPerms`.
    function isAuthorized(address user, address delegate, uint256 requiredPerms) external view returns (bool);

    function setSession(address delegate, uint256 perms, uint64 expiry) external;

    function revokeSession(address delegate) external;

    function setSessionBySig(
        address user,
        address delegate,
        uint256 perms,
        uint64 expiry,
        uint256 nonce,
        uint256 deadline,
        bytes calldata sig
    ) external;
}
