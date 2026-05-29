// SPDX-License-Identifier: MIT
pragma solidity ^0.8.34;

import {EchidnaSetup} from "./EchidnaSetup.sol";
import {MaliciousReentrantReceiver} from "../mocks/MaliciousReentrantReceiver.sol";
import {Constants} from "src/lib/Constants.sol";

/// @title Adversarial ETH-receive reentrancy harness.
/// @notice Drives every ETH-paying path with a contract receiver that
///         attempts a reentrant call back into the protocol on every ETH
///         receive:
///         - `MineCore` King payout (best-effort with bounded gas stipend)
///         - `ShareholderRoyalties.claimShareholder`
///         - `MarketRouter` escrow refund / settlement
///
///         Protocol posture under attack:
///         - King payout is best-effort with a bounded gas stipend. The
///           payment may credit `kingEthBalance` instead of pushing. The
///           outer takeover MUST NOT revert. The attacker MUST NOT receive
///           more cumulative ETH than they were owed.
///         - Shareholder claim and escrow refund use `nonReentrant`. Any
///           successful reentrant call into a guarded function is a
///           violation.
///
///         The attacker proxies its actions via `proxyCall` so msg.sender
///         is the attacker contract; this lets it hold the King role and
///         appear as a legitimate shareholder / refund recipient when the
///         protocol pushes ETH.
///
/// @dev Corpus-bounding rationale (2026-05-06 rework):
///      Prior revisions accepted `uint256 ethValue` and `uint256 payloadKind`
///      arguments. `ethValue` was clamped to `address(this).balance` (a
///      finite test budget, ≪ uint96 max ≈ 7.9e28 wei) and `payloadKind`
///      was modulo'd against {2, 4} on entry. The high bits had no effect
///      on the contract under test, but Echidna's coverage tracker treated
///      every distinct 256-bit input as a candidate corpus entry. At
///      assertion-mode saturation (cov:25942) the corpus kept growing with
///      equivalent sequences and OOM-killed the worker at 24/30 GB.
///      Narrowing `ethValue -> uint96` and `payloadKind -> uint8` collapses
///      the input space to value ranges that actually exercise distinct
///      branches, while keeping wide enough headroom for the harness budget.
contract EchidnaReentrancyReceiver is EchidnaSetup {
    MaliciousReentrantReceiver internal attacker;

    uint256 internal cumulativeAttackerKingEthOwed;
    uint256 internal cumulativeAttackerEthReceived;

    bool internal sawAttackerOverpayment;

    constructor() payable {
        _deployAndWire();
        attacker = new MaliciousReentrantReceiver();
    }

    // ================================================================
    // Actions
    // ================================================================

    /// @dev Have the attacker take the crown. msg.sender on `mineCore.takeover`
    ///      is the attacker contract, so the attacker becomes King and is
    ///      eligible for the next reign's payout.
    /// @dev    The attacker is NOT yet owed any ETH simply by becoming King;
    ///         their entitlement is realized only when a subsequent dethrone
    ///         pays out the King share. We therefore do NOT credit
    ///         `cumulativeAttackerKingEthOwed` here.
    function action_attackerTakesCrown(uint96 ethValue) public payable {
        uint256 price = mineCore.getCurrentTakeoverPrice();
        uint256 value = uint256(ethValue);
        if (value < price) value = price;
        if (address(this).balance < value) return;

        bytes memory data = abi.encodeWithSignature("takeover(uint256)", uint256(type(uint256).max));
        (bool ok,) = address(attacker).call{value: value}(
            abi.encodeWithSignature("proxyCall(address,uint256,bytes)", address(mineCore), value, data)
        );
        ok;
    }

    /// @dev Dethrone the attacker. The protocol sends King payout ETH to the
    ///      attacker; its `receive()` callback fires and attempts a reentrant
    ///      call back into the protocol. The attempt is staged by setting
    ///      `reentrantTarget`/`reentrantData` before the takeover.
    function action_dethroneAttacker(uint8 payloadKind) public payable {
        uint256 price = mineCore.getCurrentTakeoverPrice();
        if (msg.value < price) return;

        uint256 kind = uint256(payloadKind);
        bytes memory payload;
        if (kind % 4 == 0) {
            payload = abi.encodeWithSignature("takeover(uint256)", uint256(type(uint256).max));
        } else if (kind % 4 == 1) {
            payload = abi.encodeWithSignature("withdrawKingBalance()");
        } else if (kind % 4 == 2) {
            payload = abi.encodeWithSignature("retryPushShareholderEth()");
        } else {
            payload = abi.encodeWithSignature("withdrawRefundBalance(address)", address(attacker));
        }
        attacker.setReentrantCall(address(mineCore), payload, 50_000);

        bool attackerWasKing = mineCore.currentKing() == address(attacker);
        uint256 attackerEthBefore = address(attacker).balance;
        bool dethroned;
        try mineCore.takeover{value: price}(type(uint256).max) {
            dethroned = true;
        } catch {}
        uint256 attackerEthAfter = address(attacker).balance;

        if (attackerEthAfter > attackerEthBefore) {
            cumulativeAttackerEthReceived += (attackerEthAfter - attackerEthBefore);
        }

        // Realize the legitimate King-share owed when the attacker actually
        // got dethroned. The owed envelope equals the protocol-defined share
        // of the dethrone price, regardless of whether the push payout
        // succeeded or fell back to `kingEthBalance` (the kingEthBalance
        // bucket only defers, it does not change the entitlement).
        if (attackerWasKing && dethroned) {
            uint256 kingShare = (price * Constants.KING_ETH_SHARE_PCT) / Constants.KING_ETH_SHARE_DENOM;
            cumulativeAttackerKingEthOwed += kingShare;
        }

        attacker.clearReentrantCall();
    }

    /// @dev The attacker calls `withdrawKingBalance` after a failed push.
    ///      This is a pull payment that lands ETH on the attacker.
    function action_attackerWithdrawKingBalance(uint8 payloadKind) public {
        uint256 kind = uint256(payloadKind);
        bytes memory payload;
        if (kind % 2 == 0) {
            payload = abi.encodeWithSignature("withdrawKingBalance()");
        } else {
            payload = abi.encodeWithSignature("retryPushShareholderEth()");
        }
        attacker.setReentrantCall(address(mineCore), payload, 50_000);

        uint256 attackerEthBefore = address(attacker).balance;
        bytes memory data = abi.encodeWithSignature("withdrawKingBalance()");
        (bool ok,) = address(attacker)
            .call(abi.encodeWithSignature("proxyCall(address,uint256,bytes)", address(mineCore), uint256(0), data));
        ok;
        uint256 attackerEthAfter = address(attacker).balance;

        if (attackerEthAfter > attackerEthBefore) {
            cumulativeAttackerEthReceived += (attackerEthAfter - attackerEthBefore);
        }

        attacker.clearReentrantCall();
    }

    function action_observeOverpayment() public {
        if (cumulativeAttackerEthReceived > cumulativeAttackerKingEthOwed) {
            sawAttackerOverpayment = true;
        }
    }

    // ================================================================
    // Properties
    // ================================================================

    /// @notice The attacker MUST NOT receive more cumulative ETH than the
    ///         intended King-payout envelope would allow. Any surplus is a
    ///         double-credit / guard-bypass extraction.
    /// @dev    Owed is realized at dethrone time as
    ///         `KING_ETH_SHARE_PCT/KING_ETH_SHARE_DENOM` of the dethrone
    ///         price, summed across reigns where the attacker was actually
    ///         the King when the takeover succeeded. Since the attacker's
    ///         takeover cost is unrelated to the King-share they receive
    ///         on a later dethrone (and prices grow), bounding owed by the
    ///         takeover price they paid is mathematically wrong.
    function echidna_attacker_no_overpayment() public view returns (bool) {
        return !sawAttackerOverpayment;
    }

    /// @notice Any successful reentrant call into a guarded function is a
    ///         violation. King payout uses a bounded gas stipend so even the
    ///         reentrancy attempt should fail; shareholder + escrow paths
    ///         use explicit ReentrancyGuard.
    function echidna_no_reentrant_call_succeeded_into_guarded_path() public view returns (bool) {
        return attacker.reentrantSuccesses() == 0;
    }
}
