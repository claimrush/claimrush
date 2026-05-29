// SPDX-License-Identifier: MIT
pragma solidity ^0.8.34;

import {Test} from "forge-std/Test.sol";

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";

import {LpStakingVault7D} from "src/vault/LpStakingVault7D.sol";
import {Errors} from "src/lib/Errors.sol";

import {MockERC20} from "./mocks/MockERC20.sol";
import {MockAerodromePool} from "./mocks/MockAerodromePool.sol";
import {MockAerodromeRouter} from "./mocks/MockAerodromeRouter.sol";
import {MockFurnaceLpRewards} from "./mocks/MockFurnaceLpRewards.sol";
import {MockVe} from "./mocks/MockVe.sol";

contract LpStakingVault7DHarvestTest is Test {
    MockAerodromePool internal lp;
    MockERC20 internal weth;
    MockERC20 internal claim;
    MockFurnaceLpRewards internal furnace;
    MockVe internal ve;
    MockAerodromeRouter internal router;
    LpStakingVault7D internal vault;

    address internal factory = address(0xFACA);

    address internal alice = address(0xA11CE);
    address internal genesis = address(0xCAFE);
    address internal keeper = address(this);

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

        // Seed stake so harvested rewards distribute via rewardPerToken.
        lp.mint(alice, 100e18);
        vm.startPrank(alice);
        lp.approve(address(vault), type(uint256).max);
        vault.stake(100e18);
        vm.stopPrank();
    }

    function testHarvestRevertsOnNoFees() public {
        lp.setNextFees(0, 0);

        vm.expectRevert(LpStakingVault7D.NoFeesToHarvest.selector);
        vault.harvestFeesToRewards(block.timestamp + 1, 0);
    }

    function testHarvestRevertsForNonKeeper() public {
        lp.setNextFees(1e18, 0);
        vm.prank(alice);
        vm.expectRevert(Errors.NotAuthorized.selector);
        vault.harvestFeesToRewards(block.timestamp + 1, 0);
    }

    function testHarvestOwnerAllowedWithoutKeeperAllowlist() public {
        vault.setHarvestKeeper(address(this), false);
        assertFalse(vault.isHarvestKeeper(address(this)));

        lp.setNextFees(1e18, 0);
        router.setRateX18(1e18);

        uint256 wethBefore = weth.balanceOf(address(this));
        vault.harvestFeesToRewards(block.timestamp + 1, 1e18);

        assertEq(weth.balanceOf(address(this)), wethBefore, "no bounty paid to caller");
        assertEq(vault.earned(alice), 1e18);
        assertEq(vault.totalClaimRewardsFundedFromVaultFees(), 1e18);
    }

    function testSetHarvestKeeperOnlyOwner() public {
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, alice));
        vault.setHarvestKeeper(alice, true);
    }

    function testSetHarvestKeeperZeroAddressReverts() public {
        vm.expectRevert(Errors.ZeroAddress.selector);
        vault.setHarvestKeeper(address(0), true);
    }

    function testHarvestSwapsAllFeeWethToRewards() public {
        // feeWeth = 1e18 => the entire amount is swapped to CLAIM and credited as rewards.
        lp.setNextFees(1e18, 0);
        router.setRateX18(1e18); // 1:1

        uint256 wethBefore = weth.balanceOf(address(this));
        vault.harvestFeesToRewards(block.timestamp + 1, 1e18);

        // Caller receives no WETH (no bounty mechanism).
        assertEq(weth.balanceOf(address(this)), wethBefore);

        // All value credited to stakers as CLAIM rewards.
        // With a single staker, alice earns all.
        assertEq(vault.earned(alice), 1e18);
        assertEq(vault.totalClaimRewardsFundedFromVaultFees(), 1e18);
    }

    function testPreviewHandlesRouterRevert() public {
        // Preview reads balances only; seed some balances to simulate fees.
        weth.mint(address(vault), 1e18);
        router.setRevertGetAmountsOut(true);

        (uint256 feeWeth, uint256 feeClaim, uint256 expectedClaimOut) = vault.previewHarvestFeesToRewards();

        assertEq(feeWeth, 1e18);
        assertEq(feeClaim, 0);
        assertEq(expectedClaimOut, 0);
    }

    function testHarvestRevertsOnNoFeesEvenIfRewardBalancePresent() public {
        // Fund and account some CLAIM rewards so the vault holds an accounted reserve.
        claim.mint(address(vault), 10e18);
        vm.prank(address(furnace));
        vault.notifyRewards(10e18);

        // No new fees from the pool.
        lp.setNextFees(0, 0);

        vm.expectRevert(LpStakingVault7D.NoFeesToHarvest.selector);
        vault.harvestFeesToRewards(block.timestamp + 1, 0);
    }

    function testPreviewExcludesAccountedRewardBalanceFromFeeClaim() public {
        claim.mint(address(vault), 5e18);
        vm.prank(address(furnace));
        vault.notifyRewards(5e18);

        (uint256 feeWeth, uint256 feeClaim,) = vault.previewHarvestFeesToRewards();
        assertEq(feeWeth, 0);
        assertEq(feeClaim, 0);
    }

    function testHarvestDoesNotCountPreExistingPendingRewardsAsVaultFees() public {
        // Simulate CLAIM already sitting in the vault after a prior best-effort notify failure.
        claim.mint(address(vault), 10e18);

        // This harvest brings in fresh CLAIM fees only.
        lp.setNextFees(0, 5e18);

        vault.harvestFeesToRewards(block.timestamp + 1, 0);

        assertEq(vault.totalClaimRewardsFundedFromVaultFees(), 5e18, "only freshly harvested fees count");
        assertEq(vault.earned(alice), 15e18, "staker still receives both pending rewards and fresh fees");
        assertEq(vault.accountedRewardBalance(), 15e18, "all rewards remain fully accounted");
    }

    function testHarvestRevertsOnNoActualFeesWhenOnlyPendingRewardsExist() public {
        // Simulate CLAIM already sitting in the vault after a prior best-effort notify failure.
        claim.mint(address(vault), 10e18);
        lp.setNextFees(0, 0);

        vm.expectRevert(LpStakingVault7D.NoFeesToHarvest.selector);
        vault.harvestFeesToRewards(block.timestamp + 1, 0);

        assertEq(vault.lastFeeHarvestTs(), 0, "reward-only call must not advance harvest timer");
        assertEq(vault.totalClaimRewardsFundedFromVaultFees(), 0, "reward-only call must not inflate fee counter");
        assertEq(vault.rewardPerTokenStored(), 0, "reverted harvest must not mutate reward index");
    }

    function testPendingRewardsOnlyCallDoesNotAdvanceHarvestTimer() public {
        // First, perform a successful harvest so the timer is initialized.
        lp.setNextFees(1e18, 0);
        router.setRateX18(1e18);
        vault.harvestFeesToRewards(block.timestamp + 1, 1e18);

        uint256 firstHarvestTs = vault.lastFeeHarvestTs();
        uint256 t1 = firstHarvestTs + 1 days;
        vm.warp(t1);

        // Pending rewards alone must not count as a fresh harvest.
        claim.mint(address(vault), 10e18);
        lp.setNextFees(0, 0);

        vm.expectRevert(LpStakingVault7D.NoFeesToHarvest.selector);
        vault.harvestFeesToRewards(t1 + 1, 0);

        assertEq(vault.lastFeeHarvestTs(), firstHarvestTs, "failed reward-only call must not refresh timer");

        // A real harvest still succeeds and advances the timer.
        lp.setNextFees(1e18, 0);

        uint256 wethBefore = weth.balanceOf(address(this));
        vault.harvestFeesToRewards(t1 + 1, 1e18);

        assertEq(weth.balanceOf(address(this)), wethBefore, "no bounty paid to caller");
        assertEq(vault.lastFeeHarvestTs(), t1, "successful harvest advances timer");
    }
}

