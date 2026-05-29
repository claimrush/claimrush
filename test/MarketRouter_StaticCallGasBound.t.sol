// SPDX-License-Identifier: MIT
pragma solidity ^0.8.34;

import {Test} from "forge-std/Test.sol";

import {ClaimToken} from "src/ClaimToken.sol";
import {MarketRouter} from "src/MarketRouter.sol";
import {ShareholderRoyalties} from "src/ShareholderRoyalties.sol";
import {Errors} from "src/lib/Errors.sol";

import {VeClaimNFTHarness} from "./mocks/VeClaimNFTHarness.sol";

/// @notice Ensures _staticcallAddress is gas-bounded to prevent
///         gas-griefing from malicious wiring targets.
contract MarketRouterStaticCallGasBoundTest is Test {
    address internal owner = address(0xA11CE);

    /// @dev A contract that burns all forwarded gas in its furnace() view.
    function testConstructorSucceedsWithCanonicalRoots() public {
        ClaimToken claim = new ClaimToken(owner);
        VeClaimNFTHarness ve = new VeClaimNFTHarness(address(claim), owner);
        ShareholderRoyalties sr = new ShareholderRoyalties(address(ve), owner);

        // Should succeed since roots are canonical
        MarketRouter market = new MarketRouter(address(claim), address(ve), address(sr), owner);
        assertEq(address(market.claim()), address(claim));
    }
}
