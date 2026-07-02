// SPDX-License-Identifier: MIT
pragma solidity ^0.8.34;

import {Test} from "forge-std/Test.sol";

import {ClaimToken} from "src/ClaimToken.sol";
import {MineCore} from "src/MineCore.sol";
import {Constants} from "src/lib/Constants.sol";

import {MockVe} from "./mocks/MockVe.sol";
import {MineCoreHarness} from "./mocks/MineCoreHarness.sol";
import {MockRoyaltiesRevertBomb, MockFurnaceRevertBomb} from "./mocks/RevertBombMocks.sol";

/// @notice Regression tests: revert-data bombs in best-effort dependencies MUST NOT brick takeovers.
contract MineCoreRevertBombHardeningTest is Test {
    ClaimToken internal claim;
    MockVe internal ve;

    address internal owner = address(0xA11CE);
    address internal alice;
    address internal bob;

    function setUp() public {
        alice = makeAddr("alice");
        bob = makeAddr("bob");

        claim = new ClaimToken(owner);
        ve = new MockVe();
    }

    function testTakeoverDoesNotRevertOnRoyaltiesRevertDataBomb() public {
        MockRoyaltiesRevertBomb royalties = new MockRoyaltiesRevertBomb();
        royalties.setRevertSize(1_048_576); // 1 MiB
        royalties.setRevertOnTakeover(true);
        royalties.setRevertOnFlush(true);

        MineCoreHarness mineCore = new MineCoreHarness(address(claim), address(ve), address(royalties), owner);

        vm.prank(owner);
        claim.setMineCore(address(mineCore));

        MockFurnaceRevertBomb furnace = new MockFurnaceRevertBomb();
        furnace.setWiring(address(claim), address(ve), address(mineCore), address(royalties));
        ve.setClaimToken(address(claim));

        vm.mockCall(address(royalties), abi.encodeWithSignature("ve()"), abi.encode(address(ve)));
        vm.mockCall(address(royalties), abi.encodeWithSignature("furnace()"), abi.encode(address(furnace)));
        vm.mockCall(address(royalties), abi.encodeWithSignature("mineCore()"), abi.encode(address(mineCore)));
        vm.mockCall(address(royalties), abi.encodeWithSignature("mineMarket()"), abi.encode(address(0)));

        ve.setFurnace(address(furnace));
        vm.prank(owner);
        mineCore.setFurnace(address(furnace));
        mineCore.setGenesisKingClaimCollectedForTest(true);
        vm.prank(owner);
        mineCore.setTakeoversPaused(false);

        // First takeover uses the floor.
        uint256 floor = Constants.TAKEOVER_PRICE_FLOOR;
        vm.deal(alice, floor);

        // Bound gas so that copying the revert-data buffer would OOG.
        vm.prank(alice);
        mineCore.takeover{value: floor, gas: 4_000_000}(type(uint256).max);

        assertEq(mineCore.currentKing(), alice);
        assertEq(mineCore.shareholderEthPending(), floor);
    }

    function testKingAutoLockDoesNotRevertOnFurnaceRevertDataBomb() public {
        MockRoyaltiesRevertBomb royalties = new MockRoyaltiesRevertBomb();
        royalties.setRevertOnTakeover(false);
        royalties.setRevertOnFlush(false);

        MineCoreHarness mineCore = new MineCoreHarness(address(claim), address(ve), address(royalties), owner);

        vm.prank(owner);
        claim.setMineCore(address(mineCore));

        MockFurnaceRevertBomb furnace = new MockFurnaceRevertBomb();
        furnace.setRevertSize(1_048_576); // 1 MiB
        furnace.setWiring(address(claim), address(ve), address(mineCore), address(royalties));
        ve.setClaimToken(address(claim));

        vm.mockCall(address(royalties), abi.encodeWithSignature("ve()"), abi.encode(address(ve)));
        vm.mockCall(address(royalties), abi.encodeWithSignature("furnace()"), abi.encode(address(furnace)));
        vm.mockCall(address(royalties), abi.encodeWithSignature("mineCore()"), abi.encode(address(mineCore)));
        vm.mockCall(address(royalties), abi.encodeWithSignature("mineMarket()"), abi.encode(address(0)));

        ve.setFurnace(address(furnace));
        vm.prank(owner);
        mineCore.setFurnace(address(furnace));
        mineCore.setGenesisKingClaimCollectedForTest(true);
        vm.prank(owner);
        mineCore.setTakeoversPaused(false);

        // Ensure emissions are live.
        uint256 t0 = mineCore.emissionStartTime();
        vm.warp(t0 + 1);

        // Genesis: Alice becomes king.
        uint256 floor = Constants.TAKEOVER_PRICE_FLOOR;
        vm.deal(alice, floor);
        vm.prank(alice);
        mineCore.takeover{value: floor}(type(uint256).max);
        assertEq(mineCore.currentKing(), alice);

        // Alice enables create-once auto-lock (targetTokenId = 0).
        vm.prank(alice);
        mineCore.setKingAutoLockConfig(true, 0, uint32(Constants.MIN_LOCK_DURATION), false, 1);

        // Advance so Alice has non-zero King-stream accrual.
        vm.warp(block.timestamp + 1000);

        // Bob dethrones Alice; auto-lock will attempt Furnace.enterWithClaimFor and hit the revert-data bomb.
        uint256 price = mineCore.getTakeoverPrice(block.timestamp);
        vm.deal(bob, price);
        vm.prank(bob);
        mineCore.takeover{value: price, gas: 4_000_000}(type(uint256).max);

        assertEq(mineCore.currentKing(), bob);

        // Alice's takeover-window liquid slice is paid; the locked slice's Furnace entry fails on the
        // revert bomb, so that remainder is credited as pending (for a later force-locked withdrawal)
        // and no lock is pinned.
        uint256 mined1 = mineCore.getReignInfo(1).totalClaimMined;
        uint256 expLiquid1 = (mined1 * mineCore.kingLiquidShareBps(alice)) / 10_000;
        assertEq(claim.balanceOf(alice), expLiquid1, "alice receives only her takeover-window liquid share");
        assertEq(
            mineCore.pendingKingClaim(alice), mined1 - expLiquid1, "locked slice credited as pending on lock failure"
        );

        (,, uint256 pinnedTokenId,,,) = mineCore.getKingAutoLockConfig(alice);
        assertEq(pinnedTokenId, 0);
    }
}
