// SPDX-License-Identifier: MIT
pragma solidity ^0.8.34;

import {Script, console2} from "forge-std/Script.sol";

import {LocalWETH} from "../src/mocks/LocalWETH.sol";
import {LocalAerodromeRouter} from "../src/mocks/localdex/LocalAerodromeRouter.sol";
import {TestnetSwapFactory} from "../src/mocks/testnet/TestnetSwapFactory.sol";

/// @notice Deploy swap-capable mock Aerodrome DEX to Base Sepolia.
/// @dev Deploys a minimal swap-capable testnet DEX for integration testing.
///      Uses TestnetSwapFactory (CREATE2-capable) + LocalAerodromeRouter (swap-capable)
///      so ALL protocol surfaces work on Sepolia: furnace ETH entry, DEX quotes, LP creation.
///
///      TestnetSwapFactory.getPool() returns the CREATE2-predicted pool address for ANY
///      token pair, even before the pool is deployed.  This satisfies Deploy.s.sol's
///      `require(poolFor(...) != address(0))`.
///
///      Deploy.s.sol auto-materializes the pool on testnet (chainId 84532) via
///      factory.createPool() after ClaimToken is deployed but before the vault
///      constructors that require pool code.  No separate CreateTestnetPool step
///      is needed in the standard flow.
///
///      NOTE — SAME DEPLOYER KEY REQUIREMENT:
///      TestnetSwapFactory.createPool() is onlyOwner, where owner = the EOA that
///      deployed the factory (i.e. the key used for THIS script).  Deploy.s.sol
///      calls factory.createPool() on Sepolia to auto-materialize the pool.
///      Therefore this script, Deploy.s.sol, and the fallback CreateTestnetPool.s.sol
///      MUST all be broadcast with the same PRIVATE_KEY, or Sepolia deploy will
///      revert with NOT_OWNER.
///
///      Run order:
///        1. DeployTestnetSwapDex.s.sol  (this script -- outputs AERODROME_ROUTER, FACTORY, WETH)
///        2. Deploy.s.sol               (pass AERODROME_ROUTER; auto-creates pool on Sepolia)
///        3. Wire.s.sol
///        4. FinalizeGenesis.s.sol       (pool.mint works, swaps work)
///
/// Required env:
/// - PRIVATE_KEY              Deployer EOA key.
///
/// Optional env:
/// - CLAIM_PER_WETH           Default mock exchange rate for pools (default 864000,
///                            chosen so spot price is continuous across
///                            `LaunchController.finalizeGenesis()`: Sepolia
///                            genesis seeds 5 ETH against 4.32M CLAIM, i.e.
///                            864_000 CLAIM per WETH).
contract DeployTestnetSwapDex is Script {
    function run() external {
        require(block.chainid == 84532, "DeployTestnetSwapDex: Base Sepolia only (chainId 84532)");

        uint256 pk = vm.envUint("PRIVATE_KEY");
        address deployer = vm.addr(pk);
        console2.log("Deployer:", deployer);

        vm.startBroadcast(pk);

        LocalWETH weth = new LocalWETH();
        console2.log("MockWETH:", address(weth));

        TestnetSwapFactory factory = new TestnetSwapFactory(address(weth));
        console2.log("MockFactory:", address(factory));

        uint256 rate = _envUintOrDefault("CLAIM_PER_WETH", 864_000);
        if (rate != 864_000) factory.setDefaultRate(rate);
        console2.log("DefaultRate:", rate, "CLAIM per WETH");

        LocalAerodromeRouter router = new LocalAerodromeRouter(address(factory), address(weth));
        console2.log("MockRouter (AERODROME_ROUTER):", address(router));

        require(router.defaultFactory() == address(factory), "factory mismatch");
        require(router.weth() == address(weth), "weth mismatch");

        vm.stopBroadcast();

        console2.log("");
        console2.log("=== For Deploy.s.sol ===");
        console2.log("export AERODROME_ROUTER=%s", address(router));
        console2.log("");
        console2.log("=== For manual fallback / validation (CreateTestnetPool.s.sol) ===");
        console2.log("export FACTORY=%s", address(factory));
        console2.log("export WETH=%s", address(weth));
    }

    function _envUintOrDefault(string memory key, uint256 fallback_) internal returns (uint256) {
        try vm.envUint(key) returns (uint256 v) {
            return v;
        } catch {
            return fallback_;
        }
    }
}
