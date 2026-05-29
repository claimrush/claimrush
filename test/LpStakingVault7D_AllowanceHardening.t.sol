// SPDX-License-Identifier: MIT
pragma solidity ^0.8.34;

import {Test} from "forge-std/Test.sol";

import {LpStakingVault7D} from "src/vault/LpStakingVault7D.sol";
import {Constants} from "src/lib/Constants.sol";

import {MockERC20} from "./mocks/MockERC20.sol";
import {MockAerodromePool} from "./mocks/MockAerodromePool.sol";
import {MockAerodromeRouter} from "./mocks/MockAerodromeRouter.sol";
import {MockVe} from "./mocks/MockVe.sol";

contract MockRevertingFurnace {
    address public immutable claim;
    address public immutable ve;

    constructor(address claim_, address ve_) {
        claim = claim_;
        ve = ve_;
    }

    function enterWithClaimFor(address, uint256, uint256, uint256, bool, uint256) external pure {
        revert("MockRevertingFurnace: revert");
    }
}

/// @notice Regression test: best-effort auto-compound must not accumulate CLAIM allowance
///         when Furnace reverts (since we catch and continue).
contract LpStakingVault7D_AllowanceHardeningTest is Test {
    MockERC20 internal weth;
    MockERC20 internal claim;
    MockAerodromePool internal lp;
    MockVe internal ve;
    MockAerodromeRouter internal router;
    MockRevertingFurnace internal furnace;
    LpStakingVault7D internal vault;

    address internal factory = address(0xFACADE);
    address internal genesis = address(0xCAFE);

    address internal alice = address(0xA11CE);
    address internal keeper = address(0xBEEF);

    function setUp() public {
        weth = new MockERC20("WETH", "WETH");
        claim = new MockERC20("CLAIM", "CLAIM");

        lp = new MockAerodromePool(address(weth), address(claim));
        ve = new MockVe();
        router = new MockAerodromeRouter(factory, address(weth));
        router.setPoolFor(address(weth), address(claim), false, factory, address(lp));

        furnace = new MockRevertingFurnace(address(claim), address(ve));

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

    function _stakeAndFundRewards(uint256 lpAmount, uint256 claimAmount) internal {
        lp.mint(alice, lpAmount);

        vm.startPrank(alice);
        lp.approve(address(vault), lpAmount);
        vault.stake(lpAmount);
        vm.stopPrank();

        // Fund rewards and notify from furnace (allowed notifier).
        claim.mint(address(vault), claimAmount);
        vm.prank(address(furnace));
        vault.notifyRewards(0); // ignored; balance delta is the source of truth
    }

    function testAutoCompoundRevertDoesNotAccumulateAllowance() public {
        _stakeAndFundRewards(Constants.MIN_UNBOND_AMOUNT, 100e18);

        // Configure destination lock.
        uint256 tokenId = 1;
        ve.setOwner(tokenId, alice);
        ve.setLockInfo(tokenId, 1, block.timestamp + 1 days, false, false);

        vm.prank(alice);
        vault.setAutoCompoundConfig(true, tokenId, Constants.MIN_LOCK_DURATION, 0, 0);

        assertEq(claim.allowance(address(vault), address(furnace)), 0);

        // Call twice to ensure no accumulation over repeated failures.
        vm.prank(keeper);
        vault.compoundFor(alice);
        assertEq(claim.allowance(address(vault), address(furnace)), 0);

        vm.prank(keeper);
        vault.compoundFor(alice);
        assertEq(claim.allowance(address(vault), address(furnace)), 0);

        // Rewards must remain claimable after failed compounding attempts.
        assertGt(vault.earned(alice), 0);
    }
}
