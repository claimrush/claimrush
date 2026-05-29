// SPDX-License-Identifier: MIT
pragma solidity ^0.8.34;

import {console2} from "forge-std/console2.sol";
import {BroadcastSignerBase} from "./lib/BroadcastSignerBase.sol";
import {TimelockController} from "lib/openzeppelin-contracts/contracts/governance/TimelockController.sol";

/// @notice Standalone Timelock deploy helper used to break a forge-broadcast trace
///         decoder bug that mis-aligns the LaunchController -> TimelockController
///         CREATE pair when emitted from a single broadcast script. Keeping the
///         TimelockController CREATE in its own broadcast log avoids the stuck
///         "type check failed for offset (usize)" error that aborts `--broadcast`
///         before any tx is submitted.
///
/// Required env (same conventions as Deploy.s.sol):
/// - PRIVATE_KEY (hot key) or LEDGER_ADDRESS / SIGNER_ADDRESS (hardware wallet)
/// - ADMIN_SAFE          Safe / governance proposer-executor for the new timelock
///
/// Optional env:
/// - TIMELOCK_DELAY_SECONDS  Override the default delay
///                           Defaults: 48 hours on Base mainnet, 1 hour on Base Sepolia
/// - ALLOW_UNSAFE_MAINNET_TIMELOCK_DELAY  Break-glass for sub-48 h delay on mainnet
///
/// Output: prints `export TIMELOCK_ADDRESS=0x...` for downstream wiring into
/// Deploy.s.sol via the same env file.
contract DeployTimelock is BroadcastSignerBase {
    function run() external {
        uint256 cid = block.chainid;
        require(cid == 8453 || cid == 84532, "DeployTimelock: unsupported chainId");

        BroadcastSigner memory broadcaster = _resolveBroadcastSigner();
        address deployer = broadcaster.account;

        address adminSafe = vm.envAddress("ADMIN_SAFE");
        require(adminSafe != address(0), "DeployTimelock: ADMIN_SAFE=0");
        require(adminSafe.code.length > 0, "DeployTimelock: ADMIN_SAFE is not a contract");

        uint256 defaultDelay = block.chainid == 8453 ? 48 hours : 1 hours;
        uint256 delaySeconds = _tryEnvUintOrZero("TIMELOCK_DELAY_SECONDS");
        if (delaySeconds == 0) delaySeconds = defaultDelay;

        if (block.chainid == 8453 && delaySeconds < 48 hours) {
            require(
                _tryEnvUintOrZero("ALLOW_UNSAFE_MAINNET_TIMELOCK_DELAY") != 0,
                "DeployTimelock: TIMELOCK_DELAY_SECONDS below 48h on mainnet requires ALLOW_UNSAFE_MAINNET_TIMELOCK_DELAY=1"
            );
        }

        address[] memory proposers = new address[](1);
        proposers[0] = adminSafe;
        address[] memory executors = new address[](1);
        executors[0] = adminSafe;

        _startBroadcast(broadcaster);
        TimelockController timelock = new TimelockController(delaySeconds, proposers, executors, deployer);
        vm.stopBroadcast();

        console2.log("Deployer:", deployer);
        console2.log("AdminSafe:", adminSafe);
        console2.log("DelaySeconds:", delaySeconds);
        console2.log("Timelock:", address(timelock));
        console2.log("=== For Deploy.s.sol ===");
        console2.log("export TIMELOCK_ADDRESS=", address(timelock));
    }
}
