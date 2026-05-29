// SPDX-License-Identifier: MIT
pragma solidity ^0.8.34;

import {Test} from "forge-std/Test.sol";

import {LpStakingVault7D} from "src/vault/LpStakingVault7D.sol";
import {DelegationHub} from "src/DelegationHub.sol";
import {Constants} from "src/lib/Constants.sol";
import {Errors} from "src/lib/Errors.sol";
import {DelegationPermissions} from "src/lib/DelegationPermissions.sol";

import {MockERC20} from "../mocks/MockERC20.sol";
import {MockAerodromePool} from "../mocks/MockAerodromePool.sol";
import {MockAerodromeRouter} from "../mocks/MockAerodromeRouter.sol";
import {MockFurnaceLpRewards} from "../mocks/MockFurnaceLpRewards.sol";
import {MockVe} from "../mocks/MockVe.sol";

contract LpStakingVault7DStateMachineInvariants is Test {
    MockERC20 internal weth;
    MockERC20 internal claim;
    MockAerodromePool internal lp;
    MockVe internal ve;
    MockAerodromeRouter internal router;
    MockFurnaceLpRewards internal furnace;
    LpStakingVault7D internal vault;

    address internal genesis;
    address internal factory;
    bool internal stable;

    address internal alice;
    address internal bob;
    address internal carol;
    address internal compoundKeeper;
    address internal mineCore;
    address internal delegate;

    address[] internal stakers;

    uint256 internal lastRPT;

    function setUp() public {
        vm.txGasPrice(0);

        genesis = makeAddr("genesis");
        factory = address(0xFACADE);
        stable = false;

        alice = makeAddr("alice");
        bob = makeAddr("bob");
        carol = makeAddr("carol");
        compoundKeeper = makeAddr("compoundKeeper");
        mineCore = makeAddr("mineCore");
        delegate = makeAddr("delegate");

        weth = new MockERC20("Wrapped Ether", "WETH");
        claim = new MockERC20("Claim", "CLAIM");
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
            stable,
            address(this)
        );
        vault.setHarvestKeeper(compoundKeeper, true);
        vm.etch(mineCore, hex"00");

        stakers.push(alice);
        stakers.push(bob);
        stakers.push(carol);

        // Seed LP balances + approvals.
        lp.mint(alice, 10_000e18);
        lp.mint(bob, 10_000e18);
        lp.mint(carol, 10_000e18);

        for (uint256 i = 0; i < stakers.length; i++) {
            address u = stakers[i];
            vm.startPrank(u);
            lp.approve(address(vault), type(uint256).max);
            vm.stopPrank();
        }

        // Seed ve tokenIds so auto-compound config can be toggled on without reverts.
        // Note: MockVe doesn't enforce MAX_LOCK_DURATION; we set a far-future lockEnd to keep it valid.
        ve.setOwner(1, alice);
        ve.setLockInfo(1, 1e18, block.timestamp + 10_000 days, false, false);

        ve.setOwner(2, bob);
        ve.setLockInfo(2, 1e18, block.timestamp + 10_000 days, false, false);

        ve.setOwner(3, carol);
        ve.setLockInfo(3, 1e18, block.timestamp + 10_000 days, false, false);

        lastRPT = vault.rewardPerTokenStored();
    }

    function testFuzz_constructorRejectsAnyNonCanonicalPool(address badPool) public {
        vm.assume(badPool != address(0));
        vm.assume(badPool != address(lp));

        vm.expectRevert(Errors.InvalidPool.selector);
        new LpStakingVault7D(
            badPool,
            address(weth),
            address(claim),
            address(ve),
            address(furnace),
            address(router),
            factory,
            stable,
            address(this)
        );
    }

    function testFuzz_constructorRejectsAnyFurnaceVeRootMismatch(address badVe) public {
        vm.assume(badVe != address(0));
        vm.assume(badVe != address(ve));

        MockFurnaceLpRewards wrongFurnace = new MockFurnaceLpRewards(address(claim), badVe);

        vm.expectRevert(Errors.WiringMismatch.selector);
        new LpStakingVault7D(
            address(lp),
            address(weth),
            address(claim),
            address(ve),
            address(wrongFurnace),
            address(router),
            factory,
            stable,
            address(this)
        );
    }

    function testSetAutoCompoundConfigForUserRejectsMineCoreFurnaceDrift() public {
        DelegationHub canonicalHub = new DelegationHub();
        uint256 tokenId = 77;

        ve.setOwner(tokenId, alice);
        ve.setLockInfo(tokenId, 1e18, block.timestamp + 30 days, false, false);

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

    /// @notice Stateful fuzz exploring stake/unbond/withdraw/notify/claim/lock/compound/harvest flows.
    ///         Invariants focus on:
    ///         - LP accounting: vault LP balance == totalStaked + totalUnbonded
    ///         - reward accounting: accountedRewardBalance <= CLAIM balance
    ///         - conservation: all minted CLAIM ends up in vault/furnace/users
    function testFuzz_stateMachine_preservesLpAndAccountedClaim(uint256 seed) public {
        uint256 steps = 20;

        for (uint256 i = 0; i < steps; i++) {
            bytes32 h = keccak256(abi.encode(seed, i));

            _advanceTime(h);

            uint8 action = uint8(uint256(h) % 9);
            address user = stakers[uint256(uint8(uint256(h >> 8))) % stakers.length];

            if (action == 0) {
                _stake(user, _randAmount(h, 250e18));
            } else if (action == 1) {
                _beginUnbond(user, _randAmount(h, 250e18));
            } else if (action == 2) {
                _withdrawMatured(user);
            } else if (action == 3) {
                _fundAndNotify(_randAmount(h, 500e18));
            } else if (action == 4) {
                _claimRewards(user);
            } else if (action == 5) {
                _claimRewardsAndLock(user);
            } else if (action == 6) {
                _toggleAutoCompound(user, (uint256(h >> 16) & 1) == 1);
            } else if (action == 7) {
                _compoundFor(user);
            } else {
                _harvestFeesToRewards(h);
            }

            _assertInvariants();
        }

        _assertInvariants();
    }

    function testFuzz_pendingBalanceDeltaIsIndexedBeforeLateStake(
        uint96 aliceStakeRaw,
        uint96 bobStakeRaw,
        uint96 pendingRewardRaw
    ) public {
        uint256 aliceStakeAmt = bound(uint256(aliceStakeRaw), 1e18, 1_000e18);
        uint256 bobStakeAmt = bound(uint256(bobStakeRaw), 1e18, 1_000e18);
        uint256 pendingReward = bound(uint256(pendingRewardRaw), 1e18, 1_000_000e18);

        vm.prank(alice);
        vault.stake(aliceStakeAmt);

        // Simulate CLAIM that already reached the vault before a successful notifier checkpoint.
        claim.mint(address(vault), pendingReward);

        vm.prank(bob);
        vault.stake(bobStakeAmt);

        uint256 expectedRPT = (pendingReward * 1e18) / aliceStakeAmt;
        uint256 expectedAliceEarned = (aliceStakeAmt * expectedRPT) / 1e18;

        assertEq(vault.rewardPerTokenStored(), expectedRPT, "pending delta indexed on pre-stake denominator");
        assertEq(vault.earned(alice), expectedAliceEarned, "existing stake keeps prior pending rewards");
        assertEq(vault.earned(bob), 0, "late stake cannot capture prior pending rewards");
        assertEq(vault.accountedRewardBalance(), pendingReward, "pending balance delta checkpointed");
    }

    function testFuzz_pendingBalanceDeltaIsIndexedBeforeManualClaim(uint96 aliceStakeRaw, uint96 pendingRewardRaw)
        public
    {
        uint256 aliceStakeAmt = bound(uint256(aliceStakeRaw), 1e18, 1_000e18);
        uint256 pendingReward = bound(uint256(pendingRewardRaw), 1e18, 1_000_000e18);

        vm.prank(alice);
        vault.stake(aliceStakeAmt);

        // Simulate CLAIM that already reached the vault before a successful notifier checkpoint.
        claim.mint(address(vault), pendingReward);

        vm.prank(alice);
        vault.claimRewards();

        uint256 expectedRPT = (pendingReward * 1e18) / aliceStakeAmt;

        assertEq(vault.rewardPerTokenStored(), expectedRPT, "pending delta indexed before manual claim");
        assertLe(claim.balanceOf(alice), pendingReward + 2048, "manual claim upper bound");
        assertGe(claim.balanceOf(alice), pendingReward - 2048, "manual claim lower bound");
        assertLe(vault.accountedRewardBalance(), 2048, "accounted balance cleared after payout");
    }

    function testFuzz_compoundUsesMaxOfConfiguredAndRemainingDuration(uint40 remainingRaw, uint40 configuredRaw)
        public
    {
        uint256 remaining = bound(uint256(remainingRaw), Constants.MIN_LOCK_DURATION, Constants.MAX_LOCK_DURATION);
        uint256 configured = bound(uint256(configuredRaw), Constants.MIN_LOCK_DURATION, Constants.MAX_LOCK_DURATION);

        vm.prank(alice);
        vault.stake(100e18);

        vm.warp(block.timestamp + 1 days + 1);

        ve.setLockInfo(1, 1e18, block.timestamp + remaining, false, false);

        vm.prank(alice);
        vault.setAutoCompoundConfig(true, 1, configured, 0, 0);

        _fundAndNotify(100e18);

        vm.prank(compoundKeeper);
        vault.compoundFor(alice);

        uint256 expected = configured;
        if (remaining > expected) expected = remaining;
        assertEq(furnace.lastDurationSeconds(), expected, "compound uses max(config, remaining)");
    }

    function testFuzz_rewardRemainderCarriesAcrossSuccessiveNotifies(uint128 firstRaw, uint128 secondRaw) public {
        uint256 firstReward = bound(uint256(firstRaw), 1, 1_000_000);
        uint256 secondReward = bound(uint256(secondRaw), 1, 1_000_000);

        vm.prank(alice);
        vault.stake(1e18);

        vm.prank(bob);
        vault.stake(2e18);

        claim.mint(address(vault), firstReward);
        vm.prank(address(furnace));
        vault.notifyRewards(0);

        claim.mint(address(vault), secondReward);
        vm.prank(address(furnace));
        vault.notifyRewards(0);

        uint256 totalReward = firstReward + secondReward;
        uint256 expectedRPT = totalReward / 3;
        uint256 expectedQueued = totalReward - (expectedRPT * 3);

        assertEq(vault.rewardPerTokenStored(), expectedRPT, "reward remainder carried across notifies");
        assertEq(vault.queuedRewards(), expectedQueued, "only true remainder stays queued");
        assertEq(vault.earned(alice), expectedRPT, "alice earns her full carried share");
        assertEq(vault.earned(bob), expectedRPT * 2, "bob earns his full carried share");
    }

    function testFuzz_queuedRemainderSurvivesFirstStakeUntilLaterNotify(uint128 queuedRaw, uint128 laterRaw) public {
        uint256 queuedReward = bound(uint256(queuedRaw), 1, 1_000_000);
        uint256 laterReward = bound(uint256(laterRaw), 1, 1_000_000);

        claim.mint(address(vault), queuedReward);
        vm.prank(address(furnace));
        vault.notifyRewards(0);

        vm.prank(alice);
        vault.stake(3e18);

        claim.mint(address(vault), laterReward);
        vm.prank(address(furnace));
        vault.notifyRewards(0);

        uint256 totalReward = queuedReward + laterReward;
        uint256 expectedRPT = totalReward / 3;
        uint256 expectedQueued = totalReward - (expectedRPT * 3);

        assertEq(vault.rewardPerTokenStored(), expectedRPT, "first stake preserves queued remainder");
        assertEq(vault.queuedRewards(), expectedQueued, "only residual dust remains queued after first stake");
        assertEq(vault.earned(alice), expectedRPT * 3, "sole staker eventually receives full queued amount");
    }

    function testFuzz_harvestCountsOnlyFreshFeesNotPreexistingPendingRewards(
        uint96 pendingRewardRaw,
        uint96 feeClaimRaw
    ) public {
        uint256 pendingReward = bound(uint256(pendingRewardRaw), 1e18, 1_000_000e18);
        uint256 feeClaim = bound(uint256(feeClaimRaw), 1e18, 1_000_000e18);

        vm.prank(alice);
        vault.stake(100e18);

        // Simulate CLAIM already sitting in the vault after a prior best-effort notify failure.
        claim.mint(address(vault), pendingReward);

        // Harvest brings in fresh CLAIM fees only.
        lp.setNextFees(0, feeClaim);
        address harvester = makeAddr("feeHarvester");
        vault.setHarvestKeeper(harvester, true);

        vm.prank(harvester);
        vault.harvestFeesToRewards(block.timestamp + 1, 0);

        assertEq(vault.totalClaimRewardsFundedFromVaultFees(), feeClaim, "fee counter excludes older pending rewards");
        assertLe(vault.earned(alice), pendingReward + feeClaim + 2048, "staker earned upper bound");
        assertGe(vault.earned(alice), pendingReward + feeClaim - 2048, "staker earned lower bound");
    }

    // ------------------------------------------------------------
    // Actions
    // ------------------------------------------------------------

    function _advanceTime(bytes32 h) internal {
        // Bump time up to 2 days per step to traverse unbonding windows.
        uint256 dt = uint256(uint16(uint256(h >> 240))) % 2 days;
        if (dt != 0) vm.warp(block.timestamp + dt);
    }

    function _randAmount(bytes32 h, uint256 max) internal pure returns (uint256) {
        // [1..max]
        uint256 x = uint256(h);
        return (x % max) + 1;
    }

    function _stake(address user, uint256 amount) internal {
        uint256 bal = lp.balanceOf(user);
        // Vault rejects any stake < MIN_UNBOND_AMOUNT (anti-dust); skip if the user
        // can't even meet the floor, otherwise clamp up to it.
        if (bal < Constants.MIN_UNBOND_AMOUNT) return;
        if (amount < Constants.MIN_UNBOND_AMOUNT) amount = Constants.MIN_UNBOND_AMOUNT;
        if (amount > bal) amount = bal;

        vm.prank(user);
        vault.stake(amount);
    }

    function _beginUnbond(address user, uint256 amount) internal {
        uint256 staked = vault.stakedBalance(user);
        if (staked == 0) return;

        // Respect MAX_UNBONDS_PER_USER (spec: 25).
        if (vault.getUnbondCount(user) >= 25) return;

        if (amount > staked) amount = staked;

        // Vault rejects partial unbonds < MIN_UNBOND_AMOUNT but permits the
        // full-exit form (amount == stakedBalance). Mirror that here so the
        // harness only invokes contract paths that are valid by construction.
        if (amount < Constants.MIN_UNBOND_AMOUNT) {
            if (staked >= Constants.MIN_UNBOND_AMOUNT) {
                amount = Constants.MIN_UNBOND_AMOUNT;
            } else {
                amount = staked;
            }
        }

        vm.prank(user);
        vault.beginUnbond(amount);
    }

    function _withdrawMatured(address user) internal {
        vm.prank(user);
        vault.withdrawMatured();
    }

    function _fundAndNotify(uint256 amount) internal {
        // Fund the vault directly and notify from the configured reward notifier.
        claim.mint(address(vault), amount);

        vm.prank(address(furnace));
        vault.notifyRewards(0);
    }

    function _claimRewards(address user) internal {
        vm.prank(user);
        (bool ok,) = address(vault).call(abi.encodeWithSelector(vault.claimRewards.selector));
        ok;
    }

    function _claimRewardsAndLock(address user) internal {
        vm.prank(user);
        (bool ok,) =
            address(vault).call(abi.encodeWithSelector(vault.claimRewardsAndLock.selector, 0, 30 days, false, 1));
        ok;
    }

    function _toggleAutoCompound(address user, bool enabled) internal {
        // Each user has a deterministic tokenId: 1,2,3.
        uint256 tokenId = user == alice ? 1 : (user == bob ? 2 : 3);
        uint256 duration = 30 days;
        if (duration < Constants.MIN_LOCK_DURATION) duration = Constants.MIN_LOCK_DURATION;
        if (duration > Constants.MAX_LOCK_DURATION) duration = Constants.MAX_LOCK_DURATION;

        vm.prank(user);
        vault.setAutoCompoundConfig(enabled, tokenId, duration, 0, 0);
    }

    function _compoundFor(address user) internal {
        vm.prank(compoundKeeper);
        vault.compoundFor(user);
    }

    function _harvestFeesToRewards(bytes32 h) internal {
        // Make sure we actually have something to harvest.
        uint256 feeWeth = (uint256(uint16(uint256(h >> 32))) % 50e18) + 1;
        uint256 feeClaim = (uint256(uint16(uint256(h >> 48))) % 50e18);

        lp.setNextFees(feeWeth, feeClaim);

        address harvester = makeAddr("harvester");
        vault.setHarvestKeeper(harvester, true);
        vm.prank(harvester);
        (bool ok,) =
            address(vault).call(abi.encodeWithSelector(vault.harvestFeesToRewards.selector, block.timestamp + 1, 1));
        ok;
    }

    // ------------------------------------------------------------
    // Invariants
    // ------------------------------------------------------------

    function _assertInvariants() internal {
        // 1) rewardPerTokenStored is monotonic.
        uint256 rpt = vault.rewardPerTokenStored();
        assertGe(rpt, lastRPT, "rewardPerTokenStored decreased");
        lastRPT = rpt;

        // 2) accountedRewardBalance is always <= actual CLAIM balance.
        assertLe(vault.accountedRewardBalance(), claim.balanceOf(address(vault)), "accounted > balance");

        // 3) LP held by the vault equals staked + total unbonded.
        uint256 stakedSum;
        uint256 unbondSum;
        for (uint256 i = 0; i < stakers.length; i++) {
            address u = stakers[i];
            stakedSum += vault.stakedBalance(u);

            uint256 n = vault.getUnbondCount(u);
            for (uint256 j = 0; j < n; j++) {
                (, uint256 amt,) = vault.getUnbondByIndex(u, j);
                unbondSum += amt;
            }
        }

        assertEq(vault.totalStaked(), stakedSum, "totalStaked != sum(stakedBalance)");
        assertEq(lp.balanceOf(address(vault)), vault.totalStaked() + unbondSum, "LP balance mismatch");

        // 4) In this harness, all minted CLAIM should live in {vault, furnace, users}.
        uint256 sum = claim.balanceOf(address(vault)) + claim.balanceOf(address(furnace)) + claim.balanceOf(alice)
            + claim.balanceOf(bob) + claim.balanceOf(carol);

        assertEq(claim.totalSupply(), sum, "CLAIM supply leaked");
    }
}
