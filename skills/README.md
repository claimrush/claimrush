# ClaimRush Agent Skills

This folder ships **workspace-scoped agent skills** that drive the ClaimRush
protocol from a chat-based AI agent runner (OpenClaw, Cursor, or any other
runner that reads `SKILL.md` files with YAML frontmatter).

A skill is a thin chat-friendly wrapper around the canonical TypeScript SDK
in [`agents/sdk/`](../agents/sdk/README.md). Skills do not introduce new
protocol rules; they enforce safety guardrails (spend caps, slippage floors,
deadlines, mainnet double-confirm) on top of the SDK so a chat agent cannot
bypass them by accident.

## Shipped skills

| Skill | Path | Purpose |
|-------|------|---------|
| `claimrush` | [`skills/claimrush/`](claimrush/) | Drive `MineCore`, `Furnace`, `ShareholderRoyalties`, `MarketRouter`, `DelegationHub`, and the live agent loop from chat. Enforces the [CRAL](../docs/manuals/developer/agents-and-automation.cral.yaml) safety pack. |

## Layout convention

Each skill lives under `skills/<name>/` and ships, at minimum:

```
skills/<name>/
  SKILL.md          # agent-facing instructions (LLM reads this)
  README.md         # human notes (setup, CLI surface, env vars)
  package.json
  src/              # TypeScript source
  scripts/          # convenience wrappers (setup.sh, cr.sh, ...)
```

Build artefacts (`dist/`, `node_modules/`, `*.tsbuildinfo`) are gitignored
and regenerable via `bash skills/<name>/scripts/setup.sh`.

## Reference

- SDK reference: [`agents/sdk/README.md`](../agents/sdk/README.md)
- Developer manual: [`docs/manuals/developer/agents-and-automation.md`](../docs/manuals/developer/agents-and-automation.md)
- Tutorial (developer): [`docs/manuals/developer/tutorials/run-claimrush-openclaw-skill.md`](../docs/manuals/developer/tutorials/run-claimrush-openclaw-skill.md)
- License: [`LICENSE`](../LICENSE)
- Trademarks: [`TRADEMARKS.md`](../TRADEMARKS.md)
