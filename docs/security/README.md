# Security documentation index

This page is the public index for ClaimRush's security surface. Most of
the working security documentation is **intentionally not part of the
public repository** — see the section
[Why some documents live only in private](#why-some-documents-live-only-in-private)
below. This README exists so that operators, integrators, and security
researchers landing at `github.com/claimrush/claimrush/docs/security`
or `github.com/claimrush/claimrush/tree/main/docs/security` find a clear
pointer to the right channels instead of a 404.

If you reached this page because an aggregator listing, press kit, or
operator note linked to a `docs/security/*.md` path that does not exist
on this public repo, that path is one of the coordinated-disclosure-only
documents listed below. Request access via the security contact, or use
the public-safe equivalents in
[Public verification surfaces](#public-verification-surfaces).

## Security contact

For all security-sensitive correspondence (vulnerability reports, audit
coordination, integration security review, request for working
security documents):

- **Email**: `security@claimru.sh`
- **GitHub private vulnerability reporting**: enabled on this
  repository when applicable. See the
  [public disclosure policy](../../SECURITY.md) for severity tiers,
  response targets, safe-harbor expectations, and what to include in a
  report.

Do **not** report vulnerabilities via public GitHub issues,
unsolicited DMs, or Telegram/Discord "support" chats.

## Public verification surfaces

The protocol exposes a complete set of public surfaces that any
auditor, reviewer, or integrator can use to verify the operational
state of the deployed contracts without needing access to the private
security documents:

| Surface | URL | What it covers |
|---|---|---|
| Public disclosure policy | [`SECURITY.md`](../../SECURITY.md) | Supported versions, severity tiers, response targets, reporting channels, safe-harbor. |
| Live security verification page | [`https://docs.claimru.sh/security`](https://docs.claimru.sh/security) | Live on-chain pause status, per-contract freeze state, upgradeability detection (live-read from chain), routing-governance and pause-control addresses, revoke.cash link for allowance management. |
| Live protocol status | [`https://claimru.sh/status`](https://claimru.sh/status) | Operational state, on-chain event history, indexer freshness. |
| Source code | [`src/`](../../src) | Every value-paying contract: `ClaimToken`, `MineCore`, `Furnace`, `ShareholderRoyalties`, `MarketRouter`, `VeClaimNFT`, `LpStakingVault7D`, `GenesisLPVault24M`, `EntryTokenRegistry`. |
| Subgraph / indexing | [`subgraph/`](../../subgraph) | Event mappings and schema for every protocol surface. |
| Deployment manifests | [`deployments/`](../../deployments) | Authoritative on-chain addresses, including the proxy/impl/admin triplet for upgradeable contracts. |
| Block explorer (live contracts) | [`https://basescan.org/token/0x059D278233fEC14CB6D1A74E6FB482BC3f91ADbf`](https://basescan.org/token/0x059D278233fEC14CB6D1A74E6FB482BC3f91ADbf) | Source-verified contracts, read/write surface, event log. |

For day-to-day verification ("is anything paused right now?", "is the
proxy admin still owned by the timelock?", "did the freeze-and-burn
ceremony land?"), the **Live security verification page** at
`docs.claimru.sh/security` is the canonical view — it reads on-chain
state live rather than from a static snapshot.

## Why some documents live only in private

The full v1.0.0 security architecture (trust boundaries, roles and
permissions matrix, global invariants, on-chain threat map, CI
security gates, verification and audit plan, security test matrix,
game-integrity and anti-abuse controls, off-chain fraud prevention,
privacy/logging/data-retention rules, user-safety / anti-phishing
posture, and third-party trust inventory) is maintained as working
documentation in the private monorepo. These documents are
intentionally **not** mirrored to the public surface for three
reasons:

1. **Coordinated disclosure.** Several documents enumerate live
   trust boundaries, role grants, and operator interventions in detail
   that is appropriate for a researcher engaged in coordinated
   disclosure but not for a static public page. Linking them publicly
   would create asymmetric attack signal.
2. **Cross-references to internal operations.** The documents reference
   private infrastructure runbooks, incident-response timelines, and
   audit-tracker entries that are not themselves public.
3. **Working-document semantics.** These are operating documents that
   update on every audit cycle and every drift-sweep closure. The
   public surfaces above (live verification page, source code,
   deployment manifests) reflect the same facts as deployed
   on-chain, in a form that is both more useful and more
   verification-resistant to staleness than a static markdown
   snapshot.

If you need access to one of these documents for a legitimate
purpose (audit engagement, integration security review, vulnerability
triage, security questionnaire), email `security@claimru.sh` with the
specific document name(s) you need and the context. Standard response
within 24 hours; access typically granted within 72 hours of intake.

The named private documents include (this list is informational, not
an invitation to enumerate; none of these paths resolve in the public
repository):

```
docs/security/security-architecture-and-trust-boundaries-v1.0.0.md
docs/security/roles-and-permissions-matrix-v1.0.0.md
docs/security/invariants-v1.0.0.md
docs/security/threat-map-v1.0.0.md
docs/security/ci-security-gates-v1.0.0.md
docs/security/security-verification-and-audit-plan-v1.0.0.md
docs/security/security-test-matrix-v1.0.0.md
docs/security/pre-implementation-security-audit-v1.0.0.md
docs/security/external-audit-tracker-v1.0.0.md
docs/security/game-integrity-and-anti-abuse-v1.0.0.md
docs/security/indexer-and-analytics-security-v1.0.0.md
docs/security/offchain-fraud-prevention-and-data-integrity-v1.0.0.md
docs/security/privacy-logging-and-data-retention-v1.0.0.md
docs/security/third-party-trust-inventory-live-v1.0.0.md
docs/security/third-party-dependencies-and-trust-inventory-v1.0.0.md
docs/security/user-safety-and-anti-phishing-v1.0.0.md
docs/security/vulnerability-reporting-and-disclosure-v1.0.0.md
```

The last entry in the list above is the long-form
reporter-expectations document; the short public disclosure policy
lives at the repo root in [`SECURITY.md`](../../SECURITY.md).

## External audit status

A third-party external audit is scheduled as part of the protocol's
Phase 8 (Freeze-and-Burn) milestone. The audit report and any related
public advisories will be published under this `docs/security/`
directory when complete, and referenced from this README.

Until the external audit lands, the public verification surface (live
on-chain state at `docs.claimru.sh/security` + source code at `src/` +
deployment manifests) plus the published pre-implementation
self-audit (shared on request via `security@claimru.sh`) constitute
the available security artefacts.

## For aggregator and listing reviewers

If you are a CoinGecko / CoinMarketCap / DefiLlama / GeckoTerminal /
DexTools / DexScreener / etc. reviewer evaluating a listing
submission and were directed here from one of those forms, the
relevant references are:

- This README (`docs/security/README.md`) — security index and policy.
- [`SECURITY.md`](../../SECURITY.md) at the repo root — public
  vulnerability disclosure policy.
- [`https://docs.claimru.sh/security`](https://docs.claimru.sh/security) —
  live verification surface.
- [`src/`](../../src) — full protocol source code.
- [`deployments/base_mainnet.json`](../../deployments/base_mainnet.json) —
  authoritative on-chain addresses.

For any additional verification material (audit-track artefacts,
invariants doc, threat map, etc.), please reply via your submission
thread or email `security@claimru.sh` directly. We are responsive
within 24h on weekdays and happy to share working security documents
under coordinated-disclosure terms.
