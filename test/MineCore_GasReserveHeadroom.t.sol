// SPDX-License-Identifier: MIT
pragma solidity ^0.8.34;

import {Test} from "forge-std/Test.sol";
import {Vm} from "forge-std/Vm.sol";

import {ClaimToken} from "src/ClaimToken.sol";
import {Furnace} from "src/Furnace.sol";
import {FurnaceGuardHelper} from "src/FurnaceGuardHelper.sol";

import {FurnaceQuoter} from "src/FurnaceQuoter.sol";
import {MineCore} from "src/MineCore.sol";
import {ShareholderRoyalties} from "src/ShareholderRoyalties.sol";
import {EntryTokenRegistry} from "src/EntryTokenRegistry.sol";
import {Constants} from "src/lib/Constants.sol";

import {VeClaimNFTHarness} from "./mocks/VeClaimNFTHarness.sol";
import {MockAerodromeRouter} from "./mocks/MockAerodromeRouter.sol";
import {MockWETH} from "./mocks/MockWETH.sol";
import {MineCoreHarness} from "./mocks/MineCoreHarness.sol";

/// @notice Forward-looking regression for the settle-claim reserve margin.
///
/// `_settlePrevKingClaim` forwards exactly
///   SETTLE_CLAIM_MIN_GAS - SETTLE_CLAIM_ENTER_RESERVE_GAS = 1_200_000 - 500_000 = 700_000
/// gas to `Furnace.enterWithClaimFor` at the min-gas boundary. Historical
/// gas-snapshot shows the worst-case enter path (new lock + bonus AMM) at
/// 631_326 gas and the top-up-existing path at 664_445 gas — both inside 700k
/// with 5–11% headroom.
///
/// This test asserts `KingAutoLockExecuted` fires at a modest 2M outer
/// takeover gas budget, where the boundary 700k forward MUST succeed. If a
/// future Furnace change pushes enterWithClaimFor cost past ~700k, the try
/// block OOGs and the catch emits `KingAutoLockFailed` instead — this test
/// then redlines with a message indicating that `SETTLE_CLAIM_MIN_GAS` must
/// be raised (and a new implementation deployed) or enterWithClaimFor cost
/// must be reduced before merging.
///
/// Cross-references:
///   - `test/MineCore_GasEstimationTrap.t.sol` — sibling dead-zone sweep
///   - `src/MineCore.sol:837,843` — the two constants under protection
contract MineCoreGasReserveHeadroomTest is Test {
    ClaimToken internal claim;
    VeClaimNFTHarness internal ve;
    ShareholderRoyalties internal royalties;
    Furnace internal furnace;
    MineCoreHarness internal mineCore;
    EntryTokenRegistry internal registry;

    MockWETH internal weth;
    MockAerodromeRouter internal router;

    address internal owner = address(0xA11CE);
    address internal mineMarket = address(0xBABA);
    address internal alice = address(0xA11C3);
    address internal bob = address(0xB0B);

    bytes32 internal constant AUTO_LOCK_EXECUTED_SIG =
        keccak256("KingAutoLockExecuted(uint256,address,uint256,uint256)");
    bytes32 internal constant AUTO_LOCK_SKIPPED_SIG = keccak256("KingAutoLockSkipped(uint256,address,uint256,uint8)");
    bytes32 internal constant AUTO_LOCK_FAILED_SIG = keccak256("KingAutoLockFailed(uint256,address,uint256,bytes)");

    function setUp() public {
        vm.etch(mineMarket, hex"00");

        claim = new ClaimToken(owner);
        ve = new VeClaimNFTHarness(address(claim), owner);
        royalties = new ShareholderRoyalties(address(ve), owner);
        furnace = new Furnace(
            address(claim), address(ve), address(new FurnaceGuardHelper(address(claim), address(ve))), owner
        );
        FurnaceQuoter quoter = new FurnaceQuoter(address(furnace));
        mineCore = new MineCoreHarness(address(claim), address(ve), address(royalties), owner);

        registry = new EntryTokenRegistry(owner);
        weth = new MockWETH();
        vm.etch(address(0xFAc7), hex"00");
        router = new MockAerodromeRouter(address(0xFAc7), address(weth));

        vm.startPrank(owner);
        claim.setMineCore(address(mineCore));
        vm.mockCall(mineMarket, abi.encodeWithSignature("ve()"), abi.encode(address(ve)));
        vm.mockCall(mineMarket, abi.encodeWithSignature("claim()"), abi.encode(address(claim)));
        vm.mockCall(mineMarket, abi.encodeWithSignature("royalties()"), abi.encode(address(royalties)));

        furnace.setMineCore(address(mineCore));
        furnace.setFurnaceQuoter(address(quoter));
        furnace.setMineMarket(mineMarket);
        furnace.setShareholderRoyalties(address(royalties));
        furnace.setEntryTokenRegistry(address(registry));

        mineCore.setFurnace(address(furnace));
        royalties.setWiring(address(mineCore), mineMarket, address(furnace));
        ve.setFurnace(address(furnace));
        ve.setMineMarket(mineMarket);
        EntryTokenRegistry mineCoreRegistry = new EntryTokenRegistry(owner);
        mineCore.setEntryTokenRegistry(address(mineCoreRegistry));
        mineCore.setGenesisKingClaimCollectedForTest(true);
        mineCore.setTakeoversPaused(false);

        registry.setRouterConfig(address(router), router.defaultFactory(), router.weth(), address(claim));
        vm.stopPrank();

        uint256 seed = 1_000_000e18;
        vm.prank(address(mineCore));
        claim.mint(address(furnace), seed);
        vm.prank(address(mineCore));
        furnace.creditReserve(seed);
    }

    function _takeoverAsGenesis(address user) internal {
        uint256 price = mineCore.getTakeoverPrice(block.timestamp);
        vm.deal(user, price);
        vm.prank(user);
        mineCore.takeover{value: price}(type(uint256).max);
    }

    function _takeoverWithGasLimit(address caller, uint256 price, uint256 gasLimit)
        internal
        returns (bool ok, Vm.Log[] memory logs)
    {
        vm.deal(caller, price);
        vm.recordLogs();
        vm.prank(caller);
        (ok,) = address(mineCore).call{value: price, gas: gasLimit}(
            abi.encodeWithSelector(mineCore.takeover.selector, type(uint256).max)
        );
        logs = vm.getRecordedLogs();
    }

    function _logHasTopic0(Vm.Log[] memory logs, bytes32 sig, address emitter) internal pure returns (bool) {
        for (uint256 i = 0; i < logs.length; i++) {
            if (logs[i].emitter != emitter) continue;
            if (logs[i].topics.length == 0) continue;
            if (logs[i].topics[0] == sig) return true;
        }
        return false;
    }

    /// @dev At a 2M outer gas budget, `_settlePrevKingClaim` is entered with
    ///      enough gasleft() that the guard passes AND the 700k forward to
    ///      `Furnace.enterWithClaimFor` MUST complete successfully. If this
    ///      assertion ever flips from EXECUTED to FAILED, a Furnace cost
    ///      increase has eroded the 500k reserve margin — raise
    ///      `SETTLE_CLAIM_MIN_GAS` (and deploy a new implementation via the
    ///      timelocked ProxyAdmin) or reduce enterWithClaimFor cost before
    ///      merging the change.
    function testAutoLockExecutesAtModestGasBudget() public {
        uint256 t0 = mineCore.emissionStartTime();
        vm.warp(t0 + 1);
        _takeoverAsGenesis(alice);

        vm.prank(alice);
        mineCore.setKingAutoLockConfig(true, 0, uint32(Constants.MIN_LOCK_DURATION), false, 1);

        vm.warp(block.timestamp + 1000);

        uint256 price = mineCore.getTakeoverPrice(block.timestamp);
        (bool ok, Vm.Log[] memory logs) = _takeoverWithGasLimit(bob, price, 2_000_000);

        assertTrue(ok, "takeover reverted at gas=2M");
        assertTrue(
            _logHasTopic0(logs, AUTO_LOCK_EXECUTED_SIG, address(mineCore)),
            "KingAutoLockExecuted missing at gas=2M -- 500k reserve margin has eroded; bump SETTLE_CLAIM_MIN_GAS or reduce enterWithClaimFor cost"
        );
        assertFalse(
            _logHasTopic0(logs, AUTO_LOCK_FAILED_SIG, address(mineCore)),
            "KingAutoLockFailed at gas=2M -- enterWithClaimFor cost has outgrown the 700k forward budget"
        );
    }

    /// @dev Complementary invariant: at a fat 5M outer budget the full
    ///      takeover including auto-lock must stay well under the 2.5M
    ///      frontend TAKEOVER_GAS_FLOOR (historical snapshot: 2_567_716).
    ///      If this flips, the 2.5M frontend floor is eroded next.
    function testFullTakeoverUnderFrontendFloorWithMargin() public {
        uint256 t0 = mineCore.emissionStartTime();
        vm.warp(t0 + 1);
        _takeoverAsGenesis(alice);

        vm.prank(alice);
        mineCore.setKingAutoLockConfig(true, 0, uint32(Constants.MIN_LOCK_DURATION), false, 1);

        vm.warp(block.timestamp + 1000);

        uint256 price = mineCore.getTakeoverPrice(block.timestamp);
        vm.deal(bob, price);
        vm.prank(bob);
        uint256 gasBefore = gasleft();
        mineCore.takeover{value: price, gas: 5_000_000}(type(uint256).max);
        uint256 used = gasBefore - gasleft();

        // TAKEOVER_GAS_FLOOR is 2_500_000. Require 10% headroom so a future
        // drift that would push real takeover gas past the frontend floor
        // redlines here first.
        uint256 FRONTEND_FLOOR = 2_500_000;
        assertLt(
            used * 11 / 10,
            FRONTEND_FLOOR,
            "full takeover gas * 1.1 exceeds frontend TAKEOVER_GAS_FLOOR -- raise the floor or reduce takeover cost"
        );
    }
}
