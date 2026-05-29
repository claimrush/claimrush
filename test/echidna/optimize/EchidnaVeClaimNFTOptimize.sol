// SPDX-License-Identifier: MIT
pragma solidity ^0.8.34;

import {EchidnaSetup} from "../EchidnaSetup.sol";
import {Constants} from "src/lib/Constants.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/// @title VeClaimNFT economic worst-case search.
/// @notice Optimization-mode harness. Targets totalLockedClaim conservation,
///         per-user lock-count cap excess, and ve-bias drift. Each
///         `optimize_*` function returns an `int256` Echidna maximizes;
///         positive values indicate a bound violation.
contract EchidnaVeClaimNFTOptimize is EchidnaSetup {
    uint256[] internal createdTokenIds;

    int256 internal worstTotalLockedAboveBalance;
    int256 internal worstUserNftCountAboveCap;
    int256 internal worstVeCachedAboveCurrent;

    constructor() payable {
        _deployAndWire();
    }

    // ================================================================
    // Actions
    // ================================================================

    function action_takeover() public payable {
        uint256 price = mineCore.getCurrentTakeoverPrice();
        if (msg.value < price) return;
        try mineCore.takeover{value: price}(type(uint256).max) {} catch {}
    }

    function action_enterWithClaim(uint256 amount, uint256 durationSeconds) public {
        if (amount < Constants.MIN_LOCK_AMOUNT) amount = Constants.MIN_LOCK_AMOUNT;
        if (amount > 5_000_000e18) amount = 5_000_000e18;
        if (durationSeconds < Constants.MIN_LOCK_DURATION) durationSeconds = Constants.MIN_LOCK_DURATION;
        if (durationSeconds > Constants.MAX_LOCK_DURATION) durationSeconds = Constants.MAX_LOCK_DURATION;
        if (claim.balanceOf(msg.sender) < amount) return;
        try furnace.enterWithClaim(amount, 0, durationSeconds, false, 0) returns (uint256 tokenId) {
            createdTokenIds.push(tokenId);
        } catch {}
    }

    function action_extendWithBonus(uint256 idx, uint256 newDuration) public {
        if (createdTokenIds.length == 0) return;
        uint256 tokenId = createdTokenIds[idx % createdTokenIds.length];
        if (newDuration < Constants.MIN_LOCK_DURATION) newDuration = Constants.MIN_LOCK_DURATION;
        if (newDuration > Constants.MAX_LOCK_DURATION) newDuration = Constants.MAX_LOCK_DURATION;
        try furnace.extendWithBonus(tokenId, newDuration, 0) {} catch {}
    }

    function action_setAutoMax(uint256 idx, bool enabled) public {
        if (createdTokenIds.length == 0) return;
        uint256 tokenId = createdTokenIds[idx % createdTokenIds.length];
        try ve.setAutoMax(tokenId, enabled) {} catch {}
    }

    function action_unlock(uint256 idx) public {
        if (createdTokenIds.length == 0) return;
        uint256 tokenId = createdTokenIds[idx % createdTokenIds.length];
        try ve.unlock(tokenId) {} catch {}
    }

    function action_checkpointGlobal() public {
        ve.checkpointGlobalState();
    }

    function action_observeLockedAboveBalance() public {
        uint256 locked = ve.totalLockedClaim();
        uint256 bal = IERC20(address(claim)).balanceOf(address(ve));
        int256 above = int256(locked) - int256(bal);
        if (above > worstTotalLockedAboveBalance) worstTotalLockedAboveBalance = above;
    }

    function action_observeUserNftCap() public {
        address[3] memory senders = [address(0x20000), address(0x30000), address(0x40000)];
        for (uint256 i = 0; i < 3; i++) {
            uint256 nftCount = ve.balanceOf(senders[i]);
            int256 above = int256(nftCount) - int256(uint256(Constants.MAX_VE_NFTS_PER_USER));
            if (above > worstUserNftCountAboveCap) worstUserNftCountAboveCap = above;
        }
    }

    function action_observeVeBiasDrift() public {
        uint256 cached = ve.totalVeCached();
        uint256 current = ve.totalVeCurrent();
        if (cached > current) {
            int256 drift = int256(cached - current);
            if (drift > worstVeCachedAboveCurrent) worstVeCachedAboveCurrent = drift;
        }
    }

    // ================================================================
    // Optimization targets
    // ================================================================

    /// @notice Worst observed surplus of `totalLockedClaim` over CLAIM custody
    ///         held by `VeClaimNFT`. Must remain `<= 0` (M3 conservation).
    function optimize_ve_totalLockedAboveBalance() public view returns (int256) {
        return worstTotalLockedAboveBalance;
    }

    /// @notice Worst observed surplus of per-user NFT count over the documented
    ///         cap. Must remain `<= 0`.
    function optimize_ve_userNftCountAboveCap() public view returns (int256) {
        return worstUserNftCountAboveCap;
    }

    /// @notice Worst observed surplus of `totalVeCached` over `totalVeCurrent`.
    ///         Cache should never lead the current measurement.
    function optimize_ve_cachedAboveCurrent() public view returns (int256) {
        return worstVeCachedAboveCurrent;
    }
}
