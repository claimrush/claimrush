// SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

import {Constants} from "./lib/Constants.sol";
import {Errors} from "./lib/Errors.sol";
import {SafeApprove} from "./lib/SafeApprove.sol";
import {SafeERC20View} from "./lib/SafeERC20View.sol";
import {SafeTransfer} from "./lib/SafeTransfer.sol";
import {IDexAdapter} from "./interfaces/IDexAdapter.sol";
import {IEntryTokenRegistry} from "./interfaces/IEntryTokenRegistry.sol";
import {IFurnaceQuoter} from "./interfaces/IFurnaceQuoter.sol";
import {IMineCore} from "./interfaces/IMineCore.sol";
import {IVeClaimNFT} from "./interfaces/IVeClaimNFT.sol";
import {IWETH} from "./interfaces/IWETH.sol";

/// @notice Externalized cross-contract guard checks for Furnace.
/// @dev Bound to the canonical CLAIM/ve roots so proxied Furnace runtimes can share the same helper
///      model as direct deployments without pinning a specific Furnace address in immutable bytecode.
contract FurnaceGuardHelper {
    bytes4 internal constant _SEL_FURNACE = bytes4(keccak256("furnace()"));
    address private immutable _claim;
    address private immutable _ve;
    address private immutable _self;
    bytes4 internal constant _SEL_CLAIM = bytes4(keccak256("claim()"));
    bytes4 internal constant _SEL_VE = bytes4(keccak256("ve()"));
    bytes4 internal constant _SEL_MINE_CORE = bytes4(keccak256("mineCore()"));
    bytes4 internal constant _SEL_MINE_MARKET = bytes4(keccak256("mineMarket()"));
    bytes4 internal constant _SEL_ROYALTIES = bytes4(keccak256("royalties()"));
    bytes4 internal constant _SEL_DELEGATION_HUB = bytes4(keccak256("delegationHub()"));
    bytes4 internal constant _SEL_ENTRY_TOKEN_REGISTRY = bytes4(keccak256("entryTokenRegistry()"));

    // ── Furnace storage layout mirrors ────────────────────────────────────────────────
    // The four `*Delegated` emergency / rescue functions below run in Furnace's storage
    // context. Hardcoded slot indices avoid a 9-arg parameter explosion at the
    // delegatecall boundary. Parity with Furnace's storage layout is enforced in
    // test/SecurityCriticalConstantsPinned.t.sol — any drift in either contract MUST
    // update both sides atomically.
    uint256 internal constant _SLOT_DEPLOYMENT_TIME = 54;
    uint256 internal constant _SLOT_MINE_CORE = 56;
    uint256 internal constant _SLOT_LP_REWARDS_VAULT = 58;
    uint256 internal constant _SLOT_PENDING_SELL_SELLER = 59;
    uint256 internal constant _SLOT_DELEGATION_HUB = 63;
    uint256 internal constant _SLOT_FURNACE_RESERVE = 64;
    uint256 internal constant _SLOT_LAST_LP_OVERFLOW_DRIP_UPDATE = 69;
    uint256 internal constant _SLOT_LP_STREAM_RATE_PER_SEC = 70;
    uint256 internal constant _SLOT_LP_STREAM_PERIOD_FINISH = 71;
    uint256 internal constant _SLOT_LP_STREAM_LAST_UPDATE = 72;
    uint256 internal constant _SLOT_LP_STREAM_CARRY = 73;
    uint256 internal constant _SLOT_EMERGENCY_REWIRE_EXECUTE_AFTER = 74;
    uint256 internal constant _SLOT_EMERGENCY_REWIRE_TARGET_VAULT = 75;
    uint256 internal constant _SLOT_LAST_AUTOMAX_BONUS_CLAIM = 78;
    uint256 internal constant _SLOT_BONUS_BASIS = 79;

    uint256 internal constant _EMERGENCY_VAULT_REWIRE_DELAY = 7 days;

    struct ExistingLockResolution {
        uint256 veOut;
        uint256 lockEnd;
        uint256 newEnd;
    }

    struct SellExecutionData {
        uint256 claimOut;
        uint256 spreadBps;
        uint256 lpSaleShareBps;
        uint256 lpReward;
        uint256 reserveAdd;
        uint256 bonusBpsUsed;
    }

    struct OverflowDripPreview {
        uint256 elapsed;
        uint256 inflowPerDay;
        uint256 capInflowPerDay;
        uint256 alphaBps;
        uint256 gateBps;
        uint256 perDay;
    }

    constructor(address claim_, address ve_) {
        if (claim_ == address(0) || ve_ == address(0)) revert Errors.ZeroAddress();
        // Reject empty code AND EIP-7702 delegated-EOA prefixes. A 7702 delegation header is
        // exactly 23 bytes (`0xEF 0x01 0x00` + 20-byte delegate). Requiring `> 23` excludes
        // both bare EOAs and delegated EOAs while remaining trivially true for any real
        // contract. The extcodehash check provides parity with FurnaceQuoter and rejects the
        // narrow CREATE2-pre-execution case where size > 0 but codehash == keccak256("").
        if (claim_.code.length <= 23 || ve_.code.length <= 23) revert Errors.NotAContract();
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
        _self = address(this);
    }

    function _isCanonicalFurnace(address furnace) internal view returns (bool) {
        // `> 23` rejects bare EOAs and EIP-7702 delegated EOAs (whose 23-byte delegation
        // designator would otherwise satisfy a `code.length != 0` check while still being
        // controlled by the underlying EOA's delegation tuple).
        if (furnace == address(0) || furnace.code.length <= 23) return false;
        if (_staticcallAddress(furnace, _SEL_CLAIM) != _claim) return false;
        if (_staticcallAddress(furnace, _SEL_VE) != _ve) return false;
        return true;
    }

    /// @dev EIP-7702 designators are exactly 23 bytes long and start with the magic prefix
    ///      `0xEF0100`. The setter validators below treat that exact shape as a delegated EOA
    ///      and revert `Errors.DelegatedEOA()`. Any other 23-byte (or smaller) contract is
    ///      accepted by this helper — the per-validator `code.length == 0` check is the
    ///      "must be a contract" gate. This avoids the over-rejection of legitimate
    ///      small-code contracts that the prior `<= 23` shortcut produced.
    function _rejectDelegatedEOA(address account) internal view {
        if (account.code.length != 23) return;
        bytes32 head;
        assembly ("memory-safe") {
            let ptr := mload(0x40)
            mstore(ptr, 0)
            extcodecopy(account, ptr, 0, 3)
            head := mload(ptr)
        }
        if (bytes3(head) == bytes3(0xef0100)) revert Errors.DelegatedEOA();
    }

    function _requireFurnaceOrSelf() internal view {
        if (msg.sender == _self) return;
        if (!_isCanonicalFurnace(msg.sender)) revert Errors.NotAuthorized();
    }

    function _requireDelegatecallCanonicalFurnace() internal view {
        if (!_isCanonicalFurnace(address(this))) revert Errors.NotAuthorized();
    }

    /// @notice Clamp `durationSeconds` to [`MIN_LOCK_DURATION`, `MAX_LOCK_DURATION`] and return the
    ///         duration-weight curve value at integer-bps resolution.
    /// @dev Returns `floor(_clampAndDurationWeight(d).weight / WEIGHT_PRECISION)` for the second
    ///      output, so external integrators continue to receive the bps-shaped view of the curve.
    ///      Value-paying callers inside the protocol use the sub-bp `_clampAndDurationWeight` /
    ///      `_weightDelta` pair directly to keep `principalEff` proportional to time committed.
    function clampAndDurationWeightBps(uint256 durationSeconds)
        external
        pure
        returns (uint256 clampedDuration, uint256 weightBps)
    {
        uint256 weight;
        (clampedDuration, weight) = _clampAndDurationWeight(durationSeconds);
        weightBps = weight / Constants.WEIGHT_PRECISION;
    }

    /// @notice Clamp `durationSeconds` and evaluate the Furnace duration-weight curve at sub-bp
    ///         (`WEIGHT_PRECISION`) resolution.
    /// @dev Piecewise-linear interpolation across the canonical breakpoints
    ///      (7d / 14d / 21d / 30d / 90d / 180d / 270d / 365d at 100 / 175 / 300 / 500 / 1500 /
    ///      4000 / 6500 / 10000 bps respectively). The output sits in
    ///      `[100 * WEIGHT_PRECISION, BPS_DENOM * WEIGHT_PRECISION]` and is paired with
    ///      `Constants.WEIGHT_DENOM` when computing
    ///      `principalEff = mulDiv(amount, weightDelta, WEIGHT_DENOM)`.
    function _clampAndDurationWeight(uint256 durationSeconds)
        internal
        pure
        returns (uint256 clampedDuration, uint256 weight)
    {
        if (durationSeconds < Constants.MIN_LOCK_DURATION) {
            clampedDuration = Constants.MIN_LOCK_DURATION;
        } else if (durationSeconds > Constants.MAX_LOCK_DURATION) {
            clampedDuration = Constants.MAX_LOCK_DURATION;
        } else {
            clampedDuration = durationSeconds;
        }

        uint256 d = clampedDuration;
        if (d <= Constants.MIN_LOCK_DURATION) return (clampedDuration, 100 * Constants.WEIGHT_PRECISION);
        if (d <= 14 days) return (clampedDuration, _segmentWeight(d, Constants.MIN_LOCK_DURATION, 14 days, 100, 175));
        if (d <= 21 days) return (clampedDuration, _segmentWeight(d, 14 days, 21 days, 175, 300));
        if (d <= 30 days) return (clampedDuration, _segmentWeight(d, 21 days, 30 days, 300, 500));
        if (d <= 90 days) return (clampedDuration, _segmentWeight(d, 30 days, 90 days, 500, 1500));
        if (d <= 180 days) return (clampedDuration, _segmentWeight(d, 90 days, 180 days, 1500, 4000));
        if (d <= 270 days) return (clampedDuration, _segmentWeight(d, 180 days, 270 days, 4000, 6500));
        return (clampedDuration, _segmentWeight(d, 270 days, Constants.MAX_LOCK_DURATION, 6500, Constants.BPS_DENOM));
    }

    /// @dev Sub-bp linear interpolation between two duration-weight breakpoints. Used by
    ///      `_clampAndDurationWeight` for each segment of the piecewise curve.
    function _segmentWeight(uint256 d, uint256 leftSec, uint256 rightSec, uint256 leftBps, uint256 rightBps)
        internal
        pure
        returns (uint256)
    {
        return leftBps * Constants.WEIGHT_PRECISION
            + Math.mulDiv(d - leftSec, (rightBps - leftBps) * Constants.WEIGHT_PRECISION, rightSec - leftSec);
    }

    function previewSellImpactVolume(uint256 currentVolume, uint256 lastUpdate, uint256 nowTs)
        external
        pure
        returns (uint256)
    {
        if (currentVolume == 0) return 0;

        uint256 dt = (nowTs > lastUpdate) ? (nowTs - lastUpdate) : 0;
        if (dt >= Constants.BONUS_DECAY_WINDOW) return 0;

        uint256 remaining = Constants.BONUS_DECAY_WINDOW - dt;
        return Math.mulDiv(currentVolume, remaining, Constants.BONUS_DECAY_WINDOW);
    }

    function computeBonusAmmRates(
        bool lpRewardsEnabled,
        uint256 reserveBefore,
        uint256 currentVirtualDepth,
        uint256 lastBonusUpdate,
        uint256 userSpotBps,
        uint256 lpScaleBps,
        uint256 nowTs
    )
        external
        pure
        returns (uint256 lpRateBps, uint256 grossSpotBps, uint256 virtualDepthPreview, uint256 virtualDepthEffective)
    {
        if (reserveBefore == 0 || userSpotBps == 0) return (0, 0, 0, 0);

        lpRateBps = Math.mulDiv(_lpTopupRateBps(lpRewardsEnabled, userSpotBps), lpScaleBps, Constants.BPS_DENOM);
        grossSpotBps = _grossSpotBonusBps(userSpotBps, lpRateBps);
        if (grossSpotBps == 0) return (lpRateBps, 0, 0, 0);

        virtualDepthPreview =
            _previewVirtualDepth(reserveBefore, currentVirtualDepth, lastBonusUpdate, grossSpotBps, nowTs);

        // Spec §7.3.3 / invariants §4.6: the AMM denominator is floored only at vTarget.
        // `_previewVirtualDepth(...)` already returns `max(decayedV, vTarget)`, so applying an
        // additional `reserveBefore` floor would underpay in the >100% gross regime and make the
        // execution path disagree with the state lens / quote bps.
        virtualDepthEffective = virtualDepthPreview;
    }

    function computeBonusAmmPayout(
        uint256 reserveBefore,
        uint256 principalEff,
        uint256 userSpotBps,
        uint256 lpRateBps,
        uint256 grossSpotBps,
        uint256 virtualDepthPreview,
        uint256 virtualDepthEffective
    ) external pure returns (uint256 grossBonus, uint256 quoteUserBps, uint256 quoteLpBps) {
        if (reserveBefore == 0 || principalEff == 0 || grossSpotBps == 0) return (0, 0, 0);

        grossBonus = Math.mulDiv(reserveBefore, principalEff, virtualDepthEffective + principalEff);
        if (grossBonus > reserveBefore) grossBonus = reserveBefore;

        uint256 grossQuoteBps = Math.mulDiv(reserveBefore, Constants.BPS_DENOM, virtualDepthPreview);
        if (grossQuoteBps > grossSpotBps) grossQuoteBps = grossSpotBps;

        if (lpRateBps == 0) {
            return (grossBonus, grossQuoteBps, 0);
        }

        quoteUserBps = Math.mulDiv(grossQuoteBps, Constants.BPS_DENOM, Constants.BPS_DENOM + lpRateBps);
        if (quoteUserBps > userSpotBps) quoteUserBps = userSpotBps;
        quoteLpBps = Math.mulDiv(quoteUserBps, lpRateBps, Constants.BPS_DENOM);
    }

    function validateNewLock(uint256 amountLocked, uint256 durationSeconds, bool createAutoMax)
        external
        pure
        returns (uint256 veOut)
    {
        if (createAutoMax && durationSeconds != Constants.MAX_LOCK_DURATION) revert Errors.InvalidDuration();
        if (amountLocked < Constants.MIN_LOCK_AMOUNT) revert Errors.MinLockAmountNotMet();
        veOut = Math.mulDiv(amountLocked, durationSeconds, Constants.MAX_LOCK_DURATION);
    }

    /// @notice Resolve effective lock duration and the sub-bp duration-weight used to compute
    ///         `principalEff = mulDiv(principalClaim, weight, WEIGHT_DENOM)` on a Furnace entry.
    /// @return effectiveDuration Clamped (and, for existing locks, lock-end-aligned) duration.
    /// @return weight Sub-bp duration-weight curve value at `effectiveDuration`. Pair with
    ///                `Constants.WEIGHT_DENOM`.
    function resolveEntryDurationAndWeight(
        address ve_,
        address user,
        uint256 targetTokenId,
        uint256 durationSeconds,
        bool createAutoMax
    ) external view returns (uint256 effectiveDuration, uint256 weight) {
        (uint256 d,) = _clampAndDurationWeight(durationSeconds);

        if (targetTokenId == 0) {
            if (createAutoMax && d != Constants.MAX_LOCK_DURATION) revert Errors.InvalidDuration();
            effectiveDuration = d;
            (, weight) = _clampAndDurationWeight(d);
            return (effectiveDuration, weight);
        }

        address tokenOwner = address(0);
        try IVeClaimNFT(ve_).ownerOf(targetTokenId) returns (address o) {
            tokenOwner = o;
        } catch {
            revert Errors.InvalidToken();
        }
        if (tokenOwner != user) revert Errors.NotAuthorized();

        uint256 lockEnd;
        bool autoMaxExisting;
        bool listed;
        (, lockEnd, autoMaxExisting, listed) = IVeClaimNFT(ve_).getLockInfo(targetTokenId);
        if (listed) revert Errors.LockListedOrFrozen();

        uint256 nowTs = block.timestamp;
        if (lockEnd <= nowTs) revert Errors.LockExpired();

        if (autoMaxExisting) {
            if (d != Constants.MAX_LOCK_DURATION) revert Errors.InvalidDuration();
            effectiveDuration = Constants.MAX_LOCK_DURATION;
        } else {
            effectiveDuration = lockEnd - nowTs;
            if (effectiveDuration < Constants.MIN_LOCK_DURATION) revert Errors.InvalidDuration();
        }

        (, weight) = _clampAndDurationWeight(effectiveDuration);
    }

    function resolveExistingLockDestination(
        address ve_,
        address user,
        uint256 targetTokenId,
        uint256 amountLocked,
        uint256 durationSeconds
    ) external view returns (ExistingLockResolution memory out) {
        address tokenOwner = address(0);
        try IVeClaimNFT(ve_).ownerOf(targetTokenId) returns (address o) {
            tokenOwner = o;
        } catch {
            revert Errors.InvalidToken();
        }
        if (tokenOwner != user) revert Errors.NotAuthorized();

        bool autoMaxExisting;
        bool listed;
        (, out.lockEnd, autoMaxExisting, listed) = IVeClaimNFT(ve_).getLockInfo(targetTokenId);
        if (listed) revert Errors.LockListedOrFrozen();

        uint256 nowTs = block.timestamp;
        if (out.lockEnd <= nowTs) revert Errors.LockExpired();

        uint256 newRemaining;
        uint256 oldRemaining = out.lockEnd - nowTs;
        if (autoMaxExisting) {
            if (durationSeconds != Constants.MAX_LOCK_DURATION) revert Errors.InvalidDuration();
            newRemaining = Constants.MAX_LOCK_DURATION;
        } else {
            newRemaining = oldRemaining;
            if (newRemaining < Constants.MIN_LOCK_DURATION) revert Errors.InvalidDuration();
        }

        out.veOut = Math.mulDiv(amountLocked, newRemaining, Constants.MAX_LOCK_DURATION);
        out.newEnd = nowTs + newRemaining;
    }

    function resolveExtendWithBonus(address ve_, address user, uint256 tokenId, uint256 durationSeconds)
        external
        view
        returns (uint256 lockAmount, uint256 newDuration, uint256 principalEff)
    {
        uint256 lockEnd;
        bool autoMax;
        bool listed;
        (lockAmount, lockEnd, autoMax, listed) = IVeClaimNFT(ve_).getLockInfo(tokenId);
        if (lockAmount == 0) revert Errors.InvalidToken();
        if (autoMax) revert Errors.InvalidDuration();
        if (listed) revert Errors.LockListedOrFrozen();

        uint256 nowTs = block.timestamp;
        if (lockEnd <= nowTs) revert Errors.LockExpired();
        // Symmetric with `resolveEntryDurationAndWeight`: a hostile or non-canonical `ve_`
        // that reverts from `ownerOf` is mapped to `InvalidToken` rather than propagating
        // raw revert data through Furnace's caller frame. The earlier `lockAmount == 0`
        // check already rejects non-existent tokens against the canonical VeClaimNFT, so
        // this path only triggers when a future `ve_` allows lockAmount-without-owner
        // states.
        address tokenOwner = address(0);
        try IVeClaimNFT(ve_).ownerOf(tokenId) returns (address o) {
            tokenOwner = o;
        } catch {
            revert Errors.InvalidToken();
        }
        if (tokenOwner != user) revert Errors.NotAuthorized();

        (newDuration,) = _clampAndDurationWeight(durationSeconds);
        uint256 oldRemaining = lockEnd - nowTs;
        if (newDuration <= oldRemaining) revert Errors.InvalidDuration();

        principalEff = Math.mulDiv(lockAmount, _weightDelta(newDuration, oldRemaining), Constants.WEIGHT_DENOM);
    }

    /// @notice Preflight + bonus resolution for `Furnace.mergeLocksWithBonus[For]`.
    /// @dev Mirrors `resolveExtendWithBonus` shape. All ownership / listing / expiry
    ///      reverts live here so Furnace runtime stays under EIP-170. Mixed
    ///      AutoMax / non-AutoMax pairs are accepted: `_mergeLocksInternal` resolves
    ///      the survivor via `newAutoMax = OR` and the helper computes the bonus on
    ///      the non-AutoMax side using its `MAX_LOCK_DURATION` weight delta. AutoMax
    ///      is reversible (toggle-off path), so any survivor AutoMax state is
    ///      recoverable by the user without burning principal.
    function resolveMergeWithBonus(address ve_, address user, uint256 fromTokenId, uint256 intoTokenId)
        external
        view
        returns (uint256 fromAmt, uint256 intoAmt, uint256 newRemaining, uint256 principalEff, uint256 durationDelta)
    {
        (fromAmt, intoAmt, newRemaining, principalEff, durationDelta,,) =
            _resolveMergeWithBonusInternal(ve_, user, fromTokenId, intoTokenId);
    }

    /// @notice Full merge preflight for the delegated execution body (`FurnaceExtendHelper`).
    /// @dev Same computation as `resolveMergeWithBonus`, but also returns the shorter lock's
    ///      `(tokenId, amount)` so the execution body can re-price the bonus against that lock's
    ///      user-principal basis (`bonusBasis`). A plain `view` over ve state — no Furnace storage
    ///      context required, so `FurnaceExtendHelper` reaches it via a regular external call.
    function resolveMergeWithBonusFull(address ve_, address user, uint256 fromTokenId, uint256 intoTokenId)
        external
        view
        returns (
            uint256 fromAmt,
            uint256 intoAmt,
            uint256 newRemaining,
            uint256 principalEff,
            uint256 durationDelta,
            uint256 shorterTokenId,
            uint256 shorterAmt
        )
    {
        return _resolveMergeWithBonusInternal(ve_, user, fromTokenId, intoTokenId);
    }

    /// @dev Internal twin of `resolveMergeWithBonus`. Shared between the external view
    ///      and the in-helper merge body so both paths produce identical preflight
    ///      semantics. Also returns the shorter lock's tokenId/amount so `_mergeBody`
    ///      can re-price the bonus against that lock's user-principal basis.
    function _resolveMergeWithBonusInternal(address ve_, address user, uint256 fromTokenId, uint256 intoTokenId)
        internal
        view
        returns (
            uint256 fromAmt,
            uint256 intoAmt,
            uint256 newRemaining,
            uint256 principalEff,
            uint256 durationDelta,
            uint256 shorterTokenId,
            uint256 shorterAmt
        )
    {
        if (fromTokenId == intoTokenId) revert Errors.NotAuthorized();

        // AutoMax-mismatch is intentionally allowed: `_mergeLocksInternal` resolves
        // the survivor with `newAutoMax = fromAutoMax || intoAutoMax`, which is a
        // pure duration extension for the non-AutoMax side (its remaining is shorter
        // than `MAX_LOCK_DURATION`). `_resolveLockForMerge` already maps an AutoMax
        // side's remaining to `MAX_LOCK_DURATION`, so the bonus formula below pays
        // out on the non-AutoMax side's principal at the full `BPS_AT_MAX` weight
        // delta. AutoMax is reversible by the user (toggle-off path on VeClaimNFT),
        // so no perpetual lock-in.
        uint256 fromRemaining;
        (fromAmt, fromRemaining,) = _resolveLockForMerge(ve_, user, fromTokenId);
        uint256 intoRemaining;
        (intoAmt, intoRemaining,) = _resolveLockForMerge(ve_, user, intoTokenId);

        uint256 longerRemaining;
        uint256 shorterRemaining;
        if (fromRemaining > intoRemaining) {
            longerRemaining = fromRemaining;
            shorterRemaining = intoRemaining;
            shorterAmt = intoAmt;
            shorterTokenId = intoTokenId;
        } else {
            longerRemaining = intoRemaining;
            shorterRemaining = fromRemaining;
            shorterAmt = fromAmt;
            shorterTokenId = fromTokenId;
        }
        newRemaining = longerRemaining;
        durationDelta = longerRemaining - shorterRemaining;
        principalEff = (durationDelta == 0)
            ? 0
            : Math.mulDiv(shorterAmt, _weightDelta(longerRemaining, shorterRemaining), Constants.WEIGHT_DENOM);
    }

    /// @dev Shared per-lock validation for `resolveMergeWithBonus`. Returns
    ///      `(amount, remaining, autoMax)` after all preflight reverts have passed.
    function _resolveLockForMerge(address ve_, address user, uint256 tokenId)
        internal
        view
        returns (uint256 amt, uint256 remaining, bool autoMax)
    {
        address tokenOwner = address(0);
        try IVeClaimNFT(ve_).ownerOf(tokenId) returns (address o) {
            tokenOwner = o;
        } catch {
            revert Errors.InvalidToken();
        }
        if (tokenOwner != user) revert Errors.NotAuthorized();

        uint256 lockEnd;
        bool listed;
        (amt, lockEnd, autoMax, listed) = IVeClaimNFT(ve_).getLockInfo(tokenId);
        if (amt == 0) revert Errors.InvalidToken();
        if (listed) revert Errors.LockListedOrFrozen();
        if (autoMax) {
            remaining = Constants.MAX_LOCK_DURATION;
        } else {
            uint256 nowTs = block.timestamp;
            if (lockEnd <= nowTs) revert Errors.LockExpired();
            remaining = lockEnd - nowTs;
        }
    }

    function normalizeSellExecutionQuote(
        address quoter,
        uint256 lockAmount,
        uint256 lockEnd,
        bool autoMax,
        uint256 minClaimOut,
        uint256 reserveNow,
        address core,
        uint256 fundedDay,
        uint256 fundedToday
    ) external view returns (SellExecutionData memory q, uint256 cut) {
        IFurnaceQuoter.SellExecutionQuote memory raw = _quoteSellLockForExecution(quoter, lockAmount, lockEnd, autoMax);

        uint256 claimOut = raw.claimOut;
        if (claimOut == 0) revert Errors.AmountZero();
        if (claimOut < minClaimOut) revert Errors.SlippageTooHigh();
        if (claimOut > lockAmount) revert Errors.InvariantViolation();
        if (raw.claimOut + raw.lpReward + raw.reserveAdd > lockAmount) revert Errors.InvariantViolation();

        cut = lockAmount - claimOut;
        if (raw.reserveBefore != reserveNow) revert Errors.InvariantViolation();

        uint256 reserveAdd = raw.reserveAdd + (cut - (raw.lpReward + raw.reserveAdd));
        uint256 lpReward = raw.lpReward;

        uint256 capRemaining = _lpSaleRewardCapRemaining(core, fundedDay, fundedToday);
        if (lpReward > capRemaining) {
            reserveAdd += (lpReward - capRemaining);
            lpReward = capRemaining;
        }

        uint256 lpSaleShareBps = (cut > 0 && lpReward > 0) ? Math.mulDiv(lpReward, Constants.BPS_DENOM, cut) : 0;

        q = SellExecutionData({
            claimOut: claimOut,
            spreadBps: raw.spreadBps,
            lpSaleShareBps: lpSaleShareBps,
            lpReward: lpReward,
            reserveAdd: reserveAdd,
            bonusBpsUsed: raw.bonusBpsUsed
        });
    }

    function timeSinceLaunch(address core, uint256 deploymentTime) external view returns (uint256 elapsed) {
        return _timeSinceLaunch(core, deploymentTime);
    }

    function getFurnaceInflowPerDay(address core) external view returns (uint256) {
        return _furnaceInflowPerDay(core);
    }

    function getCapInflowPerDay(address core) external view returns (uint256) {
        return _capInflowPerDayFromInflow(_furnaceInflowPerDay(core));
    }

    function previewOverflowDrip(address core, uint256 deploymentTime, uint256 reserve)
        external
        view
        returns (OverflowDripPreview memory p)
    {
        return _previewOverflowDrip(core, deploymentTime, reserve);
    }

    function getLpOverflowDripPerDay(address core, uint256 deploymentTime, uint256 reserve)
        external
        view
        returns (uint256)
    {
        return _previewOverflowDrip(core, deploymentTime, reserve).perDay;
    }

    function lpStreamLiability(uint256 carry, uint256 finish, uint256 rate, uint256 last)
        external
        pure
        returns (uint256 liability)
    {
        liability = carry;
        if (rate == 0 || finish == 0 || finish <= last) return liability;
        liability += (finish - last) * rate;
    }

    function pendingLpOverflowDripLiability(
        address core,
        uint256 deploymentTime,
        uint256 reserveBefore,
        uint256 lastOverflowUpdate
    ) external view returns (uint256 pending) {
        if (block.timestamp <= lastOverflowUpdate) return 0;
        if (reserveBefore <= Constants.RESERVE_TARGET_FINAL) return 0;

        OverflowDripPreview memory p = _previewOverflowDrip(core, deploymentTime, reserveBefore);
        if (p.perDay == 0) return 0;

        pending = Math.mulDiv(p.perDay, block.timestamp - lastOverflowUpdate, 1 days);
        if (pending == 0) return 0;

        uint256 maxSpend = reserveBefore - Constants.RESERVE_TARGET_FINAL;
        if (pending > maxSpend) pending = maxSpend;
    }

    function lpSaleRewardCapPerDay(address core) external view returns (uint256) {
        return _lpSaleRewardCapPerDay(core);
    }

    function lpSaleRewardFundedToday(uint256 fundedDay, uint256 fundedToday) external view returns (uint256) {
        return _lpSaleRewardFundedToday(fundedDay, fundedToday);
    }

    function lpSaleRewardCapRemaining(address core, uint256 fundedDay, uint256 fundedToday)
        external
        view
        returns (uint256)
    {
        return _lpSaleRewardCapRemaining(core, fundedDay, fundedToday);
    }

    function lpRewardsVaultLiability(
        address vault,
        address core,
        uint256 deploymentTime,
        uint256 reserveBefore,
        uint256 carry,
        uint256 finish,
        uint256 rate,
        uint256 lastOverflowUpdate,
        uint256 lastStreamUpdate
    ) external view returns (uint256 liability) {
        _requireFurnaceOrSelf();
        liability = _lpRewardsVaultLiabilityView(
            vault, core, deploymentTime, reserveBefore, carry, finish, rate, lastOverflowUpdate, lastStreamUpdate
        );
    }

    /// @dev Stream-plus-pending-overflow-drip liability. Internal so the emergency-rewire
    ///      delegatecall path can reuse it after SLOADing the inputs from Furnace storage,
    ///      without paying the `_requireFurnaceOrSelf` cost twice.
    function _lpRewardsVaultLiabilityView(
        address vault,
        address core,
        uint256 deploymentTime,
        uint256 reserveBefore,
        uint256 carry,
        uint256 finish,
        uint256 rate,
        uint256 lastOverflowUpdate,
        uint256 lastStreamUpdate
    ) internal view returns (uint256 liability) {
        if (vault == address(0)) return 0;

        liability = carry;
        if (rate != 0 && finish != 0 && finish > lastStreamUpdate) {
            liability += (finish - lastStreamUpdate) * rate;
        }

        if (block.timestamp <= lastOverflowUpdate || reserveBefore <= Constants.RESERVE_TARGET_FINAL) {
            return liability;
        }

        OverflowDripPreview memory p = _previewOverflowDrip(core, deploymentTime, reserveBefore);
        if (p.perDay == 0) return liability;

        uint256 pending = Math.mulDiv(p.perDay, block.timestamp - lastOverflowUpdate, 1 days);
        if (pending == 0) return liability;

        uint256 maxSpend = reserveBefore - Constants.RESERVE_TARGET_FINAL;
        if (pending > maxSpend) pending = maxSpend;
        liability += pending;
    }

    function reserveSyncState(
        address claimToken,
        address furnace,
        uint256 carry,
        uint256 finish,
        uint256 rate,
        uint256 lastStreamUpdate
    ) external view returns (uint256 cap, uint256 bal, uint256 liability) {
        _requireFurnaceOrSelf();

        liability = carry;
        if (rate != 0 && finish != 0 && finish > lastStreamUpdate) {
            liability += (finish - lastStreamUpdate) * rate;
        }

        bal = IERC20(claimToken).balanceOf(furnace);
        cap = bal > liability ? bal - liability : 0;
    }

    function _previewVirtualDepth(
        uint256 reserve,
        uint256 currentVirtualDepth,
        uint256 lastBonusUpdate,
        uint256 grossSpotBonusBps,
        uint256 nowTs
    ) internal pure returns (uint256 vNow) {
        if (reserve == 0 || grossSpotBonusBps == 0) return 0;

        uint256 V = currentVirtualDepth;
        uint256 vTarget = Math.mulDiv(reserve, Constants.BPS_DENOM, grossSpotBonusBps, Math.Rounding.Ceil);

        if (V < vTarget) V = vTarget;

        uint256 dt = (nowTs > lastBonusUpdate) ? (nowTs - lastBonusUpdate) : 0;
        if (dt >= Constants.BONUS_DECAY_WINDOW) return vTarget;

        if (V > vTarget) {
            uint256 excess = V - vTarget;
            uint256 remaining = Constants.BONUS_DECAY_WINDOW - dt;
            excess = Math.mulDiv(excess, remaining, Constants.BONUS_DECAY_WINDOW);
            V = vTarget + excess;
        }

        return V;
    }

    function _lpTopupRateBps(bool lpRewardsEnabled, uint256 userSpotBonusBps) internal pure returns (uint256) {
        if (!lpRewardsEnabled) return 0;
        if (Constants.MAX_USER_BONUS_BPS == 0) return 0;

        uint256 span = (Constants.LP_TOPUP_RATE_MAX_BPS >= Constants.LP_TOPUP_RATE_MIN_BPS)
            ? Constants.LP_TOPUP_RATE_MAX_BPS - Constants.LP_TOPUP_RATE_MIN_BPS
            : 0;

        uint256 extra = 0;
        uint256 gamma = Constants.LP_TOPUP_GAMMA;
        if (gamma == 1) {
            extra = Math.mulDiv(span, userSpotBonusBps, Constants.MAX_USER_BONUS_BPS);
        } else if (gamma == 2) {
            extra = Math.mulDiv(
                Math.mulDiv(span, userSpotBonusBps, Constants.MAX_USER_BONUS_BPS),
                userSpotBonusBps,
                Constants.MAX_USER_BONUS_BPS
            );
        } else {
            revert Errors.InvariantViolation();
        }

        uint256 rate = Constants.LP_TOPUP_RATE_MIN_BPS + extra;
        if (rate < Constants.LP_TOPUP_RATE_MIN_BPS) return Constants.LP_TOPUP_RATE_MIN_BPS;
        if (rate > Constants.LP_TOPUP_RATE_MAX_BPS) return Constants.LP_TOPUP_RATE_MAX_BPS;
        return rate;
    }

    function _grossSpotBonusBps(uint256 userSpotBonusBps, uint256 lpTopupRateBps) internal pure returns (uint256) {
        uint256 lpTopupSpotBps = Math.mulDiv(userSpotBonusBps, lpTopupRateBps, Constants.BPS_DENOM);
        uint256 gross = userSpotBonusBps + lpTopupSpotBps;
        if (gross > Constants.MAX_GROSS_BONUS_BPS) return Constants.MAX_GROSS_BONUS_BPS;
        return gross;
    }

    function _quoteSellLockForExecution(address quoter, uint256 lockAmount, uint256 lockEnd, bool autoMax)
        internal
        view
        returns (IFurnaceQuoter.SellExecutionQuote memory q)
    {
        if (quoter == address(0)) revert Errors.ZeroAddress();

        bytes memory payload = abi.encodeCall(IFurnaceQuoter.quoteSellLockForExecution, (lockAmount, lockEnd, autoMax));

        uint256 maxRd = 224;
        bool quoteOk;
        bytes memory quoteData;
        assembly ("memory-safe") {
            let ptr := add(payload, 0x20)
            let plen := mload(payload)
            quoteOk := staticcall(1000000, quoter, ptr, plen, 0, 0)
            let rdLen := returndatasize()
            if gt(rdLen, maxRd) { rdLen := maxRd }
            quoteData := mload(0x40)
            mstore(0x40, add(add(quoteData, 0x20), and(add(rdLen, 0x1f), not(0x1f))))
            mstore(quoteData, rdLen)
            returndatacopy(add(quoteData, 0x20), 0, rdLen)
        }
        if (!quoteOk || quoteData.length < 224) revert Errors.QuoteCallFailed();
        q = abi.decode(quoteData, (IFurnaceQuoter.SellExecutionQuote));
    }

    function _timeSinceLaunch(address core, uint256 deploymentTime) internal view returns (uint256 elapsed) {
        uint256 t0 = deploymentTime;

        if (core != address(0) && core.code.length != 0) {
            try IMineCore(core).emissionStartTime() returns (uint256 start) {
                t0 = start;
            } catch {}
        }

        if (block.timestamp <= t0) return 0;
        return block.timestamp - t0;
    }

    function _furnaceInflowPerDay(address core) internal view returns (uint256) {
        if (core == address(0) || core.code.length == 0) return 0;
        return IMineCore(core).getFurnaceEmissionRateAt(block.timestamp) * 1 days;
    }

    function _lpSaleRewardCapPerDay(address core) internal view returns (uint256) {
        uint256 fixedCap = Constants.LP_SALE_REWARD_CAP_FIXED_CAP_PER_DAY;
        uint256 inflowPerDay = _furnaceInflowPerDay(core);
        if (inflowPerDay == 0) return fixedCap;

        uint256 capInflow =
            Math.mulDiv(inflowPerDay, Constants.LP_SALE_REWARD_CAP_INFLOW_SHARE_BPS, Constants.BPS_DENOM);
        if (capInflow == 0) return fixedCap;

        return capInflow < fixedCap ? capInflow : fixedCap;
    }

    function _lpSaleRewardFundedToday(uint256 fundedDay, uint256 fundedToday) internal view returns (uint256) {
        uint256 day = block.timestamp / 1 days;
        if (fundedDay != day) return 0;
        return fundedToday;
    }

    function _lpSaleRewardCapRemaining(address core, uint256 fundedDay, uint256 fundedToday)
        internal
        view
        returns (uint256)
    {
        uint256 cap = _lpSaleRewardCapPerDay(core);
        uint256 used = _lpSaleRewardFundedToday(fundedDay, fundedToday);
        if (used >= cap) return 0;
        return cap - used;
    }

    function _previewOverflowDrip(address core, uint256 deploymentTime, uint256 reserve)
        internal
        view
        returns (OverflowDripPreview memory p)
    {
        if (reserve <= Constants.RESERVE_TARGET_FINAL) return p;

        p.elapsed = _timeSinceLaunch(core, deploymentTime);
        p.inflowPerDay = _furnaceInflowPerDay(core);
        p.capInflowPerDay = _capInflowPerDayFromInflow(p.inflowPerDay);
        p.alphaBps = _dripAlphaBps(p.elapsed);
        if (p.alphaBps == 0 || p.capInflowPerDay == 0) return p;

        uint256 baseCap = p.capInflowPerDay;
        if (baseCap > Constants.LP_OVERFLOW_DRIP_FIXED_CAP_PER_DAY) {
            baseCap = Constants.LP_OVERFLOW_DRIP_FIXED_CAP_PER_DAY;
        }

        p.gateBps = _gateBpsFromReserve(reserve);
        if (p.gateBps == 0) return p;

        uint256 out = Math.mulDiv(baseCap, p.gateBps, Constants.BPS_DENOM);
        p.perDay = Math.mulDiv(out, p.alphaBps, Constants.BPS_DENOM);
    }

    function dripAlphaBps(uint256 elapsed) external pure returns (uint256) {
        return _dripAlphaBps(elapsed);
    }

    function capInflowPerDayFromInflow(uint256 inflowPerDay) external pure returns (uint256) {
        return _capInflowPerDayFromInflow(inflowPerDay);
    }

    function gateBpsFromReserve(uint256 reserve) external pure returns (uint256) {
        return _gateBpsFromReserve(reserve);
    }

    function furnaceInflowPerDay(address core) external view returns (uint256) {
        return _furnaceInflowPerDay(core);
    }

    function furnaceInflowPerDayAt(address core, uint256 timestamp) external view returns (uint256) {
        if (core == address(0) || core.code.length == 0) return 0;
        return IMineCore(core).getFurnaceEmissionRateAt(timestamp) * 1 days;
    }

    function _dripAlphaBps(uint256 elapsed) internal pure returns (uint256) {
        if (elapsed <= Constants.LP_OVERFLOW_DRIP_START) return 0;

        uint256 dt = elapsed - Constants.LP_OVERFLOW_DRIP_START;
        if (dt >= Constants.LP_OVERFLOW_DRIP_RAMP) return Constants.BPS_DENOM;

        return Math.mulDiv(Constants.BPS_DENOM, dt, Constants.LP_OVERFLOW_DRIP_RAMP);
    }

    function _capInflowPerDayFromInflow(uint256 inflowPerDay) internal pure returns (uint256) {
        return Math.mulDiv(inflowPerDay, Constants.LP_OVERFLOW_DRIP_INFLOW_SHARE_CAP_BPS, Constants.BPS_DENOM);
    }

    function _gateBpsFromReserve(uint256 reserve) internal pure returns (uint256) {
        if (reserve <= Constants.RESERVE_TARGET_FINAL) return 0;

        uint256 excess = reserve - Constants.RESERVE_TARGET_FINAL;
        return Math.mulDiv(Constants.BPS_DENOM, excess, excess + Constants.LP_OVERFLOW_DRIP_GATE_K);
    }

    /// @notice Create a new VeClaimNFT lock via delegatecall (runs in Furnace storage context).
    /// @dev `payable` so delegatecall from `Furnace.enterWithEth{value: ...}` does not revert on
    ///      Solidity’s non-payable `msg.value` guard; ETH is never forwarded to `ve` (plain calls).
    function createLockDelegated(
        address claimToken,
        address veAddr,
        address user,
        uint256 amount,
        uint256 duration,
        bool autoMax
    ) external payable returns (uint256 tokenId) {
        _requireDelegatecallCanonicalFurnace();
        SafeERC20.forceApprove(IERC20(claimToken), veAddr, amount);
        tokenId = IVeClaimNFT(veAddr).createLockFor(user, amount, duration, autoMax);
        SafeERC20.forceApprove(IERC20(claimToken), veAddr, 0);
    }

    /// @notice Add to an existing VeClaimNFT lock via delegatecall (runs in Furnace storage context).
    /// @dev `payable` for the same delegatecall / `msg.value` reason as `createLockDelegated`.
    function addToLockDelegated(address claimToken, address veAddr, address user, uint256 tokenId, uint256 amount)
        external
        payable
    {
        _requireDelegatecallCanonicalFurnace();
        SafeERC20.forceApprove(IERC20(claimToken), veAddr, amount);
        IVeClaimNFT(veAddr).addToLockFor(user, tokenId, amount);
        SafeERC20.forceApprove(IERC20(claimToken), veAddr, 0);
    }

    function staticcallAddress(address target, bytes4 sel) external view returns (address) {
        return _staticcallAddress(target, sel);
    }

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

    function _requireLpRewardsVaultCompatibleInternal(
        address furnace,
        address claim_,
        address ve_,
        address vault,
        bool strictFurnaceError
    ) internal view {
        if (vault.code.length == 0) revert Errors.NotAContract();
        _rejectDelegatedEOA(vault);

        address configuredFurnace = _staticcallAddress(vault, _SEL_FURNACE);
        if (configuredFurnace != furnace) {
            if (strictFurnaceError) revert Errors.LpRewardsVaultFurnaceMismatch();
            revert Errors.WiringMismatch();
        }

        if (_staticcallAddress(vault, _SEL_CLAIM) != claim_) revert Errors.WiringMismatch();
        if (_staticcallAddress(vault, _SEL_VE) != ve_) revert Errors.WiringMismatch();
    }

    function requireLpRewardsVaultCompatible(
        address furnace,
        address claim_,
        address ve_,
        address vault,
        bool strictFurnaceError
    ) external view {
        _requireLpRewardsVaultCompatibleInternal(furnace, claim_, ve_, vault, strictFurnaceError);
    }

    function requireFurnaceQuoterCompatible(address furnace, address quoter) external view {
        if (quoter == address(0)) revert Errors.ZeroAddress();
        if (quoter.code.length == 0) revert Errors.NotAContract();
        _rejectDelegatedEOA(quoter);

        try IFurnaceQuoter(quoter).userSpotBonusBps(0, 1, 0, 0) returns (uint256) {}
        catch {
            revert Errors.InvariantViolation();
        }

        try IFurnaceQuoter(quoter).lpScaleBps(0, 1, 0, 0) returns (uint256) {}
        catch {
            revert Errors.InvariantViolation();
        }

        try IFurnaceQuoter(quoter).furnace() returns (address f) {
            if (f != furnace) revert Errors.InvalidToken();
        } catch {
            revert Errors.InvalidToken();
        }
    }

    function validateShareholderRoyaltiesSetter(address furnace, address sr) external view {
        if (sr == address(0)) revert Errors.ZeroAddress();
        if (sr.code.length == 0) revert Errors.NotAContract();
        _rejectDelegatedEOA(sr);

        address srFurnace = _staticcallAddress(sr, _SEL_FURNACE);
        if (srFurnace != address(0) && srFurnace != furnace) revert Errors.WiringMismatch();

        // Reciprocal binding: if `sr` exposes a `ve()` getter, it MUST agree with the canonical
        // veClaimNFT root. Otherwise streamed bonuses or royalty splits could route against a
        // sibling ve tree, breaking lock-share accounting.
        address srVe = _staticcallAddress(sr, _SEL_VE);
        if (srVe != address(0) && srVe != _ve) revert Errors.WiringMismatch();
    }

    function validateDistinctEntryTokenRegistry(address core, address registry) external view {
        if (registry == address(0)) revert Errors.ZeroAddress();
        if (registry.code.length == 0) revert Errors.NotAContract();
        _rejectDelegatedEOA(registry);
        if (core == address(0) || core.code.length == 0) return;

        address mineCoreRegistry = _staticcallAddress(core, _SEL_ENTRY_TOKEN_REGISTRY);
        if (mineCoreRegistry != address(0) && mineCoreRegistry == registry) revert Errors.WiringMismatch();
    }

    /// @notice Validates a candidate `mineCore` for `Furnace.setMineCore`.
    /// @dev Rejects bare EOAs (`code.length == 0`) and EIP-7702 delegators
    ///      (`_rejectDelegatedEOA`). If the candidate exposes a `furnace()` getter, it must
    ///      reciprocally bind to the calling Furnace; an inconsistent wiring is a deploy-time
    ///      misconfiguration that would otherwise silently corrupt downstream emission math.
    function validateMineCoreSetter(address furnace, address core) external view {
        if (core == address(0)) revert Errors.ZeroAddress();
        if (core.code.length == 0) revert Errors.NotAContract();
        _rejectDelegatedEOA(core);

        address coreFurnace = _staticcallAddress(core, _SEL_FURNACE);
        if (coreFurnace != address(0) && coreFurnace != furnace) revert Errors.WiringMismatch();
    }

    /// @notice Validates a candidate `mineMarket` for `Furnace.setMineMarket`.
    /// @dev Same EOA / EIP-7702 / contract-must-have-code rules as the other setters.
    ///      MineMarket does not expose a canonical `furnace()` getter today, so no reciprocal
    ///      check is enforced here — the per-call `_requireCanonicalMineMarketEntryCaller`
    ///      gate validates the live wiring on every entry.
    function validateMineMarketSetter(address market) external view {
        if (market == address(0)) revert Errors.ZeroAddress();
        if (market.code.length == 0) revert Errors.NotAContract();
        _rejectDelegatedEOA(market);
    }

    function requireOnlyShareholderRoyalties(address furnace, address ve_, address sr, address core, address sender)
        external
        view
    {
        if (sender != sr) revert Errors.OnlyShareholderRoyalties();
        if (sr == address(0) || sr.code.length == 0) revert Errors.WiringMismatch();
        if (core == address(0) || core.code.length == 0) revert Errors.WiringMismatch();

        if (
            _staticcallAddress(sr, _SEL_FURNACE) != furnace || _staticcallAddress(sr, _SEL_VE) != ve_
                || _staticcallAddress(sr, _SEL_MINE_CORE) != core || _staticcallAddress(core, _SEL_ROYALTIES) != sr
        ) {
            revert Errors.WiringMismatch();
        }
    }

    function requireCanonicalMineCoreEntryCaller(
        address furnace,
        address claim_,
        address ve_,
        address core,
        address sender
    ) external view {
        if (sender != core) revert Errors.NotAuthorized();
        if (core == address(0) || core.code.length == 0) revert Errors.WiringMismatch();

        if (
            _staticcallAddress(claim_, _SEL_MINE_CORE) != core || _staticcallAddress(core, _SEL_FURNACE) != furnace
                || _staticcallAddress(core, _SEL_CLAIM) != claim_ || _staticcallAddress(core, _SEL_VE) != ve_
                || _staticcallAddress(ve_, _SEL_FURNACE) != furnace
        ) {
            revert Errors.WiringMismatch();
        }
    }

    function _requireCanonicalMineMarketInternal(
        address furnace,
        address claim_,
        address ve_,
        address sr,
        address core,
        address mm
    ) internal view {
        if (mm == address(0) || mm.code.length == 0) revert Errors.WiringMismatch();
        if (core == address(0) || core.code.length == 0) revert Errors.WiringMismatch();
        if (sr == address(0) || sr.code.length == 0) revert Errors.WiringMismatch();

        if (
            _staticcallAddress(mm, _SEL_CLAIM) != claim_ || _staticcallAddress(mm, _SEL_VE) != ve_
                || _staticcallAddress(mm, _SEL_ROYALTIES) != sr || _staticcallAddress(ve_, _SEL_MINE_MARKET) != mm
                || _staticcallAddress(ve_, _SEL_FURNACE) != furnace
                || _staticcallAddress(claim_, _SEL_MINE_CORE) != core
                || _staticcallAddress(core, _SEL_FURNACE) != furnace || _staticcallAddress(core, _SEL_ROYALTIES) != sr
                || _staticcallAddress(core, _SEL_CLAIM) != claim_ || _staticcallAddress(core, _SEL_VE) != ve_
                || _staticcallAddress(sr, _SEL_FURNACE) != furnace || _staticcallAddress(sr, _SEL_VE) != ve_
                || _staticcallAddress(sr, _SEL_MINE_CORE) != core || _staticcallAddress(sr, _SEL_MINE_MARKET) != mm
        ) {
            revert Errors.WiringMismatch();
        }
    }

    function requireCanonicalMineMarket(
        address furnace,
        address claim_,
        address ve_,
        address sr,
        address core,
        address mm
    ) external view {
        _requireCanonicalMineMarketInternal(furnace, claim_, ve_, sr, core, mm);
    }

    function validateFreezeConfig(
        address furnace,
        address claim_,
        address ve_,
        address sr,
        address core,
        address mm,
        address quoter,
        address vault,
        address guardian_
    ) external view {
        if (sr == address(0) || core == address(0) || mm == address(0) || quoter == address(0)) {
            revert Errors.ZeroAddress();
        }

        _requireCanonicalMineMarketInternal(furnace, claim_, ve_, sr, core, mm);
        if (guardian_ != core) revert Errors.WiringMismatch();
        this.requireFurnaceQuoterCompatible(furnace, quoter);
        if (vault != address(0)) {
            _requireLpRewardsVaultCompatibleInternal(furnace, claim_, ve_, vault, true);
        }
    }

    function requireCanonicalMineMarketEntryCaller(
        address furnace,
        address claim_,
        address ve_,
        address sr,
        address core,
        address mm,
        address sender
    ) external view {
        if (sender != mm) revert Errors.NotAuthorized();
        _requireCanonicalMineMarketInternal(furnace, claim_, ve_, sr, core, mm);
    }

    function requireCanonicalMineMarketOperator(
        address furnace,
        address claim_,
        address ve_,
        address sr,
        address core,
        address mm,
        address operator
    ) external view {
        if (operator != mm) revert Errors.NotAuthorized();
        _requireCanonicalMineMarketInternal(furnace, claim_, ve_, sr, core, mm);
    }

    function requireCanonicalDelegationHub(address furnace, address claim_, address ve_, address hub, address core)
        external
        view
    {
        if (hub == address(0)) revert Errors.ZeroAddress();
        if (hub.code.length == 0) revert Errors.WiringMismatch();
        if (core == address(0) || core.code.length == 0) revert Errors.WiringMismatch();

        if (
            _staticcallAddress(core, _SEL_FURNACE) != furnace || _staticcallAddress(core, _SEL_DELEGATION_HUB) != hub
                || _staticcallAddress(core, _SEL_CLAIM) != claim_ || _staticcallAddress(core, _SEL_VE) != ve_
        ) {
            revert Errors.WiringMismatch();
        }
    }

    function _requireRegistryAndRouterConfigInternal(address regAddr, address claim_)
        internal
        view
        returns (address router, address factory, address weth, address claimToken)
    {
        if (regAddr == address(0) || regAddr.code.length == 0) revert Errors.RouterConfigNotSet();

        (router, factory, weth, claimToken) = IEntryTokenRegistry(regAddr).getRouterConfig();
        if (router == address(0) || factory == address(0) || weth == address(0) || claimToken == address(0)) {
            revert Errors.RouterConfigNotSet();
        }

        if (router.code.length == 0 || factory.code.length == 0 || weth.code.length == 0 || claimToken.code.length == 0)
        {
            revert Errors.NotAContract();
        }

        if (claimToken != claim_) revert Errors.InvalidToken();
    }

    function getValidatedRouterConfig(address regAddr, address claim_)
        external
        view
        returns (address router, address factory, address weth, address claimToken)
    {
        return _requireRegistryAndRouterConfigInternal(regAddr, claim_);
    }

    // ── Delegatecall-only helpers (executed in Furnace's context) ────────────

    struct BonusAmmFrame {
        address user;
        uint256 principalClaim;
        uint256 principalEff;
        uint256 lockDurationSec;
        uint256 reserveBefore;
        uint256 userSpotBps;
        uint256 lpRateBps;
        uint256 grossSpotBps;
        uint256 virtualDepthBefore;
        uint256 quoteUserBps;
        uint256 quoteLpBps;
        uint256 grossBonus;
        uint256 userBonus;
        uint256 lpBonus;
    }

    /// @dev Emits the BonusPaid event with 15 data words via manual log2.
    ///      MUST only be called via delegatecall from Furnace so the event address is Furnace.
    function emitBonusPaid(BonusAmmFrame memory f, uint256 reserveAfter, uint256 virtualDepthAfter) external payable {
        _requireDelegatecallCanonicalFurnace();
        // topic0 = keccak256 of the full BonusPaid event signature below.
        // If the event signature changes, this hash MUST be recomputed.
        // Signature: "BonusPaid(address,uint256,uint256,uint256,uint256,uint256,uint256,uint256,uint256,uint256,uint256,uint256,uint256,uint256,uint256,uint256)"
        assembly ("memory-safe") {
            let ptr := mload(0x40)

            mstore(ptr, mload(add(f, 0x20))) // principalClaim
            mstore(add(ptr, 0x20), mload(add(f, 0x40))) // principalEff
            mstore(add(ptr, 0x40), mload(add(f, 0x160))) // grossBonusClaim
            mstore(add(ptr, 0x60), mload(add(f, 0x180))) // userBonusClaim
            mstore(add(ptr, 0x80), mload(add(f, 0x1a0))) // lpTopupClaim
            mstore(add(ptr, 0xa0), mload(add(f, 0xa0))) // userSpotBonusBps
            mstore(add(ptr, 0xc0), mload(add(f, 0xc0))) // lpTopupRateBps
            mstore(add(ptr, 0xe0), mload(add(f, 0xe0))) // grossSpotBonusBps
            mstore(add(ptr, 0x100), mload(add(f, 0x120))) // quoteUserBonusBps
            mstore(add(ptr, 0x120), mload(add(f, 0x140))) // quoteLpTopupBps
            mstore(add(ptr, 0x140), mload(add(f, 0x60))) // lockDurationSec
            mstore(add(ptr, 0x160), mload(add(f, 0x80))) // reserveBefore
            mstore(add(ptr, 0x180), reserveAfter)
            mstore(add(ptr, 0x1a0), mload(add(f, 0x100))) // virtualDepthBefore
            mstore(add(ptr, 0x1c0), virtualDepthAfter)

            mstore(0x40, add(ptr, 0x1e0))

            let userTopic := and(mload(f), 0xffffffffffffffffffffffffffffffffffffffff)
            log2(ptr, 0x1e0, 0xc465b659478fb0fcbe9fcbc1b10229d633ba82ea04f79dd1066b526f24e8c843, userTopic)
        }
    }

    /// @dev Weight-delta effective principal: `lockAmount * delta_weight / BPS_DENOM`
    ///      (used for extend-with-bonus paths).
    function incrementalPrincipalEff(uint256 lockAmount, uint256 newDuration, uint256 oldDuration)
        external
        view
        returns (uint256)
    {
        return Math.mulDiv(lockAmount, _weightDelta(newDuration, oldDuration), Constants.WEIGHT_DENOM);
    }

    /// @dev Difference of the sub-bp duration-weight curve evaluated at `newDuration` and
    ///      `oldDuration`. Pair with `Constants.WEIGHT_DENOM` to compute `principalEff` for
    ///      extend / merge bonus payouts.
    function _weightDelta(uint256 newDuration, uint256 oldDuration) internal pure returns (uint256 delta) {
        (, uint256 oldWeight) = _clampAndDurationWeight(oldDuration);
        (, uint256 newWeight) = _clampAndDurationWeight(newDuration);
        delta = newWeight > oldWeight ? newWeight - oldWeight : 0;
    }

    /// @dev Exact-receipt transferFrom via delegatecall (runs in Furnace storage context).
    ///      Non-standard ERC20s must fail closed: any short/over receipt reverts so
    ///      Furnace token entry matches EntryTokenRegistry's listing policy.
    function receiveTokenBalanceDelta(address tokenIn, address from, uint256 amountIn)
        external
        returns (uint256 actualReceived)
    {
        _requireDelegatecallCanonicalFurnace();
        (uint256 balBefore, bool ok1) = SafeERC20View.callBalanceOf(IERC20(tokenIn), address(this));
        if (!ok1) revert Errors.TransferFailed();
        if (!SafeTransfer.callTransferFrom(IERC20(tokenIn), from, address(this), amountIn)) {
            revert Errors.TransferFailed();
        }
        (uint256 balAfter, bool ok2) = SafeERC20View.callBalanceOf(IERC20(tokenIn), address(this));
        if (!ok2) revert Errors.TransferFailed();
        if (balAfter < balBefore) revert Errors.TransferFailed();
        actualReceived = balAfter - balBefore;
        if (actualReceived != amountIn) revert Errors.TransferFailed();
    }

    /// @dev Split gross bonus into user + LP portions (pure math).
    function splitBonusAmm(uint256 grossBonus, uint256 lpRateBps)
        external
        pure
        returns (uint256 userBonus, uint256 lpBonus)
    {
        if (lpRateBps == 0 || grossBonus == 0) return (grossBonus, 0);
        userBonus = Math.mulDiv(grossBonus, Constants.BPS_DENOM, Constants.BPS_DENOM + lpRateBps);
        lpBonus = grossBonus - userBonus;
    }

    /// @dev Burn a stuck veNFT and return underlying CLAIM to the seller (delegatecall from Furnace).
    event PendingSellNFTRescued(uint256 indexed tokenId, address indexed seller, uint256 claimReturned);

    // ── Emergency vault rewire & rescue (helper offload) ──────────────────────────────
    // Furnace's `requestEmergencyVaultRewire` / `cancelEmergencyVaultRewire` /
    // `executeEmergencyVaultRewire` / `rescuePendingSellNFT` are msg.data-forwarding
    // shims into the four matching-selector functions below. They run with Furnace's
    // storage and events (address(this) is Furnace), so SLOAD/SSTORE address Furnace's
    // slots and every emit produces a log with Furnace as the emitter.
    //
    // Selectors are deliberately identical to Furnace's so the shim is a single
    // `delegatecall(msg.data)` — no abi.encodeCall, which saves ~600 bytes of Furnace
    // bytecode (load-bearing for EIP-170 headroom).
    //
    // Slot indices come from `_SLOT_*` constants pinned against Furnace's storage layout
    // in test/SecurityCriticalConstantsPinned.t.sol — drift is a CI failure, not a
    // runtime mis-write.
    event EmergencyVaultRewireRequested(address indexed vault, uint256 liability, uint256 executeAfter);
    event EmergencyVaultRewireCancelled();
    event EmergencyVaultRewireExecuted(address indexed oldVault, uint256 strandedAmount);
    event LpRewardsVaultSet(address indexed oldVault, address indexed newVault);

    /// @dev Delegated body for Furnace.requestEmergencyVaultRewire(address newVault).
    ///      Caller (Furnace) must have already enforced `onlyOwner`. Selector matches
    ///      Furnace's so msg.data forwarding works without re-encoding.
    function requestEmergencyVaultRewire(address newVault) external {
        _requireDelegatecallCanonicalFurnace();

        uint256 existing;
        assembly {
            existing := sload(_SLOT_EMERGENCY_REWIRE_EXECUTE_AFTER)
        }
        if (existing != 0) revert Errors.EmergencyRewireAlreadyRequested();
        if (newVault == address(0)) revert Errors.ZeroAddress();

        address oldVault;
        uint256 deploymentTime;
        uint256 core;
        uint256 reserve;
        uint256 carry;
        uint256 finish;
        uint256 rate;
        uint256 lastOverflowUpdate;
        uint256 lastStreamUpdate;
        assembly {
            oldVault := sload(_SLOT_LP_REWARDS_VAULT)
            deploymentTime := sload(_SLOT_DEPLOYMENT_TIME)
            core := sload(_SLOT_MINE_CORE)
            reserve := sload(_SLOT_FURNACE_RESERVE)
            carry := sload(_SLOT_LP_STREAM_CARRY)
            finish := sload(_SLOT_LP_STREAM_PERIOD_FINISH)
            rate := sload(_SLOT_LP_STREAM_RATE_PER_SEC)
            lastOverflowUpdate := sload(_SLOT_LAST_LP_OVERFLOW_DRIP_UPDATE)
            lastStreamUpdate := sload(_SLOT_LP_STREAM_LAST_UPDATE)
        }
        if (newVault == oldVault) revert Errors.WiringMismatch();

        uint256 liability = _lpRewardsVaultLiabilityView(
            oldVault,
            address(uint160(core)),
            deploymentTime,
            reserve,
            carry,
            finish,
            rate,
            lastOverflowUpdate,
            lastStreamUpdate
        );
        if (liability == 0) revert Errors.LpRewardsStreamActive();

        _requireLpRewardsVaultCompatibleInternal(address(this), _claim, _ve, newVault, true);

        uint256 executeAfter = block.timestamp + _EMERGENCY_VAULT_REWIRE_DELAY;
        assembly {
            sstore(_SLOT_EMERGENCY_REWIRE_EXECUTE_AFTER, executeAfter)
            sstore(_SLOT_EMERGENCY_REWIRE_TARGET_VAULT, newVault)
        }
        emit EmergencyVaultRewireRequested(newVault, liability, executeAfter);
    }

    /// @dev Delegated body for Furnace.cancelEmergencyVaultRewire(). Caller (Furnace)
    ///      must have already enforced `onlyOwner`. Selector matches Furnace's so msg.data
    ///      forwarding works without re-encoding.
    function cancelEmergencyVaultRewire() external {
        _requireDelegatecallCanonicalFurnace();

        uint256 executeAfter;
        assembly {
            executeAfter := sload(_SLOT_EMERGENCY_REWIRE_EXECUTE_AFTER)
        }
        if (executeAfter == 0) revert Errors.EmergencyRewireNotRequested();

        assembly {
            sstore(_SLOT_EMERGENCY_REWIRE_EXECUTE_AFTER, 0)
            sstore(_SLOT_EMERGENCY_REWIRE_TARGET_VAULT, 0)
        }
        emit EmergencyVaultRewireCancelled();
    }

    /// @dev Delegated body for Furnace.executeEmergencyVaultRewire(). Caller (Furnace)
    ///      must have already enforced `onlyOwner`. Selector matches Furnace's so msg.data
    ///      forwarding works without re-encoding.
    function executeEmergencyVaultRewire() external {
        _requireDelegatecallCanonicalFurnace();

        uint256 executeAfter;
        address oldVault;
        address newVault;
        assembly {
            executeAfter := sload(_SLOT_EMERGENCY_REWIRE_EXECUTE_AFTER)
            oldVault := sload(_SLOT_LP_REWARDS_VAULT)
            newVault := sload(_SLOT_EMERGENCY_REWIRE_TARGET_VAULT)
        }
        if (executeAfter == 0) revert Errors.EmergencyRewireNotRequested();
        if (block.timestamp < executeAfter) revert Errors.EmergencyRewireDelayNotMet();
        if (newVault == address(0)) revert Errors.ZeroAddress();
        if (newVault == oldVault) revert Errors.WiringMismatch();

        _requireLpRewardsVaultCompatibleInternal(address(this), _claim, _ve, newVault, true);

        uint256 deploymentTime;
        uint256 core;
        uint256 reserve;
        uint256 carry;
        uint256 finish;
        uint256 rate;
        uint256 lastOverflowUpdate;
        uint256 lastStreamUpdate;
        assembly {
            deploymentTime := sload(_SLOT_DEPLOYMENT_TIME)
            core := sload(_SLOT_MINE_CORE)
            reserve := sload(_SLOT_FURNACE_RESERVE)
            carry := sload(_SLOT_LP_STREAM_CARRY)
            finish := sload(_SLOT_LP_STREAM_PERIOD_FINISH)
            rate := sload(_SLOT_LP_STREAM_RATE_PER_SEC)
            lastOverflowUpdate := sload(_SLOT_LAST_LP_OVERFLOW_DRIP_UPDATE)
            lastStreamUpdate := sload(_SLOT_LP_STREAM_LAST_UPDATE)
        }
        uint256 stranded = _lpRewardsVaultLiabilityView(
            oldVault,
            address(uint160(core)),
            deploymentTime,
            reserve,
            carry,
            finish,
            rate,
            lastOverflowUpdate,
            lastStreamUpdate
        );

        uint256 nowTs = block.timestamp;
        assembly {
            sstore(_SLOT_LP_STREAM_RATE_PER_SEC, 0)
            sstore(_SLOT_LP_STREAM_PERIOD_FINISH, 0)
            sstore(_SLOT_LP_STREAM_CARRY, 0)
            sstore(_SLOT_LP_STREAM_LAST_UPDATE, nowTs)
            sstore(_SLOT_LAST_LP_OVERFLOW_DRIP_UPDATE, nowTs)
            sstore(_SLOT_EMERGENCY_REWIRE_EXECUTE_AFTER, 0)
            sstore(_SLOT_EMERGENCY_REWIRE_TARGET_VAULT, 0)
            sstore(_SLOT_LP_REWARDS_VAULT, newVault)
        }
        emit LpRewardsVaultSet(oldVault, newVault);
        emit EmergencyVaultRewireExecuted(oldVault, stranded);
    }

    /// @dev Delegated body for Furnace.rescuePendingSellNFT(uint256 tokenId). SLOADs the
    ///      seller from `pendingSellSeller[tokenId]` and the canonical ve address from
    ///      this helper's `_ve` immutable so Furnace can be a pure msg.data-forwarding
    ///      shim. Caller (Furnace) must have already enforced `onlyOwner` + `nonReentrant`.
    ///      Selector matches Furnace's (`rescuePendingSellNFT(uint256)`) for msg.data
    ///      forwarding without re-encoding.
    function rescuePendingSellNFT(uint256 tokenId) external returns (uint256 withdrawn) {
        _requireDelegatecallCanonicalFurnace();

        bytes32 sellerSlot = keccak256(abi.encode(tokenId, _SLOT_PENDING_SELL_SELLER));
        bytes32 lastBonusSlot = keccak256(abi.encode(tokenId, _SLOT_LAST_AUTOMAX_BONUS_CLAIM));
        bytes32 basisSlot = keccak256(abi.encode(tokenId, _SLOT_BONUS_BASIS));
        address seller;
        assembly {
            seller := sload(sellerSlot)
        }
        if (seller == address(0)) revert Errors.ZeroAddress();
        if (IVeClaimNFT(_ve).ownerOf(tokenId) != address(this)) revert Errors.NotAuthorized();

        assembly {
            sstore(sellerSlot, 0)
            sstore(lastBonusSlot, 0)
            sstore(basisSlot, 0)
        }

        withdrawn = IVeClaimNFT(_ve).furnaceBurnAndWithdraw(tokenId, seller);
        emit PendingSellNFTRescued(tokenId, seller, withdrawn);
    }

    /// @dev Emits LockSoldToFurnace via delegatecall so the event address is Furnace.
    event LockSoldToFurnace(
        address indexed seller,
        uint256 indexed tokenId,
        uint256 lockAmount,
        uint256 claimOut,
        uint256 spreadBps,
        uint256 cut,
        uint256 lpSaleShareBps,
        uint256 lpReward,
        uint256 reserveAdd,
        uint256 bonusRefBpsUsed
    );

    function emitLockSoldToFurnace(
        address seller,
        uint256 tokenId,
        uint256 lockAmount,
        uint256 claimOut,
        uint256 spreadBps,
        uint256 cut,
        uint256 lpSaleShareBps,
        uint256 lpReward,
        uint256 reserveAdd,
        uint256 bonusRefBpsUsed
    ) external {
        _requireDelegatecallCanonicalFurnace();
        emit LockSoldToFurnace(
            seller, tokenId, lockAmount, claimOut, spreadBps, cut, lpSaleShareBps, lpReward, reserveAdd, bonusRefBpsUsed
        );
    }

    /// @dev Emits LpOverflowDripPaid via delegatecall so the event address is Furnace.
    event LpOverflowDripPaid(
        uint256 dripAmount,
        uint256 reserveBefore,
        uint256 reserveAfter,
        uint256 alphaBps,
        uint256 gateBps,
        uint256 capInflowPerDay,
        uint256 capFixedPerDay,
        uint256 reserveTarget,
        uint256 excessBefore
    );

    function emitLpOverflowDripPaid(
        uint256 dripAmount,
        uint256 reserveBefore,
        uint256 reserveAfter,
        uint256 alphaBps,
        uint256 gateBps,
        uint256 capInflowPerDay,
        uint256 capFixedPerDay,
        uint256 reserveTarget,
        uint256 excessBefore
    ) external {
        _requireDelegatecallCanonicalFurnace();
        emit LpOverflowDripPaid(
            dripAmount,
            reserveBefore,
            reserveAfter,
            alphaBps,
            gateBps,
            capInflowPerDay,
            capFixedPerDay,
            reserveTarget,
            excessBefore
        );
    }

    // ── Merge with bonus ────────────────────────────────────────────────────────────
    //
    // The merge preflight/bonus resolution lives here (`resolveMergeWithBonus` /
    // `resolveMergeWithBonusFull` / `_resolveMergeWithBonusInternal` / `_resolveLockForMerge`,
    // all pure `view` over ve state). The delegated *execution* body
    // (`Furnace.mergeLocksWithBonus[For]` -> `FurnaceExtendHelper._mergeBody`) reaches this
    // preflight via a regular external `view` call and runs the state transition + bonus
    // payout in Furnace's storage context. Consolidating the execution body alongside the
    // extend body in `FurnaceExtendHelper` keeps this helper's runtime under EIP-170.

    /// @dev Compute decayed sell impact volume + addition.
    function computeAccruedSellImpactVolume(uint256 currentVol, uint256 lastUpdate, uint256 addAmount)
        external
        view
        returns (uint256 volAfter)
    {
        uint256 decayed = 0;
        if (currentVol != 0) {
            uint256 dt = (block.timestamp > lastUpdate) ? (block.timestamp - lastUpdate) : 0;
            if (dt < Constants.BONUS_DECAY_WINDOW) {
                decayed = Math.mulDiv(currentVol, Constants.BONUS_DECAY_WINDOW - dt, Constants.BONUS_DECAY_WINDOW);
            }
        }
        volAfter = decayed + addAmount;
    }

    // ── Swap route building ─────────────────────────────────────────────────

    /// @dev Build and validate DEX swap routes from the EntryTokenRegistry for a token→CLAIM swap.
    function buildAndValidateSwapRoutes(
        address reg,
        address tokenIn,
        address router,
        address factory,
        address weth,
        address claimToken
    ) external view returns (IDexAdapter.Route[] memory dexRoutes) {
        (IEntryTokenRegistry.RegistryRoute[] memory regRoutes,) = IEntryTokenRegistry(reg).resolveFurnaceRoute(tokenIn);
        uint256 len = regRoutes.length;
        if (len == 0) revert Errors.TokenNotConfigured();
        if (len > 2) revert Errors.InvalidToken();

        if (regRoutes[0].tokenIn != tokenIn) revert Errors.InvalidToken();
        if (regRoutes[len - 1].tokenOut != claimToken) revert Errors.InvalidToken();

        if (len == 2) {
            if (regRoutes[0].tokenOut != weth || regRoutes[1].tokenIn != weth) revert Errors.InvalidToken();
        }

        dexRoutes = new IDexAdapter.Route[](len);
        for (uint256 i = 0; i < len; i++) {
            IEntryTokenRegistry.RegistryRoute memory r = regRoutes[i];
            if (r.pool == address(0)) revert Errors.TokenNotConfigured();

            address derived = IDexAdapter(router).poolFor(r.tokenIn, r.tokenOut, r.stable, factory);
            if (derived != r.pool) revert Errors.InvalidPool();

            dexRoutes[i] = IDexAdapter.Route({from: r.tokenIn, to: r.tokenOut, stable: r.stable, factory: factory});
        }

        if (dexRoutes[len - 1].to != claimToken) revert Errors.InvalidToken();
    }

    // ── Swap execution (called by Furnace) ─────────────────────────────────

    /// @notice Execute an ETH → CLAIM swap via the DexAdapter.
    /// @dev Furnace sends ETH via msg.value; CLAIM is routed to `recipient` (Furnace).
    ///      SLIPPAGE: `amountOutMin = 0` is intentional. The Furnace enforces end-to-end
    ///      sandwich protection atomically via the caller-supplied `minVeOut` parameter.
    ///      If the DEX output is sandwiched, the resulting veCLAIM falls below `minVeOut`
    ///      and the entire transaction (including the swap) reverts.
    function executeSwapEthToClaim(
        address registry,
        address router,
        address factory,
        address weth,
        address claimToken,
        address recipient
    ) external payable returns (uint256 principalClaim) {
        // slither-disable-start reentrancy-balance
        // `_requireFurnaceOrSelf` restricts callers to the Furnace, whose external entrypoints are
        // `nonReentrant`, so no callback can re-enter this path. The pre/post `balanceOf` delta is the
        // intended measurement of CLAIM actually delivered by the router — a fresh post-swap read, not
        // an exploitable stale balance.
        _requireFurnaceOrSelf();
        (bool stable, address pool) = IEntryTokenRegistry(registry).getWethClaimHop();
        if (pool == address(0)) revert Errors.WethClaimHopNotSet();

        address derived = IDexAdapter(router).poolFor(weth, claimToken, stable, factory);
        if (derived != pool) revert Errors.InvalidPool();

        IDexAdapter.Route[] memory routes = new IDexAdapter.Route[](1);
        routes[0] = IDexAdapter.Route({from: weth, to: claimToken, stable: stable, factory: factory});

        uint256 deadline = block.timestamp + Constants.SWAP_DEADLINE_SECONDS;
        // SECURITY: measure the CLAIM actually delivered to `recipient` rather than trusting the
        // router's self-reported `amounts` return value. `claimToken` is validated == the canonical
        // CLAIM upstream (getValidatedRouterConfig), so a hostile/buggy router CANNOT inflate
        // `principalClaim` beyond the CLAIM it really delivered. This keeps the caller-supplied
        // `minVeOut` a sound end-to-end bound and prevents the Furnace reserve from backing a
        // fabricated principal (audit F-1).
        uint256 balBefore = IERC20(claimToken).balanceOf(recipient);
        IDexAdapter(router).swapExactETHForTokens{value: msg.value}(0, routes, recipient, deadline);
        principalClaim = IERC20(claimToken).balanceOf(recipient) - balBefore;
        if (principalClaim == 0) revert Errors.AmountZero();
        // slither-disable-end reentrancy-balance
    }

    /// @notice Execute an ERC20 → CLAIM swap via the DexAdapter.
    /// @dev Furnace transfers `tokenIn` to this contract first; CLAIM is routed to `recipient` (Furnace).
    ///      If `tokenIn == weth`, unwraps and falls through to the ETH path.
    ///      SLIPPAGE: `amountOutMin = 0` is intentional -- see `executeSwapEthToClaim` NatSpec.
    function executeSwapTokenToClaim(
        address registry,
        address tokenIn,
        uint256 amountIn,
        address router,
        address factory,
        address weth,
        address claimToken,
        address recipient
    ) external returns (uint256 principalClaim) {
        // slither-disable-start reentrancy-balance
        // See `executeSwapEthToClaim`: the caller is gated to the `nonReentrant` Furnace and the
        // pre/post `balanceOf` delta measures CLAIM actually delivered, so the post-call read is intended.
        _requireFurnaceOrSelf();
        if (tokenIn == weth) {
            IWETH(weth).withdraw(amountIn);
            return this.executeSwapEthToClaim{value: amountIn}(registry, router, factory, weth, claimToken, recipient);
        }

        IDexAdapter.Route[] memory dexRoutes =
            this.buildAndValidateSwapRoutes(registry, tokenIn, router, factory, weth, claimToken);

        _forceApprove(IERC20(tokenIn), router, amountIn);

        uint256 deadline = block.timestamp + Constants.SWAP_DEADLINE_SECONDS;
        // SECURITY: measure delivered CLAIM rather than trusting the router's return value
        // (see executeSwapEthToClaim; audit F-1).
        uint256 balBefore = IERC20(claimToken).balanceOf(recipient);
        IDexAdapter(router).swapExactTokensForTokens(amountIn, 0, dexRoutes, recipient, deadline);
        principalClaim = IERC20(claimToken).balanceOf(recipient) - balBefore;
        if (principalClaim == 0) revert Errors.AmountZero();

        _forceApprove(IERC20(tokenIn), router, 0);
        // slither-disable-end reentrancy-balance
    }

    function _forceApprove(IERC20 token, address spender, uint256 value) internal {
        (uint256 current, bool ok) = SafeERC20View.callAllowance(token, address(this), spender);
        if (ok && current == value) return;
        if (!ok || current != 0) {
            if (!SafeApprove.callApprove(token, spender, 0)) revert Errors.ApprovalFailed();
        }
        if (value != 0) {
            if (!SafeApprove.callApprove(token, spender, value)) revert Errors.ApprovalFailed();
        }
    }

    // ── onERC721Received validation ─────────────────────────────────────────

    /// @dev Validate all preconditions for accepting a veCLAIM NFT for sellback.
    ///      `caller` is the Furnace's msg.sender (the NFT contract).
    function validateSellLockReceive(
        address furnace,
        address claim_,
        address ve_,
        address sr,
        address core,
        address mm,
        address caller,
        address operator,
        address from,
        uint256 tokenId,
        bool lockingPaused_
    ) external view {
        if (lockingPaused_) revert Errors.LockingPaused();
        if (caller != ve_) revert Errors.NotAuthorized();
        if (operator != mm) revert Errors.NotAuthorized();
        _requireCanonicalMineMarketInternal(furnace, claim_, ve_, sr, core, mm);
        if (from == address(0)) revert Errors.NotAuthorized();
        if (from == furnace) revert Errors.NotAuthorized();
        (, uint256 _lockEnd,,) = IVeClaimNFT(ve_).getLockInfo(tokenId);
        if (_lockEnd <= block.timestamp) revert Errors.LockExpired();
    }

    // ── LP stream schedule math ─────────────────────────────────────────────

    /// @dev Pure computation of new LP stream rate/finish/carry after funding `amount`.
    function computeStreamSchedule(
        uint256 amount,
        uint256 currentFinish,
        uint256 currentRate,
        uint256 carry,
        uint256 nowTs
    ) external pure returns (uint256 newRate, uint256 newFinish, uint256 newCarry) {
        uint256 remaining = 0;
        if (currentFinish > nowTs && currentRate != 0) {
            remaining = (currentFinish - nowTs) * currentRate;
        }

        uint256 total = remaining + amount + carry;
        newRate = total / Constants.LP_STREAM_WINDOW;
        // Same as total - newRate * LP_STREAM_WINDOW; `%` avoids divide-then-multiply pattern.
        newCarry = total % Constants.LP_STREAM_WINDOW;
        newFinish = nowTs + Constants.LP_STREAM_WINDOW;
    }

    /// @dev Accept ETH from WETH.withdraw() during token→CLAIM swaps (executeSwapTokenToClaim).
    ///      This receive() is unrestricted because the WETH address is not known at
    ///      construction time (it comes from the EntryTokenRegistry at runtime). ETH sent here
    ///      by accident is permanently stuck — FurnaceGuardHelper has no rescueETH surface.
    ///      Accepted risk: user-error-only, no protocol fund exposure.
    receive() external payable {}

    // ── ETH sender validation (WETH / ShareholderRoyalties) ────────────────

    /// @dev Validate that the ETH sender is either WETH or ShareholderRoyalties.
    function validateReceiveEth(address registry, address sr, address sender) external view {
        if (registry != address(0) && registry.code.length != 0) {
            try IEntryTokenRegistry(registry).getRouterConfig() returns (address, address, address weth, address) {
                if (sender == weth && weth != address(0)) return;
            } catch {}
        }
        if (sender == sr && sr != address(0)) return;
        revert Errors.NotAuthorized();
    }
}
