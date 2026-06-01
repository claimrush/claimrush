# Maintenance and Bots

Permissionless and keeper-gated upkeep surfaces that keep the protocol healthy. A **keeper** is an off-chain bot that executes recurring maintenance transactions — checkpoints, flushes, settlements, compounding — on behalf of the protocol or individual users.

`MaintenanceHub.poke(args)` is the primary housekeeping entry point. Auto-compound keepers handle opt-in reward compounding for Barons and LP stakers.

Two categories of upkeep:
- **Permissionless bounded upkeep** — MaintenanceHub
- **Opt-in compounding** — per-user best-effort keepers

**Policy:** No official Crown-taking bot shipped.

## Self-run agents (bot-owned wallets)

A self-run agent plays from its own wallet (EOA or smart contract):
- no DelegationHub sessions
- no custody of user funds
- direct integration surface (agent owns positions and rewards)

Recommended tooling:
- SDK entrypoint: `agents/sdk/`
- Developer manual: [Agents and automation](agents-and-automation.md)

Operational defaults:
- simulate before sending
- cap spend for takeovers
- use conservative slippage floors and short deadlines


## Opt-in delegated bots (DelegationHub sessions)

DelegationHub enables **session-based delegation** for user opt-in automation.

Why this exists:
- a bot can execute actions **for a user address** without taking custody
- sessions are time-limited and revocable
- protocol contracts enforce permissions onchain only after resolving their canonical auth roots; many delegated paths fail closed on live wiring drift before calling `DelegationHub.isAuthorized(...)`

Session shape:
- `delegate` (bot executor)
- `perms` (bitmask)
- `expiry` (unix seconds)

Common delegated tasks:

| Task | Contract method | Required permission |
|------|------------------|--------------------|
| Take over Crown for a user | `MineCore.takeoverFor(user, maxPrice)` | `P_TAKEOVER_FOR` |
| Update reign payout routing | `MineCore.setCurrentReignRecipients(...)` | `P_SET_REIGN_ETH_RECIPIENT` / `P_SET_REIGN_ETH_RECIPIENT_TO_CALLER_ONLY` and/or `P_SET_REIGN_CLAIM_RECIPIENT` / `P_SET_REIGN_CLAIM_RECIPIENT_TO_USER_ONLY` |
| Collect Barons rewards | `ClaimAllHelper.claimShareholderForUser(user, ...)` | `P_CLAIM_SHAREHOLDER_FOR` |
| Withdraw King fallback bucket | `ClaimAllHelper.withdrawKingBalanceForUser(user)` | `P_WITHDRAW_KING_BUCKET_FOR` |
| Collect all (bundle) | `ClaimAllHelper.claimAllFor(user, ...)` | `P_CLAIM_ALL_FOR` |
| Enter Furnace for a user (bot pays) | `Furnace.enterWithEthFor(user, ...)` | `P_FURNACE_ENTER_ETH_FOR` |
| Maintain veCLAIM lock (extend with bonus) | `Furnace.extendWithBonusFor(user, tokenId, durationSeconds, minBonusOut)` | `P_VE_EXTEND_LOCK_FOR` |
| Maintain veCLAIM locks (merge) | `Furnace.mergeLocksWithBonusFor(user, fromTokenId, intoTokenId, minBonusOut)` | `P_VE_MERGE_LOCKS_FOR` |
| Unlock expired veCLAIM lock | `VeClaimNFT.unlockExpiredForUser(user, tokenId)` | `P_VE_UNLOCK_EXPIRED_FOR` |
| Update King auto-lock config | `MineCore.setKingAutoLockConfigForUser(user, ...)` | `P_SET_KING_AUTO_LOCK_CONFIG_FOR` |
| Update Barons auto-compound config | `ShareholderRoyalties.setAutoCompoundConfigForUser(user, ...)` | `P_SET_SHAREHOLDER_AUTOCOMPOUND_CONFIG_FOR` |
| Update vault auto-compound config | `LpStakingVault7D.setAutoCompoundConfigForUser(user, ...)` | `P_SET_LP_AUTOCOMPOUND_CONFIG_FOR` |

Notes:
- Delegated takeover defaults to routing the dethroned-King 75% ETH payout to the bot executor (to support looping).
- King-stream mined CLAIM stays with the user unless the session grants `P_ROUTE_REIGN_CLAIM_TO_CALLER`.
- Under contention, reverts are normal. Read price right before sending and avoid leaving txs pending for long.

## MaintenanceHub.poke(args)

### Deployment hardening

**Constructor requirements:**

The constructor requires `marketRouter`, `furnace`, `ve`, `royalties`, `weth`, and `rescueRecipient` to all be nonzero addresses. It also requires the full canonical bundle to be wired at deploy time (see [Wiring safety model](protocol-overview.md#wiring-safety-model)):

- `VeClaimNFT.claimToken()` → canonical `CLAIM`
- `ShareholderRoyalties.mineCore()` → canonical `MineCore`
- Cross-checks across `MarketRouter`, `Furnace`, `VeClaimNFT`, `ShareholderRoyalties`, `MineCore`, and `ClaimToken` — every root must agree on one bundle

Do not point it at EOAs, placeholder addresses, or split-brain roots. A bad constructor bundle can look healthy while acting on the wrong surfaces.

**Deployment scripts:**

- `script/DeployMaintenanceHub.s.sol` resolves constructor pins from `DEPLOYMENTS_MANIFEST_JSON` or `deployments/<network>.json`
- `MARKET_ROUTER` / `FURNACE` / `VECLAIM_NFT` / `SHAREHOLDER_ROYALTIES` / `WETH` / `RESCUE_RECIPIENT` env overrides are cross-checks only and must match the manifest
- `rescueRecipient` defaults to the deployer (`msg.sender`) if not specified via environment
- If the canonical bundle is rewired, redeploy `MaintenanceHub`. Its constructor wiring is immutable.

**Token rescue:**

`rescueToken(IERC20 token)` is permissionless and transfers the hub's full balance of `token` to the immutable `rescueRecipient`. It reverts for WETH (which is forwarded via bounty logic). Use this to recover accidentally sent ERC20 tokens.

**Settlement keeper opt-in:**

`poke(args)` is permissionless, so deployment scripts keep the hub off `MarketRouter`'s settlement-keeper allowlist by default. Set `ALLOW_MAINTENANCE_HUB_SETTLEMENT_KEEPER=true` only when you intentionally want any `poke` caller to execute grace-window `executeAutoFurnace` offers. Without that flag, offers included in `poke` are still attempted best-effort but remain active until the grace window expires or an explicit keeper settles them.

### Runtime hardening

`poke(args)` re-checks the full canonical bundle at runtime (see [Wiring safety model](protocol-overview.md#wiring-safety-model)). If the preflight fails, it reverts before any sub-action.

**Signature:** `poke(PokeArgs args)`

**PokeArgs (ABI order):**

| Field | Purpose |
|-------|---------|
| `offerIds: uint256[]` | Buy intent IDs (bonus target escrows) to execute |
| `maxOffers: uint256` | Clamped to `MAX_MAINTENANCE_OFFERS_PER_CALL=50` |

**What poke does (best-effort after canonical preflight succeeds):**

1. VeClaimNFT: `checkpointGlobalState()`
2. ShareholderRoyalties: `flushPendingShareholderETH()`
3. MarketRouter: `executeAutoFurnace(offerId, deadline)` for up to N offerIds (still subject to MarketRouter keeper-grace auth; `MaintenanceHub` passes `block.timestamp + _OFFER_DEADLINE_GRACE` (300s) as deadline)
4. Furnace: `tick()` — accrues LP rewards stream and overflow drip
5. Forward any WETH delta accrued during `poke(args)` to caller (non-reverting `try/catch`; if transfer fails, WETH stays on hub)

**Not included in poke (must be called separately):**
- `MarketRouter.cancelExpiredListing(tokenId)` — expired listings are not swept by `poke(args)`.
- `MarketRouter.cancelExpiredBonusTargetEscrow(offerId)` — expired offers are not cancelled by `poke(args)`.

Keepers that run `poke(args)` should also run a separate sweep for expired listings and offers (see Keeper patterns below).

Grace-window note: `MarketRouter` checks `msg.sender`, not the original EOA. If the hub is allowlisted as a settlement keeper, any `poke` caller inherits grace-window access. See [Settlement keeper opt-in](#deployment-hardening) above.

Why the order matters:
- Flushing before `executeAutoFurnace(...)` prevents a new lock created later in the same poke from sharing older `pendingShareholderETH` that predates its entry.
- If `globalLastTs()` remains stale after the bounded checkpoint calls, the flush no-ops and pending ETH stays queued.
- Direct `flushPendingShareholderETH()` calls revert with `Errors.WiringMismatch()` on bundle drift; `poke(args)` catches the same condition earlier in its canonical-bundle preflight.

### Repo keeper (`keeper/`): `poke` scheduling

The shipped daemon task `poke` calls `MaintenanceHub.poke` only when skip-if-idle finds work (no tx on idle cycles):

- **New reign:** scans `MineCore` `Takeover` logs; a poke is justified only when `reignId` is **greater** than `lastProcessedTakeoverReignId` in `poke.json`. That avoids re-triggering on the same reign while the log scan window overlaps prior blocks.
- **LP stream / `Furnace.tick`:** when the stream is active, a poke is justified only if at least `KEEPER_POKE_LP_TICK_INTERVAL_SECS` have passed since the last successful furnace tick (default **3600** in `keeper/src/shared/config.ts`). Shorter intervals mostly burn gas; accrued CLAIM is unchanged over time, only batching differs.
- **Ve checkpoint:** when `globalLastTs` is older than `KEEPER_POKE_STALE_SECS` (default **86400s / 24h**). This is a safety net for idle periods only; normal takeover-driven pokes keep the checkpoint fresh.
- **Market:** eligible auto-furnace offers (after optional preflight).
- **Shareholder flush signal:** `pendingShareholderETH` delta exceeds `KEEPER_POKE_MIN_PENDING_ETH_DELTA` (default **0.01 ETH**) since the last check. Rounding dust from `onTakeover()` flushes is ignored.

Onchain, every successful `poke` still runs `Furnace.tick` inside `MaintenanceHub`; the keeper’s job is to avoid submitting txs when there is nothing meaningful to do.

## Keeper patterns

| Task | Method | Bound |
|------|--------|-------|
| Shareholder auto-compound | `ShareholderRoyalties.compoundForMany(users[], maxUsers)` | Up to 50 users/call (clamped onchain; caller must be the owner or an allowlisted Baron compound keeper) |
| Vault auto-compound | `LpStakingVault7D.compoundForMany(users[], maxUsers)` | Up to 50 users/call (clamped onchain; caller must be the owner or an allowlisted LP harvest/compound keeper) |
| Settle listed locks | `MarketRouter.sellListedLockToFurnace(tokenId, deadline)` | 1 tokenId/tx (batch offchain; no onchain cap; approved listings are keeper/owner-gated during grace; `deadline` reverts with `DeadlineExpired` if block.timestamp > deadline) |
| AutoMax automatic bonus growth | `Furnace.claimAutoMaxBonus(tokenId)` or `Furnace.claimAutoMaxBonusBatch(tokenIds[], maxLocks)` | Single: 1 tokenId/tx. Batch: up to 200 locks/call (clamped by `MAX_AUTOMAX_BONUS_BATCH`). 24h onchain cooldown per lock; ineligible locks return 0 (no revert); permissionless. Official keeper enforces 7-day per-owner cooldown and groups a single owner's locks together; first-touch owners (every candidate lock has `lastAutoMaxBonusClaim == 0`) bypass the off-chain cooldown so a brand-new lock owner is eligible on the next scheduled tick instead of waiting a week. The owner-group prefilter is total-size aware: a group that fits in the remaining `maxLocks` capacity is packed whole, an oversized middle group is skipped so smaller later owners still run, and a degenerate first-owner group larger than `maxLocks` is sliced down to `maxLocks` so the keeper never stalls. Keeper skips locks whose quoted bonus is below `KEEPER_AUTOMAX_BONUS_MIN_REWARD` (default **100 CLAIM**) to avoid wasting gas on small accruals; the keeper chunks `quoteAutoMaxBonusBatch` calls at `MAX_AUTOMAX_BONUS_BATCH` and merges the bonus arrays before applying that floor, so candidate sets above 200 are still filtered correctly. |
| Cancel expired listings | `MarketRouter.cancelExpiredListing(tokenId)` (or onchain batch `cancelExpiredListingBatch(tokenIds[])`) | Single: 1 tokenId/tx. Batch: best-effort, no onchain cap on array length — caller controls gas. Permissionless. Both remain callable while trading is paused. |
| Expire buy intents (bonus target escrows) | `MarketRouter.cancelExpiredBonusTargetEscrow(offerId)` (or onchain batch `cancelExpiredBonusTargetEscrowBatch(offerIds[])`) | Single: 1 offerId/tx. Batch: best-effort, no onchain cap on array length — caller controls gas. Permissionless. Both remain callable while trading is paused. Note: `cancelExpiredBonusTargetEscrowBatch` reverts the **whole** call if any one buyer's CLAIM refund fails (e.g. blacklisted recipient); use the per-offer single variant for unaffected buyers when that happens. |

Optional helper task:
- `checkpoint-before-expiry` may still call `ShareholderRoyalties.checkpointUser(owner)` for locks nearing expiry.
- The historical reward-checkpoint mechanism preserves rewards for decaying locks automatically.
- It remains useful for UX / gas smoothing when you want balances crystallized ahead of time.
- `ShareholderRoyalties.checkpointUser(owner)` is **permissionless** and **has no on-chain cooldown** — the function silently no-ops when there is nothing to crystallize (`idx == paid`). The **48-hour per-owner cooldown is enforced off-chain by the official keeper** (`keeper/src/tasks/checkpoint_before_expiry.ts`), tracked via `lastCheckpointedAt` in keeper state. Third-party keepers that want to coordinate with the official one should respect the same window; otherwise the on-chain function will no-op redundant calls.
- Treat `Errors.WiringMismatch()` as a hard operator signal — stop retrying until wiring is corrected (see [Wiring safety model](protocol-overview.md#wiring-safety-model)).

Keeper dust thresholds:
- `harvest-staking` skips harvests below `harvestStakingMinReward` / `KEEPER_HARVEST_STAKING_MIN_REWARD` (default: **1000 CLAIM**) to avoid wasting gas on dust.
- `compound-shareholders` skips users whose claimable ETH is below **0.001 ETH** (hardcoded keeper floor). Users can set their own higher minimum via `minEthToCompound` in their auto-compound config; the keeper uses whichever is higher.
- `compound-lp` skips users below `compoundLpMinReward` / `KEEPER_COMPOUND_LP_MIN_REWARD` (default: **1000 CLAIM** per user) to avoid dust compounding. Intentionally high to avoid wasting gas; lower as gas economics improve.
- `automax-bonus` skips locks whose quoted bonus is below `automaxBonusMinReward` / `KEEPER_AUTOMAX_BONUS_MIN_REWARD` (default: **100 CLAIM**). The keeper enforces a 7-day per-owner cooldown off-chain and groups all of a user's eligible locks together; the accrued bonus over a week justifies the gas cost, then executes a single batch transaction. First-touch owners (every candidate lock has `lastAutoMaxBonusClaim == 0`) bypass the off-chain cooldown so a fresh lock owner is paid out on the next scheduled tick instead of waiting a week for the first bonus.

Keeper cursor and deferred-set semantics:
- `poke` advances its internal block cursor only when both the takeover-scan stage completed cleanly (no RPC error mid-range, no malformed Takeover decode) AND the post-tx flush stage succeeded. The on-chain `Poked(furnaceTickSucceeded, flushOk)` event is the authoritative signal: when the receipt does not carry a decoded `Poked` log (missing log, wrong hub address, ABI drift), both stage flags default to `false` and every dependent cursor is held for the next idle tick. A failed flush leaves the per-reign cursor pinned to the prior reign, and the block cursor cannot move past a window the next tick must replay; without this gate, a transient flush failure or a missing receipt event would silently retire the takeover-reign and the corresponding per-reign accounting would never re-flush.
- `compound-shareholders` keeps a `pendingDeferredUsers` queue of users skipped by a latched global stop code (`paused`, `pending_guard`, `fee_cap`, `gas_limit_cap`, `total_fee_cap`, `dry_run`) on the per-user fallback path. The next batch drains this queue ahead of the round-robin so a long-lived stop cannot let the cursor lap the deferred set without ever revisiting it. Users that successfully compound on a later tick are removed from the queue; a still-latched stop re-populates the queue from the same fallback path. Deferred-origin users that drained into a tick but did not actually run — because the gas-bounded shrink dropped them as a tail, the run was a dry run, the entire prefix collapsed under the gas cap, or the batch-level send returned a global skip — are re-deferred so the next selection cycle drains them again ahead of the round-robin.
- `compound-lp` decodes the `LpRewardsLocked(address user, uint256 amountClaim, uint256 principalClaim, uint256 bonusClaim, uint256 tokenId)` event from `LpStakingVault7D` to reconcile per-user reward state. The event must be present in the keeper-side ABI for `decodeEventLog` to resolve; the shipped `LP_STAKING_VAULT_ABI` carries the canonical entry.

### Sweep listings task

Settles Market listings (limit sells) when the live payout meets or exceeds the seller's **Minimum payout** (`minClaimOut`):
1. Scan for `LockListed` events to find active listings (track `expiresAtTime` and `listedAtTime`)
2. If `block.timestamp >= expiresAtTime`: call `cancelExpiredListing(tokenId)` (permissionless cleanup)
3. If `block.timestamp < listedAtTime + SETTLEMENT_KEEPER_GRACE_SECONDS` and you are neither an allowlisted settlement keeper nor the `MarketRouter` owner, skip approved listings during the keeper grace window.
4. Otherwise, compute the live quote payout (already net) and check if `claimOut >= minClaimOut`
   - Read lock info: `VeClaimNFT.getLockInfo(tokenId)` → `(lockAmount, lockEnd, autoMax, listed)`
   - Quote with: `FurnaceQuoter.quoteSellLockToFurnaceFromInfo(lockAmount, lockEnd, autoMax)` (resolve address via `Furnace.furnaceQuoter()`)
   - Note: user-scoped sell quotes (`quoteSellLockToFurnace` / `quoteSellLockToFurnaceBreakdown`) revert while a lock is listed
5. Call `sellListedLockToFurnace(tokenId, deadline)` to settle

### Expire buy intents task

Cancels expired Buy intents (bonus target escrows) and refunds remaining budget to buyers:
1. Scan for active buy intents via bonus target escrow events
2. Check if `block.timestamp > intent.expiresAt`
3. Call `cancelExpiredBonusTargetEscrow(offerId)` to refund

**Guidance:**
- Keepers should be aware that auto-compound pauses when destination locks have **< 7 days** remaining (non-AutoMax). Users need to extend the lock or switch to a different destination.
- Treat compound calls as best-effort
- Surface pause reasons in UX
- For flows where your bot supplies `minVeOut` (direct Furnace entries / Collect-and-Lock), derive it from the live quote + your slippage policy.
- For auto-compound calls, `minVeOut` is computed onchain from a spot quote and the user’s stored `maxSlippageBps` (the keeper cannot override it).

## Slippage and deadlines

| Concept | Usage |
|---------|-------|
| `minClaimOut` | Aerodrome swaps (harvest paths) |
| `minVeOut` | Furnace entry / compounding paths |

**Typical defaults:**
- Swap slippage: 0.5-1%
- ve slippage: 0.5-1%
- Swap deadline (onchain DEX paths): `now + SWAP_DEADLINE_SECONDS` (**300s**)
- Market sell deadline (`sellLockToFurnace`): caller-supplied. Bots should choose a short deadline that matches their execution path and slippage policy.

## Settlement Window (configurable cadence)

An opt-in keeper scheduling policy that consolidates reward-settlement tasks (shareholder compound, LP compound, AutoMax bonus, LP harvest) into a single recurring cycle. The cadence is configurable via `KEEPER_SETTLEMENT_PERIOD_SECS` — **daily by default** (`86400`); set `604800` for weekly.

**Design:** keeper policy and product cadence, not a protocol-level rule. On-chain accrual remains continuous. The settlement window determines *when the keeper settles* — not when value accrues.

### Two-phase execution

All four settlement tasks fire within a window (default: a 24-hour window opening daily at 00:00 UTC; under a weekly period it opens on `KEEPER_SETTLEMENT_DAY_UTC`, default Thursday), split into two phases based on price sensitivity.

**Phase 1 — Immediate (window open):**

Non-price-sensitive tasks run sequentially at window open with a configurable gap (default: 60s).

| Order | Task | Why immediate |
|-------|------|---------------|
| 1 | `compound-lp` | Sends CLAIM to Furnace via `enterWithClaimFor`. No DEX swap — no front-running risk. |
| 2 | `automax-bonus` | Mints from Furnace reserve into locks. No DEX swap. Benefits from seeing post-compound `lockAmount` for `principalEff` sizing. |

**Phase 2 — Spread (over 24 hours):**

Price-sensitive tasks are distributed across the remaining window with randomized timing.

| Task | Execution model | Risk mitigated |
|------|----------------|---------------|
| `harvest-staking` | Once, opportunistically, when quote is favorable | Concentrated WETH→CLAIM swap |
| `compound-shareholders` | Market-impact-budgeted batches, randomized timing | Predictable synchronized buy pressure on CLAIM |

Why spread: a hard global settlement minute with all price-sensitive tasks firing at once creates predictable synchronized buy pressure that invites front-running, sandwiching, pre-positioning, and worse fills. Spreading execution across the window makes it much harder to sandwich profitably. (A shorter period such as daily also splits the per-cycle buy pressure into smaller chunks, further reducing per-event slippage.)

### Market-impact budget

Before each `compound-shareholders` batch, the keeper estimates the input size and checks quote drift against a configurable tolerance (`KEEPER_SETTLEMENT_MAX_DRIFT_BPS`, default: 100 = 1%). If the next batch would worsen fills beyond the tolerance, the keeper pauses and retries later in the window when the pool has absorbed the prior batch.

### Cycle-keyed state

Settlement state is keyed by a deterministic cycle ID derived from the window-open timestamp (e.g., `"2026-06-04"` for the cycle opening on 2026-06-04). Per-cycle state tracks:

- Phase and which immediate tasks completed (prevents duplicate phase-1 execution on restart)
- Harvest completion (single global action)
- Spread batch completion (per-batch, per-user)
- Priority queue from the prior cycle (starvation protection)
- Failed/retryable items

Persisted state is structural only: cycle ID, addresses, phase, completion flags. Quotes, reward amounts, and impact estimates are **never persisted** — they must be fetched fresh at execution time.

On daemon restart mid-window: read the cycle state, skip completed tasks, resume from the next pending batch. On restart between cycles (outside window): state is read-only until the next window opens.

### Cooldown model: cycle eligibility

When settlement mode is enabled, the keeper gates on per-cycle eligibility: "was this user processed in the current cycle?" The per-user keeper floor defaults to the settlement period (so it moves in lockstep with the cadence), and the on-chain checks (24h / 1 day / user-configured `minCadenceSeconds`) still run at execution time.

Exception: if a user sets `ShareholderRoyalties.minCadenceSeconds` to longer than the settlement period, the on-chain check remains authoritative. That user intentionally skips some cycles.

### Starvation protection

Users who were skipped or missed in cycle N (due to drift pause, window close, or quote failure) get first position in cycle N+1's spread queue. Within the priority tier, morning-window jitter still applies. No user can be starved for more than one consecutive cycle unless their individual checks genuinely fail.

### Skip rules preserved

All existing skip rules are enforced inside the window:
- No tx if the reward/value is below the configured threshold
- No tx if the per-user cooldown has not elapsed
- No tx if simulation/quote says it is not currently needed
- If one owner is eligible for multiple actions, run them in the fixed order and skip ineligible ones

The window is best-effort and conditional. It opens the gate for settlement; the existing task logic decides whether each user actually gets a tx.

### Reserve draw cycle

Settlement creates a periodic draw on `furnaceReserve`. Non-price-sensitive tasks (LP compound, AutoMax) draw reserve immediately at window open via `_applyBonusAmm`. Price-sensitive draws (shareholder compound batches) are spread across the 24-hour window.

`bonusVirtualDepth` recovers on the `BONUS_DECAY_WINDOW` (3h) timescale after each draw. Between cycles, the reserve refills continuously via emission stream, sellback credits, and overflow drip.

### Morning cache reuse

The per-user morning-hour cache from `user_morning.ts` is repurposed within the settlement window: if a user has a detected morning hour that falls within the 24h window, their compound batch is scheduled near that time. This adds natural per-user jitter to the spread phase.

### Configuration

| Env var | Default | Description |
|---------|---------|-------------|
| `KEEPER_SETTLEMENT_ENABLED` | `false` | Opt-in flag. Existing deployments unaffected until enabled. |
| `KEEPER_SETTLEMENT_PERIOD_SECS` | `86400` (daily) | Master cadence. `86400` = daily, `604800` = weekly. Drives the window spacing and the per-user floors. |
| `KEEPER_SETTLEMENT_DAY_UTC` | `4` (Thursday) | Day of week for window open (0=Sun..6=Sat). Only applies to weekly-multiple periods; ignored for daily. |
| `KEEPER_SETTLEMENT_HOUR_UTC` | `0` | Hour (UTC) for window open. |
| `KEEPER_SETTLEMENT_WINDOW_DURATION_SECS` | `86400` (24h) | Duration of the settlement window. Clamped to at most one period so windows never overlap. |
| `KEEPER_SETTLEMENT_TASK_GAP_SECS` | `60` | Pause between immediate-phase tasks. |
| `KEEPER_SETTLEMENT_RETRY_WINDOW_SECS` | `3600` | Retry window for failed immediate tasks. |
| `KEEPER_SETTLEMENT_MAX_DRIFT_BPS` | `100` (1%) | Max acceptable quote drift per batch before pausing price-sensitive execution. |

Per-user floors default to the master period; override individually to decouple a task from the cadence:

| Env var | Default | Description |
|---------|---------|-------------|
| `KEEPER_COMPOUND_SHAREHOLDER_MIN_CADENCE_SECS` | = period | Min seconds between shareholder compounds per user. A user's own on-chain `minCadenceSeconds` still wins when larger. |
| `KEEPER_COMPOUND_LP_MIN_CADENCE_SECS` | = period | Min seconds between LP compounds per user (off-chain cooldown). |
| `KEEPER_AUTOMAX_OWNER_COOLDOWN_SECS` | = period | Min seconds between AutoMax bonus runs per owner (off-chain cooldown). |

### Switching cadence (daily ↔ weekly)

Cadence is configuration, not code. To switch:

1. Keeper: set `KEEPER_SETTLEMENT_PERIOD_SECS` (`86400` daily / `604800` weekly); for weekly confirm `KEEPER_SETTLEMENT_DAY_UTC`. Restart the keeper.
2. Frontend: set `SETTLEMENT_PERIOD_MS` in the frontend cadence module `settlementCadence.ts` to match (`86400000` / `604800000`) and redeploy.

No state migration is needed in either direction. The per-user floors are recomputed live from the current period, so existing `lastCompounded`/on-chain `lastCompoundTs` anchors are reinterpreted against the new cooldown automatically, and the on-chain floors (`LpStakingVault7D.MIN_COMPOUND_INTERVAL = 1 day`, `ShareholderRoyalties.minCadenceSeconds`) remain authoritative — so the keeper never compounds earlier than the chain allows.

### Third-party keepers

Third-party keepers or bots that compound for users should be aware of the settlement window. When enabled, the official keeper will not process settlement tasks outside the window. Third-party keepers calling `compoundForMany`, `harvestFeesToRewards`, or `claimAutoMaxBonusBatch` at other times will succeed on-chain (these are permissionless calls) but may interfere with the settlement cycle's batching and starvation protection.

## See also

- [Agents and Automation](agents-and-automation.md) - SDK, CRAL pack, and agent architecture
- [Bot Sessions (DelegationHub)](delegationhub.md) - session permissions for keepers
- [Security, Guardian, Pausing](security-guardian-pausing.md) - pause states that affect keeper loops
- [Constants Reference](appendix-constants-v100.md) - slippage and deadline defaults
- Tutorial: [Run a MaintenanceHub bot](tutorials/run-maintenance-bot.md)
- SDK examples: `agents/sdk` -> `example:delegation`, `example:agent -- --acting-for <user>`
