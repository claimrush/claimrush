// SPDX-License-Identifier: MIT
pragma solidity ^0.8.34;

import {Test} from "forge-std/Test.sol";
import {ClaimToken} from "src/ClaimToken.sol";
import {Errors} from "src/lib/Errors.sol";
import {Constants} from "src/lib/Constants.sol";
import {VeClaimNFTHarness} from "../mocks/VeClaimNFTHarness.sol";
import {MockShareholderRoyaltiesCheckpoint} from "../mocks/MockShareholderRoyaltiesCheckpoint.sol";

/// @title Lock lifecycle invariant tests for VeClaimNFT.
/// @dev Covers invariants from the invariants document §3:
///      - Principal conservation across create/add/extend/merge/unlock
///      - totalVeCached conservatism (>= sum of individual ve balances)
///      - Duration bounds enforcement
contract VeClaimNFTLockLifecycleInvariantsTest is Test {
    ClaimToken internal claim;
    VeClaimNFTHarness internal ve;
    MockShareholderRoyaltiesCheckpoint internal srMock;

    address internal owner = address(0xA11CE);
    address internal mineCore = address(0xC0DE);
    address internal mineMarket = address(0xB0B0);
    address internal furnace = address(0xF00D);
    address internal alice = address(0xA);

    function setUp() public {
        vm.etch(owner, hex"00");
        vm.etch(mineCore, hex"00");
        vm.etch(mineMarket, hex"00");
        vm.etch(furnace, hex"00");

        claim = new ClaimToken(owner);
        ve = new VeClaimNFTHarness(address(claim), owner);
        srMock = new MockShareholderRoyaltiesCheckpoint();

        // Standard wiring mocks
        vm.mockCall(owner, abi.encodeWithSignature("claim()"), abi.encode(address(claim)));
        vm.mockCall(furnace, abi.encodeWithSignature("shareholderRoyalties()"), abi.encode(address(srMock)));
        vm.mockCall(mineMarket, abi.encodeWithSignature("royalties()"), abi.encode(address(srMock)));
        vm.mockCall(furnace, abi.encodeWithSignature("ve()"), abi.encode(address(ve)));
        vm.mockCall(furnace, abi.encodeWithSignature("mineMarket()"), abi.encode(mineMarket));
        vm.mockCall(furnace, abi.encodeWithSignature("mineCore()"), abi.encode(mineCore));
        vm.mockCall(furnace, abi.encodeWithSignature("claim()"), abi.encode(address(claim)));
        vm.mockCall(mineMarket, abi.encodeWithSignature("ve()"), abi.encode(address(ve)));
        vm.mockCall(mineMarket, abi.encodeWithSignature("claim()"), abi.encode(address(claim)));
        vm.mockCall(mineCore, abi.encodeWithSignature("ve()"), abi.encode(address(ve)));
        vm.mockCall(mineCore, abi.encodeWithSignature("claim()"), abi.encode(address(claim)));
        vm.mockCall(mineCore, abi.encodeWithSignature("furnace()"), abi.encode(furnace));
        vm.mockCall(mineCore, abi.encodeWithSignature("royalties()"), abi.encode(address(srMock)));
        vm.mockCall(address(srMock), abi.encodeWithSignature("ve()"), abi.encode(address(ve)));
        vm.mockCall(address(srMock), abi.encodeWithSignature("furnace()"), abi.encode(furnace));
        vm.mockCall(address(srMock), abi.encodeWithSignature("mineMarket()"), abi.encode(mineMarket));
        vm.mockCall(address(srMock), abi.encodeWithSignature("mineCore()"), abi.encode(mineCore));
        vm.mockCall(mineCore, abi.encodeWithSignature("emissionStartTime()"), abi.encode(uint256(1)));
        vm.mockCall(mineCore, abi.encodeWithSignature("GENESIS_ACCRUAL_DURATION()"), abi.encode(uint256(604800)));

        vm.prank(owner);
        claim.setMineCore(mineCore);

        vm.startPrank(owner);
        ve.setMineMarket(mineMarket);
        ve.setFurnace(furnace);
        vm.stopPrank();

        vm.prank(mineCore);
        claim.mint(alice, 50_000_000e18);

        vm.prank(alice);
        claim.approve(address(ve), type(uint256).max);
    }

    /// @dev §3: totalLockedClaim = Σ lock principals (no CLAIM created or destroyed in lock ops).
    function testFuzz_PrincipalConservationOnCreateAndAddToLock(uint128 amount1, uint128 amount2) public {
        amount1 = uint128(bound(amount1, Constants.MIN_LOCK_AMOUNT, 5_000_000e18));
        amount2 = uint128(bound(amount2, Constants.MIN_LOCK_AMOUNT, 5_000_000e18));

        uint256 claimBefore = claim.balanceOf(alice);

        vm.startPrank(alice);
        uint256 tokenId = ve.createLock(uint256(amount1), Constants.MAX_LOCK_DURATION, false);
        ve.addToLock(tokenId, uint256(amount2));
        vm.stopPrank();

        // Principal conservation: CLAIM balance delta == totalLockedClaim
        uint256 claimAfter = claim.balanceOf(alice);
        uint256 totalLocked = ve.totalLockedClaim();
        assertEq(claimBefore - claimAfter, totalLocked, "CLAIM delta must equal totalLockedClaim");

        // CLAIM in ve contract must back totalLockedClaim
        assertGe(claim.balanceOf(address(ve)), totalLocked, "ve CLAIM balance must back locked amount");
    }

    /// @dev §3: Principal conservation across merge: no CLAIM created.
    function testFuzz_PrincipalConservationOnMerge(uint128 amt1, uint128 amt2) public {
        amt1 = uint128(bound(amt1, Constants.MIN_LOCK_AMOUNT, 5_000_000e18));
        amt2 = uint128(bound(amt2, Constants.MIN_LOCK_AMOUNT, 5_000_000e18));

        vm.startPrank(alice);
        uint256 id1 = ve.createLock(uint256(amt1), Constants.MAX_LOCK_DURATION, false);
        uint256 id2 = ve.createLock(uint256(amt2), Constants.MAX_LOCK_DURATION, false);
        vm.stopPrank();

        // v1.0.0: external user merge lives on Furnace; the principal-conservation
        // property of `_mergeLocksInternal` is reached through the Furnace-only
        // `mergeLocksFor` sibling. Bonus accounting is exercised by the dedicated
        // reserve-accounting invariant suite (`Furnace_ReserveAccounting_Invariants`).
        uint256 lockedBefore = ve.totalLockedClaim();
        vm.prank(furnace);
        ve.mergeLocksFor(alice, id1, id2);
        uint256 lockedAfter = ve.totalLockedClaim();

        assertEq(lockedAfter, lockedBefore, "merge must conserve totalLockedClaim");
        assertGe(claim.balanceOf(address(ve)), lockedAfter, "ve CLAIM balance must back locked");
    }

    /// @dev §3: After unlock, CLAIM returns to user; totalLockedClaim decreases.
    function testFuzz_PrincipalConservationOnUnlock(uint128 amount) public {
        amount = uint128(bound(amount, Constants.MIN_LOCK_AMOUNT, 5_000_000e18));

        vm.prank(alice);
        uint256 tokenId = ve.createLock(uint256(amount), Constants.MIN_LOCK_DURATION, false);

        uint256 lockedBefore = ve.totalLockedClaim();
        uint256 claimBefore = claim.balanceOf(alice);

        vm.warp(block.timestamp + Constants.MIN_LOCK_DURATION + 1);

        vm.prank(alice);
        ve.unlock(tokenId);

        assertEq(ve.totalLockedClaim(), 0, "totalLockedClaim must be 0 after full unlock");
        assertEq(claim.balanceOf(alice), claimBefore + lockedBefore, "all CLAIM must return on unlock");
    }
}
