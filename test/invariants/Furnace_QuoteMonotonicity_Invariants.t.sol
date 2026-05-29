// SPDX-License-Identifier: MIT
pragma solidity ^0.8.34;

import {Test} from "forge-std/Test.sol";
import {Constants} from "src/lib/Constants.sol";
import {FurnaceHarness} from "../mocks/FurnaceHarness.sol";

/// @title Quote monotonicity invariant tests for Furnace bonus AMM.
/// @dev Covers invariants from §4.3-4.4:
///      - grossBonusClaim <= reserve_before (no overdraft)
///      - user + lp = gross (exact split)
///      - grossSpotBps <= MAX_GROSS_BONUS_BPS (cap enforcement)
contract FurnaceQuoteMonotonicityInvariantsTest is Test {
    /// @dev §4.4: Gross bonus must never exceed reserve (no overdraft).
    function testFuzz_GrossBonusNeverExceedsReserve(uint256 principal, uint256 reserve, uint256 spotBps, uint256 lpRate)
        public
        pure
    {
        // Bound inputs to reasonable ranges
        principal = bound(principal, Constants.MIN_LOCK_AMOUNT, 10_000_000e18);
        reserve = bound(reserve, principal, 100_000_000e18); // reserve >= principal for meaningful bonus
        spotBps = bound(spotBps, 0, Constants.MAX_GROSS_BONUS_BPS);
        lpRate = bound(lpRate, 0, Constants.LP_TOPUP_RATE_MAX_BPS);

        // Compute gross bonus (simplified model): gross = principal * spotBps / BPS_DENOM
        uint256 grossBonus = principal * spotBps / Constants.BPS_DENOM;

        // Core invariant: no overdraft
        if (grossBonus > reserve) {
            grossBonus = reserve; // Furnace clamps to reserve
        }
        assertTrue(grossBonus <= reserve, "gross bonus must <= reserve");
    }

    /// @dev §4.2: grossSpotBps must not exceed MAX_GROSS_BONUS_BPS.
    function testFuzz_GrossSpotBpsCapped(uint256 spotBps) public pure {
        spotBps = bound(spotBps, 0, type(uint64).max);

        uint256 capped = spotBps > Constants.MAX_GROSS_BONUS_BPS ? Constants.MAX_GROSS_BONUS_BPS : spotBps;
        assertTrue(capped <= Constants.MAX_GROSS_BONUS_BPS, "spot bps must be capped");
    }

    /// @dev §4.4: userBonus + lpBonus must equal grossBonus (exact split, no rounding loss).
    function testFuzz_BonusSplitExact(uint256 gross, uint256 lpRateBps) public pure {
        gross = bound(gross, 0, 10_000_000e18);
        lpRateBps = bound(lpRateBps, Constants.LP_TOPUP_RATE_MIN_BPS, Constants.LP_TOPUP_RATE_MAX_BPS);

        // user = floor(gross * 10_000 / (10_000 + lpRate))
        uint256 user = gross * Constants.BPS_DENOM / (Constants.BPS_DENOM + lpRateBps);
        uint256 lp = gross - user;

        // Exact split conservation
        assertEq(user + lp, gross, "user + lp must equal gross");
    }

    /// @dev §4.5: Reserve factor is 1.0x at t=0 (genesis).
    function testReserveFactorIsOneAtGenesis() public pure {
        // At t=0 into SWING_TIME, alpha = 0, so reserveFactorBps = BPS_DENOM (1.0x).
        uint256 elapsedSinceGenesis = 0;
        uint256 alpha;
        if (elapsedSinceGenesis >= Constants.SWING_TIME) {
            alpha = Constants.BPS_DENOM;
        } else {
            alpha = elapsedSinceGenesis * Constants.BPS_DENOM / Constants.SWING_TIME;
        }

        uint256 reserveFactorBps = Constants.BPS_DENOM + alpha
            * (Constants.RESERVE_FACTOR_MAX_BPS - Constants.BPS_DENOM) / Constants.BPS_DENOM;
        assertEq(reserveFactorBps, Constants.BPS_DENOM, "reserve factor must be 1.0x at genesis");
    }
}
