// SPDX-License-Identifier: MIT
pragma solidity ^0.8.34;

import {Test} from "forge-std/Test.sol";

import {ClaimToken} from "src/ClaimToken.sol";
import {FurnaceQuoter} from "src/FurnaceQuoter.sol";
import {Constants} from "src/lib/Constants.sol";
import {Errors} from "src/lib/Errors.sol";

import {FurnaceHarness} from "./mocks/FurnaceHarness.sol";
import {MockEntryTokenRegistry} from "./mocks/MockEntryTokenRegistry.sol";
import {VeClaimNFTHarness} from "./mocks/VeClaimNFTHarness.sol";

/// @notice FurnaceQuoter rejects EOA router config to stay aligned with Furnace.
contract FurnaceQuoterRouterConfigNotAContractTest is Test {
    address internal owner = address(0xA11CE);
    address internal alice = address(0xA11C3);

    ClaimToken internal claim;
    VeClaimNFTHarness internal ve;
    FurnaceHarness internal furnace;
    FurnaceQuoter internal quoter;
    MockEntryTokenRegistry internal registry;

    function setUp() public {
        claim = new ClaimToken(owner);
        ve = new VeClaimNFTHarness(address(claim), owner);
        furnace = new FurnaceHarness(address(claim), address(ve), owner);
        quoter = new FurnaceQuoter(address(furnace));
        registry = new MockEntryTokenRegistry();

        vm.startPrank(owner);
        furnace.setFurnaceQuoter(address(quoter));
        furnace.setEntryTokenRegistry(address(registry));
        vm.stopPrank();
    }

    function testQuoteEnterWithClaimReverts_NotAContract_WhenRouterConfigEOA() public {
        // Non-zero but NOT contracts.
        registry.setRouterConfig(address(0xBEEF), address(0xF00D), address(0xCAFE), address(claim));

        vm.expectRevert(Errors.NotAContract.selector);
        quoter.quoteEnterWithClaim(alice, 1e18, 0, Constants.MIN_LOCK_DURATION, false);
    }
}
