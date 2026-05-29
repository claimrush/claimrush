# Freeze-and-Burn Finality

ClaimRush v1.0.0 reaches permanent runtime finality through one timelocked ceremony. The launch window is governed and patchable. The end state is public, delayed, and irreversible.

Finality is a two-part ceremony for the proxy-backed runtime quartet:

- `freezeConfig()` locks the documented core wiring setters on the five freeze-gated contracts (ClaimToken freezes at wire time; the remaining four freeze in the ceremony)
- burning the four runtime `ProxyAdmin` owners removes quartet upgrade authority forever

The quartet is:

- `MineCore`
- `Furnace`
- `MarketRouter`
- `ShareholderRoyalties`

The direct permanent roots remain:

- `ClaimToken`
- `VeClaimNFT`

## What the ceremony does

`ClaimToken` freezes at wire time: `ClaimToken.freezeConfig()` and `ClaimToken.renounceOwnership()` execute at the end of `Wire.s.sol`, immediately after wiring. `ClaimToken` has no post-freeze owner knobs (no pause, no metadata, no guardian), so ownership is dead weight after freeze. By the time the ceremony runs, it is already frozen and ownerless.

The canonical finality batch is therefore 8 operations:

1. `MineCore.freezeConfig()`
2. `Furnace.freezeConfig()`
3. `VeClaimNFT.freezeConfig()`
4. `ShareholderRoyalties.freezeConfig()`
5. `MineCore ProxyAdmin.renounceOwnership()`
6. `Furnace ProxyAdmin.renounceOwnership()`
7. `MarketRouter ProxyAdmin.renounceOwnership()`
8. `ShareholderRoyalties ProxyAdmin.renounceOwnership()`

This ordering is mandatory.

- Every freeze call runs before any proxy-admin burn
- If any freeze precondition fails, the whole batch reverts
- No runtime proxy admin is ever burned unless all four ceremony freezes succeed first
- The script asserts that ClaimToken is already frozen before scheduling

## What finality means

After the batch executes successfully:

- All five freeze-gated contracts (`ClaimToken`, `MineCore`, `Furnace`, `VeClaimNFT`, `ShareholderRoyalties`) report `configFrozen() == true` (ClaimToken was already frozen at wire time)
- the runtime quartet can no longer be upgraded
- the quartet proxy addresses remain the canonical live addresses
- `ClaimToken` and `VeClaimNFT` remain direct permanent roots

Finality means both layers are locked:

- wiring is locked by the five `freezeConfig()` calls (ClaimToken freezes at wire time; the remaining four freeze in the ceremony)
- runtime logic is locked by burning the four runtime `ProxyAdmin`s
- the public governance window is over for the runtime itself

## What stays mutable afterward

Finality is not full protocol owner renounce.

The timelock still owns the protocol `owner()` paths after the burn, so documented post-freeze operational knobs remain available, including:

- `MineCore.guardian` (rotatable; `MineCore.setGuardian` has no freeze gate)
- `MineCore.entryTokenRegistry` (`MineCore.setEntryTokenRegistry` has no freeze gate)
- `Furnace.entryTokenRegistry` (`Furnace.setEntryTokenRegistry` has no freeze gate)
- `Furnace.delegationHub` (`Furnace.setDelegationHub` has no freeze gate, but is reciprocal-binding-gated against `MineCore.delegationHub`). Note the freeze asymmetry: `MineCore.setDelegationHub` IS `whenNotFrozen`, so the MineCore-side hub is permanently locked at the ceremony. A real post-freeze hub rotation therefore requires the new hub to be live in `MineCore.delegationHub` *before* the canonical freeze; afterwards, `Furnace` can only adopt that already-pinned address.
- `Furnace.guardian` is pinned to `MineCore` (atomically set inside `Furnace.setMineCore`, and `Furnace.setGuardian` only allows re-asserting the current `mineCore`). `Furnace.setMineCore` IS `whenNotFrozen`, so post-freeze `Furnace.guardian` is fixed to the MineCore proxy address — the operational guardian is rotated via `MineCore.setGuardian`, not on Furnace directly.
- Furnace delayed emergency LP-vault recovery (`requestEmergencyVaultRewire` / `cancelEmergencyVaultRewire` / `executeEmergencyVaultRewire` are owner-only with no freeze gate)
- `MarketRouter` policy knobs such as settlement keepers and bonus-target escrow params
- `VeClaimNFT` metadata URIs (`setBaseURI`, `setContractURI`) — these are gated by `whenMetadataNotFrozen`, not `whenNotFrozen`, so the canonical `freezeConfig()` ceremony does not lock them. They can be permanently locked at any time via the separate one-way `freezeMetadata()` call (`src/VeClaimNFT.sol`).
- `ShareholderRoyalties` compounding keepers/floors

Those actions no longer happen instantly. They remain timelocked governance actions.

Contracts whose setter is `whenNotFrozen` (ClaimAllHelper, FurnaceQuoter, LpStakingVault7D) are permanently locked after the ceremony. Contracts whose setter has no freeze gate (entry-token registries, DelegationHub, DexAdapter) remain reconfigurable through the timelock — the Security page shows these as "Configurable" after finality. See the full before/after table at the end of this document.

## Governance path

The production chain of authority is:

- `Safe -> TimelockController -> ProxyAdmin -> runtime proxy`
- `Safe -> TimelockController -> protocol owner()`

Defaults:

- `PROPOSER_ROLE = Safe`
- `CANCELLER_ROLE = Safe`
- `EXECUTOR_ROLE = Safe`

The guardian remains separate and immediate for pause/unpause response.

## Why the delay matters

The freeze-and-burn batch is intentionally timelocked before execution.

That delay is not just an operational buffer:

- it creates a public onchain countdown to finality
- the exact batch calldata is visible before execution
- the Safe can cancel if anything looks wrong
- users and integrators can see that permanent runtime immutability is approaching
- operators get one final review window before the protocol crosses into permanent runtime finality

On mainnet, that countdown is part of the protocol’s credibility story.

## Operational sequence

1. Finish deployment, wiring, and genesis
2. Transfer ownership to the timelock
3. Bootstrap the timelock roles and renounce deployer admin
4. Complete verification while quartet upgrades are still available
5. When ready for permanent finality, schedule the freeze-and-burn batch
6. Wait the timelock delay
7. Execute the batch
8. Verify frozen state and burned proxy admins onchain

## Required scripts

- `FinalizeOwnership.s.sol`
- `FinalizeTimelockBootstrap.s.sol`
- `TimelockAcceptOwnership.s.sol`
- `TimelockRuntimeUpgrade.s.sol`
- `FreezeAndBurn.s.sol`

## Emergency model before finality

Before the burn, critical runtime bugs are handled in the standard order:

1. guardian pauses the affected surface immediately
2. governance schedules the runtime upgrade through the timelock
3. wait the delay
4. execute and verify
5. unpause only after the corrective change is confirmed live

## Post-finality model

After the burn:

- runtime upgrades are impossible
- surviving owner knobs still require the timelock delay
- “post-freeze operational change” means `schedule -> wait -> execute`, not “call the setter directly”
- the timelock remains load-bearing governance, not a ceremonial leftover

## Verification checklist

After execution, confirm:

- all five `configFrozen()` values are `true`
- each runtime `ProxyAdmin.owner()` is `address(0)`
- `python3 scripts/verify_deployment.py --network <network> --rpc-url "$RPC_URL" --require-frozen` passes
- the deployment manifest still shows the same quartet proxy addresses
- the manifest `proxyAdminOwner` values are updated to `0x0000000000000000000000000000000000000000`

## Contract upgradeability before and after finality

The Security page reads `configFrozen()` and proxy-admin ownership (EIP-1967 admin slot) to detect each contract's upgradeability status live. The table below is the definitive reference for all deployed contracts.

**Proxy-backed runtime quartet** (Yes → No):

| Contract | Before ceremony | After ceremony | Mechanism |
|---|---|---|---|
| MineCore | Yes | No | ProxyAdmin ownership renounced |
| Furnace | Yes | No | ProxyAdmin ownership renounced |
| MarketRouter | Yes | No | ProxyAdmin ownership renounced |
| ShareholderRoyalties | Yes | No | ProxyAdmin ownership renounced |

**Direct permanent roots and non-proxy contracts** (always No):

| Contract | Before ceremony | After ceremony | Mechanism |
|---|---|---|---|
| ClaimToken | No | No | Direct root, frozen at wire time |
| VeClaimNFT | No | No | Direct root, no proxy |
| TimelockController | No | No | Plain contract, no proxy |
| GenesisLPVault24M | No | No | Not redeployable |

**Configurable peripherals** (Redeploy → Configurable):

| Contract | Before ceremony | After ceremony | Mechanism |
|---|---|---|---|
| FurnaceEntryTokenRegistry | Redeploy | Configurable | `setEntryTokenRegistry` has no freeze gate |
| MineCoreEntryTokenRegistry | Redeploy | Configurable | `setEntryTokenRegistry` has no freeze gate |
| DelegationHub | Redeploy | Configurable | `Furnace.setDelegationHub` has no freeze gate (gated by `requireCanonicalDelegationHub` reciprocal-binding check); `MineCore.setDelegationHub` is `whenNotFrozen`, so a post-freeze replacement requires the new hub to be live in MineCore *before* the canonical freeze. |
| DexAdapter | Redeploy | Configurable | Swapped via registry, no freeze gate |

Before the ceremony, governance can replace these by deploying a new instance and re-pointing the protocol. After the ceremony, the pointer remains writeable (timelocked), so in-place configuration changes are still possible — the status changes to "Configurable" to reflect that the contract is modified in place rather than replaced wholesale.

**Frozen redeploy contracts** (Redeploy → No):

| Contract | Before ceremony | After ceremony | Mechanism |
|---|---|---|---|
| ClaimAllHelper | Redeploy | No | `setClaimAllHelper` is `whenNotFrozen` on both MineCore and ShareholderRoyalties |
| FurnaceQuoter | Redeploy | No | `setFurnaceQuoter` is `whenNotFrozen` on Furnace |
| LpStakingVault7D | Redeploy | No | `setLpRewardsVault` is `whenNotFrozen` on Furnace |

**Standalone peripherals** (Redeploy → Redeploy):

| Contract | Before ceremony | After ceremony | Mechanism |
|---|---|---|---|
| MaintenanceHub | Redeploy | Redeploy | Standalone, no onchain pointer from a frozen contract |
| MineCoreQuoter | Redeploy | Redeploy | Standalone, no onchain pointer |
| AgentLens | Redeploy | Redeploy | Standalone read-only lens |

**Retired**:

| Contract | Before ceremony | After ceremony | Mechanism |
|---|---|---|---|
| LaunchController | Retired | Retired | Genesis-only, no longer active post-launch |

## Related pages

- [runtime-proxy-upgrades.md](runtime-proxy-upgrades.md)
- [security-guardian-pausing.md](security-guardian-pausing.md)
- [genesis.md](genesis.md)
- [protocol-overview.md](protocol-overview.md)
