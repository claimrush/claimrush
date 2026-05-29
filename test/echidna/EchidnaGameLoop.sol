// SPDX-License-Identifier: MIT
pragma solidity ^0.8.34;

import {ClaimToken} from "src/ClaimToken.sol";
import {Furnace} from "src/Furnace.sol";
import {FurnaceQuoter} from "src/FurnaceQuoter.sol";
import {MarketRouter} from "src/MarketRouter.sol";
import {ShareholderRoyalties} from "src/ShareholderRoyalties.sol";
import {VeClaimNFT} from "src/VeClaimNFT.sol";
import {Constants} from "src/lib/Constants.sol";
import {EchidnaSetup} from "./EchidnaSetup.sol";
import {MineCoreHarness} from "../mocks/MineCoreHarness.sol";

/// @dev Executes protocol calls with a real msg.sender identity.
contract GameLoopActor {
    ClaimToken internal immutable claim;
    VeClaimNFT internal immutable ve;
    Furnace internal immutable furnace;
    MarketRouter internal immutable market;
    MineCoreHarness internal immutable mineCore;
    bool internal immutable rejectEth;

    constructor(
        ClaimToken claim_,
        VeClaimNFT ve_,
        Furnace furnace_,
        MarketRouter market_,
        MineCoreHarness mineCore_,
        bool rejectEth_
    ) {
        claim = claim_;
        ve = ve_;
        furnace = furnace_;
        market = market_;
        mineCore = mineCore_;
        rejectEth = rejectEth_;
    }

    receive() external payable {
        if (rejectEth) revert("REJECT_ETH");
    }

    function approveProtocol() external {
        claim.approve(address(furnace), type(uint256).max);
        claim.approve(address(market), type(uint256).max);
    }

    function takeover(uint256 maxPrice) external payable {
        mineCore.takeover{value: msg.value}(maxPrice);
    }

    function withdrawKingBalanceTo(address to) external {
        mineCore.withdrawKingBalanceTo(to);
    }

    function withdrawRefundBalance(address to) external {
        mineCore.withdrawRefundBalance(to);
    }

    function withdrawPendingClaimTo(address to) external {
        mineCore.withdrawPendingClaimTo(to);
    }

    function enterWithClaim(
        uint256 claimAmount,
        uint256 targetTokenId,
        uint256 durationSeconds,
        bool createAutoMax,
        uint256 minVeOut
    ) external returns (uint256) {
        return furnace.enterWithClaim(claimAmount, targetTokenId, durationSeconds, createAutoMax, minVeOut);
    }

    function extendWithBonus(uint256 tokenId, uint256 durationSeconds, uint256 minBonusOut) external returns (uint256) {
        return furnace.extendWithBonus(tokenId, durationSeconds, minBonusOut);
    }

    function mergeLocksWithBonus(uint256 fromTokenId, uint256 intoTokenId, uint256 minBonusOut)
        external
        returns (uint256)
    {
        return furnace.mergeLocksWithBonus(fromTokenId, intoTokenId, minBonusOut);
    }

    function claimAutoMaxBonus(uint256 tokenId) external returns (uint256) {
        return furnace.claimAutoMaxBonus(tokenId);
    }

    function claimAutoMaxBonusBatch(uint256[] calldata tokenIds, uint256 maxLocks) external returns (uint256) {
        return furnace.claimAutoMaxBonusBatch(tokenIds, maxLocks);
    }

    function setAutoMax(uint256 tokenId, bool enabled) external {
        ve.setAutoMax(tokenId, enabled);
    }

    function unlock(uint256 tokenId) external {
        ve.unlock(tokenId);
    }

    function listLock(uint256 tokenId, uint256 minClaimOut, uint256 expiresAtTime) external {
        market.listLock(tokenId, minClaimOut, expiresAtTime);
    }

    function delistLock(uint256 tokenId) external {
        market.delistLock(tokenId);
    }

    function cancelExpiredListing(uint256 tokenId) external {
        market.cancelExpiredListing(tokenId);
    }

    function sellLockToFurnace(uint256 tokenId, uint256 minClaimOut, uint256 deadline) external returns (uint256) {
        return market.sellLockToFurnace(tokenId, minClaimOut, deadline);
    }

    function sellListedLockToFurnace(uint256 tokenId, uint256 deadline) external returns (uint256) {
        return market.sellListedLockToFurnace(tokenId, deadline);
    }

    function createBonusTargetEscrowWithTarget(
        uint256 targetBonusBps,
        uint256 budgetClaim,
        uint256 durationSeconds,
        bool createAutoMax,
        uint256 escrowTtlSeconds,
        uint256 destinationLockId,
        uint256 slippageBps
    ) external returns (uint256) {
        return market.createBonusTargetEscrowWithTarget(
            targetBonusBps,
            budgetClaim,
            durationSeconds,
            createAutoMax,
            escrowTtlSeconds,
            destinationLockId,
            slippageBps
        );
    }

    function cancelBonusTargetEscrow(uint256 offerId) external {
        market.cancelBonusTargetEscrow(offerId);
    }

    function cancelExpiredBonusTargetEscrow(uint256 offerId) external {
        market.cancelExpiredBonusTargetEscrow(offerId);
    }

    function executeAutoFurnace(uint256 offerId, uint256 deadline) external {
        market.executeAutoFurnace(offerId, deadline);
    }
}

/// @title Cross-contract adversarial game-loop harness.
/// @dev Covers player, attacker, and keeper flows across MineCore, Furnace, veNFT,
///      MarketRouter, and ShareholderRoyalties. This is intentionally broader
///      than single-contract solvency: every successful action asserts global
///      backing, while properties track quote parity, victim-grief resistance,
///      pause liveness, and round-trip no-profit behavior.
contract EchidnaGameLoop is EchidnaSetup {
    uint8 internal constant ACTOR_VICTIM = 0;
    uint8 internal constant ACTOR_ATTACKER = 1;
    uint8 internal constant ACTOR_KEEPER = 2;
    uint8 internal constant ACTOR_REJECTOR = 3;

    uint256 internal constant SEED_ACTOR_CLAIM = 3_000_000e18;
    uint256 internal constant SEED_FURNACE_RESERVE = 12_000_000e18;
    uint256 internal constant MAX_ACTION_CLAIM = 250_000e18;

    GameLoopActor internal victim;
    GameLoopActor internal attacker;
    GameLoopActor internal keeper;
    GameLoopActor internal rejector;

    uint256[] internal victimLocks;
    uint256[] internal attackerLocks;
    uint256[] internal keeperLocks;
    uint256[] internal rejectorLocks;
    uint256[] internal trackedOffers;

    mapping(uint256 => bool) internal trackedLock;
    mapping(uint256 => uint8) internal trackedLockActor;
    mapping(uint256 => bool) internal lockClosed;

    bool internal quoteExecuteSafe = true;
    bool internal victimGriefingSafe = true;
    bool internal pauseLivenessSafe = true;
    bool internal noProfitableCycleSafe = true;

    struct LockSnapshot {
        bool exists;
        address owner;
        uint256 amount;
        uint256 lockEnd;
        bool autoMax;
        bool listed;
    }

    constructor() payable {
        _deployAndWire();

        victim = new GameLoopActor(claim, ve, furnace, market, mineCore, false);
        attacker = new GameLoopActor(claim, ve, furnace, market, mineCore, false);
        keeper = new GameLoopActor(claim, ve, furnace, market, mineCore, false);
        rejector = new GameLoopActor(claim, ve, furnace, market, mineCore, true);

        victim.approveProtocol();
        attacker.approveProtocol();
        keeper.approveProtocol();
        rejector.approveProtocol();

        market.setSettlementKeeper(address(keeper), true);

        mineCore.mintClaimForTest(address(victim), SEED_ACTOR_CLAIM);
        mineCore.mintClaimForTest(address(attacker), SEED_ACTOR_CLAIM);
        mineCore.mintClaimForTest(address(keeper), SEED_ACTOR_CLAIM);
        mineCore.mintClaimForTest(address(rejector), SEED_ACTOR_CLAIM);
        mineCore.creditFurnaceReserveForTest(SEED_FURNACE_RESERVE);

        _seedActorLock(ACTOR_VICTIM, 25_000e18, Constants.MAX_LOCK_DURATION, false);
        _seedActorLock(ACTOR_VICTIM, 25_000e18, Constants.MAX_LOCK_DURATION, true);
        _seedActorLock(ACTOR_ATTACKER, 25_000e18, Constants.MAX_LOCK_DURATION, false);
        _seedActorLock(ACTOR_ATTACKER, 25_000e18, Constants.MAX_LOCK_DURATION, true);
        _seedActorLock(ACTOR_KEEPER, 25_000e18, Constants.MAX_LOCK_DURATION, false);
        _seedActorLock(ACTOR_REJECTOR, 25_000e18, Constants.MAX_LOCK_DURATION, false);
    }

    receive() external payable {}

    // ================================================================
    // Core game-loop actions
    // ================================================================

    function action_takeoverAs(uint8 actorSeed, uint256 overpayWei) public payable {
        uint256 price = mineCore.getCurrentTakeoverPrice();
        if (msg.value < price) return;

        uint256 pay = price;
        uint256 maxExtra = price / 5;
        if (maxExtra != 0) {
            uint256 extra = overpayWei % (maxExtra + 1);
            if (msg.value >= price + extra) pay = price + extra;
        }

        try _actor(actorSeed).takeover{value: pay}(type(uint256).max) {
            _assertGameState();
        } catch {}
    }

    function action_enterWithQuote(uint8 actorSeed, uint256 amountSeed, uint256 durationSeed, bool autoMax) public {
        uint8 actorId = actorSeed % 4;
        GameLoopActor actor_ = _actor(actorId);
        uint256 amount = _boundedClaimAmount(address(actor_), amountSeed, Constants.MIN_LOCK_AMOUNT, MAX_ACTION_CLAIM);
        if (amount == 0) return;
        if (ve.balanceOf(address(actor_)) >= Constants.MAX_VE_NFTS_PER_USER) return;

        uint256 duration = _boundedDuration(durationSeed);
        uint256 balBefore = claim.balanceOf(address(actor_));
        uint256 principal;
        uint256 bonus;
        uint256 veOut;
        try quoter.quoteEnterWithClaim(address(actor_), amount, 0, duration, autoMax) returns (
            uint256 principalClaim, uint256 bonusClaim, uint256 quotedVeOut, uint256
        ) {
            principal = principalClaim;
            bonus = bonusClaim;
            veOut = quotedVeOut;
        } catch {
            return;
        }
        if (veOut == 0 || principal == 0) return;

        try actor_.enterWithClaim(amount, 0, duration, autoMax, veOut) returns (uint256 tokenId) {
            _recordLock(actorId, tokenId);
            (uint256 lockAmount,,,) = ve.getLockInfo(tokenId);
            if (lockAmount < principal + bonus) quoteExecuteSafe = false;
            if (claim.balanceOf(address(actor_)) != balBefore - principal) quoteExecuteSafe = false;
            _assertGameState();
        } catch {
            if (!furnace.lockingPaused()) quoteExecuteSafe = false;
        }
    }

    function action_extendWithQuote(uint8 actorSeed, uint256 lockSeed, uint256 durationSeed) public {
        uint8 actorId = actorSeed % 4;
        uint256 tokenId = _trackedLockFor(actorId, lockSeed);
        if (tokenId == 0 || lockClosed[tokenId]) return;

        uint256 duration = _boundedDuration(durationSeed);
        uint256 quotedBonus;
        try quoter.quoteExtendWithBonus(address(_actor(actorId)), tokenId, duration) returns (
            uint256, uint256 b, uint256
        ) {
            quotedBonus = b;
        } catch {
            return;
        }

        try _actor(actorId).extendWithBonus(tokenId, duration, quotedBonus) returns (uint256 actualBonus) {
            if (actualBonus != quotedBonus) quoteExecuteSafe = false;
            _assertGameState();
        } catch {
            if (!furnace.lockingPaused()) quoteExecuteSafe = false;
        }
    }

    function action_claimAutoMaxWithQuote(uint256 lockSeed) public {
        uint256 tokenId = _anyTrackedLock(lockSeed);
        if (tokenId == 0 || lockClosed[tokenId]) return;

        LockSnapshot memory beforeState = _snapshotLock(tokenId);
        if (!beforeState.exists || !beforeState.autoMax || beforeState.listed || beforeState.lockEnd <= block.timestamp)
        {
            return;
        }

        uint256 cursorBefore = furnace.lastAutoMaxBonusClaim(tokenId);
        uint256 reserveBefore = furnace.furnaceReserve();
        uint256 quotedBonus;
        try quoter.quoteAutoMaxBonus(tokenId) returns (uint256, uint256 bonusClaim) {
            quotedBonus = bonusClaim;
        } catch {
            return;
        }

        try keeper.claimAutoMaxBonus(tokenId) returns (uint256 actualBonus) {
            LockSnapshot memory afterState = _snapshotLock(tokenId);
            if (!afterState.exists || afterState.owner != beforeState.owner) victimGriefingSafe = false;
            if (afterState.amount < beforeState.amount) victimGriefingSafe = false;
            if (actualBonus != quotedBonus) quoteExecuteSafe = false;
            if (quotedBonus == 0 && cursorBefore != 0) {
                if (furnace.lastAutoMaxBonusClaim(tokenId) != cursorBefore) quoteExecuteSafe = false;
                if (furnace.furnaceReserve() != reserveBefore) quoteExecuteSafe = false;
            }
            _assertGameState();
        } catch {
            if (quotedBonus > 0 && !furnace.lockingPaused()) quoteExecuteSafe = false;
        }
    }

    function action_enterSellRoundTripCannotProfit(
        uint8 actorSeed,
        uint256 amountSeed,
        uint256 durationSeed,
        bool autoMax
    ) public {
        uint8 actorId = actorSeed % 4;
        GameLoopActor actor_ = _actor(actorId);
        uint256 amount = _boundedClaimAmount(address(actor_), amountSeed, Constants.MIN_LOCK_AMOUNT, MAX_ACTION_CLAIM);
        if (amount == 0) return;
        if (ve.balanceOf(address(actor_)) >= Constants.MAX_VE_NFTS_PER_USER) return;

        uint256 duration = _boundedDuration(durationSeed);
        uint256 balBefore = claim.balanceOf(address(actor_));
        uint256 veOut;
        try quoter.quoteEnterWithClaim(address(actor_), amount, 0, duration, autoMax) returns (
            uint256, uint256, uint256 quotedVeOut, uint256
        ) {
            veOut = quotedVeOut;
        } catch {
            return;
        }
        if (veOut == 0) return;

        try actor_.enterWithClaim(amount, 0, duration, autoMax, veOut) returns (uint256 tokenId) {
            _recordLock(actorId, tokenId);
            (uint256 lockAmount, uint256 lockEnd, bool lockAutoMax,) = ve.getLockInfo(tokenId);
            uint256 quoteOut;
            try quoter.quoteSellLockToFurnaceFromInfo(lockAmount, lockEnd, lockAutoMax) returns (
                uint256 claimOut, uint256, uint256, uint256
            ) {
                quoteOut = claimOut;
            } catch {
                return;
            }
            try actor_.sellLockToFurnace(tokenId, quoteOut, block.timestamp + Constants.SWAP_DEADLINE_SECONDS) returns (
                uint256 actualOut
            ) {
                lockClosed[tokenId] = true;
                if (actualOut != quoteOut) quoteExecuteSafe = false;
                if (claim.balanceOf(address(actor_)) > balBefore) noProfitableCycleSafe = false;
                _assertGameState();
            } catch {}
        } catch {}
    }

    function action_extendSellRoundTripCannotProfit(uint8 actorSeed, uint256 amountSeed) public {
        uint8 actorId = actorSeed % 4;
        GameLoopActor actor_ = _actor(actorId);
        uint256 amount = _boundedClaimAmount(address(actor_), amountSeed, Constants.MIN_LOCK_AMOUNT, MAX_ACTION_CLAIM);
        if (amount == 0) return;
        if (ve.balanceOf(address(actor_)) >= Constants.MAX_VE_NFTS_PER_USER) return;

        uint256 balBefore = claim.balanceOf(address(actor_));
        uint256 veOut;
        try quoter.quoteEnterWithClaim(address(actor_), amount, 0, Constants.MIN_LOCK_DURATION, false) returns (
            uint256, uint256, uint256 quotedVeOut, uint256
        ) {
            veOut = quotedVeOut;
        } catch {
            return;
        }
        if (veOut == 0) return;

        try actor_.enterWithClaim(amount, 0, Constants.MIN_LOCK_DURATION, false, veOut) returns (uint256 tokenId) {
            _recordLock(actorId, tokenId);

            uint256 quotedBonus;
            try quoter.quoteExtendWithBonus(address(actor_), tokenId, Constants.MAX_LOCK_DURATION) returns (
                uint256, uint256 bonusClaim, uint256
            ) {
                quotedBonus = bonusClaim;
            } catch {
                return;
            }

            try actor_.extendWithBonus(tokenId, Constants.MAX_LOCK_DURATION, quotedBonus) returns (
                uint256 actualBonus
            ) {
                if (actualBonus != quotedBonus) quoteExecuteSafe = false;
                (uint256 lockAmount, uint256 lockEnd, bool lockAutoMax,) = ve.getLockInfo(tokenId);
                uint256 quoteOut;
                try quoter.quoteSellLockToFurnaceFromInfo(lockAmount, lockEnd, lockAutoMax) returns (
                    uint256 claimOut, uint256, uint256, uint256
                ) {
                    quoteOut = claimOut;
                } catch {
                    return;
                }
                try actor_.sellLockToFurnace(
                    tokenId, quoteOut, block.timestamp + Constants.SWAP_DEADLINE_SECONDS
                ) returns (
                    uint256 actualOut
                ) {
                    lockClosed[tokenId] = true;
                    if (actualOut != quoteOut) quoteExecuteSafe = false;
                    if (claim.balanceOf(address(actor_)) > balBefore) noProfitableCycleSafe = false;
                    _assertGameState();
                } catch {}
            } catch {
                if (!furnace.lockingPaused()) quoteExecuteSafe = false;
            }
        } catch {}
    }

    function action_mergeSellRoundTripCannotProfit(uint8 actorSeed, uint256 amountSeed) public {
        uint8 actorId = actorSeed % 4;
        GameLoopActor actor_ = _actor(actorId);
        uint256 totalAmount =
            _boundedClaimAmount(address(actor_), amountSeed, Constants.MIN_LOCK_AMOUNT * 2, MAX_ACTION_CLAIM);
        if (totalAmount == 0) return;
        if (ve.balanceOf(address(actor_)) + 1 >= Constants.MAX_VE_NFTS_PER_USER) return;

        uint256 shortAmount = totalAmount / 2;
        uint256 longAmount = totalAmount - shortAmount;
        if (shortAmount < Constants.MIN_LOCK_AMOUNT || longAmount < Constants.MIN_LOCK_AMOUNT) return;

        uint256 balBefore = claim.balanceOf(address(actor_));
        uint256 shortVeOut;
        uint256 longVeOut;
        try quoter.quoteEnterWithClaim(address(actor_), shortAmount, 0, Constants.MIN_LOCK_DURATION, false) returns (
            uint256, uint256, uint256 quotedVeOut, uint256
        ) {
            shortVeOut = quotedVeOut;
        } catch {
            return;
        }
        try quoter.quoteEnterWithClaim(address(actor_), longAmount, 0, Constants.MAX_LOCK_DURATION, false) returns (
            uint256, uint256, uint256 quotedVeOut, uint256
        ) {
            longVeOut = quotedVeOut;
        } catch {
            return;
        }
        if (shortVeOut == 0 || longVeOut == 0) return;

        try actor_.enterWithClaim(shortAmount, 0, Constants.MIN_LOCK_DURATION, false, shortVeOut) returns (
            uint256 shortTokenId
        ) {
            _recordLock(actorId, shortTokenId);
            try actor_.enterWithClaim(longAmount, 0, Constants.MAX_LOCK_DURATION, false, longVeOut) returns (
                uint256 longTokenId
            ) {
                _recordLock(actorId, longTokenId);
                try actor_.mergeLocksWithBonus(shortTokenId, longTokenId, 0) returns (uint256) {
                    lockClosed[shortTokenId] = true;
                    (uint256 lockAmount, uint256 lockEnd, bool lockAutoMax,) = ve.getLockInfo(longTokenId);
                    uint256 quoteOut;
                    try quoter.quoteSellLockToFurnaceFromInfo(lockAmount, lockEnd, lockAutoMax) returns (
                        uint256 claimOut, uint256, uint256, uint256
                    ) {
                        quoteOut = claimOut;
                    } catch {
                        return;
                    }
                    try actor_.sellLockToFurnace(
                        longTokenId, quoteOut, block.timestamp + Constants.SWAP_DEADLINE_SECONDS
                    ) returns (
                        uint256 actualOut
                    ) {
                        lockClosed[longTokenId] = true;
                        if (actualOut != quoteOut) quoteExecuteSafe = false;
                        if (claim.balanceOf(address(actor_)) > balBefore) noProfitableCycleSafe = false;
                        _assertGameState();
                    } catch {}
                } catch {}
            } catch {}
        } catch {}
    }

    // ================================================================
    // Market/listing/escrow actions
    // ================================================================

    function action_listActorLock(uint8 actorSeed, uint256 lockSeed, uint256 minSeed, uint256 ttlSeed) public {
        uint8 actorId = actorSeed % 4;
        uint256 tokenId = _trackedLockFor(actorId, lockSeed);
        if (tokenId == 0 || lockClosed[tokenId]) return;

        LockSnapshot memory s = _snapshotLock(tokenId);
        if (!s.exists || s.owner != address(_actor(actorId)) || s.listed || s.lockEnd <= block.timestamp + 1) return;

        uint256 ttl = 1 + (ttlSeed % (s.lockEnd - block.timestamp));
        uint256 minClaimOut = 1;
        try quoter.quoteSellLockToFurnaceFromInfo(s.amount, s.lockEnd, s.autoMax) returns (
            uint256 claimOut, uint256, uint256, uint256
        ) {
            minClaimOut = claimOut == 0 ? 1 : 1 + (minSeed % claimOut);
        } catch {}

        try _actor(actorId).listLock(tokenId, minClaimOut, block.timestamp + ttl) {
            (,,, bool listed) = ve.getLockInfo(tokenId);
            (, uint256 storedMin,,, bool active) = market.listings(tokenId);
            if (!listed || !active || storedMin == 0) quoteExecuteSafe = false;
            _assertGameState();
        } catch {}
    }

    function action_delistActorLock(uint8 actorSeed, uint256 lockSeed) public {
        uint8 actorId = actorSeed % 4;
        uint256 tokenId = _trackedLockFor(actorId, lockSeed);
        if (tokenId == 0 || lockClosed[tokenId]) return;

        try _actor(actorId).delistLock(tokenId) {
            (,,, bool listed) = ve.getLockInfo(tokenId);
            (,,,, bool active) = market.listings(tokenId);
            if (listed || active) quoteExecuteSafe = false;
            _assertGameState();
        } catch {}
    }

    function action_sellActorLockWithQuote(uint8 actorSeed, uint256 lockSeed) public {
        uint8 actorId = actorSeed % 4;
        uint256 tokenId = _trackedLockFor(actorId, lockSeed);
        if (tokenId == 0 || lockClosed[tokenId]) return;

        LockSnapshot memory s = _snapshotLock(tokenId);
        if (!s.exists || s.owner != address(_actor(actorId)) || s.lockEnd <= block.timestamp) return;

        uint256 quoteOut;
        try quoter.quoteSellLockToFurnaceFromInfo(s.amount, s.lockEnd, s.autoMax) returns (
            uint256 claimOut, uint256, uint256, uint256
        ) {
            quoteOut = claimOut;
        } catch {
            return;
        }

        try _actor(actorId)
            .sellLockToFurnace(tokenId, quoteOut, block.timestamp + Constants.SWAP_DEADLINE_SECONDS) returns (
            uint256 actualOut
        ) {
            lockClosed[tokenId] = true;
            if (actualOut != quoteOut) quoteExecuteSafe = false;
            _assertGameState();
        } catch {}
    }

    function action_sellListedByKeeperWithQuote(uint256 lockSeed) public {
        uint256 tokenId = _anyTrackedLock(lockSeed);
        if (tokenId == 0 || lockClosed[tokenId]) return;

        (address seller, uint256 minClaimOut,, uint256 expiresAt, bool active) = market.listings(tokenId);
        if (!active || seller == address(0) || block.timestamp >= expiresAt) return;

        LockSnapshot memory s = _snapshotLock(tokenId);
        if (!s.exists || !s.listed) return;

        uint256 quoteOut;
        try quoter.quoteSellLockToFurnaceFromInfo(s.amount, s.lockEnd, s.autoMax) returns (
            uint256 claimOut, uint256, uint256, uint256
        ) {
            quoteOut = claimOut;
        } catch {
            return;
        }
        if (quoteOut < minClaimOut) return;

        try keeper.sellListedLockToFurnace(tokenId, block.timestamp + Constants.SWAP_DEADLINE_SECONDS) returns (
            uint256 actualOut
        ) {
            lockClosed[tokenId] = true;
            if (actualOut != quoteOut) quoteExecuteSafe = false;
            _assertGameState();
        } catch {}
    }

    function action_createEscrow(uint8 actorSeed, uint256 budgetSeed, uint256 targetSeed, uint256 durationSeed) public {
        uint8 actorId = actorSeed % 4;
        GameLoopActor actor_ = _actor(actorId);
        uint256 budget = _boundedClaimAmount(
            address(actor_), budgetSeed, Constants.DEFAULT_MIN_BONUS_TARGET_ESCROW_BUDGET, MAX_ACTION_CLAIM
        );
        if (budget == 0) return;

        uint256 targetBonusBps = 1 + (targetSeed % 500);
        uint256 duration = _boundedDuration(durationSeed);

        try actor_.createBonusTargetEscrowWithTarget(targetBonusBps, budget, duration, false, 0, 0, 500) returns (
            uint256 offerId
        ) {
            trackedOffers.push(offerId);
            _assertGameState();
        } catch {}
    }

    function action_cancelEscrow(uint256 offerSeed) public {
        uint256 offerId = _trackedOffer(offerSeed);
        if (offerId == 0) return;

        (address buyer,,,,,,,, bool active) = market.offers(offerId);
        if (!active) return;
        GameLoopActor actor_ = _actorForAddress(buyer);
        if (address(actor_) == address(0)) return;

        try actor_.cancelBonusTargetEscrow(offerId) {
            (,,,,, uint256 fundsRemaining,,, bool stillActive) = market.offers(offerId);
            if (stillActive || fundsRemaining != 0) quoteExecuteSafe = false;
            _assertGameState();
        } catch {}
    }

    function action_executeEscrow(uint256 offerSeed) public {
        uint256 offerId = _trackedOffer(offerSeed);
        if (offerId == 0) return;

        (,,,,, uint256 fundsRemaining,, uint256 expiresAt, bool active) = market.offers(offerId);
        if (!active || fundsRemaining == 0 || block.timestamp >= expiresAt) return;

        try keeper.executeAutoFurnace(offerId, block.timestamp + Constants.SWAP_DEADLINE_SECONDS) {
            (,,,,, uint256 remaining,,, bool stillActive) = market.offers(offerId);
            if (stillActive || remaining != 0) quoteExecuteSafe = false;
            _assertGameState();
        } catch {}
    }

    function action_cancelExpiredEscrowAsKeeper(uint256 offerSeed) public {
        uint256 offerId = _trackedOffer(offerSeed);
        if (offerId == 0) return;

        (,,,,, uint256 fundsRemaining,, uint256 expiresAt, bool active) = market.offers(offerId);
        if (!active || fundsRemaining == 0 || block.timestamp < expiresAt) return;

        try keeper.cancelExpiredBonusTargetEscrow(offerId) {
            (,,,,, uint256 remaining,,, bool stillActive) = market.offers(offerId);
            if (stillActive || remaining != 0) quoteExecuteSafe = false;
            _assertGameState();
        } catch {
            pauseLivenessSafe = false;
        }
    }

    function action_escrowCancelRoundTripNoLoss(uint8 actorSeed, uint256 budgetSeed) public {
        uint8 actorId = actorSeed % 4;
        GameLoopActor actor_ = _actor(actorId);
        uint256 budget = _boundedClaimAmount(
            address(actor_), budgetSeed, Constants.DEFAULT_MIN_BONUS_TARGET_ESCROW_BUDGET, MAX_ACTION_CLAIM
        );
        if (budget == 0) return;

        uint256 balBefore = claim.balanceOf(address(actor_));
        try actor_.createBonusTargetEscrowWithTarget(1, budget, Constants.MAX_LOCK_DURATION, false, 0, 0, 500) returns (
            uint256 offerId
        ) {
            trackedOffers.push(offerId);
            try actor_.cancelBonusTargetEscrow(offerId) {
                if (claim.balanceOf(address(actor_)) != balBefore) noProfitableCycleSafe = false;
                _assertGameState();
            } catch {
                pauseLivenessSafe = false;
            }
        } catch {}
    }

    function action_escrowExecuteSellRoundTripCannotProfit(uint8 actorSeed, uint256 budgetSeed) public {
        uint8 actorId = actorSeed % 4;
        GameLoopActor actor_ = _actor(actorId);
        uint256 budget = _boundedClaimAmount(
            address(actor_), budgetSeed, Constants.DEFAULT_MIN_BONUS_TARGET_ESCROW_BUDGET, MAX_ACTION_CLAIM
        );
        if (budget == 0) return;
        if (ve.balanceOf(address(actor_)) >= Constants.MAX_VE_NFTS_PER_USER) return;

        uint256 balBefore = claim.balanceOf(address(actor_));
        uint256 expectedTokenId = ve.nextTokenId();

        try actor_.createBonusTargetEscrowWithTarget(1, budget, Constants.MAX_LOCK_DURATION, false, 0, 0, 0) returns (
            uint256 offerId
        ) {
            trackedOffers.push(offerId);
            try keeper.executeAutoFurnace(offerId, block.timestamp + Constants.SWAP_DEADLINE_SECONDS) {
                _recordLock(actorId, expectedTokenId);
                (uint256 lockAmount, uint256 lockEnd, bool lockAutoMax,) = ve.getLockInfo(expectedTokenId);
                uint256 quoteOut;
                try quoter.quoteSellLockToFurnaceFromInfo(lockAmount, lockEnd, lockAutoMax) returns (
                    uint256 claimOut, uint256, uint256, uint256
                ) {
                    quoteOut = claimOut;
                } catch {
                    return;
                }
                try actor_.sellLockToFurnace(
                    expectedTokenId, quoteOut, block.timestamp + Constants.SWAP_DEADLINE_SECONDS
                ) returns (
                    uint256 actualOut
                ) {
                    lockClosed[expectedTokenId] = true;
                    if (actualOut != quoteOut) quoteExecuteSafe = false;
                    if (claim.balanceOf(address(actor_)) > balBefore) noProfitableCycleSafe = false;
                    _assertGameState();
                } catch {}
            } catch {}
        } catch {}
    }

    function action_cancelExpiredListingAsKeeper(uint256 lockSeed) public {
        uint256 tokenId = _anyTrackedLock(lockSeed);
        if (tokenId == 0 || lockClosed[tokenId]) return;

        (address seller,,, uint256 expiresAt, bool active) = market.listings(tokenId);
        if (!active || seller == address(0) || block.timestamp < expiresAt) return;

        try keeper.cancelExpiredListing(tokenId) {
            (,,,, bool stillActive) = market.listings(tokenId);
            (,,, bool listed) = ve.getLockInfo(tokenId);
            if (stillActive || listed) quoteExecuteSafe = false;
            _assertGameState();
        } catch {
            pauseLivenessSafe = false;
        }
    }

    // ================================================================
    // Victim-griefing and pause/liveness probes
    // ================================================================

    function action_attackerCannotMutateVictimLock(uint8 mode, uint256 lockSeed) public {
        uint256 tokenId = _trackedLockFor(ACTOR_VICTIM, lockSeed);
        if (tokenId == 0 || lockClosed[tokenId]) return;

        LockSnapshot memory beforeState = _snapshotLock(tokenId);
        if (!beforeState.exists || beforeState.owner != address(victim)) return;

        uint8 m = mode % 7;
        if (m == 0) {
            try attacker.listLock(tokenId, 1, beforeState.lockEnd) {} catch {}
        } else if (m == 1) {
            try attacker.delistLock(tokenId) {} catch {}
        } else if (m == 2) {
            try attacker.sellLockToFurnace(tokenId, 0, block.timestamp + Constants.SWAP_DEADLINE_SECONDS) {} catch {}
        } else if (m == 3) {
            try attacker.setAutoMax(tokenId, !beforeState.autoMax) {} catch {}
        } else if (m == 4) {
            try attacker.unlock(tokenId) {} catch {}
        } else if (m == 5) {
            try attacker.extendWithBonus(tokenId, Constants.MAX_LOCK_DURATION, 0) {} catch {}
        } else {
            uint256 budget = _boundedClaimAmount(
                address(attacker), 0, Constants.DEFAULT_MIN_BONUS_TARGET_ESCROW_BUDGET, MAX_ACTION_CLAIM
            );
            if (budget != 0) {
                try attacker.createBonusTargetEscrowWithTarget(
                    1, budget, Constants.MAX_LOCK_DURATION, false, 1 days, tokenId, 500
                ) returns (
                    uint256 offerId
                ) {
                    trackedOffers.push(offerId);
                } catch {}
            }
        }

        if (!_sameLockState(beforeState, _snapshotLock(tokenId))) victimGriefingSafe = false;
        _assertGameState();
    }

    function action_permissionlessAutoMaxCannotDamageVictim(uint256 lockSeed) public {
        uint256 tokenId = _trackedLockFor(ACTOR_VICTIM, lockSeed);
        if (tokenId == 0 || lockClosed[tokenId]) return;

        LockSnapshot memory beforeState = _snapshotLock(tokenId);
        if (!beforeState.exists || !beforeState.autoMax || beforeState.listed || beforeState.lockEnd <= block.timestamp)
        {
            return;
        }

        uint256 quotedBonus;
        try quoter.quoteAutoMaxBonus(tokenId) returns (uint256, uint256 bonusClaim) {
            quotedBonus = bonusClaim;
        } catch {
            return;
        }

        try attacker.claimAutoMaxBonus(tokenId) returns (uint256 actualBonus) {
            LockSnapshot memory afterState = _snapshotLock(tokenId);
            if (!afterState.exists || afterState.owner != beforeState.owner) victimGriefingSafe = false;
            if (afterState.amount < beforeState.amount) victimGriefingSafe = false;
            if (actualBonus != quotedBonus) quoteExecuteSafe = false;
            _assertGameState();
        } catch {}
    }

    function action_pauseLivenessProbe(uint256 lockSeed, uint256 offerSeed) public {
        try market.pauseTrading(true) {
            uint256 offerId = _trackedOffer(offerSeed);
            if (offerId != 0) {
                (address buyer,,,,,,,, bool active) = market.offers(offerId);
                if (active) {
                    GameLoopActor buyerActor = _actorForAddress(buyer);
                    if (address(buyerActor) != address(0)) {
                        try buyerActor.cancelBonusTargetEscrow(offerId) {}
                        catch {
                            pauseLivenessSafe = false;
                        }
                    }
                }
            }

            uint256 tokenId = _trackedLockFor(ACTOR_VICTIM, lockSeed);
            if (tokenId != 0) {
                (address seller,,,, bool activeListing) = market.listings(tokenId);
                if (activeListing && seller == address(victim) && block.number > market.lastListingActionBlock(tokenId))
                {
                    try victim.delistLock(tokenId) {}
                    catch {
                        pauseLivenessSafe = false;
                    }
                }
            }
        } catch {
            pauseLivenessSafe = false;
        }

        try market.pauseTrading(false) {}
        catch {
            pauseLivenessSafe = false;
        }

        try mineCore.setLockingPaused(true) {
            uint256 tokenId = _trackedLockFor(ACTOR_ATTACKER, lockSeed);
            if (tokenId != 0) {
                try attacker.claimAutoMaxBonus(tokenId) returns (uint256) {
                    pauseLivenessSafe = false;
                } catch {}
            }
            try rejector.withdrawKingBalanceTo(address(victim)) {}
            catch {
                pauseLivenessSafe = false;
            }
            try rejector.withdrawRefundBalance(address(victim)) {}
            catch {
                pauseLivenessSafe = false;
            }
            try rejector.withdrawPendingClaimTo(address(victim)) {}
            catch {
                pauseLivenessSafe = false;
            }
        } catch {
            pauseLivenessSafe = false;
        }

        try mineCore.setLockingPaused(false) {}
        catch {
            pauseLivenessSafe = false;
        }

        try mineCore.setTakeoversPaused(true) {
            uint256 price = mineCore.getCurrentTakeoverPrice();
            if (address(this).balance >= price) {
                try victim.takeover{value: price}(type(uint256).max) {
                    pauseLivenessSafe = false;
                } catch {}
            }
        } catch {
            pauseLivenessSafe = false;
        }

        try mineCore.setTakeoversPaused(false) {}
        catch {
            pauseLivenessSafe = false;
        }

        _assertGameState();
    }

    // ================================================================
    // Deterministic seed actions for corpus and shrink targets
    // ================================================================

    function action_seedQuoteExecuteDrift() public {
        action_enterWithQuote(ACTOR_VICTIM, Constants.MIN_LOCK_AMOUNT, Constants.MAX_LOCK_DURATION, false);
        action_extendWithQuote(ACTOR_VICTIM, 0, Constants.MAX_LOCK_DURATION);
        action_claimAutoMaxWithQuote(1);
    }

    function action_seedVictimListingGrief() public {
        action_attackerCannotMutateVictimLock(0, 0);
        action_attackerCannotMutateVictimLock(2, 0);
        action_permissionlessAutoMaxCannotDamageVictim(1);
    }

    function action_seedEscrowCycle() public {
        action_escrowCancelRoundTripNoLoss(ACTOR_ATTACKER, Constants.DEFAULT_MIN_BONUS_TARGET_ESCROW_BUDGET);
        action_escrowExecuteSellRoundTripCannotProfit(ACTOR_ATTACKER, Constants.DEFAULT_MIN_BONUS_TARGET_ESCROW_BUDGET);
        action_createEscrow(
            ACTOR_VICTIM, Constants.DEFAULT_MIN_BONUS_TARGET_ESCROW_BUDGET, 1, Constants.MAX_LOCK_DURATION
        );
        action_executeEscrow(trackedOffers.length);
    }

    function action_seedNoFreeClaimCycles() public {
        action_enterSellRoundTripCannotProfit(
            ACTOR_ATTACKER, Constants.MIN_LOCK_AMOUNT, Constants.MAX_LOCK_DURATION, false
        );
        action_extendSellRoundTripCannotProfit(ACTOR_ATTACKER, Constants.MIN_LOCK_AMOUNT);
        action_mergeSellRoundTripCannotProfit(ACTOR_ATTACKER, Constants.MIN_LOCK_AMOUNT * 2);
    }

    function action_seedExpiredCleanup() public {
        action_createEscrow(
            ACTOR_KEEPER, Constants.DEFAULT_MIN_BONUS_TARGET_ESCROW_BUDGET, 1, Constants.MAX_LOCK_DURATION
        );
        action_cancelExpiredEscrowAsKeeper(trackedOffers.length);
        action_listActorLock(ACTOR_VICTIM, 0, 1, 1);
        action_cancelExpiredListingAsKeeper(0);
    }

    function action_seedPauseLiveness() public {
        action_pauseLivenessProbe(0, 0);
    }

    function action_seedRejectingKingBuckets() public {
        uint256 price = mineCore.getCurrentTakeoverPrice();
        if (address(this).balance < price * 2) return;
        try rejector.takeover{value: price}(type(uint256).max) {} catch {}
        price = mineCore.getCurrentTakeoverPrice();
        if (address(this).balance < price) return;
        try victim.takeover{value: price}(type(uint256).max) {} catch {}
        try rejector.withdrawKingBalanceTo(address(victim)) {}
        catch {
            pauseLivenessSafe = false;
        }
        _assertGameState();
    }

    // ================================================================
    // Properties
    // ================================================================

    function echidna_global_claim_liabilities_backed() public view returns (bool) {
        return _furnaceClaimBacked() && _marketEscrowBacked() && _mineCoreClaimBacked();
    }

    function echidna_eth_liabilities_backed() public view returns (bool) {
        return _mineCoreEthBacked() && _royaltiesEthBacked();
    }

    function echidna_quote_execute_parity() public view returns (bool) {
        return quoteExecuteSafe;
    }

    function echidna_victim_griefing_blocked() public view returns (bool) {
        return victimGriefingSafe;
    }

    function echidna_pause_liveness_matrix() public view returns (bool) {
        return pauseLivenessSafe;
    }

    function echidna_no_profitable_roundtrip_cycles() public view returns (bool) {
        return noProfitableCycleSafe;
    }

    function echidna_closed_offers_hold_no_funds() public view returns (bool) {
        for (uint256 i = 0; i < trackedOffers.length; ++i) {
            (,,,,, uint256 fundsRemaining,,, bool active) = market.offers(trackedOffers[i]);
            if (!active && fundsRemaining != 0) return false;
        }
        return true;
    }

    function echidna_market_escrow_accounting_exact() public view returns (bool) {
        uint256 sum;
        for (uint256 i = 0; i < trackedOffers.length; ++i) {
            (,,,,, uint256 fundsRemaining,,, bool active) = market.offers(trackedOffers[i]);
            if (active) sum += fundsRemaining;
        }
        return sum == market.totalEscrowedClaim();
    }

    function echidna_listed_state_matches_market() public view returns (bool) {
        uint256 len = _allLockCount();
        for (uint256 i = 0; i < len; ++i) {
            uint256 tokenId = _anyTrackedLock(i);
            if (tokenId == 0 || lockClosed[tokenId]) continue;
            (address seller,,,, bool active) = market.listings(tokenId);
            LockSnapshot memory s = _snapshotLock(tokenId);
            if (!s.exists) continue;
            if (s.listed && !active) return false;
            (,,, bool listed) = ve.getLockInfo(tokenId);
            if (active && (seller == address(0) || !listed)) return false;
            if (active && seller != s.owner) return false;
        }
        return true;
    }

    function echidna_tracked_lock_ownership_safe() public view returns (bool) {
        uint256 len = _allLockCount();
        for (uint256 i = 0; i < len; ++i) {
            uint256 tokenId = _anyTrackedLock(i);
            if (tokenId == 0 || lockClosed[tokenId]) continue;
            LockSnapshot memory s = _snapshotLock(tokenId);
            if (!s.exists) continue;
            uint8 actorId = trackedLockActor[tokenId];
            if (s.owner != address(_actor(actorId))) return false;
        }
        return true;
    }

    function echidna_current_king_not_protocol_owned() public view returns (bool) {
        address king = mineCore.currentKing();
        if (king == address(0)) return mineCore.currentReignId() == 0;
        if (king == address(this)) return false;
        if (king == address(claim) || king == address(ve) || king == address(furnace)) return false;
        if (king == address(market) || king == address(royalties) || king == address(mineCore)) return false;
        return
            king == address(victim) || king == address(attacker) || king == address(keeper) || king == address(rejector);
    }

    // ================================================================
    // Internal helpers
    // ================================================================

    function _seedActorLock(uint8 actorId, uint256 amount, uint256 duration, bool autoMax) internal {
        GameLoopActor actor_ = _actor(actorId);
        uint256 veOut;
        try quoter.quoteEnterWithClaim(address(actor_), amount, 0, duration, autoMax) returns (
            uint256, uint256, uint256 quotedVeOut, uint256
        ) {
            veOut = quotedVeOut;
        } catch {
            return;
        }
        if (veOut == 0) return;
        try actor_.enterWithClaim(amount, 0, duration, autoMax, veOut) returns (uint256 tokenId) {
            _recordLock(actorId, tokenId);
        } catch {}
    }

    function _recordLock(uint8 actorId, uint256 tokenId) internal {
        if (tokenId == 0 || trackedLock[tokenId]) return;
        trackedLock[tokenId] = true;
        trackedLockActor[tokenId] = actorId;
        if (actorId == ACTOR_VICTIM) {
            victimLocks.push(tokenId);
        } else if (actorId == ACTOR_ATTACKER) {
            attackerLocks.push(tokenId);
        } else if (actorId == ACTOR_KEEPER) {
            keeperLocks.push(tokenId);
        } else {
            rejectorLocks.push(tokenId);
        }
    }

    function _actor(uint8 actorSeed) internal view returns (GameLoopActor) {
        uint8 actorId = actorSeed % 4;
        if (actorId == ACTOR_VICTIM) return victim;
        if (actorId == ACTOR_ATTACKER) return attacker;
        if (actorId == ACTOR_KEEPER) return keeper;
        return rejector;
    }

    function _actorForAddress(address user) internal view returns (GameLoopActor) {
        if (user == address(victim)) return victim;
        if (user == address(attacker)) return attacker;
        if (user == address(keeper)) return keeper;
        if (user == address(rejector)) return rejector;
        return GameLoopActor(payable(address(0)));
    }

    function _trackedLockFor(uint8 actorId, uint256 seed) internal view returns (uint256) {
        if (actorId == ACTOR_VICTIM) return victimLocks.length == 0 ? 0 : victimLocks[seed % victimLocks.length];
        if (actorId == ACTOR_ATTACKER) {
            return attackerLocks.length == 0 ? 0 : attackerLocks[seed % attackerLocks.length];
        }
        if (actorId == ACTOR_KEEPER) return keeperLocks.length == 0 ? 0 : keeperLocks[seed % keeperLocks.length];
        return rejectorLocks.length == 0 ? 0 : rejectorLocks[seed % rejectorLocks.length];
    }

    function _anyTrackedLock(uint256 seed) internal view returns (uint256) {
        uint256 total = _allLockCount();
        if (total == 0) return 0;
        uint256 idx = seed % total;
        if (idx < victimLocks.length) return victimLocks[idx];
        idx -= victimLocks.length;
        if (idx < attackerLocks.length) return attackerLocks[idx];
        idx -= attackerLocks.length;
        if (idx < keeperLocks.length) return keeperLocks[idx];
        idx -= keeperLocks.length;
        return rejectorLocks[idx];
    }

    function _allLockCount() internal view returns (uint256) {
        return victimLocks.length + attackerLocks.length + keeperLocks.length + rejectorLocks.length;
    }

    function _trackedOffer(uint256 seed) internal view returns (uint256) {
        if (trackedOffers.length == 0) return 0;
        return trackedOffers[seed % trackedOffers.length];
    }

    function _boundedDuration(uint256 seed) internal pure returns (uint256) {
        uint256 span = Constants.MAX_LOCK_DURATION - Constants.MIN_LOCK_DURATION;
        return Constants.MIN_LOCK_DURATION + (seed % (span + 1));
    }

    function _boundedClaimAmount(address user, uint256 seed, uint256 minAmount, uint256 maxAmount)
        internal
        view
        returns (uint256)
    {
        uint256 bal = claim.balanceOf(user);
        if (bal < minAmount) return 0;
        uint256 cap = bal < maxAmount ? bal : maxAmount;
        if (cap <= minAmount) return minAmount;
        return minAmount + (seed % (cap - minAmount + 1));
    }

    function _snapshotLock(uint256 tokenId) internal view returns (LockSnapshot memory s) {
        try ve.ownerOf(tokenId) returns (address owner_) {
            s.exists = true;
            s.owner = owner_;
        } catch {
            return s;
        }

        try ve.getLockInfo(tokenId) returns (uint256 amount, uint256 lockEnd, bool autoMax, bool listed) {
            s.amount = amount;
            s.lockEnd = lockEnd;
            s.autoMax = autoMax;
            s.listed = listed;
        } catch {
            s.exists = false;
        }
    }

    function _sameLockState(LockSnapshot memory a, LockSnapshot memory b) internal pure returns (bool) {
        if (a.exists != b.exists) return false;
        if (!a.exists) return true;
        return a.owner == b.owner && a.amount == b.amount && a.lockEnd == b.lockEnd && a.autoMax == b.autoMax
            && a.listed == b.listed;
    }

    function _assertGlobalBacking() internal view {
        assert(_furnaceClaimBacked());
        assert(_marketEscrowBacked());
        assert(_mineCoreClaimBacked());
        assert(_mineCoreEthBacked());
        assert(_royaltiesEthBacked());
    }

    function _assertGameState() internal view {
        _assertGlobalBacking();
        assert(this.echidna_market_escrow_accounting_exact());
        assert(this.echidna_listed_state_matches_market());
        assert(this.echidna_tracked_lock_ownership_safe());
        assert(this.echidna_current_king_not_protocol_owned());
    }

    function _furnaceClaimBacked() internal view returns (bool) {
        return claim.balanceOf(address(furnace)) >= furnace.furnaceReserve() + furnace.getLpStreamRemaining();
    }

    function _marketEscrowBacked() internal view returns (bool) {
        if (claim.balanceOf(address(market)) < market.totalEscrowedClaim()) return false;
        for (uint256 i = 0; i < trackedOffers.length; ++i) {
            (,,,,, uint256 fundsRemaining,,, bool active) = market.offers(trackedOffers[i]);
            if (!active && fundsRemaining != 0) return false;
        }
        return true;
    }

    function _mineCoreClaimBacked() internal view returns (bool) {
        return claim.balanceOf(address(mineCore)) >= mineCore.totalPendingKingClaim();
    }

    function _mineCoreEthBacked() internal view returns (bool) {
        uint256 tracked = mineCore.totalKingEthOwed() + mineCore.totalRefundEthOwed() + mineCore.shareholderEthPending();
        return address(mineCore).balance >= tracked;
    }

    function _royaltiesEthBacked() internal view returns (bool) {
        return address(royalties).balance >= royalties.pendingShareholderETH();
    }
}
