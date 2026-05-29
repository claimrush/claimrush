# Achievements Telemetry

> v1.0.0 — JSONL telemetry stream emitted by the Agent SDK during live and plan-executor runs.

The Agent SDK writes a compact JSONL telemetry stream that downstream surfaces consume for monitoring, alerting, postmortems, and feeding external AI a compressed "what happened recently" context window.

> **TL;DR:** Subscribe to `agents/sdk/schemas/achievements.v1.schema.json` rather than reverse-engineering the emitter. Each line is an `Achievement` object with `ts`, `kind`, `level`, and optional context (`chain`, `user`, `blockNumber`, `txHash`, `data`). Optional client-side badge polling layers profile-badge unlocks on top.

## File locations

| Mode | Path |
|---|---|
| Live agent | `agents/sdk/out/agent-<timestamp>/achievements.jsonl` |
| Plan executor | `agents/sdk/out/execute-plan-<timestamp>/achievements.jsonl` |

## Use cases

- Monitoring, alerting, postmortems.
- Third-party analytics pipelines that subscribe to agent telemetry.
- Feeding an external AI a compressed "what happened recently" context window.

## Schema

The canonical schema lives at `agents/sdk/schemas/achievements.v1.schema.json`. Per-kind `data` payloads are documented in the schema's `$defs/AchievementData` discriminated union.

Each line is an `Achievement` object with:

- `ts` — ms since unix epoch
- `kind` — string enum (see schema for the full list)
- `level` — `info` | `warn` | `error`
- Optional context: `chain`, `chainId`, `agent`, `user`, `blockNumber`, `txHash`, `data`

## Achievement kinds (v1)

The canonical enum is `Achievement.kind` in the JSON Schema. Subscribe to the schema rather than this list when validating third-party consumers.

### Value milestones

- `TAKEOVER_SUCCESS`
- `REIGN_REWARD_COLLECTED`
- `FURNACE_LOCK_CREATED`
- `ROYALTIES_CLAIMED`
- `AUTOCOMPOUND_EXECUTED`

### Profile badges (optional)

- `BADGE_UNLOCKED`

### Safety / ops

- `SLIPPAGE_GUARD_TRIGGERED`
- `SESSION_EXPIRED`
- `PAUSED_ACTION_SKIPPED`
- `REVERTED_TX`
- `BACKOFF_ENTERED` — execute-mode circuit breaker tripped
- `BACKOFF_CLEARED` — execute-mode circuit breaker reset
- `RPC_LAG_DETECTED`
- `SUBGRAPH_LAG_DETECTED`

### Optional scoring

- `ACTION_UTILITY` — emitted only when `EMIT_ACTION_UTILITY=1`

## Badge polling (optional)

Setting `ACHIEVEMENTS_BASE_URL=<url>` enables badge polling for both the live agent and the plan executor.

- The agent polls `{ACHIEVEMENTS_BASE_URL}/api/achievements?address=<user>&chainId=<chainId>`.
- Supported chain ids: `8453` (Base), `84532` (Base Sepolia), `31337` (local Anvil).
- First successful poll initialises a baseline and emits nothing.
- After a confirmed onchain tx, the agent requests a one-shot refresh (debounced, `refresh=1`).
- Badge definitions live at `agents/sdk/src/achievements/profileBadges.ts` (delegation-only badges excluded).

## Tuning (env vars)

| Variable | Default |
|---|---|
| `ACHIEVEMENTS_POLL_MS` | `20000` |
| `ACHIEVEMENTS_REFRESH_COOLDOWN_MS` | `5000` |
| `ACHIEVEMENTS_TIMEOUT_MS` | `10000` |

## Stability notes

- Treat `data` as versioned and best-effort. Use `kind` and `level` as stable keys.
- The JSON Schema documents every `data` payload shape per `kind`. Third-party surfaces should validate against the schema.
- Achievements are telemetry and reward hooks, not an objective to farm.

## See also

- [Agents and Automation](agents-and-automation.md) — Agent SDK overview and CRAL pack
- [Agent Plan Format](agent-plan-format.md) — AgentPlan v1 schema and executor
- [Events and Indexing](events-and-indexing.md) — protocol-side event reference
