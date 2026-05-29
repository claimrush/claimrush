# Security Policy

This repository follows the ClaimRush v1.0.0 coordinated vulnerability disclosure process.

## Supported versions

Only the latest `v1.x` tagged release of the public protocol surface receives
security fixes and advisories. The deployed onchain contracts are documented
in `deployments/base_mainnet.json`; those addresses are the authoritative
source of truth for "what is live". Older tags, pre-release commits on `main`,
and any fork or vendored copy are **not** supported and will not receive
backported patches.

| Version                          | Supported          |
| -------------------------------- | ------------------ |
| `v1.x` (latest tagged release)   | Yes                |
| `main` (unreleased)              | Best-effort only   |
| `< v1.0.0`                       | No                 |
| Forks / vendored copies          | No                 |

## Bounty stance

ClaimRush does **not** currently operate a paid public bug bounty program.
Good-faith disclosures are acknowledged in the advisory once a fix is
published (unless the reporter requests anonymity), and we reserve the right
to make discretionary ex-gratia awards for high-impact reports on live
mainnet contracts. Any such award is at our sole discretion, is not a
contract, and is capped at what the onchain state realistically allowed
attackers to extract. Reporters must abide by the safe-harbour expectations
below to qualify for recognition or discretionary awards.

## Reporting a vulnerability

Please report security issues privately.

Preferred channels:
- Email: `security@claimru.sh`
- GitHub private vulnerability reporting (Security Advisories), if enabled for this repository

Do not report vulnerabilities via:
- public GitHub issues
- unsolicited direct messages
- Telegram/Discord “support” chats

## Severity and response

We triage reports using these severity levels:
- SEV0: credible loss of funds or ongoing drain
- SEV1: high-impact compromise, or widespread user loss risk
- SEV2: medium-impact abuse, partial loss, or major degradation
- SEV3: low-impact bug or hard-to-exploit weakness

Response targets (non-binding):
- acknowledge receipt within 24 hours
- provide initial triage within 72 hours

## What to report

We treat the following as in-scope:
- Onchain vulnerabilities (fund custody, routing, access control, reentrancy, accounting)
- Offchain vulnerabilities (auth/session, injection, infra misconfigurations)
- User safety threats (phishing domains, cloned UI, impersonation)

If you are unsure whether an issue is security-sensitive, report it anyway and we will triage.

## What to include

A good report usually contains:
- your contact info
- affected surface (contract name + address, endpoint path, UI flow)
- impact summary (what can be stolen/corrupted/blocked)
- reproduction steps (minimal steps; calldata/PoC if safe)
- environment details (chainId, block number range, tx hashes if any)
- suggested mitigation (optional)

Please do not include:
- seed phrases
- private keys
- any request to move user funds to “prove” a drain

## Safe harbor expectations

Researchers should:
- avoid exploiting the issue beyond what is necessary to demonstrate it
- avoid accessing or modifying other users’ data
- never attempt to drain funds

We will not request or accept “proof” via theft.

## Coordinated disclosure

- Please avoid public disclosure until we have confirmed the issue and coordinated a fix and disclosure timeline.
- We may share status updates, current mitigations, and (when appropriate) a public advisory/postmortem.

## Full policy

This file is the public vulnerability reporting and disclosure policy for
v1.0.0. The longer-form internal policy (reporter expectations, triage SLAs,
and coordinated-disclosure timelines) is shared directly with researchers
during coordinated disclosure when needed.

## Security documentation

The v1.0.0 security architecture (trust boundaries, roles and permissions
matrix, global invariants, onchain threat map, CI security gates, verification
and audit plan, game-integrity and anti-abuse controls, offchain fraud
prevention, privacy/logging/data-retention rules, user-safety / anti-phishing
posture, and third-party trust inventory) is maintained internally and shared
on request during coordinated disclosure.

Contact `security@claimru.sh`.
