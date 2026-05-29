// SPDX-License-Identifier: MIT
pragma solidity ^0.8.34;

/// @dev Minimal MineCore-like reciprocal wiring view used by market settlement tests.
contract MockMineCoreWiringView {
    address public claim;
    address public ve;
    address public royalties;
    address public furnace;
    address public entryTokenRegistry;
    uint256 public emissionStartTime;
    uint256 public furnaceEmissionRateAtTimestamp;
    uint256 public GENESIS_ACCRUAL_DURATION = 7 days;

    constructor(address _claim, address _ve, address _royalties) {
        claim = _claim;
        ve = _ve;
        royalties = _royalties;
        emissionStartTime = 1;
    }

    function setFurnace(address _furnace) external {
        furnace = _furnace;
    }

    function setEmissionSchedule(uint256 _startTime, uint256 _ratePerSecond) external {
        emissionStartTime = _startTime;
        furnaceEmissionRateAtTimestamp = _ratePerSecond;
    }

    function getFurnaceEmissionRateAt(uint256) external view returns (uint256) {
        return furnaceEmissionRateAtTimestamp;
    }
}
