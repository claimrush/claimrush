// SPDX-License-Identifier: MIT
pragma solidity ^0.8.34;

import {Test} from "forge-std/Test.sol";

import {LpStakingVault7D} from "src/vault/LpStakingVault7D.sol";
import {DelegationHub} from "src/DelegationHub.sol";
import {Constants} from "src/lib/Constants.sol";
import {Events} from "src/lib/Events.sol";
import {Errors} from "src/lib/Errors.sol";
import {DelegationPermissions} from "src/lib/DelegationPermissions.sol";

import {MockERC20} from "./mocks/MockERC20.sol";
import {MockAerodromePool} from "./mocks/MockAerodromePool.sol";
import {MockAerodromeRouter} from "./mocks/MockAerodromeRouter.sol";
import {MockFurnaceLpRewards} from "./mocks/MockFurnaceLpRewards.sol";
import {MockVe} from "./mocks/MockVe.sol";

/// @dev Minimal furnace stub whose quoter always returns `veOut == 0`.
/// Exercises the LP-vault compound skip-on-zero-quote branch: a transient
/// or dust quote must not flip `cfg.paused` since the user can retry on the
/// next compound tick once liquidity recovers.
contract MockFurnaceZeroQuote {
    address public immutable claim;
    address public immutable ve;

    constructor(address claim_, address ve_) {
        claim = claim_;
        ve = ve_;
    }

    function furnaceQuoter() external view returns (address) {
        return address(this);
    }

    function quoteEnterWithClaim(address, uint256, uint256, uint256, bool)
        external
        pure
        returns (uint256 principalClaim, uint256 bonusClaim, uint256 veOut, uint256 routeTokenId)
    {
        return (0, 0, 0, 0);
    }

    function enterWithClaimFor(address, uint256, uint256, uint256, bool, uint256) external pure {
        // Should never be reached: skip-on-zero must short-circuit before
        // `enterWithClaimFor` is dispatched. Reverting here exposes a
        // regression that would leak the zero quote past the guard.
        revert("UNREACHABLE_ENTER_WITH_CLAIM_FOR");
    }
}

/// @dev Minimal furnace stub that always reverts on entry to test best-effort behavior.
contract MockFurnaceReverting {
    address public immutable claim;
    address public immutable ve;

    constructor(address claim_, address ve_) {
        claim = claim_;
        ve = ve_;
    }

    function furnaceQuoter() external view returns (address) {
        return address(this);
    }

    function quoteEnterWithClaim(address, uint256 amountClaimIn, uint256, uint256, bool)
        external
        pure
        returns (uint256 principalClaim, uint256 bonusClaim, uint256 veOut, uint256 routeTokenId)
    {
        // Return a non-zero quote so the compound flow proceeds to
        // `enterWithClaimFor` (which reverts), exercising the catch / pause
        // branch. A zero `veOut` would land on the skip-on-zero guard
        // before the Furnace call.
        return (amountClaimIn, 0, amountClaimIn, 0);
    }

    function enterWithClaimFor(address, uint256, uint256, uint256, bool, uint256) external pure {
        revert("FURNACE_REVERT");
    }
}

contract LpStakingVault7DAutoCompoundTest is Test {
    MockAerodromePool internal lp;
    MockERC20 internal weth;
    MockERC20 internal claim;

    MockVe internal ve;
    MockAerodromeRouter internal router;
    MockFurnaceLpRewards internal furnace;

    LpStakingVault7D internal vault;

    address internal factory = address(0xFACA);

    address internal alice = address(0xA11CE);
    address internal bob = address(0xB0B);
    address internal genesis = address(0xCAFE);
    address internal keeper = address(0xBEEF);
    address internal mineCore = address(0xC0DE);
    address internal delegate = address(0xD1E6);

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
        vm.etch(mineCore, hex"00");
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

    function _configureAlice(uint256 tokenId, uint256 lockEnd, bool autoMax, bool listed, uint256 durationSeconds)
        internal
    {
        ve.setOwner(tokenId, alice);
        ve.setLockInfo(tokenId, 1, lockEnd, autoMax, listed);

        vm.prank(alice);
        vault.setAutoCompoundConfig(true, tokenId, durationSeconds, 0, 0);
    }

    function testSetAutoCompoundConfigForUserRevertsWhenFurnaceDelegationHubDiffersFromMineCore() public {
        DelegationHub canonicalHub = new DelegationHub();
        DelegationHub evilHub = new DelegationHub();

        uint256 tokenId = 700;
        ve.setOwner(tokenId, alice);
        ve.setLockInfo(tokenId, 1, block.timestamp + 30 days, false, false);

        vm.prank(alice);
        evilHub.setSession(
            delegate, DelegationPermissions.P_SET_LP_AUTOCOMPOUND_CONFIG_FOR, uint64(block.timestamp + 1 days)
        );

        vm.mockCall(address(furnace), abi.encodeWithSignature("claim()"), abi.encode(address(claim)));
        vm.mockCall(address(furnace), abi.encodeWithSignature("ve()"), abi.encode(address(ve)));
        vm.mockCall(address(furnace), abi.encodeWithSignature("mineCore()"), abi.encode(mineCore));
        vm.mockCall(address(furnace), abi.encodeWithSignature("delegationHub()"), abi.encode(address(evilHub)));

        vm.mockCall(mineCore, abi.encodeWithSignature("claim()"), abi.encode(address(claim)));
        vm.mockCall(mineCore, abi.encodeWithSignature("ve()"), abi.encode(address(ve)));
        vm.mockCall(mineCore, abi.encodeWithSignature("furnace()"), abi.encode(address(furnace)));
        vm.mockCall(mineCore, abi.encodeWithSignature("delegationHub()"), abi.encode(address(canonicalHub)));

        vm.prank(delegate);
        vm.expectRevert(Errors.WiringMismatch.selector);
        vault.setAutoCompoundConfigForUser(alice, true, tokenId, 30 days, 0, 0);

        (bool enabled, bool paused, uint256 cfgTokenId, uint256 durationSeconds,,) = vault.getAutoCompoundConfig(alice);
        assertFalse(enabled);
        assertFalse(paused);
        assertEq(cfgTokenId, 0);
        assertEq(durationSeconds, 0);
    }

    function testSetAutoCompoundConfigForUserSucceedsWhenCanonicalHubAgrees() public {
        DelegationHub canonicalHub = new DelegationHub();

        uint256 tokenId = 701;
        ve.setOwner(tokenId, alice);
        ve.setLockInfo(tokenId, 1, block.timestamp + 30 days, false, false);

        vm.prank(alice);
        canonicalHub.setSession(
            delegate, DelegationPermissions.P_SET_LP_AUTOCOMPOUND_CONFIG_FOR, uint64(block.timestamp + 1 days)
        );

        vm.mockCall(address(furnace), abi.encodeWithSignature("claim()"), abi.encode(address(claim)));
        vm.mockCall(address(furnace), abi.encodeWithSignature("ve()"), abi.encode(address(ve)));
        vm.mockCall(address(furnace), abi.encodeWithSignature("mineCore()"), abi.encode(mineCore));
        vm.mockCall(address(furnace), abi.encodeWithSignature("delegationHub()"), abi.encode(address(canonicalHub)));

        vm.mockCall(mineCore, abi.encodeWithSignature("claim()"), abi.encode(address(claim)));
        vm.mockCall(mineCore, abi.encodeWithSignature("ve()"), abi.encode(address(ve)));
        vm.mockCall(mineCore, abi.encodeWithSignature("furnace()"), abi.encode(address(furnace)));
        vm.mockCall(mineCore, abi.encodeWithSignature("delegationHub()"), abi.encode(address(canonicalHub)));

        vm.prank(delegate);
        vault.setAutoCompoundConfigForUser(alice, true, tokenId, 30 days, 0, 0);

        (bool enabled, bool paused, uint256 cfgTokenId, uint256 durationSeconds,,) = vault.getAutoCompoundConfig(alice);
        assertTrue(enabled);
        assertFalse(paused);
        assertEq(cfgTokenId, tokenId);
        assertEq(durationSeconds, 30 days);
    }

    function testSetAutoCompoundConfigForUserRevertsWhenMineCoreFurnaceDiffersFromLiveFurnace() public {
        DelegationHub canonicalHub = new DelegationHub();

        uint256 tokenId = 702;
        ve.setOwner(tokenId, alice);
        ve.setLockInfo(tokenId, 1, block.timestamp + 30 days, false, false);

        vm.prank(alice);
        canonicalHub.setSession(
            delegate, DelegationPermissions.P_SET_LP_AUTOCOMPOUND_CONFIG_FOR, uint64(block.timestamp + 1 days)
        );

        vm.mockCall(address(furnace), abi.encodeWithSignature("claim()"), abi.encode(address(claim)));
        vm.mockCall(address(furnace), abi.encodeWithSignature("ve()"), abi.encode(address(ve)));
        vm.mockCall(address(furnace), abi.encodeWithSignature("mineCore()"), abi.encode(mineCore));
        vm.mockCall(address(furnace), abi.encodeWithSignature("delegationHub()"), abi.encode(address(canonicalHub)));

        vm.mockCall(mineCore, abi.encodeWithSignature("claim()"), abi.encode(address(claim)));
        vm.mockCall(mineCore, abi.encodeWithSignature("ve()"), abi.encode(address(ve)));
        vm.mockCall(mineCore, abi.encodeWithSignature("furnace()"), abi.encode(address(0xDEAD)));
        vm.mockCall(mineCore, abi.encodeWithSignature("delegationHub()"), abi.encode(address(canonicalHub)));

        vm.prank(delegate);
        vm.expectRevert(Errors.WiringMismatch.selector);
        vault.setAutoCompoundConfigForUser(alice, true, tokenId, 30 days, 0, 0);

        (bool enabled, bool paused, uint256 cfgTokenId, uint256 durationSeconds,,) = vault.getAutoCompoundConfig(alice);
        assertFalse(enabled);
        assertFalse(paused);
        assertEq(cfgTokenId, 0);
        assertEq(durationSeconds, 0);
    }

    function testCompoundFor_PausesWhenNotOwner_AndRewardsRemainClaimable() public {
        _stakeAlice(100e18);
        _fundRewards(100e18);

        uint256 tokenId = 1;
        _configureAlice(tokenId, block.timestamp + 30 days, false, false, 30 days);

        // Simulate transfer/sale of the NFT.
        ve.setOwner(tokenId, bob);

        vm.expectEmit(true, false, false, true);
        emit Events.AutoCompoundPaused(alice, tokenId, Constants.SHAREHOLDER_AUTOCOMPOUND_PAUSE_REASON_NOT_OWNER);

        vm.warp(block.timestamp + 1 days + 1);
        vm.prank(keeper);
        vault.compoundFor(alice);

        (bool enabled, bool paused, uint256 cfgTokenId, uint256 dur,,) = vault.getAutoCompoundConfig(alice);
        assertTrue(enabled);
        assertTrue(paused);
        assertEq(cfgTokenId, tokenId);
        assertEq(dur, 30 days);

        // User can still claim rewards.
        vm.prank(alice);
        vault.claimRewards();
        assertEq(claim.balanceOf(alice), 100e18);
    }

    function testCompoundFor_RevertsForNonKeeper() public {
        vm.expectRevert(Errors.NotAuthorized.selector);
        vm.prank(alice);
        vault.compoundFor(alice);
    }

    function testCompoundFor_OwnerAllowed() public {
        _stakeAlice(100e18);
        _fundRewards(100e18);

        uint256 tokenId = 98;
        _configureAlice(tokenId, block.timestamp + 30 days, false, false, 30 days);

        vm.warp(block.timestamp + 1 days + 1);
        vault.compoundFor(alice);

        assertEq(vault.rewards(alice), 0);
        assertEq(claim.balanceOf(address(furnace)), 100e18);
        assertEq(furnace.lastUser(), alice);
        assertEq(furnace.lastDurationSeconds(), 30 days);
        assertGt(furnace.lastMinVeOut(), 0);
    }

    function testCompoundForMany_RevertsForNonKeeper() public {
        address[] memory users = new address[](1);
        users[0] = alice;

        vm.expectRevert(Errors.NotAuthorized.selector);
        vm.prank(alice);
        vault.compoundForMany(users, 1);
    }

    function testCompoundFor_clampsMinVeOutToOneWhenComputedZero() public {
        _stakeAlice(100e18);
        _fundRewards(100e18);

        uint256 tokenId = 99;
        _configureAlice(tokenId, block.timestamp + 30 days, false, false, 30 days);

        // Force a tiny quote veOut so the slippage floor rounds down to 0.
        furnace.setQuote(0, 0, 1, 0);

        vm.warp(block.timestamp + 1 days + 1);
        vm.prank(keeper);
        vault.compoundFor(alice);

        assertEq(furnace.lastMinVeOut(), 1);
    }

    function testCompoundFor_UsesConfiguredLongerDurationForExistingLock() public {
        _stakeAlice(100e18);
        _fundRewards(100e18);

        uint256 tokenId = 100;
        uint256 remaining = 30 days;
        uint256 configured = 90 days;
        _configureAlice(tokenId, block.timestamp + remaining, false, false, configured);

        vm.warp(block.timestamp + 1 days + 1);
        vm.prank(keeper);
        vault.compoundFor(alice);

        assertEq(furnace.lastDurationSeconds(), configured);
    }

    function testFuzz_compoundFor_UsesMaxOfConfiguredAndRemainingDuration(uint40 remainingRaw, uint40 configuredRaw)
        public
    {
        _stakeAlice(100e18);
        _fundRewards(100e18);

        uint256 remaining = bound(uint256(remainingRaw), Constants.MIN_LOCK_DURATION, Constants.MAX_LOCK_DURATION);
        uint256 configured = bound(uint256(configuredRaw), Constants.MIN_LOCK_DURATION, Constants.MAX_LOCK_DURATION);

        uint256 tokenId = 101;
        vm.warp(block.timestamp + 1 days + 1);
        _configureAlice(tokenId, block.timestamp + remaining, false, false, configured);

        vm.prank(keeper);
        vault.compoundFor(alice);

        uint256 expected = configured;
        if (remaining > expected) expected = remaining;
        assertEq(furnace.lastDurationSeconds(), expected);
    }

    function testCompoundFor_CheckpointsPendingRewardsBeforeAutoCompound() public {
        _stakeAlice(100e18);

        uint256 tokenId = 111;
        _configureAlice(tokenId, block.timestamp + 30 days, false, false, 30 days);

        // Simulate CLAIM that already arrived in the vault after a prior best-effort notify failure.
        claim.mint(address(vault), 100e18);
        furnace.setQuote(100e18, 0, 1, 0);

        vm.warp(block.timestamp + 1 days + 1);
        vm.prank(keeper);
        vault.compoundFor(alice);

        assertEq(vault.rewardPerTokenStored(), 1e18, "pending rewards indexed before auto-compound");
        assertEq(furnace.enterCalls(), 1, "auto-compound executed");
        assertEq(furnace.lastClaimIn(), 100e18, "auto-compound consumes pending rewards immediately");
        assertEq(claim.balanceOf(address(furnace)), 100e18, "pending rewards routed into Furnace");
        assertEq(vault.accountedRewardBalance(), 0, "accounted balance reduced after locking");
    }

    function testCompoundFor_PausesWhenListed_AndRewardsRemainClaimable() public {
        _stakeAlice(100e18);
        _fundRewards(100e18);

        uint256 tokenId = 2;
        _configureAlice(tokenId, block.timestamp + 30 days, false, false, 30 days);

        // Mark lock as listed.
        ve.setLockInfo(tokenId, 1, block.timestamp + 30 days, false, true);

        vm.expectEmit(true, false, false, true);
        emit Events.AutoCompoundPaused(alice, tokenId, Constants.SHAREHOLDER_AUTOCOMPOUND_PAUSE_REASON_LISTED);

        vm.warp(block.timestamp + 1 days + 1);
        vm.prank(keeper);
        vault.compoundFor(alice);

        (, bool paused,,,,) = vault.getAutoCompoundConfig(alice);
        assertTrue(paused);

        vm.prank(alice);
        vault.claimRewards();
        assertEq(claim.balanceOf(alice), 100e18);
    }

    function testCompoundFor_PausesWhenExpired_AndRewardsRemainClaimable() public {
        _stakeAlice(100e18);
        _fundRewards(100e18);

        uint256 tokenId = 3;
        _configureAlice(tokenId, block.timestamp + 30 days, false, false, 30 days);

        // Expire the lock.
        ve.setLockInfo(tokenId, 1, block.timestamp, false, false);

        vm.expectEmit(true, false, false, true);
        emit Events.AutoCompoundPaused(alice, tokenId, Constants.SHAREHOLDER_AUTOCOMPOUND_PAUSE_REASON_EXPIRED);

        vm.warp(block.timestamp + 1 days + 1);
        vm.prank(keeper);
        vault.compoundFor(alice);

        (, bool paused,,,,) = vault.getAutoCompoundConfig(alice);
        assertTrue(paused);

        vm.prank(alice);
        vault.claimRewards();
        assertEq(claim.balanceOf(alice), 100e18);
    }

    function testCompoundFor_PausesWhenTokenBurned_AndRewardsRemainClaimable() public {
        _stakeAlice(100e18);
        _fundRewards(100e18);

        uint256 tokenId = 4;
        _configureAlice(tokenId, block.timestamp + 30 days, false, false, 30 days);

        // Simulate token burn: ownerOf(tokenId) should revert.
        ve.setOwner(tokenId, address(0));

        vm.expectEmit(true, false, false, true);
        emit Events.AutoCompoundPaused(alice, tokenId, Constants.SHAREHOLDER_AUTOCOMPOUND_PAUSE_REASON_INVALID_TOKEN_ID);

        vm.warp(block.timestamp + 1 days + 1);
        vm.prank(keeper);
        vault.compoundFor(alice);

        (, bool paused,,,,) = vault.getAutoCompoundConfig(alice);
        assertTrue(paused);

        vm.prank(alice);
        vault.claimRewards();
        assertEq(claim.balanceOf(alice), 100e18);
    }

    function testCompoundFor_BestEffortKeepsRewardsWhenFurnaceReverts() public {
        // Deploy a fresh vault wired to a reverting furnace.
        MockERC20 weth2 = new MockERC20("WETH", "WETH");
        MockERC20 claim2 = new MockERC20("CLAIM", "CLAIM");
        MockAerodromePool lp2 = new MockAerodromePool(address(weth2), address(claim2));
        MockVe ve2 = new MockVe();
        MockAerodromeRouter router2 = new MockAerodromeRouter(factory, address(weth2));
        router2.setPoolFor(address(weth2), address(claim2), false, factory, address(lp2));
        MockFurnaceReverting badFurnace = new MockFurnaceReverting(address(claim2), address(ve2));

        LpStakingVault7D v = new LpStakingVault7D(
            address(lp2),
            address(weth2),
            address(claim2),
            address(ve2),
            address(badFurnace),
            address(router2),
            factory,
            false,
            address(this)
        );

        // Stake and fund rewards.
        lp2.mint(alice, 100e18);
        vm.startPrank(alice);
        lp2.approve(address(v), type(uint256).max);
        v.stake(100e18);
        vm.stopPrank();

        claim2.mint(address(v), 123e18);
        vm.prank(address(badFurnace));
        v.notifyRewards(123e18);

        // Configure auto-compound with a valid token.
        uint256 tokenId = 1;
        ve2.setOwner(tokenId, alice);
        ve2.setLockInfo(tokenId, 1, block.timestamp + 30 days, false, false);

        vm.prank(alice);
        v.setAutoCompoundConfig(true, tokenId, 30 days, 0, 0);

        v.setHarvestKeeper(keeper, true);

        // Should not revert even though the furnace reverts.
        vm.warp(block.timestamp + 1 days + 1);
        vm.prank(keeper);
        v.compoundFor(alice);

        // Config should remain enabled; paused is set so the keeper does not waste gas re-trying.
        (bool enabled, bool paused,,,,) = v.getAutoCompoundConfig(alice);
        assertTrue(enabled);
        assertTrue(paused);

        // Rewards must remain claimable.
        assertEq(v.rewards(alice), 123e18);
        assertEq(v.totalClaimRewardsLockedViaFurnace(), 0);

        vm.prank(alice);
        v.claimRewards();
        assertEq(claim2.balanceOf(alice), 123e18);
    }

    function testCompoundFor_QuoteSkipsOnZeroVeOut() public {
        // The Furnace quote returns `veOut == 0` (a transient / dust quote).
        // The LP-vault compound path must skip the user without flipping
        // `cfg.paused`, mirroring the shareholder-side rule, so the user can
        // retry on the next compound tick once underlying liquidity recovers.
        MockERC20 weth2 = new MockERC20("WETH", "WETH");
        MockERC20 claim2 = new MockERC20("CLAIM", "CLAIM");
        MockAerodromePool lp2 = new MockAerodromePool(address(weth2), address(claim2));
        MockVe ve2 = new MockVe();
        MockAerodromeRouter router2 = new MockAerodromeRouter(factory, address(weth2));
        router2.setPoolFor(address(weth2), address(claim2), false, factory, address(lp2));
        MockFurnaceZeroQuote zeroFurnace = new MockFurnaceZeroQuote(address(claim2), address(ve2));

        LpStakingVault7D v = new LpStakingVault7D(
            address(lp2),
            address(weth2),
            address(claim2),
            address(ve2),
            address(zeroFurnace),
            address(router2),
            factory,
            false,
            address(this)
        );

        lp2.mint(alice, 100e18);
        vm.startPrank(alice);
        lp2.approve(address(v), type(uint256).max);
        v.stake(100e18);
        vm.stopPrank();

        claim2.mint(address(v), 50e18);
        vm.prank(address(zeroFurnace));
        v.notifyRewards(50e18);

        uint256 tokenId = 1;
        ve2.setOwner(tokenId, alice);
        ve2.setLockInfo(tokenId, 1, block.timestamp + 30 days, false, false);

        vm.prank(alice);
        v.setAutoCompoundConfig(true, tokenId, 30 days, 0, 0);

        v.setHarvestKeeper(keeper, true);

        vm.warp(block.timestamp + 1 days + 1);
        vm.prank(keeper);
        v.compoundFor(alice);

        // Skip path: enabled stays true, paused stays false. Rewards are
        // preserved for the next compound tick.
        (bool enabled, bool paused,,,,) = v.getAutoCompoundConfig(alice);
        assertTrue(enabled);
        assertEq(paused, false);
        assertEq(v.rewards(alice), 50e18);
        assertEq(v.totalClaimRewardsLockedViaFurnace(), 0);
    }

    function testCompoundForMany_ProcessesValidUsersAndPausesInvalidOnes() public {
        // Two stakers, equal stake, equal reward split.
        lp.mint(alice, 100e18);
        lp.mint(bob, 100e18);

        vm.startPrank(alice);
        lp.approve(address(vault), type(uint256).max);
        vault.stake(100e18);
        vm.stopPrank();

        vm.startPrank(bob);
        lp.approve(address(vault), type(uint256).max);
        vault.stake(100e18);
        vm.stopPrank();

        claim.mint(address(vault), 200e18);
        vm.prank(address(furnace));
        vault.notifyRewards(200e18);

        // Configure both.
        ve.setOwner(1, alice);
        ve.setLockInfo(1, 1, block.timestamp + 30 days, false, false);
        vm.prank(alice);
        vault.setAutoCompoundConfig(true, 1, 30 days, 0, 0);

        ve.setOwner(2, bob);
        ve.setLockInfo(2, 1, block.timestamp + 30 days, false, false);
        vm.prank(bob);
        vault.setAutoCompoundConfig(true, 2, 30 days, 0, 0);

        // Make bob invalid at execution-time.
        ve.setLockInfo(2, 1, block.timestamp + 30 days, false, true);

        address[] memory users = new address[](2);
        users[0] = alice;
        users[1] = bob;

        vm.warp(block.timestamp + 1 days + 1);
        vm.prank(keeper);
        vault.compoundForMany(users, 2);

        // Alice should have been compounded (rewards consumed into Furnace).
        assertEq(vault.rewards(alice), 0);
        assertEq(claim.balanceOf(address(furnace)), 100e18);

        // Bob should be paused and still able to claim rewards.
        (, bool paused,,,,) = vault.getAutoCompoundConfig(bob);
        assertTrue(paused);

        vm.prank(bob);
        vault.claimRewards();
        assertEq(claim.balanceOf(bob), 100e18);
    }

    function testCompoundForMany_OwnerAllowed() public {
        lp.mint(alice, 100e18);
        lp.mint(bob, 100e18);

        vm.startPrank(alice);
        lp.approve(address(vault), type(uint256).max);
        vault.stake(100e18);
        vm.stopPrank();

        vm.startPrank(bob);
        lp.approve(address(vault), type(uint256).max);
        vault.stake(100e18);
        vm.stopPrank();

        claim.mint(address(vault), 200e18);
        vm.prank(address(furnace));
        vault.notifyRewards(200e18);

        ve.setOwner(11, alice);
        ve.setLockInfo(11, 1, block.timestamp + 30 days, false, false);
        vm.prank(alice);
        vault.setAutoCompoundConfig(true, 11, 30 days, 0, 0);

        ve.setOwner(12, bob);
        ve.setLockInfo(12, 1, block.timestamp + 30 days, false, false);
        vm.prank(bob);
        vault.setAutoCompoundConfig(true, 12, 30 days, 0, 0);

        address[] memory users = new address[](2);
        users[0] = alice;
        users[1] = bob;

        vm.warp(block.timestamp + 1 days + 1);
        vault.compoundForMany(users, 2);

        assertEq(vault.rewards(alice), 0);
        assertEq(vault.rewards(bob), 0);
        assertEq(furnace.enterCalls(), 2);
        assertEq(claim.balanceOf(address(furnace)), 200e18);
    }

    function testSetAutoCompoundConfig_autoMaxRequiresMaxDuration() public {
        uint256 tokenId = 1;
        ve.setOwner(tokenId, alice);
        ve.setLockInfo(tokenId, 1, block.timestamp + 30 days, true, false);

        vm.prank(alice);
        vm.expectRevert(Errors.InvalidDuration.selector);
        vault.setAutoCompoundConfig(true, tokenId, 30 days, 0, 0);

        vm.prank(alice);
        vault.setAutoCompoundConfig(true, tokenId, Constants.MAX_LOCK_DURATION, 0, 0);

        (bool enabled, bool paused, uint256 cfgTokenId, uint256 dur,,) = vault.getAutoCompoundConfig(alice);
        assertTrue(enabled);
        assertFalse(paused);
        assertEq(cfgTokenId, tokenId);
        assertEq(dur, Constants.MAX_LOCK_DURATION);
    }

    function testSetAutoCompoundConfig_autoMaxAllowsStaleStoredEnd() public {
        uint256 tokenId = 1;
        ve.setOwner(tokenId, alice);
        ve.setLockInfo(tokenId, 1, 0, true, false);

        vm.prank(alice);
        vault.setAutoCompoundConfig(true, tokenId, Constants.MAX_LOCK_DURATION, 0, 0);

        (bool enabled,, uint256 cfgTokenId, uint256 dur,,) = vault.getAutoCompoundConfig(alice);
        assertTrue(enabled);
        assertEq(cfgTokenId, tokenId);
        assertEq(dur, Constants.MAX_LOCK_DURATION);
    }

    function testCompoundFor_autoMaxDoesNotPauseOnExpired() public {
        _stakeAlice(100e18);
        _fundRewards(100e18);

        uint256 tokenId = 1;
        // AutoMax + stale/expired stored end.
        ve.setOwner(tokenId, alice);
        ve.setLockInfo(tokenId, 1, 0, true, false);

        vm.prank(alice);
        vault.setAutoCompoundConfig(true, tokenId, Constants.MAX_LOCK_DURATION, 0, 0);

        vm.warp(block.timestamp + 1 days + 1);
        vm.prank(keeper);
        vault.compoundFor(alice);

        // Should compound successfully (rewards consumed into Furnace) and MUST NOT pause.
        assertEq(vault.rewards(alice), 0);
        assertEq(claim.balanceOf(address(furnace)), 100e18);
        assertEq(furnace.lastDurationSeconds(), Constants.MAX_LOCK_DURATION);

        (, bool paused,,,,) = vault.getAutoCompoundConfig(alice);
        assertFalse(paused);
    }
}
