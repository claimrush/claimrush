// SPDX-License-Identifier: MIT
pragma solidity ^0.8.34;

import {Test} from "forge-std/Test.sol";

import {ClaimToken} from "src/ClaimToken.sol";
import {MineCoreHarness} from "./mocks/MineCoreHarness.sol";
import {ShareholderRoyalties} from "src/ShareholderRoyalties.sol";
import {Errors} from "src/lib/Errors.sol";
import {Constants} from "src/lib/Constants.sol";

import {MockVe} from "./mocks/MockVe.sol";

contract RevertingCreditReserveFurnace {
    address public immutable claim;
    address public immutable ve;
    address public immutable mineCore;
    address public immutable shareholderRoyalties;
    address public immutable mineMarket;

    constructor(address claim_, address ve_, address mineCore_, address shareholderRoyalties_, address mineMarket_) {
        claim = claim_;
        ve = ve_;
        mineCore = mineCore_;
        shareholderRoyalties = shareholderRoyalties_;
        mineMarket = mineMarket_;
    }

    function creditReserve(uint256) external pure {
        revert();
    }
}

contract MineCore_FurnaceReserveCreditTest is Test {
    ClaimToken internal claim;
    MockVe internal ve;
    ShareholderRoyalties internal royalties;
    MineCoreHarness internal mineCore;
    RevertingCreditReserveFurnace internal furnace;

    address internal owner = makeAddr("owner");
    address internal alice = makeAddr("alice");
    address internal market = address(0xB0B0);

    function setUp() public {
        claim = new ClaimToken(owner);
        ve = new MockVe();
        royalties = new ShareholderRoyalties(address(ve), owner);
        mineCore = new MineCoreHarness(address(claim), address(ve), address(royalties), owner);
        furnace = new RevertingCreditReserveFurnace(
            address(claim), address(ve), address(mineCore), address(royalties), market
        );

        vm.etch(market, hex"00");
        vm.mockCall(market, abi.encodeWithSignature("royalties()"), abi.encode(address(royalties)));
        vm.mockCall(market, abi.encodeWithSignature("ve()"), abi.encode(address(ve)));
        vm.mockCall(market, abi.encodeWithSignature("claim()"), abi.encode(address(claim)));

        vm.startPrank(owner);
        claim.setMineCore(address(mineCore));
        mineCore.setFurnace(address(furnace));
        royalties.setWiring(address(mineCore), market, address(furnace));
        mineCore.setGenesisKingClaimCollectedForTest(true);
        mineCore.setTakeoversPaused(false);
        vm.stopPrank();

        ve.setClaimToken(address(claim));
        ve.setFurnace(address(furnace));
        ve.setMineMarket(market);

        uint256 t1 = mineCore.emissionStartTime() + 1;
        vm.warp(t1);
        ve.setGlobalLastTs(t1);
        ve.setCheckpointAdvances(true);
    }

    function test_takeover_reverts_whenFurnaceReserveCreditFails() public {
        vm.deal(alice, 10 ether);

        vm.prank(alice);
        vm.expectRevert(Errors.InvariantViolation.selector);
        mineCore.takeover{value: Constants.TAKEOVER_PRICE_FLOOR}(type(uint256).max);

        assertEq(claim.totalSupply(), 0, "mint must roll back");
        assertEq(mineCore.currentKing(), address(0), "king must remain unset");
        assertEq(address(furnace), address(mineCore.furnace()), "configured furnace unchanged");
    }
}
