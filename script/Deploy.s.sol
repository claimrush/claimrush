// SPDX-License-Identifier: MIT
pragma solidity ^0.8.34;

import {console2} from "forge-std/console2.sol";
import {BroadcastSignerBase} from "./lib/BroadcastSignerBase.sol";

import {ClaimToken} from "../src/ClaimToken.sol";
import {VeClaimNFT} from "../src/VeClaimNFT.sol";
import {ShareholderRoyalties} from "../src/ShareholderRoyalties.sol";
import {Furnace} from "../src/Furnace.sol";
import {FurnaceGuardHelper} from "../src/FurnaceGuardHelper.sol";
import {MarketRouter} from "../src/MarketRouter.sol";
import {MineCore} from "../src/MineCore.sol";
import {MineCoreQuoter} from "../src/MineCoreQuoter.sol";
import {ClaimAllHelper} from "../src/ClaimAllHelper.sol";
import {EntryTokenRegistry} from "../src/EntryTokenRegistry.sol";
import {DexAdapter} from "../src/DexAdapter.sol";
import {TimelockController} from "lib/openzeppelin-contracts/contracts/governance/TimelockController.sol";
import {ProxyAdmin} from "lib/openzeppelin-contracts/contracts/proxy/transparent/ProxyAdmin.sol";
import {
    FurnaceProxy,
    MarketRouterProxy,
    MineCoreProxy,
    ShareholderRoyaltiesProxy
} from "../src/lib/RuntimeProxyWrappers.sol";

import {LpStakingVault7D} from "../src/vault/LpStakingVault7D.sol";
import {GenesisLPVault24M} from "../src/vault/GenesisLPVault24M.sol";

import {LaunchController} from "../src/genesis/LaunchController.sol";

import {DelegationHub} from "../src/DelegationHub.sol";
import {IPoolFactory} from "../src/interfaces/IPoolFactory.sol";

/// @notice Production deployment for ClaimRush v1.0.0 on Base mainnet / Base Sepolia.
/// @dev This script ONLY deploys contracts. Wiring is done by script/Wire.s.sol; freezing and proxy admin burn by script/FreezeAndBurn.s.sol (via timelock).
///      It simulates the full constructor sequence before broadcasting so a malformed Aerodrome router,
///      wrong LP recipient, or late constructor revert cannot leave a partial live deployment onchain.
///
/// Required signer input:
/// - local chains: LOCAL_PRIVATE_KEY (preferred), fallback PRIVATE_KEY
/// - Base Sepolia: PRIVATE_KEY
/// - Base mainnet: LEDGER_ADDRESS / SIGNER_ADDRESS with `forge script ... --ledger --sender <address>`
///                 or PRIVATE_KEY as a fallback if explicitly desired
/// - AERODROME_ROUTER    Raw Aerodrome router address (the DexAdapter wraps this).
/// - ADMIN_SAFE          Safe / governance proposer-executor for the deployment timelock.
///
/// Optional env:
/// - INITIAL_OWNER           Owner for Ownable2Step contracts (defaults to deployer).
///                           ALSO becomes LaunchController.guardian, so the production-safe flow is to keep this
///                           as the deployer through Wire / genesis / Freeze, then transfer to the long-term
///                           multisig or timelock via FinalizeOwnership.s.sol.
/// - ALLOW_NON_DEPLOYER_INITIAL_OWNER
///                           Explicit opt-in for advanced split-key flows where INITIAL_OWNER != deployer.
///                           Leave unset for the recommended single-key deployment / wiring sequence.
/// - ALLOW_NON_CANONICAL_ADMIN_SAFE
///                           Break-glass override for Base mainnet only when ADMIN_SAFE intentionally differs from
///                           the canonical v1.0.0 governance Safe pinned in this release.
/// - ALLOW_NON_CANONICAL_LP_WITHDRAW_RECIPIENT
///                           Break-glass override for Base mainnet only when LP_WITHDRAW_RECIPIENT intentionally
///                           differs from the canonical v1.0.0 withdrawal recipient pinned in this release.
/// - TIMELOCK_DELAY_SECONDS  Override the default governance timelock delay.
///                           Defaults: 48 hours on Base mainnet, 1 hour on Base Sepolia.
/// - ALLOW_UNSAFE_MAINNET_TIMELOCK_DELAY
///                           Break-glass only. Required to deploy with TIMELOCK_DELAY_SECONDS below 48 hours
///                           on Base mainnet.
///
/// Required on Base mainnet / Base Sepolia:
/// - LP_WITHDRAW_RECIPIENT   Long-term GenesisLPVault24M withdrawal recipient.
///                           This recipient is immutable in the vault and is NOT updated by later
///                           ownership handoff, so production/testnet deploys must set it explicitly.
contract Deploy is BroadcastSignerBase {
    bytes32 internal constant _IMPLEMENTATION_SLOT = 0x360894a13ba1a3210667c828492db98dca3e2076cc3735a920a3ca505d382bbc;
    bytes32 internal constant _ADMIN_SLOT = 0xb53127684a568b3173ae13b9f8a6016e243e63b6e8ee1178d6a717850b5d6103;
    address internal constant _BASE_MAINNET_AERODROME_ROUTER = 0xcF77a3Ba9A5CA399B7c97c74d54e5b1Beb874E43;
    address internal constant _BASE_MAINNET_AERODROME_FACTORY = 0x420DD381b31aEf6683db6B902084cB0FFECe40Da;
    address internal constant _BASE_MAINNET_ADMIN_SAFE = 0x73301C90691e72E021F161D8E568E1d797bC58bA;
    address internal constant _BASE_MAINNET_LP_WITHDRAW_RECIPIENT = 0xE12f0a3557309c225890dBa8D4a42f5300110554;

    struct DeployConfig {
        BroadcastSigner broadcaster;
        address deployer;
        address initialOwner;
        address adminSafe;
        address lpWithdrawRecipient;
        address aerodromeRouter;
        bool wethClaimStable;
        uint256 timelockDelaySeconds;
    }

    struct Deployed {
        address claimToken;
        address ve;
        address royalties;
        address royaltiesImplementation;
        address royaltiesProxyAdmin;
        address furnace;
        address furnaceImplementation;
        address furnaceProxyAdmin;
        address furnaceGuardHelper;
        address furnaceExtendHelper;
        address market;
        address marketImplementation;
        address marketProxyAdmin;
        address mineCore;
        address mineCoreImplementation;
        address mineCoreProxyAdmin;
        address mineCoreQuoter;
        address claimAll;
        address dexAdapter;
        address timelock;
        address furnaceEntryTokenRegistry;
        address mineCoreEntryTokenRegistry;
        address genesisLpVault24M;
        address lpStakingVault7D;
        address launchController;
        address delegationHub;
        address expectedPool;
        address weth;
        address factory;
    }

    function run() external {
        // Safety: this script is only meant for Base mainnet / Base Sepolia.
        uint256 cid = block.chainid;
        //
        //   Deploy.s.sol pins known Base mainnet/Sepolia constants (router, admin safe, etc.)
        //   and validates them at deployment time. AERODROME_ROUTER override is read from env.
        require(cid == 8453 || cid == 84532, "Deploy: unsupported chainId");

        DeployConfig memory c = _loadConfig();

        console2.log("Deploy: simulating full deployment sequence before broadcast...");
        _preflightDeploySequence(c);
        console2.log("Deploy: preflight simulation passed.");

        _startBroadcast(c.broadcaster);
        Deployed memory d = _executeDeploySequence(c);
        vm.stopBroadcast();

        _logDeploy(c.deployer, c.initialOwner, d);
    }

    function _loadConfig() internal returns (DeployConfig memory c) {
        c.broadcaster = _resolveBroadcastSigner();
        c.deployer = c.broadcaster.account;

        c.initialOwner = _envAddressOrZero("INITIAL_OWNER");
        if (c.initialOwner == address(0)) c.initialOwner = c.deployer;
        if (c.initialOwner != c.deployer) {
            require(
                _envBool("ALLOW_NON_DEPLOYER_INITIAL_OWNER"),
                "Deploy: INITIAL_OWNER != deployer; set ALLOW_NON_DEPLOYER_INITIAL_OWNER=true for split-key flow"
            );
        }

        c.lpWithdrawRecipient = _envAddressOrZero("LP_WITHDRAW_RECIPIENT");
        require(
            c.lpWithdrawRecipient != address(0), "Deploy: LP_WITHDRAW_RECIPIENT must be set explicitly on real networks"
        );

        c.aerodromeRouter = vm.envAddress("AERODROME_ROUTER");
        require(c.aerodromeRouter != address(0), "Deploy: AERODROME_ROUTER=0");
        require(c.aerodromeRouter.code.length > 0, "Deploy: AERODROME_ROUTER is not a contract");

        c.adminSafe = vm.envAddress("ADMIN_SAFE");
        require(c.adminSafe != address(0), "Deploy: ADMIN_SAFE=0");
        require(c.adminSafe.code.length > 0, "Deploy: ADMIN_SAFE is not a contract");

        uint256 defaultDelay = block.chainid == 8453 ? 48 hours : 1 hours;
        c.timelockDelaySeconds = _envUintOr("TIMELOCK_DELAY_SECONDS", defaultDelay);
        _requireValidMainnetTimelockDelay(c.timelockDelaySeconds, _envBool("ALLOW_UNSAFE_MAINNET_TIMELOCK_DELAY"));

        if (block.chainid == 8453) {
            require(
                c.aerodromeRouter == _BASE_MAINNET_AERODROME_ROUTER,
                "Deploy: AERODROME_ROUTER does not match canonical Base mainnet address"
            );
            if (c.adminSafe != _BASE_MAINNET_ADMIN_SAFE) {
                require(
                    _envBool("ALLOW_NON_CANONICAL_ADMIN_SAFE"),
                    "Deploy: ADMIN_SAFE does not match canonical Base mainnet address"
                );
            }
            if (c.lpWithdrawRecipient != _BASE_MAINNET_LP_WITHDRAW_RECIPIENT) {
                require(
                    _envBool("ALLOW_NON_CANONICAL_LP_WITHDRAW_RECIPIENT"),
                    "Deploy: LP_WITHDRAW_RECIPIENT does not match canonical Base mainnet address"
                );
            }
        }

        // v1.0.0 canonical pool: volatile (stable=false)
        c.wethClaimStable = false;
    }

    function _preflightDeploySequence(DeployConfig memory c) internal {
        uint256 snap = vm.snapshot();
        vm.startPrank(c.deployer);
        _executeDeploySequence(c);
        vm.stopPrank();
        require(vm.revertTo(snap), "Deploy: failed to revert preflight snapshot");
    }

    function _executeDeploySequence(DeployConfig memory c) internal returns (Deployed memory d) {
        // ------------------------------------------------------------
        // Core protocol contracts
        // ------------------------------------------------------------

        {
            ClaimToken claimToken = new ClaimToken(c.initialOwner);
            d.claimToken = address(claimToken);
        }

        // ------------------------------------------------------------
        // DexAdapter + token-entry registries (two independent instances)
        // ------------------------------------------------------------

        {
            DexAdapter dexAdapter = new DexAdapter(c.aerodromeRouter, c.initialOwner);
            d.dexAdapter = address(dexAdapter);

            // Canonical WETH and factory are pinned by the DexAdapter.
            d.weth = dexAdapter.weth();
            d.factory = dexAdapter.defaultFactory();
            require(d.weth.code.length > 0, "Deploy: DexAdapter.weth is not a contract");
            require(d.factory.code.length > 0, "Deploy: DexAdapter.defaultFactory is not a contract");
            if (block.chainid == 8453) {
                require(
                    d.factory == _BASE_MAINNET_AERODROME_FACTORY,
                    "Deploy: DexAdapter.defaultFactory does not match canonical Base mainnet Aerodrome factory"
                );
            }

            // Canonical expected pool address is deterministic (even if pool is created later by LaunchController).
            d.expectedPool = dexAdapter.poolFor(d.weth, d.claimToken, c.wethClaimStable, d.factory);
            require(d.expectedPool != address(0), "Deploy: poolFor returned 0");
        }

        {
            VeClaimNFT ve = new VeClaimNFT(d.claimToken, c.initialOwner);
            d.ve = address(ve);
        }
        {
            ShareholderRoyalties royaltiesImpl = new ShareholderRoyalties(d.ve, address(0));
            d.royaltiesImplementation = address(royaltiesImpl);
            d.royalties = address(
                new ShareholderRoyaltiesProxy(
                    d.royaltiesImplementation,
                    c.initialOwner,
                    abi.encodeCall(ShareholderRoyalties.initialize, (c.initialOwner))
                )
            );
            d.royaltiesProxyAdmin =
                _assertProxyDeployment(d.royalties, d.royaltiesImplementation, c.initialOwner, "ShareholderRoyalties");
        }
        {
            // Pre-deploy FurnaceGuardHelper before Furnace so the helper's ~25 KB initcode
            // is not embedded in Furnace's own initcode (EIP-3860 49,152-byte ceiling).
            FurnaceGuardHelper guardHelper = new FurnaceGuardHelper(d.claimToken, d.ve);
            d.furnaceGuardHelper = address(guardHelper);
            Furnace furnaceImpl = new Furnace(d.claimToken, d.ve, d.furnaceGuardHelper, address(0));
            d.furnaceImplementation = address(furnaceImpl);
            // Furnace self-deploys its extend-body helper in the constructor; record its address
            // (canonical-bound to the same CLAIM/ve roots + guard helper) for the manifest.
            d.furnaceExtendHelper = furnaceImpl.extendHelper();
            d.furnace = address(
                new FurnaceProxy(
                    d.furnaceImplementation, c.initialOwner, abi.encodeCall(Furnace.initialize, (c.initialOwner))
                )
            );
            d.furnaceProxyAdmin = _assertProxyDeployment(d.furnace, d.furnaceImplementation, c.initialOwner, "Furnace");
        }
        {
            MarketRouter marketImpl = new MarketRouter(d.claimToken, d.ve, d.royalties, address(0));
            d.marketImplementation = address(marketImpl);
            d.market = address(
                new MarketRouterProxy(
                    d.marketImplementation, c.initialOwner, abi.encodeCall(MarketRouter.initialize, (c.initialOwner))
                )
            );
            d.marketProxyAdmin =
                _assertProxyDeployment(d.market, d.marketImplementation, c.initialOwner, "MarketRouter");
        }
        {
            MineCore mineCoreImpl = new MineCore(d.claimToken, d.ve, d.royalties, address(0));
            d.mineCoreImplementation = address(mineCoreImpl);
            d.mineCore = address(
                new MineCoreProxy(
                    d.mineCoreImplementation, c.initialOwner, abi.encodeCall(MineCore.initialize, (c.initialOwner))
                )
            );
            d.mineCoreProxyAdmin =
                _assertProxyDeployment(d.mineCore, d.mineCoreImplementation, c.initialOwner, "MineCore");
        }
        {
            MineCoreQuoter mineCoreQuoter = new MineCoreQuoter(d.mineCore);
            d.mineCoreQuoter = address(mineCoreQuoter);
        }
        {
            ClaimAllHelper claimAll = new ClaimAllHelper(d.royalties, d.mineCore);
            d.claimAll = address(claimAll);
        }

        {
            DelegationHub hub = new DelegationHub();
            d.delegationHub = address(hub);
        }

        {
            EntryTokenRegistry furnaceEntryTokenRegistry = new EntryTokenRegistry(c.initialOwner);
            d.furnaceEntryTokenRegistry = address(furnaceEntryTokenRegistry);
        }
        {
            EntryTokenRegistry mineCoreEntryTokenRegistry = new EntryTokenRegistry(c.initialOwner);
            d.mineCoreEntryTokenRegistry = address(mineCoreEntryTokenRegistry);
        }

        // ------------------------------------------------------------
        // Testnet: materialize pool before vaults
        // ------------------------------------------------------------
        // Base Sepolia materializes the deterministic pool during deployment so
        // testnet QA has a live LP contract immediately. Base mainnet intentionally
        // defers pool creation to LaunchController.finalizeGenesis(); the vault
        // constructors pin the deterministic address even before code exists.

        if (block.chainid == 84532 && d.expectedPool.code.length == 0) {
            IPoolFactory(d.factory).createPool(d.weth, d.claimToken, c.wethClaimStable);
            require(d.expectedPool.code.length > 0, "Deploy: testnet pool materialization failed");
            console2.log("Deploy: materialized testnet pool at", d.expectedPool);
        } else if (block.chainid == 84532) {
            // Validate existing testnet pool to catch stale/misconfigured redeploys.
            (bool ok, bytes memory ret) = d.expectedPool.staticcall(abi.encodeWithSignature("wethAddr()"));
            require(ok && abi.decode(ret, (address)) == d.weth, "Deploy: existing pool WETH mismatch");
            (ok, ret) = d.expectedPool.staticcall(abi.encodeWithSignature("claimPerWeth()"));
            require(ok && abi.decode(ret, (uint256)) > 0, "Deploy: existing pool rate is zero");
            console2.log("Deploy: validated existing testnet pool at", d.expectedPool);
        }

        // ------------------------------------------------------------
        // Vaults
        // ------------------------------------------------------------

        {
            GenesisLPVault24M genesisLpVault24M = new GenesisLPVault24M(d.expectedPool, c.lpWithdrawRecipient);
            d.genesisLpVault24M = address(genesisLpVault24M);
        }

        {
            LpStakingVault7D lpStakingVault7D = new LpStakingVault7D(
                d.expectedPool,
                d.weth,
                d.claimToken,
                d.ve,
                d.furnace,
                c.aerodromeRouter,
                d.factory,
                c.wethClaimStable,
                c.initialOwner
            );
            d.lpStakingVault7D = address(lpStakingVault7D);
        }

        // ------------------------------------------------------------
        // Genesis helpers
        // ------------------------------------------------------------

        {
            // NOTE: LaunchController constructor param is named `_aerodromeRouter` but we pass the
            // DexAdapter wrapper, which exposes the same view ABI (weth(), defaultFactory(), poolFor()).
            // This decouples genesis from a specific DEX implementation while keeping the pool derivation
            // deterministic through the adapter's pinned factory.
            LaunchController launchController =
                new LaunchController(d.claimToken, d.mineCore, d.genesisLpVault24M, d.dexAdapter, c.initialOwner);
            d.launchController = address(launchController);
        }

        d.timelock = _resolveOrDeployTimelock(c);

        // ------------------------------------------------------------
        // Ops helper
        // ------------------------------------------------------------
        // MaintenanceHub is deployed AFTER Wire.s.sol. Its constructor validates
        // canonical cross-contract wiring, so deploying it here would fail closed.
    }

    /// @dev If `TIMELOCK_ADDRESS` env var is set to a contract address, validate that
    ///      it is the canonical TimelockController shape (admin proposer + executor =
    ///      ADMIN_SAFE, delay matches `c.timelockDelaySeconds`, deployer holds
    ///      `TIMELOCK_ADMIN_ROLE`) and reuse it. Otherwise CREATE a new one inline.
    ///
    ///      The env-driven path exists to work around a forge-broadcast trace-decoder
    ///      bug that mis-aligns the LaunchController -> TimelockController CREATE pair
    ///      when emitted from a single broadcast script (the decoder reads the tail of
    ///      LC's runtime bytecode as TC's constructor args and aborts `--broadcast`
    ///      before any tx is submitted). Pre-deploying TC via `script/DeployTimelock.s.sol`
    ///      and exporting `TIMELOCK_ADDRESS` lets the protocol Deploy run cleanly. The
    ///      inline CREATE path is preserved for local/test environments and for any
    ///      future forge release that fixes the upstream bug.
    function _resolveOrDeployTimelock(DeployConfig memory c) internal returns (address) {
        address pre = _envAddressOrZero("TIMELOCK_ADDRESS");
        if (pre != address(0)) {
            require(pre.code.length > 0, "Deploy: TIMELOCK_ADDRESS is not a contract");
            TimelockController existing = TimelockController(payable(pre));

            require(
                existing.getMinDelay() == c.timelockDelaySeconds,
                "Deploy: TIMELOCK_ADDRESS getMinDelay() != c.timelockDelaySeconds"
            );
            bytes32 proposerRole = existing.PROPOSER_ROLE();
            bytes32 executorRole = existing.EXECUTOR_ROLE();
            bytes32 timelockAdminRole = existing.DEFAULT_ADMIN_ROLE();
            require(
                existing.hasRole(proposerRole, c.adminSafe),
                "Deploy: TIMELOCK_ADDRESS missing proposer role for ADMIN_SAFE"
            );
            require(
                existing.hasRole(executorRole, c.adminSafe),
                "Deploy: TIMELOCK_ADDRESS missing executor role for ADMIN_SAFE"
            );
            require(
                existing.hasRole(timelockAdminRole, c.deployer),
                "Deploy: TIMELOCK_ADDRESS missing admin role for deployer (cannot rotate)"
            );
            return pre;
        }

        address[] memory proposers = new address[](1);
        proposers[0] = c.adminSafe;
        address[] memory executors = new address[](1);
        executors[0] = c.adminSafe;
        TimelockController timelock = new TimelockController(c.timelockDelaySeconds, proposers, executors, c.deployer);
        return address(timelock);
    }

    function _logDeploy(address deployer, address initialOwner, Deployed memory d) internal {
        // Minimal console output (useful when eyeballing dry-runs)
        console2.log("Deployer:", deployer);
        console2.log("Owner:", initialOwner);
        console2.log("Timelock:", d.timelock);
        console2.log("CLAIM:", d.claimToken);
        console2.log("veCLAIM:", d.ve);
        console2.log("MineCore:", d.mineCore);
        console2.log("MineCoreImpl:", d.mineCoreImplementation);
        console2.log("MineCoreProxyAdmin:", d.mineCoreProxyAdmin);
        console2.log("MineCoreQuoter:", d.mineCoreQuoter);
        console2.log("Furnace:", d.furnace);
        console2.log("FurnaceImpl:", d.furnaceImplementation);
        console2.log("FurnaceGuardHelper:", d.furnaceGuardHelper);
        console2.log("FurnaceExtendHelper:", d.furnaceExtendHelper);
        console2.log("FurnaceProxyAdmin:", d.furnaceProxyAdmin);
        console2.log("Royalties:", d.royalties);
        console2.log("RoyaltiesImpl:", d.royaltiesImplementation);
        console2.log("RoyaltiesProxyAdmin:", d.royaltiesProxyAdmin);
        console2.log("Market:", d.market);
        console2.log("MarketImpl:", d.marketImplementation);
        console2.log("MarketProxyAdmin:", d.marketProxyAdmin);
        console2.log("ClaimAllHelper:", d.claimAll);
        console2.log("DelegationHub:", d.delegationHub);
        console2.log("DexAdapter:", d.dexAdapter);
        console2.log("FurnaceRegistry:", d.furnaceEntryTokenRegistry);
        console2.log("MineCoreRegistry:", d.mineCoreEntryTokenRegistry);
        console2.log("GenesisLPVault24M:", d.genesisLpVault24M);
        console2.log("LpStakingVault7D:", d.lpStakingVault7D);
        console2.log("LaunchController:", d.launchController);
        console2.log("MaintenanceHub:", address(0));
        console2.log("ExpectedPool:", d.expectedPool);
    }

    /// @dev Validates `timelockDelaySeconds` against the Base-mainnet safety floor (48h).
    ///      Short delays require `allowUnsafe` (sourced from `ALLOW_UNSAFE_MAINNET_TIMELOCK_DELAY`
    ///      at the only production call-site). Extracted so tests can exercise the guard
    ///      without round-tripping through `vm.setEnv`, whose process-global writes race
    ///      across parallel test contracts.
    function _requireValidMainnetTimelockDelay(uint256 timelockDelaySeconds, bool allowUnsafe) internal view {
        uint256 defaultDelay = block.chainid == 8453 ? 48 hours : 1 hours;
        if (block.chainid == 8453 && timelockDelaySeconds < defaultDelay) {
            require(
                allowUnsafe,
                "Deploy: TIMELOCK_DELAY_SECONDS below 48 hours on mainnet; set ALLOW_UNSAFE_MAINNET_TIMELOCK_DELAY=true to override"
            );
        }
    }

    function _envAddressOrZero(string memory key) internal returns (address) {
        try vm.envAddress(key) returns (address v) {
            return v;
        } catch {
            return address(0);
        }
    }

    function _envBool(string memory key) internal returns (bool) {
        try vm.envBool(key) returns (bool v) {
            return v;
        } catch {
            return false;
        }
    }

    function _envUintOr(string memory key, uint256 fallbackValue) internal returns (uint256) {
        try vm.envUint(key) returns (uint256 v) {
            return v;
        } catch {
            return fallbackValue;
        }
    }

    function _assertProxyDeployment(address proxy, address implementation, address expectedOwner, string memory label)
        internal
        view
        returns (address proxyAdmin)
    {
        proxyAdmin = _readAddressSlot(proxy, _ADMIN_SLOT);
        require(proxyAdmin != address(0), string.concat("Deploy: missing proxy admin for ", label));
        require(proxyAdmin.code.length > 0, string.concat("Deploy: proxy admin missing code for ", label));
        require(
            _readAddressSlot(proxy, _IMPLEMENTATION_SLOT) == implementation,
            string.concat("Deploy: implementation slot mismatch for ", label)
        );
        require(
            ProxyAdmin(proxyAdmin).owner() == expectedOwner,
            string.concat("Deploy: proxy admin owner mismatch for ", label)
        );
    }

    function _readAddressSlot(address target, bytes32 slot) internal view returns (address out) {
        out = address(uint160(uint256(vm.load(target, slot))));
    }
}
