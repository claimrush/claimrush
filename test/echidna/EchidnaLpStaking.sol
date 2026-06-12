// SPDX-License-Identifier: MIT
pragma solidity ^0.8.34;

import {EchidnaSetup} from "./EchidnaSetup.sol";
import {LpStakingVault7D} from "src/vault/LpStakingVault7D.sol";
import {Constants} from "src/lib/Constants.sol";
import {MintableERC20} from "src/mocks/MintableERC20.sol";
import {MockERC20} from "../mocks/MockERC20.sol";
import {MockAerodromeRouter} from "../mocks/MockAerodromeRouter.sol";

/// @title Echidna harness for LpStakingVault7D LP custody, reward accounting, and unbond lifecycle.
/// @dev Invariants from the invariants document Section 14.
///
/// The harness holds LP tokens and approves the vault.
/// Previously, LP was minted to actor addresses but since Echidna calls action_*
/// on this contract, msg.sender inside vault.stake() is address(this), not the actor.
/// Without approval from address(this), all action_stake calls silently failed,
/// rendering every staking invariant trivially satisfied.
contract EchidnaLpStaking is EchidnaSetup {
    LpStakingVault7D internal vault;
    MintableERC20 internal lpToken;
    address[3] internal actors;

    /// @dev Tracks total LP staked through the harness (for cross-check invariants).
    uint256 internal ghost_totalStaked;

    /// @dev Tracks previous rewardPerTokenStored to verify monotonicity.
    uint256 internal ghost_lastRPT;

    constructor() payable {
        _deployAndWire();

        lpToken = new MintableERC20("LP Token", "LP", 18);
        MockERC20 weth = new MockERC20("Wrapped Ether", "WETH");
        address factory = address(0xFACADE);
        MockAerodromeRouter router = new MockAerodromeRouter(factory, address(weth));
        router.setPoolFor(address(weth), address(claim), false, factory, address(lpToken));

        vault = new LpStakingVault7D(
            address(lpToken),
            address(weth),
            address(claim),
            address(ve),
            address(furnace),
            address(router),
            factory,
            false,
            address(this)
        );

        actors[0] = address(0x20000);
        actors[1] = address(0x30000);
        actors[2] = address(0x40000);

        // Mint LP to the harness (address(this)) since all vault interactions
        // originate from this contract. Approve vault to pull LP from the harness.
        lpToken.mint(address(this), 3_000_000e18);
        lpToken.approve(address(vault), type(uint256).max);
    }

    // ================================================================
    // Actions
    // ================================================================

    function action_stake(uint256 amount) public {
        if (amount == 0) amount = 1e18;
        if (amount > 100_000e18) amount = 100_000e18;
        if (lpToken.balanceOf(address(this)) < amount) return;
        try vault.stake(amount) {
            ghost_totalStaked += amount;
        } catch {}
    }

    function action_beginUnbond(uint256 amount) public {
        if (amount == 0) amount = 1e18;
        if (amount > 100_000e18) amount = 100_000e18;

        // Mirror the vault's documented round-up: when the post-unbond residual would
        // be below MIN_UNBOND_AMOUNT, beginUnbond consumes the full stake instead of
        // the requested amount (LpStakingVault7D.sol lines 299-303). The ghost must
        // mirror this exactly or the cross-check property drifts every time the round-up
        // path is taken with random fuzzed amounts.
        uint256 myStake = vault.stakedBalance(address(this));
        uint256 actualAmount = amount;
        if (myStake >= amount) {
            uint256 residual = myStake - amount;
            if (residual != 0 && residual < Constants.MIN_UNBOND_AMOUNT) {
                actualAmount = myStake;
            }
        }

        try vault.beginUnbond(amount) {
            ghost_totalStaked -= actualAmount;
        } catch {}
    }

    function action_withdrawMatured() public {
        try vault.withdrawMatured() {} catch {}
    }

    function action_claimRewards() public {
        try vault.claimRewards() {} catch {}
    }

    function action_takeover() public payable {
        uint256 price = mineCore.getCurrentTakeoverPrice();
        if (msg.value < price) return;
        try mineCore.takeover{value: price}(type(uint256).max) {} catch {}
    }

    /// @dev Set auto-compound config for the caller
    function action_setAutoCompoundConfig(uint256 durationSeconds) public {
        if (durationSeconds < Constants.MIN_LOCK_DURATION) durationSeconds = Constants.MIN_LOCK_DURATION;
        if (durationSeconds > Constants.MAX_LOCK_DURATION) durationSeconds = Constants.MAX_LOCK_DURATION;
        try vault.setAutoCompoundConfig(true, 0, durationSeconds, 500, 0) {} catch {}
    }

    /// @dev Claim and lock rewards through Furnace
    function action_claimRewardsAndLock(uint256 durationSeconds) public {
        if (durationSeconds < Constants.MIN_LOCK_DURATION) durationSeconds = Constants.MIN_LOCK_DURATION;
        if (durationSeconds > Constants.MAX_LOCK_DURATION) durationSeconds = Constants.MAX_LOCK_DURATION;
        try vault.claimRewardsAndLock(0, durationSeconds, false, 1) {} catch {}
    }

    /// @dev Fund rewards to the vault (simulates Furnace notifications).
    function action_fundRewards(uint256 amount) public {
        if (amount == 0) amount = 1e18;
        if (amount > 1_000_000e18) amount = 1_000_000e18;
        mineCore.mintClaimForTest(address(vault), amount);
        try vault.notifyRewards(amount) {} catch {}
    }

    // ================================================================
    // Properties
    // ================================================================

    /// @dev Invariant §14: LP token balance of vault >= totalStaked.
    function echidna_lp_custody() public view returns (bool) {
        return lpToken.balanceOf(address(vault)) >= vault.totalStaked();
    }

    /// @dev Invariant §14: totalStaked never exceeds LP balance.
    function echidna_total_staked_consistent() public view returns (bool) {
        return vault.totalStaked() <= lpToken.balanceOf(address(vault));
    }

    /// @dev Invariant §14: rewardPerTokenStored is monotonically non-decreasing.
    ///      Compare against ghost_lastRPT instead of a trivial >= 0 check.
    function echidna_reward_per_token_monotonic() public returns (bool) {
        uint256 rpt = vault.rewardPerTokenStored();
        bool ok = rpt >= ghost_lastRPT;
        ghost_lastRPT = rpt;
        return ok;
    }

    /// @dev Invariant: CLAIM balance >= accountedRewardBalance (no over-accounting).
    function echidna_claim_solvency() public view returns (bool) {
        return claim.balanceOf(address(vault)) >= vault.accountedRewardBalance();
    }

    /// @dev STRICT user-facing solvency: the `earned()` live preview cannot exceed
    ///      the vault's CLAIM custody. Holds with no tolerance because `_earned`
    ///      clamps the per-user accrual to `indexedClaimOwed - totalRewardsCredited`
    ///      (the unallocated portion of the indexed pool). The clamp eliminates the
    ///      floor-additivity drift class — combined-floor across N notify cycles can
    ///      no longer over-credit the user beyond the indexed pool that backs them.
    function echidna_user_earned_backed() public view returns (bool) {
        uint256 balance = claim.balanceOf(address(vault));
        return vault.earned(address(this)) <= balance;
    }

    /// @dev STRICT carry-bucket bound: `queuedRewards <= claim.balanceOf(vault)`.
    ///      `queuedRewards` only ever holds CLAIM that is physically present in the
    ///      vault but not yet indexed; it is debited atomically when the next notify
    ///      ingests it via `_indexRewardsWithCarry`. The strict bound has no tolerance.
    function echidna_queued_carry_bounded() public view returns (bool) {
        uint256 balance = claim.balanceOf(address(vault));
        return vault.queuedRewards() <= balance;
    }

    /// @dev STRICT debt-accounting identity:
    ///      `Σ rewards(actor) + indexedClaimOwed_unallocated + queuedRewards
    ///        + (claim.balanceOf(vault) - accountedRewardBalance) == claim.balanceOf(vault)`
    ///      where `indexedClaimOwed_unallocated = indexedClaimOwed - totalRewardsCredited`
    ///      and the trailing term is any pending balance-delta not yet indexed.
    ///      Equivalently: `Σ rewards(actor) + indexedClaimOwed + queuedRewards <=
    ///      claim.balanceOf(vault)` AND `totalRewardsCredited == Σ rewards(actor)`.
    function echidna_lp_debt_accounting_exact() public view returns (bool) {
        uint256 perUserSum = 0;
        for (uint256 i = 0; i < 3; i++) {
            perUserSum += vault.rewards(actors[i]);
        }
        perUserSum += vault.rewards(address(this));
        uint256 indexedPool = vault.indexedClaimOwed();
        uint256 queued = vault.queuedRewards();
        uint256 balance = claim.balanceOf(address(vault));
        // Per-user sum must agree with the O(1) credited aggregator.
        if (perUserSum != vault.totalRewardsCredited()) return false;
        // Indexed pool can never exceed the vault custody backing it.
        if (indexedPool + queued > balance) return false;
        // Crystallised per-user rewards must fit inside the indexed pool.
        return perUserSum <= indexedPool;
    }

    /// @dev STRICT O(1) aggregator agreement: `totalRewardsCredited == Σ_actor rewards(actor)`.
    ///      Probes the per-checkpoint delta tracking inside `_updateReward` and the
    ///      matched debits in `claimRewards` / `claimRewardsAndLock` / auto-compound
    ///      success path.
    function echidna_total_credited_matches_sum() public view returns (bool) {
        uint256 perUserSum = 0;
        for (uint256 i = 0; i < 3; i++) {
            perUserSum += vault.rewards(actors[i]);
        }
        perUserSum += vault.rewards(address(this));
        return vault.totalRewardsCredited() == perUserSum;
    }

    /// @dev Ghost stake exactly mirrors totalStaked because matured withdrawals only move unbonded LP.
    function echidna_total_staked_matches_ghost() public view returns (bool) {
        return vault.totalStaked() == ghost_totalStaked;
    }
}
