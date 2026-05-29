// SPDX-License-Identifier: MIT
pragma solidity ^0.8.34;

import {Test} from "forge-std/Test.sol";
import {Vm} from "forge-std/Vm.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {GenesisLPVault24M} from "src/vault/GenesisLPVault24M.sol";

import {MockERC20} from "./mocks/MockERC20.sol";

/// @notice Mock Aerodrome v2-style pool that doubles as the LP token and exposes
///         a controllable fee-claim surface for unit testing
///         `GenesisLPVault24M.withdrawLp()` fee forwarding.
/// @dev Behavior knobs:
///      - `setPendingFees(...)` queues amounts to pay out on the next
///        `claimFees()` call.  The pool transfers those amounts from its own
///        balance (pre-funded by the test) to the caller, mirroring how
///        Aerodrome v2 pays out from `claimable0/1` slots.
///      - `setRevertOnClaim(true)` flips `claimFees()` into reverting, used to
///        exercise the vault's best-effort try/catch.
contract MockFeePool is MockERC20 {
    address public token0;
    address public token1;

    uint256 public pendingClaim0;
    uint256 public pendingClaim1;
    bool public revertOnClaim;
    uint256 public claimFeesCallCount;

    constructor(address _token0, address _token1) MockERC20("PoolLP", "PLP") {
        require(_token0 != address(0) && _token1 != address(0), "ZERO_TOKEN");
        require(_token0 != _token1, "SAME_TOKEN");
        (address a, address b) = _token0 < _token1 ? (_token0, _token1) : (_token1, _token0);
        token0 = a;
        token1 = b;
    }

    function setPendingFees(uint256 amount0, uint256 amount1) external {
        pendingClaim0 = amount0;
        pendingClaim1 = amount1;
    }

    function setRevertOnClaim(bool v) external {
        revertOnClaim = v;
    }

    function claimFees() external returns (uint256, uint256) {
        claimFeesCallCount += 1;
        if (revertOnClaim) revert("MockFeePool: claimFees reverted");

        uint256 c0 = pendingClaim0;
        uint256 c1 = pendingClaim1;
        pendingClaim0 = 0;
        pendingClaim1 = 0;

        if (c0 != 0) {
            require(IERC20(token0).transfer(msg.sender, c0), "T0_XFER_FAIL");
        }
        if (c1 != 0) {
            require(IERC20(token1).transfer(msg.sender, c1), "T1_XFER_FAIL");
        }
        return (c0, c1);
    }
}

/// @notice Unit tests for the `withdrawLp()` fee-claim-and-forward path added in
///         the next broadcast SHA.  See `docs/dev/internal/VALUE_FLOW_AUDIT_2026-05.md`
///         and the plan `genesis-lp-fee-claim-fix` for context.
contract GenesisLPVault24MFeeClaimTest is Test {
    MockERC20 internal weth;
    MockERC20 internal claim;
    MockFeePool internal pool;
    GenesisLPVault24M internal vault;

    address internal recipient = address(0xCAFE);
    address internal alice = address(0xA);

    uint256 internal constant LP_AMOUNT = 50e18;
    uint256 internal constant FEE0 = 3e18;
    uint256 internal constant FEE1 = 7e18;

    event FeesClaimedAndForwarded(
        address indexed token0, address indexed token1, uint256 amount0Forwarded, uint256 amount1Forwarded
    );

    function setUp() public {
        weth = new MockERC20("WETH", "WETH");
        claim = new MockERC20("CLAIM", "CLAIM");
        pool = new MockFeePool(address(weth), address(claim));
        vault = new GenesisLPVault24M(address(pool), recipient);
    }

    /// @dev Pre-fund the pool with token reserves so `claimFees()` has something
    ///      to transfer out, then queue per-token fee amounts.
    function _seedFees(uint256 amount0, uint256 amount1) internal {
        if (amount0 != 0) MockERC20(pool.token0()).mint(address(pool), amount0);
        if (amount1 != 0) MockERC20(pool.token1()).mint(address(pool), amount1);
        pool.setPendingFees(amount0, amount1);
    }

    function _startLockAndWarpToUnlock() internal {
        pool.mint(address(vault), LP_AMOUNT);
        vault.startLock();
        vm.warp(vault.unlockTime());
    }

    // -----------------------------------------------------------------
    // 1. withdrawLp claims AND forwards both fee tokens.
    // -----------------------------------------------------------------

    function test_withdrawLp_claimsAndForwardsBothTokens() public {
        _startLockAndWarpToUnlock();
        _seedFees(FEE0, FEE1);

        address t0 = pool.token0();
        address t1 = pool.token1();

        uint256 r0Before = IERC20(t0).balanceOf(recipient);
        uint256 r1Before = IERC20(t1).balanceOf(recipient);

        vm.expectEmit(true, true, false, true, address(vault));
        emit FeesClaimedAndForwarded(t0, t1, FEE0, FEE1);

        vm.prank(recipient);
        vault.withdrawLp();

        assertEq(pool.claimFeesCallCount(), 1, "claimFees called once");
        assertEq(IERC20(t0).balanceOf(recipient) - r0Before, FEE0, "recipient got fee0");
        assertEq(IERC20(t1).balanceOf(recipient) - r1Before, FEE1, "recipient got fee1");
        assertEq(pool.balanceOf(recipient), LP_AMOUNT, "recipient got all LP");
        assertEq(IERC20(t0).balanceOf(address(vault)), 0, "vault drained of fee0");
        assertEq(IERC20(t1).balanceOf(address(vault)), 0, "vault drained of fee1");
    }

    // -----------------------------------------------------------------
    // 2. Zero accumulated fees => no fee event, LP still transfers.
    // -----------------------------------------------------------------

    function test_withdrawLp_handlesZeroFees() public {
        _startLockAndWarpToUnlock();
        // No fees seeded.

        vm.recordLogs();

        vm.prank(recipient);
        vault.withdrawLp();

        assertEq(pool.claimFeesCallCount(), 1, "claimFees still called");
        assertEq(pool.balanceOf(recipient), LP_AMOUNT, "LP still transferred");

        // Confirm no FeesClaimedAndForwarded event was emitted.
        bytes32 sig = keccak256("FeesClaimedAndForwarded(address,address,uint256,uint256)");
        Vm.Log[] memory logs = vm.getRecordedLogs();
        for (uint256 i = 0; i < logs.length; ++i) {
            if (logs[i].emitter == address(vault)) {
                assertTrue(logs[i].topics[0] != sig, "no fees event when zero fees");
            }
        }
    }

    // -----------------------------------------------------------------
    // 3. Pool-side `claimFees()` revert must NOT block LP recovery.
    // -----------------------------------------------------------------

    function test_withdrawLp_handlesPoolClaimFeesRevert() public {
        _startLockAndWarpToUnlock();
        pool.setRevertOnClaim(true);

        // `vm.expectCall` records the expectation outside the failing sub-call's
        // frame, which is the correct way to assert "claimFees was attempted"
        // when the call itself reverts (any state change inside the reverted
        // frame — including `claimFeesCallCount += 1` — is rolled back).
        vm.expectCall(address(pool), abi.encodeWithSelector(MockFeePool.claimFees.selector));

        vm.prank(recipient);
        vault.withdrawLp();

        assertEq(pool.balanceOf(recipient), LP_AMOUNT, "LP still transferred");
        // No fee tokens move because the pool reverted before paying out.
        assertEq(IERC20(pool.token0()).balanceOf(recipient), 0, "no fee0 forwarded on revert");
        assertEq(IERC20(pool.token1()).balanceOf(recipient), 0, "no fee1 forwarded on revert");
        // Sanity check: the counter is back at 0 because the increment was
        // reverted along with the rest of the call frame.
        assertEq(pool.claimFeesCallCount(), 0, "counter rolled back with revert");
    }

    // -----------------------------------------------------------------
    // 4. Residual-LP branch (PostWithdraw, unlockTime == 0) also claims.
    // -----------------------------------------------------------------

    function test_withdrawLp_residualBranchAlsoClaims() public {
        // Drive vault into PostWithdraw state: lock started, fully withdrawn,
        // then someone donates more LP into the empty vault.
        _startLockAndWarpToUnlock();
        vm.prank(recipient);
        vault.withdrawLp();
        assertEq(vault.unlockTime(), 0, "unlockTime cleared after first withdraw");
        assertEq(pool.balanceOf(address(vault)), 0, "vault empty after first withdraw");

        // Donate residual LP and accrue fresh fees against the vault's address.
        uint256 residual = 5e18;
        pool.mint(address(vault), residual);
        _seedFees(FEE0, FEE1);

        address t0 = pool.token0();
        address t1 = pool.token1();
        uint256 r0Before = IERC20(t0).balanceOf(recipient);
        uint256 r1Before = IERC20(t1).balanceOf(recipient);
        uint256 lpBefore = pool.balanceOf(recipient);

        vm.expectEmit(true, true, false, true, address(vault));
        emit FeesClaimedAndForwarded(t0, t1, FEE0, FEE1);

        vm.prank(recipient);
        vault.withdrawLp();

        assertEq(pool.claimFeesCallCount(), 2, "claimFees called in residual branch too");
        assertEq(IERC20(t0).balanceOf(recipient) - r0Before, FEE0, "residual: recipient got fee0");
        assertEq(IERC20(t1).balanceOf(recipient) - r1Before, FEE1, "residual: recipient got fee1");
        assertEq(pool.balanceOf(recipient) - lpBefore, residual, "residual LP forwarded");
    }

    // -----------------------------------------------------------------
    // 5. Atomicity: fees and LP land in the same transaction.
    // -----------------------------------------------------------------

    function test_withdrawLp_feesAndLpForwardedAtomically() public {
        _startLockAndWarpToUnlock();
        _seedFees(FEE0, FEE1);

        address t0 = pool.token0();
        address t1 = pool.token1();

        // Capture the sequence of events emitted during the single withdrawLp tx.
        vm.recordLogs();

        vm.prank(recipient);
        vault.withdrawLp();

        Vm.Log[] memory logs = vm.getRecordedLogs();

        bytes32 feesSig = keccak256("FeesClaimedAndForwarded(address,address,uint256,uint256)");
        bytes32 withdrawSig = keccak256("WithdrawLp(address,uint256)");

        int256 feesIdx = -1;
        int256 withdrawIdx = -1;
        for (uint256 i = 0; i < logs.length; ++i) {
            if (logs[i].emitter != address(vault)) continue;
            if (logs[i].topics[0] == feesSig && feesIdx == -1) feesIdx = int256(i);
            if (logs[i].topics[0] == withdrawSig && withdrawIdx == -1) withdrawIdx = int256(i);
        }

        assertGe(feesIdx, int256(0), "fees event present in same tx");
        assertGe(withdrawIdx, int256(0), "withdraw event present in same tx");
        assertLt(feesIdx, withdrawIdx, "fees event precedes WithdrawLp event");

        // Final-state cross-check.
        assertEq(IERC20(t0).balanceOf(recipient), FEE0, "atomic: fee0 landed");
        assertEq(IERC20(t1).balanceOf(recipient), FEE1, "atomic: fee1 landed");
        assertEq(pool.balanceOf(recipient), LP_AMOUNT, "atomic: LP landed");
    }

    // -----------------------------------------------------------------
    // 6. Access control unchanged: non-recipient still reverts BEFORE any claim.
    // -----------------------------------------------------------------

    function test_withdrawLp_revertsOnNonRecipient() public {
        _startLockAndWarpToUnlock();
        _seedFees(FEE0, FEE1);

        vm.prank(alice);
        vm.expectRevert(GenesisLPVault24M.OnlyLpWithdrawRecipient.selector);
        vault.withdrawLp();

        // Pool's claimFees was NEVER touched on the rejected path.
        assertEq(pool.claimFeesCallCount(), 0, "no claim attempt on rejected call");
        assertEq(IERC20(pool.token0()).balanceOf(address(vault)), 0, "vault still empty fee0");
        assertEq(IERC20(pool.token1()).balanceOf(address(vault)), 0, "vault still empty fee1");
    }

    // -----------------------------------------------------------------
    // 7. Lock enforcement unchanged: pre-unlock revert still fires BEFORE any claim.
    // -----------------------------------------------------------------

    function test_withdrawLp_lockEnforcementUnchanged() public {
        pool.mint(address(vault), LP_AMOUNT);
        vault.startLock();
        _seedFees(FEE0, FEE1);

        // 1 second before unlock — must still revert.
        vm.warp(vault.unlockTime() - 1);
        vm.prank(recipient);
        vm.expectRevert(GenesisLPVault24M.UnlockTimeNotReached.selector);
        vault.withdrawLp();

        assertEq(pool.claimFeesCallCount(), 0, "no claim attempt before unlock");
    }

    // -----------------------------------------------------------------
    // 8. Defensive: a "pool" that does not expose token0()/token1()/claimFees()
    //    selectors at all (e.g. a vanilla ERC20 wired in by a deployer mistake
    //    or used as the pool in legacy fixtures) MUST NOT block LP recovery.
    //    This is the regression guard for ~30 existing GenesisLPVault24M*.t.sol
    //    tests that pass a plain MockERC20 as the pool and rely on `withdrawLp()`
    //    succeeding.
    // -----------------------------------------------------------------

    function test_withdrawLp_handlesMissingPoolSelectors() public {
        // Stand up a *fresh* vault wired to a plain MockERC20 — no claimFees,
        // no token0, no token1.  Mirrors the earlier unit-test setup pattern.
        MockERC20 plain = new MockERC20("LP", "LP");
        GenesisLPVault24M plainVault = new GenesisLPVault24M(address(plain), recipient);
        plain.mint(address(plainVault), LP_AMOUNT);
        plainVault.startLock();
        vm.warp(plainVault.unlockTime());

        vm.prank(recipient);
        plainVault.withdrawLp();

        assertEq(plain.balanceOf(recipient), LP_AMOUNT, "LP recovered despite missing selectors");
        assertEq(plain.balanceOf(address(plainVault)), 0, "vault drained");
    }
}
