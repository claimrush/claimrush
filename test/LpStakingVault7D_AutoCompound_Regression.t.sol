// SPDX-License-Identifier: MIT
pragma solidity ^0.8.34;

import {Test} from "forge-std/Test.sol";

import {LpStakingVault7D} from "src/vault/LpStakingVault7D.sol";
import {Constants} from "src/lib/Constants.sol";
import {Events} from "src/lib/Events.sol";
import {Errors} from "src/lib/Errors.sol";

import {MockERC20} from "./mocks/MockERC20.sol";
import {MockAerodromePool} from "./mocks/MockAerodromePool.sol";
import {MockAerodromeRouter} from "./mocks/MockAerodromeRouter.sol";
import {MockFurnaceLpRewards} from "./mocks/MockFurnaceLpRewards.sol";
import {MockVe} from "./mocks/MockVe.sol";

/// @title Auto-compound and cooldown edge-case tests.
/// @dev Covers:
///   1. Compound cooldown (compoundFor returns no-op, no pause within MIN_COMPOUND_INTERVAL)
///   2. MIN_COMPOUND_REWARD threshold (compoundFor returns no-op, no pause when reward < 1e15)
///   3. claimRewardsAndLock cooldown (LockCooldown revert within MIN_COMPOUND_INTERVAL)
///   4. compoundFor skips zero-address user
///   5. compoundFor skips disabled config
contract LpStakingVault7D_AutoCompound_RegressionTest is Test {
    MockAerodromePool internal lp;
    MockERC20 internal weth;
    MockERC20 internal claim;
    MockFurnaceLpRewards internal furnace;
    MockVe internal ve;
    MockAerodromeRouter internal router;
    LpStakingVault7D internal vault;

    address internal factory = address(0xFACA);
    address internal alice = address(0xA11CE);
    address internal keeper = address(0xBEEF);

    function setUp() public {
        weth = new MockERC20("WETH", "WETH");
        claim = new MockERC20("CLAIM", "CLAIM");
        lp = new MockAerodromePool(address(weth), address(claim));
        ve = new MockVe();
        router = new MockAerodromeRouter(factory, address(weth));
        router.setPoolFor(address(weth), address(claim), false, factory, address(lp));
        furnace = new MockFurnaceLpRewards(address(claim), address(ve));

        vault = new LpStakingVault7D(
            address(lp),
            address(weth),
            address(claim),
            address(ve),
            address(furnace),
            address(router),
            factory,
            false,
            address(this)
        );

        vault.setHarvestKeeper(keeper, true);
    }

    function _stakeAlice(uint256 amount) internal {
        lp.mint(alice, amount);
        vm.startPrank(alice);
        lp.approve(address(vault), type(uint256).max);
        vault.stake(amount);
        vm.stopPrank();
    }

    function _fundRewards(uint256 amount) internal {
        claim.mint(address(vault), amount);
        vm.prank(address(furnace));
        vault.notifyRewards(amount);
    }

    // ----------------------------------------------------------------
    // compoundFor returns silently (no pause) within cooldown
    // ----------------------------------------------------------------

    function test_compoundForSkipsWithinCooldown_NoPause() public {
        _stakeAlice(100e18);
        _fundRewards(100e18);

        uint256 tokenId = 50;
        ve.setOwner(tokenId, alice);
        ve.setLockInfo(tokenId, 1, block.timestamp + 90 days, false, false);

        vm.prank(alice);
        vault.setAutoCompoundConfig(true, tokenId, 30 days, 0, 0);

        // First compound succeeds.
        vm.warp(block.timestamp + 1 days + 1);
        vm.prank(keeper);
        vault.compoundFor(alice);

        assertEq(vault.rewards(alice), 0, "first compound consumes rewards");

        // Fund more rewards for a second attempt.
        _fundRewards(50e18);

        // Second compound within MIN_COMPOUND_INTERVAL => should skip (no-op), NOT pause.
        vm.prank(keeper);
        vault.compoundFor(alice);

        (, bool paused,,,,) = vault.getAutoCompoundConfig(alice);
        assertFalse(paused, "cooldown skip must NOT pause the config");
        // Rewards remain claimable.
        assertGt(vault.earned(alice), 0, "rewards remain after cooldown skip");
    }

    // ----------------------------------------------------------------
    // compoundFor skips (no pause) when reward < MIN_COMPOUND_REWARD
    // ----------------------------------------------------------------

    function test_compoundForSkipsWhenRewardBelowMinCompoundReward() public {
        _stakeAlice(100e18);

        // Fund only a tiny amount of rewards (below MIN_COMPOUND_REWARD = 1e15).
        uint256 tinyReward = vault.minCompoundReward() - 1;
        _fundRewards(tinyReward);

        uint256 tokenId = 51;
        ve.setOwner(tokenId, alice);
        ve.setLockInfo(tokenId, 1, block.timestamp + 90 days, false, false);

        vm.prank(alice);
        vault.setAutoCompoundConfig(true, tokenId, 30 days, 0, 0);

        vm.warp(block.timestamp + 1 days + 1);
        vm.prank(keeper);
        vault.compoundFor(alice);

        // Should NOT have compounded (Furnace not called).
        assertEq(furnace.enterCalls(), 0, "should not compound below MIN_COMPOUND_REWARD");

        // Config should NOT be paused (it's a skip, not a failure).
        (, bool paused,,,,) = vault.getAutoCompoundConfig(alice);
        assertFalse(paused, "below-threshold skip must NOT pause the config");

        // Rewards are still there (allow small rounding dust from rewardPerToken index math).
        assertApproxEqAbs(vault.earned(alice), tinyReward, 100, "tiny reward remains claimable");
    }

    // ----------------------------------------------------------------
    // claimRewardsAndLock reverts LockCooldown within interval
    // ----------------------------------------------------------------

    function test_claimRewardsAndLockRevertsCooldown() public {
        _stakeAlice(100e18);
        _fundRewards(200e18);

        furnace.setQuote(100e18, 0, 1, 0);

        // First call succeeds.
        vm.warp(block.timestamp + 1 days + 1);
        vm.prank(alice);
        vault.claimRewardsAndLock(0, 30 days, false, 1);

        // Fund more rewards.
        _fundRewards(100e18);

        // Second call within MIN_COMPOUND_INTERVAL should revert.
        vm.prank(alice);
        vm.expectRevert(LpStakingVault7D.LockCooldown.selector);
        vault.claimRewardsAndLock(0, 30 days, false, 1);
    }

    function test_claimRewardsAndLockSucceedsAfterCooldownExpires() public {
        _stakeAlice(100e18);
        _fundRewards(200e18);

        furnace.setQuote(100e18, 0, 1, 0);

        // First call.
        uint256 t1 = block.timestamp + 1 days + 1;
        vm.warp(t1);
        vm.prank(alice);
        vault.claimRewardsAndLock(0, 30 days, false, 1);

        // Fund more rewards.
        _fundRewards(100e18);

        // Wait for cooldown to expire.
        vm.warp(t1 + 1 days + 1);
        vm.prank(alice);
        vault.claimRewardsAndLock(0, 30 days, false, 1);

        assertEq(furnace.enterCalls(), 2, "second lock succeeds after cooldown");
    }

    // ----------------------------------------------------------------
    // Cooldown interaction between manual lock and auto-compound
    // ----------------------------------------------------------------

    function test_compoundForSucceedsAfterManualLockIndependentCooldown() public {
        _stakeAlice(100e18);
        _fundRewards(200e18);

        uint256 tokenId = 52;
        ve.setOwner(tokenId, alice);
        ve.setLockInfo(tokenId, 1, block.timestamp + 90 days, false, false);

        vm.prank(alice);
        vault.setAutoCompoundConfig(true, tokenId, 30 days, 0, 0);

        furnace.setQuote(100e18, 0, 1, 0);

        // Manual lock sets lastUserLockTs (independent from lastCompoundTs).
        vm.warp(block.timestamp + 1 days + 1);
        vm.prank(alice);
        vault.claimRewardsAndLock(0, 30 days, false, 1);

        // Fund more rewards.
        _fundRewards(100e18);

        // Auto-compound succeeds because cooldowns are now independent.
        vm.prank(keeper);
        vault.compoundFor(alice);

        (, bool paused,,,,) = vault.getAutoCompoundConfig(alice);
        assertFalse(paused, "auto-compound must NOT be paused");
    }

    // ----------------------------------------------------------------
    // compoundFor no-ops for zero address and disabled config
    // ----------------------------------------------------------------

    function test_compoundForNoopsForZeroAddress() public {
        // Should not revert, just return.
        vm.prank(keeper);
        vault.compoundFor(address(0));
    }

    function test_compoundForNoopsWhenDisabled() public {
        _stakeAlice(100e18);
        _fundRewards(100e18);

        // Alice has not configured auto-compound (disabled by default).
        vm.warp(block.timestamp + 1 days + 1);
        vm.prank(keeper);
        vault.compoundFor(alice);

        // Rewards should be untouched.
        assertEq(vault.earned(alice), 100e18, "disabled config must not consume rewards");
        assertEq(furnace.enterCalls(), 0, "disabled config must not call Furnace");
    }
}
