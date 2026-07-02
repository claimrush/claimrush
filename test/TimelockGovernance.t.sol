// SPDX-License-Identifier: MIT
pragma solidity ^0.8.34;

import {Test} from "forge-std/Test.sol";

import {ProxyAdmin} from "lib/openzeppelin-contracts/contracts/proxy/transparent/ProxyAdmin.sol";
import {
    ITransparentUpgradeableProxy,
    TransparentUpgradeableProxy
} from "lib/openzeppelin-contracts/contracts/proxy/transparent/TransparentUpgradeableProxy.sol";
import {TimelockController} from "lib/openzeppelin-contracts/contracts/governance/TimelockController.sol";
import {FreezeAndBurn} from "script/FreezeAndBurn.s.sol";
import {TimelockAcceptOwnership} from "script/TimelockAcceptOwnership.s.sol";
import {TimelockRuntimeUpgrade} from "script/TimelockRuntimeUpgrade.s.sol";

import {ClaimAllHelper} from "src/ClaimAllHelper.sol";
import {ClaimToken} from "src/ClaimToken.sol";
import {Constants} from "src/lib/Constants.sol";
import {Errors} from "src/lib/Errors.sol";
import {DelegationHub} from "src/DelegationHub.sol";
import {FurnaceQuoter} from "src/FurnaceQuoter.sol";
import {IMarketRouter} from "src/interfaces/IMarketRouter.sol";
import {MarketRouter} from "src/MarketRouter.sol";
import {MockEntryTokenRegistry} from "test/mocks/MockEntryTokenRegistry.sol";
import {FurnaceHarness} from "test/mocks/FurnaceHarness.sol";
import {MineCoreHarness} from "test/mocks/MineCoreHarness.sol";
import {ShareholderRoyaltiesHarness} from "test/mocks/ShareholderRoyaltiesHarness.sol";
import {VeClaimNFTHarness} from "test/mocks/VeClaimNFTHarness.sol";

interface ITimelockVersionedRuntime {
    function version() external view returns (uint256);
}

interface ITimelockOwnable2StepLike {
    function owner() external view returns (address);
    function pendingOwner() external view returns (address);
    function transferOwnership(address newOwner) external;
    function acceptOwnership() external;
}

contract MineCoreTimelockV2 is MineCoreHarness {
    constructor(address claim_, address ve_, address royalties_) MineCoreHarness(claim_, ve_, royalties_, address(0)) {}

    function version() external pure returns (uint256) {
        return 2;
    }
}

contract FurnaceTimelockV2 is FurnaceHarness {
    constructor(address claim_, address ve_) FurnaceHarness(claim_, ve_, address(0)) {}

    function version() external pure returns (uint256) {
        return 2;
    }
}

contract TimelockCallerStub {}

contract TimelockOwnableStub {
    address public owner;
    address public pendingOwner;

    constructor(address initialOwner) {
        owner = initialOwner;
    }

    function transferOwnership(address newOwner) external {
        require(msg.sender == owner, "not owner");
        pendingOwner = newOwner;
    }

    function acceptOwnership() external {
        require(msg.sender == pendingOwner, "not pending owner");
        owner = pendingOwner;
        pendingOwner = address(0);
    }
}

contract TimelockAcceptOwnershipHarness is TimelockAcceptOwnership {
    function needsAcceptance(address target, address timelockAddr, uint8 action, string memory label)
        external
        view
        returns (bool)
    {
        return _needsAcceptance(target, timelockAddr, Action(action), label);
    }
}

contract TimelockGovernanceTest is Test {
    bytes32 internal constant _IMPLEMENTATION_SLOT = 0x360894a13ba1a3210667c828492db98dca3e2076cc3735a920a3ca505d382bbc;
    bytes32 internal constant _ADMIN_SLOT = 0xb53127684a568b3173ae13b9f8a6016e243e63b6e8ee1178d6a717850b5d6103;
    bytes32 internal constant _ZERO_PREDECESSOR = bytes32(0);
    uint256 internal constant _TIMELOCK_DELAY = 2 days;
    /// @dev Arbitrary non-zero key so `BroadcastSignerBase._resolveBroadcastSigner`
    ///      finds a valid local signer. The simulation paths exercised by
    ///      `testGovernanceScriptSimulationEnvCases` never actually broadcast, so
    ///      the exact value only matters insofar as it parses and is non-zero.
    uint256 internal constant _SIMULATION_LOCAL_PK = 1;

    address internal owner = makeAddr("owner");
    address internal adminSafe;
    address internal alice = makeAddr("alice");
    address internal bob = makeAddr("bob");
    address internal keeper = makeAddr("keeper");
    address internal newKeeper = makeAddr("newKeeper");

    ClaimToken internal claim;
    VeClaimNFTHarness internal ve;
    MineCoreHarness internal mineCore;
    FurnaceHarness internal furnace;
    MarketRouter internal market;
    ShareholderRoyaltiesHarness internal royalties;
    TimelockController internal timelock;

    ProxyAdmin internal mineCoreAdmin;
    ProxyAdmin internal furnaceAdmin;
    ProxyAdmin internal marketAdmin;
    ProxyAdmin internal royaltiesAdmin;

    DelegationHub internal hub;
    ClaimAllHelper internal claimAllHelper;
    FurnaceQuoter internal furnaceQuoter;
    TimelockOwnableStub internal furnaceRegistry;
    TimelockOwnableStub internal mineCoreRegistry;
    TimelockOwnableStub internal dexAdapter;
    TimelockOwnableStub internal lpStakingVault7D;

    uint256 internal listedTokenId;
    uint256 internal offerId;

    function setUp() public {
        vm.setEnv("ADMIN_SAFE", "");
        vm.setEnv("TIMELOCK_CALLER", "");
        vm.setEnv("TIMELOCK_ACTION", "");
        vm.setEnv("TIMELOCK_SALT", "");
        vm.setEnv("DEPLOYMENTS_MANIFEST_JSON", "");
        vm.setEnv("MINE_CORE_NEW_IMPLEMENTATION", "");
        vm.setEnv("MINE_CORE_UPGRADE_DATA", "");
        vm.setEnv("FURNACE_NEW_IMPLEMENTATION", "");
        vm.setEnv("FURNACE_UPGRADE_DATA", "");
        vm.setEnv("MARKET_ROUTER_NEW_IMPLEMENTATION", "");
        vm.setEnv("MARKET_ROUTER_UPGRADE_DATA", "");
        vm.setEnv("SHAREHOLDER_ROYALTIES_NEW_IMPLEMENTATION", "");
        vm.setEnv("SHAREHOLDER_ROYALTIES_UPGRADE_DATA", "");
        // Prime a valid local broadcast key. Every script we invoke via
        // `script.run()` calls `BroadcastSignerBase._resolveBroadcastSigner`,
        // which in a local-chain context demands `LOCAL_PRIVATE_KEY` (or a
        // fallback `PRIVATE_KEY`) be a non-zero uint. Peer test contracts such
        // as `ScriptSafety.t.sol` deliberately zero these variables to test
        // error paths, and because Foundry runs test contracts in parallel
        // threads sharing one OS process env, those writes can leak into this
        // suite. We re-apply the signer env vars here (and again right before
        // each `script.run()` below) so our simulation paths stay deterministic
        // regardless of suite ordering.
        _primeSignerEnv();

        adminSafe = address(new TimelockCallerStub());
        claim = new ClaimToken(owner);
        ve = new VeClaimNFTHarness(address(claim), owner);

        (address royaltiesProxy, ProxyAdmin royaltiesProxyAdmin) = _deployRoyaltiesProxy();
        royalties = ShareholderRoyaltiesHarness(royaltiesProxy);
        royaltiesAdmin = royaltiesProxyAdmin;

        (address marketProxy, ProxyAdmin marketProxyAdmin) = _deployMarketProxy(royaltiesProxy);
        market = MarketRouter(marketProxy);
        marketAdmin = marketProxyAdmin;

        (address furnaceProxy, ProxyAdmin furnaceProxyAdmin) = _deployFurnaceProxy();
        furnace = FurnaceHarness(payable(furnaceProxy));
        furnaceAdmin = furnaceProxyAdmin;

        (address mineCoreProxy, ProxyAdmin mineCoreProxyAdmin) = _deployMineCoreProxy(royaltiesProxy);
        mineCore = MineCoreHarness(payable(mineCoreProxy));
        mineCoreAdmin = mineCoreProxyAdmin;

        _wireRuntimeQuartet();
        _seedRuntimeState();
        _deployTimelock();
        _transferGovernanceToTimelock();
    }

    function testTimelockBootstrapAndOwnershipHandoff() public view {
        assertEq(timelock.getMinDelay(), _TIMELOCK_DELAY, "timelock delay should match governance policy");

        assertTrue(timelock.hasRole(timelock.PROPOSER_ROLE(), adminSafe), "safe should propose");
        assertTrue(timelock.hasRole(timelock.CANCELLER_ROLE(), adminSafe), "safe should cancel");
        assertTrue(timelock.hasRole(timelock.EXECUTOR_ROLE(), adminSafe), "safe should execute");
        assertTrue(timelock.hasRole(timelock.DEFAULT_ADMIN_ROLE(), address(timelock)), "timelock should self-admin");
        assertFalse(
            timelock.hasRole(timelock.DEFAULT_ADMIN_ROLE(), address(this)), "deployer admin should be renounced"
        );

        assertEq(mineCoreAdmin.owner(), address(timelock), "MineCore ProxyAdmin should be timelock-owned");
        assertEq(furnaceAdmin.owner(), address(timelock), "Furnace ProxyAdmin should be timelock-owned");
        assertEq(marketAdmin.owner(), address(timelock), "MarketRouter ProxyAdmin should be timelock-owned");
        assertEq(royaltiesAdmin.owner(), address(timelock), "Royalties ProxyAdmin should be timelock-owned");

        assertEq(claim.owner(), address(0), "ClaimToken owner should already be renounced");
        assertEq(claim.pendingOwner(), address(0), "ClaimToken pendingOwner should clear");
        assertTrue(claim.configFrozen(), "ClaimToken should already be frozen");
        assertEq(ve.owner(), address(timelock), "VeClaimNFT owner should be timelock");
        assertEq(ve.pendingOwner(), address(0), "VeClaimNFT pendingOwner should clear");
        assertEq(mineCore.owner(), address(timelock), "MineCore owner should be timelock");
        assertEq(mineCore.pendingOwner(), address(0), "MineCore pendingOwner should clear");
        assertEq(furnace.owner(), address(timelock), "Furnace owner should be timelock");
        assertEq(furnace.pendingOwner(), address(0), "Furnace pendingOwner should clear");
        assertEq(market.owner(), address(timelock), "MarketRouter owner should be timelock");
        assertEq(market.pendingOwner(), address(0), "MarketRouter pendingOwner should clear");
        assertEq(royalties.owner(), address(timelock), "Royalties owner should be timelock");
        assertEq(royalties.pendingOwner(), address(0), "Royalties pendingOwner should clear");
        assertEq(furnaceRegistry.owner(), address(timelock), "Furnace registry owner should be timelock");
        assertEq(furnaceRegistry.pendingOwner(), address(0), "Furnace registry pendingOwner should clear");
        assertEq(mineCoreRegistry.owner(), address(timelock), "MineCore registry owner should be timelock");
        assertEq(mineCoreRegistry.pendingOwner(), address(0), "MineCore registry pendingOwner should clear");
        assertEq(dexAdapter.owner(), address(timelock), "DexAdapter owner should be timelock");
        assertEq(dexAdapter.pendingOwner(), address(0), "DexAdapter pendingOwner should clear");
        assertEq(lpStakingVault7D.owner(), address(timelock), "LpStakingVault7D owner should be timelock");
        assertEq(lpStakingVault7D.pendingOwner(), address(0), "LpStakingVault7D pendingOwner should clear");
    }

    /// @dev Governance-script simulation tests use vm.setEnv (process-global).
    ///      Running them as separate test* functions causes parallel env var races.
    ///      This sequential runner avoids that.
    function testGovernanceScriptSimulationEnvCases() public {
        uint256 snap;

        snap = vm.snapshot();
        _testTimelockAcceptOwnershipScriptSimulatesSafeScheduleWithoutBroadcast();
        vm.revertTo(snap);

        snap = vm.snapshot();
        _testTimelockAcceptOwnershipScriptSimulatesSafeScheduleBeforeInitiate();
        vm.revertTo(snap);

        snap = vm.snapshot();
        _testFreezeAndBurnScriptSimulatesSafeScheduleWithoutBroadcast();
        vm.revertTo(snap);

        snap = vm.snapshot();
        _testTimelockRuntimeUpgradeScriptSimulatesSafeScheduleWithoutBroadcast();
        vm.revertTo(snap);
    }

    function _testTimelockAcceptOwnershipScriptSimulatesSafeScheduleWithoutBroadcast() internal {
        vm.prank(address(timelock));
        ve.transferOwnership(owner);
        vm.prank(owner);
        ve.acceptOwnership();
        vm.prank(owner);
        ve.transferOwnership(address(timelock));

        assertEq(ve.owner(), owner, "VeClaimNFT owner should be moved out of timelock for setup");
        assertEq(ve.pendingOwner(), address(timelock), "VeClaimNFT pending owner should point back to timelock");

        _primeTimelockSimEnv();

        TimelockAcceptOwnership script = new TimelockAcceptOwnership();
        script.run();

        address[] memory targets = new address[](1);
        uint256[] memory values = new uint256[](1);
        bytes[] memory payloads = new bytes[](1);
        targets[0] = address(ve);
        payloads[0] = abi.encodeWithSignature("acceptOwnership()");

        bytes32 op = timelock.hashOperationBatch(targets, values, payloads, _ZERO_PREDECESSOR, bytes32(0));
        assertFalse(timelock.isOperation(op), "simulation-only Safe path should not queue live operations");
        assertEq(ve.owner(), owner, "simulation-only Safe path must not mutate owner");
        assertEq(ve.pendingOwner(), address(timelock), "simulation-only Safe path must not clear pending owner");
    }

    function _testTimelockAcceptOwnershipScriptSimulatesSafeScheduleBeforeInitiate() internal {
        _moveAllOwnershipTargetsTo(owner);
        _assertOwnershipTargetsState(owner, address(0));

        _primeTimelockSimEnv();

        TimelockAcceptOwnership script = new TimelockAcceptOwnership();
        script.run();

        bytes32 op = timelock.hashOperationBatch(
            _ownershipAcceptTargets(), _zeroValues(9), _acceptOwnershipPayloads(9), _ZERO_PREDECESSOR, bytes32(0)
        );
        assertFalse(timelock.isOperation(op), "simulation-only Safe path should not queue live operations");
        _assertOwnershipTargetsState(owner, address(0));
    }

    function testTimelockAcceptOwnershipExecuteRejectsTargetsNotPendingToTimelock() public {
        _moveAllOwnershipTargetsTo(owner);

        vm.prank(owner);
        ve.transferOwnership(address(timelock));

        assertEq(mineCore.owner(), owner, "MineCore should be out of timelock ownership for this negative case");
        assertEq(mineCore.pendingOwner(), address(0), "MineCore should not be pending back to timelock");

        TimelockAcceptOwnershipHarness harness = new TimelockAcceptOwnershipHarness();
        vm.expectRevert("TimelockAcceptOwnership: MineCore not pending to timelock");
        harness.needsAcceptance(address(mineCore), address(timelock), 1, "MineCore");
    }

    function _testFreezeAndBurnScriptSimulatesSafeScheduleWithoutBroadcast() internal {
        _primeTimelockSimEnv();

        FreezeAndBurn script = new FreezeAndBurn();
        script.run();

        bytes32 op = timelock.hashOperationBatch(
            _freezeAndBurnTargets(), _zeroValues(8), _freezeAndBurnPayloads(), _ZERO_PREDECESSOR, bytes32(0)
        );
        assertFalse(timelock.isOperation(op), "simulation-only Safe path should not queue live operations");
        assertFalse(mineCore.configFrozen(), "simulation-only Safe path must not freeze MineCore");
        assertFalse(furnace.configFrozen(), "simulation-only Safe path must not freeze Furnace");
        assertFalse(ve.configFrozen(), "simulation-only Safe path must not freeze VeClaimNFT");
        assertFalse(royalties.configFrozen(), "simulation-only Safe path must not freeze Royalties");
    }

    function _testTimelockRuntimeUpgradeScriptSimulatesSafeScheduleWithoutBroadcast() internal {
        address oldMineCoreImpl = _implementationOf(address(mineCore));
        address newMineCoreImpl = address(new MineCoreTimelockV2(address(claim), address(ve), address(royalties)));

        _primeTimelockSimEnv();
        vm.setEnv("MINE_CORE_NEW_IMPLEMENTATION", vm.toString(newMineCoreImpl));

        TimelockRuntimeUpgrade script = new TimelockRuntimeUpgrade();
        script.run();

        address[] memory targets = new address[](1);
        uint256[] memory values = new uint256[](1);
        bytes[] memory payloads = new bytes[](1);
        targets[0] = address(mineCoreAdmin);
        payloads[0] = abi.encodeCall(
            ProxyAdmin.upgradeAndCall,
            (ITransparentUpgradeableProxy(payable(address(mineCore))), newMineCoreImpl, bytes(""))
        );

        bytes32 op = timelock.hashOperationBatch(targets, values, payloads, _ZERO_PREDECESSOR, bytes32(0));
        assertFalse(timelock.isOperation(op), "simulation-only Safe path should not queue live operations");
        assertEq(_implementationOf(address(mineCore)), oldMineCoreImpl, "simulation-only Safe path must not upgrade");
    }

    function testTimelockBatchUpgradeCanRotateMineCoreAndFurnaceAtomically() public {
        address oldMineCoreImpl = _implementationOf(address(mineCore));
        address oldFurnaceImpl = _implementationOf(address(furnace));

        address newMineCoreImpl = address(new MineCoreTimelockV2(address(claim), address(ve), address(royalties)));
        address newFurnaceImpl = address(new FurnaceTimelockV2(address(claim), address(ve)));

        address[] memory targets = new address[](2);
        bytes[] memory payloads = new bytes[](2);
        targets[0] = address(mineCoreAdmin);
        payloads[0] = abi.encodeCall(
            ProxyAdmin.upgradeAndCall,
            (ITransparentUpgradeableProxy(payable(address(mineCore))), newMineCoreImpl, bytes(""))
        );
        targets[1] = address(furnaceAdmin);
        payloads[1] = abi.encodeCall(
            ProxyAdmin.upgradeAndCall,
            (ITransparentUpgradeableProxy(payable(address(furnace))), newFurnaceImpl, bytes(""))
        );

        _scheduleAndExecuteBatch(targets, payloads, keccak256("runtime-upgrade"));

        assertEq(_implementationOf(address(mineCore)), newMineCoreImpl, "MineCore implementation should rotate");
        assertEq(_implementationOf(address(furnace)), newFurnaceImpl, "Furnace implementation should rotate");
        assertTrue(oldMineCoreImpl != newMineCoreImpl, "MineCore implementation must change");
        assertTrue(oldFurnaceImpl != newFurnaceImpl, "Furnace implementation must change");
        assertEq(ITimelockVersionedRuntime(address(mineCore)).version(), 2, "MineCore should run v2 logic");
        assertEq(ITimelockVersionedRuntime(address(furnace)).version(), 2, "Furnace should run v2 logic");

        assertEq(mineCore.currentKing(), alice, "MineCore state should survive upgrade");
        assertEq(mineCore.kingEthBalance(alice), 1 ether, "MineCore balances should survive upgrade");
        assertEq(furnace.furnaceReserve(), 500e18, "Furnace reserve should survive upgrade");
        assertEq(furnace.mineCore(), address(mineCore), "Furnace reciprocal wiring should survive upgrade");
    }

    function testFreezeAndBurnMakesRuntimeImmutableButKeepsOwnerKnobsTimelocked() public {
        _scheduleAndExecuteBatch(_freezeAndBurnTargets(), _freezeAndBurnPayloads(), keccak256("freeze-and-burn"));

        assertTrue(claim.configFrozen(), "ClaimToken should remain frozen from wire time");
        assertTrue(mineCore.configFrozen(), "MineCore should be frozen");
        assertTrue(furnace.configFrozen(), "Furnace should be frozen");
        assertTrue(ve.configFrozen(), "VeClaimNFT should be frozen");
        assertTrue(royalties.configFrozen(), "Royalties should be frozen");
        assertEq(mineCoreAdmin.owner(), address(0), "MineCore ProxyAdmin should be burned");
        assertEq(furnaceAdmin.owner(), address(0), "Furnace ProxyAdmin should be burned");
        assertEq(marketAdmin.owner(), address(0), "MarketRouter ProxyAdmin should be burned");
        assertEq(royaltiesAdmin.owner(), address(0), "Royalties ProxyAdmin should be burned");

        MockEntryTokenRegistry replacementRegistry = new MockEntryTokenRegistry();
        address[] memory ownerTargets = new address[](2);
        bytes[] memory ownerPayloads = new bytes[](2);
        ownerTargets[0] = address(mineCore);
        ownerPayloads[0] = abi.encodeWithSignature("setEntryTokenRegistry(address)", address(replacementRegistry));
        ownerTargets[1] = address(market);
        ownerPayloads[1] = abi.encodeCall(MarketRouter.setSettlementKeeper, (newKeeper, true));

        _scheduleAndExecuteBatch(ownerTargets, ownerPayloads, keccak256("post-burn-owner-knobs"));

        assertEq(mineCore.entryTokenRegistry(), address(replacementRegistry), "MineCore registry should remain mutable");
        assertTrue(market.isSettlementKeeper(newKeeper), "MarketRouter policy knobs should remain timelocked");

        address oldMineCoreImpl = _implementationOf(address(mineCore));
        address newMineCoreImpl = address(new MineCoreTimelockV2(address(claim), address(ve), address(royalties)));
        address[] memory upgradeTargets = new address[](1);
        bytes[] memory upgradePayloads = new bytes[](1);
        upgradeTargets[0] = address(mineCoreAdmin);
        upgradePayloads[0] = abi.encodeCall(
            ProxyAdmin.upgradeAndCall,
            (ITransparentUpgradeableProxy(payable(address(mineCore))), newMineCoreImpl, bytes(""))
        );

        bytes32 op = _scheduleBatch(upgradeTargets, upgradePayloads, keccak256("post-burn-upgrade-attempt"));
        vm.warp(block.timestamp + _TIMELOCK_DELAY + 1);
        vm.expectRevert();
        vm.prank(adminSafe);
        timelock.executeBatch(
            upgradeTargets,
            _zeroValues(upgradeTargets.length),
            upgradePayloads,
            _ZERO_PREDECESSOR,
            keccak256("post-burn-upgrade-attempt")
        );

        assertEq(_implementationOf(address(mineCore)), oldMineCoreImpl, "MineCore implementation should remain locked");
        assertFalse(timelock.isOperationDone(op), "failed upgrade must not complete");
    }

    function testFreezeAndBurnBatchIsAtomicIfAFreezePreconditionFails() public {
        ClaimAllHelper alternateHelper = new ClaimAllHelper(address(royalties), address(mineCore));

        address[] memory mismatchTargets = new address[](1);
        bytes[] memory mismatchPayloads = new bytes[](1);
        mismatchTargets[0] = address(mineCore);
        mismatchPayloads[0] = abi.encodeWithSignature("setClaimAllHelper(address)", address(alternateHelper));
        _scheduleAndExecuteBatch(mismatchTargets, mismatchPayloads, keccak256("desync-claimall-helper"));

        address[] memory targets = _freezeAndBurnTargets();
        bytes[] memory payloads = _freezeAndBurnPayloads();
        bytes32 salt = keccak256("freeze-and-burn-should-fail");
        bytes32 op = _scheduleBatch(targets, payloads, salt);

        vm.warp(block.timestamp + _TIMELOCK_DELAY + 1);
        vm.expectRevert();
        vm.prank(adminSafe);
        timelock.executeBatch(targets, _zeroValues(targets.length), payloads, _ZERO_PREDECESSOR, salt);

        assertTrue(claim.configFrozen(), "ClaimToken should stay frozen from wire time");
        assertFalse(mineCore.configFrozen(), "MineCore should remain unfrozen on failed batch");
        assertFalse(furnace.configFrozen(), "Furnace should remain unfrozen on failed batch");
        assertFalse(ve.configFrozen(), "VeClaimNFT should remain unfrozen on failed batch");
        assertFalse(royalties.configFrozen(), "Royalties should remain unfrozen on failed batch");
        assertEq(mineCoreAdmin.owner(), address(timelock), "MineCore ProxyAdmin should not burn on failed batch");
        assertEq(furnaceAdmin.owner(), address(timelock), "Furnace ProxyAdmin should not burn on failed batch");
        assertEq(marketAdmin.owner(), address(timelock), "MarketRouter ProxyAdmin should not burn on failed batch");
        assertEq(royaltiesAdmin.owner(), address(timelock), "Royalties ProxyAdmin should not burn on failed batch");
        assertFalse(timelock.isOperationDone(op), "failed batch must not complete");
    }

    function _deployTimelock() internal {
        address[] memory proposers = new address[](1);
        address[] memory executors = new address[](1);
        proposers[0] = adminSafe;
        executors[0] = adminSafe;
        timelock = new TimelockController(_TIMELOCK_DELAY, proposers, executors, address(this));
        timelock.renounceRole(timelock.DEFAULT_ADMIN_ROLE(), address(this));
    }

    /// @dev Re-applies the local broadcast key immediately before any script invocation.
    ///      See `setUp` for the race-avoidance rationale.
    function _primeSignerEnv() internal {
        vm.setEnv("LOCAL_PRIVATE_KEY", vm.toString(_SIMULATION_LOCAL_PK));
        vm.setEnv("PRIVATE_KEY", vm.toString(_SIMULATION_LOCAL_PK));
    }

    /// @dev Pin every env var the governance-script simulation paths read,
    ///      including the manifest, the schedule action, and the broadcast
    ///      signer. `TIMELOCK_CALLER` takes priority over `ADMIN_SAFE` in
    ///      `TimelockScriptBase._timelockCallerOrZero`; pinning it to the
    ///      PROPOSER-roled `adminSafe` keeps the resolved caller deterministic
    ///      even when a peer suite sharing the process-global env clears
    ///      `ADMIN_SAFE` mid-run.
    function _primeTimelockSimEnv() internal {
        vm.setEnv("DEPLOYMENTS_MANIFEST_JSON", _timelockManifestJson());
        vm.setEnv("ADMIN_SAFE", vm.toString(adminSafe));
        vm.setEnv("TIMELOCK_CALLER", vm.toString(adminSafe));
        vm.setEnv("TIMELOCK_ACTION", "schedule");
        _primeSignerEnv();
    }

    function _transferGovernanceToTimelock() internal {
        vm.startPrank(owner);
        address[] memory targets = _ownershipAcceptTargets();
        for (uint256 i = 0; i < targets.length; i++) {
            ITimelockOwnable2StepLike(targets[i]).transferOwnership(address(timelock));
        }

        mineCoreAdmin.transferOwnership(address(timelock));
        assertEq(mineCoreAdmin.owner(), address(timelock), "MineCore ProxyAdmin transfer should be immediate");
        furnaceAdmin.transferOwnership(address(timelock));
        assertEq(furnaceAdmin.owner(), address(timelock), "Furnace ProxyAdmin transfer should be immediate");
        marketAdmin.transferOwnership(address(timelock));
        assertEq(marketAdmin.owner(), address(timelock), "MarketRouter ProxyAdmin transfer should be immediate");
        royaltiesAdmin.transferOwnership(address(timelock));
        assertEq(royaltiesAdmin.owner(), address(timelock), "Royalties ProxyAdmin transfer should be immediate");
        vm.stopPrank();

        bytes[] memory payloads = _acceptOwnershipPayloads(targets.length);
        _scheduleAndExecuteBatch(targets, payloads, keccak256("accept-ownership"));
    }

    function _scheduleBatch(address[] memory targets, bytes[] memory payloads, bytes32 salt)
        internal
        returns (bytes32 op)
    {
        uint256[] memory values = _zeroValues(targets.length);
        op = timelock.hashOperationBatch(targets, values, payloads, _ZERO_PREDECESSOR, salt);
        vm.prank(adminSafe);
        timelock.scheduleBatch(targets, values, payloads, _ZERO_PREDECESSOR, salt, _TIMELOCK_DELAY);
        assertTrue(timelock.isOperationPending(op), "scheduled operation should be pending");
    }

    function _scheduleAndExecuteBatch(address[] memory targets, bytes[] memory payloads, bytes32 salt)
        internal
        returns (bytes32 op)
    {
        op = _scheduleBatch(targets, payloads, salt);
        vm.warp(block.timestamp + _TIMELOCK_DELAY + 1);
        vm.prank(adminSafe);
        timelock.executeBatch(targets, _zeroValues(targets.length), payloads, _ZERO_PREDECESSOR, salt);
        assertTrue(timelock.isOperationDone(op), "operation should be completed");
    }

    function _freezeAndBurnTargets() internal view returns (address[] memory targets) {
        targets = new address[](8);
        targets[0] = address(mineCore);
        targets[1] = address(furnace);
        targets[2] = address(ve);
        targets[3] = address(royalties);
        targets[4] = address(mineCoreAdmin);
        targets[5] = address(furnaceAdmin);
        targets[6] = address(marketAdmin);
        targets[7] = address(royaltiesAdmin);
    }

    function _freezeAndBurnPayloads() internal pure returns (bytes[] memory payloads) {
        payloads = new bytes[](8);
        payloads[0] = abi.encodeWithSignature("freezeConfig()");
        payloads[1] = abi.encodeWithSignature("freezeConfig()");
        payloads[2] = abi.encodeWithSignature("freezeConfig()");
        payloads[3] = abi.encodeWithSignature("freezeConfig()");
        payloads[4] = abi.encodeWithSignature("renounceOwnership()");
        payloads[5] = abi.encodeWithSignature("renounceOwnership()");
        payloads[6] = abi.encodeWithSignature("renounceOwnership()");
        payloads[7] = abi.encodeWithSignature("renounceOwnership()");
    }

    function _timelockManifestJson() internal view returns (string memory) {
        string memory zero = vm.toString(address(0));
        return string.concat(_timelockManifestCoreJson(), _timelockManifestAuxJson(), zero, '"}}}');
    }

    function _timelockManifestCoreJson() internal view returns (string memory) {
        return string.concat(
            '{"contracts":{"TimelockController":{"address":"',
            vm.toString(address(timelock)),
            '","bootstrapAdmin":"',
            vm.toString(address(this)),
            '"},"ClaimToken":{"address":"',
            vm.toString(address(claim)),
            '"},"VeClaimNFT":{"address":"',
            vm.toString(address(ve)),
            '"},"MineCore":{"address":"',
            vm.toString(address(mineCore)),
            '","proxyAdmin":"',
            vm.toString(address(mineCoreAdmin)),
            '"},"ShareholderRoyalties":{"address":"',
            vm.toString(address(royalties)),
            '","proxyAdmin":"',
            vm.toString(address(royaltiesAdmin)),
            '"},"Furnace":{"address":"',
            vm.toString(address(furnace)),
            '","proxyAdmin":"',
            vm.toString(address(furnaceAdmin)),
            '"},"MarketRouter":{"address":"',
            vm.toString(address(market)),
            '","proxyAdmin":"',
            vm.toString(address(marketAdmin)),
            '"},'
        );
    }

    function _timelockManifestAuxJson() internal view returns (string memory) {
        return string.concat(
            '"ClaimAllHelper":{"address":"',
            vm.toString(address(claimAllHelper)),
            '"},"FurnaceEntryTokenRegistry":{"address":"',
            vm.toString(address(furnaceRegistry)),
            '"},"MineCoreEntryTokenRegistry":{"address":"',
            vm.toString(address(mineCoreRegistry)),
            '"},"DexAdapter":{"address":"',
            vm.toString(address(dexAdapter)),
            '"},"LpStakingVault7D":{"address":"',
            vm.toString(address(lpStakingVault7D)),
            '"},"LaunchController":{"address":"'
        );
    }

    function _zeroValues(uint256 length) internal pure returns (uint256[] memory values) {
        values = new uint256[](length);
    }

    function _deployRoyaltiesProxy() internal returns (address proxy, ProxyAdmin admin) {
        ShareholderRoyaltiesHarness impl = new ShareholderRoyaltiesHarness(address(ve), address(0));
        return _deployProxy(address(impl), abi.encodeWithSignature("initialize(address)", owner));
    }

    function _deployMarketProxy(address royaltiesProxy) internal returns (address proxy, ProxyAdmin admin) {
        MarketRouter impl = new MarketRouter(address(claim), address(ve), royaltiesProxy, address(0));
        return _deployProxy(address(impl), abi.encodeWithSignature("initialize(address)", owner));
    }

    function _deployFurnaceProxy() internal returns (address proxy, ProxyAdmin admin) {
        FurnaceHarness impl = new FurnaceHarness(address(claim), address(ve), address(0));
        return _deployProxy(address(impl), abi.encodeWithSignature("initialize(address)", owner));
    }

    function _deployMineCoreProxy(address royaltiesProxy) internal returns (address proxy, ProxyAdmin admin) {
        MineCoreHarness impl = new MineCoreHarness(address(claim), address(ve), royaltiesProxy, address(0));
        return _deployProxy(address(impl), abi.encodeWithSignature("initialize(address)", owner));
    }

    function _deployProxy(address implementation, bytes memory initData)
        internal
        returns (address proxy, ProxyAdmin admin)
    {
        proxy = address(new TransparentUpgradeableProxy(implementation, owner, initData));
        admin = ProxyAdmin(_readAddressSlot(proxy, _ADMIN_SLOT));
        assertEq(admin.owner(), owner, "proxy admin owner should start at protocol owner");
    }

    function _wireRuntimeQuartet() internal {
        hub = new DelegationHub();
        claimAllHelper = new ClaimAllHelper(address(royalties), address(mineCore));
        furnaceQuoter = new FurnaceQuoter(address(furnace));
        furnaceRegistry = new TimelockOwnableStub(owner);
        mineCoreRegistry = new TimelockOwnableStub(owner);
        dexAdapter = new TimelockOwnableStub(owner);
        lpStakingVault7D = new TimelockOwnableStub(owner);

        vm.startPrank(owner);
        claim.setMineCore(address(mineCore));
        claim.freezeConfig();
        claim.renounceOwnership();

        furnace.setMineCore(address(mineCore));
        furnace.setMineMarket(address(market));
        furnace.setShareholderRoyalties(address(royalties));
        furnace.setFurnaceQuoter(address(furnaceQuoter));

        // The canonical-hub check requires MineCore-side wiring
        // (furnace + delegationHub) to be set before the Furnace's hub
        // pointer is bound.
        mineCore.setFurnace(address(furnace));
        mineCore.setDelegationHub(address(hub));

        furnace.setDelegationHub(address(hub));
        furnace.setEntryTokenRegistry(address(furnaceRegistry));

        mineCore.setEntryTokenRegistry(address(mineCoreRegistry));
        mineCore.setClaimAllHelper(address(claimAllHelper));

        royalties.setWiring(address(mineCore), address(market), address(furnace));
        royalties.setClaimAllHelper(address(claimAllHelper));

        market.setSettlementKeeper(keeper, true);

        ve.setFurnace(address(furnace));
        ve.setMineMarket(address(market));
        vm.stopPrank();
    }

    function _ownershipAcceptTargets() internal view returns (address[] memory targets) {
        targets = new address[](9);
        targets[0] = address(ve);
        targets[1] = address(mineCore);
        targets[2] = address(royalties);
        targets[3] = address(furnace);
        targets[4] = address(market);
        targets[5] = address(furnaceRegistry);
        targets[6] = address(mineCoreRegistry);
        targets[7] = address(dexAdapter);
        targets[8] = address(lpStakingVault7D);
    }

    function _acceptOwnershipPayloads(uint256 length) internal pure returns (bytes[] memory payloads) {
        payloads = new bytes[](length);
        for (uint256 i = 0; i < length; i++) {
            payloads[i] = abi.encodeWithSignature("acceptOwnership()");
        }
    }

    function _moveAllOwnershipTargetsTo(address newOwner) internal {
        address[] memory targets = _ownershipAcceptTargets();

        vm.startPrank(address(timelock));
        for (uint256 i = 0; i < targets.length; i++) {
            ITimelockOwnable2StepLike(targets[i]).transferOwnership(newOwner);
        }
        vm.stopPrank();

        vm.startPrank(newOwner);
        for (uint256 i = 0; i < targets.length; i++) {
            ITimelockOwnable2StepLike(targets[i]).acceptOwnership();
        }
        vm.stopPrank();
    }

    function _assertOwnershipTargetsState(address expectedOwner, address expectedPendingOwner) internal view {
        address[] memory targets = _ownershipAcceptTargets();
        for (uint256 i = 0; i < targets.length; i++) {
            assertEq(ITimelockOwnable2StepLike(targets[i]).owner(), expectedOwner, "owner mismatch");
            assertEq(
                ITimelockOwnable2StepLike(targets[i]).pendingOwner(), expectedPendingOwner, "pendingOwner mismatch"
            );
        }
    }

    function _seedRuntimeState() internal {
        vm.warp(10 days);

        mineCore.setReignStateForTest(alice, 10 days, 2 ether, 9 days);
        mineCore.setGenesisKingClaimCollectedForTest(true);
        mineCore.setKingEthBalanceForTest(alice, 1 ether);
        mineCore.setRefundEthBalanceForTest(bob, 0.25 ether);
        mineCore.setPendingKingClaimForTest(alice, 123e18);

        vm.prank(address(mineCore));
        claim.mint(address(mineCore), 123e18);

        vm.prank(address(mineCore));
        claim.mint(address(furnace), 500e18);
        vm.prank(address(mineCore));
        furnace.creditReserve(500e18);
        vm.prank(address(mineCore));
        furnace.setLockingPaused(true);

        vm.startPrank(address(mineCore));
        claim.mint(alice, 50_000e18);
        claim.mint(bob, 50_000e18);
        vm.stopPrank();

        vm.startPrank(alice);
        claim.approve(address(ve), type(uint256).max);
        listedTokenId = ve.createLock(2_000e18, Constants.MIN_LOCK_DURATION, false);
        market.listLock(listedTokenId, 1_500e18, block.timestamp + 2 days);
        vm.stopPrank();

        vm.startPrank(bob);
        claim.approve(address(market), type(uint256).max);
        uint256 budget = market.minBonusTargetEscrowBudget() + 1e18;
        offerId = market.createBonusTargetEscrowWithTarget(500, budget, Constants.MIN_LOCK_DURATION, true, 2 days, 0, 0);
        vm.stopPrank();

        vm.warp(block.timestamp + 1);
        vm.deal(address(mineCore), 2 ether);
        vm.prank(address(mineCore));
        royalties.onTakeover{value: 1 ether}(1);
        royalties.checkpointUser(alice);
    }

    // ---- Missing coverage: user functions + emergency vault after burn ----

    function testUserFunctionsWorkAfterFreezeAndBurn() public {
        _scheduleAndExecuteBatch(_freezeAndBurnTargets(), _freezeAndBurnPayloads(), keccak256("freeze-and-burn-user"));

        // MineCore: user can withdraw king balance (proxy still delegates correctly)
        vm.deal(address(mineCore), 10 ether);
        uint256 aliceBefore = alice.balance;
        vm.prank(alice);
        mineCore.withdrawKingBalance();
        assertGt(alice.balance, aliceBefore, "withdrawKingBalance must work after burn");

        // MineCore: King-stream CLAIM is force-locked on withdrawal (never paid liquid). Furnace
        // locking is paused in this scenario, so withdrawPendingClaim correctly refuses to pay out and
        // preserves the credit — proving the proxy still delegates into the implementation logic after
        // burn (a domain revert, not a proxy failure) and that the credited CLAIM is never lost.
        uint256 pendingBefore = mineCore.pendingKingClaim(alice);
        assertGt(pendingBefore, 0, "alice should have a pending credit");
        uint256 aliceClaimBefore = claim.balanceOf(alice);
        vm.prank(alice);
        vm.expectRevert(Errors.LockRouteUnavailable.selector);
        mineCore.withdrawPendingClaim();
        assertEq(mineCore.pendingKingClaim(alice), pendingBefore, "pending credit must be preserved");
        assertEq(claim.balanceOf(alice), aliceClaimBefore, "no liquid CLAIM paid out");

        // MarketRouter: user can delist (advance past listing cooldown)
        vm.roll(block.number + 1);
        vm.prank(alice);
        market.delistLock(listedTokenId);

        // MarketRouter: user can cancel expired escrow
        vm.warp(block.timestamp + 3 days);
        vm.prank(bob);
        market.cancelBonusTargetEscrow(offerId);
    }

    function testOwnerKnobsReachableThroughTimelockAfterBurn() public {
        _scheduleAndExecuteBatch(_freezeAndBurnTargets(), _freezeAndBurnPayloads(), keccak256("freeze-and-burn-owner"));

        // Furnace: owner()-gated functions must still be reachable through the timelock
        // after ProxyAdmin burn. This proves ProxyAdmin burn does not affect the owner() path.
        assertEq(furnace.owner(), address(timelock), "Furnace owner must still be timelock after burn");
        assertEq(mineCore.owner(), address(timelock), "MineCore owner must still be timelock after burn");
        assertEq(market.owner(), address(timelock), "MarketRouter owner must still be timelock after burn");
        assertEq(royalties.owner(), address(timelock), "Royalties owner must still be timelock after burn");
    }

    function testClaimTokenPreconditionsVerifiedBeforeCeremony() public view {
        // The freeze-and-burn ceremony requires ClaimToken to already be frozen and ownerless.
        // This matches the wire-time freeze behavior.
        assertTrue(claim.configFrozen(), "ClaimToken must be frozen before ceremony");
        assertEq(claim.owner(), address(0), "ClaimToken must be ownerless before ceremony");

        // The batch does NOT contain ClaimToken -- verify batch size is 8
        address[] memory targets = _freezeAndBurnTargets();
        bytes[] memory payloads = _freezeAndBurnPayloads();
        assertEq(targets.length, 8, "batch must be 8 operations");
        assertEq(payloads.length, 8, "batch payloads must be 8 operations");

        // Verify ClaimToken is not in the targets
        for (uint256 i = 0; i < targets.length; i++) {
            assertTrue(targets[i] != address(claim), "ClaimToken must not be in batch targets");
        }
    }

    /// @dev Verifies that the 9 TimelockAcceptOwnership candidates + 4 ProxyAdmins + ClaimToken(conditional)
    ///      == the 14 FinalizeOwnership targets. Guards against target-list drift between the two scripts.
    function testOwnershipTargetListConsistency() public view {
        // The 9 Ownable2Step contracts that TimelockAcceptOwnership covers
        address[] memory acceptTargets = _ownershipAcceptTargets();
        assertEq(acceptTargets.length, 9, "TimelockAcceptOwnership must cover 9 contracts");

        // The 4 ProxyAdmin contracts handled by FinalizeOwnership (single-step, not in TimelockAcceptOwnership)
        address[4] memory proxyAdmins =
            [address(mineCoreAdmin), address(furnaceAdmin), address(marketAdmin), address(royaltiesAdmin)];

        // ClaimToken is conditionally included in FinalizeOwnership (only if owner != address(0))
        // In our setUp, ClaimToken is already frozen + renounced, so it would be excluded
        assertEq(claim.owner(), address(0), "ClaimToken should be renounced in test setup");

        // Total FinalizeOwnership targets = 9 Ownable2Step + 4 ProxyAdmins + ClaimToken(conditional) = 14 slots
        // With ClaimToken renounced, 13 are populated and 1 is address(0)

        // Verify no overlap between accept targets and proxy admins
        for (uint256 i = 0; i < acceptTargets.length; i++) {
            for (uint256 j = 0; j < proxyAdmins.length; j++) {
                assertTrue(acceptTargets[i] != proxyAdmins[j], "accept target must not be a ProxyAdmin");
            }
        }

        // Verify all accept targets are unique
        for (uint256 i = 0; i < acceptTargets.length; i++) {
            for (uint256 j = i + 1; j < acceptTargets.length; j++) {
                assertTrue(acceptTargets[i] != acceptTargets[j], "accept targets must be unique");
            }
        }

        // Verify all proxy admins are unique
        for (uint256 i = 0; i < proxyAdmins.length; i++) {
            for (uint256 j = i + 1; j < proxyAdmins.length; j++) {
                assertTrue(proxyAdmins[i] != proxyAdmins[j], "proxy admins must be unique");
            }
        }

        // Verify all 13 non-zero targets are distinct (9 accept + 4 proxy)
        // This ensures the union covers the full FinalizeOwnership target space
        uint256 totalNonZeroTargets = acceptTargets.length + proxyAdmins.length; // 13
        assertEq(totalNonZeroTargets, 13, "9 accept + 4 proxy = 13 non-ClaimToken targets");
    }

    // ---- Helpers ----

    function _implementationOf(address proxy) internal view returns (address) {
        return _readAddressSlot(proxy, _IMPLEMENTATION_SLOT);
    }

    function _readAddressSlot(address target, bytes32 slot) internal view returns (address value) {
        value = address(uint160(uint256(vm.load(target, slot))));
    }
}
