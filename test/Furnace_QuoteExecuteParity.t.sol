// SPDX-License-Identifier: MIT
pragma solidity ^0.8.34;

import {Test} from "forge-std/Test.sol";

import {ClaimToken} from "src/ClaimToken.sol";
import {DelegationHub} from "src/DelegationHub.sol";
import {FurnaceQuoter} from "src/FurnaceQuoter.sol";
import {MineCore} from "src/MineCore.sol";
import {ShareholderRoyalties} from "src/ShareholderRoyalties.sol";
import {Constants} from "src/lib/Constants.sol";

import {FurnaceHarness} from "./mocks/FurnaceHarness.sol";
import {MockContract} from "./mocks/MockContract.sol";
import {MockEntryTokenRegistry} from "./mocks/MockEntryTokenRegistry.sol";
import {MockLpRewardsVault} from "./mocks/MockLpRewardsVault.sol";
import {VeClaimNFTHarness} from "./mocks/VeClaimNFTHarness.sol";

/// @title Furnace quote = execute (wei-exact M2 anchor)
/// @notice Anchors the M2 property for `extendWithBonus` to the wei. The
///         FurnaceQuoter MUST return the exact same `bonusClaim` that
///         `Furnace.extendWithBonus` emits at the call boundary, across an
///         input sweep that exercises every active region of the duration
///         weight curve and the AMM virtual-depth state.
///
///         A property-test sibling to `FurnaceMetaPropertiesTest::M2` that
///         tightens the tolerance from `1` (rounding slack) to `0` (wei-
///         exact). Catches any future drift between the quoter's
///         `_quoteBonusAmmView` and the live `_extendWithBonus` accrual path.
contract FurnaceQuoteExecuteParityTest is Test {
    ClaimToken internal claim;
    VeClaimNFTHarness internal ve;
    MineCore internal mineCore;
    FurnaceHarness internal furnace;
    FurnaceQuoter internal furnaceQuoter;
    MockLpRewardsVault internal lpVault;
    ShareholderRoyalties internal royalties;
    DelegationHub internal delegationHub;

    address internal owner = address(0xA11CE);
    address internal alice = address(0xA11C3);
    address internal mineMarket;
    address internal registry;
    address internal mineCoreRegistry;

    uint256 internal _aliceTokenId;

    function setUp() public {
        _deploy();
    }

    function _deploy() internal {
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

        _seedReserve(50_000_000e18);
        _aliceTokenId = _createLock(alice, 100_000e18, 270 days);
        vm.warp(block.timestamp + 1);
    }

    function _seedReserve(uint256 amount) internal {
        vm.prank(address(mineCore));
        claim.mint(address(furnace), amount);
        vm.prank(address(mineCore));
        furnace.creditReserve(amount);
    }

    function _createLock(address user, uint256 amount, uint256 duration) internal returns (uint256) {
        vm.prank(address(mineCore));
        claim.mint(user, amount);
        vm.startPrank(user);
        claim.approve(address(ve), type(uint256).max);
        uint256 tokenId = ve.createLock(amount, duration, false);
        vm.stopPrank();
        return tokenId;
    }

    /// @notice Wei-exact: the quoter MUST report the same `bonusClaim` the
    ///         contract emits, across an input sweep that exercises both the
    ///         180-270d and 270d-MAX segments of the curve.
    function test_QuoteEqualsExecute_WeiExact_AcrossSweep() public {
        uint256[6] memory durationDeltas = [uint256(1 days), 7 days, 30 days, 90 days, 180 days, 365 days];

        for (uint256 i = 0; i < durationDeltas.length; i++) {
            // Snapshot fresh state so each iteration sees identical curve /
            // AMM depth and is comparable against the others. The pinned
            // forge-std at this commit exposes the legacy `vm.snapshot()` /
            // `vm.revertTo()` cheatcodes, not the renamed `snapshotState` /
            // `revertToState` aliases.
            uint256 snap = vm.snapshot();

            (, uint256 lockEnd,,) = ve.getLockInfo(_aliceTokenId);
            uint256 newRemaining = (lockEnd - block.timestamp) + durationDeltas[i];
            if (newRemaining > Constants.MAX_LOCK_DURATION) {
                newRemaining = Constants.MAX_LOCK_DURATION;
            }

            // Quote first (read-only).
            (, uint256 quotedBonus,) = furnaceQuoter.quoteExtendWithBonus(alice, _aliceTokenId, newRemaining);

            // Execute and capture the emitted bonus.
            vm.prank(alice);
            uint256 executedBonus = furnace.extendWithBonus(_aliceTokenId, newRemaining, 0);

            assertEq(
                quotedBonus, executedBonus, "quote-execute parity broken: quoter and live path disagree at the wei"
            );

            vm.revertTo(snap);
        }
    }
}
