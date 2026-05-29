# Developer Glossary

> v1.0.0 — terms used across the developer manual, the spec, and the source.

Terms specific to onchain mechanics, indexer expectations, and operator runbooks. Player-facing lore terms (Crown, Furnace, Baron, King) live in the user-manual [glossary](https://docs.claimru.sh/glossary).

## A

**Auto-furnace fallback** — Subgraph-side resolution rule that links a `BonusTargetEscrowExecuted` row back to its underlying `FurnaceEnter` log when `furnaceTokenId == 0` on the execution event. The handler walks the receipt for the sibling `FurnaceEnter` with the largest `logIndex < execution.logIndex`. See [Events and Indexing](events-and-indexing.md).

**AutoMax** — Lock flag that keeps the lock pinned at the maximum remaining duration. AutoMax locks accrue an extension bonus permissionlessly via `Furnace.claimAutoMaxBonus(tokenId)`. The protocol enforces a 24-hour onchain cooldown per lock; the official keeper triggers weekly per owner.

## B

**Baron** — User-facing name for a veCLAIM holder. The royalty surface is `ShareholderRoyalties`. Royalty-share accounting uses ve weight at the moment of takeover allocation.

**Baron bundle** — The canonical pointer set on `ShareholderRoyalties` (`furnace`, `mineCore`, `mineMarket`, `claim`, `ve`). Royalty flush reverts `WiringMismatch` if any pointer disagrees with the live runtime.

**Bonus payout floor** — The minimum bonus CLAIM the Furnace will accept on extend / merge / auto-max-bonus surfaces. Caller supplies `minBonusOut`; `0` skips the guard.

**BonusTargetEscrow** — Market escrow that pre-commits a buyer's CLAIM until the Furnace gross spot bonus reaches a configured `bonusBpsVsPrincipalClaim`. Settled by the settlement keeper or by the user inside the keeper grace window.

**Bundle drift** — Generic term for the canonical bundle no longer agreeing with itself. Any state-changing surface that detects drift reverts `WiringMismatch` ("fails closed on bundle drift").

## C

**Canonical bundle** — The set of cross-contract pointers (`MineCore`, `Furnace`, `MarketRouter`, `VeClaimNFT`, `ClaimToken`, `ShareholderRoyalties`) that must agree at every state-changing call. Each contract's wiring setters validate the candidate at admin time; runtime call paths re-verify before mutating state.

**Canonical wiring** — Synonym for the canonical bundle, used when discussing admin-time validation rather than runtime checks.

**Cadence** — Per-user time window between two valid keeper triggers of the same auto-compound path. Violation reverts `CadenceNotMet`.

**CLAIM stream** — The end-to-end value flow: ETH in via takeovers → 75 / 25 split → King CLAIM minted on dethrone → Furnace bonus on Collect & Lock → veCLAIM earns royalties from future takeovers. See [Protocol Overview](protocol-overview.md).

**Collect** — UI verb for ETH payouts. Maps to `ShareholderRoyalties.claimShareholder(mode=0)` and `MineCore.withdrawKingBalance[To]`. Never used as a verb for CLAIM payouts in copy.

**Collect & Lock** — UI verb for the Baron compound path. Maps to `claimShareholder(mode=1)`, which routes ETH through `Furnace.lockEthReward(...)` and tops up the user's auto-compound destination lock.

**CRAL** — Companion YAML pack shipped alongside the developer manual that lets external agents introspect the protocol without reading prose. See [Agents and Automation](agents-and-automation.md).

## D

**Delegated EOA** — An externally owned account that has installed an EIP-7702 designator. The 23-byte runtime starts with `0xEF 0x01 0x00`. Protocol wiring setters and `Ownable2Step` ownership transfers reject these addresses with `Errors.DelegatedEOA` (`DelegatedEOAOwner(address)` on the proxy-backed runtime).

**Designator test** — The detection routine for an EIP-7702 delegated EOA: `code.length == 23 && extcodecopy[0..3] == 0xEF0100`.

**Delegatecall event emission** — Code-size relief technique used by the Furnace, where `FurnaceGuardHelper` runs critical helpers via `delegatecall` and the events are emitted from the Furnace's own storage. The helper's ABI is the deploy-time immutable.

**Drift sweep** — Internal term for the v1.0.0 work that closed structural drift on `ShareholderRoyalties` (ETH disjoint-buckets) and `LpStakingVault7D` (CLAIM debt-accounting) via O(1) accumulators. Indexers should not rely on the term; it is operator-side history.

## E

**Eternal Lock** — The one-action onboarding path that pays ≈ 1,000 CLAIM equivalent in ETH and creates a 365-day AutoMax lock with shareholder royalties pre-configured for auto-compound. See [Furnace](furnace.md).

**Extension bonus** — CLAIM paid by the Furnace on the duration delta when a non-AutoMax lock extends. Deposited directly into the surviving lock in the same transaction.

## F

**Furnace bundle** — Subset of the canonical bundle from the Furnace's perspective: `mineCore`, `mineMarket`, `shareholderRoyalties`, `lpRewardsVault`, `claim`, `ve`.

**Furnace reserve** — The CLAIM accumulator inside the Furnace that backs lock-with-bonus payouts. Funded by the Furnace emission stream credited from `MineCore` on every takeover.

**Forge** — User-facing verb for "create a lock" in lore copy. Not a contract function name.

## G

**Genesis accrual window** — The bounded interval after `emissionStartTime` (10 days on mainnet, 1 day on testnets) during which the Crown stream accrues into the one-shot genesis King CLAIM bucket. After the window elapses, the LaunchController collects it via `collectGenesisKingClaim(to=LaunchController)` as the first step of `finalizeGenesis()`.

**Gross spot bonus bps** — `FurnaceQuoter._grossSpotBonusBps`, capped at `MAX_GROSS_BONUS_BPS = 12_500`. The Market `bonusBpsVsPrincipalClaim` gate compares against this same quantity through `Math.mulDiv` floor.

**Guardian** — Fast-incident-response role on pause-bearing contracts. May pause / unpause and emergency-disable EntryTokenRegistry tokens (one-way: disable only). Cannot upgrade or rewire. The Furnace guardian is unconditionally pinned to `MineCore` post-wiring; the human-controlled pause key for locking is the Crown guardian.

## H

**Harvest** — UI verb for LP rewards (paid in CLAIM). Maps to `LpStakingVault7D` harvest surfaces. Never used for ETH payouts.

## I

**Indexed ETH / CLAIM debt** — Public accumulators backing the strict royalty and LP-staking accounting invariants. `ShareholderRoyalties.indexedEthOwed` and `LpStakingVault7D.indexedClaimOwed`, paired with `totalCrystallisedStored` and `totalRewardsCredited`.

**Invariants v1.0.0** — Canonical document listing the structural invariants every surface upholds. Lives at [docs/security/invariants-v1.0.0.md](https://github.com/claimrush/claimrush/blob/main/docs/security/invariants-v1.0.0.md) in the private monorepo. Echidna and Halmos suites pin them.

## K

**Keeper grace window** — Per-listing time slice where only the configured settlement keeper may call `settleListing`. Public settlement during the window reverts `SettlementKeeperGracePeriod`. The grace exists to give the keeper an MEV-protected execution window.

## L

**lockEthReward** — Furnace entrypoint reachable only from `ShareholderRoyalties`. Routes Baron ETH into the user's auto-compound destination lock and pays the bonus from the Furnace reserve.

**LP overflow drip** — Furnace mechanism that re-funds the LP stream when accrued top-up CLAIM exceeds the per-cycle cap. See [Furnace](furnace.md).

**LP stream** — Furnace-side smoothing schedule that funds `LpStakingVault7D` via `notifyRewards(...)` over time. Refilled on every bonus paid, sellback, and overflow drip. Status surfaced via `LpStreamFunded(amountFunded, newRatePerSec, newPeriodFinish)`.

**Lp top-up rate** — Step 2 of the bonus model: the bps-of-bonus that is set aside to fund the LP stream rather than paid to the locker.

## M

**MaintenanceHub** — Permissionless upkeep bundler. `poke(args)` advances `Furnace.tick()`, royalty flush, ve checkpoint, and listing settlement in one call. Returns granular status so the keeper can report per-action outcomes.

**MIN_VE_FLUSH** — Lower bound (`100e18`) on manual or residual shareholder flushes. Takeover-time allocations bypass the threshold; manual flushes below it no-op.

**minBonusOut** — Caller-supplied slippage floor on Furnace extend / merge / auto-max-bonus paths. Pass `0` to skip the guard.

**minClaimOut** — Caller-supplied slippage floor on Furnace `enterWithEth` / `enterWithToken` lock-CLAIM materialization.

**minVeOut** — Caller-supplied slippage floor on the resulting veCLAIM. The protocol guards the `minVeOut == 0 && veOut > 0` UX case by clamping to 1 on the `MarketRouter`, `ShareholderRoyalties`, and `LpStakingVault7D` compound paths.

## N

**notifyRewards** — `LpStakingVault7D` entrypoint that registers a fresh schedule. Allowlist gated; the Furnace is the only canonical caller. Failed calls emit `LpRewardsNotifyFailed(vault, amountClaim, revertData)`; in v1.0.0 the `revertData` field is emitted as empty bytes.

## O

**Observed-minimum watermark** — `ShareholderRoyalties` accumulator that pins the minimum across post-mutation snapshots. Backs the disjoint-buckets invariant.

**Operator notes** — Convention used on contract pages to group operator-only material (wiring setters, emergency rewire, EOA-rejection rules) under a single trailing section.

## P

**Pendingbucket** — Any of the queued ETH or CLAIM amounts that have entered the protocol but not yet been indexed against the live denominator. Surfaced via `shareholderEthPending`, `pendingShareholderETH`, `kingEthBalance`, `refundEthBalance`.

**Preflight** — `LaunchController.preflight()` returns a packed bitmask of every `finalizeGenesis()` precondition plus the would-be seed ETH. Use it instead of re-deriving the checks off-chain.

**Push payment / pull payment** — Best-effort send wrapped in try/catch; on failure the amount is credited to a per-recipient bucket withdrawn later by the recipient. `MineCore` uses pull-payment for the dethroned-King ETH; `ShareholderRoyalties` uses an indexed pull.

## R

**Reciprocal-binding check** — Admin-time guard on wiring setters whose target exposes a canonical back-pointer. Example: `Furnace.setMineCore(core)` requires `core.furnace()` to be `0` or equal to the calling Furnace.

**reignEthRecipient** / **reignClaimRecipient** — Per-reign routing pins set at reign start. The active King identity (or a delegate with the right session bits) can update them mid-reign via `setCurrentReignRecipients(...)`.

**Reign id** — Monotonic counter incremented on every successful takeover. `reignId = 0` is the genesis pseudo-reign.

## S

**Settlement keeper grace** — See *Keeper grace window*.

**Spot bonus** — The user-facing bonus rate at a specific block. Distinct from the lock-time materialized bonus, which uses the same model but at the lock's block.

**Stream re-fund** — Every Furnace event that funds the LP stream resets the schedule. Each re-fund emits `LpStreamFunded(amountFunded, newRatePerSec, newPeriodFinish)`.

## T

**takeoverWithToken** — `MineCore` entrypoint that swaps an allowlisted token to ETH via `EntryTokenRegistry.resolveTakeoverRoute` and the DexAdapter before executing the takeover. Bounded swap deadline `SWAP_DEADLINE_SECONDS = 300s`. Caller-controlled deadline variant: `takeoverWithTokenAndDeadline`.

**tick** — Permissionless Furnace upkeep entrypoint. Advances LP stream accrual and overflow-drip maintenance independent of any user action. Driven both from `MaintenanceHub.poke(args)` and directly.

**Topup** — Canonical casing for the lock-top-up identifiers across code, ABIs, docs, and SDK (lowercase `u`). All `lpTopup*` references use this casing.

## V

**ve checkpoint advancement** — `MineCore.advanceVeCheckpoint()` advances the ve global checkpoint without requiring a takeover. Use when `ve.globalLastTs()` falls significantly behind `block.timestamp` after a long pause.

**veCLAIM** — ERC-721 lock position (`VeClaimNFT`). Balance per user = sum of `principal * timeRemaining / 365d` across owned locks. Decays linearly toward zero unless AutoMax.

**Virtual depth** — Step 4 of the bonus model: the cool-off curve that reduces the spot bonus after large entries within the same window. Implemented in `FurnaceQuoter`.

## W

**Wiring hardening** — General term for the set of admin-time and runtime checks that defend against bundle drift, delegated EOAs, and pre-call fail-closed scenarios. See [Protocol Overview](protocol-overview.md) `## Wiring safety model`.

**Withdraw** — UI verb for owed balances or assets the user previously deposited (fallback King payouts, unlocked CLAIM, LP withdrawals). Never used for ETH royalty Collect.

## See also

- [Errors Reference](errors.md) — every revert by surface
- [Events and Indexing](events-and-indexing.md) — canonical event vocabulary
- [Constants Reference](appendix-constants-v100.md) — numeric thresholds named here
- [Protocol Overview](protocol-overview.md) — architecture and the CLAIM stream
- User-manual glossary: [https://docs.claimru.sh/glossary](https://docs.claimru.sh/glossary)
