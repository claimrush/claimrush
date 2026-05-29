// SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IVeClaimNFT} from "./IVeClaimNFT.sol";

// Intentionally omitted from this interface (present in ABI only):
//
//   Admin/owner setters:
//     acceptOwnership, renounceOwnership, transferOwnership
//
//   Public state variable getters (Solidity auto-generated):
//     aerodromeRouter, aerodromeFactory, lpToken, weth, wethClaimStable,
//     accountedRewardBalance, isHarvestKeeper, lastFeeHarvestTs, nextUnbondId,
//     queuedRewards, rewardPerTokenStored, rewards, userRewardPerTokenPaid,
//     totalClaimRewardsClaimed, totalClaimRewardsFundedFromFurnace,
//     totalClaimRewardsFundedFromVaultFees, totalClaimRewardsLockedViaFurnace,
//     owner, pendingOwner
//
//   Public constants:
//     BPS_DENOM, MIN_COMPOUND_INTERVAL
//

/// @notice Minimal external call surface for LpStakingVault7D.
/// @dev Used by:
/// - Furnace (reward notifications)
/// - external integrations/tests that need the owner-or-keeper-gated fee-harvest entrypoint
interface ILpStakingVault7D {
    /// @notice The Furnace address wired into the vault.
    /// @dev LpStakingVault7D exposes this as a public immutable.
    function furnace() external view returns (address);

    /// @notice The CLAIM token address wired into the vault.
    function claim() external view returns (IERC20);

    /// @notice The veCLAIM NFT address wired into the vault.
    function ve() external view returns (IVeClaimNFT);

    function notifyRewards(uint256 amountClaim) external;

    /// @notice Owner-or-keeper-allowlisted harvest of LP fees into the rewards stream.
    function harvestFeesToRewards(uint256 deadline, uint256 minClaimOut) external;

    function previewHarvestFeesToRewards()
        external
        view
        returns (uint256 feeWeth, uint256 feeClaim, uint256 expectedClaimOut);

    /// @notice Stake LP tokens for veCLAIM-aligned reward accrual.
    function stake(uint256 amount) external;

    /// @notice Begin a 7-day unbonding period for `amount` of staked LP.
    function beginUnbond(uint256 amount) external;

    /// @notice Withdraw any matured (post-7-day) unbonding tickets.
    function withdrawMatured() external;

    function claimRewards() external;

    function claimRewardsAndLock(uint256 targetTokenId, uint256 durationSeconds, bool createAutoMax, uint256 minVeOut)
        external;

    function earned(address user) external view returns (uint256);

    function stakedBalance(address user) external view returns (uint256);

    function totalStaked() external view returns (uint256);

    function getUnbondCount(address user) external view returns (uint256);

    function getUnbondByIndex(address user, uint256 index)
        external
        view
        returns (uint256 unbondId, uint256 amount, uint256 unlockTime);

    function minCompoundReward() external view returns (uint256);

    function setMinCompoundReward(uint256 floor) external;

    function setAutoCompoundConfig(
        bool enabled,
        uint256 tokenId,
        uint256 durationSeconds,
        uint32 maxSlippageBps,
        uint256 minRewardToCompound
    ) external;

    function setAutoCompoundConfigForUser(
        address user,
        bool enabled,
        uint256 tokenId,
        uint256 durationSeconds,
        uint32 maxSlippageBps,
        uint256 minRewardToCompound
    ) external;

    function getAutoCompoundConfig(address user)
        external
        view
        returns (
            bool enabled,
            bool paused,
            uint256 tokenId,
            uint256 durationSeconds,
            uint32 maxSlippageBps,
            uint256 minRewardToCompound
        );

    function compoundFor(address user) external;

    function compoundForMany(address[] calldata users, uint256 maxUsers) external;

    function setHarvestKeeper(address keeper, bool allowed) external;

    function minHarvestClaimFloor() external view returns (uint256);

    function setMinHarvestClaimFloor(uint256 floor) external;
}
