# Developer FAQ

Common questions and pitfalls for integrators building on the v1.0.0 protocol. For user-side questions, see the [user manual FAQ](https://docs.claimru.sh/faq-troubleshooting).

## Reverts

### `WiringMismatch`

A canonical-bundle gate failed. The calling contract resolved its dependencies, found that `Furnace`, `MarketRouter`, `MineCore`, `VeClaimNFT`, `ClaimToken`, or `ShareholderRoyalties` no longer agree on one canonical bundle, and reverted closed. This is intentional: split-brain deployments cannot silently mutate accounting.

Diagnose by reading the back-pointers on the live contracts and comparing them to `deployments/<network>.json`. If the manifest is stale relative to a redeploy, refresh it. If the live state has drifted from the manifest, the wiring needs governance attention. See [Protocol Overview — Wiring safety model](protocol-overview.md#wiring-safety-model).

### `DelegatedEOA(address account)` / `DelegatedEOAOwner(address account)`

The address carries an EIP-7702 designator (23-byte runtime starting with `0xEF0100`). Owner seats, guardian seats, keeper allowlist seats, wiring-setter candidates, and delegation-session delegate seats all reject this case. Use a bare EOA or an ordinary contract instead. See [Security, Guardian, Pausing — EIP-7702 designator rejection](security-guardian-pausing.md#eip-7702-designator-rejection).

### `NotAContract()`

A wiring setter was given an address with `code.length == 0`. Either it is a bare EOA (some setters that don't care about 7702 specifically still require a contract) or the contract has not been deployed yet. `MineCore` and `MaintenanceHub` also use this error for the 7702 case instead of `DelegatedEOA`.

### `MinVeOutNotMet` / `MinClaimOutNotMet`

A slippage floor tripped. The user-supplied `minVeOut` / `minClaimOut` exceeded what the Furnace would have produced at the live block. Either the quote moved after fetch, or the slippage tolerance is too tight. Re-quote via `FurnaceQuoter` and resubmit. The Furnace clamps `minVeOut == 0 && veOut > 0` to 1 as a UX guard for the auto-compound and shareholder-compound paths; direct entry paths do not.

### `BonusTargetNotMet`

A Make Offer / auto-furnace execution checked the live gross bonus against the saved target and the gate floored. The `MarketRouter.bonusBpsVsPrincipalClaim` view uses floor rounding via `Math.mulDiv` — the gate cannot spuriously reject a valid ratio. Wait for the bonus to recover or cancel the escrow.

### `TakeoversPaused` / `LockingPaused` / `TradingPaused`

The guardian has paused the surface. See [Security, Guardian, Pausing — Pause surfaces](security-guardian-pausing.md#pause-surfaces) for the per-surface effect tables and what unwind paths remain available.

### `ListingCooldown`

A market listing state change ran inside the 1-block cooldown. Wait one block and retry.

### `GenesisKingClaimNotCollected`

`MineCore.setTakeoversPaused(false)` was called before the one-shot `LaunchController.collectGenesisKingClaim(address)` ran. This is a launch-window gate; on a fully launched deployment this revert should not appear.

## Indexers

### My subgraph misses `enterWithToken` rows

`FurnaceEnter` does not include `tokenIn` / `amountIn` in its payload — the values must be recovered from the transaction receipt. For top-level direct calls, calldata decoding works. For internal calls (Safe / smart account / helper / batch), the canonical recovery rule is the **latest ERC20 `Transfer` log into the Furnace address (excluding CLAIM) strictly preceding the `FurnaceEnter` log**. See [Events and Indexing](events-and-indexing.md) → "enterWithToken" bullet for the full rule. The shipped subgraph mapping (`subgraph/src/mappings/furnace.ts`, function `deriveTokenEntryFromReceipt`) is the reference implementation.

### `AutoMax` extension stops accruing in my indexer

`VeClaimNFT.setAutoMax(tokenId, enabled)` rewrites `lockEnd = block.timestamp + MAX_LOCK_DURATION` on every flag-state change AND on the same-state enable refresh. The emitted `AutoMaxSet(user, tokenId, autoMax)` does not carry the new `lockEnd`. Indexers MUST refresh both the `autoMax` flag AND the persisted `lockEnd` (set to `event.block.timestamp + MAX_LOCK_DURATION`) on every event, regardless of flag-direction. See [Events and Indexing](events-and-indexing.md) → "AutoMax indexing invariant".

### Auto-furnace `BonusTargetEscrowExecuted` rows don't link to their `FurnaceEnter`

The join key is `(txHash, logIndex)`, not `(txHash, user)` — batched helper / maintenance transactions emit multiple sibling events that would otherwise collapse onto the same per-`(txHash, user)` row. The shipped subgraph requests `receipt: true` on the relevant handlers so it can walk the receipt and select the largest `logIndex < execution.logIndex` from the `FurnaceEnter` rows in the same transaction. See [Events and Indexing](events-and-indexing.md) → "TxFurnaceEnter join key".

### `DelegationSessionUsed` rows look corrupted

The same `DelegationSessionUsed` event selector is shared across every consuming contract (`MineCore`, `Furnace`, `VeClaimNFT`, `LpStakingVault7D`, `ShareholderRoyalties`, `ClaimAllHelper`, `FurnaceGuardHelper`). A `(topic0) → ABI` map collapses per-surface decode entries into one row. Scope the lookup by `(contract, topic0)`. The shipped event-watcher composite-keys its decode index this way and admits the `ClaimAllHelper` address into its allowlist so harvest-claim delegation activity (`P_SHAREHOLDER_CLAIM_FOR`, `P_LP_CLAIM_FOR`) is observed alongside the rest.

### Why does `ShareholderAutoCompoundFailed` fire without a paused state?

`compoundForMany` (the batch path) skips users instead of pausing them when the quote call fails. The single-user path pauses with a reason code. See [Events and Indexing](events-and-indexing.md) → "Baron auto-compound failures".

## SDK and tooling

### Where is the SDK package?

The Agent SDK lives at `agents/sdk/` inside the public protocol repo. It is not published as a standalone npm package in v1.0.0. See [Agents and Automation — Install](agents-and-automation.md#install).

### Which manifest do I read?

`deployments/<network>.json` is canonical. The `.md` mirror is rendered for humans. Always load the JSON in code and treat `contracts.<Name>.address` as the live address — `implementation`, `proxyAdmin`, and `proxyAdminOwner` are governance metadata for the proxy-backed quartet. See [Runtime Proxy Upgrades — Canonical addresses](runtime-proxy-upgrades.md#canonical-addresses).

### How do I filter logs to skip pre-deployment blocks?

Every contract entry in the manifest carries a `startBlock`. Filter `evt_block_number >= startBlock` for that contract.

### Where is the public subgraph?

There is no single public subgraph endpoint. Deploy the shipped subgraph against your own Graph node or self-hosted Graph Node. See [Events and Indexing — Public subgraph endpoint](events-and-indexing.md#public-subgraph-endpoint).

## Keepers and bots

### My keeper's `payoutBoundViolation` tripped — what happened?

The EOA balance delta did not equal `−gasSpent` after a transaction. The runtime guard treats this as a payout-routing leak (mining ETH or CLAIM rewards routed back to the keeper EOA instead of the intended recipient) and trips the circuit breaker. Verify reign / Collect / Furnace recipient configuration before resuming. See [Maintenance and Bots](maintenance-and-bots.md).

### Can I run a keeper that bypasses `KEEPER_LIVE_RUN` slippage guards?

No. `KEEPER_ALLOW_UNSAFE_MIN_OUT` and `KEEPER_ALLOW_UNSAFE_MIN_VE_OUT` are hard-forbidden when `KEEPER_LIVE_RUN=1`. This is enforced at config-load time and cannot be bypassed.

### What's the `LaunchController.preflight()` bitmask?

`preflight() returns (uint256 statusBitmask, uint256 requiredSeedEth)` mirrors every `finalizeGenesis()` precondition as packed bits 0..10 plus the would-be seed ETH. Use it for operator dry-run and monitoring instead of re-deriving the checks off-chain. See [Genesis](genesis.md).

## See also

- [Errors Reference](errors.md) — every revert by surface
- [Events and Indexing](events-and-indexing.md) — canonical event vocabulary and indexer rules
- [Protocol Overview](protocol-overview.md) — wiring safety model and trust boundaries
- [Security, Guardian, Pausing](security-guardian-pausing.md) — role hierarchy and pause surfaces
- [Glossary](glossary.md) — protocol vocabulary
