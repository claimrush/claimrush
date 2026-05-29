# Vault spec (v1.0.0): Genesis LP lock vault

This document specifies `GenesisLPVault24M`, the **genesis LP lock vault**.

It is genesis infrastructure deployed and wired during `LaunchController.finalizeGenesis()`.

## Scope

- LP custody + time lock (24 months)
- Fixed-recipient withdrawal after unlock
- Recipient-only lock extension (never shorten)

Not part of v1.0.0:
- Any generic admin sweep/rescue function (see [MUST NOT scope](#must-not-scope) below for the bounded exception around Aerodrome trading-fee forwarding inside `withdrawLp()`).

---

## Responsibilities

`GenesisLPVault24M` MUST:
- Custody the canonical Aerodrome v2 WETH/CLAIM volatile pool LP token minted at genesis.
- Enforce a **24 month** lock (`INITIAL_LOCK_DURATION = 730 days`).
- After unlock, allow LP withdrawal only to a fixed recipient address: `lpWithdrawRecipient`.
- Allow `lpWithdrawRecipient` to extend the lock to a later unlock time (never shorten).
- On `withdrawLp()`, claim accumulated Aerodrome trading fees via `pool.claimFees()` and forward the resulting `token0` + `token1` balances to `lpWithdrawRecipient` in the same transaction, **before** the LP transfer (see `withdrawLp()` below for ordering and best-effort semantics).

<a id="must-not-scope"></a>
`GenesisLPVault24M` MUST NOT:
- Allow withdrawing LP before `unlockTime`.
- Allow redirecting withdrawn LP to any address other than `lpWithdrawRecipient`.
- Include any generic admin sweep/rescue. The `withdrawLp()` fee-forwarding step is **not** a generic sweep: (a) the source is bounded to `pool.claimFees()` only — no arbitrary token can be moved; (b) the destination is fixed to immutable `lpWithdrawRecipient`; (c) the value extracted is fees that the vault's own LP position earned over the 24-month lock, which Aerodrome v2 holds in per-LP-holder `claimable0/1` slots separate from pool reserves and which would otherwise be permanently stranded against the vault's address after the LP transfer.

---

## Constants

- `INITIAL_LOCK_DURATION = 730 days` (24 months)
- `MAX_EXTENSION = 3650 days` (10 years forward cap from current timestamp)
- `MAX_ABSOLUTE_LOCK = 36500 days` (100 years absolute cap from `lockStartTime`)
- `MIN_LP_LOCK = 1e15` (dust-lock griefing guard)
- `MIN_EXTENSION_DURATION = 1 days` (minimum meaningful extension)

---

## State

Immutable wiring:
- `pool`: Aerodrome pool address (also the LP token)
- `lpWithdrawRecipient`: fixed LP withdrawal recipient

Lock state:
- `lockStartTime`: timestamp when `startLock()` was successfully called
- `unlockTime`: timestamp after which LP is withdrawable
- `lpLockedAmount`: LP amount observed when the lock was started (snapshot; MUST remain readable after withdrawal)

---

## startLock() (permissionless, one-shot)

Preconditions (MUST revert):
- `lockStartTime == 0` (one-shot)
- Vault holds LP: `IERC20(pool).balanceOf(address(this)) > 0`
  - **Implementation note:** the deployed contract uses a stricter `MIN_LP_LOCK = 1e15` guard (instead of `> 0`) to prevent dust-lock griefing.

Behavior (MUST):
- Set `lockStartTime = block.timestamp`
- Set `unlockTime = block.timestamp + INITIAL_LOCK_DURATION`
- Set `lpLockedAmount = current LP balance`
- Emit `Locked(lpLockedAmount, lockStartTime, unlockTime)`

---

## extendLock(newUnlockTime) (recipient-only)

Caller restriction (MUST):
- Only `lpWithdrawRecipient`.

Preconditions (MUST revert):
- `lockStartTime != 0` (lock started)
- `unlockTime != 0` (lock not already withdrawn; prevents re-enabling a spent lock)
- `newUnlockTime > unlockTime` (strictly increasing)
- `newUnlockTime <= block.timestamp + MAX_EXTENSION` (prevents permanent brick; MAX_EXTENSION = 3650 days)
- `newUnlockTime <= lockStartTime + MAX_ABSOLUTE_LOCK` (absolute ceiling; MAX_ABSOLUTE_LOCK = 36500 days)
- `newUnlockTime >= block.timestamp + MIN_EXTENSION_DURATION` (reject trivially short extensions and past timestamps with `ExtensionTooShort`; MIN_EXTENSION_DURATION = 1 day)

Behavior (MUST):
- Set `unlockTime = newUnlockTime`
- Emit `LockExtended(oldUnlockTime, newUnlockTime)`

---

## withdrawLp() (recipient-only, destination-fixed)

> **Constraint:** Recipient-only withdrawal prevents adversarial
> post-unlock LP ejection. The fixed recipient eliminates griefing vectors
> where a third party triggers withdrawal to an unintended destination.

Preconditions (MUST revert):
- `lockStartTime != 0` (lock must have been started; otherwise `unlockTime` is 0 and the check below would pass immediately, bypassing the time-lock)
- `block.timestamp >= unlockTime`

Behavior (MUST), in canonical CEI order:
1. **State writes first.** Clear `unlockTime = 0` (single-use marker; see `lpLockedAmount` clarification below).
2. **Claim Aerodrome trading fees.** Call `pool.claimFees()` from the vault's own address inside a `try/catch`. Aerodrome v2 settles per-LP-holder `claimable0/1` accruals into the caller's ERC20 balance — i.e. into the vault. The `try/catch` is a best-effort guard: if `pool.claimFees()` reverts, `withdrawLp()` MUST still succeed and forward the LP. Fees may be stranded in that edge case, but LP recovery MUST NOT be blocked.
3. **Forward both fee tokens.** Read `pool.token0()` and `pool.token1()` (Aerodrome-immutable), each inside its own `try/catch`. For each token, if the vault's balance is non-zero, `safeTransfer` the full balance to `lpWithdrawRecipient`. If either selector reverts (e.g. a misconfigured non-Aerodrome pool address) the helper MUST return early without forwarding — fee identification is not possible — and `withdrawLp()` MUST still succeed and forward the LP.
4. **Emit `FeesClaimedAndForwarded(token0, token1, amount0, amount1)`** if at least one of the forwarded amounts is non-zero. The event MUST precede the corresponding `WithdrawLp` event in the same transaction.
5. **Transfer all LP** held by the vault to `lpWithdrawRecipient` and emit `WithdrawLp(lpWithdrawRecipient, amount)`.
6. MUST NOT clear `lpLockedAmount`; it is the recorded amount observed at `startLock()`.

The full flow is wrapped in `nonReentrant`.

Clarification (non-binding):
- Emitting `WithdrawLp(lpWithdrawRecipient, 0)` when the vault holds no LP is acceptable.
- The same fee-claim-and-forward step (steps 2–4 above) MUST also run in the residual-LP branch (post-withdraw `unlockTime == 0`, residual LP arrived after the canonical withdrawal).

---

## Events (REQUIRED)

The vault MUST emit:
- `Locked(uint256 lpAmount, uint256 lockStartTime, uint256 unlockTime)`
- `LockExtended(uint256 oldUnlockTime, uint256 newUnlockTime)`
- `WithdrawLp(address indexed to, uint256 amount)` (emitted by the canonical post-unlock branch of `withdrawLp()`)
- `ResidualLpSwept(address indexed to, uint256 amount)` (emitted by the residual-LP branch of `withdrawLp()` — fired when `withdrawLp()` is re-invoked after the canonical withdrawal already cleared `unlockTime` and additional LP has since arrived at the vault)
- `FeesClaimedAndForwarded(address indexed token0, address indexed token1, uint256 amount0Forwarded, uint256 amount1Forwarded)` (emitted by both branches of `withdrawLp()` when at least one of the forwarded amounts is non-zero; always precedes the corresponding `WithdrawLp` or `ResidualLpSwept` event in the same transaction)
- `TokenRescued(address indexed token, address indexed to, uint256 amount)` (emitted by `rescueEth()`)
