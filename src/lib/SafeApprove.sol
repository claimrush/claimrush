// SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20View} from "./SafeERC20View.sol";
import {Errors} from "./Errors.sol";

/// @notice Low-level ERC20 approve helper that avoids returndata copy griefing.
/// @dev Compatibility policy:
///      - Empty returndata counts as success only for contract token addresses.
///      - Tokens that return >= 32 bytes are treated as success iff the first word is nonzero.
///      - Tokens that return 1..31 bytes are treated as failure (non-standard).
///
///      This helper never copies full returndata on failure, and copies at most 32 bytes on success,
///      preventing "return data bomb" gas griefing.
library SafeApprove {
    function callApprove(IERC20 token, address spender, uint256 value) internal returns (bool ok) {
        address tokenAddr = address(token);
        // NOTE: We intentionally avoid `bytes memory data = address(token).call(...)` here.
        // That pattern copies *all* returndata (or revert data) into memory, and can be
        // griefed by tokens that return very large buffers.
        // Instead we:
        // - set the call output area size to 0 (so CALL does not copy output)
        // - on success, copy at most 32 bytes (the first ABI word)
        // - on failure, copy 0 bytes
        assembly ("memory-safe") {
            // Default to false.
            ok := 0

            // Build calldata for approve(address,uint256).
            // 4-byte selector + 32-byte spender + 32-byte value = 0x44 bytes.
            let ptr := mload(0x40)
            mstore(ptr, shl(224, 0x095ea7b3))
            mstore(add(ptr, 0x04), spender)
            mstore(add(ptr, 0x24), value)

            // Call token.approve(spender, value) with no output buffer.
            // This prevents the EVM from copying large returndata into memory.
            // Keep a small gas reserve so callers can still handle failures
            // (e.g. revert with Errors.ApprovalFailed) even if token call
            // consumes almost all forwarded gas.
            let callGas := gas()
            if gt(callGas, 6000) { callGas := sub(callGas, 5000) }
            let success := call(callGas, tokenAddr, 0, ptr, 0x44, 0, 0)
            if success {
                let rds := returndatasize()
                // Tokens that return no data are treated as success *only* when the token is a contract.
                // Calls to EOAs (or self-destructed contracts) also succeed with empty returndata, but perform no action.
                if iszero(rds) {
                    if gt(extcodesize(tokenAddr), 0) { ok := 1 }
                }
                // Tokens that return >= 32 bytes are treated as success iff first word != 0.
                // Short returns (1..31) are treated as failure.
                if iszero(ok) {
                    if iszero(lt(rds, 0x20)) {
                        returndatacopy(ptr, 0, 0x20)
                        ok := iszero(iszero(mload(ptr)))
                    }
                }
            }
        }
    }

    /// @notice Force-approve for tokens that revert on approve(nonzero -> nonzero) (e.g. USDT).
    /// @dev Tokens like USDT revert on approve(nonzero -> nonzero).  This helper:
    ///      1. Reads the current allowance via gas-bounded SafeERC20View.callAllowance (return-bomb safe).
    ///      2. If the read fails or the current allowance is non-zero, approves 0 first.
    ///      3. Approves the requested value (skipped when value == 0 since step 2 already cleared).
    ///
    ///      Reverts with Errors.ApprovalFailed() if any underlying approve call fails.
    ///      Early-exits when the current allowance already equals `value`.
    ///
    /// @dev Spender-trust assumption. `forceApprove` resets the on-chain allowance to `value`
    ///      and is therefore only safe when the caller has independently established that
    ///      `spender` is a canonical / trusted protocol address (e.g. an Aerodrome router that
    ///      the caller has validated against `EntryTokenRegistry` or a fresh `DexAdapter`
    ///      `factory()` lookup) AND that the approval window is closed inside the same
    ///      transaction (e.g. via `forceApprove(token, spender, 0)` after the swap).
    ///      Standing approvals to an arbitrary `spender` are out of scope for this helper.
    function forceApprove(IERC20 token, address spender, uint256 value) internal {
        (uint256 current, bool ok) = SafeERC20View.callAllowance(token, address(this), spender);

        // Already at target -- skip redundant approvals.
        if (ok && current == value) return;

        // Clear to 0 first when: allowance read failed (defense-in-depth) OR current != 0 (USDT safety).
        if (!ok || current != 0) {
            if (!callApprove(token, spender, 0)) revert Errors.ApprovalFailed();
        }

        if (value != 0) {
            if (!callApprove(token, spender, value)) revert Errors.ApprovalFailed();
        }
    }
}
