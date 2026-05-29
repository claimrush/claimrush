// SPDX-License-Identifier: MIT
pragma solidity ^0.8.34;

import {Script, console2} from "forge-std/Script.sol";

import {TestnetSwapFactory} from "../src/mocks/testnet/TestnetSwapFactory.sol";
import {TestnetSwapPool} from "../src/mocks/testnet/TestnetSwapPool.sol";

/// @notice Deploy and configure the CLAIM/WETH pool on Sepolia via CREATE2.
/// @dev This script is a FALLBACK / validation tool.  In the standard flow,
///      Deploy.s.sol materializes the pool on testnet (chainId 84532)
///      automatically.  Use this script only if you need to create the pool
///      separately (e.g. redeployment after a factory reset).
///
///      IMPORTANT: Do NOT send tokens to the pool before FinalizeGenesis.
///      LaunchController._ensureEmptyOrSkim() will revert if it finds unexpected
///      balances.
///
///      Standard run order:
///        1. DeployTestnetSwapDex.s.sol  -> FACTORY, WETH, AERODROME_ROUTER
///        2. Deploy.s.sol               -> CLAIM_TOKEN, all protocol addresses
///                                         (auto-creates pool on chainId 84532)
///        3. Wire.s.sol
///        4. FinalizeGenesis.s.sol       (pool.mint works, swaps work)
///
///      POST-GENESIS LIQUIDITY: Do NOT send tokens directly to the pool.
///      Raw transfers are skimmable by anyone, and transfer + mint is
///      frontrunnable.  Use the router for atomic swaps, or a Forge script
///      that does transfer + mint in a single broadcast transaction.
///
/// Required env:
/// - PRIVATE_KEY
/// - CLAIM_TOKEN      ClaimToken address (from Deploy.s.sol output)
/// - WETH             MockWETH address (from DeployTestnetSwapDex output)
/// - FACTORY          TestnetSwapFactory address (from DeployTestnetSwapDex output)
contract CreateTestnetPool is Script {
    function run() external {
        require(block.chainid == 84532, "CreateTestnetPool: Base Sepolia only");

        uint256 pk = vm.envUint("PRIVATE_KEY");

        address claimToken = vm.envAddress("CLAIM_TOKEN");
        address weth = vm.envAddress("WETH");
        address factoryAddr = vm.envAddress("FACTORY");

        require(claimToken != address(0) && claimToken.code.length > 0, "invalid CLAIM_TOKEN");
        require(weth != address(0) && weth.code.length > 0, "invalid WETH");
        require(factoryAddr != address(0) && factoryAddr.code.length > 0, "invalid FACTORY");

        TestnetSwapFactory factory = TestnetSwapFactory(factoryAddr);

        address predicted = factory.getPool(weth, claimToken, false);
        require(predicted != address(0), "factory prediction returned 0");
        if (predicted.code.length > 0) {
            console2.log("Pool already deployed at:", predicted);
            _validateExistingPool(predicted, weth, factoryAddr);
            return;
        }

        console2.log("Predicted pool address:", predicted);

        vm.startBroadcast(pk);
        address pool = factory.createPool(weth, claimToken, false);
        vm.stopBroadcast();

        require(pool == predicted, "CREATE2 address mismatch -- factory bug");
        require(pool.code.length > 0, "pool has no code after deployment");

        address verified = factory.getPool(weth, claimToken, false);
        require(verified == pool, "getPool != deployed address after createPool");

        _validateExistingPool(pool, weth, factoryAddr);

        TestnetSwapPool p = TestnetSwapPool(pool);
        console2.log("Pool deployed at:", pool);
        console2.log("  token0:", p.token0());
        console2.log("  token1:", p.token1());
        console2.log("  wethAddr:", p.wethAddr());
        console2.log("  claimPerWeth:", p.claimPerWeth());
    }

    function _validateExistingPool(address pool, address weth, address factoryAddr) internal view {
        TestnetSwapPool p = TestnetSwapPool(pool);
        require(p.wethAddr() == weth, "existing pool: WETH mismatch");
        require(p.claimPerWeth() > 0, "existing pool: rate is zero");
        require(p.deployer() == factoryAddr, "existing pool: not factory-managed (setPoolRate will fail)");
        console2.log("  Validated: wethAddr=%s  rate=%d  deployer=%s", p.wethAddr(), p.claimPerWeth(), p.deployer());
    }
}
