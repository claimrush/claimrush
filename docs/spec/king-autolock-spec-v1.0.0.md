# King auto-lock into Furnace (optional) — ClaimRush v1.0.0 extension

This document specifies an **optional** feature: a King may opt-in to automatically lock their **King-stream mined CLAIM**
into the Furnace at reign finalization, receiving the same Furnace bonus/reserve accounting as a normal `enterWithClaim(...)`.

Status in this repo:
- Storage + config functions + config event are implemented.
- Takeover execution path wiring (best-effort) is implemented.

## Goals

When enabled for a King:

- At reign finalization, the King-stream mined CLAIM that would normally be minted directly to the dethroned King
  is instead routed through the Furnace entry flow so the King receives:
  - the Furnace bonus (from Furnace reserve),
  - and a veCLAIM lock (top-up existing lock or create a new lock).

Constraints:

- Opt-in per user, off by default.
- Safe: no third party can force-lock for someone else.
- No stealing: the King must either receive the ve lock or receive the liquid CLAIM.
- Gas bounded: no unbounded loops; must not add O(n) work to takeovers.

## Protocol preconditions

- `Furnace.enterWithClaimFor(...)` MUST allow `MineCore` as an allowlisted caller so MineCore can route
  King-stream mined CLAIM through the canonical Furnace entry flow (and receive the exact same bonus math).

## User configuration UX

A user configures King auto-lock via `MineCore.setKingAutoLockConfig(...)`.

Fields:

- `enabled` (bool)
  - Default: false.
- `targetTokenId` (uint256)
  - `0` = create-once mode.
  - `!= 0` = top-up existing veNFT lock.
- `durationSeconds` (uint32)
  - Create-once mode (`targetTokenId == 0`): required and MUST be within `[MIN_LOCK_DURATION, MAX_LOCK_DURATION]`.
  - Existing lock mode (`targetTokenId != 0`):
    - `0` means "use current remaining duration" (no additional extension unless clamped).
    - otherwise treated as a minimum duration (MineCore will pass `max(durationSeconds, remaining)` to Furnace).
    - The target lock MUST retain at least `KING_FORCE_LOCK_MIN_DURATION` of remaining duration
      (equal to `MAX_LOCK_DURATION`), or be an AutoMax lock. The force-locked slice is never
      extended when routed into an existing lock, so a shorter target would let ~100% of the slice
      become liquid within that lock's remaining window — defeating the anti-recycling horizon the
      50% liquid clamp assumes. A target that fails this check is rejected and settlement falls back
      to the default create-once AutoMax lock. This bound is distinct from `MIN_LOCK_DURATION`, which
      applies to ordinary user entries.
- `createAutoMax` (bool)
  - Only meaningful in create-once mode (`targetTokenId == 0`).
  - If true, `durationSeconds` MUST equal `MAX_LOCK_DURATION` (VeClaimNFT autoMax semantics).
- `minVeOut` (uint256)
  - Slippage guard passed through to Furnace (best-effort execution).
  - Stored `minVeOut = 0` is treated as a sentinel meaning “no extra floor”; MineCore clamps it to `1` before calling Furnace because `Furnace.enter*` rejects zero `minVeOut`.
  - If the Furnace execution would still revert (including `MinVeOutNotMet`), MineCore falls back to minting liquid CLAIM.

Create-once behavior (anti "too many veNFTs"):

- In create-once mode, the first successful auto-lock creates a new veNFT and MineCore stores it in `pinnedTokenId`.
- Subsequent dethronements top up that pinned lock (no new veNFTs).
- The pinned lock id is preserved even if the user switches to an explicit destination lock.
  - Disable (`enabled=false`) to clear the pinned lock and allow a new create-once lock to be created.
- If the pinned lock becomes invalid (expired, transferred, listed), MineCore skips auto-lock and mints liquid CLAIM
  until the user reconfigures.

## Onchain storage

`MineCore` stores, per user:

```
struct KingAutoLockConfig {
  bool enabled;
  bool createAutoMax;
  uint32 durationSeconds;
  uint256 targetTokenId;
  uint256 pinnedTokenId;
  uint256 minVeOut;
}
mapping(address => KingAutoLockConfig) kingAutoLockConfig;
```

## Events (analytics/UI)

- `Events.KingAutoLockConfigured(user, enabled, targetTokenId, pinnedTokenId, durationSeconds, createAutoMax, minVeOut)`

Execution events:

- `Events.KingAutoLockExecuted(reignId, user, principalClaim, tokenIdUsed)`
- `Events.KingAutoLockSkipped(reignId, user, principalClaim, reasonCode)`
- `Events.KingAutoLockFailed(reignId, user, principalClaim, revertData)`

Reason codes (`KingAutoLockSkipped.reasonCode`):
- `1` = `NOT_OWNER`
- `2` = `LISTED`
- `3` = `EXPIRED`
- `4` = `INVALID_TOKEN_ID`
- `0xFF` (`255`) = `INSUFFICIENT_GAS` — the auto-lock branch was skipped because `gasleft() < SETTLE_CLAIM_MIN_GAS` at the entry point of `_settlePrevKingClaim`. The CLAIM amount is minted as liquid CLAIM (or credited to the king's withdrawable bucket) and the takeover proceeds; this is an operational (not user-error) skip, and the reign finalisation remains well-formed.

### Gas reserves (operational)

MineCore uses two internal gas constants during auto-lock settlement; wallets and bots that estimate takeover gas MUST account for both (values below are the shipped v1.0.0 settings):

- `SETTLE_CLAIM_MIN_GAS = 1_200_000` — minimum `gasleft()` required to even attempt the auto-lock branch; below this, the code short-circuits to liquid CLAIM and emits `KingAutoLockSkipped(..., 0xFF)`.
- `SETTLE_CLAIM_ENTER_RESERVE_GAS = 500_000` — budget retained for the outer `catch` block and the remainder of `_executeTakeover` (new-reign SSTOREs, `ReignRecipientsSet`/`Takeover`/`DelegationSessionUsed` events, hybrid refund). Subtracted from `gasleft()` when forwarding to `Furnace.enterWithClaimFor`.

Rationale: these values are sized above the measured cost of the full auto-lock branch plus the finalisation tail, so a takeover that enters auto-lock always has sufficient budget to finalise regardless of sub-call outcome.

`KingAutoLockFailed.revertData` decoding notes (shipped v1.0.0):
- pre-call fail-closed path with no wired Furnace: `abi.encodeWithSelector(Errors.ZeroAddress.selector)`
- pre-call fail-closed path with stale / split-brain Furnace wiring: `abi.encodeWithSelector(Errors.WiringMismatch.selector)`
- if the downstream Furnace call itself reverts, MineCore captures bounded revert data (up to 128 bytes via `_boundedRevertData()`) and emits it in `KingAutoLockFailed.revertData`, then falls back to liquid CLAIM

Note: The underlying Furnace entry emits `Events.FurnaceEnter(user, mode, ethIn, principalClaim, bonusClaim, tokenId)`
so indexers can recover the exact `bonusClaim` paid during auto-lock execution.

## Takeover execution flow (high level)

At reign finalization, MineCore:

1. Computes King-stream mined CLAIM for the dethroned King.
2. If the dethroned King has auto-lock enabled and Furnace is wired:
   - Mint that CLAIM to MineCore (not to the user yet).
   - Approve Furnace and call `Furnace.enterWithClaimFor(user, amount, ...)`.
   - If successful: the user receives a ve lock with the Furnace bonus.
   - If it fails for any reason: MineCore falls back to paying the same CLAIM amount as liquid CLAIM.
   - **Existing-lock mode (non-AutoMax):** if the resolved destination lock’s remaining time is `< KING_FORCE_LOCK_MIN_DURATION` (equal to `MAX_LOCK_DURATION`), MUST **not** call Furnace; treat as skip with `KingAutoLockSkipped` and `reasonCode = INVALID_DURATION` (same liquid-CLAIM fallback as other skips). The force-lock slice is never extended, so only a full-duration or AutoMax destination preserves the anti-recycling horizon; anything shorter falls back to the default create-once AutoMax lock.
3. Always emits the existing `ReignFinalized` event with `totalClaimMined` equal to the principal King-stream emission.
