// SPDX-License-Identifier: MIT
pragma solidity ^0.8.34;

import {Test} from "forge-std/Test.sol";

import {ClaimToken} from "src/ClaimToken.sol";
import {MarketRouter} from "src/MarketRouter.sol";
import {ShareholderRoyalties} from "src/ShareholderRoyalties.sol";
import {Errors} from "src/lib/Errors.sol";

import {VeClaimNFTHarness} from "./mocks/VeClaimNFTHarness.sol";

contract MarketRouterConstructorRootMismatchTest is Test {
    address internal owner = address(0xA11CE);

    function testConstructorRevertsWhenVeClaimRootMismatches() public {
        ClaimToken claimA = new ClaimToken(owner);
        ClaimToken claimB = new ClaimToken(owner);
        VeClaimNFTHarness ve = new VeClaimNFTHarness(address(claimB), owner);
        ShareholderRoyalties sr = new ShareholderRoyalties(address(ve), owner);

        vm.expectRevert(Errors.WiringMismatch.selector);
        new MarketRouter(address(claimA), address(ve), address(sr), owner);
    }

    function testConstructorRevertsWhenRoyaltiesVeRootMismatches() public {
        ClaimToken claim = new ClaimToken(owner);
        VeClaimNFTHarness veA = new VeClaimNFTHarness(address(claim), owner);
        VeClaimNFTHarness veB = new VeClaimNFTHarness(address(claim), owner);
        ShareholderRoyalties srB = new ShareholderRoyalties(address(veB), owner);

        vm.expectRevert(Errors.WiringMismatch.selector);
        new MarketRouter(address(claim), address(veA), address(srB), owner);
    }

    function testConstructorAcceptsCanonicalRoots() public {
        ClaimToken claim = new ClaimToken(owner);
        VeClaimNFTHarness ve = new VeClaimNFTHarness(address(claim), owner);
        ShareholderRoyalties sr = new ShareholderRoyalties(address(ve), owner);

        MarketRouter market = new MarketRouter(address(claim), address(ve), address(sr), owner);
        assertEq(address(market.claim()), address(claim));
        assertEq(address(market.ve()), address(ve));
        assertEq(address(market.royalties()), address(sr));
    }

    function testFuzzConstructorRevertsWhenRoyaltiesVeRootMismatches(address wrongVe) public {
        vm.assume(wrongVe != address(0));
        ClaimToken claim = new ClaimToken(owner);
        VeClaimNFTHarness ve = new VeClaimNFTHarness(address(claim), owner);
        MockRoyaltiesVeView sr = new MockRoyaltiesVeView(wrongVe);

        if (wrongVe == address(ve)) {
            MarketRouter market = new MarketRouter(address(claim), address(ve), address(sr), owner);
            assertEq(address(market.royalties()), address(sr));
        } else {
            vm.expectRevert(Errors.WiringMismatch.selector);
            new MarketRouter(address(claim), address(ve), address(sr), owner);
        }
    }
}

contract MockRoyaltiesVeView {
    address public immutable ve;

    constructor(address ve_) {
        ve = ve_;
    }
}
