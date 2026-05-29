# Base MCP plugin

> **TL;DR** — ClaimRush ships a Base MCP plugin so AI assistants on Base
> can read protocol state and prepare unsigned calldata for user actions.
> The plugin is served at `claimru.sh/api/mcp/v1/*` and returns
> ordered-batch envelopes consumed by Base MCP's `send_calls`. The
> service never signs, never holds keys, and never broadcasts.

This page is the integrator reference. For the user-facing tutorial,
see [Use with an AI assistant (Base MCP)](https://docs.claimru.sh/tutorials/use-with-ai-assistants).

## What it is

The plugin is a markdown skill plus a hosted HTTP API:

- **Plugin spec**: the markdown file at the repo root path
  [`plugins/claimrush.md`](https://github.com/claimrush/claimrush/blob/main/plugins/claimrush.md)
  describes the read + prepare endpoints in the format Base's
  `base/skills` indexer consumes. After a mainnet-soak window the spec
  is submitted upstream to `base-org/base-skills` so Coinbase Wallet
  and the Base AI sandbox pick ClaimRush up as an available skill
  automatically.
- **API service**: an operator-side service routing requests for
  `claimru.sh/api/mcp/v1/*`. Returns ordered-batch envelopes with
  `{ to, data, value, chainId }` per step. Hosted off the public
  protocol source: integrators consume the API, the operator runs the
  service.

## Endpoint catalog

### Reads

- `GET /api/mcp/v1/state/:address` — per-user state snapshot. Numeric balances are RPC reads (the subgraph does not index per-block view output); the lock list is hydrated from the subgraph when configured, else `[]`. `source` is `"subgraph+rpc"` or `"rpc"`.
- `GET /api/mcp/v1/preflight` — LaunchController.preflight() bitmask + `finalized` boolean.
- `GET /api/mcp/v1/quote/lock-via-furnace` — Furnace quote with clamped `minVeOut`.

### Prepare (returns unsigned calldata)

| Action              | User-facing verb | Function on-chain                                           |
|---------------------|------------------|-------------------------------------------------------------|
| `collect-all`       | Collect          | `ClaimAllHelper.claimAll(mode, …)` (bundled royalties + LP) |
| `collect-royalties` | Collect          | `ShareholderRoyalties.claimShareholder(mode, …)`            |
| `harvest-rewards`   | Harvest          | `LpStakingVault7D.claimRewards()` / `…AndLock(...)`         |
| `withdraw-lp`       | Withdraw         | `LpStakingVault7D.withdrawMatured()`                        |
| `lock-via-furnace`  | Lock via Furnace | `Furnace.enterWithClaim(...)` (+ CLAIM approve if needed)   |
| `stake-lp`          | Stake            | `LpStakingVault7D.stake(amount)` (+ LP approve if needed)   |
| `unbond-lp`         | Unbond           | `LpStakingVault7D.beginUnbond(amount)`                      |
| `lock`              | Lock             | `VeClaimNFT.createLockFor(...)` (+ CLAIM approve)           |
| `topup`             | Top up           | `VeClaimNFT.addToLockFor(...)` (+ CLAIM approve)            |
| `extend`            | Extend           | `VeClaimNFT.extendLockToFor(...)`                           |

The user-facing verb is the language an integrator's assistant MUST use
when narrating the action to the end-user. ClaimRush's brand voice
forbids "claim" as a verb in UI; ETH payouts are **collected**, LP CLAIM
rewards are **harvested**, CLAIM is **locked** (plain or via the Furnace),
and deposited LP is **withdrawn**. The on-chain function names retain
their legacy `claim*` ABI for backward compatibility.

Full request/response shapes live in the
[plugin spec](https://github.com/claimrush/claimrush/blob/main/plugins/claimrush.md).

## Response envelope

Every prepare endpoint returns the ordered-batch shape. Example below
is the two-step `lock-via-furnace` envelope; single-step actions
(e.g. `collect-royalties`) return a one-element `transactions` array:

```json
{
  "ok": true,
  "chain": "base",
  "chainId": 8453,
  "transactions": [
    { "step": "approve", "to": "0x…", "data": "0x…", "value": "0x0", "chainId": 8453 },
    { "step": "lock",    "to": "0x…", "data": "0x…", "value": "0x0", "chainId": 8453 }
  ]
}
```

`step` is informational — Base MCP's `send_calls` only consumes
`{ to, data, value, chainId }`. The step label lets the assistant relay
each transaction to the user in plain language. Step labels follow the
brand-voice verb policy: `approve`, `collect`, `harvest`, `lock`,
`topup`, `extend`, `stake`, `unbond`, `withdraw`. (`action` is a
reserved legacy label that no current handler emits.)

Errors follow `{ ok: false, error: "CODE", message: "…" }` with optional
`detail` and (for rate-limit responses) `retryAfterSec`. The full error
catalog is documented in the
[plugin spec](https://github.com/claimrush/claimrush/blob/main/plugins/claimrush.md#error-responses).

## Calldata correctness guarantees

The plugin uses the **same calldata-encoding path** as the ClaimRush
web app. The shared math + ABI encoder used by both implements
`durationWeight`, `applyMinVeOutClamp`, and `bonusBpsVsPrincipalClaim`,
mirroring the on-chain helpers in `FurnaceGuardHelper`, `FurnaceQuoter`,
`MarketRouter`, `ShareholderRoyalties`, and `LpStakingVault7D`.

A blocking CI gate runs the parity test suite, which imports the live
web-app helpers and asserts byte-identical output across a fuzzed input
grid. Any drift between the plugin's calldata-encoding path and the web
app's fails the build.

In effect, the parity gate enforces:

```
webapp.encode(args) == plugin.encode(args) == viem.encodeFunctionData(args)
```

## Fail-closed posture

The plugin refuses to emit calldata if anything is off:

1. **Genesis not finalized** — every prepare endpoint reads
   `LaunchController.preflight()` first. If bit 0 of the returned
   bitmask is SET (= `!genesisFinalized`), the endpoint returns
   `503 GENESIS_NOT_FINALIZED` with the bitmask diagnostic. Bit 0
   clears the moment `finalizeGenesis()` commits, after which the gate
   stops tripping.
2. **Address missing** — if the deployment manifest lacks the contract
   the action needs, the endpoint returns `503 CHAIN_UNREADY`.
3. **Bad inputs** — strict address / non-negative uint256 / canonical
   boolean parsers reject anything off-shape. Bad inputs return
   `400 BAD_PARAMS` without touching the RPC.
4. **Upstream RPC failures** — `502 STATE_READ_FAILED` /
   `502 QUOTE_FAILED` rather than a generic 500.

## Hosting & runtime

- **Domain**: `claimru.sh/api/mcp/v1/*` (production) and
  `staging.claimru.sh/api/mcp/v1/*` (Sepolia rehearsal).
- **Runtime**: Cloudflare Worker, no Durable Object state aside from
  the shared `RateLimiter` token-bucket.
- **Upstreams**: routes through `rpc-proxy.claimru.sh` for `eth_call`
  reads (which enforces method allow/deny + chain-id guard) and the
  subgraph proxy for indexed state.
- **Rate limit**: 300 req/min/IP per route prefix. Returns 429 +
  `Retry-After` when over budget.
- **CORS**: enabled (`Access-Control-Allow-Origin: *`); the API is
  read-only and idempotent so cross-origin GETs are safe.
- **Auth**: none on the read/prepare paths. The upstream RPC proxy
  rejects any write methods at its layer regardless.

## Local development

To exercise the plugin against a local fork, point your integration
at the staging endpoint (`staging.claimru.sh/api/mcp/v1/*` on Base
Sepolia, chainId 84532). The staging plugin uses the same encoding
path as production, so calldata it returns is interchangeable with
production calldata for matching inputs.

Smoke test against the hosted endpoint:

```bash
curl 'https://claimru.sh/api/mcp/v1/preflight'
curl 'https://claimru.sh/api/mcp/v1/quote/lock-via-furnace?user=0xabc…&claimAmountWei=1000000000000000000000&durationSeconds=2592000'
curl 'https://claimru.sh/api/mcp/v1/prepare/collect-all'
```

## Versioning

This page describes the **v1** API at `/api/mcp/v1/*`. Breaking changes
to the route grammar will land under `/api/mcp/v2/*`; both will be
co-served during the transition. Backwards-incompatible changes inside
v1 will never ship.

The plugin spec is versioned in lockstep with this page; the parity
gate in CI catches any drift between the spec's documented routes and
the API's actually-served routes.

## See also

- User tutorial: [Use with an AI assistant (Base MCP)](https://docs.claimru.sh/tutorials/use-with-ai-assistants)
- Developer tutorial: [Build a Base MCP agent for ClaimRush](tutorials/build-base-mcp-agent.md)
- Architecture appendix: [`docs/architecture/base-mcp-plugin-appendix-v1.0.0.md`](https://github.com/claimrush/claimrush/blob/main/docs/architecture/base-mcp-plugin-appendix-v1.0.0.md)
- Plugin spec: [`plugins/claimrush.md`](https://github.com/claimrush/claimrush/blob/main/plugins/claimrush.md)
- Furnace math reference: [Furnace](furnace.md)
- ClaimAllHelper reference: [ClaimAllHelper](claimallhelper.md)
- Repo map: [`repo-map.md`](repo-map.md)
- Base MCP docs (upstream): [docs.base.org/ai-agents/plugins/custom-plugins](https://docs.base.org/ai-agents/plugins/custom-plugins)
