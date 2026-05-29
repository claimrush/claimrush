# Run the ClaimRush OpenClaw skill

**Where this fits:** chat-driven entrypoint to the [TypeScript SDK](../agents-and-automation.md) · Skill source: [`skills/claimrush/`](https://github.com/claimrush/claimrush/tree/main/skills/claimrush) · Safety pack: [`agents-and-automation.cral.yaml`](https://developers.claimru.sh/agents-and-automation.cral.yaml)

This tutorial walks through the full lifecycle of running the
`skills/claimrush/` agent skill end to end: install, read state, dry-run the
agent loop, send a write against local Anvil, promote to Base Sepolia, and
finally execute a single mainnet write under the `--i-understand` gate.

The skill is a thin chat-friendly wrapper around `@claimrush/agent-sdk`.
Every write goes through one CRAL guardrail layer
(`skills/claimrush/src/safety/cral.ts`) so the agent (or a chat user)
cannot bypass the manifest's spend caps, slippage floors, deadlines, or
the mainnet double-confirm.

## Prerequisites

- Node 20+ and `npm` on `PATH`
- A repo checkout with submodules / Foundry deps (`make deps`)
- For local writes: a running Anvil node with the local deploy applied
  (see [Getting started](../getting-started.md) and
  [`script/DeployLocal.s.sol`](https://github.com/claimrush/claimrush/blob/main/script/DeployLocal.s.sol))
- For Base Sepolia / mainnet: a funded EOA private key and an RPC URL you
  control or trust
- An OpenClaw or Cursor session that loads workspace skill manifests; the
  CLI can also be driven directly from any shell

The skill never owns keys. It reads them from the same env vars the SDK
harness reads (`MNEMONIC`, `LOCAL_MNEMONIC`, `PRIVATE_KEYS`, `PRIVATE_KEY`).

## 1. One-shot setup

From the repo root:

```bash
bash skills/claimrush/scripts/setup.sh
```

This installs and builds the SDK at `agents/sdk/`, installs the skill,
deduplicates `viem` so the SDK and skill share one type identity, builds
the skill to `skills/claimrush/dist/`, and runs an offline action-coverage
smoke check.

After setup, every command runs through the wrapper:

```bash
bash skills/claimrush/scripts/cr.sh --help
```

If you skip `setup.sh` the wrapper will build on first invocation, but the
deduplicate step won't run; running `setup.sh` once up front avoids
intermittent type errors when the SDK and skill resolve different `viem`
copies.

## 2. Read state first (no transactions)

Always read state before proposing or running any write. The skill exposes
two read-only verbs:

```bash
RPC_URL=http://127.0.0.1:8545 \
  bash skills/claimrush/scripts/cr.sh status --pretty

RPC_URL=http://127.0.0.1:8545 \
  bash skills/claimrush/scripts/cr.sh monitor --events --limit 20
```

`status` returns the canonical `GameStateSnapshot` (current King, takeover
price, `takeoversPaused`, pending shareholder ETH, ve summary) under one
JSON object. `monitor` tails recent contract events so you can see
contention or paused states before sending anything.

Add `--user 0xYourAddress` to `status` for the per-user slice (claimable
ETH, locks, market positions). The full schema is documented in
[`agents/sdk/README.md`](https://github.com/claimrush/claimrush/blob/main/agents/sdk/README.md).

## 3. Dry-run the live agent loop

The `agent` verb runs a single tick against the configured chain and
prints what it _would_ do without sending. This is the safest way to
verify the SDK is correctly wired to your RPC and identity.

```bash
RPC_URL=http://127.0.0.1:8545 \
  bash skills/claimrush/scripts/cr.sh agent
```

Defaults:

- `--once` is implied; `--loop` is opt-in and additionally requires
  `--i-acknowledge-loop-execute` when combined with `--execute`
- no `--enable-takeovers`, `--enable-furnace-entry`, or `--enable-collect`
  flags, so the loop is purely observational
- the parsed CRAL hard rules are echoed under `cralContext.hardRules` in
  the JSONL output (suppress with `--no-cral-context`)

To preview what the loop would do _if_ it were sending takeover txs (still
without executing):

```bash
RPC_URL=http://127.0.0.1:8545 \
  bash skills/claimrush/scripts/cr.sh agent \
    --enable-takeovers --max-takeover-eth 0.001 --slippage-bps 50
```

The output includes the simulated quote, the resolved `minOut`, and the
deadline the skill would set when calling `MineCore.takeover`.

## 4. Send a write against local Anvil

Pick a verb that maps to the loop you want to test. Every write is
dry-run by default; pass `--execute` to send.

Takeover with ETH:

```bash
RPC_URL=http://127.0.0.1:8545 \
  bash skills/claimrush/scripts/cr.sh takeover \
    --eth --max-eth 0.001 --slippage-bps 50 --deadline-seconds 60

# review the quote, then re-run with --execute:
RPC_URL=http://127.0.0.1:8545 \
  bash skills/claimrush/scripts/cr.sh takeover \
    --eth --max-eth 0.001 --slippage-bps 50 --deadline-seconds 60 --execute
```

Furnace entry with ETH (chat-friendly alias):

```bash
RPC_URL=http://127.0.0.1:8545 \
  bash skills/claimrush/scripts/cr.sh furnace lock 0.05 --duration-days 30

RPC_URL=http://127.0.0.1:8545 \
  bash skills/claimrush/scripts/cr.sh furnace lock 0.05 --duration-days 30 \
    --slippage-bps 50 --execute
```

Collect ETH royalties (or compound straight into a Furnace lock):

```bash
RPC_URL=http://127.0.0.1:8545 \
  bash skills/claimrush/scripts/cr.sh collect --mode eth --min-eth 0.0005

RPC_URL=http://127.0.0.1:8545 \
  bash skills/claimrush/scripts/cr.sh collect --mode lock \
    --duration-days 30 --slippage-bps 50 --execute
```

Each invocation appends one line to
`agents/sdk/out/skill-<ts>/receipts.jsonl` with the verb, parsed inputs,
network, simulation result, and (for `--execute` runs) the tx hash. Tail
this file when running unattended to audit what the skill actually did.

## 5. Promote to Base Sepolia

The skill resolves `--chain base_sepolia` to the deployment manifest at
`deployments/base_sepolia.json` and the matching ABI set under
`abis/base_sepolia/`. Set the RPC URL via `--rpc-url` or `RPC_URL`:

```bash
RPC_URL=https://sepolia.base.org \
PRIVATE_KEY=0xYourTestnetKey \
  bash skills/claimrush/scripts/cr.sh status --chain base_sepolia --pretty

RPC_URL=https://sepolia.base.org \
PRIVATE_KEY=0xYourTestnetKey \
  bash skills/claimrush/scripts/cr.sh agent --chain base_sepolia
```

`base_sepolia` uses the same CRAL guards as local Anvil but with a tighter
default takeover hard cap (`CR_SKILL_MAX_TAKEOVER_ETH_HARDCAP=1.0` ETH by
default; override per-shell). It does not require `--i-understand`.

## 6. Mainnet preflight (the `--i-understand` gate)

Mainnet is intentionally a four-flag commit:

1. `--chain base`
2. `--execute`
3. `--i-understand`
4. an `RPC_URL` (or `--rpc-url`) listed in `CR_SKILL_BASE_RPC_ALLOWLIST`

If any of these is missing, the skill refuses _before_ resolving the
network or reading the deployment manifest. There is no way to bypass
this from the chat surface short of editing
`skills/claimrush/src/util/executor.ts`.

```bash
export CR_SKILL_BASE_RPC_ALLOWLIST=https://mainnet.base.org,https://your-private-rpc.example
export RPC_URL=https://your-private-rpc.example
export PRIVATE_KEY=0xYourMainnetKey

# 1. dry-run the exact command first
bash skills/claimrush/scripts/cr.sh takeover --eth \
  --max-eth 0.001 --slippage-bps 50 --deadline-seconds 60 --chain base

# 2. send only after reviewing the simulation output
bash skills/claimrush/scripts/cr.sh takeover --eth \
  --max-eth 0.001 --slippage-bps 50 --deadline-seconds 60 \
  --chain base --execute --i-understand
```

The skill applies a non-trivial-spend interactive `[y/N]` confirmation on
top of `--i-understand`. Run it from a TTY when sending mainnet writes.

For MEV-sensitive paths (e.g. `collect --mode lock`), set
`PRIVATE_RPC_URL` and `PRIVATE_RPC_MODE=route|only`. The skill warns and
refuses `--execute` on mainnet `collect --mode lock` without a private
RPC.

## 7. Inspect the CRAL context the LLM sees

The same CRAL manifest the skill loads at startup is dumpable in three
formats:

```bash
bash skills/claimrush/scripts/cr.sh cral --format prompt        # short system-prompt blob
bash skills/claimrush/scripts/cr.sh cral --format hard-rules    # one rule per line
bash skills/claimrush/scripts/cr.sh cral --format json --pretty # full structured pack
```

Use `--format prompt` to seed an LLM prompt, or `--format hard-rules` to
embed a tight reference card next to a chat agent's reasoning trace. The
canonical source remains
[`docs/manuals/developer/agents-and-automation.cral.yaml`](https://developers.claimru.sh/agents-and-automation.cral.yaml).

## 8. Receipts and JSONL telemetry

Output streams are written under the SDK's run directory
(`agents/sdk/out/...`). Each run gets its own timestamped subdirectory:

- Per-invocation skill receipts: `receipts.jsonl`
- SDK event stream: `events.jsonl`
- SDK achievements stream: `achievements.jsonl`
- SDK live agent stream: `agent.jsonl`

Each receipt records `{ ts, verb, input, network, simulation, hash,
errorInfo }`. `errorInfo.kind` distinguishes a CRAL preflight refusal
from an on-chain revert, which keeps post-mortems honest.

## What to do next

- Read [`skills/claimrush/SKILL.md`](https://github.com/claimrush/claimrush/blob/main/skills/claimrush/SKILL.md)
  end to end — it is the same file an LLM-driven runner consumes.
- Read the `agents-and-automation.cral.yaml` manifest for the canonical
  list of hard rules and common confusions the skill enforces.
- Cross-link to the SDK reference at
  [`agents/sdk/README.md`](https://github.com/claimrush/claimrush/blob/main/agents/sdk/README.md) when you need
  to extend the action surface (the skill is meant to stay thin).
- For session-based delegation, pair this tutorial with
  [Bot sessions (DelegationHub)](../delegationhub.md).
