// SPDX-License-Identifier: MIT
pragma solidity ^0.8.34;

import {console2} from "forge-std/Script.sol";
import {BroadcastSignerBase} from "./lib/BroadcastSignerBase.sol";

import {MaintenanceHub} from "../src/MaintenanceHub.sol";

/// @notice Deploy MaintenanceHub AFTER wiring (Wire.s.sol) has completed.
/// @dev The MaintenanceHub constructor validates cross-contract references
///      (e.g. furnace.shareholderRoyalties() == royalties), which only hold
///      after Wire.s.sol has wired the core contracts together.
///      Canonical constructor pins are resolved from DEPLOYMENTS_MANIFEST_JSON
///      or deployments/<network>.json so manual env overrides cannot silently
///      deploy a split-brain helper against stale roots.
///      The script simulates the full constructor sequence before broadcasting
///      so a MaintenanceHub WiringMismatch revert fails closed before any live tx.
contract DeployMaintenanceHub is BroadcastSignerBase {
    function run() external {
        require(
            block.chainid == 31337 || block.chainid == 1337 || block.chainid == 8453 || block.chainid == 84532,
            "DeployMaintenanceHub: unsupported chainId"
        );

        BroadcastSigner memory signer = _resolveBroadcastSigner();
        bool isLocal = _isLocalChain();

        string memory json = _manifestJson();
        address market = vm.parseJsonAddress(json, ".contracts.MarketRouter.address");
        address furnace = vm.parseJsonAddress(json, ".contracts.Furnace.address");
        address ve = vm.parseJsonAddress(json, ".contracts.VeClaimNFT.address");
        address royalties = vm.parseJsonAddress(json, ".contracts.ShareholderRoyalties.address");
        address weth = vm.parseJsonAddress(json, ".aerodrome.wrappedNative.address");
        address rescueRecipient_ = _envAddressOr("RESCUE_RECIPIENT", signer.account);

        require(market != address(0), "DeployMaintenanceHub: missing MarketRouter in manifest");
        require(furnace != address(0), "DeployMaintenanceHub: missing Furnace in manifest");
        require(ve != address(0), "DeployMaintenanceHub: missing VeClaimNFT in manifest");
        require(royalties != address(0), "DeployMaintenanceHub: missing ShareholderRoyalties in manifest");
        require(weth != address(0), "DeployMaintenanceHub: missing wrappedNative in manifest");
        require(rescueRecipient_ != address(0), "DeployMaintenanceHub: missing rescueRecipient");

        _requireContract(market, "MARKET_ROUTER");
        _requireContract(furnace, "FURNACE");
        _requireContract(ve, "VECLAIM_NFT");
        _requireContract(royalties, "SHAREHOLDER_ROYALTIES");
        _requireContract(weth, "WETH");

        _requireEnvMatchesManifest(isLocal, "LOCAL_MARKET_ROUTER", "MARKET_ROUTER", market, "MARKET_ROUTER");
        _requireEnvMatchesManifest(isLocal, "LOCAL_FURNACE", "FURNACE", furnace, "FURNACE");
        _requireEnvMatchesManifest(isLocal, "LOCAL_VECLAIM_NFT", "VECLAIM_NFT", ve, "VECLAIM_NFT");
        _requireEnvMatchesManifest(
            isLocal, "LOCAL_SHAREHOLDER_ROYALTIES", "SHAREHOLDER_ROYALTIES", royalties, "SHAREHOLDER_ROYALTIES"
        );
        _requireEnvMatchesManifest(isLocal, "LOCAL_WETH", "WETH", weth, "WETH");

        console2.log("DeployMaintenanceHub: simulating full deployment before broadcast...");
        _preflightDeploySequence(market, furnace, ve, royalties, weth, rescueRecipient_);
        console2.log("DeployMaintenanceHub: preflight simulation passed.");

        vm.stopPrank();
        _startBroadcast(signer);

        MaintenanceHub maintenanceHub = new MaintenanceHub(market, furnace, ve, royalties, weth, rescueRecipient_);

        vm.stopBroadcast();

        maintenanceHub;
    }

    function _preflightDeploySequence(
        address market,
        address furnace,
        address ve,
        address royalties,
        address weth,
        address rescueRecipient_
    ) internal {
        uint256 snap = vm.snapshot();
        new MaintenanceHub(market, furnace, ve, royalties, weth, rescueRecipient_);
        require(vm.revertTo(snap), "DeployMaintenanceHub: failed to revert preflight snapshot");
    }

    function _manifestPath() internal view returns (string memory) {
        if (block.chainid == 31337 || block.chainid == 1337) return "deployments/local.json";
        if (block.chainid == 8453) return "deployments/base_mainnet.json";
        return "deployments/base_sepolia.json";
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

    function _envAddressOr(string memory key, address fallbackValue) internal returns (address out) {
        try vm.envAddress(key) returns (address v) {
            out = v;
        } catch {
            out = fallbackValue;
        }
    }

    function _envAddressForChain(bool isLocal, string memory localKey, string memory prodKey)
        internal
        returns (address out)
    {
        if (isLocal) {
            out = _envAddressOr(localKey, _envAddressOr(prodKey, address(0)));
        } else {
            out = _envAddressOr(prodKey, address(0));
        }
    }

    function _requireEnvMatchesManifest(
        bool isLocal,
        string memory localKey,
        string memory prodKey,
        address expected,
        string memory label
    ) internal {
        address supplied = _envAddressForChain(isLocal, localKey, prodKey);
        require(
            supplied == address(0) || supplied == expected,
            string.concat("DeployMaintenanceHub: manifest/env mismatch for ", label)
        );
    }

    function _requireContract(address target, string memory label) internal view {
        require(target.code.length > 0, string.concat("DeployMaintenanceHub: ", label, " is not a contract"));
    }
}
