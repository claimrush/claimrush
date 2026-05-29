// SPDX-License-Identifier: MIT
pragma solidity ^0.8.34;

import {ShareholderRoyalties} from "src/ShareholderRoyalties.sol";

/// @dev Test harness that exposes internal checkpoint helpers for direct unit testing.
contract ShareholderRoyaltiesHarness is ShareholderRoyalties {
    constructor(address _ve, address initialOwner) ShareholderRoyalties(_ve, initialOwner) {}

    /// @dev Bulk-load a checkpoint into the array (bypasses normal flush flow).
    function pushCheckpoint(uint40 ts, uint256 cumEthPerVe, uint256 cumTw) external {
        rewardCheckpoints.push(
            RewardCheckpoint({timestamp: ts, cumulativeEthPerVe: cumEthPerVe, cumulativeTimeWeightedEthPerVe: cumTw})
        );
    }

    /// @dev Force the array length via assembly so tests can simulate a full
    ///      array without 50k SSTORE iterations.
    function forceSetArrayLength(uint256 newLen) external {
        assembly {
            sstore(rewardCheckpoints.slot, newLen)
        }
    }

    /// @dev Write a single checkpoint at `index` using assembly. Caller must
    ///      ensure `index < rewardCheckpoints.length`.
    function setCheckpointAt(uint256 index, uint40 ts, uint256 cumEthPerVe, uint256 cumTw) external {
        bytes32 base;
        assembly {
            mstore(0x00, rewardCheckpoints.slot)
            base := keccak256(0x00, 0x20)
        }
        uint256 slotBase = uint256(base) + index * 3;
        assembly {
            sstore(slotBase, ts)
            sstore(add(slotBase, 1), cumEthPerVe)
            sstore(add(slotBase, 2), cumTw)
        }
    }

    function rewardCheckpointsLength() external view returns (uint256) {
        return rewardCheckpoints.length;
    }

    function getRewardCheckpoint(uint256 i) external view returns (uint40 ts, uint256 cumEthPerVe, uint256 cumTw) {
        RewardCheckpoint storage cp = rewardCheckpoints[i];
        return (cp.timestamp, cp.cumulativeEthPerVe, cp.cumulativeTimeWeightedEthPerVe);
    }

    function getOverflowCheckpoint(uint256 i) external view returns (uint40 ts, uint256 cumEthPerVe, uint256 cumTw) {
        RewardCheckpoint storage ov = _overflowCheckpoints[i];
        return (ov.timestamp, ov.cumulativeEthPerVe, ov.cumulativeTimeWeightedEthPerVe);
    }

    function overflowCheckpointsLength() external view returns (uint256) {
        return _overflowCheckpoints.length;
    }

    function exposed_getRewardPrefixBefore(uint256 ts) external view returns (uint256 idx, uint256 timeWeightedIdx) {
        return _getRewardPrefixBefore(ts);
    }

    function exposed_latestRewardTimestamp() external view returns (uint40) {
        return _latestRewardTimestamp();
    }

    function exposed_ethPerVeTimeWeighted() external view returns (uint256) {
        return ethPerVeTimeWeighted;
    }

    function indexedEthOwedForTest() external view returns (uint256) {
        return indexedEthOwed;
    }

    function totalCrystallisedStoredForTest() external view returns (uint256) {
        return totalCrystallisedStored;
    }

    function exposed_canStoreRewardCheckpoint(uint40 rewardTs) external view returns (bool) {
        return _canStoreRewardCheckpoint(rewardTs);
    }

    function exposed_storeRewardCheckpoint(uint40 rewardTs) external {
        _storeRewardCheckpoint(rewardTs);
    }

    /// @dev Force the overflow array length via assembly.
    function forceSetOverflowArrayLength(uint256 newLen) external {
        assembly {
            sstore(_overflowCheckpoints.slot, newLen)
        }
    }

    /// @dev Write a single overflow checkpoint at `index` using assembly.
    function setOverflowCheckpointAt(uint256 index, uint40 ts, uint256 cumEthPerVe, uint256 cumTw) external {
        bytes32 base;
        assembly {
            mstore(0x00, _overflowCheckpoints.slot)
            base := keccak256(0x00, 0x20)
        }
        uint256 slotBase = uint256(base) + index * 3;
        assembly {
            sstore(slotBase, ts)
            sstore(add(slotBase, 1), cumEthPerVe)
            sstore(add(slotBase, 2), cumTw)
        }
    }

    function getOverflowRingHead() external view returns (uint256) {
        return _overflowRingHead;
    }

    function setOverflowRingHead(uint256 head) external {
        _overflowRingHead = head;
    }

    /// @dev Allow tests to set ethPerVe/ethPerVeTimeWeighted directly.
    function setEthPerVe(uint256 v) external {
        ethPerVe = v;
    }

    function setEthPerVeTimeWeighted(uint256 v) external {
        ethPerVeTimeWeighted = v;
    }

    /// @dev Allow tests that bypass the natural takeover/flush flow to seed the
    ///      `indexedEthOwed` accumulator so the per-checkpoint clamp doesn't
    ///      clip the manually-engineered accrual to zero.
    function setIndexedEthOwed(uint256 v) external {
        indexedEthOwed = v;
    }

    /// @dev Fund the harness and invoke the internal ETH-push path. Lets tests drive
    ///      `_callWithValueNoReturndata` directly without going through a full claim flow.
    function exposed_callWithValueNoReturndata(address to, uint256 value) external returns (bool) {
        return _callWithValueNoReturndata(to, value);
    }
}
