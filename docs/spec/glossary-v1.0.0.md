# docs/spec/glossary-v1.0.0.md

This file defines **canonical terms** used across the ClaimRush v1.0.0 documentation.

If a term is used inconsistently across docs, this glossary definition wins.

---

## Tokens and units

- **CLAIM**
  - The primary ERC-20 token used by the game.
  - Units: `1e18` decimals unless stated otherwise.

- **veCLAIM**
  - The locked-CLAIM balance issued by the Furnace; determines royalty share.
  - Implemented as an NFT (each lock is a tokenId).
  - Not transferable as a balance; ownership is via NFT ownership.

- **WETH / ETH**
  - ETH is the native asset.
  - WETH is used for AMM routing (see Aerodrome integration docs).

- **bps**
  - Basis points.
  - `10_000 bps = 100%`.
  - Canonical denominator: `BPS_DENOM = 10_000` (see `src/lib/Constants.sol`).

- **durationSeconds**
  - Lock duration expressed in seconds.
  - Canonical duration bounds: `[MIN_LOCK_DURATION, MAX_LOCK_DURATION]` (see constants doc).

- **MIN_LOCK_AMOUNT**
  - Protocol minimum CLAIM required to **create a new veCLAIM lock NFT**.
  - `MIN_LOCK_AMOUNT = 1,000 CLAIM` (`1_000e18`).
  - Applies to `createLock` / `createLockFor` (minting only). Adding to an existing lock may be any `amount > 0`.

---

## Core game concepts

- **King**
  - The current top player address in `MineCore`.
  - Becomes king by executing a valid **takeover**.

- **Reign**
  - The time interval where a specific king remains king.
  - Ends the instant a new king successfully takes over.

- **Takeover**
  - The onchain action that replaces the current king with a new one.
  - Payment is made in ETH (and optionally through token routing as defined in spec).

- **Reference price**
  - The base takeover price used by the takeover price function before decay.
  - See takeover decay rules in `src/lib/Constants.sol`.

---

## Locks and marketplace

- **Lock / ve position**
  - A veCLAIM NFT representing locked principal CLAIM + lock end timestamp + configuration flags.

- **Listed**
  - A lock that is listed for sale to the Furnace via `MarketRouter` with a `minClaimOut` price floor.

- **Bonus Target Escrow**
  - A conditional entry order that executes into the Furnace when the target bonus is available.
  - Defined by `targetBonusBps`, `budgetClaim`, `durationSeconds`, and optional `destinationLockId`.
  - The Furnace is the only counterparty — this is NOT a bid to acquire locks from other users.

---

## Furnace (entry + bonus engine)

- **Furnace**
  - Entry engine that converts ETH/CLAIM (and optionally other tokens) into locked veCLAIM.
  - Also mints/allocates a **bonus** on top of user principal under the shared bonus model.

- **Principal**
  - The portion of an entry that comes from the user’s own funds (after routing/swap).

- **Bonus**
  - Additional CLAIM allocated from a shared reserve, quoted and paid using the spot-cap + AMM model.
  - The canonical bonus math is in `src/lib/Constants.sol` (Spot cap + AMM).

- **Duration weight**
  - Non-linear multiplier in bps applied to principal inside the bonus model.
  - Canonical curve: `src/lib/Constants.sol` §3.4D.

---

## Roles, pausing, and governance

- **Owner**
  - Admin role for contract configuration. In production, behind timelock + multisig.

- **Guardian**
  - Limited role to pause user-facing actions during incidents.
  - Canonical pause rules: `docs/spec/spec-v1.0.0.md` and security docs.

- **Freeze**
  - A one-way transition on each of the five core contracts that permanently locks their core game-rule wiring setters via `freezeConfig()`.
  - `ClaimToken` locks `setMineCore()`; `Furnace` locks `setShareholderRoyalties()`, `setMineCore()`, `setMineMarket()`, `setFurnaceQuoter()`, `setLpRewardsVault()` while the delayed emergency LP-vault recovery path (`requestEmergencyVaultRewire(address)`, `cancelEmergencyVaultRewire()`, `executeEmergencyVaultRewire()`) remains callable after freeze; `MineCore` locks `setFurnace()`, `setClaimAllHelper()`, `setDelegationHub()`; `VeClaimNFT` locks `setFurnace()`, `setMineMarket()`; `ShareholderRoyalties` locks `setWiring()`, `setClaimAllHelper()`.
  - After freeze, operational peripherals (entryTokenRegistry, keeper allowlists, guardian) remain owner-configurable via timelock + multisig. `Furnace.setDelegationHub` is owner-mutable post-freeze by design (the authoritative hub identity is frozen on `MineCore`, and `Furnace.setDelegationHub` validates against `MineCore.delegationHub()`).

---

## Automation and maintenance

- **Keeper bot (official)**
  - An offchain automation service operated by the team.
- Watches onchain events and calls maintenance functions to keep UX smooth (market auto-fallback, checkpoints, flushes, tick, and keeper tasks).

- **Executor (auto-compound)**
  - The address that calls `compoundFor` / `compoundForMany` for an opted-in user.
- In v1.0.0, Baron auto-compound and LP auto-compound are keeper-allowlisted with owner break-glass; the official keeper is the expected primary executor for both.

- **MaintenanceHub**
  - A permissionless onchain bundler that aggregates multiple maintenance actions into a single transaction.
  - Spec: `docs/spec/maintenance-hub-spec-v1.0.0.md`.

- **Poke**
  - A single maintenance transaction (typically a call to `MaintenanceHub.poke(...)`).
  - Designed to be safe and best-effort: one failing sub-action does not revert the entire poke.

- **Staleness-based bounty**
  - Historical concept: a bounty paid when a maintenance action was stale.
  - Not used by `LpStakingVault7D.harvestFeesToRewards` in v1.0.0 (which is owner-or-keeper-allowlisted and pays no bounty).
  - The remaining staleness-related bounty in v1.0.0 is `MaintenanceHub.poke(...)`'s WETH delta forwarding (`bountyWethForwarded`), which is incidental subcall byproduct and not a staleness gate.

---

## Indexing and analytics

- **Event schema / enum codebook**
  - Canonical indexing expectations live in `docs/analytics/dune-integration-pack-v1.0.0.md`.
  - If any event naming differs elsewhere, the Dune integration pack wins for analytics consumers.

---

## Referrals (UI-only)

- **Referral code**
  - A 6-character alphanumeric code used in invite links (`?ref=XXXXXX`).
  - Not a wallet address.

- **Referrer**
  - The player whose referral code is used in an invite link.

- **Referred player**
  - A player who lands with a referral code and later completes their first meaningful onchain action.

- **Pending referral**
  - A referral code captured from the URL and stored locally, waiting for redemption.

- **Qualified referral**
  - A referred player who successfully redeems after their first meaningful onchain action.

- **Meaningful onchain action (referrals)**
  - Any one of these first-time actions by a wallet:
    - `VeClaimNFT.LockCreated` (first lock created)
    - `ShareholderRoyalties.ShareholderClaim` (first royalties claim)
    - `MineCore.Takeover` where the wallet is `newKing` (first takeover)

This definition is the canonical v1.0.0 referrals glossary entry.
