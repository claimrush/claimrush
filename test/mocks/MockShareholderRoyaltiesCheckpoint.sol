// SPDX-License-Identifier: MIT
pragma solidity ^0.8.34;

/// @dev Minimal mock for Furnace tests that only need `checkpointUser` + wiring getters.
contract MockShareholderRoyaltiesCheckpoint {
    event Checkpointed(address indexed user);

    address public furnace;
    address public ve;
    address public mineCore;
    address public mineMarket;

    function setWiring(address _mineCore, address _mineMarket, address _furnace, address _ve) external {
        mineCore = _mineCore;
        mineMarket = _mineMarket;
        furnace = _furnace;
        ve = _ve;
    }

    function checkpointUser(address user) external {
        emit Checkpointed(user);
    }
}
