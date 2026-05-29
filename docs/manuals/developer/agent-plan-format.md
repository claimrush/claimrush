# Agent Plan Format

> v1.0.0 — AgentPlan schema and executor for external AI decision systems.

If you want an external AI system to decide actions on top of ClaimRush, use **AgentPlan v1**. The plan format is a JSON serialization of action lists that the Agent SDK can simulate or execute against the live protocol.

> **TL;DR:** Build a plan with `example:plan`. Simulate or execute with `example:execute-plan`. The schema lives at `agents/sdk/schemas/agent-plan.v1.schema.json`. The executor covers the full gameplay surface for self-run agents and adds `...For(user)` variants for delegated mode. Auto-approvals can insert ERC-20 and veNFT approvals ahead of the actions that need them.

## Build and execute a plan

```bash
RPC_URL=http://127.0.0.1:8545 \
npm -C agents/sdk run example:plan -- --out /tmp/agent-plan.json --pretty

RPC_URL=http://127.0.0.1:8545 \
npm -C agents/sdk run example:execute-plan -- --plan /tmp/agent-plan.json

# Optional: emit achievements.jsonl (and poll profile badges)
ACHIEVEMENTS_BASE_URL=http://127.0.0.1:3000 \
  npm -C agents/sdk run example:execute-plan -- --plan /tmp/agent-plan.json --execute
```

CLI parity: the same knobs are available as flags (see `--help`):

- `--achievements-base-url`
- `--achievements-poll-ms`
- `--achievements-refresh-cooldown-ms`
- `--achievements-timeout-ms`

## Market actions

Market actions (offers, listings, sells) are expressed as plan actions:

```bash
# Show available commands
RPC_URL=http://127.0.0.1:8545 \
npm -C agents/sdk run example:market -- --help

# Example: create an offer (simulated)
RPC_URL=http://127.0.0.1:8545 TARGET_BONUS_BPS=2500 BUDGET_CLAIM=1000000000000000000 DURATION_DAYS=30 \
  npm -C agents/sdk run example:market -- --cmd offer-create
```

## Delegated mode

Add `--acting-for 0xUserAddress` to `example:plan` so the plan targets a user identity (and uses delegated entry points when executed).

## Schema

The canonical JSON Schema lives at `agents/sdk/schemas/agent-plan.v1.schema.json` (action enum + field set).

## Action coverage (AgentPlan v1)

The SDK executor covers (nearly) the full gameplay surface for self-run agents.

### MineCore

- Takeovers: `mineCore.takeover`, `mineCore.takeoverWithToken`
- Config: `mineCore.setCurrentReignRecipients`, `mineCore.setKingAutoLockConfig`
- Withdrawals: `mineCore.withdrawKingBalance`, `mineCore.withdrawRefundBalance`

### Furnace

- Entry: `furnace.enterWithEth`, `furnace.enterWithClaim`, `furnace.enterWithToken`

### ShareholderRoyalties

- Collect: `royalties.claimShareholderEth`, `royalties.claimShareholderLock`
- Config: `royalties.setAutoCompoundConfig`

### MarketRouter

- Listings: `marketRouter.listLock`, `marketRouter.delistLock`, `marketRouter.cancelExpiredListing`
- Offers: `marketRouter.createBonusTargetEscrowWithTarget`, `marketRouter.cancelBonusTargetEscrow`, `marketRouter.extendBonusTargetEscrowExpiry`, `marketRouter.cancelExpiredBonusTargetEscrow`, `marketRouter.executeAutoFurnace`
- Exits: `marketRouter.sellLockToFurnace`, `marketRouter.sellListedLockToFurnace`

### VeClaimNFT (veCLAIM positions)

- Maintenance: `furnace.extendWithBonus`, `furnace.extendWithBonusFor`, `furnace.mergeLocksWithBonus`, `furnace.mergeLocksWithBonusFor`, `ve.unlock`, `ve.setAutoMax`
- Checkpoints: `ve.checkpointGlobalState`, `ve.checkpointTotalVe`

### Approvals

- ERC20: `erc20.approve`, `erc20.ensureAllowance`
- veNFT: `ve.approve`, `ve.setApprovalForAll`

## Auto approvals

For unattended operation, the agent can automatically insert the required ERC20 and veNFT approval actions ahead of swap / takeover / market actions.

Enable via env vars:

- `AUTO_APPROVE_ENABLED=1`
- `AUTO_APPROVE_MODE=exact|max` (default: `exact`)
- `AUTO_APPROVE_NFT=0|1` (default: `1`)

Notes:

- Auto approvals are inserted only when executing transactions; dry-run does not send approvals.
- Not compatible with `PRIVATE_RPC_MODE=only` — approval txs are blocked. Pre-approve, or use `PRIVATE_RPC_MODE=route`.
- veNFT auto approvals use per-tokenId `approve` (not `setApprovalForAll`) for safety.

Delegated mode adds `...For(user)` action variants where the protocol exposes them, plus safe account-management actions (auto-compound configs and ve maintenance).

## See also

- [Agents and Automation](agents-and-automation.md) — Agent SDK overview, CRAL pack, repo entrypoints
- [Achievements Telemetry](achievements-telemetry.md) — JSONL telemetry stream emitted alongside plans
- [Bot Sessions (DelegationHub)](delegationhub.md) — session management for delegated agents
