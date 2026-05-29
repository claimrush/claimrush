// SPDX-License-Identifier: MIT
pragma solidity ^0.8.34;

import {console2} from "forge-std/Script.sol";
import {stdJson} from "forge-std/StdJson.sol";
import {BroadcastSignerBase} from "./lib/BroadcastSignerBase.sol";

interface IOwnable2StepLike {
    function owner() external view returns (address);
    function pendingOwner() external view returns (address);
    function transferOwnership(address newOwner) external;
    function acceptOwnership() external;
}

interface IOwnableLike {
    function owner() external view returns (address);
    function transferOwnership(address newOwner) external;
}

interface IFinalizeOwnershipLaunchControllerLike {
    function genesisFinalized() external view returns (bool);
}

interface IFinalizeOwnershipGuardianLike {
    function guardian() external view returns (address);
}

interface IFinalizeOwnershipFreezableLike {
    function configFrozen() external view returns (bool);
}

interface IFinalizeOwnershipTimelockLike {
    function hasRole(bytes32 role, address account) external view returns (bool);
}

/// @notice Finalize ownership for all ownership-bearing contracts in the deployment manifest.
/// @dev On Base mainnet / Base Sepolia, initiate mode fails closed unless genesis is finalized,
///      MineCore.guardian has rotated away from LaunchController, and ClaimToken has already
///      been frozen plus owner-renounced at wire time. Set ALLOW_UNSAFE_PRE_FINAL_HANDOFF=true
///      only for deliberate break-glass/manual flows.
///      The script simulates the selected ownership action (initiate or accept) across all targets before broadcasting so a stale manifest
///      or non-conforming target cannot leave ownership half-transferred across the stack. Runtime proxy
///      admins use plain Ownable, are resolved live from the EIP-1967 admin slot when present, and are
///      cross-checked against manifest/env metadata to catch drift before governance handoff.
///      Usage:
///      1) Initiate from current owner:
///         OWNERSHIP_ACTION=initiate NEW_OWNER=0x... forge script script/FinalizeOwnership.s.sol:FinalizeOwnership
///      2) Accept from pending owner EOA:
///         OWNERSHIP_ACTION=accept forge script script/FinalizeOwnership.s.sol:FinalizeOwnership
///      NOTE: if NEW_OWNER is a multisig or timelock contract, acceptance must be executed by that
///      contract itself (for example via a Safe transaction), not by this script.
///      Signer selection:
///      - local chains: LOCAL_PRIVATE_KEY (preferred), fallback PRIVATE_KEY
///      - Base Sepolia: PRIVATE_KEY
///      - Base mainnet: LEDGER_ADDRESS / SIGNER_ADDRESS with `forge script ... --ledger --sender <address>`
///                      or PRIVATE_KEY as a fallback if explicitly desired
///
///
///   Front-running analysis: transferOwnership sets pendingOwner. An attacker
///   cannot call acceptOwnership because they are not the pendingOwner. The
///   two-step pattern prevents front-running: only pendingOwner can call acceptOwnership.
///
///   The script iterates over the manifest ownership targets but does NOT include
///   GenesisLPVault24M, DelegationHub, MaintenanceHub, or LaunchController.
///   Those contracts do not expose a transferable owner surface and are excluded.
///
///   ALLOW_UNSAFE_PRE_FINAL_HANDOFF is gated behind an explicit env flag;
///   intended for break-glass/manual flows only.
contract FinalizeOwnership is BroadcastSignerBase {
    using stdJson for string;

    bytes32 internal constant _ADMIN_SLOT = 0xb53127684a568b3173ae13b9f8a6016e243e63b6e8ee1178d6a717850b5d6103;

    struct Addrs {
        address timelock;
        address timelockBootstrapAdmin;
        address claimToken;
        address ve;
        address mineCore;
        address mineCoreProxyAdmin;
        address royalties;
        address royaltiesProxyAdmin;
        address furnace;
        address furnaceProxyAdmin;
        address marketRouter;
        address marketRouterProxyAdmin;
        address furnaceEntryTokenRegistry;
        address mineCoreEntryTokenRegistry;
        address dexAdapter;
        address lpStakingVault7D;
        address launchController;
    }

    function run() external {
        string memory action = _envStringOr("OWNERSHIP_ACTION", "initiate");
        bool doAccept;
        if (_eq(action, "accept")) {
            doAccept = true;
        } else if (_eq(action, "initiate")) {
            doAccept = false;
        } else {
            revert("FinalizeOwnership: OWNERSHIP_ACTION must be initiate or accept");
        }

        bool addrsFromEnv = _envBoolOr("OWNERSHIP_ADDRS_FROM_ENV", false);
        Addrs memory a = _loadAddrs(addrsFromEnv);
        address[] memory targets = _targets(a);
        if (addrsFromEnv) {
            require(_hasAnyTarget(targets), "FinalizeOwnership: OWNERSHIP_ADDRS_FROM_ENV requires at least one target");
        } else {
            _requireManifestTargetsComplete(a, targets);
        }

        BroadcastSigner memory signer = _resolveBroadcastSigner();
        address actor = signer.account;
        address newOwner = _envAddressOrZero("NEW_OWNER");

        if (!doAccept) {
            require(newOwner != address(0), "FinalizeOwnership: NEW_OWNER required");
            require(newOwner != actor, "FinalizeOwnership: NEW_OWNER must differ from current actor");
            _assertSafeInitiateState(a, newOwner, _envBoolOr("ALLOW_UNSAFE_PRE_FINAL_HANDOFF", false), addrsFromEnv);
        }

        console2.log("FinalizeOwnership: simulating ownership action across all targets before broadcast...");
        _preflightOwnershipSequence(targets, actor, newOwner, doAccept, addrsFromEnv);
        console2.log("FinalizeOwnership: preflight simulation passed.");

        _startBroadcast(signer);
        _executeOwnershipSequence(targets, actor, newOwner, doAccept, true, addrsFromEnv);
        vm.stopBroadcast();
    }

    function _preflightOwnershipSequence(
        address[] memory targets,
        address actor,
        address newOwner,
        bool doAccept,
        bool allowPartialTargets
    ) internal {
        uint256 snap = vm.snapshot();
        vm.startPrank(actor);
        _executeOwnershipSequence(targets, actor, newOwner, doAccept, false, allowPartialTargets);
        vm.stopPrank();
        require(vm.revertTo(snap), "FinalizeOwnership: failed to revert preflight snapshot");
    }

    function _executeOwnershipSequence(
        address[] memory targets,
        address actor,
        address newOwner,
        bool doAccept,
        bool logActions,
        bool allowPartialTargets
    ) internal {
        for (uint256 i = 0; i < targets.length; i++) {
            address t = targets[i];
            if (t == address(0)) {
                if (logActions) console2.log("skip omitted slot", i);
                continue;
            }
            if (t.code.length == 0) {
                require(allowPartialTargets, "FinalizeOwnership: target has no code");
                if (logActions) console2.log("skip no code", t);
                continue;
            }
            IOwnableLike ownable = IOwnableLike(t);
            bool isTwoStep = _supportsPendingOwner(t);
            address owner0 = ownable.owner();
            address pendingOwner0 = isTwoStep ? IOwnable2StepLike(t).pendingOwner() : address(0);

            if (doAccept) {
                if (isTwoStep) {
                    IOwnable2StepLike c = IOwnable2StepLike(t);
                    if (pendingOwner0 == actor) {
                        c.acceptOwnership();
                        require(c.owner() == actor, "FinalizeOwnership: acceptOwnership did not set owner");
                        require(c.pendingOwner() == address(0), "FinalizeOwnership: acceptOwnership left pending owner");
                        if (logActions) console2.log("accepted", t);
                    } else if (!allowPartialTargets) {
                        require(
                            owner0 == actor && pendingOwner0 == address(0),
                            "FinalizeOwnership: target not pending to actor"
                        );
                        if (logActions) console2.log("already accepted", t);
                    } else if (logActions) {
                        console2.log("skip accept", t);
                    }
                } else if (!allowPartialTargets) {
                    require(owner0 == actor, "FinalizeOwnership: target not owned by actor");
                    if (logActions) console2.log("already accepted", t);
                } else if (logActions) {
                    console2.log("skip accept", t);
                }
            } else {
                if (isTwoStep) {
                    IOwnable2StepLike c = IOwnable2StepLike(t);
                    if (owner0 == actor) {
                        if (pendingOwner0 == newOwner) {
                            if (logActions) console2.log("already initiated", t);
                        } else {
                            require(pendingOwner0 == address(0), "FinalizeOwnership: target pendingOwner mismatch");
                            c.transferOwnership(newOwner);
                            require(
                                c.pendingOwner() == newOwner,
                                "FinalizeOwnership: transferOwnership did not set pending owner"
                            );
                            if (logActions) console2.log("initiated", t);
                        }
                    } else if (!allowPartialTargets) {
                        require(
                            owner0 == newOwner && pendingOwner0 == address(0),
                            "FinalizeOwnership: target owner mismatch"
                        );
                        if (logActions) console2.log("already handed off", t);
                    } else if (logActions) {
                        console2.log("skip initiate", t);
                    }
                } else if (owner0 == actor) {
                    ownable.transferOwnership(newOwner);
                    require(ownable.owner() == newOwner, "FinalizeOwnership: transferOwnership did not set owner");
                    if (logActions) console2.log("initiated", t);
                } else if (!allowPartialTargets) {
                    require(owner0 == newOwner, "FinalizeOwnership: target owner mismatch");
                    if (logActions) console2.log("already handed off", t);
                } else if (logActions) {
                    console2.log("skip initiate", t);
                }
            }
        }
    }

    function _supportsPendingOwner(address target) internal view returns (bool) {
        (bool ok, bytes memory data) =
            target.staticcall(abi.encodeWithSelector(IOwnable2StepLike.pendingOwner.selector));
        return ok && data.length == 32;
    }

    /// @dev Returns the ownership-bearing contracts whose ownership must be transferred.
    ///      Intentionally excluded (no transferable owner surface):
    ///        - ClaimToken once `Wire.s.sol` has already frozen it and renounced ownership.
    ///        - GenesisLPVault24M: no owner; withdraw recipient is immutable.
    ///        - DelegationHub: no owner; session management is purely user-driven.
    ///        - MaintenanceHub: no owner; poke() is permissionless.
    ///        - LaunchController: no owner; guardian-only finalizeGenesis() is one-shot.
    ///      Runtime proxy admins are resolved live from the proxy admin slot when present and
    ///      cross-checked against manifest/env metadata if supplied.
    ///
    ///      ORDERING: Ownable2Step contracts are listed first because transferOwnership only
    ///      sets pendingOwner (recoverable by re-running initiate). Plain-Ownable runtime
    ///      ProxyAdmins are listed last because their transferOwnership is immediate and
    ///      irreversible. If a partial broadcast failure occurs mid-sequence, earlier
    ///      Ownable2Step targets can be re-initiated while no irreversible ProxyAdmin
    ///      transfer has landed yet.
    function _targets(Addrs memory a) internal view returns (address[] memory out) {
        out = new address[](14);
        // --- Ownable2Step (recoverable: sets pendingOwner only) ---
        if (_ownerOrZero(a.claimToken) != address(0)) {
            out[0] = a.claimToken;
        }
        out[1] = a.ve;
        out[2] = a.mineCore;
        out[3] = a.royalties;
        out[4] = a.furnace;
        out[5] = a.marketRouter;
        out[6] = a.furnaceEntryTokenRegistry;
        out[7] = a.mineCoreEntryTokenRegistry;
        out[8] = a.dexAdapter;
        out[9] = a.lpStakingVault7D;
        // --- Plain Ownable ProxyAdmins (immediate transfer, irreversible) ---
        out[10] = a.mineCoreProxyAdmin;
        out[11] = a.royaltiesProxyAdmin;
        out[12] = a.furnaceProxyAdmin;
        out[13] = a.marketRouterProxyAdmin;
    }

    function _ownerOrZero(address target) internal view returns (address owner_) {
        if (target == address(0) || target.code.length == 0) return address(0);
        (bool ok, bytes memory data) = target.staticcall(abi.encodeWithSelector(IOwnableLike.owner.selector));
        if (ok && data.length == 32) {
            owner_ = abi.decode(data, (address));
        }
    }

    function _hasAnyTarget(address[] memory targets) internal pure returns (bool) {
        for (uint256 i = 0; i < targets.length; i++) {
            if (targets[i] != address(0)) return true;
        }
        return false;
    }

    function _readAddrs(string memory json) internal view returns (Addrs memory a) {
        a.timelock = _tryReadAddress(json, ".contracts.TimelockController.address");
        a.timelockBootstrapAdmin = _tryReadAddress(json, ".contracts.TimelockController.bootstrapAdmin");
        a.claimToken = json.readAddress(".contracts.ClaimToken.address");
        a.ve = json.readAddress(".contracts.VeClaimNFT.address");
        a.mineCore = json.readAddress(".contracts.MineCore.address");
        a.mineCoreProxyAdmin = _tryReadAddress(json, ".contracts.MineCore.proxyAdmin");
        a.royalties = json.readAddress(".contracts.ShareholderRoyalties.address");
        a.royaltiesProxyAdmin = _tryReadAddress(json, ".contracts.ShareholderRoyalties.proxyAdmin");
        a.furnace = json.readAddress(".contracts.Furnace.address");
        a.furnaceProxyAdmin = _tryReadAddress(json, ".contracts.Furnace.proxyAdmin");
        a.marketRouter = json.readAddress(".contracts.MarketRouter.address");
        a.marketRouterProxyAdmin = _tryReadAddress(json, ".contracts.MarketRouter.proxyAdmin");
        a.furnaceEntryTokenRegistry = json.readAddress(".contracts.FurnaceEntryTokenRegistry.address");
        a.mineCoreEntryTokenRegistry = json.readAddress(".contracts.MineCoreEntryTokenRegistry.address");
        a.dexAdapter = json.readAddress(".contracts.DexAdapter.address");
        a.lpStakingVault7D = json.readAddress(".contracts.LpStakingVault7D.address");
        a.launchController = json.readAddress(".contracts.LaunchController.address");
    }

    function _loadAddrs(bool addrsFromEnv) internal returns (Addrs memory a) {
        if (addrsFromEnv) {
            a.timelock = _envAddressOrZero("OWNERSHIP_TIMELOCK");
            a.timelockBootstrapAdmin = _envAddressOrZero("OWNERSHIP_TIMELOCK_BOOTSTRAP_ADMIN");
            a.claimToken = _envAddressOrZero("OWNERSHIP_CLAIM_TOKEN");
            a.ve = _envAddressOrZero("OWNERSHIP_VE");
            a.mineCore = _envAddressOrZero("OWNERSHIP_MINE_CORE");
            a.mineCoreProxyAdmin = _envAddressOrZero("OWNERSHIP_MINE_CORE_PROXY_ADMIN");
            a.royalties = _envAddressOrZero("OWNERSHIP_ROYALTIES");
            a.royaltiesProxyAdmin = _envAddressOrZero("OWNERSHIP_ROYALTIES_PROXY_ADMIN");
            a.furnace = _envAddressOrZero("OWNERSHIP_FURNACE");
            a.furnaceProxyAdmin = _envAddressOrZero("OWNERSHIP_FURNACE_PROXY_ADMIN");
            a.marketRouter = _envAddressOrZero("OWNERSHIP_MARKET_ROUTER");
            a.marketRouterProxyAdmin = _envAddressOrZero("OWNERSHIP_MARKET_ROUTER_PROXY_ADMIN");
            a.furnaceEntryTokenRegistry = _envAddressOrZero("OWNERSHIP_FURNACE_ENTRY_TOKEN_REGISTRY");
            a.mineCoreEntryTokenRegistry = _envAddressOrZero("OWNERSHIP_MINECORE_ENTRY_TOKEN_REGISTRY");
            a.dexAdapter = _envAddressOrZero("OWNERSHIP_DEX_ADAPTER");
            a.lpStakingVault7D = _envAddressOrZero("OWNERSHIP_LP_STAKING_VAULT");
            a.launchController = _envAddressOrZero("OWNERSHIP_LAUNCH_CONTROLLER");
            return _resolveRuntimeProxyAdmins(a);
        }
        string memory json = _manifestJson();
        return _resolveRuntimeProxyAdmins(_readAddrs(json));
    }

    function _manifestPath() internal view returns (string memory) {
        if (block.chainid == 8453) return "deployments/base_mainnet.json";
        if (block.chainid == 84532) return "deployments/base_sepolia.json";
        if (block.chainid == 31337 || block.chainid == 1337) return "deployments/local.json";
        revert("FinalizeOwnership: unsupported chain");
    }

    function _manifestJson() internal view returns (string memory json) {
        try vm.envString("DEPLOYMENTS_MANIFEST_JSON") returns (string memory inlineJson) {
            if (bytes(inlineJson).length > 0) return _sanitizeInlineJson(inlineJson);
        } catch {}
        return vm.readFile(_manifestPath());
    }

    function _sanitizeInlineJson(string memory raw) internal pure returns (string memory) {
        bytes memory b = bytes(raw);
        if (b.length == 0) return raw;
        uint256 start = 0;
        // forge-lint: disable-next-line(unsafe-typecast)
        while (start < b.length && b[start] != bytes1("{")) start++;
        uint256 end = b.length;
        // forge-lint: disable-next-line(unsafe-typecast)
        while (end > start && b[end - 1] != bytes1("}")) end--;
        if (start >= end) return raw;
        if (start == 0 && end == b.length) return raw;
        bytes memory out = new bytes(end - start);
        for (uint256 i = 0; i < out.length; i++) {
            out[i] = b[start + i];
        }
        return string(out);
    }

    function _tryReadAddress(string memory json, string memory path) internal view returns (address out) {
        try vm.parseJsonAddress(json, path) returns (address v) {
            out = v;
        } catch {
            out = address(0);
        }
    }

    function _envAddressOrZero(string memory key) internal returns (address out) {
        try vm.envAddress(key) returns (address v) {
            out = v;
        } catch {
            out = address(0);
        }
    }

    function _envStringOr(string memory key, string memory fallbackValue) internal returns (string memory out) {
        try vm.envString(key) returns (string memory v) {
            out = v;
        } catch {
            out = fallbackValue;
        }
    }

    function _envBoolOr(string memory key, bool fallbackValue) internal returns (bool out) {
        try vm.envBool(key) returns (bool v) {
            out = v;
        } catch {
            out = fallbackValue;
        }
    }

    function _assertSafeInitiateState(
        Addrs memory a,
        address newOwner,
        bool allowUnsafePreFinalHandoff,
        bool addrsFromEnv
    ) internal view {
        if (allowUnsafePreFinalHandoff) return;
        if (block.chainid != 8453 && block.chainid != 84532) return;

        bool requireCanonicalTimelock = !addrsFromEnv || a.timelock != address(0);
        if (requireCanonicalTimelock) {
            _requireTargetDeployed(a.timelock, "TimelockController");
            require(newOwner == a.timelock, "FinalizeOwnership: NEW_OWNER must equal TimelockController");
            require(
                a.timelockBootstrapAdmin != address(0), "FinalizeOwnership: missing TimelockController.bootstrapAdmin"
            );
            require(
                !IFinalizeOwnershipTimelockLike(a.timelock).hasRole(bytes32(0), a.timelockBootstrapAdmin),
                "FinalizeOwnership: timelock bootstrap admin still active"
            );
        }

        require(
            a.launchController != address(0) && a.launchController.code.length > 0,
            "FinalizeOwnership: missing LaunchController"
        );
        require(
            IFinalizeOwnershipLaunchControllerLike(a.launchController).genesisFinalized(),
            "FinalizeOwnership: genesis not finalized"
        );

        _requireFrozen(a.claimToken, "ClaimToken");
        require(IOwnableLike(a.claimToken).owner() == address(0), "FinalizeOwnership: ClaimToken owner not renounced");
        require(
            IFinalizeOwnershipGuardianLike(a.mineCore).guardian() != a.launchController,
            "FinalizeOwnership: MineCore guardian still LaunchController"
        );
    }

    function _requireManifestTargetsComplete(Addrs memory a, address[] memory targets) internal view {
        bool strictRuntimeProxyAdmins = block.chainid != 31337 && block.chainid != 1337;
        _requireTargetDeployed(a.claimToken, "ClaimToken");
        _requireTargetDeployed(a.ve, "VeClaimNFT");
        _requireTargetDeployed(a.mineCore, "MineCore");
        if (strictRuntimeProxyAdmins) {
            _requireTargetDeployed(a.mineCoreProxyAdmin, "MineCoreProxyAdmin");
        } else {
            _requireOptionalTargetDeployed(a.mineCoreProxyAdmin, "MineCoreProxyAdmin");
        }
        _requireTargetDeployed(a.royalties, "ShareholderRoyalties");
        if (strictRuntimeProxyAdmins) {
            _requireTargetDeployed(a.royaltiesProxyAdmin, "ShareholderRoyaltiesProxyAdmin");
        } else {
            _requireOptionalTargetDeployed(a.royaltiesProxyAdmin, "ShareholderRoyaltiesProxyAdmin");
        }
        _requireTargetDeployed(a.furnace, "Furnace");
        if (strictRuntimeProxyAdmins) {
            _requireTargetDeployed(a.furnaceProxyAdmin, "FurnaceProxyAdmin");
        } else {
            _requireOptionalTargetDeployed(a.furnaceProxyAdmin, "FurnaceProxyAdmin");
        }
        _requireTargetDeployed(a.marketRouter, "MarketRouter");
        if (strictRuntimeProxyAdmins) {
            _requireTargetDeployed(a.marketRouterProxyAdmin, "MarketRouterProxyAdmin");
        } else {
            _requireOptionalTargetDeployed(a.marketRouterProxyAdmin, "MarketRouterProxyAdmin");
        }
        _requireTargetDeployed(a.furnaceEntryTokenRegistry, "FurnaceEntryTokenRegistry");
        _requireTargetDeployed(a.mineCoreEntryTokenRegistry, "MineCoreEntryTokenRegistry");
        _requireTargetDeployed(a.dexAdapter, "DexAdapter");
        _requireTargetDeployed(a.lpStakingVault7D, "LpStakingVault7D");
        _requireUniqueTargets(targets);
    }

    function _resolveRuntimeProxyAdmins(Addrs memory a) internal view returns (Addrs memory) {
        a.mineCoreProxyAdmin = _resolveProxyAdmin(a.mineCore, a.mineCoreProxyAdmin, "MineCore");
        a.royaltiesProxyAdmin = _resolveProxyAdmin(a.royalties, a.royaltiesProxyAdmin, "ShareholderRoyalties");
        a.furnaceProxyAdmin = _resolveProxyAdmin(a.furnace, a.furnaceProxyAdmin, "Furnace");
        a.marketRouterProxyAdmin = _resolveProxyAdmin(a.marketRouter, a.marketRouterProxyAdmin, "MarketRouter");
        return a;
    }

    function _resolveProxyAdmin(address proxy, address configuredProxyAdmin, string memory label)
        internal
        view
        returns (address resolvedProxyAdmin)
    {
        if (proxy == address(0) || proxy.code.length == 0) return configuredProxyAdmin;

        resolvedProxyAdmin = _readAddressSlot(proxy, _ADMIN_SLOT);
        if (resolvedProxyAdmin == address(0)) {
            return configuredProxyAdmin;
        }

        require(
            resolvedProxyAdmin.code.length > 0, string.concat("FinalizeOwnership: proxy admin has no code for ", label)
        );
        require(
            _supportsOwnerGetter(resolvedProxyAdmin),
            string.concat("FinalizeOwnership: proxy admin missing owner() for ", label)
        );

        if (configuredProxyAdmin != address(0)) {
            require(
                configuredProxyAdmin == resolvedProxyAdmin,
                string.concat("FinalizeOwnership: proxy admin mismatch for ", label)
            );
        }
    }

    function _requireTargetDeployed(address target, string memory label) internal view {
        require(target != address(0), string.concat("FinalizeOwnership: missing ", label));
        require(target.code.length > 0, string.concat("FinalizeOwnership: no code at ", label));
    }

    function _requireOptionalTargetDeployed(address target, string memory label) internal view {
        if (target == address(0)) return;
        require(target.code.length > 0, string.concat("FinalizeOwnership: no code at ", label));
    }

    function _requireUniqueTargets(address[] memory targets) internal pure {
        for (uint256 i = 0; i < targets.length; i++) {
            if (targets[i] == address(0)) continue;
            for (uint256 j = i + 1; j < targets.length; j++) {
                require(targets[i] != targets[j], "FinalizeOwnership: duplicate ownership target");
            }
        }
    }

    function _requireFrozen(address target, string memory label) internal view {
        require(target != address(0), string.concat("FinalizeOwnership: missing ", label));
        require(target.code.length > 0, string.concat("FinalizeOwnership: no code at ", label));
        require(
            IFinalizeOwnershipFreezableLike(target).configFrozen(),
            string.concat("FinalizeOwnership: ", label, " not frozen")
        );
    }

    function _eq(string memory a, string memory b) internal pure returns (bool) {
        return keccak256(bytes(a)) == keccak256(bytes(b));
    }

    function _supportsOwnerGetter(address target) internal view returns (bool) {
        (bool ok, bytes memory data) = target.staticcall(abi.encodeWithSelector(IOwnableLike.owner.selector));
        return ok && data.length == 32;
    }

    function _readAddressSlot(address target, bytes32 slot) internal view returns (address out) {
        out = address(uint160(uint256(vm.load(target, slot))));
    }

    function _envUintOr(string memory key, uint256 fallbackValue) internal returns (uint256 out) {
        try vm.envUint(key) returns (uint256 v) {
            out = v;
        } catch {
            out = fallbackValue;
        }
    }
}
