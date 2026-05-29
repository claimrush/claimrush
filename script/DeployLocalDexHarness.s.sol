// SPDX-License-Identifier: MIT
pragma solidity ^0.8.34;

import {Script, console2} from "forge-std/Script.sol";

import {DexAdapter} from "../src/DexAdapter.sol";
import {LocalWETH} from "../src/mocks/LocalWETH.sol";
import {LocalAerodromeFactory} from "../src/mocks/localdex/LocalAerodromeFactory.sol";
import {LocalAerodromeRouter} from "../src/mocks/localdex/LocalAerodromeRouter.sol";
import {LocalEntryToken} from "../src/mocks/localdex/LocalEntryToken.sol";
import {LocalClaimWethPool, LocalEntryWethPool, LocalEntryClaimPool} from "../src/mocks/localdex/LocalPools.sol";

/// @notice Path B helper: deploy a fully-local Aerodrome-like DEX + DexAdapter.
/// @dev This script only deploys + registers pools. Configuration (registry wiring)
///      and liquidity seeding are handled by separate scripts.
///      It simulates the full local DEX deployment + pool-registration sequence before
///      broadcast so a late registration failure cannot leave a partial local DEX topology behind.
contract DeployLocalDexHarness is Script {
    function run() external {
        require(block.chainid == 31337 || block.chainid == 1337, "DeployLocalDexHarness: local chain only");

        uint256 pk = vm.envUint("LOCAL_PRIVATE_KEY");
        address deployer = vm.addr(pk);
        address claimToken = vm.envAddress("LOCAL_CLAIM_TOKEN");
        require(claimToken != address(0), "DeployLocalDexHarness: LOCAL_CLAIM_TOKEN missing");
        require(claimToken.code.length > 0, "DeployLocalDexHarness: LOCAL_CLAIM_TOKEN is not a contract");

        console2.log("DeployLocalDexHarness: simulating full deployment sequence before broadcast...");
        _preflightDeploySequence(deployer, claimToken);
        console2.log("DeployLocalDexHarness: preflight simulation passed.");

        vm.startBroadcast(pk);
        _executeDeploySequence(deployer, claimToken);
        vm.stopBroadcast();
    }

    function _preflightDeploySequence(address deployer, address claimToken) internal {
        uint256 snap = vm.snapshot();
        vm.startPrank(deployer);
        _executeDeploySequence(deployer, claimToken);
        vm.stopPrank();
        require(vm.revertTo(snap), "DeployLocalDexHarness: failed to revert preflight snapshot");
    }

    function _executeDeploySequence(address deployer, address claimToken) internal virtual {
        LocalWETH weth = new LocalWETH();
        LocalAerodromeFactory factory = new LocalAerodromeFactory();
        LocalAerodromeRouter aerodromeRouter = new LocalAerodromeRouter(address(factory), address(weth));

        // Adapter used by EntryTokenRegistry routerConfig.
        DexAdapter dexAdapter = new DexAdapter(address(aerodromeRouter), deployer);

        // Default entry token for local E2E flows.
        LocalEntryToken entryToken = new LocalEntryToken();

        // Named pools (stable=false) so we can easily find them in broadcast output.
        LocalClaimWethPool claimWethPool = new LocalClaimWethPool(claimToken, address(weth));
        LocalEntryWethPool entryWethPool = new LocalEntryWethPool(address(entryToken), address(weth));
        LocalEntryClaimPool entryClaimPool = new LocalEntryClaimPool(address(entryToken), claimToken);

        // Register pools in the factory for router.poolFor(...).
        factory.registerPool(claimToken, address(weth), false, address(claimWethPool));
        factory.registerPool(address(entryToken), address(weth), false, address(entryWethPool));
        factory.registerPool(address(entryToken), claimToken, false, address(entryClaimPool));

        require(dexAdapter.weth() == address(weth), "DeployLocalDexHarness: DexAdapter.weth mismatch");
        require(
            dexAdapter.defaultFactory() == address(factory), "DeployLocalDexHarness: DexAdapter.defaultFactory mismatch"
        );

        _requireRegisteredPool(
            aerodromeRouter,
            claimToken,
            address(weth),
            address(factory),
            address(claimWethPool),
            "LOCAL_CLAIM_WETH_POOL"
        );
        _requireRegisteredPool(
            aerodromeRouter,
            address(entryToken),
            address(weth),
            address(factory),
            address(entryWethPool),
            "LOCAL_ENTRY_WETH_POOL"
        );
        _requireRegisteredPool(
            aerodromeRouter,
            address(entryToken),
            claimToken,
            address(factory),
            address(entryClaimPool),
            "LOCAL_ENTRY_CLAIM_POOL"
        );

        // Silence unused variable warnings in older solc versions.
        dexAdapter;
    }

    function _requireRegisteredPool(
        LocalAerodromeRouter router,
        address tokenA,
        address tokenB,
        address factory,
        address expectedPool,
        string memory label
    ) internal view {
        require(
            router.poolFor(tokenA, tokenB, false, factory) == expectedPool,
            string.concat("DeployLocalDexHarness: ", label, " not registered")
        );
    }
}
