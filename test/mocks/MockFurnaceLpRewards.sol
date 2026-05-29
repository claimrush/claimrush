// SPDX-License-Identifier: MIT
pragma solidity ^0.8.34;

import {MockERC20} from "./MockERC20.sol";

/// @notice Mock Furnace implementing only the LP rewards subset used by LpStakingVault7D.
contract MockFurnaceLpRewards {
    MockERC20 public immutable CLAIM;
    address public immutable ve;

    uint256 public quotePrincipal;
    uint256 public quoteBonus;
    uint256 public quoteVeOut;
    uint256 public quoteRouteTokenId;

    address public lastUser;
    uint256 public lastClaimIn;
    uint256 public lastDurationSeconds;
    uint256 public lastMinVeOut;
    uint256 public enterCalls;

    bool public shouldRevert;

    constructor(address claim_, address ve_) {
        CLAIM = MockERC20(claim_);
        ve = ve_;

        // Default quote: no bonus, no routing.
        quoteVeOut = 1;
    }

    function claim() external view returns (address) {
        return address(CLAIM);
    }

    function furnaceQuoter() external view returns (address) {
        return address(this);
    }

    function setShouldRevert(bool val) external {
        shouldRevert = val;
    }

    function setQuote(uint256 principal, uint256 bonus, uint256 veOut, uint256 routeTokenId) external {
        quotePrincipal = principal;
        quoteBonus = bonus;
        quoteVeOut = veOut;
        quoteRouteTokenId = routeTokenId;
    }

    function quoteEnterWithClaim(
        address user,
        uint256 claimIn,
        uint256 targetTokenId,
        uint256 durationSeconds,
        bool createAutoMax
    ) external view returns (uint256 principalClaim, uint256 bonusClaim, uint256 veOut, uint256 routeTokenId) {
        user;
        claimIn;
        targetTokenId;
        durationSeconds;
        createAutoMax;
        return (quotePrincipal, quoteBonus, quoteVeOut, quoteRouteTokenId);
    }

    function enterWithClaimFor(
        address user,
        uint256 claimAmount,
        uint256 targetTokenId,
        uint256 durationSeconds,
        bool createAutoMax,
        uint256 minVeOut
    ) external returns (uint256 tokenIdUsed) {
        require(!shouldRevert, "MockFurnace: forced revert");
        lastUser = user;
        lastClaimIn = claimAmount;
        lastDurationSeconds = durationSeconds;
        lastMinVeOut = minVeOut;
        enterCalls += 1;

        // For compatibility with callers that expect a tokenIdUsed return value,
        // mirror the targetTokenId unless the caller passed 0.
        tokenIdUsed = targetTokenId == 0 ? 1 : targetTokenId;
        createAutoMax;

        // Pull CLAIM from caller (the vault).
        require(CLAIM.transferFrom(msg.sender, address(this), claimAmount), "MockFurnace: transferFrom");
    }
}
