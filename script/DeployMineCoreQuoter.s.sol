// SPDX-License-Identifier: MIT
pragma solidity ^0.8.34;

import {BroadcastSignerBase} from "./lib/BroadcastSignerBase.sol";

import {MineCoreQuoter} from "../src/MineCoreQuoter.sol";

/// @notice Deploy the MineCoreQuoter view-only takeover quoting helper.
/// @dev Designed for local deployment flows but usable on any chain.
///      When a deployments manifest is available, the script treats it as the
///      canonical source of MineCore truth and only accepts env vars that match
///      that manifest. Unsupported/custom chains may still fall back to env-only
///      deployment when no manifest is supplied.
///
/// Optional manifest sources:
/// - DEPLOYMENTS_MANIFEST_JSON
/// - deployments/base_mainnet.json on chainId 8453
/// - deployments/base_sepolia.json on chainId 84532
///
/// Env fallback when no manifest is available:
/// - local chainIds 31337 / 1337: prefer LOCAL_MINE_CORE, fallback to MINE_CORE
///   (standard local bootstrap writes deployments/local.json after this helper runs)
/// - production/testnet chains: require MINE_CORE
///
/// Signer input:
/// - local chains: LOCAL_PRIVATE_KEY (preferred), fallback PRIVATE_KEY
/// - Base Sepolia: PRIVATE_KEY
/// - Base mainnet: LEDGER_ADDRESS / SIGNER_ADDRESS with `forge script ... --ledger --sender <address>`
///                 or PRIVATE_KEY as a fallback if explicitly desired
contract DeployMineCoreQuoter is BroadcastSignerBase {
    function run() external {
        bool isLocal = block.chainid == 31337 || block.chainid == 1337;
        BroadcastSigner memory signer = _resolveBroadcastSigner();

        string memory json = _manifestJsonOrEmpty();
        address mineCore = _envAddressOrZero(isLocal, "LOCAL_MINE_CORE", "MINE_CORE");
        if (bytes(json).length != 0) {
            address manifestMineCore = vm.parseJsonAddress(json, ".contracts.MineCore.address");
            require(manifestMineCore != address(0), "DeployMineCoreQuoter: missing MineCore in manifest");
            require(
                mineCore == address(0) || mineCore == manifestMineCore,
                "DeployMineCoreQuoter: manifest/env mismatch for MINE_CORE"
            );
            mineCore = manifestMineCore;
        } else {
            require(mineCore != address(0), "DeployMineCoreQuoter: missing required env address");
        }
        require(mineCore.code.length > 0, "DeployMineCoreQuoter: MINE_CORE is not a contract");

        vm.stopPrank();
        _startBroadcast(signer);
        MineCoreQuoter q = new MineCoreQuoter(mineCore);
        vm.stopBroadcast();

        // Defense-in-depth readback: the constructor already enforces the pairing
        // (immutable wiring + revert-on-bad-input), but asserting it here surfaces
        // any future constructor regression in the deploy log instead of letting
        // it ship silently.
        require(q.mineCore() == mineCore, "DeployMineCoreQuoter: quoter mineCore mismatch");
    }

    function _envAddressOrZero(bool isLocal, string memory localKey, string memory prodKey)
        internal
        returns (address out)
    {
        if (isLocal) {
            try vm.envAddress(localKey) returns (address v) {
                out = v;
                return out;
            } catch {}
        }

        try vm.envAddress(prodKey) returns (address v2) {
            out = v2;
            return out;
        } catch {
            out = address(0);
            return out;
        }
    }

    function _defaultManifestPath() internal view returns (string memory) {
        if (block.chainid == 8453) return "deployments/base_mainnet.json";
        if (block.chainid == 84532) return "deployments/base_sepolia.json";
        return "";
    }

    function _manifestJsonOrEmpty() internal view returns (string memory json) {
        try vm.envString("DEPLOYMENTS_MANIFEST_JSON") returns (string memory inlineJson) {
            if (bytes(inlineJson).length > 0) return _sanitizeInlineJson(inlineJson);
        } catch {}

        string memory path = _defaultManifestPath();
        if (bytes(path).length == 0) return "";

        try vm.readFile(path) returns (string memory fileJson) {
            return fileJson;
        } catch {
            return "";
        }
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
}
