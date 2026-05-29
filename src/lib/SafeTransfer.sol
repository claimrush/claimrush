// SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/// @notice Low-level ERC20 transfer helper that avoids returndata copy griefing.
/// @dev Compatibility policy (mirrors SafeApprove):
///      - Empty returndata counts as success only for contract token addresses.
///      - Tokens that return >= 32 bytes are treated as success iff the first word is nonzero.
///      - Tokens that return 1..31 bytes are treated as failure (non-standard).
///
///      This helper never copies full returndata on failure, and copies at most 32 bytes on success,
///      preventing "return data bomb" gas griefing.
library SafeTransfer {
    function callTransfer(IERC20 token, address to, uint256 value) internal returns (bool ok) {
        address tokenAddr = address(token);
        assembly ("memory-safe") {
            ok := 0

            // calldata: transfer(address,uint256)
            // selector 0xa9059cbb
            let ptr := mload(0x40)
            mstore(ptr, shl(224, 0xa9059cbb))
            mstore(add(ptr, 0x04), to)
            mstore(add(ptr, 0x24), value)

            // Keep a small gas reserve so callers can still handle failures.
            let callGas := gas()
            if gt(callGas, 6000) { callGas := sub(callGas, 5000) }

            let success := call(callGas, tokenAddr, 0, ptr, 0x44, 0, 0)
            if success {
                let rds := returndatasize()
                // Treat empty return data as success only for contracts.
                // EOAs (or self-destructed contracts) also return empty data but perform no transfer.
                if iszero(rds) {
                    if gt(extcodesize(tokenAddr), 0) { ok := 1 }
                }
                if iszero(ok) {
                    if iszero(lt(rds, 0x20)) {
                        returndatacopy(ptr, 0, 0x20)
                        ok := iszero(iszero(mload(ptr)))
                    }
                }
            }
        }
    }

    function callTransferFrom(IERC20 token, address from, address to, uint256 value) internal returns (bool ok) {
        address tokenAddr = address(token);
        assembly ("memory-safe") {
            ok := 0

            // calldata: transferFrom(address,address,uint256)
            // selector 0x23b872dd
            let ptr := mload(0x40)
            mstore(ptr, shl(224, 0x23b872dd))
            mstore(add(ptr, 0x04), from)
            mstore(add(ptr, 0x24), to)
            mstore(add(ptr, 0x44), value)

            // 4 + 32*3 = 0x64
            let callGas := gas()
            if gt(callGas, 6000) { callGas := sub(callGas, 5000) }

            let success := call(callGas, tokenAddr, 0, ptr, 0x64, 0, 0)
            if success {
                let rds := returndatasize()
                // Treat empty return data as success only for contracts.
                // EOAs (or self-destructed contracts) also return empty data but perform no transfer.
                if iszero(rds) {
                    if gt(extcodesize(tokenAddr), 0) { ok := 1 }
                }
                if iszero(ok) {
                    if iszero(lt(rds, 0x20)) {
                        returndatacopy(ptr, 0, 0x20)
                        ok := iszero(iszero(mload(ptr)))
                    }
                }
            }
        }
    }
}
