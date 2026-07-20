// SPDX-License-Identifier: MIT
pragma solidity ^0.8.34;

import {Test} from "forge-std/Test.sol";

import {ClaimToken} from "src/ClaimToken.sol";
import {MineCore} from "src/MineCore.sol";
import {ShareholderRoyalties} from "src/ShareholderRoyalties.sol";
import {FurnaceQuoter} from "src/FurnaceQuoter.sol";
import {MineCoreHelper} from "src/MineCoreHelper.sol";
import {Constants} from "src/lib/Constants.sol";
import {DelegationHub} from "src/DelegationHub.sol";

import {FurnaceHarness} from "../mocks/FurnaceHarness.sol";
import {MockContract} from "../mocks/MockContract.sol";
import {MockEntryTokenRegistry} from "../mocks/MockEntryTokenRegistry.sol";
import {MockLpRewardsVault} from "../mocks/MockLpRewardsVault.sol";
import {VeClaimNFTHarness} from "../mocks/VeClaimNFTHarness.sol";

/// @title Regression — King-stream force-lock destination requires the full anti-recycling horizon.
/// @notice The force-locked slice of a dethroned King's mined CLAIM is never extended when routed
///         into an existing lock. Accepting a short existing lock (e.g. a self-created 7-day lock)
///         would collapse the force-lock horizon and let ~100% of the slice become liquid within
///         days, defeating the "liquid can never exceed 50%" bound. A non-AutoMax destination is
///         therefore only eligible when its remaining duration is at least
///         KING_FORCE_LOCK_MIN_DURATION; otherwise settlement falls back to the default AutoMax lock.
contract KingForceLockHorizonRegression is Test {
    uint8 internal constant REASON_INVALID_DURATION = 5;

    ClaimToken internal claim;
    VeClaimNFTHarness internal ve;
    MineCore internal mineCore;
    FurnaceHarness internal furnace;
    FurnaceQuoter internal furnaceQuoter;
    MockLpRewardsVault internal lpVault;
    ShareholderRoyalties internal royalties;
    DelegationHub internal delegationHub;
    MineCoreHelper internal helper;
    address internal mineMarket;
    address internal registry;
    address internal mineCoreRegistry;

    address internal owner = address(0xA11CE);
    address internal king = address(0x6B1B);

    function setUp() public {
        claim = new ClaimToken(owner);
        ve = new VeClaimNFTHarness(address(claim), owner);
        royalties = new ShareholderRoyalties(address(ve), owner);
        mineCore = new MineCore(address(claim), address(ve), address(royalties), owner);
        furnace = new FurnaceHarness(address(claim), address(ve), owner);
        furnaceQuoter = new FurnaceQuoter(address(furnace));
        delegationHub = new DelegationHub();
        helper = new MineCoreHelper();
        mineMarket = address(new MockContract());
        registry = address(new MockEntryTokenRegistry());
        mineCoreRegistry = address(new MockEntryTokenRegistry());
        vm.mockCall(mineMarket, abi.encodeWithSignature("claim()"), abi.encode(address(claim)));
        vm.mockCall(mineMarket, abi.encodeWithSignature("ve()"), abi.encode(address(ve)));
        vm.mockCall(mineMarket, abi.encodeWithSignature("royalties()"), abi.encode(address(royalties)));

        vm.startPrank(owner);
        claim.setMineCore(address(mineCore));
        furnace.setMineCore(address(mineCore));
        furnace.setFurnaceQuoter(address(furnaceQuoter));
        furnace.setShareholderRoyalties(address(royalties));
        furnace.setMineMarket(mineMarket);
        furnace.setEntryTokenRegistry(registry);
        mineCore.setFurnace(address(furnace));
        mineCore.setDelegationHub(address(delegationHub));
        mineCore.setEntryTokenRegistry(mineCoreRegistry);
        furnace.setDelegationHub(address(delegationHub));
        royalties.setWiring(address(mineCore), mineMarket, address(furnace));
        ve.setFurnace(address(furnace));
        ve.setMineMarket(mineMarket);
        vm.stopPrank();

        lpVault = new MockLpRewardsVault();
        lpVault.setFurnace(address(furnace));
        vm.prank(owner);
        furnace.setLpRewardsVault(address(lpVault));
    }

    function _createLock(uint256 amount, uint256 duration, bool autoMax) internal returns (uint256 tokenId) {
        vm.prank(address(mineCore));
        claim.mint(king, amount);
        vm.startPrank(king);
        claim.approve(address(ve), type(uint256).max);
        tokenId = ve.createLock(amount, duration, autoMax);
        vm.stopPrank();
    }

    /// @notice A self-created 7-day lock is rejected as a force-lock destination.
    function test_ShortExistingLockRejected() public {
        uint256 tokenId = _createLock(Constants.MIN_LOCK_AMOUNT, Constants.MIN_LOCK_DURATION, false);

        (bool ok,,,, uint8 reason) = helper.resolveKingAutoLockDestination(address(ve), king, tokenId, 0, false);

        assertFalse(ok, "7-day lock must be rejected as force-lock destination");
        assertEq(reason, REASON_INVALID_DURATION, "reason must be INVALID_DURATION");
    }

    /// @notice A mid-length (180-day) non-AutoMax lock is still below the required horizon.
    function test_MidLengthExistingLockRejected() public {
        uint256 tokenId = _createLock(Constants.MIN_LOCK_AMOUNT, 180 days, false);

        (bool ok,,,, uint8 reason) = helper.resolveKingAutoLockDestination(address(ve), king, tokenId, 0, false);

        assertFalse(ok, "180-day lock must be rejected as force-lock destination");
        assertEq(reason, REASON_INVALID_DURATION, "reason must be INVALID_DURATION");
    }

    /// @notice An AutoMax lock retains the full horizon and remains an eligible destination.
    function test_AutoMaxExistingLockAccepted() public {
        uint256 tokenId = _createLock(Constants.MIN_LOCK_AMOUNT, Constants.MAX_LOCK_DURATION, true);

        (bool ok, uint256 resolvedTokenId, uint256 resolvedDuration,, uint8 reason) =
            helper.resolveKingAutoLockDestination(address(ve), king, tokenId, 0, false);

        assertTrue(ok, "AutoMax lock must be accepted");
        assertEq(resolvedTokenId, tokenId, "resolves to the AutoMax lock");
        assertEq(resolvedDuration, Constants.MAX_LOCK_DURATION, "AutoMax resolves at MAX_LOCK_DURATION");
        assertEq(reason, 0, "no rejection reason");
    }

    /// @notice The default create-once path (targetTokenId == 0) is unaffected and still resolves.
    function test_DefaultCreateOnceStillResolves() public {
        (bool ok, uint256 resolvedTokenId,,, uint8 reason) =
            helper.resolveKingAutoLockDestination(address(ve), king, 0, 0, true);

        assertTrue(ok, "create-once default must resolve");
        assertEq(resolvedTokenId, 0, "create-once returns tokenId 0");
        assertEq(reason, 0, "no rejection reason");
    }
}
