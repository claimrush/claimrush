# ClaimAllHelper implementer checklist (v1.0.0)

This is an **implementer-focused checklist** for `ClaimAllHelper`, a stateless helper that combines:
- Baron rewards (ShareholderRoyalties)
- King rewards (MineCore)

Source of truth:
- Canonical spec: `docs/spec/spec-v1.0.0.md`
  - ClaimAll helper: §9
  - Shareholder claim semantics: §6
  - King withdraw semantics: §5.5

Spec aids (recommended):
- `docs/spec/spec-quality-standard-v1.0.0.md`
- `docs/spec/state-machines-v1.0.0.md`

This document **does not introduce new rules**. It restates MUST/MUST NOT requirements in an order suitable for incremental implementation and review.

---

## Goals

`ClaimAllHelper` MUST:
- Provide `claimAll(...)` for the caller, plus delegation-gated `claimShareholderForUser`, `withdrawKingBalanceForUser`, and `claimAllFor` where the protocol supports bot sessions.
- Be **stateless** (no persistent balances, no accounting state, no custody). Immutable wiring references (`royalties`, `mineCore`) are allowed.
- Preserve the exact semantics of the underlying calls, except where the implementation intentionally swallows king-withdraw reverts (see try/catch asymmetry below).

`ClaimAllHelper` MUST NOT:
- Change tokenomics or permissions.
- Introduce a new escrow, fee, or sweep surface.

---

## Checklist: contract design

MUST:
- No configurable parameters required.
- No owner/admin required.
- No ETH/token custody required.

Defense-in-depth (non-binding):
- Mark the contract as non-upgradeable (no proxy).
- Keep the contract small and reviewable.

---

## Checklist: immutables + constructor

MUST (shipped shape):
- Expose `IShareholderRoyalties public immutable royalties` and `IMineCore public immutable mineCore`.

Constructor `constructor(address _royalties, address _mineCore)` MUST:
- Revert `Errors.ZeroAddress()` if either argument is `address(0)`.
- Revert `Errors.NotAContract()` if either argument has no code (`code.length == 0`).

---

## Checklist: `claimAll(...)` entrypoint

From `docs/spec/spec-v1.0.0.md` §9.

### Required signature (MUST)

```solidity
function claimAll(
  uint8 mode,
  uint256 targetTokenId,
  uint256 durationSeconds,
  bool createAutoMax,
  uint256 minVeOut
) external nonReentrant;
```

Constraints (required):
- `mode` MUST encode the same shareholder payout mode as the canonical spec + analytics pack (e.g. ETH vs lock-to-furnace); the helper forwards it as `uint8` to `ShareholderRoyalties.claimShareholderFor`.
- The lock-destination parameters are forwarded to `ShareholderRoyalties.claimShareholderFor(msg.sender, ...)`.

### Required call sequence (MUST)

0) Enforce canonical wiring (MUST, before external payout calls):
- Run the same checks as `_requireCanonicalHelperWiring()`: staticcalls on `MineCore` and `ShareholderRoyalties` MUST show this helper as `claimAllHelper()`, `MineCore.royalties()` MUST equal `ShareholderRoyalties`, and `ShareholderRoyalties.mineCore()` MUST equal `MineCore`. On failure, revert `Errors.WiringMismatch()`. If a checked address has no code, revert `Errors.NotAContract()`.
- Shipped implementation: wiring reads use a gas-bounded `staticcall` (100_000 gas) and decode only the first 32-byte word as an address (low 160 bits), avoiding full return-data copy (anti griefing).

1) Claim shareholder rewards:
- Call `ShareholderRoyalties.claimShareholderFor(msg.sender, mode, targetTokenId, durationSeconds, createAutoMax, minVeOut)`.
- This MUST preserve ShareholderRoyalties's revert/no-op behavior (call is **not** wrapped in `try/catch`).

2) Claim king rewards:
- Call `MineCore.withdrawKingBalanceFor(msg.sender)` inside `try` / `catch (bytes memory reason)`. The catch block MUST emit `Events.KingWithdrawalFailed(msg.sender, reason)`.
- **Try/catch asymmetry (MUST match shipped behavior):** shareholder claim failures revert the whole transaction; king withdraw failures emit `KingWithdrawalFailed` and are swallowed after shareholder succeeds, so the tx can still succeed without king payout. No-op / zero-balance behavior inside MineCore still applies when the call succeeds (zero balance returns early, does not revert).

Ordering:
- Use the order above (shareholder first, then king) to match the canonical spec.

Wiring note:
- Since `ClaimAllHelper` is a separate contract, MineCore and ShareholderRoyalties MUST expose helper-only "for" entrypoints
  that preserve the same accounting as the direct-call functions but pay out to an explicit `user`.
- Those "for" entrypoints MUST be restricted to the configured ClaimAllHelper address.
- The ClaimAllHelper address MUST be wired into both contracts.
- The helper constructor MUST reject zero addresses and EOAs.
- Delegation-gated wrappers (`claimShareholderForUser`, `withdrawKingBalanceForUser`, `claimAllFor`) MUST resolve the canonical `DelegationHub` from the live `MineCore` / `ShareholderRoyalties` / shared `Furnace` bundle.
  - `MineCore.furnace()` and `ShareholderRoyalties.furnace()` MUST agree on one canonical Furnace.
  - That Furnace MUST point back to the same `MineCore` and `ShareholderRoyalties`.
  - `Furnace.delegationHub()` MUST equal `MineCore.delegationHub()`.
  - A raw `MineCore.delegationHub()` read is insufficient.

### Reentrancy + CEI (MUST)

- The helper MUST use OpenZeppelin `ReentrancyGuard` and `nonReentrant` on every external entrypoint (`claimAll`, `claimShareholderForUser`, `withdrawKingBalanceForUser`, `claimAllFor`).
- Follow CEI within each function; external calls are to configured protocol contracts only.

---

## Checklist: delegation-gated entrypoints

These MUST match the shipped API (all `external nonReentrant`).

### `claimShareholderForUser`

```solidity
function claimShareholderForUser(
  address user,
  uint8 mode,
  uint256 targetTokenId,
  uint256 durationSeconds,
  bool createAutoMax,
  uint256 minVeOut
) external nonReentrant;
```

MUST:
- Revert `Errors.ZeroAddress()` if `user == address(0)`.
- Revert `Errors.NotAuthorized()` if `user == msg.sender` (delegate must differ from principal).
- Resolve the canonical `DelegationHub` via `_resolveShareholderDelegationHub()` (Furnace bundle agreement with MineCore; see wiring note under `claimAll(...)`) and revert `Errors.ZeroAddress()`, `Errors.NotAContract()`, or `Errors.WiringMismatch()` on failure.
- Revert `Errors.NotAuthorized()` if `DelegationHub.isAuthorized(user, msg.sender, P_CLAIM_SHAREHOLDER_FOR)` is false (`P_CLAIM_SHAREHOLDER_FOR` = `1 << 7` in `DelegationPermissions`).
- Call `royalties.claimShareholderFor(user, ...)`.
- Emit `Events.DelegationSessionUsed(user, msg.sender, DelegationActionTypes.CLAIM_SHAREHOLDER_FOR, P_CLAIM_SHAREHOLDER_FOR, 0, block.timestamp)` (`CLAIM_SHAREHOLDER_FOR` = `10` in `DelegationActionTypes`).

MUST NOT:
- Wrap `claimShareholderFor` in `try/catch` (reverts propagate).

### `claimShareholderToCallerForUser`

```solidity
function claimShareholderToCallerForUser(address user) external nonReentrant;
```

MUST:
- Revert `Errors.ZeroAddress()` if `user == address(0)`.
- Revert `Errors.NotAuthorized()` if `user == msg.sender`.
- Resolve the canonical `DelegationHub` via `_resolveShareholderDelegationHub()` (same Furnace-bundle agreement as `claimShareholderForUser`).
- Revert `Errors.NotAuthorized()` unless `DelegationHub.isAuthorized(user, msg.sender, P_CLAIM_SHAREHOLDER_FOR | P_ROUTE_SHAREHOLDER_ETH_TO_CALLER)` is true — BOTH bits are required (`P_CLAIM_SHAREHOLDER_FOR` = `1 << 7`, `P_ROUTE_SHAREHOLDER_ETH_TO_CALLER` = `1 << 18`).
- Call `royalties.claimShareholderForTo(user, payable(msg.sender))` — ETH-only by construction; the recipient is the caller (`msg.sender`), never an arbitrary address.
- Emit `Events.DelegationSessionUsed(user, msg.sender, DelegationActionTypes.CLAIM_SHAREHOLDER_TO_CALLER_FOR, P_CLAIM_SHAREHOLDER_FOR | P_ROUTE_SHAREHOLDER_ETH_TO_CALLER, 0, block.timestamp)` (`CLAIM_SHAREHOLDER_TO_CALLER_FOR` = `13` in `DelegationActionTypes`).

MUST NOT:
- Wrap `claimShareholderForTo` in `try/catch` (reverts propagate).
- Accept any recipient other than `msg.sender` (no arbitrary-recipient variant exists).

### `withdrawKingBalanceForUser`

```solidity
function withdrawKingBalanceForUser(address user) external nonReentrant;
```

MUST:
- Same `user` / delegation gate as above, with `P_WITHDRAW_KING_BUCKET_FOR` (`1 << 6`) and `DelegationActionTypes.WITHDRAW_KING_BUCKET_FOR` (`11`).
- Call `mineCore.withdrawKingBalanceFor(user)` without `try/catch` (MineCore revert semantics preserved).
- Emit `Events.DelegationSessionUsed` with `refId = 0` and `timestamp = block.timestamp`.

### `claimAllFor`

```solidity
function claimAllFor(
  address user,
  uint8 mode,
  uint256 targetTokenId,
  uint256 durationSeconds,
  bool createAutoMax,
  uint256 minVeOut
) external nonReentrant;
```

MUST:
- Same `user` / hub resolution as `claimShareholderForUser`, with `P_CLAIM_ALL_FOR` (`1 << 8`) and `DelegationActionTypes.CLAIM_ALL_FOR` (`12`).
- Call `royalties.claimShareholderFor(user, ...)` then `try mineCore.withdrawKingBalanceFor(user) {} catch (bytes memory reason) { emit Events.KingWithdrawalFailed(user, reason); }` (same asymmetry as `claimAll`).
- Emit `Events.DelegationSessionUsed` after both steps (with `refId = 0`).

### `Events.DelegationSessionUsed` (canonical signature)

From `src/lib/Events.sol` (emit only on delegation paths; **`claimAll` does not emit**):

```solidity
event DelegationSessionUsed(
  address indexed user,
  address indexed delegate,
  uint8 indexed actionType,
  uint256 permsUsed,
  uint256 refId,
  uint256 timestamp
);
```

### Internal helpers (shipped; not external API)

MUST exist in the reference implementation for wiring and delegation:

- `_staticcallAddress(address target, bytes4 sel) internal view returns (address)` — gas-bounded address read.
- `_requireCanonicalHelperWiring() internal view` — MineCore/ShareholderRoyalties/helper triangle.
- `_resolveCanonicalFurnace() internal view returns (address)` — agrees `furnace()` on both sides and Furnace back-references.
- `_resolveMineCoreDelegationHub() internal view returns (address)` — `MineCore.delegationHub()` equals `Furnace.delegationHub()`.
- `_resolveShareholderDelegationHub() internal view returns (address)` — same hub as mine path (alias).
- `_requireDelegated(address user, uint256 requiredPerms, address hub) internal view` — `IDelegationHub(hub).isAuthorized(user, msg.sender, requiredPerms)`.

Selector constants used for staticcalls: `royalties()`, `mineCore()`, `claimAllHelper()`, `furnace()`, `shareholderRoyalties()`, `delegationHub()` (keccak256-derived `bytes4`).

---

## Checklist: pause behavior

- The helper MUST inherit pause behavior from the underlying contracts.
- The helper MUST NOT bypass pause enforcement.

---

## Checklist: tests (minimum)

1) `claimAll` when both king + shareholder balances are zero:
- MUST be safe and MUST succeed (no-op) when both balances are zero (underlying functions return early).

2) `claimAll` with only king balance:
- MUST transfer exactly the same amount as a direct `MineCore.withdrawKingBalanceFor(msg.sender)` (equivalent to `withdrawKingBalance` for the caller when wiring is correct).

3) `claimAll` with only shareholder balance:
- MUST match `claimShareholder` behavior for each mode.

4) `claimAll` with both balances non-zero:
- MUST succeed and match calling each function separately.

5) Pause matrix:
- Under each paused state, behavior MUST match the underlying contracts.

6) Try/catch king path:
- After a successful shareholder claim in `claimAll` / `claimAllFor`, if `withdrawKingBalanceFor` reverts, the transaction MUST still succeed (king failure swallowed).

7) Wiring enforcement:
- `claimAll` MUST revert `Errors.WiringMismatch()` when MineCore/ShareholderRoyalties do not list this helper or cross-point at each other.

8) Delegation negatives:
- `claimShareholderForUser` / `withdrawKingBalanceForUser` / `claimAllFor` MUST revert `Errors.NotAuthorized()` when `user == msg.sender` or delegation is missing.

---

## Checklist: errors referenced by ClaimAllHelper

From `src/lib/Errors.sol`, the helper MUST use only these among protocol-wide errors (others may exist for other contracts):

| Error | When |
| --- | --- |
| `ZeroAddress()` | Constructor args; `user == address(0)` on delegated entrypoints |
| `NotAContract()` | Constructor; wiring/staticcall targets without code |
| `WiringMismatch()` | `_requireCanonicalHelperWiring` or Furnace/delegation hub bundle disagreement |
| `NotAuthorized()` | Delegation checks; `user == msg.sender` on delegated entrypoints |

Underlying `ShareholderRoyalties` / `MineCore` / `DelegationHub` may revert with their own errors; only the king withdraw leg in `claimAll` / `claimAllFor` is caught and ignored.
