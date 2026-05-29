// SPDX-License-Identifier: MIT
pragma solidity ^0.8.34;

import {Test} from "forge-std/Test.sol";
import {IERC721} from "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import {IERC721Receiver} from "@openzeppelin/contracts/token/ERC721/IERC721Receiver.sol";

import {ClaimToken} from "src/ClaimToken.sol";
import {Constants} from "src/lib/Constants.sol";
import {IVeClaimNFT} from "src/interfaces/IVeClaimNFT.sol";

import {VeClaimNFTHarness} from "./mocks/VeClaimNFTHarness.sol";
import {MockMineCoreWiringView} from "./mocks/MockMineCoreWiringView.sol";
import {MockShareholderRoyaltiesCheckpoint} from "./mocks/MockShareholderRoyaltiesCheckpoint.sol";

contract RegressionPass03MarketRouterMock {
    address public claim;
    address public ve;
    address public royalties;
    address public furnace;

    constructor(address _claim, address _ve, address _royalties) {
        claim = _claim;
        ve = _ve;
        royalties = _royalties;
    }

    function setFurnace(address _furnace) external {
        furnace = _furnace;
    }

    function pullToFurnace(address seller, uint256 tokenId) external {
        IERC721(ve).safeTransferFrom(seller, furnace, tokenId);
    }
}

contract RegressionPass03ReentrantFurnaceMock is IERC721Receiver {
    address public claim;
    address public ve;
    address public mineMarket;
    address public shareholderRoyalties;
    address public mineCore;
    address public sweepTo;
    bool public armed;

    constructor(address _claim, address _ve, address _mineMarket, address _sr, address _mineCore, address _sweepTo) {
        claim = _claim;
        ve = _ve;
        mineMarket = _mineMarket;
        shareholderRoyalties = _sr;
        mineCore = _mineCore;
        sweepTo = _sweepTo;
    }

    function armBurn(bool on) external {
        armed = on;
    }

    function onERC721Received(address, address, uint256 tokenId, bytes calldata) external override returns (bytes4) {
        if (armed) {
            armed = false;
            IVeClaimNFT(ve).furnaceBurnAndWithdraw(tokenId, sweepTo);
        }

        return IERC721Receiver.onERC721Received.selector;
    }
}

/// @notice supplementary tests covering:
///   - receiver-hook reentrancy on MineMarket -> Furnace `safeTransferFrom`
///   - repeated `setAutoMax(tokenId, true)` must refresh the raw stored `lockEnd`
contract RegressionPass03VeClaimNFTTest is Test {
    ClaimToken internal claim;
    VeClaimNFTHarness internal ve;
    MockShareholderRoyaltiesCheckpoint internal sr;
    MockMineCoreWiringView internal core;
    RegressionPass03MarketRouterMock internal market;
    RegressionPass03ReentrantFurnaceMock internal furnace;

    address internal owner = address(0xA11CE);
    address internal alice = address(0xB0B);
    address internal thief = address(0xBAD);

    function setUp() public {
        vm.etch(owner, hex"00");

        claim = new ClaimToken(owner);
        vm.mockCall(owner, abi.encodeWithSignature("claim()"), abi.encode(address(claim)));
        ve = new VeClaimNFTHarness(address(claim), owner);
        sr = new MockShareholderRoyaltiesCheckpoint();
        core = new MockMineCoreWiringView(address(claim), address(ve), address(sr));
        market = new RegressionPass03MarketRouterMock(address(claim), address(ve), address(sr));
        furnace = new RegressionPass03ReentrantFurnaceMock(
            address(claim), address(ve), address(market), address(sr), address(core), thief
        );

        market.setFurnace(address(furnace));
        core.setFurnace(address(furnace));
        sr.setWiring(address(core), address(market), address(furnace), address(ve));

        vm.mockCall(owner, abi.encodeWithSignature("emissionStartTime()"), abi.encode(uint256(1)));
        vm.mockCall(owner, abi.encodeWithSignature("GENESIS_ACCRUAL_DURATION()"), abi.encode(uint256(604800)));

        vm.startPrank(owner);
        claim.setMineCore(address(core));
        ve.setMineMarket(address(market));
        ve.setFurnace(address(furnace));
        vm.stopPrank();
    }

    function _mintClaim(address to, uint256 amount) internal {
        vm.startPrank(owner);
        claim.setMineCore(owner);
        claim.mint(to, amount);
        claim.setMineCore(address(core));
        vm.stopPrank();
    }

    function test_safeTransferFrom_marketCanTransferToFurnaceWhenReceiverDoesNotReenter() public {
        uint256 amount = Constants.MIN_LOCK_AMOUNT;
        _mintClaim(alice, amount);

        vm.startPrank(alice);
        claim.approve(address(ve), amount);
        uint256 tokenId = ve.createLock(amount, Constants.MIN_LOCK_DURATION, false);
        vm.stopPrank();

        market.pullToFurnace(alice, tokenId);

        assertEq(ve.ownerOf(tokenId), address(furnace), "lock should move into furnace custody");
        assertEq(ve.totalLockedClaim(), amount, "custody transfer must not change principal accounting");
        assertEq(claim.balanceOf(address(ve)), amount, "principal should remain locked inside ve");
    }

    function test_safeTransferFrom_reentrantReceiverCannotConsumeLock() public {
        uint256 amount = Constants.MIN_LOCK_AMOUNT;
        _mintClaim(alice, amount);

        vm.startPrank(alice);
        claim.approve(address(ve), amount);
        uint256 tokenId = ve.createLock(amount, Constants.MIN_LOCK_DURATION, false);
        vm.stopPrank();

        furnace.armBurn(true);

        vm.expectRevert();
        market.pullToFurnace(alice, tokenId);

        assertEq(ve.ownerOf(tokenId), alice, "lock owner should remain seller after revert");
        assertEq(claim.balanceOf(thief), 0, "receiver must not siphon principal during callback");
        assertEq(ve.totalLockedClaim(), amount, "totalLockedClaim should remain unchanged");
        assertEq(claim.balanceOf(address(ve)), amount, "ve should still hold the locked principal");
    }

    function test_setAutoMax_trueRefreshesStoredEndEvenWhenAlreadyEnabled() public {
        uint256 amount = Constants.MIN_LOCK_AMOUNT;
        _mintClaim(alice, amount);

        vm.startPrank(alice);
        claim.approve(address(ve), amount);
        uint256 tokenId = ve.createLock(amount, Constants.MAX_LOCK_DURATION, true);
        vm.stopPrank();

        (uint256[] memory amounts0, uint256[] memory lockEnds0, bool[] memory autoMax0) =
            ve.getShareholderLockParams(alice);
        assertEq(amounts0.length, 1, "expected single lock");
        assertEq(amounts0[0], amount, "unexpected principal");
        assertTrue(autoMax0[0], "lock should start in autoMax mode");
        uint256 rawEnd0 = lockEnds0[0];

        vm.warp(block.timestamp + 30 days);

        vm.prank(alice);
        ve.setAutoMax(tokenId, true);

        (uint256[] memory amounts1, uint256[] memory lockEnds1, bool[] memory autoMax1) =
            ve.getShareholderLockParams(alice);
        assertEq(amounts1.length, 1, "lock count changed unexpectedly");
        assertEq(amounts1[0], amount, "principal changed unexpectedly");
        assertTrue(autoMax1[0], "lock should remain autoMax");
        assertEq(lockEnds1[0], block.timestamp + Constants.MAX_LOCK_DURATION, "raw lockEnd must refresh to now + MAX");
        assertGt(lockEnds1[0], rawEnd0, "re-enabling autoMax should move the stored end forward");
        assertEq(ve.veBalanceOf(alice), amount, "economic ve should remain max-weight");
    }
}
