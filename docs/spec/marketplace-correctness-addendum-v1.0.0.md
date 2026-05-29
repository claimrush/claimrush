# Listing correctness addendum (v1.0.0)

This addendum captures the safety-critical rules for `MarketRouter` listing clears and sell-to-Furnace flows.

## 1. Double-sale prevention

A single veCLAIM lock must never be sellable twice.

Relevant sale paths:
- `sellListedLockToFurnace`
- `sellLockToFurnace`

Required rule:
- Any path that consumes a lock or clears a listing must clear MarketRouter listing state first.
- If the lock was listed, the path must also clear `VeClaimNFT.setListed(tokenId, false)` before transferring ownership into Furnace custody.

"Clear listing state" means:
- mark the listing inactive
- remove the token from the seller's active-listings index
- preserve 1-block relist protection for seller-controlled listing state changes

Event expectations:
- listed settlement emits `ListingSettled(tokenId, seller, claimOut, penalty)`
- direct sell-now that auto-clears a listing emits `LockDelisted(tokenId, seller, SOLD_TO_FURNACE)`
- strict-mode MarketRouter never emits `LockDelisted(..., APPROVAL_REVOKED)`; reason code `5` is a reserved compatibility analytics value
- expired listing unwind emits `LockDelisted(tokenId, seller, EXPIRED)`

Keeper-grace note:
- strict-mode MarketRouter does not have an approval-revoked path that bypasses keeper-grace auth.

## 2. Checkpoint and custody-transfer ordering

For any flow that moves a lock into Furnace custody, the safety-critical ordering is:

1. clear MarketRouter listing state
2. clear the VeClaimNFT listed flag if the lock was listed
3. call `ShareholderRoyalties.checkpointTransfer(seller, furnace)`
4. transfer ownership into Furnace custody
5. let Furnace execute burn, payout, reserve updates, and LP-sale accounting

The strict requirement is:
- `checkpointTransfer(seller, furnace)` must happen before ownership transfer, meaning before the seller loses the lock.
- The `furnace` used for checkpoint + custody transfer must be the canonically wired Furnace resolved from `ve.furnace()` and cross-checked against `ShareholderRoyalties`, `MineCore`, `ClaimToken`, and `VeClaimNFT`.

It does **not** need to happen before every ve-adjacent bit flip.
Clearing `listed = false` before checkpoint is acceptable because `listed` is only a mutation guard and does not change shareholder balances.

## 3. Accounting responsibility split

MarketRouter responsibilities:
- listing / offer state management
- price-floor and pause checks
- keeper-grace enforcement
- checkpoint before custody transfer
- ownership transfer into Furnace custody
- market-layer events

Furnace responsibilities after custody transfer:
- execute sellback math
- burn or withdraw the lock
- pay the seller
- credit reserve and LP-sale accounting

Therefore:
- docs must not describe listing settlement as if MarketRouter directly transfers reserve penalty and seller payout itself
- the penalty surfaced on `ListingSettled` is the duration-based deduction represented as `lockAmount - claimOut`

## 4. Summary

1. No user-to-user lock sales.
2. Furnace is the only counterparty and execution engine for sellbacks.
3. Listings must be cleared before the lock can be consumed.
4. `checkpointTransfer` is required before custody transfer, not before every ve-related guard flag change.
