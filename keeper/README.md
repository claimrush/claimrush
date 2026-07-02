# ClaimRush Keeper

This folder contains an **offchain keeper runner** for ClaimRush v1.0.0.

Primary purposes (v1.0.0):

- Call `MaintenanceHub.poke(args)` on a schedule.
- Run the underlying maintenance calls directly:
  - `LpStakingVault7D.harvestFeesToRewards(deadline, minClaimOut)`
  - `MarketRouter.executeAutoFurnace(offerId)`
  - `MarketRouter.sellListedLockToFurnace(tokenId)`
    - approved listings are allowlisted settlement-keeper or owner gated during `SETTLEMENT_KEEPER_GRACE_SECONDS`, then become permissionless
    - (`APPROVAL_REVOKED` is a reserved compatibility analytics code and is not emitted by the strict-mode router)
- Run required **auto-compounding** responsibilities directly (NOT via `MaintenanceHub`):
  - `ShareholderRoyalties.compoundForMany(users[], maxUsers)` for opted-in Barons (keeper-allowlisted; owner break-glass also allowed)
  - `LpStakingVault7D.compoundForMany(users[], maxUsers)` for opted-in LP stakers (keeper-allowlisted; owner break-glass also allowed)

Operational references:

- Live operating procedures are deployment-specific and are not bundled in this public repo.

### Adaptive cadence

The keeper's hot-loop cadence is driven by two independent health signals the
daemon logs on every reschedule as `[tier=… ws=…]`:

- `tier=primary|fallback|unknown` — reflects the most recent
  `x-rpc-proxy-upstream-tier` header returned by an upstream RPC proxy (for
  example a Cloudflare Worker that load-balances between multiple Base RPC
  providers). `primary` means the main upstream served the request; `fallback`
  means the proxy has failed over to a secondary upstream. `unknown` covers
  direct-RPC deployments (e.g. local/dev) and indicates the keeper cannot
  distinguish tiers.
- `ws=healthy|recently-disconnected|disconnected|disabled` — liveness of the
  Base WSS subscription used for fast event notification. `disabled` means the
  keeper was configured without a WSS URL (poll-only).

When primary + WSS are both healthy the keeper runs at its normal cadence.
When either signal degrades, cadence stretches to conserve fallback-provider
compute-units and avoid hammering a degraded upstream. Sustained
`tier=fallback ws=disconnected` is the signature of a full fast-path outage
and should page on-call. Operational runbooks for a given deployment are
not bundled in this public repo (see "Operational references" above);
deployment operators wire their own alert routing off the health endpoint
(`KEEPER_HEALTH_PORT`) and the `[tier=… ws=…]` reschedule log lines.

## Features

- **Dry-run mode** (`KEEPER_DRY_RUN=1`): logs intended actions and computed args without submitting transactions.
- **Quote + slippage protection**
  - Harvests: quote `minClaimOut` using Aerodrome router `getAmountsOut()`.
  - Auto-compound: `minVeOut` is computed on-chain from each user's stored `maxSlippageBps`; the keeper does not supply slippage values.
- **Worklist sourcing for auto-compound** (no external DB required)
  - Event-sourced user sets (configured vs paused), scanned in bounded block chunks.
  - Logs are merged + sorted by `(blockNumber, logIndex)` to preserve chain order.
  - On-chain `getAutoCompoundConfig(user)` is the source of truth during batching.
- **Gas-bounded batching**
  - Builds a candidate batch (bounded by `KEEPER_COMPOUND_*_MAX_USERS`).
  - Uses `eth_estimateGas` and shrinks batch size until it fits `KEEPER_COMPOUND_MAX_GAS`.
- **Backoff safety**
  - Market: per-offer exponential backoff with jitter.
  - Auto-compound: per-user exponential backoff for off-chain failures (RPC flakiness, quote failures).
- **Single instance lock** (local file lock with TTL + heartbeat; heartbeat read/write failures are treated as lost-lock conditions and terminate the keeper. Release now unlinks the lock only when the current process can still prove ownership, so corrupt/unreadable lock files fail closed and may require TTL expiry or manual cleanup.)
- **Fail-closed circuit breaker state** (`circuit_breaker.json` is treated as trusted safety input; malformed/unreadable state blocks new tx submission instead of silently resetting the failure counter, and a tripped breaker state still blocks new tx even if the JSON pause-file write failed).
- **Optional RPC auth header**:
  - Prefer per-endpoint tokens:
    - `KEEPER_PRIVATE_RPC_AUTH_TOKEN` for the private (write) RPC.
    - `KEEPER_PUBLIC_RPC_AUTH_TOKEN` for the public (read) RPC.
  - Backward compatible:
    - `KEEPER_RPC_AUTH_TOKEN` applies to BOTH public + private RPCs.
  - Useful if you run a Cloudflare Worker reverse-proxy in front of upstream RPCs.
- **Basic alert hooks**:
  - Persisted JSON status includes last-attempt + last-success timestamps (global and per task), plus per-task revert counts.
  - Optional webhook POST on errors. Redirect responses are treated as failures and are not followed.
- **Optional health server** (daemon):
  - Enable with `KEEPER_HEALTH_PORT` to expose `GET /healthz` and `GET /metrics` (Prometheus).
  - Default bind host is `127.0.0.1`. If binding to a non-loopback host, set `KEEPER_HEALTH_TOKEN`.

## Install

From `keeper/` inside the repo:

```bash
npm ci --omit=dev
```

`npm ci --omit=dev` is recommended for server installs to keep the runtime footprint minimal. `tsx` is pinned as a runtime dependency in this package, so a separate global install is not required.

Production/server installs must preserve the repo layout with these repo-relative paths present alongside `keeper/`:

- `packages/node-utils/`
- `deployments/`

Do not copy only the `keeper/` folder into a standalone directory. The package depends on repo-relative shared code and runtime deployment manifests.

## Configure

Copy the template and fill values:

```bash
# Copy the example env file and fill in your values
cp .env.example .env.keeper
```

If you use a process manager (systemd, Docker, etc.), point it at the env file that matches your target network.

The env file MUST pin `KEEPER_DEPLOYMENT` to the target network (e.g. `base_mainnet` or `base_sepolia`). Keep RPC URLs as explicit placeholders so a staging env cannot silently inherit local/dev values.

Notes:

- If you put an auth token in front of your RPC (eg Cloudflare Worker proxy), prefer:
  - `KEEPER_PRIVATE_RPC_AUTH_TOKEN="..."`
  - (optional) `KEEPER_PUBLIC_RPC_AUTH_TOKEN="..."`
  - Compatibility env var: `KEEPER_RPC_AUTH_TOKEN="..."` (applies to both)
- Auto-compound task state lives in:
  - `$KEEPER_STATE_DIR/<deployment>/compound_shareholders.json`
  - `$KEEPER_STATE_DIR/<deployment>/compound_lp.json`

## Commands

Run once:

```bash
KEEPER_ENV=/path/to/your/keeper.env

# One-shot poke
./node_modules/.bin/tsx ./src/run.ts poke --env "$KEEPER_ENV"

# One-shot harvest
./node_modules/.bin/tsx ./src/run.ts harvest-staking --env "$KEEPER_ENV"

# One-shot market sweep (sends one tx per offer)
./node_modules/.bin/tsx ./src/run.ts sweep-market --env "$KEEPER_ENV"

# One-shot listing sweep (sends one tx per listing; approved settlements are allowlisted settlement-keeper or owner gated during grace)
./node_modules/.bin/tsx ./src/run.ts sweep-listings --env "$KEEPER_ENV"

# One-shot auto-compound batches
./node_modules/.bin/tsx ./src/run.ts compound-shareholders --env "$KEEPER_ENV"
./node_modules/.bin/tsx ./src/run.ts compound-lp --env "$KEEPER_ENV"

# One-shot expire offers (cancel all expired bonus target escrows)
./node_modules/.bin/tsx ./src/run.ts expire-offers --env "$KEEPER_ENV"

# One-shot automax bonus (batch-collect accrued AutoMax bonuses)
./node_modules/.bin/tsx ./src/run.ts automax-bonus --env "$KEEPER_ENV"

# One-shot checkpoint-before-expiry (optional pre-materialization for locks expiring soon)
./node_modules/.bin/tsx ./src/run.ts checkpoint-before-expiry --env "$KEEPER_ENV"

# Print local status (last success timestamp, revert counts)
./node_modules/.bin/tsx ./src/run.ts status --env "$KEEPER_ENV"
```

Swap the env file path as appropriate for your target network. Before you start the daemon, verify the chosen env file's `KEEPER_DEPLOYMENT` matches the network you intend to run.

Cron (if you schedule keeper tasks via crontab instead of the daemon):

```cron
# Optional: pre-materialize shareholder rewards for locks expiring in the next 24h (every 6h)
0 */6 * * * cd /path/to/claimrush/keeper && set -a && . /path/to/your/keeper.env && set +a && ./node_modules/.bin/tsx ./src/run.ts checkpoint-before-expiry
```

Daemon loop (multi-task):

```bash
# Uses KEEPER_DAEMON_TASKS from the env file
./node_modules/.bin/tsx ./src/run.ts daemon --env "$KEEPER_ENV"

# Override tasks at the CLI
./node_modules/.bin/tsx ./src/run.ts daemon --tasks poke,sweep-market,compound-shareholders --env "$KEEPER_ENV"

# Run each configured task once (useful for debugging or CI)
./node_modules/.bin/tsx ./src/run.ts daemon --once --tasks all --env "$KEEPER_ENV"
```

`--tasks all` expands to: `poke`, `harvest-staking`, `sweep-market`, `sweep-listings`, `expire-offers`, `checkpoint-before-expiry`, `compound-shareholders`, `compound-lp`, `automax-bonus`. Note that `all` intentionally includes `expire-offers` and `automax-bonus` but also includes `sweep-listings`.

Notes:

- `checkpoint-before-expiry` is optional. The reward-checkpoint mechanism handles decaying-lock expiry correctly without pre-materialization.
- It can still be useful to pre-materialize balances for UX or to reduce first-interaction gas after long inactivity.

## Settlement Window (configurable cadence)

An opt-in scheduling mode that consolidates reward-settlement tasks into a shared recurring cycle instead of running them on independent intervals. The cadence is set by `KEEPER_SETTLEMENT_PERIOD_SECS` — daily by default (`86400`); set `604800` for weekly.

When enabled (`KEEPER_SETTLEMENT_ENABLED=1`), the settlement tasks (`compound-lp`, `automax-bonus`, `harvest-staking`) are excluded from the normal interval-based loop and instead run within a 24-hour window each cycle:

- **Phase 1 (immediate):** `compound-lp` and `automax-bonus` run at window open (no DEX swap, no front-running risk).
- **Phase 2 (spread):** `harvest-staking` runs once opportunistically.

`compound-shareholders` is **not** a settlement task: it always runs in the normal interval loop. A fixed wall-clock window attempts the compound once per cycle, but the on-chain `ShareholderRoyalties` cadence floor is a hard 24h — because each compound lands a few seconds past window-open, the next cycle's attempt is always just short of 24h and skips, collapsing the effective cadence to ~48h. Running it on its own interval makes attempts floor-relative: with `KEEPER_COMPOUND_SHAREHOLDER_MIN_CADENCE_SECS` set just above 24h (e.g. `86700` = 24h+5min) the keeper only attempts once the contract will accept it, holding a ~daily cadence. Pair the floor with `KEEPER_COMPOUND_SHAREHOLDER_INTERVAL_SECS` (clamped to a 3600s / 60m minimum, e.g. `3600`) so an eligible user is picked up within one tick of the floor clearing.

By default every user that has cleared the floor on a given tick is compounded together in one `compoundForMany` transaction. Set `KEEPER_COMPOUND_SHAREHOLDER_SPREAD_SECS` to fan them out instead: it adds a deterministic per-user jitter offset in `[0, spread)` on top of the floor (derived from `(user, lastCompoundTs)`, so it is stable while a user waits and re-randomizes after each compound). A synchronized cohort spreads across the window on the first cycle and never re-synchronizes. The effective per-user cadence becomes `[floor, floor + spread)`, so larger spreads buy more separation at the cost of a later worst-case cadence (e.g. `21600` = 6h fans ~10 users out roughly evenly and caps cadence near 30h).

The spread also covers the **first-ever** compound. A user with on-chain `lastCompoundTs == 0` (never compounded — e.g. a freshly enrolled user, or a backlog discovered in one scan) has no cadence anchor, so without this they would all be immediately eligible and batch into a single transaction. Instead the first compound is deferred to `firstSeen + jitter(user)`, where `firstSeen` is the unix second the keeper first saw the user enabled (tracked per-user in `compound_shareholders.json`, reset on disable). This keeps the very first compound of a cohort inside the spread window too.

Configuration env vars:

| Env var                                        | Default         | Description                                                    |
| ---------------------------------------------- | --------------- | -------------------------------------------------------------- |
| `KEEPER_SETTLEMENT_ENABLED`                    | `false`         | Opt-in.                                                        |
| `KEEPER_SETTLEMENT_PERIOD_SECS`                | `86400` (daily) | Master cadence. `86400` daily, `604800` weekly.                |
| `KEEPER_SETTLEMENT_DAY_UTC`                    | `4` (Thursday)  | 0=Sun..6=Sat. Weekly-multiple periods only; ignored for daily. |
| `KEEPER_SETTLEMENT_HOUR_UTC`                   | `0`             | Hour (UTC) for window open.                                    |
| `KEEPER_SETTLEMENT_WINDOW_DURATION_SECS`       | `86400`         | Window duration (clamped to <= one period).                    |
| `KEEPER_SETTLEMENT_TASK_GAP_SECS`              | `60`            | Pause between immediate tasks.                                 |
| `KEEPER_SETTLEMENT_RETRY_WINDOW_SECS`          | `3600`          | Retry window for failed immediate tasks.                       |
| `KEEPER_SETTLEMENT_MAX_DRIFT_BPS`              | `100` (1%)      | Max quote drift before pausing batches.                        |
| `KEEPER_COMPOUND_SHAREHOLDER_MIN_CADENCE_SECS` | = period        | Per-user shareholder compound floor.                           |
| `KEEPER_COMPOUND_LP_MIN_CADENCE_SECS`          | = period        | Per-user LP compound floor.                                    |
| `KEEPER_AUTOMAX_OWNER_COOLDOWN_SECS`           | = period        | Per-owner AutoMax bonus floor.                                 |

State file: `<stateDir>/<deployment>/settlement.json`

Verify it ran: check `settlement.json` for the current cycle ID, phase, and batch completion. Logs show `settlement [immediate]` and `settlement [spread]` prefixes.

All existing skip rules (thresholds, cooldowns, simulations) are preserved inside the window. Non-settlement tasks (`poke`, `sweep-market`, etc.) continue on their normal intervals.

To switch cadence: set `KEEPER_SETTLEMENT_PERIOD_SECS` (and the matching `SETTLEMENT_PERIOD_MS` constant in the frontend cadence module `settlementCadence.ts`) and restart. No state migration is needed: the per-user cooldown is computed live from the current period, so existing `lastCompounded` timestamps are reinterpreted automatically and on-chain floors (e.g. `LpStakingVault7D.MIN_COMPOUND_INTERVAL = 1 day`) remain authoritative.

See [developer docs — Settlement Window](../docs/manuals/developer/maintenance-and-bots.md#settlement-window-configurable-cadence) for the full design.

## Safety notes

- Use a **private / MEV-protected RPC** for transaction submission when possible.
- Keep deadlines tight (default is `+300s`).
- Keep slippage conservative and monitor reverts.
- `KEEPER_ALLOW_UNSAFE_MIN_OUT=1` is for emergency continuity only (harvest slippage).
- `KEEPER_ALLOW_UNSAFE_MIN_VE_OUT=1` is no longer used by auto-compound tasks (`minVeOut` is computed on-chain).
- Keeper key should be **gas-only** and secured per the security docs.

## Deploy checklist

Live deployment and ops hardening use the approved procedures for the target environment.
