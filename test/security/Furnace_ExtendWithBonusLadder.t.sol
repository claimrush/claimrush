// SPDX-License-Identifier: MIT
pragma solidity ^0.8.34;

import {Test} from "forge-std/Test.sol";

import {ClaimToken} from "src/ClaimToken.sol";
import {MineCore} from "src/MineCore.sol";
import {ShareholderRoyalties} from "src/ShareholderRoyalties.sol";
import {FurnaceQuoter} from "src/FurnaceQuoter.sol";
import {Constants} from "src/lib/Constants.sol";
import {DelegationHub} from "src/DelegationHub.sol";

import {FurnaceHarness} from "../mocks/FurnaceHarness.sol";
import {MockContract} from "../mocks/MockContract.sol";
import {MockEntryTokenRegistry} from "../mocks/MockEntryTokenRegistry.sol";
import {MockLpRewardsVault} from "../mocks/MockLpRewardsVault.sol";
import {VeClaimNFTHarness} from "../mocks/VeClaimNFTHarness.sol";

/// @title Regression — `extendWithBonus` prices the duration-weight bonus on the user's committed
///        principal basis, not the bonus-inflated live `Lock.amount`.
/// @notice The extend bonus is priced against `bonusBasis` (user-supplied principal) rather than
///         `Lock.amount`. Because `Lock.amount` grows every time a bonus is folded back into the
///         lock, pricing the next commitment off it would let a laddered sequence of extensions
///         compound the bonus multiplicatively over a single 7d->365d commitment. Pricing off the
///         fixed basis makes the cumulative bonus path-independent.
///
///         These tests assert path independence: fragmenting the same commitment into many rungs
///         over the same final wall clock earns essentially the same bonus as a single extension.
///         The execution body lives in `FurnaceExtendHelper` (delegatecall from Furnace); these
///         tests exercise it end-to-end through the Furnace `extendWithBonus` shim.
contract FurnaceExtendWithBonusLadderRegression is Test {
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

    uint256 internal constant PRINCIPAL = 1_000_000e18;
    uint256 internal constant SPACING = 3 hours; // == Constants.BONUS_DECAY_WINDOW

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

    function _lockAmount(uint256 tokenId) internal view returns (uint256 amount) {
        (amount,,,) = ve.getLockInfo(tokenId);
    }

    /// @notice Ladders 7d -> 90d -> 270d -> 365d and compares against a single 7d -> 365d extension
    ///         at an identical final wall clock. The two must earn essentially the same bonus.
    function test_LadderedExtendMatchesSingleExtension() public {
        _seedReserve(Constants.RESERVE_TARGET_FINAL);

        uint256 tokenId = _createLock(user, PRINCIPAL, Constants.MIN_LOCK_DURATION, false);
        uint256 startTs = block.timestamp;
        uint256 snapId = vm.snapshot();

        // Run A (baseline): one extension 7d -> 365d.
        vm.warp(startTs + 3 * SPACING);
        uint256 reserveBeforeA = furnace.furnaceReserve();
        vm.prank(user);
        furnace.extendWithBonus(tokenId, Constants.MAX_LOCK_DURATION, 0);
        uint256 baselineLock = _lockAmount(tokenId);
        uint256 baselineDrain = reserveBeforeA - furnace.furnaceReserve();

        require(vm.revertTo(snapId), "snapshot revert failed");

        // Run B (ladder): 7d -> 90d -> 270d -> 365d, spaced so the AMM virtual depth decays.
        uint256 reserveBeforeB = furnace.furnaceReserve();
        uint256[3] memory targets = [uint256(90 days), uint256(270 days), Constants.MAX_LOCK_DURATION];
        for (uint256 i = 0; i < targets.length; i++) {
            vm.warp(block.timestamp + SPACING);
            vm.prank(user);
            furnace.extendWithBonus(tokenId, targets[i], 0);
        }
        uint256 ladderLock = _lockAmount(tokenId);
        uint256 ladderDrain = reserveBeforeB - furnace.furnaceReserve();

        emit log_named_uint("baseline lock (1 extend)  ", baselineLock);
        emit log_named_uint("ladder   lock (3 extends) ", ladderLock);
        emit log_named_uint("baseline reserve drained  ", baselineDrain);
        emit log_named_uint("ladder   reserve drained  ", ladderDrain);

        // Path independence: the ladder must not out-earn a single extension by more than a
        // negligible AMM-curvature/rounding margin. Pricing on a fixed basis with virtual-depth
        // decay between spaced rungs makes the ladder earn slightly LESS — never more.
        assertLe(ladderLock, baselineLock + baselineLock / 2000, "ladder must not out-earn single extension");
        // Sanity: the ladder still earns the vast majority (>=90%) of the single-extension bonus,
        // confirming a real bonus was paid rather than the value collapsing to ~zero.
        uint256 baselineBonus = baselineLock - PRINCIPAL;
        uint256 ladderBonus = ladderLock - PRINCIPAL;
        assertGe(ladderBonus, (baselineBonus * 9) / 10, "ladder bonus unexpectedly small vs single extension");
    }

    /// @notice Same commitment, 10 uniform rungs. The advantage over a single extension must stay
    ///         negligible regardless of rung count.
    function test_AdvantageDoesNotScaleWithRungCount() public {
        _seedReserve(Constants.RESERVE_TARGET_FINAL);

        uint256 tokenId = _createLock(user, PRINCIPAL, Constants.MIN_LOCK_DURATION, false);
        uint256 startTs = block.timestamp;
        uint256 snapId = vm.snapshot();

        uint256 rungs = 10;

        vm.warp(startTs + rungs * SPACING);
        vm.prank(user);
        furnace.extendWithBonus(tokenId, Constants.MAX_LOCK_DURATION, 0);
        uint256 baselineLock = _lockAmount(tokenId);

        require(vm.revertTo(snapId), "snapshot revert failed");

        uint256 lo = Constants.MIN_LOCK_DURATION;
        uint256 hi = Constants.MAX_LOCK_DURATION;
        for (uint256 i = 1; i <= rungs; i++) {
            vm.warp(block.timestamp + SPACING);
            uint256 target = lo + ((hi - lo) * i) / rungs;
            vm.prank(user);
            furnace.extendWithBonus(tokenId, target, 0);
        }
        uint256 ladderLock = _lockAmount(tokenId);

        uint256 advantageBps = ladderLock > baselineLock ? ((ladderLock - baselineLock) * 10_000) / baselineLock : 0;
        emit log_named_uint("baseline lock (1 extend)   ", baselineLock);
        emit log_named_uint("ladder   lock (10 extends) ", ladderLock);
        emit log_named_uint("advantage (bps of baseline)", advantageBps);

        assertLt(advantageBps, 50, "10-rung ladder advantage must be negligible");
    }

    /// @notice `bonusBasis` seeds from the live amount on the first extend of a lock that predates
    ///         basis accounting (created directly on ve), then stays fixed as bonuses fold in.
    function test_BonusBasisSeedsOnceThenStaysFixed() public {
        _seedReserve(Constants.RESERVE_TARGET_FINAL);

        uint256 tokenId = _createLock(user, PRINCIPAL, Constants.MIN_LOCK_DURATION, false);
        assertEq(furnace.bonusBasis(tokenId), 0, "basis unset before first extend");

        vm.warp(block.timestamp + SPACING);
        vm.prank(user);
        furnace.extendWithBonus(tokenId, 90 days, 0);

        // Seeded from the live amount at first touch (== PRINCIPAL, no prior bonus folded in yet).
        assertEq(furnace.bonusBasis(tokenId), PRINCIPAL, "basis seeded from live amount on first extend");

        uint256 lockAfterFirst = _lockAmount(tokenId);
        assertGt(lockAfterFirst, PRINCIPAL, "first extend folded a bonus into the lock");

        vm.warp(block.timestamp + SPACING);
        vm.prank(user);
        furnace.extendWithBonus(tokenId, Constants.MAX_LOCK_DURATION, 0);

        // Basis is unchanged by folded bonuses: the second rung is priced off PRINCIPAL, not the
        // grown lock amount.
        assertEq(furnace.bonusBasis(tokenId), PRINCIPAL, "basis stays fixed as bonuses fold in");
    }
}
