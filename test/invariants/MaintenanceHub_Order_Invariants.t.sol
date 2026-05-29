// SPDX-License-Identifier: MIT
pragma solidity ^0.8.34;

import {Test} from "forge-std/Test.sol";

import {MaintenanceHub} from "src/MaintenanceHub.sol";
import {Errors} from "src/lib/Errors.sol";

import {MockWETH} from "test/mocks/MockWETH.sol";

contract MaintenanceOrderRecorder {
    uint256 public seq;
    uint256 public globalSeq;
    uint256 public totalSeq;
    uint256 public flushSeq;
    uint256 public firstMarketSeq;

    function markGlobal() external {
        seq += 1;
        if (globalSeq == 0) globalSeq = seq;
    }

    function markTotal() external {
        seq += 1;
        if (totalSeq == 0) totalSeq = seq;
    }

    function markFlush() external {
        seq += 1;
        if (flushSeq == 0) flushSeq = seq;
    }

    function markMarket() external {
        seq += 1;
        if (firstMarketSeq == 0) firstMarketSeq = seq;
    }
}

contract MarketOrderSpy {
    MaintenanceOrderRecorder public immutable recorder;
    mapping(uint256 => bool) public shouldRevert;
    address public ve;
    address public royalties;
    address public claim;

    constructor(MaintenanceOrderRecorder recorder_) {
        recorder = recorder_;
    }

    function setWiring(address _ve, address _royalties, address _claim) external {
        ve = _ve;
        royalties = _royalties;
        claim = _claim;
    }

    function setRevert(uint256 offerId, bool value) external {
        shouldRevert[offerId] = value;
    }

    function executeAutoFurnace(uint256 offerId, uint256) external {
        recorder.markMarket();
        if (shouldRevert[offerId]) revert("MarketOrderSpy: revert");
    }
}

contract VeOrderSpy {
    MaintenanceOrderRecorder public immutable recorder;
    address public furnace;
    address public mineMarket;
    address public claimToken;

    constructor(MaintenanceOrderRecorder recorder_) {
        recorder = recorder_;
    }

    function setWiring(address _furnace, address _mineMarket, address _claimToken) external {
        furnace = _furnace;
        mineMarket = _mineMarket;
        claimToken = _claimToken;
    }

    function checkpointGlobalState() external {
        recorder.markGlobal();
    }

    function checkpointTotalVe() external {
        recorder.markTotal();
    }
}

contract RoyaltiesOrderSpy {
    MaintenanceOrderRecorder public immutable recorder;
    address public furnace;
    address public mineMarket;
    address public ve;
    address public mineCore;

    constructor(MaintenanceOrderRecorder recorder_) {
        recorder = recorder_;
    }

    function setWiring(address _furnace, address _mineMarket, address _ve, address _mineCore) external {
        furnace = _furnace;
        mineMarket = _mineMarket;
        ve = _ve;
        mineCore = _mineCore;
    }

    function flushPendingShareholderETH() external {
        recorder.markFlush();
    }
}

contract FurnaceOrderSpy {
    address public ve;
    address public shareholderRoyalties;
    address public mineMarket;
    address public mineCore;
    address public claim;

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

    function tick() external pure returns (uint256) {
        return 0;
    }
}

contract ClaimOrderSpy {
    address public mineCore;

    function setMineCore(address _mineCore) external {
        mineCore = _mineCore;
    }
}

contract MineCoreOrderSpy {
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

contract MaintenanceHubOrderInvariantsTest is Test {
    function _wireCanonicalMaintenanceBundle(
        MarketOrderSpy market,
        FurnaceOrderSpy furnace,
        VeOrderSpy ve,
        RoyaltiesOrderSpy royalties
    ) internal {
        ClaimOrderSpy claim = new ClaimOrderSpy();
        MineCoreOrderSpy core = new MineCoreOrderSpy();

        claim.setMineCore(address(core));
        core.setWiring(address(furnace), address(royalties), address(ve), address(claim));
        market.setWiring(address(ve), address(royalties), address(claim));
        furnace.setWiring(address(ve), address(royalties), address(market), address(core), address(claim));
        ve.setWiring(address(furnace), address(market), address(claim));
        royalties.setWiring(address(furnace), address(market), address(ve), address(core));
    }

    function testFuzz_pokeAlwaysCheckpointsAndFlushesBeforeMarketSweep(uint8 offerCountRaw, uint8 revertMask) public {
        MaintenanceOrderRecorder recorder = new MaintenanceOrderRecorder();
        MarketOrderSpy market = new MarketOrderSpy(recorder);
        FurnaceOrderSpy furnace = new FurnaceOrderSpy();
        VeOrderSpy ve = new VeOrderSpy(recorder);
        RoyaltiesOrderSpy royalties = new RoyaltiesOrderSpy(recorder);
        MockWETH weth = new MockWETH();

        _wireCanonicalMaintenanceBundle(market, furnace, ve, royalties);
        MaintenanceHub hub = new MaintenanceHub(
            address(market), address(furnace), address(ve), address(royalties), address(weth), address(0xDE5C0E)
        );

        uint256 offerCount = bound(uint256(offerCountRaw), 0, 8);
        uint256[] memory ids = new uint256[](offerCount);
        bool anySweepShouldSucceed = false;
        for (uint256 i = 0; i < offerCount; ++i) {
            ids[i] = i + 1;
            if (((uint256(revertMask) >> i) & 1) == 1) {
                market.setRevert(ids[i], true);
            } else {
                anySweepShouldSucceed = true;
            }
        }

        hub.poke(MaintenanceHub.PokeArgs({offerIds: ids, maxOffers: offerCount}));

        assertTrue(recorder.globalSeq() != 0, "global checkpoint not called");
        assertEq(recorder.totalSeq(), 0, "checkpointTotalVe must not be called (redundant)");
        assertTrue(recorder.flushSeq() != 0, "flush not called");
        assertLt(recorder.globalSeq(), recorder.flushSeq(), "global checkpoint must precede flush");

        if (offerCount != 0 && anySweepShouldSucceed) {
            assertTrue(recorder.firstMarketSeq() != 0, "market sweep not called");
            assertLt(recorder.flushSeq(), recorder.firstMarketSeq(), "flush must precede market sweep");
        } else if (offerCount != 0) {
            // When every market sweep reverts, the recorder mutation in the spy is rolled back too.
            assertEq(recorder.firstMarketSeq(), 0, "all reverted sweeps should not persist marker");
        } else {
            assertEq(recorder.firstMarketSeq(), 0, "unexpected market sweep");
        }
    }

    function testPokeRevertsOnceImmutableBundleDriftsOffCanonicalClaimOrCoreRoots() public {
        MaintenanceOrderRecorder recorder = new MaintenanceOrderRecorder();
        MarketOrderSpy market = new MarketOrderSpy(recorder);
        FurnaceOrderSpy furnace = new FurnaceOrderSpy();
        VeOrderSpy ve = new VeOrderSpy(recorder);
        RoyaltiesOrderSpy royalties = new RoyaltiesOrderSpy(recorder);
        MockWETH weth = new MockWETH();

        _wireCanonicalMaintenanceBundle(market, furnace, ve, royalties);
        MaintenanceHub hub = new MaintenanceHub(
            address(market), address(furnace), address(ve), address(royalties), address(weth), address(0xDE5C0E)
        );

        ClaimOrderSpy foreignClaim = new ClaimOrderSpy();
        market.setWiring(address(ve), address(royalties), address(foreignClaim));

        vm.expectRevert(Errors.WiringMismatch.selector);
        hub.poke(MaintenanceHub.PokeArgs({offerIds: new uint256[](0), maxOffers: 0}));
    }

    function testPokeRevertsOnceImmutableBundleDriftsOffCanonicalFurnaceClaimRoot() public {
        MaintenanceOrderRecorder recorder = new MaintenanceOrderRecorder();
        MarketOrderSpy market = new MarketOrderSpy(recorder);
        FurnaceOrderSpy furnace = new FurnaceOrderSpy();
        VeOrderSpy ve = new VeOrderSpy(recorder);
        RoyaltiesOrderSpy royalties = new RoyaltiesOrderSpy(recorder);
        MockWETH weth = new MockWETH();

        _wireCanonicalMaintenanceBundle(market, furnace, ve, royalties);
        MaintenanceHub hub = new MaintenanceHub(
            address(market), address(furnace), address(ve), address(royalties), address(weth), address(0xDE5C0E)
        );

        ClaimOrderSpy foreignClaim = new ClaimOrderSpy();
        furnace.setWiring(address(ve), address(royalties), address(market), furnace.mineCore(), address(foreignClaim));

        vm.expectRevert(Errors.WiringMismatch.selector);
        hub.poke(MaintenanceHub.PokeArgs({offerIds: new uint256[](0), maxOffers: 0}));
    }
}
