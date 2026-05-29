// SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {Ownable2Step} from "@openzeppelin/contracts/access/Ownable2Step.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";

import {Errors} from "./lib/Errors.sol";
import {IClaimToken} from "./interfaces/IClaimToken.sol";
import {Events} from "./lib/Events.sol";

/// @notice CLAIM token. Supply starts at 0. No fees. Minting restricted to MineCore only.
/// @dev Admin pattern (locked): Ownable2Step with a live `owner()` path; production deployments are expected to place that owner behind an admin timelock/multisig. `configFrozen` freezes wiring.
contract ClaimToken is ERC20, Ownable2Step, IClaimToken {
    bytes4 internal constant _SEL_CLAIM = bytes4(keccak256("claim()"));
    bytes4 internal constant _SEL_EMISSION_START_TIME = bytes4(keccak256("emissionStartTime()"));
    bytes4 internal constant _SEL_GENESIS_ACCRUAL_DURATION = bytes4(keccak256("GENESIS_ACCRUAL_DURATION()"));

    address public mineCore; // the only allowed minter
    bool public configFrozen;

    /// @dev Secondary caller-context probe used to reject caller-sensitive `claim()` implementations
    ///      during wiring validation. CLAIM transfers/mints to this helper are blocked to avoid a sink.
    ClaimTokenWiringProbe internal immutable _wiringProbe;

    modifier whenNotFrozen() {
        if (configFrozen) revert Errors.ConfigFrozen();
        _;
    }

    modifier onlyMineCore() {
        if (msg.sender != mineCore) revert Errors.OnlyMineCore();
        _;
    }

    constructor(address initialOwner) ERC20("ClaimRush", "CLAIM") Ownable(initialOwner) {
        // Ownable(initialOwner) already reverts with OwnableInvalidOwner(address(0))
        // before this body runs. An explicit zero-address check here would be unreachable dead code.
        // The runtime `transferOwnership` surface rejects EIP-7702 delegated EOAs.
        // The constructor enforces the same rule on `initialOwner` so a delegated
        // initial owner cannot exercise mint-wiring (`setMineCore`, `freezeConfig`)
        // through public executor code before the first hardened transfer.
        _rejectDelegatedEOA(initialOwner);
        _wiringProbe = new ClaimTokenWiringProbe();
    }

    function _isRestrictedRecipient(address to) internal view returns (bool) {
        return to == address(this) || to == address(_wiringProbe);
    }

    /// @dev Reject EIP-7702-delegated EOAs as candidate MineCore roots.
    ///      A delegation designator is exactly 23 bytes: `0xEF 0x01 0x00 || 20-byte target`.
    ///      EIP-3541 prevents legacy runtime bytecode from starting with `0xEF`, and EOF v1 uses
    ///      `0xEF 0x00 0x01`, so the prefix check does not collide with deployable contract code.
    function _rejectDelegatedEOA(address target) internal view {
        if (target.code.length != 23) return;
        bytes32 head;
        assembly ("memory-safe") {
            let ptr := mload(0x40)
            extcodecopy(target, ptr, 0, 3)
            head := mload(ptr)
        }
        if (uint256(head) >> 232 == 0xEF0100) revert Errors.DelegatedEOA();
    }

    /// @notice Query whether `to` is a restricted recipient (transfers and mints will revert).
    function isRestrictedRecipient(address to) external view returns (bool) {
        return _isRestrictedRecipient(to);
    }

    /// @dev Block any token movement whose destination is this contract or the internal wiring probe.
    ///      Prevents CLAIM from being permanently trapped via transfer / transferFrom.
    function _update(address from, address to, uint256 value) internal override {
        if (_isRestrictedRecipient(to)) revert Errors.TransfersRestricted();
        super._update(from, to, value);
    }

    /// @dev Staticcall `target` with a 4-byte selector and decode the first word as an address.
    ///      Hardening: never copies full returndata/revertdata into memory (prevents "return data bomb" griefing).
    ///      Gas-bounded: forwards at most 100 000 gas to prevent untrusted callees from consuming
    ///      the caller's entire gas budget during wiring checks.
    function _staticcallAddress(address target, bytes4 sel) internal view returns (address out) {
        out = address(0);
        assembly ("memory-safe") {
            mstore(0x00, sel)

            let success := staticcall(100000, target, 0x00, 0x04, 0x00, 0x20)
            if success {
                if iszero(lt(returndatasize(), 0x20)) {
                    out := and(mload(0x00), 0xFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFF)
                }
            }
        }
    }

    /// @dev Staticcall `target` with a 4-byte selector and decode the first word as a uint256.
    ///      Uses the same returndata-bomb and gas-bounded hardening as `_staticcallAddress(...)`.
    function _staticcallUint256(address target, bytes4 sel) internal view returns (uint256 out) {
        out = 0;
        assembly ("memory-safe") {
            mstore(0x00, sel)

            let success := staticcall(100000, target, 0x00, 0x04, 0x00, 0x20)
            if success {
                if iszero(lt(returndatasize(), 0x20)) {
                    out := mload(0x00)
                }
            }
        }
    }

    /// @dev Validate `target.claim()` from two distinct caller contexts.
    ///      A single ClaimToken-originated staticcall can be spoofed by caller-sensitive fallbacks that
    ///      echo `msg.sender`; requiring both ClaimToken and the internal probe to observe `address(this)`
    ///      fails closed for that class of implementation.
    function _checkCanonicalClaimRoot(address target) internal view {
        if (_staticcallAddress(target, _SEL_CLAIM) != address(this)) revert Errors.WiringMismatch();
        if (_wiringProbe.probeClaim(target) != address(this)) revert Errors.WiringMismatch();
    }

    /// @dev Freeze-time hardening: `claim()` alone is not unique to MineCore across the shipped
    ///      codebase. Require MineCore-specific genesis schedule getters as well so ClaimToken
    ///      cannot be irreversibly frozen to another CLAIM-root protocol contract such as MarketRouter.
    function _checkFreezeTimeMineCoreIdentity(address target) internal view {
        _checkCanonicalClaimRoot(target);
        if (_staticcallUint256(target, _SEL_EMISSION_START_TIME) == 0) revert Errors.WiringMismatch();
        if (_staticcallUint256(target, _SEL_GENESIS_ACCRUAL_DURATION) == 0) revert Errors.WiringMismatch();
    }

    /// @notice Pre-freeze wiring (repeatable until `freezeConfig`). Set MineCore as the only minter.
    function setMineCore(address _mineCore) external onlyOwner whenNotFrozen {
        if (_mineCore == address(0)) revert Errors.ZeroAddress();
        if (_mineCore.code.length == 0) revert Errors.NotAContract();
        _rejectDelegatedEOA(_mineCore);

        // Use the full MineCore identity check at setter time, not just the claim() probe.
        // The weaker _checkCanonicalClaimRoot would accept any contract with a claim() getter
        // returning this ClaimToken (MarketRouter, Furnace, FurnaceQuoter, LpStakingVault7D,
        // LaunchController all qualify). The full check narrows to MineCore via
        // emissionStartTime() != 0 && GENESIS_ACCRUAL_DURATION() != 0, both of which MineCore
        // sets during initialization.
        _checkFreezeTimeMineCoreIdentity(_mineCore);

        address oldMineCore = mineCore;
        mineCore = _mineCore;
        emit Events.MineCoreChanged(oldMineCore, _mineCore);
    }

    function freezeConfig() external onlyOwner whenNotFrozen {
        address core = mineCore;
        if (core == address(0)) revert Errors.ZeroAddress();
        if (core.code.length == 0) revert Errors.NotAContract();
        _rejectDelegatedEOA(core);

        // Freeze-time identity hardening: `claim()` alone is not a unique MineCore fingerprint
        // across the shipped protocol. Require MineCore-specific getters as well so ClaimToken
        // cannot be irreversibly frozen to another CLAIM-root contract.
        _checkFreezeTimeMineCoreIdentity(core);

        configFrozen = true;
        emit Events.ConfigFrozen();
    }

    function owner() public view override(Ownable, IClaimToken) returns (address) {
        return super.owner();
    }

    function pendingOwner() public view override(Ownable2Step, IClaimToken) returns (address) {
        return super.pendingOwner();
    }

    function transferOwnership(address newOwner) public override(Ownable2Step, IClaimToken) onlyOwner {
        if (
            newOwner == owner() || newOwner == pendingOwner() || _isRestrictedRecipient(newOwner)
                || newOwner == mineCore
        ) {
            revert Errors.InvariantViolation();
        }
        // Reject EIP-7702 delegated EOAs: a delegated owner can let arbitrary callers
        // exercise `mint` (post-acceptance) and other owner-only surfaces.
        _rejectDelegatedEOA(newOwner);
        super.transferOwnership(newOwner);
    }

    function acceptOwnership() public override(Ownable2Step, IClaimToken) {
        // Re-validate at acceptance: a nominee that becomes a delegated EOA between
        // nomination and acceptance must be rejected here, not just at transfer time.
        _rejectDelegatedEOA(msg.sender);
        super.acceptOwnership();
    }

    function renounceOwnership() public override(Ownable, IClaimToken) onlyOwner {
        if (!configFrozen) revert Errors.NotAuthorized();
        super.renounceOwnership();
    }

    function mint(address to, uint256 amount) external onlyMineCore {
        if (to == address(0)) revert Errors.ZeroAddress();
        if (_isRestrictedRecipient(to)) revert Errors.TransfersRestricted();
        if (amount == 0) revert Errors.AmountZero();
        _mint(to, amount);
    }

    /// @notice Burns CLAIM held by the caller.
    /// @dev `burnFrom` is not supported.
    function burn(uint256 amount) external {
        if (amount == 0) revert Errors.AmountZero();
        _burn(msg.sender, amount);
    }
}

/// @dev Distinct caller-context probe for reciprocal MineCore wiring checks.
contract ClaimTokenWiringProbe {
    bytes4 internal constant _SEL_CLAIM = bytes4(keccak256("claim()"));

    /// @dev Probe `target.claim()` from a caller context distinct from ClaimToken itself.
    ///      Uses the same returndata-bomb and gas-bounded staticcall hardening as ClaimToken.
    function probeClaim(address target) external view returns (address out) {
        out = address(0);
        bytes4 sel = _SEL_CLAIM;
        assembly ("memory-safe") {
            mstore(0x00, sel)

            let success := staticcall(100000, target, 0x00, 0x04, 0x00, 0x20)
            if success {
                if iszero(lt(returndatasize(), 0x20)) {
                    out := and(mload(0x00), 0xFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFF)
                }
            }
        }
    }
}
