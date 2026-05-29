# Build a Base MCP agent for ClaimRush

> **TL;DR** — Write an AI-driven helper that reads ClaimRush state via the
> Base MCP plugin and prepares actions for the user to sign. No custody,
> no broadcasting — just the same JSON envelopes Coinbase Wallet's agent
> mode consumes.

This tutorial walks through the minimum scaffolding to call the
ClaimRush Base MCP plugin from your own agent runner. Whether you're
building a custom assistant, a hosted automation, or an internal
diagnostic tool, the integration surface is the same:

1. Identify the user's intent.
2. Call read endpoints to gather context (`/state/:address`,
   `/preflight`, `/quote/lock-via-furnace`).
3. Call the matching prepare endpoint and hand the `transactions` array
   to your wallet integration (e.g. Base MCP's `send_calls`, or your own
   batch executor).

## Prerequisites

- Node.js 22 (matches the repo's `.nvmrc`).
- A wallet integration that can execute an EIP-5792-style `wallet_sendCalls`
  batch. For Base MCP-aware wallets, this is `send_calls`.
- A Base mainnet (chainId 8453) or Sepolia (84532) RPC endpoint for
  state checks. The plugin handles all on-chain reads internally — your
  agent does not need an RPC connection just to use the plugin.

## Scaffolding

The plugin exposes a public, idempotent, rate-limited HTTP API. There is
no SDK to install; `fetch` is enough.

```ts
const BASE = 'https://claimru.sh/api/mcp/v1';

async function callPlugin<T>(path: string): Promise<T> {
  const res = await fetch(`${BASE}${path}`);
  const body = await res.json();
  if (!res.ok || !body.ok) {
    throw new Error(`${body.error ?? 'PLUGIN_ERROR'}: ${body.message ?? res.statusText}`);
  }
  return body as T;
}
```

The worker accepts only `GET` and `OPTIONS`; `POST`/`PUT`/`DELETE` are
rejected with `405 METHOD_NOT_ALLOWED`. Rate limit is 300 requests / minute
per client IP per route prefix.

## Reading state

Three reads cover most agent decisions:

```ts
// 1. Is the protocol live?
const preflight = await callPlugin<{ finalized: boolean; statusBitmask: string; requiredSeedEth: string }>(
  '/preflight',
);
if (!preflight.finalized) {
  // The plugin will also refuse to emit calldata when not finalized; you
  // get the same signal here so the agent can stop early.
  return tellUser(`Genesis not finalized yet (bitmask ${preflight.statusBitmask}).`);
}

// 2. What does the user's account look like?
const state = await callPlugin<{ user: { veLocks: unknown[]; pendingRoyaltiesEthWei: string } }>(
  `/state/${userAddress}`,
);

// 3. What would a hypothetical lock-via-Furnace look like?
const quote = await callPlugin<{
  principalClaimWei: string;
  bonusClaimWei: string;
  veOutWei: string;
  minVeOutWei: string;
}>(`/quote/lock-via-furnace?user=${userAddress}&claimAmountWei=${amountWei}&durationSeconds=${durationSec}`);
```

## Preparing actions

Every prepare endpoint returns the ordered-batch envelope:

```ts
type PreparedBatch = {
  ok: true;
  chain: 'base';
  chainId: 8453;
  transactions: Array<{
    step:
      | 'approve'
      | 'collect'
      | 'harvest'
      | 'lock'
      | 'topup'
      | 'extend'
      | 'stake'
      | 'unbond'
      | 'withdraw'
      | 'action'; // reserved generic label; no current handler emits it
    to: `0x${string}`;
    data: `0x${string}`;
    value: `0x${string}`;
    chainId: number;
  }>;
};
```

For a lock-via-Furnace action:

```ts
const batch = await callPlugin<PreparedBatch>(
  `/prepare/lock-via-furnace?user=${userAddress}` +
    `&claimAmountWei=${amountWei}` +
    `&durationSeconds=${durationSec}` +
    `&slippageBps=50`,
);

// `batch.transactions` is [approve, lock] when CLAIM allowance is
// insufficient, otherwise just [lock].
await sendCalls(batch.transactions);
```

`sendCalls` is whatever your wallet integration provides — most Base MCP
clients call it directly via the tool. For raw EIP-5792 wallets you can
forward the same array to `wallet_sendCalls`.

## Error handling

The plugin returns structured errors that map cleanly onto user-facing
messages:

| Code                   | HTTP | When                                                          | Suggested action                                     |
|------------------------|------|---------------------------------------------------------------|-----------------------------------------------------|
| `BAD_ADDRESS`          | 400  | `:address` param malformed                                    | Show the user the input you parsed; ask them to clarify. |
| `BAD_PARAMS`           | 400  | Query param missing or out of range                           | Re-prompt for the missing value.                    |
| `RATE_LIMITED`         | 429  | 300 req/min/IP exceeded                                       | Honor `retryAfterSec`; back off.                    |
| `GENESIS_NOT_FINALIZED`| 503  | LaunchController.preflight() bit 0 still SET                  | Tell the user genesis isn't live; surface the bitmask. |
| `CHAIN_UNREADY`        | 503  | Deployment manifest missing the contract address              | Ops issue — report.                                 |
| `QUOTE_FAILED`         | 502  | FurnaceQuoter eth_call reverted                               | Show the raw revert reason; retry isn't usually fruitful. |
| `STATE_READ_FAILED`    | 502  | Required RPC view-call failed (balanceOf / stakedBalance / claimableEth / earned) | Retry once; if still failing, surface to ops.       |
| `INTERNAL_ERROR`       | 500  | Unhandled exception in the worker                             | Retry with backoff; report if persistent.           |

The agent should treat every non-200 response as a structured error and
*not* assume `ok: true`.

## minVeOut and slippage

For lock-via-Furnace actions (`/prepare/lock-via-furnace`) the plugin
auto-quotes via `FurnaceQuoter` and applies the same `applyMinVeOutClamp`
UX guard the frontend uses:

```
minVeOut = floor(veOut * (10_000 - slippageBps) / 10_000)
if (veOut > 0 && minVeOut == 0) minVeOut = 1
```

Pass `slippageBps` to override the default (50 bps = 0.5%). The clamp to
1 wei matches the on-chain guard in `MarketRouter`,
`ShareholderRoyalties`, and `LpStakingVault7D`, so an agent prompt can
never silently produce a calldata that bypasses slippage protection.

If your agent needs to surface the quote to the user before preparing
the action, call `/quote/lock-via-furnace` first — the response shape
includes the same `minVeOutWei` field the prepare endpoint will use, so
the user can review the exact slippage floor before signing.

## Local development

The plugin is hosted at `claimru.sh/api/mcp/v1/*` and at
`staging.claimru.sh/api/mcp/v1/*` for Sepolia testing. For local
fork testing, run your agent against staging (Sepolia chainId 84532)
and a Coinbase Smart Wallet pointed at the same network. Local
integration tests can also exercise the underlying encoding path
directly by importing
[`@claimrush/calldata-prepare`](https://github.com/claimrush/claimrush/tree/main/packages/calldata-prepare).

## Idempotency and retries

Every endpoint is idempotent and side-effect-free — they only read
chain state and return calldata. Safe to retry on transient errors. The
plugin worker does not de-duplicate identical requests; if your agent
calls `/prepare/lock-via-furnace` twice with the same arguments, you'll
get the same batch back twice, and `send_calls` will produce two
independent batches (the user prompted twice).

For "did the user already do this?" questions, read `/state/:address`
after the action completes — the subgraph is the source of truth.

## See also

- Reference: [Base MCP plugin](../base-mcp-plugin.md)
- Plugin spec: [`plugins/claimrush.md`](https://github.com/claimrush/claimrush/blob/main/plugins/claimrush.md)
- Architecture: [`docs/architecture/base-mcp-plugin-appendix-v1.0.0.md`](https://github.com/claimrush/claimrush/blob/main/docs/architecture/base-mcp-plugin-appendix-v1.0.0.md)
- Agent SDK (for self-run agents without the plugin): [Agents and Automation](../agents-and-automation.md)
- Base MCP docs: [docs.base.org/ai-agents/plugins/custom-plugins](https://docs.base.org/ai-agents/plugins/custom-plugins)
