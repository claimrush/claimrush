# MineCore implementer checklist (v1.0.0)

This is an **implementer-focused checklist** for the MineCore game loop.

Source of truth:
- Canonical behavior: `docs/spec/spec-v1.0.0.md` §5 (MineCore)
- Constants: `src/lib/Constants.sol`
- Rounding rules: [math and rounding appendix](../architecture/math-and-rounding-appendix-v1.0.0.md)

Spec aids (recommended):
- `docs/spec/state-machines-v1.0.0.md` (MineCore takeover diagrams)
- `docs/spec/test-vectors-v1.0.0.md` (§4 takeover price decay)

This document **does not introduce new rules**. It restates MUST/MUST NOT requirements in an order suitable for incremental implementation and review.

---

## Goals

MineCore MUST:
- Track the current King and reign boundaries.
- Price takeovers deterministically (referencePrice decay down to a floor).
- Mint emissions correctly (including the Furnace stream) and never “mine” during pauses.
- Split takeover ETH:
  - 75% to the previous reign's configured ETH recipient (`reignEthRecipient[prevReignId]`, falling back to `prevKing`) — hybrid: best-effort push with a bounded gas stipend, pull-based fallback on push failure.
  - 25% to the Shareholder index (via ShareholderRoyalties).
- Preserve liveness:
  - Refund failure MUST NOT revert takeover.
  - King payout failure MUST NOT revert takeover (the failure is converted into a pull-based credit keyed by the routed recipient).

---

## Checklist: state you MUST have

From `spec-v1.0.0.md` §5.1, implementation MUST maintain at least:
- `currentKing`
- `currentReignId`
- `currentReignStartTime`
- `currentReignLastAccrualTime`
- `referencePrice`
- Per-reign metadata required by views:
  - king address
  - start time
  - end time (if finalized)
  - pricePaid
  - referencePrice used for that reign
  - totalClaimMined
  - totalEthToKing
- Withdrawal buckets:
  - `kingEthBalance[ethRecipient]` — keyed by the **routed ETH recipient** (`reignEthRecipient[reignId]` or `prevKing` fallback), NOT by the king identity.
  - `refundEthBalance[user]` (hybrid refund fallback).
- Per-reign routing (set when a reign starts):
  - `reignEthRecipient[reignId]` — defaults to `address(0)` (which resolves to the king identity at payout time).
  - `reignClaimRecipient[reignId]` — same default; the CLAIM stream is paid to the king identity when unset.

---

## Checklist: takeover price

Source: `spec-v1.0.0.md` §5.3 and constants doc.

- Floor:
  - `TAKEOVER_PRICE_FLOOR = 0.001 ether`
- Decay window:
  - `TAKEOVER_DECAY_PERIOD = 1 hours`
- Rules:
  - If there has never been a takeover (`currentKing == address(0)`): required price is the floor.
  - Otherwise:
    - `t = max(0, timestamp - currentReignStartTime)`
    - If `t >= TAKEOVER_DECAY_PERIOD`: price is the floor.
    - Else: `price = max(floor, referencePrice - referencePrice * t / TAKEOVER_DECAY_PERIOD)`.
    - Decay is toward 0, clamped at floor. Low-cost takeovers reach floor before 60 min.
  - Price MUST clamp to floor (never below).

Test vectors:
- See `docs/spec/test-vectors-v1.0.0.md` §4 for price-decay worked examples.

---


## Checklist: takeover entrypoints (preconditions + reverts)

Source: `spec-v1.0.0.md` §5.4.1.

Both public takeover entrypoints produce an ETH-denominated `pricePaid` and then follow the same deterministic takeover sequence (§5.4.2).

Shared preconditions (both entrypoints):
- `require(!takeoversPaused)`.
- `require(msg.sender != currentKing)` (no self-takeovers).

`takeover(uint256 maxPrice)` (ETH entry):
- Revert `PriceExceeded` if `getCurrentTakeoverPrice() > maxPrice`.
- Treat `msg.value` as a maximum cap (`maxPriceEth`).
- Compute `price = getCurrentTakeoverPrice()` and enforce `price <= msg.value`.
- Set `pricePaid = price`.
- Refund amount:
  - `refundEth = msg.value - pricePaid` (hybrid refund).

`takeoverWithToken(address tokenIn, uint256 amountIn, uint256 minEthOut, uint256 maxPrice)` (token entry):
- Routing MUST be fixed and resolved via `EntryTokenRegistry` (no user-supplied paths/pools).
- **WETH special-case (REQUIRED):** if `tokenIn == wrappedNative` (WETH), bypass registry route resolution:
  - pull `amountIn` WETH, unwrap 1:1 to ETH, and set `ethOut = amountIn`.
- Else: swap `tokenIn -> WETH -> unwrap -> ETH`, producing `ethOut`.
- Enforce user slippage guard: `ethOut >= minEthOut`.
- Revert `PriceExceeded` if `getCurrentTakeoverPrice() > maxPrice`.
- Compute `price = getCurrentTakeoverPrice()` and enforce `ethOut >= price`.
- Set `pricePaid = price`.
- Refund amount:
  - `refundEth = ethOut - pricePaid` (hybrid refund).

`takeoverWithTokenAndDeadline(address tokenIn, uint256 amountIn, uint256 minEthOut, uint256 maxPrice, uint256 deadline)`:
- Same as `takeoverWithToken` but enforces a caller-supplied swap `deadline` instead of using `block.timestamp`.

---

## Guarded takeover entrypoints (not part of the v1.0.0 repo)

These entrypoints are optional extension guidance only. The shipped v1.0.0 `MineCore` in this repo exposes `takeover(maxPrice)`, `takeoverWithToken(tokenIn, amountIn, minEthOut, maxPrice)`, `takeoverWithTokenAndDeadline(...)`, and `takeoverFor(newKing, maxPrice)` only; it does **not** include `takeoverIf(...)` or `takeoverForIf(...)`.

These entrypoints make automation safer and cheaper under contention.

Suggested signatures:
- `takeoverIf(uint256 reignIdExpected, uint256 maxPriceWei, uint256 minReignAgeSeconds, uint256 deadline)` (payable)
- `takeoverForIf(address newKing, uint256 reignIdExpected, uint256 maxPriceWei, uint256 minReignAgeSeconds, uint256 deadline)` (payable)

Guard rules (MUST):
- `block.timestamp <= deadline`.
- `currentReignId == reignIdExpected`.
- `getCurrentTakeoverPrice() <= maxPriceWei`.
- `msg.value >= getCurrentTakeoverPrice()`.
- If `minReignAgeSeconds != 0` and there is an active king:
  - `block.timestamp - currentReignStartTime >= minReignAgeSeconds`.

Implementation note:
- Check guards before ve checkpointing so losing txs revert cheaply.

---

## Checklist: deterministic takeover sequence

Source: `spec-v1.0.0.md` §5.4.2.

Implement the internal takeover sequence so it always follows this order:

1) **Compute the required takeover price**
- Use `getCurrentTakeoverPrice()`.
- Enforce `maxPrice` guard: revert `PriceExceeded` if `price > maxPrice`.
- Enforce the max-cap rule based on the entrypoint:
  - `takeover(maxPrice)`: `require(msg.value >= price)`.
  - `takeoverWithToken(...)`: `require(ethOut >= price)` (post-swap ETH).
- Set `pricePaid = price`.

2) **Compute refund**
- Entry-dependent refund amount:
  - `takeover(maxPrice)`: `refundEth = msg.value - pricePaid`.
  - `takeoverWithToken(...)`: `refundEth = ethOut - pricePaid`.

3) **Checkpoint global ve state**
- Call:
  - `veClaimNFT.checkpointGlobalState()`
- `checkpointGlobalState()` already syncs `totalVeCached` internally, so a separate `checkpointTotalVe()` call is not required.
- This call MUST be gas-guarded per the VeClaimNFT rules (§4.3), but MineCore is responsible for calling it before reign finalization.
- `MineCore` MUST keep calling `checkpointGlobalState()` until one of the following is true:
  - `veClaimNFT.globalLastTs() == block.timestamp`
  - `gasleft()` drops below the safety guard
  - the ve contract stops making forward progress
- `MineCore` MUST NOT add a second fixed per-takeover iteration cap on top of VeClaimNFT's per-call `MAX_SLOPE_CHANGES_PER_CALL` bound.

4) **Accrue emissions since last accrual cursor**
- `accrualStart = currentReignLastAccrualTime`
- `accrualEnd = block.timestamp`
- Paused time MUST NOT be included (see “Pause” checklist below).
- Mint emissions for `[accrualStart, accrualEnd)` using the integral method (§5.4.3):
  - If `prevKing != address(0)`:
    - Default: mint the King stream to the previous King.
    - Optional extension: if MineCore King auto-lock is enabled for the dethroned King, route the King-stream principal through the Furnace entry flow (best-effort; MUST NOT revert takeover on failure).
      - Stored `minVeOut = 0` is treated as a sentinel and clamped to `1` before the Furnace call because `enterWithClaimFor` rejects zero `minVeOut`.
      - On any failure after that (including `minVeOut` not met), fall back to minting the same principal amount as liquid CLAIM to the previous King.
      - See `docs/spec/king-autolock-spec-v1.0.0.md`.
      - [ ] King auto-lock `_resolveExistingToken` returns failure (EXPIRED skip / liquid CLAIM) when a non-AutoMax destination lock has `< MIN_LOCK_DURATION` remaining.
    - Record `claimMinedToPrevKing` (used in the `ReignFinalized` event). This is the King-stream principal amount (not including any Furnace bonus).
  - Always: mint the Furnace stream to the Furnace contract address and credit it to the Furnace reserve via `Furnace.creditReserve(...)`.

5) **Finalize the previous reign (if any)**
If `prevKing != address(0)`:
- Snapshot:
  - `totalVeForReign[prevReignId] = veClaimNFT.totalVeCached()` (post checkpoint)
- `reignEndTime[prevReignId] = now`
- Resolve routing recipients:
  - `prevEthRecipient = reignEthRecipient[prevReignId]` (fallback to `prevKing` when unset).
  - `prevClaimRecipient = reignClaimRecipient[prevReignId]` (fallback to `prevKing` when unset).
- Split ETH:
  - `kingShare = pricePaid * 75 / 100`
  - `shareholderShare = pricePaid - kingShare`
- Pay the previous reign's ETH recipient (hybrid push + pull-fallback):
  - Attempt to push `kingShare` ETH to `prevEthRecipient` with a bounded gas stipend.
  - On success: emit `Events.KingEthPaid(prevEthRecipient, kingShare)`.
  - On failure: credit `kingEthBalance[prevEthRecipient] += kingShare` and emit `Events.KingEthCredited(prevEthRecipient, kingShare)`. The withdrawable bucket is keyed by the **routed ETH recipient**, NOT `prevKing`.
  - King payout failure MUST NOT revert takeover.
- Allocate shareholder ETH:
  - `ShareholderRoyalties.onTakeover{value: shareholderShare}(prevReignId)`
- Auto-flush (liveness + anti-retroactive capture):
  - `ShareholderRoyalties.flushPendingShareholderETH()`
  - Canonical takeover allocations are already indexed by `onTakeover`; this extra flush MUST remain safe for residual pending ETH and MUST NOT revert when the processed denominator is zero, when it rounds below `MIN_VE_FLUSH`, or when `globalLastTs()` is still stale after bounded checkpointing.
  - Gas: flush is O(1) (no holder enumeration). The takeover caller pays this extra gas as part of the takeover transaction.
- Emit:
  - `Events.ReignFinalized(prevReignId, prevKing, reignStartTime[prevReignId], now, claimMinedToPrevKing, kingShare)`

If `prevKing == address(0)`:
- `kingShare = 0`
- `shareholderShare = pricePaid`
- Allocate shareholder ETH:
  - `ShareholderRoyalties.onTakeover{value: shareholderShare}(0)`
- Auto-flush:
  - `ShareholderRoyalties.flushPendingShareholderETH()`
- MUST NOT emit `ReignFinalized` (first reign has no predecessor).

6) **Start the new reign**
- Let `newKing` be the king identity for this reign. `newKing == msg.sender` for direct entrypoints; `newKing` is the delegator for `takeoverFor`.
- `currentReignId += 1`
- `currentKing = newKing`
- `currentReignStartTime = now`
- `currentReignLastAccrualTime = now`
- `referencePrice = pricePaid * 2`
- Persist per-reign routing (`reignEthRecipient[newReignId]`, `reignClaimRecipient[newReignId]`) and emit `Events.ReignRecipientsSet(newReignId, newKing, ethRecipient, claimRecipient)`.
- Persist per-reign metadata required by views.
- Emit:
  - `Events.Takeover(currentReignId, prevKing, newKing, pricePaid, referencePrice, now)`

7) **Hybrid refund (required)**
- Attempt to return `refundEth` to caller in the same transaction.
- If the transfer fails:
  - `refundEthBalance[caller] += refundEth`
- Refund failure MUST NOT revert takeover.
- Expose a withdrawal function that allows withdrawing the stored refund to a chosen recipient.

---


## Checklist: events (indexer compatibility)

Source:
- `docs/analytics/dune-integration-pack-v1.0.0.md` (canonical event schema for dashboards/indexers).
- `spec-v1.0.0.md` event list (MUST mirror the analytics pack).

MUST emit the following MineCore events. Signatures below mark `indexed` args explicitly; **topic ordering is binding for raw-log decoders and subgraph handlers** — see `abis/base_mainnet/MineCore.abi.json` for canonical indexed flags.

Core product events (required for any conforming implementation):

- `Events.Takeover(uint256 indexed reignId, address indexed previousKing, address indexed newKing, uint256 pricePaid, uint256 referencePrice, uint256 timestamp)`
  - Emit once per successful takeover after you have updated reign state.
- `Events.ReignFinalized(uint256 indexed reignId, address indexed king, uint256 startTime, uint256 endTime, uint256 totalClaimMined, uint256 totalEthToKing)`
  - Emit only on non-genesis takeovers (when a previous King exists).
- `Events.ReignRecipientsSet(uint256 indexed reignId, address indexed king, address ethRecipient, address claimRecipient)`
  - Emit when a new reign is started with non-default routing, so indexers can track `kingEthBalance[ethRecipient]` correctly.
- `Events.KingEthPaid(address indexed recipient, uint256 amount)`
  - Emit on successful best-effort push of the dethroned reign's ETH share to the routed recipient.
- `Events.KingEthCredited(address indexed recipient, uint256 amount)`
  - Emit when the push failed and the amount was credited to `kingEthBalance[recipient]` instead.
- `Events.TakeoversPausedChanged(bool paused)`
  - Emit on every pause toggle (after clamping accrual time if a King exists).
- `Events.KingWithdrawal(address indexed king, uint256 amount)`
  - Emit on successful `withdrawKingBalance()`.
- `Events.KingWithdrawalTo(address indexed king, address indexed to, uint256 amount)`
  - Emit on successful `withdrawKingBalanceTo(to)`.
- `Events.EntryTokenRegistrySet(address indexed registry)`
  - Emit when `setEntryTokenRegistry(registry)` updates the active registry.

Additional events emitted by the canonical MineCore (required for full analytics parity; see `spec-v1.0.0.md` §10 event appendix for the authoritative list):

- `Events.FurnaceChanged(...)`, `Events.RefundCredited(...)`, `Events.RefundWithdrawn(...)`, `Events.DelegationSessionUsed(...)`, `Events.KingAutoLockSkipped(...)`, `Events.ShareholderRoyaltiesTakeoverFailed(...)`, `Events.ShareholderRoyaltiesFlushFailed(...)`.

Clarification (non-binding):
- Shareholder ETH events are emitted by `ShareholderRoyalties` (do not duplicate them in MineCore).
- If any doc disagrees on an event signature, the Dune integration pack wins (`docs/v1.0.0-index.md` Rule 2).

---

## Checklist: emission math

Source: `spec-v1.0.0.md` §5.2 and §5.4.3.

Implementation MUST:
- Use the integral method described in spec (§5.4.3).
- Use the emission constants from `src/lib/Constants.sol`.
- Maintain exactness around the decay transition:
  - Use trapezoidal integral inside the decay window.
  - Use tail-floor rate beyond the decay window.
- Avoid double-minting:
  - Advance `currentReignLastAccrualTime` exactly once per takeover.
  - Clamp it on takeover pause transitions (below).

---

## Checklist: pause behavior

Source: `spec-v1.0.0.md` §5.6.1.

- `setTakeoversPaused(bool paused)` (guardian-only)
  - Emit: `Events.TakeoversPausedChanged(paused)`.
  - While paused: all takeover entrypoints MUST revert.
  - On every transition (`false -> true` and `true -> false`):
    - If `currentKing != address(0)`, set `currentReignLastAccrualTime = block.timestamp`.
    - Purpose: paused time is never mined later.
  - MUST NOT mutate:
    - `currentKing`
    - `currentReignId`
    - `currentReignStartTime`
    - `referencePrice`

Clarification:
- The spec clamps emissions during pauses. It does not redefine takeover price decay during pauses.
- Do not add extra “freeze time” behavior unless the canonical spec changes.

---

## Checklist: withdrawals

Source: `spec-v1.0.0.md` §5.5 and §5.4.2.

### `withdrawKingBalance()`
- Read `amount = kingEthBalance[msg.sender]` (keyed by the **routed ETH recipient**, not necessarily the king identity).
- If `amount == 0`, return.
- Set `kingEthBalance[msg.sender] = 0` (checks-effects-interactions).
- Send ETH using `call`.
- Revert on failure with `Errors.EthTransferFailed()`.
- MUST be `nonReentrant`.
- Emit: `Events.KingWithdrawal(msg.sender, amount)`.


### `withdrawKingBalanceTo(address to)`
- Same as `withdrawKingBalance()` but sends ETH to a caller-specified `to` address.
- MUST revert if `to == address(0)`.
- Emits `Events.KingWithdrawalTo(msg.sender, to, amount)`.

### `withdrawKingBalanceFor(address user)` (ClaimAllHelper-only)
- Restricted to the canonical `ClaimAllHelper` via `onlyClaimAllHelper`.
- Withdraws `kingEthBalance[user]` and sends the ETH **directly to `user`** (not to the ClaimAllHelper). The helper is only the authorised caller that enables bundled claim flows; it never takes custody of the king ETH balance.
- CEI: zero `kingEthBalance[user]` and decrement `totalKingEthOwed` BEFORE the external call. On send failure revert (or retry to `user` with a bounded liveness fallback, per canonical implementation).

### `withdrawRefundBalance(address to)`
- Read `amount = refundEthBalance[msg.sender]`.
- If `amount == 0`, return.
- MUST revert if `to == address(0)` to prevent accidental burns.
- Set `refundEthBalance[msg.sender] = 0` (checks-effects-interactions).
- Send ETH to `to` using `call`.
- Revert on failure with `Errors.EthTransferFailed()` (or equivalent).
- MUST be `nonReentrant`.


---

## Checklist: views

Source: `spec-v1.0.0.md` §5.7.

`getReignInfo(reignId)` MUST return all metadata needed by:
- analytics
- UI
- indexers

Minimum fields (per `spec-v1.0.0.md` §5.7):
- king address
- startTime
- endTime (0 if not finalized, or optional)
- pricePaid
- referencePrice
- totalClaimMined
- totalEthToKing

`getKingReigns(king, cursor, limit)` MUST be:
- paginated (`cursor` + `limit`), and MUST NOT revert on large histories
- stable ordering (append-only history, oldest -> newest, unless spec changes)
- deterministic for indexers (no filtering based on caller)
- consistent with internal cursor guardrails

---

## Common failure modes (implementation review)

- Emissions minted during paused windows.
- Pushing ETH to the previous King during takeover instead of crediting the withdrawal bucket.
- Reverting takeover if refund transfer fails.
- Not checkpointing ve state before finalizing a reign.
- Updating `currentReignStartTime` or `referencePrice` during pause toggles (forbidden by spec).

## Checklist: config freeze (`configFrozen` / `freezeConfig()`)

- `bool public configFrozen` — one-way flag, default `false`.
- `modifier whenNotFrozen()` — reverts `Errors.ConfigFrozen()` if `configFrozen == true`.
- Frozen setters (MUST have `whenNotFrozen`):
  - `setFurnace(address)` — `onlyOwner whenNotFrozen nonReentrant`
  - `setClaimAllHelper(address)` — `onlyOwner whenNotFrozen`
  - `setDelegationHub(address)` — `onlyOwner whenNotFrozen`
- `freezeConfig()` — `onlyOwner whenNotFrozen`:
  - MUST revert if `address(furnace) == address(0)`
  - MUST revert if `address(furnace).code.length == 0`
  - Sets `configFrozen = true`
  - Emits `Events.ConfigFrozen()`
- NOT frozen (remain `onlyOwner` after freeze):
  - `setEntryTokenRegistry`
  - `setGuardian` (always callable by owner or current guardian, subject to genesis lock; every nonzero assignment runs `_rejectDelegatedEOA(guardian)` so EIP-7702 delegated EOAs revert `DelegatedEOA` on the post-genesis branch as well)
  - `setTakeoversPaused`, `setLockingPaused` (guardian-gated)
