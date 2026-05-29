// SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

import {IDexAdapter} from "src/interfaces/IDexAdapter.sol";
import {IPoolFactory} from "src/interfaces/IPoolFactory.sol";
import {IAerodromePool} from "src/interfaces/IAerodromePool.sol";
import {IAerodromePoolMint} from "src/interfaces/IAerodromePoolMint.sol";
import {IAerodromePoolSkim} from "src/interfaces/IAerodromePoolSkim.sol";
import {IWETH} from "src/interfaces/IWETH.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

import {GenesisLPVault24M} from "src/vault/GenesisLPVault24M.sol";

import {AerodromeForkBase} from "./AerodromeForkBase.t.sol";

contract AerodromePoolForkTest is AerodromeForkBase {
    using SafeERC20 for IERC20;
    uint256 internal constant SEED_WETH = 50 ether;
    uint256 internal constant SEED_CLAIM = 500_000e18;

    function setUp() public override {
        super.setUp();
    }

    // --- mint ---

    function test_mint_returnsGeometricMean() public {
        uint256 wethAmount = 10 ether;
        uint256 claimAmount = 100_000e18;

        _dealWeth(address(this), wethAmount);
        _dealClaim(address(this), claimAmount);

        IERC20(WETH).safeTransfer(pool, wethAmount);
        IERC20(address(claimToken)).safeTransfer(pool, claimAmount);

        uint256 lpMinted = IAerodromePoolMint(pool).mint(alice);

        // First mint: LP = sqrt(weth * claim) - MINIMUM_LIQUIDITY
        // Aerodrome volatile pool uses the geometric mean for initial liquidity
        uint256 expectedApprox = Math.sqrt(wethAmount * claimAmount);
        assertGt(lpMinted, 0, "LP minted > 0");
        // Allow for MINIMUM_LIQUIDITY (1000 wei) deduction on first mint
        assertApproxEqRel(lpMinted, expectedApprox, 0.01e18, "LP ~ sqrt(weth*claim)");
        assertEq(IERC20(pool).balanceOf(alice), lpMinted, "alice received LP");
    }

    function test_mint_secondDepositorProportional() public {
        _seedPool(SEED_WETH, SEED_CLAIM);
        uint256 totalLpAfterSeed = IERC20(pool).totalSupply();

        uint256 addWeth = 5 ether;
        uint256 addClaim = 50_000e18;

        _dealWeth(address(this), addWeth);
        _dealClaim(address(this), addClaim);

        IERC20(WETH).safeTransfer(pool, addWeth);
        IERC20(address(claimToken)).safeTransfer(pool, addClaim);

        uint256 lpMinted = IAerodromePoolMint(pool).mint(bob);
        assertGt(lpMinted, 0, "second deposit mints LP");

        // Second depositor should get ~10% of supply (adding 10% more of each token)
        uint256 expectedFraction = (totalLpAfterSeed * addWeth) / SEED_WETH;
        assertApproxEqRel(lpMinted, expectedFraction, 0.01e18, "proportional LP mint");
    }

    // --- claimFees ---

    function test_claimFees_returnsRealFeesAfterSwaps() public {
        _seedPool(SEED_WETH, SEED_CLAIM);

        // LP holder must be the one calling claimFees (fees accrue to LP holders)
        uint256 lpBal = IERC20(pool).balanceOf(address(this));
        assertGt(lpBal, 0, "test contract holds LP");

        // Generate trading volume
        _generateTradingFees(5, 1 ether);

        // Claim fees
        (uint256 claimed0, uint256 claimed1) = IAerodromePool(pool).claimFees();

        // At least one of the fee amounts should be non-zero after trading
        assertTrue(claimed0 > 0 || claimed1 > 0, "claimFees returned non-zero fees after trading");
    }

    function test_claimFees_zeroBeforeTrading() public {
        _seedPool(SEED_WETH, SEED_CLAIM);

        (uint256 claimed0, uint256 claimed1) = IAerodromePool(pool).claimFees();
        assertEq(claimed0, 0, "no fees before trading (token0)");
        assertEq(claimed1, 0, "no fees before trading (token1)");
    }

    // --- skim ---

    function test_skim_removesExcessTokens() public {
        _seedPool(SEED_WETH, SEED_CLAIM);

        // Donate extra tokens directly to the pool (simulating a donation attack)
        uint256 donateWeth = 1 ether;
        uint256 donateClaim = 10_000e18;
        _dealWeth(pool, donateWeth);
        _dealClaim(pool, donateClaim);

        uint256 wethBeforeSkim = IERC20(WETH).balanceOf(pool);
        uint256 claimBeforeSkim = claimToken.balanceOf(pool);

        // Skim excess to bob
        IAerodromePoolSkim(pool).skim(bob);

        uint256 wethAfterSkim = IERC20(WETH).balanceOf(pool);
        uint256 claimAfterSkim = claimToken.balanceOf(pool);

        // Pool balances should decrease (excess removed)
        assertLt(wethAfterSkim, wethBeforeSkim, "WETH decreased after skim");
        assertLt(claimAfterSkim, claimBeforeSkim, "CLAIM decreased after skim");

        // Bob should have received the excess
        assertGt(IERC20(WETH).balanceOf(bob), 0, "bob received WETH from skim");
        assertGt(claimToken.balanceOf(bob), 0, "bob received CLAIM from skim");

        // Crucially: skim does NOT empty the pool (only removes excess over reserves)
        assertGt(wethAfterSkim, 0, "pool still has WETH reserves");
        assertGt(claimAfterSkim, 0, "pool still has CLAIM reserves");
    }

    function test_skim_noExcessIsNoop() public {
        _seedPool(SEED_WETH, SEED_CLAIM);

        uint256 wethBefore = IERC20(WETH).balanceOf(pool);
        uint256 claimBefore = claimToken.balanceOf(pool);

        IAerodromePoolSkim(pool).skim(bob);

        assertEq(IERC20(WETH).balanceOf(pool), wethBefore, "no change when no excess");
        assertEq(claimToken.balanceOf(pool), claimBefore, "no change when no excess");
        assertEq(IERC20(WETH).balanceOf(bob), 0, "bob got nothing");
    }

    // --- Pool type ---

    function test_poolIsVolatile() public view {
        // Verify pool was created with stable=false (volatile)
        address fromFactory = IPoolFactory(AERODROME_FACTORY).getPool(WETH, address(claimToken), false);
        assertEq(fromFactory, pool, "pool is volatile (stable=false)");

        // A stable pool for the same pair should not exist
        address stablePool = IPoolFactory(AERODROME_FACTORY).getPool(WETH, address(claimToken), true);
        assertEq(stablePool, address(0), "no stable pool exists");
    }

    // --- GenesisLPVault24M.withdrawLp() — fee claim + forward end-to-end ---

    /// @notice End-to-end on real Aerodrome: seed the pool with the vault as the
    ///         LP recipient (mirroring how `LaunchController.finalizeGenesis()`
    ///         materializes genesis LP), accrue trading fees, warp past the
    ///         24-month unlock, and verify `withdrawLp()` lands BOTH the LP and
    ///         the accumulated WETH+CLAIM fees in the same transaction.
    /// @dev Regression coverage for the stranded-fee class fixed in the next
    ///      broadcast SHA — see `docs/dev/internal/VALUE_FLOW_AUDIT_2026-05.md`.
    function test_genesisLpVault_withdrawLp_claimsAndForwardsFees() public {
        address recipient = makeAddr("genesisLpRecipient");
        GenesisLPVault24M vault = new GenesisLPVault24M(pool, recipient);

        uint256 lpMinted = _seedPoolTo(SEED_WETH, SEED_CLAIM, address(vault));
        assertGt(lpMinted, 0, "vault holds genesis LP");
        assertEq(IERC20(pool).balanceOf(address(vault)), lpMinted, "vault LP balance == minted");

        vault.startLock();
        assertEq(vault.lpLockedAmount(), lpMinted, "lpLockedAmount snapshots minted LP");

        _generateTradingFees(5, 1 ether);

        vm.warp(vault.unlockTime());

        uint256 wethRecipBefore = IERC20(WETH).balanceOf(recipient);
        uint256 claimRecipBefore = claimToken.balanceOf(recipient);
        uint256 lpRecipBefore = IERC20(pool).balanceOf(recipient);

        vm.prank(recipient);
        vault.withdrawLp();

        // LP transferred in full.
        assertEq(IERC20(pool).balanceOf(recipient) - lpRecipBefore, lpMinted, "recipient received full genesis LP");
        assertEq(IERC20(pool).balanceOf(address(vault)), 0, "vault drained of LP");

        // At least one fee token forwarded (Aerodrome v2 fees split across both
        // sides after round-trip swaps; both should be non-zero in practice).
        uint256 wethDelta = IERC20(WETH).balanceOf(recipient) - wethRecipBefore;
        uint256 claimDelta = claimToken.balanceOf(recipient) - claimRecipBefore;
        assertTrue(wethDelta > 0 || claimDelta > 0, "recipient received non-zero accumulated trading fees");

        // Vault must NOT retain any fee-token balance after the forward.
        assertEq(IERC20(WETH).balanceOf(address(vault)), 0, "vault drained of WETH");
        assertEq(claimToken.balanceOf(address(vault)), 0, "vault drained of CLAIM");
    }
}
