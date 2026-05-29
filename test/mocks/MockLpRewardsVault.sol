// SPDX-License-Identifier: MIT
pragma solidity ^0.8.34;

interface IFurnaceRootsView {
    function claim() external view returns (address);
    function ve() external view returns (address);
}

/// @notice Minimal LP rewards vault mock.
contract MockLpRewardsVault {
    /// @dev Mirrors LpStakingVault7D's public immutable getter so Furnace can validate wiring.
    address public furnace;

    address public claimOverride;
    bool public hasClaimOverride;

    address public veOverride;
    bool public hasVeOverride;

    bool public revertOnNotify;

    uint256 public notifyCalls;
    uint256 public lastNotifiedAmount;

    error NotifyReverted();

    function setFurnace(address _furnace) external {
        furnace = _furnace;
    }

    function setClaimOverride(address claim_) external {
        claimOverride = claim_;
        hasClaimOverride = true;
    }

    function clearClaimOverride() external {
        claimOverride = address(0);
        hasClaimOverride = false;
    }

    function setVeOverride(address ve_) external {
        veOverride = ve_;
        hasVeOverride = true;
    }

    function clearVeOverride() external {
        veOverride = address(0);
        hasVeOverride = false;
    }

    function claim() external view returns (address) {
        if (hasClaimOverride) return claimOverride;

        address f = furnace;
        if (f == address(0)) return address(0);
        return IFurnaceRootsView(f).claim();
    }

    function ve() external view returns (address) {
        if (hasVeOverride) return veOverride;

        address f = furnace;
        if (f == address(0)) return address(0);
        return IFurnaceRootsView(f).ve();
    }

    function setRevertOnNotify(bool _revertOnNotify) external {
        revertOnNotify = _revertOnNotify;
    }

    function notifyRewards(uint256 amountClaim) external {
        if (revertOnNotify) revert NotifyReverted();
        notifyCalls += 1;
        lastNotifiedAmount = amountClaim;
    }
}
