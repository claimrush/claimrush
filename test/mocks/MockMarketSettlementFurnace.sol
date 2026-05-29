// SPDX-License-Identifier: MIT
pragma solidity ^0.8.34;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/// @dev Minimal Furnace-like surface for MarketRouter settlement hardening tests.
contract MockMarketSettlementFurnace {
    address public claim;
    address public ve;
    address public mineMarket;
    address public shareholderRoyalties;
    address public furnaceQuoter;
    address public mineCore;

    constructor(address _claim, address _ve, address _mineMarket, address _shareholderRoyalties) {
        claim = _claim;
        ve = _ve;
        mineMarket = _mineMarket;
        shareholderRoyalties = _shareholderRoyalties;
    }

    function setMineCore(address _mineCore) external {
        mineCore = _mineCore;
    }

    function setFurnaceQuoter(address _quoter) external {
        furnaceQuoter = _quoter;
    }

    function quoteSellLockToFurnaceFromInfo(uint256 lockAmount, uint256, bool)
        external
        pure
        returns (uint256 claimOut, uint256 spreadBps, uint256 lpReward, uint256 reserveAdd)
    {
        return (lockAmount, 0, 0, 0);
    }

    function sellLockToFurnaceFromMarket(address seller, uint256, uint256 minClaimOut)
        external
        returns (uint256 claimOut)
    {
        claimOut = minClaimOut;
        if (seller != address(0) && claim != address(0) && minClaimOut != 0) {
            IERC20(claim).transfer(seller, minClaimOut);
        }
    }

    function quoteEnterWithClaim(address, uint256 claimIn, uint256 targetTokenId, uint256, bool)
        external
        pure
        returns (uint256 principalClaim, uint256 bonusClaim, uint256 veOut, uint256 routeTokenId)
    {
        return (claimIn, 0, claimIn, targetTokenId);
    }

    function enterWithClaimFor(address, uint256, uint256 targetTokenId, uint256, bool, uint256)
        external
        pure
        returns (uint256 tokenIdUsed)
    {
        return targetTokenId;
    }
}
