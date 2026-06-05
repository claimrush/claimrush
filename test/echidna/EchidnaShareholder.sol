// SPDX-License-Identifier: MIT
pragma solidity ^0.8.34;

import {EchidnaSetup} from "./EchidnaSetup.sol";
import {Constants} from "src/lib/Constants.sol";
import {DelegationPermissions} from "src/lib/DelegationPermissions.sol";
import {ClaimAllHelper} from "src/ClaimAllHelper.sol";

/// @dev Delegate ("looping bot") that pulls a Baron's shareholder ETH to itself via
///      the caller-only helper path. Accepts the routed ETH so custody genuinely
///      leaves ShareholderRoyalties.
contract ShareholderLoopBot {
    function pull(ClaimAllHelper helper, address user) external {
        helper.claimShareholderToCallerForUser(user);
    }

    receive() external payable {}
}

/// @title Echidna harness for ShareholderRoyalties ETH index solvency and flush safety.
/// @dev Invariants from the invariants document Section 5.
contract EchidnaShareholder is EchidnaSetup {
    address[3] internal actors;

    ShareholderLoopBot internal loopBot;

    constructor() payable {
        _deployAndWire();
        actors[0] = address(0x20000);
        actors[1] = address(0x30000);
        actors[2] = address(0x40000);
        loopBot = new ShareholderLoopBot();
    }

    // ================================================================
    // Actions
    // ================================================================

    /// @dev Takeover to fund shareholders
    function action_takeover() public payable {
        uint256 price = mineCore.getCurrentTakeoverPrice();
        if (msg.value < price) return;
        try mineCore.takeover{value: price}(type(uint256).max) {} catch {}
    }

    /// @dev Flush pending shareholder ETH
    function action_flush() public {
        try royalties.flushPendingShareholderETH() {} catch {}
    }

    /// @dev Checkpoint a user
    function action_checkpointUser(uint256 actorIdx) public {
        address user = actors[actorIdx % 3];
        royalties.checkpointUser(user);
    }

    /// @dev Claim shareholder ETH
    function action_claimShareholder() public {
        try royalties.claimShareholder(Constants.SHAREHOLDER_MODE_ETH, 0, 0, false, 0) {} catch {}
    }

    /// @dev Enter Furnace to create ve locks (needed for ve balance)
    function action_enterFurnace(uint256 amount, uint256 durationSeconds) public {
        if (amount < Constants.MIN_LOCK_AMOUNT) amount = Constants.MIN_LOCK_AMOUNT;
        if (amount > 5_000_000e18) amount = 5_000_000e18;
        if (durationSeconds < Constants.MIN_LOCK_DURATION) durationSeconds = Constants.MIN_LOCK_DURATION;
        if (durationSeconds > Constants.MAX_LOCK_DURATION) durationSeconds = Constants.MAX_LOCK_DURATION;
        mineCore.mintClaimForTest(address(this), amount);
        claim.approve(address(furnace), amount);
        (,, uint256 veOut,) = quoter.quoteEnterWithClaim(address(this), amount, 0, durationSeconds, false);
        if (veOut == 0) return;
        try furnace.enterWithClaim(amount, 0, durationSeconds, false, veOut) {} catch {}
    }

    /// @dev Set auto-compound config (claim as lock mode)
    function action_setAutoCompoundConfig(uint256 durationSeconds) public {
        if (durationSeconds < Constants.MIN_LOCK_DURATION) durationSeconds = Constants.MIN_LOCK_DURATION;
        if (durationSeconds > Constants.MAX_LOCK_DURATION) durationSeconds = Constants.MAX_LOCK_DURATION;
        try royalties.setAutoCompoundConfig(true, 0, durationSeconds, 86400, 0, 500) {} catch {}
    }

    /// @dev Claim shareholder ETH and lock via Furnace (mode=1)
    function action_claimShareholderAndLock(uint256 durationSeconds) public {
        if (durationSeconds < Constants.MIN_LOCK_DURATION) durationSeconds = Constants.MIN_LOCK_DURATION;
        if (durationSeconds > Constants.MAX_LOCK_DURATION) durationSeconds = Constants.MAX_LOCK_DURATION;
        try royalties.claimShareholder(Constants.SHAREHOLDER_MODE_LOCK_FURNACE, 0, durationSeconds, false, 0) {}
            catch {}
    }

    /// @dev Delegated caller-only routing of Baron ETH through ClaimAllHelper.
    ///      `address(this)` is the Baron (grantor); `loopBot` is the delegate. With the
    ///      route bit granted, the helper forwards the Baron's collected ETH to the bot
    ///      (custody leaves the contract). The strict disjoint-buckets and crystallised-
    ///      sum identities must hold across the move; without the route bit the call must
    ///      revert and leave state untouched.
    function action_claimShareholderToCallerForUser(bool grantRouteBit) public {
        uint256 perms = DelegationPermissions.P_CLAIM_SHAREHOLDER_FOR;
        if (grantRouteBit) {
            perms |= DelegationPermissions.P_ROUTE_SHAREHOLDER_ETH_TO_CALLER;
        }
        try delegationHub.setSession(address(loopBot), perms, type(uint64).max) {}
        catch {
            return;
        }
        try loopBot.pull(claimAllHelper, address(this)) {} catch {}
    }

    // ================================================================
    // Properties
    // ================================================================

    /// @dev Invariant §5: STRICT physical solvency.
    ///      `Σ _claimableEthStored(actor) + pendingShareholderETH <= address(this).balance`.
    ///      The bookkeeping invariant that must never be violated: every wei the
    ///      contract has already committed to a user (via the `_claimableEthStored`
    ///      mapping) plus the un-flushed pending carry must fit inside actual custody.
    function echidna_shareholder_physical_solvency() public view returns (bool) {
        uint256 totalStored = 0;
        for (uint256 i = 0; i < 3; i++) {
            totalStored += royalties.claimableEthStored(actors[i]);
        }
        totalStored += royalties.claimableEthStored(address(this));
        uint256 pending = royalties.pendingShareholderETH();
        uint256 balance = address(royalties).balance;
        return totalStored + pending <= balance;
    }

    /// @dev Invariant §5: STRICT disjoint-buckets identity.
    ///      `Σ _claimableEthStored(actor) + indexedEthOwed + pendingShareholderETH
    ///        == address(this).balance` at every external entry boundary.
    ///      The three buckets partition the contract's ETH custody: crystallised
    ///      user stored claims, indexed-but-uncrystallised, and un-flushed pending
    ///      carry. Holds with no tolerance because `checkpointUser` clamps the per-
    ///      user credit to the available indexed pool (see `ShareholderRoyalties.sol
    ///      checkpointUser` — M-AccountingFloorDrift class).
    function echidna_shareholder_disjoint_buckets_exact() public view returns (bool) {
        uint256 totalStored = 0;
        for (uint256 i = 0; i < 3; i++) {
            totalStored += royalties.claimableEthStored(actors[i]);
        }
        totalStored += royalties.claimableEthStored(address(this));
        uint256 indexedBucket = royalties.indexedEthOwed();
        uint256 pending = royalties.pendingShareholderETH();
        uint256 balance = address(royalties).balance;
        return totalStored + indexedBucket + pending == balance;
    }

    /// @dev Invariant §5: O(1) aggregator agreement.
    ///      `totalCrystallisedStored == Σ_actor _claimableEthStored(actor)`.
    ///      Probes the `totalCrystallisedStored` accumulator that `sweepDust` reads
    ///      to skip crystallised user claims; any divergence here would let dust-
    ///      sweeping touch ETH that backs unclaimed user balances.
    function echidna_total_crystallised_matches_sum() public view returns (bool) {
        uint256 perUserSum = 0;
        for (uint256 i = 0; i < 3; i++) {
            perUserSum += royalties.claimableEthStored(actors[i]);
        }
        perUserSum += royalties.claimableEthStored(address(this));
        return royalties.totalCrystallisedStored() == perUserSum;
    }

    /// @dev Invariant §5: pendingShareholderETH should not exceed contract balance.
    function echidna_pending_leq_balance() public view returns (bool) {
        return royalties.pendingShareholderETH() <= address(royalties).balance;
    }
}
