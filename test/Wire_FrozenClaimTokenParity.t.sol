// SPDX-License-Identifier: MIT
pragma solidity ^0.8.34;

import {Test} from "forge-std/Test.sol";

import {Wire} from "../script/Wire.s.sol";
import {ClaimAllHelper} from "../src/ClaimAllHelper.sol";
import {ClaimToken} from "../src/ClaimToken.sol";
import {DelegationHub} from "../src/DelegationHub.sol";
import {EntryTokenRegistry} from "../src/EntryTokenRegistry.sol";
import {Furnace} from "../src/Furnace.sol";
import {FurnaceGuardHelper} from "../src/FurnaceGuardHelper.sol";

import {MarketRouter} from "../src/MarketRouter.sol";
import {MineCore} from "../src/MineCore.sol";
import {ShareholderRoyalties} from "../src/ShareholderRoyalties.sol";
import {VeClaimNFTHarness} from "./mocks/VeClaimNFTHarness.sol";

contract _WireFrozenClaimHarness is Wire {
    function execute(Addrs memory a, address broadcaster) external {
        require(msg.sender == broadcaster, "not broadcaster");
        vm.stopPrank();
        vm.startPrank(broadcaster);
        _executeWire(a, broadcaster, address(0), true, false, false);
        vm.stopPrank();
    }
}

contract WireFrozenClaimTokenParityTest is Test {
    function testWireRejectsFrozenClaimTokenMineCoreDrift() public {
        address owner = vm.addr(1);

        ClaimToken claim = new ClaimToken(owner);
        VeClaimNFTHarness ve = new VeClaimNFTHarness(address(claim), owner);
        ShareholderRoyalties royalties = new ShareholderRoyalties(address(ve), owner);
        Furnace furnace = new Furnace(
            address(claim), address(ve), address(new FurnaceGuardHelper(address(claim), address(ve))), owner
        );
        MineCore replacementMineCore = new MineCore(address(claim), address(ve), address(royalties), owner);
        MineCore mineCore = new MineCore(address(claim), address(ve), address(royalties), owner);
        MarketRouter marketRouter = new MarketRouter(address(claim), address(ve), address(royalties), owner);
        EntryTokenRegistry furnaceRegistry = new EntryTokenRegistry(owner);
        EntryTokenRegistry mineCoreRegistry = new EntryTokenRegistry(owner);
        ClaimAllHelper claimAllHelper = new ClaimAllHelper(address(royalties), address(mineCore));
        DelegationHub delegationHub = new DelegationHub();

        vm.startPrank(owner);
        claim.setMineCore(address(mineCore));
        furnace.setMineCore(address(mineCore));
        furnace.setMineMarket(address(marketRouter));
        furnace.setShareholderRoyalties(address(royalties));
        mineCore.setFurnace(address(furnace));
        royalties.setWiring(address(mineCore), address(marketRouter), address(furnace));
        ve.setFurnace(address(furnace));
        ve.setMineMarket(address(marketRouter));
        claim.freezeConfig();
        claim.renounceOwnership();
        vm.stopPrank();

        ClaimAllHelper replacementHelper = new ClaimAllHelper(address(royalties), address(replacementMineCore));

        Wire.Addrs memory addrs;
        addrs.claimToken = address(claim);
        addrs.ve = address(ve);
        addrs.royalties = address(royalties);
        addrs.furnace = address(furnace);
        addrs.marketRouter = address(marketRouter);
        addrs.mineCore = address(replacementMineCore);
        addrs.furnaceEntryTokenRegistry = address(furnaceRegistry);
        addrs.mineCoreEntryTokenRegistry = address(mineCoreRegistry);
        addrs.claimAllHelper = address(replacementHelper);
        addrs.delegationHub = address(delegationHub);

        _WireFrozenClaimHarness harness = new _WireFrozenClaimHarness();

        vm.expectRevert(bytes("Wire: frozen ClaimToken.mineCore mismatch"));
        vm.startPrank(owner);
        harness.execute(addrs, owner);

        assertEq(claim.mineCore(), address(mineCore), "frozen ClaimToken root should stay unchanged");
        assertEq(furnace.mineCore(), address(mineCore), "live Furnace root should stay unchanged");
    }
}
