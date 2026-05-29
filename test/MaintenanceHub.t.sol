// SPDX-License-Identifier: MIT
pragma solidity ^0.8.34;

import {Test} from "forge-std/Test.sol";

import {MaintenanceHub} from "src/MaintenanceHub.sol";
import {Constants} from "src/lib/Constants.sol";
import {Errors} from "src/lib/Errors.sol";
import {IMarketRouter} from "src/interfaces/IMarketRouter.sol";

import {MockWETH} from "./mocks/MockWETH.sol";

interface IRoyaltiesCallsView_MaintenanceHub {
    function calls() external view returns (uint256);
}

interface IVeCallCounters_MaintenanceHub {
    function globalCalls() external view returns (uint256);
    function totalCalls() external view returns (uint256);
}

contract MockMarketRouter_MaintenanceHub {
    uint256 public successCalls;
    mapping(uint256 => bool) public shouldRevert;
    address public ve;
    address public royalties;
    address public claim;
    bool public requireFlushBeforeMarket;

    function setWiring(address _ve, address _royalties, address _claim) external {
        ve = _ve;
        royalties = _royalties;
        claim = _claim;
    }

    function setRevert(uint256 offerId, bool v) external {
        shouldRevert[offerId] = v;
    }

    function setRequireFlushBeforeMarket(bool v) external {
        requireFlushBeforeMarket = v;
    }

    function executeAutoFurnace(uint256 offerId, uint256) external {
        if (requireFlushBeforeMarket) {
            require(
                royalties != address(0) && IRoyaltiesCallsView_MaintenanceHub(royalties).calls() > 0,
                "MockMarketRouter: flush-first"
            );
        }
        if (shouldRevert[offerId]) revert("MockMarketRouter: revert");
        successCalls++;
    }
}

contract MockVe_MaintenanceHub {
    bool public revertGlobal;
    bool public revertTotal;
    uint256 public globalCalls;
    uint256 public totalCalls;
    address public furnace;
    address public mineMarket;
    address public claimToken;

    function setWiring(address _furnace, address _mineMarket, address _claimToken) external {
        furnace = _furnace;
        mineMarket = _mineMarket;
        claimToken = _claimToken;
    }

    function setReverts(bool g, bool t) external {
        revertGlobal = g;
        revertTotal = t;
    }

    function checkpointGlobalState() external {
        globalCalls++;
        if (revertGlobal) revert("MockVe: global");
    }

    function checkpointTotalVe() external {
        totalCalls++;
        if (revertTotal) revert("MockVe: total");
    }
}

contract MockRoyalties_MaintenanceHub {
    bool public shouldRevert;
    bool public requireCheckpointsBeforeFlush;
    uint256 public calls;
    address public furnace;
    address public mineMarket;
    address public ve;
    address public mineCore;

    function setWiring(address _furnace, address _mineMarket, address _ve, address _mineCore) external {
        furnace = _furnace;
        mineMarket = _mineMarket;
        ve = _ve;
        mineCore = _mineCore;
    }

    function setRevert(bool v) external {
        shouldRevert = v;
    }

    function setRequireCheckpointsBeforeFlush(bool v) external {
        requireCheckpointsBeforeFlush = v;
    }

    function flushPendingShareholderETH() external {
        if (requireCheckpointsBeforeFlush) {
            require(
                ve != address(0) && IVeCallCounters_MaintenanceHub(ve).globalCalls() > 0,
                "MockRoyalties: checkpoint-first"
            );
        }
        calls++;
        if (shouldRevert) revert("MockRoyalties: revert");
    }
}

contract MockStakingVault_MaintenanceHub {
    MockWETH public immutable weth;
    bool public shouldRevert;
    uint256 public bounty;
    uint256 public calls;

    constructor(MockWETH _weth) {
        weth = _weth;
    }

    function configure(uint256 _bounty, bool _revert) external {
        bounty = _bounty;
        shouldRevert = _revert;
    }

    function harvestFeesToRewards(uint256, uint256) external {
        calls++;
        if (shouldRevert) revert("MockStakingVault: revert");
        if (bounty > 0) {
            require(weth.transfer(msg.sender, bounty), "Mock: transfer failed");
        }
    }
}

contract MockFurnace_MaintenanceHub {
    bool public shouldRevert;
    uint256 public calls;
    address public ve;
    address public shareholderRoyalties;
    address public mineMarket;
    address public mineCore;
    address public claim;
    MockWETH public tickBountyWeth;
    uint256 public tickBountyAmount;

    function setWiring(
        address _ve,
        address _shareholderRoyalties,
        address _mineMarket,
        address _mineCore,
        address _claim
    ) external {
        ve = _ve;
        shareholderRoyalties = _shareholderRoyalties;
        mineMarket = _mineMarket;
        mineCore = _mineCore;
        claim = _claim;
    }

    function setRevert(bool v) external {
        shouldRevert = v;
    }

    function setTickBounty(MockWETH _weth, uint256 _amount) external {
        tickBountyWeth = _weth;
        tickBountyAmount = _amount;
    }

    function tick() external returns (uint256) {
        calls++;
        if (shouldRevert) revert("MockFurnace: revert");
        if (tickBountyAmount != 0) {
            require(address(tickBountyWeth) != address(0), "MockFurnace: no bounty token");
            require(tickBountyWeth.transfer(msg.sender, tickBountyAmount), "MockFurnace: bounty transfer failed");
        }
        return 0;
    }
}

contract MockClaimToken_MaintenanceHub {
    address public mineCore;

    function setMineCore(address _mineCore) external {
        mineCore = _mineCore;
    }
}

contract MockMineCore_MaintenanceHub {
    address public furnace;
    address public royalties;
    address public ve;
    address public claim;

    function setWiring(address _furnace, address _royalties, address _ve, address _claim) external {
        furnace = _furnace;
        royalties = _royalties;
        ve = _ve;
        claim = _claim;
    }
}

/// @dev Mock that burns ~1.4M gas per executeAutoFurnace call, used to test the loop gas guard.
contract GasBurnerMarket_MaintenanceHub {
    uint256 public successCalls;
    address public ve;
    address public royalties;
    address public claim;

    function setWiring(address _ve, address _royalties, address _claim) external {
        ve = _ve;
        royalties = _royalties;
        claim = _claim;
    }

    function executeAutoFurnace(uint256, uint256) external {
        uint256 target = gasleft() > 1_400_000 ? gasleft() - 1_400_000 : 0;
        while (gasleft() > target) {}
        successCalls++;
    }
}

contract MaintenanceHubTest is Test {
    // Mirror the contract event for expectEmit
    event Poked(
        address caller,
        bool checkpointOk,
        bool flushOk,
        uint256 offersAttempted,
        uint256 offersSucceeded,
        bool furnaceTickSucceeded,
        uint256 bountyWethForwarded
    );

    function _wireCanonicalMaintenanceBundle(
        MockMarketRouter_MaintenanceHub market,
        MockFurnace_MaintenanceHub furnace,
        MockVe_MaintenanceHub ve,
        MockRoyalties_MaintenanceHub royalties
    ) internal {
        MockClaimToken_MaintenanceHub claim = new MockClaimToken_MaintenanceHub();
        MockMineCore_MaintenanceHub core = new MockMineCore_MaintenanceHub();

        claim.setMineCore(address(core));
        core.setWiring(address(furnace), address(royalties), address(ve), address(claim));
        market.setWiring(address(ve), address(royalties), address(claim));
        furnace.setWiring(address(ve), address(royalties), address(market), address(core), address(claim));
        ve.setWiring(address(furnace), address(market), address(claim));
        royalties.setWiring(address(furnace), address(market), address(ve), address(core));
    }

    function testConstructorZeroAddressReverts() public {
        MockWETH weth = new MockWETH();

        vm.expectRevert(Errors.ZeroAddress.selector);
        new MaintenanceHub(address(0), address(1), address(1), address(1), address(weth), address(0xDE5C0E));
    }

    function testConstructorNonContractReverts() public {
        MockWETH weth = new MockWETH();
        MockMarketRouter_MaintenanceHub market = new MockMarketRouter_MaintenanceHub();
        MockFurnace_MaintenanceHub furnace = new MockFurnace_MaintenanceHub();
        MockVe_MaintenanceHub ve = new MockVe_MaintenanceHub();
        MockRoyalties_MaintenanceHub royalties = new MockRoyalties_MaintenanceHub();
        _wireCanonicalMaintenanceBundle(market, furnace, ve, royalties);

        vm.expectRevert(Errors.NotAContract.selector);
        new MaintenanceHub(
            address(0xBEEF), address(furnace), address(ve), address(royalties), address(weth), address(0xDE5C0E)
        );

        vm.expectRevert(Errors.NotAContract.selector);
        new MaintenanceHub(
            address(market), address(furnace), address(ve), address(royalties), address(0xCAFE), address(0xDE5C0E)
        );
    }

    function testPoke_ForwardsBountyDelta_AndCountsOffers() public {
        MockWETH weth = new MockWETH();
        MockMarketRouter_MaintenanceHub market = new MockMarketRouter_MaintenanceHub();
        MockFurnace_MaintenanceHub furnace = new MockFurnace_MaintenanceHub();
        MockVe_MaintenanceHub ve = new MockVe_MaintenanceHub();
        MockRoyalties_MaintenanceHub royalties = new MockRoyalties_MaintenanceHub();
        MockStakingVault_MaintenanceHub staking = new MockStakingVault_MaintenanceHub(weth);

        _wireCanonicalMaintenanceBundle(market, furnace, ve, royalties);
        MaintenanceHub hub = new MaintenanceHub(
            address(market), address(furnace), address(ve), address(royalties), address(weth), address(0xDE5C0E)
        );

        // One offer fails, others succeed.
        market.setRevert(2, true);

        uint256 bountyStaking = 7 ether;

        weth.mint(address(staking), bountyStaking);
        staking.configure(bountyStaking, false);

        uint256[] memory ids = new uint256[](3);
        ids[0] = 1;
        ids[1] = 2;
        ids[2] = 3;

        MaintenanceHub.PokeArgs memory args = MaintenanceHub.PokeArgs({offerIds: ids, maxOffers: 10});

        address keeper = address(0xBEEF);

        // Track attempted calls explicitly.
        uint256 dl = block.timestamp + 300;
        vm.expectCall(address(market), abi.encodeCall(IMarketRouter.executeAutoFurnace, (uint256(1), dl)));
        vm.expectCall(address(market), abi.encodeCall(IMarketRouter.executeAutoFurnace, (uint256(2), dl)));
        vm.expectCall(address(market), abi.encodeCall(IMarketRouter.executeAutoFurnace, (uint256(3), dl)));

        vm.expectEmit(false, false, false, true);
        emit Poked(keeper, true, true, 3, 2, true, 0);

        vm.prank(keeper);
        hub.poke(args);

        // NOTE: `successCalls` only counts non-reverting calls.
        // Attempted calls are asserted via `vm.expectCall(...)` and the Poked event above.
        assertEq(market.successCalls(), 2);
        assertEq(furnace.calls(), 1);
        assertEq(ve.globalCalls(), 1);
        assertEq(ve.totalCalls(), 0);
        assertEq(royalties.calls(), 1);
        assertEq(staking.calls(), 0);
        assertEq(weth.balanceOf(keeper), 0);
        assertEq(weth.balanceOf(address(hub)), 0);
    }

    function testPoke_CheckpointsAndFlushBeforeExecutingMarketSweep() public {
        MockWETH weth = new MockWETH();
        MockMarketRouter_MaintenanceHub market = new MockMarketRouter_MaintenanceHub();
        MockFurnace_MaintenanceHub furnace = new MockFurnace_MaintenanceHub();
        MockVe_MaintenanceHub ve = new MockVe_MaintenanceHub();
        MockRoyalties_MaintenanceHub royalties = new MockRoyalties_MaintenanceHub();

        _wireCanonicalMaintenanceBundle(market, furnace, ve, royalties);
        MaintenanceHub hub = new MaintenanceHub(
            address(market), address(furnace), address(ve), address(royalties), address(weth), address(0xDE5C0E)
        );

        royalties.setRequireCheckpointsBeforeFlush(true);
        market.setRequireFlushBeforeMarket(true);

        uint256[] memory ids = new uint256[](1);
        ids[0] = 1;

        MaintenanceHub.PokeArgs memory args = MaintenanceHub.PokeArgs({offerIds: ids, maxOffers: 1});

        address keeper = address(0xA11CE);

        vm.expectEmit(false, false, false, true);
        emit Poked(keeper, true, true, 1, 1, true, 0);

        vm.prank(keeper);
        hub.poke(args);

        assertEq(ve.globalCalls(), 1);
        assertEq(ve.totalCalls(), 0);
        assertEq(royalties.calls(), 1);
        assertEq(market.successCalls(), 1);
        assertEq(furnace.calls(), 1);
    }

    function testPoke_ClampsOffersToCap() public {
        MockWETH weth = new MockWETH();
        MockMarketRouter_MaintenanceHub market = new MockMarketRouter_MaintenanceHub();
        MockFurnace_MaintenanceHub furnace = new MockFurnace_MaintenanceHub();
        MockVe_MaintenanceHub ve = new MockVe_MaintenanceHub();
        MockRoyalties_MaintenanceHub royalties = new MockRoyalties_MaintenanceHub();

        _wireCanonicalMaintenanceBundle(market, furnace, ve, royalties);
        MaintenanceHub hub = new MaintenanceHub(
            address(market), address(furnace), address(ve), address(royalties), address(weth), address(0xDE5C0E)
        );

        uint256 cap = Constants.MAX_MAINTENANCE_OFFERS_PER_CALL;
        uint256[] memory ids = new uint256[](cap + 10);
        for (uint256 i = 0; i < ids.length; ++i) {
            ids[i] = i + 1;
        }

        MaintenanceHub.PokeArgs memory args = MaintenanceHub.PokeArgs({offerIds: ids, maxOffers: type(uint256).max});

        address keeper = address(0xCAFE);

        vm.expectEmit(false, false, false, true);
        emit Poked(keeper, true, true, cap, cap, true, 0);

        vm.prank(keeper);
        hub.poke(args);

        assertEq(market.successCalls(), cap);
    }

    function testPoke_BestEffortReverts_DoesNotHarvestStaking() public {
        MockWETH weth = new MockWETH();
        MockMarketRouter_MaintenanceHub market = new MockMarketRouter_MaintenanceHub();
        MockFurnace_MaintenanceHub furnace = new MockFurnace_MaintenanceHub();
        MockVe_MaintenanceHub ve = new MockVe_MaintenanceHub();
        MockRoyalties_MaintenanceHub royalties = new MockRoyalties_MaintenanceHub();
        MockStakingVault_MaintenanceHub staking = new MockStakingVault_MaintenanceHub(weth);

        _wireCanonicalMaintenanceBundle(market, furnace, ve, royalties);
        MaintenanceHub hub = new MaintenanceHub(
            address(market), address(furnace), address(ve), address(royalties), address(weth), address(0xDE5C0E)
        );

        // Make all attempted sub-actions fail.
        uint256[] memory ids = new uint256[](3);
        ids[0] = 1;
        ids[1] = 2;
        ids[2] = 3;
        market.setRevert(1, true);
        market.setRevert(2, true);
        market.setRevert(3, true);

        ve.setReverts(true, true);
        royalties.setRevert(true);
        furnace.setRevert(true);

        uint256 bountyStaking = 1 ether;
        weth.mint(address(staking), bountyStaking);
        staking.configure(bountyStaking, false);

        MaintenanceHub.PokeArgs memory args = MaintenanceHub.PokeArgs({offerIds: ids, maxOffers: 10});

        address keeper = address(0xD00D);

        // Ensure all offer calls are attempted (even if they revert and are caught).
        uint256 dl = block.timestamp + 300;
        vm.expectCall(address(market), abi.encodeCall(IMarketRouter.executeAutoFurnace, (uint256(1), dl)));
        vm.expectCall(address(market), abi.encodeCall(IMarketRouter.executeAutoFurnace, (uint256(2), dl)));
        vm.expectCall(address(market), abi.encodeCall(IMarketRouter.executeAutoFurnace, (uint256(3), dl)));

        vm.expectEmit(false, false, false, true);
        emit Poked(keeper, false, false, 3, 0, false, 0);

        vm.prank(keeper);
        hub.poke(args);

        assertEq(staking.calls(), 0);
        assertEq(weth.balanceOf(keeper), 0);
    }

    function testConstructorRevertsWhenMarketVeRootMismatches() public {
        MockWETH weth = new MockWETH();
        MockMarketRouter_MaintenanceHub market = new MockMarketRouter_MaintenanceHub();
        MockFurnace_MaintenanceHub furnace = new MockFurnace_MaintenanceHub();
        MockVe_MaintenanceHub ve = new MockVe_MaintenanceHub();
        MockVe_MaintenanceHub foreignVe = new MockVe_MaintenanceHub();
        MockRoyalties_MaintenanceHub royalties = new MockRoyalties_MaintenanceHub();

        _wireCanonicalMaintenanceBundle(market, furnace, ve, royalties);
        market.setWiring(address(foreignVe), address(royalties), market.claim());

        vm.expectRevert(Errors.WiringMismatch.selector);
        new MaintenanceHub(
            address(market), address(furnace), address(ve), address(royalties), address(weth), address(0xDE5C0E)
        );
    }

    function testConstructorRevertsWhenFurnaceRoyaltiesRootMismatches() public {
        MockWETH weth = new MockWETH();
        MockMarketRouter_MaintenanceHub market = new MockMarketRouter_MaintenanceHub();
        MockFurnace_MaintenanceHub furnace = new MockFurnace_MaintenanceHub();
        MockVe_MaintenanceHub ve = new MockVe_MaintenanceHub();
        MockRoyalties_MaintenanceHub royalties = new MockRoyalties_MaintenanceHub();
        MockRoyalties_MaintenanceHub foreignRoyalties = new MockRoyalties_MaintenanceHub();

        _wireCanonicalMaintenanceBundle(market, furnace, ve, royalties);
        furnace.setWiring(
            address(ve), address(foreignRoyalties), furnace.mineMarket(), furnace.mineCore(), furnace.claim()
        );

        vm.expectRevert(Errors.WiringMismatch.selector);
        new MaintenanceHub(
            address(market), address(furnace), address(ve), address(royalties), address(weth), address(0xDE5C0E)
        );
    }

    function testConstructorRevertsWhenFurnaceClaimRootMismatchesCanonicalClaim() public {
        MockWETH weth = new MockWETH();
        MockMarketRouter_MaintenanceHub market = new MockMarketRouter_MaintenanceHub();
        MockFurnace_MaintenanceHub furnace = new MockFurnace_MaintenanceHub();
        MockVe_MaintenanceHub ve = new MockVe_MaintenanceHub();
        MockRoyalties_MaintenanceHub royalties = new MockRoyalties_MaintenanceHub();
        MockClaimToken_MaintenanceHub foreignClaim = new MockClaimToken_MaintenanceHub();

        _wireCanonicalMaintenanceBundle(market, furnace, ve, royalties);
        furnace.setWiring(address(ve), address(royalties), address(market), furnace.mineCore(), address(foreignClaim));

        vm.expectRevert(Errors.WiringMismatch.selector);
        new MaintenanceHub(
            address(market), address(furnace), address(ve), address(royalties), address(weth), address(0xDE5C0E)
        );
    }

    function testConstructorRevertsWhenRoyaltiesMarketBackpointerMismatches() public {
        MockWETH weth = new MockWETH();
        MockMarketRouter_MaintenanceHub market = new MockMarketRouter_MaintenanceHub();
        MockMarketRouter_MaintenanceHub foreignMarket = new MockMarketRouter_MaintenanceHub();
        MockFurnace_MaintenanceHub furnace = new MockFurnace_MaintenanceHub();
        MockVe_MaintenanceHub ve = new MockVe_MaintenanceHub();
        MockRoyalties_MaintenanceHub royalties = new MockRoyalties_MaintenanceHub();

        _wireCanonicalMaintenanceBundle(market, furnace, ve, royalties);
        royalties.setWiring(address(furnace), address(foreignMarket), address(ve), royalties.mineCore());

        vm.expectRevert(Errors.WiringMismatch.selector);
        new MaintenanceHub(
            address(market), address(furnace), address(ve), address(royalties), address(weth), address(0xDE5C0E)
        );
    }

    function testConstructorRevertsWhenMarketClaimRootMismatchesVeClaimRoot() public {
        MockWETH weth = new MockWETH();
        MockMarketRouter_MaintenanceHub market = new MockMarketRouter_MaintenanceHub();
        MockFurnace_MaintenanceHub furnace = new MockFurnace_MaintenanceHub();
        MockVe_MaintenanceHub ve = new MockVe_MaintenanceHub();
        MockRoyalties_MaintenanceHub royalties = new MockRoyalties_MaintenanceHub();
        MockClaimToken_MaintenanceHub foreignClaim = new MockClaimToken_MaintenanceHub();

        _wireCanonicalMaintenanceBundle(market, furnace, ve, royalties);
        market.setWiring(address(ve), address(royalties), address(foreignClaim));

        vm.expectRevert(Errors.WiringMismatch.selector);
        new MaintenanceHub(
            address(market), address(furnace), address(ve), address(royalties), address(weth), address(0xDE5C0E)
        );
    }

    function testConstructorRevertsWhenRoyaltiesMineCoreRootMismatchesCanonicalCore() public {
        MockWETH weth = new MockWETH();
        MockMarketRouter_MaintenanceHub market = new MockMarketRouter_MaintenanceHub();
        MockFurnace_MaintenanceHub furnace = new MockFurnace_MaintenanceHub();
        MockVe_MaintenanceHub ve = new MockVe_MaintenanceHub();
        MockRoyalties_MaintenanceHub royalties = new MockRoyalties_MaintenanceHub();
        MockMineCore_MaintenanceHub foreignCore = new MockMineCore_MaintenanceHub();

        _wireCanonicalMaintenanceBundle(market, furnace, ve, royalties);
        royalties.setWiring(address(furnace), address(market), address(ve), address(foreignCore));

        vm.expectRevert(Errors.WiringMismatch.selector);
        new MaintenanceHub(
            address(market), address(furnace), address(ve), address(royalties), address(weth), address(0xDE5C0E)
        );
    }

    function testFuzz_constructorRejectsAnyMarketVeMismatch(address bogusVe) public {
        MockWETH weth = new MockWETH();
        MockMarketRouter_MaintenanceHub market = new MockMarketRouter_MaintenanceHub();
        MockFurnace_MaintenanceHub furnace = new MockFurnace_MaintenanceHub();
        MockVe_MaintenanceHub ve = new MockVe_MaintenanceHub();
        MockRoyalties_MaintenanceHub royalties = new MockRoyalties_MaintenanceHub();

        vm.assume(bogusVe != address(0));
        vm.assume(bogusVe != address(ve));
        vm.assume(bogusVe != address(market));
        vm.assume(bogusVe != address(furnace));
        vm.assume(bogusVe != address(royalties));
        vm.assume(bogusVe != address(weth));
        vm.assume(uint160(bogusVe) > 1024); // avoid precompile addresses
        vm.etch(bogusVe, hex"00");

        _wireCanonicalMaintenanceBundle(market, furnace, ve, royalties);
        market.setWiring(bogusVe, address(royalties), market.claim());

        vm.expectRevert(Errors.WiringMismatch.selector);
        new MaintenanceHub(
            address(market), address(furnace), address(ve), address(royalties), address(weth), address(0xDE5C0E)
        );
    }

    function testPokeRevertsWhenMarketClaimRootDriftsFromCanonicalVeClaimRoot() public {
        MockWETH weth = new MockWETH();
        MockMarketRouter_MaintenanceHub market = new MockMarketRouter_MaintenanceHub();
        MockFurnace_MaintenanceHub furnace = new MockFurnace_MaintenanceHub();
        MockVe_MaintenanceHub ve = new MockVe_MaintenanceHub();
        MockRoyalties_MaintenanceHub royalties = new MockRoyalties_MaintenanceHub();
        MockClaimToken_MaintenanceHub foreignClaim = new MockClaimToken_MaintenanceHub();

        _wireCanonicalMaintenanceBundle(market, furnace, ve, royalties);
        MaintenanceHub hub = new MaintenanceHub(
            address(market), address(furnace), address(ve), address(royalties), address(weth), address(0xDE5C0E)
        );

        market.setWiring(address(ve), address(royalties), address(foreignClaim));

        vm.expectRevert(Errors.WiringMismatch.selector);
        hub.poke(MaintenanceHub.PokeArgs({offerIds: new uint256[](0), maxOffers: 0}));
    }

    function testPokeRevertsWhenFurnaceClaimRootDriftsFromCanonicalClaim() public {
        MockWETH weth = new MockWETH();
        MockMarketRouter_MaintenanceHub market = new MockMarketRouter_MaintenanceHub();
        MockFurnace_MaintenanceHub furnace = new MockFurnace_MaintenanceHub();
        MockVe_MaintenanceHub ve = new MockVe_MaintenanceHub();
        MockRoyalties_MaintenanceHub royalties = new MockRoyalties_MaintenanceHub();
        MockClaimToken_MaintenanceHub foreignClaim = new MockClaimToken_MaintenanceHub();

        _wireCanonicalMaintenanceBundle(market, furnace, ve, royalties);
        MaintenanceHub hub = new MaintenanceHub(
            address(market), address(furnace), address(ve), address(royalties), address(weth), address(0xDE5C0E)
        );

        furnace.setWiring(address(ve), address(royalties), address(market), furnace.mineCore(), address(foreignClaim));

        vm.expectRevert(Errors.WiringMismatch.selector);
        hub.poke(MaintenanceHub.PokeArgs({offerIds: new uint256[](0), maxOffers: 0}));
    }

    function testPokeRevertsWhenRoyaltiesMineCoreRootDriftsFromCanonicalCore() public {
        MockWETH weth = new MockWETH();
        MockMarketRouter_MaintenanceHub market = new MockMarketRouter_MaintenanceHub();
        MockFurnace_MaintenanceHub furnace = new MockFurnace_MaintenanceHub();
        MockVe_MaintenanceHub ve = new MockVe_MaintenanceHub();
        MockRoyalties_MaintenanceHub royalties = new MockRoyalties_MaintenanceHub();
        MockMineCore_MaintenanceHub foreignCore = new MockMineCore_MaintenanceHub();

        _wireCanonicalMaintenanceBundle(market, furnace, ve, royalties);
        MaintenanceHub hub = new MaintenanceHub(
            address(market), address(furnace), address(ve), address(royalties), address(weth), address(0xDE5C0E)
        );

        royalties.setWiring(address(furnace), address(market), address(ve), address(foreignCore));

        vm.expectRevert(Errors.WiringMismatch.selector);
        hub.poke(MaintenanceHub.PokeArgs({offerIds: new uint256[](0), maxOffers: 0}));
    }

    function testPoke_DoesNotForwardPreexistingHubWeth() public {
        MockWETH weth = new MockWETH();
        MockMarketRouter_MaintenanceHub market = new MockMarketRouter_MaintenanceHub();
        MockFurnace_MaintenanceHub furnace = new MockFurnace_MaintenanceHub();
        MockVe_MaintenanceHub ve = new MockVe_MaintenanceHub();
        MockRoyalties_MaintenanceHub royalties = new MockRoyalties_MaintenanceHub();
        MockStakingVault_MaintenanceHub staking = new MockStakingVault_MaintenanceHub(weth);

        _wireCanonicalMaintenanceBundle(market, furnace, ve, royalties);
        MaintenanceHub hub = new MaintenanceHub(
            address(market), address(furnace), address(ve), address(royalties), address(weth), address(0xDE5C0E)
        );

        // Seed hub with WETH that arrived outside poke (e.g. accidental transfer). `poke` must
        // forward only newly realized WETH so the next arbitrary caller cannot drain this balance.
        uint256 preexisting = 10 ether;
        weth.mint(address(hub), preexisting);

        uint256 bountyStaking = 3 ether;
        weth.mint(address(staking), bountyStaking);
        staking.configure(bountyStaking, false);

        MaintenanceHub.PokeArgs memory args = MaintenanceHub.PokeArgs({offerIds: new uint256[](0), maxOffers: 0});

        address keeper = address(0xF00D);

        vm.expectEmit(false, false, false, true);
        emit Poked(keeper, true, true, 0, 0, true, 0);

        vm.prank(keeper);
        hub.poke(args);

        assertEq(weth.balanceOf(keeper), 0);
        assertEq(weth.balanceOf(address(hub)), preexisting);
    }

    function testPoke_ForwardsPositiveWethDeltaToCaller() public {
        MockWETH weth = new MockWETH();
        MockMarketRouter_MaintenanceHub market = new MockMarketRouter_MaintenanceHub();
        MockFurnace_MaintenanceHub furnace = new MockFurnace_MaintenanceHub();
        MockVe_MaintenanceHub ve = new MockVe_MaintenanceHub();
        MockRoyalties_MaintenanceHub royalties = new MockRoyalties_MaintenanceHub();

        _wireCanonicalMaintenanceBundle(market, furnace, ve, royalties);
        MaintenanceHub hub = new MaintenanceHub(
            address(market), address(furnace), address(ve), address(royalties), address(weth), address(0xDE5C0E)
        );

        uint256 bounty = 2 ether;
        weth.mint(address(furnace), bounty);
        furnace.setTickBounty(weth, bounty);

        MaintenanceHub.PokeArgs memory args = MaintenanceHub.PokeArgs({offerIds: new uint256[](0), maxOffers: 0});

        address keeper = address(0xABCD);

        vm.expectEmit(false, false, false, true);
        emit Poked(keeper, true, true, 0, 0, true, bounty);

        vm.prank(keeper);
        hub.poke(args);

        assertEq(furnace.calls(), 1);
        assertEq(weth.balanceOf(keeper), bounty);
        assertEq(weth.balanceOf(address(hub)), 0);
        assertEq(weth.balanceOf(address(furnace)), 0);
    }

    // ------------------------------------------------------------------
    // offerId=0 entries are silently skipped (not attempted)
    // ------------------------------------------------------------------

    function testPoke_SkipsZeroOfferIds() public {
        MockWETH weth = new MockWETH();
        MockMarketRouter_MaintenanceHub market = new MockMarketRouter_MaintenanceHub();
        MockFurnace_MaintenanceHub furnace = new MockFurnace_MaintenanceHub();
        MockVe_MaintenanceHub ve = new MockVe_MaintenanceHub();
        MockRoyalties_MaintenanceHub royalties = new MockRoyalties_MaintenanceHub();

        _wireCanonicalMaintenanceBundle(market, furnace, ve, royalties);
        MaintenanceHub hub = new MaintenanceHub(
            address(market), address(furnace), address(ve), address(royalties), address(weth), address(0xDE5C0E)
        );

        // Array with zero IDs interspersed: [1, 0, 3, 0, 5]
        uint256[] memory ids = new uint256[](5);
        ids[0] = 1;
        ids[1] = 0; // skipped
        ids[2] = 3;
        ids[3] = 0; // skipped
        ids[4] = 5;

        MaintenanceHub.PokeArgs memory args = MaintenanceHub.PokeArgs({offerIds: ids, maxOffers: 10});

        address keeper = address(0xBEEF);

        // Only 3 non-zero IDs attempted, all succeed.
        vm.expectEmit(false, false, false, true);
        emit Poked(keeper, true, true, 3, 3, true, 0);

        vm.prank(keeper);
        hub.poke(args);

        assertEq(market.successCalls(), 3, "only non-zero IDs should reach the market");
    }

    // ------------------------------------------------------------------
    // gas guard breaks loop when gasleft < gasCap + 600_000
    // ------------------------------------------------------------------

    function testPoke_GasGuardBreaksLoopEarly() public {
        MockWETH weth = new MockWETH();
        GasBurnerMarket_MaintenanceHub market = new GasBurnerMarket_MaintenanceHub();
        MockFurnace_MaintenanceHub furnace = new MockFurnace_MaintenanceHub();
        MockVe_MaintenanceHub ve = new MockVe_MaintenanceHub();
        MockRoyalties_MaintenanceHub royalties = new MockRoyalties_MaintenanceHub();

        // Wire canonical bundle inline (GasBurnerMarket has same getter interface).
        MockClaimToken_MaintenanceHub claimToken = new MockClaimToken_MaintenanceHub();
        MockMineCore_MaintenanceHub core = new MockMineCore_MaintenanceHub();
        claimToken.setMineCore(address(core));
        core.setWiring(address(furnace), address(royalties), address(ve), address(claimToken));
        market.setWiring(address(ve), address(royalties), address(claimToken));
        furnace.setWiring(address(ve), address(royalties), address(market), address(core), address(claimToken));
        ve.setWiring(address(furnace), address(market), address(claimToken));
        royalties.setWiring(address(furnace), address(market), address(ve), address(core));

        MaintenanceHub hub = new MaintenanceHub(
            address(market), address(furnace), address(ve), address(royalties), address(weth), address(0xDE5C0E)
        );

        // 10 offers — gas limit prevents processing all of them.
        uint256[] memory ids = new uint256[](10);
        for (uint256 i = 0; i < 10; ++i) {
            ids[i] = i + 1;
        }

        MaintenanceHub.PokeArgs memory args = MaintenanceHub.PokeArgs({offerIds: ids, maxOffers: 10});

        address keeper = address(0xBEEF);

        // Give enough gas for preamble + a few gas-burning iterations + post-loop work,
        // but NOT enough for all 10 iterations.  Each iteration burns ~1.4M gas;
        // the loop guard breaks when gasleft() < gasCap(1.5M) + 600_000 = 2.1M.
        vm.prank(keeper);
        hub.poke{gas: 5_500_000}(args);

        uint256 processed = market.successCalls();
        assertGt(processed, 0, "at least one offer should have been processed");
        assertLt(processed, 10, "gas guard should have broken the loop before all 10 offers");

        // Furnace tick should still have executed after the loop broke.
        assertEq(furnace.calls(), 1, "furnace tick must execute even when loop breaks early");
    }
}
