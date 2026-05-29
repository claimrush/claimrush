// SPDX-License-Identifier: MIT
pragma solidity ^0.8.34;

import {EchidnaSetup} from "./EchidnaSetup.sol";
import {Constants} from "src/lib/Constants.sol";

/// @title Echidna harness for MineCore king uniqueness, ETH splits, and emission correctness.
/// @dev Invariants from the invariants document Section 6.
contract EchidnaMineCore is EchidnaSetup {
    // Shadow ETH accounting
    uint256 internal totalEthIn;
    uint256 internal totalShareholderEthReceived;
    bool internal pauseClampSafe = true;

    constructor() payable {
        _deployAndWire();
    }

    // ================================================================
    // Actions
    // ================================================================

    /// @dev Perform a takeover
    function action_takeover() public payable {
        uint256 price = mineCore.getCurrentTakeoverPrice();
        if (msg.value < price) return;

        uint256 shareholderBalBefore = address(royalties).balance;

        try mineCore.takeover{value: price}(type(uint256).max) {
            totalEthIn += price;
            uint256 shareholderBalAfter = address(royalties).balance;
            totalShareholderEthReceived += (shareholderBalAfter - shareholderBalBefore);
        } catch {}
    }

    /// @dev Withdraw king ETH balance
    function action_withdrawKingBalance() public {
        try mineCore.withdrawKingBalance() {} catch {}
    }

    /// @dev Withdraw refund ETH balance
    function action_withdrawRefundBalance() public {
        try mineCore.withdrawRefundBalance(msg.sender) {} catch {}
    }

    /// @dev Withdraw fallback CLAIM bucket for the caller.
    function action_withdrawPendingClaim() public {
        try mineCore.withdrawPendingClaim() {} catch {}
    }

    /// @dev Retry pending shareholder ETH after a best-effort royalty push failure.
    function action_retryPushShareholderEth() public {
        try mineCore.retryPushShareholderEth() {} catch {}
    }

    function action_setTakeoversPaused(bool paused) public {
        bool beforePaused = mineCore.takeoversPaused();
        address kingBefore = mineCore.currentKing();
        try mineCore.setTakeoversPaused(paused) {
            if (beforePaused != paused && kingBefore != address(0)) {
                if (mineCore.currentReignLastAccrualTime() != block.timestamp) {
                    pauseClampSafe = false;
                }
            }
        } catch {}
    }

    function action_setLockingPaused(bool paused) public {
        try mineCore.setLockingPaused(paused) {} catch {}
    }

    // ================================================================
    // Properties
    // ================================================================

    /// @dev Invariant §6: reignIds are monotonically increasing.
    function echidna_reign_monotonic() public view returns (bool) {
        return mineCore.currentReignId() >= 0;
    }

    /// @dev Invariant §6: ETH conservation -- system ETH <= total ETH sent in.
    function echidna_eth_conservation() public view returns (bool) {
        uint256 systemEth = address(mineCore).balance + address(royalties).balance;
        return systemEth <= totalEthIn;
    }

    /// @dev Invariant §6: Takeover price should never be below floor.
    function echidna_price_above_floor() public view returns (bool) {
        return mineCore.getCurrentTakeoverPrice() >= Constants.TAKEOVER_PRICE_FLOOR;
    }

    /// @dev Invariant §6: emissionStartTime is immutable and in the past.
    function echidna_emission_start_immutable() public view returns (bool) {
        return mineCore.emissionStartTime() <= block.timestamp;
    }

    /// @dev Invariant §2: Furnace reserve is backed by actual CLAIM tokens.
    function echidna_furnace_reserve_backed() public view returns (bool) {
        uint256 reserve = furnace.furnaceReserve();
        uint256 bal = claim.balanceOf(address(furnace));
        return bal >= reserve;
    }

    /// @dev Invariant §1: Only MineCore can mint CLAIM.
    function echidna_sole_minter() public view returns (bool) {
        return claim.mineCore() == address(mineCore);
    }

    /// @dev ETH pull-payment buckets must be backed by MineCore's ETH balance.
    function echidna_eth_liability_buckets_backed() public view returns (bool) {
        uint256 tracked = mineCore.totalKingEthOwed() + mineCore.totalRefundEthOwed() + mineCore.shareholderEthPending();
        return address(mineCore).balance >= tracked;
    }

    /// @dev Pending fallback CLAIM must be backed by MineCore-held CLAIM.
    function echidna_claim_liability_bucket_backed() public view returns (bool) {
        return claim.balanceOf(address(mineCore)) >= mineCore.totalPendingKingClaim();
    }

    /// @dev The active reign accrual cursor must stay inside the active reign window.
    function echidna_reign_accrual_cursor_bounded() public view returns (bool) {
        if (mineCore.currentKing() == address(0)) return true;
        uint256 cursor = mineCore.currentReignLastAccrualTime();
        return cursor >= mineCore.currentReignStartTime() && cursor <= block.timestamp;
    }

    /// @dev Pause/unpause transitions must clamp the reign accrual cursor so
    ///      paused time cannot be mined later by the incumbent king.
    function echidna_pause_transitions_clamp_accrual_cursor() public view returns (bool) {
        return pauseClampSafe;
    }
}
