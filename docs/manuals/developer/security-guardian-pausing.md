# Security, Guardian, Pausing

This page explains:
- roles (admin vs guardian)
- pause surfaces
- what happens when paused
- how clients and bots should behave

## Roles (high level)

Admin (owner):
- config wiring via `onlyOwner` setters, governed by the live `TimelockController`
- contracts enforce the live `owner()` path; in v1.0.0 that owner path is the `TimelockController` governed by the Safe
- cannot use pause surfaces as a substitute for governance

Guardian:
- fast incident response
- long-term role is pause/unpause on core surfaces, subject to the MineCore genesis gate that blocks `setTakeoversPaused(false)` until `genesisKingClaimCollected == true`, disable-only response on registries, and documented emergency self-rotation via `setGuardian(address)`
- launch-phase exception: `MineCore.guardian` may be the `LaunchController` contract during genesis, which also has the one-shot `collectGenesisKingClaim(address)` privilege used by `finalizeGenesis()`; installing that LaunchController guardian is owner-only, and only that canonical LaunchController-like guardian for this exact `MineCore + CLAIM` pair may use the privilege
- production v1.0.0 uses a dedicated guardian multisig with strict op policy; the contracts enforce only the configured guardian address

Canonical reference:
- This page plus `docs/spec/spec-v1.0.0.md` define the public role and pause surfaces for v1.0.0.

## Config governance model

### What is direct vs upgradeable

`ClaimToken` and `VeClaimNFT` are direct permanent roots.

`MineCore`, `Furnace`, `MarketRouter`, and `ShareholderRoyalties` are deployed behind transparent proxies. Their proxy addresses are the canonical runtime addresses, and governed upgrades happen through timelock-owned `ProxyAdmin` contracts until the final freeze-and-burn ceremony burns those proxy admins.

### Freeze-and-burn finality (summary)

Five core contracts expose `configFrozen` + one-way `freezeConfig()`:

| Contract | Frozen setters |
|---|---|
| **ClaimToken** | `setMineCore()` |
| **Furnace** | `setShareholderRoyalties()`, `setMineCore()`, `setMineMarket()`, `setFurnaceQuoter()`, `setLpRewardsVault()` |
| **MineCore** | `setFurnace()`, `setClaimAllHelper()`, `setDelegationHub()` |
| **VeClaimNFT** | `setFurnace()`, `setMineMarket()` |
| **ShareholderRoyalties** | `setWiring()` (mineCore, mineMarket, furnace), `setClaimAllHelper()` |

Before the canonical freeze, `MineCore`, `Furnace`, `MarketRouter`, and `ShareholderRoyalties` keep stable proxy addresses with timelock-owned `ProxyAdmin`s. The freeze-and-burn finality ceremony locks the table above and renounces the four runtime `ProxyAdmin` owners in a single timelock batch — freeze first, burn second, atomic under any precondition failure.

`Furnace.setDelegationHub` and the delayed Furnace emergency LP-vault recovery path (`requestEmergencyVaultRewire` / `cancelEmergencyVaultRewire` / `executeEmergencyVaultRewire`) intentionally remain `onlyOwner` after freeze. Both surfaces are reciprocal-bound or delay-gated and are documented as the narrow exceptions.

The full ceremony procedure, the script-canonical path (`FreezeAndBurn.s.sol`), the reciprocal-bundle validation per contract, the launch sequence, and the per-contract Security-page status mapping live in [Freeze-and-Burn Finality](freeze-and-burn-finality.md).

### Runtime safeguards (always on)

These constraints hold regardless of freeze status:

- `Furnace.setMineCore(address _mineCore)` atomically assigns `guardian = _mineCore`; `Furnace.setGuardian(address)` only allows re-asserting the current `MineCore`, preserving the single pause surface.
- **Wiring order:** `Furnace.setMineCore` MUST be called before `MineCore.setFurnace` — MineCore validates `Furnace.mineCore() == address(this)`.
- `EntryTokenRegistry` cannot change `router` / `factory` in place after route surfaces exist.
- Before freeze, `Furnace` cannot change or clear `lpRewardsVault` while already-earned LP liability remains attributable to the current vault.
- MineCore genesis exception: before `genesisKingClaimCollected == true`, only `owner` may install the `LaunchController` guardian; once installed, MineCore guardian rotation is locked until collection finalizes.

### What integrators should monitor

- `configFrozen()` on all 5 core contracts (detect whether game-rule wiring is permanently locked).
- Ownership changes on the live timelock owner path and the four runtime `ProxyAdmin`s.
- Pause flags, guardian/owner changes, registry token disables, operational allowlist updates, and runtime implementation / proxy-admin owner changes.

## Mutable guardian fields (rotation surface)

Four contracts expose a mutable `guardian` field that MUST be in lockstep at the production Guardian Safe. `setGuardian(address)` is callable on each surface either by the live owner or by the current guardian (emergency self-rotation) at all times, including while paused.

Every nonzero guardian assignment — including the post-genesis branch on `MineCore` and the human-EOA branch on `EntryTokenRegistry` — runs `_rejectDelegatedEOA(guardian)`. Bare EOAs (`code.length == 0`) and ordinary contracts pass; addresses carrying an EIP-7702 designator (`0xef0100 || target`) revert `DelegatedEOA`. The signer behind a 7702-delegated address can revoke or replace the underlying executor at any time, so admitting one as guardian would expose a public pause / disable / rotate surface controlled by whoever currently runs as code at that address.

The runtime defence-in-depth check varies by surface:

- `MineCore.onlyGuardian` and `MarketRouter.onlyGuardian` re-run `_rejectDelegatedEOA(msg.sender)` on every guardian-only call. A seated guardian that installs a 7702 designator after the rotation cannot route protocol-control surfaces through public-executor code; the seat-side check on `setGuardian` covers the new seat and the modifier runtime check closes the post-seating install vector.
- `EntryTokenRegistry.setTokenEnabled` re-runs `_rejectDelegatedEOA(sender)` inline on the guardian-disable branch (the only guardian-callable surface).
- `LaunchController.finalizeGenesis()` re-runs `_rejectDelegatedEOA(sender)` inline against the immutable guardian.
- `Furnace.onlyGuardian` does not re-run the runtime check; `Furnace.guardian` MUST be `MineCore` post-wiring (a contract address, never a 7702 designator), and the brief pre-wiring window is closed operationally by the deployment script. The owner-side proxy-admin guard, the constructor seat, and the wiring guard pinning `guardian == mineCore` together cover the threat model without spending an EIP-170 budget word on the modifier check.

| Contract | Field | Pause / disable surface controlled |
|---|---|---|
| `MineCore` | `MineCore.guardian` | `setTakeoversPaused(bool)`; forwards `setLockingPaused(bool)` into `Furnace` |
| `MarketRouter` | `MarketRouter.guardian` | `setTradingPaused(bool)` |
| `FurnaceEntryTokenRegistry` | `FurnaceEntryTokenRegistry.guardian` | guardian-only `setTokenEnabled(token, false)` for `Furnace.enterWithToken` |
| `MineCoreEntryTokenRegistry` | `MineCoreEntryTokenRegistry.guardian` | guardian-only `setTokenEnabled(token, false)` for `MineCore.takeoverWithToken` |

`Furnace.guardian` is **not** in the rotation set. It is unconditionally pinned to the canonical `MineCore` proxy address (atomically assigned inside `Furnace.setMineCore`; `Furnace.setGuardian` only allows re-asserting the current `MineCore`). The human pause key for locking is `MineCore.guardian`, which forwards `setLockingPaused(bool)` into Furnace through the single-switch wiring above.

Operator invariant — **all four mutable `guardian` fields MUST resolve to the same Guardian Safe address** in steady-state production. Verification recipe (post-deploy and post-rotation):

```
python3 scripts/verify_deployment.py \
    --network base_<sepolia|mainnet> --rpc-url $RPC \
    --expected-guardian $GUARDIAN_SAFE \
    --expected-secondary-guardian $GUARDIAN_SAFE
```

The verifier checks `MineCore.guardian == --expected-guardian` and `MarketRouter.guardian == FurnaceEntryTokenRegistry.guardian == MineCoreEntryTokenRegistry.guardian == --expected-secondary-guardian` (defaults to `--expected-guardian` when omitted). It also asserts `Furnace.guardian == MineCore` (spec-locked pin). Any mismatch is a hard fail and MUST be resolved by a `setGuardian(address)` rotation before further deploy steps proceed.

MineCore genesis exception (launch window only): before `genesisKingClaimCollected == true`, `MineCore.guardian` may be the canonical `LaunchController` contract, and the field is owner-installable. Once the canonical LaunchController-like guardian is installed, MineCore guardian rotation is locked until `genesisKingClaimCollected == true` flips. This exception applies only to `MineCore.guardian`; the other three fields ship with the Guardian Safe directly and follow the lockstep invariant from initial wiring.

## EIP-7702 designator rejection

ClaimRush rejects EIP-7702-delegated EOAs at every privileged seat. The signer behind a 7702-delegated address can re-point the executor code at any time, so admitting one as an owner, guardian, keeper, or delegation seat would expose protocol entry points to whoever currently runs as code at that address.

The canonical designator test is `code.length == 23 && extcodecopy[0..3] == 0xEF0100`. Bare EOAs (`code.length == 0`) and ordinary contracts pass; only the 7702 designator prefix reverts. The reject helper is named `_rejectDelegatedEOA` everywhere except `DexAdapter` (which uses the designator-only `_rejectDelegated7702Owner` to accept bare-EOA owners) and the `UpgradeableProtocolBase` virtual hook (which uses `_validateNewOwner` and reverts `DelegatedEOAOwner(account)` instead of `DelegatedEOA(account)`).

Four enforcement surfaces:

### Keeper allowlist 7702 guard

Every keeper-allowlist enable runs `_rejectDelegatedEOA(keeper)` before flipping the entry to `true`. Disables (`allowed == false`) skip the check so a compromised seat can always be removed. The dust-guard floors (`setMinAutoCompoundEth`, `setMinCompoundReward`, `setMinHarvestClaimFloor`) do not run the rejection.

| Contract | Setter | Effect of allowlisting |
|---|---|---|
| `MarketRouter` | `setSettlementKeeper(addr, true)` | admits `addr` to the settlement-keeper grace window for `executeAutoFurnace` and the routed sell paths |
| `ShareholderRoyalties` | `setAutoCompoundKeeper(addr, true)` | admits `addr` to the auto-compound batch path (`compoundForMany`) |
| `LpStakingVault7D` | `setHarvestKeeper(addr, true)` | admits `addr` to the harvest path that triggers `notifyRewards` and the LP fee harvest |

### Initial-owner 7702 guard

Constructors and initializers reject a delegated-EOA `initialOwner` at deploy time.

| Contract | Seat | Variant |
|---|---|---|
| `ClaimToken` | constructor `initialOwner` | strict `_rejectDelegatedEOA` |
| `VeClaimNFT` | constructor `initialOwner` | strict `_rejectDelegatedEOA` |
| `MarketRouter` | initializer `initialOwner` | strict `_rejectDelegatedEOA` |
| `ShareholderRoyalties` | initializer `initialOwner` | strict `_rejectDelegatedEOA` |
| `LpStakingVault7D` | constructor `initialOwner` | strict `_rejectDelegatedEOA` |
| `Furnace` | constructor `initialOwner` (impl-direct path) | designator-only check (`code.length == 23`) inlined for EIP-170 budget |
| `DexAdapter` | constructor `initialOwner` and `transferOwnership(newOwner)` | designator-only `_rejectDelegated7702Owner` |

The strict variant accepts bare EOAs and ordinary contracts but rejects 7702 designators. The designator-only variant also accepts bare EOAs (only the `0xEF0100` prefix reverts) and exists where the impl must stay under EIP-170 (`Furnace`) or where operator setups expect a bare-EOA owner (`DexAdapter` — see [EntryTokenRegistry and DexAdapter](entrytokenregistry-and-dexadapter.md)).

### Owner-transfer 7702 guard

The Ownable2Step transfer / accept seam runs the rejection at both nominate and accept time so a nominee that installs a 7702 designator between calls is caught at acceptance. The `onlyOwner` modifier on `UpgradeableProtocolBase` re-runs the check on every owner-only call (one `extcodecopy(msg.sender, 0, 0, 3)` per call) so a seated owner that installs a designator post-acceptance cannot route owner-only surfaces through public-executor code.

| Contract | Surface | Variant |
|---|---|---|
| `MineCore` | `transferOwnership` + `acceptOwnership` (inherited) | base `_validateNewOwner` virtual hook on `UpgradeableProtocolBase` |
| `MarketRouter` | `transferOwnership` + `acceptOwnership` (inherited) | base `_validateNewOwner` virtual hook on `UpgradeableProtocolBase` |
| `ShareholderRoyalties` | `transferOwnership` + `acceptOwnership` (inherited) | base `_validateNewOwner` virtual hook on `UpgradeableProtocolBase` |
| `Furnace` | `transferOwnership` + `acceptOwnership` (inherited) | `_validateNewOwner` overridden to a no-op for EIP-170 budget |
| `ClaimToken` | `transferOwnership` + `acceptOwnership` overrides | strict `_rejectDelegatedEOA` |
| `VeClaimNFT` | `transferOwnership` + `acceptOwnership` overrides | strict `_rejectDelegatedEOA` |
| `LpStakingVault7D` | `transferOwnership` + `acceptOwnership` overrides | strict `_rejectDelegatedEOA` |
| `EntryTokenRegistry` | `transferOwnership` + `acceptOwnership` overrides | strict `_rejectDelegatedEOA` |
| `DexAdapter` | `transferOwnership` + `acceptOwnership` overrides | designator-only `_rejectDelegated7702Owner` |

`Furnace` concentrates the protection at the proxy admin seat and the deploy-time owner-Safe pinning instead of the runtime hook, since the impl is within ~25 bytes of EIP-170. Any future override of this hook MUST document the alternative coverage in NatSpec.

#### Mixed-authority owner branches

Several setters allow either the owner OR a non-owner role (guardian, keeper, helper) to call them. The owner side of these branches is an explicit `msg.sender == owner()` equality check rather than an `onlyOwner` modifier, so the modifier-side runtime designator rejection does not apply. The contract enforces the guard explicitly on the owner branch:

- `MarketRouter.setGuardian`, `MarketRouter.sellListedLockToFurnace`, `MarketRouter.executeAutoFurnace`: owner branch runs `_validateNewOwner(msg.sender)`.
- `MineCore.setGuardian`: pre- and post-genesis owner branches run `_validateNewOwner(sender)`.
- `ShareholderRoyalties.onlyAutoCompoundKeeper` and `LpStakingVault7D.onlyHarvestKeeper`: modifiers run `_rejectDelegatedEOA(msg.sender)` unconditionally, so owner and keeper branches both reject 7702 callers.
- `EntryTokenRegistry.setGuardian`, `EntryTokenRegistry.setTokenEnabled`: owner-side branches run `_rejectDelegatedEOA(sender)`; `_checkOwner` also calls the helper so the OZ-Ownable2Step `onlyOwner` modifier picks up the guard too.

The non-owner branch retains its own seat-side guards (`_rejectDelegatedEOA(guardian)` at `setGuardian`, `_rejectDelegatedEOA(keeper)` at every keeper allowlist enable).

### Delegation session-seat 7702 guard

`DelegationHub.setSession(delegate, perms, expiry, ...)` runs `_rejectDelegatedEOA(delegate)` whenever `perms != 0`. Revocations (`perms == 0`) skip the check so a compromised session can always be torn down. See [Bot Sessions (DelegationHub)](delegationhub.md) for the full permissions matrix and consuming-contract list.

## Pause surfaces

### MineCore: takeoversPaused

Controlled by:
- MineCore.guardian

Operational note:
- guardian can always pause takeovers
- unpausing (`setTakeoversPaused(false)`) reverts with `Errors.GenesisKingClaimNotCollected` until `genesisKingClaimCollected == true`

Effect when true:
- takeover(maxPrice) reverts with Errors.TakeoversPaused
- takeoverWithToken(tokenIn, amountIn, minEthOut, maxPrice) reverts with Errors.TakeoversPaused
- getTakeoverPrice still works

Mining safety (important):
- On pause transitions, MineCore clamps currentReignLastAccrualTime to block.timestamp.
- This means paused time is never mined later.

### Furnace: lockingPaused

Controlled by:
- MineCore.guardian via `MineCore.setLockingPaused(bool)` forwarding into Furnace
- `Furnace.guardian` is atomically set to `_mineCore` inside `Furnace.setMineCore(address _mineCore)`; no separate `setGuardian` call is needed. Rotate the human guardian on `MineCore`, not on `Furnace`

Effect when true:
- enterWithEth / enterWithClaim / enterWithToken reverts with Errors.LockingPaused
- sellLockToFurnaceFromMarket and the MarketRouter sell paths that depend on it also revert with Errors.LockingPaused
- FurnaceQuoter quote views (quoteEnterWith*, quoteSellLockToFurnace*, quoteSellLockForExecution) also revert (same pause gate)
- ShareholderRoyalties Collect & Lock mode continues to work only when locking is enabled

Canonical single-switch wiring:
- MineCore.setLockingPaused(bool) forwards to Furnace
- `Furnace.guardian` MUST be `MineCore` (atomically assigned inside `Furnace.setMineCore`)

### MarketRouter: tradingPaused

Controlled by:
- MarketRouter.guardian

Effect when true:
- `listLock`, `sellLockToFurnace`, `sellListedLockToFurnace`, `createBonusTargetEscrowWithTarget`, `executeAutoFurnace`, and `extendBonusTargetEscrowExpiry` revert with `Errors.TradingPaused`
- unwind / housekeeping still work:
  - `delistLock(tokenId)`
  - `cancelExpiredListing(tokenId)` (permissionless after listing expiry)
  - `cancelBonusTargetEscrow(offerId)` (buyer while canonical; anyone as refund-only rescue if the router is no longer canonical for the live market bundle)
  - `cancelExpiredBonusTargetEscrow(offerId)` (permissionless after offer expiry)
  - `emergencyDelist(tokenId)` (seller-only after 7 days)

### EntryTokenRegistry: disable tokens

Controlled by:
- owner can enable and disable tokens
- guardian can disable tokens only (emergency safety valve); guardian calling `setTokenEnabled(token, true)` reverts with `NotAuthorized`
- **1-hour cooldown after guardian disable**: when the guardian disables a token, the owner cannot re-enable it for 1 hour (`GUARDIAN_DISABLE_COOLDOWN`). Both `setTokenEnabled(enabled=true)` and `setTokenConfig(enabled=true)` respect this cooldown. This gives incident responders time to escalate before the owner can override.
- guardian rotation via `setGuardian(address)` remains available for emergency key replacement

Effect:
- disabled tokens cannot be used for:
  - Furnace.enterWithToken
  - MineCore.takeoverWithToken

WETH is not allowlisted and is always supported via the WETH special-case.

### What pause does **not** mean

There is no global onchain maintenance pause.

- `MaintenanceHub.poke(...)` stays permissionless onchain.
- Keeper pause files and circuit breakers are **offchain** safety rails for the team-operated bot only.
- Those keeper-local controls do **not** block public users or other callers from hitting onchain entrypoints.
- Individual subcalls inside `MaintenanceHub.poke(...)` still obey their own onchain pause checks (`tradingPaused`, `lockingPaused`, `takeoversPaused`) and may fail best-effort.

### Keeper daemon behaviour during pause (important clarification)

`KEEPER_PAUSED=1` or a pause file prevents `sendContractTx()` from submitting onchain transactions, but the daemon loop continues running read-only tasks (scanning, quoting, logging). For full quiescence, stop the keeper process — do not rely on the pause file alone.

---

## Guardian activation criteria (practical)

The guardian should pause only for clear protocol safety reasons.
Common triggers:
- takeover pricing anomalies (unexpected getTakeoverPrice outputs, reference price corruption)
- unexpected revert spikes on core paths (takeover, enter, offer acceptance)
- swap routing anomalies (registry routes mismatching router.poolFor validation)
- reserve accounting inconsistencies (reserve underflow attempts, abnormal bonus quotes)
- suspected exploit paths or dependency failures (DEX router issues, pool hijack risk)

## What clients should do when paused

UI behavior:
- detect pause flags and display a clear banner
- disable affected CTAs
- keep exit paths available (delist, cancel offer, withdraw balances)

Bot behavior:
- stop calling:
  - takeovers when takeoversPaused
  - Furnace entry when lockingPaused
  - executeAutoFurnace when tradingPaused
- keep calling `MaintenanceHub.poke({ offerIds: [], maxOffers: 0 })` for non-swap upkeep

User funds safety (important)
- Pausing does not seize funds.
- Pausing only prevents new state transitions on the paused surfaces.
- Pull-based withdrawals remain available:
  - MineCore.withdrawKingBalance
  - MineCore.withdrawRefundBalance
- Market unwind / housekeeping paths remain available:
  - MarketRouter.delistLock / cancelExpiredListing / cancelBonusTargetEscrow / cancelExpiredBonusTargetEscrow / emergencyDelist


## FAQ for integrators: what happens when guardian pauses?

Takeovers paused (MineCore.takeoversPaused = true):
- New takeovers revert.
- The current reign cannot end.
- Crown emission accrual is clamped at the pause boundary.
  - There is no "backpay" when unpaused.
- UI should:
  - hide/disable takeover buttons
  - keep price display, history, and Crown ETH withdrawal UX

Locking paused (Furnace.lockingPaused = true):
- New Furnace entries revert.
- All FurnaceQuoter quoteEnterWith* and quoteSellLock* views revert.
- MarketRouter sell paths that settle into Furnace also revert: `sellLockToFurnace`, `sellListedLockToFurnace` (downstream `Furnace.sellLockToFurnaceFromMarket` has `whenLockingEnabled`).
- Barons ETH collection still works in mode 0 (Collect ETH).
- Auto-compound paths behave safely:
  - `ShareholderRoyalties.compoundFor(user)` bubbles the Furnace revert atomically, so claimable ETH and cadence state stay untouched.
  - `ShareholderRoyalties.compoundForMany(users[], maxUsers)` restores the affected user's accounting on downstream Furnace failure, but canonical Baron-bundle drift detected during `checkpointUser(user)` can still fail close before mutation and revert the batch.
  - LP vault auto-compound keeps rewards intact on revert.
- UI should:
  - disable lock actions and compounding CTAs
  - keep Collect ETH CTA available

Trading paused (MarketRouter.tradingPaused = true):
- Market actions revert (`listLock`, `sellLockToFurnace`, `sellListedLockToFurnace`, `createBonusTargetEscrowWithTarget`, `executeAutoFurnace`, `extendBonusTargetEscrowExpiry`).
- Unwind / housekeeping stay open:
  - delistLock, cancelExpiredListing, cancelBonusTargetEscrow, cancelExpiredBonusTargetEscrow, emergencyDelist (seller-only after 7d)
- UI should:
  - disable new listings and bonus target escrow actions
  - keep cancel/delist buttons available

Token disabled (EntryTokenRegistry token enabled=false):
- enterWithToken and/or takeoverWithToken revert for that token.
- ETH entry remains available.
- UI should:
  - gray out the token in token pickers
  - explain that it was disabled for safety

## See also

- [Protocol Overview](protocol-overview.md) — role hierarchy and ownership
- [Maintenance and Bots](maintenance-and-bots.md) — keeper loops affected by pause states
- [Events and Indexing](events-and-indexing.md) — pause and guardian events
- [Constants Reference](appendix-constants-v100.md) — guardian and safety constants
