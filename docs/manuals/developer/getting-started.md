# Getting Started

This page covers repo setup, local development, and key integration rules.

## Integration rules (must follow)

1. **Never hardcode addresses.** Load from `deployments/<network>.json`.
2. **Never invent event signatures.** Use `src/lib/Events.sol` + ABIs in `abis/`.
3. **Use correct UI verbs.** ETH payouts = "Collect" | LP rewards = "Harvest"

## Prerequisites

| Tool | Version |
|------|---------|
| Foundry | 1.5.1 (CI pinned) |
| Node.js | Use repo `.nvmrc` |
| Python 3 | For lint/sync scripts |
| Git | Standard |

## Repo setup

```bash
make deps    # Foundry libraries (pinned)
make build   # Build contracts
make test    # Run tests
```

## Local protocol workflow

The public repo ships the protocol source, tests, manifests, subgraph, analytics pack, keeper, and SDK. It does not ship the proprietary application UI or the private one-command local orchestration wrapper.

Use the public workflow:

```bash
make deps
make build
make test
make gates
```

SDK examples that target a local chain assume `RPC_URL=http://127.0.0.1:8545`.

EIP-170 code size limits are enforced by default. To allow oversized local deploys, run with `LOCAL_ALLOW_OVERSIZE=1` (or `--allow-oversize`).

## CI-parity gates

```bash
make gates
```

Run before shipping changes. This target includes deployment sync, docs/ABI/subgraph checks, policy lint, analytics SQL lint, and other repo guardrails defined in `Makefile`.

## Supported environments

| Environment | Network |
|-------------|---------|
| local | Anvil (Foundry) |
| base_sepolia | Base Sepolia (staging) |
| base_mainnet | Base mainnet (production) |

**Manifests:** `deployments/<network>.json` (canonical)

## Deployed addresses

| Type | Path |
|------|------|
| Canonical | `deployments/<network>.json` |
| Human-readable | `deployments/<network>.md` |

**Rule:** Filter logs by `evt_block_number >= startBlock` from manifest.

## ABIs

ABIs are emitted to `abis/<network>/<Contract>.abi.json` and are the source of truth for contract decoding. Import them as JSON in your client of choice (viem, ethers, wagmi all accept the shipped shape). Event signatures track `src/lib/Events.sol` plus contract-local events; see [Events and Indexing](events-and-indexing.md).

## First call

The minimal read — load the manifest, point a public client at Base, fetch the current King, and quote the next takeover price:

```ts
import { createPublicClient, http } from "viem";
import { base } from "viem/chains";
import manifest from "./deployments/base_mainnet.json";
import mineCoreAbi from "./abis/base_mainnet/MineCore.abi.json";

const client = createPublicClient({ chain: base, transport: http(process.env.RPC_URL) });
const mineCore = { address: manifest.contracts.MineCore.proxy, abi: mineCoreAbi } as const;

const [king, price] = await Promise.all([
  client.readContract({ ...mineCore, functionName: "currentKing" }),
  client.readContract({
    ...mineCore,
    functionName: "getTakeoverPrice",
    args: [BigInt(Math.floor(Date.now() / 1000))],
  }),
]);

console.log({ king, takeoverPriceWei: price.toString() });
```

Two rules carried by this snippet: (1) addresses always come from the deployment manifest, never hardcoded; (2) ABIs always come from `abis/<network>/`, never reconstructed from signatures. For richer reads (royalties, locks, Furnace quotes), see [Agents and Automation — Read state for decision making](agents-and-automation.md#read-state-for-decision-making).

## Base Sepolia (staging)

Sepolia is the rehearsal target for new SDK / indexer integrations before mainnet. Read `deployments/base_sepolia.json` for the live address list and start block. ClaimToken on Sepolia is deployed alongside the rest of the bundle — bridge or swap WETH/ETH from a public Sepolia faucet to acquire the entry tokens used by tutorials.

## Repo map

See [Repo Map](repo-map.md) for the path-by-path inventory and entry routes.

## Key params (v1.0.0)

The canonical list lives in [Constants Reference](appendix-constants-v100.md). A short reminder of the most-asked values:

- **Crown pricing** — `TAKEOVER_PRICE_FLOOR = 0.001 ETH`, `TAKEOVER_DECAY_PERIOD = 1 hour`, `referencePrice = pricePaid * 2` on every successful takeover.
- **Emissions** — linear decay over `EMISSION_DECAY_PERIOD = 2 years`. Crown stream `50 → 50/9 CLAIM/s`; Furnace reserve stream `5 → 5/9 CLAIM/s`.
- **Locks** — `MIN_LOCK_AMOUNT = 1,000 CLAIM`, duration `[7, 365] days`, `MAX_LOCKS_PER_USER = 32`.
- **Barons activation** — `MIN_VE_FLUSH = 100e18`. Manual flushes below the threshold no-op; takeover allocations bypass it.

## See also

- [Protocol Overview](protocol-overview.md) — big picture architecture
- [Core Mechanics](core-mechanics.md) and [Furnace](furnace.md) — building an app
- [Events and Indexing](events-and-indexing.md) — analytics and indexing
- [Agents and Automation](agents-and-automation.md) — building agents
- [Maintenance and Bots](maintenance-and-bots.md) — building keepers
- [Tutorials](tutorials/README.md) — integration tutorials
- User manual: [ClaimRush User Manual](https://docs.claimru.sh/)
