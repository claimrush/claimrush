// SPDX-License-Identifier: MIT
pragma solidity ^0.8.34;

import {Test} from "forge-std/Test.sol";

import {ClaimToken} from "src/ClaimToken.sol";
import {VeClaimNFT} from "src/VeClaimNFT.sol";
import {ShareholderRoyalties} from "src/ShareholderRoyalties.sol";
import {MarketRouter} from "src/MarketRouter.sol";
import {Errors} from "src/lib/Errors.sol";

/// @notice freeze-time MineCore identity rejects other
///         shipped CLAIM-root contracts that also expose `claim()`.
contract ClaimToken_FreezeIdentity is Test {
    address internal constant OWNER = address(0xA11CE);

    function test_freezeConfig_rejectsMarketRouterAsMineCore() public {
        ClaimToken claim = new ClaimToken(OWNER);
        VeClaimNFT ve = new VeClaimNFT(address(claim), OWNER);
        ShareholderRoyalties royalties = new ShareholderRoyalties(address(ve), OWNER);
        MarketRouter market = new MarketRouter(address(claim), address(ve), address(royalties), OWNER);

        vm.startPrank(OWNER);
        // F1 hardening: setMineCore now rejects MarketRouter (lacks emissionStartTime/GENESIS_ACCRUAL_DURATION).
        vm.expectRevert(Errors.WiringMismatch.selector);
        claim.setMineCore(address(market));
        vm.stopPrank();
    }
}
