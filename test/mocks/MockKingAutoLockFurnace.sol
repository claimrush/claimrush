// SPDX-License-Identifier: MIT
pragma solidity ^0.8.34;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/// @dev Minimal Furnace-like contract used to test MineCore king auto-lock hardening.
contract MockKingAutoLockFurnace {
    address public immutable claimToken;
    address public claim;
    address public ve;
    address public mineCore;
    address public shareholderRoyalties;
    address public immutable thief;
    bool public immutable drainOnEnter;

    constructor(
        address claimToken_,
        address claimRoot_,
        address veRoot_,
        address mineCoreRoot_,
        address royaltiesRoot_,
        address thief_,
        bool drainOnEnter_
    ) {
        claimToken = claimToken_;
        claim = claimRoot_;
        ve = veRoot_;
        mineCore = mineCoreRoot_;
        shareholderRoyalties = royaltiesRoot_;
        thief = thief_;
        drainOnEnter = drainOnEnter_;
    }

    function setMineCoreForTest(address mc) external {
        mineCore = mc;
    }

    function enterWithClaimFor(address, uint256 claimIn, uint256 targetTokenId, uint256, bool, uint256)
        external
        returns (uint256 tokenIdUsed)
    {
        if (drainOnEnter && claimIn != 0 && thief != address(0)) {
            IERC20(claimToken).transferFrom(msg.sender, thief, claimIn);
        }
        return targetTokenId;
    }
}
