// SPDX-License-Identifier: MIT
pragma solidity ^0.8.34;

import {Test} from "forge-std/Test.sol";

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {Errors} from "src/lib/Errors.sol";
import {SafeTransfer} from "src/lib/SafeTransfer.sol";

import {MockTransferReturnToken} from "./mocks/MockTransferReturnToken.sol";

/// @notice Minimal harness that mirrors protocol pull/transfer patterns,
///         but uses SafeTransfer to avoid return-data copy griefing.
contract ForceTransferHarness {
    function pullFrom(IERC20 token, address from, address to, uint256 value) external {
        if (!SafeTransfer.callTransferFrom(token, from, to, value)) revert Errors.TransferFailed();
    }

    function push(IERC20 token, address to, uint256 value) external {
        if (!SafeTransfer.callTransfer(token, to, value)) revert Errors.TransferFailed();
    }
}

contract SafeTransferReturnDataHardeningTest is Test {
    MockTransferReturnToken internal token;
    ForceTransferHarness internal h;

    address internal from = address(0xA11CE);
    address internal to = address(0xB0B);

    function setUp() public {
        token = new MockTransferReturnToken();
        h = new ForceTransferHarness();

        token.mint(from, 1_000 ether);
        vm.prank(from);
        token.approve(address(h), type(uint256).max);
    }

    function testTransferFrom_ReturnNone_TreatedAsSuccess() public {
        token.setMode(MockTransferReturnToken.Mode.ReturnNone);

        h.pullFrom(IERC20(address(token)), from, to, 123);
        assertEq(token.balanceOf(to), 123);
    }

    function testTransferFrom_ReturnShort1_RevertsTransferFailed() public {
        token.setMode(MockTransferReturnToken.Mode.ReturnShort1);

        vm.expectRevert(Errors.TransferFailed.selector);
        h.pullFrom(IERC20(address(token)), from, to, 1);

        assertEq(token.balanceOf(to), 0);
    }

    function testTransferFrom_ReturnFalse32_RevertsTransferFailed() public {
        token.setMode(MockTransferReturnToken.Mode.ReturnFalse32);

        vm.expectRevert(Errors.TransferFailed.selector);
        h.pullFrom(IERC20(address(token)), from, to, 1);

        assertEq(token.balanceOf(to), 0);
    }

    function testTransferFrom_ReturnExtra64True_TreatedAsSuccess() public {
        token.setMode(MockTransferReturnToken.Mode.ReturnExtra64True);

        h.pullFrom(IERC20(address(token)), from, to, 777);
        assertEq(token.balanceOf(to), 777);
    }

    function testTransferFrom_RevertLarge_RevertsTransferFailed_WithLimitedGas() public {
        // Large revert data should not be copied into memory by the transfer helper.
        // If it is, this call is likely to run out of gas (return-data bomb).
        token.setReturnSize(262_144);
        token.setMode(MockTransferReturnToken.Mode.RevertLarge);

        // Call through a gas-limited frame to catch any unintended returndata copying.
        (bool ok, bytes memory data) = address(h).call{gas: 300_000}(
            abi.encodeWithSelector(ForceTransferHarness.pullFrom.selector, IERC20(address(token)), from, to, 1)
        );
        assertFalse(ok);
        data;

        // State should be unchanged because the outer call reverted.
        assertEq(token.balanceOf(to), 0);
    }

    function testTransferFrom_ReturnLargeTrue_SucceedsWithLimitedGas() public {
        // Large success return data should not be copied into memory by the transfer helper.
        token.setReturnSize(262_144);
        token.setMode(MockTransferReturnToken.Mode.ReturnLargeTrue);

        (bool ok,) = address(h).call{gas: 300_000}(
            abi.encodeWithSelector(ForceTransferHarness.pullFrom.selector, IERC20(address(token)), from, to, 42)
        );
        assertTrue(ok);

        assertEq(token.balanceOf(to), 42);
    }

    function testTransferFrom_Eoa_ReturnNone_RevertsTransferFailed() public {
        // Calls to EOAs succeed with empty returndata but do not perform any token logic.
        // SafeTransfer MUST treat this as failure (mirrors OZ SafeERC20's contract check).
        IERC20 eoa = IERC20(address(0xBEEF));

        vm.expectRevert(Errors.TransferFailed.selector);
        h.pullFrom(eoa, from, to, 1);
    }

    function testTransfer_Eoa_ReturnNone_RevertsTransferFailed() public {
        IERC20 eoa = IERC20(address(0xBEEF));

        vm.expectRevert(Errors.TransferFailed.selector);
        h.push(eoa, to, 1);
    }
}
