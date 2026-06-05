// SPDX-License-Identifier: MIT
pragma solidity ^0.8.34;

import {ProxyAdmin} from "lib/openzeppelin-contracts/contracts/proxy/transparent/ProxyAdmin.sol";
import {
    ITransparentUpgradeableProxy
} from "lib/openzeppelin-contracts/contracts/proxy/transparent/TransparentUpgradeableProxy.sol";
import {TimelockController} from "lib/openzeppelin-contracts/contracts/governance/TimelockController.sol";
import {TimelockScriptBase} from "./lib/TimelockScriptBase.sol";

/// @notice Schedule or execute the ONE atomic Timelock batch that activates the
///         shareholder route-to-caller path on a live, timelock-owned (NOT-frozen) stack.
///
/// @dev The batch is a single ordered sequence of 5 calls. Ordering is load-bearing —
///      `Furnace.setDelegationHub` validates the candidate hub against
///      `MineCore.delegationHub()` (via `FurnaceGuardHelper.requireCanonicalDelegationHub`),
///      so MineCore must be re-pointed first:
///
///        0. ShareholderRoyalties ProxyAdmin.upgradeAndCall(SR proxy, NEW_SR_IMPL, "")
///        1. MineCore.setDelegationHub(NEW_DELEGATION_HUB)
///        2. Furnace.setDelegationHub(NEW_DELEGATION_HUB)        [requires (1)]
///        3. MineCore.setClaimAllHelper(NEW_CLAIM_ALL_HELPER)
///        4. ShareholderRoyalties.setClaimAllHelper(NEW_CLAIM_ALL_HELPER)
///
///      All five execute atomically inside `TimelockController.executeBatch`, so the stack
///      is never observed in a partially-rewired state. The setters are `onlyOwner` (owner
///      == Timelock) and the core MineCore/SR setters are `whenNotFrozen` — this batch MUST
///      land before any `FreezeAndBurn` ceremony.
///
///      Required env:
///        - NEW_DELEGATION_HUB
///        - NEW_CLAIM_ALL_HELPER
///        - NEW_SHAREHOLDER_ROYALTIES_IMPL
///      Optional:
///        - TIMELOCK_ACTION   (schedule | execute; default schedule)
///        - TIMELOCK_SALT
///        - TIMELOCK_CALLER / ADMIN_SAFE  (simulation-only: prints the calldata the Safe submits)
contract TimelockDelegationRewire is TimelockScriptBase {
    enum Action {
        Schedule,
        Execute
    }

    bytes32 internal constant IMPLEMENTATION_SLOT = 0x360894a13ba1a3210667c828492db98dca3e2076cc3735a920a3ca505d382bbc;

    function run() external {
        GovernanceAddrs memory addrs = _loadGovernanceAddrs();
        _requireCode(addrs.timelock, "TimelockController");
        _requireCode(addrs.mineCore, "MineCore");
        _requireCode(addrs.furnace, "Furnace");
        _requireCode(addrs.shareholderRoyalties, "ShareholderRoyalties");
        _requireCode(addrs.shareholderRoyaltiesProxyAdmin, "ShareholderRoyalties ProxyAdmin");

        address newHub = vm.envAddress("NEW_DELEGATION_HUB");
        address newHelper = vm.envAddress("NEW_CLAIM_ALL_HELPER");
        address newRoyaltiesImpl = vm.envAddress("NEW_SHAREHOLDER_ROYALTIES_IMPL");
        _requireCode(newHub, "NEW_DELEGATION_HUB");
        _requireCode(newHelper, "NEW_CLAIM_ALL_HELPER");
        _requireCode(newRoyaltiesImpl, "NEW_SHAREHOLDER_ROYALTIES_IMPL");

        // Fail closed if the surfaces this batch mutates are not Timelock-governed.
        require(
            ProxyAdmin(addrs.shareholderRoyaltiesProxyAdmin).owner() == addrs.timelock,
            "TimelockDelegationRewire: SR proxy admin not owned by timelock"
        );
        _requireOwner(addrs.mineCore, addrs.timelock, "MineCore");
        _requireOwner(addrs.furnace, addrs.timelock, "Furnace");
        _requireOwner(addrs.shareholderRoyalties, addrs.timelock, "ShareholderRoyalties");

        (address[] memory targets, uint256[] memory values, bytes[] memory payloads) =
            _buildBatch(addrs, newHub, newHelper, newRoyaltiesImpl);

        TimelockController timelock = TimelockController(payable(addrs.timelock));
        bytes32 salt = _envBytes32OrZero("TIMELOCK_SALT");
        bytes32 operationId = timelock.hashOperationBatch(targets, values, payloads, ZERO_PREDECESSOR, salt);
        _logOperation(operationId, "TimelockDelegationRewire.operationId");

        Action action = _parseAction();
        address contractCaller = _timelockCallerOrZero();

        if (contractCaller != address(0)) {
            if (action == Action.Schedule) {
                _requireTimelockActionCaller(timelock, contractCaller, true);
                _dryRunBatchExecution(addrs, targets, values, payloads, newHub, newHelper, newRoyaltiesImpl);
                _simulateSchedule(timelock, contractCaller, targets, values, payloads, salt, operationId);
                _logTimelockActionSubmission(
                    "TimelockDelegationRewire.scheduleBatch",
                    contractCaller,
                    address(timelock),
                    abi.encodeCall(
                        TimelockController.scheduleBatch,
                        (targets, values, payloads, ZERO_PREDECESSOR, salt, timelock.getMinDelay())
                    )
                );
            } else {
                require(timelock.isOperationReady(operationId), "TimelockDelegationRewire: operation is not ready");
                _requireTimelockActionCaller(timelock, contractCaller, false);
                _simulateExecute(timelock, contractCaller, targets, values, payloads, salt, operationId);
                _logTimelockActionSubmission(
                    "TimelockDelegationRewire.executeBatch",
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
            _dryRunBatchExecution(addrs, targets, values, payloads, newHub, newHelper, newRoyaltiesImpl);
            _simulateSchedule(timelock, actor, targets, values, payloads, salt, operationId);

            _startBroadcast(signer);
            timelock.scheduleBatch(targets, values, payloads, ZERO_PREDECESSOR, salt, timelock.getMinDelay());
            vm.stopBroadcast();
            require(timelock.isOperationPending(operationId), "TimelockDelegationRewire: operation not pending");
        } else {
            require(timelock.isOperationReady(operationId), "TimelockDelegationRewire: operation is not ready");
            _requireTimelockActionCaller(timelock, actor, false);
            _simulateExecute(timelock, actor, targets, values, payloads, salt, operationId);

            _startBroadcast(signer);
            timelock.executeBatch(targets, values, payloads, ZERO_PREDECESSOR, salt);
            vm.stopBroadcast();
            require(timelock.isOperationDone(operationId), "TimelockDelegationRewire: operation not done");
            _assertRewired(addrs, newHub, newHelper, newRoyaltiesImpl);
        }
    }

    function _buildBatch(GovernanceAddrs memory addrs, address newHub, address newHelper, address newRoyaltiesImpl)
        internal
        pure
        returns (address[] memory targets, uint256[] memory values, bytes[] memory payloads)
    {
        targets = new address[](5);
        values = new uint256[](5);
        payloads = new bytes[](5);

        // 0. Upgrade the ShareholderRoyalties implementation (adds claimShareholderForTo).
        targets[0] = addrs.shareholderRoyaltiesProxyAdmin;
        payloads[0] = abi.encodeCall(
            ProxyAdmin.upgradeAndCall,
            (ITransparentUpgradeableProxy(payable(addrs.shareholderRoyalties)), newRoyaltiesImpl, bytes(""))
        );

        // 1. Re-point MineCore at the new DelegationHub FIRST so Furnace's canonical check passes.
        targets[1] = addrs.mineCore;
        payloads[1] = abi.encodeWithSignature("setDelegationHub(address)", newHub);

        // 2. Re-point Furnace at the new DelegationHub (validates against MineCore's hub).
        targets[2] = addrs.furnace;
        payloads[2] = abi.encodeWithSignature("setDelegationHub(address)", newHub);

        // 3. Re-point MineCore at the new ClaimAllHelper.
        targets[3] = addrs.mineCore;
        payloads[3] = abi.encodeWithSignature("setClaimAllHelper(address)", newHelper);

        // 4. Re-point ShareholderRoyalties at the new ClaimAllHelper.
        targets[4] = addrs.shareholderRoyalties;
        payloads[4] = abi.encodeWithSignature("setClaimAllHelper(address)", newHelper);
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
            "TimelockDelegationRewire: schedule simulation did not queue operation"
        );
        vm.stopPrank();
        require(vm.revertTo(snap), "TimelockDelegationRewire: failed to revert schedule simulation snapshot");
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
        require(timelock.isOperationDone(operationId), "TimelockDelegationRewire: execute simulation did not complete");
        vm.stopPrank();
        require(vm.revertTo(snap), "TimelockDelegationRewire: failed to revert execute simulation snapshot");
    }

    /// @dev Schedule-time fail-closed guard. `scheduleBatch` only queues the operation hash; it
    ///      does NOT run the inner calls, so a frozen config, a wiring drift, or the Furnace
    ///      canonical-hub ordering guard would otherwise stay silent until `executeBatch` —
    ///      AFTER the timelock min-delay has already been burned. This dry-runs every inner call
    ///      AS the Timelock (matching `executeBatch` semantics: setters are `onlyOwner == Timelock`
    ///      and `ProxyAdmin.upgradeAndCall` is `onlyOwner == Timelock`), in batch order, inside a
    ///      snapshot that is reverted before returning. Any revert here aborts the schedule.
    function _dryRunBatchExecution(
        GovernanceAddrs memory addrs,
        address[] memory targets,
        uint256[] memory values,
        bytes[] memory payloads,
        address newHub,
        address newHelper,
        address newRoyaltiesImpl
    ) internal {
        uint256 snap = vm.snapshot();
        for (uint256 i = 0; i < targets.length; i++) {
            vm.prank(addrs.timelock);
            (bool ok,) = targets[i].call{value: values[i]}(payloads[i]);
            require(
                ok,
                string.concat(
                    "TimelockDelegationRewire: schedule-time dry-run reverted on batch call #",
                    vm.toString(i),
                    " (check config-frozen / wiring / hub ordering)"
                )
            );
        }
        _assertRewired(addrs, newHub, newHelper, newRoyaltiesImpl);
        require(vm.revertTo(snap), "TimelockDelegationRewire: failed to revert dry-run snapshot");
    }

    function _assertRewired(GovernanceAddrs memory addrs, address newHub, address newHelper, address newRoyaltiesImpl)
        internal
        view
    {
        require(
            _readAddressSlot(addrs.shareholderRoyalties, IMPLEMENTATION_SLOT) == newRoyaltiesImpl,
            "TimelockDelegationRewire: SR implementation slot mismatch after execute"
        );
        require(
            _readAddressFn(addrs.mineCore, "delegationHub()") == newHub,
            "TimelockDelegationRewire: MineCore delegationHub mismatch after execute"
        );
        require(
            _readAddressFn(addrs.furnace, "delegationHub()") == newHub,
            "TimelockDelegationRewire: Furnace delegationHub mismatch after execute"
        );
        require(
            _readAddressFn(addrs.mineCore, "claimAllHelper()") == newHelper,
            "TimelockDelegationRewire: MineCore claimAllHelper mismatch after execute"
        );
        require(
            _readAddressFn(addrs.shareholderRoyalties, "claimAllHelper()") == newHelper,
            "TimelockDelegationRewire: ShareholderRoyalties claimAllHelper mismatch after execute"
        );
    }

    function _requireOwner(address target, address expectedOwner, string memory label) internal view {
        require(
            _readAddressFn(target, "owner()") == expectedOwner,
            string.concat("TimelockDelegationRewire: ", label, " not owned by timelock")
        );
    }

    function _parseAction() internal returns (Action action) {
        string memory raw = _envStringOr("TIMELOCK_ACTION", "schedule");
        bytes32 hash = keccak256(bytes(raw));
        if (hash == keccak256("schedule")) return Action.Schedule;
        if (hash == keccak256("execute")) return Action.Execute;
        revert("TimelockDelegationRewire: TIMELOCK_ACTION must be schedule or execute");
    }

    function _readAddressSlot(address target, bytes32 slot) internal view returns (address out) {
        out = address(uint160(uint256(vm.load(target, slot))));
    }

    function _readAddressFn(address target, string memory sig) internal view returns (address out) {
        (bool ok, bytes memory data) = target.staticcall(abi.encodeWithSignature(sig));
        require(ok && data.length >= 32, string.concat("TimelockDelegationRewire: staticcall failed for ", sig));
        out = abi.decode(data, (address));
    }
}
