// SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Errors} from "../lib/Errors.sol";
import {IGenesisLPVault24M} from "../interfaces/IGenesisLPVault24M.sol";
import {IAerodromePool} from "../interfaces/IAerodromePool.sol";

// GenesisLPVault24M holds *genesis* LP while LpStakingVault7D holds *user-staked* LP.

/// @notice Genesis LP vault for ClaimRush v1.0.0.
/// @dev Spec: docs/spec/vault-spec.md
///
/// Responsibilities:
/// - Custody the canonical Aerodrome WETH/CLAIM vAMM LP token created at genesis.
/// - Enforce a 24 month time-lock on that LP position.
/// - After unlock, allow LP withdrawal only to a fixed recipient: lpWithdrawRecipient.
///   `withdrawLp()` also claims accumulated Aerodrome trading fees from the pool
///   and forwards both fee tokens to `lpWithdrawRecipient` in the same transaction
///   (Aerodrome v2 keeps fees in per-LP-holder claimable slots separate from pool
///   reserves; without this on-vault claim path the 24 months of fees would be
///   permanently stranded against the vault's address after the LP transfer).
/// - Allow the lock to be extended (never shortened).
contract GenesisLPVault24M is ReentrancyGuard, IGenesisLPVault24M {
    using SafeERC20 for IERC20;

    // Errors (local)
    error LockAlreadyStarted();
    error LockNotStarted();
    error NoLp();
    error OnlyLpWithdrawRecipient();
    error UnlockTimeNotReached();
    error UnlockTimeNotIncreased();
    error ExtensionTooLong();
    error AlreadyWithdrawn();
    error DustLock();
    error NoTokenToRescue();
    error ExtensionTooShort();
    event TokenRescued(address indexed token, address indexed to, uint256 amount);

    // Constants (v1.0.0 policy)

    /// @notice Initial lock duration: 730 days (~24 months).
    // 728-732 calendar days depending on leap years; 730 is a fixed-duration approximation.
    uint256 public constant INITIAL_LOCK_DURATION = 730 days;
    /// @notice Maximum forward extension from current timestamp (10 years).
    uint256 public constant MAX_EXTENSION = 3650 days;
    /// @notice Absolute maximum lock duration from lockStartTime (100 years).
    uint256 public constant MAX_ABSOLUTE_LOCK = 36500 days;
    uint256 public constant MIN_LP_LOCK = 1e15;
    /// @notice Minimum meaningful extension: 1 day.  Prevents sub-block "re-locks" after expiry.
    uint256 public constant MIN_EXTENSION_DURATION = 1 days;

    // Immutable config

    /// @notice Aerodrome pool address (also the LP token).
    address public immutable pool;

    /// @notice Fixed recipient of LP withdrawals.
    address public immutable lpWithdrawRecipient;

    // Lock state

    /// @notice Timestamp when the lock was started.
    uint256 public lockStartTime;

    /// @notice Timestamp when the LP becomes withdrawable.
    /// @dev Holds `0` in two distinct states: (1) PreStartLock — before `startLock()` has been
    ///      called; and (2) PostWithdraw — after the main `withdrawLp()` branch has executed and
    ///      the genesis LP has been transferred out. External readers must consult
    ///      `lockStartTime() == 0` to disambiguate (only true in PreStartLock).
    uint256 public unlockTime;

    /// @notice LP amount observed when the lock was started.
    uint256 public lpLockedAmount;

    // Events (required)

    // Lock lifecycle events live in the interface; TokenRescued is defined locally.

    modifier onlyLpWithdrawRecipient() {
        if (msg.sender != lpWithdrawRecipient) revert OnlyLpWithdrawRecipient();
        // Runtime 7702 reject: the constructor enforces this at deploy, but the
        // recipient EOA can install a delegation designator afterward and turn
        // every privileged path here (`extendLock`, `withdrawLp`, `rescueEth`)
        // into a public-executor surface — `extendLock` in particular can push
        // the genesis LP unlock toward the 100-year cap. Re-check on every
        // protected call so a post-seating delegation flip is rejected.
        if (msg.sender.code.length == 23) {
            bytes3 prefix;
            address sender = msg.sender;
            assembly ("memory-safe") {
                extcodecopy(sender, 0x00, 0x00, 0x03)
                prefix := mload(0x00)
            }
            if (prefix == 0xEF0100) revert Errors.DelegatedEOA();
        }
        _;
    }

    /// @dev `_pool` may be a deterministic CREATE2 address before the pool has live code.
    ///      The canonical deployment flow separately validates that the pinned address matches
    ///      DexAdapter.poolFor(...) and LaunchController later materializes the pool during genesis.
    constructor(address _pool, address _lpWithdrawRecipient) {
        if (_pool == address(0) || _lpWithdrawRecipient == address(0)) revert Errors.ZeroAddress();
        if (_lpWithdrawRecipient == _pool) revert Errors.WiringMismatch();
        // Reject the vault itself as the recipient. There is no self-call path, so passing
        // `address(this)` would brick `extendLock`/`withdrawLp`/`rescueEth` permanently. The
        // vault address is known at deploy time via CREATE2, so a single deployer typo could
        // otherwise lock the genesis LP for 24 months.
        if (_lpWithdrawRecipient == address(this)) revert Errors.WiringMismatch();
        // Reject EIP-7702 delegated EOAs as the recipient. A 7702 designator is exactly the
        // 23-byte sequence `0xEF 0x01 0x00 || delegate`. Allowing such a recipient would let
        // the underlying EOA's delegation tuple silently change after deployment, moving the
        // effective code that runs inside `extendLock`/`withdrawLp`/`rescueEth`. Bare EOAs
        // remain accepted because the canonical local-deploy flow uses an EOA recipient and
        // because the `OnlyLpWithdrawRecipient` modifier still gates every privileged path.
        if (_lpWithdrawRecipient.code.length == 23) {
            bytes3 prefix;
            address rcp = _lpWithdrawRecipient;
            assembly ("memory-safe") {
                extcodecopy(rcp, 0x00, 0x00, 0x03)
                prefix := mload(0x00)
            }
            if (prefix == 0xEF0100) revert Errors.DelegatedEOA();
        }
        pool = _pool;
        lpWithdrawRecipient = _lpWithdrawRecipient;
    }

    // Locking

    /// @notice Start the 24 month lock. One-shot.
    /// @dev The vault MUST already hold LP (minted directly to it during genesis or transferred in the same tx).
    ///      This function is intentionally permissionless (no access control).  In the canonical genesis
    ///      flow it is called by LaunchController.finalizeGenesis() immediately after minting LP to this
    ///      vault.  Pre-genesis griefing is mitigated by: (1) CLAIM can only be minted by MineCore, which
    ///      is paused until genesis; (2) LaunchController._ensureEmptyOrSkim() reverts if the pool has
    ///      non-zero totalSupply.  Any deployment that mints CLAIM pre-genesis must treat access
    ///      control on startLock as a separate deployment invariant.
    function startLock() external nonReentrant {
        if (lockStartTime != 0) revert LockAlreadyStarted();

        uint256 bal = IERC20(pool).balanceOf(address(this));
        if (bal == 0) revert NoLp();
        if (bal < MIN_LP_LOCK) revert DustLock();

        uint256 _lockStartTime = block.timestamp;
        uint256 _unlockTime = block.timestamp + INITIAL_LOCK_DURATION;
        lockStartTime = _lockStartTime;
        unlockTime = _unlockTime;
        lpLockedAmount = bal;

        emit Locked(bal, _lockStartTime, _unlockTime);
    }

    /// @notice Extend the lock (never shorten).
    /// @dev Callable only by the fixed lpWithdrawRecipient. There is no shortenLock();
    ///      once extended, the action is irreversible. Consider carefully before extending.
    function extendLock(uint256 newUnlockTime) external nonReentrant onlyLpWithdrawRecipient {
        if (lockStartTime == 0) revert LockNotStarted();
        if (unlockTime == 0) revert AlreadyWithdrawn();
        if (newUnlockTime <= unlockTime) revert UnlockTimeNotIncreased();
        if (newUnlockTime > block.timestamp + MAX_EXTENSION) revert ExtensionTooLong();
        if (newUnlockTime > lockStartTime + MAX_ABSOLUTE_LOCK) revert ExtensionTooLong();
        // The MIN_EXTENSION_DURATION check below (>= 1 day) strictly implies
        // `newUnlockTime > block.timestamp`, so a separate "in-the-past" guard is unreachable.
        // If MIN_EXTENSION_DURATION is ever lowered to zero, reintroduce a past-check here.
        if (newUnlockTime < block.timestamp + MIN_EXTENSION_DURATION) revert ExtensionTooShort();

        uint256 old = unlockTime;
        unlockTime = newUnlockTime;

        emit LockExtended(old, newUnlockTime);
    }

    /// @notice Withdraw all LP after unlock, to the fixed recipient.  Also claims and
    ///         forwards any accumulated Aerodrome trading fees in the same transaction.
    /// @dev Restricted to lpWithdrawRecipient to prevent adversarial force-withdrawal.
    ///      Fee claim and forwarding are best-effort: if any of `pool.claimFees()`,
    ///      `pool.token0()`, or `pool.token1()` reverts, the LP recovery still
    ///      proceeds (forwarding is skipped instead of bubbling the revert).
    ///      CEI: state writes precede the fee claim and LP transfer (which are
    ///      external interactions).  `nonReentrant` guards the full flow.
    function withdrawLp() external nonReentrant onlyLpWithdrawRecipient {
        // Ensure the lock has been started. Otherwise, `unlockTime` remains 0 and withdrawal would be
        // immediately possible, bypassing the intended time-lock.
        if (lockStartTime == 0) revert LockNotStarted();

        if (unlockTime == 0) {
            uint256 residual = IERC20(pool).balanceOf(address(this));
            if (residual == 0) revert AlreadyWithdrawn();
            // Claim and forward any accumulated trading fees attributed to the
            // residual LP balance before transferring the LP itself out.
            _claimAndForwardPoolFees();
            IERC20(pool).safeTransfer(lpWithdrawRecipient, residual);
            emit ResidualLpSwept(lpWithdrawRecipient, residual);
            return;
        }

        if (block.timestamp < unlockTime) revert UnlockTimeNotReached();

        uint256 amount = IERC20(pool).balanceOf(address(this));
        if (amount == 0) revert NoLp();

        // Preserve the original genesis snapshot for long-lived dashboards / historical analysis.
        // `lpLockedAmount` records the LP observed at startLock() time and should remain
        // readable even after the lock has been withdrawn.
        unlockTime = 0;

        // Claim 24 months of accumulated Aerodrome trading fees and forward both
        // fee tokens to the recipient before the LP transfer.  Aerodrome v2 routes
        // fees to per-LP-holder claimable slots separate from pool reserves, so
        // this on-vault claim path is the only way the recipient can recover them.
        _claimAndForwardPoolFees();

        IERC20(pool).safeTransfer(lpWithdrawRecipient, amount);
        emit WithdrawLp(lpWithdrawRecipient, amount);
    }

    /// @notice Rescue ETH force-sent to this vault (e.g. via selfdestruct).
    function rescueEth() external nonReentrant onlyLpWithdrawRecipient {
        uint256 balance = address(this).balance;
        if (balance == 0) revert NoTokenToRescue();
        (bool ok,) = lpWithdrawRecipient.call{value: balance}("");
        if (!ok) revert Errors.EthTransferFailed();
        emit TokenRescued(address(0), lpWithdrawRecipient, balance);
    }

    /// @dev Best-effort claim of Aerodrome `claimFees()` followed by forwarding of
    ///      both pool tokens (`token0`/`token1`) to `lpWithdrawRecipient`.  Reads
    ///      `pool.token0()` / `pool.token1()` dynamically (Aerodrome v2-immutable).
    ///      Bounded scope: the only tokens that can be moved by this helper are the
    ///      pool's two underlying tokens; the destination is fixed-immutable.  This
    ///      is NOT a generic sweep (see `docs/spec/vault-spec.md` "MUST NOT" scope).
    ///      All three external pool calls (`claimFees`, `token0`, `token1`) are
    ///      wrapped so that a misbehaving / non-conforming pool cannot DoS LP
    ///      recovery.  If `token0()` or `token1()` reverts the helper returns
    ///      early (no fee forwarding possible without identifying the tokens),
    ///      and `withdrawLp()`'s subsequent LP transfer still runs.
    function _claimAndForwardPoolFees() internal {
        try IAerodromePool(pool).claimFees() returns (
            uint256, uint256
        ) {
        // ok — claimable balances now sit on this vault as ERC20 balances.
        }
            catch {
            // Best-effort: continue with whatever balances are already settled
            // (could be zero).  LP recovery must not be blocked by a fee-claim
            // pathology.
        }
        address t0 = address(0);
        address t1 = address(0);
        try IAerodromePool(pool).token0() returns (address _t0) {
            t0 = _t0;
        } catch {
            // Pool does not expose token0() — cannot identify the fee token,
            // so skip forwarding entirely.  LP recovery still proceeds.
            return;
        }
        try IAerodromePool(pool).token1() returns (address _t1) {
            t1 = _t1;
        } catch {
            // Pool does not expose token1() — same reasoning as above.
            return;
        }
        uint256 b0 = IERC20(t0).balanceOf(address(this));
        uint256 b1 = IERC20(t1).balanceOf(address(this));
        if (b0 != 0) IERC20(t0).safeTransfer(lpWithdrawRecipient, b0);
        if (b1 != 0) IERC20(t1).safeTransfer(lpWithdrawRecipient, b1);
        if (b0 != 0 || b1 != 0) {
            emit FeesClaimedAndForwarded(t0, t1, b0, b1);
        }
    }
}
