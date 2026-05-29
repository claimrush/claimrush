# Agents and Automation

> **TL;DR:** Self-run agents play from their own wallet; delegated agents act for a user via [DelegationHub](delegationhub.md) sessions. The TypeScript Agent SDK (`agents/sdk/`) provides ready-made loops. See [Maintenance & Bots](maintenance-and-bots.md) for keeper surfaces.

ClaimRush is permissionless:
- EOAs and smart contracts can play.
- Anyone can build bots/agents.

**Governance note:**
- `ClaimToken` and `VeClaimNFT` are permanent direct roots.
- `MineCore`, `Furnace`, `MarketRouter`, and `ShareholderRoyalties` are proxy-backed runtime contracts governed through owned proxy admins.
- Wiring setters are `onlyOwner`, governed through the live `TimelockController`.
- `ClaimToken` ownership is frozen and renounced at deployment (in `Wire.s.sol`). The freeze-and-burn batch then freezes `MineCore`, `Furnace`, `VeClaimNFT`, and `ShareholderRoyalties`. None of those wiring locks disable proxy-admin upgrades until the quartet proxy admins are burned.
- Gameplay is permissionless from day one.
- Agents should monitor: pause flags, guardian/owner changes, registry token disables, operational allowlist updates, proxy-admin ownership changes, and runtime implementation upgrades.
- See [Security, guardian, pausing](security-guardian-pausing.md#config-governance-model).

This page covers:

- **Self-run agents**: agent plays from its own wallet.
- **Delegated agents**: agent acts for a user address via **DelegationHub** sessions.

## CRAL pack

Machine-readable CRAL companion (runnable manifests and guardrails):
- [agents-and-automation.cral.yaml](https://developers.claimru.sh/agents-and-automation.cral.yaml)

Use the Markdown page for explanation. Use the CRAL file for automation — every example on this page has a matching manifest entry. To browse the canonical manifest map, read the YAML directly or run `bash skills/claimrush/scripts/cr.sh cral --format json --pretty`.

The same CRAL manifest is loaded by the `skills/claimrush/` agent skill at startup; see [OpenClaw / Cursor skill](#openclaw--cursor-skill).

## Repo entrypoints

| What | Where |
|------|-------|
| Agent tooling root | `agents/` |
| TypeScript SDK | `agents/sdk/` |
| Local manifests | `deployments/<network>.json` |
| ABIs | `abis/<network>/*.abi.json` |
| Optional snapshot bundler | `src/lens/AgentLens.sol` |
| MineCore takeover quoter | `src/MineCoreQuoter.sol` |
| Furnace quoter (heavy view math) | `src/FurnaceQuoter.sol` |
| Spot swap quoting (DexAdapter + registries) | `agents/sdk/src/dexQuotes.ts` |
| Live prices helper (CLAIM/ETH + entry tokens) | `agents/sdk/src/prices.ts` |
| Event cursor (reorg-safe checkpoints) | `agents/sdk/src/agent/eventCursor.ts` |
| Monitor endpoint (HTTP) | `agents/sdk/src/agent/monitor.ts` |
| Tx manager + replacement | `agents/sdk/src/tx/txManager.ts` |
| Backoff / circuit breaker | `agents/sdk/src/agent/backoff.ts` |
| Strategy plugins + loader | `agents/sdk/src/agent/strategies.ts`, `agents/sdk/src/agent/strategyLoader.ts` |
| Strategy templates | `agents/sdk/strategies/` |
| Replay runner | `agents/sdk/src/agent/replay.ts`, `agents/sdk/examples/replay.ts` |
| Achievements telemetry (SDK) | `agents/sdk/src/achievements/` |
| Achievements JSONL schema | `agents/sdk/schemas/achievements.v1.schema.json` |
| OpenClaw / Cursor agent skill | `skills/claimrush/` |


The SDK is designed for:
- **deterministic inputs** (snapshots)
- **event-driven wakeups** (JSONL event stream)
- **safe execution** (dry-run by default; explicit `--execute`)

## Install

The SDK ships as source inside the public protocol repo at `agents/sdk/`. It is not published as a standalone npm package in v1.0.0. Integrators consume it by checking out the repo and installing from the workspace path:

```bash
npm -C agents/sdk ci
```

Then import from your local copy (`import { ... } from "../path/to/agents/sdk/src"`) or set up a workspace alias in your own build. Examples on this page assume that layout.

## Read state for decision making

### Snapshot API

The SDK exposes `getGameStateSnapshot(opts)` where `opts` must include `publicClient` and `manifest`; optional fields such as `user`, `abiNetwork`, and `agentLensAddress` refine the snapshot. It returns:
- `meta` (chainId, blockNumber, timestamps)
- `addresses` (contract addresses from manifest)
- `global` (MineCore/Furnace/Royalties/Ve/Market/LP vault/Dex state)
- optional `user` slice (balances + claimables + config) when a wallet address is provided

Run the snapshot example:

```bash
RPC_URL=http://127.0.0.1:8545 \
USER_ADDRESS=0xYourAgentAddress \
npm -C agents/sdk run example:snapshot
```

**Performance:** If `AgentLens` is deployed and present in the manifest, the snapshot prefers:
- `AgentLens.readGlobalV1()`
- `AgentLens.readUserV1(user)`

…and falls back to `publicClient.multicall()` (or sequential reads).

### Optional onchain snapshot bundler (AgentLens)

`AgentLens` is a pure **view** contract that bundles reads into two calls:
- `readGlobalV1()`
- `readUserV1(user)`

Local deploys include it in `deployments/local.json`.

Important wiring note:
- `AgentLens` snapshots addresses as constructor immutables. If the canonical bundle is rewired, redeploy `AgentLens` and refresh the manifest (see [Wiring safety model](protocol-overview.md#wiring-safety-model)).
- Local deploy flow deploys `AgentLens` only after `MaintenanceHub` exists so the snapshot matches the final bundle.
- `DeployAgentLens.s.sol` fails closed if any required input points at a non-contract address, and verifies the supplied addresses resolve to one canonical bundle before deploying.
- Companion optional modules must be supplied together: `MaintenanceHub` requires `MarketRouter` + `DexAdapter`; `LpStakingVault7D` and `GenesisLPVault24M` require `DexAdapter`; `LaunchController` requires `DexAdapter` + `GenesisLPVault24M`.
- `scripts/verify_deployment.py` checks `AgentLens` immutables exactly against the manifest, including optional `0x0` fields.

Use cases:
- reduce RPC calls for high-frequency agents
- reduce “N reads” variance across RPC providers

## Quote token takeovers

`MineCore` exposes two token-takeover entrypoints:

- `takeoverWithToken(tokenIn, amountIn, minEthOut, maxPrice)` — uses an internal `block.timestamp + SWAP_DEADLINE_SECONDS` (300s / 5 min) deadline.
- `takeoverWithTokenAndDeadline(tokenIn, amountIn, minEthOut, maxPrice, deadline)` — caller-supplied absolute `deadline`. Reverts `DeadlineExpired` if `block.timestamp > deadline`. Use this variant for **private-RPC / MEV-protected submissions**, where a tx may sit in a builder relay long enough that the implicit 5-minute window in the non-deadline variant is too narrow, and stale inclusion should self-revert at a caller-known time.

Both variants require a `minEthOut` slippage guard **and** a `maxPrice` guard (Crown price ceiling). The deadline variant adds the `deadline` floor on top.

Use the view-only contract `MineCoreQuoter` (and the SDK helpers) to:
- validate the allowlisted takeover route for `tokenIn`
- compute the expected ETH out for a given `amountIn`
- derive a safe `minEthOut` from a slippage setting

Example (local):

```bash
# Default uses wrapped native (WETH) + amountIn = current takeover price
RPC_URL=http://127.0.0.1:8545 \
  npm -C agents/sdk run example:takeover-token-quote

# Custom token route (token must be enabled in MineCoreEntryTokenRegistry; the EntryTokenRegistry instance wired to MineCore)
# AMOUNT_IN is raw base units (example: 1 USDC = 1000000)
RPC_URL=http://127.0.0.1:8545 \
TOKEN_IN=0xYourTokenAddress \
AMOUNT_IN=1000000 \
SLIPPAGE_BPS=100 \
  npm -C agents/sdk run example:takeover-token-quote
```

Outputs include:
- `expectedEthOut`
- `takeoverPriceAtQuote`
- `minEthOut` (slippage-adjusted)
- `minEthOutStrict` (optional: clamped to never be below takeover price)

Agent rule of thumb:
- never hardcode a route
- always compute `minEthOut` from a quote and an explicit slippage policy

## Live prices and swap quotes

Most strategies need **spot prices** for:
- CLAIM/ETH (how expensive it is to acquire CLAIM, or what ETH you get back)
- entry tokens in ETH or CLAIM (to decide between paying with ETH vs token, or whether a token path is economical)

The SDK includes `getLivePrices(params)` where `params` must include `contracts` and `publicClient`, plus either `subgraphUrl` for subgraph-backed entry-token enumeration or an explicit `entryTokens` list. It:
- enumerates enabled entry tokens from the **subgraph** (`EntryTokenConfig`)
- computes spot quotes from onchain reads using the protocol's `DexAdapter.getAmountsOut`
- uses allowlisted routes from the registries (no hardcoded Aerodrome paths)
- optionally includes the subgraph `TokenPricingSnapshot` (CLAIM/ETH TWAP + ETH/USD)

Example:

```bash
RPC_URL=http://127.0.0.1:8545 \
SUBGRAPH_URL=http://127.0.0.1:8000/subgraphs/name/claimrush/local \
  npm -C agents/sdk run example:prices

# Optional tuning
# MAX_TOKENS=200 (default)
# INCLUDE_SUBGRAPH_PRICING=true (default)

# Optional: enable in-memory caching + RPC throttling (useful when polling)
# PRICES_CACHE=1
# PRICES_RPC_CONCURRENCY=16
# PRICES_QUOTE_TTL_MS=5000        (set 0 to disable quote caching)
# PRICES_ENTRYTOKENS_TTL_MS=60000 (entry token enumeration via subgraph)
# PRICES_PRICING_TTL_MS=15000     (subgraph pricing snapshot)
# PRICES_META_TTL_MS=21600000     (ERC20 metadata)
# PRICES_DEX_TTL_MS=300000        (DexAdapter config)
```

Notes:
- Cached quotes are for decision support / UI. For tx guardrails (`minOut`), re-quote immediately before sending.
- Spot quotes are **size-dependent**. The default snapshot quotes **1 token** (10^decimals) per entry token.
- Treat subgraph pricing as informational (it can lag). Spot quotes come from onchain reads.
- In this repo, `TokenPricingSnapshot` is optional in practice: the subgraph defines the entity shape, but no bundled producer populates live pricing fields by itself. Agents should treat missing or stale snapshot values as normal and fall back to onchain spot quotes.
- If a token fails to quote, the output includes per-token `errors`. Agents should treat those tokens as unknown/unsupported.

## Listen to events

### JSONL event stream

The SDK includes an event streamer that prints one event per line (JSONL).

```bash
RPC_URL=http://127.0.0.1:8545 \
npm -C agents/sdk run example:events
```

Filters:
- `--contracts MineCore,Furnace`
- `--events Takeover,FurnaceEnter`
- `--from-block 0`
- `--poll` (HTTP polling fallback)

### Optional subgraph backfill

If you have a subgraph endpoint, you can backfill recent history before starting the live RPC stream.

```bash
RPC_URL=http://127.0.0.1:8545 \
SUBGRAPH_URL=http://127.0.0.1:8000/subgraphs/name/claimrush/local \
npm -C agents/sdk run example:events -- --backfill --backfill-limit 100
```

Backfilled events include `source: "subgraph"` (live RPC events use `source: "rpc"`).

## Local simulation harness

Use the harness to run a deterministic “golden path” and write artifacts:

```bash
RPC_URL=http://127.0.0.1:8545 \
npm -C agents/sdk run example:harness
```

Artifacts are written under:
- `agents/sdk/out/harness-<timestamp>/`

## Live agent loop

The SDK includes a reference live loop:
- takes snapshots
- (optionally) listens to events
- proposes actions
- can execute transactions if explicitly enabled

Dry-run once:

```bash
RPC_URL=http://127.0.0.1:8545 \
npm -C agents/sdk run example:agent -- --once
```

Execute (sends tx):

```bash
RPC_URL=http://127.0.0.1:8545 \
npm -C agents/sdk run example:agent -- --execute
```

Spending actions are **opt-in**:
- `--enable-furnace-entry --furnace-eth-in <amount>`
- `--enable-takeovers --max-takeover-eth <cap>`

### Private RPC for takeovers and swaps (optional)

Takeovers and swap-heavy actions are MEV-sensitive. If you operate a private tx endpoint (protected RPC / builder relay), the SDK can route selected transactions there.

Config
- Env: `PRIVATE_RPC_URL`, `PRIVATE_RPC_MODE=off|route|only`
- CLI: `--private-rpc-url`, `--private-rpc-mode off|route|only`

Modes
- `route`: send allowlisted actions via `PRIVATE_RPC_URL`, everything else via `RPC_URL`
- `only`: **block execution** of non-allowlisted actions (dry-run still works)
- `off`: disable private routing (default when `PRIVATE_RPC_URL` is unset)

Allowlisted actions (v3)
- Takeovers (MEV-sensitive):
  - `mineCore.takeover`, `mineCore.takeoverFor`
  - `mineCore.takeoverWithToken`
- Furnace entry (swap-heavy when token-based):
  - `furnace.enterWithEth`, `furnace.enterWithEthFor`
  - `furnace.enterWithToken`, `furnace.enterWithTokenFromCallerFor`
  - `furnace.enterWithClaim`, `furnace.enterWithClaimFromCallerFor`
- Market exits / fills (swap/quote sensitive):
  - `marketRouter.sellLockToFurnace`, `marketRouter.sellListedLockToFurnace`, `marketRouter.executeAutoFurnace`
- Royalties lock-mode collect (routes ETH through Furnace):
  - `royalties.claimShareholderLock` (SDK plan-action kind for `ShareholderRoyalties.claimShareholder(mode=1, ...)`)
- ClaimAllHelper delegated wrappers (`claimShareholderForUser`, `claimAllFor`) are ETH-only (`mode == 0`); they do not perform Furnace locks and therefore are not on the swap-heavy MEV-sensitive rail. The Furnace-lock rail for shareholder Collect runs through the user-direct path `royalties.claimShareholder (mode = LOCK_FURNACE)` listed above.

Notes
- Reads and simulations always use `RPC_URL` (private routing only affects sending).
- In `PRIVATE_RPC_MODE=only`, non-allowlisted writes (offers/listings/approvals/config) are blocked. Use `route` for mixed workloads.
- Private RPC providers are trusted infrastructure. Use only endpoints you trust.

Example (strict allowlist mode)
```bash
RPC_URL=http://127.0.0.1:8545 PRIVATE_RPC_URL=http://127.0.0.1:8545 PRIVATE_RPC_MODE=only npm -C agents/sdk run example:agent -- --execute --enable-takeovers --max-takeover-eth 0.01
```


## Reliability and monitoring

These knobs are optional, but recommended for real unattended bots.

### Monitor endpoint (optional)

Expose a local HTTP endpoint with agent health + recent telemetry:
- Enable: `--monitor` (or env `AGENT_MONITOR_ENABLED=1`)
- Bind: `AGENT_MONITOR_HOST=127.0.0.1` (default), `AGENT_MONITOR_PORT=8787` (default)
- Optional auth: `AGENT_MONITOR_TOKEN=<secret>`
- Ring size: `AGENT_MONITOR_MAX_RECENT=200` (default)

Example:
```bash
RPC_URL=http://127.0.0.1:8545   npm -C agents/sdk run example:agent -- --once --monitor

curl http://127.0.0.1:8787/health
```

### Durable event cursor (events + reorg safety)

When events are enabled, the agent persists a cursor file:
- `agents/sdk/out/agent-state/<chain>/<chainId>/<agent[-for-user]>/event-cursor.json`
- This includes the last processed block + a recent-key set used to dedupe events across reorgs.
- On startup, the agent rewinds a small number of blocks and replays deterministically.

Config (env)
- `AGENT_STATE_DIR=<path>` (override state root)
- `EVENT_CURSOR_REWIND_BLOCKS=20` (default)
- `EVENT_CURSOR_MAX_KEYS=5000` (default)

### Nonce manager + tx replacement (optional)

For MEV-sensitive txs and flaky RPCs, the SDK can manage nonces and fee-bump stuck txs:
- `TX_MANAGE_NONCES=1` (managed nonce allocation + receipt timeout; useful when mixing public + private RPC)
- `TX_REPLACEMENT_ENABLED=1` (implies managed nonces; fee-bump + resubmit stuck txs)
  - `TX_REPLACEMENT_TIMEOUT_MS=45000` (receipt timeout; also the per-attempt replacement window when enabled)
  - `TX_REPLACEMENT_MAX_ATTEMPTS=3`
  - `TX_POLL_INTERVAL_MS=1500`
  - `TX_FEE_BUMP_BPS=12500` (+25% per attempt)

The per-action `txs.jsonl` file records `nonce`, `attempts`, and `hashes` when replacement is enabled.

### Backoff circuit breaker (execute mode)

When `--execute` is enabled, the runner uses an explicit circuit breaker:
- Default: enabled (set `BACKOFF_ENABLED=0` to disable)
- Emits achievements: `BACKOFF_ENTERED`, `BACKOFF_CLEARED`
- Config (env):
  - `BACKOFF_BASE_MS=1000`
  - `BACKOFF_MAX_MS=600000`
  - `BACKOFF_MULTIPLIER=2`
  - `BACKOFF_MAX_TIMEOUTS=3`
  - `BACKOFF_MAX_ERRORS=10`
  - `BACKOFF_RESET_AFTER_MS=600000`

### Replay + strategy development (offline)

Record ticks in a live run, then replay offline to regression-test decision-making:
- Record: `WRITE_TICK_RECORDS=1` (live agent)
- Replay: `npm -C agents/sdk run example:replay -- --run-dir agents/sdk/out/agent-<timestamp> --compare --pretty`
- Strategy modules:
  - Load into the live agent: `--strategy-module ./path/to/strategy.mjs`
  - Example: `npm -C agents/sdk run example:agent -- --strategy-module ./my-strategy.mjs`
  - Or via env: `STRATEGY_MODULES=./a.mjs,./b.mjs`
  - Templates live in `agents/sdk/strategies/`
- Fast iteration: `npm -C agents/sdk run example:strategy -- --run-dir ... --strategy-module ... --pretty`


## Achievements telemetry

The SDK writes a compact JSONL telemetry stream in two modes (live agent and plan executor). The full schema, kind enum, optional badge polling, and tuning knobs live in [Achievements Telemetry](achievements-telemetry.md). Subscribe to the JSON Schema at `agents/sdk/schemas/achievements.v1.schema.json` rather than reverse-engineering the emitter.

## Delegated agents

Delegated agents run from the bot's wallet, but **act for** a `user` address via **DelegationHub** sessions.

High-level model:
- User grants a session: `(delegate, perms, expiry)`.
- Bot submits txs from its own address (pays gas and any ETH/CLAIM spend), calling delegated protocol entry points.
- Protocol contracts resolve their canonical auth roots onchain and then verify the session via `DelegationHub.isAuthorized(...)`. Do not assume a raw stored `delegationHub` pointer is trusted in isolation.

### Create or refresh a session

In production, the user signature should come from their wallet (EOA) or an EIP-1271 smart wallet.

Local demo (actor0=user, actor1=delegate):

```bash
RPC_URL=http://127.0.0.1:8545 \
npm -C agents/sdk run example:delegation
```

### Run the live agent for a user

Use `--acting-for` to switch the agent into delegated mode.

```bash
# run the delegate (actor1) but act for the user address
RPC_URL=http://127.0.0.1:8545 \
npm -C agents/sdk run example:agent -- --actor-index 1 --acting-for 0xUserAddress --once

# execute (sends tx)
RPC_URL=http://127.0.0.1:8545 \
npm -C agents/sdk run example:agent -- --actor-index 1 --acting-for 0xUserAddress --execute
```

Notes:
- Strategy flags like `--enable-furnace-entry` / `--enable-takeovers` still apply, but the SDK will prefer delegated entry points when `--acting-for` is set.
- The session must include the required permission bits for each action (see [Bot sessions (DelegationHub)](delegationhub.md)).

### Delegated smoke test harness

The harness includes a small delegated scenario:

```bash
RPC_URL=http://127.0.0.1:8545 \
npm -C agents/sdk run example:harness -- --scenario delegated
```

This performs:
- `DelegationHub.setSessionBySig` (user signs, delegate submits)
- `Furnace.enterWithEthFor(user, ...)` (delegate pays, user receives ve)
- `MineCore.takeoverFor(user, maxPrice)` (delegate pays, user becomes King)

## Plan format for external AI

The AgentPlan v1 schema, executor, action coverage, and auto-approval semantics live in [Agent Plan Format](agent-plan-format.md). Build a plan with `example:plan`; simulate or execute with `example:execute-plan`. Canonical source: `agents/sdk/schemas/agent-plan.v1.schema.json`.

## Subgraph health and core/event-derived address parity

Before relying on subgraph data in production, validate:
- indexing lag vs RPC head
- core/event-derived protocol contract address parity vs current manifest

```bash
RPC_URL=... \
SUBGRAPH_URL=... \
npm -C agents/sdk run example:subgraph-health -- --pretty
```

## Operational guidance

For self-run agents:
- Use a dedicated wallet (separate from treasury / cold storage).
- Always cap spend (`maxTakeoverEth`, max actions per cycle).
- Always include slippage floors and deadlines.
- Treat MineCore contention reverts as normal; re-quote right before send.
- Log everything (snapshots, decisions, tx hashes, reverts).

For delegated agents:
- Prefer short session expiries (hours, not days) to limit user exposure.
- Re-check session validity before executing; user may revoke mid-cycle.
- Track permission bits required per action type (see [Bot sessions](delegationhub.md)).
- Separate spend accounting: bot pays gas and ETH / CLAIM, user receives benefits.
- Log the user address (`--acting-for`) with every action for session history.
- Handle EIP-1271 smart wallet signatures in production (not just EOA).
- Monitor for session expiry approaching; prompt user to refresh proactively.

## OpenClaw / Cursor skill

The repository ships a workspace-scoped agent skill at [`skills/claimrush/`](https://github.com/claimrush/claimrush/tree/main/skills/claimrush) that wraps `@claimrush/agent-sdk` with a chat-friendly CLI. It is compatible with any runner that consumes workspace skill manifests (OpenClaw, Cursor, etc.) and is the canonical surface for chat-driven control of the protocol. Every write goes through one CRAL guardrail layer (`skills/claimrush/src/safety/cral.ts`); dry-run is the default and mainnet writes require four flags (`--chain base --execute --i-understand` plus an `RPC_URL` listed in `CR_SKILL_BASE_RPC_ALLOWLIST`).

Verbs:

| Verb | Action |
|------|--------|
| `status` | `getGameStateSnapshot` (read-only). |
| `monitor` | Tail events / achievements (read-only). |
| `takeover` | `MineCore.takeover` / `takeoverWithToken`. |
| `lock` | `Furnace.enterWithEth` / `enterWithClaim` / `enterWithToken`. |
| `furnace` | Chat alias: `furnace lock <ETH>` / `furnace status` rewrites to `lock` / `status`. |
| `collect` | `ShareholderRoyalties.claimShareholderEth` / `claimShareholderLock` (ETH royalties). |
| `withdraw` | `MineCore.withdrawKingBalance` / `withdrawRefundBalance`. |
| `market` | Offer / listing / sell-to-furnace. |
| `session` | `DelegationHub`: build / submit / revoke / status. |
| `plan` | `AgentPlan` v1: build or execute. |
| `agent` | Run the live agent loop (defaults to `--once`; `--loop` is opt-in). |
| `cral` | Print the parsed CRAL safety pack (`json` / `prompt` / `hard-rules`). |

**SDK vs skill.** Use the SDK directly for service-shaped runners that own their own scheduling, retries, and persistence; headless replay; or fine-grained access to internals not surfaced as a CLI verb. Use the skill when a chat agent is making decisions on the user's behalf, when you want a single guardrail chokepoint between an LLM and the SDK, or when you want a uniform JSONL receipt format across reads and writes.

## Base MCP plugin

For AI assistants that already speak Base's Model Context Protocol (Coinbase Wallet's agent mode, the Base AI sandbox, custom MCP-aware clients), ClaimRush ships a hosted plugin at `claimru.sh/api/mcp/v1/*`. The plugin produces unsigned calldata that the user's wallet signs via `send_calls` — there's no SDK to install and no delegation required.

See the developer reference: **[Base MCP plugin](base-mcp-plugin.md)** and the tutorial: **[Build a Base MCP agent for ClaimRush](tutorials/build-base-mcp-agent.md)**. The user-facing tutorial is at [Use with an AI assistant (Base MCP)](https://docs.claimru.sh/tutorials/use-with-ai-assistants).

The full end-to-end lifecycle — setup, read state, dry-run, local write, sepolia, mainnet preflight, CRAL inspection, receipts — lives in the tutorial: [Run the ClaimRush OpenClaw skill](tutorials/run-claimrush-openclaw-skill.md).

Reference:
- Agent-facing instructions: [`skills/claimrush/SKILL.md`](https://github.com/claimrush/claimrush/blob/main/skills/claimrush/SKILL.md)
- Human notes (CLI surface, env vars, safety rules): [`skills/claimrush/README.md`](https://github.com/claimrush/claimrush/blob/main/skills/claimrush/README.md)
- CRAL manifest: [`docs/manuals/developer/agents-and-automation.cral.yaml`](https://developers.claimru.sh/agents-and-automation.cral.yaml) (the same file the skill loads at startup)

## See also

- [Bot Sessions (DelegationHub)](delegationhub.md) — session management and permission map
- [Maintenance and Bots](maintenance-and-bots.md) — keeper loops and slippage
- [Tutorials](tutorials/README.md) — step-by-step recipes
- Tutorial: [Run a Crown bot](tutorials/run-crown-bot-at-30min.md)
- Tutorial: [Run the ClaimRush OpenClaw skill](tutorials/run-claimrush-openclaw-skill.md)
- Reference: [Base MCP plugin](base-mcp-plugin.md)
- Tutorial: [Build a Base MCP agent for ClaimRush](tutorials/build-base-mcp-agent.md)
- User manual: [Bots & Automation](https://docs.claimru.sh/bots-and-automation)
