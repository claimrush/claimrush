// SPDX-License-Identifier: MIT
pragma solidity ^0.8.34;

import {Test} from "forge-std/Test.sol";
import {Vm} from "forge-std/Vm.sol";
import {console2} from "forge-std/console2.sol";

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
import {MineCoreGasProbeHarness} from "./mocks/MineCoreGasProbeHarness.sol";

/// @notice Regression coverage for the `_settlePrevKingClaim` gas-profile guarantee.
///
/// `_settlePrevKingClaim` MUST finalize the takeover for every gas-limit value, choosing one of
/// three valid outcomes:
///   1. auto-lock succeeds (KingAutoLockExecuted + Takeover emitted)
///   2. auto-lock skipped up-front due to tight gas (KingAutoLockSkipped + Takeover)
///   3. auto-lock attempted, inner call OOGs, liquid CLAIM fallback (KingAutoLockFailed
///      + KingClaimCredited? + Takeover)
///
/// Reverting the outer takeover is never acceptable. A non-monotonic gas profile (where a caller
/// with enough gas to enter the auto-lock branch but not enough to finish it OOGs the whole
/// takeover) would violate this guarantee and is what this suite specifically rules out.
contract MineCoreGasEstimationTrapTest is Test {
    ClaimToken internal claim;
    VeClaimNFTHarness internal ve;
    ShareholderRoyalties internal royalties;
    Furnace internal furnace;
    MineCoreGasProbeHarness internal mineCore;
    EntryTokenRegistry internal registry;

    MockWETH internal weth;
    MockAerodromeRouter internal router;

    address internal owner = address(0xA11CE);
    address internal mineMarket = address(0xBABA);

    address internal alice = address(0xA11C3);
    address internal bob = address(0xB0B);

    // Event signatures we assert on.
    bytes32 internal constant TAKEOVER_SIG = keccak256("Takeover(uint256,address,address,uint256,uint256,uint256)");
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
        mineCore = new MineCoreGasProbeHarness(address(claim), address(ve), address(royalties), owner);

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

        // Seed Furnace reserve so bonus math is non-trivial.
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

    /// @dev Helper that invokes `takeover` at a specific gas limit and captures emitted
    ///      events via `vm.recordLogs`, returning the call success flag and the log trace.
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

    function _seedExistingLock(address user, uint256 claimAmount, uint32 durationSeconds)
        internal
        returns (uint256 tokenId)
    {
        vm.prank(address(mineCore));
        claim.mint(address(mineCore), claimAmount);

        vm.prank(address(mineCore));
        claim.approve(address(furnace), claimAmount);

        vm.prank(address(mineCore));
        tokenId = furnace.enterWithClaimFor(user, claimAmount, 0, durationSeconds, false, 1);
    }

    function _setupProbeScenarioNewLock(uint256 minVeOut) internal returns (uint256 claimAmount) {
        uint256 t0 = mineCore.emissionStartTime();
        vm.warp(t0 + 1);
        _takeoverAsGenesis(alice);

        vm.prank(alice);
        mineCore.setKingAutoLockConfig(true, 0, uint32(Constants.MIN_LOCK_DURATION), false, minVeOut);

        vm.warp(block.timestamp + 1000);
        claimAmount = mineCore.kingEmittedExposed(mineCore.currentReignLastAccrualTime(), block.timestamp);
    }

    function _setupProbeScenarioTopUp(uint256 minVeOut) internal returns (uint256 claimAmount, uint256 tokenId) {
        uint256 t0 = mineCore.emissionStartTime();
        vm.warp(t0 + 1);
        _takeoverAsGenesis(alice);

        tokenId = _seedExistingLock(alice, 50_000e18, uint32(Constants.MAX_LOCK_DURATION));

        vm.prank(alice);
        mineCore.setKingAutoLockConfig(true, tokenId, 0, false, minVeOut);

        vm.warp(block.timestamp + 1000);
        claimAmount = mineCore.kingEmittedExposed(mineCore.currentReignLastAccrualTime(), block.timestamp);
    }

    function _probeNewLock(uint256 minVeOut)
        internal
        returns (MineCoreGasProbeHarness.SettleGasProbe memory probe, uint256 claimAmount)
    {
        uint256 snapshot = vm.snapshot();
        claimAmount = _setupProbeScenarioNewLock(minVeOut);
        probe = mineCore.probeSettlePrevKingClaim(1, alice, claimAmount);
        vm.revertTo(snapshot);
    }

    function _probeTopUp(uint256 minVeOut)
        internal
        returns (MineCoreGasProbeHarness.SettleGasProbe memory probe, uint256 claimAmount, uint256 tokenId)
    {
        uint256 snapshot = vm.snapshot();
        (claimAmount, tokenId) = _setupProbeScenarioTopUp(minVeOut);
        probe = mineCore.probeSettlePrevKingClaim(1, alice, claimAmount);
        vm.revertTo(snapshot);
    }

    function _probePreEnterOverhead(MineCoreGasProbeHarness.SettleGasProbe memory probe)
        internal
        pure
        returns (uint256)
    {
        return probe.gasEntry - probe.gasBeforeEnter;
    }

    function _probeEnterGasUsed(MineCoreGasProbeHarness.SettleGasProbe memory probe) internal pure returns (uint256) {
        return probe.gasBeforeEnter - probe.gasAfterEnterOrCatch;
    }

    function _probePostEnterCleanup(MineCoreGasProbeHarness.SettleGasProbe memory probe)
        internal
        pure
        returns (uint256)
    {
        return probe.gasAfterEnterOrCatch - probe.gasAfterSettle;
    }

    function _enterBudgetAtFloor(MineCoreGasProbeHarness.SettleGasProbe memory probe) internal view returns (uint256) {
        return mineCore.settleClaimMinGasForTest() - mineCore.settleClaimEnterReserveGasForTest()
            - _probePreEnterOverhead(probe);
    }

    /// @dev Core regression: step through the historical dead-zone plus comfortable margins
    ///      on both sides. Every gas limit must produce a finalized takeover with some
    ///      valid auto-lock outcome — never an OOG revert.
    function testTakeoverFinalizesAcrossFormerDeadZone() public {
        // Arrange: Alice is king with auto-lock enabled and non-trivial duration so the
        // auto-lock branch has real work to do when she is dethroned.
        uint256 t0 = mineCore.emissionStartTime();
        vm.warp(t0 + 1);
        _takeoverAsGenesis(alice);

        vm.prank(alice);
        mineCore.setKingAutoLockConfig(true, 0, uint32(Constants.MIN_LOCK_DURATION), false, 1);

        // Advance time so prevKing accrued non-zero CLAIM (forces _settlePrevKingClaim).
        vm.warp(block.timestamp + 1000);

        // Sweep across the ~1.04M – ~1.49M gas-limit band plus bookends; every bucket must
        // succeed without tripping the takeover fallback. Each iteration re-establishes the
        // scenario to keep outcomes independent.
        uint256[14] memory gasLimits = [
            uint256(900_000),
            1_000_000,
            1_050_000,
            1_100_000,
            1_150_000,
            1_200_000,
            1_250_000,
            1_300_000,
            1_350_000,
            1_400_000,
            1_450_000,
            1_500_000,
            1_800_000,
            2_500_000
        ];

        for (uint256 i = 0; i < gasLimits.length; i++) {
            uint256 gasLimit = gasLimits[i];
            uint256 snapshot = vm.snapshot();

            uint256 price = mineCore.getTakeoverPrice(block.timestamp);
            (bool ok, Vm.Log[] memory logs) = _takeoverWithGasLimit(bob, price, gasLimit);

            // Invariant 1: the takeover MUST succeed at every gas limit we test.
            assertTrue(ok, string.concat("takeover reverted at gas=", vm.toString(gasLimit)));

            // Invariant 2: a Takeover event must have been emitted, proving the new-reign
            //              state transition actually happened (not just a partial execution).
            assertTrue(
                _logHasTopic0(logs, TAKEOVER_SIG, address(mineCore)),
                string.concat("Takeover not emitted at gas=", vm.toString(gasLimit))
            );

            // Invariant 3: exactly one of the three auto-lock outcome events must fire.
            bool executed = _logHasTopic0(logs, AUTO_LOCK_EXECUTED_SIG, address(mineCore));
            bool skipped = _logHasTopic0(logs, AUTO_LOCK_SKIPPED_SIG, address(mineCore));
            bool failed = _logHasTopic0(logs, AUTO_LOCK_FAILED_SIG, address(mineCore));
            uint256 count = (executed ? 1 : 0) + (skipped ? 1 : 0) + (failed ? 1 : 0);
            assertEq(count, 1, string.concat("expected exactly one auto-lock outcome at gas=", vm.toString(gasLimit)));

            // Invariant 4: new king is Bob in every branch.
            assertEq(mineCore.currentKing(), bob, string.concat("currentKing != bob at gas=", vm.toString(gasLimit)));

            vm.revertTo(snapshot);
        }
    }

    /// @dev Sanity: with abundant gas, the happy auto-lock branch still executes and the
    ///      veNFT is minted. Guards against an overcorrection that accidentally disables
    ///      auto-lock on the success path.
    function testAutoLockStillExecutesWithAbundantGas() public {
        uint256 t0 = mineCore.emissionStartTime();
        vm.warp(t0 + 1);
        _takeoverAsGenesis(alice);

        vm.prank(alice);
        mineCore.setKingAutoLockConfig(true, 0, uint32(Constants.MIN_LOCK_DURATION), false, 1);

        vm.warp(block.timestamp + 1000);
        uint256 price = mineCore.getTakeoverPrice(block.timestamp);
        (bool ok, Vm.Log[] memory logs) = _takeoverWithGasLimit(bob, price, 5_000_000);

        assertTrue(ok, "abundant-gas takeover reverted");
        assertTrue(
            _logHasTopic0(logs, AUTO_LOCK_EXECUTED_SIG, address(mineCore)), "KingAutoLockExecuted missing on happy path"
        );

        (,, uint256 pinnedTokenId,,,) = mineCore.getKingAutoLockConfig(alice);
        assertTrue(pinnedTokenId != 0, "pinnedTokenId not set");
        assertEq(ve.balanceOf(alice), 1, "alice veNFT count");
        assertEq(claim.balanceOf(alice), 0, "alice must not receive liquid CLAIM on happy path");
    }

    /// @dev Quantifies the gas floor at `_settlePrevKingClaim` entry required to keep
    ///      the auto-lock branch monotonically non-reverting.
    ///
    /// For any auto-lock branch we care about, the gas left at function entry must cover:
    ///   1. pre-enter overhead (destination resolution, wiring checks, mint, approve)
    ///   2. the explicit `enterWithClaimFor{gas: ...}` sub-call budget
    ///   3. the reserved 500k for catch cleanup + the rest of `_executeTakeover`
    ///
    /// This test measures the real integrated pre-enter overhead and inner-call cost for:
    ///   - new veNFT mint
    ///   - top-up of an existing veNFT
    ///   - late inner revert (`minVeOut` too high), which exercises the catch path
    ///
    /// The forwardable budget at the 1.2M floor is:
    ///   `SETTLE_CLAIM_MIN_GAS - SETTLE_CLAIM_ENTER_RESERVE_GAS - preEnterOverhead`
    ///
    /// We require that budget to exceed actual inner-call gas by at least 10%.
    function testMeasuredEnterBudgetRetainsTenPercentHeadroom() public {
        (MineCoreGasProbeHarness.SettleGasProbe memory createProbe,) = _probeNewLock(1);
        (MineCoreGasProbeHarness.SettleGasProbe memory topUpProbe,,) = _probeTopUp(1);
        (MineCoreGasProbeHarness.SettleGasProbe memory catchProbe,) = _probeNewLock(type(uint256).max);

        uint8 successOutcome = mineCore.probeOutcomeEnterSucceeded();
        uint8 catchOutcome = mineCore.probeOutcomeEnterCaught();

        assertEq(createProbe.outcome, successOutcome, "new-lock probe must succeed");
        assertEq(topUpProbe.outcome, successOutcome, "top-up probe must succeed");
        assertEq(catchProbe.outcome, catchOutcome, "late-revert probe must hit catch");

        uint256 createBudget = _enterBudgetAtFloor(createProbe);
        uint256 topUpBudget = _enterBudgetAtFloor(topUpProbe);
        uint256 catchBudget = _enterBudgetAtFloor(catchProbe);

        uint256 createEnterGas = _probeEnterGasUsed(createProbe);
        uint256 topUpEnterGas = _probeEnterGasUsed(topUpProbe);
        uint256 catchEnterGas = _probeEnterGasUsed(catchProbe);

        assertGe(createBudget, (createEnterGas * 110) / 100, "new-lock enter budget lost 10% headroom");
        assertGe(topUpBudget, (topUpEnterGas * 110) / 100, "top-up enter budget lost 10% headroom");
        assertGe(catchBudget, (catchEnterGas * 110) / 100, "late-revert enter budget lost 10% headroom");

        console2.log("settle min gas", mineCore.settleClaimMinGasForTest());
        console2.log("enter reserve gas", mineCore.settleClaimEnterReserveGasForTest());

        console2.log("create pre-enter overhead", _probePreEnterOverhead(createProbe));
        console2.log("create enter gas", createEnterGas);
        console2.log("create post-enter cleanup", _probePostEnterCleanup(createProbe));
        console2.log(
            "create gas left after settle at floor",
            mineCore.settleClaimMinGasForTest() - (createProbe.gasEntry - createProbe.gasAfterSettle)
        );

        console2.log("top-up pre-enter overhead", _probePreEnterOverhead(topUpProbe));
        console2.log("top-up enter gas", topUpEnterGas);
        console2.log("top-up post-enter cleanup", _probePostEnterCleanup(topUpProbe));
        console2.log(
            "top-up gas left after settle at floor",
            mineCore.settleClaimMinGasForTest() - (topUpProbe.gasEntry - topUpProbe.gasAfterSettle)
        );

        console2.log("catch pre-enter overhead", _probePreEnterOverhead(catchProbe));
        console2.log("catch enter gas", catchEnterGas);
        console2.log("catch post-enter cleanup", _probePostEnterCleanup(catchProbe));
        console2.log(
            "catch gas left after settle at floor",
            mineCore.settleClaimMinGasForTest() - (catchProbe.gasEntry - catchProbe.gasAfterSettle)
        );
    }
}
