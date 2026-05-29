// SPDX-License-Identifier: MIT
pragma solidity ^0.8.34;

import {Test} from "forge-std/Test.sol";

import {Constants} from "src/lib/Constants.sol";

/// @notice Guardrails against accidental drift in analytics mode codes,
///         delist reason codes, and auto-compound pause reason codes.
///
/// All numeric mappings pinned here MUST be immutable once deployed.
/// @dev See docs/analytics/dune-integration-pack-v1.0.0.md for the canonical codebook.
contract ModeCodesGuardrailTest is Test {
    function testFurnaceModeCodesArePinned() public {
        assertEq(Constants.FURNACE_MODE_ENTER_WITH_ETH, 0);
        assertEq(Constants.FURNACE_MODE_ENTER_WITH_CLAIM, 1);
        assertEq(Constants.FURNACE_MODE_LOCK_FURNACE, 2);
        assertEq(Constants.FURNACE_MODE_ENTER_WITH_TOKEN, 3);
    }

    function testShareholderModeCodesArePinned() public {
        assertEq(Constants.SHAREHOLDER_MODE_ETH, 0);
        assertEq(Constants.SHAREHOLDER_MODE_LOCK_FURNACE, 1);
    }

    function testLockDelistReasonCodesArePinned() public {
        assertEq(Constants.LOCK_DELIST_REASON_NORMAL, 0);
        assertEq(Constants.LOCK_DELIST_REASON_EMERGENCY, 1);
        assertEq(Constants.LOCK_DELIST_REASON_SOLD_INTO_OFFER, 2);
        assertEq(Constants.LOCK_DELIST_REASON_SOLD_TO_FURNACE, 3);
        assertEq(Constants.LOCK_DELIST_REASON_EXPIRED, 4);
        assertEq(Constants.LOCK_DELIST_REASON_APPROVAL_REVOKED, 5);
    }

    function testShareholderAutoCompoundPauseReasonCodesArePinned() public {
        assertEq(Constants.SHAREHOLDER_AUTOCOMPOUND_PAUSE_REASON_NOT_OWNER, 1);
        assertEq(Constants.SHAREHOLDER_AUTOCOMPOUND_PAUSE_REASON_LISTED, 2);
        assertEq(Constants.SHAREHOLDER_AUTOCOMPOUND_PAUSE_REASON_EXPIRED, 3);
        assertEq(Constants.SHAREHOLDER_AUTOCOMPOUND_PAUSE_REASON_INVALID_TOKEN_ID, 4);
    }
}
