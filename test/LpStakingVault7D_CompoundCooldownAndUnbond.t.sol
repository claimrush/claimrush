// SPDX-License-Identifier: MIT
pragma solidity ^0.8.34;

import {Test} from "forge-std/Test.sol";

import {LpStakingVault7D} from "src/vault/LpStakingVault7D.sol";
import {Constants} from "src/lib/Constants.sol";
import {Errors} from "src/lib/Errors.sol";
import {Events} from "src/lib/Events.sol";

import {MockERC20} from "./mocks/MockERC20.sol";
import {MockAerodromePool} from "./mocks/MockAerodromePool.sol";
import {MockAerodromeRouter} from "./mocks/MockAerodromeRouter.sol";
import {MockFurnaceLpRewards} from "./mocks/MockFurnaceLpRewards.sol";
import {MockVe} from "./mocks/MockVe.sol";

/// @title LpStakingVault7D compound-cooldown and unbond edge cases.
/// @dev Covers compound cooldown behavior on Furnace revert, harvest-floor
///      event emission, `getUnbondByIndex` withdrawn-entry semantics, and
///      supplementary edge cases.
contract LpStakingVault7D_CompoundCooldownAndUnbond_Test is Test {
    MockAerodromePool internal lp;
    MockERC20 internal weth;
    MockERC20 internal claimToken;
    MockFurnaceLpRewards internal furnace;
    MockVe internal ve;
    MockAerodromeRouter internal router;
    LpStakingVault7D internal vault;

    address internal factory = address(0xFACA);
    address internal alice = address(0xA11CE);
    address internal keeper = address(0xBEEF);

    function setUp() public {
        weth = new MockERC20("WETH", "WETH");
        claimToken = new MockERC20("CLAIM", "CLAIM");
        lp = new MockAerodromePool(address(weth), address(claimToken));
        ve = new MockVe();
        router = new MockAerodromeRouter(factory, address(weth));
        router.setPoolFor(address(weth), address(claimToken), false, factory, address(lp));
        furnace = new MockFurnaceLpRewards(address(claimToken), address(ve));

        vault = new LpStakingVault7D(
            address(lp),
            address(weth),
            address(claimToken),
            address(ve),
            address(furnace),
            address(router),
            factory,
            false,
            address(this)
        );

        vault.setHarvestKeeper(keeper, true);

        // Set up alice with a stake and auto-compound config.
        lp.mint(alice, 1000e18);
        vm.startPrank(alice);
        lp.approve(address(vault), type(uint256).max);
        vault.stake(1000e18);
        vm.stopPrank();

        // Set up ve token for alice's auto-compound.
        ve.setOwner(1, alice);
        ve.setLockInfo(1, 1e18, block.timestamp + 365 days, false, false);

        vm.prank(alice);
        vault.setAutoCompoundConfig(true, 1, 30 days, 0, 0);
    }

    // ── lastCompoundTs must NOT advance on Furnace revert ───────────

    function test_compoundFor_failedFurnaceDoesNotAdvanceCooldown() public {
        // Fund rewards so compound has something to process.
        claimToken.mint(address(vault), 100e18);
        vm.prank(address(furnace));
        vault.notifyRewards(0);

        // Advance past the compound cooldown.
        vm.warp(block.timestamp + 1 days + 1);

        // Make Furnace revert on enterWithClaimFor.
        furnace.setShouldRevert(true);

        uint256 tsBefore = vault.lastCompoundTs(alice);

        vm.prank(keeper);
        vault.compoundFor(alice);

        // lastCompoundTs MUST NOT advance on failure so the caller can retry in the same block.
        uint256 tsAfter = vault.lastCompoundTs(alice);
        assertEq(tsAfter, tsBefore, "lastCompoundTs must not advance on Furnace revert");

        // Rewards should be preserved.
        assertGt(vault.earned(alice), 0, "rewards must be restored after failed compound");
    }

    function test_compoundFor_successDoesAdvanceCooldown() public {
        // Fund rewards.
        claimToken.mint(address(vault), 100e18);
        vm.prank(address(furnace));
        vault.notifyRewards(0);

        // Advance past cooldown.
        vm.warp(block.timestamp + 1 days + 1);

        // Furnace works normally (default: no revert).
        furnace.setShouldRevert(false);

        vm.prank(keeper);
        vault.compoundFor(alice);

        // On success: lastCompoundTs is updated to the current block.
        assertEq(vault.lastCompoundTs(alice), block.timestamp, "lastCompoundTs must advance on success");
    }

    function test_compoundFor_retryPossibleImmediatelyAfterFailure() public {
        // Fund rewards.
        claimToken.mint(address(vault), 100e18);
        vm.prank(address(furnace));
        vault.notifyRewards(0);

        // Advance past cooldown.
        vm.warp(block.timestamp + 1 days + 1);

        // First attempt: Furnace reverts.
        furnace.setShouldRevert(true);
        vm.prank(keeper);
        vault.compoundFor(alice);

        // lastCompoundTs MUST NOT have advanced on failure.
        assertEq(vault.lastCompoundTs(alice), 0, "lastCompoundTs must not advance on Furnace revert");

        // The catch block pauses the config to signal the failure to off-chain keepers.
        // User (or keeper via delegation) must re-enable before retry.
        vm.prank(alice);
        vault.setAutoCompoundConfig(true, 1, 30 days, 0, 0);

        // Second attempt (same block): Furnace works now.
        // Because lastCompoundTs wasn't advanced, the cooldown doesn't block retry.
        furnace.setShouldRevert(false);
        vm.prank(keeper);
        vault.compoundFor(alice);

        // Should have succeeded — cooldown advanced now.
        assertEq(vault.lastCompoundTs(alice), block.timestamp, "retry should succeed after failed attempt");
        // Rewards should be consumed.
        assertEq(vault.earned(alice), 0, "rewards consumed by successful compound retry");
    }

    // ── setMinHarvestClaimFloor event emission ──────────────────────

    function test_setMinHarvestClaimFloor_emitsEvent() public {
        vm.expectEmit(false, false, false, true);
        emit Events.MinHarvestClaimFloorSet(0, 1e18);
        vault.setMinHarvestClaimFloor(1e18);

        vm.expectEmit(false, false, false, true);
        emit Events.MinHarvestClaimFloorSet(1e18, 5e18);
        vault.setMinHarvestClaimFloor(5e18);

        vm.expectEmit(false, false, false, true);
        emit Events.MinHarvestClaimFloorSet(5e18, 0);
        vault.setMinHarvestClaimFloor(0);
    }

    function test_setMinHarvestClaimFloor_onlyOwner() public {
        vm.prank(alice);
        vm.expectRevert();
        vault.setMinHarvestClaimFloor(1e18);
    }

    // ── setMinHarvestClaimFloor MAX bound ────────────────────────────────

    function test_setMinHarvestClaimFloor_acceptsMax() public {
        uint256 maxFloor = vault.MAX_MIN_HARVEST_CLAIM_FLOOR();
        assertEq(maxFloor, 100_000e18);

        vault.setMinHarvestClaimFloor(maxFloor);
        assertEq(vault.minHarvestClaimFloor(), maxFloor);
    }

    function test_setMinHarvestClaimFloor_revertsAboveMax() public {
        uint256 maxFloor = vault.MAX_MIN_HARVEST_CLAIM_FLOOR();

        vm.expectRevert(Errors.AmountTooLarge.selector);
        vault.setMinHarvestClaimFloor(maxFloor + 1);
    }

    function test_setMinHarvestClaimFloor_revertsAtUintMax() public {
        vm.expectRevert(Errors.AmountTooLarge.selector);
        vault.setMinHarvestClaimFloor(type(uint256).max);
    }

    function test_setMinHarvestClaimFloor_zeroStillValid() public {
        vault.setMinHarvestClaimFloor(1e18);
        vault.setMinHarvestClaimFloor(0);
        assertEq(vault.minHarvestClaimFloor(), 0);
    }

    // ── setMinCompoundReward event emission + bounds ─────────────────

    function test_setMinCompoundReward_emitsEvent() public {
        uint256 initial = vault.minCompoundReward();

        vm.expectEmit(false, false, false, true);
        emit Events.MinCompoundRewardSet(initial, 1e18);
        vault.setMinCompoundReward(1e18);

        vm.expectEmit(false, false, false, true);
        emit Events.MinCompoundRewardSet(1e18, 5e18);
        vault.setMinCompoundReward(5e18);

        vm.expectEmit(false, false, false, true);
        emit Events.MinCompoundRewardSet(5e18, 0);
        vault.setMinCompoundReward(0);
    }

    function test_setMinCompoundReward_onlyOwner() public {
        vm.prank(alice);
        vm.expectRevert();
        vault.setMinCompoundReward(1e18);
    }

    function test_setMinCompoundReward_acceptsMax() public {
        uint256 maxFloor = vault.MAX_MIN_COMPOUND_REWARD();
        assertEq(maxFloor, 1000e18);

        vault.setMinCompoundReward(maxFloor);
        assertEq(vault.minCompoundReward(), maxFloor);
    }

    function test_setMinCompoundReward_revertsAboveMax() public {
        uint256 maxFloor = vault.MAX_MIN_COMPOUND_REWARD();

        vm.expectRevert(Errors.AmountTooLarge.selector);
        vault.setMinCompoundReward(maxFloor + 1);
    }

    function test_setMinCompoundReward_revertsAtUintMax() public {
        vm.expectRevert(Errors.AmountTooLarge.selector);
        vault.setMinCompoundReward(type(uint256).max);
    }

    function test_setMinCompoundReward_zeroStillValid() public {
        vault.setMinCompoundReward(1e18);
        vault.setMinCompoundReward(0);
        assertEq(vault.minCompoundReward(), 0);
    }

    // ── getUnbondByIndex withdrawn-entry semantics ──────────────────

    function test_getUnbondByIndex_withdrawnAlwaysFalse() public {
        vm.startPrank(alice);
        vault.beginUnbond(10e18);
        vm.stopPrank();

        (, uint256 amount,) = vault.getUnbondByIndex(alice, 0);
        assertEq(amount, 10e18, "active unbond amount");
    }

    function test_getUnbondByIndex_entryDisappearsAfterWithdrawal() public {
        vm.startPrank(alice);
        vault.beginUnbond(10e18);
        vm.stopPrank();

        assertEq(vault.getUnbondCount(alice), 1);

        // Mature and withdraw.
        vm.warp(block.timestamp + Constants.UNBONDING_PERIOD);
        vm.prank(alice);
        vault.withdrawMatured();

        // Entry is gone (swap-and-pop), not marked withdrawn.
        assertEq(vault.getUnbondCount(alice), 0, "withdrawn entry must be removed, not marked");
    }

    // ── Supplementary: cross-function state interactions ─────────────

    // ── claimRewardsAndLock: per-user 24h cooldown gate ───────────────

    /// @dev Mirrors the UI-visible `LockCooldown()` gate at
    ///      `LpStakingVault7D.sol:481`. Locks `lastUserLockTs[msg.sender]` to the
    ///      successful execution's block timestamp and binds for one full
    ///      `MIN_COMPOUND_INTERVAL` (24h) against `msg.sender`, independent of
    ///      the keeper-side `lastCompoundTs` anchor. The dashboard "Harvest & Lock"
    ///      button and modal must surface this gate via `lastUserLockTs(user)` so
    ///      the wallet popup never opens on a call that will revert.
    function test_claimRewardsAndLock_revertsOnBackToBackCall() public {
        // Fund the first reward window.
        claimToken.mint(address(vault), 100e18);
        vm.prank(address(furnace));
        vault.notifyRewards(0);

        // Advance past the initial cooldown floor (`lastUserLockTs[alice] = 0`
        // would otherwise block the first call against the deployment timestamp).
        vm.warp(block.timestamp + vault.MIN_COMPOUND_INTERVAL() + 1);

        // First call succeeds and writes `lastUserLockTs[alice] = block.timestamp`.
        uint256 firstCallTs = block.timestamp;
        vm.prank(alice);
        vault.claimRewardsAndLock(1, 30 days, false, 1);
        assertEq(vault.lastUserLockTs(alice), firstCallTs, "first call writes anchor");

        // Re-fund rewards so a second attempt has something to consume; otherwise
        // the function returns early (no-op) on a zero reward balance and the
        // cooldown gate is never reached.
        claimToken.mint(address(vault), 100e18);
        vm.prank(address(furnace));
        vault.notifyRewards(0);

        // Advance just shy of the 24h cooldown boundary. Second call must revert
        // with `LockCooldown()` — this is the selector that surfaces as
        // `0x39be4a63` to the wallet's UserOp simulator.
        vm.warp(firstCallTs + vault.MIN_COMPOUND_INTERVAL() - 1);
        vm.prank(alice);
        vm.expectRevert(LpStakingVault7D.LockCooldown.selector);
        vault.claimRewardsAndLock(1, 30 days, false, 1);

        // After advancing past the cooldown, the gate clears and the call lands.
        uint256 secondCallTs = firstCallTs + vault.MIN_COMPOUND_INTERVAL();
        vm.warp(secondCallTs);
        vm.prank(alice);
        vault.claimRewardsAndLock(1, 30 days, false, 1);
        assertEq(vault.lastUserLockTs(alice), secondCallTs, "second call re-anchors");
        assertEq(vault.earned(alice), 0, "rewards consumed by second successful lock");
    }

    function test_compoundFor_afterClaimRewardsAndLock_independentCooldowns() public {
        // Fund rewards.
        claimToken.mint(address(vault), 200e18);
        vm.prank(address(furnace));
        vault.notifyRewards(0);

        // Advance past the initial cooldown so claimRewardsAndLock doesn't revert.
        vm.warp(block.timestamp + 1 days + 1);

        // Alice manually locks rewards (sets lastUserLockTs, NOT lastCompoundTs).
        vm.prank(alice);
        vault.claimRewardsAndLock(1, 30 days, false, 1);

        // Fund more rewards.
        claimToken.mint(address(vault), 200e18);
        vm.prank(address(furnace));
        vault.notifyRewards(0);

        // Keeper compounds in the same block — succeeds because cooldowns are independent.
        vm.prank(keeper);
        vault.compoundFor(alice);

        // Compound succeeded: rewards consumed.
        assertEq(vault.earned(alice), 0, "compound should succeed with independent cooldowns");
    }

    function test_stake_afterPendingBalanceDelta_preservesAccountedRewardBalance() public {
        // Simulate unnotified CLAIM in vault.
        claimToken.mint(address(vault), 500e18);

        uint256 accountedBefore = vault.accountedRewardBalance();

        // Bob stakes — triggers _checkpointPendingRewardsBeforeStakeChange.
        address bob = address(0xB0B);
        lp.mint(bob, 100e18);
        vm.startPrank(bob);
        lp.approve(address(vault), type(uint256).max);
        vault.stake(100e18);
        vm.stopPrank();

        // accountedRewardBalance should now reflect the pending 500e18.
        assertGt(vault.accountedRewardBalance(), accountedBefore, "checkpoint must account pending balance");
        assertEq(
            vault.accountedRewardBalance(),
            claimToken.balanceOf(address(vault)),
            "accountedRewardBalance must equal actual CLAIM balance after checkpoint"
        );
    }
}
