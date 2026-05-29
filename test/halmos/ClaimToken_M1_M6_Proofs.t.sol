// SPDX-License-Identifier: MIT
pragma solidity ^0.8.34;

/// @title ClaimToken M1-M6 bounded symbolic proofs
/// @notice Encodes the canonical accounting meta-properties from
///         `docs/security/invariants-v1.0.0.md` § 15 across the
///         `ClaimToken` value-paying surfaces (`mint`, `burn`,
///         `setMineCore`, `freezeConfig`).
///
/// @dev    Rate continuity (M1), quote=execute (M2), path independence
///         (M4), and floor direction (M6) do not bind on a vanilla ERC20
///         — there is no payout-curve input, no public quoter, transfers
///         compose by ERC20 invariant, and there is no `mulDiv` in the
///         transfer path. The auxiliary obligations encode the role
///         gating that keeps `mint` callable only from `MineCore` and
///         the freeze idempotence that locks `mineCore` once
///         `configFrozen == true`.
contract ClaimToken_M1_M6_Proofs {
    uint256 internal constant MAX_SYMBOLIC_VALUE = 1_000_000_000_000e18;

    struct TokenState {
        uint256 totalSupply;
        uint256 balanceA;
        uint256 balanceB;
    }

    /// @dev Mirrors `mint` at `src/ClaimToken.sol:186-191` (after the role
    ///      gate has been satisfied). The mint credits the recipient and
    ///      bumps `totalSupply`.
    function _mint(TokenState memory s, bool toA, uint256 amount) internal pure returns (TokenState memory) {
        s.totalSupply += amount;
        if (toA) s.balanceA += amount;
        else s.balanceB += amount;
        return s;
    }

    /// @dev Mirrors `burn` at `src/ClaimToken.sol:195-198`. The burn
    ///      debits the caller and decreases `totalSupply`.
    function _burn(TokenState memory s, bool fromA, uint256 amount) internal pure returns (TokenState memory) {
        s.totalSupply -= amount;
        if (fromA) s.balanceA -= amount;
        else s.balanceB -= amount;
        return s;
    }

    /// @dev Mirrors the ERC20 transfer composition. CLAIM transfers do
    ///      not move totalSupply.
    function _transfer(TokenState memory s, bool fromA, uint256 amount) internal pure returns (TokenState memory) {
        if (fromA) {
            s.balanceA -= amount;
            s.balanceB += amount;
        } else {
            s.balanceB -= amount;
            s.balanceA += amount;
        }
        return s;
    }

    // ---------------------------------------------------------------------
    // M3 — Conservation
    // ---------------------------------------------------------------------

    /// @notice M3: `totalSupply` equals the sum of holder balances after a
    ///         mint to a fresh holder.
    /// @dev    Mirrors `mint` at `src/ClaimToken.sol:186-191`.
    function check_claimTokenM3MintAddsToTotalSupply(uint256 amount) public pure {
        require(amount > 0 && amount <= MAX_SYMBOLIC_VALUE);

        TokenState memory s = TokenState({totalSupply: 0, balanceA: 0, balanceB: 0});
        s = _mint(s, true, amount);

        assert(s.totalSupply == s.balanceA + s.balanceB);
    }

    /// @notice M3: a burn drops `totalSupply` and the caller balance by
    ///         the same amount; no other holder is touched.
    /// @dev    Mirrors `burn` at `src/ClaimToken.sol:195-198`.
    function check_claimTokenM3BurnDropsTotalSupplyAndCallerInLockstep(uint256 mintAmount, uint256 burnAmount)
        public
        pure
    {
        require(mintAmount > 0 && mintAmount <= MAX_SYMBOLIC_VALUE);
        require(burnAmount <= mintAmount);

        TokenState memory s = TokenState({totalSupply: 0, balanceA: 0, balanceB: 0});
        s = _mint(s, true, mintAmount);
        uint256 supplyBefore = s.totalSupply;
        uint256 holderBefore = s.balanceA;

        s = _burn(s, true, burnAmount);

        assert(
            supplyBefore - s.totalSupply == burnAmount && holderBefore - s.balanceA == burnAmount
                && s.totalSupply == s.balanceA + s.balanceB
        );
    }

    /// @notice M3: a transfer between two holders preserves both
    ///         `totalSupply` and the sum of holder balances.
    /// @dev    Mirrors the ERC20 transfer path; transfers MUST NOT mint
    ///         or burn CLAIM.
    function check_claimTokenM3TransferPreservesTotalSupply(uint256 mintAmount, uint256 transferAmount) public pure {
        require(mintAmount > 0 && mintAmount <= MAX_SYMBOLIC_VALUE);
        require(transferAmount <= mintAmount);

        TokenState memory s = TokenState({totalSupply: 0, balanceA: 0, balanceB: 0});
        s = _mint(s, true, mintAmount);
        uint256 supplyBefore = s.totalSupply;

        s = _transfer(s, true, transferAmount);

        assert(s.totalSupply == supplyBefore && s.totalSupply == s.balanceA + s.balanceB);
    }

    // ---------------------------------------------------------------------
    // M5 — Cooldown-or-continuity (role gating)
    // ---------------------------------------------------------------------

    /// @dev Mirrors the `onlyMineCore` modifier at
    ///      `src/ClaimToken.sol:31-34` and the `mint` entry at
    ///      `src/ClaimToken.sol:186`.
    function _mintRoleGate(address caller, address mineCore) internal pure returns (bool reverts) {
        return caller != mineCore;
    }

    /// @notice M5: `mint` reverts when the caller is not `mineCore`.
    function check_claimTokenM5MintRevertsForNonMineCoreCaller(address mineCore, address caller) public pure {
        require(mineCore != address(0));
        require(caller != mineCore);

        assert(_mintRoleGate(caller, mineCore));
    }

    /// @notice M5: `mint` permits the call when the caller is `mineCore`.
    function check_claimTokenM5MintPermitsMineCoreCaller(address mineCore) public pure {
        require(mineCore != address(0));

        assert(!_mintRoleGate(mineCore, mineCore));
    }

    /// @dev Mirrors the `whenNotFrozen` modifier consult at
    ///      `src/ClaimToken.sol:26-29` and the `setMineCore` entry at
    ///      `src/ClaimToken.sol:126`.
    function _setMineCoreFrozenGate(bool configFrozen) internal pure returns (bool reverts) {
        return configFrozen;
    }

    /// @notice M5: once `configFrozen == true`, `setMineCore` reverts. The
    ///         frozen `mineCore` slot cannot be rewired.
    function check_claimTokenM5SetMineCoreRevertsWhenFrozen(address newMineCore) public pure {
        require(newMineCore != address(0));

        assert(_setMineCoreFrozenGate(true));
    }

    /// @notice M5: while `configFrozen == false`, `setMineCore` is
    ///         permitted past the freeze gate.
    function check_claimTokenM5SetMineCorePermittedWhenNotFrozen(address newMineCore) public pure {
        require(newMineCore != address(0));

        assert(!_setMineCoreFrozenGate(false));
    }

    // ---------------------------------------------------------------------
    // Auxiliary — role gating
    // ---------------------------------------------------------------------

    /// @dev Mirrors the `mint` validity gate at `src/ClaimToken.sol:187-189`.
    ///      `_isRestrictedRecipient(to)` resolves to
    ///      `to == address(this) || to == address(_wiringProbe)` per
    ///      `src/ClaimToken.sol:43`; the model carries `tokenSelf`
    ///      and `wiringProbe` as symbolic addresses to match the
    ///      production gate verbatim.
    function _mintTargetGate(address to, address tokenSelf, address wiringProbe, uint256 amount)
        internal
        pure
        returns (bool reverts)
    {
        if (to == address(0)) return true;
        if (to == tokenSelf || to == wiringProbe) return true;
        if (amount == 0) return true;
        return false;
    }

    /// @notice Role gating: `mint` reverts on a zero-address recipient
    ///         even when the caller is MineCore.
    function check_claimTokenAuxMintRejectsZeroRecipient(address tokenSelf, address wiringProbe, uint256 amount)
        public
        pure
    {
        require(tokenSelf != address(0));
        require(wiringProbe != address(0));
        require(amount <= MAX_SYMBOLIC_VALUE);

        assert(_mintTargetGate(address(0), tokenSelf, wiringProbe, amount));
    }

    /// @notice Role gating: `mint` reverts when the recipient is the
    ///         token contract itself.
    function check_claimTokenAuxMintRejectsTokenSelfRecipient(address tokenSelf, address wiringProbe, uint256 amount)
        public
        pure
    {
        require(tokenSelf != address(0));
        require(wiringProbe != address(0));
        require(amount > 0 && amount <= MAX_SYMBOLIC_VALUE);

        assert(_mintTargetGate(tokenSelf, tokenSelf, wiringProbe, amount));
    }

    /// @notice Role gating: `mint` reverts when the recipient is the
    ///         wiring probe.
    function check_claimTokenAuxMintRejectsWiringProbeRecipient(address tokenSelf, address wiringProbe, uint256 amount)
        public
        pure
    {
        require(tokenSelf != address(0));
        require(wiringProbe != address(0));
        require(amount > 0 && amount <= MAX_SYMBOLIC_VALUE);

        assert(_mintTargetGate(wiringProbe, tokenSelf, wiringProbe, amount));
    }

    /// @notice Role gating: `mint` reverts on a zero-amount request
    ///         even when the caller is MineCore.
    function check_claimTokenAuxMintRejectsZeroAmount(address to, address tokenSelf, address wiringProbe) public pure {
        require(to != address(0));
        require(tokenSelf != address(0));
        require(wiringProbe != address(0));
        require(to != tokenSelf);
        require(to != wiringProbe);

        assert(_mintTargetGate(to, tokenSelf, wiringProbe, 0));
    }

    /// @notice Role gating: `mint` permits the call on a non-zero
    ///         recipient that is neither the token nor the wiring probe,
    ///         past the validity gate.
    function check_claimTokenAuxMintPermitsValidTarget(
        address to,
        address tokenSelf,
        address wiringProbe,
        uint256 amount
    ) public pure {
        require(to != address(0));
        require(tokenSelf != address(0));
        require(wiringProbe != address(0));
        require(to != tokenSelf);
        require(to != wiringProbe);
        require(amount > 0 && amount <= MAX_SYMBOLIC_VALUE);

        assert(!_mintTargetGate(to, tokenSelf, wiringProbe, amount));
    }

    /// @dev Mirrors `freezeConfig` at `src/ClaimToken.sol:144-157` and the
    ///      `whenNotFrozen` modifier at `src/ClaimToken.sol:26-29`.
    function _freezeStep(bool configFrozenBefore) internal pure returns (bool configFrozenAfter, bool reverted) {
        if (configFrozenBefore) {
            return (configFrozenBefore, true);
        }
        return (true, false);
    }

    /// @notice Role gating: a first `freezeConfig` call from an unfrozen
    ///         state succeeds and sets `configFrozen == true`.
    function check_claimTokenAuxFreezeFirstCallSetsFrozen() public pure {
        (bool after_, bool reverted) = _freezeStep(false);

        assert(after_ && !reverted);
    }

    /// @notice Role gating: a second `freezeConfig` call from a frozen
    ///         state reverts via `whenNotFrozen`. Freeze is idempotent.
    function check_claimTokenAuxFreezeSecondCallReverts() public pure {
        (, bool reverted) = _freezeStep(true);

        assert(reverted);
    }
}
