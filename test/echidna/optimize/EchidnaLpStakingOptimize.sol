// SPDX-License-Identifier: MIT
pragma solidity ^0.8.34;

import {EchidnaSetup} from "../EchidnaSetup.sol";
import {LpStakingVault7D} from "src/vault/LpStakingVault7D.sol";
import {MintableERC20} from "src/mocks/MintableERC20.sol";
import {MockERC20} from "../../mocks/MockERC20.sol";
import {MockAerodromeRouter} from "../../mocks/MockAerodromeRouter.sol";

/// @title LpStakingVault7D economic worst-case search.
/// @notice Optimization-mode harness. Targets reward-pool over-credit, LP
///         custody shortfall, queued-carry overflow, and per-actor reward
///         gain. Each `optimize_*` function returns an `int256` Echidna
///         maximizes; positive values indicate accounting deviation from the
///         M3 conservation envelope on the staking surface.
contract EchidnaLpStakingOptimize is EchidnaSetup {
    LpStakingVault7D internal vault;
    MintableERC20 internal lpTokenLocal;
    address[3] internal actors;

    int256 internal worstUserEarnedAboveBalance;
    int256 internal worstQueuedAboveBalance;
    int256 internal worstStakedAboveLpBalance;
    int256 internal worstRewardSumAboveCredited;
    int256 internal worstActorRewardGain;

    constructor() payable {
        _deployAndWire();

        lpTokenLocal = new MintableERC20("LP Token", "LP", 18);
        MockERC20 wethLocal = new MockERC20("Wrapped Ether", "WETH");
        address factory = address(0xFACADE);
        MockAerodromeRouter router = new MockAerodromeRouter(factory, address(wethLocal));
        router.setPoolFor(address(wethLocal), address(claim), false, factory, address(lpTokenLocal));

        vault = new LpStakingVault7D(
            address(lpTokenLocal),
            address(wethLocal),
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

        lpTokenLocal.mint(address(this), 3_000_000e18);
        lpTokenLocal.approve(address(vault), type(uint256).max);
    }

    // ================================================================
    // Actions
    // ================================================================

    function action_stake(uint256 amount) public {
        if (amount == 0) amount = 1e18;
        if (amount > 100_000e18) amount = 100_000e18;
        if (lpTokenLocal.balanceOf(address(this)) < amount) return;
        try vault.stake(amount) {} catch {}
    }

    function action_beginUnbond(uint256 amount) public {
        if (amount == 0) amount = 1e18;
        if (amount > 100_000e18) amount = 100_000e18;
        try vault.beginUnbond(amount) {} catch {}
    }

    function action_withdrawMatured() public {
        try vault.withdrawMatured() {} catch {}
    }

    function action_claimRewards() public {
        // Stakes are placed in the harness's name (the vault sees address(this)
        // as msg.sender on `stake`/`claimRewards`). Track the harness CLAIM
        // balance, not msg.sender (the Echidna actor), to capture reward flow.
        uint256 claimBefore = claim.balanceOf(address(this));
        try vault.claimRewards() {
            uint256 claimAfter = claim.balanceOf(address(this));
            if (claimAfter > claimBefore) {
                int256 gain = int256(claimAfter - claimBefore);
                if (gain > worstActorRewardGain) worstActorRewardGain = gain;
            }
        } catch {}
    }

    function action_fundRewards(uint256 amount) public {
        if (amount == 0) amount = 1e18;
        if (amount > 1_000_000e18) amount = 1_000_000e18;
        mineCore.mintClaimForTest(address(vault), amount);
        try vault.notifyRewards(amount) {} catch {}
    }

    function action_takeover() public payable {
        uint256 price = mineCore.getCurrentTakeoverPrice();
        if (msg.value < price) return;
        try mineCore.takeover{value: price}(type(uint256).max) {} catch {}
    }

    function action_observeUserEarnedAboveBalance() public {
        uint256 balance = claim.balanceOf(address(vault));
        uint256 earned = vault.earned(address(this));
        int256 above = int256(earned) - int256(balance);
        if (above > worstUserEarnedAboveBalance) worstUserEarnedAboveBalance = above;
    }

    function action_observeQueuedAboveBalance() public {
        uint256 balance = claim.balanceOf(address(vault));
        uint256 queued = vault.queuedRewards();
        int256 above = int256(queued) - int256(balance);
        if (above > worstQueuedAboveBalance) worstQueuedAboveBalance = above;
    }

    function action_observeStakedAboveLpBalance() public {
        uint256 staked = vault.totalStaked();
        uint256 lpBal = lpTokenLocal.balanceOf(address(vault));
        int256 above = int256(staked) - int256(lpBal);
        if (above > worstStakedAboveLpBalance) worstStakedAboveLpBalance = above;
    }

    function action_observeRewardSumVsCredited() public {
        uint256 perUserSum = 0;
        for (uint256 i = 0; i < 3; i++) {
            perUserSum += vault.rewards(actors[i]);
        }
        perUserSum += vault.rewards(address(this));
        uint256 credited = vault.totalRewardsCredited();
        int256 diff = int256(perUserSum) - int256(credited);
        if (diff > worstRewardSumAboveCredited) worstRewardSumAboveCredited = diff;
        int256 negDiff = int256(credited) - int256(perUserSum);
        if (negDiff > worstRewardSumAboveCredited) worstRewardSumAboveCredited = negDiff;
    }

    // ================================================================
    // Optimization targets
    // ================================================================

    /// @notice Worst observed surplus of `earned()` over vault CLAIM custody.
    ///         Must remain `<= 0`.
    function optimize_lpStaking_userEarnedAboveBalance() public view returns (int256) {
        return worstUserEarnedAboveBalance;
    }

    /// @notice Worst observed surplus of `queuedRewards` over vault CLAIM
    ///         custody. Must remain `<= 0`.
    function optimize_lpStaking_queuedAboveBalance() public view returns (int256) {
        return worstQueuedAboveBalance;
    }

    /// @notice Worst observed surplus of `totalStaked` over vault LP custody.
    ///         Must remain `<= 0` (M3 LP conservation).
    function optimize_lpStaking_stakedAboveLpBalance() public view returns (int256) {
        return worstStakedAboveLpBalance;
    }

    /// @notice Worst observed absolute disagreement between
    ///         `Σ rewards(actor)` and `totalRewardsCredited`. Must remain
    ///         `<= 0` for the O(1) aggregator identity.
    function optimize_lpStaking_rewardSumDelta() public view returns (int256) {
        return worstRewardSumAboveCredited;
    }

    /// @notice Largest single-call CLAIM gain to a claiming actor. Bounded by
    ///         intended reward envelope.
    function optimize_lpStaking_actorRewardGain() public view returns (int256) {
        return worstActorRewardGain;
    }
}
