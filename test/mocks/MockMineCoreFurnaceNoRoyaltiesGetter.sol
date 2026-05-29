// SPDX-License-Identifier: MIT
pragma solidity ^0.8.34;

/// @dev Minimal Furnace-like surface used to prove MineCore must not accept a foreign contract
///      that self-reports MineCore / CLAIM / ve roots but omits `shareholderRoyalties()` entirely.
contract MockMineCoreFurnaceNoRoyaltiesGetter {
    address public claim;
    address public ve;
    address public mineCore;
    address public delegationHub;

    constructor(address claim_, address ve_, address mineCore_, address delegationHub_) {
        claim = claim_;
        ve = ve_;
        mineCore = mineCore_;
        delegationHub = delegationHub_;
    }

    function setDelegationHub(address hub_) external {
        delegationHub = hub_;
    }

    function creditReserve(uint256) external {}
}
