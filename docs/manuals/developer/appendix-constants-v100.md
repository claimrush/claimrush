# Constants Reference

Curated snapshot of the most user-visible and integration-relevant constants from `src/lib/Constants.sol`. This page is a curated mirror for the manuals, not the canonical source of truth. `src/lib/Constants.sol` is canonical, and some contract-local constants (for example `MineCore.GENESIS_ACCRUAL_DURATION`) intentionally live outside this appendix.

## Takeover (MineCore)

| Constant | Value |
|---|---:|
| TAKEOVER_PRICE_FLOOR | 0.001 ETH |
| TAKEOVER_DECAY_PERIOD | 1 hour |
| KING_ETH_SHARE_PCT | 75 |
| KING_ETH_SHARE_DENOM | 100 |

The canonical takeover split: `KING_ETH_SHARE_PCT / KING_ETH_SHARE_DENOM = 75 / 100`
sends 75% of the takeover payment to the dethroned King and 25% to the Barons
royalty pool. Pinned in `Constants.sol`; not a governance-configurable rate.

## Emissions (MineCore + Furnace)

| Constant | Value |
|---|---:|
| EMISSION_DECAY_PERIOD | 2 years |
| KING_EMISSION_LAUNCH_RATE | 50 CLAIM/sec |
| KING_EMISSION_FLOOR | ~5.56 CLAIM/sec |
| FURNACE_EMISSION_LAUNCH_RATE | 5 CLAIM/sec |
| FURNACE_EMISSION_FLOOR | ~0.555 CLAIM/sec |

The launch and floor rates are a deliberate 10:1 split (King:Furnace). Both
streams decay through the same `_rateAt` helper in `MineCoreHelper`, so
`kingRate(t) = 10 × furnaceRate(t)` holds within ~5–15 wei (parts-per-quintillion
drift from `mulDiv` floor-rounding plus the 5-wei truncation of `5/9` in the
Furnace floor). `AgentLens.currentKingEmissionRate` exposes the King rate
directly, and the SDK's `mineCore.currentKingEmissionRate` field surfaces it via
`getGameStateSnapshot`. Agent strategies should size reign budgets against the
King rate, not the Furnace rate. The 10:1 invariant is pinned by
`testKingFurnaceLaunchRateRatioPinned` and
`testKingFurnaceFloorRatioPinnedWithin5Wei` in
`test/SecurityCriticalConstantsPinned.t.sol`.

## Baron royalties (ShareholderRoyalties)

| Constant | Value |
|---|---:|
| MIN_VE_FLUSH | 100 veCLAIM |
| MAX_REWARD_CHECKPOINTS | 50,000 |
| MAX_OVERFLOW_CHECKPOINTS | 50,000 |
| SHAREHOLDER_MODE_ETH | 0 |
| SHAREHOLDER_MODE_LOCK_FURNACE | 1 |

`MIN_VE_FLUSH` gates manual / residual shareholder flushes. Canonical takeover allocations are
auto-attempted immediately and index against the current processed shareholder denominator once
`checkpointTotalVe()` has advanced `ve.globalLastTs()` to the current block.

Shareholder auto-compound pause reason codebook (`SetAutoCompoundConfig` events; numeric mappings
are immutable once deployed and must match `docs/analytics/dune-integration-pack-v1.0.0.md`):

| Constant | Value |
|---|---:|
| SHAREHOLDER_AUTOCOMPOUND_PAUSE_REASON_NOT_OWNER | 1 |
| SHAREHOLDER_AUTOCOMPOUND_PAUSE_REASON_LISTED | 2 |
| SHAREHOLDER_AUTOCOMPOUND_PAUSE_REASON_EXPIRED | 3 |
| SHAREHOLDER_AUTOCOMPOUND_PAUSE_REASON_INVALID_TOKEN_ID | 4 |
| SHAREHOLDER_AUTOCOMPOUND_PAUSE_REASON_FURNACE_REVERT | 5 |
| SHAREHOLDER_AUTOCOMPOUND_PAUSE_REASON_QUOTE_FAILED | 6 |
| SHAREHOLDER_AUTOCOMPOUND_PAUSE_REASON_CHECKPOINT_FAILED | 7 |

## Furnace lock parameters

| Constant | Value |
|---|---:|
| MIN_LOCK_AMOUNT | 1,000 CLAIM (minimum for `createLock` / `createLockFor`) |
| MIN_TOPUP_AMOUNT | 1 CLAIM (minimum for `addToLock` top-ups; bounds slope rounding dust) |
| MIN_LOCK_DURATION | 7 days; also enforced as the minimum **remaining** time for an existing lock to be used as an entry destination |
| MAX_LOCK_DURATION | 365 days |
| MAX_VE_NFTS_PER_USER | 32 |
| `Furnace.EMERGENCY_VAULT_REWIRE_DELAY` | 7 days (executor cooldown for `requestEmergencyVaultRewire` → `executeEmergencyVaultRewire`; contract-local, lives in `src/Furnace.sol`) |

Furnace entry mode codebook (`FurnaceEnter` events; numeric mappings are immutable once deployed
and must match `docs/analytics/dune-integration-pack-v1.0.0.md`):

| Constant | Value |
|---|---:|
| FURNACE_MODE_ENTER_WITH_ETH | 0 |
| FURNACE_MODE_ENTER_WITH_CLAIM | 1 |
| FURNACE_MODE_LOCK_FURNACE | 2 |
| FURNACE_MODE_ENTER_WITH_TOKEN | 3 |

## LP staking vault (LpStakingVault7D)

| Constant | Value |
|---|---:|
| UNBONDING_PERIOD | 7 days |
| MAX_UNBONDS_PER_USER | 25 |
| MIN_UNBOND_AMOUNT | 1e15 wei (0.001 LP token; minimum per `unbond(...)` request, prevents dust slips) |

## Genesis LP vault

| Constant | Value |
|---|---:|
| INITIAL_LOCK_DURATION | 730 days (24 months) |
| MAX_EXTENSION | 3,650 days (10 years) |
| MAX_ABSOLUTE_LOCK | 36,500 days (100 years) |
| MIN_LP_LOCK | 1e15 wei |
| MIN_EXTENSION_DURATION | 1 day |

## Bonus mechanics

User + LP bonus clamps:

| Constant | Value |
|---|---:|
| BPS_DENOM | 10,000 |
| WEIGHT_PRECISION | 1e8 |
| WEIGHT_DENOM | BPS_DENOM × WEIGHT_PRECISION = 1e12 |
| MAX_USER_BONUS_BPS | 10,000 |
| MAX_GROSS_BONUS_BPS | 12,500 |

`WEIGHT_PRECISION` is the internal precision multiplier of the Furnace duration-weight curve;
`WEIGHT_DENOM` is the matching divisor for `principalEff = mulDiv(amount, weightDelta, WEIGHT_DENOM)`.
The public bps view `durationWeightBps(durationSeconds)` returns the integer floor of the
sub-bp curve.

Lock-% anchors:

| Constant | Value |
|---|---:|
| LOCK_PCT_TARGET_BPS | 700 |
| LOCK_PCT_MIN_FOR_BOOST_CAP_BPS | 500 |
| LOCK_PCT_FULL_BOOST_CAP_BPS | 2,000 |

Reserve-factor cap + ramp:

| Constant | Value |
|---|---:|
| RESERVE_TARGET_FINAL | 20,000,000 CLAIM |
| RESERVE_FACTOR_MAX_BPS_LOWLOCK | 15,000 |
| RESERVE_FACTOR_MAX_BPS | 20,000 |
| SWING_TIME | 60 days |

Virtual depth / decay windows:

| Constant | Value |
|---|---:|
| BONUS_DECAY_WINDOW | 3 hours |
| LP_STREAM_WINDOW | 14 days |

LP top-up (when enabled):

| Constant | Value |
|---|---:|
| LP_TOPUP_RATE_MIN_BPS | 750 |
| LP_TOPUP_RATE_MAX_BPS | 1,500 |
| LP_TOPUP_GAMMA | 2 |

Absolute-supply anchor (not the primary v1.0.0 bonus anchor; retained in Constants for reference):

| Constant | Value |
|---|---:|
| LOCK_TARGET | 120,000,000 CLAIM |

## Furnace sellback (lock → liquid CLAIM)

The sellback quote is a single net payout (`claimOut`). The implied haircut is `lockAmount - claimOut`.

| Constant | Value |
|---|---:|
| SELL_SPREAD_MIN_BPS | 500 |
| SELL_SPREAD_MAX_BPS | 9,900 |
| SELL_SPREAD_FLOOR_7D_BPS | 120 |
| SELL_SPREAD_GAMMA | 2 |
| SELL_ROUND_TRIP_LOSS_MAX_BPS | 9,900 |
| SELL_IMPACT_BPS_PER_STEP | 100 |
| SELL_IMPACT_MAX_BPS | 1,500 |

LP sale (portion of sell haircut routed to LP rewards):

| Constant | Value |
|---|---:|
| LP_SALE_MIN_BPS | 500 |
| LP_SALE_MAX_BPS | 1,500 |
| LP_SALE_GAMMA | 2 |
| LP_SALE_REWARD_CAP_INFLOW_SHARE_BPS | 2,500 |
| LP_SALE_REWARD_CAP_FIXED_CAP_PER_DAY | 150,000 CLAIM/day |

## LP overflow drip (Furnace → LP rewards stream)

Separate from the per-entry LP top-up split. Enabled only when `lpRewardsVault != address(0)`.

| Constant | Value |
|---|---:|
| LP_OVERFLOW_DRIP_START | 18 months (18 × 30 days) |
| LP_OVERFLOW_DRIP_RAMP | 180 days |
| LP_OVERFLOW_DRIP_INFLOW_SHARE_CAP_BPS | 1,000 (10%) |
| LP_OVERFLOW_DRIP_FIXED_CAP_PER_DAY | 30,000 CLAIM/day |
| LP_OVERFLOW_DRIP_GATE_K | 2,000,000 CLAIM |

View helpers on Furnace: `getLpOverflowDripPerDay()`, `getLpStreamRemaining()`, `getLpStreamState()`.

## MarketRouter (listings + buy intents)

| Constant | Value |
|---|---:|
| SETTLEMENT_KEEPER_GRACE_SECONDS | 1800 |
| EMERGENCY_DELIST_MIN_AGE | 7 days |

Buy intent (bonus target escrow) defaults and bounds:

| Constant | Value |
|---|---:|
| DEFAULT_MIN_BONUS_TARGET_ESCROW_BUDGET | 10,000 CLAIM |
| DEFAULT_MAX_BONUS_TARGET_ESCROW_DISCOUNT_BPS | 8,000 |
| DEFAULT_BONUS_TARGET_ESCROW_TTL_SECONDS | 30 days |
| MIN_BONUS_TARGET_ESCROW_TTL_SECONDS | 300 (5 minutes; hard floor on caller-supplied `ttl`, anti–flash-collateral) |
| MAX_BONUS_TARGET_ESCROW_TTL_SECONDS | 90 days (hard ceiling on caller-supplied `ttl`) |

Delist reason codebook:

| Constant | Value |
|---|---:|
| LOCK_DELIST_REASON_NORMAL | 0 |
| LOCK_DELIST_REASON_EMERGENCY | 1 |
| LOCK_DELIST_REASON_SOLD_INTO_OFFER | 2 |
| LOCK_DELIST_REASON_SOLD_TO_FURNACE | 3 |
| LOCK_DELIST_REASON_EXPIRED | 4 |
| LOCK_DELIST_REASON_APPROVAL_REVOKED | 5 |

In the strict-mode MarketRouter, delist codes `2` and `5` are reserved analytics values and are not emitted.

## Maintenance / keepers

| Constant | Value |
|---|---:|
| MAX_MAINTENANCE_OFFERS_PER_CALL | 50 |
| MAX_LP_COMPOUND_USERS_PER_CALL | 50 |
| MAX_SHAREHOLDER_COMPOUND_USERS_PER_CALL | 50 |
| MAX_AUTOMAX_BONUS_BATCH | 200 |

## ve checkpointing

| Constant | Value |
|---|---:|
| MAX_SLOPE_CHANGES_PER_CALL | 250 |

## Pagination (MineCore)

| Constant | Value |
|---|---:|
| MAX_KING_REIGNS_PER_CALL | 100 |

Default slippage / safety bounds used by onchain automation:

| Constant | Value |
|---|---:|
| DEFAULT_AUTOCOMPOUND_MAX_SLIPPAGE_BPS | 500 (ShareholderRoyalties default when user config has 0) |
| DEFAULT_LP_AUTOCOMPOUND_MAX_SLIPPAGE_BPS | 300 (LpStakingVault7D default when user config has 0) |
| `ShareholderRoyalties.MAX_AUTOCOMPOUND_SLIPPAGE_BPS` | 2000 (hard cap on user-supplied `maxSlippageBps` in `ShareholderRoyalties.setAutoCompoundConfig` / `setAutoCompoundConfigForUser`; contract-local — lives in `src/ShareholderRoyalties.sol`, not `Constants.sol`) |
| `LpStakingVault7D.setAutoCompoundConfig` user cap | 1000 (hard-coded 10% cap on user-supplied `maxSlippageBps`; contract-local — `src/vault/LpStakingVault7D.sol`, not `Constants.sol`) |
| `LpStakingVault7D.MIN_COMPOUND_INTERVAL` | 1 day (per-address compound cooldown; gates both `claimRewardsAndLock` against `lastUserLockTs[user]` and `compoundFor` against `lastCompoundTs[user]`; contract-local — `src/vault/LpStakingVault7D.sol`, not `Constants.sol`. `claimRewardsAndLock` reverts `LockCooldown()`; `compoundFor` silently skips.) |
| HARVEST_MAX_SLIPPAGE_BPS | 100 (LP harvest WETH→CLAIM swap on-chain sanity floor) |
| CALLER_QUOTE_MIN_FLOOR_PCT | 90 (caller-supplied quote must be ≥ 90% of the on-chain floor; powers the `CallerQuoteDivergence` keeper validation) |
| FURNACE_LOCK_GAS_BUFFER | 200,000 gas |
| SWAP_DEADLINE_SECONDS | 300 |

## See also

- [Getting Started](getting-started.md) — deployed addresses and SDK install
- [Furnace](furnace.md) — bonus rates and lock parameters
- [Core Mechanics](core-mechanics.md) — emission schedule and takeover pricing
- [Maintenance and Bots](maintenance-and-bots.md) — slippage and deadline defaults
