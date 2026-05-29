// SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/// @notice Low-level ERC20 view helpers that avoid returndata copy griefing.
/// @dev These helpers:
///      - perform the call with output size 0 (so the EVM does not copy returndata)
///      - on success, copy at most 32 bytes (the first ABI word)
///      - on failure, copy 0 bytes
///
///      Returns `(value, ok)` where `ok` is true iff the call succeeded and returned at least 32 bytes.
///      Short returns (1..31 bytes) are treated as failure.
///      For `callDecimals`, `ok` also requires the decoded word to fit in `uint8`.
library SafeERC20View {
    /// @dev Must cover callee memory expansion for pathological ERC20s that return huge returndata while
    ///      still placing the uint256 in the first 32 bytes (~256 KiB is ~155k gas of memory alone).
    uint256 private constant VIEW_CALL_GAS = 240_000;

    function callBalanceOf(IERC20 token, address account) internal view returns (uint256 value, bool ok) {
        address tokenAddr = address(token);
        uint256 gasBudget = VIEW_CALL_GAS;
        assembly ("memory-safe") {
            value := 0
            ok := 0

            // calldata: balanceOf(address)
            // selector 0x70a08231
            let ptr := mload(0x40)
            mstore(ptr, shl(224, 0x70a08231))
            mstore(add(ptr, 0x04), account)

            // Bound gas so malicious tokens cannot exhaust caller gas by returning huge buffers.
            let success := staticcall(gasBudget, tokenAddr, ptr, 0x24, 0, 0)
            if success {
                let rds := returndatasize()
                if iszero(lt(rds, 0x20)) {
                    returndatacopy(ptr, 0, 0x20)
                    value := mload(ptr)
                    ok := 1
                }
            }
        }
    }

    function callAllowance(IERC20 token, address owner, address spender)
        internal
        view
        returns (uint256 value, bool ok)
    {
        address tokenAddr = address(token);
        uint256 gasBudget = VIEW_CALL_GAS;
        assembly ("memory-safe") {
            value := 0
            ok := 0

            // calldata: allowance(address,address)
            // selector 0xdd62ed3e
            let ptr := mload(0x40)
            mstore(ptr, shl(224, 0xdd62ed3e))
            mstore(add(ptr, 0x04), owner)
            mstore(add(ptr, 0x24), spender)

            // Bound gas so malicious tokens cannot exhaust caller gas by returning huge buffers.
            let success := staticcall(gasBudget, tokenAddr, ptr, 0x44, 0, 0)
            if success {
                let rds := returndatasize()
                if iszero(lt(rds, 0x20)) {
                    returndatacopy(ptr, 0, 0x20)
                    value := mload(ptr)
                    ok := 1
                }
            }
        }
    }

    /// @notice Gas-bounded, return-bomb-safe wrapper for ERC20.decimals().
    /// @dev Same hardening pattern as callBalanceOf / callAllowance:
    ///      - staticcall with bounded gas (VIEW_CALL_GAS; prevents malicious gas exhaustion)
    ///      - output size 0 on call, then manual returndatacopy of at most 32 bytes
    ///      - validates the returned word fits in uint8 (0-255)
    /// @return value The token's decimals (0 if call failed or out of range).
    /// @return ok    True iff the call succeeded, returned >= 32 bytes, and the value fits in uint8.
    function callDecimals(IERC20 token) internal view returns (uint8 value, bool ok) {
        address tokenAddr = address(token);
        uint256 gasBudget = VIEW_CALL_GAS;
        assembly ("memory-safe") {
            value := 0
            ok := 0

            // calldata: decimals()  -- selector 0x313ce567
            let ptr := mload(0x40)
            mstore(ptr, shl(224, 0x313ce567))

            let success := staticcall(gasBudget, tokenAddr, ptr, 0x04, 0, 0)
            if success {
                let rds := returndatasize()
                if iszero(lt(rds, 0x20)) {
                    returndatacopy(ptr, 0, 0x20)
                    let raw := mload(ptr)
                    if lt(raw, 256) {
                        value := raw
                        ok := 1
                    }
                }
            }
        }
    }
}
