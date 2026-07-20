// SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

import "forge-std/Test.sol";
import {MineCoreHelper} from "src/MineCoreHelper.sol";

/// @title PoC: pause clamp forfeits the sitting king's PRE-PAUSE active emissions
/// @notice Demonstrates that `MineCore.setTakeoversPaused` advancing
///         `currentReignLastAccrualTime = block.timestamp` on pause ENTRY
///         (MineCore.sol:502) WITHOUT first minting the already-accrued window
///         destroys the king's pre-pause ACTIVE accrual — not just the paused time.
///
/// Verified cursor trajectory produced by MineCore (emissionStartTime = 0):
///   t=1000  takeover -> currentReignLastAccrualTime = 1000  (MineCore.sol:1216)
///   t=1500  pause    -> currentReignLastAccrualTime = 1500  (MineCore.sol:502, mints NOTHING)
///   t=1800  unpause  -> currentReignLastAccrualTime = 1800  (MineCore.sol:502, mints NOTHING)
///   t=2000  takeover -> mints _kingEmitted(accrualStart = 1800, 2000)  (MineCore.sol:1132-1135)
///
/// Intended behavior per the inline comment at MineCore.sol:500 ("so paused time
/// is never mined later") is to exclude ONLY the paused window [1500,1800].
/// The implementation instead also forfeits the active window [1000,1500].
contract PauseAccrualForfeiturePoC is Test {
    MineCoreHelper helper;
    uint256 constant EST = 0; // emissionStartTime

    function setUp() public {
        helper = new MineCoreHelper();
    }

    function test_PauseClampBurnsPrePauseActiveAccrual() public {
        uint256 reignStart = 1000; //  king takes throne
        uint256 pauseTs = 1500; //  500s of ACTIVE reign elapses, then guardian pauses
        uint256 unpauseTs = 1800; //  300s paused (legitimately excluded)
        uint256 takeoverTs = 2000; //  200s active after unpause, then next takeover finalizes

        // What MineCore ACTUALLY mints to the king at finalization (cursor pinned to unpauseTs):
        uint256 actuallyMinted = helper.kingEmitted(EST, unpauseTs, takeoverTs); // [1800,2000]

        // What SHOULD be minted if only the paused window were excluded:
        //   active = [reignStart, pauseTs] + [unpauseTs, takeoverTs]
        uint256 prePauseActive = helper.kingEmitted(EST, reignStart, pauseTs); // [1000,1500]
        uint256 owedPausedExcludedOnly = prePauseActive + actuallyMinted;

        uint256 forfeited = owedPausedExcludedOnly - actuallyMinted;

        emit log_named_uint("actuallyMinted (buggy)       ", actuallyMinted);
        emit log_named_uint("owed (paused-time-excluded)  ", owedPausedExcludedOnly);
        emit log_named_uint("forfeited CLAIM (pre-pause)  ", forfeited);
        emit log_named_uint("forfeited as pct of owed (%) ", (forfeited * 100) / owedPausedExcludedOnly);

        // The forfeited amount is exactly the pre-pause ACTIVE window the king earned.
        assertEq(forfeited, prePauseActive, "forfeit must equal pre-pause active accrual");

        // Magnitude: ~25,000 CLAIM lost from a 500s active window early in the schedule
        // (launch rate ~50 CLAIM/s). The loss DWARFS what the king is actually paid.
        assertGt(forfeited, actuallyMinted * 2, "loss dwarfs the amount actually paid");
        assertGt(forfeited, 20_000e18, "early-schedule loss is on the order of tens of thousands of CLAIM");
    }
}
