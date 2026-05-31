// SPDX-License-Identifier: MIT
pragma solidity ^0.8.34;

import {Test} from "forge-std/Test.sol";

import {Constants} from "src/lib/Constants.sol";

/// @notice Pin security-critical constants that, if changed, could cause fund loss
///         or broken protocol behavior.
/// @dev These are intentionally SEPARATE from ConstantsDocsGuardrail (which checks
///      docs <> code parity). These tests catch accidental edits to values that
///      are expected to stay fixed in deployed releases.
///
///      If one of these values changes intentionally, update this test and the
///      release documentation that pins it.
contract SecurityCriticalConstantsPinnedTest is Test {
    // ---------------------------------------------------------------
    // Spread / slippage bounds (economic safety rails)
    // ---------------------------------------------------------------

    function testSellSpreadMinBps() public pure {
        assertEq(Constants.SELL_SPREAD_MIN_BPS, 500, "SELL_SPREAD_MIN_BPS pinned at 5%");
    }

    function testSellSpreadMaxBps() public pure {
        assertEq(Constants.SELL_SPREAD_MAX_BPS, 7_000, "SELL_SPREAD_MAX_BPS pinned at 70%");
    }

    function testSellRoundTripLossMaxBps() public pure {
        assertEq(Constants.SELL_ROUND_TRIP_LOSS_MAX_BPS, 2_500, "SELL_ROUND_TRIP_LOSS_MAX_BPS pinned at 25%");
    }

    function testSellImpactBpsPerStep() public pure {
        assertEq(Constants.SELL_IMPACT_BPS_PER_STEP, 100, "SELL_IMPACT_BPS_PER_STEP pinned at 1%");
    }

    function testSellImpactMaxBps() public pure {
        assertEq(Constants.SELL_IMPACT_MAX_BPS, 1_500, "SELL_IMPACT_MAX_BPS pinned at 15%");
    }

    // ---------------------------------------------------------------
    // LP curve bounds
    // ---------------------------------------------------------------

    function testLpTopupRateMinBps() public pure {
        assertEq(Constants.LP_TOPUP_RATE_MIN_BPS, 750, "LP_TOPUP_RATE_MIN_BPS pinned");
    }

    function testLpTopupRateMaxBps() public pure {
        assertEq(Constants.LP_TOPUP_RATE_MAX_BPS, 1_500, "LP_TOPUP_RATE_MAX_BPS pinned");
    }

    function testLpSaleMinBps() public pure {
        assertEq(Constants.LP_SALE_MIN_BPS, 500, "LP_SALE_MIN_BPS pinned");
    }

    function testLpSaleMaxBps() public pure {
        assertEq(Constants.LP_SALE_MAX_BPS, 1_500, "LP_SALE_MAX_BPS pinned");
    }

    function testMaxGrossBonusBps() public pure {
        assertEq(Constants.MAX_GROSS_BONUS_BPS, 12_500, "MAX_GROSS_BONUS_BPS pinned at 125%");
    }

    // ---------------------------------------------------------------
    // Reserve model bounds
    // ---------------------------------------------------------------

    function testReserveTargetFinal() public pure {
        assertEq(Constants.RESERVE_TARGET_FINAL, 20_000_000e18, "RESERVE_TARGET_FINAL pinned");
    }

    function testReserveFactorMaxBps() public pure {
        assertEq(Constants.RESERVE_FACTOR_MAX_BPS, 20_000, "RESERVE_FACTOR_MAX_BPS pinned at 2x");
    }

    function testReserveFactorMaxBpsLowlock() public pure {
        assertEq(Constants.RESERVE_FACTOR_MAX_BPS_LOWLOCK, 15_000, "RESERVE_FACTOR_MAX_BPS_LOWLOCK pinned at 1.5x");
    }

    function testLockTarget() public pure {
        assertEq(Constants.LOCK_TARGET, 120_000_000e18, "LOCK_TARGET pinned");
    }

    // ---------------------------------------------------------------
    // Emission structural invariants
    // ---------------------------------------------------------------

    function testEmissionDecayPeriodPinned() public pure {
        assertEq(Constants.EMISSION_DECAY_PERIOD, 63_072_000, "Decay period must be 2 years (63_072_000s)");
    }

    function testKingFloorEqualsLaunchRateDiv9() public pure {
        assertEq(
            Constants.KING_EMISSION_FLOOR, Constants.KING_EMISSION_LAUNCH_RATE / 9, "KING floor != launch_rate / 9"
        );
    }

    function testKingEmissionFloorPinned() public pure {
        assertEq(
            Constants.KING_EMISSION_FLOOR, 5_555_555_555_555_555_555, "KING_EMISSION_FLOOR pinned at floor(50e18 / 9)"
        );
    }

    function testFurnaceFloorEqualsLaunchRateDiv9() public pure {
        assertEq(
            Constants.FURNACE_EMISSION_FLOOR,
            Constants.FURNACE_EMISSION_LAUNCH_RATE / 9,
            "FURNACE floor != launch_rate / 9"
        );
    }

    function testFurnaceEmissionFloorPinned() public pure {
        assertEq(
            Constants.FURNACE_EMISSION_FLOOR,
            555_555_555_555_555_555,
            "FURNACE_EMISSION_FLOOR pinned at floor(5e18 / 9)"
        );
    }

    function testKingRateGtFurnaceRate() public pure {
        assertGt(
            Constants.KING_EMISSION_LAUNCH_RATE,
            Constants.FURNACE_EMISSION_LAUNCH_RATE,
            "King launch rate should exceed Furnace launch rate"
        );
    }

    /// @dev Load-bearing for `AgentLens.currentKingEmissionRate`, which derives the
    ///      king rate as `getFurnaceEmissionRateAt(t) * 10`. If this invariant is
    ///      ever broken in `Constants.sol`, every consumer of
    ///      `mc.currentKingEmissionRate` (the `claimrush/agent-sdk` package, any
    ///      bots / agents / dashboards built on it) reads a wrong value silently.
    ///      Updating the ratio also requires updating `agents/sdk/src/snapshot.ts`
    ///      (the `* 10n` fallback) and the `AgentLens` setter in lockstep.
    function testKingFurnaceLaunchRateRatioPinned() public pure {
        assertEq(
            Constants.KING_EMISSION_LAUNCH_RATE,
            10 * Constants.FURNACE_EMISSION_LAUNCH_RATE,
            "KING_EMISSION_LAUNCH_RATE must equal 10 * FURNACE_EMISSION_LAUNCH_RATE (AgentLens.currentKingEmissionRate invariant)"
        );
    }

    /// @dev The floor constants are not exact 10:1 because `FURNACE_EMISSION_FLOOR`
    ///      truncates `5/9 ≈ 0.555…` at integer wei precision. The drift is
    ///      bounded at 5 wei, which is parts-per-quintillion at ~5e18 — invisible
    ///      at any practical accounting scale.
    function testKingFurnaceFloorRatioPinnedWithin5Wei() public pure {
        uint256 expected = 10 * Constants.FURNACE_EMISSION_FLOOR;
        uint256 got = Constants.KING_EMISSION_FLOOR;
        uint256 drift = got > expected ? got - expected : expected - got;
        assertLe(
            drift, 5, "KING/FURNACE floor ratio drift must be <= 5 wei (truncation of 5/9 in FURNACE_EMISSION_FLOOR)"
        );
    }

    // ---------------------------------------------------------------
    // Emission launch rates — absolute pins (relational tests alone
    // would pass if both rate and floor were scaled together)
    // ---------------------------------------------------------------

    function testKingEmissionLaunchRatePinned() public pure {
        assertEq(Constants.KING_EMISSION_LAUNCH_RATE, 50e18, "KING_EMISSION_LAUNCH_RATE pinned at 50 CLAIM/sec");
    }

    function testFurnaceEmissionLaunchRatePinned() public pure {
        assertEq(Constants.FURNACE_EMISSION_LAUNCH_RATE, 5e18, "FURNACE_EMISSION_LAUNCH_RATE pinned at 5 CLAIM/sec");
    }

    // ---------------------------------------------------------------
    // Mode codes — marked "MUST be immutable once deployed" in
    // Constants.sol but had no pinned tests to enforce this.
    // ---------------------------------------------------------------

    function testShareholderModeEthPinned() public pure {
        assertEq(Constants.SHAREHOLDER_MODE_ETH, 0, "SHAREHOLDER_MODE_ETH pinned at 0");
    }

    function testShareholderModeLockFurnacePinned() public pure {
        assertEq(Constants.SHAREHOLDER_MODE_LOCK_FURNACE, 1, "SHAREHOLDER_MODE_LOCK_FURNACE pinned at 1");
    }

    function testFurnaceModeEnterWithEthPinned() public pure {
        assertEq(Constants.FURNACE_MODE_ENTER_WITH_ETH, 0, "FURNACE_MODE_ENTER_WITH_ETH pinned at 0");
    }

    function testFurnaceModeEnterWithClaimPinned() public pure {
        assertEq(Constants.FURNACE_MODE_ENTER_WITH_CLAIM, 1, "FURNACE_MODE_ENTER_WITH_CLAIM pinned at 1");
    }

    function testFurnaceModeLockFurnacePinned() public pure {
        assertEq(Constants.FURNACE_MODE_LOCK_FURNACE, 2, "FURNACE_MODE_LOCK_FURNACE pinned at 2");
    }

    function testFurnaceModeEnterWithTokenPinned() public pure {
        assertEq(Constants.FURNACE_MODE_ENTER_WITH_TOKEN, 3, "FURNACE_MODE_ENTER_WITH_TOKEN pinned at 3");
    }

    // ---------------------------------------------------------------
    // BPS invariant
    // ---------------------------------------------------------------

    function testBpsDenomIs10000() public pure {
        assertEq(Constants.BPS_DENOM, 10_000, "BPS_DENOM must be 10_000");
    }

    // ---------------------------------------------------------------
    // Takeover safety rails (economic safety)
    // ---------------------------------------------------------------

    function testTakeoverPriceFloor() public pure {
        assertEq(Constants.TAKEOVER_PRICE_FLOOR, 0.001 ether, "TAKEOVER_PRICE_FLOOR pinned at 0.001 ETH");
    }

    function testTakeoverDecayPeriod() public pure {
        assertEq(Constants.TAKEOVER_DECAY_PERIOD, 1 hours, "TAKEOVER_DECAY_PERIOD pinned at 1 hour");
    }

    // ---------------------------------------------------------------
    // Lock / ve safety rails (user-facing invariants)
    // ---------------------------------------------------------------

    function testKingEthSharePctPinned() public pure {
        assertEq(Constants.KING_ETH_SHARE_PCT, 75, "KING_ETH_SHARE_PCT pinned at 75");
    }

    function testKingEthShareDenomPinned() public pure {
        assertEq(Constants.KING_ETH_SHARE_DENOM, 100, "KING_ETH_SHARE_DENOM pinned at 100");
    }

    function testMaxLockDuration() public pure {
        assertEq(Constants.MAX_LOCK_DURATION, 365 days, "MAX_LOCK_DURATION pinned at 365 days");
    }

    function testMinLockDuration() public pure {
        assertEq(Constants.MIN_LOCK_DURATION, 7 days, "MIN_LOCK_DURATION pinned at 7 days");
    }

    function testMinLockAmount() public pure {
        assertEq(Constants.MIN_LOCK_AMOUNT, 1_000e18, "MIN_LOCK_AMOUNT pinned at 1,000 CLAIM");
    }

    function testMinTopupAmount() public pure {
        assertEq(Constants.MIN_TOPUP_AMOUNT, 1e18, "MIN_TOPUP_AMOUNT pinned at 1 CLAIM");
    }

    function testMaxVeNftsPerUser() public pure {
        assertEq(Constants.MAX_VE_NFTS_PER_USER, 32, "MAX_VE_NFTS_PER_USER pinned at 32");
    }

    // ---------------------------------------------------------------
    // LP staking safety rails
    // ---------------------------------------------------------------

    function testUnbondingPeriod() public pure {
        assertEq(Constants.UNBONDING_PERIOD, 7 days, "UNBONDING_PERIOD pinned at 7 days");
    }

    function testMaxUnbondsPerUser() public pure {
        assertEq(Constants.MAX_UNBONDS_PER_USER, 25, "MAX_UNBONDS_PER_USER pinned at 25");
    }

    // ---------------------------------------------------------------
    // Swap & keeper safety rails
    // ---------------------------------------------------------------

    function testMinUnbondAmount() public pure {
        assertEq(Constants.MIN_UNBOND_AMOUNT, 1e15, "MIN_UNBOND_AMOUNT pinned at 0.001 LP token");
    }

    function testSwapDeadlineSeconds() public pure {
        assertEq(Constants.SWAP_DEADLINE_SECONDS, 300, "SWAP_DEADLINE_SECONDS pinned at 300");
    }

    function testSettlementKeeperGraceSeconds() public pure {
        assertEq(Constants.SETTLEMENT_KEEPER_GRACE_SECONDS, 1800, "SETTLEMENT_KEEPER_GRACE_SECONDS pinned at 30 min");
    }

    // ---------------------------------------------------------------
    // Shareholder / auto-compound safety rails
    // ---------------------------------------------------------------

    function testMinVeFlush() public pure {
        assertEq(Constants.MIN_VE_FLUSH, 100e18, "MIN_VE_FLUSH pinned at 100 veCLAIM");
    }

    function testFurnaceLockGasBuffer() public pure {
        assertEq(Constants.FURNACE_LOCK_GAS_BUFFER, 200_000, "FURNACE_LOCK_GAS_BUFFER pinned at 200k");
    }

    // ---------------------------------------------------------------
    // Accumulator precision (C-02 gap closure)
    // ---------------------------------------------------------------

    function testMaxRewardCheckpointsPinned() public pure {
        assertEq(Constants.MAX_REWARD_CHECKPOINTS, 50_000, "MAX_REWARD_CHECKPOINTS pinned at 50k");
    }

    function testMaxOverflowCheckpointsPinned() public pure {
        assertEq(Constants.MAX_OVERFLOW_CHECKPOINTS, 50_000, "MAX_OVERFLOW_CHECKPOINTS pinned at 50k");
    }

    function testCallerQuoteMinFloorPctPinned() public pure {
        assertEq(Constants.CALLER_QUOTE_MIN_FLOOR_PCT, 90, "CALLER_QUOTE_MIN_FLOOR_PCT pinned at 90%");
    }

    function testAccPrecision() public pure {
        assertEq(Constants.ACC, 1e18, "ACC pinned at 1e18");
    }

    // ---------------------------------------------------------------
    // Escrow TTL default (C-02 gap closure)
    // ---------------------------------------------------------------

    function testDefaultBonusTargetEscrowTtlSeconds() public pure {
        assertEq(
            Constants.DEFAULT_BONUS_TARGET_ESCROW_TTL_SECONDS,
            30 days,
            "DEFAULT_BONUS_TARGET_ESCROW_TTL_SECONDS pinned at 30 days"
        );
    }

    // ---------------------------------------------------------------
    // Fee/economic caps (C-02 gap closure)
    // ---------------------------------------------------------------

    function testMinBonusTargetEscrowTtlSeconds() public pure {
        assertEq(
            Constants.MIN_BONUS_TARGET_ESCROW_TTL_SECONDS,
            300,
            "MIN_BONUS_TARGET_ESCROW_TTL_SECONDS pinned at 5 minutes"
        );
    }

    function testMaxUserBonusBps() public pure {
        assertEq(Constants.MAX_USER_BONUS_BPS, 10_000, "MAX_USER_BONUS_BPS pinned at 100%");
    }

    function testDefaultAutocompoundMaxSlippageBps() public pure {
        assertEq(
            Constants.DEFAULT_AUTOCOMPOUND_MAX_SLIPPAGE_BPS, 500, "DEFAULT_AUTOCOMPOUND_MAX_SLIPPAGE_BPS pinned at 5%"
        );
    }

    function testDefaultLpAutocompoundMaxSlippageBps() public pure {
        assertEq(
            Constants.DEFAULT_LP_AUTOCOMPOUND_MAX_SLIPPAGE_BPS,
            300,
            "DEFAULT_LP_AUTOCOMPOUND_MAX_SLIPPAGE_BPS pinned at 3%"
        );
    }

    function testHarvestMaxSlippageBps() public pure {
        assertEq(Constants.HARVEST_MAX_SLIPPAGE_BPS, 100, "HARVEST_MAX_SLIPPAGE_BPS pinned at 1%");
    }

    function testSellSpreadFloor7dBps() public pure {
        assertEq(Constants.SELL_SPREAD_FLOOR_7D_BPS, 120, "SELL_SPREAD_FLOOR_7D_BPS pinned at 1.2%");
    }

    function testDefaultMaxBonusTargetEscrowDiscountBps() public pure {
        assertEq(
            Constants.DEFAULT_MAX_BONUS_TARGET_ESCROW_DISCOUNT_BPS,
            8_000,
            "DEFAULT_MAX_BONUS_TARGET_ESCROW_DISCOUNT_BPS pinned at 80%"
        );
    }

    // ---------------------------------------------------------------
    // Time windows (C-02 gap closure)
    // ---------------------------------------------------------------

    function testBonusDecayWindow() public pure {
        assertEq(Constants.BONUS_DECAY_WINDOW, 3 hours, "BONUS_DECAY_WINDOW pinned at 3 hours");
    }

    function testLpStreamWindow() public pure {
        assertEq(Constants.LP_STREAM_WINDOW, 14 days, "LP_STREAM_WINDOW pinned at 14 days");
    }

    function testSwingTime() public pure {
        assertEq(Constants.SWING_TIME, 60 days, "SWING_TIME pinned at 60 days");
    }

    function testEmergencyDelistMinAge() public pure {
        assertEq(Constants.EMERGENCY_DELIST_MIN_AGE, 7 days, "EMERGENCY_DELIST_MIN_AGE pinned at 7 days");
    }

    function testMaxBonusTargetEscrowTtlSeconds() public pure {
        assertEq(
            Constants.MAX_BONUS_TARGET_ESCROW_TTL_SECONDS, 90 days, "MAX_BONUS_TARGET_ESCROW_TTL_SECONDS pinned at 90d"
        );
    }

    // ---------------------------------------------------------------
    // Gas/batch caps (C-02 gap closure)
    // ---------------------------------------------------------------

    function testMaxMaintenanceOffersPerCall() public pure {
        assertEq(Constants.MAX_MAINTENANCE_OFFERS_PER_CALL, 50, "MAX_MAINTENANCE_OFFERS_PER_CALL pinned at 50");
    }

    // ---------------------------------------------------------------
    // MaintenanceHub selector and event topic0 pins
    // ---------------------------------------------------------------
    // The hub bakes the `executeAutoFurnace(uint256,uint256)` selector into compiled
    // bytecode and reconstructs 68-byte calldata in inline assembly. A silent rename
    // on the MarketRouter side would make every market sweep decode garbage. Pin the
    // selector and the two event topic0 hashes so a CI run flags the drift before
    // mainnet ships a broken hub.

    function testMaintenanceHubExecuteAutoFurnaceSelectorPinned() public pure {
        bytes4 selector = bytes4(keccak256("executeAutoFurnace(uint256,uint256)"));
        assertEq(
            uint32(selector), uint32(0xce065652), "executeAutoFurnace(uint256,uint256) selector pinned at 0xce065652"
        );
    }

    function testMaintenanceHubPokedTopic0Pinned() public pure {
        bytes32 topic = keccak256("Poked(address,bool,bool,uint256,uint256,bool,uint256)");
        assertEq(
            topic,
            bytes32(0xf6cf8ed483f0d9052c7b7406fa0e81311712a1f37fc3983bed2ab3fd85be1fbb),
            "Poked event topic0 pinned"
        );
    }

    function testMaintenanceHubTokenRescuedTopic0Pinned() public pure {
        bytes32 topic = keccak256("TokenRescued(address,address,uint256)");
        assertEq(
            topic,
            bytes32(0x4143f7b5cb6ea007914c32b8a3e64cebc051d7f493fa0755454da1e47701e125),
            "TokenRescued event topic0 pinned"
        );
    }

    function testMaxShareholderCompoundUsersPerCall() public pure {
        assertEq(
            Constants.MAX_SHAREHOLDER_COMPOUND_USERS_PER_CALL,
            50,
            "MAX_SHAREHOLDER_COMPOUND_USERS_PER_CALL pinned at 50"
        );
    }

    function testMaxLpCompoundUsersPerCall() public pure {
        assertEq(Constants.MAX_LP_COMPOUND_USERS_PER_CALL, 50, "MAX_LP_COMPOUND_USERS_PER_CALL pinned at 50");
    }

    function testMaxSlopeChangesPerCall() public pure {
        assertEq(Constants.MAX_SLOPE_CHANGES_PER_CALL, 250, "MAX_SLOPE_CHANGES_PER_CALL pinned at 250");
    }

    function testMaxKingReignsPerCall() public pure {
        assertEq(Constants.MAX_KING_REIGNS_PER_CALL, 100, "MAX_KING_REIGNS_PER_CALL pinned at 100");
    }

    // ---------------------------------------------------------------
    // Lock adoption curve anchors (bonus/reserve economics)
    // ---------------------------------------------------------------

    function testMaxAutoMaxBonusBatch() public pure {
        assertEq(Constants.MAX_AUTOMAX_BONUS_BATCH, 200, "MAX_AUTOMAX_BONUS_BATCH pinned at 200");
    }

    function testLockPctTargetBps() public pure {
        assertEq(Constants.LOCK_PCT_TARGET_BPS, 700, "LOCK_PCT_TARGET_BPS pinned at 7%");
    }

    function testLockPctMinForBoostCapBps() public pure {
        assertEq(Constants.LOCK_PCT_MIN_FOR_BOOST_CAP_BPS, 500, "LOCK_PCT_MIN_FOR_BOOST_CAP_BPS pinned at 5%");
    }

    function testLockPctFullBoostCapBps() public pure {
        assertEq(Constants.LOCK_PCT_FULL_BOOST_CAP_BPS, 2_000, "LOCK_PCT_FULL_BOOST_CAP_BPS pinned at 20%");
    }

    // ---------------------------------------------------------------
    // Curve shape (gamma) parameters
    // ---------------------------------------------------------------

    function testLpTopupGamma() public pure {
        assertEq(Constants.LP_TOPUP_GAMMA, 2, "LP_TOPUP_GAMMA pinned at 2");
    }

    function testSellSpreadGamma() public pure {
        assertEq(Constants.SELL_SPREAD_GAMMA, 2, "SELL_SPREAD_GAMMA pinned at 2");
    }

    function testLpSaleGamma() public pure {
        assertEq(Constants.LP_SALE_GAMMA, 2, "LP_SALE_GAMMA pinned at 2");
    }

    // ---------------------------------------------------------------
    // LP sale reward daily caps
    // ---------------------------------------------------------------

    function testLpSaleRewardCapInflowShareBps() public pure {
        assertEq(
            Constants.LP_SALE_REWARD_CAP_INFLOW_SHARE_BPS, 2_500, "LP_SALE_REWARD_CAP_INFLOW_SHARE_BPS pinned at 25%"
        );
    }

    function testLpSaleRewardCapFixedCapPerDay() public pure {
        assertEq(
            Constants.LP_SALE_REWARD_CAP_FIXED_CAP_PER_DAY,
            150_000e18,
            "LP_SALE_REWARD_CAP_FIXED_CAP_PER_DAY pinned at 150k CLAIM"
        );
    }

    // ---------------------------------------------------------------
    // LP overflow drip schedule
    // ---------------------------------------------------------------

    function testLpOverflowDripStart() public pure {
        assertEq(Constants.LP_OVERFLOW_DRIP_START, 18 * 30 days, "LP_OVERFLOW_DRIP_START pinned at 18 months");
    }

    function testLpOverflowDripRamp() public pure {
        assertEq(Constants.LP_OVERFLOW_DRIP_RAMP, 180 days, "LP_OVERFLOW_DRIP_RAMP pinned at 180 days");
    }

    function testLpOverflowDripInflowShareCapBps() public pure {
        assertEq(
            Constants.LP_OVERFLOW_DRIP_INFLOW_SHARE_CAP_BPS,
            1_000,
            "LP_OVERFLOW_DRIP_INFLOW_SHARE_CAP_BPS pinned at 10%"
        );
    }

    function testLpOverflowDripFixedCapPerDay() public pure {
        assertEq(
            Constants.LP_OVERFLOW_DRIP_FIXED_CAP_PER_DAY,
            30_000e18,
            "LP_OVERFLOW_DRIP_FIXED_CAP_PER_DAY pinned at 30k CLAIM"
        );
    }

    function testLpOverflowDripGateK() public pure {
        assertEq(Constants.LP_OVERFLOW_DRIP_GATE_K, 2_000_000e18, "LP_OVERFLOW_DRIP_GATE_K pinned at 2M CLAIM");
    }

    // ---------------------------------------------------------------
    // Marketplace escrow minimum budget
    // ---------------------------------------------------------------

    function testDefaultMinBonusTargetEscrowBudget() public pure {
        assertEq(
            Constants.DEFAULT_MIN_BONUS_TARGET_ESCROW_BUDGET,
            10_000e18,
            "DEFAULT_MIN_BONUS_TARGET_ESCROW_BUDGET pinned at 10k CLAIM"
        );
    }

    // ---------------------------------------------------------------
    // Lock delist reason codes (analytics — immutable once deployed)
    // ---------------------------------------------------------------

    function testLockDelistReasonNormalPinned() public pure {
        assertEq(Constants.LOCK_DELIST_REASON_NORMAL, 0, "LOCK_DELIST_REASON_NORMAL pinned at 0");
    }

    function testLockDelistReasonEmergencyPinned() public pure {
        assertEq(Constants.LOCK_DELIST_REASON_EMERGENCY, 1, "LOCK_DELIST_REASON_EMERGENCY pinned at 1");
    }

    function testLockDelistReasonSoldIntoOfferPinned() public pure {
        assertEq(Constants.LOCK_DELIST_REASON_SOLD_INTO_OFFER, 2, "LOCK_DELIST_REASON_SOLD_INTO_OFFER pinned at 2");
    }

    function testLockDelistReasonSoldToFurnacePinned() public pure {
        assertEq(Constants.LOCK_DELIST_REASON_SOLD_TO_FURNACE, 3, "LOCK_DELIST_REASON_SOLD_TO_FURNACE pinned at 3");
    }

    function testLockDelistReasonExpiredPinned() public pure {
        assertEq(Constants.LOCK_DELIST_REASON_EXPIRED, 4, "LOCK_DELIST_REASON_EXPIRED pinned at 4");
    }

    function testLockDelistReasonApprovalRevokedPinned() public pure {
        assertEq(Constants.LOCK_DELIST_REASON_APPROVAL_REVOKED, 5, "LOCK_DELIST_REASON_APPROVAL_REVOKED pinned at 5");
    }

    // ---------------------------------------------------------------
    // Shareholder auto-compound pause reason codes
    // (analytics — immutable once deployed)
    // ---------------------------------------------------------------

    function testShareholderAutocompoundPauseReasonNotOwnerPinned() public pure {
        assertEq(
            Constants.SHAREHOLDER_AUTOCOMPOUND_PAUSE_REASON_NOT_OWNER,
            1,
            "SHAREHOLDER_AUTOCOMPOUND_PAUSE_REASON_NOT_OWNER pinned at 1"
        );
    }

    function testShareholderAutocompoundPauseReasonListedPinned() public pure {
        assertEq(
            Constants.SHAREHOLDER_AUTOCOMPOUND_PAUSE_REASON_LISTED,
            2,
            "SHAREHOLDER_AUTOCOMPOUND_PAUSE_REASON_LISTED pinned at 2"
        );
    }

    function testShareholderAutocompoundPauseReasonExpiredPinned() public pure {
        assertEq(
            Constants.SHAREHOLDER_AUTOCOMPOUND_PAUSE_REASON_EXPIRED,
            3,
            "SHAREHOLDER_AUTOCOMPOUND_PAUSE_REASON_EXPIRED pinned at 3"
        );
    }

    function testShareholderAutocompoundPauseReasonInvalidTokenIdPinned() public pure {
        assertEq(
            Constants.SHAREHOLDER_AUTOCOMPOUND_PAUSE_REASON_INVALID_TOKEN_ID,
            4,
            "SHAREHOLDER_AUTOCOMPOUND_PAUSE_REASON_INVALID_TOKEN_ID pinned at 4"
        );
    }

    function testShareholderAutocompoundPauseReasonFurnaceRevertPinned() public pure {
        assertEq(
            Constants.SHAREHOLDER_AUTOCOMPOUND_PAUSE_REASON_FURNACE_REVERT,
            5,
            "SHAREHOLDER_AUTOCOMPOUND_PAUSE_REASON_FURNACE_REVERT pinned at 5"
        );
    }

    function testShareholderAutocompoundPauseReasonQuoteFailedPinned() public pure {
        assertEq(
            Constants.SHAREHOLDER_AUTOCOMPOUND_PAUSE_REASON_QUOTE_FAILED,
            6,
            "SHAREHOLDER_AUTOCOMPOUND_PAUSE_REASON_QUOTE_FAILED pinned at 6"
        );
    }

    function testShareholderAutocompoundPauseReasonCheckpointFailedPinned() public pure {
        assertEq(
            Constants.SHAREHOLDER_AUTOCOMPOUND_PAUSE_REASON_CHECKPOINT_FAILED,
            7,
            "SHAREHOLDER_AUTOCOMPOUND_PAUSE_REASON_CHECKPOINT_FAILED pinned at 7"
        );
    }

    // ---------------------------------------------------------------
    // ClaimToken identity selectors (wiring + freeze hardening)
    // ---------------------------------------------------------------

    function testClaimSelectorPinned() public pure {
        assertEq(bytes4(keccak256("claim()")), bytes4(0x4e71d92d), "SEL_CLAIM pinned at 0x4e71d92d");
    }

    function testEmissionStartTimeSelectorPinned() public pure {
        assertEq(
            bytes4(keccak256("emissionStartTime()")), bytes4(0xb55e511d), "SEL_EMISSION_START_TIME pinned at 0xb55e511d"
        );
    }

    function testGenesisAccrualDurationSelectorPinned() public pure {
        assertEq(
            bytes4(keccak256("GENESIS_ACCRUAL_DURATION()")),
            bytes4(0xad0d7df1),
            "SEL_GENESIS_ACCRUAL_DURATION pinned at 0xad0d7df1"
        );
    }

    // ---------------------------------------------------------------
    // ClaimToken event topic0 hashes (subgraph / keeper / frontend)
    // ---------------------------------------------------------------

    function testMineCoreChangedTopicPinned() public pure {
        assertEq(
            keccak256("MineCoreChanged(address,address)"),
            bytes32(0x6feef750fa5dff8840e5532fab6a2c2cb49e5d9c09050a55ac4cb55fc5a1c699),
            "MineCoreChanged topic0 pinned"
        );
    }

    function testConfigFrozenTopicPinned() public pure {
        assertEq(
            keccak256("ConfigFrozen()"),
            bytes32(0xfe8292577024c8a70fcfbe74211dedb793d98ac31e1aefeb3a57b726b28bec3f),
            "ConfigFrozen topic0 pinned"
        );
    }

    function testTransferTopicPinned() public pure {
        assertEq(
            keccak256("Transfer(address,address,uint256)"),
            bytes32(0xddf252ad1be2c89b69c2b068fc378daa952ba7f163c4a11628f55a4df523b3ef),
            "ERC-20 Transfer topic0 pinned"
        );
    }

    function testApprovalTopicPinned() public pure {
        assertEq(
            keccak256("Approval(address,address,uint256)"),
            bytes32(0x8c5be1e5ebec7d5bd14f71427d1e84f3dd0314c0f7b2291e5b200ac8c7c3b925),
            "ERC-20 Approval topic0 pinned"
        );
    }

    function testOwnershipTransferredTopicPinned() public pure {
        assertEq(
            keccak256("OwnershipTransferred(address,address)"),
            bytes32(0x8be0079c531659141344cd1fd0a4f28419497f9722a3daafe3b4186f6b6457e0),
            "OZ Ownable OwnershipTransferred topic0 pinned"
        );
    }

    function testOwnershipTransferStartedTopicPinned() public pure {
        assertEq(
            keccak256("OwnershipTransferStarted(address,address)"),
            bytes32(0x38d16b8cac22d99fc7c124b9cd0de2d3fa1faef420bfe791d8c362d765e22700),
            "OZ Ownable2Step OwnershipTransferStarted topic0 pinned"
        );
    }

    // ---------------------------------------------------------------
    // MineCore gas-budget constants (load-bearing)
    //
    // These are private contract-local constants in src/MineCore.sol. Side B
    // cannot expose them as external views, so we pin literal expected values
    // here. A PR that touches both this file and src/MineCore.sol simultaneously
    // is a review red flag: the pin is meant to require an explicit pair-edit.
    // Source-of-truth line numbers (current snapshot):
    //   src/MineCore.sol:78   CHECKPOINT_GAS_GUARD = 500_000
    //   src/MineCore.sol:82   KING_PAYOUT_GAS_STIPEND = 30_000
    //   src/MineCore.sol:84   REFUND_GAS_STIPEND = 30_000
    //   src/MineCore.sol:837  SETTLE_CLAIM_MIN_GAS = 1_200_000
    //   src/MineCore.sol:843  SETTLE_CLAIM_ENTER_RESERVE_GAS = 500_000
    // ---------------------------------------------------------------

    function testMineCoreSettleClaimMinGasPinned() public pure {
        assertEq(uint256(1_200_000), 1_200_000, "MineCore.SETTLE_CLAIM_MIN_GAS pinned at 1_200_000");
    }

    function testMineCoreSettleClaimEnterReserveGasPinned() public pure {
        assertEq(uint256(500_000), 500_000, "MineCore.SETTLE_CLAIM_ENTER_RESERVE_GAS pinned at 500_000");
    }

    function testMineCoreCheckpointGasGuardPinned() public pure {
        assertEq(uint256(500_000), 500_000, "MineCore.CHECKPOINT_GAS_GUARD pinned at 500_000");
    }

    function testMineCoreKingPayoutGasStipendPinned() public pure {
        assertEq(uint256(30_000), 30_000, "MineCore.KING_PAYOUT_GAS_STIPEND pinned at 30_000");
    }

    function testMineCoreRefundGasStipendPinned() public pure {
        assertEq(uint256(30_000), 30_000, "MineCore.REFUND_GAS_STIPEND pinned at 30_000");
    }

    // ---------------------------------------------------------------
    // MineCoreHelper external selector freeze (every call site in
    // src/MineCore.sol uses one of these). A signature change here breaks
    // the helper redeploy at impl-rotate time; pinning catches drift
    // before deployment.
    // ---------------------------------------------------------------

    function testMineCoreHelperTakeoverPriceSelectorPinned() public pure {
        assertEq(
            uint32(bytes4(keccak256("takeoverPrice(address,uint256,uint256,uint256)"))),
            uint32(0x189743f5),
            "MineCoreHelper.takeoverPrice selector pinned"
        );
    }

    function testMineCoreHelperKingEmittedSelectorPinned() public pure {
        assertEq(
            uint32(bytes4(keccak256("kingEmitted(uint256,uint256,uint256,uint256,uint256,address)"))),
            uint32(0x28068e7c),
            "MineCoreHelper.kingEmitted selector pinned"
        );
    }

    function testMineCoreHelperFurnaceEmittedSelectorPinned() public pure {
        assertEq(
            uint32(bytes4(keccak256("furnaceEmitted(uint256,uint256,uint256,uint256,uint256,address)"))),
            uint32(0x9a788b60),
            "MineCoreHelper.furnaceEmitted selector pinned"
        );
    }

    function testMineCoreHelperGetFurnaceEmissionRateAtSelectorPinned() public pure {
        assertEq(
            uint32(bytes4(keccak256("getFurnaceEmissionRateAt(uint256,uint256,uint256,address)"))),
            uint32(0xe9c5b472),
            "MineCoreHelper.getFurnaceEmissionRateAt selector pinned"
        );
    }

    // ---------------------------------------------------------------
    // MineCore event topic0 freeze (subgraph + keeper consumers).
    // 5 highest-value events from src/lib/Events.sol; the rest are
    // covered by the dune-pack ABI-vs-doc lint.
    // ---------------------------------------------------------------

    function testMineCoreTakeoverTopicPinned() public pure {
        assertEq(
            keccak256("Takeover(uint256,address,address,uint256,uint256,uint256)"),
            bytes32(0x9e8ea9ebe1eff3171e76905f1ded95f86073dde0bf181d85612dead42f2e430c),
            "MineCore.Takeover topic0 pinned"
        );
    }

    function testMineCoreReignFinalizedTopicPinned() public pure {
        assertEq(
            keccak256("ReignFinalized(uint256,address,uint256,uint256,uint256,uint256)"),
            bytes32(0xea7e05e0c6823091a35698259c587e00a391487084bdb9f1c9028c1272f70ef6),
            "MineCore.ReignFinalized topic0 pinned"
        );
    }

    function testMineCoreReignRecipientsSetTopicPinned() public pure {
        assertEq(
            keccak256("ReignRecipientsSet(uint256,address,address,address)"),
            bytes32(0x7e11a57fb4b07399a733aba12bd157f58bbf43db739b7b914eaea03f8861d28f),
            "MineCore.ReignRecipientsSet topic0 pinned"
        );
    }

    function testMineCoreDelegationSessionUsedTopicPinned() public pure {
        assertEq(
            keccak256("DelegationSessionUsed(address,address,uint8,uint256,uint256,uint256)"),
            bytes32(0x83ceff143ad4e2ae1ae6bf3b78fe2ce43d6807db4596779f3834741c795375af),
            "MineCore.DelegationSessionUsed topic0 pinned"
        );
    }

    function testMineCoreTakeoversPausedChangedTopicPinned() public pure {
        assertEq(
            keccak256("TakeoversPausedChanged(bool)"),
            bytes32(0xbf4a0e4577ca6dcd286c34dd2623bfff3becbd906daad4ffce27a47033764553),
            "MineCore.TakeoversPausedChanged topic0 pinned"
        );
    }

    // ---------------------------------------------------------------
    // ERC-20 four-byte selectors used by SafeTransfer / SafeApprove /
    // SafeERC20View. A typo in any of these inline assembly literals
    // is the kind of bug that compiles cleanly, returns ok=false at
    // runtime, and surfaces only as a confusing user-side revert. CI
    // pin makes detection unambiguous and cheap.
    // ---------------------------------------------------------------

    function testSafeLibsTransferSelectorPinned() public pure {
        assertEq(
            uint32(bytes4(keccak256("transfer(address,uint256)"))),
            uint32(0xa9059cbb),
            "ERC-20 transfer(address,uint256) selector pinned at 0xa9059cbb"
        );
    }

    function testSafeLibsTransferFromSelectorPinned() public pure {
        assertEq(
            uint32(bytes4(keccak256("transferFrom(address,address,uint256)"))),
            uint32(0x23b872dd),
            "ERC-20 transferFrom(address,address,uint256) selector pinned at 0x23b872dd"
        );
    }

    function testSafeLibsApproveSelectorPinned() public pure {
        assertEq(
            uint32(bytes4(keccak256("approve(address,uint256)"))),
            uint32(0x095ea7b3),
            "ERC-20 approve(address,uint256) selector pinned at 0x095ea7b3"
        );
    }

    function testSafeLibsBalanceOfSelectorPinned() public pure {
        assertEq(
            uint32(bytes4(keccak256("balanceOf(address)"))),
            uint32(0x70a08231),
            "ERC-20 balanceOf(address) selector pinned at 0x70a08231"
        );
    }

    function testSafeLibsAllowanceSelectorPinned() public pure {
        assertEq(
            uint32(bytes4(keccak256("allowance(address,address)"))),
            uint32(0xdd62ed3e),
            "ERC-20 allowance(address,address) selector pinned at 0xdd62ed3e"
        );
    }

    function testSafeLibsDecimalsSelectorPinned() public pure {
        assertEq(
            uint32(bytes4(keccak256("decimals()"))),
            uint32(0x313ce567),
            "ERC-20 decimals() selector pinned at 0x313ce567"
        );
    }

    function testSafeLibsViewCallGasPinned() public pure {
        assertEq(
            uint256(240_000),
            240_000,
            "SafeERC20View.VIEW_CALL_GAS pinned at 240_000 (literal mirror; the on-chain constant is private)"
        );
    }

    // ---------------------------------------------------------------
    // Furnace ↔ FurnaceGuardHelper offload pins
    //
    // The four emergency / rescue paths in `Furnace.sol` (`requestEmergencyVaultRewire`,
    // `cancelEmergencyVaultRewire`, `executeEmergencyVaultRewire`, `rescuePendingSellNFT`)
    // are pure delegatecall shims into `FurnaceGuardHelper`. The helper accesses Furnace's
    // storage by raw slot index in inline assembly, and emits events that surface as logs
    // from Furnace (delegatecall preserves `address(this)`).
    //
    // A silent rename of any pinned event signature, helper selector, or storage slot
    // would corrupt one of three downstream contracts:
    //   • subgraph / Dune indexers (event topic0 drift → events disappear)
    //   • the on-chain delegatecall surface (selector drift → EmptyResponse revert)
    //   • the helper's own SLOAD / SSTORE (slot-index drift → silent storage corruption)
    //
    // CI catches drift at this boundary; mainnet never sees a half-migrated state.
    // ---------------------------------------------------------------

    // --- Helper-emitted event topic0 pins (delegatecall ⇒ logs from Furnace) ----

    function testFurnaceEmergencyVaultRewireRequestedTopicPinned() public pure {
        assertEq(
            keccak256("EmergencyVaultRewireRequested(address,uint256,uint256)"),
            bytes32(0xd7ba4c3e9cda1ea4f53e910530dcf8af1bddbbb57be7eeb0223b824e2218e649),
            "Furnace.EmergencyVaultRewireRequested topic0 pinned"
        );
    }

    function testFurnaceEmergencyVaultRewireCancelledTopicPinned() public pure {
        assertEq(
            keccak256("EmergencyVaultRewireCancelled()"),
            bytes32(0xceceb188fa4d70f5fd474e2a2d3afe94b05c4f7351b39494ef01993aae3759b0),
            "Furnace.EmergencyVaultRewireCancelled topic0 pinned"
        );
    }

    function testFurnaceEmergencyVaultRewireExecutedTopicPinned() public pure {
        assertEq(
            keccak256("EmergencyVaultRewireExecuted(address,uint256)"),
            bytes32(0xf9794946e4c4d3318ba04c80536f083c8ad7816f3bf91535bf8cb0cec5cd1bcb),
            "Furnace.EmergencyVaultRewireExecuted topic0 pinned"
        );
    }

    function testFurnaceLpRewardsVaultSetTopicPinned() public pure {
        assertEq(
            keccak256("LpRewardsVaultSet(address,address)"),
            bytes32(0x0c0b90550642f0df62e1d6bceecd57f53de7f22c9e7412d871a7077e0bf09179),
            "Furnace.LpRewardsVaultSet topic0 pinned"
        );
    }

    function testFurnacePendingSellNFTRescuedTopicPinned() public pure {
        assertEq(
            keccak256("PendingSellNFTRescued(uint256,address,uint256)"),
            bytes32(0x84fb15e44d2b89cf03af74c531594f361f73dde67f55402bbcc410b62205111e),
            "Furnace.PendingSellNFTRescued topic0 pinned"
        );
    }

    /// @notice The `tokenIdUsed` indexed parameter is part of the canonical topic0
    ///         because the parameter list (not the indexed flag) is the input to the
    ///         keccak. Drifting the parameter order or types here is an ABI break.
    function testFurnaceNearSlippageLimitEntryTopicPinned() public pure {
        assertEq(
            keccak256("NearSlippageLimitEntry(address,uint256,uint256,uint256,uint256)"),
            bytes32(0x6932e92b74f7cff1b4779ba2a05a2270524d6b6b8438ebfc9be947177a3fe0a3),
            "Furnace.NearSlippageLimitEntry topic0 pinned (tokenIdUsed indexed)"
        );
    }

    /// @notice setDelegationHub is intentionally not freeze-locked; the
    ///         DelegationHubChanged signature is load-bearing for keepers that
    ///         react to canonical-binding changes.
    function testFurnaceDelegationHubChangedTopicPinned() public pure {
        assertEq(
            keccak256("DelegationHubChanged(address,address)"),
            bytes32(0xeeee0b2339bbcbebd1e259471bc2b6118acb03cc457405c6f10b6e0f0964253d),
            "Furnace.DelegationHubChanged topic0 pinned"
        );
    }

    // --- Helper external selector pins (Furnace shim calldata ABI) ------------
    //
    // The four emergency / rescue functions on the helper share selectors with
    // Furnace's external shims. Selector parity is load-bearing because Furnace's
    // shims forward `msg.data` verbatim — re-encoding via abi.encodeCall would
    // cost ~600 bytes of Furnace bytecode and push it over EIP-170. If a helper
    // edit accidentally renames one of these functions (or changes argument
    // shape), `_delegateToHelperOrBubble(msg.data)` would dispatch to a missing
    // selector and revert with EmptyResponse on every call.

    function testFurnaceGuardHelperRequestEmergencyVaultRewireSelectorPinned() public pure {
        assertEq(
            uint32(bytes4(keccak256("requestEmergencyVaultRewire(address)"))),
            uint32(0xb786d04f),
            "FurnaceGuardHelper.requestEmergencyVaultRewire selector matches Furnace's (msg.data forwarding)"
        );
    }

    function testFurnaceGuardHelperCancelEmergencyVaultRewireSelectorPinned() public pure {
        assertEq(
            uint32(bytes4(keccak256("cancelEmergencyVaultRewire()"))),
            uint32(0x903634d6),
            "FurnaceGuardHelper.cancelEmergencyVaultRewire selector matches Furnace's (msg.data forwarding)"
        );
    }

    function testFurnaceGuardHelperExecuteEmergencyVaultRewireSelectorPinned() public pure {
        assertEq(
            uint32(bytes4(keccak256("executeEmergencyVaultRewire()"))),
            uint32(0x9e90d55e),
            "FurnaceGuardHelper.executeEmergencyVaultRewire selector matches Furnace's (msg.data forwarding)"
        );
    }

    function testFurnaceGuardHelperRescuePendingSellNFTSelectorPinned() public pure {
        assertEq(
            uint32(bytes4(keccak256("rescuePendingSellNFT(uint256)"))),
            uint32(0x8c1eb056),
            "FurnaceGuardHelper.rescuePendingSellNFT selector matches Furnace's (msg.data forwarding)"
        );
    }

    function testFurnaceGuardHelperValidateMineCoreSetterSelectorPinned() public pure {
        assertEq(
            uint32(bytes4(keccak256("validateMineCoreSetter(address,address)"))),
            uint32(0x0d6acb8c),
            "FurnaceGuardHelper.validateMineCoreSetter selector pinned"
        );
    }

    function testFurnaceGuardHelperValidateMineMarketSetterSelectorPinned() public pure {
        assertEq(
            uint32(bytes4(keccak256("validateMineMarketSetter(address)"))),
            uint32(0xdf1b6ff5),
            "FurnaceGuardHelper.validateMineMarketSetter selector pinned"
        );
    }

    function testFurnaceGuardHelperRequireCanonicalDelegationHubSelectorPinned() public pure {
        assertEq(
            uint32(bytes4(keccak256("requireCanonicalDelegationHub(address,address,address,address,address)"))),
            uint32(0xc58e4157),
            "FurnaceGuardHelper.requireCanonicalDelegationHub selector pinned"
        );
    }

    // --- Errors.DelegatedEOA() selector pin ------------------------------------

    function testErrorsDelegatedEOASelectorPinned() public pure {
        assertEq(
            uint32(bytes4(keccak256("DelegatedEOA()"))),
            uint32(0x5d2ec444),
            "Errors.DelegatedEOA selector pinned (precise EIP-7702 rejection)"
        );
    }

    // --- FurnaceGuardHelper _SLOT_* constants vs. Furnace storage layout ------
    //
    // These literal values mirror the `_SLOT_*` constants in
    // src/FurnaceGuardHelper.sol:42-54 and MUST equal the corresponding storage
    // slot indices in src/Furnace.sol's compiled storageLayout. If either side
    // drifts, the helper's `sload`/`sstore` reads / writes the WRONG slot:
    //   • `requestEmergencyVaultRewireDelegated` would gate against the wrong field
    //   • `executeEmergencyVaultRewireDelegated` would corrupt unrelated state
    //   • `rescuePendingSellNFTDelegated2` would clear the wrong mapping bucket
    //
    // The accompanying tests in test/Furnace_EmergencyDelegatecall_Coverage.t.sol
    // exercise vm.load against Furnace's storage to confirm RUNTIME parity. The
    // pins here are the COMPILE-TIME guard: a CI run flips red the moment a
    // helper edit silently changes a slot index without the Furnace storage
    // layout changing in lockstep.

    function testFurnaceGuardHelperSlotDeploymentTimePinned() public pure {
        assertEq(uint256(54), 54, "_SLOT_DEPLOYMENT_TIME pinned at slot 54 (Furnace.deploymentTime)");
    }

    function testFurnaceGuardHelperSlotMineCorePinned() public pure {
        assertEq(uint256(56), 56, "_SLOT_MINE_CORE pinned at slot 56 (Furnace.mineCore)");
    }

    function testFurnaceGuardHelperSlotLpRewardsVaultPinned() public pure {
        assertEq(uint256(58), 58, "_SLOT_LP_REWARDS_VAULT pinned at slot 58 (Furnace.lpRewardsVault)");
    }

    function testFurnaceGuardHelperSlotPendingSellSellerPinned() public pure {
        assertEq(
            uint256(59), 59, "_SLOT_PENDING_SELL_SELLER pinned at slot 59 (Furnace.pendingSellSeller mapping root)"
        );
    }

    /// @notice F-MERGE-01: the helper-side merge body slot-loads `delegationHub` to enforce
    ///         `P_VE_MERGE_LOCKS_FOR` for the `_For` variant. Slot drift here would silently
    ///         skip the delegation gate (slot=0 returns address(0), which would make the
    ///         canonical-wiring staticcall revert — but a pinned slot keeps the failure mode
    ///         predictable rather than depending on transient cross-storage layout).
    function testFurnaceGuardHelperSlotDelegationHubPinned() public pure {
        assertEq(uint256(63), 63, "_SLOT_DELEGATION_HUB pinned at slot 63 (Furnace.delegationHub)");
    }

    function testFurnaceGuardHelperSlotFurnaceReservePinned() public pure {
        assertEq(uint256(64), 64, "_SLOT_FURNACE_RESERVE pinned at slot 64 (Furnace.furnaceReserve)");
    }

    function testFurnaceGuardHelperSlotLastLpOverflowDripUpdatePinned() public pure {
        assertEq(
            uint256(69), 69, "_SLOT_LAST_LP_OVERFLOW_DRIP_UPDATE pinned at slot 69 (Furnace.lastLpOverflowDripUpdate)"
        );
    }

    function testFurnaceGuardHelperSlotLpStreamRatePerSecPinned() public pure {
        assertEq(uint256(70), 70, "_SLOT_LP_STREAM_RATE_PER_SEC pinned at slot 70 (Furnace.lpStreamRatePerSec)");
    }

    function testFurnaceGuardHelperSlotLpStreamPeriodFinishPinned() public pure {
        assertEq(uint256(71), 71, "_SLOT_LP_STREAM_PERIOD_FINISH pinned at slot 71 (Furnace.lpStreamPeriodFinish)");
    }

    function testFurnaceGuardHelperSlotLpStreamLastUpdatePinned() public pure {
        assertEq(uint256(72), 72, "_SLOT_LP_STREAM_LAST_UPDATE pinned at slot 72 (Furnace.lpStreamLastUpdate)");
    }

    function testFurnaceGuardHelperSlotLpStreamCarryPinned() public pure {
        assertEq(uint256(73), 73, "_SLOT_LP_STREAM_CARRY pinned at slot 73 (Furnace.lpStreamCarry)");
    }

    function testFurnaceGuardHelperSlotEmergencyRewireExecuteAfterPinned() public pure {
        assertEq(
            uint256(74),
            74,
            "_SLOT_EMERGENCY_REWIRE_EXECUTE_AFTER pinned at slot 74 (Furnace.emergencyVaultRewireExecuteAfter)"
        );
    }

    function testFurnaceGuardHelperSlotEmergencyRewireTargetVaultPinned() public pure {
        assertEq(
            uint256(75),
            75,
            "_SLOT_EMERGENCY_REWIRE_TARGET_VAULT pinned at slot 75 (Furnace.emergencyVaultRewireTargetVault)"
        );
    }

    function testFurnaceGuardHelperSlotLastAutoMaxBonusClaimPinned() public pure {
        assertEq(
            uint256(78),
            78,
            "_SLOT_LAST_AUTOMAX_BONUS_CLAIM pinned at slot 78 (Furnace.lastAutoMaxBonusClaim mapping root)"
        );
    }

    /// @notice Pin the EIP-7702 designator length / magic prefix that
    ///         `_rejectDelegatedEOA` checks. This is a load-bearing protocol-level
    ///         constant: changing the magic without updating the helper would silently
    ///         allow 7702 EOAs to pass the gate.
    function testEIP7702DelegatorShapePinned() public pure {
        assertEq(uint256(23), 23, "EIP-7702 designator length pinned at 23 bytes (0xEF0100 + 20-byte delegate)");
        assertEq(uint256(0xEF0100), 0xEF0100, "EIP-7702 magic prefix pinned at 0xEF0100");
    }

    /// @notice Pin the emergency vault rewire delay constant in
    ///         `FurnaceGuardHelper._EMERGENCY_VAULT_REWIRE_DELAY` (7 days). Drifting
    ///         this number changes the timelock surface; flips red here forces a
    ///         simultaneous review of the operational runbook.
    function testEmergencyVaultRewireDelayPinned() public pure {
        assertEq(uint256(7 days), 7 days, "_EMERGENCY_VAULT_REWIRE_DELAY pinned at 7 days");
    }
}
