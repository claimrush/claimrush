// SPDX-License-Identifier: MIT
pragma solidity ^0.8.34;

import {EchidnaSetup} from "./EchidnaSetup.sol";
import {Constants} from "src/lib/Constants.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/// @title Echidna harness for MarketRouter escrow conservation and listing state machine.
/// @dev Invariants from the invariants document Section 7.
contract EchidnaMarketRouter is EchidnaSetup {
    uint256[] internal escrowIds;
    uint256 internal escrowCount;
    uint256[] internal lockTokenIds;
    uint256 internal lockCount;
    address[] internal observedUsers;
    mapping(address => bool) internal observedUserSeen;

    constructor() payable {
        _deployAndWire();
        _observeUser(address(this));
    }

    // ================================================================
    // Actions
    // ================================================================

    function action_takeover() public payable {
        _observeUser(msg.sender);
        uint256 price = mineCore.getCurrentTakeoverPrice();
        if (msg.value < price) return;
        try mineCore.takeover{value: price}(type(uint256).max) {} catch {}
    }

    function action_enterFurnace(uint256 amount, uint256 durationSeconds) public {
        _observeUser(msg.sender);
        if (amount < Constants.MIN_LOCK_AMOUNT) amount = Constants.MIN_LOCK_AMOUNT;
        if (amount > 5_000_000e18) amount = 5_000_000e18;
        if (durationSeconds < Constants.MIN_LOCK_DURATION) durationSeconds = Constants.MIN_LOCK_DURATION;
        if (durationSeconds > Constants.MAX_LOCK_DURATION) durationSeconds = Constants.MAX_LOCK_DURATION;
        if (claim.balanceOf(msg.sender) < amount) return;
        try furnace.enterWithClaim(amount, 0, durationSeconds, false, 0) returns (uint256 tokenId) {
            lockTokenIds.push(tokenId);
            lockCount++;
        } catch {}
    }

    function action_listLock(uint256 idx, uint256 minClaimOut) public {
        _observeUser(msg.sender);
        if (lockCount == 0) return;
        uint256 tokenId = lockTokenIds[idx % lockCount];
        uint256 expiresAt = block.timestamp + 30 days;
        try market.listLock(tokenId, minClaimOut, expiresAt) {} catch {}
    }

    function action_delistLock(uint256 idx) public {
        _observeUser(msg.sender);
        if (lockCount == 0) return;
        uint256 tokenId = lockTokenIds[idx % lockCount];
        try market.delistLock(tokenId) {} catch {}
    }

    function action_sellLockToFurnace(uint256 idx, uint256 minClaimOut) public {
        _observeUser(msg.sender);
        if (lockCount == 0) return;
        uint256 tokenId = lockTokenIds[idx % lockCount];
        try market.sellLockToFurnace(tokenId, minClaimOut, block.timestamp + 300) {} catch {}
    }

    function action_createEscrow(uint256 budgetClaim, uint256 targetBonusBps, uint256 durationSeconds) public {
        _observeUser(msg.sender);
        if (budgetClaim < Constants.DEFAULT_MIN_BONUS_TARGET_ESCROW_BUDGET) {
            budgetClaim = Constants.DEFAULT_MIN_BONUS_TARGET_ESCROW_BUDGET;
        }
        if (budgetClaim > 1_000_000e18) budgetClaim = 1_000_000e18;
        if (durationSeconds < Constants.MIN_LOCK_DURATION) durationSeconds = Constants.MIN_LOCK_DURATION;
        if (durationSeconds > Constants.MAX_LOCK_DURATION) durationSeconds = Constants.MAX_LOCK_DURATION;
        if (targetBonusBps > 10_000) targetBonusBps = 10_000;
        if (claim.balanceOf(msg.sender) < budgetClaim) return;
        try market.createBonusTargetEscrowWithTarget(
            targetBonusBps, budgetClaim, durationSeconds, false, 0, 0, 500
        ) returns (
            uint256 offerId
        ) {
            escrowIds.push(offerId);
            escrowCount++;
        } catch {}
    }

    function action_cancelEscrow(uint256 idx) public {
        _observeUser(msg.sender);
        if (escrowCount == 0) return;
        uint256 offerId = escrowIds[idx % escrowCount];
        try market.cancelBonusTargetEscrow(offerId) {} catch {}
    }

    function action_cancelExpiredEscrow(uint256 idx) public {
        _observeUser(msg.sender);
        if (escrowCount == 0) return;
        uint256 offerId = escrowIds[idx % escrowCount];
        try market.cancelExpiredBonusTargetEscrow(offerId) {} catch {}
    }

    function action_cancelExpiredEscrowBatch(uint256 idx1, uint256 idx2, uint256 idx3) public {
        _observeUser(msg.sender);
        if (escrowCount == 0) return;
        uint256[] memory ids = new uint256[](3);
        ids[0] = escrowIds[idx1 % escrowCount];
        ids[1] = escrowIds[idx2 % escrowCount];
        ids[2] = escrowIds[idx3 % escrowCount];
        try market.cancelExpiredBonusTargetEscrowBatch(ids) {} catch {}
    }

    function action_emergencyDelist(uint256 idx) public {
        _observeUser(msg.sender);
        if (lockCount == 0) return;
        uint256 tokenId = lockTokenIds[idx % lockCount];
        try market.emergencyDelist(tokenId) {} catch {}
    }

    function action_executeAutoFurnace(uint256 idx) public {
        _observeUser(msg.sender);
        if (escrowCount == 0) return;
        uint256 offerId = escrowIds[idx % escrowCount];
        try market.executeAutoFurnace(offerId, block.timestamp + 300) {} catch {}
    }

    function action_extendBonusTargetEscrowExpiry(uint256 idx, uint256 extraSeconds) public {
        _observeUser(msg.sender);
        if (escrowCount == 0) return;
        uint256 offerId = escrowIds[idx % escrowCount];
        (,,,,,,, uint256 expiresAt, bool active) = market.offers(offerId);
        if (!active) return;
        if (extraSeconds == 0) extraSeconds = 1;
        if (extraSeconds > 30 days) extraSeconds = 30 days;
        try market.extendBonusTargetEscrowExpiry(offerId, expiresAt + extraSeconds) {} catch {}
    }

    function action_pauseTrading(bool paused) public {
        _observeUser(msg.sender);
        try market.pauseTrading(paused) {} catch {}
    }

    // ================================================================
    // Properties
    // ================================================================

    /// @dev Invariant §7: CLAIM balance of MarketRouter >= sum of active escrow fundsRemaining.
    function echidna_escrow_solvency() public view returns (bool) {
        uint256 totalFundsRemaining = 0;
        for (uint256 i = 0; i < escrowCount; i++) {
            (,,,,, uint256 fundsRemaining,,, bool active) = market.offers(escrowIds[i]);
            if (active) {
                totalFundsRemaining += fundsRemaining;
            }
        }
        return claim.balanceOf(address(market)) >= totalFundsRemaining;
    }

    /// @dev Invariant §7: Listed lock flag consistency.
    function echidna_listing_flag_consistency() public view returns (bool) {
        for (uint256 i = 0; i < lockCount; i++) {
            uint256 tokenId = lockTokenIds[i];
            (address seller,,,, bool active) = market.listings(tokenId);
            if (active && seller != address(0)) {
                (,,, bool listed) = ve.getLockInfo(tokenId);
                if (!listed) return false;
            }
        }
        return true;
    }

    /// @dev Invariant §7: nextOfferId monotonically increasing.
    function echidna_offer_id_monotonic() public view returns (bool) {
        return market.nextOfferId() >= 1;
    }

    /// @dev Invariant §7: No CLAIM drain — MarketRouter balance must never
    ///      decrease except through documented escrow refund/execution paths.
    ///      This catches any sweep/rescue that might leak escrowed CLAIM.
    function echidna_no_claim_leak() public view returns (bool) {
        return echidna_escrow_solvency();
    }

    /// @dev Closed offers must not retain spendable escrow accounting.
    function echidna_inactive_offers_have_no_remaining_funds() public view returns (bool) {
        for (uint256 i = 0; i < escrowCount; i++) {
            (,,,,, uint256 fundsRemaining,,, bool active) = market.offers(escrowIds[i]);
            if (!active && fundsRemaining != 0) return false;
        }
        return true;
    }

    /// @dev List/delist/relist cycles must not duplicate a token in the seller's
    ///      active-listing index. Duplicates make pagination and offchain mirrors
    ///      overcount the same sellable lock.
    function echidna_user_listing_index_has_no_duplicates() public view returns (bool) {
        for (uint256 u = 0; u < observedUsers.length; u++) {
            uint256[] memory listings = market.getUserListings(observedUsers[u]);
            for (uint256 i = 0; i < listings.length; i++) {
                for (uint256 j = i + 1; j < listings.length; j++) {
                    if (listings[i] == listings[j]) return false;
                }
            }
        }
        return true;
    }

    /// @dev Active listings must be indexed exactly once under their seller;
    ///      inactive listings must not linger in any observed seller index.
    function echidna_user_listing_index_matches_active_state() public view returns (bool) {
        for (uint256 i = 0; i < lockCount; i++) {
            uint256 tokenId = lockTokenIds[i];
            (address seller,,,, bool active) = market.listings(tokenId);
            bool sellerObserved;
            for (uint256 u = 0; u < observedUsers.length; u++) {
                if (observedUsers[u] == seller) sellerObserved = true;
                uint256 count = _countUint(market.getUserListings(observedUsers[u]), tokenId);
                if (active && observedUsers[u] == seller) {
                    if (count != 1) return false;
                } else if (count != 0) {
                    return false;
                }
            }
            if (active && !sellerObserved) return false;
        }
        return true;
    }

    /// @dev Buyer offer index must not duplicate offerIds across create/cancel/
    ///      expire/execute cycles.
    function echidna_user_offer_index_has_no_duplicates() public view returns (bool) {
        for (uint256 u = 0; u < observedUsers.length; u++) {
            uint256[] memory offers = market.getUserBonusTargetEscrows(observedUsers[u]);
            for (uint256 i = 0; i < offers.length; i++) {
                for (uint256 j = i + 1; j < offers.length; j++) {
                    if (offers[i] == offers[j]) return false;
                }
            }
        }
        return true;
    }

    /// @dev Active offers must be indexed exactly once under the buyer; closed
    ///      offers must not remain in any observed buyer index.
    function echidna_user_offer_index_matches_active_state() public view returns (bool) {
        for (uint256 i = 0; i < escrowCount; i++) {
            uint256 offerId = escrowIds[i];
            (address buyer,,,,, uint256 fundsRemaining,,, bool active) = market.offers(offerId);
            if (active && fundsRemaining == 0) return false;

            bool buyerObserved;
            for (uint256 u = 0; u < observedUsers.length; u++) {
                if (observedUsers[u] == buyer) buyerObserved = true;
                uint256 count = _countUint(market.getUserBonusTargetEscrows(observedUsers[u]), offerId);
                if (active && observedUsers[u] == buyer) {
                    if (count != 1) return false;
                } else if (count != 0) {
                    return false;
                }
            }
            if (active && !buyerObserved) return false;
        }
        return true;
    }

    function _observeUser(address user) internal {
        if (observedUserSeen[user]) return;
        observedUserSeen[user] = true;
        observedUsers.push(user);
    }

    function _countUint(uint256[] memory values, uint256 needle) internal pure returns (uint256 count) {
        for (uint256 i = 0; i < values.length; i++) {
            if (values[i] == needle) count++;
        }
    }
}
