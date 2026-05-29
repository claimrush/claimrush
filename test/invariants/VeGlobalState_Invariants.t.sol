// SPDX-License-Identifier: MIT
pragma solidity ^0.8.34;

import {Test} from "forge-std/Test.sol";

import {ClaimToken} from "src/ClaimToken.sol";
import {DelegationHub} from "src/DelegationHub.sol";
import {Constants} from "src/lib/Constants.sol";
import {Errors} from "src/lib/Errors.sol";

import {VeClaimNFTHarness} from "../mocks/VeClaimNFTHarness.sol";
import {MockShareholderRoyaltiesCheckpointSpy} from "../mocks/MockShareholderRoyaltiesCheckpointSpy.sol";

contract MockFurnaceWithSR {
    address public immutable sr;

    constructor(address sr_) {
        sr = sr_;
    }

    function shareholderRoyalties() external view returns (address) {
        return sr;
    }

    function burnAndWithdraw(VeClaimNFTHarness ve, uint256 tokenId, address to) external {
        ve.furnaceBurnAndWithdraw(tokenId, to);
    }
}

/// @dev Property-style tests for transfer restrictions + pointer maintenance.
contract VeGlobalStateInvariantsTest is Test {
    ClaimToken public claim;
    VeClaimNFTHarness internal ve;

    MockShareholderRoyaltiesCheckpointSpy internal sr;
    MockFurnaceWithSR internal furnaceMock;
    DelegationHub internal canonicalHub;

    address internal owner = address(0xA11CE);
    address internal mineCore = address(0xC0DE);
    address internal market = address(0xB0B0);
    address internal alice = address(0xA);
    address internal bob = address(0xB);

    function setUp() public {
        // Mock addresses must look like contracts for NotAContract guards.
        vm.etch(mineCore, hex"00");
        vm.etch(market, hex"00");

        vm.startPrank(owner);
        claim = new ClaimToken(owner);

        ve = new VeClaimNFTHarness(address(claim), owner);
        sr = new MockShareholderRoyaltiesCheckpointSpy(address(ve));
        furnaceMock = new MockFurnaceWithSR(address(sr));
        canonicalHub = new DelegationHub();
        vm.mockCall(market, abi.encodeWithSignature("royalties()"), abi.encode(address(sr)));
        vm.mockCall(market, abi.encodeWithSignature("ve()"), abi.encode(address(ve)));
        vm.mockCall(market, abi.encodeWithSignature("claim()"), abi.encode(address(claim)));
        vm.mockCall(address(furnaceMock), abi.encodeWithSignature("mineMarket()"), abi.encode(market));
        vm.mockCall(address(furnaceMock), abi.encodeWithSignature("mineCore()"), abi.encode(mineCore));
        vm.mockCall(address(furnaceMock), abi.encodeWithSignature("ve()"), abi.encode(address(ve)));
        vm.mockCall(address(furnaceMock), abi.encodeWithSignature("claim()"), abi.encode(address(claim)));
        vm.mockCall(address(furnaceMock), abi.encodeWithSignature("delegationHub()"), abi.encode(address(canonicalHub)));

        vm.mockCall(mineCore, abi.encodeWithSignature("ve()"), abi.encode(address(ve)));
        vm.mockCall(mineCore, abi.encodeWithSignature("claim()"), abi.encode(address(claim)));
        vm.mockCall(mineCore, abi.encodeWithSignature("furnace()"), abi.encode(address(furnaceMock)));
        vm.mockCall(mineCore, abi.encodeWithSignature("delegationHub()"), abi.encode(address(canonicalHub)));
        vm.mockCall(mineCore, abi.encodeWithSignature("royalties()"), abi.encode(address(sr)));
        vm.mockCall(mineCore, abi.encodeWithSignature("emissionStartTime()"), abi.encode(uint256(1)));
        vm.mockCall(mineCore, abi.encodeWithSignature("GENESIS_ACCRUAL_DURATION()"), abi.encode(uint256(604800)));

        claim.setMineCore(mineCore);
        ve.setFurnace(address(furnaceMock));
        ve.setMineMarket(market);
        vm.stopPrank();

        vm.startPrank(mineCore);
        claim.mint(alice, 50_000e18);
        claim.mint(bob, 50_000e18);
        vm.stopPrank();
    }

    function _assertTotalLockedEqualsSum(uint256[] memory tokenIds) internal view {
        uint256 sum;
        for (uint256 i = 0; i < tokenIds.length; i++) {
            (uint256 amount,,,) = ve.getLockInfo(tokenIds[i]);
            sum += amount;
        }
        assertEq(ve.totalLockedClaim(), sum);
    }

    function testFuzz_OwnerTransferAlwaysReverts(uint256 tokenId) public {
        tokenId = bound(tokenId, 1, type(uint256).max);
        ve.mintForTest(alice, tokenId);

        vm.prank(alice);
        vm.expectRevert(Errors.OnlyMineMarket.selector);
        ve.transferFrom(alice, bob, tokenId);
    }

    function test_PrincipalConservation_totalLockedClaimEqualsSumOfLockAmounts() public {
        uint256[] memory tokenIds = new uint256[](2);

        // Alice creates a lock.
        vm.startPrank(alice);
        claim.approve(address(ve), type(uint256).max);
        uint256 id1 = ve.createLock(Constants.MIN_LOCK_AMOUNT, Constants.MIN_LOCK_DURATION, false);
        vm.stopPrank();

        tokenIds[0] = id1;
        _assertTotalLockedEqualsSum(tokenIds);

        // Alice increases principal.
        vm.prank(alice);
        ve.addToLock(id1, 1_000e18);
        _assertTotalLockedEqualsSum(tokenIds);

        // Bob creates a second lock.
        vm.startPrank(bob);
        claim.approve(address(ve), type(uint256).max);
        uint256 id2 = ve.createLock(Constants.MIN_LOCK_AMOUNT * 2, Constants.MIN_LOCK_DURATION, false);
        vm.stopPrank();

        tokenIds[1] = id2;
        _assertTotalLockedEqualsSum(tokenIds);

        // Alice unlocks after expiry (burn path 1).
        (, uint256 lockEnd,,) = ve.getLockInfo(id1);
        vm.warp(lockEnd + 1);

        vm.prank(alice);
        ve.unlock(id1);
        _assertTotalLockedEqualsSum(tokenIds);

        // Bob sells into the furnace (burn path 2).
        ve.setApprovalForAllForTest(bob, market, true);

        vm.prank(market);
        ve.transferFrom(bob, address(furnaceMock), id2);

        furnaceMock.burnAndWithdraw(ve, id2, bob);
        _assertTotalLockedEqualsSum(tokenIds);

        assertEq(ve.totalLockedClaim(), 0);
    }

    function testFuzz_FurnaceExtendThenTopUp_FirstCheckpointUsesPreExtensionEnd(
        uint40 durationRaw,
        uint40 extensionRaw,
        uint96 topUpRaw
    ) public {
        uint256 duration = bound(uint256(durationRaw), Constants.MIN_LOCK_DURATION, Constants.MAX_LOCK_DURATION - 1);
        uint256 extension = bound(uint256(extensionRaw), 1, Constants.MAX_LOCK_DURATION - duration);
        uint256 topUp = bound(uint256(topUpRaw), 1_000e18, 10_000e18);

        vm.startPrank(alice);
        claim.approve(address(ve), type(uint256).max);
        uint256 tokenId = ve.createLock(1_000e18, duration, false);
        vm.stopPrank();

        sr.reset();
        sr.setTokenIdToInspect(tokenId);

        vm.prank(mineCore);
        claim.mint(address(furnaceMock), topUp);
        vm.prank(address(furnaceMock));
        claim.approve(address(ve), topUp);

        (, uint256 oldEnd,,) = ve.getLockInfo(tokenId);
        uint256 newEnd = oldEnd + extension;

        vm.startPrank(address(furnaceMock));
        ve.extendLockToFor(alice, tokenId, newEnd);
        ve.addToLockFor(alice, tokenId, topUp);
        vm.stopPrank();

        assertEq(sr.firstObservedLockEnd(), oldEnd, "first checkpoint must observe the pre-extension end");
    }

    function testFuzz_FurnaceOnlyExtendRejectsSpoofFurnaceMissingMineCore(uint96 amountRaw, uint40 extensionRaw)
        public
    {
        uint256 amount = bound(uint256(amountRaw), Constants.MIN_LOCK_AMOUNT, 10_000e18);
        uint256 extension = bound(uint256(extensionRaw), 1, 30 days);

        vm.startPrank(alice);
        claim.approve(address(ve), type(uint256).max);
        uint256 tokenId = ve.createLock(amount, Constants.MIN_LOCK_DURATION, false);
        vm.stopPrank();

        address badFurnace = makeAddr("veSpoofFurnaceNoMineCore");
        vm.etch(badFurnace, hex"00");
        vm.mockCall(badFurnace, abi.encodeWithSignature("ve()"), abi.encode(address(ve)));
        vm.mockCall(badFurnace, abi.encodeWithSignature("claim()"), abi.encode(address(claim)));
        vm.mockCall(badFurnace, abi.encodeWithSignature("mineMarket()"), abi.encode(market));

        vm.prank(owner);
        vm.expectRevert(Errors.WiringMismatch.selector);
        ve.setFurnace(badFurnace);
    }

    function testFuzz_FurnaceOnlyExtendRejectsSingleSurfaceFurnaceDrift(uint96 amountRaw, uint40 extensionRaw) public {
        uint256 amount = bound(uint256(amountRaw), Constants.MIN_LOCK_AMOUNT, 10_000e18);
        uint256 extension = bound(uint256(extensionRaw), 1, 30 days);

        MockFurnaceWithSR badFurnace = new MockFurnaceWithSR(address(sr));
        vm.mockCall(address(badFurnace), abi.encodeWithSignature("mineMarket()"), abi.encode(market));
        vm.mockCall(address(badFurnace), abi.encodeWithSignature("mineCore()"), abi.encode(mineCore));
        vm.mockCall(address(badFurnace), abi.encodeWithSignature("ve()"), abi.encode(address(ve)));
        vm.mockCall(address(badFurnace), abi.encodeWithSignature("claim()"), abi.encode(address(claim)));

        vm.prank(owner);
        vm.expectRevert(Errors.WiringMismatch.selector);
        ve.setFurnace(address(badFurnace));
    }

    function testFuzz_SetListedRejectsSingleSurfaceMineMarketDrift(uint96 amountRaw) public {
        uint256 amount = bound(uint256(amountRaw), Constants.MIN_LOCK_AMOUNT, 10_000e18);

        address badMarket = makeAddr("badMineMarketInvariant");
        vm.etch(badMarket, hex"00");
        vm.mockCall(badMarket, abi.encodeWithSignature("ve()"), abi.encode(address(ve)));
        vm.mockCall(badMarket, abi.encodeWithSignature("claim()"), abi.encode(address(claim)));
        vm.mockCall(badMarket, abi.encodeWithSignature("royalties()"), abi.encode(address(sr)));

        vm.prank(owner);
        vm.expectRevert(Errors.WiringMismatch.selector);
        ve.setMineMarket(badMarket);
    }
}
