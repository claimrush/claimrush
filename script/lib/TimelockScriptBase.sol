// SPDX-License-Identifier: MIT
pragma solidity ^0.8.34;

import {console2} from "forge-std/Script.sol";
import {stdJson} from "forge-std/StdJson.sol";
import {TimelockController} from "lib/openzeppelin-contracts/contracts/governance/TimelockController.sol";
import {BroadcastSignerBase} from "./BroadcastSignerBase.sol";

abstract contract TimelockScriptBase is BroadcastSignerBase {
    using stdJson for string;

    struct GovernanceAddrs {
        address timelock;
        address timelockBootstrapAdmin;
        address claimToken;
        address veClaimNFT;
        address mineCore;
        address mineCoreProxyAdmin;
        address shareholderRoyalties;
        address shareholderRoyaltiesProxyAdmin;
        address furnace;
        address furnaceProxyAdmin;
        address marketRouter;
        address marketRouterProxyAdmin;
        address claimAllHelper;
        address furnaceEntryTokenRegistry;
        address mineCoreEntryTokenRegistry;
        address dexAdapter;
        address lpStakingVault7D;
        address launchController;
    }

    bytes32 internal constant ZERO_PREDECESSOR = bytes32(0);

    function _loadGovernanceAddrs() internal view returns (GovernanceAddrs memory a) {
        string memory json = _manifestJson();
        a.timelock = json.readAddress(".contracts.TimelockController.address");
        a.timelockBootstrapAdmin = _tryReadAddress(json, ".contracts.TimelockController.bootstrapAdmin");
        a.claimToken = json.readAddress(".contracts.ClaimToken.address");
        a.veClaimNFT = json.readAddress(".contracts.VeClaimNFT.address");
        a.mineCore = json.readAddress(".contracts.MineCore.address");
        a.mineCoreProxyAdmin = json.readAddress(".contracts.MineCore.proxyAdmin");
        a.shareholderRoyalties = json.readAddress(".contracts.ShareholderRoyalties.address");
        a.shareholderRoyaltiesProxyAdmin = json.readAddress(".contracts.ShareholderRoyalties.proxyAdmin");
        a.furnace = json.readAddress(".contracts.Furnace.address");
        a.furnaceProxyAdmin = json.readAddress(".contracts.Furnace.proxyAdmin");
        a.marketRouter = json.readAddress(".contracts.MarketRouter.address");
        a.marketRouterProxyAdmin = json.readAddress(".contracts.MarketRouter.proxyAdmin");
        a.claimAllHelper = json.readAddress(".contracts.ClaimAllHelper.address");
        a.furnaceEntryTokenRegistry = json.readAddress(".contracts.FurnaceEntryTokenRegistry.address");
        a.mineCoreEntryTokenRegistry = json.readAddress(".contracts.MineCoreEntryTokenRegistry.address");
        a.dexAdapter = json.readAddress(".contracts.DexAdapter.address");
        a.lpStakingVault7D = json.readAddress(".contracts.LpStakingVault7D.address");
        a.launchController = json.readAddress(".contracts.LaunchController.address");
    }

    function _manifestJson() internal view returns (string memory json) {
        try vm.envString("DEPLOYMENTS_MANIFEST_JSON") returns (string memory inlineJson) {
            if (bytes(inlineJson).length > 0) return _sanitizeInlineJson(inlineJson);
        } catch {}
        return vm.readFile(_manifestPath());
    }

    function _manifestPath() internal view returns (string memory) {
        if (block.chainid == 8453) return "deployments/base_mainnet.json";
        if (block.chainid == 84532) return "deployments/base_sepolia.json";
        if (block.chainid == 31337 || block.chainid == 1337) return "deployments/local.json";
        revert("TimelockScriptBase: unsupported chain");
    }

    function _broadcastSigner() internal returns (BroadcastSigner memory signer) {
        signer = _resolveBroadcastSigner();
        require(signer.account != address(0), "TimelockScriptBase: missing broadcast signer");
    }

    function _envStringOr(string memory key, string memory fallbackValue) internal returns (string memory) {
        try vm.envString(key) returns (string memory v) {
            return v;
        } catch {
            return fallbackValue;
        }
    }

    function _envBytesOrEmpty(string memory key) internal returns (bytes memory) {
        try vm.envBytes(key) returns (bytes memory v) {
            return v;
        } catch {
            return bytes("");
        }
    }

    function _envBytes32OrZero(string memory key) internal returns (bytes32) {
        try vm.envBytes32(key) returns (bytes32 v) {
            return v;
        } catch {
            console2.log("TimelockScriptBase: %s not set, defaulting to bytes32(0)", key);
            return bytes32(0);
        }
    }

    function _envAddressOrZero(string memory key) internal returns (address) {
        try vm.envAddress(key) returns (address v) {
            return v;
        } catch {
            return address(0);
        }
    }

    function _requireCode(address target, string memory label) internal view {
        require(target != address(0), string.concat("TimelockScriptBase: missing ", label));
        require(target.code.length > 0, string.concat("TimelockScriptBase: no code at ", label));
    }

    function _timelockCallerOrZero() internal returns (address caller) {
        caller = _envAddressOrZero("TIMELOCK_CALLER");
        if (caller == address(0)) caller = _envAddressOrZero("ADMIN_SAFE");
        if (caller != address(0)) {
            require(caller.code.length > 0, "TimelockScriptBase: timelock caller has no code");
        }
    }

    function _requireTimelockActionCaller(TimelockController timelock, address caller, bool needsProposer)
        internal
        view
    {
        if (needsProposer) {
            require(
                timelock.hasRole(timelock.PROPOSER_ROLE(), caller), "TimelockScriptBase: caller lacks PROPOSER_ROLE"
            );
            return;
        }

        bool hasDirectRole = timelock.hasRole(timelock.EXECUTOR_ROLE(), caller);
        bool hasOpenRole = timelock.hasRole(timelock.EXECUTOR_ROLE(), address(0));
        if (hasOpenRole && !hasDirectRole) {
            console2.log("TimelockScriptBase: WARNING: caller %s accepted via open EXECUTOR_ROLE (address(0))", caller);
        }
        require(hasDirectRole || hasOpenRole, "TimelockScriptBase: caller lacks EXECUTOR_ROLE");
    }

    function _logTimelockActionSubmission(
        string memory actionLabel,
        address caller,
        address timelockAddr,
        bytes memory callData
    ) internal pure {
        console2.log(actionLabel);
        console2.log("submit this call from");
        console2.log(caller);
        console2.log("to");
        console2.log(timelockAddr);
        console2.log("calldata");
        console2.logBytes(callData);
    }

    function _logOperation(bytes32 operationId, string memory actionLabel) internal pure {
        console2.log(actionLabel);
        console2.logBytes32(operationId);
    }

    function _sanitizeInlineJson(string memory raw) internal pure returns (string memory) {
        // ASCII byte values for the JSON object delimiters; using literal byte
        // constants avoids the `bytes1("...")` truncating-cast lint while
        // matching exactly one byte in the inline-JSON wrapper.
        bytes1 openBrace = 0x7B; // '{'
        bytes1 closeBrace = 0x7D; // '}'
        bytes memory b = bytes(raw);
        if (b.length == 0) return raw;
        uint256 start = 0;
        while (start < b.length && b[start] != openBrace) start++;
        uint256 end = b.length;
        while (end > start && b[end - 1] != closeBrace) end--;
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
}
