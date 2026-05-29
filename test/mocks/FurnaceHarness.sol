// SPDX-License-Identifier: MIT
pragma solidity ^0.8.34;

import {Furnace} from "src/Furnace.sol";
import {FurnaceGuardHelper} from "src/FurnaceGuardHelper.sol";
import {IFurnaceQuoter} from "src/interfaces/IFurnaceQuoter.sol";

/// @notice Test harness for accessing Furnace internals.
/// @dev Exposes helper views so invariants can compute expected values without
/// duplicating private logic. Bonus math is delegated to furnaceQuoter.
contract FurnaceHarness is Furnace {
    constructor(address claim_, address ve_, address initialOwner)
        Furnace(claim_, ve_, address(new FurnaceGuardHelper(claim_, ve_)), initialOwner)
    {}

    // ------------------------------------------------------------
    // Bonus math helpers (delegate to FurnaceQuoter)
    // ------------------------------------------------------------

    function exposedBaseUserBps(uint256 lockedSupply, uint256 totalSupply) external view returns (uint256) {
        return IFurnaceQuoter(furnaceQuoter).baseUserBps(lockedSupply, totalSupply);
    }

    function exposedReserveFullnessBps(uint256 reserve) external view returns (uint256) {
        return IFurnaceQuoter(furnaceQuoter).reserveFullnessBps(reserve);
    }

    function exposedSwingAlphaBps(uint256 elapsed) external view returns (uint256) {
        return IFurnaceQuoter(furnaceQuoter).swingAlphaBps(elapsed);
    }

    function exposedReserveFactorBps(uint256 reserveFullnessBps, uint256 swingAlphaBps)
        external
        view
        returns (uint256)
    {
        return IFurnaceQuoter(furnaceQuoter).reserveFactorBps(reserveFullnessBps, swingAlphaBps);
    }

    function exposedUserSpotBonusBps(uint256 lockedSupply, uint256 totalSupply, uint256 reserve, uint256 elapsed)
        external
        view
        returns (uint256)
    {
        return IFurnaceQuoter(furnaceQuoter).userSpotBonusBps(lockedSupply, totalSupply, reserve, elapsed);
    }

    function exposedLpScaleBps(uint256 lockedSupply, uint256 totalSupply, uint256 reserve, uint256 elapsed)
        external
        view
        returns (uint256)
    {
        return IFurnaceQuoter(furnaceQuoter).lpScaleBps(lockedSupply, totalSupply, reserve, elapsed);
    }

    function exposedLpTopupRateBps(uint256 userSpotBonusBps) external view returns (uint256) {
        return IFurnaceQuoter(furnaceQuoter).computeLpTopupRateBps(userSpotBonusBps);
    }

    function exposedLpSaleShareBps(uint256 userSpotBonusBps) external view returns (uint256) {
        return IFurnaceQuoter(furnaceQuoter).lpSaleShareBps(userSpotBonusBps);
    }

    function exposedGrossSpotBonusBps(uint256 userSpotBonusBps, uint256 lpTopupRateBps)
        external
        view
        returns (uint256)
    {
        return IFurnaceQuoter(furnaceQuoter).grossSpotBonusBps(userSpotBonusBps, lpTopupRateBps);
    }

    // ------------------------------------------------------------
    // AMM internals (virtual depth + payout)
    // ------------------------------------------------------------

    /// @notice Virtual depth preview using the current reserve and a given gross cap in bps.
    function exposedPreviewVirtualDepth(uint256 grossSpotBonusBps) external view returns (uint256) {
        return IFurnaceQuoter(furnaceQuoter).previewVirtualDepthWithReserve(furnaceReserve, grossSpotBonusBps);
    }

    /// @notice Updates the stored virtual depth using the given gross cap in bps.
    /// @dev Now a view since _updateVirtualDepth was moved out; returns the preview value.
    function exposedUpdateVirtualDepth(uint256 grossSpotBonusBps) external view returns (uint256) {
        return IFurnaceQuoter(furnaceQuoter).previewVirtualDepthWithReserve(furnaceReserve, grossSpotBonusBps);
    }

    /// @notice Applies the bonus AMM for a principal amount and returns (grossBonus, userBonus, lpBonus).
    function exposedApplyBonusAmm(uint256 principalClaim)
        external
        returns (uint256 grossBonus, uint256 userBonus, uint256 lpBonus)
    {
        return _applyBonusAmm(address(0), principalClaim, principalClaim, 0);
    }

    // ------------------------------------------------------------
    // Drip helpers
    // ------------------------------------------------------------

    function exposedDripAlphaBps(uint256 elapsed) external view returns (uint256) {
        return FurnaceGuardHelper(_guardHelper).dripAlphaBps(elapsed);
    }

    function exposedCapInflowPerDayFromInflow(uint256 inflowPerDay) external view returns (uint256) {
        return FurnaceGuardHelper(_guardHelper).capInflowPerDayFromInflow(inflowPerDay);
    }

    function exposedGateBpsFromReserve(uint256 reserve) external view returns (uint256) {
        return FurnaceGuardHelper(_guardHelper).gateBpsFromReserve(reserve);
    }

    function exposedLpOverflowDripPerDay(uint256, uint256, uint256) external view returns (uint256) {
        return FurnaceGuardHelper(_guardHelper).getLpOverflowDripPerDay(mineCore, deploymentTime, furnaceReserve);
    }

    function exposedFurnaceInflowPerDayAt(uint256 timestamp) external view returns (uint256) {
        return FurnaceGuardHelper(_guardHelper).furnaceInflowPerDayAt(mineCore, timestamp);
    }

    function exposedCapInflowPerDayAt(uint256 timestamp) external view returns (uint256) {
        return FurnaceGuardHelper(_guardHelper)
            .capInflowPerDayFromInflow(FurnaceGuardHelper(_guardHelper).furnaceInflowPerDayAt(mineCore, timestamp));
    }

    // ------------------------------------------------------------
    // LP stream helpers (tests)
    // ------------------------------------------------------------

    function exposedAccrueLpStream() external returns (uint256) {
        return _accrueLpStream();
    }

    function exposedFundLpStream(uint256 amount) external {
        _fundLpStreamInternal(amount, true);
    }

    function exposedLpStreamCarry() external view returns (uint256) {
        return lpStreamCarry;
    }

    function exposedLpStreamLiability() external view returns (uint256) {
        return FurnaceGuardHelper(_guardHelper)
            .lpStreamLiability(lpStreamCarry, lpStreamPeriodFinish, lpStreamRatePerSec, lpStreamLastUpdate);
    }

    function exposedPendingLpOverflowDripLiability() external view returns (uint256) {
        if (lpRewardsVault == address(0)) return 0;
        return FurnaceGuardHelper(_guardHelper)
            .pendingLpOverflowDripLiability(mineCore, deploymentTime, furnaceReserve, lastLpOverflowDripUpdate);
    }

    function exposedLpRewardsVaultLiability() external view returns (uint256) {
        return _lpRewardsVaultLiability();
    }

    function setLpRewardsVaultForTest(address vault) external {
        lpRewardsVault = vault;
    }

    function exposedSyncFurnaceReserve() external {
        _syncFurnaceReserve();
    }

    // ------------------------------------------------------------
    // Test helpers (sell impact + round-trip floors)
    // ------------------------------------------------------------

    function exposedSellRoundTripLossBps(uint256 remainingSec) external view returns (uint256) {
        return IFurnaceQuoter(furnaceQuoter).sellRoundTripLossBps(remainingSec);
    }

    function exposedSellRoundTripSpreadFloorBps(uint256 userSpotBonusBps, uint256 remainingSec)
        external
        view
        returns (uint256)
    {
        return IFurnaceQuoter(furnaceQuoter).sellRoundTripSpreadFloorBps(userSpotBonusBps, remainingSec);
    }

    function exposedPreviewSellImpactVolumeAt(uint256 nowTs) external view returns (uint256) {
        return IFurnaceQuoter(furnaceQuoter).previewSellImpactVolumeAt(nowTs);
    }

    function exposedSellImpactBps(uint256 volAfter, uint256 elapsed) external view returns (uint256) {
        return IFurnaceQuoter(furnaceQuoter).sellImpactBps(volAfter, elapsed);
    }

    function exposedAccrueSellImpactVolume(uint256 addAmount) external returns (uint256 volAfter) {
        return _accrueSellImpactVolume(addAmount);
    }

    // ------------------------------------------------------------
    // Duration weight helpers (bonus curve tests)
    // ------------------------------------------------------------

    function exposedDurationWeightBps(uint256 durationSeconds) external view returns (uint256) {
        return IFurnaceQuoter(furnaceQuoter).durationWeightBps(durationSeconds);
    }

    function exposedClampDurationSeconds(uint256 durationSeconds) external view returns (uint256) {
        return IFurnaceQuoter(furnaceQuoter).clampDurationSeconds(durationSeconds);
    }

    // ------------------------------------------------------------
    // Internal state getters (for tests after Tier-2 internalization)
    // ------------------------------------------------------------

    function exposedBonusVirtualDepth() external view returns (uint256) {
        return bonusVirtualDepth;
    }

    function exposedLastBonusUpdate() external view returns (uint256) {
        return lastBonusUpdate;
    }

    function exposedSellImpactVolume() external view returns (uint256) {
        return sellImpactVolume;
    }

    function exposedLastSellImpactUpdate() external view returns (uint256) {
        return lastSellImpactUpdate;
    }

    function exposedLastLpOverflowDripUpdate() external view returns (uint256) {
        return lastLpOverflowDripUpdate;
    }

    function exposedLpStreamRatePerSec() external view returns (uint256) {
        return lpStreamRatePerSec;
    }

    function exposedLpStreamPeriodFinish() external view returns (uint256) {
        return lpStreamPeriodFinish;
    }

    function exposedLpStreamLastUpdate() external view returns (uint256) {
        return lpStreamLastUpdate;
    }

    function exposedLpSaleFundedDay() external view returns (uint256) {
        return lpSaleFundedDay;
    }

    function exposedLpSaleFundedToday() external view returns (uint256) {
        return lpSaleFundedToday;
    }

    function exposedLastAutoMaxBonusClaim(uint256 tokenId) external view returns (uint256) {
        return lastAutoMaxBonusClaim[tokenId];
    }

    // ------------------------------------------------------------
    // Guard helper coverage helpers
    // ------------------------------------------------------------

    function exposedGuardHelper() external view returns (address payable) {
        return _guardHelper;
    }

    /// @dev Delegatecall emitLockSoldToFurnace with dummy values.
    ///      Used to prove event-emission delegatecalls do not mutate Furnace storage.
    function exposedDelegatecallEmitLockSoldToFurnace() external {
        (bool ok,) = _guardHelper.delegatecall(
            abi.encodeCall(
                FurnaceGuardHelper.emitLockSoldToFurnace,
                (address(0xBEEF), 42, 1000e18, 900e18, 1000, 100e18, 500, 50e18, 50e18, 250)
            )
        );
        require(ok, "delegatecall failed");
    }
}
