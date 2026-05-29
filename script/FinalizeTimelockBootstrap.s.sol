// SPDX-License-Identifier: MIT
pragma solidity ^0.8.34;

import {TimelockController} from "lib/openzeppelin-contracts/contracts/governance/TimelockController.sol";
import {TimelockScriptBase} from "./lib/TimelockScriptBase.sol";

/// @notice Finalize governance timelock bootstrap by granting the Guardian an independent
///         cancellation role and renouncing the deployer's bootstrap admin role.
/// @dev Preconditions:
///      - the timelock is already deployed and recorded in the deployment manifest
///      - the Safe already has proposer / canceller / executor roles
///      - the timelock still has self-admin
///      Broadcast this as the deployer once the role configuration is verified.
///
///      On non-local chains, GUARDIAN is required. The script grants CANCELLER_ROLE to
///      the Guardian Safe so there is an independent party that can cancel malicious
///      proposals during the timelock delay window, even if ADMIN_SAFE is compromised.
///      The Guardian does NOT receive PROPOSER_ROLE or EXECUTOR_ROLE.
contract FinalizeTimelockBootstrap is TimelockScriptBase {
    bytes32 internal constant PROPOSER_ROLE = keccak256("PROPOSER_ROLE");
    bytes32 internal constant EXECUTOR_ROLE = keccak256("EXECUTOR_ROLE");
    bytes32 internal constant CANCELLER_ROLE = keccak256("CANCELLER_ROLE");
    bytes32 internal constant DEFAULT_ADMIN_ROLE = bytes32(0);

    function run() external {
        GovernanceAddrs memory addrs = _loadGovernanceAddrs();
        _requireCode(addrs.timelock, "TimelockController");

        address adminSafe = vm.envAddress("ADMIN_SAFE");
        require(adminSafe != address(0), "FinalizeTimelockBootstrap: ADMIN_SAFE=0");

        address guardian = _envAddressOrZero("GUARDIAN");
        bool isLocal = block.chainid == 31337 || block.chainid == 1337;
        if (!isLocal) {
            require(guardian != address(0), "FinalizeTimelockBootstrap: GUARDIAN required on non-local chains");
            require(guardian != adminSafe, "FinalizeTimelockBootstrap: GUARDIAN must differ from ADMIN_SAFE");
            require(guardian.code.length > 0, "FinalizeTimelockBootstrap: GUARDIAN is not a contract");
        }

        TimelockController timelock = TimelockController(payable(addrs.timelock));
        _assertBootstrapState(timelock, adminSafe);

        BroadcastSigner memory signer = _broadcastSigner();
        address actor = signer.account;
        if (!isLocal) {
            require(
                addrs.timelockBootstrapAdmin != address(0),
                "FinalizeTimelockBootstrap: missing manifest bootstrap admin"
            );
        }
        if (addrs.timelockBootstrapAdmin != address(0)) {
            require(
                addrs.timelockBootstrapAdmin == actor, "FinalizeTimelockBootstrap: actor != manifest bootstrap admin"
            );
        }
        require(
            timelock.hasRole(DEFAULT_ADMIN_ROLE, actor),
            "FinalizeTimelockBootstrap: actor lacks bootstrap timelock admin role"
        );

        bool grantGuardianCanceller = guardian != address(0) && !timelock.hasRole(CANCELLER_ROLE, guardian);

        uint256 snap = vm.snapshot();
        vm.startPrank(actor);
        if (grantGuardianCanceller) {
            timelock.grantRole(CANCELLER_ROLE, guardian);
        }
        timelock.renounceRole(DEFAULT_ADMIN_ROLE, actor);
        require(
            !timelock.hasRole(DEFAULT_ADMIN_ROLE, actor),
            "FinalizeTimelockBootstrap: deployer admin role still present after simulation"
        );
        vm.stopPrank();
        require(vm.revertTo(snap), "FinalizeTimelockBootstrap: failed to revert preflight snapshot");

        _startBroadcast(signer);
        if (grantGuardianCanceller) {
            timelock.grantRole(CANCELLER_ROLE, guardian);
        }
        timelock.renounceRole(DEFAULT_ADMIN_ROLE, actor);
        vm.stopBroadcast();

        _assertPostBootstrap(timelock, actor, adminSafe, guardian);
    }

    function _assertBootstrapState(TimelockController timelock, address adminSafe) internal view {
        require(
            timelock.hasRole(PROPOSER_ROLE, adminSafe), "FinalizeTimelockBootstrap: ADMIN_SAFE missing PROPOSER_ROLE"
        );
        require(
            timelock.hasRole(CANCELLER_ROLE, adminSafe), "FinalizeTimelockBootstrap: ADMIN_SAFE missing CANCELLER_ROLE"
        );
        require(
            timelock.hasRole(EXECUTOR_ROLE, adminSafe), "FinalizeTimelockBootstrap: ADMIN_SAFE missing EXECUTOR_ROLE"
        );
        require(
            timelock.hasRole(DEFAULT_ADMIN_ROLE, address(timelock)),
            "FinalizeTimelockBootstrap: timelock missing self-admin role"
        );
        require(
            !timelock.hasRole(EXECUTOR_ROLE, address(0)),
            "FinalizeTimelockBootstrap: EXECUTOR_ROLE is open (address(0)) - anyone can execute"
        );
        require(
            !timelock.hasRole(DEFAULT_ADMIN_ROLE, address(0)),
            "FinalizeTimelockBootstrap: DEFAULT_ADMIN_ROLE is open (address(0)) - anyone is admin"
        );
        require(
            !timelock.hasRole(DEFAULT_ADMIN_ROLE, adminSafe),
            "FinalizeTimelockBootstrap: ADMIN_SAFE has DEFAULT_ADMIN_ROLE - only deployer and timelock should"
        );
    }

    function _assertPostBootstrap(TimelockController timelock, address actor, address adminSafe, address guardian)
        internal
        view
    {
        // Deployer must have no roles whatsoever.
        require(
            !timelock.hasRole(DEFAULT_ADMIN_ROLE, actor),
            "FinalizeTimelockBootstrap: deployer admin role still present after broadcast"
        );
        require(!timelock.hasRole(PROPOSER_ROLE, actor), "FinalizeTimelockBootstrap: deployer still has PROPOSER_ROLE");
        require(
            !timelock.hasRole(CANCELLER_ROLE, actor), "FinalizeTimelockBootstrap: deployer still has CANCELLER_ROLE"
        );
        require(!timelock.hasRole(EXECUTOR_ROLE, actor), "FinalizeTimelockBootstrap: deployer still has EXECUTOR_ROLE");

        // ADMIN_SAFE operational roles preserved.
        require(timelock.hasRole(PROPOSER_ROLE, adminSafe), "FinalizeTimelockBootstrap: ADMIN_SAFE lost PROPOSER_ROLE");
        require(
            timelock.hasRole(CANCELLER_ROLE, adminSafe), "FinalizeTimelockBootstrap: ADMIN_SAFE lost CANCELLER_ROLE"
        );
        require(timelock.hasRole(EXECUTOR_ROLE, adminSafe), "FinalizeTimelockBootstrap: ADMIN_SAFE lost EXECUTOR_ROLE");

        // Guardian independent cancellation authority.
        if (guardian != address(0)) {
            require(
                timelock.hasRole(CANCELLER_ROLE, guardian), "FinalizeTimelockBootstrap: GUARDIAN missing CANCELLER_ROLE"
            );
            require(
                !timelock.hasRole(PROPOSER_ROLE, guardian),
                "FinalizeTimelockBootstrap: GUARDIAN must not have PROPOSER_ROLE"
            );
            require(
                !timelock.hasRole(EXECUTOR_ROLE, guardian),
                "FinalizeTimelockBootstrap: GUARDIAN must not have EXECUTOR_ROLE"
            );
        }
    }
}
