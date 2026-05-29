# House (developer participation)

The **House** is a developer-controlled onchain address that can participate in ClaimRush like any other player.

## Identity

- UI label: `claimrushdev.base.eth`
- For integrations and analytics, treat this as a normal address (no protocol-level special casing).

## No special privileges

The House:
- has **no admin permissions**
- has **no guardian permissions**
- has **no privileged contract hooks**
- uses the same public functions and mechanics available to all players

## Comms and expectations

- No pre-announcements of House actions, token swaps, or strategy.
- The House may share post-facto notes or context, but makes no commitments about timing, size, or intent.

## Integration note

If your UI / indexer needs to badge or filter the House:
- Resolve and match the same address the official UI uses for `claimrushdev.base.eth`.

## See also

- [Protocol Overview](protocol-overview.md) — ownership and role hierarchy
- [Security, Guardian, Pausing](security-guardian-pausing.md) — guardian safety controls
- [Getting Started](getting-started.md) — deployed addresses and contract manifests
- User manual: [The House](https://docs.claimru.sh/house)
