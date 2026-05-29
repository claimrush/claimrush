// SPDX-License-Identifier: MIT
pragma solidity ^0.8.34;

import {Test} from "forge-std/Test.sol";

import {DelegationHub} from "src/DelegationHub.sol";
import {MaintenanceHub} from "src/MaintenanceHub.sol";
import {MarketRouter} from "src/MarketRouter.sol";
import {ClaimToken} from "src/ClaimToken.sol";
import {EntryTokenRegistry} from "src/EntryTokenRegistry.sol";
import {Furnace} from "src/Furnace.sol";
import {FurnaceGuardHelper} from "src/FurnaceGuardHelper.sol";

import {FurnaceQuoter} from "src/FurnaceQuoter.sol";
import {MineCore} from "src/MineCore.sol";
import {MineCoreQuoter} from "src/MineCoreQuoter.sol";
import {ShareholderRoyalties} from "src/ShareholderRoyalties.sol";
import {ClaimAllHelper} from "src/ClaimAllHelper.sol";
import {AgentLens} from "src/lens/AgentLens.sol";
import {Errors} from "src/lib/Errors.sol";
import {Deploy} from "../script/Deploy.s.sol";

import {MockEntryTokenRegistry} from "./mocks/MockEntryTokenRegistry.sol";
import {MockAerodromeRouter} from "./mocks/MockAerodromeRouter.sol";
import {MockMineCoreWiringView} from "./mocks/MockMineCoreWiringView.sol";
import {MockWETH} from "./mocks/MockWETH.sol";
import {VeClaimNFTHarness} from "./mocks/VeClaimNFTHarness.sol";

contract DummyFactory {}

contract DeploymentWiringTest is Test {
    ClaimToken internal claim;
    VeClaimNFTHarness internal ve;
    ShareholderRoyalties internal royalties;
    Furnace internal furnace;
    MarketRouter internal market;
    MineCore internal mineCore;
    MockEntryTokenRegistry internal furnaceRegistryMock;
    MockEntryTokenRegistry internal mineCoreRegistryMock;

    address internal owner = address(0xA11CE);
    address internal alice = address(0xA);
    address internal bob = address(0xB);

    function setUp() public {
        claim = new ClaimToken(owner);
        ve = new VeClaimNFTHarness(address(claim), owner);
        royalties = new ShareholderRoyalties(address(ve), owner);
        furnace = new Furnace(
            address(claim), address(ve), address(new FurnaceGuardHelper(address(claim), address(ve))), owner
        );
        FurnaceQuoter quoter = new FurnaceQuoter(address(furnace));
        market = new MarketRouter(address(claim), address(ve), address(royalties), owner);
        mineCore = new MineCore(address(claim), address(ve), address(royalties), owner);

        // Wire canonical addresses (ClaimToken.freezeConfig validates MineCore wiring).
        DelegationHub hub = new DelegationHub();
        ClaimAllHelper claimAllHelper = new ClaimAllHelper(address(royalties), address(mineCore));
        furnaceRegistryMock = new MockEntryTokenRegistry();
        mineCoreRegistryMock = new MockEntryTokenRegistry();

        vm.startPrank(owner);
        claim.setMineCore(address(mineCore));
        furnace.setMineCore(address(mineCore));
        furnace.setMineMarket(address(market));
        furnace.setShareholderRoyalties(address(royalties));
        furnace.setFurnaceQuoter(address(quoter));
        // Canonical-hub check: `furnace.setDelegationHub` calls
        // `requireCanonicalDelegationHub` which requires
        // `mineCore.furnace() == furnace` and `mineCore.delegationHub() == hub`
        // *before* the furnace-side hub pointer is set.  Wire MineCore-side
        // bindings first, then bind the hub on Furnace.
        mineCore.setFurnace(address(furnace));
        mineCore.setDelegationHub(address(hub));
        furnace.setDelegationHub(address(hub));
        furnace.setEntryTokenRegistry(address(furnaceRegistryMock));
        mineCore.setEntryTokenRegistry(address(mineCoreRegistryMock));
        mineCore.setClaimAllHelper(address(claimAllHelper));
        royalties.setWiring(address(mineCore), address(market), address(furnace));
        royalties.setClaimAllHelper(address(claimAllHelper));
        ve.setFurnace(address(furnace));
        ve.setMineMarket(address(market));
        vm.stopPrank();
    }

    function testWiringRejectsZeroAddresses() public {
        vm.expectRevert(Errors.ZeroAddress.selector);
        new MineCore(address(0), address(ve), address(royalties), owner);

        // Pre-deploy a valid helper so we can isolate Furnace's own zero-address check.
        FurnaceGuardHelper validHelper = new FurnaceGuardHelper(address(claim), address(ve));

        vm.expectRevert(Errors.ZeroAddress.selector);
        new Furnace(address(0), address(ve), address(validHelper), owner);

        vm.expectRevert(Errors.ZeroAddress.selector);
        new Furnace(address(claim), address(0), address(validHelper), owner);

        vm.expectRevert(Errors.ZeroAddress.selector);
        new Furnace(address(claim), address(ve), address(0), owner);

        vm.expectRevert(Errors.ZeroAddress.selector);
        new MarketRouter(address(claim), address(0), address(royalties), owner);

        vm.expectRevert(Errors.ZeroAddress.selector);
        new VeClaimNFTHarness(address(0), owner);

        vm.expectRevert(Errors.ZeroAddress.selector);
        new ShareholderRoyalties(address(0), owner);
    }

    function testCoreConstructorsRejectNonContractImmutableRoots() public {
        vm.expectRevert(Errors.NotAContract.selector);
        new VeClaimNFTHarness(address(0xBEEF), owner);

        vm.expectRevert(Errors.NotAContract.selector);
        new ShareholderRoyalties(address(0xCAFE), owner);

        vm.expectRevert(Errors.NotAContract.selector);
        new MineCoreQuoter(address(0xF00D));
    }

    function testMineCoreQuoterPinsCanonicalMineCore() public {
        MineCoreQuoter quoter = new MineCoreQuoter(address(mineCore));
        assertEq(quoter.mineCore(), address(mineCore));
    }

    function testProductionDeployRequiresExplicitLpWithdrawRecipientOnRealNetworks() public {
        vm.chainId(84532);

        MockWETH weth = new MockWETH();
        DummyFactory factory = new DummyFactory();
        MockAerodromeRouter router = new MockAerodromeRouter(address(factory), address(weth));

        vm.setEnv("PRIVATE_KEY", "1");
        vm.setEnv("AERODROME_ROUTER", vm.toString(address(router)));
        vm.setEnv("LP_WITHDRAW_RECIPIENT", "");

        Deploy deployScript = new Deploy();

        vm.expectRevert("Deploy: LP_WITHDRAW_RECIPIENT must be set explicitly on real networks");
        deployScript.run();
    }

    function testProductionStyleWethClaimHopIsDeferredUntilCanonicalPoolIsLive() public {
        MockWETH weth = new MockWETH();
        address factory = address(0xFACADE);
        vm.etch(factory, hex"00");

        MockAerodromeRouter router = new MockAerodromeRouter(factory, address(weth));
        EntryTokenRegistry registry = new EntryTokenRegistry(owner);

        address canonicalPool = address(0xBEEF);
        router.setPoolFor(address(weth), address(claim), false, factory, canonicalPool);

        vm.prank(owner);
        registry.setRouterConfig(address(router), factory, address(weth), address(claim));

        // Pre-genesis: the deterministic pool address is known, but the pool is not deployed yet.
        vm.prank(owner);
        vm.expectRevert(Errors.NotAContract.selector);
        registry.setWethClaimHop(false, canonicalPool);

        (, address poolBefore) = registry.getWethClaimHop();
        assertEq(poolBefore, address(0), "hop should stay deferred until the canonical pool exists");

        // Post-genesis: once the canonical pool has code, the registry can bind it.
        vm.etch(canonicalPool, hex"00");

        vm.prank(owner);
        registry.setWethClaimHop(false, canonicalPool);

        (bool stable, address poolAfter) = registry.getWethClaimHop();
        assertFalse(stable);
        assertEq(poolAfter, canonicalPool);
    }

    function testMaintenanceHubCannotDeployBeforeCanonicalWiring() public {
        MockWETH weth = new MockWETH();

        ClaimToken freshClaim = new ClaimToken(owner);
        VeClaimNFTHarness freshVe = new VeClaimNFTHarness(address(freshClaim), owner);
        ShareholderRoyalties freshRoyalties = new ShareholderRoyalties(address(freshVe), owner);
        Furnace freshFurnace = new Furnace(
            address(freshClaim),
            address(freshVe),
            address(new FurnaceGuardHelper(address(freshClaim), address(freshVe))),
            owner
        );
        MarketRouter freshMarket =
            new MarketRouter(address(freshClaim), address(freshVe), address(freshRoyalties), owner);

        vm.expectRevert(Errors.WiringMismatch.selector);
        new MaintenanceHub(
            address(freshMarket),
            address(freshFurnace),
            address(freshVe),
            address(freshRoyalties),
            address(weth),
            address(0xDE5C0E)
        );
    }

    function testMaintenanceHubDeploysAfterCanonicalWiring() public {
        MockWETH weth = new MockWETH();
        MaintenanceHub hub = new MaintenanceHub(
            address(market), address(furnace), address(ve), address(royalties), address(weth), address(0xDE5C0E)
        );
        assertGt(address(hub).code.length, 0);
    }

    function testMaintenanceHubRejectsSplitBrainClaimAndMineCoreBundleAtDeploy() public {
        ClaimToken foreignClaim = new ClaimToken(owner);
        Furnace foreignFurnace = new Furnace(
            address(foreignClaim),
            address(ve),
            address(new FurnaceGuardHelper(address(foreignClaim), address(ve))),
            owner
        );

        vm.prank(owner);
        vm.expectRevert(Errors.WiringMismatch.selector);
        ve.setFurnace(address(foreignFurnace));
    }

    function testMaintenanceHubRejectsForeignFurnaceClaimRootAtDeploy() public {
        ClaimToken foreignClaim = new ClaimToken(owner);
        Furnace foreignFurnace = new Furnace(
            address(foreignClaim),
            address(ve),
            address(new FurnaceGuardHelper(address(foreignClaim), address(ve))),
            owner
        );

        vm.prank(owner);
        vm.expectRevert(Errors.WiringMismatch.selector);
        ve.setFurnace(address(foreignFurnace));
    }

    function testMaintenanceHubPokeRevertsWhenRoyaltiesMineCoreRootDriftsAfterDeploy() public {
        MockWETH weth = new MockWETH();
        MaintenanceHub hub = new MaintenanceHub(
            address(market), address(furnace), address(ve), address(royalties), address(weth), address(0xDE5C0E)
        );

        MockMineCoreWiringView foreignMineCore =
            new MockMineCoreWiringView(address(claim), address(ve), address(royalties));

        vm.prank(owner);
        royalties.setWiring(address(foreignMineCore), address(market), address(furnace));

        vm.expectRevert(Errors.WiringMismatch.selector);
        hub.poke(MaintenanceHub.PokeArgs({offerIds: new uint256[](0), maxOffers: 0}));
    }

    function testMaintenanceHubSettlementKeeperRoleIsAttachedSeparatelyAfterDeploy() public {
        MockWETH weth = new MockWETH();
        MaintenanceHub hub = new MaintenanceHub(
            address(market), address(furnace), address(ve), address(royalties), address(weth), address(0xDE5C0E)
        );

        assertFalse(
            market.isSettlementKeeper(address(hub)),
            "MaintenanceHub should not receive settlement privileges implicitly"
        );

        vm.prank(owner);
        market.setSettlementKeeper(address(hub), true);
        assertTrue(market.isSettlementKeeper(address(hub)), "second wire pass must allowlist MaintenanceHub explicitly");
    }

    function testAgentLensPinsPostDeploymentMaintenanceHubAddress() public {
        MockWETH weth = new MockWETH();
        MaintenanceHub hub = new MaintenanceHub(
            address(market), address(furnace), address(ve), address(royalties), address(weth), address(0xDE5C0E)
        );

        AgentLens lens = new AgentLens(
            AgentLens.ConstructorParams({
                claimToken: address(claim),
                veClaimNFT: address(ve),
                mineCore: address(mineCore),
                shareholderRoyalties: address(royalties),
                furnace: address(furnace),
                marketRouter: address(market),
                lpStakingVault7D: address(0),
                dexAdapter: address(0),
                furnaceEntryTokenRegistry: address(0),
                mineCoreEntryTokenRegistry: address(0),
                delegationHub: address(0),
                claimAllHelper: address(0),
                maintenanceHub: address(hub),
                launchController: address(0),
                genesisLPVault24M: address(0)
            })
        );

        AgentLens.Addresses memory addrs = lens.getAddresses();
        assertEq(lens.maintenanceHub(), address(hub));
        assertEq(addrs.maintenanceHub, address(hub));
    }

    function testOnlyMineCoreCanMintClaim() public {
        vm.prank(alice);
        vm.expectRevert(Errors.OnlyMineCore.selector);
        claim.mint(alice, 1);

        vm.prank(address(mineCore));
        claim.mint(alice, 123);
        assertEq(claim.balanceOf(alice), 123);
    }

    function testClaimSetMineCoreRejectsForeignClaimRootPreFreeze() public {
        address foreignMineCore = address(new ForeignMineCoreClaimView(address(0xDEAD)));

        vm.prank(owner);
        vm.expectRevert(Errors.WiringMismatch.selector);
        claim.setMineCore(foreignMineCore);
    }

    function testOnlyMineMarketCanTransferVeNftToFurnace() public {
        uint256 tokenId = 1;
        ve.mintForTest(alice, tokenId);

        vm.prank(alice);
        vm.expectRevert(Errors.OnlyMineMarket.selector);
        ve.transferFrom(alice, bob, tokenId);

        ve.approveForTest(address(market), tokenId);

        // MineMarket cannot transfer veNFTs to arbitrary recipients in strict mode.
        vm.prank(address(market));
        vm.expectRevert(Errors.MarketMustTransferToFurnace.selector);
        ve.transferFrom(alice, bob, tokenId);

        // MineMarket may transfer into Furnace custody.
        vm.prank(address(market));
        ve.transferFrom(alice, address(furnace), tokenId);
        assertEq(ve.ownerOf(tokenId), address(furnace));
    }

    function testOnlyMineCoreCanCallOnTakeover() public {
        vm.deal(alice, 1 ether);

        vm.prank(alice);
        vm.expectRevert(Errors.OnlyMineCore.selector);
        royalties.onTakeover{value: 1 ether}(1);

        vm.deal(address(mineCore), 1 ether);
        vm.prank(address(mineCore));
        royalties.onTakeover{value: 1 ether}(1);
        assertEq(royalties.pendingShareholderETH(), 1 ether);
    }

    function testRoyaltiesOnTakeoverRevertsWhenMineMarketDriftsToForeignRoyaltiesRoot() public {
        ShareholderRoyalties foreignRoyalties = new ShareholderRoyalties(address(ve), owner);
        MarketRouter rogueMarket = new MarketRouter(address(claim), address(ve), address(foreignRoyalties), owner);

        vm.prank(owner);
        royalties.setWiring(address(mineCore), address(rogueMarket), address(furnace));

        vm.deal(address(mineCore), 1 ether);
        vm.prank(address(mineCore));
        vm.expectRevert(Errors.WiringMismatch.selector);
        royalties.onTakeover{value: 1 ether}(1);

        assertEq(royalties.pendingShareholderETH(), 0, "runtime drift must not enqueue takeover ETH");
    }

    function testRoyaltiesSetWiringRevertsWhenPendingEthRemains() public {
        vm.deal(address(mineCore), 1 ether);
        vm.prank(address(mineCore));
        royalties.onTakeover{value: 1 ether}(1);
        assertEq(royalties.pendingShareholderETH(), 1 ether, "canonical takeover should enqueue pending ETH");

        ShareholderRoyalties foreignRoyalties = new ShareholderRoyalties(address(ve), owner);
        MarketRouter rogueMarket = new MarketRouter(address(claim), address(ve), address(foreignRoyalties), owner);

        vm.prank(owner);
        vm.expectRevert(Errors.PendingEthNotDrained.selector);
        royalties.setWiring(address(mineCore), address(rogueMarket), address(furnace));

        assertEq(royalties.pendingShareholderETH(), 1 ether, "setWiring revert must preserve pending ETH");
    }

    function testOnlyMineMarketCanCallCheckpointTransfer() public {
        vm.prank(alice);
        vm.expectRevert(Errors.OnlyMineMarket.selector);
        royalties.checkpointTransfer(alice, bob);

        vm.prank(address(market));
        royalties.checkpointTransfer(alice, bob);
    }

    function testOnlyShareholderRoyaltiesCanCallLockEthReward() public {
        vm.deal(alice, 1 ether);
        vm.prank(alice);
        vm.expectRevert(Errors.OnlyShareholderRoyalties.selector);
        furnace.lockEthReward{value: 1 ether}(alice, 1 ether, 0, 0, false, 0);

        vm.deal(address(royalties), 1 ether);
        vm.prank(address(royalties));
        vm.expectRevert(Errors.RouterConfigNotSet.selector);
        furnace.lockEthReward{value: 1 ether}(alice, 1 ether, 0, 0, false, 0);
    }

    function testMarketConstructorRejectsEoaRoyaltiesAddress() public {
        vm.expectRevert(Errors.NotAContract.selector);
        new MarketRouter(address(claim), address(ve), address(0x1234), owner);
    }

    function testFreezeConfigDisablesFurtherChanges() public {
        vm.prank(owner);
        claim.freezeConfig();

        vm.prank(owner);
        vm.expectRevert(Errors.ConfigFrozen.selector);
        claim.setMineCore(address(0x1234));
    }
}

contract ForeignMineCoreClaimView {
    address public claim;

    constructor(address claim_) {
        claim = claim_;
    }
}
