// SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

/// @notice Minimal external call surface for GenesisLPVault24M.
/// @dev Used by:
/// - LaunchController (one-shot genesis start)
interface IGenesisLPVault24M {
    event Locked(uint256 lpAmount, uint256 lockStartTime, uint256 unlockTime);
    event LockExtended(uint256 oldUnlockTime, uint256 newUnlockTime);
    event WithdrawLp(address indexed to, uint256 amount);
    event ResidualLpSwept(address indexed to, uint256 amount);
    /// @notice Emitted when accumulated Aerodrome trading fees are claimed from the
    ///         pool and forwarded to `lpWithdrawRecipient` as part of `withdrawLp()`.
    /// @dev Fired only when at least one of `amount0Forwarded` or `amount1Forwarded`
    ///      is non-zero. Always emitted before the corresponding `WithdrawLp` /
    ///      `ResidualLpSwept` event in the same transaction. `token0` / `token1`
    ///      are the pool's underlying tokens (WETH/CLAIM ordering is pool-defined).
    event FeesClaimedAndForwarded(
        address indexed token0, address indexed token1, uint256 amount0Forwarded, uint256 amount1Forwarded
    );

    function rescueEth() external;

    function pool() external view returns (address);

    function lpWithdrawRecipient() external view returns (address);

    function INITIAL_LOCK_DURATION() external view returns (uint256);

    function MAX_EXTENSION() external view returns (uint256);

    function MIN_LP_LOCK() external view returns (uint256);

    function MIN_EXTENSION_DURATION() external view returns (uint256);

    /// @notice One-shot start of the 24-month LP lock by LaunchController during genesis.
    function startLock() external;

    /// @notice Extension of the unlock time (must be later than current `unlockTime()`).
    /// @dev Callable only by `lpWithdrawRecipient()`. The vault has no `owner()`.
    function extendLock(uint256 newUnlockTime) external;

    /// @notice Withdraws the locked LP balance to `lpWithdrawRecipient()` after `unlockTime()`.
    /// @dev Atomically claims accumulated Aerodrome trading fees via the pool's `claimFees()`
    ///      and forwards both `token0` / `token1` balances to `lpWithdrawRecipient()` BEFORE the
    ///      LP transfer (best-effort: `try/catch`-guarded so a misbehaving pool cannot DoS LP
    ///      recovery). Same fee-claim-and-forward step also runs in the residual-LP branch
    ///      (`unlockTime == 0`, post-canonical-withdraw). Emits `FeesClaimedAndForwarded` when at
    ///      least one forwarded amount is non-zero, then either `WithdrawLp` (canonical branch)
    ///      or `ResidualLpSwept` (residual branch). Callable only by `lpWithdrawRecipient()`.
    function withdrawLp() external;

    function unlockTime() external view returns (uint256);

    function lpLockedAmount() external view returns (uint256);

    function lockStartTime() external view returns (uint256);
}
