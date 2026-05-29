// SPDX-License-Identifier: MIT
pragma solidity ^0.8.34;

import {Test} from "forge-std/Test.sol";

import {ClaimToken} from "src/ClaimToken.sol";
import {MineCore} from "src/MineCore.sol";
import {Furnace} from "src/Furnace.sol";
import {FurnaceGuardHelper} from "src/FurnaceGuardHelper.sol";

import {MarketRouter} from "src/MarketRouter.sol";
import {ShareholderRoyalties} from "src/ShareholderRoyalties.sol";
import {UpgradeableProtocolBase} from "src/lib/UpgradeableProtocolBase.sol";

import {VeClaimNFTHarness} from "./mocks/VeClaimNFTHarness.sol";

/// @notice UpgradeableProtocolBase.transferOwnership must reject address(0).
///         All 4 runtime quartet contracts (MineCore, Furnace, MarketRouter, ShareholderRoyalties)
///         inherit from UpgradeableProtocolBase and must enforce this check, mirroring OZ
///         Ownable2Step semantics where pendingOwner = address(0) is reserved as the
///         "no transfer in flight" sentinel.
contract UpgradeableProtocolBase_TransferOwnership is Test {
    address internal constant OWNER = address(0xA11CE);
    address internal constant ALICE = address(0xA);

    ClaimToken internal claim;
    VeClaimNFTHarness internal ve;
    ShareholderRoyalties internal royalties;
    MineCore internal mineCore;
    Furnace internal furnace;
    MarketRouter internal marketRouter;

    function setUp() public {
        claim = new ClaimToken(OWNER);
        ve = new VeClaimNFTHarness(address(claim), OWNER);
        royalties = new ShareholderRoyalties(address(ve), OWNER);
        mineCore = new MineCore(address(claim), address(ve), address(royalties), OWNER);
        furnace = new Furnace(
            address(claim), address(ve), address(new FurnaceGuardHelper(address(claim), address(ve))), OWNER
        );
        marketRouter = new MarketRouter(address(claim), address(ve), address(royalties), OWNER);
    }

    function test_mineCore_transferOwnership_zeroAddress_reverts() public {
        vm.prank(OWNER);
        vm.expectRevert(abi.encodeWithSelector(UpgradeableProtocolBase.OwnableInvalidOwner.selector, address(0)));
        mineCore.transferOwnership(address(0));
    }

    function test_furnace_transferOwnership_zeroAddress_reverts() public {
        vm.prank(OWNER);
        vm.expectRevert(abi.encodeWithSelector(UpgradeableProtocolBase.OwnableInvalidOwner.selector, address(0)));
        furnace.transferOwnership(address(0));
    }

    function test_marketRouter_transferOwnership_zeroAddress_reverts() public {
        vm.prank(OWNER);
        vm.expectRevert(abi.encodeWithSelector(UpgradeableProtocolBase.OwnableInvalidOwner.selector, address(0)));
        marketRouter.transferOwnership(address(0));
    }

    function test_shareholderRoyalties_transferOwnership_zeroAddress_reverts() public {
        vm.prank(OWNER);
        vm.expectRevert(abi.encodeWithSelector(UpgradeableProtocolBase.OwnableInvalidOwner.selector, address(0)));
        royalties.transferOwnership(address(0));
    }

    function test_mineCore_transferOwnership_validAddress_succeeds() public {
        vm.prank(OWNER);
        mineCore.transferOwnership(ALICE);
        assertEq(mineCore.pendingOwner(), ALICE);
    }
}
