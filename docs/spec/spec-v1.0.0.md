# ClaimRush v1.0.0 – Clean SPEC

This is the **clean, implementation-facing specification** for ClaimRush v1.0.0.

It is the canonical implementation reference for:
- Core game mechanics
- Contract responsibilities
- Constants and invariants that MUST be enforced in code

This SPEC MUST always be read together with:
- [Architecture reference](../architecture/architecture-reference-v1.0.0.md)
- User manual: <https://docs.claimru.sh/>
- `docs/manuals/developer/`
- `docs/analytics/leaderboards-ui-and-dune-compatible-v1.0.0.md`
- `docs/spec/spec-quality-standard-v1.0.0.md`
- `src/lib/Constants.sol`
- `docs/spec/entry-token-registry-v1.0.0.md`
- `docs/spec/launch-controller-spec-v1.0.0.md`
- [Aerodrome integration appendix](../architecture/aerodrome-integration-appendix-v1.0.0.md)
- [Aerodrome liquidity bootstrap appendix](../architecture/aerodrome-liquidity-bootstrap-appendix-v1.0.0.md)
- `docs/spec/state-machines-v1.0.0.md`
- `docs/spec/test-vectors-v1.0.0.md`

If there is ever a conflict, **this SPEC + Guardrails + Architecture Reference** together define the intended behavior.

## Normative interpretation

- This document is normative for ClaimRush v1.0.0.
- Keywords are interpreted as:
  - MUST / MUST NOT: absolute implementation requirements.
  - NOT PART OF V1.0.0: explicitly excluded from this repo’s v1.0.0 implementation.
- Guidance language (including `recommended`, `should`, `may`, `optional`) is non-binding. Treat it as implementation help only.
- Binding requirements use only: MUST / MUST NOT / REQUIRED / NOT PART OF V1.0.0.
- Conflict resolution follows the source-of-truth rules in `docs/v1.0.0-index.md`.
- The published spec set MUST state every requirement that changes implementation behavior.

---

## 0. High-level overview

ClaimRush is an onchain game where players compete to become **King** and mine CLAIM emissions, while long-term **Barons** lock CLAIM to earn a share of takeover ETH.

Key roles:

- **King**
  - Pays ETH to take the Mine (takeover).
  - Receives CLAIM emissions while reigning.
  - Receives 75% of the next takeover ETH.
- **Barons (veCLAIM holders)**
  - Lock CLAIM for up to 1 year (linear decay).
  - Receive 25% of every takeover’s ETH via `ShareholderRoyalties`.
  - The protocol MUST support manual compounding by routing Barons ETH rewards through Furnace lock mode via `claimShareholder(LOCK_FURNACE, ...)`.
  - The protocol MUST support keeper-allowlisted auto-compounding of Barons ETH rewards into Furnace on a user-defined cadence, with owner break-glass execution retained for emergencies (no economics change; see §6.7).

Core properties:

- CLAIM supply starts at 0.
- No premine, no protocol fees, no treasury.
- Emissions:
  - 50 CLAIM/sec to King at launch → 50/9 CLAIM/sec tail floor (≈ 5.555).
  - 5 CLAIM/sec to Furnace reserve at launch → 5/9 CLAIM/sec (≈ 0.555) tail floor.
- ve model = 1-year max locks, linear decay.
- Furnace is the **only** bonus system.
  - The Furnace computes a **gross** bonus and then splits that bonus into:
    - a **net user bonus** (locked for the user)
    - an LP vault reward (liquid CLAIM, distributed to staked LP)
- veCLAIM NFTs are non-transferable for users (strict mode: no user↔user transfers).
  - The only non-mint/non-burn transfer is MarketRouter (`mineMarket`) moving a lock into Furnace custody (`to == furnace`) for settlement/sellback (see §4.5 and §7.6).

LP incentives (new in v1.0.0):
- The protocol ships an on-protocol LP Staking Vault funded by a split of the Furnace gross bonus (not a protocol fee).
- LP vault rewards are liquid CLAIM.
- LP vault MUST harvest Aerodrome pool fees via owner-or-keeper-allowlisted callers and donate 100% of net fee value into LP rewards (WETH-only, staleness-based bounty; typically `0` under the official keeper bot).
- The protocol MUST ship a permissionless `MaintenanceHub.poke(...)` convenience router for bundling ve checkpoints + shareholder flush + market auto-fallback exec + Furnace tick.
- Baron auto-compound (§6.7) is keeper-allowlisted (plus owner) and is expected to be executed by the official keeper in normal operation. `MaintenanceHub` MUST NOT execute Baron auto-compound.

Canonical currencies (locked):

- Takeover accounting currency: **ETH only**
- King and Baron payouts: **ETH only**
- Furnace output: **CLAIM only**
- Leaderboards and analytics: **ETH-denominated** for takeover spend and payout metrics (no per-entry-token leaderboards)

Multi-token entry (allowlisted):

- Furnace accepts ETH, CLAIM, and allowlisted ERC20 tokens. `tokenIn` is swapped to CLAIM at the entry boundary via `EntryTokenRegistry`.
- MineCore takeovers accept ETH and allowlisted ERC20 tokens. `tokenIn` is swapped to ETH at the entry boundary via `EntryTokenRegistry`.
- All core takeover accounting and payout events remain ETH-denominated.

---

## 1. Contract set (v1.0.0)

v1.0.0 is designed as a **direct-root + upgradeable-runtime** architecture. `ClaimToken` and `VeClaimNFT` remain direct permanent roots. `MineCore`, `Furnace`, `MarketRouter`, and `ShareholderRoyalties` are deployed behind transparent proxies whose proxy addresses are the canonical runtime endpoints. `DexAdapter` remains direct-deployed and non-upgradeable (scope B-07 choice B); DEX/router changes ship via redeploying `DexAdapter` and calling `EntryTokenRegistry.setRouterConfig(...)` through the live owner() path (typically timelocked in production).

Clarification (non-binding): section numbering
- Subsections under §1 use `1.0.x` to avoid collision with §1.1 (deployment wiring).
- These are section IDs, not release versions.

### 1.0.1 Direct roots + proxy-backed runtime

`ClaimToken` and `VeClaimNFT` are direct-deployed permanent roots. `MineCore`, `Furnace`, `MarketRouter`, and `ShareholderRoyalties` are proxy-backed runtime contracts whose canonical addresses are their transparent proxies. Game-rule parameters remain fixed inside a deployed implementation, but governance can upgrade the runtime quartet by upgrading those proxies. All five freeze-gated contracts still expose a one-way `freezeConfig()` that permanently locks their documented core wiring setters: `ClaimToken` locks `setMineCore()` and is frozen plus owner-renounced at the end of `Wire.s.sol`; `Furnace` locks `setShareholderRoyalties`, `setMineCore`, `setMineMarket`, `setFurnaceQuoter`, and `setLpRewardsVault` (the delayed emergency LP-vault recovery path `requestEmergencyVaultRewire(address)`, `cancelEmergencyVaultRewire()`, `executeEmergencyVaultRewire()` remains available after freeze); `MineCore` locks `setFurnace()`, `setClaimAllHelper()`; `VeClaimNFT` locks `setFurnace`, `setMineMarket`; `ShareholderRoyalties` locks `setWiring()`, `setClaimAllHelper()`. The freeze-and-burn ceremony freezes the remaining four contracts and burns the four runtime proxy admins. Operational peripherals (delegationHub, entryTokenRegistry, guardian, keeper allowlists, etc.) remain owner-configurable via timelock + multisig until and after finality where documented.

1. `ClaimToken`           – ERC20 CLAIM token.
2. `VeClaimNFT`           – ve-lock contract, positions as ERC721.
3. `MineCore`             – main game engine (reigns, takeovers, emissions).
4. `ShareholderRoyalties` – ETH index for veCLAIM holders.
5. `Furnace`              – unified entry + shared bonus engine.
6. `LpStakingVault7D`     – LP staking vault (WETH/CLAIM LP), funded by a split of Furnace gross bonus.
7. `LaunchController`      – one-shot genesis controller (10d accrual → liquidity + LP lock + activate).
8. `GenesisLPVault24M`     – locks genesis LP for 24 months (fixed-recipient withdrawal after unlock).

### 1.0.2 Routers/adapters (DexAdapter remains replaceable via redeploy)

Extensibility surfaces: the runtime quartet (MineCore, VeClaimNFT, Furnace, ShareholderRoyalties) is proxy-backed, so each can be upgraded via the standard proxy mechanism. `DexAdapter` is deployed directly (no proxy) and treated as immutable at its address; DEX/router changes ship via redeploying `DexAdapter` and calling `EntryTokenRegistry.setRouterConfig(...)` through the live owner() path (typically timelocked in production). `MarketRouter` is part of the proxy-backed runtime quartet. No `GameRouter` contract is part of v1.0.0.

9. `MarketRouter` – privileged marketplace router/adapter.
   - This address is wired into `VeClaimNFT` as `mineMarket` (via `VeClaimNFT.setMineMarket(...)`).
   - `MarketRouter` is the only allowed veCLAIM transfer caller (besides mint/burn), and it may only transfer locks into Furnace custody (`to == furnace`).
   - v1 lock-management behavior (list/delist + bonus target escrow execution) lives behind `MarketRouter` in strict mode.

10. `DexAdapter` – DEX router adapter implementing the exact `IAerodromeRouter` subset expected by the core/registry.
   - This address is referenced by `EntryTokenRegistry` as its `router`.
   - At launch it MUST delegate to Aerodrome v2 internally, but the protocol roots/runtime MUST NOT be permanently bound to a specific DEX implementation.

11. `GameRouter` – no `GameRouter` contract is implemented or deployed in this repo’s v1.0.0 release.
   - This repo’s v1.0.0 implementation MUST NOT implement or deploy `GameRouter`.

### 1.0.3 External governed config (one-way freezable)

12. `EntryTokenRegistry` – **external** governed allowlist + swap-route config for allowlisted entry tokens.

Gameplay and economics are not controlled by `EntryTokenRegistry`. It only controls which ERC20 tokens are accepted at the entry boundary and which allowlisted pools are used for swaps. In v1.0.0, DEX/router changes are executed by redeploying `DexAdapter` and calling `EntryTokenRegistry.setRouterConfig(...)` through the live owner() path (typically timelocked in production), and MUST preserve all v1.0.0 economics and invariants.

### Routing governance policy (normative)

This is the locked governance model for the routing trust surface (EntryTokenRegistry + DexAdapter).

REQUIRED:
- **Production deployment policy:** each EntryTokenRegistry `owner()` path should be the **ADMIN timelock** (timelock controlled by a multisig). Contracts themselves enforce only the live `owner()` address.
- **Immediate disables:** token disables MUST be possible immediately via **GUARDIAN (disable-only)** in EntryTokenRegistry.
- **No silent WETH/CLAIM rewiring:** `wrappedNative` and `claimToken` MUST be immutable after initialization in EntryTokenRegistry.
- **High-trust changes:** EntryTokenRegistry routing changes (including updating `router` to a new `DexAdapter`) MUST be governed through the live `owner()` path, with production policy expecting multisig + timelock.

See `docs/spec/entry-token-registry-v1.0.0.md` for the interface and the detailed governance rules.

---

### 1.1 Deployment wiring and initialization order

**Access control standard (locked):**
- Use OpenZeppelin `Ownable2Step` on all configurable contracts.
- `owner` is the live `owner()` path; in production v1.0.0 it is the `TimelockController` governed by the Safe.
- `guardian` is a separate fast-response address for safety actions (core pause surfaces, registry disable-only token response, and documented emergency `setGuardian` self-rotation). `setGuardian` MUST remain owner-callable, and most rotatable surfaces in v1.0.0 also allow the current guardian emergency fast-path described in §10.2, subject to documented exceptions.

#### Deploy order

1. ClaimToken
2. VeClaimNFT
3. DexAdapter (non-upgradeable in v1.0.0)
4. EntryTokenRegistry (deploy two instances: Furnace registry, MineCore registry)
5. ShareholderRoyalties
6. Furnace
7. LpStakingVault7D
8. MarketRouter (proxy-backed runtime contract)
9. MineCore
10. GenesisLPVault24M
11. LaunchController
12. ClaimAllHelper

#### Components not part of v1.0.0

- No `GameRouter` contract is part of v1.0.0.

#### Phase B: one-time wiring (REQUIRED)

All **core-contract** wiring setters, except `setGuardian` and the documented operational allowlist setters (`MarketRouter.setSettlementKeeper`, `ShareholderRoyalties.setAutoCompoundKeeper`, `LpStakingVault7D.setHarvestKeeper`), MUST be `onlyOwner`. In production v1.0.0, the `owner()` path is controlled by the Safe-governed timelock. ClaimToken wiring is frozen and owner-renounced at the end of `Wire.s.sol`; the remaining four core game-rule wiring surfaces are permanently locked during the freeze-and-burn ceremony (see Phase C).

EntryTokenRegistry is governed separately; its setters remain `onlyOwner` (no freeze).
Production ownership MUST follow the Routing governance policy above.

- ClaimToken
  - Set MineCore as the only minter.
- VeClaimNFT
  - Set `mineMarket` to the **MarketRouter** address via `VeClaimNFT.setMineMarket(MarketRouter)` (this MUST NOT be a one-shot marketplace implementation).
  - Set Furnace as the only allowed caller of `createLockFor` / `addToLockFor`.
- EntryTokenRegistry (two instances: Furnace registry, MineCore registry)
  - Set global router config (never user-supplied):
    - `router` (**DexAdapter**, implementing the required `IAerodromeRouter` subset)
    - `factory` (router default factory, or explicitly stored)
    - `wrappedNative` (WETH on Base)
    - `claimToken` (CLAIM)
  - Set the allowlisted base hop used by multi-hop routes:
    - `WETH -> CLAIM` pool + `stable` flag
  - Configure allowlisted entry tokens (curated):
    - For each `tokenIn`, set enabled/disabled and the allowed pool(s)/stable flags used for swaps.
  - These registry instances are the governed surface for token allowlisting and allowlisted pool/hop configuration.
  - Routing execution logic is implemented by **DexAdapter** and MUST preserve the v1.0.0 routing invariants (no user-supplied routes, allowlist-only, fail-closed validation).
  - v1.0.0 DexAdapter deployment is **non-upgradeable**: no proxy upgrades.
  - Router/DEX changes require redeploying DexAdapter and calling `EntryTokenRegistry.setRouterConfig(...)` through the live owner() path (typically timelocked in production).
    - Once the global WETH/CLAIM hop or any per-token config has been set, router/factory changes MUST use a fresh registry deployment instead of changing the existing registry in place.
  - Policy split (REQUIRED, no ABI changes):
    - Furnace and MineCore each store their own EntryTokenRegistry pointer.
    - Deploy two registries:
      - Furnace registry: onboarding tokens (may include stablecoins).
      - MineCore registry: takeoverWithToken tokens (MUST start empty at genesis; `wrappedNative` (WETH) is implicit and always supported).
    - Configure both registries:
      - Configure both with the same router config.
      - Configure the WETH/CLAIM hop on any registry wired into Furnace (required).
      - The takeover-only registry may leave the WETH/CLAIM hop unset (it is not used by takeover routes).
      - The Furnace registry MUST have a live WETH/CLAIM hop configured, and its wired `MarketRouter.royalties()` MUST match `Furnace.shareholderRoyalties()`. These invariants are enforced by runtime checks (setter validation or entry-time guards), not by a freeze gate.
- ShareholderRoyalties
  - Set MineCore as the only allowed caller of `onTakeover`.
  - Set MarketRouter as the only allowed caller of `checkpointTransfer`.
  - Set Furnace address for LOCK_FURNACE.
- Furnace
  - Set ShareholderRoyalties as the only allowed caller of `lockEthReward`.
  - Set `lpRewardsVault` (LpStakingVault7D) address, used for the Furnace bonus split.
    - If unset (`address(0)`), the LP split MUST be disabled (lpRewardClaim = 0) so Furnace cannot brick.
  - Set MarketRouter, LpStakingVault7D, and MineCore as allowed callers of `enterWithClaimFor` (used by Bonus Target Order auto-fallback, LP reward compounding, and King auto-lock; now includes explicit lock destination + duration parameters).
  - Set `EntryTokenRegistry` address (never user-supplied):
    - Furnace resolves all allowlisted entry-token routes via the registry at runtime.
    - This registry MUST differ from MineCore’s registry (policy split required).

- LpStakingVault7D
  - MUST be configured to use the canonical Aerodrome WETH/CLAIM LP token used by Furnace swaps.
  - MUST accept reward donations from the following sources (no protocol fees):
    - Furnace (bonus split: `lpRewardClaim`)
    - Itself (fee harvest on staked LP)
  - If the vault restricts `notifyRewards(amountClaim)`, it MUST allowlist the above sources.
    - If `notifyRewards` is permissionless instead, it MUST account rewards by observed token balance delta (not by caller-supplied amount), to prevent fake-notify griefing.
  - MUST wire the Furnace address used by `claimRewardsAndLock(targetTokenId, durationSeconds, createAutoMax, minVeOut)`.
- MineCore + MarketRouter
  - (MarketRouter) Optionally set bonus target escrow spam controls via `setBonusTargetEscrowParams(minBudgetClaim, maxDiscountBps)`:
    - Defaults:
      - `minBonusTargetEscrowBudget = 10_000e18`
    - These minimums MUST be checked only at `createBonusTargetEscrowWithTarget(...)` time.
    - Raising minimums later affects only new escrows; existing escrows are not invalidated.
    - Governance: production policy expects multisig + timelock control of the live `owner()` path; minimums are increase-only. The separate settlement-keeper allowlist remains owner-managed via `setSettlementKeeper(address,bool)`, and the `MarketRouter` owner retains the documented break-glass ability to execute listing/offer settlement during the keeper-priority grace window.
  - (MineCore) Set `EntryTokenRegistry` address (for `takeoverWithToken` swaps).
    - This registry MUST differ from Furnace’s registry (policy split required; MUST start empty at genesis; `wrappedNative` (WETH) is implicit and always supported).
  - Set `guardian` addresses for pause surfaces and fast-response registry controls. On rotatable surfaces, `setGuardian(address)` remains an owner-controlled recovery path and also allows the current guardian emergency fast path, subject to the documented MineCore/Furnace exceptions.

#### Phase C: ClaimToken finalization + freeze-and-burn finality (required)

Five core contracts implement `bool configFrozen`, `modifier whenNotFrozen`, and `function freezeConfig() external onlyOwner`:

1. **ClaimToken** — freezes `setMineCore()` (mint authority). This happens at the end of `Wire.s.sol`, and `ClaimToken.renounceOwnership()` executes immediately afterward.
2. **Furnace** — freezes `setShareholderRoyalties()`, `setMineCore()`, `setMineMarket()`, `setFurnaceQuoter()`, and `setLpRewardsVault()`. The delayed emergency LP-vault recovery path (`requestEmergencyVaultRewire(address)`, `cancelEmergencyVaultRewire()`, `executeEmergencyVaultRewire()`) remains callable after freeze.
3. **MineCore** — freezes `setFurnace()`, `setClaimAllHelper()`, `setDelegationHub()`.
4. **VeClaimNFT** — freezes `setFurnace()`, `setMineMarket()`.
5. **ShareholderRoyalties** — freezes `setWiring()` (mineCore, mineMarket, furnace), `setClaimAllHelper()`.

Operational peripherals remain owner-configurable after freeze: `setDelegationHub`, `setEntryTokenRegistry`, `setAutoCompoundKeeper`, `setHarvestKeeper`, `setSettlementKeeper`, `setGuardian`, metadata URIs.

MarketRouter is proxy-backed (transparent proxy + ProxyAdmin) but has no wiring setters to freeze. LpStakingVault7D uses constructor-only immutables and has no wiring setters to freeze.

Finality requirements:

- `Wire.s.sol` MUST call `ClaimToken.freezeConfig()` after canonical wiring succeeds, and MUST immediately call `ClaimToken.renounceOwnership()` once frozen.
- Each remaining ceremony `freezeConfig()` MUST reject when any frozen pointer is zero.
- `ClaimToken.freezeConfig()` additionally MUST reject when `MineCore.claim() != address(this)` (reciprocal wiring validation).
- `FreezeAndBurn.s.sol` validates the full canonical bundle (all cross-contract pointers form a consistent graph including MarketRouter) before scheduling or executing the finality batch.

After ClaimToken finalization and freeze-and-burn finality:
- **Permanently disabled:** `ClaimToken.setMineCore()`, `Furnace.{setShareholderRoyalties, setMineCore, setMineMarket, setFurnaceQuoter, setLpRewardsVault}`, `MineCore.{setFurnace, setClaimAllHelper, setDelegationHub}`, `VeClaimNFT.{setFurnace, setMineMarket}`, `ShareholderRoyalties.{setWiring, setClaimAllHelper}`.
- **Still owner-configurable:** `Furnace.{setDelegationHub, setEntryTokenRegistry, requestEmergencyVaultRewire(address), cancelEmergencyVaultRewire(), executeEmergencyVaultRewire()}`, `MineCore.setEntryTokenRegistry`, EntryTokenRegistry config, keeper allowlists.
  - `Furnace.setDelegationHub` is owner-mutable post-freeze by design: the authoritative hub identity is frozen on `MineCore`, and `Furnace.setDelegationHub` validates the candidate against `MineCore.delegationHub()`.
- DexAdapter is **non-upgradeable** in v1.0.0 (scope B-07).
- The runtime quartet (`MineCore`, `Furnace`, `MarketRouter`, `ShareholderRoyalties`) is proxy-backed. `freezeConfig()` locks documented wiring setters but does not disable transparent-proxy upgrades governed through the owned proxy admins.
- Guardian pause/unpause remains functional.
- The documented operational allowlists remain owner-managed: `MarketRouter.setSettlementKeeper`, `ShareholderRoyalties.setAutoCompoundKeeper`, and `LpStakingVault7D.setHarvestKeeper`.
- No generic admin rescue/sweep functions exist in the direct roots, proxy-backed runtime, or routers/adapters, except the bounded exceptions in §10.4 (DexAdapter, MineCore, ShareholderRoyalties, GenesisLPVault24M). Accidental transfers are generally unrecoverable, except bounded LaunchController donation handling during `finalizeGenesis()` and the bounded rescue functions in §10.4.

#### Post-finalization allowed actions (MUST remain possible)

After freeze-and-burn finality and ownership finalization, the following actions MUST still be possible:

- **ADMIN (owner)**
  - Rotate `guardian` keys via `setGuardian(address newGuardian)` on all contracts, subject to per-contract exceptions: the MineCore genesis lock while the canonical LaunchController-like guardian is installed and `genesisKingClaimCollected == false`, and the requirement that `Furnace.guardian` stays pinned to `MineCore` once set (calls may only re-assert `MineCore`). A pre-existing contract owner/guardian used for split-key deployment does not by itself activate that MineCore genesis lock.
  - Manage the documented operational allowlists:
    - `MarketRouter.setSettlementKeeper(address keeper, bool allowed)`
    - `ShareholderRoyalties.setAutoCompoundKeeper(address keeper, bool allowed)`
    - `LpStakingVault7D.setHarvestKeeper(address keeper, bool allowed)`
  - No generic rescue / sweep functions exist in v1.0.0, except bounded exceptions (see §10.4).

- **GUARDIAN (long-term safety role)**
  - `MineCore.setTakeoversPaused(bool)`
  - `MarketRouter.pauseTrading(bool)`
  - `MineCore.setLockingPaused(bool)` (MineCore forwards to Furnace; single pause surface)
  - `EntryTokenRegistry.setTokenEnabled(tokenIn, false)` (disable-only; re-enables require owner)
  - During the genesis bootstrap only: if `MineCore.guardian` is the canonical LaunchController-like contract for that exact `MineCore + CLAIM` pair and `genesisKingClaimCollected == false`, that guardian may call `MineCore.collectGenesisKingClaim(address to)` exactly once via `LaunchController.finalizeGenesis()`. A pre-existing contract owner/guardian used for split-key deployment cannot call it before that canonical handoff.

- **Users / anyone**
  - `MineCore.takeover(maxPrice)`, `MineCore.takeoverWithToken(...)`, and `MineCore.withdrawKingBalance()` / `withdrawKingBalanceTo(to)`
  - `ShareholderRoyalties.flushPendingShareholderETH()`, `checkpointUser(user)`, and `claimShareholder(mode,targetTokenId,durationSeconds,createAutoMax,minVeOut)`
  - `VeClaimNFT` lock lifecycle actions (create, add, extend, merge, unlock) subject to listed rules
  - `Furnace` entry and quote functions, subject to `lockingPaused`
  - `MarketRouter` lock management actions, subject to `tradingPaused`
    - `delistLock`, `cancelExpiredListing`, `cancelBonusTargetEscrow`, `cancelExpiredBonusTargetEscrow`, and `emergencyDelist` MUST remain callable while paused (`extendBonusTargetEscrowExpiry` also reverts when paused) to unwind or clean up positions

See the roles and permissions matrix for the full per-function caller matrix.

### 1.2 Launch and liquidity bootstrap (protocol-enforced genesis)

ClaimRush starts with **supply = 0**, no premine, no treasury.

However, v1.0.0 relies on a public WETH/CLAIM market for:
- Furnace entry swaps (ETH → CLAIM → lock)
- Price discovery for takeover participants
- Organic secondary trading of CLAIM and veCLAIM NFTs

In this version, genesis liquidity is **enforced by contracts**, not by any off-protocol operator.

#### DEX and pool (locked for launch)
- Chain: **Base**
- DEX: **Aerodrome v2**
- Pool: **WETH/CLAIM vAMM** (volatile, full-range)
- Router route: `stable = false`

#### Definitions
- `T0`: the `block.timestamp` of the protocol deployment transaction on Base.
- `Genesis accrual window`: `[T0, T0 + 10 days]`.

#### Contract-enforced genesis (high level)

A dedicated one-shot controller (`LaunchController`) orchestrates genesis:

- During the genesis accrual window:
  - Takeovers are paused.
  - CLAIM emissions accrue to the protocol (not to players):
    - the **King stream** is accrued into a dedicated genesis bucket (not attributed to any reign/king) and materialized to `LaunchController` at `finalizeGenesis()`.
    - the **Furnace stream** accrues to `Furnace` reserve (as usual).
- Genesis accrual emits no `Takeover`/`ReignFinalized` events, so it is not counted in King history/leaderboards.
- After the window ends:
  - Only `LaunchController.guardian` can call `LaunchController.finalizeGenesis()` exactly once.
  - `finalizeGenesis()` must itself call `MineCore.collectGenesisKingClaim(address(this))`; MineCore rejects EOA callers and unrelated contract guardians even if they are the current guardian. Only the canonical LaunchController-like guardian for that exact `MineCore + CLAIM` pair may materialize the bucket.
  - `LaunchController` pins `router.weth()` and `router.defaultFactory()` at deployment and validates finalization against those cached roots. Later `router.defaultFactory()` drift is ignored, while `router.weth()` or `router.poolFor(..., cachedFactory)` drift aborts finalization.
  - That call materializes the genesis King-stream CLAIM bucket into `LaunchController`. `LaunchController` then seeds initial market liquidity with that minted amount, locks LP, and activates takeovers. Genesis finalization does **not** create a veCLAIM lock.

#### finalizeGenesis() (guardian-only, one-time)

`finalizeGenesis()` MUST execute as an atomic flow in a single transaction:

1) Materialize the 10d King-stream genesis bucket
- Mint/collect the 10d King-stream CLAIM amount into `LaunchController`.
- Clarification: the Furnace stream is still minted/credited by MineCore as usual; LaunchController does not materialize Furnace emissions.

2) Seed the WETH/CLAIM pool with genesis liquidity
- Use a fixed **50 ETH** seed amount.
- Add liquidity with:
  - `50 ETH` +
  - **the CLAIM materialized in step 1** (that genesis bucket only; donated/pre-existing `CLAIM` already sitting on `LaunchController` is excluded from the canonical seed and swept during finalization).

3) Lock genesis LP
- LP tokens received from seeding MUST be locked for **24 months (730 days)** in `GenesisLPVault24M`.
- LP is withdrawable only after unlock, and only to `GenesisLPVault24M.lpWithdrawRecipient`.
- `GenesisLPVault24M` MUST support `extendLock(newUnlockTime)` to extend the lock (never shorten).

4) Enable the game
- After LP is locked, the game can be activated (unpause takeovers).

Mining start rule:
- After genesis finalization, there is no active King.
- No player mines until the first takeover purchase assigns the first King.

Reference docs (normative):
- `docs/spec/launch-controller-spec-v1.0.0.md`
- [Aerodrome liquidity bootstrap appendix](../architecture/aerodrome-liquidity-bootstrap-appendix-v1.0.0.md)
- [Aerodrome integration appendix](../architecture/aerodrome-integration-appendix-v1.0.0.md)
- `docs/spec/vault-spec.md`

### 1.3 EntryTokenRegistry (external allowlist)

EntryTokenRegistry is a governed external contract that enables **allowlisted entry tokens** while preserving canonical currencies:

- Takeover accounting + payouts: **ETH only**
- Furnace output: **CLAIM only**
- Leaderboards: ETH-denominated for takeover spend and payout metrics (no per-entry-token leaderboards)

Core contracts query the registry at runtime to determine:

- whether a token is enabled
- whether `tokenIn -> CLAIM` is direct or via `tokenIn -> WETH -> CLAIM`
- which Aerodrome pools/stable flags are allowlisted per hop (validated via `router.poolFor`)

This is the only new trust surface for multi-token entry.

See: `docs/spec/entry-token-registry-v1.0.0.md`
- `docs/spec/launch-controller-spec-v1.0.0.md`
- [Aerodrome integration appendix](../architecture/aerodrome-integration-appendix-v1.0.0.md)
- [Aerodrome liquidity bootstrap appendix](../architecture/aerodrome-liquidity-bootstrap-appendix-v1.0.0.md)

## 2. Global invariants (MUST hold on-chain)

These rules are **non-negotiable** and MUST be enforced by code, not just docs.

### 2.1 Monetary & supply

- CLAIM total supply starts at `0`.
- No premine, no dev or treasury allocation.
- No protocol fees anywhere:
  - No skim on swaps.
  - No fee-on-transfer logic.
  - No hidden share / skim in marketplaces or index math.
- No treasury:
  - No dedicated contract that accumulates balances outside documented flows.
  - Any admin function MUST NOT move protocol-accounted balances (and v1.0.0 ships with no generic rescue/sweep functions; bounded exceptions are documented in §10.4).

### 2.2 Game structure

- Exactly one active King mines at any time.
- veCLAIM NFTs:
  - Non-transferable for users in strict mode. The only non-mint/non-burn transfer is `MarketRouter` moving a lock into Furnace custody (`to == furnace`).
  - No direct OTC transfers between users.
- `MarketRouter`:
  - Charges 0% protocol fee.
  - All prices denominated in CLAIM.
- Furnace is the **only** bonus system.
  - No parallel bonus curves or “second Furnace” bonus systems.
  - The protocol MUST route a defined share of the Furnace **gross** bonus to LP stakers (see §7.2.2).
    - This MUST NOT change the Furnace curve mechanics.
    - This MUST NOT make a user’s bonus depend on their LP stake.

### 2.3 Takeover & ETH flows

- Takeover price rules:
  - After each capture: `referencePrice = lastPaidPrice * 2`.
  - Price decays toward 0 over 1 hour, clamped at floor of `0.001 ETH`: `price = max(floor, referencePrice * (1 - t / decayPeriod))`.
  - Low-cost takeovers reach floor before 60 min. After 1 hour, price is fixed at the floor (cannot go lower).
  - `msg.value` is a maximum cap. MineCore MUST charge exactly the current takeover price at execution time and MUST return or credit any excess ETH (hybrid refund).
- ETH split on takeover:
  - 75% to previous King (credited to that King’s ETH balance).
  - 25% to `ShareholderRoyalties` for Barons.

### 2.4 ve model & aggregates

- Max lock duration = `365 days`.
- ve model = linear decay:
  - `ve = amount * remaining / MAX_LOCK_DURATION`.
- Global ve aggregate maintained with bias/slope model:
  - `totalVeCached` is an O(1) aggregate.
  - `checkpointGlobalState()` MUST be bounded by `MAX_SLOPE_CHANGES_PER_CALL = 250` per call.
- `flushPendingShareholderETH` is permissionless. It returns immediately when `pendingShareholderETH == 0`, but for non-zero pending ETH it MUST fail closed unless the live `Furnace / MarketRouter / MineCore / VeClaimNFT / ClaimToken` bundle still resolves to this exact `ShareholderRoyalties` root.
  - MineCore MUST auto-attempt flush immediately after each takeover allocation.
  - Canonical takeover allocations MUST be auto-attempted immediately against the current processed shareholder denominator whenever `totalVeBiasScaled() > 0`, even if that denominator rounds below `MIN_VE_FLUSH`, and MUST index as soon as `checkpointTotalVe()` advances `ve.globalLastTs()` to the current block.
  - Manual / permissionless flushes for residual pending ETH MUST return (no-op) when `totalVeBiasScaled() == 0` or when `ceilDiv(totalVeBiasScaled(), 1e18) < MIN_VE_FLUSH`.
  - Gas: `flushPendingShareholderETH()` is O(1) (no holder enumeration). When MineCore auto-attempts it in the takeover sequence, the takeover caller pays the extra gas.

### 2.5 Furnace & bonus safety

Furnace is the unified entry + bonus engine.

Locked design requirements:

- **User headline cap**:
  - The number shown to users is net user bonus.
  - `MAX_USER_BONUS_BPS = 10_000` (100% cap on user bonus).

- **Lock-% anchor**:
  - User cap is anchored to total lock% (`lockedPctBps = floor(10_000 * lockedSupply / totalSupply)`) using `LOCK_PCT_TARGET_BPS` (env-config §3.4).
  - Sign MUST be correct: more lock adoption ⇒ lower base user cap.

- **Reserve control (damp or boost) with bootstrap ramp**:
  - Reserve multiplier is centered on `RESERVE_TARGET_FINAL` and can be <1 or >1.
  - Effect ramps from 0% at launch to 100% at `SWING_TIME = 60 days`.
  - Upward boost is additionally capped at low lock adoption (see env-config §3.4.2).

- **Additive LP top-up**:
  - LP rewards are a top-up funded from the same reserve.
  - Base LP top-up rate is 7.5% → 15% of the user bonus (via `lpRateBps`), not a subtractive cut.
  - Effective LP top-up rate is additionally scaled down by the reserve factor (down-only), so it never exceeds the base curve.
  - Gross protocol spend can reach ~115% when user cap is 100% (hard clamp remains 125%).

- **AMM dynamics**:
  - Bonus payout is stateful AMM-style using `furnaceReserve` (R) and `bonusVirtualDepth` (V).
  - `BONUS_DECAY_WINDOW = 3 hours` controls recovery speed after large entries.

- **UI semantics**:
  - UI "bonus %" MUST reflect net user bonus (`userBonusBps` / `quoteUserBonusBps`).
  - UI MUST keep LP rewards separate from the net user bonus (never blended):
    - Primary UI: show “LP stakers (24h): X CLAIM” (indexer-derived rolling 24h total; includes per-entry split + overflow drip).
    - Advanced view: may show `quoteLpTopupBps` and `lpOverflowDripPerDay` as debug.

### 2.6 Pause safety and no-rescue policy

- Paused takeovers MUST NOT allow:
  - “Infinite reign” accrual of King emissions during the paused period.

- **No rescue / sweep functions in v1.0.0 (locked)**
  - v1.0.0 MUST NOT include any admin/guardian rescue or sweep functions, except the bounded exceptions listed in §10.4.
  - Contracts MUST NOT implement any generic fund-moving admin functions such as:
    - `rescue*`, `sweep*`, `recover*`, `withdrawERC20*`, `withdrawETH*` (outside documented user flows).
  - For contracts without rescue exceptions (see §10.4), any ERC20 tokens or ETH mistakenly sent to those contracts are unrecoverable in v1.0.0.
  - If you deploy with an upgrade mechanism, upgrades MUST NOT introduce rescue/sweep backdoors.

### 2.7 Gas & DoS (bounded work)

- v1 introduces a per-address veNFT ownership cap to keep onchain work bounded:
  - `MAX_VE_NFTS_PER_USER = 32` (see `src/lib/Constants.sol`; MUST match).
  - `VeClaimNFT` MUST enforce the cap on mint and on transfer (receiver-side).
  - This allows onchain callers (e.g. ShareholderRoyalties) to safely compute `veBalanceOf(user)` by iterating a bounded number of locks.
  - Multi-row lock lists are still primarily for analytics/indexers (see §11 views).

- No unbounded loops over user-controlled collections:
  - Any loop over ve locks, slope changes, listings, or bonus target escrows MUST be bounded by a constant or internal cursor (e.g. `MAX_SLOPE_CHANGES_PER_CALL`).
- Batch/list entrypoints (caller-supplied worklists):
  - Any entrypoint that iterates over a caller-supplied list MUST:
    - take an explicit caller-supplied maximum count parameter for caller control.
    - clamp the maximum count parameter (`maxItems`) to a hard `MAX_*_PER_CALL` constant.
    - iterate at most `min(list.length, maxItemsClamped)` items
  - v1.0.0 hard caps (numeric):
    - `MAX_MAINTENANCE_OFFERS_PER_CALL = 50` (MaintenanceHub.poke offer sweep)
    - `MAX_SHAREHOLDER_COMPOUND_USERS_PER_CALL = 50` (ShareholderRoyalties.compoundForMany)
    - `MAX_LP_COMPOUND_USERS_PER_CALL = 50` (LpStakingVault7D.compoundForMany)
    - `MAX_KING_REIGNS_PER_CALL = 100` (MineCore.getKingReigns)
- Ve global state:
  - `VeClaimNFT.checkpointGlobalState()` MUST:
    - Respect `MAX_SLOPE_CHANGES_PER_CALL`.
    - Never attempt to process more slope changes than this per call.
    - Remain permissionless and non-blocking (no data shape that makes it always revert).
- Takeovers:
  - The MineCore takeover sequence MUST:
    - Use a gas-guarded loop when calling `checkpointGlobalState` (stop when `gasleft()` is low or no progress is made).
    - Keep looping until ve catches up or the gas/progress stop conditions hit.
    - MUST NOT add a second fixed per-takeover iteration cap on top of `VeClaimNFT`'s per-call `MAX_SLOPE_CHANGES_PER_CALL` bound.
    - Complete King accrual and ETH splits within reasonable gas limits, even with many ve locks and slope changes.
- Furnace:
  - `enterWithEth`, `enterWithClaim`, and `lockEthReward` MUST perform only O(1) work per user call:
    - No iteration over all locks or all users.
    - Bonus calculation and lock destination routing MUST be constant-time per call.
- MarketRouter (strict mode: Furnace-only lock trading):
  - `listLock`, `delistLock`, `createBonusTargetEscrowWithTarget`, `cancelBonusTargetEscrow`, and `executeAutoFurnace` MUST:
    - Perform O(1) or strictly bounded work per call.
    - Never iterate over all listings or all escrows.
  - Listing settlement MUST:
    - Transfer the lock to Furnace custody and burn it.
    - Pay the seller CLAIM from the Furnace.
- Test suite:
  - Foundry tests and invariants MUST include gas-focused scenarios to catch:
    - Takeovers with many ve slope changes.
    - Furnace entries under heavy usage.
    - Market activity with many active listings and bonus target escrows.
  - Honest users MUST NOT be systematically DoS’d by predictable, gas-heavy scenarios.

### 2.8 Cross-contract reentrancy & CEI ordering

**Standard (locked):** use `ReentrancyGuard` and follow CEI in all functions that send ETH, move CLAIM, transfer veNFTs, or call other core contracts.

Required ordering:
- MineCore.takeover:
  - update reign/accounting state before external ETH sends
  - failed sends credit withdrawable balances (withdraw pattern)
- ShareholderRoyalties.claimShareholder:
  - checkpoint + zero claimableEth before ETH send or Furnace call
  - LOCK_FURNACE bubbles reverts so claimableEth is not lost
- Furnace entry:
  - compute swap + bonus, update reserve/accounting, then route to lock
  - enforce `minVeOut` on the entry-attributable `veOut` (covers only the newly locked amount at the lock's remaining duration)
- MarketRouter (lock management router — strict mode: Furnace-only):
  - Listing settlement MUST follow this ordering:
    1. Read the listing and require it is active and not expired.
    2. No approval-revoked shortcut exists in strict mode; settlement proceeds directly to keeper-grace auth and live-quote checks.
    3. For approved listings, enforce the keeper-priority grace auth.
    4. Verify the live Furnace quote can meet the stored `minClaimOut` floor.
    5. Clear MarketRouter listing state and clear `VeClaimNFT.setListed(tokenId, false)` before transfer so the router can legally move the lock into Furnace custody.
    6. Call `ShareholderRoyalties.checkpointTransfer(seller, furnace)` before ownership transfer so seller royalty accounting is flushed before the seller loses the lock.
    7. Transfer the veNFT to Furnace custody.
    8. Let Furnace perform the sellback execution, burn or withdraw the lock, pay the seller, and credit reserve / LP sale accounting.
    9. Emit `ListingSettled(tokenId, seller, claimOut, penalty)` where `penalty = lockAmount - claimOut`.
  - `executeAutoFurnace` MUST follow this ordering:
    1. Verify the live Furnace quote can meet the stored `targetBonusBps` for the remaining budget.
    2. Close the escrow (CEI) and set `fundsRemaining = 0` before external calls.
    3. Route the escrowed CLAIM into the Furnace via `Furnace.enterWithClaimFor`.
    4. Emit `BonusTargetEscrowExecuted` and the backwards-compatible mirror `BonusTargetEscrowAutoFurnaceExecuted`.
  - In all sell-to-Furnace flows, `ShareholderRoyalties.checkpointTransfer(seller, furnace)` MUST occur before ownership transfer. Clearing the `listed` flag first is acceptable because it is only a mutation guard, not a shareholder balance change.
- ClaimAllHelper:
  - atomic orchestration, bubbles reverts

---

## 3. ClaimToken

**Type**: ERC20 CLAIM implementation.

### 3.1 Behavior

- Name: `ClaimRush`
- Symbol: `CLAIM`
- Decimals: `18`
- Total supply at deployment: `0`.
- Minting according to the emission schedule MUST be performed only by MineCore (MineCore mints the King stream to the King and the Furnace stream to the Furnace).
- No fees, rebasing, or reflection.

### 3.2 Required functions

- Standard ERC20 interface.
- `mint(address to, uint256 amount)` – callable only by MineCore.
- `burn(uint256 amount)` (true burn, reduces total supply):
  - Available for voluntary burns intended to be true supply reduction.
  - MUST burn from `msg.sender` and reduce total supply.
- `setMineCore(address mineCore)` for the MineCore pointer:
  - MUST reject zero or non-contract `mineCore`.
  - MUST fail closed at setter time unless the candidate MineCore already reports `claim() == address(this)`; otherwise a foreign MineCore would become the live CLAIM minter immediately.
  - MUST be disabled after `ClaimToken.freezeConfig()`.
- `freezeConfig()` for the MineCore pointer:
  - MUST reject zero or non-contract `mineCore`.
  - MUST verify reciprocal wiring before freezing: `MineCore.claim() == address(this)`.

- `burnFrom(address account, uint256 amount)` is not part of v1.0.0 (MUST NOT exist).
  - Implementers MUST NOT inherit `ERC20Burnable` or any surface that exposes `burnFrom`.

### 3.3 Invariants

- `totalSupply` equals sum of all balances.
- No function other than authorized minting can increase supply.
- No function other than explicit burn (if present) can decrease supply.

---

## 4. VeClaimNFT (veCLAIM)

**Type**: ERC721 representing ve-lock positions.

### 4.1 Lock model

Each position (tokenId) stores at least:

- `amount` – CLAIM principal locked (18 decimals).
- `lockStart` – timestamp when lock was last updated.
- `lockEnd` – stored unlock timestamp used when `autoMax == false`.
  - When `autoMax == true`, the lock is treated as continuously extended to the maximum duration.
  - User-facing reads and eligibility checks MUST use an **effective end**:
    - `effectiveLockEnd(now) = (autoMax ? (now + MAX_LOCK_DURATION) : lockEnd)`.
- `autoMax` – an automatic “keep me at max ve forever” switch:
  - While `autoMax == true`, ve MUST NOT decay (ve stays at the max-weight value).
  - A lock MUST NOT be treated as expired while `autoMax == true`.
- `listed` flag – to coordinate with MarketRouter.

Constraints:

- `MAX_LOCK_DURATION = 365 days`.
- `MIN_LOCK_AMOUNT = 1_000e18` CLAIM (1,000 CLAIM).
  - Applies to **minting only**: `createLock` / `createLockFor` MUST revert unless `amount >= MIN_LOCK_AMOUNT`.
- Hard bound (always):
  - For non-AutoMax locks (`autoMax == false`): at any time, `block.timestamp < lockEnd <= block.timestamp + MAX_LOCK_DURATION` for any non-expired lock.
  - For AutoMax locks (`autoMax == true`): `effectiveLockEnd(now) = block.timestamp + MAX_LOCK_DURATION` (so remaining time is always `MAX_LOCK_DURATION`).

Creation (mint) constraints (v1.0.0 enforcement):

Both mint entrypoints MUST enforce the same creation rules:

- `amount >= MIN_LOCK_AMOUNT`
- `MIN_LOCK_DURATION <= duration <= MAX_LOCK_DURATION`
- AutoMax validation (MUST):
  - If `autoMax == true`, MUST require `duration == MAX_LOCK_DURATION`.
  - If `duration < MAX_LOCK_DURATION`, MUST require `autoMax == false`.
  - At `duration == MAX_LOCK_DURATION`, `autoMax` is an explicit opt-in at creation time (both true and false are allowed).

Entry-point:

- `createLockFor` is Furnace-only and mints to an explicit `user` (so Furnace can route locks for recipients without ERC721 approvals). There is no user-facing direct lock creation path; all lock minting flows through the Furnace.

Clarification:
- These rules are about **creation (mint)**. Existing lock lifecycle functions (e.g. `setAutoMax`) and the Furnace-routed merge surface (`Furnace.mergeLocksWithBonus[For]`) remain valid unless otherwise specified.

Per-user veNFT count cap (v1.0.0+):

- v1 enforces a per-address cap on how many veCLAIM NFTs an address may own at once:
  - `MAX_VE_NFTS_PER_USER = 32` (see `src/lib/Constants.sol`; MUST match).
- Cap enforcement (MUST):
  - `createLock` / `createLockFor` MUST revert if minting would cause `balanceOf(user) > MAX_VE_NFTS_PER_USER`.
  - veCLAIM transfers (via MarketRouter; mint/burn excluded) MUST revert if the receiver would exceed the cap.
- Rationale:
  - Makes `veBalanceOf(user)` safe to call onchain (bounded iteration), enabling ShareholderRoyalties checkpointing, Market checkpointTransfer, and keeper batches.
- UX guidance (non-binding):
  - Users can consolidate by calling `Furnace.mergeLocksWithBonus(fromTokenId, intoTokenId, minBonusOut)`. Principal is preserved (`fromAmount + intoAmount` is moved into the surviving lock), `lockEnd` becomes the max, and an extension-style bonus is paid on the duration delta when one lock is shorter than the other.

ve (linear decay):

- `remaining(t) = autoMax ? MAX_LOCK_DURATION : (lockEnd > t ? (lockEnd - t) : 0)`.
- `veOf(tokenId, t) = amount * remaining(t) / MAX_LOCK_DURATION`.

Rounding / precision (MUST):

- ve uses the same 18-decimal scale as `amount`.
- ve computations MUST round **DOWN** (floor).
  - Implement with a single mulDiv: `ve = mulDivDown(amount, remaining, MAX_LOCK_DURATION)`.
  - Do **not** compute `slope = amount / MAX` then `slope * remaining` (double-floor).
- Per-user ve view:
  - `veBalanceOf(user)` MUST equal the sum over locks owned by `user` of `veOf(tokenId, now)`, rounding each lock DOWN.
- **Safety requirement:** global aggregates used as denominators (e.g. `totalVeCached`) MUST be conservative:
  - After checkpointing, `totalVeCached` MUST be >= the sum of user `veBalanceOf(user)` returned at the same timestamp.
  - Achieve this by rounding **UP** (ceiling) in any division inside global slope/bias math.

### 4.2 Core functions

VeClaimNFT MUST support the full lock lifecycle (owner-controlled) and the protocol routing hooks used by Furnace.

**User-facing lifecycle (token owner only)**

- `setAutoMax(uint256 tokenId, bool enabled)`
- `unlock(uint256 tokenId)` (only after expiry)
- Merging locks: see `Furnace.mergeLocksWithBonus(fromTokenId, intoTokenId, minBonusOut)` (§5). v1.0.0 removes the raw `VeClaimNFT.mergeLocks` entry point and routes all merges through Furnace so the bonus engine and reserve accounting are reused.

**Protocol routing helpers (Furnace-only)**

These exist so Furnace can route deposits into a user’s lock without relying on ERC721 approvals.

- `createLockFor(address user, uint256 amount, uint256 duration, bool autoMax)` → returns `tokenId`
- `addToLockFor(address user, uint256 tokenId, uint256 amount)`
- `extendLockToFor(address user, uint256 tokenId, uint256 newEnd)`
- `mergeLocksFor(address user, uint256 fromTokenId, uint256 intoTokenId)` (Furnace-only sibling backing `Furnace.mergeLocksWithBonus[For]`)

Access control (MUST):

- VeClaimNFT MUST store the authorized Furnace address (`furnace`) and MUST reject helper calls unless the caller is that Furnace and the live Furnace/MineCore/ClaimToken surfaces still agree on one canonical bundle, plus `MarketRouter` / `ShareholderRoyalties` when those modules are already wired.
- The delegated ve-maintenance wrapper `unlockExpiredForUser` MUST resolve the canonical `DelegationHub` through that same live Furnace/MarketRouter/MineCore bundle and MUST reject split-brain `MineCore.furnace() != Furnace` wiring before trusting session bits. Merge delegation is enforced at `Furnace.mergeLocksWithBonusFor` (which inherits the same canonical-binding gate).
- The Furnace address MUST be configured during Phase B wiring via `setFurnace(address furnace)` (`onlyOwner`).
- Wiring setters on VeClaimNFT (`setFurnace`, `setMineMarket`) are `onlyOwner whenNotFrozen` and are protected by the production timelock + multisig. `VeClaimNFT.freezeConfig()` permanently locks both `setFurnace` and `setMineMarket` once called; only metadata setters (`setBaseURI`, `setContractURI`) remain owner-configurable after freeze.
- Runtime and setter-time canonical-bundle validation still applies: the live `Furnace`, `MarketRouter`, `ShareholderRoyalties`, `MineCore`, and `ClaimToken` MUST form one canonical bundle. At minimum:
  - `Furnace.shareholderRoyalties() == MarketRouter.royalties()`
  - `ShareholderRoyalties.{ve,furnace,mineMarket,mineCore}` match the live Ve/Furnace/MarketRouter/MineCore addresses
  - `MineCore.{ve,claim,furnace,royalties}` match the same bundle
  - `ClaimToken.mineCore() == MineCore`

Implementation note (MUST):

- `createLock` and `createLockFor` MUST share the same internal `_createLock(payer, user, amount, duration, autoMax)` path for the shared state updates (minting, accounting, CLAIM pull, `lockEnd` computation).
- Entry-point validation MUST be enforced at the public function boundary:
  - Both entrypoints enforce the shared duration bounds and AutoMax rules from §4.1.
  - `createLockFor` MUST additionally enforce canonical-Furnace authorization (not just a raw stored address equality).

**Marketplace coordination (MarketRouter-only)**

- `setListed(uint256 tokenId, bool listed)` (called on list/delist/buy)

> VeClaimNFT has no guardian in v1.0.0; emergency pause is handled at the MineCore/Furnace level.

---

#### 4.2.1 Shared preconditions (mutations)

These shared preconditions apply to **user-facing lifecycle mutations** and the Furnace helpers `addToLockFor` and `extendLockToFor`.
They do **not** apply to marketplace coordination (`setListed`) .

For any user-facing lifecycle mutation that targets an existing `tokenId` (all except `createLock` / `createLockFor`):

- `tokenId` MUST exist.
- `ownerOf(tokenId)` MUST be the lock owner used by the call:
  - User-facing mutations: `msg.sender` MUST be the owner.
  - Furnace helper `addToLockFor`: `ownerOf(tokenId)` MUST equal the passed `user`.
- The lock MUST NOT be `listed`.
- The lock MUST NOT be expired, except `unlock`.
  - Expiry is defined as: `autoMax == false && block.timestamp >= lockEnd`.
  - AutoMax locks (`autoMax == true`) MUST be treated as non-expired for these checks.

Exceptions / coordination functions:

- `setListed(tokenId, true)` is called only by MarketRouter and MUST require the lock is eligible to list (see §4.2.3).
- `setListed(tokenId, false)` is called only by MarketRouter and MUST be allowed even when the lock is currently listed or expired.
- This enables a seller to delist and then unlock.

---

#### 4.2.2 State update rules

- `totalLockedClaim()` MUST track the sum of principals across all live locks.
- `totalLockedClaim()` is the canonical locked-supply source. The raw CLAIM balance of VeClaimNFT MAY be higher due to direct token transfers (donations) and MUST NOT be used for economic calculations.
- Any successful mutation that changes principal or `lockEnd` MUST:
  - For non-AutoMax locks (`autoMax == false`): update the per-lock bias/slope schedule.
  - For AutoMax locks (`autoMax == true`): treat the lock as **constant max ve** (zero slope) and do NOT schedule slope changes.
  - Update the global aggregates so `totalVeCached()` becomes correct after `checkpointTotalVe()`.
  - Set `lockStart = block.timestamp`.

---

#### 4.2.3 Semantics (per function)

**`createLockFor` (Furnace-only mint path)**

- Callable only by the canonically wired Furnace (fail closed if the live Furnace/MineCore/ClaimToken bundle has drifted, plus `MarketRouter` / `ShareholderRoyalties` when those modules are already wired).
- Require `amount >= MIN_LOCK_AMOUNT`.
- Require `MIN_LOCK_DURATION <= duration <= MAX_LOCK_DURATION`.
- AutoMax validation (MUST):
  - If `autoMax == true`, MUST require `duration == MAX_LOCK_DURATION` (else revert).
  - If `duration < MAX_LOCK_DURATION`, MUST require `autoMax == false`.
- Compute `lockEnd`:
  - If `autoMax == true`: `lockEnd = block.timestamp + MAX_LOCK_DURATION` (ignore `duration`).
  - Else: `lockEnd = block.timestamp + duration`.
- Mint veNFT to `user`.
- Initialize `listed = false`, `autoMax = autoMax`.
- Increase `totalLockedClaim` by `amount`.
- Emit `LockCreated(user, tokenId, amount, lockEnd, autoMax)`.

Clarification:
- At `duration == MAX_LOCK_DURATION`, `autoMax` is an explicit opt-in at creation time (UI checkbox default = off).
- `createLockFor` exists only so Furnace can mint locks for a recipient without relying on ERC721 approvals.

**`addToLock` / `addToLockFor`**

- Require `amount >= MIN_TOPUP_AMOUNT` (env-config §3.1B). The floor bounds slope-rounding dust per top-up.
- Increase principal by `amount`.
- For non-AutoMax locks (`autoMax == false`), MUST NOT change `lockEnd`.
- For AutoMax locks (`autoMax == true`), implementations MAY refresh the stored `lockEnd` to `block.timestamp + MAX_LOCK_DURATION` for metadata parity.
  - This MUST NOT change the economic outcome, since AutoMax ve does not decay.
- Increase `totalLockedClaim` by `amount`.
- Emit `LockAmountIncreased(user, tokenId, amount)`.

**`extendLockToFor(address user, uint256 tokenId, uint256 newEnd)` (Furnace-only)**

- Callable only by the canonically wired Furnace (fail closed if the live Furnace/MineCore/ClaimToken bundle has drifted, plus `MarketRouter` / `ShareholderRoyalties` when those modules are already wired).
- MUST enforce the shared mutation preconditions in §4.2.1 (owner MUST equal `user`, not listed, not expired).
- Let `oldEnd = lockEnd[tokenId]`.
- Require `newEnd <= block.timestamp + MAX_LOCK_DURATION`.
- For non-AutoMax locks:
  - Require `newEnd > oldEnd`.
  - Set `lockEnd[tokenId] = newEnd`.
- For AutoMax locks:
  - The effective end MUST be `block.timestamp + MAX_LOCK_DURATION` (ignore the passed `newEnd`).
  - MUST NOT require `newEnd > oldEnd`.
  - Set `lockEnd[tokenId] = block.timestamp + MAX_LOCK_DURATION`.
- Emit `LockExtended(user, tokenId, oldEnd, lockEnd[tokenId])`.

**`Furnace.mergeLocksWithBonus(fromTokenId, intoTokenId, minBonusOut)`** (and `mergeLocksWithBonusFor` delegated sibling)

The user-facing merge surface lives on Furnace in v1.0.0. Internally Furnace
delegates to `VeClaimNFT.mergeLocksFor` (Furnace-only sibling of `extendLockToFor`).

Pre-validation (`FurnaceGuardHelper.resolveMergeWithBonus`):

- Require `fromTokenId != intoTokenId`.
- Require both locks exist and have the same owner (`user`).
- Both locks MUST NOT be listed and MUST NOT be expired.
- AutoMax mismatch is intentionally **NOT** a revert path. Mixed
  AutoMax / non-AutoMax pairs are accepted; the survivor follows the OR-rule
  (`newAutoMax = fromAutoMax || intoAutoMax`) implemented in
  `_mergeLocksInternal`. The bonus is computed on the non-AutoMax side at full
  `BPS_AT_MAX` weight delta because `_resolveLockForMerge` maps an AutoMax
  side's `remaining` to `MAX_LOCK_DURATION`. AutoMax is reversible
  (`setAutoMax(tokenId, false)` after the merge), so there is no perpetual
  lock-in. `Errors.AutoMaxMismatch` itself stays as an error symbol — it is
  used by `MarketRouter._validateEligibleDestinationLock` (sellback target
  consistency) and `MineCore._setKingAutoLockConfig` (King auto-lock target
  consistency); neither of those is the merge case.

Merge state transition (executed by VeClaimNFT under Furnace's authority):

- Let `amountMoved = amount[fromTokenId]`.
- Move state into `intoTokenId`:
  - `amount[intoTokenId] += amountMoved`
  - `autoMax[intoTokenId] = autoMax[fromTokenId] || autoMax[intoTokenId]`
    (OR-rule survivor; mixed pairs are valid).
  - If the resulting lock is AutoMax: `lockEnd[intoTokenId] = block.timestamp + MAX_LOCK_DURATION`.
  - Else (non-AutoMax): `lockEnd[intoTokenId] = max(lockEnd[intoTokenId], lockEnd[fromTokenId])`.
- Burn `fromTokenId`.
- `totalLockedClaim` MUST remain unchanged at this step (principal is moved).
- Emit `LockMerged(owner, fromTokenId, intoTokenId, amountMoved)`.

Bonus payout (Furnace, identical AMM to `extendWithBonus`):

- `durationDelta = longer.remaining - shorter.remaining`. If `durationDelta == 0`
  (both sides equal duration, including the both-AutoMax case where each maps
  to `MAX_LOCK_DURATION`), no bonus is paid and the entire bonus block is
  skipped.
- For mixed AutoMax pairs the AutoMax side is the "longer" side (its remaining
  is `MAX_LOCK_DURATION`), so the bonus is paid on the non-AutoMax side's
  principal at `weightDelta(MAX_LOCK_DURATION, nonAutoMaxRemaining)` from the
  sub-bp duration-weight curve (env-config §3.4D).
- `principalEff = Math.mulDiv(shorter.amount, weightDelta(longer.remaining, shorter.remaining), WEIGHT_DENOM)`.
- `(grossBonus, userBonus, lpBonus) = _applyBonusAmm(user, shorter.amount, principalEff, durationDelta)`.
- `userBonus` is added to the surviving lock via `addToLockFor` (no transfer to the user; never rebases `lockEnd`).
- Slippage gate: revert if `userBonus < minBonusOut`. Pass `minBonusOut = 0` to disable.
- Reserve accounting is synchronized through the standard `_syncFurnaceReserve` path so the post-merge `furnaceReserve` mirrors the on-chain CLAIM balance.

Emit `Events.FurnaceMergeWithBonus(user, fromTokenId, intoTokenId, fromAmount, intoAmount, newPrincipal, newEnd, newAutoMax, durationDelta, bonusClaim)`.
`LockMerged` is the ve-side state-transition event for VeClaimNFT-level subgraph parity
and does not surface the bonus; downstream indexers MUST consume `FurnaceMergeWithBonus`
for full economic context.

**`setAutoMax(tokenId, enabled)`**

- Owner-only.
- If enabling:
  - Set `autoMax[tokenId] = true`.
  - Set `lockEnd[tokenId] = block.timestamp + MAX_LOCK_DURATION`.
  - ve MUST immediately become max-weight and then remain non-decaying.
- If disabling:
  - Set `autoMax[tokenId] = false`.
  - Set `lockEnd[tokenId] = block.timestamp + MAX_LOCK_DURATION`.
    - This models “stop auto-extending now”: ve remains continuous at toggle time, and then begins to decay.

**`unlock(tokenId)`**

- Owner-only.
- MUST revert while `autoMax[tokenId] == true`.
- Require `block.timestamp >= lockEnd[tokenId]`.
- Require NOT listed.
- Let `owner = msg.sender`.
- Let `amountReturned = amount[tokenId]` (principal).
- Decrease `totalLockedClaim` by `amountReturned`.
- Burn the veNFT, then transfer `amountReturned` CLAIM to `owner`.
- Emit `LockUnlocked(owner, tokenId, amountReturned)`.

**`setListed(uint256 tokenId, bool listed)`**

- Callable only by MarketRouter.
- Purpose: coordination flag so VeClaimNFT can enforce mutation bans while a lock is listed on MarketRouter.
- If `listed == true` (listing):
  - MUST require the lock exists.
  - MUST require the lock is NOT expired.
    - Expiry is defined as: `autoMax == false && block.timestamp >= lockEnd`.
  - MUST require the lock is not already listed (idempotent false→true only).
  - Set `listed = true`.
- If `listed == false` (delist / sale finalization):
  - MUST require the lock exists.
  - MUST be callable even if the lock is currently listed or expired.
  - This enables sellers to delist then unlock.
  - Set `listed = false`.

### 4.3 Aggregates & checkpointing

Global state:

- `totalLockedClaim()` – sum of principals across all active locks.
- `totalVeCached()` – global ve amount from bias/slope model.
- `checkpointGlobalState()` – applies pending slope changes, bounded by `MAX_SLOPE_CHANGES_PER_CALL`.
- `checkpointTotalVe()` – updates `totalVeCached` (permissionless; `checkpointGlobalState()` already syncs `totalVeCached` internally, so MineCore.takeover does not call this separately).

Rules:

- `checkpointGlobalState()` MUST be permissionless.
- MineCore.takeover MUST call `checkpointGlobalState()` in a gas-guarded loop before finalizing a reign. Each `checkpointGlobalState()` call is bounded by `MAX_SLOPE_CHANGES_PER_CALL`; the outer MineCore loop MUST keep advancing until ve catches up or the gas/progress stop conditions hit. A separate `checkpointTotalVe()` call is not required because `checkpointGlobalState()` already syncs `totalVeCached`.

Precision rules for global checkpointing (MUST):

- Any **division** performed while updating **global aggregates** MUST round **UP** (ceiling) so aggregates are not underestimated.
- Any `mulDiv` MUST use 512-bit intermediate math (avoid overflow).
- When applying time decay, subtract the decay amount rounded **DOWN** (so the remaining bias is conservative-high).
- Use signed math for intermediate `(bias - decay)` and clamp at 0 (never underflow).

One acceptable fixed-point representation (recommended):

- `SLOPE_SCALE = 1e18`.
- When a lock is created/updated:
  - `slopeScaled = ceilDiv(amount * SLOPE_SCALE, MAX_LOCK_DURATION)`.
  - `bias = ceilDiv(slopeScaled * remaining(now), SLOPE_SCALE)`.
- When decaying a bias over `dt` seconds:
  - `decay = mulDivDown(slopeScaled, dt, SLOPE_SCALE)`.
  - `bias = bias > decay ? (bias - decay) : 0`.

### 4.4 Lock destination (explicit routing)

v1.0.0 uses **explicit lock destinations** for all Furnace-style “lock CLAIM into veCLAIM” flows.

There is **no onchain active-lock pointer system** in this model.

Any protocol entry that locks CLAIM on behalf of a user MUST accept:

- `targetTokenId` (0 = create a new lock)
- `durationSeconds` (selected duration, clamped to **7 days .. 365 days**)
- `createAutoMax` (only meaningful when creating a new lock at `MAX_LOCK_DURATION`)

Rules (MUST):

- If `targetTokenId == 0`:
  - Create a new lock for the user via:
    - `createLockFor(user, amount, durationSeconds, autoMax=createAutoMax)`.
    - `amount` MUST satisfy `amount >= MIN_LOCK_AMOUNT` (else revert).
  - `createAutoMax` MUST be `false` unless `durationSeconds == MAX_LOCK_DURATION`.

- If `targetTokenId != 0`:
  - The lock MUST be eligible for mutation (owner = user, not listed, not expired).
  - For existing **non-AutoMax** locks: if remaining time is less than `MIN_LOCK_DURATION` (7 days), entry MUST revert with `InvalidDuration`. This prevents bonus extraction via near-expiry locks.
  - For non-AutoMax locks (remaining `>= MIN_LOCK_DURATION`): `durationSeconds` is clamped to the lock's current remaining duration. The entry path does not extend the lock's duration; only `Furnace.extendWithBonus` can extend duration.
  - For AutoMax locks: `durationSeconds` MUST equal `MAX_LOCK_DURATION` (UI locks the slider).
  - Add to the lock via `addToLockFor(user, targetTokenId, amount)`.

Quote view rule (MUST):

- Any quote that returns `veOut` MUST return only the ve attributable to the newly locked amount at the resulting remaining duration.

### 4.5 Transfer restrictions

- `transferFrom` / `safeTransferFrom` MUST revert unless:
  - Mint (from 0 address).
  - Burn (to 0 address).
  - Caller is MarketRouter (the configured `mineMarket`) **and** the transfer moves the NFT into Furnace custody (`to == furnace`).
    - VeClaimNFT MUST fail closed unless the live `mineMarket`, `furnace`, `MineCore`, `ClaimToken`, and (when wired) `ShareholderRoyalties` surfaces still point at the same canonical bundle.
    - Listed locks MUST be delisted before transfer.

Notes (locked for v1.0.0):
- Adapters are not supported in v1.0.0; any adapter support requires a spec bump.
- Strict mode: there are no user↔user transfers. MarketRouter is the only supported transfer gateway and it may only transfer locks into Furnace custody for settlement/sellback.

---

## 5. MineCore

**Type**: main game engine (reigns, emissions, takeovers).

### 5.1 State

Key state:

- `address currentKing`
- `currentKing` is a plain `address` and may be an EOA or a contract (e.g., a smart account); no EOA-only assumptions.
- `uint256 currentReignId`
- `uint256 currentReignStartTime`
- `uint256 currentReignLastAccrualTime` (required for emissions math)
- `uint256 referencePrice` – basis for takeover doubling rule.
- `bool takeoversPaused`
- Any tracking needed for King balances and reign info.

### 5.2 Emissions

At launch:

- King stream: `50 CLAIM/sec`.
- Furnace stream: `5 CLAIM/sec`.
- Emissions decay linearly over `EMISSION_DECAY_PERIOD = 63_072_000 seconds` (2 years) down to floors:
  - King floor: `50/9 CLAIM/sec` (≈ 5.555).
  - Furnace floor: `5/9 CLAIM/sec` (≈ 0.555).

Implementation outline (conceptual):

```solidity
function kingEmissionRate(uint256 t) public view returns (uint256);
function furnaceEmissionRate(uint256 t) public view returns (uint256);
```

- `t` is time since emission start.
- Each function returns the per-second rate, clamped to its floor.

MineCore is responsible for minting CLAIM according to these schedules and sending to:

- King’s CLAIM balance (mint directly to the reigning King address).
- Furnace reserve funding (emission stream):
  - MineCore MUST mint the Furnace stream to the `Furnace` contract address.
  - MineCore MUST then call `Furnace.creditReserve(furnaceMined)` to increment `furnaceReserve` by the exact minted amount.
  - Direct transfers to `Furnace` MUST NOT be treated as reserve funding.

### 5.3 Takeover price

Let:

- `referencePrice` – last price used for doubling, updated after each takeover.
- `floor = 0.001 ether`.
- `TAKEOVER_DECAY_PERIOD = 1 hours`.
- `t` – time since last takeover (or since emission start for first reign).

Price function:

- At `t = 0`:
  - `price = referencePrice` (or `floor` on first ever takeover).
- For `0 < t < TAKEOVER_DECAY_PERIOD`:
  - `price = max(floor, referencePrice * (1 - t / TAKEOVER_DECAY_PERIOD))`
  - Decay is toward 0, clamped at floor (not toward floor directly).
  - Low-cost takeovers reach floor before 60 min.
- For `t >= TAKEOVER_DECAY_PERIOD`:
  - `price = floor`.

After a successful takeover paying `paid`, set:

- `referencePrice = paid * 2`.

Required view helpers:

- `getTakeoverPrice(uint256 timestamp) external view returns (uint256 price)`
  - Returns the takeover price **that would be required at** `timestamp`.
  - If no takeover has ever happened (`currentKing == address(0)`), return `floor`.
  - Otherwise:
    - Let `t = timestamp <= currentReignStartTime ? 0 : (timestamp - currentReignStartTime)`.
    - If `t >= TAKEOVER_DECAY_PERIOD`, return `floor`.
    - Else return `max(floor, referencePrice - referencePrice * t / TAKEOVER_DECAY_PERIOD)`.
  - MUST clamp to `floor` (never below).

- `getCurrentTakeoverPrice() external view returns (uint256 price)`
  - Equivalent to `getTakeoverPrice(block.timestamp)`.

### 5.4 Takeover function

Both `takeover(uint256 maxPrice)` and `takeoverWithToken(address tokenIn, uint256 amountIn, uint256 minEthOut, uint256 maxPrice)` execute a King handoff and finalize the previous reign. They MUST be deterministic and follow the exact sequence below.

### 5.4.1 Preconditions

MineCore exposes two public entrypoints that both produce an ETH-denominated `pricePaid`:

- For `takeover(uint256 maxPrice)` (payable)
  - ETH entry path.
  - Caller supplies `msg.value` as `maxPriceEth` (maximum cap).
  - MineCore MUST revert `PriceExceeded` if `getCurrentTakeoverPrice() > maxPrice`.
  - MineCore computes `price = getCurrentTakeoverPrice()` and MUST enforce `price <= maxPriceEth`.
  - MineCore sets `pricePaid = price`.
  - Excess `maxPriceEth - pricePaid` is refundable (hybrid refund).

- For `takeoverWithToken(address tokenIn, uint256 amountIn, uint256 minEthOut, uint256 maxPrice)`
  - Allowlisted token entry path.
  - Pulls `amountIn` of `tokenIn` from the caller, swaps `tokenIn -> WETH -> unwrap -> ETH`, and sets:
    - `ethOut` (post-swap ETH)
  - MUST enforce `ethOut >= minEthOut` (user slippage guard).
  - Routing is fixed and resolved via `EntryTokenRegistry` (no user-supplied paths/pools/stable flags).
  - **WETH special-case (REQUIRED):** if `tokenIn == wrappedNative` (WETH), MineCore MUST bypass registry route resolution,
    pull `amountIn` WETH, unwrap 1:1 to ETH, set `ethOut = amountIn`, and still enforce `ethOut >= minEthOut`.
  - MineCore MUST revert `PriceExceeded` if `getCurrentTakeoverPrice() > maxPrice`.
  - MineCore computes `price = getCurrentTakeoverPrice()` and MUST enforce `ethOut >= price`.
  - MineCore sets `pricePaid = price`.
  - Excess `ethOut - pricePaid` is refundable (hybrid refund).

Shared preconditions:

- `require(!takeoversPaused)`.
- `require(msg.sender != currentKing)`. The current King cannot takeover again; MUST be dethroned before retaking.
- Takeover payments are max-capped: MineCore MUST charge exactly `price = getCurrentTakeoverPrice()` and MUST return/credit any excess ETH (hybrid refund). Refund failure MUST NOT revert takeover.

### 5.4.2 Deterministic takeover sequence (MUST follow)

Let:

- `prevKing = currentKing`
- `prevReignId = currentReignId`
- `nowTs = block.timestamp`
- `price = getCurrentTakeoverPrice()`
- `creditedEth` – ETH available to fund the takeover:
  - For `takeover(maxPrice)`: `msg.value` (maxPriceEth cap)
  - For `takeoverWithToken(...)`: `ethOut` (post-swap ETH)

1. **Checkpoint ve global state (bounded)**
   - MineCore MUST ensure `totalVeCached` is fresh before finalizing the prior reign.
   - Run bounded global checkpointing:
     - `veClaimNFT.checkpointGlobalState()` MUST enforce a hard cap of `MAX_SLOPE_CHANGES_PER_CALL` slope-change iterations per call.
     - A separate `veClaimNFT.checkpointTotalVe()` call is not required (`checkpointGlobalState()` already syncs `totalVeCached`).

2. **Validate price**
   - `require(creditedEth >= price)`.
   - Set `pricePaid = price` (the charged takeover price).
   - Set `newReferencePrice = pricePaid * 2`.
   - Define `refundEth = creditedEth - pricePaid` (if positive) and refund/credit it via hybrid refund.

3. **Accrue emissions since last accrual cursor**
   - Let `accrualStart = currentReignLastAccrualTime` and `accrualEnd = nowTs`.
   - Paused time MUST NOT be included in this interval (see §5.6).
   - Mint emissions for `[accrualStart, accrualEnd)` using the integral method in §5.4.3:
     - If `prevKing != address(0)`: accrue the King-stream amount for `prevKing` (amount is
       computed here; the actual mint is deferred to step 4 finalization, which routes it
       through either `Furnace.enterWithClaimFor` for auto-lock, direct transfer, or a
       pull-payment credit depending on the dethroned king's auto-lock configuration).
     - Always: MineCore mints the Furnace stream to `Furnace` and MUST call `Furnace.creditReserve(furnaceMined)` to credit it into `furnaceReserve`.

4. **Finalize previous reign (if any)**
   - If `prevKing != address(0)`:
     - Snapshot `totalVeForReign[prevReignId] = veClaimNFT.totalVeCached()` (post-checkpoint).
     - Set `reignEndTime[prevReignId] = nowTs`.
     - Compute ETH split:
       - `kingShare = pricePaid * 75 / 100`.
       - `shareholderShare = pricePaid - kingShare`.
     - Resolve routing recipients for the previous reign:
       - `prevEthRecipient = reignEthRecipient[prevReignId]`, falling back to `prevKing` when unset (default / direct takeover).
       - `prevClaimRecipient = reignClaimRecipient[prevReignId]`, falling back to `prevKing` when unset.
     - Pay King ETH to `prevEthRecipient` (best-effort push with pull-based fallback):
       - Attempt to push `kingShare` ETH to `prevEthRecipient` with a bounded gas stipend.
       - If the push fails, credit `kingEthBalance[prevEthRecipient] += kingShare` (the withdrawable bucket is keyed by the **routed recipient**, NOT the king identity).
       - On push success emit `Events.KingEthPaid(prevEthRecipient, kingShare)`; on credit emit `Events.KingEthCredited(prevEthRecipient, kingShare)`.
       - King payout failure MUST NOT revert takeover.
     - Allocate shareholder ETH:
       - Call `ShareholderRoyalties.onTakeover{value: shareholderShare}(prevReignId)`.
       - Then call `ShareholderRoyalties.flushPendingShareholderETH()` (auto-attempt; usually a no-op after immediate indexing, but MUST remain safe for residual pending ETH and MUST also safely no-op if `globalLastTs()` is still stale after bounded checkpointing).
     - Emit:
       - `Events.ReignFinalized(prevReignId, prevKing, reignStartTime[prevReignId], nowTs, claimMinedToPrevKing, kingShare)`.

5. **Genesis rule (no previous King)**
   - If `prevKing == address(0)`:
     - `kingShare = 0`.
     - `shareholderShare = pricePaid`.
     - Call `ShareholderRoyalties.onTakeover{value: shareholderShare}(0)`.
     - Then call `ShareholderRoyalties.flushPendingShareholderETH()` (auto-attempt; usually a no-op after immediate indexing, but MUST remain safe for residual pending ETH and MUST also safely no-op if `globalLastTs()` is still stale after bounded checkpointing).
     - No `ReignFinalized` event is emitted.

6. **Start new reign**
   - Let `newKing` be the king identity for this reign. For direct entrypoints (`takeover`, `takeoverWithToken`) `newKing == msg.sender`; for delegated entrypoints (`takeoverFor`) `newKing` is the delegator address passed by the authorised caller.
   - Set `currentReignId = prevReignId + 1` (first takeover produces `reignId = 1`).
   - Set `currentKing = newKing`.
   - Set `currentReignStartTime = nowTs`.
   - Set `currentReignLastAccrualTime = nowTs`.
   - Set `referencePrice = newReferencePrice`.
   - Persist routing configuration for this reign (`reignEthRecipient[newReignId]`, `reignClaimRecipient[newReignId]`) and emit `Events.ReignRecipientsSet(newReignId, newKing, ethRecipient, claimRecipient)`.
   - Record per-reign metadata required for `getReignInfo` (king, startTime, pricePaid, referencePrice, etc).
   - Emit:
     - `Events.Takeover(currentReignId, prevKing, newKing, pricePaid, referencePrice, nowTs)`.

#### Hybrid refund (required)

- Follows strict CEI ordering: state is written (credit `refundEthBalance` and `totalRefundEthOwed`) **before** the external ETH transfer attempt, then reversed if the inline transfer succeeds.
- Attempt to return `refundEth` to the caller in the same transaction.
- If the ETH transfer succeeds, reverse the pre-written state (debit `refundEthBalance` and `totalRefundEthOwed`).
- If the ETH transfer fails, the pre-written credit remains and `RefundCredited` is emitted.
- Provide a withdrawal function allowing the caller to withdraw to a chosen recipient address.
- Refund failure MUST NOT revert takeover.

### 5.4.3 Emission math requirement

MineCore MUST compute emissions for an interval using the integral of the linear-decay schedule, not `rate(end) * dt`.

Let:

- `t = timestamp - emissionStartTime`
- `D = EMISSION_DECAY_PERIOD`
- `R0 = LAUNCH_RATE`
- `RF = FLOOR_RATE`

Rate function:

- For `t <= D`:
  - `rate(t) = R0 - (R0 - RF) * t / D`
- For `t >= D`:
  - `rate(t) = RF`

For an interval `[ts0, ts1)`:

- `t0 = ts0 - emissionStartTime`
- `t1 = ts1 - emissionStartTime`

If `t1 <= D` (fully in decay region):

- `emitted = (rate(t0) + rate(t1)) * (ts1 - ts0) / 2`

If `t0 < D < t1` (crosses the floor boundary):

- `emitted = integral(ts0, emissionStartTime + D) + RF * (ts1 - (emissionStartTime + D))`

If `t0 >= D`:

- `emitted = RF * (ts1 - ts0)`

Implementation notes:

- Rates use 18 decimals (CLAIM has 18 decimals).
- Floor division rounding is acceptable, but MUST be consistent across King and Furnace streams.

### 5.5 King payouts

Kings are paid using a hybrid mechanism: MineCore attempts a best-effort in-tx ETH push to the dethroned King, and falls back to a pull-based balance bucket (`kingEthBalance`) if that push fails. King payout failure MUST NOT revert takeover.

State:

- `mapping(address => uint256) kingEthBalance` – ETH owed to each address when the best-effort dethroned-King payout could not be pushed in-tx.

Rules:

- On every non-genesis takeover:
  - Compute `kingShare = pricePaid * 75 / 100`.
  - Attempt to push `kingShare` ETH to `prevKing` with a bounded gas stipend.
  - If that push fails: `kingEthBalance[prevKing] += kingShare`.
- `withdrawKingBalance()` allows `msg.sender` to withdraw `kingEthBalance[msg.sender]`.

Helper entrypoint (required for ClaimAllHelper):

- `withdrawKingBalanceFor(address user)` MUST preserve the exact same accounting semantics as `withdrawKingBalance()`,
  but operate on `user` instead of `msg.sender` and pay out to `user`.
- It MUST be restricted to the configured `ClaimAllHelper` address.

`withdrawKingBalance()` requirements:

1. Read `amount = kingEthBalance[msg.sender]`.
2. If `amount == 0`, return.
3. Set `kingEthBalance[msg.sender] = 0`.
4. Send ETH to `to` using `call`.
5. If the transfer to `to` fails and `to != user` (the bucket owner), retry delivery to `user`.
6. Revert with `Errors.EthTransferFailed()` only if both attempts fail.

Security requirements:

- MUST follow checks-effects-interactions.
- MUST be `nonReentrant`.

### 5.6 Admin / pause

MineCore is the canonical pause router for the protocol.

### 5.6.1 Takeover pause

- `setTakeoversPaused(bool paused)` (guardian-only)
  - MUST cause all takeover entrypoints (`takeover(maxPrice)`, `takeoverWithToken(...)`, `takeoverFor(...)`) to revert while paused.
  - On every transition where the flag changes (both `false -> true` and `true -> false`):
    - If `currentKing != address(0)`, MUST set `currentReignLastAccrualTime = block.timestamp`.
    - This clamps accrual so paused time is never mined later.
  - MUST NOT mutate:
    - `currentKing`
    - `currentReignId`
    - `currentReignStartTime`
    - `referencePrice`

### 5.6.2 Locking pause (Furnace)

- `setLockingPaused(bool paused)` (guardian-only)
  - Used to pause/unpause Furnace entry and protocol-driven locking.
  - Operators MUST have a single pause surface: `MineCore.setLockingPaused(bool)` MUST forward to `Furnace.setLockingPaused(bool)` (operators call MineCore, not Furnace).
  - Wiring requirement: `Furnace.guardian` MUST be set to MineCore when the MineCore pointer is wired. Once set to MineCore, `Furnace.setGuardian()` MUST only allow re-asserting MineCore, so `MineCore.setLockingPaused(bool)` cannot be disabled by guardian drift. Human guardian rotation happens on `MineCore.guardian`, not `Furnace.guardian`.

Clarification (non-binding):

- Takeover pause and locking pause are independent: each can be paused without affecting the other.

### 5.7 King history views

MineCore MUST expose the following read-only helpers (also defined in §11.1).

These helpers allow UIs and indexers to reconstruct reign timelines and leaderboards without guessing:

- `getReignInfo(uint256 reignId)` – returns key data about a reign:
  - king address, startTime, optional endTime, pricePaid, referencePrice, totalClaimMined, totalEthToKing.
- `getKingReigns(address king, uint256 cursor, uint256 limit)` – paginated list of reignIds for a King (limit is clamped to `MAX_KING_REIGNS_PER_CALL`).

---

## 6. ShareholderRoyalties

Per-user veNFT count cap (v1.0.0+):
- v1 enforces `balanceOf(user) <= MAX_VE_NFTS_PER_USER` where `MAX_VE_NFTS_PER_USER = 32` (see `src/lib/Constants.sol`; MUST match).
- Reward accounting remains bounded because `VeClaimNFT.veBalanceOf(user)` may iterate over at most `MAX_VE_NFTS_PER_USER` locks.
- Multi-row lock ownership lists are still for indexers/analytics (see §11 views); v1 does not enumerate all holders onchain.

**Type**: ETH index contract for veCLAIM holders.

### 6.1 State

Key data:

- `uint256 ethPerVe` – global index scaled by `ACC = 1e18`.
- `uint256 pendingShareholderETH` – ETH stored until flushed or deferred while the ve checkpoint timestamp is still stale or while checkpoint storage cannot safely represent a new distinct reward timestamp.
- `RewardCheckpoint[] rewardCheckpoints` – monotonically timestamped checkpoints of:
  - `cumulativeEthPerVe`
  - `cumulativeTimeWeightedEthPerVe = Σ(deltaEthPerVe * rewardTs)`
- `uint256 ethPerVeTimeWeighted`
- `RewardCheckpoint[] _overflowCheckpoints` – overflow array (capped at `MAX_OVERFLOW_CHECKPOINTS`). Once `rewardCheckpoints` reaches `MAX_REWARD_CHECKPOINTS` the main array is frozen and subsequent flushes append here. `_getRewardPrefixBefore` binary-searches both arrays. When the overflow array also fills it becomes a ring buffer with FIFO eviction of entries older than `MAX_LOCK_DURATION`; if a new distinct timestamp cannot be stored safely yet, flush MUST defer before advancing `ethPerVe`.
- `uint256 _overflowRingHead` – ring-buffer write head for `_overflowCheckpoints` (zero while the overflow array is still growing).
- `mapping(address => uint256) userEthPerVePaid`
- `mapping(address => uint256) claimableEth`
- `mapping(address => uint256) userTimeWeightedEthPerVePaid`
- `mapping(address => uint40) userLastRewardTs`
- `mapping(address => uint256) userRewardRemainder`

Also needs references to VeClaimNFT and Furnace. VeClaimNFT MUST expose:
- `checkpointTotalVe()`
- `totalVeBiasScaled()` (processed total ve-bias, units `ve * 1e18`)
- `globalLastTs()`
- `getShareholderLockParams(user)` returning parallel arrays of `(amount, lockEnd, autoMax)`

This extra state is REQUIRED so delayed checkpoints for decaying locks can be settled against historical flush timestamps instead of claim-time `veBalanceOf(user)`.

### 6.2 On takeover

`onTakeover(uint256 reignId)` (payable):

- Called by MineCore for the 25% shareholder share.
- For non-zero ETH, MUST fail closed unless the live `Furnace`, `MarketRouter`, `MineCore`, `VeClaimNFT`, and `ClaimToken` bundle still resolves to this exact `ShareholderRoyalties` root.
  - Rationale: otherwise MineCore can keep indexing takeover ETH into a stale royalties surface while checkpoint / claim paths already fail closed on the canonical bundle drift.
- Accumulates `msg.value` into `pendingShareholderETH`.
- MUST immediately attempt shareholder indexing against the current processed denominator when `totalWeight > 0`, even if the denominator rounds below `MIN_VE_FLUSH`. This attempt may still no-op if `VeClaimNFT.globalLastTs()` remains behind `block.timestamp` after bounded checkpointing.
- MineCore MUST call `flushPendingShareholderETH()` after each `onTakeover(...)` attempt.
- The same canonical-bundle preflight applies to `addPendingShareholderETH(uint256 reignId)` when MineCore retries a shareholder push that failed during the takeover transaction.
- MUST emit `ShareholderTakeoverAllocation(reignId, amountEth)` with `amountEth = msg.value`.

### 6.3 Flush

`flushPendingShareholderETH()`:

- If `pendingShareholderETH == 0`, return.
- For non-zero pending ETH, MUST fail closed unless the live `Furnace`, `MarketRouter`, `MineCore`, `VeClaimNFT`, and `ClaimToken` bundle still resolves to this exact `ShareholderRoyalties` root.
- MUST call `VeClaimNFT.checkpointTotalVe()` first.
- Let `rewardTs = VeClaimNFT.globalLastTs()`.
- If `rewardTs != block.timestamp`, return (no-op; the ve checkpoint is still stale and indexing must defer).
- Let `totalWeight = VeClaimNFT.totalVeBiasScaled()`.
- If `totalWeight == 0`, return (no-op).
- Let `veTotal = ceilDiv(totalWeight, 1e18)`.
- If `veTotal < MIN_VE_FLUSH`, return (no-op).
- If checkpoint storage cannot safely represent `rewardTs` (main array capped, overflow ring capped, oldest overflow entry still within `MAX_LOCK_DURATION`, and no same-block coalescing applies), return (no-op; keep pending ETH queued).
- Compute index delta **rounding DOWN**:
  - `delta = mulDivDown(pendingShareholderETH, 1e36, totalWeight)`.
- If `delta == 0`, return (keep `pendingShareholderETH`; avoids rounding-to-zero grief).
- Increase `ethPerVe += delta`.
- Increase `ethPerVeTimeWeighted += delta * rewardTs`.
- Store the reward checkpoint for `rewardTs`. If `rewardCheckpoints.length >= MAX_REWARD_CHECKPOINTS`, the main array is frozen and the checkpoint is routed to `_overflowCheckpoints` (ring-buffer with FIFO eviction at `MAX_OVERFLOW_CHECKPOINTS`).
- Compute the actually-distributed ETH **rounding DOWN**:
  - `distributed = mulDivDown(delta, totalWeight, 1e36)`.
- Decrease `pendingShareholderETH -= distributed` (keeps the remainder dust in the pending bucket).

Rationale:

- Canonical takeover allocations are indexed immediately when the ve checkpoint has caught up to the current block, so later ve entrants cannot dilute rewards that were generated before they became shareholders.
- `flushPendingShareholderETH()` remains permissionless so anyone can trigger indexing for residual pending ETH when (a) the system has no processed shareholders yet, (b) bounded checkpointing leaves `globalLastTs()` stale, or (c) rounding dust later becomes indexable.
- If the live Baron bundle drifts away from this `ShareholderRoyalties` root, non-empty `flushPendingShareholderETH()` MUST revert with `WiringMismatch` rather than silently indexing against a stale royalties surface.
- Historical reward checkpoints are REQUIRED for correctness when a user checkpoints long after a decaying lock has partially or fully expired.
- If the reward checkpoint history is saturated inside the active lock horizon, flushing MUST defer rather than pinning an old timestamp to newer cumulative time-weighted values.
- Prevents stale-timestamp indexing from letting already-expired locks capture post-expiry rewards.
- Prevents “dust theft”, under-accrual for decaying locks, and stranded ETH caused by claim-time `veBalanceOf(user)`.
- Ensures total ETH claimable via the index never exceeds ETH deposited.

### 6.4 User checkpoint

`checkpointUser(address user)`:

- Let `idx = ethPerVe` and `paid = userEthPerVePaid[user]`.
- If `idx == paid`, return (already up to date).
- Load the user’s current lock parameters from `VeClaimNFT.getShareholderLockParams(user)`.
  - This call is gas-bounded in v1.0.0+ because VeClaimNFT enforces `MAX_VE_NFTS_PER_USER`.
  - VeClaimNFT MUST checkpoint ShareholderRoyalties before every ve mutation, so the current lock set is a valid basis for all unprocessed reward epochs.
- `checkpointUser` MUST fail closed unless the live `Furnace`, `MarketRouter`, `MineCore`, `VeClaimNFT`, and `ClaimToken` still resolve to one canonical Baron bundle rooted at this exact `ShareholderRoyalties` contract.
  - Rationale: MarketRouter transfer settlement depends on `checkpointTransfer(...)` landing on this royalties root before ownership moves; a split-brain `MarketRouter.royalties()` or `MineCore.royalties()` root would otherwise let this contract continue accruing and claiming against a stale lock-set assumption.
- For each lock:
  - AutoMax lock:
    - weight is constant = `amount * 1e18`
    - accrue across all unprocessed epochs
  - Decaying lock:
    - only reward checkpoints with `rewardTs < lockEnd` are eligible
    - use prefix sums over `deltaEthPerVe` and `deltaEthPerVe * rewardTs`
    - equivalently:
      - `accrued = floor(slopeScaled(amount) * (lockEnd * Δidx - ΔtimeWeightedIdx) / 1e36)`
- Sum all lock accruals into `claimableEth[user]`.
- Carry any sub-wei remainder forward in `userRewardRemainder[user]`.
- Set:
  - `userEthPerVePaid[user] = ethPerVe`
  - `userTimeWeightedEthPerVePaid[user] = ethPerVeTimeWeighted`
  - `userLastRewardTs[user] = latestRewardTs`

Constraints (required):

- `checkpointUser` MUST NOT revert due to rounding edge cases (except on obvious invalid input / invariant violations).
- Rounding MUST be floor at ETH-credit boundaries.
- This prevents users from extracting more than their pro-rata share while preserving delayed claims for decaying locks.

### 6.5 Transfers

`checkpointTransfer(address from, address to)`:

- Callable **only** by MarketRouter.
- MUST be called **before** transferring veNFT ownership.
- Inherits the same canonical Baron-bundle preflight as `checkpointUser(...)`; if the live `Furnace / MarketRouter / MineCore / VeClaimNFT / ClaimToken` bundle drifts away from this exact `ShareholderRoyalties`, transfer settlement MUST fail closed rather than checkpointing the wrong royalties surface.
- If `from == to`, return.
- Steps:

1. `checkpointUser(from)`.
2. `checkpointUser(to)`.

Goal: **no retroactive rewards** to new lock owners.

Rationale:

- Seller accrues up to the transfer timestamp.
- Buyer’s `userEthPerVePaid` is set to current index, so new owner cannot claim past periods.

### 6.6 Claim

`claimShareholder(ShareholderMode mode, uint256 targetTokenId, uint256 durationSeconds, bool createAutoMax, uint256 minVeOut)`:

- Mode can be:
  - `ETH` – withdraw ETH directly.
  - `LOCK_FURNACE` – send ETH to Furnace and lock for user.
- MUST be `nonReentrant`.
- MUST follow CEI ordering: checkpoint → read amount → clear claimable → external call.
- If `amount == 0`, function MUST return early (no-op).

Steps:

1. `checkpointUser(msg.sender)`.
2. Read `amount = claimableEth[msg.sender]`.
3. If `amount == 0`, return.
4. Set `claimableEth[msg.sender] = 0`.
5. If `mode == ETH`:
   - Send `amount` wei ETH to `msg.sender` (use `call` and revert on failure).
   - `targetTokenId`, `durationSeconds`, `createAutoMax`, and `minVeOut` MUST be ignored.
6. If `mode == LOCK_FURNACE`:
   - Call `Furnace.lockEthReward{value: amount}(msg.sender, amount, targetTokenId, durationSeconds, createAutoMax, minVeOut)`.
   - MUST bubble reverts (atomic revert).
7. Otherwise, revert invalid `mode`.

Constraints (required):

- `claimShareholder` MUST NOT send ETH externally before clearing `claimableEth[msg.sender]`.
- `claimShareholder` and `claimShareholderFor(...)` MUST fail closed unless the live `Furnace`, `MarketRouter`, `MineCore`, `VeClaimNFT`, and `ClaimToken` still resolve one canonical Baron bundle rooted at this exact royalties contract.
- In `LOCK_FURNACE` mode, the Furnace call MUST revert if it cannot fund `ethAmount`.
  - `ShareholderRoyalties` MUST pass `msg.value == ethAmount` into `Furnace.lockEthReward(...)`.
  - `Furnace.lockEthReward(...)` does not source `ethAmount` from idle Furnace ETH balance.
  - `claimShareholder` MUST NOT permanently lose `claimableEth` on failure (full transaction reverts).

Helper entrypoint (required for ClaimAllHelper):

- `claimShareholderFor(address user, uint8 mode, ...)` MUST preserve the exact same accounting semantics as
  `claimShareholder(...)`, but operate on `user` instead of `msg.sender` and pay out to `user`.
- It MUST be restricted to the configured `ClaimAllHelper` address.

### 6.7 Auto-compound into Furnace (keeper-allowlisted with owner break-glass, in scope)

Goal:
- Allow Barons to opt into a keeper-assisted auto-claim cadence that compounds their accrued shareholder ETH into veCLAIM via Furnace, **without changing reward economics**.

Key property (MUST):
- This feature MUST NOT change how much ETH each Baron earns. It only changes *when/how* the user claims, and routes the claim into Furnace lock mode when the user enables auto-compound.

Why keeper-allowlisted (design choice):
- Barons opt in and keep execution delegated to designated keeper operators.
- In practice, the official keeper runs compounding; owner is a break-glass executor.
- Users can always disable auto-compound if they prefer to control timing/quotes.

#### 6.7.1 State (REQUIRED)

Per-user config:

- `struct ShareholderAutoCompoundConfig {`
  - `bool enabled;`
  - `bool paused;`
  - `uint256 tokenId;` (destination veNFT; MUST be existing; no create-new in v1)
  - `uint256 durationSeconds;` (target remaining duration after each compound)
  - `uint32 minCadenceSeconds;` (minimum time between successful compounds)
  - `uint256 minEthToCompound;` (minimum accrued ETH required to attempt compounding)
  - `uint32 maxSlippageBps;` (user-configured max slippage in basis points; 0 = use protocol default)
  - `uint40 lastCompoundTs;` (timestamp of last successful compound)
- `}`

Defaults:
- `enabled = false`, `paused = false`.

#### 6.7.2 User configuration

Setter (REQUIRED):

`setAutoCompoundConfig(bool enabled, uint256 tokenId, uint256 durationSeconds, uint32 minCadenceSeconds, uint256 minEthToCompound, uint32 maxSlippageBps)`

Delegation-gated config setter (implemented in the shipped v1.0.0 code):

`setAutoCompoundConfigForUser(address user, bool enabled, uint256 tokenId, uint256 durationSeconds, uint32 minCadenceSeconds, uint256 minEthToCompound, uint32 maxSlippageBps)`

- Requires `P_SET_SHAREHOLDER_AUTOCOMPOUND_CONFIG_FOR`.
- MUST fail closed unless the live `Furnace`, `MarketRouter`, `MineCore`, `VeClaimNFT`, and `ClaimToken` still resolve one canonical Baron bundle and the live Furnace/MineCore pair still agree on one canonical `DelegationHub`; a raw `Furnace.delegationHub()` read is insufficient.

Keeper management (REQUIRED):

`setAutoCompoundKeeper(address keeper, bool allowed)` (owner-only)

Rules (MUST):

- If `enabled == false`:
  - MUST clear `paused`.
  - MUST clear `lastCompoundTs` (reset cadence state).
  - Clarification (non-binding): It is allowed to also clear destination/cadence fields to defaults.
- If `enabled == true`:
  - `tokenId != 0` (v1 does not create new locks in auto-compound).
  - `tokenId` MUST be owned by the configured user at configuration time (`msg.sender` on the self path; `user` on the delegation-gated path).
  - `tokenId` MUST NOT be listed.
  - `tokenId` MUST NOT be expired (`lockEnd > block.timestamp`).
  - `durationSeconds` MUST satisfy `MIN_LOCK_DURATION <= durationSeconds <= MAX_LOCK_DURATION`.
  - If `tokenId` is AutoMax, `durationSeconds` MUST equal `MAX_LOCK_DURATION`.
- `maxSlippageBps` is stored per-user. If `0`, the contract uses `DEFAULT_AUTOCOMPOUND_MAX_SLIPPAGE_BPS` at execution time. Non-zero values MUST be `<= 2_000` (20%); the setter reverts `SlippageTooHigh` above this cap.
- Any successful config change MUST set `paused = false`.
- MUST emit `ShareholderAutoCompoundConfigured(...)`.

Guidance (non-binding; UI):
- Suggested presets for `minCadenceSeconds`: 1h, 6h, 24h (default), 7d.
- Suggested default `minEthToCompound`: a non-dust threshold (example: 0.01 ETH), configurable.

#### 6.7.3 Single-user execution

`compoundFor(address user)`

Note: `minVeOut` is **not** passed by the caller. The contract computes it on-chain from the user's stored `maxSlippageBps` and a Furnace quote (see "Slippage protection" below).

Reentrancy (MUST):
- MUST be `nonReentrant`.

Authorization:
- `BARON_COMPOUND_KEEPER` allowlist or owner.

Preconditions (MUST):
- Config MUST be enabled and not paused.
- Cadence: if `lastCompoundTs != 0`, require `block.timestamp >= lastCompoundTs + minCadenceSeconds`.
  - `lastCompoundTs == 0` means “never successfully compounded” and MUST NOT block the first compound.
- Always call `checkpointUser(user)` before reading `claimableEth[user]`.
- Runtime execution therefore inherits the same canonical Baron-bundle fail-closed behavior as `checkpointUser(user)`; stale `Furnace / MarketRouter / MineCore / VeClaimNFT / ClaimToken` roots MUST stop compounding before any accounting mutation.

No-op conditions (required):
- If `claimableEth[user] == 0`, function MUST return.
- If `claimableEth[user] < minEthToCompound`, function MUST return.

Destination validation (MUST):
- At execution time, validate the destination lock is still eligible:
  - still owned by `user`
  - not listed
  - not expired
  - AutoMax invariants still hold (if AutoMax, treat duration as `MAX_LOCK_DURATION`)
- If destination is invalid:
  - Set `paused = true`.
  - Emit `ShareholderAutoCompoundPaused(user, tokenId, reasonCode)`.
  - Return (do not revert).

Effective duration:
- Let `remaining = max(0, lockEnd - block.timestamp)`.
- `effectiveDurationSeconds = max(durationSeconds, remaining)` (Furnace entry path clamps this to `remaining` for non-AutoMax locks, so the lock's duration does not change).
- If destination is AutoMax, `effectiveDurationSeconds = MAX_LOCK_DURATION`.

Slippage protection (MUST):
- The contract MUST compute `minVeOut` on-chain using the user's stored `maxSlippageBps`:
  1. Query `Furnace.quoteEnterWithEth(user, amount, tokenId, effectiveDurationSeconds, false)` to obtain `veOut` for the newly locked amount at the resulting remaining duration.
  2. Let `slippageBps = maxSlippageBps` (or `DEFAULT_AUTOCOMPOUND_MAX_SLIPPAGE_BPS` if `0`).
  3. Compute `minVeOut = veOut * (BPS_DENOM - slippageBps) / BPS_DENOM`.
     - If `veOut > 0` but floor-rounding would produce `minVeOut == 0`, clamp to `1` before calling Furnace.
  4. If the quote call reverts in `compoundFor(user)`, the function MUST revert rather than execute blind.
     - Batch semantics differ: `compoundForMany(...)` skips that user when a quote cannot be computed.

Execution (MUST):
- Use CEI ordering:
  1. checkpointUser(user)
  2. read `amount = claimableEth[user]`
  3. clear `claimableEth[user] = 0`
  4. set `lastCompoundTs = now`
  5. call Furnace in LOCK_FURNACE mode:
     - `Furnace.lockEthReward{value: amount}(user, amount, tokenId, effectiveDurationSeconds, false, minVeOut)`
     - where `minVeOut` is computed on-chain as described above.
- MUST bubble reverts from Furnace (atomic). On revert, `claimableEth` and `lastCompoundTs` MUST NOT be lost (transaction revert).

Events (MUST):
- MUST emit `ShareholderAutoCompoundExecuted(user, msg.sender, amountEth, tokenId, effectiveDurationSeconds)` on success.
- MUST emit the usual `ShareholderClaim(user, LOCK_FURNACE, amountEth)` as well.
  - Constraint: the `ShareholderClaim` emitted in Auto-Compound MUST match the user-initiated claim semantics (same mode code, amount, and accounting boundaries).

#### 6.7.4 Batch execution (REQUIRED)

`compoundForMany(address[] users, uint256 maxUsers)`

Input rules (MUST):
- MUST be gas-bounded:
  - Let `usersN = min(users.length, min(maxUsers, MAX_SHAREHOLDER_COMPOUND_USERS_PER_CALL))`.
  - Iterate only over `[0..usersN)`.
- MUST NOT iterate over all users onchain (caller supplies explicit worklist).

Authorization:
- `BARON_COMPOUND_KEEPER` allowlist or owner.

Execution semantics (MUST):
- For each `user` in-order, attempt the same compounding action as `compoundFor(user)`, but with bounded per-user best-effort semantics:
  - Canonical Baron-bundle drift discovered by `checkpointUser(user)` MUST still fail closed before any per-user accounting mutation, and MAY revert the batch call.
  - If the destination lock is invalid, the contract MUST pause the user (emit `ShareholderAutoCompoundPaused`) and continue.
  - If the quote call fails for a given user, skip that user and continue without advancing `claimableEth` or `lastCompoundTs`.
  - If the downstream Furnace call fails after checkpoint/quote preflight passes, the user’s `claimableEth` and `lastCompoundTs` MUST NOT be lost/advanced.
- `minVeOut` is computed on-chain per user (same inputs as `compoundFor`); the caller does not supply per-user slippage values or any `minVeOut[]` companion array.

Events (MUST):
- Reuse the single-user events:
  - MUST emit `ShareholderAutoCompoundExecuted` for each successful user compound.
  - MUST emit `ShareholderAutoCompoundPaused` for any paused user.
  - No additional batch-only event is required.

#### 6.7.5 Failure policy (Policy SR-2: skip + pause)

If any lock-eligibility condition fails, compounding MUST:
- Skip for that user (return).
- Pause the user’s config until they update it.
- Never create a new lock as a fallback (v1).

Reason codes (REQUIRED; canonical and immutable once deployed; see `docs/analytics/dune-integration-pack-v1.0.0.md`):
- `1` = `NOT_OWNER`
- `2` = `LISTED`
- `3` = `EXPIRED`
- `4` = `INVALID_TOKEN_ID`

## 7. Furnace

**Type**: unified entry and bonus engine.

### 7.1 State

- `ClaimToken` CLAIM.
- `VeClaimNFT` veCLAIM.
- `ShareholderRoyalties` for lock mode.
- `LpStakingVault7D` (lpRewardsVault) for LP staker rewards.

LP rewards funding sources (protocol-defined; no protocol fees):
- Furnace gross-bonus split (per-entry LP top-up; §7.3.4) → funded into the LP rewards stream (§7.3.6).
- LP overflow drip (protocol; §7.3.5) → funded into the LP rewards stream (§7.3.6).
- Furnace sellback LP share (protocol; §7.6) → funded into the LP rewards stream (§7.3.6).
- LP vault fee harvesting (§7.5).

- `EntryTokenRegistry` registry
  - Furnace resolves allowlisted entry-token routes via the registry at runtime.
  - The registry is governed and is the designated allowlisting/routing-config surface (owner-managed via timelock + multisig).

The registry address MUST be set during Phase B wiring (owner-only), and MUST NOT be user-supplied.

Bonus accounting (AMM-style):

- `uint256 furnaceReserve` – CLAIM inventory reserved for the Furnace bonus engine:
  - pays gross bonuses (user + LP top-up) drawn by the AMM (§7.3.4), and
  - funds the protocol LP overflow drip (§7.3.5).
  - NOTE: Furnace sellback does not spend reserve; it is self-funded by the sold lock’s principal (§7.6).
- `uint256 bonusVirtualDepth` – AMM “depth” state (in CLAIM units). Higher = worse bonus quote.
- `uint256 lastBonusUpdate` – timestamp used for virtual-depth decay.

LP rewards streaming (smoothing):

- `address lpRewardsVault` – destination for LP rewards drips (liquid CLAIM), notified via `LpStakingVault7D.notifyRewards(...)`.
  - Set during Phase B wiring; remains owner-managed via timelock + multisig.
  - If unset (`address(0)`), all LP reward funding MUST be disabled:
    - `lpTopupClaim` MUST be treated as 0
    - overflow drip MUST not fund the stream
    - sellback LP share MUST be 0
  - Rewires or disables of `lpRewardsVault` MUST fail closed while already-earned LP liability remains attributable to the current vault.
    - That liability includes both the parked LP stream remainder and overflow-drip rewards already accrued for the current vault period but not yet checkpointed into the stream.
  - Any successful vault change MUST reset the overflow-drip accrual cursor so the new vault period cannot inherit backlog from a prior or disabled period.
- Stream schedule state (in Furnace):
  - `uint256 lpStreamRatePerSec`
  - `uint256 lpStreamPeriodFinish`
  - `uint256 lpStreamLastUpdate`

Constraints (required):
- `furnaceReserve` is an accounting variable; it MUST be updated only by:
  - `creditReserve(amount)` (MineCore emission stream), and
  - the sellback path net retention (§7.6).
  - Direct ERC20 transfers to Furnace MUST NOT automatically change `furnaceReserve` or LP stream state.
- Solvency invariant (bucketed):
  - Let `lpStreamRemaining` be the remaining scheduled stream amount (see §7.3.6).
  - MUST hold: `ClaimToken.balanceOf(Furnace) >= furnaceReserve + lpStreamRemaining`.
- `bonusVirtualDepth` is *not* a balance; it is a rate-control state variable.

### 7.2 Entry paths

Preconditions (locked):

- Furnace MUST be configured with a non-zero `EntryTokenRegistry` address.
- EntryTokenRegistry MUST have valid router config and allowlisted pool configuration for any enabled entry path.
- Quote views that depend on swap estimation MUST use the same registry configuration.
- If the registry is unset, or a token/pool is not allowlisted, these functions MUST revert (fail closed).

Lock destination parameters (used by **all** entry paths and quote views):

- `targetTokenId`
  - `0` means “create a new lock for the receiver”.
  - Non-zero means “use this existing lock id”.
- `durationSeconds`
  - The selected lock duration (clamped to `MIN_LOCK_DURATION .. MAX_LOCK_DURATION`).
  - For existing locks, this is interpreted as “target remaining duration from now”, so it can only extend, never shorten.
- `createAutoMax`
  - Only meaningful when `targetTokenId == 0` **and** `durationSeconds == MAX_LOCK_DURATION`.
  - UI checkbox default: **off**.

Core execution behavior (MUST):

- Compute `commitmentClaim` from the entry (swap result or direct CLAIM).
- Apply Furnace bonus using the AMM with **duration weighting** (see §7.3.3 and `src/lib/Constants.sol` §3.4D).
- Route `principalClaim + userBonusClaim` into the selected lock destination (see §4.4):
  - If `targetTokenId == 0`: mint a new lock via `VeClaimNFT.createLockFor(...)`.
  - Else: add to the existing lock via `VeClaimNFT.addToLockFor(...)` (duration is not changed by entry; for non-AutoMax locks, `durationSeconds` is clamped to the current remaining duration).
- Compute the entry-attributable `veOut` and enforce `veOut >= minVeOut`.
  - `veOut` tracks only the newly locked amount (`principalClaim + userBonusClaim`) at the resulting remaining duration.

Entry functions:

1. `enterWithEth(uint256 targetTokenId, uint256 durationSeconds, bool createAutoMax, uint256 minVeOut)` payable
   - Swap `msg.value` ETH to CLAIM using Aerodrome CLAIM/WETH pool.
   - Set `commitmentClaim = claimAmountFromSwap`.
   - Compute `principalEff = Math.mulDiv(commitmentClaim, weight, WEIGHT_DENOM)` using the sub-bp duration-weight curve (env-config §3.4D), then apply bonus via `_applyBonusAmm(user, commitmentClaim, principalEff, durationSeconds)`.
   - Route principal + bonus into the selected lock destination (§4.4).
   - Enforce `minVeOut`.

2. `enterWithClaim(uint256 claimAmount, uint256 targetTokenId, uint256 durationSeconds, bool createAutoMax, uint256 minVeOut)`
   - Transfer `claimAmount` from user to Furnace.
   - `commitmentClaim = claimAmount`.
   - Apply bonus and route into the selected lock destination (§4.4).
   - Enforce `minVeOut`.

3. `enterWithClaimFor(address user, uint256 claimAmount, uint256 targetTokenId, uint256 durationSeconds, bool createAutoMax, uint256 minVeOut) returns (uint256 tokenIdUsed)`
   - Callable only by authorized contracts:
     - MarketRouter (marketplace auto-Furnace fallback), but only while the live `MarketRouter` still resolves the same `claim`, `ve`, and `royalties` roots as the canonical `Furnace` / `ShareholderRoyalties` bundle
     - LpStakingVault7D (LP reward compounding)
     - MineCore (King auto-lock)
   - Intended use: contract-held CLAIM routed into Furnace while crediting veCLAIM to `user`.
   - Transfer `claimAmount` from the caller to Furnace.
   - `commitmentClaim = claimAmount`.
   - Apply bonus and route into the selected lock destination for `user` (§4.4).
   - Enforce `minVeOut`.

4. `enterWithToken(address tokenIn, uint256 amountIn, uint256 targetTokenId, uint256 durationSeconds, bool createAutoMax, uint256 minVeOut)`
   - **WETH special-case (REQUIRED):** if `tokenIn == wrappedNative` (WETH), Furnace MUST treat this as an ETH entry boundary:
     - Transfer `amountIn` WETH from the user to Furnace.
     - Unwrap 1:1 to ETH.
     - Swap `ETH -> (router wraps to WETH) -> CLAIM` using the pinned `WETH -> CLAIM` hop.
     - (WETH MUST NOT be configured as `tokenIn` in the registry.)
   - Else: require `tokenIn` is enabled in `EntryTokenRegistry` for Furnace entry.
   - Transfer `amountIn` of `tokenIn` from user to Furnace.
   - Resolve routing via `EntryTokenRegistry` (no user routes):
     - If a direct `tokenIn -> CLAIM` pool is configured + enabled, swap directly.
     - Else swap `tokenIn -> WETH -> CLAIM`.
   - Set `commitmentClaim = claimAmountFromSwap`.
   - Compute `principalEff = Math.mulDiv(commitmentClaim, weight, WEIGHT_DENOM)` using the sub-bp duration-weight curve (env-config §3.4D), then apply bonus via `_applyBonusAmm(user, commitmentClaim, principalEff, durationSeconds)`.
   - Route principal + bonus into the selected lock destination (§4.4).
   - Enforce `minVeOut`.

5. `lockEthReward(address user, uint256 ethAmount, uint256 targetTokenId, uint256 durationSeconds, bool createAutoMax, uint256 minVeOut)`
   - Callable only by ShareholderRoyalties.
   - `msg.value` MUST equal `ethAmount` exactly.
   - Uses only the ETH transferred in with the current call from ShareholderRoyalties.
   - Swap ETH → CLAIM, then same as `enterWithEth`.

#### 7.2.1 Swap path and MEV safety (MUST)

**Threat model**

- Aerodrome (Uniswap-v2 style) swaps are manipulable within a block.
- The protocol’s protection is **atomic revert** via `minVeOut` (not a TWAP oracle).

**Swap path requirements**

Routing is fixed and registry-driven (no user-supplied routes/pools/stable flags):

- `enterWithEth` / `lockEthReward`:
  - Swap `ETH -> (router wraps to WETH) -> CLAIM` using the allowlisted `WETH -> CLAIM` hop.

- `enterWithToken(tokenIn, ...)`:
  - If `tokenIn == wrappedNative` (WETH): unwrap 1:1 and treat as the ETH entry path (swap `ETH -> CLAIM` via the pinned `WETH -> CLAIM` hop).
  - If a direct pool is configured + enabled: swap `tokenIn -> CLAIM` directly.
  - Else swap `tokenIn -> WETH -> CLAIM`.

- Every hop MUST be validated against allowlisted pools using:
  - `router.poolFor(tokenA, tokenB, stableFlag, factory)`
  - and compared to the allowlisted pool address from `EntryTokenRegistry`.

Multi-hop is allowed only for the fixed route shape above. Arbitrary dynamic routing remains forbidden.

**Deadline requirement (locked)**

- Any router swap MUST include a `deadline` parameter and forward it to the router.

Furnace entry functions (pinned ABI):
- v1.0.0 Furnace entry functions do **not** accept a user-supplied `deadline` in their ABI.
- Furnace MUST compute `deadline = block.timestamp + SWAP_DEADLINE_SECONDS` internally and pass it to the router.

Other components:
- If a component exposes a `deadline` parameter, it MUST forward the caller-supplied value to the router unchanged.

Operational default (recommended):
- `SWAP_DEADLINE_SECONDS = 300`

**Slippage / MEV protection (locked)**

- The contract MUST enforce the user’s `minVeOut` on the entry-attributable `veOut` after:
  - swap,
  - bonus payout,
  - lock destination routing (including any extension needed to determine the resulting remaining duration).
- `veOut` / `minVeOut` cover only the newly locked amount (`principalClaim + userBonusClaim`). 
- If `veOut < minVeOut`, the function MUST revert (and the swap MUST revert with it).

**UI requirement (locked)**

Furnace MUST expose quote views.

These views allow UIs to set safe `minVeOut`:

- `quoteEnterWithEth(address user, uint256 ethIn, uint256 targetTokenId, uint256 durationSeconds, bool createAutoMax)` → `(principalClaim, bonusClaim, veOut, routeTokenId)`
- `quoteEnterWithClaim(address user, uint256 claimIn, uint256 targetTokenId, uint256 durationSeconds, bool createAutoMax)` → `(principalClaim, bonusClaim, veOut, routeTokenId)`
- `quoteEnterWithToken(address user, address tokenIn, uint256 amountIn, uint256 targetTokenId, uint256 durationSeconds, bool createAutoMax)` → `(principalClaim, bonusClaim, veOut, routeTokenId)`

Where:

- `veOut` is the entry-attributable ve for the newly locked amount at the resulting remaining duration.
- `routeTokenId` MUST be consistent with `targetTokenId`:
  - If `targetTokenId == 0`, `routeTokenId` MUST be `0`.
  - If `targetTokenId != 0`, `routeTokenId` MUST equal `targetTokenId`.

Quote bonus semantics (locked):
- In all quote views, `bonusClaim` MUST be the **net user bonus** (after the user/LP split in §7.3.4).
- The gross bonus (`grossBonusClaim`) may be computed internally for accounting, but it is not a user-facing number in v1.

UI MUST set:

- `minVeOut = floor(quoteVeOut * (10_000 - slippageBps) / 10_000)`
- If `quoteVeOut > 0` but floor-rounding would produce `minVeOut == 0`, clamp to `1`.

Recommended defaults:

- default `slippageBps = 100` (1%)
- allow user range `10..500` (0.1%..5%)
- show a strong warning above `1_000` (10%)

Operational guidance (non-binding):

- For large ETH entries, UIs recommend sending via a private / MEV-protected RPC to reduce revert risk.

All MUST be protected with `ReentrancyGuard`.

### 7.3 Bonus calculation (locked-supply anchor + LP top-up + AMM)

Design goals (unchanged):

- Small entries receive a bonus rate near the current spot cap.
- Large entries receive materially less (size impact), like swapping into low liquidity.
- Splitting a large entry into many transactions MUST NOT materially improve total bonus.
- Quotes recover over time as the virtual depth decays back toward its target.

Source of truth:

- `src/lib/Constants.sol` §3.4 (constants + formulas)
- [Math and rounding appendix](../architecture/math-and-rounding-appendix-v1.0.0.md) §M.2 (rounding)

#### 7.3.1 Locked-supply anchor + reserve ramp (user cap)

Definitions:

- `totalSupply`: total supply of CLAIM (`ClaimToken.totalSupply()`).
- `lockedSupply`: total CLAIM locked in ve (principal + locked bonuses), typically `VeClaimNFT.totalLockedClaim()`.
- `R = furnaceReserve`.
- `elapsed = block.timestamp - launchTime`.

User cap (net):

- `lockedPctBps = clamp(floor(10_000 * lockedSupply / totalSupply), 0, 10_000)`.
- `baseUserBps = floor(MAX_USER_BONUS_BPS * LOCK_PCT_TARGET_BPS / (LOCK_PCT_TARGET_BPS + lockedPctBps))`.
- `reserveFullnessBps = clamp(floor(10_000 * R / RESERVE_TARGET_FINAL), 0, RESERVE_FACTOR_MAX_BPS)`.
- `swingAlphaBps = clamp(floor(10_000 * elapsed / SWING_TIME), 0, 10_000)`.
- `reserveFactorBps = 10_000 + floor(swingAlphaBps * (reserveFullnessBps - 10_000) / 10_000)` (piecewise; use a **ceiling** adjustment on the down-branch when `reserveFullnessBps < 10_000`).
- Lock-% dependent max boost cap:
  - `maxReserveFactorBps = RESERVE_FACTOR_MAX_BPS_LOWLOCK` when `lockedPctBps <= LOCK_PCT_MIN_FOR_BOOST_CAP_BPS`.
  - `maxReserveFactorBps = RESERVE_FACTOR_MAX_BPS` when `lockedPctBps >= LOCK_PCT_FULL_BOOST_CAP_BPS`.
  - Linear ramp between those two lock% points.
  - `reserveFactorBps = min(reserveFactorBps, maxReserveFactorBps)`.
- `userSpotBps = min(MAX_USER_BONUS_BPS, floor(baseUserBps * reserveFactorBps / 10_000))`.

#### 7.3.2 LP top-up and gross cap

LP top-up is additive, expressed as bps of the user bonus:

- Normalize the user spot bonus into a 0..10_000 bonus axis:
  - `bBps = clamp(floor(userSpotBps * 10_000 / MAX_USER_BONUS_BPS), 0, 10_000)`.

- Compute the **base** LP top-up rate (convex in `bBps`):
  - `lpRateBpsBase = LP_TOPUP_RATE_MIN_BPS + floor((LP_TOPUP_RATE_MAX_BPS - LP_TOPUP_RATE_MIN_BPS) * (bBps ^ LP_TOPUP_GAMMA) / (10_000 ^ LP_TOPUP_GAMMA))`.

- Apply **reserve-aware scaling (down-only)** so LP rewards never increase above the base curve:
  - `lpScaleBps = lpScaleBps(lockedSupply, totalSupply, R, elapsed)` in `[0..10_000]`.
  - `lpRateBps = floor(lpRateBpsBase * lpScaleBps / 10_000)`.

- `lpTopupSpotBps = floor(userSpotBps * lpRateBps / 10_000)`.
- `grossSpotBps = userSpotBps + lpTopupSpotBps`.

Bounds (v1.0.0 pinned constants):

- `userSpotBps <= 10_000` (100%).
- Hard clamp: `grossSpotBps <= 12_500` (125%).
- With current defaults (`LP_TOPUP_RATE_MAX_BPS = 1_500`), `grossSpotBps <= 11_500` (115%) before reserve-aware scaling.

#### 7.3.3 AMM state and decay (gross)

AMM state:

- `R = furnaceReserve` (CLAIM reserve).
- `V = bonusVirtualDepth`.
- `lastBonusUpdate`.
- `BONUS_DECAY_WINDOW = 3 hours`.

vTarget (strict cap enforcement):

- If `grossSpotBps == 0` or `R == 0`, treat as zero-bonus regime.
- Else `vTarget = ceil(R * 10_000 / grossSpotBps)` (ceiling division).

Before paying any bonus, enforce:

- `V = max(V, vTarget)`.
- `V` decays linearly back toward `vTarget` over `BONUS_DECAY_WINDOW`.

#### 7.3.4 Gross bonus payout and split

Given principal `P` and duration weight `weight` from the sub-bp curve (see env-config §3.4D):

- `P_eff = Math.mulDiv(P, weight, WEIGHT_DENOM)` (floor).
- If `P_eff == 0`: bonus is 0 and AMM state does not change.

Gross bonus (AMM-style):

- `grossBonusClaim = floor(R * P_eff / (V + P_eff))`.
- Update state using gross:
  - `R = R - grossBonusClaim`.
  - `V = V + P_eff`.

Split gross bonus into user + LP:

- `denom = 10_000 + lpRateBps`.
- `userBonusClaim = floor(grossBonusClaim * 10_000 / denom)`.
- `lpRewardClaim = grossBonusClaim - userBonusClaim`.

Routing:

- User receives `P + userBonusClaim` locked into the destination lock (§4.4).
- If LP rewards are enabled (`lpRewardsVault != address(0)`), Furnace MUST fund the LP rewards stream by `lpRewardClaim` (liquid CLAIM).
  - The stream drips to `lpRewardsVault` over `LP_STREAM_WINDOW` (§7.3.6).

UI semantics:

- "Bonus %" shown to users is always the user side (`userBonusBps` / `quoteUserBonusBps`).
- UI MUST keep LP rewards separate from the net user bonus (never blended):
  - Primary UI: show “LP stakers (24h): X CLAIM” (indexer-derived rolling 24h total; includes per-entry split + overflow drip).
  - Advanced view: may show `quoteLpTopupBps` and `lpOverflowDripPerDay` (CLAIM/day).

#### 7.3.4.1 Bonus payout floor (extend / merge / AutoMax)

The user-bonus delivery step on the extend, merge, and AutoMax bonus paths
calls `VeClaimNFT.addToLockFor`, which enforces `amount >= MIN_TOPUP_AMOUNT`
(env-config §3.1B). Furnace MUST apply the following floor at the user-bonus
delivery step on `extendWithBonus[For]`, `mergeLocksWithBonus[For]`, and
`claimAutoMaxBonus[Batch]`:

- If `userBonusClaim >= MIN_TOPUP_AMOUNT`: deliver via `addToLockFor`.
- If `0 < userBonusClaim < MIN_TOPUP_AMOUNT` on user-initiated extend / merge:
  credit the dust to `furnaceReserve` and set the surfaced `bonusClaim` return
  value to `0`. The surviving lock receives no bonus on that call.
- If `0 < userBonusClaim < MIN_TOPUP_AMOUNT` on permissionless AutoMax claim:
  return `0` before applying the AMM and do not update
  `lastAutoMaxBonusClaim[tokenId]`. Third-party keepers MUST NOT be able to
  burn another user's accrual window with a zero-delivered claim.
- If `userBonusClaim == 0`: standard skip (no reserve credit, no `addToLockFor`).

The extend / merge dust credit MUST keep the bucketed solvency invariant
`ClaimToken.balanceOf(Furnace) >= furnaceReserve + lpStreamRemaining` intact:
`grossBonusClaim` has already debited `furnaceReserve` in §7.3.4, so the dust
credit returns the user-side share of that debit to `furnaceReserve` whenever
the surviving lock cannot receive it. The LP-side share (`lpRewardClaim`) is
unaffected and continues to fund the LP rewards stream per §7.3.4.

The slippage gate (`minBonusOut`) MUST be evaluated on the surfaced
`bonusClaim` (i.e. `0` when the floor refund applies), so callers can opt in
to revert via `MinVeOutNotMet` rather than silently accepting a
zero-payout extension.

#### 7.3.5 LP overflow drip (protocol → LP rewards stream)

In addition to the per-lock LP top-up split (`lpRewardClaim`, §7.3.4), the protocol can fund LP rewards with a **periodic overflow drip** from the Furnace reserve.

Goal:
- Reduce the risk of a post-year-1 LP rewards cliff for volatile pools, while still allowing LP rewards to decline naturally as emissions decay into year 2.

Key properties (locked):

- The drip is independent of lock volume (it is not triggered by entries).
- It only pays when the reserve is above the healthy target:
  - `excess = max(0, furnaceReserve - RESERVE_TARGET_FINAL)`
  - If `excess == 0`, drip is 0.
- It is conservative and bounded:
  - hard cap: `LP_OVERFLOW_DRIP_FIXED_CAP_PER_DAY` (CLAIM/day)
  - inflow cap: `LP_OVERFLOW_DRIP_INFLOW_SHARE_CAP_BPS` of the **current Furnace inflow/day**
  - time ramp-in: starts at `LP_OVERFLOW_DRIP_START` and ramps linearly over `LP_OVERFLOW_DRIP_RAMP`
  - excess gate: `gBps = excess / (excess + LP_OVERFLOW_DRIP_GATE_K)` (bps form)

Destination:

- If LP rewards are enabled (`lpRewardsVault != address(0)`), the drip MUST be **funded into the LP rewards stream** (same destination concept as `lpRewardClaim`).
  - The stream drips to `lpRewardsVault` over `LP_STREAM_WINDOW` (§7.3.6).

Source of truth (exact math + rounding):

- `src/lib/Constants.sol` §3.4.6
- [Math and rounding appendix](../architecture/math-and-rounding-appendix-v1.0.0.md) §M.2 (LP overflow drip rounding)

#### 7.3.6 LP rewards stream (14-day smoothing)

All LP rewards that are funded by Furnace MUST be **streamed over time** to `LpStakingVault7D`.

Goal:
- Avoid large spikes/drops in the LP reward rate due to discrete large Furnace entries or single large sellbacks.

Constant (locked):
- `LP_STREAM_WINDOW = 14 days`

State (in Furnace):
- `uint256 lpStreamRatePerSec`
- `uint256 lpStreamPeriodFinish`
- `uint256 lpStreamLastUpdate`

Derived (definition; used for solvency accounting):
- `lpStreamRemaining`:
  - If `block.timestamp >= lpStreamPeriodFinish`: `0`
  - Else: `(lpStreamPeriodFinish - block.timestamp) * lpStreamRatePerSec`

Funding sources (MUST all route into the stream when LP rewards are enabled):
- Entry bonus split: `lpRewardClaim` from §7.3.4.
- LP overflow drip: `dripAmount` from §7.3.5.
- Sellback LP share: `lpReward` from §7.6.

Accrual (MUST):
- Before any operation that may fund or change the LP stream schedule, Furnace MUST accrue the stream:
  - `t = min(block.timestamp, lpStreamPeriodFinish_before)`
  - `owed = min(lpStreamRemaining_before, (t - lpStreamLastUpdate) * lpStreamRatePerSec)`
  - If `owed > 0`:
    - Transfer `owed` CLAIM to `lpRewardsVault`.
    - Best-effort call `LpStakingVault7D.notifyRewards(owed)` (delta-based; the vault ignores the caller-supplied amount and credits the observed CLAIM balance delta; see vault spec).
    - A reverting LP-vault notify MUST NOT revert the upstream Furnace flow; the CLAIM transfer remains funded in the vault and Furnace emits `LpRewardsNotifyFailed(...)`.
  - Set `lpStreamLastUpdate = t`.

Schedule update on funding (MUST; Synthetix-style rollover):
- On internal `_fundLpStream(amount)` when `amount > 0`:
  - If `block.timestamp >= lpStreamPeriodFinish`:
    - `lpStreamRatePerSec = floor(amount / LP_STREAM_WINDOW)`
  - Else:
    - `carry = (lpStreamPeriodFinish - block.timestamp) * lpStreamRatePerSec`
    - `lpStreamRatePerSec = floor((carry + amount) / LP_STREAM_WINDOW)`
  - `lpStreamPeriodFinish = block.timestamp + LP_STREAM_WINDOW`
  - Emit `LpStreamFunded(amountFunded, newRatePerSec, newPeriodFinish)` with the updated schedule.

Rounding note (non-binding):
- Any remainder from `floor(... / LP_STREAM_WINDOW)` stays as CLAIM dust in Furnace and is carried forward implicitly by the `carry` term on the next funding call.

Executor surface:
- `tick()` MUST be permissionless and MUST accrue the LP stream.
  - It MAY also execute the once-per-day LP overflow drip funding and MUST still enforce the per-day guard for overflow funding (see §7.3.5).

### 7.4 Reserve funding and invariants

Reserve funding sources (REQUIRED):

- MineCore emissions (Furnace stream):
  - MineCore MUST mint the Furnace emission stream to `Furnace` and call `Furnace.creditReserve(amount)` to record it.
  - `creditReserve(amount)` MUST be callable only by MineCore.

- Sellback net retention (§7.6):
  - On each successful sellback, Furnace MUST credit the computed `reserveAdd` into `furnaceReserve`.
  - Sellback is self-funded by the sold lock’s principal; it is not a MineCore emission.

Reserve spending / debits (REQUIRED):

- Gross bonus payouts on entries:
  - On each entry that pays a non-zero gross bonus, Furnace MUST decrease `furnaceReserve` by `grossBonusClaim`.
  - For the bonus path, `grossBonusClaim = userBonusClaim + lpRewardClaim` (§7.3.4).
  - If LP rewards are enabled, `lpRewardClaim` MUST be funded into the LP rewards stream (§7.3.6).

- LP overflow drip funding:
  - On each overflow funding execution with `dripAmount > 0`, Furnace MUST:
    - decrease `furnaceReserve` by `dripAmount`, and
    - fund the LP rewards stream by `dripAmount` (§7.3.5, §7.3.6).

Accounting note (important):
- `furnaceReserve` is an accounting variable and MUST NOT be derived from the ERC20 balance.
- Direct ERC20 transfers to Furnace are ignored by the accounting (they do not change `furnaceReserve`).

Invariants (REQUIRED):

- Non-negativity:
  - `furnaceReserve >= 0`.

- Bucketed solvency:
  - Let `lpStreamRemaining` be defined as in §7.3.6.
  - MUST hold: `ClaimToken.balanceOf(Furnace) >= furnaceReserve + lpStreamRemaining`.

- Bonus engine safety:
  - Any bonus payout MUST satisfy: `grossBonusClaim <= furnaceReserve_before`.

### 7.5 LP staking vault integration (LpStakingVault7D)

This is a first-class v1.0.0 mechanic:

- An on-protocol LP staking vault exists to incentivize Aerodrome CLAIM/WETH liquidity.
- Funding sources (no protocol fees):
  - Furnace LP stream (Furnace-funded LP rewards are streamed over `LP_STREAM_WINDOW`; see §7.3.6):
    - Per-entry LP top-up from the Furnace gross-bonus split (`lpRewardClaim`, §7.3.4).
    - LP overflow drip funding (`dripAmount`, §7.3.5).
    - Sellback LP share (`lpReward`, §7.6).
  - Donated LP-vault fee harvest (fees on staked LP; fees → swap to CLAIM → donate to LP rewards).
- This is not a protocol fee and does not create a treasury.
- No CLAIM is burned for LP-fee reward streams; fee-derived CLAIM is donated to LP stakers.
- Rewards are liquid CLAIM and are claimable by LP stakers.
- Users may compound LP vault rewards by locking them into Furnace bonus locks in one action:
  - `LpStakingVault7D.claimRewardsAndLock(...)` MUST route via `Furnace.enterWithClaimFor(user, claimAmount, targetTokenId, durationSeconds, createAutoMax, minVeOut)` using the user’s selected lock destination.
  - `minVeOut` MUST be enforced as slippage protection on the entry-attributable `veOut` returned by the quote / execution path.

- LP auto-compound is IN SCOPE for v1.0.0 (OFF by default):
  - Users configure it onchain via `LpStakingVault7D.setAutoCompoundConfig(enabled, tokenId, durationSeconds, maxSlippageBps)`.
  - The shipped code also exposes `LpStakingVault7D.setAutoCompoundConfigForUser(user, ...)`, gated by `P_SET_LP_AUTOCOMPOUND_CONFIG_FOR`. That delegated path MUST fail closed unless the live Furnace and MineCore still resolve the same canonical `DelegationHub` through one shared Furnace root (`MineCore.furnace() == Furnace`).
- `LpStakingVault7D.compoundFor(user)` MUST be keeper-allowlisted (owner + `setHarvestKeeper`). Slippage protection (`minVeOut`) is computed on-chain from the user's stored `maxSlippageBps` and a Furnace quote.
  - The official maintainer bot calls `compoundFor` directly (NOT via `MaintenanceHub`).

Full vault specification:
- See `docs/spec/lp-staking-vault-spec.md`.

### 7.6 veCLAIM sellback (lock → liquid CLAIM, Furnace buyback + burn)

v1.0.0 adds an optional **sellback** path that allows a lock owner to early-exit a veCLAIM position by selling it to the Furnace at a discount.

High-level:
- User sells a veCLAIM NFT to Furnace.
- Furnace takes custody, burns it, and withdraws the underlying CLAIM principal immediately.
- Furnace pays the seller liquid CLAIM (`claimOut`) < underlying principal (`lockAmount`), applying a dynamic spread.
- The retained amount (`lockAmount - claimOut`) is split:
  - `lpReward` (to LP rewards stream; §7.3.6)
  - `reserveAdd` (credited into `furnaceReserve`)

Economics goals:
- Provide an on-chain liquidity exit for locks without requiring an offchain market.
- Discourage sellbacks when locking participation is low (high Furnace bonus), to avoid a death spiral:
  - High bonus ⇒ higher sellback spread.
  - Low bonus ⇒ lower sellback spread.
- Penalize large sells via size-dependent spread, similar to the Furnace bonus AMM slippage.

Entry point (REQUIRED):
- `sellLockToFurnace(uint256 tokenId, uint256 minClaimOut, uint256 deadline)`:
  - Reverts if `lockingPaused`.
  - Requires `msg.sender` is the token owner.
  - User-facing settlement is routed through `MarketRouter`, which MUST auto-delist an active listing before the sellback.
  - MUST accrue the LP rewards stream before funding it (§7.3.6).
  - MUST execute the `VeClaimNFT.furnaceBurnAndWithdraw(tokenId, address(this))` flow (Furnace-only; see §4.5).
  - Determines `lockAmount` as the withdrawn principal.
  - Computes `claimOut`, `lpReward`, and `reserveAdd` using the pricing rules below.
  - Transfers `claimOut` CLAIM to the seller.
  - Credits `reserveAdd = lockAmount - claimOut - lpReward` into `furnaceReserve`.
  - Funds the LP rewards stream by `lpReward` (if enabled).
  - Emits `LockSoldToFurnace(...)` (§11.2).

MarketRouter-only helper (REQUIRED for sellLockToFurnace):
- `sellLockToFurnaceFromMarket(address seller, uint256 tokenId, uint256 minClaimOut)`:
  - Callable only by the canonically wired MarketRouter bundle. A raw `Furnace.mineMarket` pointer match is not sufficient.
  - MarketRouter MUST move the veNFT into Furnace custody with `safeTransferFrom(...)` before calling this helper. The receiver hook itself MUST fail closed against the same canonical MarketRouter / Ve / royalties / MineCore / Claim bundle check used by helper execution. Furnace records the observed `from` address during the receiver hook and rejects any `seller` argument that does not match that observed owner.
  - Uses the same pricing as `sellLockToFurnace` and pays CLAIM to `seller`.
  - MUST revert if the lock is still listed; MarketRouter is expected to clear listing state first.

Sellback pricing (pinned for v1.0.0; tunable constants in env-config):

Inputs:
- `L = lockAmount` (CLAIM principal withdrawn).
- `reserveBefore = furnaceReserve` (before crediting `reserveAdd`; used for sellback quotes).
- `elapsed = block.timestamp - launchTime` (same definition as §7.3.1).
- `lockedSupplyExcl` (total locked CLAIM excluding the sold lock; read after burning the sold lock, i.e. `VeClaimNFT.totalLockedClaim()` post-burn).
- `totalSupply = ClaimToken.totalSupply()`.
- `userSpotBonusBps` computed as the Furnace **user spot bonus** (§7.3.1) using `lockedSupplyExcl`, `totalSupply`, and `reserveBefore`:
  - `userSpotBonusBps = userSpotBonusBps(lockedSupplyExcl, totalSupply, reserveBefore, elapsed)`.
- `baseUserBps` computed as the lock-% anchored **base** user bonus (§7.3.1) using `lockedSupplyExcl` and `totalSupply`:
  - `baseUserBps = baseUserBps(lockedSupplyExcl, totalSupply)`.
- `remainingSec = max(0, lockEnd[tokenId] - block.timestamp)`.
  - For `autoMax` locks, treat `remainingSec = MAX_LOCK_DURATION`.

Step A: system spread from bonus (convex, with a no-arbitrage floor):
- Define the sell-side bonus reference (prevents reserve-drain manipulation):
  - `bonusBps = max(userSpotBonusBps, baseUserBps)`
- `bBps = clamp(floor(bonusBps * 10_000 / MAX_USER_BONUS_BPS), 0..10_000)`.
- Compute the no-arbitrage floor for the *current* bonus regime:
  - `spreadNoArbBps = ceil(10_000 * bonusBps / (10_000 + bonusBps))`.
- Compute the protocol curve:
  - `spreadCurveBps = SELL_SPREAD_MIN_BPS + floor((SELL_SPREAD_MAX_BPS - SELL_SPREAD_MIN_BPS) * (bBps^SELL_SPREAD_GAMMA) / (10_000^SELL_SPREAD_GAMMA))`.
- Use the higher of the two:
  - `spreadSystemBps = max(spreadNoArbBps, spreadCurveBps)`.

Step B: duration modifier (optional but RECOMMENDED):
- `durBps = sellDurationFactorBps(remainingSec)` (0..10_000; env-config §3.4E).
- `spreadDurBps = floor(spreadSystemBps * durBps / 10_000)`.

Step C: size modifier (AMM-like, discourages whales):
- `sizeRatioBps = floor(10_000 * L / (lockedSupplyExcl + L))`.
- `spreadBps = spreadDurBps + floor((SELL_SPREAD_MAX_BPS - spreadDurBps) * sizeRatioBps / 10_000)`.
- **v1.0.0 note:** `_sellSpreadWithSize` ignores `sizeRatioBps` — it returns `spreadDurBps` unchanged. The `sizeRatioBps` value is computed and included in `SellLockQuoteBreakdown` for analytics only. The size modifier formula is not active in v1.0.0.

Duration floor (at 7d remaining):
- If `remainingSec <= MIN_LOCK_DURATION`, enforce:
  - `spreadBps = max(spreadBps, SELL_SPREAD_FLOOR_7D_BPS)`.

Round-trip principal-loss floor (anti-flip, REQUIRED for v1.0.0+):
- Define `remainingClamped = clamp(remainingSec, MIN_LOCK_DURATION, MAX_LOCK_DURATION)`.
- Define the desired principal loss for an immediate buy→sell at this remaining duration:
  - `lossBps = ceil(SELL_ROUND_TRIP_LOSS_MAX_BPS * remainingClamped / MAX_LOCK_DURATION)`.
- Convert the principal-loss floor into a minimum sell spread (bps on lockAmount):
  - Compute the **effective buy bonus** at this duration (entry weights, see §7.3.2):
    - `buyWeightBps = durationWeightBps(remainingClamped)` (0..10_000)
    - `bBuyBps = floor(bonusBps * buyWeightBps / 10_000)`
  - Derive the required sell spread:
    - `spreadRoundTripFloorBps = ceil(10_000 * (bBuyBps + lossBps) / (10_000 + bBuyBps))`
  - Enforce:
    - `spreadBps = max(spreadBps, spreadRoundTripFloorBps)`.

Step C.2: burst sell impact add-on (anti-splitting, RECOMMENDED):
- Maintain a cumulative sell volume state that decays linearly to 0 over `BONUS_DECAY_WINDOW`:
  - `sellImpactVolume` (CLAIM; decays)
  - `lastSellImpactUpdate` (timestamp)
- For quotes, preview the decayed volume:
  - `volBefore = previewDecay(sellImpactVolume, lastSellImpactUpdate, BONUS_DECAY_WINDOW)`
  - `volAfter = volBefore + L`
- Compute dynamic thresholds (anchored to mining rate):
  - `kingRatePerSec = kingEmissionRateAt(block.timestamp)`
  - `eWindow = kingRatePerSec * BONUS_DECAY_WINDOW`  // expected King emission over the window
  - `freeVol = floor(eWindow / 2)`  // 0.5 * E3h
  - `stepVol = floor(eWindow / 5)`  // 0.2 * E3h
- Compute the add-on:
  - If `volAfter <= freeVol`: `impactBps = 0`
  - Else:
    - `excess = volAfter - freeVol`
    - `steps = floor(excess / stepVol)`
    - `impactBps = min(SELL_IMPACT_MAX_BPS, steps * SELL_IMPACT_BPS_PER_STEP)`
- Apply:
  - `spreadBps = min(SELL_SPREAD_MAX_BPS, spreadBps + impactBps)`
- On execution, update the state:
  - `sellImpactVolume = volAfter`
  - `lastSellImpactUpdate = block.timestamp`.

Step D: seller payout:
- `claimOut = floor(L * (10_000 - spreadBps) / 10_000)`.
- Enforce slippage protection: require `claimOut >= minClaimOut`.

Step E: cut split (reserve vs LP):
- `cut = L - claimOut`.

- Compute the **base** LP share of the cut (convex in `bBps`):
  - `lpSaleShareBpsBase = LP_SALE_MIN_BPS + floor((LP_SALE_MAX_BPS - LP_SALE_MIN_BPS) * (bBps^LP_SALE_GAMMA) / (10_000^LP_SALE_GAMMA))`.

- Apply **reserve-aware scaling (down-only)** so LP share never increases above the base curve:
  - `lpScaleBps = lpScaleBps(lockedSupplyExcl, totalSupply, reserveBefore, elapsed)`  // in [0..10_000]
  - `lpSaleShareBps = floor(lpSaleShareBpsBase * lpScaleBps / 10_000)`.

- Compute LP reward from the cut and apply the **daily sellback cap**:
  - `lpRewardRaw = floor(cut * lpSaleShareBps / 10_000)`.
  - If LP rewards are disabled (`lpRewardsVault == address(0)`), set `lpReward = 0`.
  - Otherwise:
    - `inflowPerDay = furnaceEmissionRateAt(t) * 1 days` (from MineCore schedule).
    - `lpRewardCapPerDay`:
      - if `inflowPerDay == 0`: `LP_SALE_REWARD_CAP_FIXED_CAP_PER_DAY` (MineCore unset / emission disabled).
      - else: `min(floor(inflowPerDay * LP_SALE_REWARD_CAP_INFLOW_SHARE_BPS / 10_000), LP_SALE_REWARD_CAP_FIXED_CAP_PER_DAY)`.
    - `lpRewardCapRemaining = max(0, lpRewardCapPerDay - lpSaleFundedToday)`.
    - `lpReward = min(lpRewardRaw, lpRewardCapRemaining)`.

- `reserveAdd = cut - lpReward`.

Notes:
- The cap applies only to the sellback-funded LP stream top-up (volume-driven LP funding).
- The cap does NOT apply to the time-based LP overflow drip.

Accounting (REQUIRED):
- Increase `furnaceReserve` by `reserveAdd`.
- Fund the LP rewards stream by `lpReward` (§7.3.6).

Safety notes (REQUIRED):
- Sellback MUST NOT be possible for an already-expired lock (`lockEnd <= block.timestamp`); users should unlock normally.
- Sellback MUST NOT be possible if the lock is listed on MarketRouter (must delist first).
- Furnace MUST NOT ever transfer a veCLAIM NFT from one user to another. In strict mode, only `MarketRouter` may transfer a lock, and only into Furnace custody (`to == furnace`) as part of settlement/sellback flows (§4.5).

---

## 8. MarketRouter

**Type**: veCLAIM lock management router (strict mode: Furnace-only settlements).

**Role in the immutable-core architecture (critical):**

- `MarketRouter` is the privileged lock-management router/adapter wired into `VeClaimNFT` as `mineMarket` (see Phase B wiring).
- Strict mode: there are no user-to-user lock sales or transfers. `MarketRouter` may only transfer a lock into Furnace custody (`to == furnace`) for settlement/sellback.
- `MarketRouter` MUST call `ShareholderRoyalties.checkpointTransfer` before moving a lock into Furnace custody (so ETH royalties accounting stays correct for the seller).
- Constructor hardening (REQUIRED): deployment MUST fail closed unless `claim`, `ve`, and `royalties` are non-zero live contracts, `ve.claimToken() == claim`, and `royalties.ve() == ve`.
- Runtime hardening (REQUIRED): settlement and auto-Furnace execution MUST resolve the live Furnace from `ve.furnace()` and fail closed unless `Furnace.{mineMarket,shareholderRoyalties}`, `ShareholderRoyalties`, `MineCore`, `ClaimToken`, and `VeClaimNFT` still point at the same canonical bundle. A raw stored/passed Furnace pointer is not sufficient.

**Upgradeability policy (pinned for v1.0.0):**

- MarketRouter is part of the proxy-backed runtime quartet; keep the proxy address canonical and route code upgrades through the owned proxy admin.
- Because MarketRouter may escrow user CLAIM (global-offer budgets), it remains a **high-trust** surface even with upgrades. The mitigation is governed proxy-admin control plus post-upgrade verification, not redeploying to a fresh address.

**Required mitigations (locked for v1.0.0):**

- Design MarketRouter to be as **non-custodial** as possible (minimize or externalize escrow where feasible).
- No sweep/rescue functions, ever.
- Any MarketRouter replacement (calling `VeClaimNFT.setMineMarket(...)`, `Furnace.setMineMarket(...)`, and `ShareholderRoyalties.setWiring(mineCore, newMarketRouter, furnace)`) is a protocol-level event.
  - If `MaintenanceHub` has already been deployed, it MUST be redeployed against the new bundle.
  - In production, deployment policy expects the relevant live `owner()` path to sit behind a multisig + timelock.

**Strict mode invariant (Furnace-only lock trading):**
- The **Furnace is the only counterparty** for lock purchases.
- There are **no user-to-user lock sales**.
- Listings are limit sells to the Furnace.
- Bonus target escrow orders are entry orders into the Furnace.

### 8.1 Listing model

Each listing is a **limit sell to the Furnace** with a price floor (`minClaimOut`).

Each listing includes at least:

- `tokenId`
- `seller`
- `minClaimOut` (price floor)
- `listedAtTime` (for emergency delist min-age checks, and for `Events.LockListed.listedAt`).

Additional per-token metadata (required):

- `lastListingActionBlock[tokenId]` for the 1-block cooldown between listing state changes (list/delist/relist/emergencyDelist), and to prevent same-block relist after a settlement.
  - MUST be updated on any listing state change, including clearing a listing via settlement.
  - MUST be enforced by requiring `block.number > lastListingActionBlock[tokenId]` on seller-controlled listing state changes (list/delist/relist/emergencyDelist).

**Implementation note**: Keep `listedAtTime` (time-based) separate from `lastListingActionBlock` (block-based). Using only timestamps makes the 1-block cooldown impossible; using only block numbers makes emergency-delisting min-age checks impossible.

### 8.2 Functions

1. `listLock(uint256 tokenId, uint256 minClaimOut, uint256 expiresAtTime)`
   - Create a limit sell order to the Furnace with a price floor and explicit expiry.
   - Require:
     - Caller owns `tokenId`.
     - MarketRouter is approved for that NFT.
     - Lock is not expired and not otherwise restricted.
     - `expiresAtTime > block.timestamp`.
     - `expiresAtTime <= lockEnd`.
   - Set listing and mark lock as `listed` by calling `VeClaimNFT.setListed(tokenId, true)`.
   - Enforce 1-block cooldown on any listing state change via `lastListingActionBlock[tokenId]` (see §8.1).

2. `delistLock(uint256 tokenId)`
   - Only seller can delist while local listing state is active.
   - Enforce the same 1-block cooldown via `lastListingActionBlock[tokenId]` and update it on delist.
   - Clear listing and `listed` flag by calling `VeClaimNFT.setListed(tokenId, false)`.
   - Replacement rescue: if the canonical `MarketRouter` address is rewired after a redeploy and the new router has no local listing record for `tokenId`, the current owner MUST still be able to call `delistLock(tokenId)` on the new router to clear a stale `VeClaimNFT.listed == true` flag and refresh the cooldown anchor.
   - MUST remain callable even when trading is paused (unwind path; users MUST be able to unstick positions).

3. Listing settlement (Furnace settles listing)
   - Strict-mode settlement does not include an approval-revoked self-clear path.
   - When the Furnace can meet the `minClaimOut` price floor, the approved listing is settled.
   - Canonical ordering (MUST):
     1. Read listing and require it is active.
     2. No approval-revoked shortcut exists in strict mode; settlement proceeds directly to keeper-grace auth, live listed-flag validation, and quote checks.
     3. For approved listings, enforce keeper-priority auth.
     4. Require the live `VeClaimNFT.listed` flag to still be `true`. A stale local listing slot alone is insufficient because canonical-router replacement rescue can clear the ve-level listed flag on a new router while an old router still retains local listing storage. If that old router is later rewired back, settlement MUST NOT resurrect that stale slot into a live sale.
     5. Verify Furnace can meet the `minClaimOut` price floor.
     6. Clear internal listing state and clear the VeClaimNFT listed flag (CEI anchor before custody transfer).
     7. Call `ShareholderRoyalties.checkpointTransfer(seller, furnace)` BEFORE veNFT transfer.
     8. Transfer veNFT to Furnace custody with `safeTransferFrom(...)`.
     9. Call `Furnace.sellLockToFurnaceFromMarket(seller, tokenId, minClaimOut)` on the canonically wired Furnace/MarketRouter bundle.
        - Furnace is the execution engine for seller payout and retained-cut accounting.
        - Furnace binds payout to the observed `safeTransferFrom(...)` sender and rejects a mismatched `seller` argument.
        - Seller receives `claimOut` CLAIM.
        - The retained cut `lockAmount - claimOut` is booked inside Furnace as `reserveAdd` plus optional `lpReward`.
     10. Emit `ListingSettled(tokenId, seller, claimOut, penalty)`, where `penalty = lockAmount - claimOut`.

4. `sellLockToFurnace(uint256 tokenId, uint256 minClaimOut, uint256 deadline)`
   - Instant sellback to the Furnace at the current protocol quote.
   - Preconditions:
     - Caller owns `tokenId` and MarketRouter is approved.
     - `block.timestamp <= deadline`.
   - Double-sale prevention:
     - If the lock has an active listing, it MUST be cleared (auto-delist) before the sellback.
   - Route the lock to the Furnace and receive CLAIM.
   - If a listing was auto-cancelled, emit `LockDelisted(tokenId, seller, SOLD_TO_FURNACE)`.

#### 8.2.1 Bonus Target Escrow (Entry Order into Furnace)

A Bonus Target Escrow is a standing order that executes into the Furnace once the Furnace can meet the user's target bonus. This is the ONLY way to place conditional entry orders in v1.0.0.

**Key concepts:**
- `targetBonusBps` — the minimum Furnace bonus the user requires before execution
- `slippageBps` — tolerance for deriving `minVeOut` at execution time
- `budgetClaim` — CLAIM escrowed for Furnace entry
- `durationSeconds` — lock duration for the resulting ve lock
- `createAutoMax` — whether to create/add to an AutoMax lock
- `destinationLockId` — optional existing lock to add to (0 = create new)
- `escrowTtlSeconds` — time-to-live before expiry

**UI minimum behavior (normative for the official UI):**
- Bonus target slider minimum MUST equal `Furnace.getFurnaceState().quoteUserBonusBps`.
- The UI MUST always show the user's "Minimum received (minVeOut)" for any Furnace entry path.

5. `createBonusTargetEscrowWithTarget(uint256 targetBonusBps, uint256 budgetClaim, uint256 durationSeconds, bool createAutoMax, uint256 escrowTtlSeconds, uint256 destinationLockId, uint256 slippageBps)`
   - Create a conditional entry order that executes into Furnace when the target bonus is available.
   - MUST fail closed unless this router still resolves the live canonical Furnace / ShareholderRoyalties / MineCore / ClaimToken / VeClaimNFT market bundle.
   - Enforce (at creation only) (MUST):
     - `budgetClaim >= minBonusTargetEscrowBudget`.
     - `MIN_LOCK_DURATION <= durationSeconds <= MAX_LOCK_DURATION`.
     - Escrow TTL bounds (if `escrowTtlSeconds == 0`, use `DEFAULT_BONUS_TARGET_ESCROW_TTL_SECONDS`; else require `1 <= escrowTtlSeconds <= MAX_BONUS_TARGET_ESCROW_TTL_SECONDS`).
     - If `destinationLockId != 0`, it MUST be an eligible creator-owned lock:
       - owned by creator
       - not listed
       - not expired (AutoMax = never treated as expired)
       - AutoMax flag matches `createAutoMax`
   - Store `expiresAt = block.timestamp + effectiveTtlSeconds`.
   - Escrow `budgetClaim` CLAIM in MarketRouter as `fundsRemaining`.
   - Store `targetBonusBps` and `slippageBps` in `BonusTargetConfig` mapping.
   - Emit two events (two-event pattern for immutable contracts):
     1. `BonusTargetEscrowCreated(escrowId, buyer, discountBps, durationSeconds, createAutoMax, expiresAt, destinationLockId, budgetClaim, createdAt)` — base escrow data (discountBps is derived from targetBonusBps)
     2. `BonusTargetEscrowConfigured(escrowId, buyer, targetBonusBps, slippageBps)` — bonus target configuration
   - Raw indexers (Dune) can join these two events by `escrowId` to reconstruct the full escrow state.

6. `cancelBonusTargetEscrow(uint256 offerId)`
   - Only creator can cancel while this router is still canonical.
   - If this router is no longer the live canonical market surface for the current Furnace / ShareholderRoyalties / MineCore / ClaimToken / VeClaimNFT bundle, cancellation becomes permissionless as an unwind rescue and still refunds the creator.
   - Refund remaining `fundsRemaining` CLAIM to creator and mark escrow inactive.
   - MUST remain callable even when trading is paused (unwind path).
   - Emit `BonusTargetEscrowCancelled(escrowId, buyer, refundClaim)`.

7. `cancelExpiredBonusTargetEscrow(uint256 offerId)`
   - Permissionless once expired (`block.timestamp >= expiresAt`).
   - Refund remaining `fundsRemaining` CLAIM to creator and mark escrow inactive.
   - MUST remain callable even when trading is paused (unwind path).
   - Emit `BonusTargetEscrowExpired(escrowId, buyer, refundClaim)`.

8. `extendBonusTargetEscrowExpiry(uint256 offerId, uint256 newExpiresAt)`
   - Creator-only.
   - MUST fail closed unless this router still resolves the live canonical Furnace / ShareholderRoyalties / MineCore / ClaimToken / VeClaimNFT market bundle.
   - Require escrow is active and not expired.
   - Require `newExpiresAt > expiresAt`.
   - Require `newExpiresAt <= offer.createdAt + MAX_BONUS_TARGET_ESCROW_TTL_SECONDS`.
   - Update stored expiry.
   - Emit `BonusTargetEscrowExpiryExtended(escrowId, buyer, oldExpiresAt, newExpiresAt)`.

9. `executeAutoFurnace(uint256 offerId, uint256 deadline)`
   - MUST revert with `DeadlineExpired` if `block.timestamp > deadline`.
   - During `SETTLEMENT_KEEPER_GRACE_SECONDS`, only allowlisted settlement keepers and the `MarketRouter` owner may call. After that, the function is permissionless.
   - Expected caller in production: a **team-operated keeper bot** that monitors escrows and submits this transaction once executable.
   - The function remains permissionless after the grace window so anyone can execute if the keeper is down.
   - MUST revert if `tradingPaused == true`.
   - Preconditions (MUST):
     - Escrow is active, not expired (`block.timestamp < expiresAt`), and has `fundsRemaining > 0`.
   - Trigger check MUST use the amount-specific quote for the remaining budget using the escrow's duration + AutoMax settings:
     - Resolve the destination lock at execution time:
       - If `destinationLockId != 0` and the lock is still eligible (owned by creator, not listed, not expired; AutoMax matches), use it.
       - Else set `resolvedLockId = 0` (create new).
       - Clarification: if `resolvedLockId == 0`, minting a new lock requires `fundsRemaining >= MIN_LOCK_AMOUNT` (1,000 CLAIM; see §4.1). If the remaining budget is below `MIN_LOCK_AMOUNT`, this path is not executable; the creator can cancel, extend expiry and wait, or let the escrow expire and be unwound.
     - Derive `executionDurationSeconds` from the resolved destination semantics:
       - If `resolvedLockId == 0`, use the escrow's stored `durationSeconds`.
       - If `resolvedLockId != 0` and the destination lock is AutoMax, use `MAX_LOCK_DURATION`.
       - If `resolvedLockId != 0` and the destination lock is non-AutoMax, use its live remaining duration (`lockEnd - block.timestamp`) because entry does not extend duration.
     - Call `Furnace.quoteEnterWithClaim(buyer, fundsRemaining, resolvedLockId, executionDurationSeconds, createAutoMax)` → `(principalClaim, bonusClaim, veOut, routeTokenId)`
     - Compute `bonusBpsVsPrincipalClaim = floor(bonusClaim * 10_000 / principalClaim)`
     - Require `bonusBpsVsPrincipalClaim >= targetBonusBps`
     - Derive `minVeOut` from the same quote and stored slippage:
       - `minVeOut = floor(veOut * (10_000 - slippageBps) / 10_000)`
       - If `veOut > 0` but floor-rounding would produce `minVeOut == 0`, clamp to `1` before calling Furnace.
   - Execution (MUST):
     - Route the remaining `fundsRemaining` CLAIM into Furnace for the creator via:
       - `Furnace.enterWithClaimFor(buyer, fundsRemaining, resolvedLockId, executionDurationSeconds, createAutoMax, minVeOut)` (ENTER_WITH_CLAIM path).
     - Enforce `minVeOut` slippage protection on the entry-attributable `veOut` returned by the quote / execution path.
     - Close the escrow (set `fundsRemaining = 0` and mark inactive).
   - CEI ordering (MUST):
     1. Snapshot `fundsRemaining` into a local variable and set stored `fundsRemaining = 0` (close escrow) before external calls.
     2. Call Furnace and bubble reverts if `minVeOut` is not met.
     3. Emit `BonusTargetEscrowExecuted(escrowId, buyer, claimIn, principalClaim, bonusClaim, veOut, routeTokenId, furnaceTokenId)`.
     4. Emit `BonusTargetEscrowAutoFurnaceExecuted(escrowId, buyer, claimIn, principalClaim, bonusClaim, veOut, routeTokenId, furnaceTokenId)` as the back-compat companion receipt.

10. `emergencyDelist(uint256 tokenId)`
   - Safety valve for stuck listings.
   - MUST be callable only by the listing seller.
   - Allowed if listing age exceeds `EMERGENCY_DELIST_MIN_AGE` (7 days).
   - MUST be callable even if `tradingPaused == true`.
   - MUST update `lastListingActionBlock[tokenId]` when force-clearing the listing.

11. `pauseTrading(bool paused)`
   - Guardian-only.
   - Sets `tradingPaused = paused`. Unpause by calling `pauseTrading(false)`.
   - When `tradingPaused == true`, `listLock`, `sellLockToFurnace`, `sellListedLockToFurnace`, `createBonusTargetEscrowWithTarget`, `extendBonusTargetEscrowExpiry`, and `executeAutoFurnace` MUST revert.
   - `delistLock`, `cancelExpiredListing`, `cancelBonusTargetEscrow`, `cancelExpiredBonusTargetEscrow`, and `emergencyDelist` MUST remain callable (unwind / housekeeping paths).

### 8.3 Constraints & invariants

- 0% protocol fee (no treasury skim).
- Listing settlements: duration-based penalty (99% at 365d, ~1% at 7d) is the retained sellback cut `lockAmount - claimOut` (not a protocol fee). Seller receives `claimOut`. Furnace books that cut as `reserveAdd` plus optional `lpReward` funding into the LP stream.
- Bonus target escrow execution routes CLAIM into Furnace (0% fee).
- Prices denominated only in CLAIM.
- Listed locks cannot be mutated in VeClaimNFT:
  - No addToLockFor, extend, merge, unlock, or setAutoMax while listed.
- Reentrancy protection on all settlement functions.

Economic griefing / spam controls (v1.0.0 defaults)

- Bonus target escrow spam controls (MarketRouter owner-managed config; v1 defaults):
  - `minBonusTargetEscrowBudget = 10_000e18` (10,000 CLAIM)

- Per-escrow expiry (TTL):
  - Each escrow stores `expiresAt` (timestamp), set at creation from `escrowTtlSeconds`:
    - If `escrowTtlSeconds == 0`, use `DEFAULT_BONUS_TARGET_ESCROW_TTL_SECONDS`.
    - Else require `1 <= escrowTtlSeconds <= MAX_BONUS_TARGET_ESCROW_TTL_SECONDS`.
  - Escrows MUST reject execution at or after expiry (`block.timestamp >= expiresAt`).
  - Remaining budget is refundable via `cancelBonusTargetEscrow` (buyer-only) or `cancelExpiredBonusTargetEscrow` (permissionless after expiry).
  - Buyer MAY extend expiry via `extendBonusTargetEscrowExpiry` (`newExpiresAt <= offer.createdAt + MAX_BONUS_TARGET_ESCROW_TTL_SECONDS`).
- Enforcement semantics:
  - These minimums MUST be enforced **only** at escrow creation time (`createBonusTargetEscrowWithTarget(...)`).
  - Raising minimums later affects **only new escrows**.
  - Existing escrows keep their stored parameters and remain executable (subject to remaining budget and normal constraints).
- Governance:
  - Configurable via the live `owner()` path (production policy expects multisig + timelock).
  - Policy: minimums can only increase, never decrease.
  - There is no `MarketRouter.freezeConfig()`. Escrow parameters remain owner-managed via timelock + multisig.
  - `MarketRouter.renounceOwnership()` MUST revert so redeploy + rewire, settlement-keeper management, spam-control changes, and the documented owner break-glass execution path remain live.
  - `MarketRouter.setGuardian(address)` MUST reject `address(this)` because the router cannot call its own guardian-gated pause surface.
- Prefer UI/analytics filtering over strict onchain per-address escrow limits unless explicitly needed.

---

## 9. ClaimAll helper

`ClaimAllHelper` is a stateless helper to combine King + Baron rewards.

- `claimAll(uint8 mode, uint256 targetTokenId, uint256 durationSeconds, bool createAutoMax, uint256 minVeOut)`:
  - Calls `ShareholderRoyalties.claimShareholderFor(msg.sender, mode, targetTokenId, durationSeconds, createAutoMax, minVeOut)`.
  - Calls `MineCore.withdrawKingBalanceFor(msg.sender)` inside `try` / `catch (bytes memory reason)`. King withdrawal failure emits `Events.KingWithdrawalFailed(msg.sender, reason)` and is swallowed; the baron claim is NOT wrapped in `try/catch` and reverts the entire transaction on failure.

Implementation note:

- Since `ClaimAllHelper` is a separate contract, it cannot preserve `msg.sender` inside the downstream contracts.
  Therefore, MineCore and ShareholderRoyalties expose helper-only "for" entrypoints that preserve the exact same
  accounting as the direct-call functions, but pay out to an explicit `user`.
- `ShareholderRoyalties.claimShareholderFor(...)` and `MineCore.withdrawKingBalanceFor(...)` MUST be restricted to
  the configured ClaimAllHelper address.
- The ClaimAllHelper address MUST be wired into both contracts during Phase B wiring.
- Delegation-gated helper wrappers (`claimShareholderForUser`, `withdrawKingBalanceForUser`, `claimAllFor`) MUST fail
  closed unless live `MineCore`, `ShareholderRoyalties`, and their shared `Furnace` still resolve one canonical
  delegation bundle. At minimum:
  - `MineCore.claimAllHelper() == address(this)`
  - `MineCore.royalties() == ShareholderRoyalties`
  - `ShareholderRoyalties.claimAllHelper() == address(this)`
  - `ShareholderRoyalties.mineCore() == MineCore`
  - `MineCore.furnace() == ShareholderRoyalties.furnace()`
  - `Furnace.mineCore() == MineCore`
  - `Furnace.shareholderRoyalties() == ShareholderRoyalties`
  - `Furnace.delegationHub() == MineCore.delegationHub()`
- A raw `MineCore.delegationHub()` read is not sufficient for delegated helper authorization.
- `claimShareholderForUser` and `claimAllFor` MUST reject any non-zero `mode` after authorization clears.
  Delegated shareholder Collect MUST settle ETH to `user` and MUST NOT route the payout into a Furnace lock;
  LOCK_FURNACE Collect remains user-direct via `ShareholderRoyalties.claimShareholder(...)`.

It MUST NOT change economics and only orchestrates the same payout logic.

---

## 10. Admin, guardian, and upgrades (locked pattern)

### 10.1 Roles (locked)

- **ADMIN** = `owner` (OpenZeppelin `Ownable2Step`) on all configurable contracts.
  - Production deployment policy expects ADMIN to be a multisig + timelock (not an EOA); contracts themselves enforce only the live `owner()` path.
- **GUARDIAN** = fast-response safety address (stored as `guardian`).
  - Long-term guardian keys can pause/unpause takeovers, locking, and trading, can perform the documented disable-only `EntryTokenRegistry` action, and can use the documented `setGuardian(address)` emergency self-rotation path on rotatable surfaces.
  - Long-term guardian keys MUST NOT be able to upgrade, confiscate NFTs, change economics, or access any reusable mint/sweep/fund-moving surface.
  - Launch-phase exception: before `genesisKingClaimCollected == true`, `MineCore.guardian` may be the `LaunchController` contract. Installing that LaunchController guardian is owner-only. Only that canonical LaunchController-like guardian for this exact `MineCore + CLAIM` pair receives the additional one-shot `MineCore.collectGenesisKingClaim(address to)` privilege; a pre-existing contract owner/guardian does not.

### 10.2 Access-control implementation standard (locked)

Use this exact pattern:

- `Ownable2Step` for ADMIN ownership (owner = timelock multisig).
- A separate `guardian` address for safety actions (pause surfaces on core contracts, disable-only token-entry controls on registries, and documented `setGuardian(address)` emergency self-rotation on rotatable surfaces), except for the one-shot `LaunchController` contract guardian during genesis.
- A one-way config freeze on the **five core game-rule contracts**:

  - `ClaimToken`, `Furnace`, `MineCore`, `VeClaimNFT`, and `ShareholderRoyalties` each implement `bool configFrozen`, `modifier whenNotFrozen`, and `function freezeConfig() external onlyOwner` that permanently locks their core game-rule wiring setters (see Phase C).
  - `MarketRouter` is proxy-backed but has no wiring setters to freeze. `LpStakingVault7D` uses constructor-only immutables and has no wiring setters to freeze.
  - `EntryTokenRegistry` has its own ratchet locks (wrappedNative/claimToken are one-way immutable after first init; router/factory cannot change once tokens are configured).
  - Operational peripherals (`setDelegationHub`, `setEntryTokenRegistry`, keeper allowlists) remain `onlyOwner`, protected by timelock + multisig.

All wiring/config setter functions MUST be `onlyOwner`, except `setGuardian` and the documented operational allowlist setters (`MarketRouter.setSettlementKeeper`, `ShareholderRoyalties.setAutoCompoundKeeper`, `LpStakingVault7D.setHarvestKeeper`) (see below).

Guardian rotation (emergency fast path):
- `setGuardian(newGuardian)` MUST be callable by `owner`.
- v1.0.0 rotatable surfaces also allow the current `guardian` to call `setGuardian(newGuardian)` as an emergency fast path, subject to documented exceptions (notably the MineCore pre-genesis contract-guardian lock and the requirement that `Furnace.guardian` may only re-assert `MineCore` once set). That path MUST always remain callable to recover from guardian compromise.
- Every nonzero guardian assignment MUST run `_rejectDelegatedEOA(newGuardian)` so that EIP-7702 delegated EOAs (addresses carrying the 23-byte designator `0xef0100 || target`) revert `DelegatedEOA` on every rotatable surface, including the `MineCore` post-genesis branch where the guardian is otherwise allowed to be a bare EOA. Bare EOAs and ordinary contracts pass; the rejection prevents a 7702 signer from inheriting the public pause / disable / rotate surface by replacing the underlying executor.
- MineCore genesis exception: before `genesisKingClaimCollected == true`, only `owner` may install the LaunchController-style contract guardian; once that contract guardian is installed, rotation remains locked until `genesisKingClaimCollected == true`.
- On `ClaimToken`, it MUST NOT be gated by `whenNotFrozen` (guardian rotation must survive the ClaimToken freeze).
- It MUST remain callable even while the protocol is paused, so it MUST NOT be gated by any pause modifier.

### 10.3 DexAdapter change policy (v1.0.0)

Policy (v1.0.0, locked):

- **Direct roots + proxy-backed runtime:** keep `ClaimToken` and `VeClaimNFT` direct. Deploy `MineCore`, `Furnace`, `MarketRouter`, and `ShareholderRoyalties` behind transparent proxies and treat the proxy addresses as canonical. `Wire.s.sol` finalizes ClaimToken by freezing `setMineCore()` and renouncing ownership once canonical wiring succeeds. The freeze-and-burn sequence then permanently locks the documented core wiring setters on Furnace (shareholderRoyalties/mineCore/mineMarket/furnaceQuoter/lpRewardsVault), MineCore (furnace/claimAllHelper), VeClaimNFT (furnace/mineMarket), and ShareholderRoyalties (mineCore/mineMarket/furnace/claimAllHelper), while burning the four runtime proxy admins. Operational peripherals remain owner-managed via timelock + multisig.
- `MarketRouter` is part of the proxy-backed runtime quartet; upgrades happen through its proxy admin rather than redeploy + bundle rewire.
- No `GameRouter` contract is part of v1.0.0, and it MUST NOT be implemented or deployed.
- `DexAdapter` is deployed directly (no proxy) and has **no** UUPS upgrade surface.
  - Exported DexAdapter ABIs MUST NOT include any UUPS upgrade functions.
  - DEX/router changes in v1.0.0 are executed by redeploying `DexAdapter` and calling `EntryTokenRegistry.setRouterConfig(...)` through the live owner() path (typically timelocked in production) (no core rewiring required).
    - Once the WETH/CLAIM hop or any token config exists, use a fresh registry deployment instead of rewiring router/factory in place.

Hard rules:

- Routers/adapters MUST NOT include **any** generic sweep/rescue/admin-drain functions, ever — except the bounded DexAdapter rescue functions (`rescueETH`, `rescueToken`) documented in §10.4.
- DexAdapter MUST NOT expose a governance setter that swaps the underlying Aerodrome router (e.g., `setAerodromeRouter`).
  - Router/DEX changes MUST occur only via redeploying `DexAdapter` and calling `EntryTokenRegistry.setRouterConfig(...)` through the live owner() path (typically timelocked in production).
- DexAdapter MUST be non-custodial and MUST NOT retain user funds across calls.
  - If a contract holds escrowed user funds (e.g., marketplace bids), it becomes a high-trust surface and MUST be timelocked (via ownership, not upgradeability).

DexAdapter upgradeability boundary:
- `DexAdapter` has no proxy upgrade surface in v1.0.0.

### 10.4 No rescue / sweep in v1.0.0

v1.0.0 ships with **no generic admin rescue/sweep functions**, with bounded exceptions.

- v1.0.0 MUST NOT include any rescue/sweep/admin-drain function that withdraws arbitrary ERC20 tokens or ETH, except the bounded exceptions listed below.
  - Examples of banned function names (outside the exceptions): `sweepToken`, `sweepETH`, `recoverERC20`.
- The only allowed balance movements are the documented game flows:
  - takeovers + ETH split accounting
  - shareholder ETH claims / lock routing
  - Furnace entry swaps + lock routing
  - MarketRouter escrow + settlement
  - VeClaimNFT lock lifecycle (unlock returns principal)
  - LaunchController bounded donation handling during `finalizeGenesis()` (pool donation skim + residual token sweep to guardian)
- Bounded rescue exceptions:
  - DexAdapter `rescueETH(address payable to)` (owner-only, `nonReentrant`): recovers native ETH accidentally stuck in the adapter from Aerodrome router refunds. DexAdapter should never hold ETH long-term. The only legitimate receive path is refunds from failed router swaps (`receive()` is gated to `aerodromeRouter` only).
  - DexAdapter `rescueToken(IERC20 token, address to)` (owner-only, `nonReentrant`): recovers ERC-20 tokens accidentally stuck in the adapter. DexAdapter should never hold ERC-20 balances long-term.
  - MineCore `rescueEth(address to)` (owner-only, `nonReentrant`): recovers ETH not tracked by any accounting bucket (`totalKingEthOwed`, `totalRefundEthOwed`, `shareholderEthPending`). Bounded to the difference between `address(this).balance` and the sum of these global aggregate counters.
  - MineCore `rescueClaim(address to)` (owner-only, `nonReentrant`): recovers CLAIM not tracked by `totalPendingKingClaim`. Bounded to the difference between the CLAIM token balance and `totalPendingKingClaim`.
  - ShareholderRoyalties `sweepDust(address to)` (owner-only): sweeps rounding-residual ETH dust.
  - GenesisLPVault24M `rescueEth()` (`lpWithdrawRecipient`-only, `nonReentrant`): recovers force-sent ETH (e.g. via `selfdestruct` or coinbase). The vault holds only LP tokens by design and has no `receive()`/`fallback()`, so ETH can only arrive via force-send.
  - GenesisLPVault24M `withdrawLp()` Aerodrome trading-fee forwarding (`lpWithdrawRecipient`-only, `nonReentrant`): inside `withdrawLp()`, the vault calls `pool.claimFees()` and `safeTransfer`s the resulting `token0` / `token1` balances to the immutable `lpWithdrawRecipient` BEFORE the LP transfer. NOT a generic sweep — (a) the source is bounded to `pool.claimFees()` only (no arbitrary token can be moved); (b) the destination is fixed to immutable `lpWithdrawRecipient`; (c) the value extracted is fees the vault's own LP position earned over the 24-month lock that Aerodrome v2 holds in per-LP-holder `claimable0/1` slots separate from pool reserves and that would otherwise be permanently stranded against the vault's address after the LP transfer. The fee-claim and forward step is also `try/catch`-wrapped (best-effort) so a misbehaving pool cannot DoS LP recovery. Same step also runs in the residual-LP branch (`unlockTime == 0`, post-canonical-withdraw). See `docs/spec/vault-spec.md` *withdrawLp()* / *MUST NOT scope*.

Upgradeability boundary:
- The bounded exceptions above are the full fund-moving admin surface in v1.0.0.

Forbidden:
- Admin actions MUST NOT change ETH split, emission schedule constants, or introduce fees/taxes.
- Admin actions MUST NOT seize user veCLAIM NFTs or user balances.

## 11. Views and analytics (for indexers and dashboards)

This section defines views and events that enable rich analytics dashboards (Dune, Flipside, etc.) without changing core economics.

### 11.1 Common views

These MUST be implemented as read-only helpers that mirror the underlying state:

- **VeClaimNFT (locks)**
  - `getLockInfo(uint256 tokenId)` – `(amount, lockEnd, autoMax, listed)` (4-tuple).
  - Indexers enumerate tokenIds owned by a user via ERC721 Transfer events.
    - v1.0.0 enforces a per-user veNFT cap (`MAX_VE_NFTS_PER_USER`, currently 32).
    - Onchain helpers that enumerate a user’s tokenIds (example: `veBalanceOf(user)`) are permitted only because this cap keeps the loop gas-bounded.

- **MineCore (Kings & reigns)**
  - `getReignInfo(uint256 reignId)` – key data about a reign:
    - king address, startTime, optional endTime, pricePaid, referencePrice, totalClaimMined, totalEthToKing.
  - `getKingReigns(address king, uint256 cursor, uint256 limit)` – paginated list of reignIds for a King (limit is clamped to `MAX_KING_REIGNS_PER_CALL`).

- **Furnace (bonus state)**
  - `getFurnaceState()` – `(reserve, lockedSupply, userSpotBonusBps, lpTopupRateBps, quoteUserBonusBps, quoteLpTopupBps, virtualDepth, lastUpdate)`.
    - `reserve` is the current Furnace reserve (CLAIM wei).
    - `lockedSupply` is the current ve locked supply (CLAIM wei), sourced from `VeClaimNFT.totalLockedClaim()`.
    - IMPORTANT: `lockedSupply` MUST NOT be derived from `CLAIM.balanceOf(address(VeClaimNFT))`; direct CLAIM transfers to VeClaimNFT are treated as donations and are not counted by `totalLockedClaim()`.
    - `userSpotBonusBps` is the **net user** spot cap (bps of principal; <= 10_000).
    - `lpTopupRateBps` is the LP top-up rate (bps of the user bonus; 0 when LP vault is unset).
    - `quoteUserBonusBps` is the **net user** small-entry quote (UI headline) at `MAX_LOCK_DURATION`.
    - `quoteLpTopupBps` is the additive LP top-up small-entry quote.
    - `virtualDepth` is the decayed-preview of the bonus AMM virtual depth used for quoting.
    - `lastUpdate` is the last bonus AMM update timestamp.

    - Useful derivations (offchain or in UI):
      - `quoteLpTopupBps = floor(quoteUserBonusBps * lpTopupRateBps / 10_000)`.
      - The internal gross quote used for clamping can be slightly higher than `quoteUserBonusBps + quoteLpTopupBps` because the LP side is derived from the floored user quote.
      - `grossSpotBps = userSpotBonusBps + floor(userSpotBonusBps * lpTopupRateBps / 10_000)`.
      - `reserveFullnessBps` / `reserveFactorBps` can be derived from `reserve`, `launchTime`, and env-config §3.4.2.

  - LP rewards stream transparency (read-only helpers):
    - `getLpStreamState()` – `(ratePerSec, periodFinish, lastUpdate, remaining)`.
    - `getLpStreamRemaining()` – `remaining` (CLAIM wei; same definition as §7.3.6).

  - LP overflow drip transparency (read-only helpers):
    - `getFurnaceInflowPerDay()` – current MineCore → Furnace inflow used by the drip cap (CLAIM/day).
    - `getCapInflowPerDay()` – current inflow-share cap/day (CLAIM/day; see §7.3.5).
    - `getLpOverflowDripPerDay()` – current computed overflow drip/day (CLAIM/day; see §7.3.5).
    - `tick()` – permissionless accumulator step that:
      - accrues the LP rewards stream (transfers any owed amount to `lpRewardsVault`), and
      - MAY also execute the once-per-day LP overflow drip funding (if enabled).
      - returns `dripped` (CLAIM wei transferred to `lpRewardsVault` in this call).

  - `quoteEnterWithEth(address user, uint256 ethIn, uint256 targetTokenId, uint256 durationSeconds, bool createAutoMax)` – `(principalClaim, bonusClaim, veOut, routeTokenId)`.
  - `quoteEnterWithClaim(address user, uint256 claimIn, uint256 targetTokenId, uint256 durationSeconds, bool createAutoMax)` – `(principalClaim, bonusClaim, veOut, routeTokenId)`.
  - `quoteEnterWithToken(address user, address tokenIn, uint256 amountIn, uint256 targetTokenId, uint256 durationSeconds, bool createAutoMax)` – `(principalClaim, bonusClaim, veOut, routeTokenId)`.
    - In these quote views:
      - `bonusClaim` is the **net** user bonus (it does not include the LP top-up).
      - `routeTokenId` MUST be consistent with `targetTokenId`:
        - If `targetTokenId == 0`, `routeTokenId` MUST be `0`.
        - If `targetTokenId != 0`, `routeTokenId` MUST equal `targetTokenId`.

  - `quoteSellLockToFurnace(address user, uint256 tokenId)` – `(lockAmount, claimOut, spreadBps, lpReward, reserveAdd)`.
- `quoteSellLockToFurnaceBreakdown(address user, uint256 tokenId)` – struct with sell quote components:
  - Includes intermediate bonus inputs (for UI + analytics):
    - `spotBonusBps` – user spot bonus (depends on current reserve).
    - `baseBonusBps` – lock%-anchored base bonus (reserve-independent).
    - `bonusRefBpsUsed` – sell-math bonus reference (`max(spotBonusBps, baseBonusBps)`).
      - `bonusBpsUsed` is kept for backward compatibility and MUST equal `bonusRefBpsUsed`.
    - `isBonusClampBinding` – convenience boolean: true iff `spotBonusBps < baseBonusBps` (the clamp binds).
  - Also includes: `spreadSystemBps`, `durFactorBps`, `spreadDurBps`, `sizeRatioBps`, plus final `(claimOut, spreadBps, lpReward, reserveAdd)`.

- **ShareholderRoyalties (Barons)**
  - `getShareholderState(address user)` – `(claimableEthLive, userVe, userEthPerVePaid)`.
    - `claimableEthLive` MUST include stored `claimableEth` plus any uncheckpointed rewards implied by historical reward checkpoints.
    - Offchain clients MUST treat this first field as authoritative and MUST NOT add a separate `currentVe * (ethPerVe - paid)` term.
  - System-level reads are exposed via existing getters (`ethPerVe()`, `pendingShareholderETH()`, and `ve.totalVeCached()`).
  - (REQUIRED) `getAutoCompoundConfig(address user)` – `(enabled, paused, tokenId, durationSeconds, minCadenceSeconds, minEthToCompound, maxSlippageBps, lastCompoundTs)`.

- **MarketRouter** (lock management — strict mode: Furnace-only)
  - `getListing(uint256 tokenId)` – listing struct `(seller, minClaimOut, listedAtTime, expiresAtTime, active)`.
  - `getBonusTargetEscrow(uint256 offerId)` – base escrow struct `(buyer, discountBps, durationSeconds, createAutoMax, destinationLockId, fundsRemaining, createdAt, expiresAt, active)`.
  - `bonusTargetConfigs(uint256 offerId)` – target/slippage config `(targetBonusBps, slippageBps, configured)`.
  - `getUserListings(address user)` – list of listed `tokenId` values.
  - `getUserBonusTargetEscrows(address user)` – list of `offerId` values (the same numeric identifier emitted as `escrowId` in `BonusTargetEscrow*` events).
  - `totalEscrowedClaim()` – total CLAIM currently held in active bonus target escrows (sum of all `fundsRemaining`).

These views MUST always reflect the real on-chain state; they MUST NOT add any derived or cached balances that diverge from core storage.

### 11.2 Events (for analytics)

Dune dashboards should be built primarily from:
- decoded events
- ERC20 / ERC721 transfers
- traces (fallback only)

Canonical event schema (names + parameter order) and the enum/codebook mappings are defined in:
- `docs/analytics/dune-integration-pack-v1.0.0.md`

`src/lib/Events.sol` is a **convenience mirror** for implementers.
Contracts may emit library-declared events (example: `emit Events.Takeover(...)`) or declare identical events locally.

In all cases, emitted event signatures MUST match the Dune integration pack.

See also:
- `docs/analytics/dune-integration-pack-v1.0.0.md` (addresses, start blocks, enum codebook)
- `docs/analytics/leaderboards-ui-and-dune-compatible-v1.0.0.md` (only official leaderboards)

Recommended events:

- **Common admin / transparency**
  - `event GuardianChanged(address indexed oldGuardian, address indexed newGuardian);`
  - `event ConfigFrozen();` (ClaimToken, Furnace, MineCore, VeClaimNFT, ShareholderRoyalties)
  - `event OwnershipTransferStarted(address indexed previousOwner, address indexed newOwner);` (OpenZeppelin `Ownable2Step`)
  - `event OwnershipTransferred(address indexed previousOwner, address indexed newOwner);` (OpenZeppelin `Ownable`)

- **EntryTokenRegistry** (allowlist + routing transparency)
  - `event RouterConfigSet(address indexed router, address indexed factory, address indexed wrappedNative, address claimToken);`
    - Note: non-anonymous events are limited to 3 indexed params; claimToken is included in data.
  - `event WethClaimPoolSet(address indexed pool, bool stable);`
  - `event TokenConfigSet(address indexed tokenIn, bool enabled, bool directToClaimEnabled, bool tokenClaimStable, address tokenClaimPool, bool tokenWethStable, address tokenWethPool);`
  - `event TokenEnabledChanged(address indexed tokenIn, bool enabled);`

- **VeClaimNFT** (lock lifecycle)
  - `event LockCreated(address indexed user, uint256 indexed tokenId, uint256 amount, uint256 lockEnd, bool autoMax);`
  - `event LockExtended(address indexed user, uint256 indexed tokenId, uint256 oldEnd, uint256 newEnd);`
  - `event LockAmountIncreased(address indexed user, uint256 indexed tokenId, uint256 amountAdded);`
  - `event LockMerged(address indexed user, uint256 indexed fromTokenId, uint256 indexed intoTokenId, uint256 amountMoved);`
  - `event LockUnlocked(address indexed user, uint256 indexed tokenId, uint256 amountReturned);`
  - `event AutoMaxSet(address indexed user, uint256 indexed tokenId, bool autoMax);`
  - `event DelegationSessionUsed(address indexed user, address indexed delegate, uint8 indexed actionType, uint256 permsUsed, uint256 refId, uint256 timestamp);`

- **MineCore** (Kings & takeovers)
  - `event EntryTokenRegistrySet(address indexed registry);`
  - `event Takeover(uint256 indexed reignId, address indexed previousKing, address indexed newKing, uint256 pricePaid, uint256 referencePrice, uint256 timestamp);`
  - `event ReignRecipientsSet(uint256 indexed reignId, address indexed king, address indexed ethRecipient, address claimRecipient);`
  - `event DelegationSessionUsed(address indexed user, address indexed delegate, uint8 indexed actionType, uint256 permsUsed, uint256 refId, uint256 timestamp);`
  - `event ReignFinalized(uint256 indexed reignId, address indexed king, uint256 startTime, uint256 endTime, uint256 totalClaimMined, uint256 totalEthToKing);`
  - `event TakeoversPausedChanged(bool paused);`
  - `event KingWithdrawal(address indexed king, uint256 amount);`
  - `event KingAutoLockConfigured(address indexed user, bool enabled, uint256 targetTokenId, uint256 pinnedTokenId, uint256 durationSeconds, bool createAutoMax, uint256 minVeOut);`
  - `event KingAutoLockExecuted(uint256 indexed reignId, address indexed user, uint256 principalClaim, uint256 tokenIdUsed);`
  - `event KingAutoLockSkipped(uint256 indexed reignId, address indexed user, uint256 principalClaim, uint8 reasonCode);`
  - `event KingAutoLockFailed(uint256 indexed reignId, address indexed user, uint256 principalClaim, bytes revertData);`

- **ShareholderRoyalties** (Barons’ ETH)
  - `event ShareholderTakeoverAllocation(uint256 indexed reignId, uint256 amountEth);`
  - `event ShareholderFlush(uint256 amountEth, uint256 deltaEthPerVe);`
  - `event ShareholderClaim(address indexed user, uint8 mode, uint256 amountEth);`
  - `event DelegationSessionUsed(address indexed user, address indexed delegate, uint8 indexed actionType, uint256 permsUsed, uint256 refId, uint256 timestamp);`
  - `event ShareholderAutoCompoundConfigured(address indexed user, bool enabled, uint256 tokenId, uint256 durationSeconds, uint32 minCadenceSeconds, uint256 minEthToCompound, uint32 maxSlippageBps);`
  - `event ShareholderAutoCompoundKeeperSet(address indexed keeper, bool allowed);`
  - `event ShareholderAutoCompoundPaused(address indexed user, uint256 tokenId, uint8 reasonCode);`
  - `event ShareholderAutoCompoundExecuted(address indexed user, address indexed executor, uint256 amountEth, uint256 tokenId, uint256 effectiveDurationSeconds);`

- **Furnace** (entries + reserve)
  - `event EntryTokenRegistrySet(address indexed registry);`
  - `event LpRewardsVaultSet(address indexed oldVault, address indexed newVault);`
  - `event DelegationSessionUsed(address indexed user, address indexed delegate, uint8 indexed actionType, uint256 permsUsed, uint256 refId, uint256 timestamp);`
  - `event FurnaceEnter(address indexed user, uint8 mode, uint256 ethIn, uint256 principalClaim, uint256 bonusClaim, uint256 tokenId);`
  - _The following three events are emitted from the Furnace address via `delegatecall` into `FurnaceGuardHelper` (EIP-170 relief). They are declared in `IFurnace` so they appear in Furnace's compiled ABI._
  - `event BonusPaid(address indexed user, uint256 principal, uint256 principalEff, uint256 grossBonusClaim, uint256 userBonusClaim, uint256 lpTopupClaim, uint256 userSpotBonusBps, uint256 lpTopupRateBps, uint256 grossSpotBonusBps, uint256 quoteUserBonusBps, uint256 quoteLpTopupBps, uint256 lockDurationSec, uint256 reserveBefore, uint256 reserveAfter, uint256 virtualDepthBefore, uint256 virtualDepthAfter);`
  - `event LockSoldToFurnace(address indexed seller, uint256 indexed tokenId, uint256 lockAmount, uint256 claimOut, uint256 spreadBps, uint256 cut, uint256 lpSaleShareBps, uint256 lpReward, uint256 reserveAdd, uint256 bonusRefBpsUsed);`
  - `event LpOverflowDripPaid(uint256 dripAmount, uint256 reserveBefore, uint256 reserveAfter, uint256 alphaBps, uint256 gateBps, uint256 capInflowPerDay, uint256 capFixedPerDay, uint256 reserveTarget, uint256 excessBefore);`
  - `event LpRewardsNotifyFailed(address indexed vault, uint256 amountClaim, bytes revertData);`
  - `event LpStreamFunded(uint256 amountFunded, uint256 newRatePerSec, uint256 newPeriodFinish);`
  - `event ReserveCredited(uint256 amount, uint256 newReserve);`
  - `event ReserveClamped(address indexed caller, uint256 oldReserve, uint256 newReserve, uint256 claimBalance, uint256 lpStreamLiability);`
  - `event LockingPausedChanged(bool paused);`

- **LpStakingVault7D** (LP staking vault)
  - `event LpStaked(address indexed user, uint256 amount);`
  - `event LpUnbondStarted(address indexed user, uint256 indexed unbondId, uint256 amount, uint256 unlockTime);`
  - `event LpUnbondWithdrawn(address indexed user, uint256 indexed unbondId, uint256 amount);`
  - `event LpRewardsNotified(uint256 amountClaim);`
  - `event LpRewardsClaimed(address indexed user, uint256 amountClaim);`
  - `event LpRewardsLocked(address indexed user, uint256 amountClaim, uint256 principalClaim, uint256 bonusClaim, uint256 tokenId);`
  - `event AutoCompoundConfigured(address indexed user, bool enabled, uint256 tokenId, uint256 durationSeconds, uint32 maxSlippageBps, uint256 minRewardToCompound);`
  - `event AutoCompoundPaused(address indexed user, uint256 tokenId, uint8 reasonCode);`
  - `event LpFeesHarvestedToRewards(address indexed caller, uint256 feeWeth, uint256 feeClaim, uint256 claimToRewards);`
  - `event DelegationSessionUsed(address indexed user, address indexed delegate, uint8 indexed actionType, uint256 permsUsed, uint256 refId, uint256 timestamp);`

- **LaunchController** (genesis finalization)
  - `event GenesisFinalized(uint256 timestamp, uint256 claimMinted, uint256 claimToLiquidity, uint256 lpMinted, address pool, address genesisLpVault);`

- **GenesisLPVault24M** (genesis LP lock)
  - `event Locked(uint256 lpAmount, uint256 lockStartTime, uint256 unlockTime);`
  - `event LockExtended(uint256 oldUnlockTime, uint256 newUnlockTime);`
  - `event WithdrawLp(address indexed to, uint256 amount);`

- **MarketRouter** (lock management — strict mode: Furnace-only)
  - `event LockListed(uint256 indexed tokenId, address indexed seller, uint256 minClaimOut, uint256 listedAtTime, uint256 expiresAtTime);`
  - `event LockDelisted(uint256 indexed tokenId, address indexed seller, uint8 reason);`
  - `event ListingSettled(uint256 indexed tokenId, address indexed seller, uint256 claimOut, uint256 penalty);`
  - `event MarketSellToFurnace(uint256 indexed tokenId, address indexed seller, uint256 minClaimOut, uint256 deadline, uint256 claimOut);`
  - `event TradingPausedChanged(bool paused);`
  - `event BonusTargetEscrowParamsChanged(uint256 oldMinBudget, uint256 newMinBudget, uint256 oldMaxDiscountBps, uint256 newMaxDiscountBps);`
  - `event BonusTargetEscrowCreated(uint256 indexed escrowId, address indexed buyer, uint256 discountBps, uint256 durationSeconds, bool createAutoMax, uint256 expiresAt, uint256 destinationLockId, uint256 budgetClaim, uint256 createdAt);`
  - `event BonusTargetEscrowExpired(uint256 indexed escrowId, address indexed buyer, uint256 refundClaim);`
  - `event BonusTargetEscrowExpiryExtended(uint256 indexed escrowId, address indexed buyer, uint256 oldExpiresAt, uint256 newExpiresAt);`
  - `event BonusTargetEscrowCancelled(uint256 indexed escrowId, address indexed buyer, uint256 refundClaim);`
  - `event BonusTargetEscrowConfigured(uint256 indexed escrowId, address indexed buyer, uint256 targetBonusBps, uint256 slippageBps);`
  - `event BonusTargetEscrowExecuted(uint256 indexed escrowId, address indexed buyer, uint256 claimIn, uint256 principalClaim, uint256 bonusClaim, uint256 veOut, uint256 routeTokenId, uint256 furnaceTokenId);`
  - `event BonusTargetEscrowAutoFurnaceExecuted(uint256 indexed escrowId, address indexed buyer, uint256 claimIn, uint256 principalClaim, uint256 bonusClaim, uint256 veOut, uint256 routeTokenId, uint256 furnaceTokenId);`
  - `event SettlementKeeperSet(address indexed keeper, bool allowed);`

Clarification:
- Dune does not reliably call view functions for “current state” panels.
- For “current state” dashboards, prefer “latest-event” patterns (pause toggles, config set, etc.) and deterministic formulas driven by events.

### 11.3 Leaderboards (UI + Dune compatible)

v1.0.0 defines a small, fixed set of off-chain leaderboards for:
- UI (application)
- Dune dashboards

These leaderboards are computed from events and are not computed on-chain.

Canonical definition:
- `docs/analytics/leaderboards-ui-and-dune-compatible-v1.0.0.md`
Indexer/Dune implementation notes:
- `docs/analytics/indexer-and-dune-implementation-guide-v1.0.0.md`

The ONLY official v1.0.0 leaderboards are (8 total; see the canonical document above
for full presentation rules and address-label requirements):

Crown (Mine Game)
1. Top CLAIM mined as King
   - Duration filter: last 24h, last 7d (default), last 30d, lifetime
   - Metric: `SUM(ReignFinalized.totalClaimMined)` by `king`
   - Duration semantics: include a reign iff its `MineCore.ReignFinalized` event occurred within the window (filter by `ReignFinalized.evt_block_time`). Not prorated.
2. Longest reign
   - Duration filter: last 24h, last 7d (default), last 30d, lifetime
   - Metric: `MAX(endTime - startTime)` per `king` (longest single reign, in seconds)
3. Most takeovers executed
   - Duration filter: last 24h, last 7d (default), last 30d, lifetime
   - Metric: `COUNT(Takeover)` by `newKing`
4. Top ETH spent on takeovers
   - Duration filter: last 24h, last 7d (default), last 30d, lifetime
   - Metric: `SUM(Takeover.pricePaid)` by `newKing`

Furnace (includes Barons)
5. Top royalties claimed
   - Duration filter: last 24h, last 7d (default), last 30d, lifetime
   - Metric: `SUM(ShareholderClaim.amountEth)` by `user` (includes both ETH and LOCK_FURNACE modes)
6. Top veCLAIM holders (current)
   - Timeframe: current snapshot only (no duration filter)
   - Metric: snapshot `veBalance` per address at latest block
7. Top CLAIM sent to Furnace
   - Duration filter: last 24h, last 7d (default), last 30d, lifetime
   - Metric: `SUM(FurnaceEnter.principalClaim)` by `user`
8. Top ETH sent to Furnace
   - Duration filter: last 24h, last 7d (default), last 30d, lifetime
   - Metric: `SUM(FurnaceEnter.ethIn)` by `user`

Rules:
- Sort descending by metric.
- Do not show APY, ROI, net "earned", concentration/share metrics, or profit projections.
- Do not add any other leaderboards in v1.0.0.

## 12. Summary of MUST / MUST NOT

**MUST**

- Enforce all invariants in Section 2.
- Implement exactly the v1.0.0 contract set (no unapproved extras):
  - Immutable core: ClaimToken, VeClaimNFT, MineCore, ShareholderRoyalties, Furnace, LpStakingVault7D
  - Routers/adapters: MarketRouter, DexAdapter
  - Registry: EntryTokenRegistry
  - Helper: ClaimAllHelper
- Use Furnace as the only bonus system.
- Anchor the spot bonus cap to liquid CLAIM supply, and enforce bonuses via the AMM.
- Enforce `minVeOut` on all ETH→CLAIM+lock routes.
- Restrict veCLAIM transfers to MarketRouter (plus mint/burn).
- Respect 75/25 ETH split and takeover pricing rules.

**MUST NOT**

- Add any protocol fees, dev taxes, or hidden treasuries.
- Allow circumventing MarketRouter for ve transfers.
- Allow upgrade logic to introduce a hidden sweep/rescue path that can steal protocol-accounted balances.
- Let King accrue “free” emissions during paused periods.

This document is meant to be implementation-friendly: if any implementation deviates from this SPEC, it is a bug unless explicitly justified and updated here.
