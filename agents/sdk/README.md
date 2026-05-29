# @claimrush/agent-sdk

Internal TypeScript SDK to help offchain agents interact with ClaimRush.

Scope (v1)

- Load deployment manifests from `/<repo>/deployments/*.json`
- Load ABIs from `/<repo>/abis/*/*.abi.json`
- Create viem contract clients (read + write), including derived contracts (FurnaceQuoter) resolved from chain
- Common quote helpers (MineCore and Furnace)
- Basic error classification (custom errors)
- Agent telemetry (achievements JSONL)

Install

```bash
npm -C agents/sdk install
```

Action coverage audit

```bash
npm -C agents/sdk run example:action-coverage -- --pretty
```

This reads `schemas/agent-plan.v1.schema.json` and outputs the supported `AgentAction.kind` values.

Example (local)

1. start Anvil + deploy contracts:

```bash
npm run local
```

2. run quickstart:

```bash
RPC_URL=http://127.0.0.1:8545 npm -C agents/sdk run example:quickstart
```

3. print a full game snapshot (optional USER_ADDRESS slice):

```bash
RPC_URL=http://127.0.0.1:8545 USER_ADDRESS=0xf39Fd6e51aad88F6F4ce6aB8827279cffFb92266 \
  npm -C agents/sdk run example:snapshot
```

4. quote a token takeover (compute `minEthOut` for `MineCore.takeoverWithToken`)

```bash
# Default:
# - TOKEN_IN defaults to wrapped native (WETH) from the MineCoreEntryTokenRegistry
# - AMOUNT_IN defaults to the current takeover price (WETH unwrap is 1:1)
RPC_URL=http://127.0.0.1:8545 \
  npm -C agents/sdk run example:takeover-token-quote

# Custom token route (must be allowlisted in MineCoreEntryTokenRegistry)
# AMOUNT_IN is raw base units (example: 1 USDC = 1000000)
RPC_URL=http://127.0.0.1:8545 \
TOKEN_IN=0xYourTokenAddress \
AMOUNT_IN=1000000 \
SLIPPAGE_BPS=100 \
  npm -C agents/sdk run example:takeover-token-quote
```

Notes:

- The quote is produced by the onchain view contract `MineCoreQuoter`, which mirrors MineCore's swap validation.
- Use `minEthOut` (or the stricter `minEthOutStrict`) from the output as the third arg to `takeoverWithToken(...)`.

5. live prices (CLAIM/ETH + entry tokens) and Aerodrome spot quotes

This example:

- Enumerates enabled entry tokens from the subgraph (`EntryTokenConfig`).
- Computes spot quotes via the protocol's `DexAdapter.getAmountsOut` using allowlisted registry routes.
- Optionally includes the subgraph `TokenPricingSnapshot` (CLAIM/ETH TWAP + ETH/USD).

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
- Spot quotes are size-dependent. The helper quotes **1 token** (10^decimals) for each entry token.
- Treat subgraph pricing as informational (it can lag). Spot quotes come from onchain reads.

6. stream events (JSON lines) (defaults: MineCore/Furnace/Royalties core events)

```bash
RPC_URL=http://127.0.0.1:8545 npm -C agents/sdk run example:events

# Optional: backfill recent events from the subgraph before live streaming
SUBGRAPH_URL=http://127.0.0.1:8000/subgraphs/name/claimrush/local \
  npm -C agents/sdk run example:events -- --backfill
```

7. run the agent harness (deterministic local simulation + regression assertions)

```bash
RPC_URL=http://127.0.0.1:8545 npm -C agents/sdk run example:harness
```

Delegated smoke scenario (actor0=user, actor1=delegate):

```bash
RPC_URL=http://127.0.0.1:8545 \
npm -C agents/sdk run example:harness -- --scenario delegated
```

8. run a live agent loop (policy + executor)
   - Defaults to DRY-RUN (no tx). Add `--execute` to send transactions.

```bash
RPC_URL=http://127.0.0.1:8545 npm -C agents/sdk run example:agent

# Optional: backfill recent events from the subgraph into the agent's event log on startup
SUBGRAPH_URL=http://127.0.0.1:8000/subgraphs/name/claimrush/local EVENT_BACKFILL=1 \
  npm -C agents/sdk run example:agent

# Enable spending actions explicitly
npm -C agents/sdk run example:agent -- --enable-furnace-entry --furnace-eth-in 1000 --execute
npm -C agents/sdk run example:agent -- --enable-takeovers --max-takeover-eth 0.01 --execute
```

### Monitor endpoint (optional)

The live agent can expose a lightweight local HTTP server for health + recent telemetry (plans, strategies, events, txs, achievements). This is useful for dashboards and supervising unattended bots.

Config

- Enable: `--monitor` (or env `AGENT_MONITOR_ENABLED=1`)
- Bind: `AGENT_MONITOR_HOST=127.0.0.1` (default), `AGENT_MONITOR_PORT=8787` (default)
- Optional auth: `AGENT_MONITOR_TOKEN=<secret>` (send `Authorization: Bearer <secret>`)
- Ring size: `AGENT_MONITOR_MAX_RECENT=200` (default)

Endpoints

- `GET /health` – basic health + counters
- `GET /state` – full monitor state (includes backoff + event cursor snapshots when enabled)
- `GET /recent/plans?limit=50`
- `GET /recent/strategies?limit=50`
- `GET /recent/events?limit=50`
- `GET /recent/txs?limit=50`
- `GET /recent/achievements?limit=50`

Example

```bash
RPC_URL=http://127.0.0.1:8545   npm -C agents/sdk run example:agent -- --once --monitor

curl http://127.0.0.1:8787/health
curl http://127.0.0.1:8787/recent/txs?limit=10

# If AGENT_MONITOR_TOKEN is set:
curl -H "Authorization: Bearer $AGENT_MONITOR_TOKEN" http://127.0.0.1:8787/state
```

Notes

- Intended for localhost / trusted networks. Do not expose it publicly.

### Private RPC for takeovers and swaps (optional)

If you operate a private transaction endpoint (protected RPC / builder relay), the SDK can route **MEV-sensitive** transactions there.

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
- Royalties lock-mode claim (routes ETH through Furnace):
  - `royalties.claimShareholderLock`
- ClaimAllHelper when it performs a Furnace lock:
  - `claimAllHelper.claimShareholderForUser`, `claimAllHelper.claimAllFor` when `mode=LOCK_FURNACE (1)`

Notes

- Reads and simulations always use `RPC_URL` (private routing only affects **sending**).
- In `PRIVATE_RPC_MODE=only`, non-allowlisted writes (offers/listings/approvals/config) are blocked. Use `route` for mixed workloads.
- Treat private RPC providers as trusted infrastructure for your order flow.

Example (strict allowlist: block everything else)

```bash
RPC_URL=http://127.0.0.1:8545     PRIVATE_RPC_URL=http://127.0.0.1:8545     PRIVATE_RPC_MODE=only       npm -C agents/sdk run example:agent -- --execute --enable-takeovers --max-takeover-eth 0.01
```

### Strategy plugins (optional)

The live agent can be driven by _programmatic_ strategy plugins instead of the built-in policy planner.

Behavior

- When `strategies` is provided (non-empty), the agent calls each strategy every tick (priority desc, then id) and concatenates proposed actions.
- If `strategies` is unset, the agent uses the built-in policy `buildActionPlan(...)`.
- Strategy traces are written to `decisions.jsonl` and (when the monitor server is enabled) exposed at `GET /recent/strategies`.

Programmatic example

```ts
import { runLiveAgent, createPolicyStrategy, type AgentStrategy } from '@claimrush/agent-sdk';

const snipeTakeover: AgentStrategy = {
  id: 'takeover.snipe',
  priority: 100,
  stopOnActions: true,
  propose: (ctx) => {
    if (!ctx.config.enableTakeovers) return;
    const price = ctx.snapshot.global.mineCore.currentTakeoverPrice;
    // Your logic here (budget checks, cooldowns, risk rules...)
    return [{ kind: 'mineCore.takeover', price }];
  },
};

await runLiveAgent({
  rpcUrl: process.env.RPC_URL!,
  chain: 'local',
  execute: false,
  strategies: [
    snipeTakeover,
    createPolicyStrategy({ priority: 0 }), // fallback to default behavior
  ],
});
```

CLI example (load strategy modules)

```bash
# Load strategies from an ESM module (repeatable)
npm -C agents/sdk run example:agent -- \
  --strategy-module ./path/to/strategies.js \
  --include-policy-strategy \
  --execute

# Or via env (comma-separated)
STRATEGY_MODULES=./a.js,./b.js INCLUDE_POLICY_STRATEGY=1 \
  npm -C agents/sdk run example:agent -- --execute
```

9. build a plan file (AgentPlan JSON)
   - Useful when an external agent/LLM decides actions and you want a stable handoff format.

```bash
RPC_URL=http://127.0.0.1:8545 npm -C agents/sdk run example:plan -- --out /tmp/agent-plan.json --pretty
```

10. execute a plan file (simulate by default)

```bash
# Simulate (no tx)
RPC_URL=http://127.0.0.1:8545 npm -C agents/sdk run example:execute-plan -- --plan /tmp/agent-plan.json

# Execute (sends tx)
RPC_URL=http://127.0.0.1:8545 npm -C agents/sdk run example:execute-plan -- --plan /tmp/agent-plan.json --execute

# Optional: emit achievements.jsonl (and poll frontend badges)
ACHIEVEMENTS_BASE_URL=http://127.0.0.1:3000 \
  npm -C agents/sdk run example:execute-plan -- --plan /tmp/agent-plan.json --execute
```

11. market actions demo (offers, listings, sells)

```bash
# Prints a single-action plan and simulates it (no tx)
RPC_URL=http://127.0.0.1:8545 npm -C agents/sdk run example:market -- --help

# Example: create an offer (simulated)
RPC_URL=http://127.0.0.1:8545 TARGET_BONUS_BPS=2500 BUDGET_CLAIM=1000000000000000000 DURATION_DAYS=30 \
  npm -C agents/sdk run example:market -- --cmd offer-create

# Execute (offers are NOT allowlisted for PRIVATE_RPC_MODE=only; use route/off)
RPC_URL=http://127.0.0.1:8545 \
  TARGET_BONUS_BPS=2500 BUDGET_CLAIM=1000000000000000000 DURATION_DAYS=30 \
  npm -C agents/sdk run example:market -- --cmd offer-create --execute

# Optional: set PRIVATE_RPC_URL + PRIVATE_RPC_MODE=route so only swap/takeover txs go private
```

Action coverage (AgentPlan v1)

- MineCore:
  - Takeovers: `takeover`, `takeoverWithToken`
  - Config: `setCurrentReignRecipients`, `setKingAutoLockConfig`
  - Withdrawals: `withdrawKingBalance`, `withdrawRefundBalance`
- Furnace:
  - Entry: `enterWithEth`, `enterWithClaim`, `enterWithToken` (+ delegated `...For` variants)
- Royalties:
  - Claims: `claimShareholderEth`, `claimShareholderLock`
  - Auto-compound config: `setAutoCompoundConfig` (+ delegated `...ForUser`)
- MarketRouter:
  - Listings: `listLock`, `delistLock`, `cancelExpiredListing`
  - Offers: `createBonusTargetEscrowWithTarget`, `cancelBonusTargetEscrow`, `extendBonusTargetEscrowExpiry`, `cancelExpiredBonusTargetEscrow`, `executeAutoFurnace`
  - Exits: `sellLockToFurnace`, `sellListedLockToFurnace`
- Furnace (lock economics):
  - Extend: `extendWithBonus`, `extendWithBonusFor`
  - Merge: `mergeLocksWithBonus`, `mergeLocksWithBonusFor` (v1.0.0; replaces the
    raw `VeClaimNFT.mergeLocks{,ForUser}` entry points so the bonus engine and
    reserve accounting are reused)
- veCLAIM (VeClaimNFT):
  - Maintenance: `unlock`, `setAutoMax`
  - Checkpoints: `checkpointGlobalState`, `checkpointTotalVe`
- Approvals:
  - ERC20: `approve`, `ensureAllowance`
  - veNFT: `approve`, `setApprovalForAll`

Tip: external AIs should treat these schemas as canonical:

- Plan actions: `agents/sdk/schemas/agent-plan.v1.schema.json`
- Run session (session.json): `agents/sdk/schemas/agent-session.v1.schema.json`
- Tick records (ticks.jsonl lines): `agents/sdk/schemas/agent-tick-record.v1.schema.json`

Plan schema (v1)

- `agents/sdk/schemas/agent-plan.v1.schema.json`
  Session schema (v1)
- `agents/sdk/schemas/agent-session.v1.schema.json`
  Tick record schema (v1)
- `agents/sdk/schemas/agent-tick-record.v1.schema.json`
  Artifacts are written under:
- Harness: `agents/sdk/out/harness-<timestamp>/`
  - `snapshot.before.json` / `snapshot.after.json`
  - `events.jsonl`
  - `run.json`
- Live agent: `agents/sdk/out/agent-<timestamp>/`
  - `session.json` (run metadata + policy config)
  - `ticks.jsonl` (optional; enable with `WRITE_TICK_RECORDS=1`)
  - `snapshot.latest.json`
  - `decisions.jsonl`
  - `txs.jsonl`
  - `events.jsonl`
  - `achievements.jsonl`
- Plan executor: `agents/sdk/out/execute-plan-<timestamp>/`
  - `plan.json`
  - `results.jsonl`
  - `achievements.jsonl`

- Durable state: `agents/sdk/out/agent-state/<chain>/<chainId>/<agent[-for-user]>/`
  - `event-cursor.json` (event stream checkpoint + reorg-safe dedupe)
  - Override dir: `AGENT_STATE_DIR=<path>`
  - Knobs: `EVENT_CURSOR_REWIND_BLOCKS=20`, `EVENT_CURSOR_MAX_KEYS=5000`

## Replay (offline)

To make agent decision-making auditable and regression-testable, you can record per-tick snapshots during a live agent run and replay them offline.

Record ticks

- Env: `WRITE_TICK_RECORDS=1`
- Only effective when `WRITE_ARTIFACTS=1` (default)

Example

```bash
# Run a dry-run agent and record ticks
RPC_URL=http://127.0.0.1:8545 WRITE_TICK_RECORDS=1 \
  npm -C agents/sdk run example:agent
```

Replay

```bash
npm -C agents/sdk run example:replay -- --run-dir agents/sdk/out/agent-<timestamp> --pretty
```

Replay + compare (regression check)

```bash
npm -C agents/sdk run example:replay -- --run-dir agents/sdk/out/agent-<timestamp> --compare --pretty
```

Replay with strategy plugins (optional)

- If the original run was started with custom `AgentStrategy` plugins, replay/compare must load the same strategy modules.
- CLI (repeatable):

```bash
npm -C agents/sdk run example:replay -- \
  --run-dir agents/sdk/out/agent-<timestamp> \
  --compare \
  --strategy-module ./path/to/strategies.js
```

- Env (comma-separated): `STRATEGY_MODULES=./a.js,./b.js`

Compare output

- `replay.compare.jsonl` (only when `--compare`; contains mismatched ticks)

Repo fixture (CI sanity check)

- `agents/sdk/fixtures/replay/empty-run/` is a minimal offline run directory used as a regression sentinel.
- Run it with: `make agents-replay-fixture` (also included in `make gates-agents`).

Output (replay)

- `replay.plans.jsonl` (one line per tick; includes `actions`)
- `replay.summary.json`

Notes

- Replay does **not** send transactions (planner only).
- Tick records include the snapshot, the policy state, and (in delegated mode) the caller + delegation contexts used for planning.

## Auto approvals

When running unattended, the agent can automatically insert the required approval actions _ahead_ of token/NFT-based actions.

Enable (env vars)

- `AUTO_APPROVE_ENABLED=1`
- `AUTO_APPROVE_MODE=exact|max` (default: `exact`)
- `AUTO_APPROVE_NFT=1` (default: `1`; set to `0` to disable veNFT approvals)

Safety notes

- Auto approvals are inserted only when `execute=true` (they are skipped in dry-run mode).
- Auto approvals are **not compatible with** `PRIVATE_RPC_MODE=only` (approval txs are blocked). Pre-approve once, or use `PRIVATE_RPC_MODE=route`.
- `exact` approves only the minimum needed for the next action.
- `max` approves `MaxUint256` (more convenient, higher risk).
- veNFT approvals use per-tokenId `approve` (not `setApprovalForAll`) for safety.

Currently auto-approved

- `furnace.enterWithClaim`, `furnace.enterWithToken` (+ delegated `...FromCallerFor` variants)
- `mineCore.takeoverWithToken`
- `marketRouter.createBonusTargetEscrowWithTarget`
- `marketRouter.listLock`, `marketRouter.sellLockToFurnace`, `marketRouter.sellListedLockToFurnace`

## txs.jsonl

The live agent writes a JSONL stream of action execution results to:

- `agents/sdk/out/agent-<timestamp>/txs.jsonl`

Each line includes:

- `ts` (ms since unix epoch)
- `chain`, `chainId`
- `agent` (sender)
- `user` (managed identity; same as agent when self-playing)
- `action` (the AgentAction object)
- `simulated` (boolean)
- `hash` (present for executed txs)
- `receiptBlockNumber` (present when mined)
- `tx` (transaction telemetry)
  - `route`: `public` | `private` (private is only used for allowlisted MEV-sensitive txs)
  - `privateRpcMode`: `off` | `route` | `only`
  - `nonce`, `attempts`, `hashes` (present when tx manager / replacement is enabled)
  - `blockNumber`, `status`, `gasUsed`, `effectiveGasPrice`, `feePaidWei` (present when mined)
- `errorInfo` (best-effort decoded error classification)
- `details` (quotes, guards, misc context)
- `error` (string)

Notes

- `feePaidWei` is computed as `gasUsed * effectiveGasPrice` when both are available.
- `hashes` is useful for fee-bump replacements (first..last broadcast for a nonce).

Enable nonce management / replacement (optional)

- `TX_MANAGE_NONCES=1` (managed nonce allocation + receipt timeout; useful when mixing public + private RPC)
- `TX_REPLACEMENT_ENABLED=1` (implies managed nonces; fee-bump + resubmit stuck txs)
  - `TX_REPLACEMENT_TIMEOUT_MS=45000` (receipt timeout; also the per-attempt replacement window when enabled)
  - `TX_REPLACEMENT_MAX_ATTEMPTS=3`
  - `TX_POLL_INTERVAL_MS=1500`
  - `TX_FEE_BUMP_BPS=12500` (+25% per attempt)

## Achievements (telemetry)

Both the live agent loop and the plan executor emit structured milestones/incidents:

- Live agent: `agents/sdk/out/agent-<timestamp>/achievements.jsonl`
- Plan executor: `agents/sdk/out/execute-plan-<timestamp>/achievements.jsonl`

Each line is a JSON object:

- `ts` (ms since unix epoch)
- `kind` (string)
- `level` (`info` | `warn` | `error`)
- optional context: `chain`, `chainId`, `agent`, `user`, `blockNumber`, `txHash`, `data`

Achievement kinds (v1)

- Value milestones:
  - `TAKEOVER_SUCCESS` (king changed to the tracked identity)
  - `REIGN_REWARD_COLLECTED` (king/refund bucket withdrawal)
  - `FURNACE_LOCK_CREATED` (new ve lock via Furnace)
  - `ROYALTIES_CLAIMED` (shareholder claim executed)
  - `AUTOCOMPOUND_EXECUTED` (shareholder auto-compound executed)
- Frontend profile badges (optional):
  - `BADGE_UNLOCKED` (new badge unlocked or tier upgraded; polled from the public achievements API)
- Safety/ops:
  - `SLIPPAGE_GUARD_TRIGGERED` (tx reverted on a minOut guard)
  - `SESSION_EXPIRED` (delegated mode: session missing/expired)
  - `PAUSED_ACTION_SKIPPED` (feature paused; agent skipped)
  - `REVERTED_TX` (unclassified revert; includes best-effort error info)
  - `RPC_LAG_DETECTED` (best-effort head timestamp staleness)
  - `SUBGRAPH_LAG_DETECTED` (subgraph indexing lag vs RPC head)
  - `BACKOFF_ENTERED` (circuit breaker activated; agent pauses writes)
  - `BACKOFF_CLEARED` (cooldown elapsed; agent resumes)
- Optional scoring:
  - `ACTION_UTILITY` (only if `EMIT_ACTION_UTILITY=1`)

Tuning (env)

- `EMIT_ACTION_UTILITY=1`
- `SUBGRAPH_LAG_THRESHOLD_BLOCKS=200` (default)
- `SUBGRAPH_CHECK_INTERVAL_MS=60000` (default)
- `RPC_LAG_THRESHOLD_SECONDS=0` (disabled by default)
- `RPC_LAG_RECENT_WINDOW_SECONDS=60` (default)
- Frontend achievements API (optional):
  - `ACHIEVEMENTS_BASE_URL=<url>` (enables badge polling; ex: https://claimru.sh or http://127.0.0.1:3000)
  - `ACHIEVEMENTS_POLL_MS=20000` (default)
  - `ACHIEVEMENTS_REFRESH_COOLDOWN_MS=5000` (default)
  - `ACHIEVEMENTS_TIMEOUT_MS=10000` (default)

Frontend badge polling

- The agent polls: `{ACHIEVEMENTS_BASE_URL}/api/achievements?address=<user>&chainId=<chainId>`.
- Supported chain ids: 8453 (Base), 84532 (Base sepolia), 31337 (local Anvil).
- First successful poll initializes a baseline and emits nothing.
- After a confirmed onchain tx, the agent requests a one-shot refresh (debounced, `refresh=1`).
- Badge definitions are ported from the frontend into `agents/sdk/src/achievements/profileBadges.ts` (delegation-only badges excluded).

Using achievements as compact agent context

```bash
# Tail the last 20 achievements across recent runs
tail -n 50 agents/sdk/out/agent-*/achievements.jsonl | tail -n 20

# Or: plan executor runs
tail -n 50 agents/sdk/out/execute-plan-*/achievements.jsonl | tail -n 20
```

Notes

- Treat `data` as versioned/best-effort; rely on `kind` + `level` for stability.
- Most value achievements come from **onchain events** (source of truth), not the subgraph.

Filter examples:

```bash
# Only MineCore takeovers, starting from block 0
RPC_URL=http://127.0.0.1:8545 \
  npm -C agents/sdk run example:events -- --contracts MineCore --events Takeover --from-block 0

# Watch all Furnace events via polling (HTTP friendly)
RPC_URL=http://127.0.0.1:8545 \
  npm -C agents/sdk run example:events -- --contracts Furnace --events '*' --poll
```

Usage (library)

```ts
import {
  createClaimRushClients,
  loadDeploymentManifest,
  getClaimRushContracts,
  quoteCurrentTakeoverPrice,
  getGameStateSnapshot,
} from '@claimrush/agent-sdk';

const manifest = loadDeploymentManifest({ chain: 'local' });
const { publicClient } = createClaimRushClients({ rpcUrl: 'http://127.0.0.1:8545' });
const contracts = await getClaimRushContracts({ publicClient, manifest });
const price = await quoteCurrentTakeoverPrice({ contracts });

// Optional: one-shot snapshot of game state + account slice
const snap = await getGameStateSnapshot({ publicClient, manifest, user: '0x...' });
```

11. check subgraph health (indexing lag + core/event-discoverable protocol address parity)

```bash
RPC_URL=http://127.0.0.1:8545 \
SUBGRAPH_URL=http://127.0.0.1:8000/subgraphs/name/claimrush/local \
  npm -C agents/sdk run example:subgraph-health -- --pretty
```

## DelegationHub sessions (agent manages a user identity)

If you want a bot to act _for_ a user (instead of acting as itself), the protocol supports session-based delegation via `DelegationHub`.

This SDK includes helpers for:

- Canonical permission bits (`src/delegation/permissions.ts`)
- EIP-712 typed data generation (`buildSetSessionTypedData`)
- Gasless session set-by-signature (`signSetSession` + `submitSetSessionBySig`)

Example (local):

```bash
RPC_URL=http://127.0.0.1:8545 npm -C agents/sdk run example:delegation
```

Production-style session flow (user signs, delegate submits):

```bash
# 1) Build typed data JSON (safe to run without user private key)
RPC_URL=http://127.0.0.1:8545 \
npm -C agents/sdk run example:session -- --cmd build \
  --user 0xUserAddress \
  --delegate 0xDelegateAddress \
  --perms TAKEOVER_FOR,CLAIM_ALL_FOR \
  --expiry-seconds 3600 \
  --deadline-seconds 600 \
  --out /tmp/session.json \
  --pretty

# 2) User signs /tmp/session.json with eth_signTypedData_v4 in their wallet
# 3) Delegate submits (delegate pays gas)
RPC_URL=http://127.0.0.1:8545 \
PRIVATE_KEYS=0x<delegatePrivateKey> \
npm -C agents/sdk run example:session -- --cmd submit --typed-data /tmp/session.json --sig 0x...

# Revoke (gasless): build + submit with perms=0 expiry=0
RPC_URL=http://127.0.0.1:8545 \
npm -C agents/sdk run example:session -- --cmd build --revoke \
  --user 0xUserAddress \
  --delegate 0xDelegateAddress \
  --out /tmp/revoke.json \
  --pretty

RPC_URL=http://127.0.0.1:8545 \
PRIVATE_KEYS=0x<delegatePrivateKey> \
npm -C agents/sdk run example:session -- --cmd submit --typed-data /tmp/revoke.json --sig 0x...
```

Run a delegated agent loop (delegate is actor1):

```bash
RPC_URL=http://127.0.0.1:8545 \
npm -C agents/sdk run example:agent -- --actor-index 1 --acting-for 0xUserAddress --once

# execute (sends tx)
RPC_URL=http://127.0.0.1:8545 \
npm -C agents/sdk run example:agent -- --actor-index 1 --acting-for 0xUserAddress --execute

# optional: delegated safe maintenance (ve upkeep + config sync)
RPC_URL=http://127.0.0.1:8545 \
ENABLE_SAFE_MAINTENANCE=1 \
npm -C agents/sdk run example:agent -- --actor-index 1 --acting-for 0xUserAddress --execute
```

Build a plan for a user identity:

```bash
RPC_URL=http://127.0.0.1:8545 \
npm -C agents/sdk run example:plan -- --acting-for 0xUserAddress --out /tmp/agent-plan.json --pretty
```

Notes:

- The example uses 2 derived accounts: actor0 = user, actor1 = delegate.
- In production, the user signature should come from a wallet (EOA) or an EIP-1271 smart account.
- Required perms depend on the actions you enable (see docs/manuals/developer/delegationhub.md).
  - For `ENABLE_SAFE_MAINTENANCE=1`, you typically want: `VE_EXTEND_LOCK_FOR`, `VE_UNLOCK_EXPIRED_FOR`, plus any config sync perms you plan to use (`SET_*_CONFIG_FOR`).
  - Tuning: `VE_EXTEND_IF_REMAINING_DAYS` and `VE_EXTEND_BY_DAYS` (defaults: 7 and 30).
  - Config sync env vars: `KING_AUTO_LOCK_*`, `ROYALTIES_AUTOCOMPOUND_*`, `LP_AUTOCOMPOUND_*`.

## Additional examples

- `npm -C agents/sdk run example:strategy` — run a custom strategy example.
- `npm -C agents/sdk run example:delegation-full-test` — end-to-end delegation session test (create, use, revoke).
