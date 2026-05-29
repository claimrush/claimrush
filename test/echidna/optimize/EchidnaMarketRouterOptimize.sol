// SPDX-License-Identifier: MIT
pragma solidity ^0.8.34;

import {EchidnaSetup} from "../EchidnaSetup.sol";
import {Constants} from "src/lib/Constants.sol";

/// @title MarketRouter economic worst-case search.
/// @notice Optimization-mode harness. Targets escrow imbalance, listing
///         duplication, listed-state mutation count, and per-actor net CLAIM
///         gain. Each `optimize_*` function returns an `int256` Echidna
///         maximizes; positive values indicate accounting deviation.
contract EchidnaMarketRouterOptimize is EchidnaSetup {
    uint256[] internal escrowIds;
    uint256[] internal lockTokenIds;
    address[3] internal actors;

    int256 internal worstEscrowImbalance;
    int256 internal worstInactiveOfferRetainsFunds;
    int256 internal worstListingDuplicateCount;
    int256 internal worstActorClaimGainAboveSpend;

    mapping(address => uint256) internal cumulativeActorClaimSpent;
    mapping(address => uint256) internal cumulativeActorClaimReceived;

    constructor() payable {
        _deployAndWire();
        actors[0] = address(0x20000);
        actors[1] = address(0x30000);
        actors[2] = address(0x40000);
    }

    // ================================================================
    // Actions
    // ================================================================

    function action_takeover() public payable {
        uint256 price = mineCore.getCurrentTakeoverPrice();
        if (msg.value < price) return;
        try mineCore.takeover{value: price}(type(uint256).max) {} catch {}
    }

    function action_enterFurnace(uint256 amount, uint256 durationSeconds) public {
        if (amount < Constants.MIN_LOCK_AMOUNT) amount = Constants.MIN_LOCK_AMOUNT;
        if (amount > 5_000_000e18) amount = 5_000_000e18;
        if (durationSeconds < Constants.MIN_LOCK_DURATION) durationSeconds = Constants.MIN_LOCK_DURATION;
        if (durationSeconds > Constants.MAX_LOCK_DURATION) durationSeconds = Constants.MAX_LOCK_DURATION;
        if (claim.balanceOf(msg.sender) < amount) return;
        try furnace.enterWithClaim(amount, 0, durationSeconds, false, 0) returns (uint256 tokenId) {
            lockTokenIds.push(tokenId);
        } catch {}
    }

    function action_listLock(uint256 idx, uint256 minClaimOut) public {
        if (lockTokenIds.length == 0) return;
        uint256 tokenId = lockTokenIds[idx % lockTokenIds.length];
        try market.listLock(tokenId, minClaimOut, block.timestamp + 30 days) {} catch {}
    }

    function action_delistLock(uint256 idx) public {
        if (lockTokenIds.length == 0) return;
        uint256 tokenId = lockTokenIds[idx % lockTokenIds.length];
        try market.delistLock(tokenId) {} catch {}
    }

    function action_sellLockToFurnace(uint256 idx, uint256 minClaimOut) public {
        if (lockTokenIds.length == 0) return;
        uint256 tokenId = lockTokenIds[idx % lockTokenIds.length];
        uint256 claimBefore = claim.balanceOf(msg.sender);
        try market.sellLockToFurnace(tokenId, minClaimOut, block.timestamp + 300) {
            uint256 claimAfter = claim.balanceOf(msg.sender);
            if (claimAfter > claimBefore) {
                cumulativeActorClaimReceived[msg.sender] += (claimAfter - claimBefore);
            }
            // Net actor profit = cumulative CLAIM received via the sellback
            // path - cumulative CLAIM committed to escrow. The sellback round
            // trip is designed to be loss-making; sustained positive values
            // indicate a profitable extraction loop.
            uint256 received = cumulativeActorClaimReceived[msg.sender];
            uint256 spent = cumulativeActorClaimSpent[msg.sender];
            if (received > spent) {
                int256 gain = int256(received - spent);
                if (gain > worstActorClaimGainAboveSpend) worstActorClaimGainAboveSpend = gain;
            }
        } catch {}
    }

    function action_createEscrow(uint256 budgetClaim, uint256 targetBonusBps, uint256 durationSeconds) public {
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
            cumulativeActorClaimSpent[msg.sender] += budgetClaim;
        } catch {}
    }

    function action_cancelEscrow(uint256 idx) public {
        if (escrowIds.length == 0) return;
        try market.cancelBonusTargetEscrow(escrowIds[idx % escrowIds.length]) {} catch {}
    }

    function action_observeEscrowImbalance() public {
        uint256 totalFundsRemaining = 0;
        for (uint256 i = 0; i < escrowIds.length; i++) {
            (,,,,, uint256 fundsRemaining,,, bool active) = market.offers(escrowIds[i]);
            if (active) totalFundsRemaining += fundsRemaining;
        }
        int256 imbalance = int256(totalFundsRemaining) - int256(claim.balanceOf(address(market)));
        if (imbalance > worstEscrowImbalance) worstEscrowImbalance = imbalance;
    }

    function action_observeInactiveOfferRetainsFunds() public {
        uint256 totalRetained = 0;
        for (uint256 i = 0; i < escrowIds.length; i++) {
            (,,,,, uint256 fundsRemaining,,, bool active) = market.offers(escrowIds[i]);
            if (!active && fundsRemaining > 0) totalRetained += fundsRemaining;
        }
        int256 r = int256(totalRetained);
        if (r > worstInactiveOfferRetainsFunds) worstInactiveOfferRetainsFunds = r;
    }

    function action_observeListingDuplicates() public {
        uint256 totalDupes = 0;
        for (uint256 a = 0; a < 3; a++) {
            uint256[] memory listings = market.getUserListings(actors[a]);
            for (uint256 i = 0; i < listings.length; i++) {
                for (uint256 j = i + 1; j < listings.length; j++) {
                    if (listings[i] == listings[j]) totalDupes++;
                }
            }
        }
        int256 d = int256(totalDupes);
        if (d > worstListingDuplicateCount) worstListingDuplicateCount = d;
    }

    // ================================================================
    // Optimization targets
    // ================================================================

    /// @notice Worst observed surplus of active-escrow `fundsRemaining` over
    ///         MarketRouter CLAIM custody. Must remain `<= 0` (M3 escrow
    ///         conservation).
    function optimize_market_escrowImbalance() public view returns (int256) {
        return worstEscrowImbalance;
    }

    /// @notice Worst observed `fundsRemaining` retained on closed offers. Must
    ///         remain `<= 0`.
    function optimize_market_inactiveOfferFunds() public view returns (int256) {
        return worstInactiveOfferRetainsFunds;
    }

    /// @notice Worst observed listing-duplication count across observed users.
    ///         Must remain `<= 0`.
    function optimize_market_listingDuplicateCount() public view returns (int256) {
        return worstListingDuplicateCount;
    }

    /// @notice Worst observed CLAIM gain to an actor in excess of CLAIM they
    ///         escrowed. High positive values indicate a profitable round-trip
    ///         through the listing/sellback path.
    function optimize_market_actorClaimGainAboveSpend() public view returns (int256) {
        return worstActorClaimGainAboveSpend;
    }
}
