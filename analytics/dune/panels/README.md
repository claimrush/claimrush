# Dune panel templates (v1.0.0)

These queries are optional helpers for building dashboards.

Design goals:
- Use events (not view calls)
- Prefer single-row outputs when possible (compact + faster)
- Allow small multi-row time series when the visualization needs it (example: Furnace bonus history)
- Keep logic minimal and trace-free

Prerequisites:
- Contracts decoded on Dune (`<DUNE_SCHEMA>`)
- Start blocks filled from `deployments/base_mainnet.json`

Notable templates:
- `07_furnace_enter_with_token_decoded_30d.sql` -- decodes `enterWithToken(...)` calldata
- `08_furnace_sellback_24h.sql` -- sellback volume + split (seller payout / LP stream funding / reserve add)
- `09_lp_rewards_notify_failed_30d.sql` -- LP vault notify failures suppressed (transfer still succeeds)
- `09_lp_reward_transfers_without_notify_30d.sql` -- CLAIM transfers to LP vault without matching LpRewardsNotified
- `10_furnace_reserve_clamped_30d.sql` -- reserve accounting clamped to onchain backing
