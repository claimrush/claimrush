// SPDX-License-Identifier: MIT
pragma solidity ^0.8.34;

import {Test} from "forge-std/Test.sol";

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {SafeERC20View} from "src/lib/SafeERC20View.sol";

import {MockViewReturnToken} from "./mocks/MockViewReturnToken.sol";

contract SafeERC20ViewHarness {
    function safeBalanceOf(IERC20 token, address user) external view returns (uint256 value, bool ok) {
        return SafeERC20View.callBalanceOf(token, user);
    }

    function safeAllowance(IERC20 token, address owner, address spender)
        external
        view
        returns (uint256 value, bool ok)
    {
        return SafeERC20View.callAllowance(token, owner, spender);
    }

    function safeDecimals(IERC20 token) external view returns (uint8 value, bool ok) {
        return SafeERC20View.callDecimals(token);
    }
}

contract SafeERC20ViewReturnDataHardeningTest is Test {
    MockViewReturnToken internal token;
    SafeERC20ViewHarness internal h;

    address internal alice = address(0xA11CE);
    address internal bob = address(0xB0B);

    function setUp() public {
        token = new MockViewReturnToken();
        h = new SafeERC20ViewHarness();

        token.mint(alice, 123);
        vm.prank(alice);
        token.approve(bob, 7);
    }

    function testBalanceOf_ReturnLarge_DoesNotOOG_WithLimitedGas() public {
        token.setReturnSize(262_144);
        token.setBalanceMode(MockViewReturnToken.Mode.ReturnLarge);

        (bool ok, bytes memory data) = address(h).call{gas: 200_000}(
            abi.encodeWithSelector(SafeERC20ViewHarness.safeBalanceOf.selector, IERC20(address(token)), alice)
        );
        assertTrue(ok);

        (uint256 bal, bool balOk) = abi.decode(data, (uint256, bool));
        assertTrue(balOk);
        assertEq(bal, 123);
    }

    function testAllowance_ReturnLarge_DoesNotOOG_WithLimitedGas() public {
        token.setReturnSize(262_144);
        token.setAllowanceMode(MockViewReturnToken.Mode.ReturnLarge);

        (bool ok, bytes memory data) = address(h).call{gas: 200_000}(
            abi.encodeWithSelector(SafeERC20ViewHarness.safeAllowance.selector, IERC20(address(token)), alice, bob)
        );
        assertTrue(ok);

        (uint256 a, bool aOk) = abi.decode(data, (uint256, bool));
        assertTrue(aOk);
        assertEq(a, 7);
    }

    function testAllowance_RevertLarge_ReturnsOkFalse_NoOOG() public {
        token.setReturnSize(262_144);
        token.setAllowanceMode(MockViewReturnToken.Mode.RevertLarge);

        (bool ok, bytes memory data) = address(h).call{gas: 200_000}(
            abi.encodeWithSelector(SafeERC20ViewHarness.safeAllowance.selector, IERC20(address(token)), alice, bob)
        );
        assertTrue(ok);

        (uint256 a, bool aOk) = abi.decode(data, (uint256, bool));
        assertFalse(aOk);
        assertEq(a, 0);
    }

    function testBalanceOf_ReturnShort1_ReturnsOkFalse() public {
        token.setBalanceMode(MockViewReturnToken.Mode.ReturnShort1);

        (bool ok, bytes memory data) = address(h).call{gas: 200_000}(
            abi.encodeWithSelector(SafeERC20ViewHarness.safeBalanceOf.selector, IERC20(address(token)), alice)
        );
        assertTrue(ok);

        (uint256 bal, bool balOk) = abi.decode(data, (uint256, bool));
        assertFalse(balOk);
        assertEq(bal, 0);
    }

    function testDecimals_StandardEighteen_ReturnsOk() public {
        token.setDecimalsValue(18);
        (uint8 value, bool ok) = SafeERC20View.callDecimals(IERC20(address(token)));
        assertTrue(ok);
        assertEq(value, 18);
    }

    function testDecimals_BoundaryUint8Max_ReturnsOk() public {
        token.setDecimalsValue(255);
        (uint8 value, bool ok) = SafeERC20View.callDecimals(IERC20(address(token)));
        assertTrue(ok);
        assertEq(value, 255);
    }

    function testDecimals_OutOfRange256_ReturnsOkFalse() public {
        // Exact boundary: lt(raw, 256) is false for raw == 256, so ok must stay false.
        token.setDecimalsValue(256);
        (uint8 value, bool ok) = SafeERC20View.callDecimals(IERC20(address(token)));
        assertFalse(ok);
        assertEq(value, 0);
    }

    function testDecimals_RevertLarge_ReturnsOkFalse_NoOOG() public {
        token.setReturnSize(262_144);
        token.setDecimalsMode(MockViewReturnToken.Mode.RevertLarge);

        (bool ok, bytes memory data) = address(h).call{gas: 200_000}(
            abi.encodeWithSelector(SafeERC20ViewHarness.safeDecimals.selector, IERC20(address(token)))
        );
        assertTrue(ok);

        (uint8 value, bool decOk) = abi.decode(data, (uint8, bool));
        assertFalse(decOk);
        assertEq(value, 0);
    }

    function testDecimals_Eoa_ReturnNone_ReturnsOkFalse() public {
        // Calls to EOAs succeed with empty returndata. SafeERC20View has no
        // EOA-guard fallback (unlike SafeTransfer / SafeApprove): a view that
        // returns nothing has no usable value, so ok must be false.
        IERC20 eoa = IERC20(address(0xBEEF));
        (uint8 value, bool ok) = SafeERC20View.callDecimals(eoa);
        assertFalse(ok);
        assertEq(value, 0);
    }

    function testDecimals_ReturnShort1_ReturnsOkFalse() public {
        token.setDecimalsMode(MockViewReturnToken.Mode.ReturnShort1);
        (uint8 value, bool ok) = SafeERC20View.callDecimals(IERC20(address(token)));
        assertFalse(ok);
        assertEq(value, 0);
    }
}
