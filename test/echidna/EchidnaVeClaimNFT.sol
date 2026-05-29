// SPDX-License-Identifier: MIT
pragma solidity ^0.8.34;

import {EchidnaSetup} from "./EchidnaSetup.sol";
import {Constants} from "src/lib/Constants.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/// @title Echidna harness for VeClaimNFT lock lifecycle and totalLockedClaim conservation.
/// @dev Invariants from the invariants document Section 3.
contract EchidnaVeClaimNFT is EchidnaSetup {
    // Track created token IDs for fuzzing operations
    uint256[] internal createdTokenIds;
    uint256 internal tokenIdCount;

    constructor() payable {
        _deployAndWire();
    }

    // ================================================================
    // Actions
    // ================================================================

    /// @dev Takeover to generate CLAIM emissions
    function action_takeover() public payable {
        uint256 price = mineCore.getCurrentTakeoverPrice();
        if (msg.value < price) return;
        try mineCore.takeover{value: price}(type(uint256).max) {} catch {}
    }

    /// @dev Enter Furnace to create a lock (creates veNFTs)
    function action_enterWithClaim(uint256 amount, uint256 durationSeconds) public {
        if (amount < Constants.MIN_LOCK_AMOUNT) amount = Constants.MIN_LOCK_AMOUNT;
        if (amount > 5_000_000e18) amount = 5_000_000e18;
        if (durationSeconds < Constants.MIN_LOCK_DURATION) durationSeconds = Constants.MIN_LOCK_DURATION;
        if (durationSeconds > Constants.MAX_LOCK_DURATION) durationSeconds = Constants.MAX_LOCK_DURATION;

        if (claim.balanceOf(msg.sender) < amount) return;

        try furnace.enterWithClaim(amount, 0, durationSeconds, false, 0) returns (uint256 tokenId) {
            createdTokenIds.push(tokenId);
            tokenIdCount++;
        } catch {}
    }

    /// @dev Extend a lock duration via Furnace.extendWithBonus (the user-facing path).
    function action_extendLock(uint256 idx, uint256 additionalDuration) public {
        if (tokenIdCount == 0) return;
        uint256 tokenId = createdTokenIds[idx % tokenIdCount];
        if (additionalDuration == 0) additionalDuration = 1 days;
        if (additionalDuration > Constants.MAX_LOCK_DURATION) additionalDuration = Constants.MAX_LOCK_DURATION;
        try furnace.extendWithBonus(tokenId, additionalDuration, 0) {} catch {}
    }

    /// @dev Toggle autoMax on a lock
    function action_setAutoMax(uint256 idx, bool enabled) public {
        if (tokenIdCount == 0) return;
        uint256 tokenId = createdTokenIds[idx % tokenIdCount];
        try ve.setAutoMax(tokenId, enabled) {} catch {}
    }

    /// @dev Merge two locks via the Furnace user-facing entrypoint
    ///      (`Furnace.mergeLocksWithBonus` — v1.0.0 replaces `ve.mergeLocks`).
    ///      `minBonusOut = 0` opts out of the slippage guard so the fuzzer
    ///      keeps full coverage of merge regimes that yield 0 bonus.
    function action_mergeLocks(uint256 idx1, uint256 idx2) public {
        if (tokenIdCount < 2) return;
        uint256 fromId = createdTokenIds[idx1 % tokenIdCount];
        uint256 intoId = createdTokenIds[idx2 % tokenIdCount];
        if (fromId == intoId) return;
        try furnace.mergeLocksWithBonus(fromId, intoId, 0) {} catch {}
    }

    /// @dev Unlock an expired lock
    function action_unlock(uint256 idx) public {
        if (tokenIdCount == 0) return;
        uint256 tokenId = createdTokenIds[idx % tokenIdCount];
        try ve.unlock(tokenId) {} catch {}
    }

    /// @dev Enter with AutoMax enabled
    function action_enterAutoMax(uint256 amount) public {
        if (amount < Constants.MIN_LOCK_AMOUNT) amount = Constants.MIN_LOCK_AMOUNT;
        if (amount > 5_000_000e18) amount = 5_000_000e18;
        if (claim.balanceOf(msg.sender) < amount) return;
        try furnace.enterWithClaim(amount, 0, Constants.MAX_LOCK_DURATION, true, 0) returns (uint256 tokenId) {
            createdTokenIds.push(tokenId);
            tokenIdCount++;
        } catch {}
    }

    /// @dev Claim AutoMax bonus (permissionless — anyone can call)
    function action_claimAutoMaxBonus(uint256 idx) public {
        if (tokenIdCount == 0) return;
        uint256 tokenId = createdTokenIds[idx % tokenIdCount];
        try furnace.claimAutoMaxBonus(tokenId) {} catch {}
    }

    /// @dev Checkpoint global state
    function action_checkpointGlobal() public {
        ve.checkpointGlobalState();
    }

    // ================================================================
    // Properties
    // ================================================================

    /// @dev Invariant §3: totalLockedClaim backed by CLAIM balance in VeClaimNFT.
    function echidna_total_locked_backed() public view returns (bool) {
        uint256 locked = ve.totalLockedClaim();
        uint256 claimBal = IERC20(address(claim)).balanceOf(address(ve));
        return claimBal >= locked;
    }

    /// @dev Invariant §3: totalVeCached and totalVeCurrent do not underflow.
    function echidna_total_ve_non_negative() public view returns (bool) {
        ve.totalVeCached();
        ve.totalVeCurrent();
        return true;
    }

    /// @dev Invariant §3: mineMarket wiring is correct for transfer restrictions.
    function echidna_no_arbitrary_transfer() public view returns (bool) {
        return address(ve.mineMarket()) == address(market);
    }

    /// @dev Invariant §3: Per-user veNFT count <= MAX_VE_NFTS_PER_USER.
    function echidna_user_nft_cap() public view returns (bool) {
        address[3] memory senders = [address(0x20000), address(0x30000), address(0x40000)];
        for (uint256 i = 0; i < 3; i++) {
            if (ve.balanceOf(senders[i]) > Constants.MAX_VE_NFTS_PER_USER) return false;
        }
        return true;
    }
}
