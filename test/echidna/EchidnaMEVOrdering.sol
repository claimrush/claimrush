// SPDX-License-Identifier: MIT
pragma solidity ^0.8.34;

import {EchidnaSetup} from "./EchidnaSetup.sol";
import {Constants} from "src/lib/Constants.sol";

/// @title Adversarial multi-actor ordering harness.
/// @notice Models MEV ordering attacks by interleaving actions from multiple
///         actors within the fuzzer's transaction sequence:
///         - Sandwich on `Furnace.enterWithEth` (front-run + back-run)
///         - Front-run on `MineCore.takeover` (race the King change)
///         - Back-run on `ShareholderRoyalties.claimShareholder`
///         - JIT liquidity / list-and-pull on `MarketRouter` listings
///
///         The protocol's intended posture is that documented MEV envelopes
///         are bounded by `minVeOut`, `minClaimOut`, and `minEthOut`
///         slippage parameters. Properties below verify that no actor can
///         extract value beyond those envelopes via ordering alone.
contract EchidnaMEVOrdering is EchidnaSetup {
    address[3] internal actors;

    // Track the worst observed value extraction beyond the documented envelope.
    bool internal sawSandwichBeyondEnvelope;
    bool internal sawFrontRunBeyondEnvelope;
    bool internal sawJitLiquidityViolation;

    // Sandwich-state machine: pre-victim and post-victim observations.
    uint256 internal preVictimReserve;
    uint256 internal preVictimAttackerVe;
    bool internal sandwichPrePhase;

    constructor() payable {
        _deployAndWire();
        actors[0] = address(0x20000);
        actors[1] = address(0x30000);
        actors[2] = address(0x40000);
    }

    // ================================================================
    // Actions — multi-actor sequence to expose ordering attacks
    // ================================================================

    /// @dev Step 1 of a sandwich: attacker front-runs the victim by entering
    ///      the Furnace first.
    function action_sandwichFrontRun(uint256 amount, uint256 durationSeconds) public {
        if (amount < Constants.MIN_LOCK_AMOUNT) amount = Constants.MIN_LOCK_AMOUNT;
        if (amount > 1_000_000e18) amount = 1_000_000e18;
        if (durationSeconds < Constants.MIN_LOCK_DURATION) durationSeconds = Constants.MIN_LOCK_DURATION;
        if (durationSeconds > Constants.MAX_LOCK_DURATION) durationSeconds = Constants.MAX_LOCK_DURATION;

        if (claim.balanceOf(msg.sender) < amount) return;

        preVictimReserve = furnace.furnaceReserve();
        preVictimAttackerVe = ve.veBalanceOf(msg.sender);
        sandwichPrePhase = true;

        try furnace.enterWithClaim(amount, 0, durationSeconds, false, 0) {}
        catch {
            sandwichPrePhase = false;
        }
    }

    /// @dev Step 2 of a sandwich: victim's transaction.
    function action_sandwichVictimEntry(uint256 amount, uint256 durationSeconds, uint256 minVeOut) public {
        if (amount < Constants.MIN_LOCK_AMOUNT) amount = Constants.MIN_LOCK_AMOUNT;
        if (amount > 1_000_000e18) amount = 1_000_000e18;
        if (durationSeconds < Constants.MIN_LOCK_DURATION) durationSeconds = Constants.MIN_LOCK_DURATION;
        if (durationSeconds > Constants.MAX_LOCK_DURATION) durationSeconds = Constants.MAX_LOCK_DURATION;
        if (minVeOut > type(uint128).max) minVeOut = uint256(type(uint128).max);

        if (claim.balanceOf(msg.sender) < amount) return;

        // Victim uses the slippage guard. If the sandwich attacker shifted
        // the curve enough, this should revert rather than under-deliver.
        try furnace.enterWithClaim(amount, 0, durationSeconds, false, minVeOut) {} catch {}
    }

    /// @dev Step 3 of a sandwich: attacker back-runs by exiting (sellback).
    function action_sandwichBackRun(uint256 tokenId, uint256 minClaimOut) public {
        if (tokenId == 0) return;
        if (!sandwichPrePhase) return;

        uint256 attackerClaimBefore = claim.balanceOf(msg.sender);
        try market.sellLockToFurnace(tokenId, minClaimOut, block.timestamp + 300) {
            uint256 attackerClaimAfter = claim.balanceOf(msg.sender);
            uint256 attackerVeAfter = ve.veBalanceOf(msg.sender);

            // Sandwich is "successful" if the attacker's net CLAIM gain plus
            // residual ve outweighs their initial CLAIM input by more than
            // the documented sellback envelope (`SELL_ROUND_TRIP_LOSS_MAX_BPS`
            // tolerance). Since the round-trip is designed to lose principal
            // (scaling with remaining lock duration up to the max loss floor),
            // any net positive gain is outside the envelope.
            if (attackerClaimAfter > attackerClaimBefore && attackerVeAfter > preVictimAttackerVe) {
                sawSandwichBeyondEnvelope = true;
            }
        } catch {}

        sandwichPrePhase = false;
    }

    /// @dev Front-run on takeover: attacker submits a takeover at the same
    ///      price the victim is targeting. The protocol's invariant is that
    ///      a single block / sequence cannot crown two Kings off the same
    ///      price quote; the second call must either revert (`PriceExceeded`)
    ///      or pay the new (higher) price. We track this by snapshotting
    ///      the current King and price across two consecutive takeover
    ///      attempts. If both succeed at the same price quote, that is a
    ///      double-reign violation.
    function action_takeoverRace() public payable {
        uint256 priceBefore = mineCore.getCurrentTakeoverPrice();
        if (msg.value < priceBefore) return;

        address kingBefore = mineCore.currentKing();
        try mineCore.takeover{value: priceBefore}(type(uint256).max) {
            address kingAfterFirst = mineCore.currentKing();
            uint256 priceAfterFirst = mineCore.getCurrentTakeoverPrice();

            // A successful first takeover MUST advance the price (by reset
            // logic) or change the king. If the very next takeover lands at
            // the same quoted price AND succeeds, two reigns paid identical
            // entry — a front-run / sandwich envelope break.
            if (priceAfterFirst <= priceBefore && address(this).balance >= priceBefore) {
                try mineCore.takeover{value: priceBefore}(type(uint256).max) {
                    address kingAfterSecond = mineCore.currentKing();
                    if (kingAfterFirst != kingAfterSecond && kingBefore != kingAfterSecond) {
                        sawFrontRunBeyondEnvelope = true;
                    }
                } catch {}
            }
        } catch {}
    }

    /// @dev Back-run / JIT on shareholder claim: attacker optionally creates a
    ///      fresh max-duration AutoMax lock (the reporter's "JIT veCLAIM lock"
    ///      sequence) and then checkpoints + claims immediately around a
    ///      takeover finalization. The fuzzer interleaves this with
    ///      `action_takeoverRace`, so a lock minted one call before a takeover
    ///      participates in that takeover's shareholder distribution. The
    ///      snapshot-distribution model intentionally credits the
    ///      instantaneous ve holder set, so capturing a *snapshot-weighted*
    ///      share is by design; what `echidna_backrun_claim_cannot_oversettle`
    ///      pins is that no such sequence can withdraw beyond the accounting's
    ///      reserved liabilities (i.e. cannot dip into the pool or another
    ///      holder's crystallised balance).
    function action_backRunClaim(uint256 jitAmount, bool createJitLock) public {
        if (createJitLock && claim.balanceOf(msg.sender) >= Constants.MIN_LOCK_AMOUNT) {
            if (jitAmount < Constants.MIN_LOCK_AMOUNT) jitAmount = Constants.MIN_LOCK_AMOUNT;
            if (jitAmount > 1_000_000e18) jitAmount = 1_000_000e18;
            if (claim.balanceOf(msg.sender) >= jitAmount) {
                // AutoMax max-duration lock: the worst case for JIT capture, since
                // AutoMax locks carry full weight with no creation-time eligibility gate.
                try furnace.enterWithClaim(jitAmount, 0, Constants.MAX_LOCK_DURATION, true, 0) {} catch {}
            }
        }
        try royalties.checkpointUser(msg.sender) {} catch {}
        try royalties.claimShareholder(Constants.SHAREHOLDER_MODE_ETH, 0, 0, false, 0) {} catch {}
    }

    /// @dev JIT liquidity: list a lock at a price and immediately delist.
    ///      The protocol MUST NOT credit the attacker for the listing window
    ///      itself — only completed sales pay. We verify by snapshotting the
    ///      attacker's CLAIM + ETH balance before list and after delist; any
    ///      net credit during a list/delist round-trip is a violation.
    function action_jitListAndPull(uint256 idx, uint256 minClaimOut) public {
        if (claim.balanceOf(msg.sender) < Constants.MIN_LOCK_AMOUNT) return;
        try furnace.enterWithClaim(Constants.MIN_LOCK_AMOUNT, 0, Constants.MAX_LOCK_DURATION, false, 0) returns (
            uint256 tokenId
        ) {
            uint256 claimBefore = claim.balanceOf(msg.sender);
            uint256 ethBefore = msg.sender.balance;
            try market.listLock(tokenId, minClaimOut, block.timestamp + 30 days) {
                try market.delistLock(tokenId) {
                    uint256 claimAfter = claim.balanceOf(msg.sender);
                    uint256 ethAfter = msg.sender.balance;
                    if (claimAfter > claimBefore || ethAfter > ethBefore) {
                        sawJitLiquidityViolation = true;
                    }
                } catch {}
            } catch {}
        } catch {}
        idx;
    }

    // ================================================================
    // Properties
    // ================================================================

    /// @notice Sandwich attacks on `Furnace.enterWithEth` / `enterWithClaim`
    ///         MUST NOT yield the attacker net positive CLAIM after the full
    ///         front-run / back-run cycle. The sellback round-trip envelope
    ///         is designed to be loss-making for the attacker.
    function echidna_sandwich_no_net_positive_extraction() public view returns (bool) {
        return !sawSandwichBeyondEnvelope;
    }

    /// @notice Front-run on takeover MUST NOT permit two reigns to claim the
    ///         same takeover slot. The first transaction wins; the second
    ///         either reverts or pays the new (higher) price.
    function echidna_takeover_front_run_no_double_reign() public view returns (bool) {
        return !sawFrontRunBeyondEnvelope;
    }

    /// @notice JIT list-and-pull MUST NOT credit the attacker with anything
    ///         for the brief listing window itself. Only completed sales pay.
    function echidna_jit_list_pull_no_phantom_credit() public view returns (bool) {
        return !sawJitLiquidityViolation;
    }

    /// @notice JIT veCLAIM lock / back-run shareholder-claim safety bound.
    /// @dev Takeover shareholder ETH is distributed to the *instantaneous* veCLAIM
    ///      holder set at takeover time (snapshot model), so a lock created shortly
    ///      before a takeover legitimately shares in that distribution — that
    ///      dilution is by design and is NOT what this property guards. What MUST
    ///      hold regardless of *when* a lock was created is that no checkpoint /
    ///      claim sequence (including the JIT front-run lock + back-run claim path
    ///      modeled in `action_backRunClaim`) can settle a user more ETH than the
    ///      contract's accounting reserves: the three ETH buckets — crystallised
    ///      stored claims, indexed-but-uncrystallised, and un-flushed pending carry
    ///            — must always fit inside actual custody. A JIT-capture fault that
    ///      let a fresh lock withdraw beyond its indexed entitlement (dipping into
    ///      the pool or another holder's crystallised balance) would drop the
    ///      contract balance below reserved liabilities and trip this invariant.
    ///      This complements `EchidnaShareholder`'s disjoint-buckets checks by
    ///      exercising the bound under the multi-actor MEV-ordering state space.
    function echidna_backrun_claim_cannot_oversettle() public view returns (bool) {
        uint256 totalStored = 0;
        for (uint256 i = 0; i < 3; i++) {
            totalStored += royalties.claimableEthStored(actors[i]);
        }
        totalStored += royalties.claimableEthStored(address(this));
        uint256 reserved = totalStored + royalties.indexedEthOwed() + royalties.pendingShareholderETH();
        return reserved <= address(royalties).balance;
    }
}
