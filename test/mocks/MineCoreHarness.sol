// SPDX-License-Identifier: MIT
pragma solidity ^0.8.34;

import {MineCore} from "src/MineCore.sol";

/// @notice Test harness for mutating MineCore state that is normally updated by takeover.
contract MineCoreHarness is MineCore {
    constructor(address claim_, address ve_, address royalties_, address initialOwner)
        MineCore(claim_, ve_, royalties_, initialOwner)
    {}

    function setReignStateForTest(address king, uint256 reignStartTime, uint256 refPrice, uint256 lastAccrual)
        external
    {
        currentKing = king;
        currentReignStartTime = reignStartTime;
        referencePrice = refPrice;
        currentReignLastAccrualTime = lastAccrual;
    }

    function setKingAutoLockPinnedTokenIdForTest(address user, uint256 tokenId) external {
        kingAutoLockConfig[user].pinnedTokenId = tokenId;
    }

    function setKingEthBalanceForTest(address user, uint256 amount) external {
        totalKingEthOwed = totalKingEthOwed - kingEthBalance[user] + amount;
        kingEthBalance[user] = amount;
    }

    function setRefundEthBalanceForTest(address user, uint256 amount) external {
        totalRefundEthOwed = totalRefundEthOwed - refundEthBalance[user] + amount;
        refundEthBalance[user] = amount;
    }

    function setShareholderEthPendingHarness(uint256 amount) external {
        shareholderEthPending = amount;
    }

    function setGenesisKingClaimCollectedForTest(bool collected) external {
        genesisKingClaimCollected = collected;
    }

    function setPendingKingClaimForTest(address user, uint256 amount) external {
        totalPendingKingClaim = totalPendingKingClaim - pendingKingClaim[user] + amount;
        pendingKingClaim[user] = amount;
    }

    /// @dev Force a King's takeover-window count, bypassing the no-self-succession bound, to exercise
    ///      the defensive `> KING_LIQUID_SHARE_MAX_BPS` clamp in `_kingLiquidBps`.
    function setTakeoverWindowCountForTest(address user, uint256 count) external {
        takeoverWindowTakeovers[user] = count;
    }

    function mintClaimForTest(address to, uint256 amount) external {
        claim.mint(to, amount);
    }

    function creditFurnaceReserveForTest(uint256 amount) external {
        claim.mint(address(furnace), amount);
        furnace.creditReserve(amount);
    }

    /// @dev Expose internal emission integrals for precision testing.
    function kingEmittedExposed(uint256 ts0, uint256 ts1) external view returns (uint256) {
        return _kingEmitted(ts0, ts1);
    }

    function furnaceEmittedExposed(uint256 ts0, uint256 ts1) external view returns (uint256) {
        return _furnaceEmitted(ts0, ts1);
    }

    function helperAddressForTest() external view returns (address) {
        return _helper;
    }
}
