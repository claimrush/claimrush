// SPDX-License-Identifier: MIT
pragma solidity ^0.8.34;

import {Script, console2} from "forge-std/Script.sol";

import {EntryTokenRegistry} from "../src/EntryTokenRegistry.sol";

/// @notice Path B helper: configure EntryTokenRegistries for fully-local swaps.
/// @dev Reads deployments/local.json and simulates the full registry-configuration sequence before
///      broadcast so owner/pool drift fails closed before any partial registry writes.
contract ConfigureLocalPathB is Script {
    struct LocalPathBConfig {
        address furnaceReg;
        address mineReg;
        address dexAdapter;
        address poolFactory;
        address wrappedNative;
        address claimToken;
        address claimWethPool;
        address entryToken;
        address entryWethPool;
        address entryClaimPool;
    }

    function run() external {
        require(block.chainid == 31337 || block.chainid == 1337, "ConfigureLocalPathB: local chain only");

        uint256 pk = vm.envUint("LOCAL_PRIVATE_KEY");
        LocalPathBConfig memory cfg = _loadConfig();

        address broadcaster = vm.addr(pk);
        console2.log("ConfigureLocalPathB: simulating full registry configuration before broadcast...");
        _preflightConfigureSequence(cfg, broadcaster);
        console2.log("ConfigureLocalPathB: preflight simulation passed.");

        vm.startBroadcast(pk);
        _executeConfigureSequence(cfg);
        vm.stopBroadcast();
    }

    function _loadConfig() internal returns (LocalPathBConfig memory cfg) {
        string memory json = vm.readFile("deployments/local.json");

        cfg.claimToken = vm.parseJsonAddress(json, ".contracts.ClaimToken.address");
        cfg.dexAdapter = vm.parseJsonAddress(json, ".contracts.DexAdapter.address");
        cfg.poolFactory = vm.parseJsonAddress(json, ".aerodrome.poolFactory.address");
        cfg.wrappedNative = vm.parseJsonAddress(json, ".aerodrome.wrappedNative.address");
        cfg.claimWethPool = vm.parseJsonAddress(json, ".aerodrome.claimWethPool.address");

        cfg.furnaceReg = vm.parseJsonAddress(json, ".contracts.FurnaceEntryTokenRegistry.address");
        cfg.mineReg = vm.parseJsonAddress(json, ".contracts.MineCoreEntryTokenRegistry.address");

        cfg.entryToken = vm.parseJsonAddress(json, ".localDex.entryToken.address");
        cfg.entryWethPool = vm.parseJsonAddress(json, ".localDex.pools.entryWeth.address");
        cfg.entryClaimPool = vm.parseJsonAddress(json, ".localDex.pools.entryClaim.address");

        _requireDeployed(cfg.claimToken, "ClaimToken");
        _requireDeployed(cfg.dexAdapter, "DexAdapter");
        _requireDeployed(cfg.poolFactory, "Aerodrome.poolFactory");
        _requireDeployed(cfg.wrappedNative, "Aerodrome.wrappedNative");
        _requireDeployed(cfg.claimWethPool, "Aerodrome.claimWethPool");
        _requireDeployed(cfg.furnaceReg, "FurnaceEntryTokenRegistry");
        _requireDeployed(cfg.mineReg, "MineCoreEntryTokenRegistry");
        _requireDeployed(cfg.entryToken, "localDex.entryToken");
        _requireDeployed(cfg.entryWethPool, "localDex.pools.entryWeth");
        _requireDeployed(cfg.entryClaimPool, "localDex.pools.entryClaim");
    }

    function _preflightConfigureSequence(LocalPathBConfig memory cfg, address broadcaster) internal {
        uint256 snap = vm.snapshot();
        vm.startPrank(broadcaster);
        _executeConfigureSequence(cfg);
        vm.stopPrank();
        require(vm.revertTo(snap), "ConfigureLocalPathB: failed to revert preflight snapshot");
    }

    function _executeConfigureSequence(LocalPathBConfig memory cfg) internal {
        // Router config (uses DexAdapter wrapper).
        EntryTokenRegistry(cfg.furnaceReg)
            .setRouterConfig(cfg.dexAdapter, cfg.poolFactory, cfg.wrappedNative, cfg.claimToken);
        EntryTokenRegistry(cfg.mineReg)
            .setRouterConfig(cfg.dexAdapter, cfg.poolFactory, cfg.wrappedNative, cfg.claimToken);

        // WETH -> CLAIM hop used by Furnace when tokenIn == wrappedNative.
        (, address existingPool) = EntryTokenRegistry(cfg.furnaceReg).getWethClaimHop();
        if (existingPool == address(0)) {
            EntryTokenRegistry(cfg.furnaceReg).setWethClaimHop(false, cfg.claimWethPool);
        }

        // Token configs for the default local entry token.
        // - MineCore: only needs tokenIn -> WETH hop for takeoverWithToken.
        //   setTokenConfig(tokenIn, enabled, directToClaimEnabled, tokenClaimStable, tokenClaimPool, tokenWethStable, tokenWethPool)
        EntryTokenRegistry(cfg.mineReg)
            .setTokenConfig(
                cfg.entryToken,
                true,
                false, // directToClaimEnabled
                false, // tokenClaimStable (unused when directToClaimEnabled=false)
                address(0), // tokenClaimPool (unused when directToClaimEnabled=false)
                false, // tokenWethStable
                cfg.entryWethPool
            );

        // - Furnace: use directToClaim route (token -> CLAIM pool) by default.
        EntryTokenRegistry(cfg.furnaceReg)
            .setTokenConfig(
                cfg.entryToken,
                true,
                true, // directToClaimEnabled
                false, // tokenClaimStable
                cfg.entryClaimPool,
                false, // tokenWethStable
                cfg.entryWethPool
            );
        EntryTokenRegistry(cfg.furnaceReg).setFurnaceEntryTokenExactReceiptSafe(cfg.entryToken, true);
    }

    function _requireDeployed(address a, string memory what) internal view {
        require(a != address(0), string.concat("ConfigureLocalPathB: missing ", what));
        require(a.code.length > 0, string.concat("ConfigureLocalPathB: no code at ", what));
    }
}
