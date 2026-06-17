// SPDX-License-Identifier: MIT
pragma solidity ^0.8.34;

import {BroadcastSignerBase} from "./lib/BroadcastSignerBase.sol";

import {FurnaceQuoter} from "../src/FurnaceQuoter.sol";

/// @notice Deploy a fresh FurnaceQuoter bound to the live Furnace proxy.
/// @dev The quoter is stateless view-math: it inlines the sell-spread / bonus
///      constants at construction. Deploying a new quoter and re-pointing the
///      Furnace at it (see `script/TimelockSetFurnaceQuoter.s.sol`) is how a
///      constant change such as `SELL_ROUND_TRIP_LOSS_MAX_BPS` is activated on a
///      live, timelock-owned stack — no proxy upgrade, no state migration.
///
///      The constructor enforces the pairing (immutable wiring + revert-on-bad-input);
///      the readback below surfaces any constructor wiring fault in the deploy log.
///
/// Optional manifest sources (canonical Furnace truth):
/// - DEPLOYMENTS_MANIFEST_JSON
/// - deployments/base_mainnet.json on chainId 8453
/// - deployments/base_sepolia.json on chainId 84532
///
/// Env fallback when no manifest is available:
/// - local chainIds 31337 / 1337: prefer LOCAL_FURNACE, fallback to FURNACE
/// - production/testnet chains: require FURNACE (and it must match the manifest)
///
/// Signer input:
/// - local chains: LOCAL_PRIVATE_KEY (preferred), fallback PRIVATE_KEY
/// - Base Sepolia: PRIVATE_KEY
/// - Base mainnet: SIGNER_ADDRESS / LEDGER_ADDRESS with `forge script ... --ledger --sender <address>`
///                 or PRIVATE_KEY as a fallback if explicitly desired
///
/// Run (mainnet, Ledger):
///   FURNACE=0x... SIGNER_ADDRESS=0x... \
///   forge script script/DeployFurnaceQuoter.s.sol:DeployFurnaceQuoter \
///     --rpc-url $RPC --broadcast --verify \
///     --etherscan-api-key $BASESCAN_API_KEY \
///     --ledger --sender $SIGNER_ADDRESS
contract DeployFurnaceQuoter is BroadcastSignerBase {
    function run() external {
        bool isLocal = block.chainid == 31337 || block.chainid == 1337;
        BroadcastSigner memory signer = _resolveBroadcastSigner();

        string memory json = _manifestJsonOrEmpty();
        address furnace = _envAddressOrZero(isLocal, "LOCAL_FURNACE", "FURNACE");
        if (bytes(json).length != 0) {
            address manifestFurnace = vm.parseJsonAddress(json, ".contracts.Furnace.address");
            require(manifestFurnace != address(0), "DeployFurnaceQuoter: missing Furnace in manifest");
            require(
                furnace == address(0) || furnace == manifestFurnace,
                "DeployFurnaceQuoter: manifest/env mismatch for FURNACE"
            );
            furnace = manifestFurnace;
        } else {
            require(furnace != address(0), "DeployFurnaceQuoter: missing required env address");
        }
        require(furnace.code.length > 0, "DeployFurnaceQuoter: FURNACE is not a contract");

        vm.stopPrank();
        _startBroadcast(signer);
        FurnaceQuoter q = new FurnaceQuoter(furnace);
        vm.stopBroadcast();

        // Defense-in-depth readback: the constructor already enforces the pairing
        // (immutable wiring + revert-on-bad-input), but asserting it here surfaces
        // any constructor wiring fault in the deploy log instead of letting
        // it ship silently. The re-point compatibility gate
        // (`FurnaceGuardHelper.requireFurnaceQuoterCompatible`) also requires
        // `quoter.furnace() == furnace`.
        require(q.furnace() == furnace, "DeployFurnaceQuoter: quoter furnace mismatch");
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
        bytes1 openBrace = 0x7B; // '{'
        bytes1 closeBrace = 0x7D; // '}'
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
}
