# GenesisLPVault24M implementer checklist (v1.0.0)

This is an **implementer-focused checklist** for the genesis LP lock vault (`GenesisLPVault24M`).

Source of truth:
- Contract spec (canonical): `docs/spec/vault-spec.md`
- Genesis orchestration: `docs/spec/launch-controller-spec-v1.0.0.md`
- Aerodrome integration: [Aerodrome integration appendix](../architecture/aerodrome-integration-appendix-v1.0.0.md)

Spec aids (recommended):
- `docs/spec/spec-quality-standard-v1.0.0.md`
- `docs/spec/state-machines-v1.0.0.md`
- `docs/spec/test-vectors-v1.0.0.md`

This document **does not introduce new rules**. It restates MUST/MUST NOT requirements in an order suitable for incremental implementation and review.

---

## Goals

GenesisLPVault24M MUST:
- Custody the canonical Aerodrome v2 WETH/CLAIM volatile pool LP token minted at genesis.
- Enforce a **24 month** lock (`INITIAL_LOCK_DURATION = 730 days`).
- After unlock, allow LP withdrawal only to a fixed recipient address: `lpWithdrawRecipient`.
- Allow the lock to be extended to a later unlock time (never shortened), callable only by `lpWithdrawRecipient`.
- On `withdrawLp()`, claim accumulated Aerodrome trading fees via `pool.claimFees()` and forward the resulting `token0` + `token1` balances to `lpWithdrawRecipient` in the same transaction, **before** the LP transfer (Aerodrome v2 routes per-LP-holder fees to `claimable0/1` slots that would otherwise be permanently stranded against the vault's address after the LP transfer).

GenesisLPVault24M MUST NOT:
- Provide any generic admin sweep/rescue (bounded exceptions: `rescueEth()` recovers force-sent ETH only; the `withdrawLp()` fee-forwarding step is bounded to `pool.claimFees()` source + immutable `lpWithdrawRecipient` destination).
- Allow withdrawing LP before `unlockTime`.
- Allow redirecting withdrawn LP to any address other than `lpWithdrawRecipient`.
- Allow anyone other than `lpWithdrawRecipient` to call `withdrawLp()`.

---

## Checklist: required wiring (immutables / config)

From `vault-spec.md` (GenesisLPVault24M section).

Deploy GenesisLPVault24M with immutable references to:
- `pool` (Aerodrome v2 WETH/CLAIM volatile pool, also the LP token)
- `lpWithdrawRecipient` (fixed recipient of LP after unlock)

---

## Checklist: lock state variables

Expose (recommended for dashboards/indexers):
- `lockStartTime`
- `unlockTime`
- `lpLockedAmount` (snapshot of the amount observed at `startLock()`; do not clear it on withdrawal)

Rules:
- LP cannot be withdrawn before `unlockTime`.
- `extendLock` MUST be strictly increasing.
- `lpLockedAmount` MUST remain as the original `startLock()` snapshot even after LP withdrawal.

---

## Checklist: startLock() (permissionless, one-shot)

From `vault-spec.md` “startLock()”.

Preconditions (MUST revert):
- `lockStartTime == 0` (one-shot, reverts `LockAlreadyStarted`)
- Vault holds LP: `IERC20(pool).balanceOf(address(this)) > 0` (reverts `NoLp` when zero)
- Vault LP balance MUST satisfy `>= MIN_LP_LOCK = 1e15` (reverts `DustLock` for dust-lock griefing)

Steps (MUST):
- `lockStartTime = block.timestamp`
- `unlockTime = block.timestamp + INITIAL_LOCK_DURATION` (730 days)
- `lpLockedAmount = IERC20(pool).balanceOf(address(this))`
- Emit `Locked(lpLockedAmount, lockStartTime, unlockTime)`

---

## Checklist: extendLock(newUnlockTime) (recipient-only)

From `vault-spec.md` “extendLock(uint256 newUnlockTime)”.

Caller restriction (MUST):
- Only `lpWithdrawRecipient`.

Preconditions (MUST revert):
- `lockStartTime != 0`
- `unlockTime != 0` (lock not already withdrawn; prevents re-enabling a spent lock with `AlreadyWithdrawn`)
- `newUnlockTime > unlockTime` (never shorten)
- `newUnlockTime <= block.timestamp + MAX_EXTENSION` (prevents permanent brick with `ExtensionTooLong`)
- `newUnlockTime <= lockStartTime + MAX_ABSOLUTE_LOCK` (absolute ceiling with `ExtensionTooLong`)
- `newUnlockTime >= block.timestamp + MIN_EXTENSION_DURATION` (reject trivially short extensions and past timestamps with `ExtensionTooShort`)

Constants:
- `MAX_EXTENSION = 3650 days` (10 years) — maximum forward extension from current timestamp
- `MAX_ABSOLUTE_LOCK = 36500 days` (100 years) — absolute ceiling from `lockStartTime`
- `MIN_EXTENSION_DURATION = 1 days` — minimum meaningful extension beyond the current timestamp

Steps:
- `unlockTime = newUnlockTime`
- Emit `LockExtended(oldUnlockTime, newUnlockTime)`

---

## Checklist: withdrawLp() (recipient-only, destination-fixed)

From `vault-spec.md` “withdrawLp()”.

Preconditions (MUST revert):
- `msg.sender == lpWithdrawRecipient` (recipient-only access control)
- `lockStartTime != 0` (reverts `LockNotStarted`)
- Canonical post-unlock branch: `block.timestamp >= unlockTime` (reverts `UnlockTimeNotReached`)
- Residual-LP branch (`unlockTime == 0`): vault holds residual LP (reverts `AlreadyWithdrawn` when zero)

Rules (canonical post-unlock branch — `unlockTime != 0`, `block.timestamp >= unlockTime`):
- Read `amount = IERC20(pool).balanceOf(address(this))`.
- Revert with `Errors.NoLp()` if `amount == 0`.
- Clear `unlockTime = 0` (state write before external interactions — CEI).
- Run the **fee-claim-and-forward** helper (`_claimAndForwardPoolFees()` — see below).
- Transfer `amount` LP to `lpWithdrawRecipient`.
- Emit `WithdrawLp(lpWithdrawRecipient, amount)`.

Rules (residual-LP branch — `unlockTime == 0`, post-canonical-withdraw, more LP arrived since):
- Read `residual = IERC20(pool).balanceOf(address(this))`.
- Revert with `AlreadyWithdrawn` if `residual == 0`.
- Run the **same fee-claim-and-forward** helper.
- Transfer `residual` LP to `lpWithdrawRecipient`.
- Emit `ResidualLpSwept(lpWithdrawRecipient, residual)`.

The full flow is wrapped in `nonReentrant`.

Fee-claim-and-forward helper (`_claimAndForwardPoolFees()`), best-effort semantics:
- Wrap `pool.claimFees()` in `try/catch` — a misbehaving pool MUST NOT DoS LP recovery; settled balances proceed if available, otherwise zero is treated as "no fees this withdrawal".
- Read `pool.token0()` and `pool.token1()` (Aerodrome-immutable), each in its own `try/catch`. If either selector reverts (e.g. the `pool` address is wired to a non-Aerodrome contract by mistake), the helper MUST return early without forwarding — fee identification is not possible — and `withdrawLp()`'s subsequent LP transfer still runs.
- For each token, if the vault's balance is non-zero, `safeTransfer` the full balance to `lpWithdrawRecipient`.
- Emit `FeesClaimedAndForwarded(token0, token1, amount0Forwarded, amount1Forwarded)` if at least one of the forwarded amounts is non-zero. The event MUST precede the corresponding `WithdrawLp` (canonical) or `ResidualLpSwept` (residual) event in the same transaction.

---

## Checklist: events (REQUIRED)

From `vault-spec.md` events list.

MUST emit:
- `Locked(lpAmount, lockStartTime, unlockTime)`
- `LockExtended(oldUnlockTime, newUnlockTime)`
- `WithdrawLp(to, amount)` (canonical post-unlock branch)
- `ResidualLpSwept(to, amount)` (residual-LP branch)
- `FeesClaimedAndForwarded(token0, token1, amount0Forwarded, amount1Forwarded)` (both branches; emitted only when at least one forwarded amount is non-zero; always precedes the corresponding `WithdrawLp` / `ResidualLpSwept` in the same transaction)
- `TokenRescued(address token = 0, address to = lpWithdrawRecipient, uint256 amount)` (emitted by `rescueEth()`)
