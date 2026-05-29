# Runtime Proxy Upgrades

ClaimRush v1.0.0 keeps two permanent direct roots:

- `ClaimToken`
- `VeClaimNFT`

The live runtime is a transparent-proxy quartet:

- `MineCore`
- `Furnace`
- `MarketRouter`
- `ShareholderRoyalties`

This runbook is the operator-facing procedure for upgrading that quartet without changing the live protocol addresses.

## What actually changes

An upgrade changes the implementation behind a stable proxy address.

- Users, bots, and indexers continue calling the same canonical runtime addresses
- State stays at the proxy address
- Event emitters stay the proxy addresses
- `freezeConfig()` alone does **not** disable these upgrades
- the separate [freeze-and-burn finality ceremony](freeze-and-burn-finality.md) is what removes quartet upgrade authority permanently

This governed upgrade window exists for one reason: the live game can be repaired without address churn before finality arrives. After finality, that window is closed.

This runbook covers the canonical 1.0.0 runtime-upgrade path. Use the timelock + proxy-admin flow described here for the runtime quartet.

## Canonical addresses

For the runtime quartet, the manifest fields mean:

| Field | Meaning |
|------|---------|
| `contracts.<Name>.address` | Live proxy address. This is the canonical protocol address integrations should call. |
| `contracts.<Name>.implementation` | Current implementation address behind the proxy. |
| `contracts.<Name>.proxyAdmin` | Owned `ProxyAdmin` contract that controls upgrades for that proxy. |
| `contracts.<Name>.proxyAdminOwner` | Current owner of that `ProxyAdmin` (normally the timelock, later `0x0` after burn). |

The current deployment tooling and docs treat `.address` as canonical and `implementation` / `proxyAdmin` as governance metadata.

## Upgrade authority

- Runtime upgrades happen through OpenZeppelin `ProxyAdmin` contracts owned by the timelock
- The runtime contracts themselves do **not** expose UUPS `upgradeTo(...)` entrypoints
- `ProxyAdmin` ownership is plain `Ownable`, not `Ownable2Step`
- Direct protocol contracts still use `Ownable2Step`
- [genesis.md](genesis.md) and [security-guardian-pausing.md](security-guardian-pausing.md) describe the ownership handoff posture around launch and freeze

## Preconditions

Before upgrading any runtime proxy:

1. Confirm the target proxy address, current implementation, current `ProxyAdmin`, current `ProxyAdmin` owner, and timelock delay from `deployments/<network>.json`
2. Confirm the new implementation is storage-compatible with the current live version
3. Confirm the implementation constructor still disables direct initialization and uses the same canonical direct roots
4. Run the relevant Solidity test suite, including [test/ProxyRuntimeQuartet.t.sol](https://github.com/claimrush/claimrush/blob/main/test/ProxyRuntimeQuartet.t.sol)
5. Rehearse the exact upgrade on a fork or testnet before touching production
6. Decide whether the change is:
   - a single-contract upgrade
   - a coupled multi-contract upgrade that should be executed as one Safe batch
7. Confirm the quartet has not already passed the [freeze-and-burn finality ceremony](freeze-and-burn-finality.md)

## Storage compatibility rules

Treat storage layout review as mandatory.

- Do not reorder existing state variables
- Do not delete existing state variables
- Do not change the type of an existing state variable
- Do not move mapping or array declarations
- Only append new storage in a layout-compatible way
- Re-run the upgrade tests whenever the changed contract stores meaningful user or protocol state

If an upgrade writes incompatible storage, the proxy address survives but the live state may be corrupted.

## Implementation deployment rules

Deploy a fresh implementation address first. Do **not** point integrations at the implementation address.

Current constructors are:

| Contract | Implementation constructor |
|------|---------|
| `MineCore` | `new MineCore(claim, ve, royalties, address(0))` |
| `Furnace` | `new Furnace(claim, ve, guardHelper, address(0))` (deploy `new FurnaceGuardHelper(claim, ve)` first) |
| `MarketRouter` | `new MarketRouter(claim, ve, royalties, address(0))` |
| `ShareholderRoyalties` | `new ShareholderRoyalties(ve, address(0))` |

Notes:

- Keep the same direct roots the live proxy expects
- Pass `address(0)` as `initialOwner` for standalone implementation deployments
- The constructor must still disable direct initialization on the implementation

## Rehearsal checklist

Before production:

1. Deploy the new implementation(s) on a fork or testnet
2. Simulate the exact `ProxyAdmin.upgradeAndCall(...)` call set
3. Verify that the live proxy addresses do not change
4. Verify that the implementation slot changes to the new implementation
5. Verify that the proxy-admin owner does not change
6. Verify critical wiring and state still hold:
   - `ClaimToken.mineCore() == MineCore proxy`
   - `VeClaimNFT.furnace() == Furnace proxy`
   - `VeClaimNFT.mineMarket() == MarketRouter proxy`
   - quartet cross-contract wiring still resolves to one canonical bundle
7. Run `python3 scripts/verify_deployment.py --network <network> --rpc-url "$RPC_URL"`

If the change touches multiple runtime contracts with shared assumptions, prefer one batched rehearsal and one batched production execution.

## Production execution

### Single-contract upgrade

Schedule and execute the upgrade through the timelock. The Safe is the proposer/canceller/executor, but the onchain caller into the `ProxyAdmin` is the `TimelockController`.

The inner call remains:

```solidity
ProxyAdmin.upgradeAndCall(
    ITransparentUpgradeableProxy(proxy),
    newImplementation,
    data
)
```

Use `data = ""` for a pure logic swap with no post-upgrade call.

### Multi-contract upgrade

If multiple runtime contracts are coupled:

- prepare all implementation deployments first
- submit one timelock batch that upgrades every affected proxy atomically
- avoid leaving the live system in a mixed-version window longer than necessary

Because state-changing paths fail closed on bundle drift, a mixed-version rollout can revert unexpectedly even if the proxy addresses themselves do not change.

## When to use `upgradeAndCall(...)` data

Use non-empty `data` only when the new implementation exposes an explicit post-upgrade initialization or state-transition entrypoint.

Requirements for that entrypoint:

- callable safely through the proxy
- idempotent or otherwise strictly one-time guarded
- storage-compatible with the live layout
- covered by upgrade tests

If no post-upgrade call is required, use empty calldata.

## Post-upgrade verification

Immediately after execution:

1. Read the EIP-1967 implementation slot and confirm it matches the approved implementation
2. Confirm the proxy address is unchanged
3. Confirm the `ProxyAdmin.owner()` is unchanged
4. Confirm the direct roots still point at the same proxies:
   - `ClaimToken.mineCore()`
   - `VeClaimNFT.furnace()`
   - `VeClaimNFT.mineMarket()`
5. Confirm runtime bundle wiring still matches:
   - `MineCore.furnace()`
   - `Furnace.mineCore()`
   - `Furnace.mineMarket()`
   - `Furnace.shareholderRoyalties()`
   - `ShareholderRoyalties` wiring back to the live bundle
6. Run `python3 scripts/verify_deployment.py --network <network> --rpc-url "$RPC_URL"`
7. Update `deployments/<network>.json`:
   - keep `.contracts.<Name>.address` unchanged
   - rotate `.contracts.<Name>.implementation`
   - keep `.contracts.<Name>.proxyAdmin` unchanged unless governance intentionally rotated it
8. Sync generated deployment docs:
   - `bash scripts/sync_deployments_all.sh --write`
   - `python3 scripts/sync_docs_deployments.py --write`

## Rollback posture

If the new logic is bad but storage is still valid:

- deploy or reuse a known-good implementation
- call `ProxyAdmin.upgradeAndCall(...)` again to point the proxy back

Important caveat:

- rollback restores old code, not old state
- if the bad implementation already wrote corrupted state, code rollback alone may not fully repair the system

## Freeze interaction

`freezeConfig()` remains important, but it is not the full finality step by itself.

- it permanently locks the documented wiring setters on the freeze-gated contracts
- before finality, it does **not** disable proxy-admin upgrades for `MineCore`, `Furnace`, `MarketRouter`, or `ShareholderRoyalties`
- after the [freeze-and-burn finality ceremony](freeze-and-burn-finality.md), those upgrades are impossible because the four runtime `ProxyAdmin`s no longer have owners

Operationally, that means:

- pre-burn: runtime upgrades remain part of the trust model and go through the timelock
- post-burn: runtime logic is permanent, but surviving owner knobs still go through the timelock delay

## Related pages

- [protocol-overview.md](protocol-overview.md) — architecture and trust boundaries
- [security-guardian-pausing.md](security-guardian-pausing.md) — governance, guardian, and freeze model
- [genesis.md](genesis.md) — launch ownership handoff and freeze timing
- [freeze-and-burn-finality.md](freeze-and-burn-finality.md) — permanent runtime finality ceremony
- [Runtime quartet upgrade path](https://github.com/claimrush/claimrush/blob/main/docs/architecture/runtime-quartet-upgrade-path-v1.0.0.md) — design background for the proxy-backed runtime quartet
