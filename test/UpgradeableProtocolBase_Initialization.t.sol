// SPDX-License-Identifier: MIT
pragma solidity ^0.8.34;

import {Test} from "forge-std/Test.sol";

import {ClaimToken} from "src/ClaimToken.sol";
import {Furnace} from "src/Furnace.sol";
import {FurnaceGuardHelper} from "src/FurnaceGuardHelper.sol";
import {MarketRouter} from "src/MarketRouter.sol";
import {MineCore} from "src/MineCore.sol";
import {ShareholderRoyalties} from "src/ShareholderRoyalties.sol";
import {UpgradeableProtocolBase} from "src/lib/UpgradeableProtocolBase.sol";

import {VeClaimNFTHarness} from "./mocks/VeClaimNFTHarness.sol";

contract UpgradeableProtocolBase_Initialization is Test {
    address internal constant OWNER = address(0xA11CE);

    function test_runtimeQuartetImplementationsRejectDirectInitialize() public {
        ClaimToken claim = new ClaimToken(OWNER);
        VeClaimNFTHarness ve = new VeClaimNFTHarness(address(claim), OWNER);
        ShareholderRoyalties royalties = new ShareholderRoyalties(address(ve), address(0));
        FurnaceGuardHelper helper = new FurnaceGuardHelper(address(claim), address(ve));
        Furnace furnace = new Furnace(address(claim), address(ve), address(helper), address(0));
        MarketRouter marketRouter = new MarketRouter(address(claim), address(ve), address(royalties), address(0));
        MineCore mineCore = new MineCore(address(claim), address(ve), address(royalties), address(0));

        vm.expectRevert(UpgradeableProtocolBase.InvalidInitialization.selector);
        royalties.initialize(OWNER);

        vm.expectRevert(UpgradeableProtocolBase.InvalidInitialization.selector);
        furnace.initialize(OWNER);

        vm.expectRevert(UpgradeableProtocolBase.InvalidInitialization.selector);
        marketRouter.initialize(OWNER);

        vm.expectRevert(UpgradeableProtocolBase.InvalidInitialization.selector);
        mineCore.initialize(OWNER);
    }
}
