// SPDX-License-Identifier: MIT
pragma solidity ^0.8.34;

import {Test} from "forge-std/Test.sol";

import {DelegationActionTypes} from "src/lib/DelegationActionTypes.sol";
import {Events} from "src/lib/Events.sol";

/// @notice Pin delegation action type IDs against accidental drift.
/// @dev These numeric IDs are emitted in events and indexed by the subgraph
///      and Dune decoders.  They MUST be immutable once deployed.
///      See docs/analytics/dune-integration-pack-v1.0.0.md.
contract DelegationActionTypesGuardrailTest is Test {
    // MineCore
    function testTakeoverForIsPinned() public {
        assertEq(DelegationActionTypes.TAKEOVER_FOR, 1);
    }

    function testMineCoreSetReignRecipientsIsPinned() public {
        assertEq(DelegationActionTypes.MINECORE_SET_REIGN_RECIPIENTS, 2);
    }

    // ClaimAllHelper
    function testClaimShareholderForIsPinned() public {
        assertEq(DelegationActionTypes.CLAIM_SHAREHOLDER_FOR, 10);
    }

    function testWithdrawKingBucketForIsPinned() public {
        assertEq(DelegationActionTypes.WITHDRAW_KING_BUCKET_FOR, 11);
    }

    function testClaimAllForIsPinned() public {
        assertEq(DelegationActionTypes.CLAIM_ALL_FOR, 12);
    }

    // Furnace
    function testFurnaceEnterWithEthForIsPinned() public {
        assertEq(DelegationActionTypes.FURNACE_ENTER_WITH_ETH_FOR, 20);
    }

    function testFurnaceEnterWithClaimForIsPinned() public {
        assertEq(DelegationActionTypes.FURNACE_ENTER_WITH_CLAIM_FOR, 21);
    }

    function testFurnaceEnterWithTokenForIsPinned() public {
        assertEq(DelegationActionTypes.FURNACE_ENTER_WITH_TOKEN_FOR, 22);
    }

    // VeClaimNFT (lock maintenance)
    function testVeExtendLockForIsPinned() public {
        assertEq(DelegationActionTypes.VE_EXTEND_LOCK_FOR, 30);
    }

    function testVeMergeLocksForIsPinned() public {
        assertEq(DelegationActionTypes.VE_MERGE_LOCKS_FOR, 31);
    }

    function testVeUnlockExpiredForIsPinned() public {
        assertEq(DelegationActionTypes.VE_UNLOCK_EXPIRED_FOR, 32);
    }

    // Settings / config
    function testMineCoreSetKingAutoLockConfigForIsPinned() public {
        assertEq(DelegationActionTypes.MINECORE_SET_KING_AUTO_LOCK_CONFIG_FOR, 40);
    }

    function testShareholderSetAutoCompoundConfigForIsPinned() public {
        assertEq(DelegationActionTypes.SHAREHOLDER_SET_AUTOCOMPOUND_CONFIG_FOR, 41);
    }

    function testLpStakingSetAutoCompoundConfigForIsPinned() public {
        assertEq(DelegationActionTypes.LP_STAKING_SET_AUTOCOMPOUND_CONFIG_FOR, 42);
    }

    /// @notice Pin `Events.DelegationSessionUsed` topic0 against accidental reorder.
    /// @dev Event signature is
    ///      `DelegationSessionUsed(address,address,uint8,uint256,uint256,uint256)`.
    ///      Any change to field order, type, or indexed-ness re-derives topic0
    ///      and silently breaks every subgraph / Dune decoder. The hex constant
    ///      below MUST match both the canonical keccak of the signature string
    ///      AND the compile-time `Events.DelegationSessionUsed.selector`.
    function testDelegationSessionUsedTopic0Pinned() public {
        bytes32 pinned = 0x83ceff143ad4e2ae1ae6bf3b78fe2ce43d6807db4596779f3834741c795375af;
        bytes32 fromString = keccak256("DelegationSessionUsed(address,address,uint8,uint256,uint256,uint256)");
        bytes32 fromEvent = Events.DelegationSessionUsed.selector;
        assertEq(fromString, pinned, "DelegationSessionUsed canonical string drifted");
        assertEq(fromEvent, pinned, "Events.DelegationSessionUsed declaration drifted");
    }

    /// @notice All declared action-type IDs must be pairwise distinct.
    /// @dev Per-ID pin tests catch drift-by-change but do not surface duplicate
    ///      assignment with a clear failure message (e.g. editing two constants
    ///      to the same value). This test collects every declared id into a
    ///      local array and asserts each pair differs. Any new action-type added
    ///      to DelegationActionTypes.sol MUST also be added to this list so
    ///      future collisions stay detectable.
    function testActionTypeIdsArePairwiseDistinct() public {
        uint8[14] memory ids = [
            DelegationActionTypes.TAKEOVER_FOR,
            DelegationActionTypes.MINECORE_SET_REIGN_RECIPIENTS,
            DelegationActionTypes.CLAIM_SHAREHOLDER_FOR,
            DelegationActionTypes.WITHDRAW_KING_BUCKET_FOR,
            DelegationActionTypes.CLAIM_ALL_FOR,
            DelegationActionTypes.FURNACE_ENTER_WITH_ETH_FOR,
            DelegationActionTypes.FURNACE_ENTER_WITH_CLAIM_FOR,
            DelegationActionTypes.FURNACE_ENTER_WITH_TOKEN_FOR,
            DelegationActionTypes.VE_EXTEND_LOCK_FOR,
            DelegationActionTypes.VE_MERGE_LOCKS_FOR,
            DelegationActionTypes.VE_UNLOCK_EXPIRED_FOR,
            DelegationActionTypes.MINECORE_SET_KING_AUTO_LOCK_CONFIG_FOR,
            DelegationActionTypes.SHAREHOLDER_SET_AUTOCOMPOUND_CONFIG_FOR,
            DelegationActionTypes.LP_STAKING_SET_AUTOCOMPOUND_CONFIG_FOR
        ];
        for (uint256 i = 0; i < ids.length; i++) {
            for (uint256 j = i + 1; j < ids.length; j++) {
                assertTrue(
                    ids[i] != ids[j], "DelegationActionTypes ID collision: two constants share the same uint8 value"
                );
            }
        }
    }
}
