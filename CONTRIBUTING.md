# Contributing to ClaimRush

This document covers the contribution process for ClaimRush.

## License

ClaimRush is licensed under the [MIT License](./LICENSE). By contributing,
you agree that your contributions will be licensed under the same terms.

## Contributor License Agreement (CLA)

All contributors must agree to the [ClaimRush CLA](./CLA.md) before their
first pull request can be merged. The CLA preserves your copyright while
granting the project the flexibility to manage licensing over time.

First-time contributors will be prompted by a CLA-assistant bot on their
pull request. You only need to sign once.

## Getting Started

See the [Developer Manual](./docs/manuals/developer/getting-started.md) for repo setup,
local stack, and integration rules.

```bash
make deps    # Foundry libraries (pinned)
make build   # Build contracts
make test    # Run tests
make gates   # CI-parity checks — run before submitting a PR
```

## Pull Requests

1. Fork the repo and create a feature branch.
2. Run `make gates` locally before pushing.
3. Open a PR with a clear description of the change.
4. Sign the CLA when prompted (first-time contributors only).
5. Address review feedback.

## Reporting Issues

- **Security vulnerabilities:** email **security@claimru.sh** (do not open
  a public issue).
- **Bugs and feature requests:** open a GitHub issue.

## Code of Conduct

Be respectful. Contributions are evaluated on technical merit. Harassment
or abuse will not be tolerated.
