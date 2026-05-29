# ClaimRush OpenClaw Skill

Workspace-level OpenClaw / Cursor agent skill that wraps
[`@claimrush/agent-sdk`](../../agents/sdk/README.md) with a chat-friendly CLI
and enforces the safety rules defined in
[`docs/manuals/developer/agents-and-automation.cral.yaml`](../../docs/manuals/developer/agents-and-automation.cral.yaml)
(CRAL). It is also discoverable by other AgentSkills-compatible runners
(Cursor agent skills, etc.); the on-disk format is `SKILL.md` with YAML
frontmatter and a body.

## Layout

```
skills/claimrush/
  SKILL.md              # agent-facing instructions (LLM reads this)
  README.md             # this file (human notes)
  package.json
  tsconfig.json
  src/
    cli.ts              # `claimrush` chat CLI dispatcher
    commands/...        # one file per verb
    safety/...          # CRAL guardrails (caps, slippage, deadlines, mainnet gate)
  scripts/
    cr.sh               # convenience wrapper around `node dist/cli.js`
    setup.sh            # one-shot install/build/smoke-check
```

## Setup

```bash
bash skills/claimrush/scripts/setup.sh
```

This builds `agents/sdk/`, installs and builds this skill, and runs a quick
offline smoke check (`npm -C agents/sdk run example:action-coverage`).

## CLI

After setup, invoke the CLI as either:

```bash
bash skills/claimrush/scripts/cr.sh <verb> [flags]
# or
node skills/claimrush/dist/cli.js <verb> [flags]
```

Verbs:

- `status`              snapshot of mineCore / furnace / royalties (read-only)
- `monitor`             tail events / achievements (read-only)
- `takeover`            mineCore.takeover or takeoverWithToken
- `lock`                furnace.enterWithEth / enterWithClaim / enterWithToken
- `furnace`             chat alias: `furnace lock <ETH>` / `furnace status`
- `collect`             ETH royalties: royalties.claimShareholderEth | claimShareholderLock
- `withdraw`            mineCore.withdrawKingBalance | withdrawRefundBalance
- `market`              offer-create / list / sell-to-furnace
- `session`             DelegationHub: build / submit / revoke / status
- `plan`                AgentPlan v1: build or execute
- `agent`               run the live agent loop (defaults to --once; --loop is opt-in)
- `cral`                print the parsed CRAL safety pack (json | prompt | hard-rules)

Every write verb is **dry-run by default**. Pass `--execute` to actually send
a transaction. On Base mainnet (`--chain base`), `--execute` additionally
requires `--i-understand` and an allowlisted RPC URL via
`CR_SKILL_BASE_RPC_ALLOWLIST`.

## Environment

Inherits everything the SDK reads (`RPC_URL`, `CLAIMRUSH_CHAIN`,
`ABI_NETWORK`, `MNEMONIC` / `PRIVATE_KEYS`, `PRIVATE_RPC_URL`,
`PRIVATE_RPC_MODE`, etc.) plus a few skill-specific vars:

| var                                       | meaning                                                        | default              |
| ----------------------------------------- | -------------------------------------------------------------- | -------------------- |
| `CR_SKILL_MAX_TAKEOVER_ETH_HARDCAP`       | absolute upper bound on `--max-takeover-eth`                   | `0.05` on `base`, `1` elsewhere |
| `CR_SKILL_MAX_FURNACE_ETH_HARDCAP`        | absolute upper bound on `--furnace-eth-in`                     | `1` on `base`, `100` elsewhere  |
| `CR_SKILL_MAX_SLIPPAGE_BPS`               | hard upper bound on `--slippage-bps`                           | `200` (= 2 %)        |
| `CR_SKILL_BASE_RPC_ALLOWLIST`             | comma-separated list of permitted mainnet RPC URLs             | (none; mainnet sends fail) |
| `CR_SKILL_OUTDIR`                         | override the receipts directory                                | `agents/sdk/out/skill-<ts>` |

## Safety rules (lifted from CRAL)

The CRAL guard refuses to send when any of the following are violated:

1. integer-only units (no float math),
2. `--execute` flag (writes are dry-run by default),
3. spend caps (`--max-takeover-eth`, `--furnace-eth-in`, hard caps via env),
4. slippage `<= CR_SKILL_MAX_SLIPPAGE_BPS`,
5. live re-quote at send (rejects if drift exceeds slippage),
6. deadlines (`--deadline-seconds`, default 60s),
7. mainnet double-confirm (`--i-understand` + RPC allowlist),
8. delegated mode requires a live `DelegationHub.isAuthorized` precheck.

See [SKILL.md](./SKILL.md) for the agent-facing version of these rules.

## License and contributing

- License: see the repository [`LICENSE`](../../LICENSE).
- Contributing: see the repository [`CONTRIBUTING.md`](../../CONTRIBUTING.md)
  and [`CLA.md`](../../CLA.md).
- Trademarks: see [`TRADEMARKS.md`](../../TRADEMARKS.md). The "ClaimRush"
  name, the ClaimRush logo and wordmark, the illustrated Crown / Furnace /
  Baron page backgrounds, and the achievement badge artwork are protected
  brand assets; this skill does not grant rights to any of them.

## Reference

- Canonical SDK: [`agents/sdk/README.md`](../../agents/sdk/README.md)
- CRAL safety pack: [`docs/manuals/developer/agents-and-automation.cral.yaml`](../../docs/manuals/developer/agents-and-automation.cral.yaml)
- Developer manual: [`docs/manuals/developer/agents-and-automation.md`](../../docs/manuals/developer/agents-and-automation.md)
