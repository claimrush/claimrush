# Bot Sessions (DelegationHub)

`DelegationHub` is the onchain session registry for opt-in bot delegation. It lets users grant time-limited, permission-scoped sessions to bot addresses, which protocol contracts verify on every delegated call. In the [CLAIM stream](protocol-overview.md), this is how bots automate takeovers, harvesting, Furnace entries, and lock maintenance on behalf of users.

> **TL;DR:** Users call `setSession(delegate, perms, expiry)` or sign gasless via EIP-712. Bots are checked with `isAuthorized(user, delegate, requiredPerms)`. 18 permission bits covering Crown, Harvest, Furnace, VeLock, and Config actions. Sessions should be short-lived with minimal perms.

A session is:
- `user` (the identity being represented)
- `delegate` (the bot / executor)
- `perms` (permission bitmask)
- `expiry` (unix seconds)

Sessions are verified by protocol contracts onchain via `isAuthorized(...)`.

## Read surface

| Method | Notes |
|---|---|
| `getSession(user, delegate) -> (perms, expiry)` | Raw stored session data |
| `isAuthorized(user, delegate, requiredPerms) -> bool` | Returns `false` (no revert) on any of: `user == delegate`, `requiredPerms == 0`, `requiredPerms` containing bits outside `DelegationPermissions.ALL`, `expiry == 0`, `expiry <= block.timestamp`, or `(session.perms & requiredPerms) != requiredPerms`. |
| `nonces(user) -> uint256` | EIP-712 nonce for gasless set-by-sig. Also increments on direct `setSession(...)` / `revokeSession(...)` to invalidate outstanding signatures. |

## Write surface

| Method | Caller | Notes |
|---|---|---|
| `setSession(delegate, perms, expiry)` | user | Stores session; overwrites prior |
| `revokeSession(delegate)` | user | Clears perms + expiry |
| `setSessionBySig(user, delegate, perms, expiry, nonce, deadline, sig)` | anyone | Gasless; validates signature + nonce + deadline |

Signature model:
- EIP-712 domain:
  - name: `ClaimRush DelegationHub`
  - version: `1`
- Typehash: `SetSession(address user,address delegate,uint256 perms,uint256 expiry,uint256 nonce,uint256 deadline)` (note: `expiry` is encoded as `uint256` in the typed struct even though storage uses `uint64`).
- Uses OpenZeppelin `SignatureChecker` (supports EOAs + EIP-1271 smart wallets).
- Direct onchain `setSession(...)` and `revokeSession(...)` also increment `nonces(user)`.
  - Integrators MUST re-read the current nonce after any direct session change.
  - Any outstanding `SetSession` signature becomes invalid once a direct update/revoke lands onchain.

Validation rules (apply to all three write paths):
- `user == address(0)` or `delegate == address(0)` revert `ZeroAddress`.
- `user == delegate` reverts `NotAuthorized` (self-delegation is useless — `isAuthorized` would always return `false`).
- `perms` containing bits outside `DelegationPermissions.ALL` reverts `NotAuthorized`.
- `perms != 0` with `expiry == 0` or `expiry <= block.timestamp` reverts `DeadlineExpired` (no unreachable sessions in storage).
- `perms != 0` with a `delegate` whose code carries an EIP-7702 designator (`0xEF0100 || target`) reverts `DelegatedEOA`. Bare EOAs and ordinary contracts pass. Revocations (`perms == 0`) skip the check so a compromised session can always be torn down. The signer behind a 7702-delegated executor can re-point the delegate at arbitrary code at any time, and a session with non-zero permissions authorizes the delegate to call protocol entry points on the user's behalf — see [Security, Guardian, Pausing — Delegation session-seat 7702 guard](security-guardian-pausing.md#delegation-session-seat-7702-guard) for the cross-contract rule.
- `setSessionBySig` additionally reverts `DeadlineExpired` if `block.timestamp > deadline` and `NotAuthorized` if the supplied `nonce` does not equal the current `nonces[user]` or the signature does not verify.

Direct vs signed encoding asymmetry for revocation:
- The **direct** path silently coerces `expiry = 0` whenever `perms == 0`, so `setSession(delegate, 0, anyExpiry)` and `revokeSession(delegate)` both produce the canonical `(perms=0, expiry=0)` revocation in storage.
- The **signed** path is strict — `perms == 0 && expiry != 0` reverts `DeadlineExpired` (`src/DelegationHub.sol` L96). When building a revocation signature, integrators MUST set `expiry = 0` exactly, otherwise the signed call will revert at submission time. This guarantees a single canonical encoding per nonce.

## Consumers in protocol contracts

Important:
- protocol consumers do not all trust a raw stored `delegationHub` pointer in isolation
- MineCore resolves the canonical hub through the live Furnace + MineCore bundle before checking session bits
- ClaimAllHelper, VeClaimNFT, ShareholderRoyalties, and LpStakingVault7D apply similar consumer-specific live wiring checks

### MineCore: delegated takeover

`MineCore.takeoverFor(newKing, maxPrice)`:
- `msg.sender` pays ETH and becomes the executor
- `newKing` becomes the King identity
- requires `DelegationHub.isAuthorized(newKing, msg.sender, P_TAKEOVER_FOR)` against the canonically resolved hub

Default routing for the new reign:
- `ethRecipient = msg.sender` (bot)
- `claimRecipient = newKing` (user)

Optional:
- if the session also grants `P_ROUTE_REIGN_CLAIM_TO_CALLER`, MineCore sets:
  - `claimRecipient = msg.sender`

Mid-reign routing update:
- `MineCore.setCurrentReignRecipients(ethRecipient, claimRecipient)`
  - MineCore again resolves the canonical hub through the live Furnace + MineCore bundle before checking any session bits
  - callable by the active King identity
  - or an authorized delegate with:
    - for `ethRecipient`: `P_SET_REIGN_ETH_RECIPIENT` or `P_SET_REIGN_ETH_RECIPIENT_TO_CALLER_ONLY`
    - for `claimRecipient`: `P_SET_REIGN_CLAIM_RECIPIENT` or `P_SET_REIGN_CLAIM_RECIPIENT_TO_USER_ONLY`

### ClaimAllHelper: delegated harvest + withdraw

`ClaimAllHelper` provides delegation-gated wrappers:
- `claimShareholderForUser(user, ...)` requires `P_CLAIM_SHAREHOLDER_FOR`
- `withdrawKingBalanceForUser(user)` requires `P_WITHDRAW_KING_BUCKET_FOR`
- `claimAllFor(user, ...)` requires `P_CLAIM_ALL_FOR`

### Furnace: delegated entry (bot pays, user receives lock)

Delegated entry points:
- `enterWithEthFor(user, ...)` requires `P_FURNACE_ENTER_ETH_FOR`
- `enterWithClaimFromCallerFor(user, ...)` requires `P_FURNACE_ENTER_CLAIM_FOR`
- `enterWithTokenFromCallerFor(user, ...)` requires `P_FURNACE_ENTER_TOKEN_FOR`

### VeClaimNFT: delegated lock maintenance (safe, non-custodial)

Delegated lock maintenance entry points:
- `Furnace.extendWithBonusFor(user, tokenId, durationSeconds, minBonusOut)` requires `P_VE_EXTEND_LOCK_FOR`
- `Furnace.mergeLocksWithBonusFor(user, fromTokenId, intoTokenId, minBonusOut)` requires `P_VE_MERGE_LOCKS_FOR` (the merge path runs through Furnace so the bonus engine and reserve accounting are reused)
- `unlockExpiredForUser(user, tokenId)` requires `P_VE_UNLOCK_EXPIRED_FOR`

Non-custodial rules enforced:
- no ERC20 spend from the user
- unlock returns CLAIM to `user` (never to the delegate)
- merge/extend require the lock(s) are owned by `user`

### Settings/config: delegated config setters (safe, non-custodial)

Delegated config entry points:
- `MineCore.setKingAutoLockConfigForUser(user, ...)` requires `P_SET_KING_AUTO_LOCK_CONFIG_FOR`
- `ShareholderRoyalties.setAutoCompoundConfigForUser(user, ...)` requires `P_SET_SHAREHOLDER_AUTOCOMPOUND_CONFIG_FOR`
  - The callee resolves the canonical hub from the live Furnace / MineCore pair and also rejects split-brain Baron bundles where the `MarketRouter` / `MineCore` / `ClaimToken` back-pointers drift away from the active ShareholderRoyalties surface.
- `LpStakingVault7D.setAutoCompoundConfigForUser(user, ...)` requires `P_SET_LP_AUTOCOMPOUND_CONFIG_FOR`

Non-custodial rules enforced:
- config-only (no value transfer)
- tokenId parameters must be veNFTs owned by `user`

## Permissions map

Canonical bits are defined in `src/lib/DelegationPermissions.sol`.

| Group | Bit | Permission | Enables |
|---|---:|---|---|
| Crown | 0 | `P_TAKEOVER_FOR` | `MineCore.takeoverFor(newKing, maxPrice)` |
| Crown | 1 | `P_ROUTE_REIGN_CLAIM_TO_CALLER` | Route King-stream mined CLAIM to bot during delegated takeover |
| Crown | 2 | `P_SET_REIGN_ETH_RECIPIENT` | Allow delegate to set `ethRecipient` mid-reign to any address |
| Crown | 3 | `P_SET_REIGN_ETH_RECIPIENT_TO_CALLER_ONLY` | Allow delegate to set `ethRecipient = msg.sender` mid-reign |
| Crown | 4 | `P_SET_REIGN_CLAIM_RECIPIENT` | Allow delegate to set `claimRecipient` mid-reign to any address |
| Crown | 5 | `P_SET_REIGN_CLAIM_RECIPIENT_TO_USER_ONLY` | Allow delegate to set `claimRecipient = king` mid-reign |
| Harvest | 6 | `P_WITHDRAW_KING_BUCKET_FOR` | `ClaimAllHelper.withdrawKingBalanceForUser(user)` |
| Harvest | 7 | `P_CLAIM_SHAREHOLDER_FOR` | `ClaimAllHelper.claimShareholderForUser(user, ...)` |
| Harvest | 8 | `P_CLAIM_ALL_FOR` | `ClaimAllHelper.claimAllFor(user, ...)` |
| Furnace | 9 | `P_FURNACE_ENTER_ETH_FOR` | `Furnace.enterWithEthFor(user, ...)` |
| Furnace | 10 | `P_FURNACE_ENTER_CLAIM_FOR` | `Furnace.enterWithClaimFromCallerFor(user, ...)` |
| Furnace | 11 | `P_FURNACE_ENTER_TOKEN_FOR` | `Furnace.enterWithTokenFromCallerFor(user, ...)` |
| VeLock | 12 | `P_VE_EXTEND_LOCK_FOR` | `Furnace.extendWithBonusFor(user, tokenId, durationSeconds, minBonusOut)` |
| VeLock | 13 | `P_VE_MERGE_LOCKS_FOR` | `Furnace.mergeLocksWithBonusFor(user, fromTokenId, intoTokenId, minBonusOut)` |
| VeLock | 14 | `P_VE_UNLOCK_EXPIRED_FOR` | `VeClaimNFT.unlockExpiredForUser(user, tokenId)` |
| Config | 15 | `P_SET_KING_AUTO_LOCK_CONFIG_FOR` | `MineCore.setKingAutoLockConfigForUser(user, ...)` |
| Config | 16 | `P_SET_SHAREHOLDER_AUTOCOMPOUND_CONFIG_FOR` | `ShareholderRoyalties.setAutoCompoundConfigForUser(user, ...)` |
| Config | 17 | `P_SET_LP_AUTOCOMPOUND_CONFIG_FOR` | `LpStakingVault7D.setAutoCompoundConfigForUser(user, ...)` |

## Integration guidance

- Keep sessions short-lived (hours/days), refresh as needed.
- Offchain tooling should not treat a raw stored `delegationHub` pointer as sufficient; protocol consumers may reject a session if live wiring drift breaks their canonical hub resolution.
- Use minimal perms for the bot’s job.
- Treat recipient routing perms as high risk:
  - `P_SET_REIGN_ETH_RECIPIENT` can redirect the dethroned-King ETH payout for the active reign.
  - `P_SET_REIGN_CLAIM_RECIPIENT` can redirect mined CLAIM mid-reign.
  - Prefer constrained variants (`...TO_CALLER_ONLY`, `...TO_USER_ONLY`) where possible.
- Treat delegation as security-sensitive UX (like approvals):
  - show the delegate address
  - show expiry
  - show selected permissions
  - provide a single-call revoke


## Agent SDK

This repo's TypeScript SDK (`agents/sdk/`) includes helpers for DelegationHub:
- canonical permission bits (`agents/sdk/src/delegation/permissions.ts`)
- EIP-712 typed data builder (`buildSetSessionTypedData`)
- sign + submit `setSessionBySig` (`signSetSession`, `submitSetSessionBySig`)

Examples:

```bash
# Local demo (user signs with derived actor0; delegate submits with derived actor1)
RPC_URL=http://127.0.0.1:8545 npm -C agents/sdk run example:delegation

# Production-style: user wallet signs typed data; delegate submits signature
RPC_URL=http://127.0.0.1:8545 \
  npm -C agents/sdk run example:session -- --cmd build \
    --user 0xUserAddress \
    --delegate 0xDelegateAddress \
    --perms TAKEOVER_FOR,CLAIM_ALL_FOR \
    --out /tmp/session.json \
    --pretty

# user signs /tmp/session.json via eth_signTypedData_v4
RPC_URL=http://127.0.0.1:8545 PRIVATE_KEYS=0x<delegatePrivateKey> \
  npm -C agents/sdk run example:session -- --cmd submit --typed-data /tmp/session.json --sig 0x...

# Revoke (gasless)
RPC_URL=http://127.0.0.1:8545 \
  npm -C agents/sdk run example:session -- --cmd build --revoke --user 0xUserAddress --delegate 0xDelegateAddress --out /tmp/revoke.json --pretty
RPC_URL=http://127.0.0.1:8545 PRIVATE_KEYS=0x<delegatePrivateKey> \
  npm -C agents/sdk run example:session -- --cmd submit --typed-data /tmp/revoke.json --sig 0x...

# Run a delegated agent loop
RPC_URL=http://127.0.0.1:8545 npm -C agents/sdk run example:agent -- --actor-index 1 --acting-for 0xUserAddress --once

# Delegated safe maintenance (ve upkeep + optional config sync)
RPC_URL=http://127.0.0.1:8545 \
  ENABLE_SAFE_MAINTENANCE=1 \
  VE_EXTEND_IF_REMAINING_DAYS=7 \
  VE_EXTEND_BY_DAYS=30 \
  npm -C agents/sdk run example:agent -- --actor-index 1 --acting-for 0xUserAddress --once

Optional config sync env vars:
- `KING_AUTO_LOCK_*` (MineCore King auto-lock config)
- `ROYALTIES_AUTOCOMPOUND_*` (ShareholderRoyalties auto-compound config)
- `LP_AUTOCOMPOUND_*` (LP vault auto-compound config)
```

## Observability and indexing

DelegationHub emits two events:

- `SessionSet(user indexed, delegate indexed, perms, expiry)` — emitted on `setSession(...)`, `revokeSession(delegate)` (as `perms=0, expiry=0`), and `setSessionBySig(...)`.
- `NonceIncremented(user indexed, newNonce)` — emitted **on every** mutating path: direct `setSession`, direct `revokeSession`, and successful `setSessionBySig`. Indexers can rely on this event alone to reconstruct the live `nonces(user)` value and to invalidate cached signatures without needing to re-query the contract after every write.

Expiry notes (important for integrators):
- `isAuthorized(...)` returns `false` if `expiry == 0` or `expiry <= block.timestamp` (expired sessions are invalid at the exact second of expiry, not one second later).
- No "never-expires" session value exists in v1.0.0.
- `perms != 0` with `expiry == 0` or `expiry <= block.timestamp` reverts (`Errors.DeadlineExpired()`). Enforced in `_setSession(...)` and `setSessionBySig(...)` to prevent unreachable sessions from polluting storage.

In addition, protocol contracts emit `Events.DelegationSessionUsed(user, delegate, actionTypeId, permsUsed, refId, timestamp)`
when a delegated entrypoint succeeds.

`actionTypeId` is a numeric `uint8` defined in `src/lib/DelegationActionTypes.sol`:

| actionTypeId | Constant | Subgraph category | `refId` meaning |
|---:|---|---|---|
| 1 | `TAKEOVER_FOR` | `TAKEOVER` | `newReignId` |
| 2 | `MINECORE_SET_REIGN_RECIPIENTS` | `REIGN_RECIPIENTS` | `reignId` |
| 10 | `CLAIM_SHAREHOLDER_FOR` | `CLAIM` | `0` |
| 11 | `WITHDRAW_KING_BUCKET_FOR` | `CLAIM` | `0` |
| 12 | `CLAIM_ALL_FOR` | `CLAIM` | `0` |
| 20 | `FURNACE_ENTER_WITH_ETH_FOR` | `FURNACE_ENTER` | `tokenIdUsed` |
| 21 | `FURNACE_ENTER_WITH_CLAIM_FOR` | `FURNACE_ENTER` | `tokenIdUsed` |
| 22 | `FURNACE_ENTER_WITH_TOKEN_FOR` | `FURNACE_ENTER` | `tokenIdUsed` |
| 30 | `VE_EXTEND_LOCK_FOR` | `VE_LOCK` | `tokenId` |
| 31 | `VE_MERGE_LOCKS_FOR` | `VE_LOCK` | `intoTokenId` (destination) |
| 32 | `VE_UNLOCK_EXPIRED_FOR` | `VE_LOCK` | `tokenId` |
| 40 | `MINECORE_SET_KING_AUTO_LOCK_CONFIG_FOR` | `CONFIG` | destination `tokenId` (0 when disabling / not yet pinned) |
| 41 | `SHAREHOLDER_SET_AUTOCOMPOUND_CONFIG_FOR` | `CONFIG` | `tokenId` (0 when disabling) |
| 42 | `LP_STAKING_SET_AUTOCOMPOUND_CONFIG_FOR` | `CONFIG` | `tokenId` (0 when disabling) |

Subgraph behavior (this repo):
- The subgraph stores both:
  - `actionTypeId` (exact numeric id; canonical for review and analytics)
  - `actionType` (coarse enum for UI), derived by id ranges (see `subgraph/src/utils/delegation.ts`)
- Raw `actionTypeId` is canonical. The shipped coarse mapper in `subgraph/src/utils/delegation.ts` maps `actionTypeId = 2` (`MINECORE_SET_REIGN_RECIPIENTS`) to `actionType = REIGN_RECIPIENTS`.
- Rolling session state is kept in `DelegationSession` (including `lastUsedAt`, `lastActionType`, `lastTxHash`).
- Full history is recorded in `DelegationSessionUse` (immutable, tx hashes included).
- Session change events are recorded in `DelegationSessionSetEvent` (immutable, tx hashes included).

These entities power:
- **Advanced → Bot access** (sessions list + activity feed + single-call revoke)
- **Radar Inbox** alerts (bot session used, session granted/updated/revoked, recipients changed mid-reign)

## Operator notes

The remaining section covers source layout and deploy-time wiring. Integrators can skip unless instrumenting governance flows or troubleshooting a bundle-drift revert.

### Contract + wiring

Source:
- `src/DelegationHub.sol`
- `src/interfaces/IDelegationHub.sol`
- `src/lib/DelegationPermissions.sol` (canonical bit positions)

Wiring (v1.0.0+):

Every delegated path fails closed on bundle drift (see [Wiring safety model](protocol-overview.md#wiring-safety-model)). No contract trusts a raw `delegationHub()` read in isolation — each resolves the hub through cross-checks against the live bundle:

- **MineCore / Furnace**: each stores `delegationHub`; authorization requires the other contract to agree on the same hub and the same CLAIM / ve roots.
- **ClaimAllHelper**: resolves the hub from MineCore / ShareholderRoyalties / Furnace; rejects split-brain `MineCore.furnace()` vs `ShareholderRoyalties.furnace()` wiring.
- **VeClaimNFT**: safe-maintenance wrappers resolve the hub through Furnace + MarketRouter + MineCore.
- **ShareholderRoyalties / LpStakingVault7D**: resolve through Furnace + MineCore cross-checks.
- **MarketRouter**: does not use DelegationHub in v1.0.0. Market actions are owner-initiated transactions; the router uses its built-in `mineMarket` transfer role for lock custody, not ERC-721 approvals or delegation sessions.

**Wiring rule:** set the hub address before going live. The setter is `onlyOwner`, governed through the live timelock owner path.

**Freeze asymmetry between MineCore and Furnace:** these two setters are gated differently by design.

- `MineCore.setDelegationHub` is `onlyOwner whenNotFrozen` — once `MineCore.freezeConfig()` lands, the hub identity is permanent.
- `Furnace.setDelegationHub` is `onlyOwner` only (deliberately NOT freeze-gated). At call time, `FurnaceGuardHelper.requireCanonicalDelegationHub(...)` verifies the candidate equals `mineCore.delegationHub()`, so a post-freeze rebind on Furnace cannot drift to a hub that MineCore has not also approved. Combined with the per-call `_requireDelegated` cross-validation, the post-freeze Furnace setter cannot escalate authority — it can only re-pin Furnace to MineCore's already-frozen hub.

DelegationHub itself is permissionless and has no owner / setters / freeze surface — its only mutating entrypoints are `setSession`, `revokeSession`, and `setSessionBySig`, all keyed by the user's own address (or signature).

## See also

- [Agents and Automation](agents-and-automation.md) — SDK, CRAL pack, and agent architecture
- [Maintenance and Bots](maintenance-and-bots.md) — keeper loops that consume sessions
- [Security, Guardian, Pausing](security-guardian-pausing.md) — guardian controls and pause states
- Tutorial: [Run a Crown bot](tutorials/run-crown-bot-at-30min.md)
- User manual: [Bots & Automation](https://docs.claimru.sh/bots-and-automation)
