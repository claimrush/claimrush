// SPDX-License-Identifier: MIT
pragma solidity ^0.8.34;

import {Test} from "forge-std/Test.sol";

import {ClaimToken} from "src/ClaimToken.sol";
import {MineCore} from "src/MineCore.sol";
import {FurnaceQuoter} from "src/FurnaceQuoter.sol";
import {Constants} from "src/lib/Constants.sol";
import {Errors} from "src/lib/Errors.sol";

import {FurnaceHarness} from "./mocks/FurnaceHarness.sol";
import {MockShareholderRoyaltiesCheckpoint} from "./mocks/MockShareholderRoyaltiesCheckpoint.sol";
import {VeClaimNFTHarness} from "./mocks/VeClaimNFTHarness.sol";

/// @notice `quoteAutoMaxBonusBatch` MUST enforce the same batch cap as
///         `Furnace.claimAutoMaxBonusBatch` (`Constants.MAX_AUTOMAX_BONUS_BATCH`).
contract FurnaceQuoter_BatchLimit_Test is Test {
    ClaimToken internal claim;
    VeClaimNFTHarness internal ve;
    MineCore internal mineCore;
    FurnaceHarness internal furnace;
    FurnaceQuoter internal quoter;

    address internal owner = address(0xA11CE);

    function setUp() public {
        claim = new ClaimToken(owner);
        ve = new VeClaimNFTHarness(address(claim), owner);
        MockShareholderRoyaltiesCheckpoint mockSR = new MockShareholderRoyaltiesCheckpoint();
        mineCore = new MineCore(address(claim), address(ve), address(mockSR), owner);
        furnace = new FurnaceHarness(address(claim), address(ve), owner);
        quoter = new FurnaceQuoter(address(furnace));

        address market = address(0xB0B0);
        vm.etch(market, hex"00");
        vm.mockCall(market, abi.encodeWithSignature("ve()"), abi.encode(address(ve)));
        vm.mockCall(market, abi.encodeWithSignature("claim()"), abi.encode(address(claim)));
        vm.mockCall(market, abi.encodeWithSignature("royalties()"), abi.encode(address(mockSR)));

        vm.startPrank(owner);
        claim.setMineCore(address(mineCore));
        furnace.setMineCore(address(mineCore));
        furnace.setFurnaceQuoter(address(quoter));
        furnace.setShareholderRoyalties(address(mockSR));
        furnace.setMineMarket(market);
        mineCore.setFurnace(address(furnace));
        mockSR.setWiring(address(mineCore), market, address(furnace), address(ve));
        ve.setFurnace(address(furnace));
        ve.setMineMarket(market);
        vm.stopPrank();
    }

    function test_batchQuote_revertsWhenOverLimit() public {
        uint256 overSize = Constants.MAX_AUTOMAX_BONUS_BATCH + 1;
        uint256[] memory ids = new uint256[](overSize);
        for (uint256 i = 0; i < overSize; i++) {
            ids[i] = i + 1;
        }

        vm.expectRevert(Errors.BatchTooLarge.selector);
        quoter.quoteAutoMaxBonusBatch(ids);
    }

    function test_batchQuote_succeedsAtExactLimit() public {
        uint256 n = Constants.MAX_AUTOMAX_BONUS_BATCH;
        uint256[] memory ids = new uint256[](n);
        for (uint256 i = 0; i < n; i++) {
            ids[i] = i + 1;
        }

        // Locks don't exist so bonuses will be 0, but it must not revert with BatchTooLarge.
        (uint256[] memory bonuses, uint256 totalBonus) = quoter.quoteAutoMaxBonusBatch(ids);
        assertEq(bonuses.length, n, "bonuses array length");
        assertEq(totalBonus, 0, "no real locks so total bonus is 0");
    }

    function test_batchQuote_emptyArray() public {
        uint256[] memory ids = new uint256[](0);
        (uint256[] memory bonuses, uint256 totalBonus) = quoter.quoteAutoMaxBonusBatch(ids);
        assertEq(bonuses.length, 0, "empty input -> empty output");
        assertEq(totalBonus, 0, "no bonus for empty batch");
    }

    function test_batchQuote_singleElement() public {
        uint256[] memory ids = new uint256[](1);
        ids[0] = 999;

        (uint256[] memory bonuses, uint256 totalBonus) = quoter.quoteAutoMaxBonusBatch(ids);
        assertEq(bonuses.length, 1, "single-element output");
        assertEq(totalBonus, 0, "non-existent lock returns 0");
    }

    /// @notice Fresh autoMax locks report eligible so the keeper starts the
    ///         onchain AutoMax cursor with the initial zero-bonus call.
    function test_filterAutoMaxBonusEligible_includesFirstTouch() public {
        uint256 amount = 100_000e18;
        vm.prank(address(mineCore));
        claim.mint(owner, amount);

        vm.startPrank(owner);
        claim.approve(address(ve), amount);
        uint256 tokenId = ve.createLock(amount, Constants.MAX_LOCK_DURATION, true);
        vm.stopPrank();

        uint256[] memory ids = new uint256[](1);
        ids[0] = tokenId;

        bool[] memory beforeInit = quoter.filterAutoMaxBonusEligible(ids);
        assertTrue(beforeInit[0], "first touch is eligible so the keeper bootstraps the cursor");

        furnace.claimAutoMaxBonus(tokenId);
        vm.warp(block.timestamp + 1 days);

        bool[] memory afterCooldown = quoter.filterAutoMaxBonusEligible(ids);
        assertTrue(afterCooldown[0], "initialized lock is eligible after cooldown");
    }

    /// @notice `lastAutoMaxBonusClaimBatch` mirrors `Furnace.lastAutoMaxBonusClaim`
    ///         exactly: 0 for first-touch tokens, the bootstrap timestamp after
    ///         the first claim. Used by the keeper to consolidate first-touch /
    ///         cooldown bookkeeping into one eth_call instead of N.
    function test_lastAutoMaxBonusClaimBatch_mirrorsPerTokenView() public {
        uint256 amount = 100_000e18;
        vm.prank(address(mineCore));
        claim.mint(owner, amount * 2);

        vm.startPrank(owner);
        claim.approve(address(ve), amount * 2);
        uint256 freshId = ve.createLock(amount, Constants.MAX_LOCK_DURATION, true);
        uint256 bootstrappedId = ve.createLock(amount, Constants.MAX_LOCK_DURATION, true);
        vm.stopPrank();

        furnace.claimAutoMaxBonus(bootstrappedId);
        uint256 bootstrapTs = block.timestamp;

        uint256[] memory ids = new uint256[](2);
        ids[0] = freshId;
        ids[1] = bootstrappedId;

        uint256[] memory batched = quoter.lastAutoMaxBonusClaimBatch(ids);
        assertEq(batched.length, 2, "output preserves input length");
        assertEq(batched[0], 0, "fresh lock is first-touch");
        assertEq(batched[1], bootstrapTs, "bootstrapped lock matches per-token view");

        assertEq(batched[0], furnace.lastAutoMaxBonusClaim(freshId), "batched fresh equals per-token fresh");
        assertEq(
            batched[1],
            furnace.lastAutoMaxBonusClaim(bootstrappedId),
            "batched bootstrapped equals per-token bootstrapped"
        );
    }

    function test_lastAutoMaxBonusClaimBatch_emptyArray() public {
        uint256[] memory empty = new uint256[](0);
        uint256[] memory result = quoter.lastAutoMaxBonusClaimBatch(empty);
        assertEq(result.length, 0, "empty input returns empty output");
    }

    function test_batchQuote_duplicateIds_match_executionIdempotence() public {
        uint256 reserve = 10_000_000e18;
        vm.prank(address(mineCore));
        claim.mint(address(furnace), reserve);
        vm.prank(address(mineCore));
        furnace.creditReserve(reserve);

        uint256 amount = 100_000e18;
        vm.prank(address(mineCore));
        claim.mint(owner, amount);

        vm.startPrank(owner);
        claim.approve(address(ve), amount);
        uint256 tokenId = ve.createLock(amount, Constants.MAX_LOCK_DURATION, true);
        vm.stopPrank();

        furnace.claimAutoMaxBonus(tokenId); // initialize last claim timestamp
        vm.warp(block.timestamp + 1 days);

        uint256[] memory ids = new uint256[](2);
        ids[0] = tokenId;
        ids[1] = tokenId;

        (uint256[] memory bonuses, uint256 quotedTotal) = quoter.quoteAutoMaxBonusBatch(ids);
        uint256 executedTotal = furnace.claimAutoMaxBonusBatch(ids, ids.length);

        assertGt(bonuses[0], 0, "first occurrence should quote a bonus");
        assertEq(bonuses[1], 0, "later duplicate must not be double-counted");
        assertEq(quotedTotal, executedTotal, "batch quote must mirror execution for duplicates");
    }
}
