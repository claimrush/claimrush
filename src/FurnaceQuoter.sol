// SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

import {Constants} from "./lib/Constants.sol";
import {Errors} from "./lib/Errors.sol";

import {IDexAdapter} from "./interfaces/IDexAdapter.sol";
import {IEntryTokenRegistry} from "./interfaces/IEntryTokenRegistry.sol";
import {IClaimToken} from "./interfaces/IClaimToken.sol";
import {IVeClaimNFT} from "./interfaces/IVeClaimNFT.sol";
import {IVeClaimNFTLockStartView} from "./interfaces/IVeClaimNFTLockStartView.sol";
import {IMineCore} from "./interfaces/IMineCore.sol";

import {IFurnaceQuoter} from "./interfaces/IFurnaceQuoter.sol";
import {IFurnaceDripLens} from "./interfaces/IFurnaceDripLens.sol";

/// @dev Minimal read interface for the Furnace contract.
interface IFurnaceRead {
    function claim() external view returns (IClaimToken);
    function ve() external view returns (IVeClaimNFT);

    function entryTokenRegistry() external view returns (address);
    function lpRewardsVault() external view returns (address);

    function furnaceReserve() external view returns (uint256);
    function bonusVirtualDepth() external view returns (uint256);
    function lastBonusUpdate() external view returns (uint256);
    function lastLpOverflowDripUpdate() external view returns (uint256);

    function sellImpactVolume() external view returns (uint256);
    function lastSellImpactUpdate() external view returns (uint256);

    function getLpSaleRewardCapRemaining() external view returns (uint256);

    function lastAutoMaxBonusClaim(uint256 tokenId) external view returns (uint256);
    function bonusBasis(uint256 tokenId) external view returns (uint256);

    function deploymentTime() external view returns (uint256);
    function mineCore() external view returns (address);
    function lockingPaused() external view returns (bool);
}

/// @notice View-only quoting contract for Furnace.
/// @dev Keeps Furnace runtime bytecode small by offloading heavy quote paths.
// Immutable caching of claim/ve avoids repeated cross-contract reads in quotes.
// No upgrade risk: immutable binding means a redeployed Furnace requires a new
// quoter — this is the intended design (quoter is cheap to redeploy).
contract FurnaceQuoter is IFurnaceQuoter {
    // Immutable wiring

    address public immutable furnace;
    IClaimToken public immutable claim;
    IVeClaimNFT public immutable ve;

    constructor(address furnace_) {
        if (furnace_ == address(0)) revert Errors.ZeroAddress();
        // Use extcodesize + extcodehash double-check (matches MarketRouter._isContract)
        // to resist CREATE2 pre-deployment and post-selfdestruct edge cases.
        uint256 _size;
        assembly ("memory-safe") { _size := extcodesize(furnace_) }
        if (_size == 0) revert Errors.NotAContract();
        bytes32 _codehash;
        assembly ("memory-safe") { _codehash := extcodehash(furnace_) }
        if (_codehash == 0 || _codehash == keccak256("")) revert Errors.NotAContract();
        _rejectDelegatedEOA(furnace_);

        furnace = furnace_;

        // Cache immutables for cheaper quoting.
        IClaimToken claim_ = IFurnaceRead(furnace_).claim();
        if (address(claim_) == address(0) || address(claim_).code.length == 0) revert Errors.NotAContract();
        _rejectDelegatedEOA(address(claim_));
        claim = claim_;

        IVeClaimNFT ve_ = IFurnaceRead(furnace_).ve();
        if (address(ve_) == address(0) || address(ve_).code.length == 0) revert Errors.NotAContract();
        _rejectDelegatedEOA(address(ve_));
        ve = ve_;
    }

    /// @dev Reject EIP-7702 delegation designators as immutable wiring roots.
    ///      A 7702 designator has `code.length == 23` and begins with `0xEF0100`.
    ///      The vanilla `code.length != 0` / `extcodehash != 0` checks pass for these
    ///      addresses, so a delegated EOA could otherwise impersonate Furnace, claim, or ve
    ///      at construction and silently corrupt every quote for the lifetime of the quoter.
    function _rejectDelegatedEOA(address a) internal view {
        if (a.code.length != 23) return;
        bytes3 prefix;
        assembly ("memory-safe") {
            extcodecopy(a, 0x00, 0x00, 0x03)
            prefix := mload(0x00)
        }
        if (prefix == 0xEF0100) revert Errors.DelegatedEOA();
    }

    function _whenLockingEnabled() internal view {
        if (IFurnaceRead(furnace).lockingPaused()) revert Errors.LockingPaused();
    }

    // External view API

    function quoteEnterWithEth(
        address user,
        uint256 ethIn,
        uint256 targetTokenId,
        uint256 durationSeconds,
        bool createAutoMax
    ) external view returns (uint256 principalClaim, uint256 bonusClaim, uint256 veOut, uint256 routeTokenId) {
        _whenLockingEnabled();
        if (ethIn == 0) revert Errors.AmountZero();
        principalClaim = _principalFromEth(ethIn);
        (bonusClaim, veOut, routeTokenId) =
            _quoteAfterPrincipal(user, principalClaim, targetTokenId, durationSeconds, createAutoMax);
    }

    function quoteEnterWithClaim(
        address user,
        uint256 claimIn,
        uint256 targetTokenId,
        uint256 durationSeconds,
        bool createAutoMax
    ) external view returns (uint256 principalClaim, uint256 bonusClaim, uint256 veOut, uint256 routeTokenId) {
        _whenLockingEnabled();
        if (claimIn == 0) revert Errors.AmountZero();
        // Keep SPEC precondition checks aligned with Furnace.
        _requireRegistryAndRouterConfig();

        principalClaim = claimIn;
        (bonusClaim, veOut, routeTokenId) =
            _quoteAfterPrincipal(user, principalClaim, targetTokenId, durationSeconds, createAutoMax);
    }

    function quoteEnterWithToken(
        address user,
        address tokenIn,
        uint256 amountIn,
        uint256 targetTokenId,
        uint256 durationSeconds,
        bool createAutoMax
    ) external view returns (uint256 principalClaim, uint256 bonusClaim, uint256 veOut, uint256 routeTokenId) {
        _whenLockingEnabled();
        if (tokenIn == address(0)) revert Errors.ZeroAddress();
        if (amountIn == 0) revert Errors.AmountZero();
        if (tokenIn == address(claim)) revert Errors.InvalidToken();

        // Non-WETH token quotes are available only for routes governance has explicitly
        // marked exact-receipt safe in the Furnace entry registry.
        principalClaim = _principalFromToken(tokenIn, amountIn);
        (bonusClaim, veOut, routeTokenId) =
            _quoteAfterPrincipal(user, principalClaim, targetTokenId, durationSeconds, createAutoMax);
    }

    /// @notice Quote the bonus for extending a non-AutoMax lock to a new duration.
    function quoteExtendWithBonus(address user, uint256 tokenId, uint256 durationSeconds)
        external
        view
        returns (uint256 lockAmount, uint256 bonusClaim, uint256 newEndSec)
    {
        _whenLockingEnabled();
        (uint256 amt, uint256 lockEnd, bool autoMax, bool listed) = ve.getLockInfo(tokenId);
        if (amt == 0) revert Errors.InvalidToken();
        if (autoMax) revert Errors.InvalidDuration();
        if (listed) revert Errors.LockListedOrFrozen();
        if (lockEnd <= block.timestamp) revert Errors.LockExpired();
        if (ve.ownerOf(tokenId) != user) revert Errors.NotAuthorized();

        lockAmount = amt;

        uint256 d = _clampDurationSeconds(durationSeconds);
        uint256 oldRemaining = lockEnd - block.timestamp;
        if (d <= oldRemaining) revert Errors.InvalidDuration();

        uint256 oldWeight = _durationWeight(oldRemaining);
        uint256 newWeight = _durationWeight(d);
        uint256 delta = newWeight > oldWeight ? newWeight - oldWeight : 0;
        uint256 principalEff = Math.mulDiv(lockAmount, delta, Constants.WEIGHT_DENOM);

        // Parity with `FurnaceExtendHelper._extendBody`: re-price the extension on the user's
        // committed principal basis, not the live `lockAmount` (which already includes bonuses
        // folded back into the lock). A 0 basis marks a lock predating basis accounting and falls
        // back to the live amount. The rescale mirrors the execution path bit-for-bit.
        uint256 basis = IFurnaceRead(furnace).bonusBasis(tokenId);
        if (basis == 0) basis = lockAmount;
        if (basis < lockAmount) {
            principalEff = Math.mulDiv(principalEff, basis, lockAmount);
        }

        if (principalEff > 0) {
            (, bonusClaim,) = _quoteBonusAmmView(principalEff);
            if (bonusClaim > 0 && bonusClaim < Constants.MIN_TOPUP_AMOUNT) bonusClaim = 0;
        }

        newEndSec = block.timestamp + d;
    }

    /// @notice Quote the pending AutoMax bonus for a lock based on elapsed time since last claim;
    ///         never-claimed locks return zero bonus.
    function quoteAutoMaxBonus(uint256 tokenId) external view returns (uint256 lockAmount, uint256 bonusClaim) {
        _whenLockingEnabled();
        (lockAmount, bonusClaim) = _quoteAutoMaxBonusSingle(tokenId);
    }

    /// @notice Batch-quote pending AutoMax bonuses. Best-effort: ineligible locks return 0.
    function quoteAutoMaxBonusBatch(uint256[] calldata tokenIds)
        external
        view
        returns (uint256[] memory bonuses, uint256 totalBonus)
    {
        _whenLockingEnabled();
        uint256 n = tokenIds.length;
        if (n > Constants.MAX_AUTOMAX_BONUS_BATCH) revert Errors.BatchTooLarge();
        bonuses = new uint256[](n);
        for (uint256 i = 0; i < n;) {
            bool seenEarlier = false;
            for (uint256 j = 0; j < i; ++j) {
                if (tokenIds[j] == tokenIds[i]) {
                    seenEarlier = true;
                    break;
                }
            }

            if (!seenEarlier) {
                (, bonuses[i]) = _quoteAutoMaxBonusSingle(tokenIds[i]);
                totalBonus += bonuses[i];
            }
            unchecked {
                ++i;
            }
        }
    }

    /// @inheritdoc IFurnaceQuoter
    function filterAutoMaxBonusEligible(uint256[] calldata tokenIds) external view returns (bool[] memory eligible) {
        _whenLockingEnabled();
        uint256 n = tokenIds.length;
        eligible = new bool[](n);
        uint256 nowTs = block.timestamp;
        for (uint256 i = 0; i < n;) {
            (uint256 amt, uint256 lockEnd, bool autoMax, bool listed) = ve.getLockInfo(tokenIds[i]);
            if (amt == 0 || !autoMax || listed || lockEnd <= nowTs) {
                unchecked {
                    ++i;
                }
                continue;
            }
            uint256 lastClaim = IFurnaceRead(furnace).lastAutoMaxBonusClaim(tokenIds[i]);
            // First-touch (lastClaim == 0): lock has never been auto-max-claimed.
            // Mark eligible so the keeper performs the zero-bonus bootstrap call
            // that sets `lastAutoMaxBonusClaim[tokenId] = block.timestamp`.
            // Without this, freshly created autoMax locks accrue no bonus until
            // the owner manually invokes `claimAutoMaxBonus(tokenId)` and the UI
            // has no surface for that call. The bootstrap costs ~80k gas one
            // time per lock; the keeper-side `bootstrapTokenIds` set excludes
            // these zero-bonus calls from the owner weekly cooldown bookkeeping.
            if (lastClaim == 0) {
                eligible[i] = true;
                unchecked {
                    ++i;
                }
                continue;
            }
            uint256 lockStart = IVeClaimNFTLockStartView(address(ve)).lockStartOf(tokenIds[i]);
            if (lockStart > lastClaim) lastClaim = lockStart;
            eligible[i] = (nowTs - lastClaim) >= 1 days;
            unchecked {
                ++i;
            }
        }
    }

    /// @inheritdoc IFurnaceQuoter
    function lastAutoMaxBonusClaimBatch(uint256[] calldata tokenIds)
        external
        view
        returns (uint256[] memory lastClaims)
    {
        uint256 n = tokenIds.length;
        lastClaims = new uint256[](n);
        IFurnaceRead furnaceRead = IFurnaceRead(furnace);
        for (uint256 i = 0; i < n;) {
            lastClaims[i] = furnaceRead.lastAutoMaxBonusClaim(tokenIds[i]);
            unchecked {
                ++i;
            }
        }
    }

    /// @dev Core quote logic for a single AutoMax lock. Returns (0, 0) on ineligible.
    function _quoteAutoMaxBonusSingle(uint256 tokenId) internal view returns (uint256 lockAmount, uint256 bonusClaim) {
        (uint256 amt, uint256 lockEnd, bool autoMax, bool listed) = ve.getLockInfo(tokenId);
        if (amt == 0 || !autoMax || listed || lockEnd <= block.timestamp) return (amt, 0);

        lockAmount = amt;

        uint256 lastClaim = IFurnaceRead(furnace).lastAutoMaxBonusClaim(tokenId);
        if (lastClaim == 0) return (lockAmount, 0);

        uint256 lockStart = IVeClaimNFTLockStartView(address(ve)).lockStartOf(tokenId);
        if (lockStart > lastClaim) lastClaim = lockStart;

        uint256 elapsed = block.timestamp - lastClaim;
        if (elapsed < 1 days) return (lockAmount, 0);
        if (elapsed > Constants.MAX_LOCK_DURATION) elapsed = Constants.MAX_LOCK_DURATION;

        uint256 pseudoOldRemaining = Constants.MAX_LOCK_DURATION - elapsed;
        uint256 oldWeight = _durationWeight(pseudoOldRemaining);
        uint256 maxWeight = _durationWeight(Constants.MAX_LOCK_DURATION);
        uint256 delta = maxWeight > oldWeight ? maxWeight - oldWeight : 0;
        uint256 principalEff = Math.mulDiv(lockAmount, delta, Constants.WEIGHT_DENOM);

        if (principalEff > 0) {
            (, bonusClaim,) = _quoteBonusAmmView(principalEff);
            if (bonusClaim > 0 && bonusClaim < Constants.MIN_TOPUP_AMOUNT) bonusClaim = 0;
        }
    }

    function resolveFurnaceRoute(address tokenIn)
        external
        view
        returns (IEntryTokenRegistry.RegistryRoute[] memory route, uint256 routeTokenId)
    {
        if (tokenIn == address(0)) revert Errors.InvalidToken();

        (IEntryTokenRegistry reg, address router, address factory, address weth, address claimToken) =
            _requireRegistryAndRouterConfig();

        // Special-case: tokenIn is wrapped native (WETH). No registry route is required.
        // Mirror Furnace.enterWithToken(WETH, ...) / quoteEnterWithToken(WETH, ...) by returning
        // the canonical WETH->CLAIM hop as a single-hop route with `routeTokenId = 1` (WETH-intermediate path convention).
        if (tokenIn == weth) {
            (bool stable, address pool) = reg.getWethClaimHop();
            if (pool == address(0)) revert Errors.WethClaimHopNotSet();

            address derived = IDexAdapter(router).poolFor(weth, claimToken, stable, factory);
            if (derived != pool) revert Errors.InvalidPool();

            route = new IEntryTokenRegistry.RegistryRoute[](1);
            route[0] =
                IEntryTokenRegistry.RegistryRoute({tokenIn: weth, tokenOut: claimToken, stable: stable, pool: pool});
            routeTokenId = 1;
            return (route, routeTokenId);
        }

        (route, routeTokenId) = reg.resolveFurnaceRoute(tokenIn);
        uint256 len = route.length;
        if (len == 0 || len > 2) revert Errors.InvalidToken();

        // Defensive: route MUST start at tokenIn and end at CLAIM.
        if (route[0].tokenIn != tokenIn) revert Errors.InvalidToken();
        if (route[len - 1].tokenOut != claimToken) revert Errors.InvalidToken();

        if (len == 1) {
            if (routeTokenId != 0) revert Errors.InvalidToken();
        } else {
            if (routeTokenId != 1) revert Errors.InvalidToken();
            if (route[0].tokenOut != weth || route[1].tokenIn != weth) revert Errors.InvalidToken();
        }

        // Defensive: every registry hop must still resolve to the pinned poolFor(...) surface.
        for (uint256 i = 0; i < len; ++i) {
            IEntryTokenRegistry.RegistryRoute memory r = route[i];
            if (r.pool == address(0)) revert Errors.TokenNotConfigured();

            address derived = IDexAdapter(router).poolFor(r.tokenIn, r.tokenOut, r.stable, factory);
            if (derived != r.pool) revert Errors.InvalidPool();
        }
    }

    // Sellback quotes (lock → liquid CLAIM)

    function quoteSellLockToFurnace(address user, uint256 tokenId)
        external
        view
        returns (uint256 lockAmount, uint256 claimOut, uint256 spreadBps, uint256 lpReward, uint256 reserveAdd)
    {
        _whenLockingEnabled();
        // Load lock info (effective end for AutoMax).
        uint256 lockEnd;
        bool autoMax;
        bool listed;
        (lockAmount, lockEnd, autoMax, listed) = ve.getLockInfo(tokenId);
        if (lockAmount == 0) revert Errors.InvalidToken();
        if (listed) revert Errors.LockListedOrFrozen();

        // Ownership check (quote is user-scoped).
        if (ve.ownerOf(tokenId) != user) revert Errors.NotAuthorized();

        (claimOut, spreadBps, lpReward, reserveAdd) = _quoteSellLockToFurnaceCore(lockAmount, lockEnd, autoMax);
    }

    /// @notice Spot quote for selling based on raw lock info.
    /// @dev Used to settle listed locks (VeClaimNFT.getLockInfo marks them listed, which blocks user-scoped quotes).
    function quoteSellLockToFurnaceFromInfo(uint256 lockAmount, uint256 lockEnd, bool autoMax)
        external
        view
        returns (uint256 claimOut, uint256 spreadBps, uint256 lpReward, uint256 reserveAdd)
    {
        _whenLockingEnabled();
        if (lockAmount == 0) revert Errors.AmountZero();
        (claimOut, spreadBps, lpReward, reserveAdd) = _quoteSellLockToFurnaceCore(lockAmount, lockEnd, autoMax);
    }

    function quoteSellLockToFurnaceBreakdown(address user, uint256 tokenId)
        external
        view
        returns (SellLockQuoteBreakdown memory q)
    {
        _whenLockingEnabled();
        // Preflight lock info.
        uint256 lockAmount;
        uint256 lockEnd;
        bool autoMax;
        bool listed;
        (lockAmount, lockEnd, autoMax, listed) = ve.getLockInfo(tokenId);
        if (lockAmount == 0) revert Errors.InvalidToken();
        if (listed) revert Errors.LockListedOrFrozen();

        // Ownership check (quote is user-scoped).
        if (ve.ownerOf(tokenId) != user) revert Errors.NotAuthorized();

        uint256 nowTs = block.timestamp;
        uint256 remainingSec;
        if (autoMax) {
            remainingSec = Constants.MAX_LOCK_DURATION;
        } else {
            if (lockEnd <= nowTs) revert Errors.LockExpired();
            remainingSec = lockEnd - nowTs;
        }

        uint256 lockedSupplyExcl;
        {
            uint256 lockedSupplyBefore = ve.totalLockedClaim();
            if (lockedSupplyBefore < lockAmount) revert Errors.InvariantViolation();
            lockedSupplyExcl = lockedSupplyBefore - lockAmount;
        }

        uint256 elapsed = _timeSinceLaunch();

        // Preview reserve after any pending LP overflow drip (so UI matches execution).
        (uint256 reserveBefore,) = _previewReserveAfterLpOverflowDrip();

        SellLockMath memory m = _sellLockMath(lockAmount, remainingSec, lockedSupplyExcl, reserveBefore, elapsed);

        q.lockAmount = lockAmount;
        q.remainingSec = remainingSec;
        q.lockedSupplyExcl = lockedSupplyExcl;
        q.reserveBefore = reserveBefore;
        q.elapsed = elapsed;

        q.spotBonusBps = m.spotBonusBps;
        q.baseBonusBps = m.baseBonusBps;
        q.bonusRefBpsUsed = m.bonusRefBpsUsed;
        q.bonusBpsUsed = m.bonusRefBpsUsed;
        q.isBonusClampBinding = (m.spotBonusBps < m.baseBonusBps);

        q.spreadSystemBps = m.spreadSystemBps;
        q.durFactorBps = m.durFactorBps;
        q.spreadDurBps = m.spreadDurBps;
        q.sizeRatioBps = m.sizeRatioBps;

        q.spreadBps = m.spreadBps;
        q.claimOut = m.claimOut;
        q.lpReward = m.lpReward;
        q.reserveAdd = m.reserveAdd;
    }

    // Core Furnace state lens (UI + analytics)

    function getFurnaceState()
        external
        view
        returns (
            uint256 reserve,
            uint256 lockedSupply,
            uint256 userSpotBonusBps_,
            uint256 lpTopupRateBps,
            uint256 quoteUserBonusBps,
            uint256 quoteLpTopupBps,
            uint256 virtualDepth,
            uint256 lastUpdate
        )
    {
        // Headline state must reflect the same pending overflow-drip preview that bonus execution
        // and dedicated quote paths consume, otherwise UI state can be stale versus the next tx.
        (reserve,) = _previewReserveAfterLpOverflowDrip();
        lockedSupply = ve.totalLockedClaim();

        uint256 elapsed = _timeSinceLaunch();
        uint256 totalSupply = claim.totalSupply();

        userSpotBonusBps_ = _userSpotBonusBps(lockedSupply, totalSupply, reserve, elapsed);
        uint256 lpScaleBps_ = _lpScaleBps(lockedSupply, totalSupply, reserve, elapsed);
        bool lpEnabled = IFurnaceRead(furnace).lpRewardsVault() != address(0);
        lpTopupRateBps = Math.mulDiv(_lpTopupRateBps(lpEnabled, userSpotBonusBps_), lpScaleBps_, Constants.BPS_DENOM);

        uint256 grossSpotBonusBps_ = _grossSpotBonusBps(userSpotBonusBps_, lpTopupRateBps);

        virtualDepth = _previewVirtualDepthWithReserve(reserve, grossSpotBonusBps_);
        lastUpdate = IFurnaceRead(furnace).lastBonusUpdate();

        if (reserve == 0 || virtualDepth == 0 || userSpotBonusBps_ == 0) {
            quoteUserBonusBps = 0;
            quoteLpTopupBps = 0;
            return (
                reserve,
                lockedSupply,
                userSpotBonusBps_,
                lpTopupRateBps,
                quoteUserBonusBps,
                quoteLpTopupBps,
                virtualDepth,
                lastUpdate
            );
        }

        // Marginal quote for a small entry: grossQuoteBps = floor(R / V) (in bps), clamped to grossSpotBonusBps_.
        uint256 grossQuoteBps = Math.mulDiv(reserve, Constants.BPS_DENOM, virtualDepth);
        if (grossQuoteBps > grossSpotBonusBps_) grossQuoteBps = grossSpotBonusBps_;

        if (lpTopupRateBps == 0) {
            quoteUserBonusBps = grossQuoteBps;
            quoteLpTopupBps = 0;
            return (
                reserve,
                lockedSupply,
                userSpotBonusBps_,
                lpTopupRateBps,
                quoteUserBonusBps,
                quoteLpTopupBps,
                virtualDepth,
                lastUpdate
            );
        }

        // Convert gross quote -> user quote using the same split math as execution.
        quoteUserBonusBps = Math.mulDiv(grossQuoteBps, Constants.BPS_DENOM, Constants.BPS_DENOM + lpTopupRateBps);
        if (quoteUserBonusBps > userSpotBonusBps_) quoteUserBonusBps = userSpotBonusBps_;

        quoteLpTopupBps = Math.mulDiv(quoteUserBonusBps, lpTopupRateBps, Constants.BPS_DENOM);
    }

    // Bonus math API (for Furnace runtime; keeps Furnace under EIP-170)

    function userSpotBonusBps(uint256 lockedSupply, uint256 totalSupply, uint256 reserve, uint256 elapsed)
        external
        view
        returns (uint256)
    {
        return _userSpotBonusBps(lockedSupply, totalSupply, reserve, elapsed);
    }

    function lpScaleBps(uint256 lockedSupply, uint256 totalSupply, uint256 reserve, uint256 elapsed)
        external
        view
        returns (uint256)
    {
        return _lpScaleBps(lockedSupply, totalSupply, reserve, elapsed);
    }

    function grossSpotBonusBps(uint256 userSpotBonusBps_, uint256 lpTopupRateBps) external view returns (uint256) {
        return _grossSpotBonusBps(userSpotBonusBps_, lpTopupRateBps);
    }

    function baseUserBps(uint256 lockedSupply, uint256 totalSupply) external view returns (uint256) {
        return _baseUserBps(lockedSupply, totalSupply);
    }

    function reserveFullnessBps(uint256 reserve) external view returns (uint256) {
        return _reserveFullnessBps(reserve);
    }

    function swingAlphaBps(uint256 elapsed) external view returns (uint256) {
        return _swingAlphaBps(elapsed);
    }

    function reserveFactorBps(uint256 reserveFullnessBps_, uint256 swingAlphaBps_) external view returns (uint256) {
        return _reserveFactorBps(reserveFullnessBps_, swingAlphaBps_);
    }

    function sellRoundTripLossBps(uint256 remainingSec) external pure returns (uint256) {
        return _sellRoundTripLossBps(remainingSec);
    }

    function sellRoundTripSpreadFloorBps(uint256 userSpotBonusBps_, uint256 remainingSec)
        external
        pure
        returns (uint256)
    {
        return _sellRoundTripSpreadFloorBps(userSpotBonusBps_, remainingSec);
    }

    function previewSellImpactVolumeAt(uint256 nowTs) external view returns (uint256) {
        return _previewSellImpactVolumeAt(nowTs);
    }

    /// @notice Returns the integer-bps view of the Furnace duration-weight curve at
    ///         `durationSeconds`.
    /// @dev Equal to `_durationWeight(durationSeconds) / WEIGHT_PRECISION`. Useful for
    ///      dashboards, docs, and frontend previews. Value-paying paths inside the
    ///      protocol use `_durationWeight` directly with `Constants.WEIGHT_DENOM`.
    function durationWeightBps(uint256 durationSeconds) external pure returns (uint256) {
        return _durationWeight(durationSeconds) / Constants.WEIGHT_PRECISION;
    }

    function computeLpTopupRateBps(uint256 userSpotBonusBps_) external view returns (uint256) {
        bool lpEnabled = IFurnaceRead(furnace).lpRewardsVault() != address(0);
        return _lpTopupRateBps(lpEnabled, userSpotBonusBps_);
    }

    function clampDurationSeconds(uint256 durationSeconds) external pure returns (uint256) {
        return _clampDurationSeconds(durationSeconds);
    }

    function previewVirtualDepthWithReserve(uint256 reserve, uint256 grossSpotBonusBps_)
        external
        view
        returns (uint256)
    {
        return _previewVirtualDepthWithReserve(reserve, grossSpotBonusBps_);
    }

    function sellImpactBps(uint256 volAfter, uint256 elapsed) external pure returns (uint256) {
        return _sellImpactBps(volAfter, elapsed);
    }

    function lpSaleShareBps(uint256 userSpotBonusBps_) external pure returns (uint256) {
        return _lpSaleShareBps(userSpotBonusBps_);
    }

    // Internal quote logic

    /// @dev Clamp duration to protocol bounds.
    function _clampDurationSeconds(uint256 durationSeconds) internal pure returns (uint256) {
        if (durationSeconds < Constants.MIN_LOCK_DURATION) return Constants.MIN_LOCK_DURATION;
        if (durationSeconds > Constants.MAX_LOCK_DURATION) return Constants.MAX_LOCK_DURATION;
        return durationSeconds;
    }

    /// @dev Duration-weight curve for Furnace bonus, evaluated at sub-bp
    ///      (`Constants.WEIGHT_PRECISION`) resolution. Piecewise-linear interpolation across the
    ///      canonical breakpoints (env-config §3.4D). Output sits in
    ///      `[100 * WEIGHT_PRECISION, BPS_DENOM * WEIGHT_PRECISION]`; pair with
    ///      `Constants.WEIGHT_DENOM` when computing
    ///      `principalEff = mulDiv(amount, weightDelta, WEIGHT_DENOM)` for value-paying paths.
    ///      The bps-shaped public `durationWeightBps(uint256)` view derives from this same source.
    function _durationWeight(uint256 durationSeconds) internal pure returns (uint256) {
        uint256 d = _clampDurationSeconds(durationSeconds);
        uint256 wp = Constants.WEIGHT_PRECISION;

        // 7d => 100 bps (base case: guard against underflow if MIN_LOCK_DURATION < 7 days)
        if (d <= Constants.MIN_LOCK_DURATION) return 100 * wp;
        if (d <= 14 days) {
            return 100 * wp
                + Math.mulDiv(d - Constants.MIN_LOCK_DURATION, (175 - 100) * wp, 14 days - Constants.MIN_LOCK_DURATION);
        }

        // 14d => 175 bps
        if (d <= 21 days) {
            return 175 * wp + Math.mulDiv(d - 14 days, (300 - 175) * wp, 21 days - 14 days);
        }

        // 21 days => 300 bps
        if (d <= 30 days) {
            return 300 * wp + Math.mulDiv(d - 21 days, (500 - 300) * wp, 30 days - 21 days);
        }

        // 30d => 500 bps
        if (d <= 90 days) {
            return 500 * wp + Math.mulDiv(d - 30 days, (1500 - 500) * wp, 90 days - 30 days);
        }

        // 90d => 1500 bps
        if (d <= 180 days) {
            return 1500 * wp + Math.mulDiv(d - 90 days, (4000 - 1500) * wp, 180 days - 90 days);
        }

        // 180d => 4000 bps
        if (d <= 270 days) {
            return 4000 * wp + Math.mulDiv(d - 180 days, (6500 - 4000) * wp, 270 days - 180 days);
        }

        // 270d => 6500 bps
        // 365d => 10_000 bps
        return 6500 * wp
            + Math.mulDiv(d - 270 days, (Constants.BPS_DENOM - 6500) * wp, Constants.MAX_LOCK_DURATION - 270 days);
    }

    /// @dev View helper: preview reserve after applying LP overflow drip accrual (without mutating Furnace state).
    ///      Matches the reserve that execution would use at the start of `_applyBonusAmm`.
    function _previewReserveAfterLpOverflowDrip() internal view returns (uint256 reserveAfter, uint256 dripped) {
        uint256 reserveBefore = IFurnaceRead(furnace).furnaceReserve();
        reserveAfter = reserveBefore;

        uint256 last = IFurnaceRead(furnace).lastLpOverflowDripUpdate();
        if (block.timestamp <= last) return (reserveAfter, 0);

        // Disabled when LP rewards vault is not set.
        address vault = IFurnaceRead(furnace).lpRewardsVault();
        if (vault == address(0)) return (reserveAfter, 0);

        uint256 dt = block.timestamp - last;
        uint256 perDay = IFurnaceDripLens(furnace).getLpOverflowDripPerDay();
        if (perDay == 0) return (reserveAfter, 0);

        dripped = Math.mulDiv(perDay, dt, 1 days);
        if (dripped == 0) return (reserveAfter, 0);

        // Safety: do not allow reserve to fall below RESERVE_TARGET_FINAL.
        uint256 reserveTarget = Constants.RESERVE_TARGET_FINAL;
        if (reserveBefore <= reserveTarget) return (reserveAfter, 0);

        uint256 maxSpend = reserveBefore - reserveTarget;
        if (dripped > maxSpend) dripped = maxSpend;
        if (dripped == 0) return (reserveAfter, 0);

        reserveAfter = reserveBefore - dripped;
    }

    /// @dev View helper: preview virtual depth using an explicit reserve value.
    ///      Needed for quote views, which must simulate drip without mutating Furnace state.
    function _previewVirtualDepthWithReserve(uint256 reserve, uint256 grossSpotBonusBps_)
        internal
        view
        returns (uint256)
    {
        if (reserve == 0 || grossSpotBonusBps_ == 0) return 0;

        uint256 V = IFurnaceRead(furnace).bonusVirtualDepth();
        uint256 vTarget = Math.mulDiv(reserve, Constants.BPS_DENOM, grossSpotBonusBps_, Math.Rounding.Ceil);

        if (V < vTarget) V = vTarget;

        uint256 last = IFurnaceRead(furnace).lastBonusUpdate();
        uint256 dt = (block.timestamp > last) ? (block.timestamp - last) : 0;

        if (dt >= Constants.BONUS_DECAY_WINDOW) {
            return vTarget;
        }

        if (V > vTarget) {
            uint256 excess = V - vTarget;
            uint256 remaining = Constants.BONUS_DECAY_WINDOW - dt;
            excess = Math.mulDiv(excess, remaining, Constants.BONUS_DECAY_WINDOW);
            V = vTarget + excess;
        }

        return V;
    }

    /// @dev Computes time since launch as used by Furnace bonus + drip models.
    ///      Mirrors Furnace behavior: uses MineCore.emissionStartTime() when available.
    function _timeSinceLaunch() internal view returns (uint256) {
        uint256 t0 = IFurnaceRead(furnace).deploymentTime();
        address mineCore = IFurnaceRead(furnace).mineCore();

        if (mineCore != address(0) && mineCore.code.length != 0) {
            // `emissionStartTime()` exists on MineCore and is a public getter (set at initialization).
            // Best-effort to avoid hard failures in local/partial wiring.
            //
            // The 50_000 gas cap bounds UI view-call gas; the corresponding execution path in
            // `FurnaceGuardHelper._timeSinceLaunch` intentionally does NOT cap. A hostile MineCore
            // implementation that consumed > 50k gas here would cause this quote to fall back to
            // `deploymentTime` while execution still observed the true `emissionStartTime`. Today
            // MineCore.emissionStartTime is a single SLOAD so the asymmetry is unreachable; the
            // divergence would only matter under an adversarial MineCore rotation, which is gated
            // by the canonical-root and freeze policies.
            try IMineCore(mineCore).emissionStartTime{gas: 50_000}() returns (uint256 startTime) {
                t0 = startTime;
            } catch {
                // ignore
            }
        }

        if (block.timestamp <= t0) return 0;
        return block.timestamp - t0;
    }

    // Bonus model helpers

    function _lockedPctBps(uint256 lockedSupply, uint256 totalSupply) internal pure returns (uint256) {
        // lockedPctBps = clamp( floor(10_000 * lockedSupply / totalSupply), 0..10_000 )
        if (totalSupply == 0) return 0;

        uint256 pct = Math.mulDiv(Constants.BPS_DENOM, lockedSupply, totalSupply);
        if (pct > Constants.BPS_DENOM) return Constants.BPS_DENOM;
        return pct;
    }

    function _baseUserBps(uint256 lockedSupply, uint256 totalSupply) internal pure returns (uint256) {
        // baseUserBps = floor(MAX_USER_BONUS_BPS * LOCK_PCT_TARGET_BPS / (LOCK_PCT_TARGET_BPS + lockedPctBps))
        uint256 target = Constants.LOCK_PCT_TARGET_BPS;
        if (target == 0) return 0;

        uint256 lockedPctBps = _lockedPctBps(lockedSupply, totalSupply);
        return Math.mulDiv(Constants.MAX_USER_BONUS_BPS, target, target + lockedPctBps);
    }

    function _maxReserveFactorBps(uint256 lockedPctBps) internal pure returns (uint256) {
        uint256 lowLock = Constants.LOCK_PCT_MIN_FOR_BOOST_CAP_BPS;
        uint256 fullLock = Constants.LOCK_PCT_FULL_BOOST_CAP_BPS;

        uint256 lowCap = Constants.RESERVE_FACTOR_MAX_BPS_LOWLOCK;
        uint256 highCap = Constants.RESERVE_FACTOR_MAX_BPS;

        // Safety: never allow a cap above the hard max.
        if (lowCap > highCap) lowCap = highCap;

        if (lockedPctBps <= lowLock) return lowCap;
        if (lockedPctBps >= fullLock) return highCap;

        // Avoid division by zero if misconfigured.
        if (fullLock <= lowLock) return highCap;

        uint256 t = lockedPctBps - lowLock;
        uint256 span = fullLock - lowLock;

        uint256 inc = Math.mulDiv(highCap - lowCap, t, span);
        return lowCap + inc;
    }

    function _reserveFullnessBps(uint256 reserve) internal pure returns (uint256) {
        // reserveFullnessBps = clamp( floor(10_000 * reserve / RESERVE_TARGET_FINAL), 0..RESERVE_FACTOR_MAX_BPS )
        if (Constants.RESERVE_TARGET_FINAL == 0) return 0;
        uint256 raw = Math.mulDiv(Constants.BPS_DENOM, reserve, Constants.RESERVE_TARGET_FINAL);
        if (raw > Constants.RESERVE_FACTOR_MAX_BPS) return Constants.RESERVE_FACTOR_MAX_BPS;
        return raw;
    }

    function _swingAlphaBps(uint256 elapsed) internal pure returns (uint256) {
        // swingAlphaBps = clamp( floor(10_000 * elapsed / SWING_TIME), 0..10_000 )
        if (Constants.SWING_TIME == 0) return Constants.BPS_DENOM;
        uint256 raw = Math.mulDiv(Constants.BPS_DENOM, elapsed, Constants.SWING_TIME);
        if (raw > Constants.BPS_DENOM) return Constants.BPS_DENOM;
        return raw;
    }

    function _reserveFactorBps(uint256 reserveFullnessBps_, uint256 swingAlphaBps_) internal pure returns (uint256) {
        // reserveFactorBps = 10_000 + floor( swingAlphaBps_ * (reserveFullnessBps_ - 10_000) / 10_000 )
        // When reserveFullnessBps_ < 10_000, the factor drops below 1.0 (unsigned subtraction, ceilDiv path).
        if (swingAlphaBps_ == 0) return Constants.BPS_DENOM;
        if (reserveFullnessBps_ == Constants.BPS_DENOM) return Constants.BPS_DENOM;

        if (reserveFullnessBps_ > Constants.BPS_DENOM) {
            uint256 inc = Math.mulDiv(swingAlphaBps_, reserveFullnessBps_ - Constants.BPS_DENOM, Constants.BPS_DENOM);
            uint256 out = Constants.BPS_DENOM + inc;
            if (out > Constants.RESERVE_FACTOR_MAX_BPS) return Constants.RESERVE_FACTOR_MAX_BPS;
            return out;
        }

        uint256 dec = Math.mulDiv(
            swingAlphaBps_, Constants.BPS_DENOM - reserveFullnessBps_, Constants.BPS_DENOM, Math.Rounding.Ceil
        );

        if (dec >= Constants.BPS_DENOM) return 0;
        return Constants.BPS_DENOM - dec;
    }

    function _userSpotBonusBps(uint256 lockedSupply, uint256 totalSupply, uint256 reserve, uint256 elapsed)
        internal
        pure
        returns (uint256)
    {
        uint256 baseUserBps_ = _baseUserBps(lockedSupply, totalSupply);
        uint256 reserveFullness = _reserveFullnessBps(reserve);
        uint256 alpha = _swingAlphaBps(elapsed);
        uint256 reserveFactor = _reserveFactorBps(reserveFullness, alpha);

        // Dynamic max boost cap at low lock adoption.
        uint256 lockedPctBps = _lockedPctBps(lockedSupply, totalSupply);
        uint256 maxFactorBps = _maxReserveFactorBps(lockedPctBps);
        if (reserveFactor > maxFactorBps) reserveFactor = maxFactorBps;

        uint256 spot = Math.mulDiv(baseUserBps_, reserveFactor, Constants.BPS_DENOM);
        if (spot > Constants.MAX_USER_BONUS_BPS) return Constants.MAX_USER_BONUS_BPS;
        return spot;
    }

    /// @dev Reserve-aware scaling factor for LP rewards (down-only).
    ///      Mirrors the reserve-factor swing + dynamic cap used for the user spot bonus,
    ///      but clamps to <= 1.0x so LP rewards never increase above the base curve.
    function _lpScaleBps(uint256 lockedSupply, uint256 totalSupply, uint256 reserve, uint256 elapsed)
        internal
        pure
        returns (uint256)
    {
        uint256 reserveFullnessBps_ = _reserveFullnessBps(reserve);
        uint256 swingAlphaBps_ = _swingAlphaBps(elapsed);

        // Same reserve-factor curve as user spot.
        uint256 reserveFactorBps_ = _reserveFactorBps(reserveFullnessBps_, swingAlphaBps_);

        // Apply the same dynamic max boost cap as user spot (prevents runaway factors at low lock %).
        uint256 lockedPctBps = _lockedPctBps(lockedSupply, totalSupply);
        uint256 maxReserveFactorBps = _maxReserveFactorBps(lockedPctBps);
        if (reserveFactorBps_ > maxReserveFactorBps) reserveFactorBps_ = maxReserveFactorBps;

        // Down-only clamp.
        if (reserveFactorBps_ > Constants.BPS_DENOM) return Constants.BPS_DENOM;
        return reserveFactorBps_;
    }

    /// @dev Signature takes explicit `lpRewardsEnabled` boolean to reduce
    ///      cross-contract read divergence risk.
    function _lpTopupRateBps(bool lpRewardsEnabled, uint256 userSpotBonusBps_) internal pure returns (uint256) {
        if (!lpRewardsEnabled) return 0;

        if (Constants.MAX_USER_BONUS_BPS == 0) return 0;

        uint256 span = (Constants.LP_TOPUP_RATE_MAX_BPS >= Constants.LP_TOPUP_RATE_MIN_BPS)
            ? Constants.LP_TOPUP_RATE_MAX_BPS - Constants.LP_TOPUP_RATE_MIN_BPS
            : 0;

        uint256 extra = 0;
        uint256 gamma = Constants.LP_TOPUP_GAMMA;
        if (gamma == 1) {
            extra = Math.mulDiv(span, userSpotBonusBps_, Constants.MAX_USER_BONUS_BPS);
        } else if (gamma == 2) {
            // Convex: span * (bonus/MAX)^2  —  nested mulDiv avoids intermediate overflow.
            extra = Math.mulDiv(
                Math.mulDiv(span, userSpotBonusBps_, Constants.MAX_USER_BONUS_BPS),
                userSpotBonusBps_,
                Constants.MAX_USER_BONUS_BPS
            );
        } else {
            // Unsupported exponent (should never happen with correct Constants).
            revert Errors.InvariantViolation();
        }

        uint256 rate = Constants.LP_TOPUP_RATE_MIN_BPS + extra;

        if (rate < Constants.LP_TOPUP_RATE_MIN_BPS) return Constants.LP_TOPUP_RATE_MIN_BPS;
        if (rate > Constants.LP_TOPUP_RATE_MAX_BPS) return Constants.LP_TOPUP_RATE_MAX_BPS;
        return rate;
    }

    function _grossSpotBonusBps(uint256 userSpotBonusBps_, uint256 lpTopupRateBps) internal pure returns (uint256) {
        // grossSpot = userSpot + floor(userSpot * lpTopupRate / 10_000)
        uint256 lpTopupSpotBps = Math.mulDiv(userSpotBonusBps_, lpTopupRateBps, Constants.BPS_DENOM);
        uint256 gross = userSpotBonusBps_ + lpTopupSpotBps;
        if (gross > Constants.MAX_GROSS_BONUS_BPS) return Constants.MAX_GROSS_BONUS_BPS;
        return gross;
    }

    /// @dev View-only bonus quote that matches `_applyBonusAmm` math (but does not mutate state).
    function _quoteBonusAmmView(uint256 principalEff)
        internal
        view
        returns (uint256 grossBonus, uint256 userBonus, uint256 lpBonus)
    {
        // Mirrors `_applyBonusAmm` math; when `principalEff == 0`, bonus is zero as in execution.
        if (principalEff == 0) return (0, 0, 0);

        (uint256 reserveBefore,) = _previewReserveAfterLpOverflowDrip();
        if (reserveBefore == 0) return (0, 0, 0);

        uint256 lockedSupply = ve.totalLockedClaim();
        uint256 elapsed = _timeSinceLaunch();

        uint256 totalSupply = claim.totalSupply();

        uint256 userSpotBps = _userSpotBonusBps(lockedSupply, totalSupply, reserveBefore, elapsed);

        // Reserve-aware LP scaling (down-only).
        uint256 lpScaleBps_ = _lpScaleBps(lockedSupply, totalSupply, reserveBefore, elapsed);
        bool lpEnabled = IFurnaceRead(furnace).lpRewardsVault() != address(0);
        uint256 lpRateBps = Math.mulDiv(_lpTopupRateBps(lpEnabled, userSpotBps), lpScaleBps_, Constants.BPS_DENOM);

        uint256 grossSpotBps = _grossSpotBonusBps(userSpotBps, lpRateBps);
        if (grossSpotBps == 0) return (0, 0, 0);

        uint256 V = _previewVirtualDepthWithReserve(reserveBefore, grossSpotBps);
        if (V == 0) return (0, 0, 0);

        // Spec §7.3.3 / invariants §4.6: quotes use `max(V, vTarget)` only.
        // `_previewVirtualDepthWithReserve(...)` already returns that floor.

        // grossBonus = R * P_eff / (V + P_eff)
        grossBonus = Math.mulDiv(reserveBefore, principalEff, V + principalEff);
        if (grossBonus > reserveBefore) grossBonus = reserveBefore;

        // Split gross -> user + LP remainder.
        if (lpRateBps == 0 || grossBonus == 0) {
            userBonus = grossBonus;
            lpBonus = 0;
        } else {
            userBonus = Math.mulDiv(grossBonus, Constants.BPS_DENOM, Constants.BPS_DENOM + lpRateBps);
            lpBonus = grossBonus - userBonus;
        }
    }

    /// @dev Resolve the effective duration used by both bonus weighting and guarded veOut.
    ///      For existing non-AutoMax locks, entry does not extend duration, so the lock's
    ///      actual remaining time must control both quoting and execution.
    function _resolveDestinationDuration(
        address user,
        uint256 targetTokenId,
        uint256 durationSeconds,
        bool createAutoMax
    ) internal view returns (uint256 effectiveDuration, uint256 routeTokenId) {
        uint256 d = _clampDurationSeconds(durationSeconds);

        if (targetTokenId == 0) {
            routeTokenId = 0;
            if (createAutoMax && d != Constants.MAX_LOCK_DURATION) revert Errors.InvalidDuration();
            return (d, routeTokenId);
        }

        routeTokenId = targetTokenId;

        address owner = address(0);
        try ve.ownerOf(targetTokenId) returns (address o) {
            owner = o;
        } catch {
            revert Errors.InvalidToken();
        }

        if (owner != user) revert Errors.NotAuthorized();

        (, uint256 lockEnd, bool autoMaxExisting, bool listed) = ve.getLockInfo(targetTokenId);
        if (listed) revert Errors.LockListedOrFrozen();
        if (lockEnd <= block.timestamp) revert Errors.LockExpired();

        if (autoMaxExisting) {
            if (d != Constants.MAX_LOCK_DURATION) revert Errors.InvalidDuration();
            return (Constants.MAX_LOCK_DURATION, routeTokenId);
        }

        uint256 remaining = lockEnd - block.timestamp;
        if (remaining < Constants.MIN_LOCK_DURATION) revert Errors.InvalidDuration();
        return (remaining, routeTokenId);
    }

    function _quoteVeOutForResolvedDuration(uint256 amountLocked, uint256 effectiveDuration, uint256 routeTokenId)
        internal
        pure
        returns (uint256 veOut)
    {
        if (routeTokenId == 0 && amountLocked < Constants.MIN_LOCK_AMOUNT) revert Errors.MinLockAmountNotMet();
        veOut = Math.mulDiv(amountLocked, effectiveDuration, Constants.MAX_LOCK_DURATION);
    }

    /// @dev Shared quote path once `principalClaim` is known.
    function _quoteAfterPrincipal(
        address user,
        uint256 principalClaim,
        uint256 targetTokenId,
        uint256 durationSeconds,
        bool createAutoMax
    ) internal view returns (uint256 bonusClaim, uint256 veOut, uint256 routeTokenId) {
        (uint256 effectiveDuration, uint256 resolvedRouteTokenId) =
            _resolveDestinationDuration(user, targetTokenId, durationSeconds, createAutoMax);
        uint256 weight = _durationWeight(effectiveDuration);

        // Duration-weighted effective principal must reflect the lock's actual post-entry duration.
        uint256 principalEff = Math.mulDiv(principalClaim, weight, Constants.WEIGHT_DENOM);

        (, uint256 userBonus,) = _quoteBonusAmmView(principalEff);
        bonusClaim = userBonus;

        uint256 amountLocked = principalClaim + bonusClaim;
        veOut = _quoteVeOutForResolvedDuration(amountLocked, effectiveDuration, resolvedRouteTokenId);
        routeTokenId = resolvedRouteTokenId;
    }

    // Token routing quote helpers

    function _requireRegistryAndRouterConfig()
        internal
        view
        returns (IEntryTokenRegistry reg, address router, address factory, address weth, address claimToken)
    {
        address registryAddr = IFurnaceRead(furnace).entryTokenRegistry();
        if (registryAddr == address(0) || registryAddr.code.length == 0) revert Errors.RouterConfigNotSet();
        reg = IEntryTokenRegistry(registryAddr);

        (router, factory, weth, claimToken) = reg.getRouterConfig();
        if (router == address(0) || factory == address(0) || weth == address(0) || claimToken == address(0)) {
            revert Errors.RouterConfigNotSet();
        }

        // Defensive: require contract code for router/factory/tokens to avoid opaque ABI decode reverts.
        if (router.code.length == 0 || factory.code.length == 0 || weth.code.length == 0 || claimToken.code.length == 0)
        {
            revert Errors.NotAContract();
        }

        // Defensive: registry must be configured with this Furnace's CLAIM token.
        if (claimToken != address(claim)) revert Errors.InvalidToken();
    }

    /// @dev Bounded-returndata wrapper around IDexAdapter.getAmountsOut.
    ///      Caps returndatacopy to prevent a compromised router from inflating
    ///      memory (return-bomb) inside this view call's gas budget.
    function _principalFromDex(address router, uint256 amountIn, IDexAdapter.Route[] memory routes)
        internal
        view
        returns (uint256 principalClaim)
    {
        // Reject empty routes — maxRd would be degenerate and the
        // "amounts" array would echo amountIn as principal, yielding a 1:1 quote.
        if (routes.length == 0) revert Errors.QuoteCallFailed();
        bytes memory payload = abi.encodeCall(IDexAdapter.getAmountsOut, (amountIn, routes));
        uint256 maxRd = 64 + 32 * (routes.length + 1);
        bool ok;
        bytes memory rd;
        assembly ("memory-safe") {
            let ptr := add(payload, 0x20)
            let len := mload(payload)
            ok := staticcall(500000, router, ptr, len, 0, 0)
            let rdLen := returndatasize()
            if gt(rdLen, maxRd) { rdLen := maxRd }
            rd := mload(0x40)
            mstore(0x40, add(add(rd, 0x20), and(add(rdLen, 0x1f), not(0x1f))))
            mstore(rd, rdLen)
            returndatacopy(add(rd, 0x20), 0, rdLen)
        }
        if (!ok) revert Errors.QuoteCallFailed();
        // Minimum 64 bytes for a valid ABI-encoded uint256[] (32 offset + 32 length).
        if (rd.length < 64) revert Errors.QuoteCallFailed();
        uint256[] memory amounts = abi.decode(rd, (uint256[]));
        if (amounts.length == 0) revert Errors.QuoteCallFailed();
        if (amounts.length != routes.length + 1) revert Errors.QuoteCallFailed();
        // amounts[0] must echo the requested amountIn; reject adapter mis-computation.
        if (amounts[0] != amountIn) revert Errors.QuoteCallFailed();
        // Reject zero output — a DEX returning 0 means "no liquidity" and must
        // not be surfaced as a valid quote (callers may derive minOut from it).
        if (amounts[amounts.length - 1] == 0) revert Errors.QuoteCallFailed();
        principalClaim = amounts[amounts.length - 1];
    }

    function _principalFromEth(uint256 ethIn) internal view returns (uint256 principalClaim) {
        (IEntryTokenRegistry reg, address router, address factory, address weth, address claimToken) =
            _requireRegistryAndRouterConfig();
        (bool stable, address pool) = reg.getWethClaimHop();

        if (pool == address(0)) revert Errors.WethClaimHopNotSet();

        address derived = IDexAdapter(router).poolFor(weth, claimToken, stable, factory);
        if (derived != pool) revert Errors.InvalidPool();

        IDexAdapter.Route[] memory routes = new IDexAdapter.Route[](1);
        routes[0] = IDexAdapter.Route({from: weth, to: claimToken, stable: stable, factory: factory});

        principalClaim = _principalFromDex(router, ethIn, routes);
    }

    function _principalFromToken(address tokenIn, uint256 amountIn) internal view returns (uint256 principalClaim) {
        (IEntryTokenRegistry reg, address router, address factory, address weth, address claimToken) =
            _requireRegistryAndRouterConfig();

        // Special-case: tokenIn is wrapped native (WETH). No registry route is required.
        // Treat amountIn as native ETH (1:1 unwrap) and quote via the pinned WETH->CLAIM hop.
        if (tokenIn == weth) {
            return _principalFromEth(amountIn);
        }

        // For non-WETH tokens, this quote intentionally models only the allowlisted swap path
        // after the Furnace entry registry exact-receipt safety gate has been satisfied.

        (IEntryTokenRegistry.RegistryRoute[] memory regRoutes,) = reg.resolveFurnaceRoute(tokenIn);
        uint256 len = regRoutes.length;
        if (len == 0) revert Errors.TokenNotConfigured();
        if (len > 2) revert Errors.InvalidToken();

        // Defensive: route MUST start at tokenIn and end at CLAIM.
        if (regRoutes[0].tokenIn != tokenIn) revert Errors.InvalidToken();
        if (regRoutes[len - 1].tokenOut != claimToken) revert Errors.InvalidToken();

        // Defensive: if registry returns a 2-hop route, it MUST be tokenIn->WETH->CLAIM.
        if (len == 2) {
            if (regRoutes[0].tokenOut != weth || regRoutes[1].tokenIn != weth) revert Errors.InvalidToken();
        }

        IDexAdapter.Route[] memory dexRoutes = new IDexAdapter.Route[](len);
        for (uint256 i = 0; i < len; i++) {
            IEntryTokenRegistry.RegistryRoute memory r = regRoutes[i];
            if (r.pool == address(0)) revert Errors.TokenNotConfigured();

            address derived = IDexAdapter(router).poolFor(r.tokenIn, r.tokenOut, r.stable, factory);
            if (derived != r.pool) revert Errors.InvalidPool();

            dexRoutes[i] = IDexAdapter.Route({from: r.tokenIn, to: r.tokenOut, stable: r.stable, factory: factory});
        }

        // Defensive: route must end at CLAIM.
        if (dexRoutes[len - 1].to != claimToken) revert Errors.InvalidToken();

        principalClaim = _principalFromDex(router, amountIn, dexRoutes);
    }

    // Sellback quote logic

    function _quoteSellLockToFurnaceCore(uint256 lockAmount, uint256 lockEnd, bool autoMax)
        internal
        view
        returns (uint256 claimOut, uint256 spreadBps, uint256 lpReward, uint256 reserveAdd)
    {
        uint256 nowTs = block.timestamp;
        uint256 remainingSec;
        if (autoMax) {
            remainingSec = Constants.MAX_LOCK_DURATION;
        } else {
            if (lockEnd <= nowTs) revert Errors.LockExpired();
            remainingSec = lockEnd - nowTs;
        }

        uint256 lockedSupplyExcl;
        {
            // lockedSupplyExcl = totalLockedClaim after burning the sold lock.
            uint256 lockedSupplyBefore = ve.totalLockedClaim();
            if (lockedSupplyBefore < lockAmount) revert Errors.InvariantViolation();
            lockedSupplyExcl = lockedSupplyBefore - lockAmount;
        }

        uint256 elapsed = _timeSinceLaunch();

        // Preview reserve after any pending LP overflow drip (so UI matches execution).
        (uint256 reserveBefore,) = _previewReserveAfterLpOverflowDrip();

        SellLockMath memory m = _sellLockMath(lockAmount, remainingSec, lockedSupplyExcl, reserveBefore, elapsed);
        claimOut = m.claimOut;
        spreadBps = m.spreadBps;
        lpReward = m.lpReward;
        reserveAdd = m.reserveAdd;
    }

    /// @notice Full sell quote for Furnace execution (returns claimOut, LP share, and reserve add in one call).
    function quoteSellLockForExecution(uint256 lockAmount, uint256 lockEnd, bool autoMax)
        external
        view
        returns (IFurnaceQuoter.SellExecutionQuote memory exec)
    {
        _whenLockingEnabled();
        if (lockAmount == 0) revert Errors.AmountZero();
        uint256 nowTs = block.timestamp;
        uint256 remainingSec;
        if (autoMax) {
            remainingSec = Constants.MAX_LOCK_DURATION;
        } else {
            if (lockEnd <= nowTs) revert Errors.LockExpired();
            remainingSec = lockEnd - nowTs;
        }

        uint256 lockedSupplyExcl;
        {
            uint256 lockedSupplyBefore = ve.totalLockedClaim();
            if (lockedSupplyBefore < lockAmount) revert Errors.InvariantViolation();
            lockedSupplyExcl = lockedSupplyBefore - lockAmount;
        }

        uint256 elapsed = _timeSinceLaunch();
        (uint256 reserveBefore,) = _previewReserveAfterLpOverflowDrip();

        SellLockMath memory m = _sellLockMath(lockAmount, remainingSec, lockedSupplyExcl, reserveBefore, elapsed);

        exec.claimOut = m.claimOut;
        exec.spreadBps = m.spreadBps;
        exec.lpReward = m.lpReward;
        exec.reserveAdd = m.reserveAdd;
        exec.bonusBpsUsed = m.bonusRefBpsUsed;
        exec.reserveBefore = reserveBefore;

        uint256 cut = lockAmount - m.claimOut;
        exec.lpSaleShareBps = (cut > 0 && m.lpReward > 0) ? Math.mulDiv(m.lpReward, Constants.BPS_DENOM, cut) : 0;
    }

    struct SellLockMath {
        uint256 claimOut;
        uint256 spreadBps;
        uint256 lpReward;
        uint256 reserveAdd;

        // Bonus decomposition used by sell math.
        uint256 spotBonusBps;
        uint256 baseBonusBps;
        uint256 bonusRefBpsUsed;
        uint256 spreadSystemBps;
        uint256 durFactorBps;
        uint256 spreadDurBps;
        uint256 sizeRatioBps;
    }

    function _sellLockMath(
        uint256 lockAmount,
        uint256 remainingSec,
        uint256 lockedSupplyExcl,
        uint256 reserveBefore,
        uint256 elapsed
    ) internal view returns (SellLockMath memory m) {
        // Guard against zero-amount sells to prevent division-by-zero
        // in the sizeRatioBps calculation below (lockedSupplyExcl + lockAmount).
        if (lockAmount == 0) return m;
        uint256 totalSupply = claim.totalSupply();
        if (totalSupply == 0) revert Errors.InvariantViolation();

        // Bonus decomposition (UI + analytics).
        m.spotBonusBps = _userSpotBonusBps(lockedSupplyExcl, totalSupply, reserveBefore, elapsed);
        m.baseBonusBps = _baseUserBps(lockedSupplyExcl, totalSupply);

        // Sell-side bonus reference (prevents reserve-drain manipulation): max(spot, base).
        m.bonusRefBpsUsed = m.spotBonusBps < m.baseBonusBps ? m.baseBonusBps : m.spotBonusBps;

        uint256 spreadSystemBps = _sellSystemSpreadBps(m.bonusRefBpsUsed);

        // Apply duration modifier (piecewise-linear on remaining time).
        uint256 durFactorBps = _sellDurationFactorBps(remainingSec);
        uint256 spreadDurBps = Math.mulDiv(spreadSystemBps, durFactorBps, Constants.BPS_DENOM);

        // Expose intermediate fields for UI/analytics.
        m.spreadSystemBps = spreadSystemBps;
        m.durFactorBps = durFactorBps;
        m.spreadDurBps = spreadDurBps;
        m.sizeRatioBps = Math.mulDiv(Constants.BPS_DENOM, lockAmount, lockedSupplyExcl + lockAmount);

        m.spreadBps = _sellSpreadWithSize(spreadDurBps, m.sizeRatioBps);

        // Duration-spread floor: at 7d remaining, total spread must be at least 1.2%.
        if (remainingSec <= Constants.MIN_LOCK_DURATION && m.spreadBps < Constants.SELL_SPREAD_FLOOR_7D_BPS) {
            m.spreadBps = Constants.SELL_SPREAD_FLOOR_7D_BPS;
        }

        // Round-trip loss floor (principal): enforce a minimum buy→sell loss at this remaining duration.
        uint256 rtFloorBps = _sellRoundTripSpreadFloorBps(m.bonusRefBpsUsed, remainingSec);
        if (m.spreadBps < rtFloorBps) {
            m.spreadBps = rtFloorBps;
        }

        // Burst sell impact add-on (decays linearly over BONUS_DECAY_WINDOW).
        // Uses post-trade volume (volBefore + lockAmount) to make splitting ineffective.
        {
            uint256 volBefore = _previewSellImpactVolumeAt(block.timestamp);
            uint256 volAfter = volBefore + lockAmount;
            uint256 impactBps = _sellImpactBps(volAfter, elapsed);

            if (impactBps != 0) {
                m.spreadBps += impactBps;
                if (m.spreadBps > Constants.SELL_SPREAD_MAX_BPS) m.spreadBps = Constants.SELL_SPREAD_MAX_BPS;
            }
        }

        if (m.spreadBps >= Constants.BPS_DENOM) {
            m.claimOut = 0;
        } else {
            m.claimOut = Math.mulDiv(lockAmount, Constants.BPS_DENOM - m.spreadBps, Constants.BPS_DENOM);
        }

        uint256 cut = lockAmount - m.claimOut;

        // LP rewards are disabled when vault is not set.
        address vault = IFurnaceRead(furnace).lpRewardsVault();
        if (vault != address(0)) {
            uint256 lpShareBps = _lpSaleShareBps(m.bonusRefBpsUsed);

            // Reserve-aware LP scaling (down-only): scale LP share by the current reserve factor.
            uint256 lpScaleBps_ = _lpScaleBps(lockedSupplyExcl, totalSupply, reserveBefore, elapsed);
            lpShareBps = Math.mulDiv(lpShareBps, lpScaleBps_, Constants.BPS_DENOM);

            uint256 lpReward = Math.mulDiv(cut, lpShareBps, Constants.BPS_DENOM);

            // Daily cap on volume-driven LP funding from sellbacks.
            uint256 remainingCap = IFurnaceRead(furnace).getLpSaleRewardCapRemaining();
            if (lpReward > remainingCap) lpReward = remainingCap;

            m.lpReward = lpReward;
        } else {
            m.lpReward = 0;
        }

        m.reserveAdd = cut - m.lpReward;
    }

    /// @dev The size-dependent spread component is disabled; `sizeRatioBps`
    ///      is computed in `_sellLockMath` for off-chain analytics only.
    ///      The parameter is reserved; do not remove it from the interface.
    function _sellSpreadWithSize(
        uint256 spreadDurBps,
        uint256 /* sizeRatioBps */
    )
        internal
        pure
        returns (uint256)
    {
        if (spreadDurBps >= Constants.SELL_SPREAD_MAX_BPS) return Constants.SELL_SPREAD_MAX_BPS;
        return spreadDurBps;
    }

    /// @dev System spread = max(no-arb floor, convex curve in spot bonus).
    function _sellSystemSpreadBps(uint256 userSpotBonusBps_) internal pure returns (uint256) {
        // No-arb floor: ceil(BPS_DENOM * b / (BPS_DENOM + b)).
        uint256 noArb = Math.mulDiv(
            Constants.BPS_DENOM, userSpotBonusBps_, Constants.BPS_DENOM + userSpotBonusBps_, Math.Rounding.Ceil
        );

        // Normalized bonus in [0, 10_000].
        uint256 bBps = userSpotBonusBps_;
        if (Constants.MAX_USER_BONUS_BPS != 0) {
            bBps = Math.mulDiv(userSpotBonusBps_, Constants.BPS_DENOM, Constants.MAX_USER_BONUS_BPS);
            if (bBps > Constants.BPS_DENOM) bBps = Constants.BPS_DENOM;
        }

        uint256 span = (Constants.SELL_SPREAD_MAX_BPS >= Constants.SELL_SPREAD_MIN_BPS)
            ? Constants.SELL_SPREAD_MAX_BPS - Constants.SELL_SPREAD_MIN_BPS
            : 0;

        uint256 extra = 0;
        uint256 gamma = Constants.SELL_SPREAD_GAMMA;
        if (gamma == 1) {
            extra = Math.mulDiv(span, bBps, Constants.BPS_DENOM);
        } else if (gamma == 2) {
            // Nested mulDiv avoids intermediate overflow from bBps^2.
            extra = Math.mulDiv(Math.mulDiv(span, bBps, Constants.BPS_DENOM), bBps, Constants.BPS_DENOM);
        } else {
            revert Errors.InvariantViolation();
        }

        uint256 curve = Constants.SELL_SPREAD_MIN_BPS + extra;
        return noArb > curve ? noArb : curve;
    }

    /// @dev Duration factor (bps) based on remaining time. Piecewise-linear between breakpoints:
    ///      7d→500, 30d→1500, 90d→3500, 180d→6000, 365d→10000.
    function _sellDurationFactorBps(uint256 remainingSec) internal pure returns (uint256) {
        if (remainingSec <= Constants.MIN_LOCK_DURATION) return 500;
        if (remainingSec >= Constants.MAX_LOCK_DURATION) return Constants.BPS_DENOM;

        if (remainingSec <= 30 days) {
            return 500
                + Math.mulDiv(
                1_500 - 500, remainingSec - Constants.MIN_LOCK_DURATION, 30 days - Constants.MIN_LOCK_DURATION
            );
        }
        if (remainingSec <= 90 days) {
            return 1_500 + Math.mulDiv(3_500 - 1_500, remainingSec - 30 days, 90 days - 30 days);
        }
        if (remainingSec <= 180 days) {
            return 3_500 + Math.mulDiv(6_000 - 3_500, remainingSec - 90 days, 180 days - 90 days);
        }

        // remainingSec <= 365 days (handled above).
        return 6_000
            + Math.mulDiv(Constants.BPS_DENOM - 6_000, remainingSec - 180 days, Constants.MAX_LOCK_DURATION - 180 days);
    }

    /// @dev LP share of the sellback cut (bps), convex in spot bonus.
    function _lpSaleShareBps(uint256 userSpotBonusBps_) internal pure returns (uint256) {
        // Normalized bonus in [0, 10_000].
        uint256 bBps = userSpotBonusBps_;
        if (Constants.MAX_USER_BONUS_BPS != 0) {
            bBps = Math.mulDiv(userSpotBonusBps_, Constants.BPS_DENOM, Constants.MAX_USER_BONUS_BPS);
            if (bBps > Constants.BPS_DENOM) bBps = Constants.BPS_DENOM;
        }

        uint256 span = (Constants.LP_SALE_MAX_BPS >= Constants.LP_SALE_MIN_BPS)
            ? Constants.LP_SALE_MAX_BPS - Constants.LP_SALE_MIN_BPS
            : 0;

        uint256 extra = 0;
        uint256 gamma = Constants.LP_SALE_GAMMA;
        if (gamma == 1) {
            extra = Math.mulDiv(span, bBps, Constants.BPS_DENOM);
        } else if (gamma == 2) {
            // Nested mulDiv avoids intermediate overflow from bBps^2.
            extra = Math.mulDiv(Math.mulDiv(span, bBps, Constants.BPS_DENOM), bBps, Constants.BPS_DENOM);
        } else {
            revert Errors.InvariantViolation();
        }

        uint256 rate = Constants.LP_SALE_MIN_BPS + extra;
        if (rate < Constants.LP_SALE_MIN_BPS) return Constants.LP_SALE_MIN_BPS;
        if (rate > Constants.LP_SALE_MAX_BPS) return Constants.LP_SALE_MAX_BPS;
        return rate;
    }

    // Sell impact window helpers (decays to 0 over BONUS_DECAY_WINDOW)

    function _previewSellImpactVolumeAt(uint256 nowTs) internal view returns (uint256 vNow) {
        uint256 V = IFurnaceRead(furnace).sellImpactVolume();
        if (V == 0) return 0;

        uint256 last = IFurnaceRead(furnace).lastSellImpactUpdate();
        uint256 dt = (nowTs > last) ? (nowTs - last) : 0;
        if (dt >= Constants.BONUS_DECAY_WINDOW) return 0;

        uint256 remaining = Constants.BONUS_DECAY_WINDOW - dt;
        return Math.mulDiv(V, remaining, Constants.BONUS_DECAY_WINDOW);
    }

    function _kingRateAt(uint256 elapsed) internal pure returns (uint256 rate) {
        uint256 D = Constants.EMISSION_DECAY_PERIOD;
        uint256 R0 = Constants.KING_EMISSION_LAUNCH_RATE;
        uint256 RF = Constants.KING_EMISSION_FLOOR;
        if (R0 <= RF) return RF;
        if (elapsed >= D) return RF;

        uint256 diff = R0 - RF;
        uint256 dec = Math.mulDiv(diff, elapsed, D); // floor division
        rate = R0 - dec;
        if (rate < RF) rate = RF;
    }

    function _sellImpactBps(uint256 volAfter, uint256 elapsed) internal pure returns (uint256 impactBps) {
        // If disabled, skip.
        if (Constants.SELL_IMPACT_BPS_PER_STEP == 0 || Constants.SELL_IMPACT_MAX_BPS == 0) return 0;

        // Threshold scale: r(elapsed) * BONUS_DECAY_WINDOW as a proxy for mining emission scale.
        uint256 ratePerSec = _kingRateAt(elapsed);
        // Use mulDiv to prevent checked-overflow revert if future constant
        // changes raise KING_EMISSION_LAUNCH_RATE high enough to overflow.
        uint256 eWindow = Math.mulDiv(ratePerSec, Constants.BONUS_DECAY_WINDOW, 1);

        // Thresholds: free = 0.5 * E3h, step = 0.2 * E3h.
        uint256 freeVol = eWindow / 2;
        uint256 stepVol = eWindow / 5;

        // MIN_LOCK_AMOUNT can be zero in test configs; guard against division-by-zero.
        if (stepVol == 0) stepVol = (Constants.MIN_LOCK_AMOUNT > 0) ? Constants.MIN_LOCK_AMOUNT : 1;

        if (volAfter <= freeVol) return 0;

        uint256 excess = volAfter - freeVol;

        // Each step adds a fixed bps add-on. Cap steps to prevent overflow in the multiplication.
        uint256 maxSteps = Constants.SELL_IMPACT_MAX_BPS / Constants.SELL_IMPACT_BPS_PER_STEP + 1;
        // Floor division — seller must exceed a full stepVol above the boundary
        // to reach the next impact tier.
        // slither-disable-start divide-before-multiply
        uint256 steps = excess / stepVol;
        if (steps > maxSteps) steps = maxSteps;
        impactBps = steps * Constants.SELL_IMPACT_BPS_PER_STEP;
        // slither-disable-end divide-before-multiply

        if (impactBps > Constants.SELL_IMPACT_MAX_BPS) impactBps = Constants.SELL_IMPACT_MAX_BPS;
    }

    // Sellback spread floors

    /// @dev Linear principal-loss floor for an immediate buy→sell, scaled by remaining time.
    /// Uses a MIN_LOCK_DURATION clamp so near-expiry locks remain non-trivial.
    function _sellRoundTripLossBps(uint256 remainingSec) internal pure returns (uint256 lossBps) {
        uint256 d = remainingSec;

        if (d > Constants.MAX_LOCK_DURATION) d = Constants.MAX_LOCK_DURATION;
        if (d < Constants.MIN_LOCK_DURATION) d = Constants.MIN_LOCK_DURATION;

        // lossBps = LOSS_MAX * d / MAX_LOCK_DURATION (ceil to avoid undercutting the floor).
        lossBps =
            Math.mulDiv(Constants.SELL_ROUND_TRIP_LOSS_MAX_BPS, d, Constants.MAX_LOCK_DURATION, Math.Rounding.Ceil);
    }

    /// @dev Minimum sell spread (bps on lockAmount) required to guarantee the desired
    /// principal loss on an immediate buy→sell at the same remaining duration.
    function _sellRoundTripSpreadFloorBps(uint256 userSpotBonusBps_, uint256 remainingSec)
        internal
        pure
        returns (uint256 floorBps)
    {
        uint256 d = remainingSec;
        if (d > Constants.MAX_LOCK_DURATION) d = Constants.MAX_LOCK_DURATION;
        if (d < Constants.MIN_LOCK_DURATION) d = Constants.MIN_LOCK_DURATION;

        // Effective buy bonus bps at this remaining duration (uses entry duration weights).
        // `_durationWeight` returns the sub-bp curve value; pairing with `WEIGHT_DENOM` keeps the
        // effective bps result on the same scale as `userSpotBonusBps_`.
        uint256 buyWeight = _durationWeight(d);
        uint256 bBuyBps = Math.mulDiv(userSpotBonusBps_, buyWeight, Constants.WEIGHT_DENOM);

        uint256 lossBps = _sellRoundTripLossBps(d);

        // floor = ceil(BPS_DENOM * (b + loss) / (BPS_DENOM + b))
        floorBps =
            Math.mulDiv(Constants.BPS_DENOM, bBuyBps + lossBps, Constants.BPS_DENOM + bBuyBps, Math.Rounding.Ceil);

        if (floorBps > Constants.SELL_SPREAD_MAX_BPS) floorBps = Constants.SELL_SPREAD_MAX_BPS;
    }
}
