# Changelog

## v1.0.1 — 2026-07-20

Furnace and MineCore implementation upgrade on Base mainnet and Sepolia, executed
through the governance Timelock. Proxy addresses are unchanged; integrations need
no action.

- Extend and merge price bonuses on each lock's committed principal basis, so
  quote and execution stay in lockstep and laddered operations match single-step ones.
- King force-lock destinations require a full-horizon remaining lock.
- Swap-to-CLAIM routing derives principal from the CLAIM balance delta actually delivered.
- King emissions accrued before a pause are preserved across the pause window.
- The Furnace ABI adds the `bonusBasis()` and `extendHelper()` views (additive — nothing
  removed); deployment manifests and ABIs are refreshed for the current implementation.

Security research: Pindarev (https://github.com/PavelPindarev/audits), via coordinated
disclosure.

## v1.0.0

Initial public release of the ClaimRush v1.0.0 protocol surface.

Vulnerability reports: see [SECURITY.md](SECURITY.md).
