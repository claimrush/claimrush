// SPDX-License-Identifier: MIT
pragma solidity ^0.8.34;

import {Test} from "forge-std/Test.sol";

import {ClaimToken} from "src/ClaimToken.sol";
import {EntryTokenRegistry} from "src/EntryTokenRegistry.sol";
import {Furnace} from "src/Furnace.sol";
import {FurnaceGuardHelper} from "src/FurnaceGuardHelper.sol";

import {FurnaceQuoter} from "src/FurnaceQuoter.sol";
import {MineCore} from "src/MineCore.sol";
import {ShareholderRoyalties} from "src/ShareholderRoyalties.sol";
import {Constants} from "src/lib/Constants.sol";
import {Errors} from "src/lib/Errors.sol";

import {MockAerodromeRouter} from "./mocks/MockAerodromeRouter.sol";
import {MockContract} from "./mocks/MockContract.sol";
import {MockERC20} from "./mocks/MockERC20.sol";
import {MockVe} from "./mocks/MockVe.sol";
import {MockWETH} from "./mocks/MockWETH.sol";
import {MineCoreHarness} from "./mocks/MineCoreHarness.sol";
import {MockKingAutoLockFurnace} from "./mocks/MockKingAutoLockFurnace.sol";

contract RefundReverter {
    MineCore internal immutable mineCore;

    constructor(address mineCore_) {
        mineCore = MineCore(payable(mineCore_));
    }

    receive() external payable {
        revert("RefundReverter: no receive");
    }

    function doTakeoverFromBalance(uint256 value) external {
        mineCore.takeover{value: value}(type(uint256).max);
    }

    function withdrawRefund(address to) external {
        mineCore.withdrawRefundBalance(to);
    }
}

contract RefundReentrantReceiver {
    MineCore internal immutable mineCore;

    /// @dev 1 = not invoked, 2 = reentry failed (expected), 3 = reentry succeeded (unexpected)
    uint256 public reentryFlag = 1;

    constructor(address mineCore_) {
        mineCore = MineCore(payable(mineCore_));
    }

    receive() external payable {
        // Attempt to pull the just-credited refund bucket while the outer takeover
        // is still executing. The nonReentrant guard MUST reject this.
        (bool ok,) = address(mineCore).call(abi.encodeWithSignature("withdrawRefundBalance(address)", address(this)));
        reentryFlag = ok ? 3 : 2;
    }

    function doTakeoverFromBalance(uint256 value) external {
        mineCore.takeover{value: value}(type(uint256).max);
    }
}

/// @notice ve mock that intentionally makes NO progress in checkpointGlobalState().
/// @dev Used to ensure MineCore's gas-guarded checkpoint loop terminates safely.
contract MockVeNoProgress {
    uint256 public totalVeCached;
    uint256 public totalLockedClaim;
    address public claimToken;
    address public furnace;
    address public mineMarket;
    uint256 public globalLastTs;

    uint256 public checkpointGlobalCalls;
    uint256 public checkpointTotalCalls;

    function setTotalVeCached(uint256 v) external {
        totalVeCached = v;
    }

    function setGlobalLastTs(uint256 v) external {
        globalLastTs = v;
    }

    function setClaimToken(address t) external {
        claimToken = t;
    }

    function setFurnace(address f) external {
        furnace = f;
    }

    function setMineMarket(address m) external {
        mineMarket = m;
    }

    function checkpointGlobalState() external {
        // Intentionally do NOT advance globalLastTs.
        checkpointGlobalCalls++;
    }

    function checkpointTotalVe() external {
        checkpointTotalCalls++;
    }

    function veBalanceOf(address) external pure returns (uint256) {
        return 0;
    }

    function totalVeBiasScaled() external view returns (uint256) {
        return totalVeCached * 1e18;
    }

    function getShareholderLockParams(address)
        external
        pure
        returns (uint256[] memory amounts, uint256[] memory lockEnds, bool[] memory autoMaxFlags)
    {
        return (new uint256[](0), new uint256[](0), new bool[](0));
    }
}

/// @notice ve mock that advances by a bounded amount on each checkpointGlobalState() call.
/// @dev Used to prove MineCore does not stop after an arbitrary fixed number of progress steps.
contract MockVeGradualProgress {
    uint256 public totalVeCached;
    uint256 public totalLockedClaim;
    address public claimToken;
    address public furnace;
    address public mineMarket;
    uint256 public globalLastTs;

    uint256 public checkpointGlobalCalls;
    uint256 public checkpointTotalCalls;
    uint256 public progressPerCall = 1;

    function setTotalVeCached(uint256 v) external {
        totalVeCached = v;
    }

    function setGlobalLastTs(uint256 v) external {
        globalLastTs = v;
    }

    function setProgressPerCall(uint256 v) external {
        progressPerCall = v;
    }

    function setClaimToken(address t) external {
        claimToken = t;
    }

    function setFurnace(address f) external {
        furnace = f;
    }

    function setMineMarket(address m) external {
        mineMarket = m;
    }

    function checkpointGlobalState() external {
        checkpointGlobalCalls++;

        uint256 ts = globalLastTs;
        uint256 nowTs = block.timestamp;
        if (ts >= nowTs) return;

        uint256 remaining = nowTs - ts;
        uint256 step = progressPerCall;
        if (step > remaining) step = remaining;

        globalLastTs = ts + step;
    }

    function checkpointTotalVe() external {
        checkpointTotalCalls++;
    }

    function veBalanceOf(address) external pure returns (uint256) {
        return 0;
    }

    function totalVeBiasScaled() external view returns (uint256) {
        return totalVeCached * 1e18;
    }

    function getShareholderLockParams(address)
        external
        pure
        returns (uint256[] memory amounts, uint256[] memory lockEnds, bool[] memory autoMaxFlags)
    {
        return (new uint256[](0), new uint256[](0), new bool[](0));
    }
}

contract KingGasHeavyReceiver {
    MineCore internal immutable mineCore;

    uint256 public x;
    uint256 public y;

    constructor(address mineCore_) {
        mineCore = MineCore(payable(mineCore_));
    }

    // Requires >30k gas due to 2 SSTOREs. This makes MineCore's best-effort king payout (gas-stipended)
    // fail, forcing the fallback credit to kingEthBalance.
    receive() external payable {
        x = 1;
        y = 2;
    }

    function doTakeoverFromBalance(uint256 value) external {
        mineCore.takeover{value: value}(type(uint256).max);
    }

    function withdrawKing() external {
        mineCore.withdrawKingBalance();
    }
}

contract KingReentrantReceiver {
    MineCore internal immutable mineCore;

    /// @dev 1 = not invoked, 2 = reentry failed (expected), 3 = reentry succeeded (unexpected)
    uint256 public reentryFlag = 1;

    /// @dev Value to use for the re-entrant takeover call (set by the test).
    uint256 public reentryValue;

    constructor(address mineCore_) {
        mineCore = MineCore(payable(mineCore_));
    }

    function setReentryValue(uint256 v) external {
        reentryValue = v;
    }

    receive() external payable {
        // Attempt to re-enter MineCore.takeover() during the gas-stipended king payout.
        // This MUST fail due to MineCore's nonReentrant guard.
        (bool ok,) =
            address(mineCore).call{value: reentryValue}(abi.encodeWithSignature("takeover(uint256)", type(uint256).max));
        reentryFlag = ok ? 3 : 2;
    }

    function doTakeoverFromBalance(uint256 value) external {
        mineCore.takeover{value: value}(type(uint256).max);
    }
}

contract MineCoreTakeoverTest is Test {
    ClaimToken internal claim;
    MockVe internal ve;
    ShareholderRoyalties internal royalties;
    Furnace internal furnace;
    MineCoreHarness internal mineCore;

    address internal owner = address(0xA11CE);
    // NOTE: Avoid precompile addresses (e.g. 0x000...0A is the EIP-4844 point-eval precompile).
    // Use deterministic non-precompile addresses for EOAs in tests.
    address internal alice;
    address internal bob;

    function setUp() public {
        // Make balance accounting assertions deterministic.
        vm.txGasPrice(0);

        alice = makeAddr("alice");
        bob = makeAddr("bob");

        claim = new ClaimToken(owner);
        ve = new MockVe();
        royalties = new ShareholderRoyalties(address(ve), owner);
        furnace = new Furnace(
            address(claim), address(ve), address(new FurnaceGuardHelper(address(claim), address(ve))), owner
        );
        FurnaceQuoter quoter = new FurnaceQuoter(address(furnace));
        mineCore = new MineCoreHarness(address(claim), address(ve), address(royalties), owner);

        // Wire canonical permissions.
        vm.startPrank(owner);
        claim.setMineCore(address(mineCore));
        ve.setClaimToken(address(claim));
        furnace.setMineCore(address(mineCore));
        furnace.setFurnaceQuoter(address(quoter));
        vm.etch(address(0xB0B0), hex"00");
        furnace.setMineMarket(address(0xB0B0));
        furnace.setShareholderRoyalties(address(royalties));
        mineCore.setFurnace(address(furnace));
        vm.mockCall(address(0xB0B0), abi.encodeWithSignature("ve()"), abi.encode(address(ve)));
        vm.mockCall(address(0xB0B0), abi.encodeWithSignature("claim()"), abi.encode(address(claim)));
        vm.mockCall(address(0xB0B0), abi.encodeWithSignature("royalties()"), abi.encode(address(royalties)));
        ve.setFurnace(address(furnace));
        ve.setMineMarket(address(0xB0B0));
        royalties.setWiring(address(mineCore), address(0xB0B0), address(furnace));
        mineCore.setGenesisKingClaimCollectedForTest(true);
        mineCore.setTakeoversPaused(false);
        vm.stopPrank();

        // Provide a non-zero cached total ve so MineCore's snapshot step is exercised.
        ve.setTotalVeCached(1234);
    }

    // ------------------------------------------------------------
    // Helpers: deterministic emission integrals (mirrors MineCore)
    // ------------------------------------------------------------

    function _kingRateAt(uint256 t) internal pure returns (uint256) {
        uint256 D = Constants.EMISSION_DECAY_PERIOD;
        uint256 R0 = Constants.KING_EMISSION_LAUNCH_RATE;
        uint256 RF = Constants.KING_EMISSION_FLOOR;
        if (t >= D) return RF;
        uint256 diff = R0 - RF;
        uint256 dec = (diff * t) / D;
        uint256 rate = R0 - dec;
        if (rate < RF) rate = RF;
        return rate;
    }

    function _furnaceRateAt(uint256 t) internal pure returns (uint256) {
        uint256 D = Constants.EMISSION_DECAY_PERIOD;
        uint256 R0 = Constants.FURNACE_EMISSION_LAUNCH_RATE;
        uint256 RF = Constants.FURNACE_EMISSION_FLOOR;
        if (t >= D) return RF;
        uint256 diff = R0 - RF;
        uint256 dec = (diff * t) / D;
        uint256 rate = R0 - dec;
        if (rate < RF) rate = RF;
        return rate;
    }

    function _emitted(uint256 ts0, uint256 ts1, uint256 T0, bool isKing) internal pure returns (uint256) {
        if (ts1 <= ts0) return 0;
        if (ts1 <= T0) return 0;
        if (ts0 < T0) ts0 = T0;

        uint256 D = Constants.EMISSION_DECAY_PERIOD;
        uint256 RF = isKing ? Constants.KING_EMISSION_FLOOR : Constants.FURNACE_EMISSION_FLOOR;
        uint256 floorTs = T0 + D;

        if (ts0 >= floorTs) {
            return RF * (ts1 - ts0);
        }

        if (ts1 <= floorTs) {
            uint256 t0 = ts0 - T0;
            uint256 t1 = ts1 - T0;
            uint256 r0 = isKing ? _kingRateAt(t0) : _furnaceRateAt(t0);
            uint256 r1 = isKing ? _kingRateAt(t1) : _furnaceRateAt(t1);
            return (r0 + r1) * (ts1 - ts0) / 2;
        }

        uint256 t0b = ts0 - T0;
        uint256 r0b = isKing ? _kingRateAt(t0b) : _furnaceRateAt(t0b);
        uint256 decayPart = (r0b + RF) * (floorTs - ts0) / 2;
        uint256 floorPart = RF * (ts1 - floorTs);
        return decayPart + floorPart;
    }

    // ------------------------------------------------------------
    // Tests: takeover mechanics
    // ------------------------------------------------------------

    function testTakeoverGenesisStartsReignAndAllocatesAllToShareholders() public {
        vm.deal(alice, 10 ether);

        uint256 T0 = mineCore.emissionStartTime();
        uint256 t1 = T0 + 100;
        vm.warp(t1);

        uint256 floor = Constants.TAKEOVER_PRICE_FLOOR;

        vm.prank(alice);
        mineCore.takeover{value: floor}(type(uint256).max);

        assertEq(mineCore.currentKing(), alice);
        assertEq(mineCore.currentReignId(), 1);
        assertEq(mineCore.referencePrice(), floor * 2);
        assertEq(mineCore.currentReignStartTime(), t1);
        assertEq(mineCore.currentReignLastAccrualTime(), t1);

        (MineCore.ReignInfo memory r1) = mineCore.getReignInfo(1);
        assertEq(r1.king, alice);
        assertEq(r1.startTime, t1);
        assertEq(r1.endTime, 0);
        assertEq(r1.pricePaid, floor);
        assertEq(r1.referencePrice, floor * 2);

        // Genesis rule: 100% of takeover ETH goes to shareholders.
        assertLe(royalties.pendingShareholderETH(), 1);
        assertGt(royalties.ethPerVe(), 0);

        // Furnace stream is always mined and credited.
        uint256 expectedFurnace = _emitted(0, t1, T0, false);
        assertEq(claim.balanceOf(address(furnace)), expectedFurnace);
        assertEq(furnace.furnaceReserve(), expectedFurnace);

        // No king stream minted on the first takeover.
        assertEq(claim.balanceOf(alice), 0);
    }

    function testTakeoverNonGenesisFinalizesPrevReignAndCreditsKingBalance() public {
        vm.deal(alice, 10 ether);
        vm.deal(bob, 10 ether);

        uint256 T0 = mineCore.emissionStartTime();
        uint256 t1 = T0 + 100;
        vm.warp(t1);

        uint256 floor = Constants.TAKEOVER_PRICE_FLOOR;

        // Reign 1: alice becomes king.
        vm.prank(alice);
        mineCore.takeover{value: floor}(type(uint256).max);

        uint256 aliceBalBefore = alice.balance;

        // Reign 2: bob dethrones alice after some time.
        uint256 t2 = t1 + 50;
        vm.warp(t2);

        uint256 price2 = mineCore.getCurrentTakeoverPrice();
        vm.prank(bob);
        mineCore.takeover{value: price2}(type(uint256).max);

        assertEq(mineCore.currentKing(), bob);
        assertEq(mineCore.currentReignId(), 2);

        // Best-effort king payout: MineCore tries to push ETH to the previous king.
        // If the push fails, it credits kingEthBalance as a fallback.
        uint256 kingShare = (price2 * 75) / 100;

        // alice is an EOA in this test, so the best-effort push succeeds.
        assertEq(mineCore.kingEthBalance(alice), 0);
        assertEq(alice.balance, aliceBalBefore + kingShare);

        assertLe(royalties.pendingShareholderETH(), 1);
        assertGt(royalties.ethPerVe(), 0);

        // Reign 1 finalized metadata.
        (MineCore.ReignInfo memory r1) = mineCore.getReignInfo(1);
        assertEq(r1.king, alice);
        assertEq(r1.startTime, t1);
        assertEq(r1.endTime, t2);
        assertEq(r1.totalEthToKing, kingShare);

        uint256 expectedKingMined = _emitted(t1, t2, T0, true);
        assertEq(r1.totalClaimMined, expectedKingMined);
        assertEq(claim.balanceOf(alice), expectedKingMined);

        // Furnace receives deterministic emissions across the same intervals.
        uint256 expectedFurnaceTotal = _emitted(0, t2, T0, false);
        assertEq(claim.balanceOf(address(furnace)), expectedFurnaceTotal);
        assertEq(furnace.furnaceReserve(), expectedFurnaceTotal);

        // Reign 2 created metadata.
        (MineCore.ReignInfo memory r2) = mineCore.getReignInfo(2);
        assertEq(r2.king, bob);
        assertEq(r2.startTime, t2);
        assertEq(r2.endTime, 0);
        assertEq(r2.pricePaid, price2);
        assertEq(r2.referencePrice, price2 * 2);
    }

    function testWithdrawKingBalanceTransfersAndZerosWhenPushFails() public {
        // Use a contract king whose receive() needs > 30k gas.
        // MineCore's best-effort payout uses a gas stipend, so it will fail and credit kingEthBalance.
        KingGasHeavyReceiver king = new KingGasHeavyReceiver(address(mineCore));

        vm.deal(address(king), 10 ether);
        vm.deal(bob, 10 ether);

        uint256 T0 = mineCore.emissionStartTime();
        uint256 t1 = T0 + 10;
        vm.warp(t1);

        uint256 floor = Constants.TAKEOVER_PRICE_FLOOR;
        king.doTakeoverFromBalance(floor);

        // Dethrone.
        uint256 t2 = t1 + 1;
        vm.warp(t2);
        uint256 price2 = mineCore.getCurrentTakeoverPrice();
        vm.prank(bob);
        mineCore.takeover{value: price2}(type(uint256).max);

        uint256 expected = (price2 * 75) / 100;
        assertEq(mineCore.kingEthBalance(address(king)), expected);

        uint256 beforeBal = address(king).balance;
        king.withdrawKing();

        assertEq(mineCore.kingEthBalance(address(king)), 0);
        assertEq(address(king).balance, beforeBal + expected);
    }

    function testWithdrawKingBalanceForTransfersAndZerosWhenPushFails() public {
        address helper = address(new MockContract());
        vm.prank(owner);
        mineCore.setClaimAllHelper(helper);

        // Use a contract king whose receive() needs > 30k gas.
        // MineCore's best-effort payout uses a gas stipend, so it will fail and credit kingEthBalance.
        KingGasHeavyReceiver king = new KingGasHeavyReceiver(address(mineCore));

        vm.deal(address(king), 10 ether);
        vm.deal(bob, 10 ether);

        uint256 T0 = mineCore.emissionStartTime();
        uint256 t1 = T0 + 10;
        vm.warp(t1);

        uint256 floor = Constants.TAKEOVER_PRICE_FLOOR;
        king.doTakeoverFromBalance(floor);

        // Dethrone.
        uint256 t2 = t1 + 1;
        vm.warp(t2);
        uint256 price2 = mineCore.getCurrentTakeoverPrice();
        vm.prank(bob);
        mineCore.takeover{value: price2}(type(uint256).max);

        uint256 expected = (price2 * 75) / 100;
        assertEq(mineCore.kingEthBalance(address(king)), expected);

        uint256 beforeBal = address(king).balance;
        assertEq(king.x(), 0);
        assertEq(king.y(), 0);

        // Helper withdraws on behalf of the king contract.
        vm.prank(helper);
        mineCore.withdrawKingBalanceFor(address(king));

        assertEq(mineCore.kingEthBalance(address(king)), 0);
        assertEq(address(king).balance, beforeBal + expected);

        // The fallback path uses full gas; the king receiver can run its expensive receive().
        assertEq(king.x(), 1);
        assertEq(king.y(), 2);
    }

    function testTakeoverNonReentrant_MaliciousPrevKingReceiverCannotReenter() public {
        // Contract king whose receive() attempts to re-enter takeover during the dethroning payout.
        KingReentrantReceiver king = new KingReentrantReceiver(address(mineCore));

        vm.deal(address(king), 10 ether);
        vm.deal(bob, 10 ether);

        uint256 T0 = mineCore.emissionStartTime();
        uint256 t1 = T0 + 10;
        vm.warp(t1);

        uint256 floor = Constants.TAKEOVER_PRICE_FLOOR;
        king.doTakeoverFromBalance(floor);

        // Dethrone the contract-king; the payout triggers a re-entrant takeover attempt.
        uint256 t2 = t1 + 1;
        vm.warp(t2);

        uint256 price2 = mineCore.getCurrentTakeoverPrice();

        // Make the re-entrant call "meaningful": if reentrancy were possible, king has enough value to takeover.
        king.setReentryValue(price2);

        uint256 beforeBal = address(king).balance;

        vm.prank(bob);
        mineCore.takeover{value: price2}(type(uint256).max);

        // Takeover succeeded and advanced state.
        assertEq(mineCore.currentKing(), bob);
        assertEq(mineCore.currentReignId(), 2);

        // Re-entrant call failed (expected) and did not block the payout.
        assertEq(king.reentryFlag(), 2);
        assertEq(mineCore.kingEthBalance(address(king)), 0);

        uint256 expectedKingShare = (price2 * 75) / 100;
        assertEq(address(king).balance, beforeBal + expectedKingShare);
    }

    function testHybridRefundCreditsOnFailureAndWithdrawRefundBalance() public {
        // Use a contract that rejects ETH refunds.
        RefundReverter r = new RefundReverter(address(mineCore));

        uint256 floor = Constants.TAKEOVER_PRICE_FLOOR;
        uint256 extra = 0.01 ether;

        vm.deal(address(r), floor + extra);

        uint256 t1 = mineCore.emissionStartTime() + 1;
        vm.warp(t1);

        r.doTakeoverFromBalance(floor + extra);

        // Refund could not be pushed, so it is stored.
        assertEq(mineCore.refundEthBalance(address(r)), extra);

        address receiver = address(0xCAFE);
        vm.deal(receiver, 0);

        r.withdrawRefund(receiver);

        assertEq(mineCore.refundEthBalance(address(r)), 0);
        assertEq(receiver.balance, extra);
    }

    function testHybridRefundReentrantReceiverCannotPullRefundDuringTakeover() public {
        RefundReentrantReceiver r = new RefundReentrantReceiver(address(mineCore));

        uint256 floor = Constants.TAKEOVER_PRICE_FLOOR;
        uint256 extra = 0.01 ether;

        vm.deal(address(r), floor + extra);

        uint256 t1 = mineCore.emissionStartTime() + 1;
        vm.warp(t1);

        r.doTakeoverFromBalance(floor + extra);

        assertEq(r.reentryFlag(), 2, "refund-path reentry should be blocked");
        assertEq(mineCore.refundEthBalance(address(r)), 0, "successful refund push should clear the bucket");
        assertEq(mineCore.currentKing(), address(r), "takeover should still succeed");
    }

    function testTakeoverWithTokenGenesisWorksAndRefundsExcess() public {
        vm.deal(alice, 0);

        // Deploy router + registry with a WETH-like wrapped native.
        MockWETH weth = new MockWETH();
        MockERC20 tokenIn = new MockERC20("Token In", "TIN");

        address factory = address(0xFACA);
        vm.etch(factory, hex"00");
        MockAerodromeRouter router = new MockAerodromeRouter(factory, address(weth));
        EntryTokenRegistry registry = new EntryTokenRegistry(owner);

        // Configure router pools.
        address pool = address(0xBEEF);
        router.setPoolFor(address(tokenIn), address(weth), false, factory, pool);
        vm.etch(pool, hex"00");

        // Configure registry.
        vm.startPrank(owner);
        registry.setRouterConfig(address(router), factory, address(weth), address(claim));
        registry.setTokenConfig(address(tokenIn), true, false, false, address(0), false, pool);
        mineCore.setEntryTokenRegistry(address(registry));
        vm.stopPrank();

        // Ensure WETH has ETH so unwrapping succeeds even though the router mints tokens.
        vm.deal(address(weth), 100 ether);

        // Mint tokenIn to alice.
        tokenIn.mint(alice, 1 ether);
        vm.prank(alice);
        tokenIn.approve(address(mineCore), 1 ether);

        uint256 t1 = mineCore.emissionStartTime() + 1;
        vm.warp(t1);

        uint256 floor = Constants.TAKEOVER_PRICE_FLOOR;

        uint256 beforeEth = alice.balance;

        vm.prank(alice);
        mineCore.takeoverWithToken(address(tokenIn), 1 ether, floor, type(uint256).max);

        assertEq(mineCore.currentKing(), alice);
        assertEq(mineCore.currentReignId(), 1);

        // Alice receives the excess ETH (1 ether output - floor price).
        assertEq(alice.balance, beforeEth + (1 ether - floor));
    }

    function testTakeoverWithTokenRevertsIfRegistryPoolMismatch() public {
        // Deploy router + registry with a WETH-like wrapped native.
        MockWETH weth = new MockWETH();
        MockERC20 tokenIn = new MockERC20("Token In", "TIN");

        address factory = address(0xFACA);
        vm.etch(factory, hex"00"); // satisfy NotAContract guard
        MockAerodromeRouter router = new MockAerodromeRouter(factory, address(weth));
        EntryTokenRegistry registry = new EntryTokenRegistry(owner);

        // Configure router pools.
        address poolCorrect = address(0xBEEF);
        router.setPoolFor(address(tokenIn), address(weth), false, factory, poolCorrect);
        vm.etch(poolCorrect, hex"00");

        // Configure registry with the correct pool. (EntryTokenRegistry enforces router.poolFor(...) match.)
        vm.startPrank(owner);
        registry.setRouterConfig(address(router), factory, address(weth), address(claim));
        registry.setTokenConfig(address(tokenIn), true, false, false, address(0), false, poolCorrect);
        mineCore.setEntryTokenRegistry(address(registry));
        vm.stopPrank();

        // Now simulate a mismatch by changing router.poolFor after the registry has been configured.
        address poolWrong = address(0xCAFE);
        router.setPoolFor(address(tokenIn), address(weth), false, factory, poolWrong);

        // Mint tokenIn to alice.
        tokenIn.mint(alice, 1 ether);
        vm.prank(alice);
        tokenIn.approve(address(mineCore), 1 ether);

        uint256 t1 = mineCore.emissionStartTime() + 1;
        vm.warp(t1);

        uint256 floor = Constants.TAKEOVER_PRICE_FLOOR;

        // Registry pool mismatch MUST revert before any swap is attempted.
        vm.expectRevert(Errors.InvalidPool.selector);
        vm.prank(alice);
        mineCore.takeoverWithToken(address(tokenIn), 1 ether, floor, type(uint256).max);
    }

    function testTakeoverRevertsWhenVeCheckpointNoProgress() public {
        address user = makeAddr("noProgressUser");
        vm.deal(user, 10 ether);

        // Deploy a MineCore instance wired to a ve mock that makes no progress.
        ClaimToken claim2 = new ClaimToken(owner);
        MockVeNoProgress ve2 = new MockVeNoProgress();
        ShareholderRoyalties royalties2 = new ShareholderRoyalties(address(ve2), owner);
        Furnace furnace2 = new Furnace(
            address(claim2), address(ve2), address(new FurnaceGuardHelper(address(claim2), address(ve2))), owner
        );
        MineCoreHarness mine2 = new MineCoreHarness(address(claim2), address(ve2), address(royalties2), owner);

        vm.startPrank(owner);
        claim2.setMineCore(address(mine2));
        furnace2.setMineCore(address(mine2));
        vm.etch(address(0xB0B0), hex"00");
        furnace2.setMineMarket(address(0xB0B0));
        furnace2.setShareholderRoyalties(address(royalties2));
        mine2.setFurnace(address(furnace2));
        vm.mockCall(address(0xB0B0), abi.encodeWithSignature("ve()"), abi.encode(address(ve2)));
        vm.mockCall(address(0xB0B0), abi.encodeWithSignature("claim()"), abi.encode(address(claim2)));
        vm.mockCall(address(0xB0B0), abi.encodeWithSignature("royalties()"), abi.encode(address(royalties2)));
        royalties2.setWiring(address(mine2), address(0xB0B0), address(furnace2));
        mine2.setGenesisKingClaimCollectedForTest(true);
        mine2.setTakeoversPaused(false);
        vm.stopPrank();

        ve2.setClaimToken(address(claim2));
        ve2.setFurnace(address(furnace2));
        ve2.setMineMarket(address(0xB0B0));

        uint256 t1 = mine2.emissionStartTime() + 1;
        vm.warp(t1);

        uint256 floor = Constants.TAKEOVER_PRICE_FLOOR;

        vm.expectRevert(Errors.VeCheckpointStale.selector);
        vm.prank(user);
        mine2.takeover{value: floor}(type(uint256).max);

        assertEq(mine2.currentKing(), address(0));
        assertEq(mine2.currentReignId(), 0);
        assertEq(mine2.shareholderEthPending(), 0);
        assertEq(royalties2.pendingShareholderETH(), 0);
        assertEq(address(mine2).balance, 0);
    }

    function testTakeoverRevertsWhenVeCheckpointRemainsStale() public {
        address user = makeAddr("staleCheckpointUser");
        vm.deal(user, 10 ether);

        ClaimToken claim2 = new ClaimToken(owner);
        MockVeNoProgress ve2 = new MockVeNoProgress();
        ShareholderRoyalties royalties2 = new ShareholderRoyalties(address(ve2), owner);
        Furnace furnace2 = new Furnace(
            address(claim2), address(ve2), address(new FurnaceGuardHelper(address(claim2), address(ve2))), owner
        );
        MineCoreHarness mine2 = new MineCoreHarness(address(claim2), address(ve2), address(royalties2), owner);

        vm.startPrank(owner);
        claim2.setMineCore(address(mine2));
        furnace2.setMineCore(address(mine2));
        vm.etch(address(0xB0B0), hex"00");
        furnace2.setMineMarket(address(0xB0B0));
        furnace2.setShareholderRoyalties(address(royalties2));
        mine2.setFurnace(address(furnace2));
        vm.mockCall(address(0xB0B0), abi.encodeWithSignature("ve()"), abi.encode(address(ve2)));
        vm.mockCall(address(0xB0B0), abi.encodeWithSignature("claim()"), abi.encode(address(claim2)));
        vm.mockCall(address(0xB0B0), abi.encodeWithSignature("royalties()"), abi.encode(address(royalties2)));
        royalties2.setWiring(address(mine2), address(0xB0B0), address(furnace2));
        mine2.setGenesisKingClaimCollectedForTest(true);
        mine2.setTakeoversPaused(false);
        vm.stopPrank();

        ve2.setClaimToken(address(claim2));
        ve2.setFurnace(address(furnace2));
        ve2.setMineMarket(address(0xB0B0));

        uint256 t1 = mine2.emissionStartTime() + 1;
        vm.warp(t1);

        ve2.setTotalVeCached(Constants.MIN_VE_FLUSH);
        ve2.setGlobalLastTs(t1 - 1);

        uint256 floor = Constants.TAKEOVER_PRICE_FLOOR;

        vm.expectRevert(Errors.VeCheckpointStale.selector);
        vm.prank(user);
        mine2.takeover{value: floor}(type(uint256).max);

        assertEq(mine2.currentKing(), address(0));
        assertEq(royalties2.ethPerVe(), 0);
        assertEq(royalties2.pendingShareholderETH(), 0);
        assertEq(mine2.shareholderEthPending(), 0);
    }

    function testTakeoverSucceedsWhenVeCheckpointNeedsMoreThanTwentyProgressSteps() public {
        address user = makeAddr("manyStepUser");
        vm.deal(user, 10 ether);

        ClaimToken claim2 = new ClaimToken(owner);
        MockVeGradualProgress ve2 = new MockVeGradualProgress();
        ShareholderRoyalties royalties2 = new ShareholderRoyalties(address(ve2), owner);
        Furnace furnace2 = new Furnace(
            address(claim2), address(ve2), address(new FurnaceGuardHelper(address(claim2), address(ve2))), owner
        );
        MineCoreHarness mine2 = new MineCoreHarness(address(claim2), address(ve2), address(royalties2), owner);

        vm.startPrank(owner);
        claim2.setMineCore(address(mine2));
        furnace2.setMineCore(address(mine2));
        vm.etch(address(0xB0B0), hex"00");
        furnace2.setMineMarket(address(0xB0B0));
        furnace2.setShareholderRoyalties(address(royalties2));
        mine2.setFurnace(address(furnace2));
        vm.mockCall(address(0xB0B0), abi.encodeWithSignature("ve()"), abi.encode(address(ve2)));
        vm.mockCall(address(0xB0B0), abi.encodeWithSignature("claim()"), abi.encode(address(claim2)));
        vm.mockCall(address(0xB0B0), abi.encodeWithSignature("royalties()"), abi.encode(address(royalties2)));
        royalties2.setWiring(address(mine2), address(0xB0B0), address(furnace2));
        mine2.setGenesisKingClaimCollectedForTest(true);
        mine2.setTakeoversPaused(false);
        vm.stopPrank();

        ve2.setClaimToken(address(claim2));
        ve2.setFurnace(address(furnace2));
        ve2.setMineMarket(address(0xB0B0));

        uint256 t1 = mine2.emissionStartTime() + 21;
        vm.warp(t1);

        ve2.setGlobalLastTs(t1 - 21);
        ve2.setProgressPerCall(1);

        uint256 floor = Constants.TAKEOVER_PRICE_FLOOR;

        vm.prank(user);
        mine2.takeover{value: floor}(type(uint256).max);

        assertEq(mine2.currentKing(), user);
        assertEq(mine2.currentReignId(), 1);
        assertEq(ve2.globalLastTs(), t1);
        assertEq(ve2.checkpointGlobalCalls(), 21);
        // checkpointTotalVe is not called; checkpointGlobalState already syncs
        // the total-ve cache via the shared _checkpointGlobalStateInternal.
        assertEq(ve2.checkpointTotalCalls(), 0);
    }

    function testFuzzTakeoverSucceedsWhenVeCheckpointMakesForwardProgress(uint8 stepsBehind_) public {
        address user = makeAddr("manyStepFuzzUser");
        vm.deal(user, 10 ether);

        uint256 stepsBehind = bound(uint256(stepsBehind_), 21, 80);

        ClaimToken claim2 = new ClaimToken(owner);
        MockVeGradualProgress ve2 = new MockVeGradualProgress();
        ShareholderRoyalties royalties2 = new ShareholderRoyalties(address(ve2), owner);
        Furnace furnace2 = new Furnace(
            address(claim2), address(ve2), address(new FurnaceGuardHelper(address(claim2), address(ve2))), owner
        );
        MineCoreHarness mine2 = new MineCoreHarness(address(claim2), address(ve2), address(royalties2), owner);

        vm.startPrank(owner);
        claim2.setMineCore(address(mine2));
        furnace2.setMineCore(address(mine2));
        vm.etch(address(0xB0B0), hex"00");
        furnace2.setMineMarket(address(0xB0B0));
        furnace2.setShareholderRoyalties(address(royalties2));
        mine2.setFurnace(address(furnace2));
        vm.mockCall(address(0xB0B0), abi.encodeWithSignature("ve()"), abi.encode(address(ve2)));
        vm.mockCall(address(0xB0B0), abi.encodeWithSignature("claim()"), abi.encode(address(claim2)));
        vm.mockCall(address(0xB0B0), abi.encodeWithSignature("royalties()"), abi.encode(address(royalties2)));
        royalties2.setWiring(address(mine2), address(0xB0B0), address(furnace2));
        mine2.setGenesisKingClaimCollectedForTest(true);
        mine2.setTakeoversPaused(false);
        vm.stopPrank();

        ve2.setClaimToken(address(claim2));
        ve2.setFurnace(address(furnace2));
        ve2.setMineMarket(address(0xB0B0));

        uint256 t1 = mine2.emissionStartTime() + stepsBehind;
        vm.warp(t1);

        ve2.setGlobalLastTs(t1 - stepsBehind);
        ve2.setProgressPerCall(1);

        uint256 floor = Constants.TAKEOVER_PRICE_FLOOR;

        vm.prank(user);
        mine2.takeover{value: floor}(type(uint256).max);

        assertEq(mine2.currentKing(), user);
        assertEq(ve2.globalLastTs(), t1);
        assertEq(ve2.checkpointGlobalCalls(), stepsBehind);
    }

    function testRetryPushShareholderEthSucceedsWhenVeCheckpointNeedsMoreThanTwentyProgressSteps() public {
        ClaimToken claim2 = new ClaimToken(owner);
        MockVeGradualProgress ve2 = new MockVeGradualProgress();
        ShareholderRoyalties royalties2 = new ShareholderRoyalties(address(ve2), owner);
        Furnace furnace2 = new Furnace(
            address(claim2), address(ve2), address(new FurnaceGuardHelper(address(claim2), address(ve2))), owner
        );
        MineCoreHarness mine2 = new MineCoreHarness(address(claim2), address(ve2), address(royalties2), owner);

        vm.startPrank(owner);
        claim2.setMineCore(address(mine2));
        furnace2.setMineCore(address(mine2));
        vm.etch(address(0xB0B0), hex"00");
        furnace2.setMineMarket(address(0xB0B0));
        furnace2.setShareholderRoyalties(address(royalties2));
        mine2.setFurnace(address(furnace2));
        vm.mockCall(address(0xB0B0), abi.encodeWithSignature("ve()"), abi.encode(address(ve2)));
        vm.mockCall(address(0xB0B0), abi.encodeWithSignature("claim()"), abi.encode(address(claim2)));
        vm.mockCall(address(0xB0B0), abi.encodeWithSignature("royalties()"), abi.encode(address(royalties2)));
        royalties2.setWiring(address(mine2), address(0xB0B0), address(furnace2));
        mine2.setGenesisKingClaimCollectedForTest(true);
        mine2.setTakeoversPaused(false);
        vm.stopPrank();

        ve2.setClaimToken(address(claim2));
        ve2.setFurnace(address(furnace2));
        ve2.setMineMarket(address(0xB0B0));

        uint256 t1 = mine2.emissionStartTime() + 321;
        vm.warp(t1);

        ve2.setGlobalLastTs(t1 - 21);
        ve2.setProgressPerCall(1);
        mine2.setShareholderEthPendingHarness(1 ether);
        vm.deal(address(mine2), 1 ether);

        mine2.retryPushShareholderEth();

        assertEq(mine2.shareholderEthPending(), 0);
        assertEq(royalties2.pendingShareholderETH(), 1 ether);
        assertEq(address(royalties2).balance, 1 ether);
        assertEq(ve2.globalLastTs(), t1);
        assertEq(ve2.checkpointGlobalCalls(), 21);
        assertEq(ve2.checkpointTotalCalls(), 0);
    }

    function testRetryPushShareholderEthRevertsWhenVeCheckpointRemainsStale() public {
        ClaimToken claim2 = new ClaimToken(owner);
        MockVeNoProgress ve2 = new MockVeNoProgress();
        ShareholderRoyalties royalties2 = new ShareholderRoyalties(address(ve2), owner);
        Furnace furnace2 = new Furnace(
            address(claim2), address(ve2), address(new FurnaceGuardHelper(address(claim2), address(ve2))), owner
        );
        MineCoreHarness mine2 = new MineCoreHarness(address(claim2), address(ve2), address(royalties2), owner);

        vm.startPrank(owner);
        claim2.setMineCore(address(mine2));
        furnace2.setMineCore(address(mine2));
        vm.etch(address(0xB0B0), hex"00");
        furnace2.setMineMarket(address(0xB0B0));
        furnace2.setShareholderRoyalties(address(royalties2));
        mine2.setFurnace(address(furnace2));
        vm.mockCall(address(0xB0B0), abi.encodeWithSignature("ve()"), abi.encode(address(ve2)));
        vm.mockCall(address(0xB0B0), abi.encodeWithSignature("claim()"), abi.encode(address(claim2)));
        vm.mockCall(address(0xB0B0), abi.encodeWithSignature("royalties()"), abi.encode(address(royalties2)));
        royalties2.setWiring(address(mine2), address(0xB0B0), address(furnace2));
        mine2.setGenesisKingClaimCollectedForTest(true);
        mine2.setTakeoversPaused(false);
        vm.stopPrank();

        ve2.setClaimToken(address(claim2));
        ve2.setFurnace(address(furnace2));
        ve2.setMineMarket(address(0xB0B0));

        uint256 t1 = mine2.emissionStartTime() + 301;
        vm.warp(t1);

        ve2.setTotalVeCached(Constants.MIN_VE_FLUSH);
        ve2.setGlobalLastTs(t1 - 1);
        mine2.setShareholderEthPendingHarness(1 ether);

        vm.expectRevert(Errors.VeCheckpointStale.selector);
        mine2.retryPushShareholderEth();

        assertEq(mine2.shareholderEthPending(), 1 ether);
        assertEq(royalties2.pendingShareholderETH(), 0);
    }

    function testRetryPushShareholderEthSucceedsOnceVeCheckpointCatchesUp() public {
        ClaimToken claim2 = new ClaimToken(owner);
        MockVe ve2 = new MockVe();
        ShareholderRoyalties royalties2 = new ShareholderRoyalties(address(ve2), owner);
        Furnace furnace2 = new Furnace(
            address(claim2), address(ve2), address(new FurnaceGuardHelper(address(claim2), address(ve2))), owner
        );
        MineCoreHarness mine2 = new MineCoreHarness(address(claim2), address(ve2), address(royalties2), owner);

        vm.startPrank(owner);
        claim2.setMineCore(address(mine2));
        furnace2.setMineCore(address(mine2));
        vm.etch(address(0xB0B0), hex"00");
        furnace2.setMineMarket(address(0xB0B0));
        furnace2.setShareholderRoyalties(address(royalties2));
        mine2.setFurnace(address(furnace2));
        vm.mockCall(address(0xB0B0), abi.encodeWithSignature("ve()"), abi.encode(address(ve2)));
        vm.mockCall(address(0xB0B0), abi.encodeWithSignature("claim()"), abi.encode(address(claim2)));
        vm.mockCall(address(0xB0B0), abi.encodeWithSignature("royalties()"), abi.encode(address(royalties2)));
        royalties2.setWiring(address(mine2), address(0xB0B0), address(furnace2));
        mine2.setGenesisKingClaimCollectedForTest(true);
        mine2.setTakeoversPaused(false);
        vm.stopPrank();

        ve2.setClaimToken(address(claim2));
        ve2.setFurnace(address(furnace2));
        ve2.setMineMarket(address(0xB0B0));

        uint256 t1 = mine2.emissionStartTime() + 301;
        vm.warp(t1);

        ve2.setTotalVeCached(Constants.MIN_VE_FLUSH);
        ve2.setGlobalLastTs(t1 - 1);
        ve2.setCheckpointAdvances(true);
        mine2.setShareholderEthPendingHarness(1 ether);

        mine2.retryPushShareholderEth();

        assertEq(mine2.shareholderEthPending(), 1 ether);
        assertEq(royalties2.ethPerVe(), 0);
        assertEq(royalties2.pendingShareholderETH(), 0);
    }

    function _setForeignReserveAccrualFurnace(
        address claimRoot,
        address veRoot,
        address mineCoreRoot,
        address royaltiesRoot
    ) internal returns (MockKingAutoLockFurnace foreignFurnace) {
        foreignFurnace = new MockKingAutoLockFurnace(
            address(claim), claimRoot, veRoot, mineCoreRoot, royaltiesRoot, makeAddr("thief"), false
        );

        vm.prank(owner);
        mineCore.setFurnace(address(foreignFurnace));
    }

    function testTakeoverRevertsWhenLiveFurnaceClaimRootMismatchesBeforeReserveAccrual() public {
        uint256 price0 = mineCore.getCurrentTakeoverPrice();
        vm.deal(alice, price0);
        vm.prank(alice);
        mineCore.takeover{value: price0}(type(uint256).max);

        ClaimToken wrongClaim = new ClaimToken(owner);
        MockKingAutoLockFurnace foreignFurnace =
            _setForeignReserveAccrualFurnace(address(wrongClaim), address(ve), address(mineCore), address(royalties));

        vm.warp(block.timestamp + 1000);
        uint256 price1 = mineCore.getCurrentTakeoverPrice();
        vm.deal(bob, price1);

        vm.prank(bob);
        vm.expectRevert(Errors.WiringMismatch.selector);
        mineCore.takeover{value: price1}(type(uint256).max);

        assertEq(mineCore.currentKing(), alice, "king should remain unchanged");
        assertEq(claim.balanceOf(address(foreignFurnace)), 0, "foreign furnace must not receive emissions");
    }

    function testTakeoverRevertsWhenLiveFurnaceMineCoreRootMismatchesBeforeReserveAccrual() public {
        uint256 price0 = mineCore.getCurrentTakeoverPrice();
        vm.deal(alice, price0);
        vm.prank(alice);
        mineCore.takeover{value: price0}(type(uint256).max);

        MockKingAutoLockFurnace foreignFurnace =
            _setForeignReserveAccrualFurnace(address(claim), address(ve), address(mineCore), address(royalties));
        foreignFurnace.setMineCoreForTest(makeAddr("wrongMineCore"));

        vm.warp(block.timestamp + 1000);
        uint256 price1 = mineCore.getCurrentTakeoverPrice();
        vm.deal(bob, price1);

        vm.prank(bob);
        vm.expectRevert(Errors.WiringMismatch.selector);
        mineCore.takeover{value: price1}(type(uint256).max);

        assertEq(mineCore.currentKing(), alice, "king should remain unchanged");
        assertEq(claim.balanceOf(address(foreignFurnace)), 0, "foreign furnace must not receive emissions");
    }

    function testTakeoverRevertsWhenLiveFurnaceRoyaltiesRootMismatchesBeforeReserveAccrual() public {
        uint256 price0 = mineCore.getCurrentTakeoverPrice();
        vm.deal(alice, price0);
        vm.prank(alice);
        mineCore.takeover{value: price0}(type(uint256).max);

        MockKingAutoLockFurnace foreignFurnace = _setForeignReserveAccrualFurnace(
            address(claim), address(ve), address(mineCore), makeAddr("wrongRoyalties")
        );

        vm.warp(block.timestamp + 1000);
        uint256 price1 = mineCore.getCurrentTakeoverPrice();
        vm.deal(bob, price1);

        vm.prank(bob);
        vm.expectRevert(Errors.WiringMismatch.selector);
        mineCore.takeover{value: price1}(type(uint256).max);

        assertEq(mineCore.currentKing(), alice, "king should remain unchanged");
        assertEq(claim.balanceOf(address(foreignFurnace)), 0, "foreign furnace must not receive emissions");
    }

    function testFuzz_takeoverRejectsAnyForeignFurnaceClaimRoot(address badClaimRoot) public {
        vm.assume(badClaimRoot != address(0));
        vm.assume(badClaimRoot != address(claim));

        uint256 price0 = mineCore.getCurrentTakeoverPrice();
        vm.deal(alice, price0);
        vm.prank(alice);
        mineCore.takeover{value: price0}(type(uint256).max);

        MockKingAutoLockFurnace foreignFurnace =
            _setForeignReserveAccrualFurnace(badClaimRoot, address(ve), address(mineCore), address(royalties));

        vm.warp(block.timestamp + 1);
        uint256 price1 = mineCore.getCurrentTakeoverPrice();
        vm.deal(bob, price1);

        vm.prank(bob);
        vm.expectRevert(Errors.WiringMismatch.selector);
        mineCore.takeover{value: price1}(type(uint256).max);

        assertEq(mineCore.currentKing(), alice, "king should remain unchanged");
        assertEq(claim.balanceOf(address(foreignFurnace)), 0, "foreign furnace must not receive emissions");
    }
}
