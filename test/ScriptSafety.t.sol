//
//   The test file provides comprehensive coverage of script safety including:
//   - Preflight simulation rollback (DeployLocal, DeployLocalDexHarness)
//   - Wire preflight with full mock bundle
//   - ClaimToken config freeze (matches the wire-time finalization path in Wire.s.sol)
//   - FinalizeGenesis stub-based flow testing
//   - FinalizeOwnership initiate/accept with postcondition validation
//   - FinalizeOwnership noop-transfer detection
//   - FinalizeOwnership reverting-transfer detection
//   - ConfigureLocalPathB and SmokeLocalPathB preflight testing
//
// SPDX-License-Identifier: MIT
pragma solidity ^0.8.34;

import {Test} from "forge-std/Test.sol";
import {VmSafe} from "forge-std/Vm.sol";
import {
    TransparentUpgradeableProxy
} from "lib/openzeppelin-contracts/contracts/proxy/transparent/TransparentUpgradeableProxy.sol";

import {ConfigureLocalPathB} from "../script/ConfigureLocalPathB.s.sol";
import {Deploy} from "../script/Deploy.s.sol";
import {DeployLocal} from "../script/DeployLocal.s.sol";
import {DeployLocalDexHarness} from "../script/DeployLocalDexHarness.s.sol";
import {DeployLocalExtras} from "../script/DeployLocalExtras.s.sol";
import {DeployAgentLens} from "../script/DeployAgentLens.s.sol";
import {DeployMaintenanceHub} from "../script/DeployMaintenanceHub.s.sol";
import {DeployMineCoreQuoter} from "../script/DeployMineCoreQuoter.s.sol";
import {FinalizeOwnership} from "../script/FinalizeOwnership.s.sol";
import {SmokeLocalPathB} from "../script/SmokeLocalPathB.s.sol";
import {FinalizeGenesis} from "../script/FinalizeGenesis.s.sol";
import {BroadcastSignerBase} from "../script/lib/BroadcastSignerBase.sol";
import {LocalWETH} from "../src/mocks/LocalWETH.sol";
import {FinalizeLocalGenesis} from "../script/FinalizeLocalGenesis.s.sol";
import {Wire} from "../script/Wire.s.sol";

import {ClaimAllHelper} from "../src/ClaimAllHelper.sol";
import {ClaimToken} from "../src/ClaimToken.sol";
import {DelegationHub} from "../src/DelegationHub.sol";
import {EntryTokenRegistry} from "../src/EntryTokenRegistry.sol";
import {Errors} from "../src/lib/Errors.sol";
import {Furnace} from "../src/Furnace.sol";
import {FurnaceGuardHelper} from "../src/FurnaceGuardHelper.sol";

import {MaintenanceHub} from "../src/MaintenanceHub.sol";
import {MarketRouter} from "../src/MarketRouter.sol";
import {MineCore} from "../src/MineCore.sol";
import {ShareholderRoyalties} from "../src/ShareholderRoyalties.sol";

import {VeClaimNFTHarness} from "./mocks/VeClaimNFTHarness.sol";

contract _FinalizeGenesisLaunchControllerStub {
    address public guardian;
    bool public finalized;

    constructor(address _guardian) {
        guardian = _guardian;
    }

    function genesisFinalized() external view returns (bool) {
        return finalized;
    }

    function finalizeGenesis() external payable {
        require(msg.sender == guardian, "not guardian");
        finalized = true;
    }
}

contract _FinalizeGenesisMineCoreStub {
    address public owner;
    address public guardian;
    bool public takeoversPaused = true;
    uint256 public GENESIS_ACCRUAL_DURATION = 10 days;

    constructor(address _owner, address _guardian) {
        owner = _owner;
        guardian = _guardian;
    }

    function setGuardian(address _guardian) external {
        guardian = _guardian;
    }
}

contract _FinalizeGenesisLpVaultStub {
    function lockStartTime() external pure returns (uint256) {
        return 0;
    }

    function lpLockedAmount() external pure returns (uint256) {
        return 0;
    }
}

contract _CodeStub {
    function ping() external pure returns (bool) {
        return true;
    }
}

contract _DeployDexRootStub {
    address public factory;
    address public wrappedNative;
    address public pool;

    constructor(address _factory, address _wrappedNative, address _pool) {
        factory = _factory;
        wrappedNative = _wrappedNative;
        pool = _pool;
    }

    function aerodromeRouter() external view returns (address) {
        return address(this);
    }

    function defaultFactory() external view returns (address) {
        return factory;
    }

    function weth() external view returns (address) {
        return wrappedNative;
    }

    function poolFor(address, address, bool, address) external view returns (address) {
        return pool;
    }
}

contract _CanonicalGenesisGuardianStub {
    address public mineCore;
    address public claim;

    constructor(address _mineCore, address _claim) {
        mineCore = _mineCore;
        claim = _claim;
    }
}

contract _ScriptSafetyMarker {
    bool public touched;

    function touch() external {
        touched = true;
    }
}

contract _DeployLocalHarness is DeployLocal {
    _ScriptSafetyMarker internal immutable marker;

    constructor(_ScriptSafetyMarker _marker) {
        marker = _marker;
    }

    function preflight(address initialOwner) external {
        _preflightDeploySequence(initialOwner);
    }

    function _executeDeploySequence(address initialOwner) internal override {
        super._executeDeploySequence(initialOwner);
        marker.touch();
        revert("stub late deploy revert");
    }
}

contract _DeployHarness is Deploy {
    function loadConfigDelay() external returns (uint256 delay) {
        DeployConfig memory cfg = _loadConfig();
        delay = cfg.timelockDelaySeconds;
    }
}

contract _DeployLocalDexHarnessHarness is DeployLocalDexHarness {
    _ScriptSafetyMarker internal immutable marker;

    constructor(_ScriptSafetyMarker _marker) {
        marker = _marker;
    }

    function preflight(address deployer, address claimToken) external {
        _preflightDeploySequence(deployer, claimToken);
    }

    function _executeDeploySequence(address deployer, address claimToken) internal override {
        super._executeDeploySequence(deployer, claimToken);
        marker.touch();
        revert("stub late dex revert");
    }
}

contract _WireHarness is Wire {
    function preflight(
        Addrs memory a,
        address broadcaster,
        address guardian,
        bool isLocal,
        bool launchControllerLive,
        bool genesisFinalized
    ) external {
        _preflightWireSequence(a, broadcaster, guardian, isLocal, launchControllerLive, genesisFinalized);
    }

    function execute(
        Addrs memory a,
        address broadcaster,
        address guardian,
        bool isLocal,
        bool launchControllerLive,
        bool genesisFinalized
    ) external {
        require(msg.sender == broadcaster, "not broadcaster");
        vm.stopPrank();
        vm.startPrank(broadcaster);
        _executeWire(a, broadcaster, guardian, isLocal, launchControllerLive, genesisFinalized);
        vm.stopPrank();
    }
}

contract _ConfigureLocalPathBHarness is ConfigureLocalPathB {
    function preflight(
        address furnaceReg,
        address mineReg,
        address dexAdapter,
        address poolFactory,
        address wrappedNative,
        address claimToken,
        address claimWethPool,
        address entryToken,
        address entryWethPool,
        address entryClaimPool,
        address broadcaster
    ) external {
        LocalPathBConfig memory cfg = LocalPathBConfig({
            furnaceReg: furnaceReg,
            mineReg: mineReg,
            dexAdapter: dexAdapter,
            poolFactory: poolFactory,
            wrappedNative: wrappedNative,
            claimToken: claimToken,
            claimWethPool: claimWethPool,
            entryToken: entryToken,
            entryWethPool: entryWethPool,
            entryClaimPool: entryClaimPool
        });
        _preflightConfigureSequence(cfg, broadcaster);
    }
}

contract _SmokeLocalPathBHarness is SmokeLocalPathB {
    function preflight(address payable mineCore, address payable furnace, address payable weth, address broadcaster)
        external
    {
        _preflightSmokeSequence(mineCore, furnace, weth, broadcaster);
    }
}

contract _SmokeLocalPathBFurnaceStub {
    bool public entered;

    function enterWithToken(address, uint256, uint256, uint256, bool, uint256) external returns (uint256 tokenIdUsed) {
        entered = true;
        tokenIdUsed = 1;
    }
}

contract _SmokeLocalPathBMineCoreStub {
    uint256 public price;
    address public king;
    bool public revertOnTakeover;
    bool public takeoverCalled;

    constructor(uint256 _price, address _king, bool _revertOnTakeover) {
        price = _price;
        king = _king;
        revertOnTakeover = _revertOnTakeover;
    }

    function getCurrentTakeoverPrice() external view returns (uint256) {
        return price;
    }

    function currentKing() external view returns (address) {
        return king;
    }

    function takeover(uint256) external payable {
        takeoverCalled = true;
        if (revertOnTakeover) revert("stub takeover revert");
        king = msg.sender;
    }
}

contract _ConfigureLocalPathBRegistryStub {
    address public owner;
    bool public routerConfigured;
    address public wethClaimHop;
    address public lastTokenConfigPool;
    address public lastSafetyToken;
    bool public lastExactReceiptSafe;
    bool public revertOnTokenConfig;

    constructor(address _owner, bool _revertOnTokenConfig) {
        owner = _owner;
        revertOnTokenConfig = _revertOnTokenConfig;
    }

    function setRouterConfig(address, address, address, address) external {
        require(msg.sender == owner, "not owner");
        routerConfigured = true;
    }

    function getWethClaimHop() external view returns (bool, address) {
        return (false, wethClaimHop);
    }

    function setWethClaimHop(bool, address expectedPool) external {
        require(msg.sender == owner, "not owner");
        wethClaimHop = expectedPool;
    }

    function setTokenConfig(
        address,
        bool,
        bool directToClaimEnabled,
        bool,
        address tokenClaimPool,
        bool,
        address tokenWethPool
    ) external {
        require(msg.sender == owner, "not owner");
        if (revertOnTokenConfig) revert("stub token config revert");
        lastTokenConfigPool = directToClaimEnabled ? tokenClaimPool : tokenWethPool;
    }

    function setFurnaceEntryTokenExactReceiptSafe(address tokenIn, bool exactReceiptSafe) external {
        require(msg.sender == owner, "not owner");
        lastSafetyToken = tokenIn;
        lastExactReceiptSafe = exactReceiptSafe;
    }
}

contract _FinalizeOwnershipLaunchControllerStub {
    bool public finalized;

    constructor(bool _finalized) {
        finalized = _finalized;
    }

    function genesisFinalized() external view returns (bool) {
        return finalized;
    }
}

contract _FinalizeOwnershipOwnableStub {
    address public owner;
    address public pendingOwner;

    constructor(address _owner) {
        owner = _owner;
    }

    function transferOwnership(address newOwner) external virtual {
        require(msg.sender == owner, "not owner");
        pendingOwner = newOwner;
    }

    function acceptOwnership() external {
        require(msg.sender == pendingOwner, "not pending owner");
        owner = pendingOwner;
        pendingOwner = address(0);
    }
}

/// @dev Models any freezable contract for FinalizeOwnership freeze checks.
contract _FinalizeOwnershipClaimTokenStub is _FinalizeOwnershipOwnableStub {
    bool public frozen;

    constructor(address _owner, bool _frozen) _FinalizeOwnershipOwnableStub(_owner) {
        frozen = _frozen;
    }

    function configFrozen() external view returns (bool) {
        return frozen;
    }
}

contract _FinalizeOwnershipRevertingStub is _FinalizeOwnershipOwnableStub {
    constructor(address _owner) _FinalizeOwnershipOwnableStub(_owner) {}

    function transferOwnership(address) external pure override {
        revert("stub transfer revert");
    }
}

contract _FinalizeOwnershipNoopTransferStub is _FinalizeOwnershipOwnableStub {
    constructor(address _owner) _FinalizeOwnershipOwnableStub(_owner) {}

    function transferOwnership(address) external override {
        require(msg.sender == owner, "not owner");
        // Intentionally do nothing so FinalizeOwnership's postcondition catches it.
    }
}

contract _FinalizeOwnershipMineCoreStub is _FinalizeOwnershipOwnableStub {
    address public guardian;

    constructor(address _owner, address _guardian) _FinalizeOwnershipOwnableStub(_owner) {
        guardian = _guardian;
    }
}

contract _FinalizeOwnershipMineCoreFreezableStub is _FinalizeOwnershipMineCoreStub {
    bool public frozen;

    constructor(address _owner, address _guardian) _FinalizeOwnershipMineCoreStub(_owner, _guardian) {}

    function configFrozen() external view returns (bool) {
        return frozen;
    }
}

contract _FinalizeOwnershipTimelockStub {
    mapping(bytes32 => mapping(address => bool)) internal _roles;

    constructor(address bootstrapAdmin, bool bootstrapAdminActive) {
        _roles[bytes32(0)][address(this)] = true;
        if (bootstrapAdminActive) {
            _roles[bytes32(0)][bootstrapAdmin] = true;
        }
    }

    function hasRole(bytes32 role, address account) external view returns (bool) {
        return _roles[role][account];
    }
}

contract _FinalizeOwnershipProxyMineCoreImpl {
    address public owner;
    address public pendingOwner;
    address public guardian;
    bool public frozen;
    bool internal _initialized;

    function initialize(address _owner, address _guardian, bool _frozen) external {
        require(!_initialized, "already initialized");
        _initialized = true;
        owner = _owner;
        guardian = _guardian;
        frozen = _frozen;
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

    function configFrozen() external view returns (bool) {
        return frozen;
    }
}

contract _BroadcastSignerHarness is BroadcastSignerBase {
    function resolve() external returns (address account, uint256 privateKey, bool usePrivateKey) {
        BroadcastSigner memory signer = _resolveBroadcastSigner();
        return (signer.account, signer.privateKey, signer.usePrivateKey);
    }
}

contract ScriptSafetyTest is Test {
    bytes32 internal constant _FINALIZE_OWNERSHIP_ADMIN_SLOT =
        0xb53127684a568b3173ae13b9f8a6016e243e63b6e8ee1178d6a717850b5d6103;

    struct AgentLensRequiredBundle {
        ClaimToken claimToken;
        VeClaimNFTHarness veClaimNFT;
        MineCore mineCore;
        ShareholderRoyalties shareholderRoyalties;
        Furnace furnace;
        MarketRouter marketRouter;
        address owner;
    }

    struct WireMaintenanceHubBundle {
        ClaimToken claimToken;
        VeClaimNFTHarness veClaimNFT;
        MineCore mineCore;
        ShareholderRoyalties shareholderRoyalties;
        Furnace furnace;
        MarketRouter marketRouter;
        EntryTokenRegistry furnaceEntryTokenRegistry;
        EntryTokenRegistry mineCoreEntryTokenRegistry;
        ClaimAllHelper claimAllHelper;
        DelegationHub delegationHub;
        MaintenanceHub maintenanceHub;
    }

    function setUp() public {
        _clearScriptEnv();
    }

    function _clearScriptEnv() internal {
        _clearCallerMode();

        vm.setEnv("CLAIM_TOKEN", "");
        vm.setEnv("VECLAIM_NFT", "");
        vm.setEnv("MINE_CORE", "");
        vm.setEnv("SHAREHOLDER_ROYALTIES", "");
        vm.setEnv("FURNACE", "");
        vm.setEnv("MARKET_ROUTER", "");
        vm.setEnv("LP_STAKING_VAULT_7D", "");
        vm.setEnv("DEX_ADAPTER", "");
        vm.setEnv("FURNACE_ENTRY_TOKEN_REGISTRY", "");
        vm.setEnv("MINE_CORE_ENTRY_TOKEN_REGISTRY", "");
        vm.setEnv("DELEGATION_HUB", "");
        vm.setEnv("CLAIM_ALL_HELPER", "");
        vm.setEnv("MAINTENANCE_HUB", "");
        vm.setEnv("LAUNCH_CONTROLLER", "");
        vm.setEnv("GENESIS_LP_VAULT_24M", "");
        vm.setEnv("WETH", "");
        vm.setEnv("AERODROME_ROUTER", "");
        vm.setEnv("ADMIN_SAFE", "");
        vm.setEnv("INITIAL_OWNER", "");
        vm.setEnv("TIMELOCK_DELAY_SECONDS", "");
        vm.setEnv("NEW_OWNER", "");
        vm.setEnv("GUARDIAN", "");
        vm.setEnv("SHAREHOLDER_COMPOUND_KEEPER", "");
        vm.setEnv("VE_CLAIM_BASE_URI", "");
        vm.setEnv("VE_CLAIM_CONTRACT_URI", "");
        vm.setEnv("SETTLEMENT_KEEPER", "");
        vm.setEnv("HARVEST_KEEPER", "");
        vm.setEnv("LP_WITHDRAW_RECIPIENT", "");
        vm.setEnv("LOCAL_LP_WITHDRAW_RECIPIENT", "");
        vm.setEnv("LOCAL_CLAIM_TOKEN", "");
        vm.setEnv("LOCAL_VECLAIM_NFT", "");
        vm.setEnv("LOCAL_MINE_CORE", "");
        vm.setEnv("LOCAL_SHAREHOLDER_ROYALTIES", "");
        vm.setEnv("LOCAL_FURNACE", "");
        vm.setEnv("LOCAL_MARKET_ROUTER", "");
        vm.setEnv("LOCAL_DEX_ADAPTER", "");
        vm.setEnv("LOCAL_WETH", "");
        vm.setEnv("LOCAL_CLAIM_WETH_POOL", "");
        vm.setEnv("LOCAL_AERODROME_ROUTER", "");
        vm.setEnv("LOCAL_AERODROME_FACTORY", "");
        vm.setEnv("LOCAL_GENESIS_BURN_GUARDIAN", "");
        vm.setEnv("OWNERSHIP_CLAIM_TOKEN", "");
        vm.setEnv("OWNERSHIP_TIMELOCK", "");
        vm.setEnv("OWNERSHIP_TIMELOCK_BOOTSTRAP_ADMIN", "");
        vm.setEnv("OWNERSHIP_VE", "");
        vm.setEnv("OWNERSHIP_MINE_CORE", "");
        vm.setEnv("OWNERSHIP_MINE_CORE_PROXY_ADMIN", "");
        vm.setEnv("OWNERSHIP_ROYALTIES", "");
        vm.setEnv("OWNERSHIP_ROYALTIES_PROXY_ADMIN", "");
        vm.setEnv("OWNERSHIP_FURNACE", "");
        vm.setEnv("OWNERSHIP_FURNACE_PROXY_ADMIN", "");
        vm.setEnv("OWNERSHIP_MARKET_ROUTER", "");
        vm.setEnv("OWNERSHIP_MARKET_ROUTER_PROXY_ADMIN", "");
        vm.setEnv("OWNERSHIP_FURNACE_ENTRY_TOKEN_REGISTRY", "");
        vm.setEnv("OWNERSHIP_MINECORE_ENTRY_TOKEN_REGISTRY", "");
        vm.setEnv("OWNERSHIP_DEX_ADAPTER", "");
        vm.setEnv("OWNERSHIP_LP_STAKING_VAULT", "");
        vm.setEnv("OWNERSHIP_LAUNCH_CONTROLLER", "");
        vm.setEnv("OWNERSHIP_ACTION", "initiate");
        vm.setEnv("OWNERSHIP_ADDRS_FROM_ENV", "false");
        vm.setEnv("ALLOW_NON_DEPLOYER_INITIAL_OWNER", "false");
        vm.setEnv("ALLOW_UNSAFE_MAINNET_TIMELOCK_DELAY", "false");
        vm.setEnv("ALLOW_DEPLOYER_LP_RECIPIENT", "false");
        vm.setEnv("ALLOW_MAINTENANCE_HUB_SETTLEMENT_KEEPER", "false");
        vm.setEnv("ALLOW_MAINTENANCE_HUB_HARVEST_KEEPER", "false");
        vm.setEnv("ALLOW_UNSAFE_PRE_FINAL_HANDOFF", "false");
        vm.setEnv("ALLOW_NON_CANONICAL_ADMIN_SAFE", "false");
        vm.setEnv("ALLOW_NON_CANONICAL_LP_WITHDRAW_RECIPIENT", "false");
        vm.setEnv("TIMELOCK_CALLER", "");
        vm.setEnv("TIMELOCK_ACTION", "");
        vm.setEnv("TIMELOCK_SALT", "");
        vm.setEnv("DEPLOYMENTS_MANIFEST_JSON", "");
        vm.setEnv("PRIVATE_KEY", "0");
        vm.setEnv("LOCAL_PRIVATE_KEY", "0");
        vm.setEnv("LEDGER_ADDRESS", "");
        vm.setEnv("SIGNER_ADDRESS", "");
    }

    function _clearCallerMode() internal {
        vm.stopPrank();

        (VmSafe.CallerMode callerMode,,) = vm.readCallers();
        if (callerMode == VmSafe.CallerMode.Broadcast || callerMode == VmSafe.CallerMode.RecurrentBroadcast) {
            vm.stopBroadcast();
        }
    }

    function _pkEnv(uint256 pk) internal view returns (string memory) {
        return vm.toString(bytes32(pk));
    }

    function _proxyAdminOf(address proxy) internal view returns (address) {
        return address(uint160(uint256(vm.load(proxy, _FINALIZE_OWNERSHIP_ADMIN_SLOT))));
    }

    function _runEnvCase(function() internal fn) internal {
        _clearCallerMode();
        _clearScriptEnv();
        fn();
        _clearCallerMode();
        _clearScriptEnv();
        _clearCallerMode();
        _clearScriptEnv();
    }

    function _runAllEnvDrivenScriptCases() internal {
        _runEnvCase(_testDeployLocalDexHarnessRejectsNonContractClaimToken);
        _runEnvCase(_testDeployPreflightRejectsNonContractDexRootsBeforeLiveBroadcast);
        _runEnvCase(_testDeployRejectsUnsafeMainnetTimelockDelayOverride);
        _runEnvCase(_testDeployAllowsUnsafeMainnetTimelockDelayOverrideWithExplicitAck);
        _runEnvCase(_testDeployLocalExtrasRejectsNonContractClaimWethPool);
        _runEnvCase(_testDeployLocalExtrasRejectsGuardianOverrideDifferentFromDeployer);
        _runEnvCase(_testDeployLocalExtrasRejectsDexAdapterWrappedNativeMismatch);
        _runEnvCase(_testDeployLocalExtrasRejectsRouterWrappedNativeMismatch);
        _runEnvCase(_testDeployMaintenanceHubReadsManifestByDefault);
        _runEnvCase(_testDeployMaintenanceHubRejectsManifestEnvDrift);
        _runEnvCase(_testDeployMineCoreQuoterReadsManifestByDefault);
        _runEnvCase(_testDeployMineCoreQuoterRejectsManifestEnvDrift);
        _runEnvCase(_testFinalizeOwnershipRejectsInvalidAction);
        _runEnvCase(_testFinalizeOwnershipRejectsInitiateBeforeGenesisFinalized);
        _runEnvCase(_testFinalizeOwnershipPreflightPreventsPartialInitiateState);
        _runEnvCase(_testFinalizeOwnershipRejectsEmptyEnvTargetSet);
        _runEnvCase(_testFinalizeOwnershipRejectsSelfHandoff);
        _runEnvCase(_testFinalizeOwnershipRejectsManifestOwnerDrift);
        _runEnvCase(_testFinalizeOwnershipRejectsManifestPendingOwnerDrift);
        _runEnvCase(_testFinalizeOwnershipRejectsManifestAcceptStateDrift);
        _runEnvCase(_testFinalizeOwnershipRejectsManifestMissingTarget);
        _runEnvCase(_testFinalizeOwnershipRejectsNoOpTransferTarget);
        _runEnvCase(_testFinalizeOwnershipAllowsCanonicalPreFreezeHandoffAfterClaimTokenFinalized);
        _runEnvCase(_testFinalizeOwnershipRejectsCanonicalHandoffToNonTimelockOwner);
        _runEnvCase(_testFinalizeOwnershipRejectsCanonicalHandoffWithoutBootstrapAdminMetadata);
        _runEnvCase(_testFinalizeOwnershipRejectsCanonicalHandoffBeforeTimelockBootstrapFinalized);
        _runEnvCase(_testFinalizeOwnershipResolvesLiveProxyAdminWhenEnvMetadataMissing);
        _runEnvCase(_testFinalizeOwnershipRejectsProxyAdminMetadataDrift);
        _runEnvCase(_testFinalizeOwnershipRejectsInitiateBeforeClaimTokenFinalized);
        _runEnvCase(_testFinalizeOwnershipRejectsInitiateBeforeClaimTokenOwnerRenounced);
        _runEnvCase(_testBroadcastSignerUsesLedgerAddressOnMainnet);
        _runEnvCase(_testBroadcastSignerRejectsExplicitSignerPrivateKeyMismatch);
        _runEnvCase(_testFinalizeGenesisRevertsIfPrivateKeyDoesNotControlMineCoreOwner);
        _runEnvCase(_testFinalizeLocalGenesisRevertsIfPrivateKeyDoesNotControlMineCoreOwner);
        _runEnvCase(_testFinalizeLocalGenesisRejectsGuardianEqualLaunchController);
        _runEnvCase(_testFinalizeGenesisPreflightPreventsPartialFinalization);
        _runEnvCase(_testFinalizeLocalGenesisPreflightPreventsPartialFinalization);
        _runEnvCase(_testWirePreflightRollsBackSuccessfulSimulation);
        _runEnvCase(_testWireLeavesMaintenanceHubOffSettlementKeeperByDefault);
        _runEnvCase(_testWireRevertsWhenSettlementKeeperIsMaintenanceHubWithoutOptIn);
        _runEnvCase(_testWireAllowsMaintenanceHubSettlementKeeperWhenExplicitlyOptedIn);
        _runEnvCase(_testDeployAgentLensRejectsNonContractRequiredAddress);
        _runEnvCase(_testDeployAgentLensRejectsNonContractOptionalAddress);
        _runEnvCase(_testDeployAgentLensRejectsLiveMixedMarketRouterBundle);
        _runEnvCase(_testDeployAgentLensRejectsMixedMaintenanceHubBundle);
        _runEnvCase(_testDeployAgentLensRejectsLpVaultWithoutDexAdapter);
        _runEnvCase(_testDeployAgentLensRejectsLaunchControllerWithoutGenesisVault);
    }

    function testEnvDrivenScriptCases() public {
        _runAllEnvDrivenScriptCases();
    }

    // NOTE: Individual env-case wrappers use the `envCase` prefix (not `test`)
    // to prevent Forge from auto-discovering them as test functions.  Forge runs
    // test functions within a contract in parallel, and because vm.setEnv is
    // process-wide (not per-test), parallel execution causes non-deterministic
    // env-var races.  All env cases are exercised sequentially by
    // testEnvDrivenScriptCases() above; the envCase* entry points below exist
    // solely for targeted single-case debugging via --match-test.

    function envCaseFinalizeGenesisRevertsIfPrivateKeyDoesNotControlMineCoreOwner() public {
        _runEnvCase(_testFinalizeGenesisRevertsIfPrivateKeyDoesNotControlMineCoreOwner);
    }

    function envCaseBroadcastSignerUsesLedgerAddressOnMainnet() public {
        _runEnvCase(_testBroadcastSignerUsesLedgerAddressOnMainnet);
    }

    function envCaseBroadcastSignerRejectsExplicitSignerPrivateKeyMismatch() public {
        _runEnvCase(_testBroadcastSignerRejectsExplicitSignerPrivateKeyMismatch);
    }

    function envCaseDeployLocalDexHarnessRejectsNonContractClaimToken() public {
        _runEnvCase(_testDeployLocalDexHarnessRejectsNonContractClaimToken);
    }

    function envCaseDeployPreflightRejectsNonContractDexRootsBeforeLiveBroadcast() public {
        _runEnvCase(_testDeployPreflightRejectsNonContractDexRootsBeforeLiveBroadcast);
    }

    function envCaseDeployRejectsUnsafeMainnetTimelockDelayOverride() public {
        _runEnvCase(_testDeployRejectsUnsafeMainnetTimelockDelayOverride);
    }

    function envCaseDeployAllowsUnsafeMainnetTimelockDelayOverrideWithExplicitAck() public {
        _runEnvCase(_testDeployAllowsUnsafeMainnetTimelockDelayOverrideWithExplicitAck);
    }

    function envCaseDeployLocalExtrasRejectsNonContractClaimWethPool() public {
        _runEnvCase(_testDeployLocalExtrasRejectsNonContractClaimWethPool);
    }

    function envCaseDeployLocalExtrasRejectsGuardianOverrideDifferentFromDeployer() public {
        _runEnvCase(_testDeployLocalExtrasRejectsGuardianOverrideDifferentFromDeployer);
    }

    function envCaseDeployLocalExtrasRejectsDexAdapterWrappedNativeMismatch() public {
        _runEnvCase(_testDeployLocalExtrasRejectsDexAdapterWrappedNativeMismatch);
    }

    function envCaseDeployLocalExtrasRejectsRouterWrappedNativeMismatch() public {
        _runEnvCase(_testDeployLocalExtrasRejectsRouterWrappedNativeMismatch);
    }

    function envCaseFinalizeLocalGenesisRevertsIfPrivateKeyDoesNotControlMineCoreOwner() public {
        _runEnvCase(_testFinalizeLocalGenesisRevertsIfPrivateKeyDoesNotControlMineCoreOwner);
    }

    function envCaseFinalizeGenesisPreflightPreventsPartialFinalization() public {
        _runEnvCase(_testFinalizeGenesisPreflightPreventsPartialFinalization);
    }

    function envCaseFinalizeLocalGenesisPreflightPreventsPartialFinalization() public {
        _runEnvCase(_testFinalizeLocalGenesisPreflightPreventsPartialFinalization);
    }

    function envCaseFinalizeOwnershipResolvesLiveProxyAdminWhenEnvMetadataMissing() public {
        _runEnvCase(_testFinalizeOwnershipResolvesLiveProxyAdminWhenEnvMetadataMissing);
    }

    function envCaseFinalizeOwnershipRejectsProxyAdminMetadataDrift() public {
        _runEnvCase(_testFinalizeOwnershipRejectsProxyAdminMetadataDrift);
    }

    function envCaseFinalizeOwnershipAllowsCanonicalPreFreezeHandoffAfterClaimTokenFinalized() public {
        _runEnvCase(_testFinalizeOwnershipAllowsCanonicalPreFreezeHandoffAfterClaimTokenFinalized);
    }

    function envCaseFinalizeOwnershipRejectsCanonicalHandoffToNonTimelockOwner() public {
        _runEnvCase(_testFinalizeOwnershipRejectsCanonicalHandoffToNonTimelockOwner);
    }

    function envCaseFinalizeOwnershipRejectsCanonicalHandoffWithoutBootstrapAdminMetadata() public {
        _runEnvCase(_testFinalizeOwnershipRejectsCanonicalHandoffWithoutBootstrapAdminMetadata);
    }

    function envCaseFinalizeOwnershipRejectsCanonicalHandoffBeforeTimelockBootstrapFinalized() public {
        _runEnvCase(_testFinalizeOwnershipRejectsCanonicalHandoffBeforeTimelockBootstrapFinalized);
    }

    function envCaseWirePreflightRollsBackSuccessfulSimulation() public {
        _runEnvCase(_testWirePreflightRollsBackSuccessfulSimulation);
    }

    function envCaseWireLeavesMaintenanceHubOffSettlementKeeperByDefault() public {
        _runEnvCase(_testWireLeavesMaintenanceHubOffSettlementKeeperByDefault);
    }

    function envCaseWireRevertsWhenSettlementKeeperIsMaintenanceHubWithoutOptIn() public {
        _runEnvCase(_testWireRevertsWhenSettlementKeeperIsMaintenanceHubWithoutOptIn);
    }

    function envCaseWireAllowsMaintenanceHubSettlementKeeperWhenExplicitlyOptedIn() public {
        _runEnvCase(_testWireAllowsMaintenanceHubSettlementKeeperWhenExplicitlyOptedIn);
    }

    function envCaseDeployAgentLensRejectsNonContractRequiredAddress() public {
        _runEnvCase(_testDeployAgentLensRejectsNonContractRequiredAddress);
    }

    function envCaseDeployAgentLensRejectsNonContractOptionalAddress() public {
        _runEnvCase(_testDeployAgentLensRejectsNonContractOptionalAddress);
    }

    function envCaseDeployAgentLensRejectsLiveMixedMarketRouterBundle() public {
        _runEnvCase(_testDeployAgentLensRejectsLiveMixedMarketRouterBundle);
    }

    function envCaseDeployAgentLensRejectsMixedMaintenanceHubBundle() public {
        _runEnvCase(_testDeployAgentLensRejectsMixedMaintenanceHubBundle);
    }

    function envCaseDeployAgentLensRejectsLpVaultWithoutDexAdapter() public {
        _runEnvCase(_testDeployAgentLensRejectsLpVaultWithoutDexAdapter);
    }

    function envCaseDeployAgentLensRejectsLaunchControllerWithoutGenesisVault() public {
        _runEnvCase(_testDeployAgentLensRejectsLaunchControllerWithoutGenesisVault);
    }

    function _finalizeOwnershipManifest(address[11] memory contracts_) internal view returns (string memory) {
        bytes memory out = abi.encodePacked(
            '{"contracts":{',
            '"ClaimToken":{"address":"',
            vm.toString(contracts_[0]),
            '"},"VeClaimNFT":{"address":"',
            vm.toString(contracts_[1]),
            '"},"MineCore":{"address":"',
            vm.toString(contracts_[2]),
            '"},"ShareholderRoyalties":{"address":"',
            vm.toString(contracts_[3]),
            '"},"Furnace":{"address":"',
            vm.toString(contracts_[4]),
            '"}'
        );
        out = abi.encodePacked(
            out,
            ',"MarketRouter":{"address":"',
            vm.toString(contracts_[5]),
            '"},"FurnaceEntryTokenRegistry":{"address":"',
            vm.toString(contracts_[6]),
            '"},"MineCoreEntryTokenRegistry":{"address":"',
            vm.toString(contracts_[7]),
            '"},"DexAdapter":{"address":"',
            vm.toString(contracts_[8]),
            '"}'
        );
        out = abi.encodePacked(
            out,
            ',"LpStakingVault7D":{"address":"',
            vm.toString(contracts_[9]),
            '"},"LaunchController":{"address":"',
            vm.toString(contracts_[10]),
            '"}}}'
        );
        return string(out);
    }

    function _maintenanceHubManifest(address market, address furnace, address ve, address royalties, address weth)
        internal
        view
        returns (string memory)
    {
        return string(
            abi.encodePacked(
                '{"contracts":{',
                '"MarketRouter":{"address":"',
                vm.toString(market),
                '"},"Furnace":{"address":"',
                vm.toString(furnace),
                '"},"VeClaimNFT":{"address":"',
                vm.toString(ve),
                '"},"ShareholderRoyalties":{"address":"',
                vm.toString(royalties),
                '"}},"aerodrome":{"wrappedNative":{"address":"',
                vm.toString(weth),
                '"}}}'
            )
        );
    }

    function _deployWireMaintenanceHubBundle(address owner) internal returns (WireMaintenanceHubBundle memory b) {
        b.claimToken = new ClaimToken(owner);
        b.veClaimNFT = new VeClaimNFTHarness(address(b.claimToken), owner);
        b.shareholderRoyalties = new ShareholderRoyalties(address(b.veClaimNFT), owner);
        b.furnace = new Furnace(
            address(b.claimToken),
            address(b.veClaimNFT),
            address(new FurnaceGuardHelper(address(b.claimToken), address(b.veClaimNFT))),
            owner
        );
        b.marketRouter =
            new MarketRouter(address(b.claimToken), address(b.veClaimNFT), address(b.shareholderRoyalties), owner);
        b.mineCore = new MineCore(address(b.claimToken), address(b.veClaimNFT), address(b.shareholderRoyalties), owner);
        b.furnaceEntryTokenRegistry = new EntryTokenRegistry(owner);
        b.mineCoreEntryTokenRegistry = new EntryTokenRegistry(owner);
        b.claimAllHelper = new ClaimAllHelper(address(b.shareholderRoyalties), address(b.mineCore));
        b.delegationHub = new DelegationHub();

        vm.startPrank(owner);
        b.claimToken.setMineCore(address(b.mineCore));
        b.furnace.setMineCore(address(b.mineCore));
        b.furnace.setMineMarket(address(b.marketRouter));
        b.furnace.setShareholderRoyalties(address(b.shareholderRoyalties));
        b.mineCore.setFurnace(address(b.furnace));
        b.shareholderRoyalties.setWiring(address(b.mineCore), address(b.marketRouter), address(b.furnace));
        b.veClaimNFT.setFurnace(address(b.furnace));
        b.veClaimNFT.setMineMarket(address(b.marketRouter));
        vm.stopPrank();

        LocalWETH weth = new LocalWETH();
        b.maintenanceHub = new MaintenanceHub(
            address(b.marketRouter),
            address(b.furnace),
            address(b.veClaimNFT),
            address(b.shareholderRoyalties),
            address(weth),
            address(0xDE5C0E)
        );
    }

    function _wireAddrsFromBundle(WireMaintenanceHubBundle memory b) internal pure returns (Wire.Addrs memory addrs) {
        addrs.claimToken = address(b.claimToken);
        addrs.ve = address(b.veClaimNFT);
        addrs.royalties = address(b.shareholderRoyalties);
        addrs.furnace = address(b.furnace);
        addrs.marketRouter = address(b.marketRouter);
        addrs.mineCore = address(b.mineCore);
        addrs.furnaceEntryTokenRegistry = address(b.furnaceEntryTokenRegistry);
        addrs.mineCoreEntryTokenRegistry = address(b.mineCoreEntryTokenRegistry);
        addrs.claimAllHelper = address(b.claimAllHelper);
        addrs.delegationHub = address(b.delegationHub);
        addrs.maintenanceHub = address(b.maintenanceHub);
    }

    function _mineCoreOnlyManifest(address mineCore) internal view returns (string memory) {
        return string(abi.encodePacked('{"contracts":{"MineCore":{"address":"', vm.toString(mineCore), '"}}}'));
    }

    function _deployAgentLensRequiredBundle() internal returns (AgentLensRequiredBundle memory bundle) {
        bundle.owner = vm.addr(1);
        bundle.claimToken = new ClaimToken(bundle.owner);
        bundle.veClaimNFT = new VeClaimNFTHarness(address(bundle.claimToken), bundle.owner);
        bundle.shareholderRoyalties = new ShareholderRoyalties(address(bundle.veClaimNFT), bundle.owner);
        bundle.furnace = new Furnace(
            address(bundle.claimToken),
            address(bundle.veClaimNFT),
            address(new FurnaceGuardHelper(address(bundle.claimToken), address(bundle.veClaimNFT))),
            bundle.owner
        );
        bundle.mineCore = new MineCore(
            address(bundle.claimToken), address(bundle.veClaimNFT), address(bundle.shareholderRoyalties), bundle.owner
        );
        bundle.marketRouter = new MarketRouter(
            address(bundle.claimToken), address(bundle.veClaimNFT), address(bundle.shareholderRoyalties), bundle.owner
        );

        vm.startPrank(bundle.owner);
        bundle.claimToken.setMineCore(address(bundle.mineCore));
        bundle.furnace.setMineCore(address(bundle.mineCore));
        bundle.furnace.setMineMarket(address(bundle.marketRouter));
        bundle.furnace.setShareholderRoyalties(address(bundle.shareholderRoyalties));
        bundle.mineCore.setFurnace(address(bundle.furnace));
        bundle.shareholderRoyalties
            .setWiring(address(bundle.mineCore), address(bundle.marketRouter), address(bundle.furnace));
        bundle.veClaimNFT.setFurnace(address(bundle.furnace));
        bundle.veClaimNFT.setMineMarket(address(bundle.marketRouter));
        vm.stopPrank();
    }

    function _setAgentLensRequiredEnv(AgentLensRequiredBundle memory bundle) internal {
        string memory zero = vm.toString(address(0));
        vm.setEnv("PRIVATE_KEY", _pkEnv(1));
        vm.setEnv("CLAIM_TOKEN", vm.toString(address(bundle.claimToken)));
        vm.setEnv("VECLAIM_NFT", vm.toString(address(bundle.veClaimNFT)));
        vm.setEnv("MINE_CORE", vm.toString(address(bundle.mineCore)));
        vm.setEnv("SHAREHOLDER_ROYALTIES", vm.toString(address(bundle.shareholderRoyalties)));
        vm.setEnv("FURNACE", vm.toString(address(bundle.furnace)));
        vm.setEnv("MARKET_ROUTER", zero);
        vm.setEnv("LP_STAKING_VAULT_7D", zero);
        vm.setEnv("DEX_ADAPTER", zero);
        vm.setEnv("FURNACE_ENTRY_TOKEN_REGISTRY", zero);
        vm.setEnv("MINE_CORE_ENTRY_TOKEN_REGISTRY", zero);
        vm.setEnv("DELEGATION_HUB", zero);
        vm.setEnv("CLAIM_ALL_HELPER", zero);
        vm.setEnv("MAINTENANCE_HUB", zero);
        vm.setEnv("LAUNCH_CONTROLLER", zero);
        vm.setEnv("GENESIS_LP_VAULT_24M", zero);
    }

    function _setLocalExtrasRequiredEnv(
        address coreStub,
        address dexAdapter,
        address aerodromeRouter,
        address aerodromeFactory,
        address weth,
        address claimWethPool
    ) internal {
        if (coreStub.code.length == 0) vm.etch(coreStub, hex"00");
        if (dexAdapter.code.length == 0) vm.etch(dexAdapter, hex"00");
        if (aerodromeRouter.code.length == 0) vm.etch(aerodromeRouter, hex"00");
        if (aerodromeFactory.code.length == 0) vm.etch(aerodromeFactory, hex"00");
        if (weth.code.length == 0) vm.etch(weth, hex"00");
        if (claimWethPool.code.length == 0) vm.etch(claimWethPool, hex"00");
        vm.setEnv("LOCAL_PRIVATE_KEY", _pkEnv(1));
        vm.setEnv("LOCAL_CLAIM_WETH_POOL", vm.toString(claimWethPool));
        vm.setEnv("LOCAL_WETH", vm.toString(weth));
        vm.setEnv("LOCAL_CLAIM_TOKEN", vm.toString(coreStub));
        vm.setEnv("LOCAL_VECLAIM_NFT", vm.toString(coreStub));
        vm.setEnv("LOCAL_SHAREHOLDER_ROYALTIES", vm.toString(coreStub));
        vm.setEnv("LOCAL_FURNACE", vm.toString(coreStub));
        vm.setEnv("LOCAL_MARKET_ROUTER", vm.toString(coreStub));
        vm.setEnv("LOCAL_MINE_CORE", vm.toString(coreStub));
        vm.setEnv("LOCAL_DEX_ADAPTER", vm.toString(dexAdapter));
        vm.setEnv("LOCAL_AERODROME_ROUTER", vm.toString(aerodromeRouter));
        vm.setEnv("LOCAL_AERODROME_FACTORY", vm.toString(aerodromeFactory));
    }

    function _deployWireHarnessBundle()
        internal
        returns (Wire.Addrs memory addrs, MarketRouter marketRouter, MaintenanceHub maintenanceHub, address owner)
    {
        owner = vm.addr(1);

        ClaimToken claim = new ClaimToken(owner);
        VeClaimNFTHarness ve = new VeClaimNFTHarness(address(claim), owner);
        ShareholderRoyalties royalties = new ShareholderRoyalties(address(ve), owner);
        Furnace furnace = new Furnace(
            address(claim), address(ve), address(new FurnaceGuardHelper(address(claim), address(ve))), owner
        );
        MineCore mineCore = new MineCore(address(claim), address(ve), address(royalties), owner);
        marketRouter = new MarketRouter(address(claim), address(ve), address(royalties), owner);
        EntryTokenRegistry furnaceRegistry = new EntryTokenRegistry(owner);
        EntryTokenRegistry mineCoreRegistry = new EntryTokenRegistry(owner);
        ClaimAllHelper claimAllHelper = new ClaimAllHelper(address(royalties), address(mineCore));
        DelegationHub delegationHub = new DelegationHub();
        LocalWETH weth = new LocalWETH();

        vm.startPrank(owner);
        claim.setMineCore(address(mineCore));
        furnace.setMineCore(address(mineCore));
        furnace.setMineMarket(address(marketRouter));
        furnace.setShareholderRoyalties(address(royalties));
        mineCore.setFurnace(address(furnace));
        royalties.setWiring(address(mineCore), address(marketRouter), address(furnace));
        ve.setFurnace(address(furnace));
        ve.setMineMarket(address(marketRouter));
        vm.stopPrank();

        maintenanceHub = new MaintenanceHub(
            address(marketRouter), address(furnace), address(ve), address(royalties), address(weth), address(0xDE5C0E)
        );

        addrs.claimToken = address(claim);
        addrs.ve = address(ve);
        addrs.royalties = address(royalties);
        addrs.furnace = address(furnace);
        addrs.marketRouter = address(marketRouter);
        addrs.mineCore = address(mineCore);
        addrs.furnaceEntryTokenRegistry = address(furnaceRegistry);
        addrs.mineCoreEntryTokenRegistry = address(mineCoreRegistry);
        addrs.claimAllHelper = address(claimAllHelper);
        addrs.delegationHub = address(delegationHub);
        addrs.maintenanceHub = address(maintenanceHub);
    }

    function testDeployLocalRevertsOnNonLocalChain() public {
        vm.chainId(84532);

        DeployLocal script = new DeployLocal();

        vm.expectRevert("DeployLocal: local chain only");
        script.run();
    }

    function testDeployLocalDexHarnessRevertsOnNonLocalChain() public {
        vm.chainId(84532);

        DeployLocalDexHarness script = new DeployLocalDexHarness();

        vm.expectRevert("DeployLocalDexHarness: local chain only");
        script.run();
    }

    function testDeployLocalPreflightPreventsPartialMutation() public {
        vm.chainId(31337);

        _ScriptSafetyMarker marker = new _ScriptSafetyMarker();
        _DeployLocalHarness harness = new _DeployLocalHarness(marker);

        vm.expectRevert("stub late deploy revert");
        harness.preflight(vm.addr(1));

        assertFalse(marker.touched(), "preflight revert should roll back late local deploy mutations");
    }

    function testDeployLocalDexHarnessPreflightPreventsPartialMutation() public {
        vm.chainId(31337);

        _ScriptSafetyMarker marker = new _ScriptSafetyMarker();
        _DeployLocalDexHarnessHarness harness = new _DeployLocalDexHarnessHarness(marker);
        address claimToken = address(new _CodeStub());

        vm.expectRevert("stub late dex revert");
        harness.preflight(vm.addr(1), claimToken);

        assertFalse(marker.touched(), "preflight revert should roll back late local dex mutations");
    }

    function _testDeployLocalDexHarnessRejectsNonContractClaimToken() internal {
        vm.chainId(31337);
        vm.setEnv("LOCAL_PRIVATE_KEY", _pkEnv(1));
        vm.setEnv("LOCAL_CLAIM_TOKEN", vm.toString(address(0xBEEF)));

        DeployLocalDexHarness script = new DeployLocalDexHarness();

        vm.expectRevert("DeployLocalDexHarness: LOCAL_CLAIM_TOKEN is not a contract");
        script.run();
    }

    function _testDeployPreflightRejectsNonContractDexRootsBeforeLiveBroadcast() internal {
        vm.chainId(84532);

        uint256 deployerPk = 1;
        address deployer = vm.addr(deployerPk);
        address lpWithdrawRecipient = address(0xBEEF);
        address router = address(new _DeployDexRootStub(address(0xCAFE), address(0xBEEF), address(0xD00D)));
        address adminSafe = address(new _CodeStub());

        vm.setEnv("PRIVATE_KEY", _pkEnv(deployerPk));
        vm.setEnv("LP_WITHDRAW_RECIPIENT", vm.toString(lpWithdrawRecipient));
        vm.setEnv("AERODROME_ROUTER", vm.toString(router));
        vm.setEnv("ADMIN_SAFE", vm.toString(adminSafe));
        vm.deal(deployer, 100 ether);

        uint64 nonceBefore = vm.getNonce(deployer);
        Deploy script = new Deploy();

        // DexAdapter's constructor now rejects EOA roots returned by the
        // router (factory/weth) directly, so the typed `NotAContract`
        // selector preempts Deploy.s.sol's explicit string require. The
        // intent of the test (preflight blocks live broadcast on bad dex
        // roots) is preserved: the constructor reverts inside the snapshot
        // before any broadcast, and the post-revert nonce check still
        // proves no live tx was emitted.
        vm.expectRevert(Errors.NotAContract.selector);
        script.run();
        vm.stopPrank();

        assertEq(vm.getNonce(deployer), nonceBefore, "preflight should prevent live deploy txs");
    }

    function _testDeployRejectsUnsafeMainnetTimelockDelayOverride() internal {
        vm.chainId(8453);
        _primeMainnetDeployConfigEnv();
        vm.setEnv("TIMELOCK_DELAY_SECONDS", "3600");
        vm.setEnv("ALLOW_UNSAFE_MAINNET_TIMELOCK_DELAY", "false");

        _DeployHarness script = new _DeployHarness();

        vm.expectRevert(
            "Deploy: TIMELOCK_DELAY_SECONDS below 48 hours on mainnet; set ALLOW_UNSAFE_MAINNET_TIMELOCK_DELAY=true to override"
        );
        script.loadConfigDelay();
    }

    function _testDeployAllowsUnsafeMainnetTimelockDelayOverrideWithExplicitAck() internal {
        vm.chainId(8453);
        _primeMainnetDeployConfigEnv();
        vm.setEnv("TIMELOCK_DELAY_SECONDS", "3600");
        vm.setEnv("ALLOW_UNSAFE_MAINNET_TIMELOCK_DELAY", "true");

        _DeployHarness script = new _DeployHarness();

        assertEq(script.loadConfigDelay(), 3600, "explicit break-glass ack should permit short mainnet delay");
    }

    function _primeMainnetDeployConfigEnv() internal {
        uint256 deployerPk = 1;
        address adminSafe = address(0xA11CE);
        address router = 0xcF77a3Ba9A5CA399B7c97c74d54e5b1Beb874E43;

        vm.etch(adminSafe, address(new _CodeStub()).code);
        vm.etch(router, address(new _CodeStub()).code);

        vm.setEnv("PRIVATE_KEY", _pkEnv(deployerPk));
        vm.setEnv("LP_WITHDRAW_RECIPIENT", vm.toString(address(0xBEEF)));
        vm.setEnv("AERODROME_ROUTER", vm.toString(router));
        vm.setEnv("ADMIN_SAFE", vm.toString(adminSafe));
        vm.setEnv("ALLOW_NON_CANONICAL_ADMIN_SAFE", "true");
        vm.setEnv("ALLOW_NON_CANONICAL_LP_WITHDRAW_RECIPIENT", "true");
    }

    function testDeployLocalExtrasRevertsOnNonLocalChain() public {
        vm.chainId(84532);

        DeployLocalExtras script = new DeployLocalExtras();

        vm.expectRevert("DeployLocalExtras: local chain only");
        script.run();
    }

    function _testDeployLocalExtrasRejectsNonContractClaimWethPool() internal {
        vm.chainId(31337);

        address coreStub = address(new _CodeStub());
        address factory = address(new _CodeStub());
        address weth = address(new _CodeStub());
        address claimWethPool = address(new _CodeStub());
        address dexAdapter = address(new _DeployDexRootStub(factory, weth, claimWethPool));
        address router = address(new _DeployDexRootStub(factory, weth, claimWethPool));
        _setLocalExtrasRequiredEnv(coreStub, dexAdapter, router, factory, weth, claimWethPool);
        vm.setEnv("LOCAL_CLAIM_WETH_POOL", vm.toString(address(0xBEEF)));

        DeployLocalExtras script = new DeployLocalExtras();

        vm.expectRevert("DeployLocalExtras: LOCAL_CLAIM_WETH_POOL is not a contract");
        script.run();
    }

    function _testDeployLocalExtrasRejectsGuardianOverrideDifferentFromDeployer() internal {
        vm.chainId(31337);

        address coreStub = address(new _CodeStub());
        address factory = address(new _CodeStub());
        address weth = address(new _CodeStub());
        address claimWethPool = address(new _CodeStub());
        address dexAdapter = address(new _DeployDexRootStub(factory, weth, claimWethPool));
        address router = address(new _DeployDexRootStub(factory, weth, claimWethPool));
        _setLocalExtrasRequiredEnv(coreStub, dexAdapter, router, factory, weth, claimWethPool);
        vm.setEnv("LOCAL_GENESIS_BURN_GUARDIAN", vm.toString(address(0xBEEF)));

        DeployLocalExtras script = new DeployLocalExtras();

        vm.expectRevert();
        script.run();
    }

    function _testDeployLocalExtrasRejectsDexAdapterWrappedNativeMismatch() internal {
        vm.chainId(31337);

        address coreStub = address(new _CodeStub());
        address factory = address(new _CodeStub());
        address weth = address(new _CodeStub());
        address wrongWeth = address(new _CodeStub());
        address claimWethPool = address(new _CodeStub());
        address dexAdapter = address(new _DeployDexRootStub(factory, wrongWeth, claimWethPool));
        address router = address(new _DeployDexRootStub(factory, weth, claimWethPool));
        _setLocalExtrasRequiredEnv(coreStub, dexAdapter, router, factory, weth, claimWethPool);

        DeployLocalExtras script = new DeployLocalExtras();

        vm.expectRevert("DeployLocalExtras: DexAdapter.weth mismatch");
        script.run();
    }

    function _testDeployLocalExtrasRejectsRouterWrappedNativeMismatch() internal {
        vm.chainId(31337);

        address coreStub = address(new _CodeStub());
        address factory = address(new _CodeStub());
        address weth = address(new _CodeStub());
        address wrongWeth = address(new _CodeStub());
        address claimWethPool = address(new _CodeStub());
        address dexAdapter = address(new _DeployDexRootStub(factory, weth, claimWethPool));
        address router = address(new _DeployDexRootStub(factory, wrongWeth, claimWethPool));
        _setLocalExtrasRequiredEnv(coreStub, dexAdapter, router, factory, weth, claimWethPool);

        DeployLocalExtras script = new DeployLocalExtras();

        vm.expectRevert("DeployLocalExtras: LOCAL_WETH mismatch");
        script.run();
    }

    function _testDeployMaintenanceHubReadsManifestByDefault() internal {
        vm.chainId(84532);
        _clearCallerMode();

        uint256 broadcasterPk = 1;
        address broadcaster = vm.addr(broadcasterPk);
        AgentLensRequiredBundle memory bundle = _deployAgentLensRequiredBundle();
        LocalWETH weth = new LocalWETH();

        vm.deal(broadcaster, 100 ether);
        vm.setEnv("PRIVATE_KEY", _pkEnv(broadcasterPk));
        vm.setEnv(
            "DEPLOYMENTS_MANIFEST_JSON",
            _maintenanceHubManifest(
                address(bundle.marketRouter),
                address(bundle.furnace),
                address(bundle.veClaimNFT),
                address(bundle.shareholderRoyalties),
                address(weth)
            )
        );
        vm.setEnv("MARKET_ROUTER", vm.toString(address(0)));
        vm.setEnv("FURNACE", vm.toString(address(0)));
        vm.setEnv("VECLAIM_NFT", vm.toString(address(0)));
        vm.setEnv("SHAREHOLDER_ROYALTIES", vm.toString(address(0)));
        vm.setEnv("WETH", vm.toString(address(0)));

        uint64 nonceBefore = vm.getNonce(broadcaster);
        DeployMaintenanceHub script = new DeployMaintenanceHub();
        script.run();

        assertEq(vm.getNonce(broadcaster), nonceBefore + 1, "manifest-driven MaintenanceHub deploy should use one tx");
    }

    function _testDeployMaintenanceHubRejectsManifestEnvDrift() internal {
        vm.chainId(84532);
        _clearCallerMode();

        uint256 broadcasterPk = 1;
        AgentLensRequiredBundle memory bundle = _deployAgentLensRequiredBundle();
        LocalWETH weth = new LocalWETH();

        vm.setEnv("PRIVATE_KEY", _pkEnv(broadcasterPk));
        vm.setEnv(
            "DEPLOYMENTS_MANIFEST_JSON",
            _maintenanceHubManifest(
                address(bundle.marketRouter),
                address(bundle.furnace),
                address(bundle.veClaimNFT),
                address(bundle.shareholderRoyalties),
                address(weth)
            )
        );
        vm.setEnv("MARKET_ROUTER", vm.toString(address(new _CodeStub())));
        vm.setEnv("FURNACE", vm.toString(address(0)));
        vm.setEnv("VECLAIM_NFT", vm.toString(address(0)));
        vm.setEnv("SHAREHOLDER_ROYALTIES", vm.toString(address(0)));
        vm.setEnv("WETH", vm.toString(address(0)));

        DeployMaintenanceHub script = new DeployMaintenanceHub();

        vm.expectRevert("DeployMaintenanceHub: manifest/env mismatch for MARKET_ROUTER");
        script.run();
    }

    function _testDeployMineCoreQuoterReadsManifestByDefault() internal {
        vm.chainId(84532);
        _clearCallerMode();

        uint256 broadcasterPk = 1;
        address broadcaster = vm.addr(broadcasterPk);
        AgentLensRequiredBundle memory bundle = _deployAgentLensRequiredBundle();

        vm.deal(broadcaster, 100 ether);
        vm.setEnv("PRIVATE_KEY", _pkEnv(broadcasterPk));
        vm.setEnv("DEPLOYMENTS_MANIFEST_JSON", _mineCoreOnlyManifest(address(bundle.mineCore)));
        vm.setEnv("MINE_CORE", vm.toString(address(0)));

        uint64 nonceBefore = vm.getNonce(broadcaster);
        DeployMineCoreQuoter script = new DeployMineCoreQuoter();
        script.run();

        assertEq(vm.getNonce(broadcaster), nonceBefore + 1, "manifest-driven MineCoreQuoter deploy should use one tx");
    }

    function _testDeployMineCoreQuoterRejectsManifestEnvDrift() internal {
        vm.chainId(84532);
        _clearCallerMode();

        uint256 broadcasterPk = 1;
        AgentLensRequiredBundle memory bundle = _deployAgentLensRequiredBundle();

        vm.setEnv("PRIVATE_KEY", _pkEnv(broadcasterPk));
        vm.setEnv("DEPLOYMENTS_MANIFEST_JSON", _mineCoreOnlyManifest(address(bundle.mineCore)));
        vm.setEnv("MINE_CORE", vm.toString(address(new _CodeStub())));

        DeployMineCoreQuoter script = new DeployMineCoreQuoter();

        vm.expectRevert("DeployMineCoreQuoter: manifest/env mismatch for MINE_CORE");
        script.run();
    }

    function testConfigureLocalPathBRevertsOnNonLocalChain() public {
        vm.chainId(84532);

        ConfigureLocalPathB script = new ConfigureLocalPathB();

        vm.expectRevert("ConfigureLocalPathB: local chain only");
        script.run();
    }

    function testSmokeLocalPathBRevertsOnNonLocalChain() public {
        vm.chainId(84532);

        SmokeLocalPathB script = new SmokeLocalPathB();

        vm.expectRevert("SmokeLocalPathB: local chain only");
        script.run();
    }

    function testSmokeLocalPathBPreflightPreventsPartialMutation() public {
        vm.chainId(31337);

        address broadcaster = vm.addr(1);
        LocalWETH weth = new LocalWETH();
        _SmokeLocalPathBFurnaceStub furnace = new _SmokeLocalPathBFurnaceStub();
        _SmokeLocalPathBMineCoreStub mineCore = new _SmokeLocalPathBMineCoreStub(1 ether, address(0), true);
        _SmokeLocalPathBHarness harness = new _SmokeLocalPathBHarness();

        vm.deal(broadcaster, 1 ether);

        vm.expectRevert("SmokeLocalPathB: broadcaster balance below takeover price");
        harness.preflight(payable(address(mineCore)), payable(address(furnace)), payable(address(weth)), broadcaster);

        assertFalse(furnace.entered(), "preflight revert should roll back the furnace lock");
        assertFalse(mineCore.takeoverCalled(), "preflight revert should roll back the takeover attempt");
        assertEq(mineCore.currentKing(), address(0), "preflight revert should roll back king state");
    }

    function _testFinalizeOwnershipRejectsInvalidAction() internal {
        vm.chainId(31337);
        vm.setEnv("OWNERSHIP_ACTION", "INVALID_ACTION_STRING_123");
        assertEq(vm.envString("OWNERSHIP_ACTION"), "INVALID_ACTION_STRING_123");

        FinalizeOwnership script = new FinalizeOwnership();

        vm.expectRevert();
        script.run();
    }

    function _testFinalizeOwnershipRejectsInitiateBeforeGenesisFinalized() internal {
        vm.chainId(84532);

        uint256 ownerPk = 1;
        address newOwner = address(0xBEEF);
        _FinalizeOwnershipLaunchControllerStub launchController = new _FinalizeOwnershipLaunchControllerStub(false);
        vm.setEnv("OWNERSHIP_ADDRS_FROM_ENV", "true");
        vm.setEnv("OWNERSHIP_LAUNCH_CONTROLLER", vm.toString(address(launchController)));
        vm.setEnv("PRIVATE_KEY", _pkEnv(ownerPk));
        vm.setEnv("NEW_OWNER", vm.toString(newOwner));
        vm.setEnv("OWNERSHIP_ACTION", "initiate");
        vm.setEnv("ALLOW_UNSAFE_PRE_FINAL_HANDOFF", "false");

        FinalizeOwnership script = new FinalizeOwnership();

        vm.expectRevert();
        script.run();
    }

    function _testFinalizeOwnershipPreflightPreventsPartialInitiateState() internal {
        vm.chainId(31337);

        uint256 ownerPk = 1;
        address owner = vm.addr(ownerPk);
        address newOwner = address(0xBEEF);
        _FinalizeOwnershipClaimTokenStub claimToken = new _FinalizeOwnershipClaimTokenStub(owner, true);
        _FinalizeOwnershipRevertingStub revertingTarget = new _FinalizeOwnershipRevertingStub(owner);

        vm.setEnv("OWNERSHIP_ADDRS_FROM_ENV", "true");
        vm.setEnv("OWNERSHIP_CLAIM_TOKEN", vm.toString(address(claimToken)));
        vm.setEnv("OWNERSHIP_VE", vm.toString(address(revertingTarget)));
        vm.setEnv("OWNERSHIP_MINE_CORE", vm.toString(address(0)));
        vm.setEnv("OWNERSHIP_ROYALTIES", vm.toString(address(0)));
        vm.setEnv("OWNERSHIP_FURNACE", vm.toString(address(0)));
        vm.setEnv("OWNERSHIP_MARKET_ROUTER", vm.toString(address(0)));
        vm.setEnv("OWNERSHIP_FURNACE_ENTRY_TOKEN_REGISTRY", vm.toString(address(0)));
        vm.setEnv("OWNERSHIP_MINECORE_ENTRY_TOKEN_REGISTRY", vm.toString(address(0)));
        vm.setEnv("OWNERSHIP_DEX_ADAPTER", vm.toString(address(0)));
        vm.setEnv("OWNERSHIP_LP_STAKING_VAULT", vm.toString(address(0)));
        vm.setEnv("OWNERSHIP_LAUNCH_CONTROLLER", vm.toString(address(0)));
        vm.setEnv("LOCAL_PRIVATE_KEY", _pkEnv(ownerPk));
        vm.setEnv("OWNERSHIP_ACTION", "initiate");
        vm.setEnv("NEW_OWNER", vm.toString(newOwner));

        FinalizeOwnership script = new FinalizeOwnership();

        vm.expectRevert(bytes("stub transfer revert"));
        script.run();

        assertEq(claimToken.pendingOwner(), address(0), "preflight should prevent partial ownership initiation");
    }

    function _testFinalizeOwnershipRejectsEmptyEnvTargetSet() internal {
        vm.chainId(31337);

        uint256 ownerPk = 1;
        address newOwner = address(0xBEEF);

        vm.setEnv("OWNERSHIP_ADDRS_FROM_ENV", "true");
        vm.setEnv("OWNERSHIP_CLAIM_TOKEN", vm.toString(address(0)));
        vm.setEnv("OWNERSHIP_VE", vm.toString(address(0)));
        vm.setEnv("OWNERSHIP_MINE_CORE", vm.toString(address(0)));
        vm.setEnv("OWNERSHIP_ROYALTIES", vm.toString(address(0)));
        vm.setEnv("OWNERSHIP_FURNACE", vm.toString(address(0)));
        vm.setEnv("OWNERSHIP_MARKET_ROUTER", vm.toString(address(0)));
        vm.setEnv("OWNERSHIP_FURNACE_ENTRY_TOKEN_REGISTRY", vm.toString(address(0)));
        vm.setEnv("OWNERSHIP_MINECORE_ENTRY_TOKEN_REGISTRY", vm.toString(address(0)));
        vm.setEnv("OWNERSHIP_DEX_ADAPTER", vm.toString(address(0)));
        vm.setEnv("OWNERSHIP_LP_STAKING_VAULT", vm.toString(address(0)));
        vm.setEnv("OWNERSHIP_LAUNCH_CONTROLLER", vm.toString(address(0)));
        vm.setEnv("LOCAL_PRIVATE_KEY", _pkEnv(ownerPk));
        vm.setEnv("OWNERSHIP_ACTION", "initiate");
        vm.setEnv("NEW_OWNER", vm.toString(newOwner));

        FinalizeOwnership script = new FinalizeOwnership();

        vm.expectRevert("FinalizeOwnership: OWNERSHIP_ADDRS_FROM_ENV requires at least one target");
        script.run();
    }

    function _testFinalizeOwnershipRejectsSelfHandoff() internal {
        vm.chainId(31337);

        uint256 ownerPk = 1;
        address owner = vm.addr(ownerPk);
        _FinalizeOwnershipClaimTokenStub claimToken = new _FinalizeOwnershipClaimTokenStub(owner, true);

        vm.setEnv("OWNERSHIP_ADDRS_FROM_ENV", "true");
        vm.setEnv("OWNERSHIP_CLAIM_TOKEN", vm.toString(address(claimToken)));
        vm.setEnv("OWNERSHIP_VE", vm.toString(address(0)));
        vm.setEnv("OWNERSHIP_MINE_CORE", vm.toString(address(0)));
        vm.setEnv("OWNERSHIP_ROYALTIES", vm.toString(address(0)));
        vm.setEnv("OWNERSHIP_FURNACE", vm.toString(address(0)));
        vm.setEnv("OWNERSHIP_MARKET_ROUTER", vm.toString(address(0)));
        vm.setEnv("OWNERSHIP_FURNACE_ENTRY_TOKEN_REGISTRY", vm.toString(address(0)));
        vm.setEnv("OWNERSHIP_MINECORE_ENTRY_TOKEN_REGISTRY", vm.toString(address(0)));
        vm.setEnv("OWNERSHIP_DEX_ADAPTER", vm.toString(address(0)));
        vm.setEnv("OWNERSHIP_LP_STAKING_VAULT", vm.toString(address(0)));
        vm.setEnv("OWNERSHIP_LAUNCH_CONTROLLER", vm.toString(address(0)));
        vm.setEnv("LOCAL_PRIVATE_KEY", _pkEnv(ownerPk));
        vm.setEnv("OWNERSHIP_ACTION", "initiate");
        vm.setEnv("NEW_OWNER", vm.toString(owner));

        FinalizeOwnership script = new FinalizeOwnership();

        vm.expectRevert("FinalizeOwnership: NEW_OWNER must differ from current actor");
        script.run();
    }

    function _testFinalizeOwnershipRejectsManifestOwnerDrift() internal {
        vm.chainId(31337);

        uint256 ownerPk = 1;
        address owner = vm.addr(ownerPk);
        address newOwner = address(0xBEEF);
        _FinalizeOwnershipClaimTokenStub claimToken = new _FinalizeOwnershipClaimTokenStub(owner, true);
        _FinalizeOwnershipOwnableStub wrongOwnerTarget = new _FinalizeOwnershipOwnableStub(address(0xCAFE));
        address[11] memory contracts_;
        contracts_[0] = address(claimToken);
        contracts_[1] = address(wrongOwnerTarget);
        contracts_[2] = address(new _FinalizeOwnershipOwnableStub(owner));
        contracts_[3] = address(new _FinalizeOwnershipOwnableStub(owner));
        contracts_[4] = address(new _FinalizeOwnershipOwnableStub(owner));
        contracts_[5] = address(new _FinalizeOwnershipOwnableStub(owner));
        contracts_[6] = address(new _FinalizeOwnershipOwnableStub(owner));
        contracts_[7] = address(new _FinalizeOwnershipOwnableStub(owner));
        contracts_[8] = address(new _FinalizeOwnershipOwnableStub(owner));
        contracts_[9] = address(new _FinalizeOwnershipOwnableStub(owner));
        contracts_[10] = address(new _CodeStub());

        vm.setEnv("DEPLOYMENTS_MANIFEST_JSON", _finalizeOwnershipManifest(contracts_));
        vm.setEnv("LOCAL_PRIVATE_KEY", _pkEnv(ownerPk));
        vm.setEnv("OWNERSHIP_ACTION", "initiate");
        vm.setEnv("NEW_OWNER", vm.toString(newOwner));
        vm.setEnv("OWNERSHIP_ADDRS_FROM_ENV", "false");

        FinalizeOwnership script = new FinalizeOwnership();

        vm.expectRevert("FinalizeOwnership: target owner mismatch");
        script.run();

        assertEq(claimToken.pendingOwner(), address(0), "preflight should roll back earlier handoff state");
    }

    function _testFinalizeOwnershipRejectsManifestPendingOwnerDrift() internal {
        vm.chainId(31337);

        uint256 ownerPk = 1;
        address owner = vm.addr(ownerPk);
        address newOwner = address(0xBEEF);
        _FinalizeOwnershipClaimTokenStub claimToken = new _FinalizeOwnershipClaimTokenStub(owner, true);
        _FinalizeOwnershipOwnableStub pendingOwnerDrift = new _FinalizeOwnershipOwnableStub(owner);
        vm.prank(owner);
        pendingOwnerDrift.transferOwnership(address(0xCAFE));
        address[11] memory contracts_;
        contracts_[0] = address(claimToken);
        contracts_[1] = address(pendingOwnerDrift);
        contracts_[2] = address(new _FinalizeOwnershipOwnableStub(owner));
        contracts_[3] = address(new _FinalizeOwnershipOwnableStub(owner));
        contracts_[4] = address(new _FinalizeOwnershipOwnableStub(owner));
        contracts_[5] = address(new _FinalizeOwnershipOwnableStub(owner));
        contracts_[6] = address(new _FinalizeOwnershipOwnableStub(owner));
        contracts_[7] = address(new _FinalizeOwnershipOwnableStub(owner));
        contracts_[8] = address(new _FinalizeOwnershipOwnableStub(owner));
        contracts_[9] = address(new _FinalizeOwnershipOwnableStub(owner));
        contracts_[10] = address(new _CodeStub());

        vm.setEnv("DEPLOYMENTS_MANIFEST_JSON", _finalizeOwnershipManifest(contracts_));
        vm.setEnv("LOCAL_PRIVATE_KEY", _pkEnv(ownerPk));
        vm.setEnv("OWNERSHIP_ACTION", "initiate");
        vm.setEnv("NEW_OWNER", vm.toString(newOwner));
        vm.setEnv("OWNERSHIP_ADDRS_FROM_ENV", "false");

        FinalizeOwnership script = new FinalizeOwnership();

        vm.expectRevert("FinalizeOwnership: target pendingOwner mismatch");
        script.run();

        assertEq(claimToken.pendingOwner(), address(0), "preflight should roll back earlier handoff state");
    }

    function _testFinalizeOwnershipRejectsManifestAcceptStateDrift() internal {
        vm.chainId(31337);

        uint256 pendingOwnerPk = 2;
        address pendingOwner = vm.addr(pendingOwnerPk);
        address oldOwner = address(0xCAFE);
        _FinalizeOwnershipClaimTokenStub claimToken = new _FinalizeOwnershipClaimTokenStub(oldOwner, true);
        _FinalizeOwnershipOwnableStub wrongPendingTarget = new _FinalizeOwnershipOwnableStub(oldOwner);
        vm.prank(oldOwner);
        claimToken.transferOwnership(pendingOwner);
        vm.prank(oldOwner);
        wrongPendingTarget.transferOwnership(address(0xBEEF));
        address[11] memory contracts_;
        contracts_[0] = address(claimToken);
        contracts_[1] = address(wrongPendingTarget);
        contracts_[2] = address(new _FinalizeOwnershipOwnableStub(oldOwner));
        contracts_[3] = address(new _FinalizeOwnershipOwnableStub(oldOwner));
        contracts_[4] = address(new _FinalizeOwnershipOwnableStub(oldOwner));
        contracts_[5] = address(new _FinalizeOwnershipOwnableStub(oldOwner));
        contracts_[6] = address(new _FinalizeOwnershipOwnableStub(oldOwner));
        contracts_[7] = address(new _FinalizeOwnershipOwnableStub(oldOwner));
        contracts_[8] = address(new _FinalizeOwnershipOwnableStub(oldOwner));
        contracts_[9] = address(new _FinalizeOwnershipOwnableStub(oldOwner));
        contracts_[10] = address(new _CodeStub());

        vm.setEnv("DEPLOYMENTS_MANIFEST_JSON", _finalizeOwnershipManifest(contracts_));
        vm.setEnv("LOCAL_PRIVATE_KEY", _pkEnv(pendingOwnerPk));
        vm.setEnv("OWNERSHIP_ACTION", "accept");
        vm.setEnv("OWNERSHIP_ADDRS_FROM_ENV", "false");

        FinalizeOwnership script = new FinalizeOwnership();

        vm.expectRevert("FinalizeOwnership: target not pending to actor");
        script.run();

        assertEq(claimToken.owner(), oldOwner, "preflight should roll back earlier accept state");
        assertEq(claimToken.pendingOwner(), pendingOwner, "preflight should preserve pending owner after revert");
    }

    function _testFinalizeOwnershipRejectsManifestMissingTarget() internal {
        vm.chainId(31337);

        uint256 ownerPk = 1;
        address newOwner = address(0xBEEF);
        address[11] memory contracts_;
        contracts_[0] = address(new _CodeStub());
        contracts_[1] = address(new _CodeStub());
        contracts_[2] = address(new _CodeStub());
        contracts_[3] = address(new _CodeStub());
        contracts_[4] = address(new _CodeStub());
        contracts_[5] = address(new _CodeStub());
        contracts_[6] = address(new _CodeStub());
        contracts_[7] = address(new _CodeStub());
        contracts_[8] = address(0);
        contracts_[9] = address(new _CodeStub());
        contracts_[10] = address(new _CodeStub());

        vm.setEnv("DEPLOYMENTS_MANIFEST_JSON", _finalizeOwnershipManifest(contracts_));
        vm.setEnv("LOCAL_PRIVATE_KEY", _pkEnv(ownerPk));
        vm.setEnv("OWNERSHIP_ACTION", "initiate");
        vm.setEnv("NEW_OWNER", vm.toString(newOwner));
        vm.setEnv("OWNERSHIP_ADDRS_FROM_ENV", "false");

        FinalizeOwnership script = new FinalizeOwnership();

        vm.expectRevert("FinalizeOwnership: missing DexAdapter");
        script.run();
    }

    function _testFinalizeOwnershipRejectsNoOpTransferTarget() internal {
        vm.chainId(31337);

        uint256 ownerPk = 1;
        address owner = vm.addr(ownerPk);
        address newOwner = address(0xBEEF);
        _FinalizeOwnershipClaimTokenStub claimToken = new _FinalizeOwnershipClaimTokenStub(owner, true);
        _FinalizeOwnershipNoopTransferStub noopTarget = new _FinalizeOwnershipNoopTransferStub(owner);

        vm.setEnv("OWNERSHIP_ADDRS_FROM_ENV", "true");
        vm.setEnv("OWNERSHIP_CLAIM_TOKEN", vm.toString(address(claimToken)));
        vm.setEnv("OWNERSHIP_VE", vm.toString(address(noopTarget)));
        vm.setEnv("OWNERSHIP_MINE_CORE", vm.toString(address(0)));
        vm.setEnv("OWNERSHIP_ROYALTIES", vm.toString(address(0)));
        vm.setEnv("OWNERSHIP_FURNACE", vm.toString(address(0)));
        vm.setEnv("OWNERSHIP_MARKET_ROUTER", vm.toString(address(0)));
        vm.setEnv("OWNERSHIP_FURNACE_ENTRY_TOKEN_REGISTRY", vm.toString(address(0)));
        vm.setEnv("OWNERSHIP_MINECORE_ENTRY_TOKEN_REGISTRY", vm.toString(address(0)));
        vm.setEnv("OWNERSHIP_DEX_ADAPTER", vm.toString(address(0)));
        vm.setEnv("OWNERSHIP_LP_STAKING_VAULT", vm.toString(address(0)));
        vm.setEnv("OWNERSHIP_LAUNCH_CONTROLLER", vm.toString(address(0)));
        vm.setEnv("LOCAL_PRIVATE_KEY", _pkEnv(ownerPk));
        vm.setEnv("OWNERSHIP_ACTION", "initiate");
        vm.setEnv("NEW_OWNER", vm.toString(newOwner));

        FinalizeOwnership script = new FinalizeOwnership();

        vm.expectRevert("FinalizeOwnership: transferOwnership did not set pending owner");
        script.run();

        assertEq(claimToken.pendingOwner(), address(0), "preflight should roll back earlier pending-owner writes");
        assertEq(noopTarget.pendingOwner(), address(0), "preflight should leave noop target untouched");
    }

    function _testFinalizeOwnershipAllowsCanonicalPreFreezeHandoffAfterClaimTokenFinalized() internal {
        vm.chainId(84532);

        uint256 ownerPk = 1;
        address owner = vm.addr(ownerPk);
        address bootstrapAdmin = address(0xB00757);
        _FinalizeOwnershipTimelockStub timelock = new _FinalizeOwnershipTimelockStub(bootstrapAdmin, false);
        address newOwner = address(timelock);
        _FinalizeOwnershipLaunchControllerStub launchController = new _FinalizeOwnershipLaunchControllerStub(true);
        _FinalizeOwnershipClaimTokenStub claimToken = new _FinalizeOwnershipClaimTokenStub(address(0), true);
        _FinalizeOwnershipClaimTokenStub ve = new _FinalizeOwnershipClaimTokenStub(owner, false);
        _FinalizeOwnershipClaimTokenStub royalties = new _FinalizeOwnershipClaimTokenStub(owner, false);
        _FinalizeOwnershipClaimTokenStub furnace = new _FinalizeOwnershipClaimTokenStub(owner, false);
        _FinalizeOwnershipOwnableStub market = new _FinalizeOwnershipOwnableStub(owner);
        _FinalizeOwnershipOwnableStub furnaceReg = new _FinalizeOwnershipOwnableStub(owner);
        _FinalizeOwnershipOwnableStub mineReg = new _FinalizeOwnershipOwnableStub(owner);
        _FinalizeOwnershipMineCoreFreezableStub mineCore =
            new _FinalizeOwnershipMineCoreFreezableStub(owner, address(0xCAFE));

        vm.setEnv("OWNERSHIP_ADDRS_FROM_ENV", "true");
        vm.setEnv("OWNERSHIP_TIMELOCK", vm.toString(address(timelock)));
        vm.setEnv("OWNERSHIP_TIMELOCK_BOOTSTRAP_ADMIN", vm.toString(bootstrapAdmin));
        vm.setEnv("OWNERSHIP_CLAIM_TOKEN", vm.toString(address(claimToken)));
        vm.setEnv("OWNERSHIP_VE", vm.toString(address(ve)));
        vm.setEnv("OWNERSHIP_MINE_CORE", vm.toString(address(mineCore)));
        vm.setEnv("OWNERSHIP_ROYALTIES", vm.toString(address(royalties)));
        vm.setEnv("OWNERSHIP_FURNACE", vm.toString(address(furnace)));
        vm.setEnv("OWNERSHIP_MARKET_ROUTER", vm.toString(address(market)));
        vm.setEnv("OWNERSHIP_FURNACE_ENTRY_TOKEN_REGISTRY", vm.toString(address(furnaceReg)));
        vm.setEnv("OWNERSHIP_MINECORE_ENTRY_TOKEN_REGISTRY", vm.toString(address(mineReg)));
        vm.setEnv("OWNERSHIP_DEX_ADAPTER", vm.toString(address(0)));
        vm.setEnv("OWNERSHIP_LP_STAKING_VAULT", vm.toString(address(0)));
        vm.setEnv("OWNERSHIP_LAUNCH_CONTROLLER", vm.toString(address(launchController)));
        vm.setEnv("PRIVATE_KEY", _pkEnv(ownerPk));
        vm.setEnv("NEW_OWNER", vm.toString(newOwner));
        vm.setEnv("OWNERSHIP_ACTION", "initiate");
        vm.setEnv("ALLOW_UNSAFE_PRE_FINAL_HANDOFF", "false");

        FinalizeOwnership script = new FinalizeOwnership();
        script.run();

        assertEq(claimToken.owner(), address(0), "ClaimToken owner should stay renounced");
        assertEq(ve.pendingOwner(), newOwner, "VeClaimNFT pendingOwner should be set");
        assertEq(mineCore.pendingOwner(), newOwner, "MineCore pendingOwner should be set");
        assertEq(royalties.pendingOwner(), newOwner, "Royalties pendingOwner should be set");
        assertEq(furnace.pendingOwner(), newOwner, "Furnace pendingOwner should be set");
        assertEq(market.pendingOwner(), newOwner, "MarketRouter pendingOwner should be set");
        assertEq(furnaceReg.pendingOwner(), newOwner, "Furnace registry pendingOwner should be set");
        assertEq(mineReg.pendingOwner(), newOwner, "MineCore registry pendingOwner should be set");
    }

    function _testFinalizeOwnershipRejectsCanonicalHandoffToNonTimelockOwner() internal {
        vm.chainId(84532);

        uint256 ownerPk = 1;
        address owner = vm.addr(ownerPk);
        address adminSafe = address(0xA11CE);
        _FinalizeOwnershipTimelockStub timelock = new _FinalizeOwnershipTimelockStub(address(0), false);
        _FinalizeOwnershipClaimTokenStub ve = new _FinalizeOwnershipClaimTokenStub(owner, false);

        vm.setEnv("OWNERSHIP_ADDRS_FROM_ENV", "true");
        vm.setEnv("OWNERSHIP_TIMELOCK", vm.toString(address(timelock)));
        vm.setEnv("OWNERSHIP_CLAIM_TOKEN", vm.toString(address(0)));
        vm.setEnv("OWNERSHIP_VE", vm.toString(address(ve)));
        vm.setEnv("OWNERSHIP_MINE_CORE", vm.toString(address(0)));
        vm.setEnv("OWNERSHIP_ROYALTIES", vm.toString(address(0)));
        vm.setEnv("OWNERSHIP_FURNACE", vm.toString(address(0)));
        vm.setEnv("OWNERSHIP_MARKET_ROUTER", vm.toString(address(0)));
        vm.setEnv("OWNERSHIP_FURNACE_ENTRY_TOKEN_REGISTRY", vm.toString(address(0)));
        vm.setEnv("OWNERSHIP_MINECORE_ENTRY_TOKEN_REGISTRY", vm.toString(address(0)));
        vm.setEnv("OWNERSHIP_DEX_ADAPTER", vm.toString(address(0)));
        vm.setEnv("OWNERSHIP_LP_STAKING_VAULT", vm.toString(address(0)));
        vm.setEnv("OWNERSHIP_LAUNCH_CONTROLLER", vm.toString(address(0)));
        vm.setEnv("PRIVATE_KEY", _pkEnv(ownerPk));
        vm.setEnv("NEW_OWNER", vm.toString(adminSafe));
        vm.setEnv("OWNERSHIP_ACTION", "initiate");
        vm.setEnv("ALLOW_UNSAFE_PRE_FINAL_HANDOFF", "false");

        FinalizeOwnership script = new FinalizeOwnership();

        vm.expectRevert("FinalizeOwnership: NEW_OWNER must equal TimelockController");
        script.run();
    }

    function _testFinalizeOwnershipRejectsCanonicalHandoffBeforeTimelockBootstrapFinalized() internal {
        vm.chainId(84532);

        uint256 ownerPk = 1;
        address owner = vm.addr(ownerPk);
        address bootstrapAdmin = address(0xB00757);
        _FinalizeOwnershipTimelockStub timelock = new _FinalizeOwnershipTimelockStub(bootstrapAdmin, true);
        _FinalizeOwnershipClaimTokenStub ve = new _FinalizeOwnershipClaimTokenStub(owner, false);

        vm.setEnv("OWNERSHIP_ADDRS_FROM_ENV", "true");
        vm.setEnv("OWNERSHIP_TIMELOCK", vm.toString(address(timelock)));
        vm.setEnv("OWNERSHIP_TIMELOCK_BOOTSTRAP_ADMIN", vm.toString(bootstrapAdmin));
        vm.setEnv("OWNERSHIP_CLAIM_TOKEN", vm.toString(address(0)));
        vm.setEnv("OWNERSHIP_VE", vm.toString(address(ve)));
        vm.setEnv("OWNERSHIP_MINE_CORE", vm.toString(address(0)));
        vm.setEnv("OWNERSHIP_ROYALTIES", vm.toString(address(0)));
        vm.setEnv("OWNERSHIP_FURNACE", vm.toString(address(0)));
        vm.setEnv("OWNERSHIP_MARKET_ROUTER", vm.toString(address(0)));
        vm.setEnv("OWNERSHIP_FURNACE_ENTRY_TOKEN_REGISTRY", vm.toString(address(0)));
        vm.setEnv("OWNERSHIP_MINECORE_ENTRY_TOKEN_REGISTRY", vm.toString(address(0)));
        vm.setEnv("OWNERSHIP_DEX_ADAPTER", vm.toString(address(0)));
        vm.setEnv("OWNERSHIP_LP_STAKING_VAULT", vm.toString(address(0)));
        vm.setEnv("OWNERSHIP_LAUNCH_CONTROLLER", vm.toString(address(0)));
        vm.setEnv("PRIVATE_KEY", _pkEnv(ownerPk));
        vm.setEnv("NEW_OWNER", vm.toString(address(timelock)));
        vm.setEnv("OWNERSHIP_ACTION", "initiate");
        vm.setEnv("ALLOW_UNSAFE_PRE_FINAL_HANDOFF", "false");

        FinalizeOwnership script = new FinalizeOwnership();

        vm.expectRevert("FinalizeOwnership: timelock bootstrap admin still active");
        script.run();
    }

    function _testFinalizeOwnershipRejectsCanonicalHandoffWithoutBootstrapAdminMetadata() internal {
        vm.chainId(84532);

        uint256 ownerPk = 1;
        address owner = vm.addr(ownerPk);
        address bootstrapAdmin = address(0xB00757);
        _FinalizeOwnershipTimelockStub timelock = new _FinalizeOwnershipTimelockStub(bootstrapAdmin, false);
        _FinalizeOwnershipClaimTokenStub ve = new _FinalizeOwnershipClaimTokenStub(owner, false);

        vm.setEnv("OWNERSHIP_ADDRS_FROM_ENV", "true");
        vm.setEnv("OWNERSHIP_TIMELOCK", vm.toString(address(timelock)));
        vm.setEnv("OWNERSHIP_CLAIM_TOKEN", vm.toString(address(0)));
        vm.setEnv("OWNERSHIP_VE", vm.toString(address(ve)));
        vm.setEnv("OWNERSHIP_MINE_CORE", vm.toString(address(0)));
        vm.setEnv("OWNERSHIP_ROYALTIES", vm.toString(address(0)));
        vm.setEnv("OWNERSHIP_FURNACE", vm.toString(address(0)));
        vm.setEnv("OWNERSHIP_MARKET_ROUTER", vm.toString(address(0)));
        vm.setEnv("OWNERSHIP_FURNACE_ENTRY_TOKEN_REGISTRY", vm.toString(address(0)));
        vm.setEnv("OWNERSHIP_MINECORE_ENTRY_TOKEN_REGISTRY", vm.toString(address(0)));
        vm.setEnv("OWNERSHIP_DEX_ADAPTER", vm.toString(address(0)));
        vm.setEnv("OWNERSHIP_LP_STAKING_VAULT", vm.toString(address(0)));
        vm.setEnv("OWNERSHIP_LAUNCH_CONTROLLER", vm.toString(address(0)));
        vm.setEnv("PRIVATE_KEY", _pkEnv(ownerPk));
        vm.setEnv("NEW_OWNER", vm.toString(address(timelock)));
        vm.setEnv("OWNERSHIP_ACTION", "initiate");
        vm.setEnv("ALLOW_UNSAFE_PRE_FINAL_HANDOFF", "false");

        FinalizeOwnership script = new FinalizeOwnership();

        vm.expectRevert("FinalizeOwnership: missing TimelockController.bootstrapAdmin");
        script.run();
    }

    function _testFinalizeOwnershipResolvesLiveProxyAdminWhenEnvMetadataMissing() internal {
        vm.chainId(84532);

        uint256 ownerPk = 1;
        address owner = vm.addr(ownerPk);
        address newOwner = address(0xBEEF);
        _FinalizeOwnershipLaunchControllerStub launchController = new _FinalizeOwnershipLaunchControllerStub(true);
        _FinalizeOwnershipClaimTokenStub claimToken = new _FinalizeOwnershipClaimTokenStub(address(0), true);
        _FinalizeOwnershipClaimTokenStub ve = new _FinalizeOwnershipClaimTokenStub(owner, false);
        _FinalizeOwnershipProxyMineCoreImpl mineCoreImpl = new _FinalizeOwnershipProxyMineCoreImpl();
        TransparentUpgradeableProxy mineCoreProxy = new TransparentUpgradeableProxy(
            address(mineCoreImpl),
            owner,
            abi.encodeCall(_FinalizeOwnershipProxyMineCoreImpl.initialize, (owner, address(0xCAFE), false))
        );
        address mineCoreProxyAdmin = _proxyAdminOf(address(mineCoreProxy));

        vm.setEnv("OWNERSHIP_ADDRS_FROM_ENV", "true");
        vm.setEnv("OWNERSHIP_CLAIM_TOKEN", vm.toString(address(claimToken)));
        vm.setEnv("OWNERSHIP_VE", vm.toString(address(ve)));
        vm.setEnv("OWNERSHIP_MINE_CORE", vm.toString(address(mineCoreProxy)));
        vm.setEnv("OWNERSHIP_MINE_CORE_PROXY_ADMIN", vm.toString(address(0)));
        vm.setEnv("OWNERSHIP_ROYALTIES", vm.toString(address(0)));
        vm.setEnv("OWNERSHIP_FURNACE", vm.toString(address(0)));
        vm.setEnv("OWNERSHIP_MARKET_ROUTER", vm.toString(address(0)));
        vm.setEnv("OWNERSHIP_FURNACE_ENTRY_TOKEN_REGISTRY", vm.toString(address(0)));
        vm.setEnv("OWNERSHIP_MINECORE_ENTRY_TOKEN_REGISTRY", vm.toString(address(0)));
        vm.setEnv("OWNERSHIP_DEX_ADAPTER", vm.toString(address(0)));
        vm.setEnv("OWNERSHIP_LP_STAKING_VAULT", vm.toString(address(0)));
        vm.setEnv("OWNERSHIP_LAUNCH_CONTROLLER", vm.toString(address(launchController)));
        vm.setEnv("PRIVATE_KEY", _pkEnv(ownerPk));
        vm.setEnv("NEW_OWNER", vm.toString(newOwner));
        vm.setEnv("OWNERSHIP_ACTION", "initiate");
        vm.setEnv("ALLOW_UNSAFE_PRE_FINAL_HANDOFF", "false");

        FinalizeOwnership script = new FinalizeOwnership();
        script.run();

        assertEq(_FinalizeOwnershipProxyMineCoreImpl(address(mineCoreProxy)).pendingOwner(), newOwner);
        assertEq(_FinalizeOwnershipOwnableStub(mineCoreProxyAdmin).owner(), newOwner);
    }

    function _testFinalizeOwnershipRejectsProxyAdminMetadataDrift() internal {
        vm.chainId(84532);

        uint256 ownerPk = 1;
        address owner = vm.addr(ownerPk);
        address newOwner = address(0xBEEF);
        _FinalizeOwnershipLaunchControllerStub launchController = new _FinalizeOwnershipLaunchControllerStub(true);
        _FinalizeOwnershipClaimTokenStub claimToken = new _FinalizeOwnershipClaimTokenStub(address(0), true);
        _FinalizeOwnershipProxyMineCoreImpl mineCoreImpl = new _FinalizeOwnershipProxyMineCoreImpl();
        TransparentUpgradeableProxy mineCoreProxy = new TransparentUpgradeableProxy(
            address(mineCoreImpl),
            owner,
            abi.encodeCall(_FinalizeOwnershipProxyMineCoreImpl.initialize, (owner, address(0xCAFE), false))
        );

        vm.setEnv("OWNERSHIP_ADDRS_FROM_ENV", "true");
        vm.setEnv("OWNERSHIP_CLAIM_TOKEN", vm.toString(address(claimToken)));
        vm.setEnv("OWNERSHIP_VE", vm.toString(address(0)));
        vm.setEnv("OWNERSHIP_MINE_CORE", vm.toString(address(mineCoreProxy)));
        vm.setEnv("OWNERSHIP_MINE_CORE_PROXY_ADMIN", vm.toString(address(0x1234)));
        vm.setEnv("OWNERSHIP_ROYALTIES", vm.toString(address(0)));
        vm.setEnv("OWNERSHIP_FURNACE", vm.toString(address(0)));
        vm.setEnv("OWNERSHIP_MARKET_ROUTER", vm.toString(address(0)));
        vm.setEnv("OWNERSHIP_FURNACE_ENTRY_TOKEN_REGISTRY", vm.toString(address(0)));
        vm.setEnv("OWNERSHIP_MINECORE_ENTRY_TOKEN_REGISTRY", vm.toString(address(0)));
        vm.setEnv("OWNERSHIP_DEX_ADAPTER", vm.toString(address(0)));
        vm.setEnv("OWNERSHIP_LP_STAKING_VAULT", vm.toString(address(0)));
        vm.setEnv("OWNERSHIP_LAUNCH_CONTROLLER", vm.toString(address(launchController)));
        vm.setEnv("PRIVATE_KEY", _pkEnv(ownerPk));
        vm.setEnv("NEW_OWNER", vm.toString(newOwner));
        vm.setEnv("OWNERSHIP_ACTION", "initiate");
        vm.setEnv("ALLOW_UNSAFE_PRE_FINAL_HANDOFF", "false");

        FinalizeOwnership script = new FinalizeOwnership();

        vm.expectRevert("FinalizeOwnership: proxy admin mismatch for MineCore");
        script.run();
    }

    function _testFinalizeOwnershipRejectsInitiateBeforeClaimTokenFinalized() internal {
        vm.chainId(84532);

        uint256 ownerPk = 1;
        address owner = vm.addr(ownerPk);
        address newOwner = address(0xBEEF);
        _FinalizeOwnershipLaunchControllerStub launchController = new _FinalizeOwnershipLaunchControllerStub(true);
        _FinalizeOwnershipClaimTokenStub claimToken = new _FinalizeOwnershipClaimTokenStub(owner, false);
        _FinalizeOwnershipClaimTokenStub ve = new _FinalizeOwnershipClaimTokenStub(owner, false);
        _FinalizeOwnershipClaimTokenStub royalties = new _FinalizeOwnershipClaimTokenStub(owner, false);
        _FinalizeOwnershipClaimTokenStub furnace = new _FinalizeOwnershipClaimTokenStub(owner, false);
        _FinalizeOwnershipOwnableStub market = new _FinalizeOwnershipOwnableStub(owner);
        _FinalizeOwnershipOwnableStub furnaceReg = new _FinalizeOwnershipOwnableStub(owner);
        _FinalizeOwnershipOwnableStub mineReg = new _FinalizeOwnershipOwnableStub(owner);
        _FinalizeOwnershipMineCoreFreezableStub mineCore =
            new _FinalizeOwnershipMineCoreFreezableStub(owner, address(0xCAFE));
        vm.setEnv("OWNERSHIP_ADDRS_FROM_ENV", "true");
        vm.setEnv("OWNERSHIP_CLAIM_TOKEN", vm.toString(address(claimToken)));
        vm.setEnv("OWNERSHIP_VE", vm.toString(address(ve)));
        vm.setEnv("OWNERSHIP_MINE_CORE", vm.toString(address(mineCore)));
        vm.setEnv("OWNERSHIP_ROYALTIES", vm.toString(address(royalties)));
        vm.setEnv("OWNERSHIP_FURNACE", vm.toString(address(furnace)));
        vm.setEnv("OWNERSHIP_MARKET_ROUTER", vm.toString(address(market)));
        vm.setEnv("OWNERSHIP_FURNACE_ENTRY_TOKEN_REGISTRY", vm.toString(address(furnaceReg)));
        vm.setEnv("OWNERSHIP_MINECORE_ENTRY_TOKEN_REGISTRY", vm.toString(address(mineReg)));
        vm.setEnv("OWNERSHIP_DEX_ADAPTER", vm.toString(address(0)));
        vm.setEnv("OWNERSHIP_LP_STAKING_VAULT", vm.toString(address(0)));
        vm.setEnv("OWNERSHIP_LAUNCH_CONTROLLER", vm.toString(address(launchController)));
        vm.setEnv("PRIVATE_KEY", _pkEnv(ownerPk));
        vm.setEnv("NEW_OWNER", vm.toString(newOwner));
        vm.setEnv("OWNERSHIP_ACTION", "initiate");
        vm.setEnv("ALLOW_UNSAFE_PRE_FINAL_HANDOFF", "false");

        FinalizeOwnership script = new FinalizeOwnership();

        vm.expectRevert("FinalizeOwnership: ClaimToken not frozen");
        script.run();
    }

    function _testFinalizeOwnershipRejectsInitiateBeforeClaimTokenOwnerRenounced() internal {
        vm.chainId(84532);

        uint256 ownerPk = 1;
        address owner = vm.addr(ownerPk);
        address newOwner = address(0xBEEF);
        _FinalizeOwnershipLaunchControllerStub launchController = new _FinalizeOwnershipLaunchControllerStub(true);
        _FinalizeOwnershipClaimTokenStub claimToken = new _FinalizeOwnershipClaimTokenStub(owner, true);
        _FinalizeOwnershipClaimTokenStub ve = new _FinalizeOwnershipClaimTokenStub(owner, false);
        _FinalizeOwnershipClaimTokenStub royalties = new _FinalizeOwnershipClaimTokenStub(owner, false);
        _FinalizeOwnershipClaimTokenStub furnace = new _FinalizeOwnershipClaimTokenStub(owner, false);
        _FinalizeOwnershipOwnableStub market = new _FinalizeOwnershipOwnableStub(owner);
        _FinalizeOwnershipOwnableStub furnaceReg = new _FinalizeOwnershipOwnableStub(owner);
        _FinalizeOwnershipOwnableStub mineReg = new _FinalizeOwnershipOwnableStub(owner);
        _FinalizeOwnershipMineCoreFreezableStub mineCore =
            new _FinalizeOwnershipMineCoreFreezableStub(owner, address(0xCAFE));

        vm.setEnv("OWNERSHIP_ADDRS_FROM_ENV", "true");
        vm.setEnv("OWNERSHIP_CLAIM_TOKEN", vm.toString(address(claimToken)));
        vm.setEnv("OWNERSHIP_VE", vm.toString(address(ve)));
        vm.setEnv("OWNERSHIP_MINE_CORE", vm.toString(address(mineCore)));
        vm.setEnv("OWNERSHIP_ROYALTIES", vm.toString(address(royalties)));
        vm.setEnv("OWNERSHIP_FURNACE", vm.toString(address(furnace)));
        vm.setEnv("OWNERSHIP_MARKET_ROUTER", vm.toString(address(market)));
        vm.setEnv("OWNERSHIP_FURNACE_ENTRY_TOKEN_REGISTRY", vm.toString(address(furnaceReg)));
        vm.setEnv("OWNERSHIP_MINECORE_ENTRY_TOKEN_REGISTRY", vm.toString(address(mineReg)));
        vm.setEnv("OWNERSHIP_DEX_ADAPTER", vm.toString(address(0)));
        vm.setEnv("OWNERSHIP_LP_STAKING_VAULT", vm.toString(address(0)));
        vm.setEnv("OWNERSHIP_LAUNCH_CONTROLLER", vm.toString(address(launchController)));
        vm.setEnv("PRIVATE_KEY", _pkEnv(ownerPk));
        vm.setEnv("NEW_OWNER", vm.toString(newOwner));
        vm.setEnv("OWNERSHIP_ACTION", "initiate");
        vm.setEnv("ALLOW_UNSAFE_PRE_FINAL_HANDOFF", "false");

        FinalizeOwnership script = new FinalizeOwnership();

        vm.expectRevert("FinalizeOwnership: ClaimToken owner not renounced");
        script.run();
    }

    function _testFinalizeGenesisRevertsIfPrivateKeyDoesNotControlMineCoreOwner() internal {
        vm.chainId(84532);

        uint256 guardianPk = 1;
        address guardianEoa = vm.addr(guardianPk);
        address differentOwner = address(0xBEEF);
        address longTermGuardian = address(0xCAFE);

        _FinalizeGenesisLaunchControllerStub launchController = new _FinalizeGenesisLaunchControllerStub(guardianEoa);
        _FinalizeGenesisMineCoreStub mineCore =
            new _FinalizeGenesisMineCoreStub(differentOwner, address(launchController));
        _FinalizeGenesisLpVaultStub vault = new _FinalizeGenesisLpVaultStub();

        string memory manifest = string.concat(
            '{"contracts":{"LaunchController":{"address":"',
            vm.toString(address(launchController)),
            '"},"MineCore":{"address":"',
            vm.toString(address(mineCore)),
            '"},"GenesisLPVault24M":{"address":"',
            vm.toString(address(vault)),
            '"}}}'
        );
        vm.setEnv("DEPLOYMENTS_MANIFEST_JSON", manifest);

        vm.setEnv("PRIVATE_KEY", _pkEnv(guardianPk));
        vm.setEnv("GUARDIAN", vm.toString(longTermGuardian));

        FinalizeGenesis script = new FinalizeGenesis();

        vm.expectRevert(
            "FinalizeGenesis: signer must control MineCore.owner while MineCore.guardian is LaunchController"
        );
        script.run();
    }

    function _testBroadcastSignerUsesLedgerAddressOnMainnet() internal {
        vm.chainId(8453);

        address ledger = address(0xBEEF);
        vm.setEnv("LEDGER_ADDRESS", vm.toString(ledger));

        _BroadcastSignerHarness harness = new _BroadcastSignerHarness();
        (address account, uint256 privateKey, bool usePrivateKey) = harness.resolve();

        assertEq(account, ledger);
        assertEq(privateKey, 0);
        assertFalse(usePrivateKey);
    }

    function _testBroadcastSignerRejectsExplicitSignerPrivateKeyMismatch() internal {
        vm.chainId(8453);

        vm.setEnv("SIGNER_ADDRESS", vm.toString(address(0xBEEF)));
        vm.setEnv("PRIVATE_KEY", _pkEnv(1));

        _BroadcastSignerHarness harness = new _BroadcastSignerHarness();
        vm.expectRevert("BroadcastSigner: SIGNER_ADDRESS/PRIVATE_KEY mismatch");
        harness.resolve();
    }

    function _testFinalizeLocalGenesisRevertsIfPrivateKeyDoesNotControlMineCoreOwner() internal {
        vm.chainId(31337);

        uint256 guardianPk = 1;
        address guardianEoa = vm.addr(guardianPk);
        address differentOwner = address(0xBEEF);

        _FinalizeGenesisLaunchControllerStub launchController = new _FinalizeGenesisLaunchControllerStub(guardianEoa);
        _FinalizeGenesisMineCoreStub mineCore =
            new _FinalizeGenesisMineCoreStub(differentOwner, address(launchController));
        _FinalizeGenesisLpVaultStub vault = new _FinalizeGenesisLpVaultStub();

        string memory manifest = string.concat(
            '{"contracts":{"LaunchController":{"address":"',
            vm.toString(address(launchController)),
            '"},"MineCore":{"address":"',
            vm.toString(address(mineCore)),
            '"},"GenesisLPVault24M":{"address":"',
            vm.toString(address(vault)),
            '"}}}'
        );
        vm.setEnv("DEPLOYMENTS_MANIFEST_JSON", manifest);

        vm.setEnv("LOCAL_PRIVATE_KEY", _pkEnv(guardianPk));

        FinalizeLocalGenesis script = new FinalizeLocalGenesis();

        vm.expectRevert(
            "FinalizeLocalGenesis: LOCAL_PRIVATE_KEY must control MineCore.owner while MineCore.guardian is LaunchController"
        );
        script.run();
    }

    function _testFinalizeLocalGenesisRejectsGuardianEqualLaunchController() internal {
        vm.chainId(31337);

        uint256 guardianPk = 1;
        address guardianEoa = vm.addr(guardianPk);

        _FinalizeGenesisLaunchControllerStub launchController = new _FinalizeGenesisLaunchControllerStub(guardianEoa);
        _FinalizeGenesisMineCoreStub mineCore = new _FinalizeGenesisMineCoreStub(guardianEoa, address(launchController));
        _FinalizeGenesisLpVaultStub vault = new _FinalizeGenesisLpVaultStub();

        string memory manifest = string.concat(
            '{"contracts":{"LaunchController":{"address":"',
            vm.toString(address(launchController)),
            '"},"MineCore":{"address":"',
            vm.toString(address(mineCore)),
            '"},"GenesisLPVault24M":{"address":"',
            vm.toString(address(vault)),
            '"}}}'
        );
        vm.setEnv("DEPLOYMENTS_MANIFEST_JSON", manifest);

        vm.setEnv("LOCAL_PRIVATE_KEY", _pkEnv(guardianPk));
        vm.setEnv("GUARDIAN", vm.toString(address(launchController)));

        FinalizeLocalGenesis script = new FinalizeLocalGenesis();

        vm.expectRevert("FinalizeLocalGenesis: GUARDIAN must not equal LaunchController");
        script.run();
    }

    function _testFinalizeGenesisPreflightPreventsPartialFinalization() internal {
        vm.chainId(84532);

        uint256 guardianPk = 1;
        address guardianEoa = vm.addr(guardianPk);
        address longTermGuardian = address(0xCAFE);

        _FinalizeGenesisLaunchControllerStub launchController = new _FinalizeGenesisLaunchControllerStub(guardianEoa);
        _FinalizeGenesisMineCoreStub mineCore = new _FinalizeGenesisMineCoreStub(guardianEoa, address(launchController));
        _FinalizeGenesisLpVaultStub vault = new _FinalizeGenesisLpVaultStub();

        string memory manifest = string.concat(
            '{"contracts":{"LaunchController":{"address":"',
            vm.toString(address(launchController)),
            '"},"MineCore":{"address":"',
            vm.toString(address(mineCore)),
            '"},"GenesisLPVault24M":{"address":"',
            vm.toString(address(vault)),
            '"}}}'
        );
        vm.setEnv("DEPLOYMENTS_MANIFEST_JSON", manifest);
        vm.setEnv("PRIVATE_KEY", _pkEnv(guardianPk));
        vm.setEnv("GUARDIAN", vm.toString(longTermGuardian));
        vm.deal(guardianEoa, 100 ether);

        FinalizeGenesis script = new FinalizeGenesis();

        vm.expectRevert("FinalizeGenesis: takeovers still paused");
        script.run();

        assertFalse(launchController.finalized(), "preflight should prevent partial genesis finalization");
        assertEq(
            mineCore.guardian(), address(launchController), "preflight should roll back MineCore guardian rotation"
        );
    }

    function _testFinalizeLocalGenesisPreflightPreventsPartialFinalization() internal {
        vm.chainId(31337);

        uint256 guardianPk = 1;
        address guardianEoa = vm.addr(guardianPk);
        address longTermGuardian = address(0xCAFE);

        _FinalizeGenesisLaunchControllerStub launchController = new _FinalizeGenesisLaunchControllerStub(guardianEoa);
        _FinalizeGenesisMineCoreStub mineCore = new _FinalizeGenesisMineCoreStub(guardianEoa, address(launchController));
        _FinalizeGenesisLpVaultStub vault = new _FinalizeGenesisLpVaultStub();

        string memory manifest = string.concat(
            '{"contracts":{"LaunchController":{"address":"',
            vm.toString(address(launchController)),
            '"},"MineCore":{"address":"',
            vm.toString(address(mineCore)),
            '"},"GenesisLPVault24M":{"address":"',
            vm.toString(address(vault)),
            '"}}}'
        );
        vm.setEnv("DEPLOYMENTS_MANIFEST_JSON", manifest);
        vm.setEnv("LOCAL_PRIVATE_KEY", _pkEnv(guardianPk));
        vm.setEnv("GUARDIAN", vm.toString(longTermGuardian));
        vm.deal(guardianEoa, 100 ether);

        FinalizeLocalGenesis script = new FinalizeLocalGenesis();

        vm.expectRevert("FinalizeLocalGenesis: takeovers still paused");
        script.run();

        assertFalse(launchController.finalized(), "preflight should prevent partial local genesis finalization");
        assertEq(
            mineCore.guardian(),
            address(launchController),
            "preflight should roll back local MineCore guardian rotation"
        );
    }

    /// @dev Exercises the same reciprocal wiring checks Wire.s.sol relies on before ClaimToken.freezeConfig().
    function testClaimTokenFreezeConfigSucceedsWhenMineCoreWired() public {
        vm.chainId(31337);

        address owner = vm.addr(1);
        ClaimToken claim = new ClaimToken(owner);
        VeClaimNFTHarness ve = new VeClaimNFTHarness(address(claim), owner);
        ShareholderRoyalties royalties = new ShareholderRoyalties(address(ve), owner);
        MineCore mineCore = new MineCore(address(claim), address(ve), address(royalties), owner);

        vm.startPrank(owner);
        claim.setMineCore(address(mineCore));
        assertFalse(claim.configFrozen());
        claim.freezeConfig();
        vm.stopPrank();

        assertTrue(claim.configFrozen());
        assertEq(claim.mineCore(), address(mineCore));
    }

    function testWireRejectsFrozenClaimTokenMineCoreDrift() public {
        vm.chainId(31337);

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
        ClaimAllHelper replacementHelper = new ClaimAllHelper(address(royalties), address(replacementMineCore));
        DelegationHub delegationHub = new DelegationHub();
        LocalWETH weth = new LocalWETH();

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

        // MaintenanceHub constructor calls _requireCanonicalBundle() which validates
        // the full cross-contract wiring, so it must be created after wiring is complete.
        MaintenanceHub maintenanceHub = new MaintenanceHub(
            address(marketRouter), address(furnace), address(ve), address(royalties), address(weth), address(0xDE5C0E)
        );

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
        addrs.maintenanceHub = address(maintenanceHub);

        _WireHarness harness = new _WireHarness();

        vm.expectRevert(bytes("Wire: frozen ClaimToken.mineCore mismatch"));
        vm.startPrank(owner);
        harness.execute(addrs, owner, address(0), true, false, false);

        assertEq(claim.mineCore(), address(mineCore), "revert should preserve frozen ClaimToken root");
        assertEq(furnace.mineCore(), address(mineCore), "revert should preserve live Furnace root");
    }

    function testConfigureLocalPathBPreflightPreventsPartialRegistryMutation() public {
        vm.chainId(31337);

        address owner = vm.addr(1);
        _ConfigureLocalPathBRegistryStub furnaceReg = new _ConfigureLocalPathBRegistryStub(owner, true);
        _ConfigureLocalPathBRegistryStub mineReg = new _ConfigureLocalPathBRegistryStub(owner, false);
        _ConfigureLocalPathBHarness harness = new _ConfigureLocalPathBHarness();

        _runConfigureLocalPathBPreflight(harness, furnaceReg, mineReg, owner);

        assertFalse(furnaceReg.routerConfigured(), "preflight revert should roll back furnace router config");
        assertFalse(mineReg.routerConfigured(), "preflight revert should roll back mine router config");
        assertEq(furnaceReg.wethClaimHop(), address(0), "preflight revert should roll back WETH/CLAIM hop");
        assertEq(mineReg.lastTokenConfigPool(), address(0), "preflight revert should roll back mine token config");
        assertEq(furnaceReg.lastTokenConfigPool(), address(0), "preflight revert should roll back furnace token config");
    }

    function _runConfigureLocalPathBPreflight(
        _ConfigureLocalPathBHarness harness,
        _ConfigureLocalPathBRegistryStub furnaceReg,
        _ConfigureLocalPathBRegistryStub mineReg,
        address owner
    ) internal {
        address pool = address(new _CodeStub());
        address token = address(new _CodeStub());
        address stub = address(new _CodeStub());
        vm.expectRevert(bytes("stub token config revert"));
        harness.preflight(address(furnaceReg), address(mineReg), stub, stub, stub, stub, pool, token, pool, pool, owner);
    }

    function _buildWireAddrsWithMaintenanceHub(address owner)
        internal
        returns (Wire.Addrs memory addrs, MarketRouter market, address longTermGuardian)
    {
        ClaimToken claim = new ClaimToken(owner);
        VeClaimNFTHarness ve = new VeClaimNFTHarness(address(claim), owner);
        address royalties = address(new ShareholderRoyalties(address(ve), owner));
        Furnace furnace = new Furnace(
            address(claim), address(ve), address(new FurnaceGuardHelper(address(claim), address(ve))), owner
        );
        MineCore mineCore = new MineCore(address(claim), address(ve), address(royalties), owner);

        market = new MarketRouter(address(claim), address(ve), royalties, owner);
        longTermGuardian = address(new _CanonicalGenesisGuardianStub(address(mineCore), address(claim)));

        vm.startPrank(owner);
        claim.setMineCore(address(mineCore));
        furnace.setMineCore(address(mineCore));
        mineCore.setFurnace(address(furnace));
        furnace.setShareholderRoyalties(royalties);
        ShareholderRoyalties(royalties).setWiring(address(mineCore), address(market), address(furnace));
        vm.stopPrank();

        addrs.claimToken = address(claim);
        addrs.ve = address(ve);
        addrs.royalties = royalties;
        addrs.furnace = address(furnace);
        addrs.marketRouter = address(market);
        addrs.mineCore = address(mineCore);
        addrs.furnaceEntryTokenRegistry = address(new EntryTokenRegistry(owner));
        addrs.mineCoreEntryTokenRegistry = address(new EntryTokenRegistry(owner));
        addrs.claimAllHelper = address(new ClaimAllHelper(royalties, address(mineCore)));
        addrs.delegationHub = address(new DelegationHub());
        addrs.maintenanceHub = address(new _CodeStub());
    }

    function _testWirePreflightRollsBackSuccessfulSimulation() internal {
        vm.chainId(31337);

        address owner = vm.addr(1);
        (Wire.Addrs memory addrs,, address longTermGuardian) = _buildWireAddrsWithMaintenanceHub(owner);

        VeClaimNFTHarness ve = VeClaimNFTHarness(addrs.ve);
        ClaimToken claim = ClaimToken(addrs.claimToken);
        Furnace furnace = Furnace(payable(addrs.furnace));
        MineCore mineCore = MineCore(payable(addrs.mineCore));

        _WireHarness harness = new _WireHarness();

        address mineCoreBefore = claim.mineCore();
        address quoterBefore = furnace.furnaceQuoter();

        harness.preflight(addrs, owner, longTermGuardian, true, false, false);

        assertEq(claim.mineCore(), mineCoreBefore, "preflight should roll back ClaimToken wiring");
        assertEq(furnace.furnaceQuoter(), quoterBefore, "preflight should roll back helper deployments");
        assertEq(mineCore.guardian(), owner, "preflight should roll back MineCore guardian rotation");
    }

    function _testWireLeavesMaintenanceHubOffSettlementKeeperByDefault() internal {
        vm.chainId(31337);

        (Wire.Addrs memory addrs, MarketRouter marketRouter, MaintenanceHub maintenanceHub, address owner) =
            _deployWireHarnessBundle();

        address settlementKeeper = makeAddr("settlementKeeper");
        vm.setEnv("SETTLEMENT_KEEPER", vm.toString(settlementKeeper));
        vm.setEnv("ALLOW_MAINTENANCE_HUB_SETTLEMENT_KEEPER", "false");

        _WireHarness harness = new _WireHarness();
        vm.startPrank(owner);
        harness.execute(addrs, owner, address(0), true, false, false);

        assertTrue(
            marketRouter.isSettlementKeeper(settlementKeeper), "explicit settlement keeper should still be wired"
        );
        assertFalse(
            marketRouter.isSettlementKeeper(address(maintenanceHub)),
            "MaintenanceHub should stay off settlement keeper allowlist by default"
        );
    }

    function _testWireRevertsWhenSettlementKeeperIsMaintenanceHubWithoutOptIn() internal {
        vm.chainId(31337);

        (Wire.Addrs memory addrs,, MaintenanceHub maintenanceHub, address owner) = _deployWireHarnessBundle();

        vm.setEnv("SETTLEMENT_KEEPER", vm.toString(address(maintenanceHub)));
        vm.setEnv("ALLOW_MAINTENANCE_HUB_SETTLEMENT_KEEPER", "false");

        _WireHarness harness = new _WireHarness();

        vm.expectRevert(
            bytes("Wire: MaintenanceHub settlement keeper requires ALLOW_MAINTENANCE_HUB_SETTLEMENT_KEEPER")
        );
        vm.startPrank(owner);
        harness.execute(addrs, owner, address(0), true, false, false);
    }

    function _testWireAllowsMaintenanceHubSettlementKeeperWhenExplicitlyOptedIn() internal {
        vm.chainId(31337);

        (Wire.Addrs memory addrs, MarketRouter marketRouter, MaintenanceHub maintenanceHub, address owner) =
            _deployWireHarnessBundle();

        vm.setEnv("SETTLEMENT_KEEPER", vm.toString(address(0)));
        vm.setEnv("ALLOW_MAINTENANCE_HUB_SETTLEMENT_KEEPER", "true");

        _WireHarness harness = new _WireHarness();
        vm.startPrank(owner);
        harness.execute(addrs, owner, address(0), true, false, false);

        assertTrue(
            marketRouter.isSettlementKeeper(address(maintenanceHub)),
            "MaintenanceHub settlement keeper should require explicit opt-in"
        );
    }

    function _testDeployAgentLensRejectsNonContractRequiredAddress() internal {
        vm.chainId(84532);

        AgentLensRequiredBundle memory bundle = _deployAgentLensRequiredBundle();
        _setAgentLensRequiredEnv(bundle);
        vm.setEnv("CLAIM_TOKEN", vm.toString(address(0xBEEF)));

        DeployAgentLens script = new DeployAgentLens();

        vm.expectRevert("DeployAgentLens: claimToken is not a contract");
        script.run();
    }

    function _testDeployAgentLensRejectsNonContractOptionalAddress() internal {
        vm.chainId(84532);

        AgentLensRequiredBundle memory bundle = _deployAgentLensRequiredBundle();
        _setAgentLensRequiredEnv(bundle);
        vm.setEnv("MARKET_ROUTER", vm.toString(address(0xBEEF)));

        DeployAgentLens script = new DeployAgentLens();

        vm.expectRevert("DeployAgentLens: marketRouter is not a contract");
        script.run();
    }

    function _testDeployAgentLensRejectsLiveMixedMarketRouterBundle() internal {
        vm.chainId(84532);

        AgentLensRequiredBundle memory bundle = _deployAgentLensRequiredBundle();
        _setAgentLensRequiredEnv(bundle);

        MarketRouter wrongMarket = new MarketRouter(
            address(bundle.claimToken), address(bundle.veClaimNFT), address(bundle.shareholderRoyalties), bundle.owner
        );
        vm.setEnv("MARKET_ROUTER", vm.toString(address(wrongMarket)));

        DeployAgentLens script = new DeployAgentLens();

        vm.expectRevert("DeployAgentLens: veClaimNFT.mineMarket mismatch");
        script.run();
    }

    function _testDeployAgentLensRejectsMixedMaintenanceHubBundle() internal {
        vm.chainId(84532);

        AgentLensRequiredBundle memory bundle = _deployAgentLensRequiredBundle();
        _setAgentLensRequiredEnv(bundle);

        LocalWETH expectedWeth = new LocalWETH();
        LocalWETH wrongWeth = new LocalWETH();
        _CodeStub factory = new _CodeStub();
        _CodeStub pool = new _CodeStub();
        _DeployDexRootStub dexAdapter = new _DeployDexRootStub(address(factory), address(expectedWeth), address(pool));
        MaintenanceHub staleHub = new MaintenanceHub(
            address(bundle.marketRouter),
            address(bundle.furnace),
            address(bundle.veClaimNFT),
            address(bundle.shareholderRoyalties),
            address(wrongWeth),
            address(0xDE5C0E)
        );

        vm.setEnv("MARKET_ROUTER", vm.toString(address(bundle.marketRouter)));
        vm.setEnv("DEX_ADAPTER", vm.toString(address(dexAdapter)));
        vm.setEnv("MAINTENANCE_HUB", vm.toString(address(staleHub)));

        DeployAgentLens script = new DeployAgentLens();

        vm.expectRevert("DeployAgentLens: maintenanceHub.weth mismatch");
        script.run();
    }

    function _testDeployAgentLensRejectsLpVaultWithoutDexAdapter() internal {
        vm.chainId(84532);

        AgentLensRequiredBundle memory bundle = _deployAgentLensRequiredBundle();
        _setAgentLensRequiredEnv(bundle);
        vm.setEnv("LP_STAKING_VAULT_7D", vm.toString(address(new _CodeStub())));

        DeployAgentLens script = new DeployAgentLens();

        vm.expectRevert("DeployAgentLens: lpStakingVault7D requires dexAdapter");
        script.run();
    }

    function _testDeployAgentLensRejectsLaunchControllerWithoutGenesisVault() internal {
        vm.chainId(84532);

        AgentLensRequiredBundle memory bundle = _deployAgentLensRequiredBundle();
        _setAgentLensRequiredEnv(bundle);

        LocalWETH weth = new LocalWETH();
        _CodeStub factory = new _CodeStub();
        _CodeStub pool = new _CodeStub();
        _DeployDexRootStub dexAdapter = new _DeployDexRootStub(address(factory), address(weth), address(pool));
        vm.setEnv("DEX_ADAPTER", vm.toString(address(dexAdapter)));
        vm.setEnv("LAUNCH_CONTROLLER", vm.toString(address(new _CodeStub())));

        DeployAgentLens script = new DeployAgentLens();

        vm.expectRevert("DeployAgentLens: launchController requires genesisLPVault24M");
        script.run();
    }
}
