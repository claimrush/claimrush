// SPDX-License-Identifier: MIT
pragma solidity ^0.8.34;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {ClaimToken} from "src/ClaimToken.sol";
import {Furnace} from "src/Furnace.sol";
import {FurnaceGuardHelper} from "src/FurnaceGuardHelper.sol";
import {FurnaceQuoter} from "src/FurnaceQuoter.sol";
import {ShareholderRoyalties} from "src/ShareholderRoyalties.sol";
import {EntryTokenRegistry} from "src/EntryTokenRegistry.sol";
import {Constants} from "src/lib/Constants.sol";

import {VeClaimNFTHarness} from "./mocks/VeClaimNFTHarness.sol";
import {MockAerodromeRouter} from "./mocks/MockAerodromeRouter.sol";
import {MockWETH} from "./mocks/MockWETH.sol";
import {MineCoreHarness} from "./mocks/MineCoreHarness.sol";

/// @notice Exercises the King-stream liquid-share split: a dethroned King receives a liquid CLAIM
///         slice equal to their share of the last `KING_LIQUID_WINDOW` takeovers (clamped to
///         `KING_LIQUID_SHARE_MAX_BPS`), with the remainder force-locked.
contract MineCoreLiquidShareTest is Test {
    ClaimToken internal claim;
    VeClaimNFTHarness internal ve;
    ShareholderRoyalties internal royalties;
    Furnace internal furnace;
    MineCoreHarness internal mineCore;

    address internal owner = address(0xA11CE);
    address internal mineMarket = address(0xBABA);
    address internal alice = makeAddr("alice");
    address internal bob = makeAddr("bob");

    function setUp() public {
        vm.etch(mineMarket, hex"00");

        claim = new ClaimToken(owner);
        ve = new VeClaimNFTHarness(address(claim), owner);
        royalties = new ShareholderRoyalties(address(ve), owner);
        furnace = new Furnace(
            address(claim), address(ve), address(new FurnaceGuardHelper(address(claim), address(ve))), owner
        );
        FurnaceQuoter quoter = new FurnaceQuoter(address(furnace));
        mineCore = new MineCoreHarness(address(claim), address(ve), address(royalties), owner);

        EntryTokenRegistry registry = new EntryTokenRegistry(owner);
        MockWETH weth = new MockWETH();
        vm.etch(address(0xFAc7), hex"00");
        MockAerodromeRouter router = new MockAerodromeRouter(address(0xFAc7), address(weth));

        vm.startPrank(owner);
        claim.setMineCore(address(mineCore));
        vm.mockCall(mineMarket, abi.encodeWithSignature("ve()"), abi.encode(address(ve)));
        vm.mockCall(mineMarket, abi.encodeWithSignature("claim()"), abi.encode(address(claim)));
        vm.mockCall(mineMarket, abi.encodeWithSignature("royalties()"), abi.encode(address(royalties)));
        furnace.setMineCore(address(mineCore));
        furnace.setFurnaceQuoter(address(quoter));
        furnace.setMineMarket(mineMarket);
        furnace.setShareholderRoyalties(address(royalties));
        furnace.setEntryTokenRegistry(address(registry));
        mineCore.setFurnace(address(furnace));
        royalties.setWiring(address(mineCore), mineMarket, address(furnace));
        ve.setFurnace(address(furnace));
        ve.setMineMarket(mineMarket);
        EntryTokenRegistry mineCoreRegistry = new EntryTokenRegistry(owner);
        mineCore.setEntryTokenRegistry(address(mineCoreRegistry));
        mineCore.setGenesisKingClaimCollectedForTest(true);
        mineCore.setTakeoversPaused(false);
        registry.setRouterConfig(address(router), router.defaultFactory(), router.weth(), address(claim));
        vm.stopPrank();

        uint256 seed = 100_000_000e18;
        vm.prank(address(mineCore));
        claim.mint(address(furnace), seed);
        vm.prank(address(mineCore));
        furnace.creditReserve(seed);

        vm.warp(mineCore.emissionStartTime() + 1);
    }

    function _takeover(address user) internal {
        uint256 price = mineCore.getTakeoverPrice(block.timestamp);
        vm.deal(user, price);
        vm.prank(user);
        mineCore.takeover{value: price}(type(uint256).max);
    }

    /// @dev Ping-pong bob/alice for `rounds` (bob first, so it works whether or not alice is the
    ///      current king), advancing time so each reign mines CLAIM. A King cannot take their own
    ///      crown, so the players must alternate.
    function _pingPong(uint256 rounds) internal {
        for (uint256 i = 0; i < rounds; i++) {
            vm.warp(block.timestamp + 60);
            _takeover(bob);
            vm.warp(block.timestamp + 60);
            _takeover(alice);
        }
    }

    /// @notice A single takeover yields a 1% liquid slice (1 of the fixed last-100 window).
    function test_singleTakeover_yieldsOnePercentLiquid() public {
        _takeover(alice); // reign 1, alice in window once
        assertEq(mineCore.kingLiquidShareBps(alice), 100, "1 of 100 takeovers -> 1%");

        vm.warp(block.timestamp + 600);
        uint256 before = claim.balanceOf(alice);
        _takeover(bob); // dethrones alice

        uint256 mined = mineCore.getReignInfo(1).totalClaimMined;
        assertGt(mined, 0, "reign mined CLAIM");
        uint256 expLiquid = (mined * 100) / 10_000;
        assertEq(claim.balanceOf(alice) - before, expLiquid, "alice gets exactly her 1% liquid slice");
    }

    /// @notice The liquid share scales linearly with the King's count in the window.
    function test_shareScalesWithTakeoverCount() public {
        // alice takes 10 of the first 19 takeovers (alice leads each ping-pong round + the opener).
        _takeover(alice); // count 1
        _pingPong(9); // +9 alice, +9 bob

        assertEq(mineCore.kingWindowTakeovers(alice), 10, "alice took 10");
        assertEq(mineCore.kingWindowTakeovers(bob), 9, "bob took 9");
        assertEq(mineCore.kingLiquidShareBps(alice), 1_000, "10/100 -> 10%");
        assertEq(mineCore.kingLiquidShareBps(bob), 900, "9/100 -> 9%");
    }

    /// @notice With no self-succession, perfect 2-player alternation tops each player out at exactly
    ///         50 of the last 100 takeovers — i.e. the 50% ceiling is the structural maximum.
    function test_naturalMaxShareIsFiftyPercent() public {
        _pingPong(60); // 120 takeovers; window keeps the last 100 -> 50 alice, 50 bob
        assertEq(mineCore.kingWindowTakeovers(alice), 50, "alice holds 50 of the last 100");
        assertEq(mineCore.kingWindowTakeovers(bob), 50, "bob holds 50 of the last 100");
        assertEq(mineCore.kingLiquidShareBps(alice), Constants.KING_LIQUID_SHARE_MAX_BPS, "natural max == 50%");
    }

    /// @notice Defensive clamp: even if a count somehow exceeded 50 (impossible under no-self-succession),
    ///         the liquid share is capped at KING_LIQUID_SHARE_MAX_BPS.
    function test_liquidShareClampGuardsAboveFiftyPercent() public {
        mineCore.setTakeoverWindowCountForTest(alice, 80); // 80/100 raw -> 80%
        assertEq(mineCore.kingLiquidShareBps(alice), Constants.KING_LIQUID_SHARE_MAX_BPS, "clamped down to 50%");
    }

    /// @notice The window is bounded: total counts across all addresses never exceed KING_LIQUID_WINDOW.
    function test_windowEvictsOldestBeyondCapacity() public {
        _pingPong(70); // 140 takeovers, far beyond the 100-entry window
        uint256 total = mineCore.kingWindowTakeovers(alice) + mineCore.kingWindowTakeovers(bob);
        assertEq(total, Constants.KING_LIQUID_WINDOW, "window holds exactly the last 100 takeovers");
    }
}
