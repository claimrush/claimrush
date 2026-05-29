// SPDX-License-Identifier: MIT
pragma solidity ^0.8.34;

import {Test} from "forge-std/Test.sol";

import {LpStakingVault7D} from "src/vault/LpStakingVault7D.sol";

import {MockERC20} from "./mocks/MockERC20.sol";
import {MockAerodromePool} from "./mocks/MockAerodromePool.sol";
import {MockAerodromeRouter} from "./mocks/MockAerodromeRouter.sol";
import {MockFurnaceLpRewards} from "./mocks/MockFurnaceLpRewards.sol";
import {MockVe} from "./mocks/MockVe.sol";

/// @notice Harvest no-swap liveness coverage.
contract LpStakingVault7D_HarvestNoSwapLiveness_Test is Test {
    MockAerodromePool internal lp;
    MockERC20 internal weth;
    MockERC20 internal claim;
    MockFurnaceLpRewards internal furnace;
    MockVe internal ve;
    MockAerodromeRouter internal router;
    LpStakingVault7D internal vault;

    address internal factory = address(0xFACA);
    address internal alice = address(0xA11CE);

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

        lp.mint(alice, 100e18);
        vm.startPrank(alice);
        lp.approve(address(vault), type(uint256).max);
        vault.stake(100e18);
        vm.stopPrank();
    }

    function test_harvestClaimOnlyFees_ignoresNonZeroMinClaimOut() public {
        lp.setNextFees(0, 5e18);

        vault.harvestFeesToRewards(block.timestamp + 1, 123e18);

        assertEq(vault.totalClaimRewardsFundedFromVaultFees(), 5e18, "claim-only fees should still fund rewards");
        assertEq(vault.earned(alice), 5e18, "sole staker receives the harvested CLAIM fees");
        assertEq(vault.lastFeeHarvestTs(), block.timestamp, "successful claim-only harvest updates freshness");
    }
}
