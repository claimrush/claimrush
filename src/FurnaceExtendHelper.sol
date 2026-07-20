// SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

import {Constants} from "./lib/Constants.sol";
import {Errors} from "./lib/Errors.sol";
import {DelegationActionTypes} from "./lib/DelegationActionTypes.sol";
import {DelegationPermissions} from "./lib/DelegationPermissions.sol";
import {IDelegationHub} from "./interfaces/IDelegationHub.sol";
import {IVeClaimNFT} from "./interfaces/IVeClaimNFT.sol";
import {FurnaceGuardHelper} from "./FurnaceGuardHelper.sol";

/// @dev Furnace -> helper -> Furnace bonus AMM callback used by the extend body (which runs in
///      delegatecall context). Mirrors the merge-body callback; `__bonusAmmFromHelper` on Furnace
///      authorizes by `msg.sender == address(this)`.
interface IFurnaceExtendCallback {
    function __bonusAmmFromHelper(address user, uint256 principalClaim, uint256 principalEff, uint256 lockDurationSec)
        external
        returns (uint256 grossBonus, uint256 userBonus, uint256 lpBonus);
}

/// @notice Externalized `extendWithBonus` + `mergeLocksWithBonus` execution bodies for Furnace.
/// @dev Runs exclusively via `delegatecall` from the canonical Furnace, so every `sload`/`sstore`
///      and every `address(this)` reference targets Furnace's storage and identity. The bodies are
///      offloaded here (rather than living in `Furnace` or `FurnaceGuardHelper`) purely to keep both
///      of those runtimes under the EIP-170 24 KiB limit — the semantics are identical to an inline
///      implementation. Merge preflight/bonus resolution stays on `FurnaceGuardHelper`
///      (`resolveMergeWithBonusFull`, a pure ve-state `view`); this contract runs the state
///      transition and bonus payout.
///
///      Bonus pricing is anchored to the per-lock user-principal basis (`bonusBasis`, slot
///      `_SLOT_BONUS_BASIS` on Furnace) rather than the live `Lock.amount`. `Lock.amount` grows
///      every time a bonus is folded back into the lock, so pricing the next commitment off it
///      would let a laddered sequence of extensions compound the bonus multiplicatively over a
///      single 7d->365d commitment. Pricing off the fixed basis keeps the cumulative bonus
///      path-independent: fragmenting one extension into many rungs pays exactly what a single
///      extension pays.
contract FurnaceExtendHelper {
    // ── Canonical roots (bound at construction) ───────────────────────────────────────
    address private immutable _claim;
    address private immutable _ve;
    address payable private immutable _guardHelper;
    address private immutable _self;

    bytes4 internal constant _SEL_CLAIM = bytes4(keccak256("claim()"));
    bytes4 internal constant _SEL_VE = bytes4(keccak256("ve()"));
    bytes4 internal constant _SEL_FURNACE = bytes4(keccak256("furnace()"));
    bytes4 internal constant _SEL_DELEGATION_HUB = bytes4(keccak256("delegationHub()"));

    // ── Furnace storage layout mirrors ────────────────────────────────────────────────
    // These hardcoded slot indices target Furnace's storage while running in delegatecall.
    // Parity is enforced in test/SecurityCriticalConstantsPinned.t.sol — any drift in either
    // contract MUST update both sides atomically.
    uint256 internal constant _SLOT_MINE_CORE = 56;
    uint256 internal constant _SLOT_DELEGATION_HUB = 63;
    uint256 internal constant _SLOT_FURNACE_RESERVE = 64;
    uint256 internal constant _SLOT_LP_STREAM_RATE_PER_SEC = 70;
    uint256 internal constant _SLOT_LP_STREAM_PERIOD_FINISH = 71;
    uint256 internal constant _SLOT_LP_STREAM_LAST_UPDATE = 72;
    uint256 internal constant _SLOT_LP_STREAM_CARRY = 73;
    uint256 internal constant _SLOT_BONUS_BASIS = 79;

    uint8 internal constant MODE_EXTEND_WITH_BONUS = 4;

    /// @dev Mirrors `Events.FurnaceEnter`; topic0 parity is pinned in test/InterfaceEventParity.t.sol.
    event FurnaceEnter(
        address indexed user, uint8 mode, uint256 ethIn, uint256 principalClaim, uint256 bonusClaim, uint256 tokenId
    );

    /// @dev Mirrors `Events.DelegationSessionUsed` — emitted in delegatecall context from the
    ///      `For` variant after the extend body completes.
    event DelegationSessionUsed(
        address indexed user,
        address indexed delegate,
        uint8 indexed actionType,
        uint256 permsUsed,
        uint256 refId,
        uint256 timestamp
    );

    /// @dev Mirrors `Events.ReserveClamped` — emitted by the inlined reserve sync postlude.
    event ReserveClamped(
        address indexed caller, uint256 oldReserve, uint256 newReserve, uint256 claimBalance, uint256 lpStreamLiability
    );

    /// @dev Mirrors the canonical `Events.FurnaceMergeWithBonus` declaration; topic0 parity is
    ///      pinned in `test/InterfaceEventParity.t.sol`. Emitted in delegatecall context so the
    ///      log's emitter is Furnace.
    event FurnaceMergeWithBonus(
        address indexed user,
        uint256 indexed fromTokenId,
        uint256 indexed intoTokenId,
        uint256 fromAmount,
        uint256 intoAmount,
        uint256 newPrincipal,
        uint256 newEnd,
        bool newAutoMax,
        uint256 durationDelta,
        uint256 bonusClaim
    );

    constructor(address claim_, address ve_, address guardHelper_) {
        if (claim_ == address(0) || ve_ == address(0) || guardHelper_ == address(0)) revert Errors.ZeroAddress();
        // `> 23` rejects bare EOAs and EIP-7702 delegated EOAs alike.
        if (claim_.code.length <= 23 || ve_.code.length <= 23 || guardHelper_.code.length <= 23) {
            revert Errors.NotAContract();
        }
        bytes32 claimHash;
        bytes32 veHash;
        assembly ("memory-safe") {
            claimHash := extcodehash(claim_)
            veHash := extcodehash(ve_)
        }
        bytes32 emptyCodeHash = keccak256("");
        if (claimHash == bytes32(0) || claimHash == emptyCodeHash) revert Errors.NotAContract();
        if (veHash == bytes32(0) || veHash == emptyCodeHash) revert Errors.NotAContract();
        _claim = claim_;
        _ve = ve_;
        _guardHelper = payable(guardHelper_);
        _self = address(this);
    }

    // ── Canonical-Furnace gate (delegatecall context) ─────────────────────────────────

    function _staticcallAddress(address target, bytes4 sel) internal view returns (address out) {
        out = address(0);
        assembly ("memory-safe") {
            let ptr := mload(0x40)
            mstore(ptr, sel)
            let success := staticcall(100000, target, ptr, 0x04, 0, 0)
            if success {
                let rds := returndatasize()
                if iszero(lt(rds, 0x20)) {
                    returndatacopy(ptr, 0, 0x20)
                    out := and(mload(ptr), 0xFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFF)
                }
            }
        }
    }

    function _isCanonicalFurnace(address furnace) internal view returns (bool) {
        if (furnace == address(0) || furnace.code.length <= 23) return false;
        if (_staticcallAddress(furnace, _SEL_CLAIM) != _claim) return false;
        if (_staticcallAddress(furnace, _SEL_VE) != _ve) return false;
        return true;
    }

    /// @dev Only the canonical Furnace may delegatecall this body. `address(this)` is Furnace here.
    function _requireDelegatecallCanonicalFurnace() internal view {
        if (!_isCanonicalFurnace(address(this))) revert Errors.NotAuthorized();
    }

    /// @dev Inlined twin of Furnace's delegation gate. Reads `delegationHub` + `mineCore` via slot
    ///      pins and runs the same canonical-wiring + isAuthorized check.
    function _requireDelegatedFromHelper(address user, uint256 requiredPerms) internal view {
        address hub;
        address core;
        assembly {
            hub := sload(_SLOT_DELEGATION_HUB)
            core := sload(_SLOT_MINE_CORE)
        }
        if (hub == address(0)) revert Errors.ZeroAddress();
        if (hub.code.length == 0) revert Errors.WiringMismatch();
        if (core == address(0) || core.code.length == 0) revert Errors.WiringMismatch();
        if (
            _staticcallAddress(core, _SEL_FURNACE) != address(this)
                || _staticcallAddress(core, _SEL_DELEGATION_HUB) != hub
                || _staticcallAddress(core, _SEL_CLAIM) != _claim || _staticcallAddress(core, _SEL_VE) != _ve
        ) {
            revert Errors.WiringMismatch();
        }
        if (!IDelegationHub(hub).isAuthorized(user, msg.sender, requiredPerms)) revert Errors.NotAuthorized();
    }

    /// @dev Inlined twin of `Furnace._syncFurnaceReserve`. Clamps `furnaceReserve` down via SSTORE
    ///      if it has drifted above the available cap.
    function _syncFurnaceReserveDelegated() internal {
        uint256 carry;
        uint256 finish;
        uint256 rate;
        uint256 lastStreamUpdate;
        uint256 oldReserve;
        assembly {
            carry := sload(_SLOT_LP_STREAM_CARRY)
            finish := sload(_SLOT_LP_STREAM_PERIOD_FINISH)
            rate := sload(_SLOT_LP_STREAM_RATE_PER_SEC)
            lastStreamUpdate := sload(_SLOT_LP_STREAM_LAST_UPDATE)
            oldReserve := sload(_SLOT_FURNACE_RESERVE)
        }

        uint256 liability = carry;
        if (rate != 0 && finish != 0 && finish > lastStreamUpdate) {
            liability += (finish - lastStreamUpdate) * rate;
        }
        uint256 bal = IERC20(_claim).balanceOf(address(this));
        uint256 cap = bal > liability ? bal - liability : 0;

        if (oldReserve > cap) {
            assembly {
                sstore(_SLOT_FURNACE_RESERVE, cap)
            }
            emit ReserveClamped(msg.sender, oldReserve, cap, bal, liability);
        }
    }

    /// @dev Read/write Furnace's `bonusBasis[tokenId]` (slot `_SLOT_BONUS_BASIS`). Valid ONLY under
    ///      delegatecall from the canonical Furnace, which the callers guarantee.
    function _loadBonusBasis(uint256 tokenId) private view returns (uint256 v) {
        bytes32 slot = keccak256(abi.encode(tokenId, _SLOT_BONUS_BASIS));
        assembly {
            v := sload(slot)
        }
    }

    function _storeBonusBasis(uint256 tokenId, uint256 v) private {
        bytes32 slot = keccak256(abi.encode(tokenId, _SLOT_BONUS_BASIS));
        assembly {
            sstore(slot, v)
        }
    }

    // ── Delegated bodies (selectors match Furnace's shims for msg.data forwarding) ──────

    /// @notice Delegated body for `Furnace.extendWithBonus(uint256,uint256,uint256)`.
    function extendWithBonus(uint256 tokenId, uint256 durationSeconds, uint256 minBonusOut)
        external
        returns (uint256 bonusClaim)
    {
        _requireDelegatecallCanonicalFurnace();
        bonusClaim = _extendBody(msg.sender, tokenId, durationSeconds, minBonusOut);
    }

    /// @notice Delegated body for `Furnace.extendWithBonusFor(address,uint256,uint256,uint256)`.
    function extendWithBonusFor(address user, uint256 tokenId, uint256 durationSeconds, uint256 minBonusOut)
        external
        returns (uint256 bonusClaim)
    {
        _requireDelegatecallCanonicalFurnace();
        if (user == address(0)) revert Errors.ZeroAddress();
        _requireDelegatedFromHelper(user, DelegationPermissions.P_VE_EXTEND_LOCK_FOR);

        bonusClaim = _extendBody(user, tokenId, durationSeconds, minBonusOut);

        emit DelegationSessionUsed(
            user,
            msg.sender,
            DelegationActionTypes.VE_EXTEND_LOCK_FOR,
            DelegationPermissions.P_VE_EXTEND_LOCK_FOR,
            tokenId,
            block.timestamp
        );
    }

    /// @dev Shared extend orchestration. Runs in Furnace storage context; uses the helper's
    ///      `_claim` / `_ve` / `_guardHelper` immutables (canonical-bound at construction).
    function _extendBody(address user, uint256 tokenId, uint256 durationSeconds, uint256 minBonusOut)
        internal
        returns (uint256 bonusClaim)
    {
        (uint256 lockAmount, uint256 d, uint256 principalEff) =
            FurnaceGuardHelper(_guardHelper).resolveExtendWithBonus(_ve, user, tokenId, durationSeconds);

        // Price the extension on the user's committed principal basis, not the live
        // `lockAmount` (which already includes every bonus folded into the lock). A 0 basis
        // marks a lock without a recorded basis; seed it once from the live amount.
        // `principalEff` from the helper is `mulDiv(lockAmount, weightDelta, WEIGHT_DENOM)`;
        // rescaling by `basis / lockAmount` yields the same delta priced on `basis`.
        uint256 basis = _loadBonusBasis(tokenId);
        if (basis == 0) {
            basis = lockAmount;
            _storeBonusBasis(tokenId, lockAmount);
        }
        if (basis < lockAmount) {
            principalEff = Math.mulDiv(principalEff, basis, lockAmount);
        }

        uint256 userBonus = 0;
        if (principalEff > 0) {
            (, userBonus,) =
                IFurnaceExtendCallback(address(this)).__bonusAmmFromHelper(user, lockAmount, principalEff, d);
        }

        IVeClaimNFT(_ve).extendLockToFor(user, tokenId, block.timestamp + d);

        // Symmetric with the merge body: VeClaimNFT._addToLock enforces `amount >= MIN_TOPUP_AMOUNT`
        // to bound ceiling-rounding slope dust. A sub-floor user-side bonus is refunded to
        // `furnaceReserve` so the AMM debit stays balanced against actual CLAIM held by Furnace.
        if (userBonus >= Constants.MIN_TOPUP_AMOUNT) {
            SafeERC20.forceApprove(IERC20(_claim), _ve, userBonus);
            IVeClaimNFT(_ve).addToLockFor(user, tokenId, userBonus);
            SafeERC20.forceApprove(IERC20(_claim), _ve, 0);
        } else if (userBonus > 0) {
            assembly {
                let r := sload(_SLOT_FURNACE_RESERVE)
                sstore(_SLOT_FURNACE_RESERVE, add(r, userBonus))
            }
            userBonus = 0;
        }

        bonusClaim = userBonus;
        if (minBonusOut > 0 && bonusClaim < minBonusOut) revert Errors.MinVeOutNotMet();

        _syncFurnaceReserveDelegated();

        emit FurnaceEnter(user, MODE_EXTEND_WITH_BONUS, 0, 0, bonusClaim, tokenId);
    }

    // ── Merge with bonus (delegated execution body) ────────────────────────────────────

    /// @notice Delegated body for `Furnace.mergeLocksWithBonus(uint256,uint256,uint256)`.
    /// @dev Selector matches Furnace's so msg.data forwarding works without re-encoding.
    ///      Caller (Furnace's external) holds `nonReentrant` + `whenLockingEnabled`.
    function mergeLocksWithBonus(uint256 fromTokenId, uint256 intoTokenId, uint256 minBonusOut)
        external
        returns (uint256 bonusClaim)
    {
        _requireDelegatecallCanonicalFurnace();
        bonusClaim = _mergeBody(msg.sender, fromTokenId, intoTokenId, minBonusOut);
    }

    /// @notice Delegated body for `Furnace.mergeLocksWithBonusFor(address,uint256,uint256,uint256)`.
    /// @dev Runs the canonical delegation-hub gate inline (slot-loaded `delegationHub` + `mineCore`).
    function mergeLocksWithBonusFor(address user, uint256 fromTokenId, uint256 intoTokenId, uint256 minBonusOut)
        external
        returns (uint256 bonusClaim)
    {
        _requireDelegatecallCanonicalFurnace();
        if (user == address(0)) revert Errors.ZeroAddress();
        _requireDelegatedFromHelper(user, DelegationPermissions.P_VE_MERGE_LOCKS_FOR);

        bonusClaim = _mergeBody(user, fromTokenId, intoTokenId, minBonusOut);

        emit DelegationSessionUsed(
            user,
            msg.sender,
            DelegationActionTypes.VE_MERGE_LOCKS_FOR,
            DelegationPermissions.P_VE_MERGE_LOCKS_FOR,
            intoTokenId,
            block.timestamp
        );
    }

    /// @dev Shared merge orchestration. Runs in Furnace storage context. Preflight/bonus
    ///      resolution comes from `FurnaceGuardHelper.resolveMergeWithBonusFull` (a pure ve-state
    ///      `view`, reached via a regular external call); the state transition + bonus payout run
    ///      here against Furnace's storage.
    function _mergeBody(address user, uint256 fromTokenId, uint256 intoTokenId, uint256 minBonusOut)
        internal
        returns (uint256 bonusClaim)
    {
        (
            uint256 fromAmt,
            uint256 intoAmt,
            uint256 newRemaining,
            uint256 principalEff,
            uint256 durationDelta,
            uint256 shorterTokenId,
            uint256 shorterAmt
        ) = FurnaceGuardHelper(_guardHelper).resolveMergeWithBonusFull(_ve, user, fromTokenId, intoTokenId);

        // Price the merge bonus on the shorter lock's user-principal basis, not its live
        // amount (which already includes Furnace-paid bonuses folded in). Parity with `_extendBody`.
        if (principalEff > 0 && shorterAmt > 0) {
            uint256 shorterBasis = _loadBonusBasis(shorterTokenId);
            if (shorterBasis == 0) shorterBasis = shorterAmt;
            if (shorterBasis < shorterAmt) {
                principalEff = Math.mulDiv(principalEff, shorterBasis, shorterAmt);
            }
        }

        uint256 userBonus = 0;
        if (principalEff > 0) {
            (, userBonus,) = IFurnaceExtendCallback(address(this))
                .__bonusAmmFromHelper(user, fromAmt + intoAmt, principalEff, newRemaining);
        }

        // Survivor carries the sum of both locks' user-principal bases; burned token cleared.
        // The Furnace-paid `userBonus` added below is deliberately excluded from the basis.
        {
            uint256 fromBasis = _loadBonusBasis(fromTokenId);
            if (fromBasis == 0) fromBasis = fromAmt;
            uint256 intoBasis = _loadBonusBasis(intoTokenId);
            if (intoBasis == 0) intoBasis = intoAmt;
            _storeBonusBasis(intoTokenId, fromBasis + intoBasis);
            _storeBonusBasis(fromTokenId, 0);
        }

        (, uint256 newAmt, uint256 newEnd, bool newAutoMax) =
            IVeClaimNFT(_ve).mergeLocksFor(user, fromTokenId, intoTokenId);

        // Symmetric with `_extendBody`: VeClaimNFT._addToLock enforces `amount >= MIN_TOPUP_AMOUNT`
        // to bound ceiling-rounding slope dust. A sub-floor user-side bonus is refunded to
        // `furnaceReserve` so the AMM debit stays balanced against actual CLAIM held by Furnace.
        if (userBonus >= Constants.MIN_TOPUP_AMOUNT) {
            SafeERC20.forceApprove(IERC20(_claim), _ve, userBonus);
            IVeClaimNFT(_ve).addToLockFor(user, intoTokenId, userBonus);
            SafeERC20.forceApprove(IERC20(_claim), _ve, 0);
        } else if (userBonus > 0) {
            assembly {
                let r := sload(_SLOT_FURNACE_RESERVE)
                sstore(_SLOT_FURNACE_RESERVE, add(r, userBonus))
            }
            userBonus = 0;
        }

        bonusClaim = userBonus;
        if (minBonusOut > 0 && bonusClaim < minBonusOut) revert Errors.MinVeOutNotMet();

        _syncFurnaceReserveDelegated();

        emit FurnaceMergeWithBonus(
            user,
            fromTokenId,
            intoTokenId,
            fromAmt,
            intoAmt,
            newAmt + userBonus,
            newEnd,
            newAutoMax,
            durationDelta,
            bonusClaim
        );
    }
}
