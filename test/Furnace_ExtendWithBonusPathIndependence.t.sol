// SPDX-License-Identifier: MIT
pragma solidity ^0.8.34;

import {Test} from "forge-std/Test.sol";

import {ClaimToken} from "src/ClaimToken.sol";
import {MineCore} from "src/MineCore.sol";
import {ShareholderRoyalties} from "src/ShareholderRoyalties.sol";
import {FurnaceQuoter} from "src/FurnaceQuoter.sol";
import {Constants} from "src/lib/Constants.sol";
import {DelegationHub} from "src/DelegationHub.sol";

import {FurnaceHarness} from "./mocks/FurnaceHarness.sol";
import {MockContract} from "./mocks/MockContract.sol";
import {MockEntryTokenRegistry} from "./mocks/MockEntryTokenRegistry.sol";
import {MockLpRewardsVault} from "./mocks/MockLpRewardsVault.sol";
import {VeClaimNFTHarness} from "./mocks/VeClaimNFTHarness.sol";

/// @title Furnace `extendWithBonus` path independence
/// @notice Property: cycling N small extensions over the same time window pays the same
///         cumulative bonus as one single extension covering the full window. The duration
///         weight curve must integrate continuously over a sub-resolution sequence — no
///         extra bonus may be minted by fragmenting a single extension into many small
///         repeats.
contract FurnaceExtendWithBonusPathIndependenceTest is Test {
    ClaimToken internal claim;
    VeClaimNFTHarness internal ve;
    MineCore internal mineCore;
    FurnaceHarness internal furnace;
    FurnaceQuoter internal furnaceQuoter;
    MockLpRewardsVault internal lpVault;
    ShareholderRoyalties internal royalties;
    DelegationHub internal delegationHub;

    address internal owner = address(0xA11CE);
    address internal user = address(0xB1B1);
    address internal mineMarket;
    address internal registry;
    address internal mineCoreRegistry;

    function setUp() public {
        claim = new ClaimToken(owner);
        ve = new VeClaimNFTHarness(address(claim), owner);
        royalties = new ShareholderRoyalties(address(ve), owner);
        mineCore = new MineCore(address(claim), address(ve), address(royalties), owner);
        furnace = new FurnaceHarness(address(claim), address(ve), owner);
        furnaceQuoter = new FurnaceQuoter(address(furnace));
        delegationHub = new DelegationHub();
        mineMarket = address(new MockContract());
        registry = address(new MockEntryTokenRegistry());
        mineCoreRegistry = address(new MockEntryTokenRegistry());
        vm.mockCall(mineMarket, abi.encodeWithSignature("claim()"), abi.encode(address(claim)));
        vm.mockCall(mineMarket, abi.encodeWithSignature("ve()"), abi.encode(address(ve)));
        vm.mockCall(mineMarket, abi.encodeWithSignature("royalties()"), abi.encode(address(royalties)));

        vm.startPrank(owner);
        claim.setMineCore(address(mineCore));
        furnace.setMineCore(address(mineCore));
        furnace.setFurnaceQuoter(address(furnaceQuoter));
        furnace.setShareholderRoyalties(address(royalties));
        furnace.setMineMarket(mineMarket);
        furnace.setEntryTokenRegistry(registry);
        mineCore.setFurnace(address(furnace));
        mineCore.setDelegationHub(address(delegationHub));
        mineCore.setEntryTokenRegistry(mineCoreRegistry);
        furnace.setDelegationHub(address(delegationHub));
        royalties.setWiring(address(mineCore), mineMarket, address(furnace));
        ve.setFurnace(address(furnace));
        ve.setMineMarket(mineMarket);
        vm.stopPrank();

        lpVault = new MockLpRewardsVault();
        lpVault.setFurnace(address(furnace));
        vm.prank(owner);
        furnace.setLpRewardsVault(address(lpVault));
    }

    function _seedReserve(uint256 amount) internal {
        if (amount == 0) return;
        vm.prank(address(mineCore));
        claim.mint(address(furnace), amount);
        vm.prank(address(mineCore));
        furnace.creditReserve(amount);
    }

    function _createLock(address holder, uint256 amount, uint256 duration, bool autoMax) internal returns (uint256) {
        vm.prank(address(mineCore));
        claim.mint(holder, amount);
        vm.startPrank(holder);
        claim.approve(address(ve), type(uint256).max);
        uint256 tokenId = ve.createLock(amount, duration, autoMax);
        vm.stopPrank();
        return tokenId;
    }

    /// @notice Cycling N x 30s extensions on a near-MAX large-principal lock pays the same
    ///         cumulative bonus as a single 11x30s extension covering the same window.
    ///         A `vm.snapshot()` ensures the AMM depth, reserve balance, and lock state are
    ///         byte-identical at the start of both the baseline and cycled runs.
    function test_CyclingDoesNotInflateBaseline() public {
        uint256 reserveSeed = 50_000_000e18;
        uint256 lockAmt = 5_000_000e18;
        uint256 cycles = 11;
        uint256 step = 30;
        uint256 totalDelta = cycles * step;

        _seedReserve(reserveSeed);
        vm.warp(block.timestamp + 1);
        uint256 lockId = _createLock(user, lockAmt, Constants.MAX_LOCK_DURATION - totalDelta, false);
        vm.warp(block.timestamp + 1);
        uint256 snapId = vm.snapshot();

        // Baseline: single-shot extension covering 11 x 30s = 330s. Warp to the same
        // end-time the cycled run reaches so the AMM sees the same wall clock.
        uint256 endT = block.timestamp + cycles * step;
        vm.warp(endT);
        vm.prank(user);
        uint256 baselineBonus = furnace.extendWithBonus(lockId, Constants.MAX_LOCK_DURATION, 0);
        assertGt(baselineBonus, 0, "baseline single-shot extension should pay non-zero bonus");

        require(vm.revertTo(snapId), "snapshot revert failed");

        // Cycled: 11 separate 30s extensions, advancing the wall clock by `step` between
        // each call.
        uint256 cycledTotal = 0;
        uint256 t = block.timestamp;
        for (uint256 i = 1; i <= cycles; i++) {
            t += step;
            vm.warp(t);
            uint256 target = Constants.MAX_LOCK_DURATION - totalDelta + (i * step);
            vm.prank(user);
            uint256 paid = furnace.extendWithBonus(lockId, target, 0);
            cycledTotal += paid;
        }

        // Hard ceiling: cycled total must be within 2x of single-shot baseline. AMM
        // curvature can shift slightly when fragmenting a fill across many small steps,
        // but no sub-resolution surcharge is permitted — anything above 2x indicates a
        // continuity break in the duration weight curve.
        assertLt(cycledTotal, 2 * baselineBonus, "cycled extension cumulative bonus exceeds 2x single-shot baseline");

        // Floor-surcharge probe: a degenerate bps floor in the duration weight calculation
        // would inflate each cycled call by a full 1bp of the principal — at 5M CLAIM that
        // is ~0.05 CLAIM per call, ~0.55 CLAIM over 11 cycles. A 1 CLAIM ceiling above
        // baseline catches that pattern without false-positiving on legitimate AMM
        // curvature.
        assertLt(
            cycledTotal,
            baselineBonus + 1e18,
            "cycled extension surcharge above baseline indicates duration weight floor drift"
        );
    }
}
