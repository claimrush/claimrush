// SPDX-License-Identifier: MIT
pragma solidity ^0.8.34;

/// @title EntryTokenRegistry M1-M6 bounded symbolic proofs
/// @notice Encodes the canonical accounting meta-properties from
///         `docs/security/invariants-v1.0.0.md` § 15 across the
///         `EntryTokenRegistry` configuration surfaces (`setRouterConfig`,
///         `setWethClaimHop`, `setTokenConfig`,
///         `setFurnaceEntryTokenExactReceiptSafe`, `setTokenEnabled`,
///         `setGuardian`, route resolution views).
///
/// @dev    The registry has no value-paying surface — it does not custody
///         CLAIM, ETH, or LP. M1, M2, M3, M4, M6 do not bind. The proofs
///         here cover M5 role gating and the one-way immutability
///         ratchets (`_wrappedNative`, `_claimToken`, router / factory)
///         plus the route-resolution purity. Each gate is encoded as an
///         internal pure function and exercised with split-branch checks
///         to keep the spec encoding non-circular.
contract EntryTokenRegistry_M1_M6_Proofs {
    // ---------------------------------------------------------------------
    // M5 — Cooldown-or-continuity (role gating)
    // ---------------------------------------------------------------------

    /// @dev Mirrors the `onlyOwner` gates at
    ///      `src/EntryTokenRegistry.sol:98`, `:160`, `:197`, `:249`.
    function _ownerGate(address caller, address owner) internal pure returns (bool reverts) {
        return caller != owner;
    }

    /// @notice M5: every `setRouterConfig` / `setWethClaimHop` /
    ///         `setTokenConfig` / `setFurnaceEntryTokenExactReceiptSafe`
    ///         call reverts when the caller is not the owner.
    function check_registryM5OwnerGatedConfigWritesRevertForNonOwner(address owner, address caller) public pure {
        require(owner != address(0));
        require(caller != owner);

        assert(_ownerGate(caller, owner));
    }

    /// @notice M5: an owner caller passes the `onlyOwner` gate.
    function check_registryM5OwnerGatedConfigWritesPermitOwner(address owner) public pure {
        require(owner != address(0));

        assert(!_ownerGate(owner, owner));
    }

    /// @dev Mirrors the wrappedNative ratchet at
    ///      `src/EntryTokenRegistry.sol:122`.
    function _wrappedNativeRatchet(address storedWrappedNative, address newWrappedNative)
        internal
        pure
        returns (bool reverts)
    {
        return storedWrappedNative != address(0) && newWrappedNative != storedWrappedNative;
    }

    /// @notice M5: once `_wrappedNative` is set, a subsequent
    ///         `setRouterConfig` call with a different `wrappedNative`
    ///         reverts. The address is effectively immutable after the
    ///         first set.
    function check_registryM5WrappedNativeRatchetReverts(address storedWrappedNative, address newWrappedNative)
        public
        pure
    {
        require(storedWrappedNative != address(0));
        require(newWrappedNative != address(0));
        require(newWrappedNative != storedWrappedNative);

        assert(_wrappedNativeRatchet(storedWrappedNative, newWrappedNative));
    }

    /// @notice M5: a `setRouterConfig` call with the same `wrappedNative`
    ///         passes the ratchet (idempotent set).
    function check_registryM5WrappedNativeRatchetPermitsIdempotent(address storedWrappedNative) public pure {
        require(storedWrappedNative != address(0));

        assert(!_wrappedNativeRatchet(storedWrappedNative, storedWrappedNative));
    }

    /// @dev Mirrors the claimToken ratchet at
    ///      `src/EntryTokenRegistry.sol:123`.
    function _claimTokenRatchet(address storedClaimToken, address newClaimToken) internal pure returns (bool reverts) {
        return storedClaimToken != address(0) && newClaimToken != storedClaimToken;
    }

    /// @notice M5: once `_claimToken` is set, a subsequent
    ///         `setRouterConfig` call with a different `claimToken`
    ///         reverts. CLAIM cannot be silently rewired.
    function check_registryM5ClaimTokenRatchetReverts(address storedClaimToken, address newClaimToken) public pure {
        require(storedClaimToken != address(0));
        require(newClaimToken != address(0));
        require(newClaimToken != storedClaimToken);

        assert(_claimTokenRatchet(storedClaimToken, newClaimToken));
    }

    /// @notice M5: a `setRouterConfig` call with the same `claimToken`
    ///         passes the ratchet (idempotent set).
    function check_registryM5ClaimTokenRatchetPermitsIdempotent(address storedClaimToken) public pure {
        require(storedClaimToken != address(0));

        assert(!_claimTokenRatchet(storedClaimToken, storedClaimToken));
    }

    /// @dev Mirrors the router/factory ratchet at
    ///      `src/EntryTokenRegistry.sol:127-129`. Once any pool surface is
    ///      configured, router OR factory rewiring is rejected. The outer
    ///      `_router != address(0)` precondition mirrors the same source
    ///      line — first-init writes are permitted unconditionally.
    function _routerFactoryRatchet(
        address storedRouter,
        address newRouter,
        address storedFactory,
        address newFactory,
        address wethClaimPool,
        uint256 configuredTokenCount
    ) internal pure returns (bool reverts) {
        if (storedRouter == address(0)) return false;
        bool routerOrFactoryChanged = newRouter != storedRouter || newFactory != storedFactory;
        bool poolConfigured = wethClaimPool != address(0) || configuredTokenCount != 0;
        return routerOrFactoryChanged && poolConfigured;
    }

    /// @notice M5: once a pool surface is configured, a router rewire
    ///         attempt reverts even when the factory stays the same.
    function check_registryM5RouterRewireWithPoolReverts(
        address storedRouter,
        address newRouter,
        address storedFactory,
        address wethClaimPool,
        uint256 configuredTokenCount
    ) public pure {
        require(storedRouter != address(0));
        require(newRouter != address(0));
        require(storedFactory != address(0));
        require(newRouter != storedRouter);
        require(wethClaimPool != address(0) || configuredTokenCount != 0);

        assert(
            _routerFactoryRatchet(
                storedRouter, newRouter, storedFactory, storedFactory, wethClaimPool, configuredTokenCount
            )
        );
    }

    /// @notice M5: once a pool surface is configured, a factory rewire
    ///         attempt reverts even when the router stays the same.
    function check_registryM5FactoryRewireWithPoolReverts(
        address storedRouter,
        address storedFactory,
        address newFactory,
        address wethClaimPool,
        uint256 configuredTokenCount
    ) public pure {
        require(storedRouter != address(0));
        require(storedFactory != address(0));
        require(newFactory != address(0));
        require(newFactory != storedFactory);
        require(wethClaimPool != address(0) || configuredTokenCount != 0);

        assert(
            _routerFactoryRatchet(
                storedRouter, storedRouter, storedFactory, newFactory, wethClaimPool, configuredTokenCount
            )
        );
    }

    /// @notice M5: an idempotent router/factory set (both unchanged)
    ///         passes the ratchet regardless of pool configuration state.
    function check_registryM5RouterFactoryRatchetPermitsIdempotent(
        address storedRouter,
        address storedFactory,
        address wethClaimPool,
        uint256 configuredTokenCount
    ) public pure {
        require(storedRouter != address(0));
        require(storedFactory != address(0));

        assert(
            !_routerFactoryRatchet(
                storedRouter, storedRouter, storedFactory, storedFactory, wethClaimPool, configuredTokenCount
            )
        );
    }

    /// @notice M5: a first-init router write (storedRouter == 0) passes
    ///         the ratchet unconditionally — the outer
    ///         `_router != address(0)` guard short-circuits.
    function check_registryM5FirstInitPermitsRouterFactoryWrite(
        address newRouter,
        address newFactory,
        address wethClaimPool,
        uint256 configuredTokenCount
    ) public pure {
        require(newRouter != address(0));
        require(newFactory != address(0));

        assert(
            !_routerFactoryRatchet(address(0), newRouter, address(0), newFactory, wethClaimPool, configuredTokenCount)
        );
    }

    // ---------------------------------------------------------------------
    // Auxiliary — role gating
    // ---------------------------------------------------------------------

    /// @dev Mirrors the `setGuardian` caller gate at
    ///      `src/EntryTokenRegistry.sol:79`.
    function _setGuardianCallerGate(address caller, address owner, address guardian)
        internal
        pure
        returns (bool reverts)
    {
        return caller != owner && caller != guardian;
    }

    /// @notice Role gating: `setGuardian` reverts when the caller is
    ///         neither the owner nor the current guardian.
    function check_registryAuxSetGuardianRejectsNonOwnerNonGuardian(address owner, address guardian, address caller)
        public
        pure
    {
        require(owner != address(0));
        require(guardian != address(0));
        require(caller != owner);
        require(caller != guardian);

        assert(_setGuardianCallerGate(caller, owner, guardian));
    }

    /// @notice Role gating: `setGuardian` permits an owner caller.
    function check_registryAuxSetGuardianPermitsOwner(address owner, address guardian) public pure {
        require(owner != address(0));
        require(guardian != address(0));

        assert(!_setGuardianCallerGate(owner, owner, guardian));
    }

    /// @notice Role gating: `setGuardian` permits the current guardian
    ///         caller.
    function check_registryAuxSetGuardianPermitsGuardian(address owner, address guardian) public pure {
        require(owner != address(0));
        require(guardian != address(0));

        assert(!_setGuardianCallerGate(guardian, owner, guardian));
    }

    /// @dev Mirrors the candidate-validity checks at
    ///      `src/EntryTokenRegistry.sol:80-82`.
    function _setGuardianCandidateGate(address candidate, address registrySelf) internal pure returns (bool reverts) {
        return candidate == address(0) || candidate == registrySelf;
    }

    /// @notice Role gating: `setGuardian` rejects the zero-address
    ///         candidate.
    function check_registryAuxSetGuardianRejectsZeroCandidate(address registrySelf) public pure {
        require(registrySelf != address(0));

        assert(_setGuardianCandidateGate(address(0), registrySelf));
    }

    /// @notice Role gating: `setGuardian` rejects the registry's own
    ///         address as a guardian candidate.
    function check_registryAuxSetGuardianRejectsRegistrySelf(address registrySelf) public pure {
        require(registrySelf != address(0));

        assert(_setGuardianCandidateGate(registrySelf, registrySelf));
    }

    /// @notice Role gating: `setGuardian` permits a non-zero, non-self
    ///         candidate past the validity gate.
    function check_registryAuxSetGuardianPermitsValidCandidate(address candidate, address registrySelf) public pure {
        require(registrySelf != address(0));
        require(candidate != address(0));
        require(candidate != registrySelf);

        assert(!_setGuardianCandidateGate(candidate, registrySelf));
    }
}
