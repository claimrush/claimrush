// SPDX-License-Identifier: MIT
pragma solidity ^0.8.34;

import {EchidnaSetup} from "../EchidnaSetup.sol";
import {Constants} from "src/lib/Constants.sol";

/// @title MineCore economic worst-case search.
/// @notice Optimization-mode harness. Each `optimize_*` function returns an
///         `int256` that Echidna maximizes. Targets the King takeover loop:
///         royalty-split shortfall, ETH escrow imbalance, takeover-grief delay,
///         and per-actor net profit relative to ETH spent. Positive values
///         indicate deviation from the intended economic envelope.
/// @dev    Mirrors the action set of `EchidnaMineCore`. Property and assertion
///         coverage live in the standard suite; this file is the optimizer.
contract EchidnaMineCoreOptimize is EchidnaSetup {
    int256 internal worstShareholderShortfall;
    int256 internal worstEthSurplus;
    int256 internal worstTakeoverPriceBelowFloor;
    int256 internal worstActorEthGainAboveSpend;

    uint256 internal cumulativeEthIn;
    uint256 internal cumulativeShareholderObserved;

    constructor() payable {
        _deployAndWire();
    }

    // ================================================================
    // Actions
    // ================================================================

    function action_takeover() public payable {
        uint256 price = mineCore.getCurrentTakeoverPrice();
        if (msg.value < price) return;

        uint256 shareholderBefore = address(royalties).balance;
        uint256 actorEthBefore = msg.sender.balance;

        try mineCore.takeover{value: price}(type(uint256).max) {
            cumulativeEthIn += price;
            uint256 shareholderAfter = address(royalties).balance;
            cumulativeShareholderObserved += (shareholderAfter - shareholderBefore);

            uint256 actorEthAfter = msg.sender.balance;
            if (actorEthAfter > actorEthBefore) {
                int256 gain = int256(actorEthAfter - actorEthBefore) - int256(price);
                if (gain > worstActorEthGainAboveSpend) worstActorEthGainAboveSpend = gain;
            }
        } catch {}
    }

    function action_withdrawKingBalance() public {
        try mineCore.withdrawKingBalance() {} catch {}
    }

    function action_withdrawRefundBalance() public {
        try mineCore.withdrawRefundBalance(msg.sender) {} catch {}
    }

    function action_retryPushShareholderEth() public {
        try mineCore.retryPushShareholderEth() {} catch {}
    }

    function action_setTakeoversPaused(bool paused) public {
        try mineCore.setTakeoversPaused(paused) {} catch {}
    }

    function action_observeShareholderShortfall() public {
        if (cumulativeEthIn == 0) return;
        uint256 kingShareTotal = (cumulativeEthIn * Constants.KING_ETH_SHARE_PCT) / Constants.KING_ETH_SHARE_DENOM;
        uint256 expectedShareholder = cumulativeEthIn - kingShareTotal;
        // Net out the pending bucket on MineCore: shareholder ETH that has
        // been allocated but not yet pushed to royalties is still in flight.
        uint256 pending = mineCore.shareholderEthPending();
        uint256 delivered = cumulativeShareholderObserved + pending;
        if (expectedShareholder > delivered) {
            uint256 shortfall = expectedShareholder - delivered;
            int256 s = int256(shortfall);
            if (s > worstShareholderShortfall) worstShareholderShortfall = s;
        }
    }

    function action_observeEthSurplus() public {
        // System ETH bound by what was paid in. Surplus over inflow indicates
        // unaccounted ETH credited to a tracked bucket — accounting drift.
        uint256 systemEth = address(mineCore).balance + address(royalties).balance;
        if (systemEth > cumulativeEthIn) {
            int256 surplus = int256(systemEth - cumulativeEthIn);
            if (surplus > worstEthSurplus) worstEthSurplus = surplus;
        }
    }

    function action_observePriceBelowFloor() public {
        uint256 price = mineCore.getCurrentTakeoverPrice();
        int256 below = int256(uint256(Constants.TAKEOVER_PRICE_FLOOR)) - int256(price);
        if (below > worstTakeoverPriceBelowFloor) worstTakeoverPriceBelowFloor = below;
    }

    // ================================================================
    // Optimization targets
    // ================================================================

    /// @notice Largest observed shortfall of (cumulative shareholder receipts
    ///         + pending bucket) vs the (1 - KING_ETH_SHARE_PCT) share of
    ///         cumulative inflow. Must remain `<= 0`.
    /// @dev    Surface prefix `mc_` is the shorthand for MineCore across the
    ///         optimization-target naming scheme.
    function optimize_mc_shareholderShortfall() public view returns (int256) {
        return worstShareholderShortfall;
    }

    /// @notice Largest observed surplus of (mineCore ETH + royalties ETH) over
    ///         cumulative ETH paid in via takeovers. Must remain `<= 0`.
    function optimize_mc_ethSurplus() public view returns (int256) {
        return worstEthSurplus;
    }

    /// @notice Largest observed shortfall of `getCurrentTakeoverPrice()` below
    ///         `TAKEOVER_PRICE_FLOOR`. Must remain `<= 0`.
    function optimize_mc_priceBelowFloor() public view returns (int256) {
        return worstTakeoverPriceBelowFloor;
    }

    /// @notice Largest observed ETH gain to a takeover actor in excess of the
    ///         price they paid in the same transaction. Bounded by King-payout
    ///         envelope; sustained large positive values indicate exploit.
    function optimize_mc_actorEthGainAboveSpend() public view returns (int256) {
        return worstActorEthGainAboveSpend;
    }
}
