// SPDX-License-Identifier: MIT
pragma solidity ^0.8.34;

import {TimelockController} from "lib/openzeppelin-contracts/contracts/governance/TimelockController.sol";
import {TimelockScriptBase} from "./lib/TimelockScriptBase.sol";

/// @notice Schedule or execute the single-call Timelock batch that re-points the
///         live Furnace at a freshly-deployed FurnaceQuoter.
///
/// @dev The batch is ONE call: `Furnace.setFurnaceQuoter(NEW_FURNACE_QUOTER)`.
///      `setFurnaceQuoter` is `onlyOwner` (owner == Timelock) and `whenNotFrozen`,
///      and it routes through `FurnaceGuardHelper.requireFurnaceQuoterCompatible`
///      (the candidate must be a contract, must not revert on `userSpotBonusBps` /
///      `lpScaleBps`, and `quoter.furnace()` must equal this Furnace). The
///      schedule-time dry-run below executes the call AS the Timelock inside a
///      reverted snapshot, so a frozen config or an incompatible quoter fails
///      BEFORE the min-delay is burned rather than at `executeBatch`.
///
///      It is emitted via `scheduleBatch` / `executeBatch` (one-element arrays) so
///      the ADMIN_SAFE submits through the Transaction Builder "Enter ABI" path
///      (decoded struct params), matching the house workflow for Timelock batches.
///
///      Required env:
///        - NEW_FURNACE_QUOTER
///      Optional:
///        - TIMELOCK_ACTION   (schedule | execute; default schedule)
///        - TIMELOCK_SALT
///        - TIMELOCK_CALLER / ADMIN_SAFE  (simulation-only: prints the calldata the Safe submits)
contract TimelockSetFurnaceQuoter is TimelockScriptBase {
    enum Action {
        Schedule,
        Execute
    }

    function run() external {
        GovernanceAddrs memory addrs = _loadGovernanceAddrs();
        _requireCode(addrs.timelock, "TimelockController");
        _requireCode(addrs.furnace, "Furnace");

        address newQuoter = vm.envAddress("NEW_FURNACE_QUOTER");
        _requireCode(newQuoter, "NEW_FURNACE_QUOTER");

        // Fail closed if the surface this batch mutates is not Timelock-governed.
        _requireOwner(addrs.furnace, addrs.timelock, "Furnace");

        // The new quoter MUST already be bound to this Furnace; the on-chain
        // compatibility gate enforces the same, but checking here surfaces a
        // mis-deployed quoter before any governance action is taken.
        require(
            _readAddressFn(newQuoter, "furnace()") == addrs.furnace,
            "TimelockSetFurnaceQuoter: NEW_FURNACE_QUOTER.furnace() != Furnace"
        );

        (address[] memory targets, uint256[] memory values, bytes[] memory payloads) = _buildBatch(addrs, newQuoter);

        TimelockController timelock = TimelockController(payable(addrs.timelock));
        bytes32 salt = _envBytes32OrZero("TIMELOCK_SALT");
        bytes32 operationId = timelock.hashOperationBatch(targets, values, payloads, ZERO_PREDECESSOR, salt);
        _logOperation(operationId, "TimelockSetFurnaceQuoter.operationId");

        Action action = _parseAction();
        address contractCaller = _timelockCallerOrZero();

        if (contractCaller != address(0)) {
            if (action == Action.Schedule) {
                _requireTimelockActionCaller(timelock, contractCaller, true);
                _dryRunBatchExecution(addrs, targets, values, payloads, newQuoter);
                _simulateSchedule(timelock, contractCaller, targets, values, payloads, salt, operationId);
                _logTimelockActionSubmission(
                    "TimelockSetFurnaceQuoter.scheduleBatch",
                    contractCaller,
                    address(timelock),
                    abi.encodeCall(
                        TimelockController.scheduleBatch,
                        (targets, values, payloads, ZERO_PREDECESSOR, salt, timelock.getMinDelay())
                    )
                );
            } else {
                require(timelock.isOperationReady(operationId), "TimelockSetFurnaceQuoter: operation is not ready");
                _requireTimelockActionCaller(timelock, contractCaller, false);
                _simulateExecute(timelock, contractCaller, targets, values, payloads, salt, operationId);
                _logTimelockActionSubmission(
                    "TimelockSetFurnaceQuoter.executeBatch",
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
            _dryRunBatchExecution(addrs, targets, values, payloads, newQuoter);
            _simulateSchedule(timelock, actor, targets, values, payloads, salt, operationId);

            _startBroadcast(signer);
            timelock.scheduleBatch(targets, values, payloads, ZERO_PREDECESSOR, salt, timelock.getMinDelay());
            vm.stopBroadcast();
            require(timelock.isOperationPending(operationId), "TimelockSetFurnaceQuoter: operation not pending");
        } else {
            require(timelock.isOperationReady(operationId), "TimelockSetFurnaceQuoter: operation is not ready");
            _requireTimelockActionCaller(timelock, actor, false);
            _simulateExecute(timelock, actor, targets, values, payloads, salt, operationId);

            _startBroadcast(signer);
            timelock.executeBatch(targets, values, payloads, ZERO_PREDECESSOR, salt);
            vm.stopBroadcast();
            require(timelock.isOperationDone(operationId), "TimelockSetFurnaceQuoter: operation not done");
            _assertRewired(addrs, newQuoter);
        }
    }

    function _buildBatch(GovernanceAddrs memory addrs, address newQuoter)
        internal
        pure
        returns (address[] memory targets, uint256[] memory values, bytes[] memory payloads)
    {
        targets = new address[](1);
        values = new uint256[](1);
        payloads = new bytes[](1);

        targets[0] = addrs.furnace;
        payloads[0] = abi.encodeWithSignature("setFurnaceQuoter(address)", newQuoter);
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
            "TimelockSetFurnaceQuoter: schedule simulation did not queue operation"
        );
        vm.stopPrank();
        require(vm.revertTo(snap), "TimelockSetFurnaceQuoter: failed to revert schedule simulation snapshot");
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
        require(timelock.isOperationDone(operationId), "TimelockSetFurnaceQuoter: execute simulation did not complete");
        vm.stopPrank();
        require(vm.revertTo(snap), "TimelockSetFurnaceQuoter: failed to revert execute simulation snapshot");
    }

    /// @dev Schedule-time fail-closed guard. `scheduleBatch` only queues the operation hash;
    ///      it does NOT run the inner call, so a frozen config or an incompatible quoter would
    ///      otherwise stay silent until `executeBatch` — AFTER the min-delay is already burned.
    ///      This dry-runs the call AS the Timelock (matching `executeBatch` semantics:
    ///      `setFurnaceQuoter` is `onlyOwner == Timelock`) inside a reverted snapshot.
    function _dryRunBatchExecution(
        GovernanceAddrs memory addrs,
        address[] memory targets,
        uint256[] memory values,
        bytes[] memory payloads,
        address newQuoter
    ) internal {
        uint256 snap = vm.snapshot();
        for (uint256 i = 0; i < targets.length; i++) {
            vm.prank(addrs.timelock);
            (bool ok,) = targets[i].call{value: values[i]}(payloads[i]);
            require(
                ok,
                string.concat(
                    "TimelockSetFurnaceQuoter: schedule-time dry-run reverted on batch call #",
                    vm.toString(i),
                    " (check config-frozen / quoter compatibility)"
                )
            );
        }
        _assertRewired(addrs, newQuoter);
        require(vm.revertTo(snap), "TimelockSetFurnaceQuoter: failed to revert dry-run snapshot");
    }

    function _assertRewired(GovernanceAddrs memory addrs, address newQuoter) internal view {
        require(
            _readAddressFn(addrs.furnace, "furnaceQuoter()") == newQuoter,
            "TimelockSetFurnaceQuoter: Furnace furnaceQuoter mismatch after execute"
        );
    }

    function _requireOwner(address target, address expectedOwner, string memory label) internal view {
        require(
            _readAddressFn(target, "owner()") == expectedOwner,
            string.concat("TimelockSetFurnaceQuoter: ", label, " not owned by timelock")
        );
    }

    function _parseAction() internal returns (Action action) {
        string memory raw = _envStringOr("TIMELOCK_ACTION", "schedule");
        bytes32 hash = keccak256(bytes(raw));
        if (hash == keccak256("schedule")) return Action.Schedule;
        if (hash == keccak256("execute")) return Action.Execute;
        revert("TimelockSetFurnaceQuoter: TIMELOCK_ACTION must be schedule or execute");
    }

    function _readAddressFn(address target, string memory sig) internal view returns (address out) {
        (bool ok, bytes memory data) = target.staticcall(abi.encodeWithSignature(sig));
        require(ok && data.length >= 32, string.concat("TimelockSetFurnaceQuoter: staticcall failed for ", sig));
        out = abi.decode(data, (address));
    }
}
