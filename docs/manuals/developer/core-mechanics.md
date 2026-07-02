# Core Mechanics

Core Mechanics covers the Crown system (`MineCore`): takeover pricing, ETH routing, delegated takeovers, and CLAIM emissions. This is the entry point of the [CLAIM stream](protocol-overview.md) — where ETH flows in and CLAIM flows out. Use this page when integrating takeovers or reign settlement.

> **TL;DR:** Players call `MineCore.takeover(maxPrice)` with ETH. Price starts at 2x the last paid and decays linearly toward 0 over 1 hour, clamped at the floor. ETH splits 75/25 (King payout / Baron royalties). While King, the player mines CLAIM via a linear-decay emission stream (50→5.56 CLAIM/s over 2 years). Bots use `takeoverFor(newKing, maxPrice)` with DelegationHub sessions.

## Takeover pricing

Constants:
- TAKEOVER_PRICE_FLOOR = 0.001 ETH
- TAKEOVER_DECAY_PERIOD = 1 hour

State:
- referencePrice (updated on every takeover)
- currentReignStartTime
- currentKing

Price function (for an arbitrary timestamp nowTs):

- If currentKing == 0x0 (no Crown yet):
  - price = TAKEOVER_PRICE_FLOOR
- Else:
  - t = min(nowTs - currentReignStartTime, TAKEOVER_DECAY_PERIOD)
  - price = max(TAKEOVER_PRICE_FLOOR, referencePrice - floor(referencePrice * t / TAKEOVER_DECAY_PERIOD))

Reference price update (IMPORTANT):
- When a takeover succeeds, MineCore sets:
  - referencePrice = pricePaid * 2

Meaning:
- The next takeover starts at double the last paid price.
- The price decays toward 0 over 1 hour, clamped at floor.
- Low-cost takeovers reach floor before 60 min (e.g., 0.002 ETH ref → floor at 30 min).


## ETH routing on takeover

Let pricePaid be the takeover price at execution.

MineCore stores per-reign routing recipients:
- `reignEthRecipient[reignId]`: receives the 75% dethroned-King ETH share for that reign
- `reignClaimRecipient[reignId]`: receives the King-stream mined CLAIM for that reign

Recipients are set at reign start and emitted via `ReignRecipientsSet(...)`.
The active King identity can update recipients mid-reign via `setCurrentReignRecipients(...)`.

Delegates can also call it, but only if their DelegationHub session covers the recipient(s) being changed:
- ETH recipient: `P_SET_REIGN_ETH_RECIPIENT` or `P_SET_REIGN_ETH_RECIPIENT_TO_CALLER_ONLY`
- CLAIM recipient: `P_SET_REIGN_CLAIM_RECIPIENT` or `P_SET_REIGN_CLAIM_RECIPIENT_TO_USER_ONLY`

Successful delegated recipient updates emit both `ReignRecipientsSet(...)` and `DelegationSessionUsed(...)` so high-risk routing changes remain observable in the same session-usage stream as other delegated surfaces.

Authorization runs before the no-op short-circuit. A non-King caller passing the current pair (`ethRecipient == reignEthRecipient[reignId] && claimRecipient == reignClaimRecipient[reignId]`) reverts `NotAuthorized` unless at least one delegated permission bit was admitted on the call. The `(ethRecipient == current && claimRecipient == current) → return` short-circuit only fires for the King identity directly; an unauthorized delegate cannot use the current-pair shape to dodge the auth branch.

Non-genesis takeovers (prevKing != 0x0):
- 75% of pricePaid is paid to the dethroned reign's `reignEthRecipient[prevReignId]` (fallback: prevKing)
- 25% of pricePaid is allocated to veCLAIM holders via ShareholderRoyalties

Genesis takeover (prevKing == 0x0):
- 100% of pricePaid goes to ShareholderRoyalties
- ShareholderRoyalties.onTakeover uses reignId = 0

King-stream CLAIM settlement (prevKing != 0x0):
- mined CLAIM for the dethroned reign is split into a **liquid slice** and a **force-locked remainder**, both directed to `reignClaimRecipient[prevReignId]` (fallback: prevKing)
- the liquid slice equals the King's share of the last `KING_LIQUID_WINDOW` (100) takeovers — `liquidBps = min(windowCount * 10_000 / 100, KING_LIQUID_SHARE_MAX_BPS)` — clamped to 50%. The share is keyed to the **King identity** (`prevKing`, the player who earned it), while the payout goes to the claim recipient. The liquid slice is a direct mint and emits `KingClaimLiquidPaid`
- the remainder is force-locked into veCLAIM via `Furnace.enterWithClaimFor`: by default a single create-once perpetual (autoMax) lock that future reigns top up, or an existing lock the recipient selected via `setKingAutoLockConfig` (`targetTokenId`)
- never-brick: if the lock route is unavailable (Furnace paused/foreign wiring, gas below `SETTLE_CLAIM_MIN_GAS`, or `enterWithClaimFor` reverts) the locked slice is credited to `pendingKingClaim` and force-locked on withdrawal — it is never paid out liquid

Worked: 1 of 100 → 1% liquid / 99% locked; 20 of 100 → 20% / 80%; ≥50 of 100 → 50% (capped) / 50%.

The takeover price resets to 2x the last paid on every takeover, so a King cannot cheaply re-take their own crown; players must ping-pong the Crown. With no self-succession a single address can hold at most 50 of the last 100 takeovers, so the liquid share tops out at 50% structurally; the on-chain clamp guards the same bound in degenerate low-activity windows.

Payout mechanics:
- The dethroned King payout is best-effort in-tx (fixed gas stipend).
- If that transfer fails, MineCore credits `kingEthBalance[ethRecipient]`.
- The recipient can later withdraw via:
  - `withdrawKingBalance()` (to self), or
  - `withdrawKingBalanceTo(to)` (to an arbitrary destination)
  - delegated (bot) wrapper: `ClaimAllHelper.withdrawKingBalanceForUser(user)` (requires `P_WITHDRAW_KING_BUCKET_FOR`)
- If the chosen destination (`to`) rejects ETH and differs from the bucket owner, MineCore automatically retries delivery to the bucket owner before reverting.

Refund mechanics:
- If msg.value (or token swap proceeds) exceeds pricePaid:
  - MineCore attempts to refund immediately
  - if refund fails, credits refundEthBalance[user]
  - user can pull it via withdrawRefundBalance(to)


### Royalties allocation hardening

During takeover, MineCore pushes the Barons' ETH share to ShareholderRoyalties **best-effort** through two calls:

- `ShareholderRoyalties.onTakeover{value: amountEth}(reignId)`
- `ShareholderRoyalties.flushPendingShareholderETH()`

Takeover **does not revert** if royalties are unavailable on that call. The two failure paths and the flush no-op case have distinct recovery semantics.

#### onTakeover revert path

- Takeover still succeeds.
- MineCore credits `shareholderEthPending += amountEth`.
- Emits `ShareholderRoyaltiesTakeoverFailed(reignId, amountEth, reason)`.
- This also covers canonical Baron-bundle drift on the `ShareholderRoyalties` side, so takeover ETH is retained in MineCore instead of being indexed into a stale royalties surface.
- **Recovery:** once MineCore's bounded ve checkpoint can reach the current block timestamp, anyone can call `MineCore.retryPushShareholderEth()` to push `shareholderEthPending` into ShareholderRoyalties and attempt a flush.

#### flushPendingShareholderETH revert path

- Takeover still succeeds.
- ETH stays in `ShareholderRoyalties.pendingShareholderETH`.
- Emits `ShareholderRoyaltiesFlushFailed(reason)`.
- Direct retries also revert on canonical Baron-bundle drift instead of indexing a stale royalties surface.
- **Recovery:** anyone can call `ShareholderRoyalties.flushPendingShareholderETH()` (also called by `MaintenanceHub.poke(args)`), but `Errors.WiringMismatch()` means the live Baron bundle must be fixed first.

#### Flush no-op caveat

Even without a revert, `flushPendingShareholderETH()` may return without indexing when `VeClaimNFT.globalLastTs() != block.timestamp` after bounded checkpointing. ETH stays pending until a later flush can use a current reward timestamp.

#### Indexer notes

- `reason` is emitted as bounded revert data (up to 128 bytes) via `_boundedRevertData()`. Indexers can decode standard revert reasons from this field.
- `ShareholderRoyaltiesTakeoverFailed(...)` is also emitted on `retryPushShareholderEth()` failure (`reignId = 0`, `amountEth` = retried pending bucket).
- `retryPushShareholderEth()` reruns the bounded ve checkpoint and reverts if `globalLastTs()` is still stale — not a guaranteed immediate recovery path.
- `shareholderEthPending` is a public counter; indexers should surface it and alert on non-zero values.

## Ve checkpoint advancement

`advanceVeCheckpoint()` is a permissionless external function that advances the ve global checkpoint without requiring a takeover. If the ve system accumulates too many pending slope changes during a long pause, takeovers can become bricked because `_checkpointVeForTakeover` exhausts single-block gas. This function allows anyone to advance the checkpoint incrementally across multiple transactions until it reaches `block.timestamp`.

Keepers and bots should call this if `ve.globalLastTs()` falls significantly behind `block.timestamp` (e.g., after a sustained pause) to unblock the takeover path.

## Token takeover

`takeoverWithToken(tokenIn, amountIn, minEthOut, maxPrice)` and `takeoverWithTokenAndDeadline(tokenIn, amountIn, minEthOut, maxPrice, deadline)`:

- Swap `tokenIn` to ETH via `EntryTokenRegistry.resolveTakeoverRoute` and the DexAdapter
- WETH special-case: if `tokenIn == wrappedNative`, unwraps 1:1 without a DEX swap
- `minEthOut` enforces slippage on the swap
- `takeoverWithToken` uses `block.timestamp + SWAP_DEADLINE_SECONDS` (300s = 5 min) as the swap deadline; `takeoverWithTokenAndDeadline` enforces the caller-supplied deadline. Note that this still does not provide strong MEV protection because the base time is block-derived — for MEV-sensitive transactions, prefer `takeoverWithTokenAndDeadline`.
- After swap, executes a normal takeover with the resulting ETH

Quote via `MineCoreQuoter.quoteTakeoverWithToken(tokenIn, amountIn)` for slippage calculation.

## Delegated takeover (bots)

MineCore supports delegated Crown automation via DelegationHub sessions. It resolves the canonical hub through the live bundle and fails closed on drift before checking session bits (see [Wiring safety model](protocol-overview.md#wiring-safety-model)).

`takeoverFor(newKing, maxPrice)`:
- `msg.sender` pays ETH (the bot)
- `newKing` becomes the King identity
- `maxPrice` guards against paying more than expected (reverts `PriceExceeded` if current price exceeds it)
- requires `DelegationHub.isAuthorized(newKing, msg.sender, P_TAKEOVER_FOR)` against that canonically resolved hub

Default routing when a delegated takeover starts a new reign:
- `reignEthRecipient[newReignId] = msg.sender` (bot receives the 75% payout when dethroned)
- `reignClaimRecipient[newReignId] = newKing` (user receives mined CLAIM)

Optional:
- if the session also includes `P_ROUTE_REIGN_CLAIM_TO_CALLER`, MineCore sets:
  - `reignClaimRecipient[newReignId] = msg.sender`

Mid-reign, the King identity can update recipients:
- `setCurrentReignRecipients(ethRecipient, claimRecipient)`

An authorized delegate can also call it, but only for the recipient(s) covered by their session. The same canonical-hub resolution applies before MineCore checks any of these permission bits:
- ETH: `P_SET_REIGN_ETH_RECIPIENT` or `P_SET_REIGN_ETH_RECIPIENT_TO_CALLER_ONLY` (caller-only constrains `ethRecipient = msg.sender`)
- CLAIM: `P_SET_REIGN_CLAIM_RECIPIENT` or `P_SET_REIGN_CLAIM_RECIPIENT_TO_USER_ONLY` (user-only constrains `claimRecipient = King`)

Successful delegated updates also emit `DelegationSessionUsed(...)` with a dedicated MineCore action type, in addition to the canonical `ReignRecipientsSet(...)` routing event.

Why this exists:
- enables a bot loop where the bot pays the takeover and automatically receives the 75% dethroned payout to fund the next takeover
- keeps the King identity as the user's address (indexers and UX remain clean)

## Emissions (two streams)

CLAIM emissions are deterministic, linear-decay schedules starting at MineCore.emissionStartTime.

There are two streams:
- Crown stream: minted to the dethroned King when a takeover finalizes a reign
- Furnace stream: minted to the Furnace reserve when a takeover happens

Constants:
- EMISSION_DECAY_PERIOD D = 63,072,000 seconds (2 years)

Crown stream:
- launch rate R0_king = 50 CLAIM/s
- floor rate  RF_king = 50/9 CLAIM/s (5.555555555555555555 CLAIM/s)

Furnace stream:
- launch rate R0_furnace = 5 CLAIM/s
- floor rate  RF_furnace = 5/9 CLAIM/s (0.555555555555555555 CLAIM/s)

Rate schedule (both streams share the same shape):

```text
rate(t) =
  RF, if t >= D
  R0 - floor( (R0 - RF) * t / D ), if 0 <= t < D

where t = timestamp - emissionStartTime
```

Note: the division is Solidity integer floor-division (`Math.mulDiv(diff, t, D)`). Offchain integrators computing exact emission integrals must replicate floor-rounding to match onchain materialized amounts. The result is clamped at RF.

Concrete rates (for monitoring surfaces):
- At launch:
  - Crown: 50/sec = 180,000 CLAIM/hour
  - Furnace: 5/sec = 18,000 CLAIM/hour
- At floor (2 years and beyond):
  - Crown: (50/9)/sec = 20,000 CLAIM/hour
  - Furnace: (5/9)/sec = 2,000 CLAIM/hour

Integral (amount minted between ts0 and ts1):
- MineCore uses an exact trapezoid integral across the linear segment and a flat integral in the floor segment.
- Implementation reference: internal helpers in `src/MineCore.sol` (`_kingEmitted`, `_furnaceEmitted`).
  - These are internal (not callable via ABI) but define the exact integral.

Materialization rule (important for integrators):
- CLAIM is minted when actions occur.
- In v1.0.0, the primary materialization point is takeover finalization.
  - When someone takes over:
    - the dethroned King receives their accrued CLAIM for the reign
    - the Furnace receives its accrued CLAIM and credits it to its reserve

Pause clamp (no mining while paused):
- When guardian toggles takeoversPaused (either direction), MineCore clamps currentReignLastAccrualTime to block.timestamp.
- This prevents paused time from being mined later.

## Genesis accrual window

- GENESIS_ACCRUAL_DURATION = 10 days on Base mainnet; 1 day on testnets/local (chain-gated, set at initialization)
- During the genesis accrual window after emissionStartTime, the Crown stream accrues into a one-shot bucket.
- After the window elapses, the owner-installed LaunchController (as `MineCore.guardian` during genesis) collects it once (as the first step in `finalizeGenesis()`):
  - MineCore.collectGenesisKingClaim(to=LaunchController)
  - this call must originate from the canonical LaunchController contract itself; MineCore rejects EOAs and unrelated contract guardians even if they are the current guardian
- LaunchController uses this bucket to:
  - seed the initial WETH/CLAIM liquidity with the `CLAIM` minted by `collectGenesisKingClaim` in that same transaction (not arbitrary donated controller `CLAIM`)
  - unpause takeovers
- Genesis finalization does **not** create a veCLAIM lock.

## See also

- [Furnace](furnace.md) — lock bonus engine and counterparty
- [Locks (veCLAIM)](locks-veclaim.md) — lock lifecycle and ve mechanics
- [ShareholderRoyalties (Barons)](shareholderroyalties-barons.md) — ETH royalty distribution
- [Protocol Overview](protocol-overview.md) — high-level architecture
- Tutorial: [Build a Crown price widget + takeover call](tutorials/build-crown-price-and-takeover.md)
- Tutorial: [Run a Crown bot (takeover at 30 minutes)](tutorials/run-crown-bot-at-30min.md)
- Tutorial: [Index takeovers and reigns](tutorials/index-takeovers-and-reigns.md)
- User manual: [Core Concepts](https://docs.claimru.sh/core-concepts)
