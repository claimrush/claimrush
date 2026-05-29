# ShareholderRoyalties (Barons)

`ShareholderRoyalties` distributes ETH from takeovers to veCLAIM holders (Barons). It maintains a per-ve ETH index and supports two payout modes: Collect ETH (liquid) and Collect & Lock (compound through the [Furnace](furnace.md)). In the [CLAIM stream](protocol-overview.md), this is where the 25% takeover ETH flows to locked CLAIM holders and optionally compounds back into veCLAIM.

> **TL;DR:** Collect via `claimShareholder(mode, targetTokenId, durationSeconds, createAutoMax, minVeOut)`. `mode=0` sends ETH; `mode=1` routes through the Furnace via `lockEthReward` and compounds into the user's destination lock. Read-only previews via `claimableEth(user)` or `getShareholderState(user)`. Auto-compound is owner-or-keeper-allowlisted with per-user cadence.

## Public API

| Function | Caller | Purpose |
|---|---|---|
| `claimShareholder(mode, targetTokenId, durationSeconds, createAutoMax, minVeOut)` | user | Collect (`mode=0`) or Collect & Lock (`mode=1`). |
| `claimShareholderTo(to, mode, ...)` | user | Same, with explicit ETH receiver; `mode=1` requires `to == msg.sender`. |
| `claimShareholderFor(user, ...)` | `ClaimAllHelper` only | Helper-bundled Collect path. |
| `claimableEth(user) -> uint256` | view | Authoritative live preview (stored + uncheckpointed accrual). |
| `claimableEthStored(user) -> uint256` | view | Storage-only bucket; excludes uncheckpointed accrual. |
| `getShareholderState(user) -> (claimable, userVe, paid)` | view | Live preview plus user ve and last-paid index. |
| `checkpointUser(user)` | anyone | Materializes the user's pending accrual. State-changing. |
| `setAutoCompoundConfig(...)` | user | Opt in / out + tune cadence, slippage, destination. |
| `compoundFor(user, quote)` | owner or compound keeper | Auto-compound a single opted-in user. |
| `compoundForMany(users, quotes)` | owner or compound keeper | Batch path; skips unviable users instead of pausing. |
| `flushPendingShareholderETH()` | anyone | Re-attempt the index push for queued takeover ETH. |
| `onTakeover(reignId) payable` | `MineCore` only | Receive 25% takeover ETH and attempt indexing. |
| `lockEthReward(user, ethAmount, ...)` | `Furnace` only | Counterparty for `mode=1` compound. |

## Collecting (claimShareholder)

ShareholderRoyalties exposes a single entry for users:
- claimShareholder(mode, targetTokenId, durationSeconds, createAutoMax, minVeOut)

Modes:
- mode 0: send ETH to user (UI verb: Collect)
- mode 1: route ETH through Furnace.lockEthReward (ETH → CLAIM + Furnace bonus, locked to veCLAIM)

UI recommendation:
- Primary CTA: mode 0 (Collect ETH). Secondary: mode 1 (Collect & Lock) when `Furnace.lockingPaused == false`.
- When `Furnace.lockingPaused == true`, mode 0 (Collect ETH) is the only enabled path.

Notes:
- The contract name and method names use "claim". UI copy MUST use **Collect** for ETH.
- All state-changing collect paths fail closed on bundle drift (see [Wiring safety model](protocol-overview.md#wiring-safety-model)). If wiring is wrong, the call reverts and claimable ETH is preserved.

Helper-only entrypoint:
- `claimShareholderFor(user, ...)` exists for ClaimAllHelper bundling (and is `onlyClaimAllHelper`).
- If you want a one-tx "Collect + withdraw King bucket" flow or delegation-gated Collect wrappers, use:
  - [ClaimAllHelper (bundle + delegated Collect)](claimallhelper.md)

## Collect to alternate receiver

`claimShareholderTo(address payable to, uint8 mode, uint256 targetTokenId, uint256 durationSeconds, bool createAutoMax, uint256 minVeOut)` collects Baron ETH rewards to a specified receiver address. This allows smart-contract wallets whose primary address cannot receive ETH to redirect payouts to an EOA or compatible receiver.

- **Mode ETH** (`mode = 0`): sends collected ETH to `to`.
- **Mode LOCK_FURNACE** (`mode = 1`): `to` must equal `msg.sender` (the lock is always created for the caller). Reverts with `NotAuthorized` otherwise.
- Emits both `ShareholderClaim(user, mode, amount)` and `ShareholderClaimed(user, to, amount, mode)` (includes destination).

The `ShareholderClaimed` event is the canonical receipt for indexers tracking payout destinations. It is only emitted by `claimShareholderTo`, not by the original `claimShareholder` / `claimShareholderFor` paths.

## UI display (read-only) without checkpointUser

For monitoring surfaces and UIs, avoid calling `checkpointUser(user)` just to render a number (it is state-changing).

Read either of the two equivalent **live** preview surfaces:
- `claimableEth(user) -> uint256` — explicit external view (not an auto-getter; `_claimableEthStored` is `internal`). Routes through `_computeShareholderState` and returns the full live entitlement (stored bucket + uncheckpointed accrual implied by the global reward index).
- `getShareholderState(user) -> (claimable, userVe, paid)` — same `claimable` as above, plus the user's current ve and last-paid index. The Solidity field is named `claimable`; documentation sometimes aliases it as `claimableEthLive` for clarity.

Storage-only counterpart (use only when you specifically need the crystallised value, e.g. invariant assertions or off-chain reconciliation against payout transfers):
- `claimableEthStored(user) -> uint256` — returns just the `_claimableEthStored[user]` storage bucket and **excludes** uncheckpointed accrual. Dashboards that display this as the user's total will systematically understate Baron balances; use `claimableEth(user)` or `getShareholderState(user).claimable` instead.

Important:
- Both `claimableEth(user)` and `getShareholderState(user).claimable` are authoritative live previews.
- Do **not** recompute `claimable + userVe * (ethPerVe - paid) / ACC` offchain — that shortcut is wrong for decaying locks because it ignores historical flush timestamps.

Notes:
- The live preview still excludes ETH sitting in `pendingShareholderETH` (not yet flushed into the index).
  In normal gameplay this bucket should mostly be zero-holder carry, tiny dust, or brief carry while the ve checkpoint catches up.
- A Collect transaction checkpoints internally first, so you do not need to checkpoint separately.

## Auto-compound (owner-or-keeper-allowlisted)

This is an opt-in config. Compounding for an opted-in user is owner-or-keeper-allowlisted: the normal executor is an allowlisted Baron compound keeper, and owner break-glass remains available for recovery.

`setAutoCompoundKeeper(addr, true)` runs the delegated-EOA rejection on `addr` before allowlisting; a 7702-delegated address reverts `DelegatedEOA` at the setter. The disable path (`allowed == false`) skips the check so a compromised seat can always be removed. See [Security, Guardian, Pausing — Keeper allowlist 7702 guard](security-guardian-pausing.md#keeper-allowlist-7702-guard) for the cross-contract rule.

Config fields (stored per user):
- `enabled`, `paused`
- `tokenId` destination
  - MUST be an existing eligible user-owned lock at config time
  - v1 auto-compound never creates a new lock as a fallback; invalid destinations pause instead
- `durationSeconds` (stored; v1.0.0 execution note)
  - validated when saving config (MIN..MAX; AutoMax requires MAX)
  - adding capital does not change the lock's duration
  - effective duration at execution: current remaining for normal locks, or `MAX_LOCK_DURATION` for AutoMax
- `minCadenceSeconds` (minimum seconds between successful compounds)
- `minEthToCompound` (skip dust amounts)
- `maxSlippageBps`
  - `0` = use `DEFAULT_AUTOCOMPOUND_MAX_SLIPPAGE_BPS` (v1.0.0: 500 = 5%)
  - must be `<= 2_000` (20%); reverts `SlippageTooHigh` above this cap
- `lastCompoundTs` (read-only; updated on success)

`_validateAutoCompoundDestination` returns `(false, EXPIRED)` when a **non-AutoMax** destination lock has less than `MIN_LOCK_DURATION` (7 days) remaining.

Config surfaces:
- `setAutoCompoundConfig(...)`
- Delegation-gated setter: `setAutoCompoundConfigForUser(user, ...)` (requires `P_SET_SHAREHOLDER_AUTOCOMPOUND_CONFIG_FOR`)
  - auth fails closed on bundle drift and also requires Furnace + MineCore to agree on one canonical `DelegationHub` (see [Wiring safety model](protocol-overview.md#wiring-safety-model))

Execution surfaces:
- compoundFor(user)
- compoundForMany(users[], maxUsers) (bounded per call)

Slippage model (important):
- Executors do **not** pass `minVeOut`.
- ShareholderRoyalties computes `minVeOut` from a Furnace **spot quote** and the user’s stored `maxSlippageBps`.
- If `veOut > 0` but floor-rounding would produce `minVeOut == 0`, the contract clamps it to `1` before calling Furnace.
- If the quote fails:
  - `compoundFor(user)` reverts rather than executing without a floor
  - `compoundForMany(users[], maxUsers)` skips that user and continues
- Offchain maintainer calls SHOULD submit auto-compound txs via a private relay for MEV protection; owner break-glass should do the same when practical.

Wiring safety:

- `compoundFor(user)`: atomic — reverts on quote failure, bundle drift, or Furnace call failure. Claimable ETH and cadence state stay untouched on revert.
- `compoundForMany(users[], maxUsers)`: best-effort per user:
  - Canonical bundle check (`_requireCanonicalBaronRuntimeBundle`) runs once at the top — reverts the whole call if wiring is broken
  - Checkpoint failure → pauses that user (reason `CHECKPOINT_FAILED = 7`), continues batch
  - Quote failure → skips that user (emits `ShareholderAutoCompoundFailed`), does NOT pause, continues batch
  - Furnace call failure → pauses that user (reason `FURNACE_REVERT = 5`), restores user accounting, continues batch

Pause reasons (analytics codes, `Constants`):

| Code | Reason |
|------|--------|
| 1 | NOT_OWNER |
| 2 | LISTED |
| 3 | EXPIRED |
| 4 | INVALID_TOKEN_ID |
| 5 | FURNACE_REVERT |
| 6 | QUOTE_FAILED |
| 7 | CHECKPOINT_FAILED |

Integrator guidance:
- `compoundForMany` is best-effort; `compoundFor` is atomic and may revert.
- UIs should surface pause reasons and provide a single-transaction fix (delist, extend, update tokenId).

### Settlement window execution

When the keeper's weekly settlement window is enabled, baron auto-compound runs in the **spread phase** (phase 2): compound-shareholders batches are distributed across the 24-hour window with randomized timing and market-impact-budgeted execution.

Each batch checks quote drift before executing. If the next batch would worsen fills beyond the configured tolerance (`KEEPER_SETTLEMENT_MAX_DRIFT_BPS`), the keeper pauses and retries later in the window. Users missed in one cycle get first position in the next cycle's spread queue (starvation protection).

On-chain behavior is unchanged. The settlement window is a keeper scheduling policy. `compoundForMany` remains permissionless and can be called at any time by third-party keepers.

See [Weekly Settlement Window](maintenance-and-bots.md#weekly-settlement-window) for full configuration and design.

## Batch checkpoint

`checkpointUserBatch(address[] calldata users, uint256 maxUsers)` crystallises accrued ETH rewards for multiple users in a single transaction, capped by `maxUsers`. Each iteration calls `this.checkpointUser(user)` via try/catch — any individual revert is silently skipped and the batch continues processing remaining users (best-effort semantics).

## ETH allocation

On every takeover, MineCore allocates ETH to ShareholderRoyalties:
- genesis takeover (prevKing == 0x0): 100% of pricePaid
- otherwise: 25% of pricePaid

The contract tracks:
- pendingShareholderETH: ETH waiting to be indexed (typically zero-holder carry, rounding dust, transient carry while the ve checkpoint is still catching up to the current block timestamp, or deferred carry while checkpoint storage cannot safely represent a new reward timestamp)
- ethPerVe: global index, scaled by ACC = 1e18
- reward checkpoints keyed by flush timestamp so delayed collects for decaying locks stay correct. Once the main array reaches `MAX_REWARD_CHECKPOINTS` (50,000) it is frozen and subsequent flushes append to a bounded overflow array (`_overflowCheckpoints`, capped at `MAX_OVERFLOW_CHECKPOINTS`). `_getRewardPrefixBefore` binary-searches both arrays. When the overflow array itself fills it becomes a ring buffer with FIFO eviction of entries older than `MAX_LOCK_DURATION`. If every overflow entry is still inside the active lock horizon and the new flush has a distinct timestamp, ShareholderRoyalties **defers the flush before mutating `ethPerVe`** and leaves the ETH in `pendingShareholderETH` until the oldest overflow entry ages out. Same-block writes still coalesce in place when the timestamp matches exactly.

Runtime hardening:
- All state-changing royalties paths (`onTakeover`, `addPendingShareholderETH`, non-empty `flushPendingShareholderETH`) fail closed on bundle drift (see [Wiring safety model](protocol-overview.md#wiring-safety-model)).
- This prevents MineCore from silently indexing takeover ETH into a stale royalties surface.

## Index formula (ethPerVe)

Constants:
- ACC = 1e18
- SHAREHOLDER_WEIGHT_SCALE = 1e18
- SHAREHOLDER_ACC = 1e36
- MIN_VE_FLUSH = 100e18 (minimum total ve for manual / residual flushes)

Takeover allocations are auto-attempted immediately whenever a processed denominator exists, even below `MIN_VE_FLUSH`:

- They index in the takeover tx only when `ve.globalLastTs() == block.timestamp` after `checkpointTotalVe()`.
- If `globalLastTs()` is still stale, flushing defers — ETH stays in `pendingShareholderETH` until the checkpoint reaches the current block.
- If checkpoint storage is saturated and cannot safely represent a new distinct reward timestamp, flushing also defers — ETH stays in `pendingShareholderETH` until FIFO eviction becomes safe again.
- Manual / permissionless flushes still use `MIN_VE_FLUSH` for leftover pending ETH.
- Non-empty flushes fail closed on bundle drift (`Errors.WiringMismatch()`). See [Wiring safety model](protocol-overview.md#wiring-safety-model).

Flushing moves ETH from pendingShareholderETH into ethPerVe:

```text
ve.checkpointTotalVe()  # REQUIRED before reading processed ve-bias state
rewardTs = ve.globalLastTs()
if rewardTs != now: do nothing   # defer until the ve checkpoint fully catches up

# totalWeight is the processed total ve-bias used internally by VeClaimNFT.
totalWeight = ve.totalVeBiasScaled()          # units: ve * 1e18
if totalWeight == 0: do nothing
if ceil(totalWeight / 1e18) < MIN_VE_FLUSH: do nothing
if reward checkpoint storage cannot safely represent rewardTs: do nothing

# delta = floor(pending * SHAREHOLDER_ACC / totalWeight)
delta = floor(pendingShareholderETH * 1e36 / totalWeight)
if delta == 0: do nothing

ethPerVe += delta
ethPerVeTimeWeighted += delta * rewardTs
store_reward_checkpoint(rewardTs, ethPerVe, ethPerVeTimeWeighted)
# if main array is at MAX_REWARD_CHECKPOINTS, routes to _overflowCheckpoints

distributed = floor(delta * totalWeight / 1e36)
pendingShareholderETH -= distributed
```

How reward settlement works:
- Decaying ve locks cannot be settled safely from current `veBalanceOf(user)` alone.
- ShareholderRoyalties records historical flush timestamps and reconstructs each user’s delayed rewards from those timestamps.
- This prevents under-accrual and stranded ETH for decaying, non-AutoMax locks.

Why MIN_VE_FLUSH exists:
- It gates manual/residual flushes when rewards could not be indexed immediately.
- It keeps rounding dust in `pendingShareholderETH` when `delta == 0`.
- It matters after bounded ve checkpointing: if `globalLastTs()` is stale, flushing defers and the ETH remains pending.
- Checkpoint-history retention also matters: if the overflow ring is saturated inside the active lock horizon, flushing defers instead of writing an unsafe checkpoint approximation.

Practical implication for UIs:
- Takeover ETH does not wait for `MIN_VE_FLUSH` when there is already a processed shareholder denominator.
- `pendingShareholderETH` is mostly a residual bucket (zero-shareholder carry, rounding dust, brief carry while the ve checkpoint catches up, or transient carry while checkpoint storage waits for a safe eviction window).

## User accounting

Per-user storage (the public mapping is `userEthPerVePaid`; the rest are `internal` and exposed only via the views below):
- `userEthPerVePaid[user]` — public mapping; index value last paid out to the user
- `_claimableEthStored[user]` — checkpointed/crystallised ETH (internal). Read via `claimableEthStored(user)` for the storage-only value or `claimableEth(user)` for the **live** entitlement (stored + uncheckpointed accrual).
- `userTimeWeightedEthPerVePaid[user]` — internal; time-weighted index for decaying-lock settlement
- `userLastRewardTs[user]` — internal; last reward timestamp consumed
- `userRewardRemainder[user]` — internal; sub-wei carry bucket

checkpointUser(user):
- reconstructs unprocessed reward epochs from `VeClaimNFT.getShareholderLockParams(user)`
- uses the current lock set plus historical reward checkpoints
- is safe because VeClaimNFT checkpoints ShareholderRoyalties **before every ve mutation** (create, add, extend, merge, toggle AutoMax, unlock, transfer for settlement)
- fails closed on bundle drift (see [Wiring safety model](protocol-overview.md#wiring-safety-model)) — this ensures MarketRouter settlement checkpoints the correct royalties contract before ownership moves

Lock treatment:
- AutoMax lock:
  - constant weight = `amount`
  - accrues across all unprocessed epochs
- Decaying lock:
  - only epochs with `rewardTs < lockEnd` count
  - accrues from historical flush timestamps, not from current `veBalanceOf(user)`
  - prefix sums over `delta` and `delta * timestamp` keep settlement bounded and gas-safe

Rounding:
- ETH distribution remains floor-rounded
- per-user sub-wei fractions are carried in `userRewardRemainder[user]` instead of being silently lost

MarketRouter integration:
- MarketRouter calls `checkpointTransfer(from, to)` before moving a veNFT into Furnace custody
  (Sell now / listing settlement) so royalties accounting stays correct.

## Strict accounting invariant

`ShareholderRoyalties` maintains a disjoint-buckets invariant on its own ETH custody:

```text
totalCrystallisedStored + indexedEthOwed == address(this).balance - pendingShareholderETH
```

Where:
- `totalCrystallisedStored` — public `uint256` getter; sum of every user's `_claimableEthStored[user]` bucket. Backed by an O(1) accumulator updated on every checkpoint, collect, and dust sweep.
- `indexedEthOwed` — public `uint256` getter; sum of every user's outstanding ve-weighted entitlement implied by `(ethPerVe - userEthPerVePaid[user])`. Backed by an O(1) accumulator updated on every flush and per-user observation transition.
- `pendingShareholderETH` — public `uint256` getter; the residual bucket described above (zero-shareholder carry, rounding dust, deferred carry).

`address(this).balance - pendingShareholderETH - totalCrystallisedStored - indexedEthOwed` is the **forced surplus** — strictly forced ETH transferred outside the canonical takeover/flush path (selfdestruct beneficiary, coinbase reward, pre-deploy CREATE2 funding). `sweepDust(address to) external onlyOwner nonReentrant` derives the sweep amount as `address(this).balance - reserved` (where `reserved = pendingShareholderETH + indexedEthOwed + totalCrystallisedStored`), reverts `InvariantViolation` if `balance < reserved`, reverts `AmountZero` when no surplus exists, and is capped at 1 ETH per call (`AmountTooLarge` above the cap). The sweep emits `DustSwept(to, dust)` and never touches `pendingShareholderETH`, `totalCrystallisedStored`, or `indexedEthOwed`. Under canonical play the disjoint sum equals the balance exactly; the Echidna properties `echidna_shareholder_disjoint_buckets_exact` and `echidna_total_crystallised_matches_sum` in `test/echidna/EchidnaShareholder.sol` enforce the strict equality across the fuzz state space.

Operator monitoring should read both accumulators through their public ABI rather than reconstructing them from per-user storage. A drift between `totalCrystallisedStored` and the on-chain accumulator under load is the canonical signal that a custodial path has bypassed the checkpoint surface.

## Observed-minimum watermark

`ShareholderRoyalties` tracks two watermarks that bound reward-checkpoint scan ranges:

- **Per-user**: `userObservedMinNonAutoMaxLockEnd(user) -> uint40` is the earliest non-AutoMax lock end observed for that user across all lifecycle events. Sentinel `type(uint40).max` indicates no non-AutoMax lock at last observation. The per-user watermark contracts toward `now` only when the observed lock set actually shifts; it is never widened back out by an internal hook.
- **Global**: `_oldestObservedNonAutoMaxLockEnd` is the floor across all users. It bounds overflow ring eviction (a flush defers when the oldest overflow entry is still inside the active lock horizon).

The lock-mutation paths in `VeClaimNFT` (create, add, extend, merge, AutoMax toggle, unlock, transfer for settlement) call back through the `checkpointShareholder*` hooks, which contract the per-user watermark in real time. `checkpointUser(user)` itself only calls the observation refresher on the user's first contact — defined as either the default storage slot (`0`, brand-new user that has never been pinned) or the post-pin ceiling sentinel (`type(uint40).max`, set when a prior pin recorded "no non-AutoMax lock"). A user that already has a concrete observed value short-circuits without the external `ve.getShareholderLockParams(user)` call or the storage write, so a zero-delta `checkpointUser` keeps the hot enter path bounded under the EIP-170-tight `_settlePrevKingClaim` headroom budget.

After a merge (`Furnace.mergeLocksWithBonus*` routed through `VeClaimNFT.mergeLocksFor`) and after a settlement transfer (the only allowed transfer surface in v1.0.0; `MarketRouter` → `Furnace` custody hop), the per-user observed-min reflects the post-mutation lock set on every endpoint address that lost or gained a lock in the operation. Integrators reading `userObservedMinNonAutoMaxLockEnd(user)` immediately after one of these events get current state without a follow-up `pinUserObservedMin(user)` call.

Two recovery surfaces exist for off-chain reconciliation:

- `pinUserObservedMin(address user) external` — permissionless. Re-reads `ve.getShareholderLockParams(user)`, rewrites `_userObservedMinNonAutoMaxLockEnd[user]`, and narrows `_oldestObservedNonAutoMaxLockEnd` if the observation reveals a tighter floor. Never raises the global watermark.
- `recomputeGlobalWatermark(address[] candidates) external onlyOwner` — paginated raise. Refreshes every per-user storage observation in `candidates` without narrowing the global floor as a side effect, then widens `_oldestObservedNonAutoMaxLockEnd` to the minimum across the supplied set. Bounded at `_MAX_WATERMARK_RECOMPUTE_CANDIDATES` per call; the operator paginates the call set off-chain. Strictly raise-only and emits `OldestObservedNonAutoMaxLockEndSet(prev, next)` only when the value actually moves.
- `recomputeGlobalWatermark(address[] candidates, bool exhaustive) external onlyOwner` — same shape as the single-argument overload, with one extra capability: when `exhaustive == true` AND every candidate carries the sentinel ceiling (or the candidate list is empty), the global floor is raised straight to `type(uint40).max`. The empty-exhaustive form is the operator escape hatch when the shareholder set is provably empty and overflow checkpoint writes need to resume without a candidate list. Empty + non-exhaustive is a no-op.

Off-chain operators consult `userObservedMinNonAutoMaxLockEnd(user)` to assemble the candidate set before invoking `recomputeGlobalWatermark`. The aggregate raise / ceiling decision is the only writer to the global floor on these paths, so a paginated sweep cannot silently narrow between pages when an in-flight per-user observation is tighter than the already-converged floor. Steady-state play does not require either surface; both exist for the bounded recovery cases where global watermark widening is otherwise blocked by a stale per-user observation.

### Burn pinning

`VeClaimNFT` pins the watermark on every lock that exits the active set: settlement transfers into Furnace custody, in-place unlocks, and `furnaceBurnAndWithdraw` all call back through `pinUserObservedMin` against the address that lost the lock (and, on settlement, against the address that gained it). The pinned address may be the user or the Furnace itself; the contract recognises Furnace as a valid pinning target for the duration the lock is custodied there. A pinning call that finds no remaining non-AutoMax lock writes the sentinel ceiling, so the global floor can widen as soon as the next aggregate `recomputeGlobalWatermark` run sees that endpoint at ceiling.

The pinning helper is non-reverting: a stale or partial wiring resolution fails closed by leaving the watermark unchanged rather than bricking the outer lock mutation. Operators relying on watermark currency after a settlement / unlock / burn read `userObservedMinNonAutoMaxLockEnd(target)` to confirm the post-mutation observation; in the rare case the helper short-circuited on a wiring transient, a permissionless `pinUserObservedMin(target)` call rewrites it.

### Upgrade seeding

`seedWatermarkOnUpgrade()` is an owner-only one-shot that initialises `_oldestObservedNonAutoMaxLockEnd` to `type(uint40).max` when the slot is at its zero default. It is the post-upgrade migration entry point for proxies that were initialised before the watermark slot existed: without seeding, the overflow ring's eviction guard reads `headTs >= 0` for any candidate eviction and rejects every flush that requires safe FIFO eviction. The function is idempotent — it short-circuits as soon as the slot holds any non-zero value — so re-running it after a normal `recomputeGlobalWatermark` cycle is a no-op.

## Operator notes

The remaining section covers deploy-time wiring. Integrators can skip unless instrumenting governance flows.

### Initialization

The initializer rejects a delegated-EOA `initialOwner`: a 7702-delegated address reverts `DelegatedEOA`, while bare EOAs and ordinary contracts pass. The same rejection runs on the `_ve`, `_mineCore`, `_mineMarket`, `_furnace`, and `_claimAllHelper` wiring inputs, and on `transferOwnership` / direct owner-callable surfaces. See [Security, Guardian, Pausing — Initial-owner 7702 guard](security-guardian-pausing.md#initial-owner-7702-guard) for the cross-contract rule and the rationale.

## See also

- [Locks (veCLAIM)](locks-veclaim.md) — lock lifecycle and ve decay
- [Furnace](furnace.md) — lock bonus engine and Collect & Lock path
- [ClaimAllHelper](claimallhelper.md) — bundled collect calls
- [Core Mechanics](core-mechanics.md) — takeover loop and Baron allocation
- Tutorial: [Collect Barons ETH or Collect & Lock](tutorials/collect-barons-eth-or-lock.md)
- User manual: [The Furnace — Royalties](https://docs.claimru.sh/furnace)
