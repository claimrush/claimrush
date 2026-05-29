# ClaimAllHelper (bundle + delegated Collect)

`ClaimAllHelper` is a stateless orchestration helper that bundles common Collect actions (Barons ETH + King ETH fallback) into a single transaction and provides delegation-gated wrappers for bots. It does not change economics or custody funds. In the [CLAIM stream](protocol-overview.md), this is the bundling layer for collecting earned ETH in one call.

> **TL;DR:** `claimAll(mode, targetTokenId, durationSeconds, createAutoMax, minVeOut)` bundles Baron Collect + King-bucket withdraw for the caller. `claimAllForUser(...)` runs the same on behalf of an opted-in user via a DelegationHub session. The helper holds no funds and adds no new reward logic.

## Public API

| Function | Caller | Purpose |
|---|---|---|
| `claimAll(mode, targetTokenId, durationSeconds, createAutoMax, minVeOut)` | user | Bundle Baron Collect (`mode=0/1`) + best-effort King-bucket withdraw. |
| `claimAllForUser(user, mode, targetTokenId, durationSeconds, createAutoMax, minVeOut)` | delegate | Same, gated by the relevant DelegationHub permission bits. |
| `withdrawKingBalanceForUser(user)` | delegate | Pull King bucket only; needs `P_WITHDRAW_KING_BUCKET_FOR`. |
| `claimShareholderForUser(user, mode, ...)` | delegate | Pull Baron ETH only; needs the corresponding Collect / Compound permission bits. |

## Why a helper exists
- bundle common **Collect** actions into a single transaction
- provide **delegation-gated wrappers** for bots (via DelegationHub)

It does **not**:
- change economics
- custody funds
- introduce new reward logic

Source of truth: `src/ClaimAllHelper.sol`.

## Helper-only entrypoints

Two protocol contracts expose helper-only entrypoints:
- `ShareholderRoyalties.claimShareholderFor(user, ...)` is `onlyClaimAllHelper`
- `MineCore.withdrawKingBalanceFor(user)` is `onlyClaimAllHelper`

These entrypoints let an EOA (or bot) call ClaimAllHelper, while the helper calls into those contracts in a way that preserves protocol invariants.

## Public surface

### Bundle for the caller

`claimAll(mode, targetTokenId, durationSeconds, createAutoMax, minVeOut)`

What it does:
1. Collects Barons ETH for the caller via `ShareholderRoyalties.claimShareholderFor(msg.sender, ...)`
2. Withdraws the caller's King ETH fallback bucket via `MineCore.withdrawKingBalanceFor(msg.sender)`

Mode values match ShareholderRoyalties for the **caller bundle** only:
- `mode = 0` ETH (Collect ETH)
- `mode = 1` LOCK_FURNACE (Collect & Lock)

The delegation-gated wrappers (`claimShareholderForUser`, `claimAllFor`) accept the same arity for ABI parity but enforce **`mode == 0` only**. Any non-zero `mode` reverts `NotAuthorized` once the delegation gate clears, so a delegate can never spend the user's shareholder ETH on a fresh veCLAIM lock through these paths.

Important behavior:
- The helper is **nonpayable**.
- If the Barons Collect leg reverts (example: locking paused in mode=1), the whole bundle reverts and the King bucket is not withdrawn.
- The King ETH withdraw leg is best-effort but **selective**, not a blanket try/catch. The helper invokes `MineCore.withdrawKingBalanceFor(user)` via a low-level call and inspects the 4-byte revert selector:
  - **Selector matches `Errors.EthTransferFailed`** (the recipient rejected ETH): the helper emits `Events.KingWithdrawalFailed(user, reason)` and the bundle still succeeds with the Barons payout. The first 128 bytes of revert data are preserved in `reason` for indexers.
  - **Any other revert** (`WiringMismatch`, `ZeroAddress`, `nonReentrant` re-entry, an unrelated downstream revert, etc.): the helper rethrows the original revert verbatim and the **whole bundle reverts** — Barons payout is also rolled back by the EVM.
  - Zero King balance is a silent no-op inside MineCore (`kingEthBalance[user] == 0` returns early without reverting), not a failure path.
- The two legs are **not** symmetric: Barons failure is always fatal; King failure is best-effort **only for the specific ETH-rejection case**.

Tested-control note (recovery semantic):
- The `EthTransferFailed`-only swallow + recoverable-balance shape is asserted by `testClaimAllPartialFailureLeavesKingBalanceRecoverable` (caller bundle) and `testClaimAllForDelegatedPartialFailureLeavesKingBalanceRecoverable` (delegated bundle). Both run a first call with the King ETH transfer rejected, assert the Barons leg lands and zero successful King withdrawals were recorded, then run a second call once the ETH transfer path is restored and assert the King leg lands for the original target.
- The unconditional bubble-up of any non-`EthTransferFailed` revert is asserted by `testClaimAllBubblesUnexpectedMineCoreRevert_NoPartialClaims` (caller bundle) and `testClaimAllForDelegatedBubblesUnexpectedMineCoreRevert_NoPartialClaims` (delegated bundle). Both assert the Barons leg is rolled back when the King leg reverts with anything other than `Errors.EthTransferFailed`.

### Delegation-gated wrappers

These methods are for bots acting on behalf of `user`.

| Method | What it does | Required permission | Notes |
|---|---|---|---|
| `claimShareholderForUser(user, ...)` | Barons Collect for `user` | `P_CLAIM_SHAREHOLDER_FOR` | ETH-only (`mode == 0`); any non-zero `mode` reverts `NotAuthorized`. |
| `withdrawKingBalanceForUser(user)` | Withdraw King ETH bucket for `user` | `P_WITHDRAW_KING_BUCKET_FOR` | — |
| `claimAllFor(user, ...)` | Bundle: Barons Collect + King bucket withdraw | `P_CLAIM_ALL_FOR` | ETH-only (`mode == 0`); any non-zero `mode` reverts `NotAuthorized`. |

All three delegated wrappers reject self-calls: `if (user == msg.sender) revert NotAuthorized()`. A delegate cannot use these wrappers to act on themselves — call the non-delegated `claimShareholder` / `withdrawKingBalance` / `claimAll` (caller-bundle) paths instead.

Why ETH-only on delegated paths:
- A `DelegationHub` permission bit grants a bot the right to settle the user's earned shareholder ETH; it does not grant the right to lock that ETH into a fresh veCLAIM position on the user's behalf. Routing the payout into Furnace would convert a Collect into a position-creating operation the delegate was never authorized to perform.
- LOCK_FURNACE Collect remains user-direct via `ShareholderRoyalties.claimShareholder(mode = 1, ...)`. The delegated rail covers ETH payouts only.

Authorization model:
- ClaimAllHelper has no standalone hub pointer. Delegated wrappers resolve authority from the live `MineCore` / `ShareholderRoyalties` / shared `Furnace` bundle.
- For every delegated helper path, the helper first requires:
  - `MineCore.claimAllHelper() == address(this)`
  - `MineCore.royalties() == royalties`
  - `ShareholderRoyalties.claimAllHelper() == address(this)`
  - `ShareholderRoyalties.mineCore() == mineCore`
  - `MineCore.furnace() == ShareholderRoyalties.furnace()`
  - `Furnace.mineCore() == mineCore`
  - `Furnace.shareholderRoyalties() == royalties`
  - `Furnace.delegationHub() == MineCore.delegationHub()`
- `withdrawKingBalanceForUser(...)` fails closed on any MineCore/Furnace hub drift; it does not trust a raw `MineCore.delegationHub()` read in isolation.
- `claimShareholderForUser(...)` and `claimAllFor(...)` use that same canonical-hub preflight, so split-brain `MineCore.furnace()` vs `ShareholderRoyalties.furnace()` wiring is rejected before authorization.

On success, delegated wrappers emit:
- `Events.DelegationSessionUsed(user, delegate, actionTypeId, permsUsed, refId=0, timestamp)`

`actionTypeId` values (v1.0.0):
- 10 = `CLAIM_SHAREHOLDER_FOR`
- 11 = `WITHDRAW_KING_BUCKET_FOR`
- 12 = `CLAIM_ALL_FOR`

## Integrator notes

### Computing `minVeOut` (mode = LOCK_FURNACE)

ClaimAllHelper does not compute slippage bounds for you.

For Collect & Lock:
1. Quote via FurnaceQuoter (resolve address from `furnace.furnaceQuoter()`):
   - `furnaceQuoter.quoteEnterWithEth(user, ethIn, targetTokenId, durationSeconds, quoteCreateAutoMax)`
2. Convert quote to min-out:
   - `minVeOut = floor(veOut * (10_000 - slippageBps) / 10_000)`
   - `veOut` here covers only the newly locked amount at the lock's remaining duration; entry into an existing lock does not change its duration.
   - If `veOut > 0` but floor-rounding would produce `minVeOut == 0`, clamp to `1` before calling a Furnace entry path.

Use the same approach whether you call:
- `ShareholderRoyalties.claimShareholder(...)` directly, or
- ClaimAllHelper bundle methods.

### Locking pause behavior

If `Furnace.lockingPaused == true`:
- any path that uses mode `LOCK_FURNACE` will revert
- mode `ETH` (Collect ETH) still works

### UX recommendations

- Keep the UI verb **Collect** for ETH payouts.
- Only expose ClaimAllHelper if you actually need bundling or delegated wrappers.
  - Many apps can call `claimShareholder` and `withdrawKingBalance` separately.

## Operator notes

The remaining section covers deploy-time wiring. Integrators can skip unless instrumenting governance flows.

### Wiring

ClaimAllHelper is deployed as its own contract.

It is constructed with immutable pointers to:
- `ShareholderRoyalties` (Barons ETH)
- `MineCore` (King ETH fallback bucket)

Deployment hardening + runtime safety:
- both constructor addresses must be nonzero contract addresses
- every public path first verifies the canonical back-links it depends on:
  - `MineCore.claimAllHelper() == address(this)`
  - `MineCore.royalties() == royalties`
  - `ShareholderRoyalties.claimAllHelper() == address(this)`
  - `ShareholderRoyalties.mineCore() == mineCore`
- helper wiring changes use helper redeployment and updates to both core contracts via the timelocked owner
- `setClaimAllHelper` is gated by `whenNotFrozen` on both MineCore and ShareholderRoyalties — after the freeze-and-burn ceremony, the helper pointer is permanently locked and redeployment is no longer possible (Security page status: Redeploy → No)

Addresses come from `deployments/<network>.json`.

## See also

- [ShareholderRoyalties (Barons)](shareholderroyalties-barons.md) — royalty distribution mechanics
- [Bot Sessions (DelegationHub)](delegationhub.md) — delegated collect permissions
- [Furnace](furnace.md) — lock entry for Collect & Lock mode
- Tutorial: [Collect Barons ETH or Collect & Lock](tutorials/collect-barons-eth-or-lock.md)
- User manual: [Overview](https://docs.claimru.sh/overview)
