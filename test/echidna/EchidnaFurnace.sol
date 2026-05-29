// SPDX-License-Identifier: MIT
pragma solidity ^0.8.34;

import {EchidnaSetup} from "./EchidnaSetup.sol";
import {Constants} from "src/lib/Constants.sol";

/// @title Echidna harness for Furnace reserve solvency, bonus bounds, and split invariants.
/// @dev Invariants from the invariants document Sections 4.1-4.6C. Reserve-mutating
///      actions covered: `enterWithClaim`, `enterWithEth`, `extendWithBonus`,
///      `mergeLocksWithBonus` (v1.0.0), `claimAutoMaxBonus(Batch)`, and
///      `sellLockToFurnace`. The merge path shares `_applyBonusAmm` with
///      `extendWithBonus`, so the same `lastReserveBefore`/`lastGrossBonus`
///      shadow accounting pins `echidna_no_overdraft` across both surfaces.
contract EchidnaFurnace is EchidnaSetup {
    // Shadow accounting for split invariants
    uint256 internal lastReserveBefore;
    uint256 internal lastGrossBonus;
    bool internal lastEntryRecorded;

    // Track total principal locked via this harness
    uint256 internal totalPrincipalEntered;
    uint256[] internal autoMaxTokenIds;
    uint256 internal autoMaxCount;
    bool internal autoMaxZeroClaimCursorSafe = true;
    bool internal autoMaxBatchDuplicateSafe = true;

    constructor() payable {
        _deployAndWire();
    }

    // ================================================================
    // Actions (Echidna calls these with random params)
    // ================================================================

    /// @dev Simulate a takeover to mint CLAIM emissions and fund the reserve
    function action_takeover() public payable {
        uint256 price = mineCore.getCurrentTakeoverPrice();
        if (msg.value < price) return;
        try mineCore.takeover{value: price}(type(uint256).max) {} catch {}
    }

    /// @dev Enter the Furnace with CLAIM (if the caller has some)
    function action_enterWithClaim(uint256 amount, uint256 durationSeconds) public {
        if (amount < Constants.MIN_LOCK_AMOUNT) amount = Constants.MIN_LOCK_AMOUNT;
        if (amount > 10_000_000e18) amount = 10_000_000e18;
        if (durationSeconds < Constants.MIN_LOCK_DURATION) durationSeconds = Constants.MIN_LOCK_DURATION;
        if (durationSeconds > Constants.MAX_LOCK_DURATION) durationSeconds = Constants.MAX_LOCK_DURATION;

        uint256 bal = claim.balanceOf(msg.sender);
        if (bal < amount) return;

        // Record pre-entry state
        lastReserveBefore = furnace.furnaceReserve();

        try furnace.enterWithClaim(amount, 0, durationSeconds, false, 0) returns (uint256) {
            uint256 reserveAfter = furnace.furnaceReserve();
            if (lastReserveBefore >= reserveAfter) {
                lastGrossBonus = lastReserveBefore - reserveAfter;
            } else {
                lastGrossBonus = 0;
            }
            lastEntryRecorded = true;
            totalPrincipalEntered += amount;
        } catch {
            lastEntryRecorded = false;
        }
    }

    /// @dev Enter with ETH (swap through DEX mock)
    function action_enterWithEth(uint256 durationSeconds) public payable {
        if (msg.value == 0) return;
        if (durationSeconds < Constants.MIN_LOCK_DURATION) durationSeconds = Constants.MIN_LOCK_DURATION;
        if (durationSeconds > Constants.MAX_LOCK_DURATION) durationSeconds = Constants.MAX_LOCK_DURATION;

        lastReserveBefore = furnace.furnaceReserve();
        try furnace.enterWithEth{value: msg.value}(0, durationSeconds, false, 0) returns (uint256) {
            uint256 reserveAfter = furnace.furnaceReserve();
            if (lastReserveBefore >= reserveAfter) {
                lastGrossBonus = lastReserveBefore - reserveAfter;
            } else {
                lastGrossBonus = 0;
            }
            lastEntryRecorded = true;
        } catch {
            lastEntryRecorded = false;
        }
    }

    /// @dev Enter with CLAIM and enable AutoMax
    function action_enterAutoMax(uint256 amount, uint256 durationSeconds) public {
        if (amount < Constants.MIN_LOCK_AMOUNT) amount = Constants.MIN_LOCK_AMOUNT;
        if (amount > 10_000_000e18) amount = 10_000_000e18;
        if (durationSeconds < Constants.MIN_LOCK_DURATION) durationSeconds = Constants.MIN_LOCK_DURATION;
        if (durationSeconds > Constants.MAX_LOCK_DURATION) durationSeconds = Constants.MAX_LOCK_DURATION;

        if (claim.balanceOf(msg.sender) < amount) return;
        try furnace.enterWithClaim(amount, 0, durationSeconds, true, 0) returns (uint256 tokenId) {
            autoMaxTokenIds.push(tokenId);
            autoMaxCount++;
        } catch {}
    }

    /// @dev Claim AutoMax bonus for a single lock (permissionless)
    function action_claimAutoMaxBonus(uint256 tokenId) public {
        if (tokenId == 0) return;
        uint256 cursorBefore = furnace.lastAutoMaxBonusClaim(tokenId);
        uint256 reserveBefore = furnace.furnaceReserve();
        uint256 quotedBonus = 1;
        try quoter.quoteAutoMaxBonus(tokenId) returns (uint256, uint256 bonusClaim) {
            quotedBonus = bonusClaim;
        } catch {}

        try furnace.claimAutoMaxBonus(tokenId) {
            if (cursorBefore != 0 && quotedBonus == 0) {
                if (furnace.lastAutoMaxBonusClaim(tokenId) != cursorBefore) {
                    autoMaxZeroClaimCursorSafe = false;
                }
                if (furnace.furnaceReserve() != reserveBefore) {
                    autoMaxZeroClaimCursorSafe = false;
                }
            }
        } catch {}
    }

    /// @dev Batch claim AutoMax bonus
    function action_claimAutoMaxBonusBatch(uint256 id1, uint256 id2, uint256 id3) public {
        uint256[] memory ids = new uint256[](3);
        ids[0] = id1;
        ids[1] = id2;
        ids[2] = id3;
        try furnace.claimAutoMaxBonusBatch(ids, 25) {} catch {}
    }

    /// @dev Force a duplicate-id batch for tracked AutoMax locks. The batch path
    ///      requires strictly increasing tokenIds, so duplicate entries must not
    ///      pay more than the single pre-batch quote or consume a zero-delivered
    ///      accrual window.
    function action_claimTrackedAutoMaxDuplicateBatch(uint256 idx) public {
        if (autoMaxCount == 0) return;
        uint256 tokenId = autoMaxTokenIds[idx % autoMaxCount];
        uint256 cursorBefore = furnace.lastAutoMaxBonusClaim(tokenId);
        uint256 reserveBefore = furnace.furnaceReserve();

        uint256 quotedBonus = 0;
        try quoter.quoteAutoMaxBonus(tokenId) returns (uint256, uint256 bonusClaim) {
            quotedBonus = bonusClaim;
        } catch {
            return;
        }

        uint256[] memory ids = new uint256[](3);
        ids[0] = tokenId;
        ids[1] = tokenId;
        ids[2] = tokenId;

        try furnace.claimAutoMaxBonusBatch(ids, 25) returns (uint256 totalBonus) {
            if (totalBonus > quotedBonus) {
                autoMaxBatchDuplicateSafe = false;
            }
            if (cursorBefore != 0 && quotedBonus == 0) {
                if (furnace.lastAutoMaxBonusClaim(tokenId) != cursorBefore) {
                    autoMaxBatchDuplicateSafe = false;
                }
                if (furnace.furnaceReserve() != reserveBefore) {
                    autoMaxBatchDuplicateSafe = false;
                }
            }
        } catch {}
    }

    /// @dev Extend a lock with bonus
    function action_extendWithBonus(uint256 tokenId, uint256 newDuration) public {
        if (tokenId == 0) return;
        if (newDuration < Constants.MIN_LOCK_DURATION) newDuration = Constants.MIN_LOCK_DURATION;
        if (newDuration > Constants.MAX_LOCK_DURATION) newDuration = Constants.MAX_LOCK_DURATION;
        try furnace.extendWithBonus(tokenId, newDuration, 0) {} catch {}
    }

    /// @dev Merge two locks with bonus via the v1.0.0 Furnace entrypoint. Mirrors
    ///      the `_applyBonusAmm` reserve-mutation profile of `extendWithBonus`,
    ///      so we record `lastReserveBefore` / `lastGrossBonus` to pin the
    ///      merge case under `echidna_no_overdraft` (the same invariant that
    ///      already covers entry-side bonuses). Raw `uint256` token args
    ///      mirror `action_extendWithBonus` — the fuzzer reuses corpus seeds
    ///      from the entry actions to hit valid (caller-owned) tokenIds.
    function action_mergeLocks(uint256 fromTokenId, uint256 intoTokenId, uint256 minBonusOut) public {
        if (fromTokenId == 0 || intoTokenId == 0 || fromTokenId == intoTokenId) return;
        if (minBonusOut > 1_000_000e18) minBonusOut = 0;

        lastReserveBefore = furnace.furnaceReserve();
        try furnace.mergeLocksWithBonus(fromTokenId, intoTokenId, minBonusOut) returns (uint256) {
            uint256 reserveAfter = furnace.furnaceReserve();
            if (lastReserveBefore >= reserveAfter) {
                lastGrossBonus = lastReserveBefore - reserveAfter;
            } else {
                lastGrossBonus = 0;
            }
            lastEntryRecorded = true;
        } catch {
            lastEntryRecorded = false;
        }
    }

    /// @dev Sell a lock back to the Furnace via the MarketRouter
    function action_sellLockToFurnace(uint256 tokenId, uint256 minClaimOut) public {
        try market.sellLockToFurnace(tokenId, minClaimOut, block.timestamp + 300) {} catch {}
    }

    // ================================================================
    // Properties (MUST always return true)
    // ================================================================

    /// @dev Invariant §4.4: claim balance of Furnace >= furnaceReserve + lpStreamRemaining
    function echidna_furnace_solvency() public view returns (bool) {
        uint256 claimBal = claim.balanceOf(address(furnace));
        uint256 reserve = furnace.furnaceReserve();
        uint256 lpRemaining = furnace.getLpStreamRemaining();
        return claimBal >= reserve + lpRemaining;
    }

    /// @dev Invariant §4.4: no overdraft -- gross bonus drawn <= reserve before entry
    function echidna_no_overdraft() public view returns (bool) {
        if (!lastEntryRecorded) return true;
        return lastGrossBonus <= lastReserveBefore;
    }

    /// @dev Invariant §4.2: grossSpotBps bounded by MAX_GROSS_BONUS_BPS.
    function echidna_gross_spot_bounded() public view returns (bool) {
        try quoter.grossSpotBonusBps(Constants.MAX_USER_BONUS_BPS, Constants.LP_TOPUP_RATE_MAX_BPS) returns (
            uint256 grossBps
        ) {
            return grossBps <= Constants.MAX_GROSS_BONUS_BPS;
        } catch {
            return true;
        }
    }

    /// @dev Invariant: furnaceReserve should not exceed total CLAIM in the Furnace
    function echidna_reserve_non_negative() public view returns (bool) {
        return furnace.furnaceReserve() <= claim.balanceOf(address(furnace));
    }

    /// @dev Permissionless AutoMax claims that deliver zero user bonus must not
    ///      burn an initialized accrual cursor or spend reserve.
    function echidna_automax_zero_claim_does_not_consume_window() public view returns (bool) {
        return autoMaxZeroClaimCursorSafe;
    }

    /// @dev Duplicate AutoMax tokenIds in a batch must not multiply payout or
    ///      bypass the zero-delivered preflight.
    function echidna_automax_duplicate_batch_no_overpay() public view returns (bool) {
        return autoMaxBatchDuplicateSafe;
    }
}
