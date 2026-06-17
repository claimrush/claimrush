// SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

/// @notice Shared protocol constants. Keep this file as the single source of truth.
library Constants {
    // Time
    uint256 internal constant EMISSION_DECAY_PERIOD = 63_072_000; // 2 years (365d/year)
    uint256 internal constant MAX_LOCK_DURATION = 365 days;

    // Minimum ve lock duration (applies to new locks; existing locks may have less remaining)
    uint256 internal constant MIN_LOCK_DURATION = 7 days;

    // Minimum ve lock amount for minting (createLock / createLockFor)
    uint256 internal constant MIN_LOCK_AMOUNT = 1_000e18; // 1,000 CLAIM

    // Minimum top-up amount for addToLock to bound ceiling-rounding slope dust.
    uint256 internal constant MIN_TOPUP_AMOUNT = 1e18; // 1 CLAIM

    // Hard cap on number of veCLAIM NFTs per address (gas-bounded veBalanceOf)
    uint256 internal constant MAX_VE_NFTS_PER_USER = 32;

    // LP staking vault (LpStakingVault7D)
    uint256 internal constant UNBONDING_PERIOD = 7 days;
    uint256 internal constant MAX_UNBONDS_PER_USER = 25;
    uint256 internal constant MIN_UNBOND_AMOUNT = 1e15; // 0.001 LP token

    // Emissions (CLAIM has 18 decimals)
    uint256 internal constant KING_EMISSION_LAUNCH_RATE = 50e18; // 50 CLAIM / sec
    uint256 internal constant KING_EMISSION_FLOOR = 5_555_555_555_555_555_555; // 50/9 ≈ 5.555 CLAIM / sec
    uint256 internal constant FURNACE_EMISSION_LAUNCH_RATE = 5e18; // 5 CLAIM / sec
    uint256 internal constant FURNACE_EMISSION_FLOOR = 555_555_555_555_555_555; // 5/9 ≈ 0.555 CLAIM / sec

    // Takeovers
    uint256 internal constant TAKEOVER_DECAY_PERIOD = 1 hours;
    uint256 internal constant TAKEOVER_PRICE_FLOOR = 0.001 ether;
    uint256 internal constant KING_ETH_SHARE_PCT = 75;
    uint256 internal constant KING_ETH_SHARE_DENOM = 100;

    // Swaps — 300s accommodates Base L2 sequencer throughput constraints
    // and Aerodrome router execution latency.
    uint256 internal constant SWAP_DEADLINE_SECONDS = 300;

    // Basis points
    uint256 internal constant BPS_DENOM = 10_000;

    /// @notice Internal precision multiplier for the Furnace duration-weight curve.
    /// @dev The curve is evaluated at `BPS_DENOM * WEIGHT_PRECISION` granularity so that
    ///      `principalEff` tracks duration deltas at sub-second resolution across the full
    ///      [MIN_LOCK_DURATION, MAX_LOCK_DURATION] range. Public bps-shaped views derive
    ///      from this value via `floor(weight / WEIGHT_PRECISION)`.
    uint256 internal constant WEIGHT_PRECISION = 1e8;

    /// @notice Denominator paired with the duration-weight curve's sub-bp output.
    /// @dev Use as the `mulDiv` divisor when computing
    ///      `principalEff = mulDiv(amount, weightDelta, WEIGHT_DENOM)` — keeps the
    ///      result on the same bps scale as bonus AMM math.
    uint256 internal constant WEIGHT_DENOM = BPS_DENOM * WEIGHT_PRECISION;

    // Furnace bonus parameters

    // Website headline user cap (<= 100% / 10_000 bps)
    uint256 internal constant MAX_USER_BONUS_BPS = 10_000;

    // LP additive top-up rate: 7.5%..15% of user bonus (enabled only when lpRewardsVault != address(0))
    uint256 internal constant LP_TOPUP_RATE_MIN_BPS = 750;
    uint256 internal constant LP_TOPUP_RATE_MAX_BPS = 1_500;
    uint256 internal constant LP_TOPUP_GAMMA = 2;

    // Sellback (lock → liquid CLAIM) spreads (driven by userSpotBonusBps)
    uint256 internal constant SELL_SPREAD_MIN_BPS = 500;
    uint256 internal constant SELL_SPREAD_MAX_BPS = 7_000;
    // Minimum total sell spread at MIN_LOCK_DURATION (7d).
    uint256 internal constant SELL_SPREAD_FLOOR_7D_BPS = 120; // 1.2%
    uint256 internal constant SELL_SPREAD_GAMMA = 2;

    // Sellback: round-trip loss floor (principal loss) for an immediate buy→sell.
    // At MAX_LOCK_DURATION (365d), the floor is SELL_ROUND_TRIP_LOSS_MAX_BPS.
    // Scales linearly with remaining time, clamped to [MIN_LOCK_DURATION, MAX_LOCK_DURATION].
    uint256 internal constant SELL_ROUND_TRIP_LOSS_MAX_BPS = 5_000; // 50.00%

    // Sellback: burst impact add-on (extra spread) based on recent sell volume.
    // The cumulative sell volume decays linearly over BONUS_DECAY_WINDOW (3h).
    // Thresholds are derived from the *King* emission rate (mining) over the same window:
    // - E3h = kingRate(now) * BONUS_DECAY_WINDOW
    // - freeVol = floor(E3h * 0.5)
    // - stepVol = floor(E3h * 0.2)
    // Each additional step adds SELL_IMPACT_BPS_PER_STEP, capped at SELL_IMPACT_MAX_BPS.
    uint256 internal constant SELL_IMPACT_BPS_PER_STEP = 100; // 1.00% extra spread per step
    uint256 internal constant SELL_IMPACT_MAX_BPS = 1_500; // 15.00% max extra spread

    // Sellback cut split to LP stakers (bps of cut; convex in bonus)
    // Defaults: 5%..15% of the cut (scaled down when reserve is stressed).
    uint256 internal constant LP_SALE_MIN_BPS = 500;
    uint256 internal constant LP_SALE_MAX_BPS = 1_500;
    uint256 internal constant LP_SALE_GAMMA = 2;

    // Daily cap on LP rewards funded from sellback cut (volume-driven).
    // Cap is computed as: min(floor(inflowPerDay * shareBps / 10_000), fixedCapPerDay).
    // NOTE: This cap does NOT apply to the time-based LP overflow drip.
    uint256 internal constant LP_SALE_REWARD_CAP_INFLOW_SHARE_BPS = 2_500; // 25% of inflow/day
    uint256 internal constant LP_SALE_REWARD_CAP_FIXED_CAP_PER_DAY = 150_000e18; // 150,000 CLAIM/day

    // Gross spend cap: user + LP <= 125% / 12_500 bps
    uint256 internal constant MAX_GROSS_BONUS_BPS = 12_500;

    // Spot cap anchor: total locked CLAIM in VeClaimNFT. The model anchors on lock%.
    uint256 internal constant LOCK_TARGET = 120_000_000e18;

    // Spot cap anchor (current): locked CLAIM as % of total supply (in bps).
    // Half-max base bonus occurs at this lock%.
    uint256 internal constant LOCK_PCT_TARGET_BPS = 700; // 7.0%

    // Dynamic max reserve-factor cap at low lock adoption.
    // Below ~5% lock, we cap reserveFactorBps at RESERVE_FACTOR_MAX_BPS_LOWLOCK.
    // Between 5% and 20% lock, the cap linearly ramps up to RESERVE_FACTOR_MAX_BPS.
    uint256 internal constant LOCK_PCT_MIN_FOR_BOOST_CAP_BPS = 500; // 5%
    uint256 internal constant LOCK_PCT_FULL_BOOST_CAP_BPS = 2_000; // 20%
    uint256 internal constant RESERVE_FACTOR_MAX_BPS_LOWLOCK = 15_000; // 1.5x

    // Reserve fullness anchor and clamp
    uint256 internal constant RESERVE_TARGET_FINAL = 20_000_000e18;
    uint256 internal constant RESERVE_FACTOR_MAX_BPS = 20_000; // 2.0x

    // Reserve factor swing-in (0 at launch → full at 60d)
    uint256 internal constant SWING_TIME = 60 days;

    // Bonus AMM virtual depth decay window
    uint256 internal constant BONUS_DECAY_WINDOW = 3 hours;

    // LP rewards stream window (Furnace-funded rewards are streamed to the LP vault)
    uint256 internal constant LP_STREAM_WINDOW = 14 days;

    // LP overflow drip (time-based, post-start/ramp caps)
    uint256 internal constant LP_OVERFLOW_DRIP_START = 18 * 30 days; // 18 months (30d month convention)
    uint256 internal constant LP_OVERFLOW_DRIP_RAMP = 180 days;
    uint256 internal constant LP_OVERFLOW_DRIP_INFLOW_SHARE_CAP_BPS = 1_000; // 10% of inflow/day
    uint256 internal constant LP_OVERFLOW_DRIP_FIXED_CAP_PER_DAY = 30_000e18; // 30,000 CLAIM/day
    uint256 internal constant LP_OVERFLOW_DRIP_GATE_K = 2_000_000e18; // excess/(excess + K)

    // ShareholderRoyalties
    uint256 internal constant ACC = 1e18;
    uint256 internal constant MAX_REWARD_CHECKPOINTS = 50_000;
    uint256 internal constant MAX_OVERFLOW_CHECKPOINTS = 50_000;
    // NOTE: MIN_VE_FLUSH is 100e18 veCLAIM.
    uint256 internal constant MIN_VE_FLUSH = 100e18;

    // Mode codes (events + off-chain analytics)
    // NOTE: These numeric mappings MUST be immutable once deployed.
    // MUST match `docs/analytics/dune-integration-pack-v1.0.0.md`.
    uint8 internal constant SHAREHOLDER_MODE_ETH = 0;
    uint8 internal constant SHAREHOLDER_MODE_LOCK_FURNACE = 1;
    uint8 internal constant FURNACE_MODE_ENTER_WITH_ETH = 0;
    uint8 internal constant FURNACE_MODE_ENTER_WITH_CLAIM = 1;
    uint8 internal constant FURNACE_MODE_LOCK_FURNACE = 2;
    uint8 internal constant FURNACE_MODE_ENTER_WITH_TOKEN = 3;

    // ve checkpointing
    uint256 internal constant MAX_SLOPE_CHANGES_PER_CALL = 250;

    // Gas-bounded per-call work caps

    /// @notice Hard cap for MaintenanceHub.poke(...) offer processing per call.
    uint256 internal constant MAX_MAINTENANCE_OFFERS_PER_CALL = 50;

    /// @notice Hard cap for ShareholderRoyalties.compoundForMany(...) users processed per call.
    uint256 internal constant MAX_SHAREHOLDER_COMPOUND_USERS_PER_CALL = 50;

    /// @notice Default max slippage (bps) for auto-compound when user config has 0.
    /// @dev Applied to an on-chain spot quote (sanity-check floor only). Does not prevent sandwich
    ///      attacks on its own — keepers must submit compound txs via a private relay.
    uint256 internal constant DEFAULT_AUTOCOMPOUND_MAX_SLIPPAGE_BPS = 500; // 5%

    /// @notice Gas buffer reserved for best-effort Furnace calls in ShareholderRoyalties batch compounding.
    /// @dev Ensures the caller has enough gas to restore per-user accounting if the Furnace call fails.
    uint256 internal constant FURNACE_LOCK_GAS_BUFFER = 200_000;

    /// @notice Max slippage (bps) for LP harvest WETH→CLAIM swap (on-chain sanity-check floor).
    /// @dev This floor is derived from a spot quote and does NOT prevent sandwich attacks on its own.
    ///      Real MEV protection relies on the keeper-supplied minClaimOut + private relay submission.
    uint256 internal constant HARVEST_MAX_SLIPPAGE_BPS = 100; // 1%

    /// @notice Minimum caller quote as a percentage of the on-chain floor (CallerQuoteDivergence check).
    uint256 internal constant CALLER_QUOTE_MIN_FLOOR_PCT = 90;

    /// @notice Hard cap for LpStakingVault7D.compoundForMany(...) users processed per call.
    uint256 internal constant MAX_LP_COMPOUND_USERS_PER_CALL = 50;

    /// @notice Hard cap for Furnace.claimAutoMaxBonusBatch(...) locks processed per call.
    uint256 internal constant MAX_AUTOMAX_BONUS_BATCH = 200;

    /// @notice Default max slippage (bps) for LP vault auto-compound when user config has 0.
    /// @dev 3% narrows the sandwich window for keeper-executed compounds.
    ///      Users needing wider tolerance can explicitly set maxSlippageBps via setAutoCompoundConfig().
    uint256 internal constant DEFAULT_LP_AUTOCOMPOUND_MAX_SLIPPAGE_BPS = 300; // 3%

    /// @notice Hard cap for MineCore.getKingReigns(...) pagination per call.
    uint256 internal constant MAX_KING_REIGNS_PER_CALL = 100;

    // Emergency delist
    uint256 internal constant EMERGENCY_DELIST_MIN_AGE = 7 days;

    // Lock delist reason codes (analytics)
    // NOTE: The strict-mode MarketRouter only emits NORMAL, EMERGENCY, SOLD_TO_FURNACE, and EXPIRED.
    //       SOLD_INTO_OFFER and APPROVAL_REVOKED are reserved analytics codes and are not emitted.
    uint8 internal constant LOCK_DELIST_REASON_NORMAL = 0;
    uint8 internal constant LOCK_DELIST_REASON_EMERGENCY = 1;
    uint8 internal constant LOCK_DELIST_REASON_SOLD_INTO_OFFER = 2;
    uint8 internal constant LOCK_DELIST_REASON_SOLD_TO_FURNACE = 3;
    uint8 internal constant LOCK_DELIST_REASON_EXPIRED = 4;
    uint8 internal constant LOCK_DELIST_REASON_APPROVAL_REVOKED = 5;

    // Shareholder auto-compound pause reason codes (analytics)
    // NOTE: These numeric mappings MUST be immutable once deployed.
    // MUST match `docs/analytics/dune-integration-pack-v1.0.0.md`.
    uint8 internal constant SHAREHOLDER_AUTOCOMPOUND_PAUSE_REASON_NOT_OWNER = 1;
    uint8 internal constant SHAREHOLDER_AUTOCOMPOUND_PAUSE_REASON_LISTED = 2;
    uint8 internal constant SHAREHOLDER_AUTOCOMPOUND_PAUSE_REASON_EXPIRED = 3;
    uint8 internal constant SHAREHOLDER_AUTOCOMPOUND_PAUSE_REASON_INVALID_TOKEN_ID = 4;
    uint8 internal constant SHAREHOLDER_AUTOCOMPOUND_PAUSE_REASON_FURNACE_REVERT = 5;
    uint8 internal constant SHAREHOLDER_AUTOCOMPOUND_PAUSE_REASON_QUOTE_FAILED = 6;
    uint8 internal constant SHAREHOLDER_AUTOCOMPOUND_PAUSE_REASON_CHECKPOINT_FAILED = 7;

    // Marketplace spam control defaults (MarketRouter owner-managed governance config)
    // NOTE: These defaults are the protocol-canonical values.
    uint256 internal constant DEFAULT_MIN_BONUS_TARGET_ESCROW_BUDGET = 10_000e18; // 10,000 CLAIM
    uint256 internal constant DEFAULT_MAX_BONUS_TARGET_ESCROW_DISCOUNT_BPS = 8_000; // 80% cap; set to 10_000 to disable

    /// @notice Default expiry (TTL) for bonus target escrows when escrowTtlSeconds is 0.
    uint256 internal constant DEFAULT_BONUS_TARGET_ESCROW_TTL_SECONDS = 30 days;

    /// @notice Minimum allowed expiry (TTL) for bonus target escrows.
    /// @dev Prevents flash-collateral griefing via sub-minute TTLs.
    uint256 internal constant MIN_BONUS_TARGET_ESCROW_TTL_SECONDS = 300;

    /// @notice Maximum allowed expiry (TTL) for bonus target escrows.
    /// @dev Prevents effectively-infinite escrows while still allowing buyer renewal.
    uint256 internal constant MAX_BONUS_TARGET_ESCROW_TTL_SECONDS = 90 days;

    // Settlement keeper priority (MEV protection)

    /// @notice Grace period during which approved listings/offers prioritize whitelisted keepers (or owner).
    /// @dev After this window elapses (anchored on listing.listedAtTime / offer.createdAt),
    ///      approved listing settlement and offer execution become permissionless as a liveness
    ///      fallback.
    uint256 internal constant SETTLEMENT_KEEPER_GRACE_SECONDS = 1800; // 30 minutes
}
