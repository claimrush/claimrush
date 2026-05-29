// SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

import {Errors} from "./lib/Errors.sol";
import {Events} from "./lib/Events.sol";
import {DelegationActionTypes} from "./lib/DelegationActionTypes.sol";
import {IShareholderRoyalties} from "./interfaces/IShareholderRoyalties.sol";
import {IMineCore} from "./interfaces/IMineCore.sol";
import {IDelegationHub} from "./interfaces/IDelegationHub.sol";
import {DelegationPermissions} from "./lib/DelegationPermissions.sol";

/// @notice Stateless orchestration helper. No economics changes.
contract ClaimAllHelper is ReentrancyGuard {
    bytes4 internal constant _SEL_ROYALTIES = bytes4(keccak256("royalties()"));
    bytes4 internal constant _SEL_MINE_CORE = bytes4(keccak256("mineCore()"));
    bytes4 internal constant _SEL_CLAIM_ALL_HELPER = bytes4(keccak256("claimAllHelper()"));
    bytes4 internal constant _SEL_FURNACE = bytes4(keccak256("furnace()"));
    bytes4 internal constant _SEL_SHAREHOLDER_ROYALTIES = bytes4(keccak256("shareholderRoyalties()"));
    bytes4 internal constant _SEL_DELEGATION_HUB = bytes4(keccak256("delegationHub()"));

    IShareholderRoyalties public immutable royalties;
    IMineCore public immutable mineCore;

    constructor(address _royalties, address _mineCore) {
        if (_royalties == address(0) || _mineCore == address(0)) revert Errors.ZeroAddress();
        if (_royalties.code.length == 0 || _mineCore.code.length == 0) revert Errors.NotAContract();
        _rejectDelegatedEOA(_royalties);
        _rejectDelegatedEOA(_mineCore);
        royalties = IShareholderRoyalties(_royalties);
        mineCore = IMineCore(_mineCore);
    }

    /// @notice Claims Baron rewards (ShareholderRoyalties) and withdraws King rewards (MineCore) for the caller.
    /// @dev This helper MUST NOT change economics; it only orchestrates existing calls.
    /// @param mode 0 = ETH, 1 = LOCK_FURNACE
    /// @param targetTokenId Lock destination tokenId when mode == LOCK_FURNACE (ignored in ETH mode)
    /// @param durationSeconds Lock duration when mode == LOCK_FURNACE (ignored in ETH mode)
    /// @param createAutoMax Whether to create/enable an AutoMax destination when mode == LOCK_FURNACE (ignored in ETH mode)
    /// @param minVeOut Minimum acceptable veCLAIM output when mode == LOCK_FURNACE (ignored in ETH mode)
    function claimAll(uint8 mode, uint256 targetTokenId, uint256 durationSeconds, bool createAutoMax, uint256 minVeOut)
        external
        nonReentrant
    {
        _requireCanonicalHelperWiring();
        royalties.claimShareholderFor(msg.sender, mode, targetTokenId, durationSeconds, createAutoMax, minVeOut);
        _withdrawKingBalanceBestEffort(msg.sender);
    }

    /// @notice Claims Baron rewards (ShareholderRoyalties) for `user`.
    /// @dev Delegation-gated. This helper MUST NOT change economics; it only orchestrates existing calls.
    ///      `P_CLAIM_SHAREHOLDER_FOR` authorizes the bot to claim shareholder ETH on behalf
    ///      of `user`; it does NOT authorize the bot to spend that ETH locking a fresh
    ///      veCLAIM position. The delegated path therefore rejects every non-zero `mode`.
    ///      Self-locking remains available via the user-direct `claimShareholderFor` /
    ///      `claimAll` flows.
    function claimShareholderForUser(
        address user,
        uint8 mode,
        uint256 targetTokenId,
        uint256 durationSeconds,
        bool createAutoMax,
        uint256 minVeOut
    ) external nonReentrant {
        if (user == address(0)) revert Errors.ZeroAddress();
        if (user == msg.sender) revert Errors.NotAuthorized();
        _requireDelegated(user, DelegationPermissions.P_CLAIM_SHAREHOLDER_FOR, _resolveShareholderDelegationHub());
        // ETH-only: ordering keeps wiring / auth failures surfacing their canonical
        // errors and only enforces the mode floor once authorization has cleared.
        if (mode != 0) revert Errors.NotAuthorized();
        royalties.claimShareholderFor(user, mode, targetTokenId, durationSeconds, createAutoMax, minVeOut);

        emit Events.DelegationSessionUsed(
            user,
            msg.sender,
            DelegationActionTypes.CLAIM_SHAREHOLDER_FOR,
            DelegationPermissions.P_CLAIM_SHAREHOLDER_FOR,
            0,
            block.timestamp
        );
    }

    /// @notice Withdraws King rewards (MineCore) for `user`.
    /// @dev Delegation-gated. ETH always withdraws to `user` (matching `MineCore.withdrawKingBalanceFor` semantics).
    function withdrawKingBalanceForUser(address user) external nonReentrant {
        if (user == address(0)) revert Errors.ZeroAddress();
        if (user == msg.sender) revert Errors.NotAuthorized();
        _requireDelegated(user, DelegationPermissions.P_WITHDRAW_KING_BUCKET_FOR, _resolveMineCoreDelegationHub());
        mineCore.withdrawKingBalanceFor(user);

        emit Events.DelegationSessionUsed(
            user,
            msg.sender,
            DelegationActionTypes.WITHDRAW_KING_BUCKET_FOR,
            DelegationPermissions.P_WITHDRAW_KING_BUCKET_FOR,
            0,
            block.timestamp
        );
    }

    /// @notice Claims Baron rewards and withdraws King rewards for `user`.
    /// @dev Delegation-gated bundle. The trailing `DelegationSessionUsed` emission marks that
    ///      the session WAS consumed for an attempt; it does NOT imply both legs fully
    ///      succeeded. Cross-join against `KingWithdrawalFailed` to distinguish full-success
    ///      from partial (Baron-claimed, King-stranded) outcomes when `_withdrawKingBalanceBestEffort`
    ///      swallows an `EthTransferFailed` revert.
    /// @dev `P_CLAIM_ALL_FOR` authorizes the bundled "collect Baron ETH + withdraw King ETH"
    ///      flow on behalf of `user`; it does NOT authorize the bot to spend `user`'s
    ///      shareholder ETH locking a fresh veCLAIM position. The delegated path
    ///      therefore rejects every non-zero `mode`. Self-locking remains available
    ///      via the user-direct `claimAll(mode, ...)` self-call.
    function claimAllFor(
        address user,
        uint8 mode,
        uint256 targetTokenId,
        uint256 durationSeconds,
        bool createAutoMax,
        uint256 minVeOut
    ) external nonReentrant {
        if (user == address(0)) revert Errors.ZeroAddress();
        if (user == msg.sender) revert Errors.NotAuthorized();
        _requireDelegated(user, DelegationPermissions.P_CLAIM_ALL_FOR, _resolveShareholderDelegationHub());
        // ETH-only: ordering keeps wiring / auth failures surfacing their canonical
        // errors and only enforces the mode floor once authorization has cleared.
        if (mode != 0) revert Errors.NotAuthorized();
        royalties.claimShareholderFor(user, mode, targetTokenId, durationSeconds, createAutoMax, minVeOut);
        _withdrawKingBalanceBestEffort(user);

        emit Events.DelegationSessionUsed(
            user,
            msg.sender,
            DelegationActionTypes.CLAIM_ALL_FOR,
            DelegationPermissions.P_CLAIM_ALL_FOR,
            0,
            block.timestamp
        );
    }

    function _withdrawKingBalanceBestEffort(address user) internal {
        (bool ok, bytes memory reason) = _callWithdrawKingBalanceFor(user);
        if (ok) return;

        if (_revertSelector(reason) != Errors.EthTransferFailed.selector) {
            _revertWithReason(reason);
        }

        emit Events.KingWithdrawalFailed(user, reason);
    }

    function _callWithdrawKingBalanceFor(address user) internal returns (bool ok, bytes memory reason) {
        address target = address(mineCore);
        bytes memory data = abi.encodeCall(IMineCore.withdrawKingBalanceFor, (user));

        assembly ("memory-safe") {
            ok := call(gas(), target, 0, add(data, 0x20), mload(data), 0, 0)
            if iszero(ok) {
                let rdSize := returndatasize()
                let copyLen := rdSize
                if gt(copyLen, 128) { copyLen := 128 }

                reason := mload(0x40)
                mstore(reason, copyLen)
                returndatacopy(add(reason, 0x20), 0, copyLen)
                mstore(0x40, add(add(reason, 0x20), and(add(copyLen, 31), not(31))))
            }
        }

        if (ok) reason = "";
    }

    function _revertSelector(bytes memory reason) internal pure returns (bytes4 sel) {
        if (reason.length < 4) return bytes4(0);
        assembly ("memory-safe") {
            sel := mload(add(reason, 0x20))
        }
    }

    function _revertWithReason(bytes memory reason) internal pure {
        if (reason.length == 0) revert();
        assembly ("memory-safe") {
            revert(add(reason, 0x20), mload(reason))
        }
    }

    /// @dev Reject EIP-7702 delegation designators as permanent wiring roots.
    function _rejectDelegatedEOA(address addr) internal view {
        if (addr.code.length != 23) return;
        bytes32 head;
        assembly ("memory-safe") {
            let ptr := mload(0x40)
            extcodecopy(addr, ptr, 0, 3)
            head := mload(ptr)
        }
        if (uint256(head) >> 232 == 0xEF0100) revert Errors.DelegatedEOA();
    }

    /// @dev Staticcall `target` with a 4-byte selector and decode the first word as an address.
    ///      Hardening: never copies full returndata/revertdata into memory (prevents return-data bomb griefing).
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

    function _requireCanonicalHelperWiring() internal view {
        address core = address(mineCore);
        address sr = address(royalties);

        if (core.code.length == 0 || sr.code.length == 0) revert Errors.NotAContract();

        // Evaluated left-to-right; the first mismatching edge short-circuits into the single
        // `WiringMismatch` revert. Operators investigating a revert should call each getter
        // manually to identify which edge drifted, in this order:
        //   1. mineCore.claimAllHelper()  == address(this)
        //   2. mineCore.royalties()       == address(royalties)
        //   3. royalties.claimAllHelper() == address(this)
        //   4. royalties.mineCore()       == address(mineCore)
        if (
            _staticcallAddress(core, _SEL_CLAIM_ALL_HELPER) != address(this)
                || _staticcallAddress(core, _SEL_ROYALTIES) != sr
                || _staticcallAddress(sr, _SEL_CLAIM_ALL_HELPER) != address(this)
                || _staticcallAddress(sr, _SEL_MINE_CORE) != core
        ) {
            revert Errors.WiringMismatch();
        }
    }

    /// @dev Resolve the canonical live Furnace surface shared by MineCore and ShareholderRoyalties.
    ///      ClaimAllHelper is a convenience router with no independent trust authority, so delegated
    ///      helper flows must fail closed unless MineCore.furnace() and ShareholderRoyalties.furnace()
    ///      return the same canonical Furnace.
    function _resolveCanonicalFurnace() internal view returns (address furnace) {
        _requireCanonicalHelperWiring();

        furnace = _staticcallAddress(address(mineCore), _SEL_FURNACE);
        if (furnace == address(0)) revert Errors.ZeroAddress();
        if (furnace.code.length == 0) revert Errors.NotAContract();

        if (
            _staticcallAddress(address(royalties), _SEL_FURNACE) != furnace
                || _staticcallAddress(furnace, _SEL_MINE_CORE) != address(mineCore)
                || _staticcallAddress(furnace, _SEL_SHAREHOLDER_ROYALTIES) != address(royalties)
        ) {
            revert Errors.WiringMismatch();
        }
    }

    function _resolveMineCoreDelegationHub() internal view returns (address hub) {
        address furnace = _resolveCanonicalFurnace();

        hub = _staticcallAddress(address(mineCore), _SEL_DELEGATION_HUB);
        if (hub == address(0)) revert Errors.ZeroAddress();
        if (hub.code.length == 0) revert Errors.NotAContract();

        if (_staticcallAddress(furnace, _SEL_DELEGATION_HUB) != hub) revert Errors.WiringMismatch();
    }

    /// @dev Intentional alias of `_resolveMineCoreDelegationHub` retained per the v1.0.0
    ///      implementer checklist (`docs/spec/claimallhelper-implementer-checklist-v1.0.0.md`)
    ///      which locks in this name. `_resolveCanonicalFurnace` already agrees the hub bundle
    ///      across MineCore, ShareholderRoyalties, and Furnace, so this returns the same address;
    ///      the named alias documents that the shareholder-claim path traverses the same root of
    ///      authority as the mine path.
    function _resolveShareholderDelegationHub() internal view returns (address hub) {
        hub = _resolveMineCoreDelegationHub();
    }

    function _requireDelegated(address user, uint256 requiredPerms, address hub) internal view {
        if (!IDelegationHub(hub).isAuthorized(user, msg.sender, requiredPerms)) revert Errors.NotAuthorized();
    }
}
