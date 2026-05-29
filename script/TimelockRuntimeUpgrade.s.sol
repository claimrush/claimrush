// SPDX-License-Identifier: MIT
pragma solidity ^0.8.34;

import {ProxyAdmin} from "lib/openzeppelin-contracts/contracts/proxy/transparent/ProxyAdmin.sol";
import {
    ITransparentUpgradeableProxy
} from "lib/openzeppelin-contracts/contracts/proxy/transparent/TransparentUpgradeableProxy.sol";
import {TimelockController} from "lib/openzeppelin-contracts/contracts/governance/TimelockController.sol";
import {TimelockScriptBase} from "./lib/TimelockScriptBase.sol";

/// @notice Schedule or execute a timelock batch for runtime quartet implementation upgrades.
/// @dev Set one or more of:
///      - MINE_CORE_NEW_IMPLEMENTATION
///      - FURNACE_NEW_IMPLEMENTATION
///      - MARKET_ROUTER_NEW_IMPLEMENTATION
///      - SHAREHOLDER_ROYALTIES_NEW_IMPLEMENTATION
///      Optional calldata payload env vars:
///      - MINE_CORE_UPGRADE_DATA
///      - FURNACE_UPGRADE_DATA
///      - MARKET_ROUTER_UPGRADE_DATA
///      - SHAREHOLDER_ROYALTIES_UPGRADE_DATA
///      When `TIMELOCK_CALLER` (or `ADMIN_SAFE`) is set to the Safe / proposer-executor contract,
///      the script runs in simulation-only mode and prints the calldata that contract must submit.
contract TimelockRuntimeUpgrade is TimelockScriptBase {
    enum Action {
        Schedule,
        Execute
    }

    bytes32 internal constant IMPLEMENTATION_SLOT = 0x360894a13ba1a3210667c828492db98dca3e2076cc3735a920a3ca505d382bbc;

    struct UpgradeOp {
        address proxyAdmin;
        address proxy;
        address implementation;
        bytes data;
    }

    function run() external {
        GovernanceAddrs memory addrs = _loadGovernanceAddrs();
        _requireCode(addrs.timelock, "TimelockController");

        UpgradeOp[] memory ops = _buildOps(addrs);
        require(ops.length != 0, "TimelockRuntimeUpgrade: no runtime implementations configured");

        (address[] memory targets, uint256[] memory values, bytes[] memory payloads) = _buildBatch(ops);
        TimelockController timelock = TimelockController(payable(addrs.timelock));
        bytes32 salt = _envBytes32OrZero("TIMELOCK_SALT");
        bytes32 operationId = timelock.hashOperationBatch(targets, values, payloads, ZERO_PREDECESSOR, salt);
        _logOperation(operationId, "TimelockRuntimeUpgrade.operationId");

        Action action = _parseAction();
        address contractCaller = _timelockCallerOrZero();

        if (contractCaller != address(0)) {
            if (action == Action.Schedule) {
                _requireTimelockActionCaller(timelock, contractCaller, true);
                _simulateSchedule(timelock, contractCaller, targets, values, payloads, salt, operationId);
                _logTimelockActionSubmission(
                    "TimelockRuntimeUpgrade.scheduleBatch",
                    contractCaller,
                    address(timelock),
                    abi.encodeCall(
                        TimelockController.scheduleBatch,
                        (targets, values, payloads, ZERO_PREDECESSOR, salt, timelock.getMinDelay())
                    )
                );
            } else {
                require(timelock.isOperationReady(operationId), "TimelockRuntimeUpgrade: operation is not ready");
                _requireTimelockActionCaller(timelock, contractCaller, false);
                _simulateExecute(timelock, contractCaller, targets, values, payloads, salt, operationId);
                _logTimelockActionSubmission(
                    "TimelockRuntimeUpgrade.executeBatch",
                    contractCaller,
                    address(timelock),
                    abi.encodeCall(TimelockController.executeBatch, (targets, values, payloads, ZERO_PREDECESSOR, salt))
                );
            }
            return;
        }

        BroadcastSigner memory signer = _broadcastSigner();
        address actor = signer.account;

        if (action == Action.Schedule) {
            _requireTimelockActionCaller(timelock, actor, true);
            _simulateSchedule(timelock, actor, targets, values, payloads, salt, operationId);

            _startBroadcast(signer);
            timelock.scheduleBatch(targets, values, payloads, ZERO_PREDECESSOR, salt, timelock.getMinDelay());
            vm.stopBroadcast();
            require(timelock.isOperationPending(operationId), "TimelockRuntimeUpgrade: operation not pending");
        } else {
            require(timelock.isOperationReady(operationId), "TimelockRuntimeUpgrade: operation is not ready");
            _requireTimelockActionCaller(timelock, actor, false);
            _simulateExecute(timelock, actor, targets, values, payloads, salt, operationId);

            _startBroadcast(signer);
            timelock.executeBatch(targets, values, payloads, ZERO_PREDECESSOR, salt);
            vm.stopBroadcast();
            require(timelock.isOperationDone(operationId), "TimelockRuntimeUpgrade: operation not done");
            _assertUpgraded(ops);
        }
    }

    function _buildOps(GovernanceAddrs memory addrs) internal returns (UpgradeOp[] memory ops) {
        UpgradeOp[4] memory allOps = [
            UpgradeOp({
                proxyAdmin: addrs.mineCoreProxyAdmin,
                proxy: addrs.mineCore,
                implementation: _envAddressOrZero("MINE_CORE_NEW_IMPLEMENTATION"),
                data: _envBytesOrEmpty("MINE_CORE_UPGRADE_DATA")
            }),
            UpgradeOp({
                proxyAdmin: addrs.furnaceProxyAdmin,
                proxy: addrs.furnace,
                implementation: _envAddressOrZero("FURNACE_NEW_IMPLEMENTATION"),
                data: _envBytesOrEmpty("FURNACE_UPGRADE_DATA")
            }),
            UpgradeOp({
                proxyAdmin: addrs.marketRouterProxyAdmin,
                proxy: addrs.marketRouter,
                implementation: _envAddressOrZero("MARKET_ROUTER_NEW_IMPLEMENTATION"),
                data: _envBytesOrEmpty("MARKET_ROUTER_UPGRADE_DATA")
            }),
            UpgradeOp({
                proxyAdmin: addrs.shareholderRoyaltiesProxyAdmin,
                proxy: addrs.shareholderRoyalties,
                implementation: _envAddressOrZero("SHAREHOLDER_ROYALTIES_NEW_IMPLEMENTATION"),
                data: _envBytesOrEmpty("SHAREHOLDER_ROYALTIES_UPGRADE_DATA")
            })
        ];

        uint256 count = 0;
        for (uint256 i = 0; i < allOps.length; i++) {
            if (allOps[i].implementation != address(0)) {
                _requireCode(allOps[i].proxyAdmin, "runtime proxy admin");
                _requireCode(allOps[i].proxy, "runtime proxy");
                _requireCode(allOps[i].implementation, "new implementation");
                require(
                    ProxyAdmin(allOps[i].proxyAdmin).owner() == addrs.timelock,
                    "TimelockRuntimeUpgrade: proxy admin not owned by timelock"
                );
                count++;
            }
        }

        ops = new UpgradeOp[](count);
        uint256 cursor = 0;
        for (uint256 i = 0; i < allOps.length; i++) {
            if (allOps[i].implementation == address(0)) continue;
            ops[cursor] = allOps[i];
            cursor++;
        }
    }

    function _buildBatch(UpgradeOp[] memory ops)
        internal
        pure
        returns (address[] memory targets, uint256[] memory values, bytes[] memory payloads)
    {
        targets = new address[](ops.length);
        values = new uint256[](ops.length);
        payloads = new bytes[](ops.length);

        for (uint256 i = 0; i < ops.length; i++) {
            targets[i] = ops[i].proxyAdmin;
            payloads[i] = abi.encodeCall(
                ProxyAdmin.upgradeAndCall,
                (ITransparentUpgradeableProxy(payable(ops[i].proxy)), ops[i].implementation, ops[i].data)
            );
        }
    }

    function _simulateSchedule(
        TimelockController timelock,
        address actor,
        address[] memory targets,
        uint256[] memory values,
        bytes[] memory payloads,
        bytes32 salt,
        bytes32 operationId
    ) internal {
        uint256 snap = vm.snapshot();
        vm.startPrank(actor);
        timelock.scheduleBatch(targets, values, payloads, ZERO_PREDECESSOR, salt, timelock.getMinDelay());
        require(
            timelock.isOperationPending(operationId),
            "TimelockRuntimeUpgrade: schedule simulation did not queue operation"
        );
        vm.stopPrank();
        require(vm.revertTo(snap), "TimelockRuntimeUpgrade: failed to revert schedule simulation snapshot");
    }

    function _simulateExecute(
        TimelockController timelock,
        address actor,
        address[] memory targets,
        uint256[] memory values,
        bytes[] memory payloads,
        bytes32 salt,
        bytes32 operationId
    ) internal {
        uint256 snap = vm.snapshot();
        vm.startPrank(actor);
        timelock.executeBatch(targets, values, payloads, ZERO_PREDECESSOR, salt);
        require(timelock.isOperationDone(operationId), "TimelockRuntimeUpgrade: execute simulation did not complete");
        vm.stopPrank();
        require(vm.revertTo(snap), "TimelockRuntimeUpgrade: failed to revert execute simulation snapshot");
    }

    function _assertUpgraded(UpgradeOp[] memory ops) internal view {
        for (uint256 i = 0; i < ops.length; i++) {
            require(
                _readAddressSlot(ops[i].proxy, IMPLEMENTATION_SLOT) == ops[i].implementation,
                "TimelockRuntimeUpgrade: implementation slot mismatch after execute"
            );
        }
    }

    function _parseAction() internal returns (Action action) {
        string memory raw = _envStringOr("TIMELOCK_ACTION", "schedule");
        bytes32 hash = keccak256(bytes(raw));
        if (hash == keccak256("schedule")) return Action.Schedule;
        if (hash == keccak256("execute")) return Action.Execute;
        revert("TimelockRuntimeUpgrade: TIMELOCK_ACTION must be schedule or execute");
    }

    function _readAddressSlot(address target, bytes32 slot) internal view returns (address out) {
        out = address(uint160(uint256(vm.load(target, slot))));
    }
}
