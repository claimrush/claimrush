// SPDX-License-Identifier: MIT
pragma solidity ^0.8.34;

import {TimelockController} from "lib/openzeppelin-contracts/contracts/governance/TimelockController.sol";
import {TimelockScriptBase} from "./lib/TimelockScriptBase.sol";

interface IOwnable2StepAcceptLike {
    function owner() external view returns (address);
    function pendingOwner() external view returns (address);
    function acceptOwnership() external;
}

/// @notice Schedule or execute a timelock batch that accepts ownership on all pending Ownable2Step protocol contracts.
/// @dev Usage:
///      - EOA caller (schedule needs PROPOSER_ROLE; execute needs EXECUTOR_ROLE):
///        `TIMELOCK_ACTION=schedule TIMELOCK_SALT=0x... forge script ... --broadcast`
///      - Safe / contract caller:
///        set `TIMELOCK_CALLER=<safe>` (or `ADMIN_SAFE=<safe>`) and run without `--broadcast`
///        to simulate the action and print the exact calldata the Safe must submit.
///      Schedule mode intentionally supports pre-scheduling before `FinalizeOwnership.s.sol` runs so the
///      timelock delay can elapse before ownership is initiated; execute mode then fails closed unless every
///      ownership-bearing target is either already timelock-owned or pending to the timelock.
contract TimelockAcceptOwnership is TimelockScriptBase {
    bytes32 internal constant DEFAULT_ADMIN_ROLE = bytes32(0);

    enum Action {
        Schedule,
        Execute
    }

    function run() external {
        GovernanceAddrs memory addrs = _loadGovernanceAddrs();
        _requireCode(addrs.timelock, "TimelockController");

        TimelockController timelock = TimelockController(payable(addrs.timelock));
        Action action = _parseAction();
        _assertBootstrapFinalized(timelock, addrs.timelockBootstrapAdmin);

        address[9] memory candidates = _candidateTargets(addrs);
        (address[] memory targets, uint256[] memory values, bytes[] memory payloads) =
            _buildBatch(candidates, addrs.timelock, action);
        require(
            targets.length != 0,
            action == Action.Schedule
                ? "TimelockAcceptOwnership: no ownership acceptances remain to schedule"
                : "TimelockAcceptOwnership: no pending ownership acceptances found"
        );

        bytes32 salt = _envBytes32OrZero("TIMELOCK_SALT");
        bytes32 operationId = timelock.hashOperationBatch(targets, values, payloads, ZERO_PREDECESSOR, salt);
        _logOperation(operationId, "TimelockAcceptOwnership.operationId");

        address contractCaller = _timelockCallerOrZero();

        if (contractCaller != address(0)) {
            if (action == Action.Schedule) {
                _requireTimelockActionCaller(timelock, contractCaller, true);
                _simulateSchedule(timelock, contractCaller, targets, values, payloads, salt, operationId);
                _logTimelockActionSubmission(
                    "TimelockAcceptOwnership.scheduleBatch",
                    contractCaller,
                    address(timelock),
                    abi.encodeCall(
                        TimelockController.scheduleBatch,
                        (targets, values, payloads, ZERO_PREDECESSOR, salt, timelock.getMinDelay())
                    )
                );
            } else {
                require(timelock.isOperationReady(operationId), "TimelockAcceptOwnership: operation is not ready");
                _requireTimelockActionCaller(timelock, contractCaller, false);
                _simulateExecute(timelock, contractCaller, targets, values, payloads, salt, operationId);
                _logTimelockActionSubmission(
                    "TimelockAcceptOwnership.executeBatch",
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
            require(timelock.isOperationPending(operationId), "TimelockAcceptOwnership: operation not pending");
        } else {
            require(timelock.isOperationReady(operationId), "TimelockAcceptOwnership: operation is not ready");
            _requireTimelockActionCaller(timelock, actor, false);
            _simulateExecute(timelock, actor, targets, values, payloads, salt, operationId);

            _startBroadcast(signer);
            timelock.executeBatch(targets, values, payloads, ZERO_PREDECESSOR, salt);
            vm.stopBroadcast();
            require(timelock.isOperationDone(operationId), "TimelockAcceptOwnership: operation not done");
            _assertAccepted(addrs.timelock, candidates);
        }
    }

    function _candidateTargets(GovernanceAddrs memory addrs) internal view returns (address[9] memory candidates) {
        candidates[0] = addrs.veClaimNFT;
        candidates[1] = addrs.mineCore;
        candidates[2] = addrs.shareholderRoyalties;
        candidates[3] = addrs.furnace;
        candidates[4] = addrs.marketRouter;
        candidates[5] = addrs.furnaceEntryTokenRegistry;
        candidates[6] = addrs.mineCoreEntryTokenRegistry;
        candidates[7] = addrs.dexAdapter;
        candidates[8] = addrs.lpStakingVault7D;

        for (uint256 i = 0; i < candidates.length; i++) {
            _requireCode(candidates[i], _candidateLabel(i));
        }
    }

    function _buildBatch(address[9] memory candidates, address timelockAddr, Action action)
        internal
        view
        returns (address[] memory targets, uint256[] memory values, bytes[] memory payloads)
    {
        uint256 count = 0;
        for (uint256 i = 0; i < candidates.length; i++) {
            if (_needsAcceptance(candidates[i], timelockAddr, action, _candidateLabel(i))) count++;
        }

        targets = new address[](count);
        values = new uint256[](count);
        payloads = new bytes[](count);

        uint256 cursor = 0;
        for (uint256 i = 0; i < candidates.length; i++) {
            address target = candidates[i];
            if (!_needsAcceptance(target, timelockAddr, action, _candidateLabel(i))) continue;

            targets[cursor] = target;
            payloads[cursor] = abi.encodeCall(IOwnable2StepAcceptLike.acceptOwnership, ());
            cursor++;
        }
    }

    function _needsAcceptance(address target, address timelockAddr, Action action, string memory label)
        internal
        view
        returns (bool)
    {
        IOwnable2StepAcceptLike ownable = IOwnable2StepAcceptLike(target);
        address owner0 = ownable.owner();
        address pendingOwner0 = ownable.pendingOwner();

        if (owner0 == timelockAddr) {
            require(
                pendingOwner0 == address(0),
                string.concat(
                    "TimelockAcceptOwnership: ", label, " already owned by timelock but still has pending owner"
                )
            );
            return false;
        }

        require(
            pendingOwner0 == address(0) || pendingOwner0 == timelockAddr,
            string.concat("TimelockAcceptOwnership: ", label, " pendingOwner drift")
        );
        if (action == Action.Execute) {
            require(
                pendingOwner0 == timelockAddr,
                string.concat("TimelockAcceptOwnership: ", label, " not pending to timelock")
            );
        }
        return true;
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
            "TimelockAcceptOwnership: schedule simulation did not queue operation"
        );
        vm.stopPrank();
        require(vm.revertTo(snap), "TimelockAcceptOwnership: failed to revert schedule simulation snapshot");
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
        require(timelock.isOperationDone(operationId), "TimelockAcceptOwnership: execute simulation did not complete");
        vm.stopPrank();
        require(vm.revertTo(snap), "TimelockAcceptOwnership: failed to revert execute simulation snapshot");
    }

    function _assertAccepted(address timelockAddr, address[9] memory candidates) internal view {
        for (uint256 i = 0; i < candidates.length; i++) {
            IOwnable2StepAcceptLike ownable = IOwnable2StepAcceptLike(candidates[i]);
            require(
                ownable.owner() == timelockAddr,
                string.concat("TimelockAcceptOwnership: ", _candidateLabel(i), " owner mismatch after execute")
            );
            require(
                ownable.pendingOwner() == address(0),
                string.concat(
                    "TimelockAcceptOwnership: ", _candidateLabel(i), " pending owner not cleared after execute"
                )
            );
        }
    }

    function _assertBootstrapFinalized(TimelockController timelock, address bootstrapAdmin) internal view {
        require(
            timelock.hasRole(DEFAULT_ADMIN_ROLE, address(timelock)),
            "TimelockAcceptOwnership: timelock missing self-admin role"
        );
        if (block.chainid != 31337 && block.chainid != 1337) {
            require(bootstrapAdmin != address(0), "TimelockAcceptOwnership: missing timelock bootstrap admin");
        }
        if (bootstrapAdmin != address(0)) {
            require(
                !timelock.hasRole(DEFAULT_ADMIN_ROLE, bootstrapAdmin),
                "TimelockAcceptOwnership: timelock bootstrap admin still active"
            );
        }
    }

    function _candidateLabel(uint256 index) internal pure returns (string memory) {
        if (index == 0) return "VeClaimNFT";
        if (index == 1) return "MineCore";
        if (index == 2) return "ShareholderRoyalties";
        if (index == 3) return "Furnace";
        if (index == 4) return "MarketRouter";
        if (index == 5) return "FurnaceEntryTokenRegistry";
        if (index == 6) return "MineCoreEntryTokenRegistry";
        if (index == 7) return "DexAdapter";
        if (index == 8) return "LpStakingVault7D";
        revert("TimelockAcceptOwnership: invalid candidate index");
    }

    function _parseAction() internal returns (Action action) {
        string memory raw = _envStringOr("TIMELOCK_ACTION", "schedule");
        bytes32 hash = keccak256(bytes(raw));
        if (hash == keccak256("schedule")) return Action.Schedule;
        if (hash == keccak256("execute")) return Action.Execute;
        revert("TimelockAcceptOwnership: TIMELOCK_ACTION must be schedule or execute");
    }
}
