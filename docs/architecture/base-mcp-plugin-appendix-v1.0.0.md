# Base MCP plugin appendix — ClaimRush v1.0.0

This appendix documents the architecture of the ClaimRush Base MCP
plugin: a hosted HTTP API that lets AI assistants on Base (Coinbase
Wallet's agent mode, the Base AI sandbox, custom MCP-aware clients)
read protocol state and prepare unsigned calldata for user actions.

The plugin is an **integrator surface**, not a protocol component. It
runs off-chain, never signs, never holds keys, never broadcasts. The
user's wallet is the sole signer and the canonical fail-closed
gatekeeper.

## 1. Goals

1. **Match the web app, byte-for-byte.** Whatever calldata the regular
   ClaimRush web app would produce for a given action, the plugin must
   produce the same calldata. No "AI-assistant-only" code path that
   bypasses slippage protection or allowance gates.
2. **Be public and unauthenticated.** Anyone can hit the read endpoints;
   anyone can ask for a prepare. The user's wallet is the only thing
   that can actually execute the calldata. No API keys to lose, no auth
   surface to abuse.
3. **Fail closed.** When in doubt — genesis still active, deployment
   manifest missing an address, RPC upstream returning garbage — refuse
   to emit calldata rather than emit something that would revert.
4. **Stay isolated.** The plugin owns no contract, no L1 state, no
   custodial role. Removing the plugin would not affect any on-chain
   value flow; users would simply fall back to the regular web app.

## 2. Where it sits

```
┌─────────────────────────┐
│   Base MCP-aware LLM    │  Coinbase Wallet agent / Base AI sandbox / custom
│   (or custom assistant) │
└───────────┬─────────────┘
            │  HTTPS GET (no auth)
            ▼
┌─────────────────────────────────────────┐
│  claimru.sh/api/mcp/v1/*                │
│  ├─ /state/:address                     │
│  ├─ /preflight                          │
│  ├─ /quote/lock-via-furnace             │
│  └─ /prepare/                           │
│       collect-all, collect-royalties,   │
│       harvest-rewards, withdraw-lp,     │
│       lock-via-furnace, stake-lp,       │
│       unbond-lp, lock, topup, extend    │
└────┬─────────────────┬──────────────────┘
     │                 │
     │ eth_call        │ GraphQL
     ▼                 ▼
┌─────────────────┐  ┌──────────────────────┐
│ rpc-proxy.claim │  │ subgraph proxy       │
│ ru.sh           │  │ (Goldsky / Graph)    │
└────┬────────────┘  └──┬───────────────────┘
     │                  │
     ▼                  ▼
┌─────────────────────────────────────────┐
│  Base mainnet — ClaimRush contracts     │
│  (read-only access via eth_call only)   │
└─────────────────────────────────────────┘
            ▲
            │  send_calls (signed batch from user wallet)
            │  — bypasses the plugin entirely
            │
┌───────────┴─────────────┐
│ User wallet             │  Signs and broadcasts the calldata the LLM
│ (EOA or smart account)  │  handed to send_calls. The plugin is NOT in
└─────────────────────────┘  the broadcast path.
```

Key invariants of this topology:

- The plugin is in the **calldata-construction** path, NOT the
  **calldata-submission** path. Signed transactions never traverse the
  plugin.
- All upstream egress is through internal Cloudflare proxies
  (`rpc-proxy.claimru.sh`, the subgraph proxy). The plugin never speaks
  to a public RPC endpoint directly; it inherits the proxies' method
  allow/deny + chain-id guards.

## 3. Endpoint families

### 3.1 Reads (no calldata, no fail-closed gate)

- `GET /api/mcp/v1/state/:address` — per-user state snapshot.
  Numeric balances (`claimBalanceWei`, `lpStakedWei`, pending royalties
  and LP rewards) are always RPC view-call reads — the subgraph does
  not index per-block view-function output. The `veLocks` array is
  hydrated from the subgraph when `SUBGRAPH_URL` is configured (source
  reported as `"subgraph+rpc"`); when the subgraph is unconfigured or
  errors out, `veLocks` is `[]` and the source becomes `"rpc"`.
- `GET /api/mcp/v1/preflight` — LaunchController.preflight() result.
  Returns `finalized: true` if bit 0 of the bitmask is CLEAR (=
  `genesisFinalized`), `finalized: false` plus the bits-set diagnostic
  otherwise. `preflight()` is a plain `view` function with no
  finalize-aware modifier, so an RPC revert is a HARD error
  (`PREFLIGHT_READ_FAILED`), never interpreted as success.
- `GET /api/mcp/v1/quote/lock-via-furnace` — Furnace quote with clamped
  `minVeOut`. Mirrors `FurnaceQuoter.quoteEnterWithClaim`.

### 3.2 Prepare (return unsigned calldata, gated)

Every prepare endpoint runs a **prepare-gate** before encoding any
calldata. The gate reads the LaunchController preflight and returns
`503 GENESIS_NOT_FINALIZED` if bit 0 of the bitmask is SET
(= `!genesisFinalized`). Once `finalizeGenesis()` commits, bit 0
clears and every prepare endpoint begins emitting calldata.

The 10 prepare endpoints are listed in the developer reference. Three
of them additionally:

- Pre-quote via `FurnaceQuoter` to derive a slippage-clamped `minVeOut`
  (`/prepare/lock-via-furnace`; `/prepare/lock`, `/prepare/topup` don't
  need slippage because veCLAIM is escrowed at face value).
- Read ERC-20 allowance and prepend an `approve(spender, exactAmount)`
  call if needed (`/prepare/lock-via-furnace`, `/prepare/stake-lp`,
  `/prepare/lock`, `/prepare/topup`).

## 4. Response envelope

All prepare endpoints return the ordered-batch envelope:

```json
{
  "ok": true,
  "chain": "base",
  "chainId": 8453,
  "transactions": [
    {
      "step": "approve",
      "to": "0x059d278233fec14cb6d1a74e6fb482bc3f91adbf",
      "data": "0x095ea7b3…",
      "value": "0x0",
      "chainId": 8453
    },
    {
      "step": "lock",
      "to": "0x5f4dabb335d2609c88d3f77e15d5db4310270ad6",
      "data": "0x…",
      "value": "0x0",
      "chainId": 8453
    }
  ]
}
```

`step` is informational — Base MCP `send_calls` only consumes
`{ to, data, value, chainId }`. The label lets the assistant relay each
step to the user in plain language. Step labels follow the brand-voice
verb policy: `approve`, `collect`, `harvest`, `lock`, `topup`, `extend`,
`stake`, `unbond`, `withdraw`. (`action` is a reserved legacy label
that no current handler emits.)

Errors follow `{ ok: false, error: "CODE", message: "…" }` with optional
`detail` (and `retryAfterSec` for `RATE_LIMITED`).

## 5. Calldata correctness — the parity gate

The single most important property of this plugin is that whatever
calldata it produces for action X with arguments Y is **byte-identical**
to what the ClaimRush web app would produce for the same action with
the same arguments.

Both the web app and the hosted plugin import the same calldata-prep
package. That package owns:

- The duration-weight curve + lock constants used to pre-compute
  Furnace quotes and `minVeOut`.
- The strict-integer parsers that reject scientific-notation, hex, or
  decimal inputs at the API boundary.
- The ABI encoder (`normalizeContractCalls`) that translates a typed
  call descriptor into the `{ to, data, value, chainId }` shape Base
  MCP's `send_calls` consumes.
- The `applyMinVeOutClamp` UX guard (if a slippage calculation rounds
  to `0n` while the quoted `veOut > 0n`, clamp to `1n`).
- The `bonusBpsVsPrincipalClaim` floor-rounding to mirror the on-chain
  `Math.mulDiv` direction (see
  [Math and rounding appendix](math-and-rounding-appendix-v1.0.0.md)).

A blocking CI gate (the operator-side `mcp-api` workflow) runs the
parity suite on every change that touches the encoding path. It
asserts:

```
durationWeight_pkg(s) === durationWeight_webapp(s)    ∀ s ∈ test grid
durationWeightBps_pkg(s) === durationWeightBps_webapp(s)
```

…across a 6-hour step from 6h to 400d, plus every canonical curve
anchor and every edge case (negative, NaN, out-of-range).

A second pin on the plugin side runs the encoder for each of the 10
prepare actions and asserts byte-identity with an independently-rolled
viem reference encoding. This catches any regression in the encoder
algorithm itself.

Together the two gates enforce:

```
webapp.encode(args) == plugin.encode(args) == viem.encodeFunctionData(args)
```

## 6. Fail-closed posture

The plugin refuses to emit calldata if:

1. **Genesis not finalized.** `LaunchController.preflight()` returns a
   bitmask whose bit 0 is SET. The error response includes the status
   bitmask + bits-set count so the assistant can tell the user how
   close to launch the protocol is. An RPC revert from `preflight()`
   is a HARD error (`PREFLIGHT_READ_FAILED`), never silently treated
   as finalized.
2. **Contract address missing.** Any contract the action needs is not
   in the deployment manifest, or has the zero-address sentinel.
3. **Input out of range.** Strict parsers reject negative amounts,
   decimal amounts, hex amounts, scientific notation, and values above
   uint256-max. The contract-level gates would catch these too — the
   plugin just never even attempts the eth_call.
4. **Quote failed.** `FurnaceQuoter` eth_call reverted. Returns
   `502 QUOTE_FAILED` with the raw revert reason.
5. **RPC view-call failed.** Any of the four state RPC reads
   (`balanceOf`, `stakedBalance`, `claimableEth`, `earned`) failed.
   Returns `502 STATE_READ_FAILED`. Subgraph failure alone is
   non-fatal — the response degrades to `veLocks: []` and `source:
   "rpc"`.
6. **RPC timeout.** Each upstream call has a per-request timeout
   (default 15s). Aborts return `502 STATE_READ_FAILED` or
   `502 QUOTE_FAILED`.

In local development the genesis-not-finalized gate can be bypassed via
a runtime flag, but only with the wallet hard-pinned to a local fork.

## 7. Rate limiting

Each route prefix (`/api/mcp/v1/state/`, `/api/mcp/v1/preflight`,
`/api/mcp/v1/quote/`, `/api/mcp/v1/prepare/`) carries its own per-IP
token bucket:

- 300 req / 60 sec per IP per route prefix (production default).
- Bucket is FNV-sharded across 64 instances so no single bucket is the
  hot spot.
- Returns `429 RATE_LIMITED` with `Retry-After` header on exhaustion.

The bucket implementation is the same class re-used by the RPC and
chat surfaces; it is not plugin-specific.

## 8. Observability

The plugin reuses the canonical observability pipeline:

- `requestId` (UUID, propagated as `x-request-id` outbound)
- `traceId` (W3C trace, propagated as `traceparent` outbound)
- `path` (decision-grade routing key for metrics)
- `status` (HTTP status)

Wallet addresses appearing in path params or query strings are NOT
logged at info level; they appear only at debug level after passing
through the standard redaction filter. No PII or signature material
ever reaches logs because there is no PII or signature material in the
request handling — it sees only addresses and uint256-like inputs.

## 9. Deployment topology

- Domain: `claimru.sh/api/mcp/v1/*`
- Staging: `staging.claimru.sh/api/mcp/v1/*` (Sepolia, chainId 84532)
- No persistent state aside from the rate-limiter shard buckets
- No KV namespaces, no R2 buckets, no D1 databases

The full operator on-call playbook (deploy steps, secret rotation,
incident response) is maintained on the operator side and is not part
of the public docs surface.

## 10. Public-repo distribution

`plugins/claimrush.md` ships to the public repo
([`claimrush/claimrush`](https://github.com/claimrush/claimrush)) as
the source-of-truth plugin spec. The hosted implementation that
serves it is operator-side and is not part of the public protocol
surface.

The spec is the public-facing source of truth; the implementation is
held to it via the CI parity gate. A CI check enforces that every
route declared in the implementation is documented in
`plugins/claimrush.md`.

After a 2-week mainnet soak, the spec will be submitted upstream to
[`base-org/base-skills`](https://github.com/base-org/base-skills) so
Base's plugin indexer ingests it and Coinbase Wallet's agent mode
lists ClaimRush as an available skill automatically.

## 11. Open items (post-launch)

Tracked in the operator-side post-launch backlog:

- **Web-app math consolidation** — fold the web app's duration-weight
  helpers onto `@claimrush/calldata-prepare` so the operator-side
  parity test becomes a no-op.
- **base/skills PR** — submit `plugins/claimrush.md` to Base's plugin
  indexer once mainnet soak completes.
- **Auth on the prepare endpoints (optional)** — the plugin is
  currently fully public. If abuse appears post-launch the operator
  can layer a Coinbase Wallet ENS-attestation check via `eth_call` to
  the attestation contract before emitting prepare calldata. Read
  endpoints remain unauthenticated regardless.

## See also

- Developer reference: [`docs/manuals/developer/base-mcp-plugin.md`](https://github.com/claimrush/claimrush/blob/main/docs/manuals/developer/base-mcp-plugin.md)
- User tutorial: [Use with an AI assistant (Base MCP)](https://docs.claimru.sh/tutorials/use-with-ai-assistants)
- Public spec: [`plugins/claimrush.md`](../../plugins/claimrush.md)
- Math + rounding companion: [`docs/architecture/math-and-rounding-appendix-v1.0.0.md`](math-and-rounding-appendix-v1.0.0.md)
- Architecture reference: [`docs/architecture/architecture-reference-v1.0.0.md`](architecture-reference-v1.0.0.md)
- Base MCP docs (upstream): <https://docs.base.org/ai-agents/plugins/custom-plugins>
