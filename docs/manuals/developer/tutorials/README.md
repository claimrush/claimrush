# Tutorials

Integration tutorials for apps, bots, indexers, and analytics. Read [Getting Started](../getting-started.md) for repo setup and [Protocol Overview](../protocol-overview.md) for the CLAIM stream and contract map first.

Agent SDK workspace: `agents/sdk/`

## Universal rules

1. Load addresses + start blocks from `deployments/<network>.json`
2. Decode events from `src/lib/Events.sol` + ABIs in `abis/`
3. UI verbs: ETH payouts = **Collect** | LP rewards = **Harvest**

## Tutorials

| Tutorial | Goal |
|----------|------|
| [Index takeovers and reigns](index-takeovers-and-reigns.md) | Track Crown ownership, takeover history |
| [Crown price widget + takeover](build-crown-price-and-takeover.md) | Display price, submit takeover tx |
| [Crown bot (takeover at 30 minutes)](run-crown-bot-at-30min.md) | Run a delegated takeover loop |
| [Furnace quotes + enter](integrate-furnace-quotes-and-enter.md) | Quote veCLAIM output, execute entry |
| [Collect Barons ETH / Collect & Lock](collect-barons-eth-or-lock.md) | Show accrued ETH, implement both modes |
| [Index Market listings](index-market-orderbook.md) | Index listings, compute metrics |
| [MaintenanceHub bot](run-maintenance-bot.md) | Run permissionless poke loop |
| [Run the ClaimRush OpenClaw skill](run-claimrush-openclaw-skill.md) | Drive the SDK from chat with CRAL guardrails |
| [Build a Base MCP agent for ClaimRush](build-base-mcp-agent.md) | Wire a Base MCP–capable chat assistant against the ClaimRush plugin (reads + unsigned calldata) |
