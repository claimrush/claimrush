// SPDX-License-Identifier: MIT
pragma solidity ^0.8.34;

import {EchidnaSetup} from "../EchidnaSetup.sol";
import {Constants} from "src/lib/Constants.sol";

/// @title ShareholderRoyalties economic worst-case search.
/// @notice Optimization-mode harness. Targets over-claim, index-drift, and
///         disjoint-bucket excess. Each `optimize_*` function returns an
///         `int256` Echidna maximizes; positive values indicate accounting
///         deviation from the M3 conservation envelope.
contract EchidnaShareholderOptimize is EchidnaSetup {
    address[3] internal actors;

    int256 internal worstStoredAboveBalance;
    int256 internal worstBucketSumAboveBalance;
    int256 internal worstActorEthGainAboveZero;

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
        mineCore.mintClaimForTest(address(this), amount);
        claim.approve(address(furnace), amount);
        try furnace.enterWithClaim(amount, 0, durationSeconds, false, 0) {} catch {}
    }

    function action_flush() public {
        try royalties.flushPendingShareholderETH() {} catch {}
    }

    function action_checkpointUser(uint256 actorIdx) public {
        royalties.checkpointUser(actors[actorIdx % 3]);
    }

    function action_claimShareholder() public {
        uint256 ethBefore = msg.sender.balance;
        try royalties.claimShareholder(Constants.SHAREHOLDER_MODE_ETH, 0, 0, false, 0) {
            uint256 ethAfter = msg.sender.balance;
            if (ethAfter > ethBefore) {
                int256 gain = int256(ethAfter - ethBefore);
                if (gain > worstActorEthGainAboveZero) worstActorEthGainAboveZero = gain;
            }
        } catch {}
    }

    function action_observeStoredAboveBalance() public {
        uint256 totalStored = 0;
        for (uint256 i = 0; i < 3; i++) {
            totalStored += royalties.claimableEthStored(actors[i]);
        }
        totalStored += royalties.claimableEthStored(address(this));
        uint256 pending = royalties.pendingShareholderETH();
        uint256 balance = address(royalties).balance;
        int256 above = int256(totalStored + pending) - int256(balance);
        if (above > worstStoredAboveBalance) worstStoredAboveBalance = above;
    }

    function action_observeBucketSumAboveBalance() public {
        uint256 totalStored = 0;
        for (uint256 i = 0; i < 3; i++) {
            totalStored += royalties.claimableEthStored(actors[i]);
        }
        totalStored += royalties.claimableEthStored(address(this));
        uint256 indexedBucket = royalties.indexedEthOwed();
        uint256 pending = royalties.pendingShareholderETH();
        uint256 balance = address(royalties).balance;
        int256 above = int256(totalStored + indexedBucket + pending) - int256(balance);
        if (above > worstBucketSumAboveBalance) worstBucketSumAboveBalance = above;
    }

    // ================================================================
    // Optimization targets
    // ================================================================

    /// @notice Worst observed surplus of `Σstored + pending` over the contract
    ///         ETH balance. Must remain `<= 0` (M3 physical solvency).
    function optimize_shareholder_storedAboveBalance() public view returns (int256) {
        return worstStoredAboveBalance;
    }

    /// @notice Worst observed surplus of `Σstored + indexedEthOwed + pending`
    ///         over the contract ETH balance. Must remain `<= 0` (M3 disjoint
    ///         bucket identity, no slack).
    function optimize_shareholder_bucketSumAboveBalance() public view returns (int256) {
        return worstBucketSumAboveBalance;
    }

    /// @notice Worst single-call ETH gain to a claiming actor. Bounded by the
    ///         intended royalty envelope; sustained large values indicate
    ///         claim-path exploit.
    function optimize_shareholder_actorEthGainPerClaim() public view returns (int256) {
        return worstActorEthGainAboveZero;
    }
}
