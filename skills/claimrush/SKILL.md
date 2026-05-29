---
name: claimrush
description: >-
  Drive the ClaimRush protocol via the TypeScript SDK from chat: monitor the
  game, take over the Crown, lock into the Furnace, collect ETH royalties,
  run AgentPlans, and manage DelegationHub sessions. Enforces CRAL safety
  rules (caps, slippage, deadlines, dry-run by default).
metadata:
  openclaw:
    homepage: https://github.com/jpatenaude/claimrush
    skillKey: claimrush
    requires:
      bins: [node, npm]
      env: []
---

# ClaimRush skill

A workspace-scoped skill that wraps `@claimrush/agent-sdk` with a chat-friendly
CLI (`bash skills/claimrush/scripts/cr.sh ...`). Every write goes through a
single CRAL guardrail layer (`src/safety/cral.ts`), so the agent (and the user
via chat) cannot bypass spend caps, slippage floors, deadlines or the
mainnet double-confirm gate.

## When to use

- The user wants to **observe the game**: current King, takeover price,
  pending royalties, or recent achievement / event activity.
- The user wants to **act on ClaimRush surfaces only**: takeover the Crown,
  lock into the Furnace, collect shareholder ETH royalties, withdraw
  King / refund balances, run a market action, or build / execute an
  AgentPlan.
- The user wants to **delegate** an action to themselves via DelegationHub
  (gasless `set-session-by-sig` build + submit + revoke).
- The user wants to run an **unattended agent loop** against local Anvil or
  Base Sepolia.

## When NOT to use

- For arbitrary EVM transactions or for any contracts outside the ClaimRush
  protocol surface. Use a generic web3 tool instead.
- To compute prices or quotes from raw RPC data. Always go through the
  skill's CLI so quoting + slippage are applied consistently.
- To execute on Base mainnet without explicit, in-chat user consent and the
  `--i-understand` token. The skill will refuse otherwise.

## Setup (one-shot)

```bash
bash skills/claimrush/scripts/setup.sh
```

This installs and builds the local SDK (`agents/sdk/`), installs the skill,
deduplicates `viem` so types match, builds the skill, and runs a `status`
smoke check against the configured RPC.

After setup, all commands run via the wrapper:

```bash
bash skills/claimrush/scripts/cr.sh <verb> [flags...]
```

Set the wallet/RPC the same way the SDK examples do:

- `RPC_URL` (or `--rpc-url`) - public RPC for the chosen chain.
- `PRIVATE_RPC_URL`, `PRIVATE_RPC_MODE=route|only|off` - private RPC for the
  MEV-sensitive paths (mainnet `claimShareholderLock`, etc).
- `MNEMONIC` / `LOCAL_MNEMONIC` / `PRIVATE_KEYS` - identity. Same precedence
  as the SDK harness (see `agents/sdk/README.md`).
- `CR_SKILL_BASE_RPC_ALLOWLIST=https://...,https://...` - mandatory comma
  list of allowed mainnet RPC origins. The skill refuses any other URL when
  `--chain base`.

Environment knobs the agent may set (read in `src/safety/networks.ts`):

- `CR_SKILL_MAX_TAKEOVER_ETH_HARDCAP` (default `0.05` on mainnet, `1` on
  every other chain — Sepolia, local).
- `CR_SKILL_MAX_FURNACE_ETH_HARDCAP` (default `1` on mainnet, `100` on every
  other chain — Sepolia, local).
- `CR_SKILL_MAX_SLIPPAGE_BPS` (default `200` = 2%).

## Always read state first

Before proposing or running any write, run these read-only commands and
report what you saw:

```bash
bash skills/claimrush/scripts/cr.sh status --pretty
bash skills/claimrush/scripts/cr.sh monitor --events --limit 20
```

`status` returns the `GameStateSnapshot` (current king, takeover price,
takeoversPaused, pending shareholder ETH, ve summary). `monitor` tails
recent contract events and achievements so you can see contention or paused
states before sending a tx.

## Decision rubric (lifted from CRAL ids 02-05)

For each loop, decide in this order:

1. **Crown loop** - is the takeover price profitable vs current King cap and
   the configured `--max-takeover-eth`? If the live re-quote drifts more
   than `slippage-bps`, abort.
2. **Furnace loop** - is the share rate (`minVeOut` for the input amount)
   acceptable vs configured slippage? Prefer `enterWithEth` for the
   shortest-path entry; only use token paths when explicitly asked.
3. **Royalty loop** - if `pendingShareholderEth >= --min-eth`, prefer
   `collect --mode lock` to compound; otherwise `collect --mode eth` to
   pull ETH to the caller. The `lock` mode is private-RPC allowlisted;
   verify `PRIVATE_RPC_URL` is set when running on mainnet.
4. **Market loop** - only when explicitly asked. Use `market list` first,
   confirm the offer / listing context with the user, then act.

Treat `MineCore` reverts as expected (contention) and re-quote on the next
tick. Do not retry inside the same tick.

## Action recipes (always dry-run first)

Every verb is dry-run unless `--execute` is passed. Mainnet additionally
requires `--i-understand` AND an interactive `[y/N]` confirmation when the
spend is non-trivial.

**Read state**

```bash
bash skills/claimrush/scripts/cr.sh status --pretty
bash skills/claimrush/scripts/cr.sh monitor --events --achievements --limit 50
```

**Takeover (ETH path)**

```bash
bash skills/claimrush/scripts/cr.sh takeover \
  --eth --max-eth 0.001 --slippage-bps 50 --deadline-seconds 60
# then, only after reviewing the quote+sim:
bash skills/claimrush/scripts/cr.sh takeover \
  --eth --max-eth 0.001 --slippage-bps 50 --deadline-seconds 60 --execute
```

**Takeover (token path)**

```bash
bash skills/claimrush/scripts/cr.sh takeover \
  --token 0xToken --amount-in 1000000 --max-eth 0.001 --slippage-bps 100
```

**Furnace lock (ETH | CLAIM | token)**

```bash
bash skills/claimrush/scripts/cr.sh lock --eth 0.001 --duration-days 30
bash skills/claimrush/scripts/cr.sh lock --claim 1000 --duration-days 90
bash skills/claimrush/scripts/cr.sh lock --token 0xToken --amount-in 1000000
```

**Collect ETH royalties**

```bash
bash skills/claimrush/scripts/cr.sh collect --mode eth  --min-eth 0.0005
bash skills/claimrush/scripts/cr.sh collect --mode lock --duration-days 30
```

**Withdraw**

```bash
bash skills/claimrush/scripts/cr.sh withdraw --king
bash skills/claimrush/scripts/cr.sh withdraw --refund
```

**Market**

```bash
bash skills/claimrush/scripts/cr.sh market list
bash skills/claimrush/scripts/cr.sh market offer-create --price-eth 0.0001 --quantity 1
bash skills/claimrush/scripts/cr.sh market sell-to-furnace --token-id 42
```

**AgentPlan (build + execute)**

```bash
bash skills/claimrush/scripts/cr.sh plan build --out plan.json
bash skills/claimrush/scripts/cr.sh plan execute --plan plan.json   # dry-run
bash skills/claimrush/scripts/cr.sh plan execute --plan plan.json --execute
```

**Delegation (gasless)**

```bash
bash skills/claimrush/scripts/cr.sh session build \
  --user 0xUser --delegate 0xAgent \
  --perms TAKEOVER_FOR,FURNACE_ENTER_FOR --expiry-seconds 3600 \
  --out session.typed.json
bash skills/claimrush/scripts/cr.sh session submit --typed session.typed.signed.json
bash skills/claimrush/scripts/cr.sh session revoke --user 0xUser
bash skills/claimrush/scripts/cr.sh session status --user 0xUser --delegate 0xAgent
```

Then run any write with `--acting-for 0xUser` to use the `*For` SDK paths.

**Furnace alias** (chat-friendly positional form)

```bash
bash skills/claimrush/scripts/cr.sh furnace lock 0.05            # dry-run
bash skills/claimrush/scripts/cr.sh furnace lock 0.05 --execute  # send (with caps)
bash skills/claimrush/scripts/cr.sh furnace status
```

These rewrite to `lock --eth ...` / `status` and apply the same CRAL guards.

**Unattended agent loop** (CRAL preflight applied before each tick)

```bash
bash skills/claimrush/scripts/cr.sh agent                        # default: --once dry-run
bash skills/claimrush/scripts/cr.sh agent --once \
  --enable-takeovers --max-takeover-eth 0.001 --execute          # one tick, real send
bash skills/claimrush/scripts/cr.sh agent --loop --tick-seconds 12 \
  --max-actions-per-tick 1 --strategy-module ./strategies/mine.mjs \
  --execute --i-acknowledge-loop-execute                         # forever loop (must opt in)
```

`agent` defaults to `--once` so a forgotten flag never starts an unattended loop.
`--execute --loop` together additionally require `--i-acknowledge-loop-execute`.

**Print the parsed CRAL safety pack** (for LLM context injection)

```bash
bash skills/claimrush/scripts/cr.sh cral --format prompt          # short system-prompt blob
bash skills/claimrush/scripts/cr.sh cral --format hard-rules      # one rule per line
bash skills/claimrush/scripts/cr.sh cral --format json --pretty   # full structured pack
```

Every `agent` invocation also auto-injects `cralContext.hardRules` in its
output (suppress with `--no-cral-context`).

## Hard rules (the agent MUST obey these)

1. **Always run the verb without `--execute` first.** Report the simulated
   quote, the resolved `minOut`, the deadline, and (for delegated mode) the
   permission bits required, before asking the user to authorize execution.
2. **Never cast amounts through `Number`.** Pass them as strings (`"0.001"`)
   or wei integers; the safety layer (`parseEthStrict` / `parseTokenStrict`
   / `parseBigIntStrict`) will reject anything that round-trips through a
   float.
3. **Re-quote at send.** Do not reuse a quote across ticks; quote inside the
   same call that builds the tx and abort if drift exceeds
   `--slippage-bps` (default 200, hard ceiling `CR_SKILL_MAX_SLIPPAGE_BPS`).
4. **Set deadlines.** Default `--deadline-seconds 60`; never disable.
5. **Mainnet requires `--chain base --execute --i-understand`** AND an
   in-chat user confirmation. The CLI will refuse with a clear error when
   any of those is missing, and will refuse any `RPC_URL` not in
   `CR_SKILL_BASE_RPC_ALLOWLIST`.
6. **Spend caps are hard.** Even with `--execute`, the skill refuses if
   `--max-takeover-eth` (or the resolved Furnace `--furnace-eth-in`) exceeds
   the per-chain hard cap.
7. **Treat MineCore reverts as normal contention.** Re-quote on the next
   tick; don't retry inside the same tick.
8. **For delegated mode, re-verify the session before EACH write.** The
   skill calls `DelegationHub.isAuthorized` per action; if it returns false
   the write is aborted with a structured error.
9. **Private RPC for MEV-sensitive paths.** When running
   `collect --mode lock` on mainnet, the skill expects `PRIVATE_RPC_URL`
   (or `--private-rpc-url`) to be set; otherwise it warns and refuses
   `--execute`.
10. **One action per turn by default.** When running interactively, prefer
    a single verb per chat turn so the user can review the receipt before
    the next step.

## Telemetry & receipts

- The CLI writes a JSONL receipt for every invocation under
  `agents/sdk/out/skill-<ts>/receipts.jsonl`. Each line contains
  `{ ts, verb, input, network, simulation, txHash, errorInfo }`.
- The SDK continues to emit its own JSONL streams (`events.jsonl`,
  `achievements.jsonl`, `agent.jsonl`) under the same `out/` tree; tail
  them with `claimrush monitor` or with the SDK's `npm run example:monitor`.
- Failures include `errorInfo.kind` so a reviewer can quickly tell a
  preflight refusal apart from an on-chain revert.

## Cross-references

- Canonical safety manifest: `docs/manuals/developer/agents-and-automation.cral.yaml`
- SDK reference: `agents/sdk/README.md`
- Public API surface this skill consumes: `agents/sdk/src/index.ts`
- Skill internals (single CRAL chokepoint): `skills/claimrush/src/safety/cral.ts`
- Network / RPC allowlist: `skills/claimrush/src/safety/networks.ts`
- Pre-execution checks (delegation, RPC head freshness): `skills/claimrush/src/safety/preflight.ts`

## License and repository

- License: `LICENSE` at the repository root.
- Trademarks: `TRADEMARKS.md`. "ClaimRush", the ClaimRush logo and wordmark,
  the illustrated Crown / Furnace / Baron page backgrounds, and the
  achievement badge artwork are protected brand assets; this skill does not
  grant rights to any of them.
- Source of truth: `skills/claimrush/` in the ClaimRush repository.
