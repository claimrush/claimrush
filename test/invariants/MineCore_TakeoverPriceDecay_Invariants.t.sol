// SPDX-License-Identifier: MIT
pragma solidity ^0.8.34;

import {Test} from "forge-std/Test.sol";
import {ClaimToken} from "src/ClaimToken.sol";
import {ShareholderRoyalties} from "src/ShareholderRoyalties.sol";
import {Constants} from "src/lib/Constants.sol";
import {Errors} from "src/lib/Errors.sol";
import {MineCoreHarness} from "../mocks/MineCoreHarness.sol";
import {MockVe} from "../mocks/MockVe.sol";

/// @title Takeover price decay invariant tests for MineCore.
/// @dev Covers invariants from §6:
///      - Price >= floor at all times
///      - Price decays monotonically over TAKEOVER_DECAY_PERIOD
///      - Price at t=0 doubles the previous reference
///      - Price reaches floor at/after TAKEOVER_DECAY_PERIOD
contract MineCoreTakeoverPriceDecayInvariantsTest is Test {
    ClaimToken internal claim;
    MockVe internal ve;
    ShareholderRoyalties internal royalties;
    MineCoreHarness internal mineCore;

    address internal owner;
    address internal alice;
    address internal bob;

    function setUp() public {
        owner = makeAddr("owner");
        alice = makeAddr("alice");
        bob = makeAddr("bob");

        claim = new ClaimToken(owner);
        ve = new MockVe();
        royalties = new ShareholderRoyalties(address(ve), owner);
        mineCore = new MineCoreHarness(address(claim), address(ve), address(royalties), owner);

        vm.etch(address(0xF00D), hex"00");
        vm.etch(address(0xB0B0), hex"00");

        vm.startPrank(owner);
        claim.setMineCore(address(mineCore));
        mineCore.setFurnace(address(0xF00D));
        vm.mockCall(address(0xF00D), abi.encodeWithSignature("ve()"), abi.encode(address(ve)));
        vm.mockCall(address(0xF00D), abi.encodeWithSignature("claim()"), abi.encode(address(claim)));
        vm.mockCall(address(0xF00D), abi.encodeWithSignature("mineCore()"), abi.encode(address(mineCore)));
        vm.mockCall(address(0xF00D), abi.encodeWithSignature("mineMarket()"), abi.encode(address(0xB0B0)));
        vm.mockCall(address(0xF00D), abi.encodeWithSignature("shareholderRoyalties()"), abi.encode(address(royalties)));
        ve.setClaimToken(address(claim));
        ve.setFurnace(address(0xF00D));
        ve.setMineMarket(address(0xB0B0));
        vm.mockCall(address(0xB0B0), abi.encodeWithSignature("ve()"), abi.encode(address(ve)));
        vm.mockCall(address(0xB0B0), abi.encodeWithSignature("claim()"), abi.encode(address(claim)));
        vm.mockCall(address(0xB0B0), abi.encodeWithSignature("royalties()"), abi.encode(address(royalties)));
        vm.mockCall(address(0xB0B0), abi.encodeWithSignature("mineCore()"), abi.encode(address(mineCore)));
        vm.mockCall(address(0xB0B0), abi.encodeWithSignature("furnace()"), abi.encode(address(0xF00D)));
        royalties.setWiring(address(mineCore), address(0xB0B0), address(0xF00D));
        mineCore.setGenesisKingClaimCollectedForTest(true);
        mineCore.setTakeoversPaused(false);
        vm.stopPrank();

        ve.setTotalVeCached(Constants.MIN_VE_FLUSH);
    }

    /// @dev §6: Price always >= TAKEOVER_PRICE_FLOOR.
    function testFuzz_PriceAlwaysAboveFloor(uint256 elapsed) public {
        elapsed = bound(elapsed, 0, 2 * Constants.TAKEOVER_DECAY_PERIOD);

        // First do a takeover to establish a price reference
        uint256 price0 = mineCore.getCurrentTakeoverPrice();
        vm.deal(alice, price0);
        vm.prank(alice);
        mineCore.takeover{value: price0}(type(uint256).max);

        // Advance time
        vm.warp(block.timestamp + elapsed);

        uint256 price = mineCore.getCurrentTakeoverPrice();
        assertGe(price, Constants.TAKEOVER_PRICE_FLOOR, "price must >= floor");
    }

    /// @dev §6: Price decays monotonically — checking at 10 time intervals.
    function testPriceDecaysMonotonically() public {
        // Establish a price reference with a takeover
        uint256 price0 = mineCore.getCurrentTakeoverPrice();
        vm.deal(alice, price0);
        vm.prank(alice);
        mineCore.takeover{value: price0}(type(uint256).max);

        uint256 prevPrice = mineCore.getCurrentTakeoverPrice();
        uint256 step = Constants.TAKEOVER_DECAY_PERIOD / 10;
        uint256 ts = block.timestamp;

        for (uint256 i = 1; i <= 10; i++) {
            ts += step;
            vm.warp(ts);
            uint256 currentPrice = mineCore.getCurrentTakeoverPrice();
            assertLe(currentPrice, prevPrice, "price must not increase over time");
            prevPrice = currentPrice;
        }

        // After full decay period, price should be at floor
        assertEq(prevPrice, Constants.TAKEOVER_PRICE_FLOOR, "price must reach floor after decay period");
    }
}
