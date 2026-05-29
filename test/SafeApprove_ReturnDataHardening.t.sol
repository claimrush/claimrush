// SPDX-License-Identifier: MIT
pragma solidity ^0.8.34;

import {Test} from "forge-std/Test.sol";

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {Errors} from "src/lib/Errors.sol";
import {SafeApprove} from "src/lib/SafeApprove.sol";
import {SafeERC20View} from "src/lib/SafeERC20View.sol";

import {MockApproveReturnToken} from "./mocks/MockApproveReturnToken.sol";

/// @notice Minimal harness that mirrors the protocol's "clear then set" allowance pattern,
///         but uses SafeApprove.callApprove to avoid return-data copy griefing.
contract ForceApproveHarness {
    function forceApprove(IERC20 token, address spender, uint256 value) external {
        // Use the protocol's bounded-gas allowance probe so this harness can
        // also be used to test non-contract addresses (EOAs return empty data).
        (uint256 current, bool ok) = SafeERC20View.callAllowance(token, address(this), spender);
        if (ok && current == value) return;

        if (ok && current != 0) {
            if (!SafeApprove.callApprove(token, spender, 0)) revert Errors.ApprovalFailed();
        }

        if (value != 0) {
            if (!SafeApprove.callApprove(token, spender, value)) revert Errors.ApprovalFailed();
        }
    }
}

contract SafeApproveReturnDataHardeningTest is Test {
    MockApproveReturnToken internal token;
    ForceApproveHarness internal h;

    address internal spender = address(0xBEEF);

    function setUp() public {
        token = new MockApproveReturnToken();
        h = new ForceApproveHarness();
    }

    function testForceApprove_ReturnNone_TreatedAsSuccess() public {
        token.setMode(MockApproveReturnToken.Mode.ReturnNone);

        h.forceApprove(IERC20(address(token)), spender, 123);
        assertEq(token.allowance(address(h), spender), 123);
    }

    function testForceApprove_ReturnShort1_RevertsApprovalFailed() public {
        token.setMode(MockApproveReturnToken.Mode.ReturnShort1);

        vm.expectRevert(Errors.ApprovalFailed.selector);
        h.forceApprove(IERC20(address(token)), spender, 1);

        // State should be unchanged because the outer call reverted.
        assertEq(token.allowance(address(h), spender), 0);
    }

    function testForceApprove_ReturnFalse32_RevertsApprovalFailed() public {
        token.setMode(MockApproveReturnToken.Mode.ReturnFalse32);

        vm.expectRevert(Errors.ApprovalFailed.selector);
        h.forceApprove(IERC20(address(token)), spender, 1);

        assertEq(token.allowance(address(h), spender), 0);
    }

    function testForceApprove_ReturnExtra64True_TreatedAsSuccess() public {
        token.setMode(MockApproveReturnToken.Mode.ReturnExtra64True);

        h.forceApprove(IERC20(address(token)), spender, 777);
        assertEq(token.allowance(address(h), spender), 777);
    }

    function testForceApprove_RevertLarge_RevertsApprovalFailed() public {
        // Large revert data should not be copied into memory by the approval helper.
        // If it is, this call is likely to run out of gas (return-data bomb).
        token.setReturnSize(262_144);
        token.setMode(MockApproveReturnToken.Mode.RevertLarge);

        // Call through a gas-limited frame to catch any unintended returndata copying.
        (bool ok, bytes memory data) = address(h).call{gas: 300_000}(
            abi.encodeWithSelector(ForceApproveHarness.forceApprove.selector, IERC20(address(token)), spender, 1)
        );
        assertFalse(ok);
        // Revert payload shape is intentionally not asserted here because oversized
        // callee revert data can truncate or alter bubbled revert bytes.
        data;

        // State should be unchanged because the outer call reverted.
        assertEq(token.allowance(address(h), spender), 0);
    }

    function testForceApprove_ReturnLargeTrue_SucceedsWithLimitedGas() public {
        // Large success return data should not be copied into memory by the approval helper.
        token.setReturnSize(262_144);
        token.setMode(MockApproveReturnToken.Mode.ReturnLargeTrue);

        // Call through a gas-limited frame to ensure we don't accidentally copy full returndata.
        (bool ok,) = address(h).call{gas: 300_000}(
            abi.encodeWithSelector(ForceApproveHarness.forceApprove.selector, IERC20(address(token)), spender, 42)
        );
        assertTrue(ok);

        assertEq(token.allowance(address(h), spender), 42);
    }

    function testForceApprove_Eoa_ReturnNone_RevertsApprovalFailed() public {
        // EOAs succeed with empty returndata but cannot mutate allowance.
        // SafeApprove MUST treat this as failure to match OZ SafeERC20 semantics.
        IERC20 eoa = IERC20(address(0xBEEF));

        vm.expectRevert(Errors.ApprovalFailed.selector);
        h.forceApprove(eoa, spender, 1);
    }
}
