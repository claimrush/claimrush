// SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

import {Errors} from "../lib/Errors.sol";
import {IDexAdapter} from "../interfaces/IDexAdapter.sol";
import {IGenesisLPVault24M} from "../interfaces/IGenesisLPVault24M.sol";
import {IMineCore} from "../interfaces/IMineCore.sol";
import {IAerodromePoolMint} from "../interfaces/IAerodromePoolMint.sol";
import {IAerodromePoolSkim} from "../interfaces/IAerodromePoolSkim.sol";
import {IPoolFactory} from "../interfaces/IPoolFactory.sol";
import {IWETH} from "../interfaces/IWETH.sol";

interface IMineCoreGenesisClaimView {
    function claim() external view returns (address);
}

interface IMineCoreGuardianRotation {
    function setGuardian(address _guardian) external;
}

/// @notice One-shot genesis finalization orchestrator (v1.0.0).
/// @dev Spec: docs/spec/launch-controller-spec-v1.0.0.md
contract LaunchController is ReentrancyGuard {
    using SafeERC20 for IERC20;

    // Events (MUST)

    event GenesisFinalized(
        uint256 timestamp,
        uint256 claimMinted,
        uint256 claimToLiquidity,
        uint256 lpMinted,
        address pool,
        address genesisLpVault
    );

    event TokenSwept(address indexed token, address indexed to, uint256 amount);

    event SkimFailed(address indexed pool, bytes reason);

    /// @dev Sweep call returned non-success. Sweep is best-effort so genesis
    ///      finalization completes even when a residual ERC20 misbehaves.
    event SweepFailed(address indexed token, bytes reason);

    event DeploymentValidated(
        address indexed claim, address indexed mineCore, address genesisLpVault, address guardian, address expectedPool
    );

    // Wiring + state (public immutables for transparency)

    /// @dev Pre-seed guard: the genesis pool MUST have zero LP supply.
    ///      Any stray token balances at the pool address are treated as donations and are skimmable.
    error PoolNotEmpty();

    /// @dev Skim failed and donated balances remain, which would skew the initial pool ratio.
    error PoolDonationRemains();

    address public immutable claim;
    address public immutable mineCore;
    address public immutable genesisLpVault;
    /// @dev Stores the DexAdapter-compatible router wrapper used for canonical
    ///      WETH/factory/pool derivation during genesis, not the raw Aerodrome router.
    address public immutable aerodromeRouter;
    address public immutable weth;
    /// @dev Canonical Aerodrome factory pinned at deployment; later router.defaultFactory() drift
    ///      is ignored during finalizeGenesis() so the bootstrap cannot be redirected silently.
    address public immutable factory;
    address public immutable expectedPool;
    /// @dev Only guardian can finalize genesis (one-shot operational action).
    address public immutable guardian;

    bool public genesisFinalized;

    // Transparency state (REQUIRED by v1.0.0 spec)
    uint256 public genesisFinalizedAt;
    uint256 public genesisClaimMinted;
    uint256 public genesisClaimToLiquidity;
    uint256 public genesisLpMinted;

    constructor(
        address _claim,
        address _mineCore,
        address _genesisLpVault,
        address _aerodromeRouter,
        address _guardian
    ) {
        if (
            _claim == address(0) || _mineCore == address(0) || _genesisLpVault == address(0)
                || _aerodromeRouter == address(0) || _guardian == address(0)
        ) revert Errors.ZeroAddress();

        // LaunchController is a one-shot immutable deployment that also becomes the temporary
        // MineCore guardian during genesis. Reject EOAs/malformed addresses up front so a bad
        // controller cannot be installed and then permanently lock the protocol's pre-genesis
        // guardian handoff.
        if (
            _claim.code.length == 0 || _mineCore.code.length == 0 || _genesisLpVault.code.length == 0
                || _aerodromeRouter.code.length == 0
        ) revert Errors.NotAContract();

        // Reject EIP-7702 delegation designators on every wiring root. A delegated EOA carries
        // exactly 23 bytes of code (`0xEF0100 || 20-byte target`) so the prior `code.length == 0`
        // check is bypassable by an EIP-7702 designator pointing at any contract. Wiring a
        // delegation designator at constructor time is non-recoverable on this one-shot deploy.
        _rejectDelegatedEOA(_claim);
        _rejectDelegatedEOA(_mineCore);
        _rejectDelegatedEOA(_genesisLpVault);
        _rejectDelegatedEOA(_aerodromeRouter);
        _rejectDelegatedEOA(_guardian);

        // Self-installation guard: the controller becomes the MineCore guardian during
        // finalizeGenesis() and rotates the role to `guardian` at the end. If `_guardian ==
        // address(this)` the rotation is a no-op and the protocol is permanently held by the
        // defunct controller. Reject up front.
        if (_guardian == address(this)) revert Errors.GenesisPoolMismatch();

        claim = _claim;
        mineCore = _mineCore;
        genesisLpVault = _genesisLpVault;
        // The constructor keeps the historical `_aerodromeRouter` name, but deployments
        // intentionally pass the DexAdapter wrapper so genesis routing stays pinned to the
        // adapter's canonical WETH/factory view.
        aerodromeRouter = _aerodromeRouter;
        guardian = _guardian;

        if (IMineCoreGenesisClaimView(_mineCore).claim() != _claim) revert Errors.WiringMismatch();

        address _weth = IDexAdapter(_aerodromeRouter).weth();
        address _factory = IDexAdapter(_aerodromeRouter).defaultFactory();
        if (_weth == address(0) || _factory == address(0)) revert Errors.ZeroAddress();
        if (_weth.code.length == 0 || _factory.code.length == 0) revert Errors.NotAContract();
        _rejectDelegatedEOA(_weth);
        _rejectDelegatedEOA(_factory);

        weth = _weth;
        factory = _factory;

        // Fail closed before this controller is handed the MineCore guardian role.
        // A malformed canonical pool derivation or a GenesisLPVault wired to the wrong pool
        // would otherwise only be detected during finalizeGenesis(), at which point the
        // pre-genesis contract guardian may already be locked in place.
        address pool = IDexAdapter(_aerodromeRouter).poolFor(_weth, _claim, false, _factory);
        if (pool == address(0) || IGenesisLPVault24M(_genesisLpVault).pool() != pool) {
            revert Errors.GenesisPoolMismatch();
        }
        // CREATE2 self-collision guard. The Aerodrome pool address is a deterministic CREATE2
        // derivation; if the predicted address coincides with this controller's address the
        // genesis seed transfers would silently route LP/CLAIM/WETH to the controller and
        // corrupt the initial pool ratio. Cosmic-ray-rare, defense-in-depth.
        if (pool == address(this)) revert Errors.GenesisPoolMismatch();
        expectedPool = pool;

        emit DeploymentValidated(_claim, _mineCore, _genesisLpVault, _guardian, pool);
    }

    uint256 internal constant MAINNET_GENESIS_SEED_ETH = 50 ether;
    uint256 internal constant MAINNET_GENESIS_DURATION = 10 days;

    /// @notice Finalize genesis exactly once.
    /// @dev Payable: seed ETH scales proportionally with GENESIS_ACCRUAL_DURATION.
    ///      Mainnet (10 days) requires exactly 50 ether; a 1-day testnet requires 5 ether.
    function finalizeGenesis() external payable nonReentrant {
        address sender = msg.sender;
        if (sender != guardian) revert Errors.NotAuthorized();
        // Defense-in-depth: the constructor rejects an EIP-7702 delegated `guardian`
        // at seat install time, but the controller is deployed before genesis closes.
        // Re-run the runtime guard at finalization time so the immutable seat cannot
        // be re-routed through a post-construction 7702 designator install.
        _rejectDelegatedEOA(sender);
        if (genesisFinalized) revert Errors.GenesisAlreadyFinalized();

        // Accrual window must be complete.
        uint256 duration = IMineCore(mineCore).GENESIS_ACCRUAL_DURATION();
        if (duration == 0) revert Errors.InvalidDuration();
        uint256 t0 = IMineCore(mineCore).emissionStartTime();
        if (t0 == 0) revert Errors.InvalidDuration();
        if (block.timestamp < t0 + duration) {
            revert Errors.GenesisAccrualWindowNotComplete();
        }

        // Exact seed ETH, scaled proportionally to genesis duration.
        uint256 requiredSeedEth = MAINNET_GENESIS_SEED_ETH * duration / MAINNET_GENESIS_DURATION;
        if (msg.value != requiredSeedEth) revert Errors.GenesisExactSeedRequired();

        // Must be paused until finalized.
        if (!IMineCore(mineCore).takeoversPaused()) revert Errors.GenesisMustBePaused();

        // Recommended wiring validation.
        if (IGenesisLPVault24M(genesisLpVault).pool() != expectedPool) revert Errors.GenesisPoolMismatch();

        // Re-read router wiring only to detect drift against the constructor-pinned roots.
        // The canonical pool factory remains the immutable `factory` captured at deployment;
        // later router.defaultFactory() changes are intentionally ignored.
        address wethNow = IDexAdapter(aerodromeRouter).weth();
        if (wethNow != weth) revert Errors.GenesisWethMismatch();
        if (expectedPool != IDexAdapter(aerodromeRouter).poolFor(weth, claim, false, factory)) {
            revert Errors.GenesisPoolMismatch();
        }

        // Pool pre-seed guard: the genesis pool MUST have zero LP supply.
        // Best-effort: skim any unexpected token balances (e.g. donations to the CREATE2 pool address)
        // to the guardian to avoid donation-based DoS and keep the seed ratio deterministic when possible.
        // CEI: mark one-shot state before any external interaction.
        genesisFinalized = true;

        _ensureEmptyOrSkim(expectedPool);

        // 1) Materialize genesis accrual into this contract.
        // slither-disable-next-line reentrancy-balance
        uint256 claimBefore = IERC20(claim).balanceOf(address(this));
        IMineCore(mineCore).collectGenesisKingClaim(address(this));
        uint256 claimMinted = IERC20(claim).balanceOf(address(this)) - claimBefore;

        // 2) Seed liquidity with exactly the CLAIM received from genesis materialization + the
        // proportional ETH seed. Controller-held CLAIM donations must NOT be folded into the canonical
        // genesis seed, otherwise a pre-launch sender can skew the initial pool ratio and the recorded
        // genesis accounting. Any residual donated CLAIM is swept to the guardian at the end of finalization.
        uint256 claimForLiquidity = claimMinted;
        if (claimForLiquidity == 0) revert Errors.GenesisNoClaimForLiquidity();

        address pool = IPoolFactory(factory).getPool(weth, claim, false);
        if (pool == address(0)) {
            pool = IPoolFactory(factory).createPool(weth, claim, false);
        }

        if (pool != expectedPool) revert Errors.GenesisPoolMismatch();
        // Runtime self-collision guard. Kept as a paired check with the constructor invariant
        // so any deploy-time mistake or reorg-induced address drift cannot fold the seed
        // transfers back into this controller.
        if (pool == address(this)) revert Errors.GenesisPoolMismatch();
        _ensureEmptyOrSkim(pool);

        IERC20(claim).safeTransfer(pool, claimForLiquidity);

        // `weth` is the immutable canonical Base WETH pinned at construction
        // and screened by `_rejectDelegatedEOA`; the recipient is a fixed
        // protocol component, not an attacker-controlled destination. The
        // detector cannot model immutables-as-constants.
        // slither-disable-next-line arbitrary-send-eth
        IWETH(weth).deposit{value: requiredSeedEth}();
        IERC20(weth).safeTransfer(pool, requiredSeedEth);

        uint256 lpMinted = IAerodromePoolMint(pool).mint(genesisLpVault);
        if (lpMinted == 0) revert Errors.GenesisLpMintFailed();
        if (IERC20(pool).balanceOf(genesisLpVault) < lpMinted) revert Errors.GenesisLpBalanceMismatch();

        // 3) Start LP lock.
        IGenesisLPVault24M(genesisLpVault).startLock();

        // 4) Activate the game.
        IMineCore(mineCore).setTakeoversPaused(false);

        // 5) Rotate MineCore guardian from this (defunct) controller to the operational guardian.
        IMineCoreGuardianRotation(mineCore).setGuardian(guardian);

        // Record transparency state.
        genesisFinalizedAt = block.timestamp;
        genesisClaimMinted = claimMinted;
        genesisClaimToLiquidity = claimForLiquidity;
        genesisLpMinted = lpMinted;

        // Best-effort sweep: avoid donation-based DoS on this one-shot contract.
        _sweepToken(claim);
        _sweepToken(weth);
        _sweepToken(pool);

        emit GenesisFinalized(block.timestamp, claimMinted, claimForLiquidity, lpMinted, pool, genesisLpVault);
    }

    /// @notice Read-only mirror of every `finalizeGenesis()` precondition.
    /// @dev Off-chain monitoring and operator runbooks call this to confirm that
    ///      finalization is ready before broadcasting the state-mutating call.
    ///      Each bit reads as `1` when the matching precondition holds. The
    ///      finalize call requires bits 0-10 set and `msg.value == requiredSeedEth`.
    /// @return statusBitmask Packed precondition bits (LSB first):
    ///   bit  0: !genesisFinalized
    ///   bit  1: GENESIS_ACCRUAL_DURATION > 0
    ///   bit  2: emissionStartTime > 0
    ///   bit  3: block.timestamp >= emissionStartTime + duration
    ///   bit  4: takeoversPaused == true
    ///   bit  5: genesisLpVault.pool() == expectedPool
    ///   bit  6: aerodromeRouter.weth() == weth
    ///   bit  7: aerodromeRouter.poolFor(weth, claim, false, factory) == expectedPool
    ///   bit  8: pool is undeployed or LP supply == 0
    ///   bit  9: pool token balances are zero or removable before mint
    ///   bit 10: expectedPool != address(this) (CREATE2 self-collision guard)
    /// @return requiredSeedEth The exact `msg.value` finalizeGenesis() requires now.
    function preflight() external view returns (uint256 statusBitmask, uint256 requiredSeedEth) {
        uint256 bits = 0;

        if (!genesisFinalized) bits |= 1 << 0;

        uint256 duration = IMineCore(mineCore).GENESIS_ACCRUAL_DURATION();
        if (duration > 0) bits |= 1 << 1;

        uint256 t0 = IMineCore(mineCore).emissionStartTime();
        if (t0 > 0) bits |= 1 << 2;

        if (duration > 0 && t0 > 0 && block.timestamp >= t0 + duration) bits |= 1 << 3;

        if (IMineCore(mineCore).takeoversPaused()) bits |= 1 << 4;

        if (IGenesisLPVault24M(genesisLpVault).pool() == expectedPool) bits |= 1 << 5;

        if (IDexAdapter(aerodromeRouter).weth() == weth) bits |= 1 << 6;

        if (IDexAdapter(aerodromeRouter).poolFor(weth, claim, false, factory) == expectedPool) {
            bits |= 1 << 7;
        }

        bool poolHasCode = expectedPool.code.length != 0;
        bool poolSupplyEmpty = !poolHasCode || IERC20(expectedPool).totalSupply() == 0;
        if (poolSupplyEmpty) bits |= 1 << 8;

        uint256 poolWethBalance = IERC20(weth).balanceOf(expectedPool);
        uint256 poolClaimBalance = IERC20(claim).balanceOf(expectedPool);
        if (poolWethBalance == 0 && poolClaimBalance == 0) {
            bits |= 1 << 9;
        } else if (poolSupplyEmpty) {
            // A zero-supply pool can clear stray WETH/CLAIM via skim before minting.
            // If the pool is not deployed yet, finalization creates it before the skim check.
            bits |= 1 << 9;
        }

        if (expectedPool != address(this)) bits |= 1 << 10;

        statusBitmask = bits;
        requiredSeedEth = MAINNET_GENESIS_SEED_ETH * duration / MAINNET_GENESIS_DURATION;
    }

    // Internal helpers

    /// @dev Ensure the pool has no LP supply (no pre-seeded liquidity). Skim any stray token
    ///      balances to the guardian to avoid donation-based DoS on deterministic pool addresses.
    ///      Reverts if material balances remain after the skim attempt, to prevent donated tokens
    ///      from skewing the initial pool ratio.
    function _ensureEmptyOrSkim(address pool) internal {
        if (pool.code.length == 0) return;

        // Any LP supply means someone has already seeded liquidity, which can set an arbitrary starting price.
        if (IERC20(pool).totalSupply() != 0) revert PoolNotEmpty();

        // Skim unexpected balances (donations) so the genesis seed uses only protocol-provided amounts.
        uint256 balWeth = IERC20(weth).balanceOf(pool);
        uint256 balClaim = IERC20(claim).balanceOf(pool);
        if (balWeth != 0 || balClaim != 0) {
            // Aerodrome pools expose `skim(address)` to transfer balances in excess of reserves.
            try IAerodromePoolSkim(pool).skim(guardian) {
            // ok
            }
            catch {
                emit SkimFailed(pool, _boundedRevertData());
            }

            // Post-skim guard: if material balances remain, the initial ratio could be skewed.
            // Revert so the guardian can address the donation before retrying.
            uint256 remainWeth = IERC20(weth).balanceOf(pool);
            uint256 remainClaim = IERC20(claim).balanceOf(pool);
            if (remainWeth != 0 || remainClaim != 0) revert PoolDonationRemains();
        }
    }

    /// @dev Cap returndata to 128 bytes before allocating memory, matching the
    ///      MineCore._boundedRevertData() convention.  Prevents unbounded memory
    ///      expansion from malicious revert payloads.
    function _boundedRevertData() private pure returns (bytes memory bounded) {
        assembly ("memory-safe") {
            let rdSize := returndatasize()
            let copyLen := rdSize
            if gt(copyLen, 128) { copyLen := 128 }
            bounded := mload(0x40)
            mstore(bounded, copyLen)
            returndatacopy(add(bounded, 0x20), 0, copyLen)
            mstore(0x40, add(add(bounded, 0x20), and(add(copyLen, 31), not(31))))
        }
    }

    /// @dev Sweep an ERC20 token balance from this controller to the guardian.
    ///      Best-effort: a misbehaving token (revert on transfer, returns false, returns
    ///      malformed payload) emits `SweepFailed` and finalization continues. The sweep runs
    ///      after `genesisFinalized = true` and the MineCore guardian rotation, so a sweep
    ///      revert would otherwise unwind the entire one-shot genesis.
    function _sweepToken(address token) internal {
        // Read balance defensively. A token whose `balanceOf` reverts cannot be swept; emit
        // and continue.
        uint256 bal;
        (bool okBal, bytes memory rdBal) = token.staticcall(abi.encodeCall(IERC20.balanceOf, (address(this))));
        if (!okBal || rdBal.length < 32) {
            emit SweepFailed(token, _boundBytes(rdBal));
            return;
        }
        bal = abi.decode(rdBal, (uint256));
        if (bal == 0) return;

        (bool ok, bytes memory rd) = token.call(abi.encodeCall(IERC20.transfer, (guardian, bal)));
        if (!ok) {
            emit SweepFailed(token, _boundBytes(rd));
            return;
        }
        // SafeERC20-style success-flag check for tokens that return `bool` instead of reverting.
        if (rd.length != 0) {
            if (rd.length < 32) {
                emit SweepFailed(token, rd);
                return;
            }
            if (!abi.decode(rd, (bool))) {
                emit SweepFailed(token, rd);
                return;
            }
        }
        emit TokenSwept(token, guardian, bal);
    }

    /// @dev Reject EIP-7702 delegation designators on permanent wiring roots.
    ///      A delegated EOA carries exactly 23 bytes of code: `0xEF0100 || target20`.
    ///      Mirrors [src/ClaimAllHelper.sol::_rejectDelegatedEOA](../ClaimAllHelper.sol).
    function _rejectDelegatedEOA(address addr) internal view {
        if (addr.code.length != 23) return;
        bytes32 head;
        assembly ("memory-safe") {
            let ptr := mload(0x40)
            extcodecopy(addr, ptr, 0, 3)
            head := mload(ptr)
        }
        if (uint256(head) >> 232 == 0xEF0100) revert Errors.DelegatedEOA();
    }

    /// @dev Bound an arbitrary bytes payload to 128 bytes for event emission, matching the
    ///      `_boundedRevertData()` post-call convention but for already-captured memory.
    function _boundBytes(bytes memory data) internal pure returns (bytes memory bounded) {
        if (data.length <= 128) return data;
        bounded = new bytes(128);
        assembly ("memory-safe") {
            let src := add(data, 0x20)
            let dst := add(bounded, 0x20)
            mstore(dst, mload(src))
            mstore(add(dst, 0x20), mload(add(src, 0x20)))
            mstore(add(dst, 0x40), mload(add(src, 0x40)))
            mstore(add(dst, 0x60), mload(add(src, 0x60)))
        }
    }
}
