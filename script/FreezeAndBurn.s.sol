// SPDX-License-Identifier: MIT
pragma solidity ^0.8.34;

import {ClaimToken} from "../src/ClaimToken.sol";
import {Furnace} from "../src/Furnace.sol";
import {MineCore} from "../src/MineCore.sol";
import {VeClaimNFT} from "../src/VeClaimNFT.sol";
import {ShareholderRoyalties} from "../src/ShareholderRoyalties.sol";
import {ClaimAllHelper} from "../src/ClaimAllHelper.sol";
import {ProxyAdmin} from "lib/openzeppelin-contracts/contracts/proxy/transparent/ProxyAdmin.sol";
import {TimelockController} from "lib/openzeppelin-contracts/contracts/governance/TimelockController.sol";
import {TimelockScriptBase} from "./lib/TimelockScriptBase.sol";

interface IFreezeAndBurnOwnerCheck {
    function owner() external view returns (address);
}

/// @notice Schedule or execute the final freeze-and-burn timelock batch.
/// @dev ClaimToken freezes at wire time (Wire.s.sol) and its ownership is renounced there.
///      The batch order is intentionally:
///      1. four `freezeConfig()` calls (MineCore, Furnace, VeClaimNFT, ShareholderRoyalties)
///      2. all four runtime `ProxyAdmin.renounceOwnership()` calls
///      so any freeze-precondition failure reverts the whole batch before upgrade authority is burned.
///      The script asserts that ClaimToken is already frozen before scheduling.
///      When `TIMELOCK_CALLER` (or `ADMIN_SAFE`) is set to the Safe / proposer-executor contract,
///      the script runs in simulation-only mode and prints the calldata that contract must submit.
contract FreezeAndBurn is TimelockScriptBase {
    bytes32 internal constant DEFAULT_ADMIN_ROLE = bytes32(0);

    enum Action {
        Schedule,
        Execute
    }

    function run() external {
        GovernanceAddrs memory addrs = _loadGovernanceAddrs();
        _requireCode(addrs.timelock, "TimelockController");
        _requireCode(addrs.claimToken, "ClaimToken");
        _requireCode(addrs.mineCore, "MineCore");
        _requireCode(addrs.furnace, "Furnace");
        _requireCode(addrs.veClaimNFT, "VeClaimNFT");
        _requireCode(addrs.shareholderRoyalties, "ShareholderRoyalties");
        _requireCode(addrs.marketRouter, "MarketRouter");
        _requireCode(addrs.mineCoreProxyAdmin, "MineCoreProxyAdmin");
        _requireCode(addrs.furnaceProxyAdmin, "FurnaceProxyAdmin");
        _requireCode(addrs.marketRouterProxyAdmin, "MarketRouterProxyAdmin");
        _requireCode(addrs.shareholderRoyaltiesProxyAdmin, "ShareholderRoyaltiesProxyAdmin");
        _requireCode(addrs.furnaceEntryTokenRegistry, "FurnaceEntryTokenRegistry");
        _requireCode(addrs.mineCoreEntryTokenRegistry, "MineCoreEntryTokenRegistry");
        _requireCode(addrs.dexAdapter, "DexAdapter");
        _requireCode(addrs.lpStakingVault7D, "LpStakingVault7D");

        _validateBundle(addrs);
        _assertFinalityOwnership(addrs);
        _assertNotYetFrozen(addrs);

        (address[] memory targets, uint256[] memory values, bytes[] memory payloads) = _buildBatch(addrs);

        TimelockController timelock = TimelockController(payable(addrs.timelock));
        bytes32 salt = _envBytes32OrZero("TIMELOCK_SALT");
        bytes32 operationId = timelock.hashOperationBatch(targets, values, payloads, ZERO_PREDECESSOR, salt);
        _logOperation(operationId, "FreezeAndBurn.operationId");

        Action action = _parseAction();
        address contractCaller = _timelockCallerOrZero();

        if (contractCaller != address(0)) {
            require(
                !timelock.hasRole(DEFAULT_ADMIN_ROLE, contractCaller),
                "FreezeAndBurn: caller holds DEFAULT_ADMIN_ROLE - run FinalizeTimelockBootstrap first"
            );
            if (action == Action.Schedule) {
                _requireTimelockActionCaller(timelock, contractCaller, true);
                _simulateSchedule(timelock, contractCaller, targets, values, payloads, salt, operationId);
                _logTimelockActionSubmission(
                    "FreezeAndBurn.scheduleBatch",
                    contractCaller,
                    address(timelock),
                    abi.encodeCall(
                        TimelockController.scheduleBatch,
                        (targets, values, payloads, ZERO_PREDECESSOR, salt, timelock.getMinDelay())
                    )
                );
            } else {
                require(timelock.isOperationReady(operationId), "FreezeAndBurn: operation is not ready");
                _requireTimelockActionCaller(timelock, contractCaller, false);
                _simulateExecute(timelock, contractCaller, targets, values, payloads, salt, operationId);
                _logTimelockActionSubmission(
                    "FreezeAndBurn.executeBatch",
                    contractCaller,
                    address(timelock),
                    abi.encodeCall(TimelockController.executeBatch, (targets, values, payloads, ZERO_PREDECESSOR, salt))
                );
            }
            return;
        }

        BroadcastSigner memory signer = _broadcastSigner();
        address actor = signer.account;
        require(
            !timelock.hasRole(DEFAULT_ADMIN_ROLE, actor),
            "FreezeAndBurn: signer holds DEFAULT_ADMIN_ROLE - run FinalizeTimelockBootstrap first"
        );

        if (action == Action.Schedule) {
            _requireTimelockActionCaller(timelock, actor, true);
            _simulateSchedule(timelock, actor, targets, values, payloads, salt, operationId);

            _startBroadcast(signer);
            timelock.scheduleBatch(targets, values, payloads, ZERO_PREDECESSOR, salt, timelock.getMinDelay());
            vm.stopBroadcast();
            require(timelock.isOperationPending(operationId), "FreezeAndBurn: operation not pending");
        } else {
            require(timelock.isOperationReady(operationId), "FreezeAndBurn: operation is not ready");
            _requireTimelockActionCaller(timelock, actor, false);
            _simulateExecute(timelock, actor, targets, values, payloads, salt, operationId);

            _startBroadcast(signer);
            timelock.executeBatch(targets, values, payloads, ZERO_PREDECESSOR, salt);
            vm.stopBroadcast();
            require(timelock.isOperationDone(operationId), "FreezeAndBurn: operation not done");
            _assertFrozen(addrs);
            _assertProxyAdminsBurned(addrs);
        }
    }

    function _buildBatch(GovernanceAddrs memory addrs)
        internal
        pure
        returns (address[] memory targets, uint256[] memory values, bytes[] memory payloads)
    {
        targets = new address[](8);
        values = new uint256[](8);
        payloads = new bytes[](8);

        // ClaimToken is already frozen at wire time - not included in the batch.

        targets[0] = addrs.mineCore;
        payloads[0] = abi.encodeCall(MineCore.freezeConfig, ());

        targets[1] = addrs.furnace;
        payloads[1] = abi.encodeCall(Furnace.freezeConfig, ());

        targets[2] = addrs.veClaimNFT;
        payloads[2] = abi.encodeCall(VeClaimNFT.freezeConfig, ());

        targets[3] = addrs.shareholderRoyalties;
        payloads[3] = abi.encodeCall(ShareholderRoyalties.freezeConfig, ());

        targets[4] = addrs.mineCoreProxyAdmin;
        payloads[4] = abi.encodeWithSignature("renounceOwnership()");

        targets[5] = addrs.furnaceProxyAdmin;
        payloads[5] = abi.encodeWithSignature("renounceOwnership()");

        targets[6] = addrs.marketRouterProxyAdmin;
        payloads[6] = abi.encodeWithSignature("renounceOwnership()");

        targets[7] = addrs.shareholderRoyaltiesProxyAdmin;
        payloads[7] = abi.encodeWithSignature("renounceOwnership()");
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
        require(timelock.isOperationPending(operationId), "FreezeAndBurn: schedule simulation did not queue operation");
        vm.stopPrank();
        require(vm.revertTo(snap), "FreezeAndBurn: failed to revert schedule simulation snapshot");
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
        require(timelock.isOperationDone(operationId), "FreezeAndBurn: execute simulation did not complete");
        vm.stopPrank();
        require(vm.revertTo(snap), "FreezeAndBurn: failed to revert execute simulation snapshot");
    }

    function _assertFinalityOwnership(GovernanceAddrs memory addrs) internal view {
        address timelockAddr = addrs.timelock;
        TimelockController timelock = TimelockController(payable(timelockAddr));

        require(timelock.hasRole(DEFAULT_ADMIN_ROLE, timelockAddr), "FreezeAndBurn: timelock missing self-admin role");
        if (block.chainid != 31337 && block.chainid != 1337) {
            require(addrs.timelockBootstrapAdmin != address(0), "FreezeAndBurn: missing timelock bootstrap admin");
        }
        if (addrs.timelockBootstrapAdmin != address(0)) {
            require(
                !timelock.hasRole(DEFAULT_ADMIN_ROLE, addrs.timelockBootstrapAdmin),
                "FreezeAndBurn: bootstrap admin still has DEFAULT_ADMIN_ROLE"
            );
        }

        // ClaimToken ownership is renounced at wire time - owner must be address(0).
        require(ClaimToken(addrs.claimToken).owner() == address(0), "FreezeAndBurn: ClaimToken owner not renounced");
        require(MineCore(payable(addrs.mineCore)).owner() == timelockAddr, "FreezeAndBurn: MineCore owner != timelock");
        require(Furnace(payable(addrs.furnace)).owner() == timelockAddr, "FreezeAndBurn: Furnace owner != timelock");
        require(VeClaimNFT(addrs.veClaimNFT).owner() == timelockAddr, "FreezeAndBurn: VeClaimNFT owner != timelock");
        require(
            ShareholderRoyalties(payable(addrs.shareholderRoyalties)).owner() == timelockAddr,
            "FreezeAndBurn: ShareholderRoyalties owner != timelock"
        );

        require(
            ProxyAdmin(addrs.mineCoreProxyAdmin).owner() == timelockAddr,
            "FreezeAndBurn: MineCoreProxyAdmin owner != timelock"
        );
        require(
            ProxyAdmin(addrs.furnaceProxyAdmin).owner() == timelockAddr,
            "FreezeAndBurn: FurnaceProxyAdmin owner != timelock"
        );
        require(
            ProxyAdmin(addrs.marketRouterProxyAdmin).owner() == timelockAddr,
            "FreezeAndBurn: MarketRouterProxyAdmin owner != timelock"
        );
        require(
            ProxyAdmin(addrs.shareholderRoyaltiesProxyAdmin).owner() == timelockAddr,
            "FreezeAndBurn: ShareholderRoyaltiesProxyAdmin owner != timelock"
        );

        // Non-frozen but ownership-bearing contracts must also be timelock-owned before finality.
        require(
            IFreezeAndBurnOwnerCheck(addrs.furnaceEntryTokenRegistry).owner() == timelockAddr,
            "FreezeAndBurn: FurnaceEntryTokenRegistry owner != timelock"
        );
        require(
            IFreezeAndBurnOwnerCheck(addrs.mineCoreEntryTokenRegistry).owner() == timelockAddr,
            "FreezeAndBurn: MineCoreEntryTokenRegistry owner != timelock"
        );
        require(
            IFreezeAndBurnOwnerCheck(addrs.dexAdapter).owner() == timelockAddr,
            "FreezeAndBurn: DexAdapter owner != timelock"
        );
        require(
            IFreezeAndBurnOwnerCheck(addrs.lpStakingVault7D).owner() == timelockAddr,
            "FreezeAndBurn: LpStakingVault7D owner != timelock"
        );
        require(
            IFreezeAndBurnOwnerCheck(addrs.marketRouter).owner() == timelockAddr,
            "FreezeAndBurn: MarketRouter owner != timelock"
        );
    }

    function _assertNotYetFrozen(GovernanceAddrs memory addrs) internal view {
        // ClaimToken MUST already be frozen (freezes at wire time).
        require(
            ClaimToken(addrs.claimToken).configFrozen(),
            "FreezeAndBurn: ClaimToken not yet frozen (expected wire-time freeze)"
        );

        // The remaining four must NOT yet be frozen - the batch will freeze them.
        require(!MineCore(payable(addrs.mineCore)).configFrozen(), "FreezeAndBurn: MineCore already frozen");
        require(!Furnace(payable(addrs.furnace)).configFrozen(), "FreezeAndBurn: Furnace already frozen");
        require(!VeClaimNFT(addrs.veClaimNFT).configFrozen(), "FreezeAndBurn: VeClaimNFT already frozen");
        require(
            !ShareholderRoyalties(payable(addrs.shareholderRoyalties)).configFrozen(),
            "FreezeAndBurn: ShareholderRoyalties already frozen"
        );
    }

    function _assertFrozen(GovernanceAddrs memory addrs) internal view {
        require(ClaimToken(addrs.claimToken).configFrozen(), "FreezeAndBurn: ClaimToken not frozen");
        require(MineCore(payable(addrs.mineCore)).configFrozen(), "FreezeAndBurn: MineCore not frozen");
        require(Furnace(payable(addrs.furnace)).configFrozen(), "FreezeAndBurn: Furnace not frozen");
        require(VeClaimNFT(addrs.veClaimNFT).configFrozen(), "FreezeAndBurn: VeClaimNFT not frozen");
        require(
            ShareholderRoyalties(payable(addrs.shareholderRoyalties)).configFrozen(),
            "FreezeAndBurn: ShareholderRoyalties not frozen"
        );
    }

    function _assertProxyAdminsBurned(GovernanceAddrs memory addrs) internal view {
        require(
            ProxyAdmin(addrs.mineCoreProxyAdmin).owner() == address(0), "FreezeAndBurn: MineCoreProxyAdmin not burned"
        );
        require(
            ProxyAdmin(addrs.furnaceProxyAdmin).owner() == address(0), "FreezeAndBurn: FurnaceProxyAdmin not burned"
        );
        require(
            ProxyAdmin(addrs.marketRouterProxyAdmin).owner() == address(0),
            "FreezeAndBurn: MarketRouterProxyAdmin not burned"
        );
        require(
            ProxyAdmin(addrs.shareholderRoyaltiesProxyAdmin).owner() == address(0),
            "FreezeAndBurn: ShareholderRoyaltiesProxyAdmin not burned"
        );
    }

    function _validateBundle(GovernanceAddrs memory addrs) internal view {
        Furnace f = Furnace(payable(addrs.furnace));
        MineCore mc = MineCore(payable(addrs.mineCore));
        VeClaimNFT ve = VeClaimNFT(addrs.veClaimNFT);
        ShareholderRoyalties sr = ShareholderRoyalties(payable(addrs.shareholderRoyalties));

        require(
            ClaimToken(addrs.claimToken).mineCore() == addrs.mineCore, "FreezeAndBurn: ClaimToken.mineCore mismatch"
        );

        require(address(mc.claim()) == addrs.claimToken, "FreezeAndBurn: MineCore.claim mismatch");
        require(address(mc.ve()) == addrs.veClaimNFT, "FreezeAndBurn: MineCore.ve mismatch");
        require(address(mc.royalties()) == addrs.shareholderRoyalties, "FreezeAndBurn: MineCore.royalties mismatch");
        require(address(mc.furnace()) == addrs.furnace, "FreezeAndBurn: MineCore.furnace mismatch");

        require(address(f.claim()) == addrs.claimToken, "FreezeAndBurn: Furnace.claim mismatch");
        require(address(f.ve()) == addrs.veClaimNFT, "FreezeAndBurn: Furnace.ve mismatch");
        require(f.mineCore() == addrs.mineCore, "FreezeAndBurn: Furnace.mineCore mismatch");
        require(f.shareholderRoyalties() == addrs.shareholderRoyalties, "FreezeAndBurn: Furnace.royalties mismatch");
        require(f.mineMarket() == addrs.marketRouter, "FreezeAndBurn: Furnace.mineMarket mismatch");

        require(ve.claimToken() == addrs.claimToken, "FreezeAndBurn: VeClaimNFT.claimToken mismatch");
        require(ve.furnace() == addrs.furnace, "FreezeAndBurn: VeClaimNFT.furnace mismatch");
        require(ve.mineMarket() == addrs.marketRouter, "FreezeAndBurn: VeClaimNFT.mineMarket mismatch");

        require(address(sr.ve()) == addrs.veClaimNFT, "FreezeAndBurn: ShareholderRoyalties.ve mismatch");
        require(sr.mineCore() == addrs.mineCore, "FreezeAndBurn: ShareholderRoyalties.mineCore mismatch");
        require(address(sr.furnace()) == addrs.furnace, "FreezeAndBurn: ShareholderRoyalties.furnace mismatch");
        require(sr.mineMarket() == addrs.marketRouter, "FreezeAndBurn: ShareholderRoyalties.mineMarket mismatch");

        require(addrs.claimAllHelper != address(0), "FreezeAndBurn: missing ClaimAllHelper");
        ClaimAllHelper helper = ClaimAllHelper(addrs.claimAllHelper);
        require(address(helper.mineCore()) == addrs.mineCore, "FreezeAndBurn: ClaimAllHelper.mineCore mismatch");
        require(
            address(helper.royalties()) == addrs.shareholderRoyalties,
            "FreezeAndBurn: ClaimAllHelper.royalties mismatch"
        );
        require(mc.claimAllHelper() == addrs.claimAllHelper, "FreezeAndBurn: MineCore.claimAllHelper mismatch");
        require(
            sr.claimAllHelper() == addrs.claimAllHelper, "FreezeAndBurn: ShareholderRoyalties.claimAllHelper mismatch"
        );
    }

    function _parseAction() internal returns (Action action) {
        string memory raw = _envStringOr("TIMELOCK_ACTION", "schedule");
        bytes32 hash = keccak256(bytes(raw));
        if (hash == keccak256("schedule")) return Action.Schedule;
        if (hash == keccak256("execute")) return Action.Execute;
        revert("FreezeAndBurn: TIMELOCK_ACTION must be schedule or execute");
    }
}
