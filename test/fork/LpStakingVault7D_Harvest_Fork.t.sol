// SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {LpStakingVault7D} from "src/vault/LpStakingVault7D.sol";
import {IAerodromePool} from "src/interfaces/IAerodromePool.sol";
import {IAerodromeRouter} from "src/interfaces/IAerodromeRouter.sol";
import {IDexAdapter} from "src/interfaces/IDexAdapter.sol";

import {AerodromeForkBase, ForkClaimToken} from "./AerodromeForkBase.t.sol";

/// @dev Minimal stubs satisfying the LpStakingVault7D constructor wiring checks.
contract MockVeFork {
    function ownerOf(uint256) external pure returns (address) {
        return address(0);
    }

    function nextTokenId() external pure returns (uint256) {
        return 1;
    }
}

contract MockFurnaceFork {
    address public immutable claim;
    address public immutable ve;

    constructor(address _claim, address _ve) {
        claim = _claim;
        ve = _ve;
    }

    function furnaceQuoter() external pure returns (address) {
        return address(0);
    }
}

contract LpStakingVault7DHarvestForkTest is AerodromeForkBase {
    uint256 internal constant SEED_WETH = 50 ether;
    uint256 internal constant SEED_CLAIM = 500_000e18;

    LpStakingVault7D internal vault;
    MockVeFork internal mockVe;
    MockFurnaceFork internal mockFurnace;

    address internal keeper = makeAddr("keeper");

    function setUp() public override {
        super.setUp();

        _seedPool(SEED_WETH, SEED_CLAIM);

        vm.startPrank(deployer);

        mockVe = new MockVeFork();
        mockFurnace = new MockFurnaceFork(address(claimToken), address(mockVe));

        vault = new LpStakingVault7D(
            pool,
            WETH,
            address(claimToken),
            address(mockVe),
            address(mockFurnace),
            AERODROME_ROUTER,
            AERODROME_FACTORY,
            false,
            deployer
        );

        vault.setHarvestKeeper(keeper, true);

        vm.stopPrank();

        // Stake LP so rewards can be indexed
        uint256 lpBal = IERC20(pool).balanceOf(address(this));
        IERC20(pool).approve(address(vault), lpBal);
        vault.stake(lpBal);
    }

    function _quoteWethToClaim(uint256 wethAmount) internal view returns (uint256) {
        IAerodromeRouter.Route[] memory routes = new IAerodromeRouter.Route[](1);
        routes[0] =
            IAerodromeRouter.Route({from: WETH, to: address(claimToken), stable: false, factory: AERODROME_FACTORY});
        uint256[] memory amounts = IAerodromeRouter(AERODROME_ROUTER).getAmountsOut(wethAmount, routes);
        return amounts[1];
    }

    // --- Core harvest: WETH sitting in vault gets swapped to CLAIM ---

    function test_harvestSwapsWethToClaimViaRealRouter() public {
        // Deal WETH directly to vault (simulates fees)
        uint256 feeWeth = 0.5 ether;
        _dealWeth(address(vault), feeWeth);

        // All feeWeth goes to swap. Quote the expected output.
        uint256 expectedClaimOut = _quoteWethToClaim(feeWeth);
        uint256 minClaimOut = (expectedClaimOut * 90) / 100;

        uint256 claimBefore = claimToken.balanceOf(address(vault));

        vm.prank(keeper);
        vault.harvestFeesToRewards(block.timestamp + 9 minutes, minClaimOut);

        uint256 claimAfter = claimToken.balanceOf(address(vault));
        assertGt(claimAfter, claimBefore, "vault CLAIM increased from harvest swap");
        assertEq(vault.lastFeeHarvestTs(), block.timestamp, "harvest timestamp updated");
    }

    function test_harvestSwapUsesRealCurveMath() public {
        uint256 feeWeth = 2 ether;
        _dealWeth(address(vault), feeWeth);

        uint256 expectedClaimOut = _quoteWethToClaim(feeWeth);

        // Real output < naive due to fee + price impact
        uint256 naiveOutput = (feeWeth * SEED_CLAIM) / SEED_WETH;
        assertLt(expectedClaimOut, naiveOutput, "real quote < naive (includes fee + impact)");

        uint256 minClaimOut = (expectedClaimOut * 90) / 100;
        uint256 claimBefore = claimToken.balanceOf(address(vault));

        vm.prank(keeper);
        vault.harvestFeesToRewards(block.timestamp + 9 minutes, minClaimOut);

        uint256 claimBought = claimToken.balanceOf(address(vault)) - claimBefore;
        assertGt(claimBought, 0, "bought CLAIM > 0");
        assertApproxEqRel(claimBought, expectedClaimOut, 0.01e18, "swap output ~ quoted output");
    }

    function test_harvestSwapsAllFreshWeth() public {
        // Generate real trading fees so claimFees returns non-zero WETH
        _generateTradingFees(5, 1 ether);

        // Deal pre-existing WETH to vault. With no bounty mechanism, all WETH (pre-existing
        // + freshly claimed) is swapped to CLAIM and credited as rewards.
        uint256 preExistingWeth = 1 ether;
        _dealWeth(address(vault), preExistingWeth);

        // Over-estimate total to ensure minClaimOut >= floor * 90%.
        uint256 estimatedTotal = preExistingWeth + 0.02 ether;
        uint256 quote = _quoteWethToClaim(estimatedTotal);
        uint256 minClaimOut = (quote * 95) / 100;

        uint256 keeperWethBefore = IERC20(WETH).balanceOf(keeper);

        vm.prank(keeper);
        vault.harvestFeesToRewards(block.timestamp + 9 minutes, minClaimOut);

        uint256 keeperWethAfter = IERC20(WETH).balanceOf(keeper);

        assertEq(keeperWethAfter, keeperWethBefore, "keeper receives no WETH (no bounty mechanism)");
        assertEq(IERC20(WETH).balanceOf(address(vault)), 0, "all WETH swapped to CLAIM");
        assertEq(vault.lastFeeHarvestTs(), block.timestamp, "harvest completed");
    }

    // --- previewHarvestFeesToRewards ---

    function test_previewReturnsQuoteFromRealRouter() public {
        uint256 feeWeth = 1 ether;
        _dealWeth(address(vault), feeWeth);

        (uint256 pvFeeWeth, uint256 pvFeeClaim, uint256 pvExpectedClaimOut) = vault.previewHarvestFeesToRewards();

        assertEq(pvFeeWeth, feeWeth, "preview WETH matches");
        assertEq(pvFeeClaim, 0, "preview CLAIM is 0 (cannot call claimFees in view)");
        assertGt(pvExpectedClaimOut, 0, "preview quotes non-zero CLAIM out via real router");
    }

    // --- Effective min claim out uses real getAmountsOut ---

    function test_effectiveMinClaimOutFromRealQuote() public {
        uint256 feeWeth = 0.5 ether;
        _dealWeth(address(vault), feeWeth);

        // Pass minClaimOut=1 — the vault's CallerQuoteDivergence check should revert
        // because 1 is far below the on-chain quote floor.
        vm.prank(keeper);
        vm.expectRevert(LpStakingVault7D.CallerQuoteDivergence.selector);
        vault.harvestFeesToRewards(block.timestamp + 9 minutes, 1);
    }

    // --- No fees reverts ---

    function test_revertWhenNoFees() public {
        vm.prank(keeper);
        vm.expectRevert(LpStakingVault7D.NoFeesToHarvest.selector);
        vault.harvestFeesToRewards(block.timestamp + 9 minutes, 0);
    }
}
