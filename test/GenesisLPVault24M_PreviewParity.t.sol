// SPDX-License-Identifier: MIT
pragma solidity ^0.8.34;

import {Test} from "forge-std/Test.sol";

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {GenesisLPVault24M} from "src/vault/GenesisLPVault24M.sol";

import {MockERC20} from "./mocks/MockERC20.sol";

/// @notice Mock Aerodrome v2-style pool that exposes the
///         `token0`/`token1`/`claimFees` surface that
///         `GenesisLPVault24M._claimAndForwardPoolFees` requires. Mirrors the
///         `MockFeePool` defined inline in `GenesisLPVault24M_FeeClaim.t.sol`
///         so this parity-test file stays self-contained.
contract MockFeeForwardingPool is MockERC20 {
    address public token0;
    address public token1;

    uint256 public pendingClaim0;
    uint256 public pendingClaim1;
    bool public revertOnClaim;

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
        if (revertOnClaim) revert("MockFeeForwardingPool: claimFees reverted");

        uint256 c0 = pendingClaim0;
        uint256 c1 = pendingClaim1;
        pendingClaim0 = 0;
        pendingClaim1 = 0;

        if (c0 != 0) require(IERC20(token0).transfer(msg.sender, c0), "T0_XFER_FAIL");
        if (c1 != 0) require(IERC20(token1).transfer(msg.sender, c1), "T1_XFER_FAIL");
        return (c0, c1);
    }
}

/// @title GenesisLPVault24M wei-exact preview-vs-execute parity (item #10 from
///         the pre-mainnet readiness assessment).
/// @notice The vault has no `preview*` view of its own. The front-end reads
///         the vault's LP balance directly (`IERC20(pool).balanceOf(vault)`)
///         and the unlock time, then says "you will receive X LP plus any
///         claimable Aerodrome trading fees".
///
///         This file pins the wei-exact parity between that observable
///         pre-call state and what `withdrawLp()` actually moves to
///         `lpWithdrawRecipient`. Both the time-locked withdrawal and the
///         post-withdraw "residual sweep" branch are covered.
///
///         The fee-claim portion can only be predicted off-chain via
///         `eth_call`-style simulation -- the contract intentionally avoids
///         exposing a view that calls Aerodrome `claimFees()` because
///         `claimFees()` mutates state. The parity assertion here is that
///         *whatever* `MockAerodromePool.claimFees()` mints is forwarded
///         wei-exact to `lpWithdrawRecipient`. A mainnet UI that simulates
///         claimFees() before previewing should therefore not lie.
contract GenesisLPVault24MPreviewParityTest is Test {
    MockFeeForwardingPool internal pool;
    MockERC20 internal weth;
    MockERC20 internal claim;
    GenesisLPVault24M internal vault;

    // Resolved (token0, token1) in canonical sort order.
    address internal sortedToken0;
    address internal sortedToken1;

    address internal recipient = address(0xCAFE);

    function setUp() public {
        weth = new MockERC20("WETH", "WETH");
        claim = new MockERC20("CLAIM", "CLAIM");
        pool = new MockFeeForwardingPool(address(weth), address(claim));
        sortedToken0 = pool.token0();
        sortedToken1 = pool.token1();
        vault = new GenesisLPVault24M(address(pool), recipient);
    }

    // -----------------------------------------------------------------------
    // LP balance preview vs withdrawLp recipient receipt (post-unlock)
    // -----------------------------------------------------------------------

    function testFuzz_lpBalancePreviewEqualsRecipientReceiptPostUnlock(uint96 lpAmount_) public {
        uint256 lpAmount = bound(uint256(lpAmount_), vault.MIN_LP_LOCK(), 100_000_000e18);

        pool.mint(address(vault), lpAmount);
        vault.startLock();
        vm.warp(vault.unlockTime());

        // Frontend preview: simply IERC20(pool).balanceOf(vault).
        uint256 previewLp = pool.balanceOf(address(vault));
        assertEq(previewLp, lpAmount, "preview LP balance must equal seeded LP");

        uint256 recipBefore = pool.balanceOf(recipient);

        vm.prank(recipient);
        vault.withdrawLp();

        uint256 recipAfter = pool.balanceOf(recipient);
        assertEq(recipAfter - recipBefore, previewLp, "recipient LP delta must equal preview (wei-exact)");
        assertEq(pool.balanceOf(address(vault)), 0, "vault LP must be fully drained");
    }

    /// @notice Residual-sweep branch: withdrawLp() is called once to drain the
    ///         lock, then more LP is sent to the vault, and a SECOND withdrawLp
    ///         (taking the `unlockTime == 0` residual path) sweeps it. The
    ///         pre-call vault LP balance must equal the recipient delta exactly.
    function testFuzz_lpBalancePreviewEqualsRecipientReceiptResidualSweep(uint96 lockAmount_, uint96 residualAmount_)
        public
    {
        uint256 lockAmount = bound(uint256(lockAmount_), vault.MIN_LP_LOCK(), 50_000_000e18);
        uint256 residualAmount = bound(uint256(residualAmount_), 1, 50_000_000e18);

        pool.mint(address(vault), lockAmount);
        vault.startLock();
        vm.warp(vault.unlockTime());
        vm.prank(recipient);
        vault.withdrawLp();

        // Now seed residual LP after the lock has been retired.
        pool.mint(address(vault), residualAmount);

        uint256 previewLp = pool.balanceOf(address(vault));
        assertEq(previewLp, residualAmount, "preview must equal residual amount");

        uint256 recipBefore = pool.balanceOf(recipient);

        vm.prank(recipient);
        vault.withdrawLp();

        assertEq(
            pool.balanceOf(recipient) - recipBefore, previewLp, "residual sweep recipient delta must equal preview"
        );
        assertEq(pool.balanceOf(address(vault)), 0, "vault LP must be fully drained");
    }

    // -----------------------------------------------------------------------
    // Fee-claim forwarding parity
    // -----------------------------------------------------------------------

    /// @notice Whatever `claimFees()` mints to the vault during `withdrawLp()`
    ///         MUST be forwarded wei-exact to the recipient. This is the
    ///         "if a UI simulates claimFees() and shows the user X+Y fee
    ///         tokens, the user receives EXACTLY X+Y" guarantee.
    function testFuzz_feeClaimForwardingIsWeiExact(uint96 lpAmount_, uint96 fee0_, uint96 fee1_) public {
        uint256 lpAmount = bound(uint256(lpAmount_), vault.MIN_LP_LOCK(), 100_000_000e18);
        uint256 fee0 = bound(uint256(fee0_), 0, 100e18);
        uint256 fee1 = bound(uint256(fee1_), 0, 1_000_000e18);

        pool.mint(address(vault), lpAmount);
        vault.startLock();
        vm.warp(vault.unlockTime());

        // Pre-fund the pool with the fee tokens so claimFees() can transfer them.
        // This mirrors the on-chain reality where Aerodrome's claimable0/1 slots
        // are funded from accrued trading fees.
        if (fee0 != 0) MockERC20(sortedToken0).mint(address(pool), fee0);
        if (fee1 != 0) MockERC20(sortedToken1).mint(address(pool), fee1);
        pool.setPendingFees(fee0, fee1);

        uint256 recipToken0Before = IERC20(sortedToken0).balanceOf(recipient);
        uint256 recipToken1Before = IERC20(sortedToken1).balanceOf(recipient);
        uint256 recipLpBefore = pool.balanceOf(recipient);

        vm.prank(recipient);
        vault.withdrawLp();

        assertEq(
            IERC20(sortedToken0).balanceOf(recipient) - recipToken0Before,
            fee0,
            "token0 fee forwarding must be wei-exact"
        );
        assertEq(
            IERC20(sortedToken1).balanceOf(recipient) - recipToken1Before,
            fee1,
            "token1 fee forwarding must be wei-exact"
        );
        assertEq(pool.balanceOf(recipient) - recipLpBefore, lpAmount, "LP receipt must equal pre-call vault balance");

        // Vault must not retain any of the pool's two tokens after a complete withdraw.
        assertEq(IERC20(sortedToken0).balanceOf(address(vault)), 0, "vault must not retain token0 fees");
        assertEq(IERC20(sortedToken1).balanceOf(address(vault)), 0, "vault must not retain token1 fees");
        assertEq(pool.balanceOf(address(vault)), 0, "vault must be fully drained of LP");
    }

    /// @notice If `claimFees()` is misbehaving (reverts), the LP recovery path
    ///         MUST still deliver the LP balance exactly. Frontend can
    ///         conservatively show "LP only, fees N/A" in that scenario without
    ///         ever lying about the LP receipt.
    function testFuzz_lpReceiptIsCorrectEvenWhenClaimFeesReverts(uint96 lpAmount_) public {
        uint256 lpAmount = bound(uint256(lpAmount_), vault.MIN_LP_LOCK(), 100_000_000e18);

        pool.mint(address(vault), lpAmount);
        vault.startLock();
        vm.warp(vault.unlockTime());

        pool.setRevertOnClaim(true);

        uint256 previewLp = pool.balanceOf(address(vault));
        uint256 recipLpBefore = pool.balanceOf(recipient);

        vm.prank(recipient);
        vault.withdrawLp();

        assertEq(
            pool.balanceOf(recipient) - recipLpBefore,
            previewLp,
            "LP receipt must be wei-exact even on claimFees revert"
        );
    }
}
