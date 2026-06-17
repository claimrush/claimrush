# ClaimRush — Base MCP plugin

ClaimRush is a Base-native v3-onchain protocol with a bonus-Furnace that
locks CLAIM into veCLAIM with a duration-weighted bonus, a 7-day LP staking
vault, ETH royalty distribution to veCLAIM lockers, and an AutoMax 365-day
lock loop. This plugin teaches a Base-MCP-capable assistant how to call the
ClaimRush prepare-API to produce unsigned calldata for the user's wallet to
sign via `send_calls`.

## Plugin metadata

- **Name**: `claimrush`
- **Owner**: ClaimRush (`https://claimru.sh`)
- **Chain**: Base mainnet (`chainId = 8453`)
- **Base URL**: `https://claimru.sh/api/mcp/v1`
- **Source**: <https://github.com/claimrush/claimrush>
- **Auth**: none — every endpoint is public, idempotent, and rate-limited
  by client IP at 300 req/min per route prefix.
- **Side-effects**: none on the worker side. Every prepare endpoint returns
  unsigned calldata only; the wallet is the sole signer.

> **Safety posture.** The worker NEVER signs, NEVER holds private keys, and
> NEVER broadcasts transactions. It only produces calldata that the user's
> Base-MCP-capable wallet executes via `send_calls`. If the worker detects
> that the protocol is still mid-genesis, every prepare endpoint short-
> circuits with `GENESIS_NOT_FINALIZED` rather than emitting calldata that
> would revert on-chain. See the architecture appendix at
> [`docs/architecture/base-mcp-plugin-appendix-v1.0.0.md`][appendix] for the
> full fail-closed posture.

[appendix]: ../docs/architecture/base-mcp-plugin-appendix-v1.0.0.md

## How to use

1. The assistant identifies a user intent (e.g. *"collect my royalties to ETH"*,
   *"harvest my LP rewards"*, *"lock 250 CLAIM via the Furnace"*).
2. The assistant calls the appropriate read endpoint (`/state/:address`,
   `/preflight`, `/quote/lock-via-furnace`) to confirm the action is well-formed.
3. The assistant calls the matching prepare endpoint to get an ordered batch
   of unsigned calls.
4. The assistant hands the `transactions` array to Base MCP's `send_calls`
   tool, which prompts the user once and executes the batch atomically.

> **Voice rule for assistants.** ClaimRush uses a fixed verb policy:
> ETH payouts are **collected** (royalties), LP CLAIM rewards are
> **harvested**, CLAIM is **locked** (plain veCLAIM or via the Furnace),
> and deposited LP is **withdrawn**. Never say "claim my royalties",
> "claim rewards", or "burn CLAIM" when relaying actions to the user —
> always use the action verb listed in the table below.

The `transactions` shape returned by every prepare endpoint (example
shown is the two-step `lock-via-furnace` envelope; a single-step action
like `collect-royalties` returns a one-element `transactions` array):

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

`step` is informational — Base MCP `send_calls` only consumes
`{ to, data, value, chainId }`. The labels follow the brand-voice verb
policy and let the assistant relay each step to the user in plain
language:

| `step` label | Used for                                                       |
|--------------|----------------------------------------------------------------|
| `approve`    | ERC-20 allowance step prepended when needed                    |
| `collect`    | `collect-all`, `collect-royalties` (ETH-mode payouts)          |
| `harvest`    | `harvest-rewards` (LP CLAIM token rewards)                     |
| `lock`       | `lock`, `lock-via-furnace` (CLAIM into veCLAIM, both paths)    |
| `topup`      | `topup` (add CLAIM to existing veCLAIM lock)                   |
| `extend`     | `extend` (extend an existing veCLAIM lock end-date)            |
| `stake`      | `stake-lp`                                                     |
| `unbond`     | `unbond-lp` (begin 7-day cooldown)                             |
| `withdraw`   | `withdraw-lp` (matured-unbond payout)                          |

`action` is a reserved generic label that no current handler emits.

## Read endpoints (no calldata emitted)

### `GET /api/mcp/v1/state/:address`

Returns a compact per-user state snapshot. Numeric balances are always
read via `eth_call` (the subgraph does not index per-block view-function
output); the `veLocks` list is hydrated from the ClaimRush subgraph when
configured, or returned as `[]` otherwise.

- `address` (path param) — `0x`-prefixed 20-byte EVM address.

Response (truncated):

```json
{
  "ok": true,
  "source": "subgraph+rpc",
  "chainId": 8453,
  "user": {
    "address": "0xabc…",
    "claimBalanceWei": "1234000000000000000000",
    "lpStakedWei": "0",
    "pendingRoyaltiesEthWei": "5678000000000000",
    "pendingLpRewardsWei": "0",
    "veLocks": [{ "tokenId": "7", "amountWei": "…", "lockEnd": "…", "autoMax": false }]
  }
}
```

The numeric balances are always RPC reads (subgraph does not index per-block
view-function output). `source` is `"subgraph+rpc"` when the lock list is
hydrated from the subgraph and `"rpc"` when the subgraph is unconfigured /
returns no data (in which case `veLocks` is `[]`).

### `GET /api/mcp/v1/preflight`

Returns the LaunchController preflight bitmask plus a derived
`finalized` boolean. Mirrors `LaunchController.preflight()`.

- `finalized: true` — protocol is live, user actions enabled.
- `finalized: false` — genesis not yet committed; user actions paused.

### `GET /api/mcp/v1/quote/lock-via-furnace`

Returns the Furnace quote tuple for a hypothetical lock-via-Furnace action,
plus a clamped `minVeOutWei` derived from the supplied `slippageBps`
(default 50 bps). Mirrors `FurnaceQuoter.quoteEnterWithClaim`.

Query params:

- `user` (required) — owner address.
- `claimAmountWei` (required) — CLAIM amount to lock, in wei.
- `targetTokenId` (default `0`) — `0` mints a new lock.
- `durationSeconds` (default `0`) — new-lock duration (`0` for top-ups).
- `createAutoMax` (default `false`).
- `slippageBps` (default `50`).

Response includes `principalClaimWei`, `bonusClaimWei`, `veOutWei`,
`minVeOutWei`, `routeTokenId`.

## Prepare endpoints (return unsigned calldata)

All prepare endpoints are `GET` and return the ordered-batch envelope shown
above. Required and optional params are listed under each action.

| Action               | Path                                       | User-facing verb | Notes                                                       |
|----------------------|--------------------------------------------|------------------|-------------------------------------------------------------|
| `collect_all`        | `/api/mcp/v1/prepare/collect-all`          | Collect          | `ClaimAllHelper.claimAll(mode, …)` — bundled royalties + LP |
| `collect_royalties`  | `/api/mcp/v1/prepare/collect-royalties`    | Collect          | `ShareholderRoyalties.claimShareholder(…)` — ETH payout     |
| `harvest_rewards`    | `/api/mcp/v1/prepare/harvest-rewards`      | Harvest          | `LpStakingVault7D.claimRewards / …AndLock` — LP CLAIM       |
| `withdraw_lp`        | `/api/mcp/v1/prepare/withdraw-lp`          | Withdraw         | `LpStakingVault7D.withdrawMatured()`                        |
| `lock_via_furnace`   | `/api/mcp/v1/prepare/lock-via-furnace`     | Lock via Furnace | `Furnace.enterWithClaim` + CLAIM approve + minVe            |
| `stake_lp`           | `/api/mcp/v1/prepare/stake-lp`             | Stake            | `LpStakingVault7D.stake` + LP approve                       |
| `unbond_lp`          | `/api/mcp/v1/prepare/unbond-lp`            | Unbond           | `LpStakingVault7D.beginUnbond(amount)`                      |
| `lock`               | `/api/mcp/v1/prepare/lock`                 | Lock             | `VeClaimNFT.createLockFor` + CLAIM approve                  |
| `topup`              | `/api/mcp/v1/prepare/topup`                | Top up           | `VeClaimNFT.addToLockFor` + CLAIM approve                   |
| `extend`             | `/api/mcp/v1/prepare/extend`               | Extend           | `VeClaimNFT.extendLockToFor`                                |

> **Naming note.** Several on-chain functions are named `claim*` for legacy
> ABI-stability reasons (`claimAll`, `claimShareholder`, `claimRewards`).
> The plugin's actions and endpoints expose them under the brand-correct
> verb. The on-chain function name appears unchanged in the Notes column
> for ABI cross-reference, but the user-facing verb is the one in the
> table.

### Direct writes

#### `GET /api/mcp/v1/prepare/collect-all`

Encodes `ClaimAllHelper.claimAll(mode, targetTokenId, durationSeconds, createAutoMax, minVeOut)`.
User-facing verb: **Collect**.

- `mode` — `0` = ETH (default), `1` = COMPOUND_INTO_LOCK, `2` = COMPOUND_INTO_AUTO_MAX.
- `targetTokenId` — required for compound modes (`mode ≠ 0`).
- `durationSeconds`, `createAutoMax`, `minVeOutWei` — see Furnace quote helper.

#### `GET /api/mcp/v1/prepare/collect-royalties`

Encodes `ShareholderRoyalties.claimShareholder(...)` with the same parameter
grammar as `collect-all`. Default mode is ETH. User-facing verb: **Collect**.

#### `GET /api/mcp/v1/prepare/harvest-rewards`

Encodes `LpStakingVault7D.claimRewards()` by default, or
`claimRewardsAndLock(targetTokenId, durationSeconds, createAutoMax, minVeOut)`
when `compound=true` is passed. User-facing verb: **Harvest**.

#### `GET /api/mcp/v1/prepare/withdraw-lp`

Encodes `LpStakingVault7D.withdrawMatured()` — no parameters. The caller
must have a matured unbond ready (use `/state/:address` to check).
User-facing verb: **Withdraw**.

### Complex writes (allowance + minVeOut)

#### `GET /api/mcp/v1/prepare/lock-via-furnace`

Pre-quotes via `FurnaceQuoter.quoteEnterWithClaim`, clamps `minVeOut`, and
emits an approve+action batch when CLAIM allowance is insufficient.
User-facing verb: **Lock via Furnace**.

Required: `user`, `claimAmountWei`. Optional: `targetTokenId`,
`durationSeconds`, `createAutoMax`, `slippageBps`.

In addition to the standard `transactions` array, the response carries a
`quote` object so the assistant can echo the pre-trade numbers back to the
user without an extra `/quote/lock-via-furnace` round trip:

```json
{
  "ok": true,
  "chain": "base",
  "chainId": 8453,
  "transactions": [ /* … approve + action … */ ],
  "quote": {
    "veOutWei": "…",
    "minVeOutWei": "…",
    "slippageBps": 50
  }
}
```

#### `GET /api/mcp/v1/prepare/stake-lp`

Encodes `LpStakingVault7D.stake(amount)`. LP allowance for the vault is
auto-checked and an approve is prepended if needed.

Required: `user`, `amountWei`.

#### `GET /api/mcp/v1/prepare/unbond-lp`

Encodes `LpStakingVault7D.beginUnbond(amount)`. No allowance required.

Required: `amountWei`.

#### `GET /api/mcp/v1/prepare/lock`

Encodes `VeClaimNFT.createLockFor(user, amount, duration, autoMax)`. CLAIM
allowance for the veCLAIM NFT contract is auto-checked.

Required: `user`, `amountWei` (≥ 1_000 CLAIM), `durationSecs`. Optional: `autoMax`.

#### `GET /api/mcp/v1/prepare/topup`

Encodes `VeClaimNFT.addToLockFor(user, tokenId, amount)`. CLAIM allowance
auto-checked.

Required: `user`, `tokenId`, `amountWei`.

#### `GET /api/mcp/v1/prepare/extend`

Encodes `VeClaimNFT.extendLockToFor(user, tokenId, newEnd)`. No allowance
required.

Required: `user`, `tokenId`, `newEnd` (absolute unix timestamp).

## Error responses

Every endpoint returns a structured `{ ok: false, error, ...detail }` envelope
on failure. Common error codes:

- `BAD_ADDRESS` — input address malformed (400).
- `BAD_PARAMS` — required query param missing or out of range (400).
- `RATE_LIMITED` — client IP exceeded the per-route bucket (429).
- `GENESIS_NOT_FINALIZED` — protocol still mid-genesis (503). Includes
  `statusBitmask`, `bitsSet`, `bitsExpected` so the assistant can tell the
  user how close to launch the protocol is.
- `CHAIN_UNREADY` — deployment manifest missing an address (503).
- `QUOTE_FAILED` / `STATE_READ_FAILED` — upstream RPC failure (502).
- `INTERNAL_ERROR` — unhandled exception in the worker (500).

## Versioning

This spec describes the **v1** route family at `/api/mcp/v1/`. Breaking
changes will land under `/api/mcp/v2/` with both routes co-served during the
transition window. Backwards-incompatible changes to v1 will never ship.

## Reporting issues

Open an issue at <https://github.com/claimrush/claimrush/issues> with the
label `mcp-plugin`, or email security disclosures per `SECURITY.md`.

## See also

- Whitepaper (Activity-Routed Ownership — Protocol Design): <https://claimru.sh/whitepaper>
- User tutorial: <https://docs.claimru.sh/tutorials/use-with-ai-assistants>
- Developer reference: [`docs/manuals/developer/base-mcp-plugin.md`](../docs/manuals/developer/base-mcp-plugin.md)
- Architecture appendix: [`docs/architecture/base-mcp-plugin-appendix-v1.0.0.md`](../docs/architecture/base-mcp-plugin-appendix-v1.0.0.md)
- Base MCP docs (upstream): <https://docs.base.org/ai-agents/plugins/custom-plugins>
