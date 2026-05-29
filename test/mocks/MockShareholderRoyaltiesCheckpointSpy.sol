// SPDX-License-Identifier: MIT
pragma solidity ^0.8.34;

interface IVeLockInfoView {
    function getLockInfo(uint256 tokenId)
        external
        view
        returns (uint256 amount, uint256 lockEnd, bool autoMax, bool listed);
}

/// @dev Records checkpoint timing/ordering for VeClaimNFT tests.
contract MockShareholderRoyaltiesCheckpointSpy {
    address public immutable ve;
    uint256 public tokenIdToInspect;
    uint256 public checkpointCalls;
    uint256 public firstObservedLockEnd;
    uint256 public lastObservedLockEnd;

    constructor(address ve_) {
        ve = ve_;
    }

    function setTokenIdToInspect(uint256 tokenId) external {
        tokenIdToInspect = tokenId;
    }

    function reset() external {
        checkpointCalls = 0;
        firstObservedLockEnd = 0;
        lastObservedLockEnd = 0;
    }

    function checkpointUser(address) external {
        _record();
    }

    function checkpointTransfer(address, address) external {
        _record();
    }

    function _record() internal {
        checkpointCalls += 1;

        if (tokenIdToInspect != 0) {
            (, uint256 lockEnd,,) = IVeLockInfoView(ve).getLockInfo(tokenIdToInspect);
            if (checkpointCalls == 1) {
                firstObservedLockEnd = lockEnd;
            }
            lastObservedLockEnd = lockEnd;
        }
    }
}
