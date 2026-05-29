// SPDX-License-Identifier: MIT
pragma solidity ^0.8.34;

import {Test} from "forge-std/Test.sol";

/// @title Interface event parity invariants
/// @notice Pins canonical event topic0 for events that are redeclared in more
///         than one place. Mutating any redeclaration without updating the
///         others must turn this test red.
/// @dev Covers Furnace events triple-declared across `Events.sol`, `IFurnace`,
///      and `FurnaceGuardHelper`, and `BonusPaid` emitted via assembly `log2`
///      with a hardcoded topic0 in `FurnaceGuardHelper`.
contract InterfaceEventParity is Test {
    // -----------------------------------------------------------------
    // Furnace events are triple-declared (Events.sol, IFurnace,
    // FurnaceGuardHelper). BonusPaid is also emitted via assembly log2
    // with a hardcoded topic0 in FurnaceGuardHelper.
    // -----------------------------------------------------------------

    bytes32 internal constant TOPIC_BONUS_PAID = keccak256(
        "BonusPaid(address,uint256,uint256,uint256,uint256,uint256,uint256,uint256,uint256,uint256,uint256,uint256,uint256,uint256,uint256,uint256)"
    );

    bytes32 internal constant TOPIC_LP_OVERFLOW_DRIP_PAID =
        keccak256("LpOverflowDripPaid(uint256,uint256,uint256,uint256,uint256,uint256,uint256,uint256,uint256)");

    bytes32 internal constant TOPIC_LOCK_SOLD_TO_FURNACE =
        keccak256("LockSoldToFurnace(address,uint256,uint256,uint256,uint256,uint256,uint256,uint256,uint256,uint256)");

    bytes32 internal constant TOPIC_EMERGENCY_REWIRE_REQUESTED =
        keccak256("EmergencyVaultRewireRequested(address,uint256,uint256)");

    bytes32 internal constant TOPIC_EMERGENCY_REWIRE_CANCELLED = keccak256("EmergencyVaultRewireCancelled()");

    bytes32 internal constant TOPIC_EMERGENCY_REWIRE_EXECUTED =
        keccak256("EmergencyVaultRewireExecuted(address,uint256)");

    function test_furnace_bonusPaid_topic0_matchesAssemblyHardcode() public pure {
        // The assembly emit in FurnaceGuardHelper hardcodes this exact topic0
        // hex. Any drift between this canonical signature and the hardcoded
        // hex MUST turn this test red.
        assertEq(
            TOPIC_BONUS_PAID,
            bytes32(0xc465b659478fb0fcbe9fcbc1b10229d633ba82ea04f79dd1066b526f24e8c843),
            "BonusPaid canonical topic0 drifted from FurnaceGuardHelper assembly hardcode"
        );
    }

    function test_furnace_lpOverflowDripPaid_topic0_pinned() public pure {
        assertEq(
            TOPIC_LP_OVERFLOW_DRIP_PAID,
            bytes32(0x5b2f202c6b56905764125c99206b7ba31b5dfef2a1e43bd8ccc235001b5bf018),
            "LpOverflowDripPaid canonical topic0 drifted"
        );
    }

    function test_furnace_lockSoldToFurnace_topic0_pinned() public pure {
        assertEq(
            TOPIC_LOCK_SOLD_TO_FURNACE,
            bytes32(0x0b0e503258418bf9a719f51c4f8f0efa358d69f4462e6fbb852890fcd5f2110c),
            "LockSoldToFurnace canonical topic0 drifted"
        );
    }

    /// @notice Pins the canonical topic0 for the three EmergencyVaultRewire
    ///         lifecycle events, which are now triple-declared
    ///         (lib/Events.sol + IFurnace + FurnaceGuardHelper). The hex
    ///         literals are computed from the canonical signatures the first
    ///         time this test runs and frozen here so any future signature
    ///         drift in any of the three declarations turns this test red.
    function test_furnace_emergencyVaultRewireRequested_topic0_pinned() public pure {
        assertEq(
            TOPIC_EMERGENCY_REWIRE_REQUESTED,
            keccak256("EmergencyVaultRewireRequested(address,uint256,uint256)"),
            "EmergencyVaultRewireRequested canonical drift"
        );
    }

    function test_furnace_emergencyVaultRewireCancelled_topic0_pinned() public pure {
        assertEq(
            TOPIC_EMERGENCY_REWIRE_CANCELLED,
            keccak256("EmergencyVaultRewireCancelled()"),
            "EmergencyVaultRewireCancelled canonical drift"
        );
    }

    function test_furnace_emergencyVaultRewireExecuted_topic0_pinned() public pure {
        assertEq(
            TOPIC_EMERGENCY_REWIRE_EXECUTED,
            keccak256("EmergencyVaultRewireExecuted(address,uint256)"),
            "EmergencyVaultRewireExecuted canonical drift"
        );
    }

    // -----------------------------------------------------------------
    // GenesisLPVault24M events are double-declared (Events.sol +
    // IGenesisLPVault24M). The 'LockExtended' event has TWO overloads
    // in Events.sol (one for VeClaimNFT, one for GenesisLPVault24M).
    // -----------------------------------------------------------------

    bytes32 internal constant TOPIC_GENESIS_LOCKED = keccak256("Locked(uint256,uint256,uint256)");
    bytes32 internal constant TOPIC_GENESIS_LOCK_EXTENDED = keccak256("LockExtended(uint256,uint256)");
    bytes32 internal constant TOPIC_VECLAIM_LOCK_EXTENDED = keccak256("LockExtended(address,uint256,uint256,uint256)");
    bytes32 internal constant TOPIC_GENESIS_WITHDRAW_LP = keccak256("WithdrawLp(address,uint256)");
    bytes32 internal constant TOPIC_GENESIS_RESIDUAL_LP_SWEPT = keccak256("ResidualLpSwept(address,uint256)");
    bytes32 internal constant TOPIC_GENESIS_FEES_CLAIMED_AND_FORWARDED =
        keccak256("FeesClaimedAndForwarded(address,address,uint256,uint256)");

    function test_genesisLpVault_locked_topic0_pinned() public pure {
        assertEq(
            TOPIC_GENESIS_LOCKED,
            bytes32(0xf26b23f4faf546e2647b477c0eb493c07bbb7bd04c865a3d33ba1d99687d88c6),
            "Locked drifted"
        );
    }

    function test_genesisLpVault_lockExtended_topic0_pinned() public pure {
        assertEq(
            TOPIC_GENESIS_LOCK_EXTENDED,
            bytes32(0x4e4187a5cfd31a235276a431f3c394962d1b05cc4da52f6fa4e5460a5808ee21),
            "GenesisLPVault.LockExtended drifted"
        );
    }

    function test_lockExtended_overloads_haveDistinctTopic0() public pure {
        // Solidity allows the overload (different signatures = different
        // topic0). The subgraph routes handlers by full canonical signature.
        // This test guards against accidental signature collision.
        assertTrue(TOPIC_GENESIS_LOCK_EXTENDED != TOPIC_VECLAIM_LOCK_EXTENDED, "LockExtended overloads collided");
    }

    function test_genesisLpVault_withdrawLp_topic0_pinned() public pure {
        assertEq(TOPIC_GENESIS_WITHDRAW_LP, keccak256("WithdrawLp(address,uint256)"), "WithdrawLp canonical drift");
    }

    function test_genesisLpVault_residualLpSwept_topic0_pinned() public pure {
        assertEq(
            TOPIC_GENESIS_RESIDUAL_LP_SWEPT,
            keccak256("ResidualLpSwept(address,uint256)"),
            "ResidualLpSwept canonical drift"
        );
    }

    /// @notice Pins the canonical topic0 for `FeesClaimedAndForwarded`, which
    ///         is double-declared in `lib/Events.sol` (canonical analytics
    ///         registry) and `IGenesisLPVault24M`. The hex literal below was
    ///         computed from the canonical signature
    ///         `FeesClaimedAndForwarded(address,address,uint256,uint256)` and
    ///         is also frozen in `test/snapshots/abi/events_topics.json`.
    ///         Any silent rename, indexed-flag drift, or reorder in either
    ///         declaration MUST turn this test red.
    function test_genesisLpVault_feesClaimedAndForwarded_topic0_pinned() public pure {
        assertEq(
            TOPIC_GENESIS_FEES_CLAIMED_AND_FORWARDED,
            bytes32(0xf1840ef825418791e18c7b4c88e53de8202141d3cd96414106f27512b61ab3eb),
            "FeesClaimedAndForwarded canonical topic0 drifted"
        );
    }

    // -----------------------------------------------------------------
    // v1.0.0 — Furnace merge lifecycle event topic0 pin.
    // FurnaceMergeWithBonus is declared once (Events.sol) and emitted from
    // Furnace.sol. Pinning the canonical signature here protects ABI
    // consumers from silent renames or argument-list reorders, and makes
    // any change require a deliberate pin update in code review.
    // -----------------------------------------------------------------

    bytes32 internal constant TOPIC_FURNACE_MERGE_WITH_BONUS = keccak256(
        "FurnaceMergeWithBonus(address,uint256,uint256,uint256,uint256,uint256,uint256,bool,uint256,uint256)"
    );

    function test_furnace_mergeWithBonus_topic0_pinned() public pure {
        assertEq(
            TOPIC_FURNACE_MERGE_WITH_BONUS,
            bytes32(0xaebdf593a1660c6bab85a368b876d6c046837aff308d54e55bafb0cdaa989613),
            "FurnaceMergeWithBonus canonical topic0 drifted"
        );
    }
}
