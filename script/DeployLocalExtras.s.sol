// SPDX-License-Identifier: MIT
pragma solidity ^0.8.34;

import {Script, console2} from "forge-std/Script.sol";

import {LpStakingVault7D} from "../src/vault/LpStakingVault7D.sol";
import {GenesisLPVault24M} from "../src/vault/GenesisLPVault24M.sol";

import {LaunchController} from "../src/genesis/LaunchController.sol";
import {IDexAdapter} from "../src/interfaces/IDexAdapter.sol";

/// @notice Deploy v1.0.0 optional components that require local DEX wiring (vaults, genesis).
/// @dev Local-only helper consumed by the local deployment flow.
///      This script ONLY deploys contracts. Wiring is done by script/Wire.s.sol; freezing and proxy admin burn by script/FreezeAndBurn.s.sol (via timelock).
///      MaintenanceHub is deployed AFTER wiring (see DeployMaintenanceHub.s.sol) because its constructor
///      validates cross-contract references that only exist post-Wire. It simulates the full local
///      constructor sequence before broadcast and rejects DEX-root drift so a stale local env cannot
///      leave GenesisLPVault24M / LpStakingVault7D partially deployed.
contract DeployLocalExtras is Script {
    struct LocalConfig {
        address deployer;
        address lpWithdrawRecipient;
        address claimWethPool;
        address weth;
        address claimToken;
        address ve;
        address royalties;
        address furnace;
        address market;
        address mineCore;
        address dexAdapter;
        address aerodromeRouter;
        address aerodromeFactory;
        address guardian;
    }

    function run() external {
        require(block.chainid == 31337 || block.chainid == 1337, "DeployLocalExtras: local chain only");

        uint256 pk = vm.envUint("LOCAL_PRIVATE_KEY");
        address deployer = vm.addr(pk);
        LocalConfig memory c = _loadConfig(deployer);

        console2.log("DeployLocalExtras: simulating full deployment sequence before broadcast...");
        _preflightDeploySequence(c, deployer);
        console2.log("DeployLocalExtras: preflight simulation passed.");

        vm.startBroadcast(pk);
        _deploy(c);
        vm.stopBroadcast();
    }

    function _loadConfig(address deployer) internal returns (LocalConfig memory c) {
        c.deployer = deployer;
        c.lpWithdrawRecipient = _envAddressOrDefault("LOCAL_LP_WITHDRAW_RECIPIENT", deployer);
        c.claimWethPool = vm.envAddress("LOCAL_CLAIM_WETH_POOL");
        c.weth = vm.envAddress("LOCAL_WETH");
        c.claimToken = vm.envAddress("LOCAL_CLAIM_TOKEN");
        c.ve = vm.envAddress("LOCAL_VECLAIM_NFT");
        c.royalties = vm.envAddress("LOCAL_SHAREHOLDER_ROYALTIES");
        c.furnace = vm.envAddress("LOCAL_FURNACE");
        c.market = vm.envAddress("LOCAL_MARKET_ROUTER");
        c.mineCore = vm.envAddress("LOCAL_MINE_CORE");
        c.dexAdapter = vm.envAddress("LOCAL_DEX_ADAPTER");
        c.aerodromeRouter = vm.envAddress("LOCAL_AERODROME_ROUTER");
        c.aerodromeFactory = vm.envAddress("LOCAL_AERODROME_FACTORY");
        c.guardian = _envAddressOrDefault("LOCAL_GENESIS_BURN_GUARDIAN", deployer);

        require(c.lpWithdrawRecipient != address(0), "DeployLocalExtras: LOCAL_LP_WITHDRAW_RECIPIENT=0");

        _requireContract(c.claimWethPool, "LOCAL_CLAIM_WETH_POOL");
        _requireContract(c.weth, "LOCAL_WETH");
        _requireContract(c.claimToken, "LOCAL_CLAIM_TOKEN");
        _requireContract(c.ve, "LOCAL_VECLAIM_NFT");
        _requireContract(c.royalties, "LOCAL_SHAREHOLDER_ROYALTIES");
        _requireContract(c.furnace, "LOCAL_FURNACE");
        _requireContract(c.market, "LOCAL_MARKET_ROUTER");
        _requireContract(c.mineCore, "LOCAL_MINE_CORE");
        _requireContract(c.dexAdapter, "LOCAL_DEX_ADAPTER");
        _requireContract(c.aerodromeRouter, "LOCAL_AERODROME_ROUTER");
        _requireContract(c.aerodromeFactory, "LOCAL_AERODROME_FACTORY");

        require(IDexAdapter(c.dexAdapter).weth() == c.weth, "DeployLocalExtras: DexAdapter.weth mismatch");
        require(
            IDexAdapter(c.dexAdapter).defaultFactory() == c.aerodromeFactory,
            "DeployLocalExtras: DexAdapter.defaultFactory mismatch"
        );
        require(
            IDexAdapter(c.dexAdapter).poolFor(c.weth, c.claimToken, false, c.aerodromeFactory) == c.claimWethPool,
            "DeployLocalExtras: LOCAL_CLAIM_WETH_POOL mismatch"
        );

        require(IDexAdapter(c.aerodromeRouter).weth() == c.weth, "DeployLocalExtras: LOCAL_WETH mismatch");
        require(
            IDexAdapter(c.aerodromeRouter).defaultFactory() == c.aerodromeFactory,
            "DeployLocalExtras: LOCAL_AERODROME_FACTORY mismatch"
        );
        require(
            IDexAdapter(c.aerodromeRouter).poolFor(c.weth, c.claimToken, false, c.aerodromeFactory) == c.claimWethPool,
            "DeployLocalExtras: LOCAL_CLAIM_WETH_POOL mismatch"
        );
        require(
            c.guardian == deployer,
            "DeployLocalExtras: LOCAL_GENESIS_BURN_GUARDIAN must equal local deployer while FinalizeLocalGenesis uses one key"
        );
    }

    function _preflightDeploySequence(LocalConfig memory c, address deployer) internal {
        uint256 snap = vm.snapshot();
        vm.startPrank(deployer);
        _deploy(c);
        vm.stopPrank();
        require(vm.revertTo(snap), "DeployLocalExtras: failed to revert preflight snapshot");
    }

    function _deploy(LocalConfig memory c) internal {
        // v1.0.0 canonical pool: volatile (stable=false)
        bool wethClaimStable = false;

        GenesisLPVault24M genesisLpVault24M = new GenesisLPVault24M(c.claimWethPool, c.lpWithdrawRecipient);

        new LpStakingVault7D(
            c.claimWethPool,
            c.weth,
            c.claimToken,
            c.ve,
            c.furnace,
            c.aerodromeRouter,
            c.aerodromeFactory,
            wethClaimStable,
            c.deployer
        );

        new LaunchController(c.claimToken, c.mineCore, address(genesisLpVault24M), c.dexAdapter, c.guardian);
    }

    function _requireContract(address target, string memory label) internal view {
        require(target != address(0), string.concat("DeployLocalExtras: missing ", label));
        require(target.code.length > 0, string.concat("DeployLocalExtras: ", label, " is not a contract"));
    }

    function _envAddressOrDefault(string memory key, address defaultValue) internal returns (address out) {
        try vm.envAddress(key) returns (address v) {
            out = v;
        } catch {
            out = defaultValue;
        }
    }
}
