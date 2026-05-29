# Token Supply API

Public REST endpoints that serve CLAIM token supply data for indexers such as CoinGecko, CoinMarketCap, DeFiLlama, and any third-party aggregator.

## Endpoints

All endpoints are **unauthenticated**, return JSON, and are safe to poll at any frequency. Responses are cached for 5 minutes (max supply: 24 hours).

### GET /api/supply/total

Returns the current total supply of CLAIM (all minted tokens minus any burned).

```
GET https://claimru.sh/api/supply/total
```

**Response:**

```json
{ "result": "14349000.00" }
```

### GET /api/supply/circulating

Returns the circulating supply: total supply minus CLAIM locked in veCLAIM.

```
GET https://claimru.sh/api/supply/circulating
```

**Response:**

```json
{ "result": "12000000.00" }
```

### GET /api/supply/max

Returns `null` — CLAIM has no hard-coded max supply. Supply starts at 0 and is minted continuously by MineCore with a decaying emission schedule.

```
GET https://claimru.sh/api/supply/max
```

**Response:**

```json
{ "result": null }
```

### Error responses

On failure (RPC unreachable, contracts not deployed, or RPC returns a malformed `uint256`), all endpoints return HTTP 502 with `result: null` and an `error` code:

```json
{ "result": null, "error": "SUPPLY_NO_RPC_URL" }
```

```json
{ "result": null, "error": "SUPPLY_RPC_INVALID_UINT256" }
```

`SUPPLY_RPC_INVALID_UINT256` is emitted when the upstream RPC returns anything other than a strict `0x` + 64 hex characters payload for an `eth_call` view. The endpoints fail closed on that case rather than caching `0` as a "valid" supply read.

## Supply methodology

### Formula

```
totalSupply       = ClaimToken.totalSupply()
lockedSupply      = VeClaimNFT.totalLockedClaim()
circulatingSupply = totalSupply - lockedSupply
```

Both values are read from Base mainnet via `eth_call` against the latest block.

### Onchain sources

| Metric | Contract | Solidity selector |
|--------|----------|-------------------|
| Total supply | `ClaimToken` | `totalSupply()` — `0x18160ddd` |
| Locked supply | `VeClaimNFT` | `totalLockedClaim()` — `0x0ff566a7` |

Contract addresses are loaded from `deployments/<network>.json`.

### Why exclude locked tokens?

CoinGecko's [official supply methodology](https://support.coingecko.com/hc/en-us/articles/32294647667865) states:

> **Locked Tokens:** Tokens that are locked via smart contracts or other time-based lockups are excluded.

This matches the Aerodrome (AERO) precedent on Base: CoinGecko shows AERO circulating supply as `totalSupply - veAERO locked balance`. As of April 2026, AERO total supply is ~1.875B with ~954M locked in the Voting Escrow contract, producing a circulating supply of ~921M — which matches the CoinGecko listing exactly.

CLAIM follows the same ve-tokenomics model, so the same formula applies.

## Implementation details

| Component | Role |
|-----------|------|
| `/api/supply/total` | Server-side handler: total supply via `eth_call` to `ClaimToken.totalSupply()` (`0x18160ddd`); 5-min `cache-control`. |
| `/api/supply/circulating` | Server-side handler: circulating supply via `eth_call` to both `ClaimToken.totalSupply()` and `VeClaimNFT.totalLockedClaim()` (`0x0ff566a7`); 5-min `cache-control`. |
| `/api/supply/max` | Server-side handler: returns static `{ "result": null }` (no hard-coded max supply); 24-hour `cache-control`. |
| Response contract | All endpoints return JSON shaped as `{ result: string \| null, error?: string }`. Wei is converted to a fixed-point decimal string (18 decimals truncated to 2). |
| `deployments/<network>.json` | Source for `ClaimToken` and `VeClaimNFT` addresses used by the handlers. |
