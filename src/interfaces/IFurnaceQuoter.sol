// SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

import {IEntryTokenRegistry} from "./IEntryTokenRegistry.sol";

/// @notice View-only quoting helper for Furnace.
/// @dev This contract is deployed once and wired into Furnace via `setFurnaceQuoter`.
///      Quotes and heavy view API live here at `Furnace.furnaceQuoter()` to
///      reduce Furnace runtime bytecode size.
interface IFurnaceQuoter {
    /// @notice The Furnace this quoter is bound to.
    function furnace() external view returns (address);

    // ------------------------------------------------------------
    // Entry quotes (used by MarketRouter, UI, vault autocompound)
    // ------------------------------------------------------------

    function quoteEnterWithEth(
        address user,
        uint256 ethIn,
        uint256 targetTokenId,
        uint256 durationSeconds,
        bool createAutoMax
    ) external view returns (uint256 principalClaim, uint256 bonusClaim, uint256 veOut, uint256 routeTokenId);

    function quoteEnterWithClaim(
        address user,
        uint256 claimIn,
        uint256 targetTokenId,
        uint256 durationSeconds,
        bool createAutoMax
    ) external view returns (uint256 principalClaim, uint256 bonusClaim, uint256 veOut, uint256 routeTokenId);

    function quoteEnterWithToken(
        address user,
        address tokenIn,
        uint256 amountIn,
        uint256 targetTokenId,
        uint256 durationSeconds,
        bool createAutoMax
    ) external view returns (uint256 principalClaim, uint256 bonusClaim, uint256 veOut, uint256 routeTokenId);

    // Extension bonus quotes
    function quoteExtendWithBonus(address user, uint256 tokenId, uint256 durationSeconds)
        external
        view
        returns (uint256 lockAmount, uint256 bonusClaim, uint256 newEndSec);

    function quoteAutoMaxBonus(uint256 tokenId) external view returns (uint256 lockAmount, uint256 bonusClaim);

    function quoteAutoMaxBonusBatch(uint256[] calldata tokenIds)
        external
        view
        returns (uint256[] memory bonuses, uint256 totalBonus);

    /// @notice Batch-check which AutoMax locks are eligible for bonus claiming
    ///         (either never claimed, or at least 24h since `max(lastClaim, lockStart)`).
    /// @param tokenIds Lock token IDs to check.
    /// @return eligible Per-element boolean: true if the lock is a valid autoMax lock with elapsed cooldown.
    function filterAutoMaxBonusEligible(uint256[] calldata tokenIds) external view returns (bool[] memory eligible);

    /// @notice Batch-read `lastAutoMaxBonusClaim` for many tokens in a single eth_call.
    /// @dev Replaces N RPC reads with one for the keeper's first-touch / cooldown bookkeeping.
    ///      Returns the raw timestamp without filtering — `0` indicates first-touch (never claimed).
    /// @param tokenIds Lock token IDs to read. Order is preserved in the output.
    /// @return lastClaims Per-element last-claim unix-seconds timestamp (0 == first-touch).
    function lastAutoMaxBonusClaimBatch(uint256[] calldata tokenIds) external view returns (uint256[] memory lastClaims);

    // ------------------------------------------------------------
    // Lightweight helper for token routing (mirrors Furnace behavior)
    // ------------------------------------------------------------

    function resolveFurnaceRoute(address tokenIn)
        external
        view
        returns (IEntryTokenRegistry.RegistryRoute[] memory route, uint256 routeTokenId);

    // ------------------------------------------------------------
    // Sellback quotes (lock → liquid CLAIM)
    // ------------------------------------------------------------

    struct SellLockQuoteBreakdown {
        uint256 lockAmount;
        uint256 remainingSec;
        uint256 lockedSupplyExcl;
        uint256 reserveBefore;
        uint256 elapsed;

        // UI-facing bonus decomposition:
        // - spotBonusBps: spot bonus including reserve factor
        // - baseBonusBps: base bonus (lock-% anchored, no reserve factor)
        // - bonusRefBpsUsed: sell-side bonus reference = max(spot, base)
        uint256 spotBonusBps;
        uint256 baseBonusBps;
        uint256 bonusRefBpsUsed;
        // Same value as bonusRefBpsUsed; duplicate field name for stable ABI/decoding in analytics.
        uint256 bonusBpsUsed;
        uint256 spreadSystemBps;
        uint256 durFactorBps;
        uint256 spreadDurBps;
        uint256 sizeRatioBps;

        uint256 spreadBps;
        uint256 claimOut;
        uint256 lpReward;
        uint256 reserveAdd;

        // UI convenience: true iff the sell bonus clamp is binding (spot < base).
        bool isBonusClampBinding;
    }

    function quoteSellLockToFurnaceBreakdown(address user, uint256 tokenId)
        external
        view
        returns (SellLockQuoteBreakdown memory q);

    function quoteSellLockToFurnace(address user, uint256 tokenId)
        external
        view
        returns (uint256 lockAmount, uint256 claimOut, uint256 spreadBps, uint256 lpReward, uint256 reserveAdd);

    function quoteSellLockToFurnaceFromInfo(uint256 lockAmount, uint256 lockEnd, bool autoMax)
        external
        view
        returns (uint256 claimOut, uint256 spreadBps, uint256 lpReward, uint256 reserveAdd);

    /// @notice Full sell quote for execution in Furnace (lockAmount, lockEnd, autoMax).
    /// @dev Core sell quote fields used by `normalizeSellExecutionQuote` / execution.
    struct SellExecutionQuote {
        uint256 claimOut;
        uint256 spreadBps;
        uint256 lpReward;
        uint256 reserveAdd;
        uint256 bonusBpsUsed;
        uint256 lpSaleShareBps;
        uint256 reserveBefore;
    }

    function quoteSellLockForExecution(uint256 lockAmount, uint256 lockEnd, bool autoMax)
        external
        view
        returns (SellExecutionQuote memory);

    // ------------------------------------------------------------
    // Bonus math (used by Furnace at runtime to keep Furnace under EIP-170)
    // ------------------------------------------------------------

    function userSpotBonusBps(uint256 lockedSupply, uint256 totalSupply, uint256 reserve, uint256 elapsed)
        external
        view
        returns (uint256);

    function lpScaleBps(uint256 lockedSupply, uint256 totalSupply, uint256 reserve, uint256 elapsed)
        external
        view
        returns (uint256);

    function grossSpotBonusBps(uint256 userSpotBonusBps, uint256 lpTopupRateBps) external view returns (uint256);

    function baseUserBps(uint256 lockedSupply, uint256 totalSupply) external view returns (uint256);

    function reserveFullnessBps(uint256 reserve) external view returns (uint256);
    function swingAlphaBps(uint256 elapsed) external view returns (uint256);
    function reserveFactorBps(uint256 reserveFullnessBps, uint256 swingAlphaBps) external view returns (uint256);

    /// @notice Sell impact / round-trip helpers (for tests and harness).
    function sellRoundTripLossBps(uint256 remainingSec) external pure returns (uint256);
    function sellRoundTripSpreadFloorBps(uint256 userSpotBonusBps, uint256 remainingSec) external pure returns (uint256);
    function previewSellImpactVolumeAt(uint256 nowTs) external view returns (uint256);
    function sellImpactBps(uint256 volAfter, uint256 elapsed) external pure returns (uint256);
    function lpSaleShareBps(uint256 userSpotBonusBps) external pure returns (uint256);
    function computeLpTopupRateBps(uint256 userSpotBonusBps) external view returns (uint256);
    function durationWeightBps(uint256 durationSeconds) external pure returns (uint256);
    function clampDurationSeconds(uint256 durationSeconds) external pure returns (uint256);
    function previewVirtualDepthWithReserve(uint256 reserve, uint256 grossSpotBonusBps_) external view returns (uint256);

    // ------------------------------------------------------------
    // Core Furnace state lens (UI + analytics)
    // ------------------------------------------------------------

    function getFurnaceState()
        external
        view
        returns (
            uint256 reserve,
            uint256 lockedSupply,
            uint256 userSpotBonusBps,
            uint256 lpTopupRateBps,
            uint256 quoteUserBonusBps,
            uint256 quoteLpTopupBps,
            uint256 virtualDepth,
            uint256 lastUpdate
        );
}
