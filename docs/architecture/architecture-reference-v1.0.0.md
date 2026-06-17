# Architecture Reference – ClaimRush v1.0.0

This document defines the ClaimRush v1.0.0 architecture reference.

It bridges:
- Player-facing documentation
- Implementation-facing spec
- Guardrails and test plans


---

## 0. Design goals & constraints

### 0.1 Primary goals

- **Pure player economy**
  - No premine, no team or investor allocation.
  - No protocol fees or treasury balance.
- **Tight surface, deep meta**
  - Only one token (CLAIM).
  - One bonus engine (Furnace).
  - One official marketplace for ve positions (MarketRouter).
- **Durable game**
  - Emissions that matter for ~2 years, then a small but permanent tail.
  - No hard “end of game” date.
- **Credible alignment**
  - Kings and Barons both have clear, non-oppressive roles.
  - Kings are not economically privileged over Barons in bonus mechanics.
- **Reviewer-friendly**
  - Tight contract set, few moving parts.
  - Explicit invariants and bounded gas patterns.

### 0.2 Hard constraints

- CLAIM total supply starts at 0.
- No premine, no dev or treasury mints.
- No protocol fee on:
  - Takeover ETH
  - Emissions
  - Marketplace trades
- No ve(3,3), no gauge wars, no bribe markets.
- Locker bonuses MUST NOT depend on LP stake.
  - The protocol may route a defined share of the Furnace **gross** bonus to LP stakers via an on-protocol vault (see §1.2.1).
- No secret minting or gov-controlled “drip” contracts.
- All long-term value flows are described in a small set of contracts.


---

## 1. Architecture

### 1.1 Direct roots + proxy-backed runtime + one routing registry

Final v1.0.0 contract set (high level):

Direct roots + proxy-backed runtime:

1. `ClaimToken` – ERC20 CLAIM.
2. `VeClaimNFT` – ve locks as ERC721 positions.
3. `MineCore` – reigns, takeovers, emissions. (transparent proxy)
4. `ShareholderRoyalties` – ETH index for Barons. (transparent proxy)
5. `Furnace` – unified entry and shared bonus engine. (transparent proxy)
6. `LpStakingVault7D` – LP staking vault (7d unbonding) funded by Furnace LP incentives (gross-bonus split + optional overflow drip).

Routers/adapters (limited surface):

7. `MarketRouter` – ve marketplace router (0% protocol fee, prices in CLAIM). Listing sales surface a duration-based retained cut that Furnace books as `reserveAdd` plus optional `lpReward` funding into the LP stream. (transparent proxy)
8. `DexAdapter` – DEX router adapter used by `EntryTokenRegistry`.
9. No `GameRouter` contract is part of v1.0.0. The public UI does not depend on one.

External routing contract (governed config; mutable allowlist surface):

10. `EntryTokenRegistry` – curated allowlist of entry tokens and validated pool routing for swaps (no user-supplied routes).


### 1.2 Claim-first, not LP-first

ClaimRush v1.0.0 does not use the ve(3,3)-style pattern where players are pushed into gauge politics.

Instead:

- All core economics are in CLAIM and veCLAIM.
- The protocol relies on a standard DEX pool (Aerodrome CLAIM/WETH) for price discovery and swaps.
- The protocol does not direct emissions via gauges and does not introduce bribes.
- LP staking is supported via a dedicated vault (optional for players) that is funded from Furnace LP incentives (gross-bonus split + overflow drip; see §1.2.1 and §1.2.4), not from protocol fees.

Reason:
- Gauge/bribe systems introduce reflexive loops and “black box” emissions.
- ClaimRush keeps value flows transparent and observable:
  - Furnace remains the single bonus curve.
  - LP incentives are transparent: a bounded share of Furnace gross bonus is routed to LP stakers.

### 1.2.1 Why LP incentives are funded from Furnace bonus (not a protocol fee)

- v1.0.0 includes an on-protocol LP staking vault (`LpStakingVault7D`).
- Funding comes from a **split of the Furnace gross bonus**, not from principal and not from a trade fee.

Why this is not a fee:
- Users still pay **zero** protocol fees.
- The Furnace gross bonus is a reward paid out of a reserve; v1 redirects a bounded share of that reward to LP stakers.
- There is no treasury balance or admin-controlled bucket.

Why this improves UX and safety:
- Avoids introducing a new fee or hidden tax surface.
- Keeps “bonus %” legible: the UI displays the net user bonus (after split).
- Keeps the number of moving parts small (no gauges, no bribes, no epoch voting).

### 1.2.2 Why 7d unbonding + max 25 unbonds

Goal: discourage rapid LP in/out sniping while keeping withdrawals predictable.

- `UNBONDING_PERIOD = 7 days` provides a fixed time-lock similar to Cosmos-style bonded staking.
- `MAX_UNBONDS_PER_USER = 25` bounds per-user bookkeeping and prevents unbond spam.
- While unbonding, the unbonded amount does not earn rewards (discourages churn).

### 1.2.3 Why donate 100% of LP fees to LP stakers

- Vault-harvested Aerodrome pool fees are swapped to CLAIM and donated into the on-protocol LP Staking Vault rewards.
- No LP-fee-derived CLAIM is burned.
- Harvest is owner-or-keeper-allowlisted, with a small capped WETH bounty paid in WETH only, and **staleness-based** (bounty is usually `0` in normal ops under the official keeper bot).

Rationale:
- Burn is price-support; fee-to-rewards is liquidity-support. v1.0.0 uses liquidity-support to accelerate market depth.
- Rewards are composable: LP stakers see a single harvestable CLAIM balance funded by the Furnace bonus split + overflow drip + fee donations (Furnace-funded portions are streamed over `LP_STREAM_WINDOW` to smooth reward-rate spikes).
- Avoids gauges/bribes while still providing a transparent incentive to deepen liquidity.




### 1.2.4 LP overflow drip (reserve → LP rewards stream, starts at 18m)

Problem (volatile pools):
- Per-lock LP rewards are funded primarily by the Furnace gross-bonus split.
- As emissions decay and early lock flows normalize, the rate of new Furnace entries can drop, causing LP rewards to drop sharply.
- For volatile pools this can create a post-year-1 liquidity cliff (less depth → worse swaps/quotes → worse UX).

v1.0.0 adds a conservative **LP overflow drip** that funds CLAIM from the Furnace reserve into the Furnace **LP rewards stream** per day (then streamed to `LpStakingVault7D` over `LP_STREAM_WINDOW`, 14 days).
- The drip is intentionally bounded and only spends from **excess reserve** above the healthy target (`RESERVE_TARGET_FINAL`).
- This does **not** change the headline user bonus math (the AMM and user cap remain unchanged); it only adds a bounded reserve outflow to support liquidity.

Why the design is conservative:
- The drip is 0 when reserve is not above target (no under-target spending).
- The drip is capped as a share of the **current Furnace inflow/day**:
  - It automatically declines as emissions decline into year 2.
- A fixed hard cap is retained as a backstop (even if inflow cap binds later).
- Excess gating uses a smooth curve so small excess does not trigger an aggressive drip.

Why start at 18 months with a 180-day ramp:
- Avoids a sudden jump in LP rewards.
- Provides a bridge **before** the 2-year emissions floor, without propping rewards indefinitely.
- Still declines into year 2 as the inflow-based cap drops with emissions.

Source of truth:
- Constants + formulas: `src/lib/Constants.sol` §3.4.6
- Rounding rules: `docs/architecture/math-and-rounding-appendix-v1.0.0.md` §M.2

### 1.3 Single bonus system: shared Furnace reserve

Final v1.0.0 design:

- MineCore mints the 5 CLAIM/sec Furnace stream directly to a **single Furnace reserve**.
- All players (including Kings) use the same Furnace system:
  - ETH → CLAIM → lock (duration selectable: 7 days → 1 year; default 1 year)
  - Allowlisted ERC20 token → CLAIM → lock (duration selectable: 7 days → 1 year; default 1 year)
  - CLAIM → lock (duration selectable: 7 days → 1 year; default 1 year)
  - ETH rewards → CLAIM → lock (duration selectable: 7 days → 1 year; default 1 year)
    - This path is used when Barons collect in `LOCK_FURNACE` mode.

**Reason**:
- Makes bonuses intuitively “shared” and fair.
- Reduces accounting complexity: one reserve, one curve.


---

### 1.4 Launch liquidity bootstrap (protocol-enforced genesis)

Problem:
- Protocol supply starts at 0 (no premine).
- The Furnace entry path requires a live WETH/CLAIM market for ETH → CLAIM swaps.
- The protocol has no treasury and does not seed or manage liquidity.

Contract-enforced, verifiable onchain:
- A public **WETH/CLAIM vAMM** pool is created on **Aerodrome v2 (Base)**.
- A one-shot `LaunchController` enforces the genesis sequence:
  - Accrue emissions for 10 days (`T0 → T0 + 10d`) while takeovers are paused.
  - After 10 days, the configured guardian calls `finalizeGenesis()` once to:
    - seed genesis liquidity using **50 ETH** + the materialized 10-day King-stream `CLAIM` bucket only (not arbitrary donated controller `CLAIM`)
    - lock LP for **24 months** in `GenesisLPVault24M`
    - leave veCLAIM creation to the normal post-launch user / Furnace lock flows
- Fees earned by the locked LP are donated to LP stakers via LP vault rewards, via owner-or-keeper-allowlisted harvest with a capped, **staleness-based** WETH bounty (usually `0` under the official keeper).

Why this fits the “claim-first” design:
- The protocol remains rulebook-only with no treasury or fees.
- Genesis is operationally guardian-triggered, and LP lock is enforced onchain.
- The entire bootstrap is onchain-verifiable.

Reference docs:
- `docs/spec/vault-spec.md`

## 2. Emissions design

### 2.1 Rates and decay

At launch:

- King emission: 50 CLAIM/sec.
- Furnace reserve emission: 5 CLAIM/sec.
- Total: 55 CLAIM/sec.

Over 2 years (63,072,000 seconds):

- Both streams decay linearly.
- King floor: 50/9 CLAIM/sec (≈ 5.555).
- Furnace floor: ≈ 0.555 CLAIM/sec (5/9).
- After 2 years, total tail = ≈ 6.111 CLAIM/sec (55/9) forever.

**Why this shape**:

- **High-intensity launch**:
  - Enough CLAIM to matter and attract attention.
  - Kings have strong short-term incentives.
- **Soft landing**:
  - No cliff; incentives taper smoothly.
- **Perpetual tail**:
  - Keeps game economically “alive” indefinitely.
  - Allows late entrants to still build positions and earn rewards,
    without degenerate hyperinflation.


### 2.2 No premine & no “hidden” buckets

The protocol forbids:

- Initial mints to any address other than zero.
- Pre-loaded emission reserves sitting in a treasury.
- Backdoor admin mint functions.

All CLAIM comes from:

- King emission stream (50 → 50/9 per second).
- Furnace reserve stream (5 → 5/9 ≈ 0.555 per second).


---

## 3. Takeover mechanics and ETH splits

### 3.1 Takeover price curve

The takeover curve is **legible and predictable**:

- Reference price doubles after each capture.
- Price decays toward 0 over 1 hour, clamped at floor of 0.001 ETH: `price = max(floor, referencePrice * (1 - t / decayPeriod))`.
- Low-cost takeovers reach floor before 60 min (e.g., 0.002 ETH ref → floor at 30 min).
- Overpay is not a mechanic. `msg.value` is a max cap; MineCore charges the current takeover price and returns/credits any excess. Reference price doubles from `pricePaid`.

Operational properties:

- Doubling + floor gives a clear “ladder of courage” for Kings.
- This prevents accidental overpayment while keeping the curve legible.
- 1-hour decay gives a natural rhythm:
  - Fast, competitive takeovers when hype is high.
  - Slow, cheap re-entries when attention fades.
- Floor ensures the game never stalls because price is too high.

More complex curves (e.g. exponentials, sigmoids, multi-stage schedules) are not used;
they are harder to mentally simulate and more prone to implementation error.


#### 3.1.1 Takeover cost tier UI (Cost: High / Mid / Low)

Goal: make the takeover price decay intuitive in the UI without framing any tier as “good” or “bad”.

Component: takeover timing bar

- Render a horizontal bar under the takeover button.
- The bar represents progress through the current on-chain price-decay span since the last takeover.
- Show an explicit tier chip for takeover cost:
  - **Cost: High** (warm token family): early in the span, typically more competition.
    - Subtitle example: “Takeover cost is high right now. More competition.”
  - **Cost: Mid** (muted token family): typical takeover window.
    - Subtitle example: “Takeover cost is mid-range. Typical takeover window.”
  - **Cost: Low** (cool token family): later in the span, typically calmer entry conditions.
    - Subtitle example: “Takeover cost is low relative to this hour. Calmer entry conditions.”

Tier boundaries (v1.0.0):
- `elapsed < 25m` ⇒ Cost: High
- `25m <= elapsed < 35m` ⇒ Cost: Mid
- `elapsed >= 35m` ⇒ Cost: Low
- (If you prefer normalized `t` with a 1h decay: `t < 0.4167`, `0.4167..0.5833`, `>= 0.5833`.)

Design intent:

- All tiers are valid play styles.
- Cost: High tends to correlate with competitive ladder escalation.
- Cost: Mid tends to correlate with moderate attention and mixed pacing.
- Cost: Low tends to correlate with calmer entry conditions.
- Long stretches in Cost: Low signal lower attention, not a broken system.

Accessibility:
- Never rely on color alone. Always show a tier chip label (`Cost: High/Mid/Low`) near the marker value.


### 3.2 ETH split 75 / 25

Final split:

- 75% of takeover ETH → previous King.
- 25% → veCLAIM holders via ShareholderRoyalties.

Reasoning:

- 75% to King keeps taking the Crown profitable.
- 25% to Barons gives a strong “ETH rewards” pillar:
  - This is the primary reason to lock CLAIM long-term.
75/25 is a balanced point: Kings still care about ETH profit, and Barons
get a meaningful share of every takeover. A lower Baron share weakens ve positions;
a higher Baron share risks reducing takeover frequency.


### 3.3 Avoiding infinite reign exploits

- Takeovers can be paused for emergencies.
- While paused, the current King **MUST NOT** accumulate extra emissions for “free time”.
- Reign finalization MUST consider only *unpaused* time when computing mined CLAIM.

- Mechanism (v1.0.0):
  - On every takeover pause toggle (pause and unpause), if a King exists:
    - `currentReignLastAccrualTime = block.timestamp`
  - Effect: paused time is never mined later (prevents “infinite reign” mining).
  - UX note: if a pause happens mid-reign, King mining stops during the pause and resumes only after unpause.

Reason:

- Without this, an admin could pause during high-value periods and effectively
  mint King emissions for an extended period without risk.
- Protects the “honesty” of the emission schedule.


---


### 3.4 King history and leaderboards

The King-of-the-hill loop functions as an evolving story, not isolated transactions.

Application UI and analytics should expose:

- Recent reigns list
  - For each recent reign:
    - King address (or ENS / short label)
    - Reign start and end time
    - Reign duration
    - Takeover price paid (`pricePaid`)
  - Source:
    - `MineCore.Takeover`
    - `MineCore.ReignFinalized`
  - No address exclusions are applied in v1.0.0.
  - Genesis initialization is not a reign and emits no takeover/reign events, so it is not counted here.

- Official leaderboards (off-chain only)
  - v1.0.0 defines a fixed set of leaderboards for UI and Dune:
    - `docs/analytics/leaderboards-ui-and-dune-compatible-v1.0.0.md`
  - Do not add extra leaderboards in v1.0.0.

Design intent:

- Show history and outcomes.
- Avoid APY, ROI, net "earned", or any profit projections in the official UI.

These views are built entirely from events and view functions. No extra on-chain state is required beyond what is already specified.



---

## 4. veCLAIM model and NFT design

### 4.1 Lock duration: 7 days → 1 year

Lock duration is user-selectable in v1.0.0, within a fixed horizon:

- Min duration: 7 days.
- Max duration: 365 days.
- ve formula:
  - `ve = amount * remaining / 365 days`.
- ve decays linearly to 0 at expiry.

UI default:
- New locks default to 365 days unless the user selects otherwise.

Reasons:

- The lock horizon in v1.0.0 is 1 year.
- Linear decay is straightforward to reason about and implement.
- 1 year is a meaningful commitment horizon without requiring multi-year lock-in.

### 4.2 NFT representation

Each lock is an NFT:

- Portable (tradable on MarketRouter).
- Composable with NFT infrastructure (indexers, marketplaces, etc.).
- Represents a position object with fields: amount, end, flags.

NFT-based positions (vs. pure account-based ve):

- Make secondary markets natural.
- Support multiple separate locks per user with different strategies.
- Allow large holders to sell down exposure cleanly.


### 4.3 Explicit lock destination + AutoMax option

v1.0.0 has no hidden per-user routing pointers (no “Active Lock” / fallback routing).

Instead, **every** protocol entry that locks CLAIM via the Furnace is explicit about *where* value lands:

- `targetTokenId`
  - `0` = create a new lock
  - `>0` = add to an existing lock (and optionally extend its end)
- `durationSeconds` (7 days → 365 days)
  - Existing locks can only be **extended** (never shortened).
- `createAutoMax`
  - Only meaningful when creating a new **365-day** lock.
  - Default is **OFF**.

Properties:

- Removes an entire class of “why did this route to that lock?” surprises.
- Works cleanly for users with multiple locks (selection is explicit in UI flows).
- Supports new features like duration-weighted Furnace bonus without adding more pointer state.

AutoMax (creation-time option):

- AutoMax is an opt-in behavior for **new 365-day locks only** (checkbox default OFF).
- If a user selects an existing lock, the UI does **not** offer an AutoMax checkbox.

### 4.3.1 Mint rules for max-duration locks

v1.0.0 does **not** gate 365-day locks behind a special mint path.

The single mint entrypoint in `VeClaimNFT` is:

- `createLockFor` (Furnace-only, mints to an explicit `user`)

Mint validation (MUST):

- MUST require `amount >= MIN_LOCK_AMOUNT` (1,000 CLAIM) on mint (prevents dust ve locks).
- MUST allow: `MIN_LOCK_DURATION <= durationSeconds <= MAX_LOCK_DURATION`
- MUST reject: `durationSeconds < MIN_LOCK_DURATION` or `durationSeconds > MAX_LOCK_DURATION`
- AutoMax validation:
  - MUST reject: `autoMax == true` unless `durationSeconds == MAX_LOCK_DURATION`
  - At `durationSeconds == MAX_LOCK_DURATION`, `autoMax` is an explicit opt-in (both `true` and `false` are allowed)

`createLockFor` exists only so Furnace can mint/route locks for a recipient without relying on ERC721 approvals.

### 4.4 Marketplace-only transfers

Direct ve transfers between EOAs are forbidden:

- Only MarketRouter can move NFTs between users (besides mint/burn).

Reason:

- All secondary trading runs through a path that:
  - Calls `checkpointTransfer` in ShareholderRoyalties.
  - Enforces 0% fee and CLAIM pricing.
- This ensures ETH rewards are *never* retroactively given to new lock owners,
  and sellers keep what they earned so far.


---

## 5. Shared bonus design (Furnace)

### 5.1 Why a shared reserve

The protocol uses a single **Furnace reserve** that receives all bonus emissions (5 CLAIM/sec → 5/9 (≈ 0.555) tail) and exposes a single bonus curve shared by all participants.

Benefits:

- One transparent bonus source for all entry paths.
- No per-reign or per-path budgets that create rush-or-wait incentives.
- Straightforward to reason about sustainability.


### 5.2 Locked-supply anchor + user-first bonus cap

The Furnace spot cap anchor is **lock-% (locked / total supply)**.

#### 5.2.1 Anchor choice and sign

Anchor (lock-%):

- `totalSupply` = CLAIM total supply (`ClaimToken.totalSupply()`).
- `lockedSupply` = total CLAIM locked in ve (principal + locked bonuses), typically `VeClaimNFT.totalLockedClaim()`.
- `lockedPctBps = clamp(floor(10_000 * lockedSupply / totalSupply), 0, 10_000)`.
- Base user cap:

```text
baseUserBps = floor(MAX_USER_BONUS_BPS * LOCK_PCT_TARGET_BPS / (LOCK_PCT_TARGET_BPS + lockedPctBps))
```

- Sign is intentional:
  - **More locked ⇒ lower base user cap**.
  - This matches the desired dynamic: high participation makes the system more conservative.

#### 5.2.2 User bonus is the headline number

- UI headline shows `userBonusBps` (net user bonus), capped at 100%.
- Spot cap surfaced to users is `userSpotBps` (0..10_000).
- LP incentives are displayed separately (kept low in the header):
  - “LP stakers (24h): X CLAIM” (rolling 24h total; includes per-entry split + overflow drip).
  - Additive, not a subtractive “cut”. Never blend this into the user bonus percent.

#### 5.2.3 Gross cap can exceed 100%

- LP top-up rate is a % of the user bonus (base curve 7.5% → 15%, scaled down when reserve is stressed).
- Hard clamp remains **125%**, but with the current LP top-up max (15%) the system reaches **115% gross** when the user cap is 100%.

Why allow gross > 100%:

- It speeds reserve spending at low lock ratios without changing the headline user bonus.
- Users never see a confusing “150%” number; the user cap remains 100%.

---

### 5.3 Reserve control ramp + AMM dynamics

#### 5.3.1 Centered reserve control with time ramp

Reserve control is centered on a target and can damp or boost:

- `rawMultBps = clamp(floor(10_000 * R / RESERVE_TARGET_FINAL), 0, RESERVE_FACTOR_MAX_BPS)`.
- The effect ramps in over time:

```text
alpha = clamp(elapsed / SWING_TIME, 0, 1)
effMultBps = 10_000 + alpha * (rawMultBps - 10_000)
```

- A lock-% dependent max-boost cap is then applied before the runtime factor is used:

```text
reserveFactorBps = min(effMultBps, maxReserveFactorBps(lockedPctBps))
userSpotBps = min(MAX_USER_BONUS_BPS, floor(baseUserBps * reserveFactorBps / 10_000))
lpScaleBps = min(10_000, reserveFactorBps)
```

“Swing point” (60 days):

- `SWING_TIME = 60 days` ensures reserve control does not crush early bonuses.
- At launch (`alpha = 0`), reserves are ignored (`effMultBps = 10_000`).
- By day 60 (`alpha = 1`), reserves fully damp/boost the cap.

#### 5.3.2 Edge-case coverage

- ~5% lock:
  - User bonus can max out at 100% and reserve may still grow.
  - Acceptable: if lock stays that low long-term, the game failed.
- 40–50% lock:
  - User bonus expected to be modest (~15–20% region depending on reserves and ramp).
  - Reserve control keeps the reserve healthy.
- 50% lock is an explicit design bound.

#### 5.3.3 BONUS_DECAY_WINDOW = 3 hours

- `BONUS_DECAY_WINDOW = 3 hours`.
- Rationale:
  - Less timing meta than 2 hours.
  - Less frustration than 6 hours.
- This affects **recovery dynamics** after large entries, not the cap math.

### 5.4 Slippage protection with minVeOut

v1.0.0 does not use on-chain oracles / TWAPs:

- Instead, all ETH→CLAIM+lock flows MUST accept a `minVeOut` argument.

Reason:

- Oracle integration adds heavy complexity and protocol risk.
- Many DEXs already expose useful off-chain price feeds.
- For a game, per-transaction `minVeOut` is sufficient protection if UIs set good defaults.
  - Practical note: if a positive `veOut` quote floor-rounds to `0`, callers must clamp `minVeOut` to `1` because Furnace rejects zero `minVeOut`.

This keeps the contract set smaller and more reviewable.


---


### 5.5 Implementation notes for UI

UI MUST reflect these semantics clearly:

- Headline bonus is **user** (net):
  - Show `userBonusBps` / `userSpotBps` as the main “bonus %”.
  - Cap at 100%.
- Show LP rewards to stakers as a separate low-priority line:
  - `lpRewardsClaim24h` (indexer-derived rolling 24h total; includes per-entry split + overflow drip).
- Advanced view (optional):
  - `quoteLpTopupBps` (additive LP top-up quote) and the overflow drip rate (CLAIM/day).
- Gross values are optional (advanced view):
  - `grossSpotBps`, `quoteGrossBps`.
  - Never label these as “user bonus”.
- Transparency fields (recommended):
  - `reserve` (R), reserve multiplier, and bootstrap progress `alpha`.

---

## 6. MarketRouter design

### 6.1 0% protocol fee, CLAIM-only prices

MarketRouter:

- Charges no protocol fee (no treasury skim).
- Uses CLAIM as the single quote asset.
- Listing sales have a duration-based retained cut. See §6.2 for settlement details.

Reasons:

- Keeps the mental model clear for players.
- Avoids hidden revenue streams that could be perceived as protocol rake.
- The listing penalty prevents arbitrage between limit sell and instant sellback (Furnace sellback).
- The retained cut goes back into the system through Furnace accounting, not to a treasury.
- Creates a tight loop between CLAIM liquidity and ve positions.


### 6.2 Listing constraints

In v1.0.0 strict mode, the Furnace is the ONLY counterparty for lock settlements. There are no user-to-user lock trades.

**Listing model:**

- Listing = limit sell to Furnace with a price floor (`minClaimOut`)
- When the Furnace can meet the price floor, the listing settles:
  - Duration-based penalty is deducted (50% at 365d, ~1% at 7d)
  - Furnace books the retained cut into `reserveAdd` plus optional `lpReward` funding into the LP stream
  - Seller receives `claimOut`; the duration-based penalty is the gap `lockAmount - claimOut` booked by Furnace during sellback execution
  - Lock is burned

Enforcement:

- Listing requires owner + approval.
- Listed locks cannot be mutated (no extend, merge, unlock, auto flag changes).
- 1-block cooldown between list and delist actions per token.
- Optional emergency delist after a long enough listing period.

Reasons:

- Prevents race conditions where a listing owner mutates the lock mid-settlement.
- 1-block cooldown is an anti-spam / anti-flash-listing measure.
- Emergency delist is safety against trapped locks in edge cases.


### 6.2.1 Bonus Target Escrow spam controls (v1.0.0 defaults)

Purpose:

- Reduce escrow spam from dust budgets.

Parameters (MarketRouter owner-managed config; v1 defaults):

- `minBonusTargetEscrowBudget = 10_000e18` (10,000 CLAIM)

Per-escrow (creator-selected):
- Escrow expiry (TTL):
  - Creator supplies `escrowTtlSeconds` at creation (0 = use default).
  - Default: `DEFAULT_BONUS_TARGET_ESCROW_TTL_SECONDS = 30 days`.
  - Max (per create/extend): `MAX_BONUS_TARGET_ESCROW_TTL_SECONDS = 90 days`.
  - Creator can extend expiry later (creator-only) up to `now + MAX_BONUS_TARGET_ESCROW_TTL_SECONDS`.

Enforcement semantics:

- These checks MUST be enforced **only** when calling `createBonusTargetEscrowWithTarget(...)`.
- If governance raises minimums later, the new values affect **only new escrows**.
- Existing escrows are NOT invalidated and remain executable.

Governance:

- Configurable via `onlyOwner` setters (production policy expects the ADMIN timelock controlled by a multisig).
- Policy: **increase-only** for minimums (no decreases).
- MarketRouter is proxy-backed; parameters are governed by timelocked owner setters (no `freezeConfig()`), while code upgrades go through the owned proxy admin.

### 6.2.2 Bonus Target Escrow (entry order into Furnace)

A Bonus Target Escrow is a conditional entry order that executes into the Furnace once the Furnace can meet the user's target bonus.

When creating a Bonus Target Escrow, the creator specifies:

- `targetBonusBps` + `slippageBps`.
- Lock duration + destination settings:
  - `durationSeconds` + `createAutoMax`.
  - `escrowTtlSeconds` (escrow expiry TTL; 0 = default).
  - optional `destinationLockId` (or create new lock).

Execution model:

- During the keeper grace window, `executeAutoFurnace(offerId, deadline)` is restricted to allowlisted settlement keepers plus the `MarketRouter` owner as break-glass executor.
- `executeAutoFurnace(offerId, deadline)` is **permissionless** onchain after the keeper grace window (anyone can call it).
- In practice, a **team-operated keeper bot** monitors eligible escrows and executes when the target bonus is available.
  - Recommended: call via `MaintenanceHub.poke(...)`.

Why keep it permissionless but use a keeper:

- Onchain contracts cannot "schedule" a transaction; a keeper provides reliability and good UX.
- Permissionless execution preserves censorship resistance and allows third parties to execute if the keeper is down.

Safety rule:

- If the stored destination lock is no longer eligible at execution time (no longer owned by creator, listed, expired, AutoMax mismatch), the system MUST fall back to creating a new lock.
- Creating a new lock has a mint minimum: `MIN_LOCK_AMOUNT = 1,000 CLAIM`. With small remaining budgets, execution can revert; the creator can cancel or wait for expiry unwind.

### 6.3 ETH index fairness via checkpointTransfer

The system relies on `checkpointTransfer` to maintain fairness during lock settlements:

- Before a lock is settled to Furnace, the listing owner is fully checkpointed in ShareholderRoyalties.
- Listing owner keeps ETH accrued up to that point.

This is the core guarantee that makes ve positions settleable *without* breaking the ETH index.


---

## 7. ShareholderRoyalties design

### 7.1 ETH index model

ShareholderRoyalties uses a standard “index per unit of ve” model:

- `ethPerVe` tracks total ETH per unit of ve (scaled by ACC = 1e18).
- Each user stores `userEthPerVePaid` and `claimableEth`.

Rationale:

- The index model is well established in DeFi accounting.
- It scales naturally with many reigns and users.
- Combined with `checkpointTransfer`, it provides precise fairness.


### 7.2 MIN_VE_FLUSH, liveness, and anti-sniping

v1.0.0 introduces `MIN_VE_FLUSH` to balance:

- Liveness: Barons rewards should become visible quickly (UI trust).
- Anti-sniping optics: avoid “one Baron gets all” when ve supply is tiny.

v1.0.0 sets `MIN_VE_FLUSH = 100 veCLAIM`.

Rules:

- `flushPendingShareholderETH()` is permissionless. It returns immediately when `pendingShareholderETH == 0`, but for non-zero pending ETH it MUST fail closed unless the live `Furnace / MarketRouter / MineCore / VeClaimNFT / ClaimToken` bundle still resolves to this exact `ShareholderRoyalties` root.
- Canonical takeover allocations are auto-attempted immediately and index against the current processed shareholder denominator even below `MIN_VE_FLUSH`, but only once `checkpointTotalVe()` has advanced `ve.globalLastTs()` to the current block.
- Manual / residual flushes return (no-op) when the processed denominator rounds below `MIN_VE_FLUSH`.
- MineCore MUST auto-attempt a flush immediately after each takeover allocation (keeps `ethPerVe` current and drains any residual carry or dust).
- Gas: flush is O(1) (no holder enumeration). When called inside the takeover sequence, the takeover caller pays the extra gas.

Trade-offs:

- Too high: residual pending ETH sits longer when the system has zero shareholders or only dust.
- Too low: residual carry flushes earlier, but canonical takeover allocations are already auto-attempted immediately and become indexable as soon as the ve checkpoint catches up, so threshold optics no longer change eventual eligibility.

Edge case:

- If total ve is zero at allocation time, ETH remains pending until a processed shareholder denominator exists and a later flush can index it.


### 7.3 Keeper-allowlisted auto-compound for Baron rewards (shipped in v1.0.0; opt-in per user)

Many Barons prefer a passive compounding UX:
- accrue takeover ETH
- periodically compound that ETH into more veCLAIM via Furnace

Design constraints (MUST):
- No economics change:
  - same ETH distribution via the `ethPerVe` index
  - same Furnace pricing/bonus rules
- No new protocol fees or executor fees.
- No new custody surface (funds remain in ShareholderRoyalties until claimed/locked).

**Keeper-allowlisted execution** (with owner break-glass)

- Baron auto-compounding performs an ETH → CLAIM swap via `Furnace.lockEthReward(...)`.
- In v1.0.0, `compoundFor` / `compoundForMany` are keeper-allowlisted (plus owner):
  - only configured keeper(s) and owner may execute compounding for an opted-in user
  - the official keeper is the expected primary executor

Tradeoff (accepted):
- Execution now has a keeper liveness dependency.
- This is acceptable because:
  - execution risk from arbitrary third-party timing is reduced
  - owner has break-glass execution ability
  - users can disable auto-compound at any time

Operational model (recommended):
- Users opt in by setting an onchain auto-compound config:
  - destination lock tokenId + duration
  - cadence + minimum ETH threshold
- The official keeper bot runs:
  - Preferred execution: `ShareholderRoyalties.compoundForMany(users, maxUsers)` (gas-bounded batches).
  - Fallback: `ShareholderRoyalties.compoundFor(user)` (single-user).
  - Note: `minVeOut` is computed on-chain per user from their stored `maxSlippageBps` and a Furnace quote, with rounding-to-zero cases clamped to `1` when `veOut > 0`.

Failure policy (required):
- Destination lock eligibility is validated at execution time.
- If the destination is no longer eligible (sold, listed, expired), the config is paused and the executor skips the user.
- The system MUST NOT create a new lock as a fallback in v1.0.0 (avoid unwanted new positions).


---

## 8. Security & gas posture

### 8.1 Bounded checkpointing

The bias/slope model (veCRV-style) requires:

- `MAX_SLOPE_CHANGES_PER_CALL = 250`.
- The loop in `checkpointGlobalState()` stops when:
  - It has processed at most this many scheduled changes, or
  - It runs out of gas margin.

This is critical to avoid a global state “gas bomb” where too many expiries
make an operation permanently unusable.


### 8.2 Reentrancy and external calls

Assumptions:

- `MineCore.takeover` includes ETH sends and calls `ShareholderRoyalties.onTakeover`.
- `ShareholderRoyalties.claimShareholder` may call Furnace in lock mode.
- Furnace entry functions interact with a DEX and VeClaimNFT.

**ReentrancyGuard** is required on all external entrypoints that:

- Send ETH.
- Interact with DEXs.
- Call into other protocol contracts in a way that could reenter.


### 8.3 No rescue in v1.0.0 and upgrades (direct roots + proxy-backed runtime)

v1.0.0 is intentionally strict:

- **No generic rescue / sweep functions** are shipped in the protocol (direct roots, proxy-backed runtime, or routers/adapters).
  - No `sweepToken`, `sweepETH`, `recoverERC20`, or similar — except the bounded exceptions: DexAdapter `rescueETH()`/`rescueToken()` (owner-only), MineCore `rescueEth()` (owner-only), ShareholderRoyalties `sweepDust()` (owner-only), and GenesisLPVault24M `rescueEth()` (`lpWithdrawRecipient`-only). See `docs/spec/spec-v1.0.0.md` §10.4.
  - For contracts without rescue functions, stray tokens or ETH are unrecoverable.

Recommended upgradeability approach (v1.0.0):

- **Direct permanent roots:** keep `ClaimToken` and `VeClaimNFT` direct.
- **Proxy-backed runtime quartet:** deploy `MineCore`, `Furnace`, `MarketRouter`, and `ShareholderRoyalties` behind transparent proxies whose proxy addresses are the canonical runtime endpoints.
- **Freeze remains a wiring lock:** all five freeze-gated contracts retain a one-way `freezeConfig()`, but `ClaimToken` is frozen and owner-renounced at wire time while the freeze-and-burn ceremony freezes `Furnace`, `MineCore`, `VeClaimNFT`, and `ShareholderRoyalties`.
- **Proxy-admin governance is live only until finality:** `freezeConfig()` does not disable transparent-proxy upgrades. Until finality, the runtime quartet is upgradeable through owned `ProxyAdmin` contracts governed by the timelock + multisig; the freeze-and-burn ceremony then renounces ownership on the four runtime `ProxyAdmin`s, making the quartet permanently non-upgradeable.
- **DexAdapter remains direct:** `DexAdapter` is still deployed non-upgradeable; changes ship via redeploy + timelocked registry router-config rewiring through `EntryTokenRegistry.setRouterConfig(...)`.
  - Once the WETH/CLAIM hop or any token config exists, router/factory changes require a fresh registry deployment instead of an in-place rewire.

- No `GameRouter` contract is part of v1.0.0. The UI does not depend on one.

Why this is the balance:

- **Stable user-facing addresses:** live runtime state survives upgrades because the quartet keeps stable proxy addresses.
- **Clear trust boundary:** the immutable asset roots stay direct, while upgrade authority is explicit and concentrated in owned proxy admins.
- **Reviewability:** the upgrade surface is explicit and bounded to the runtime quartet plus the routing registry/DexAdapter surface.

Escrow trust-risk (MarketRouter):

- If `MarketRouter` holds escrowed user funds (e.g., global-offer CLAIM budgets), it is a **high-trust** surface. The proxy-backed deployment model makes it patchable, but only through governed proxy-admin upgrades.
- Mitigations (required):
  - Design `MarketRouter` to be as **non-custodial** as possible (minimize escrow, prefer pull-based settlement, or isolate escrow in an immutable helper where feasible).
  - Explicit "no generic sweep/rescue" rule applies to routers/adapters too: upgrades MUST NOT add admin drains. Bounded exceptions: DexAdapter `rescueETH()`/`rescueToken()`, MineCore `rescueEth()`, ShareholderRoyalties `sweepDust()`, GenesisLPVault24M `rescueEth()` and `withdrawLp()` Aerodrome trading-fee forwarding (source bounded to `pool.claimFees()`, destination fixed to immutable `lpWithdrawRecipient`; see `docs/spec/vault-spec.md` *withdrawLp()*) (see `docs/spec/spec-v1.0.0.md` §10.4).

Upgrade governance guideline (recommended):

- Treat router/adapter upgrades as protocol-level events: announce, diff, timelock delay, and post-upgrade monitoring.

---

## 9. Protocol boundaries in v1.0.0

The following are not part of v1.0.0:

- There is no governance token or DAO beyond CLAIM itself.
- Emission schedules are not dynamically reconfigured by governance.
- Price safety does not depend on oracle-heavy or TWAP-heavy contract designs.
- There is no multi-chain extension.
- There are no additional bonus systems such as per-reign boosts or ve-weighted airdrops.


---

## 9.1 Hosted plugin surface (Base MCP)

Outside the on-chain contract set, v1.0.0 also ships a hosted **Base MCP plugin** so AI assistants on Base can drive the protocol on behalf of a user. The plugin is a Cloudflare Worker at `claimru.sh/api/mcp/v1/*` that returns unsigned calldata; the user's wallet remains the sole signer.

The plugin is treated as an **integrator surface**, not as a protocol component:
- The worker never signs, never holds keys, never broadcasts.
- All math (duration weight, `minVeOut` UX clamp, `bonusBpsVsPrincipalClaim` floor) mirrors the on-chain helpers byte-for-byte; a CI parity gate against the frontend source rejects any drift.
- The worker fails closed during the pre-launch genesis window — every prepare endpoint returns `503 GENESIS_NOT_FINALIZED` until `LaunchController.finalizeGenesis()` commits.

The architectural details (response envelope, fail-closed posture, drift protection) live in the dedicated appendix:

- [Base MCP plugin appendix (v1.0.0)](base-mcp-plugin-appendix-v1.0.0.md)

Developer reference: [`docs/manuals/developer/base-mcp-plugin.md`](../manuals/developer/base-mcp-plugin.md). Public plugin spec: [`plugins/claimrush.md`](../../plugins/claimrush.md).

---

## 10. How to use this document

- Use this document with the spec set to understand the v1.0.0 contract model, economic surfaces, and operational constraints.
- Use it as the architecture companion to the canonical spec and manual set.
