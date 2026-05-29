// SPDX-License-Identifier: MIT
pragma solidity ^0.8.34;

import {console2} from "forge-std/Script.sol";
import {BroadcastSignerBase} from "./lib/BroadcastSignerBase.sol";

interface ILaunchControllerFinalize {
    function guardian() external view returns (address);
    function genesisFinalized() external view returns (bool);
    function finalizeGenesis() external payable;
}

interface IMineCoreFinalize {
    function owner() external view returns (address);
    function guardian() external view returns (address);
    function takeoversPaused() external view returns (bool);
    function setGuardian(address _guardian) external;
    function GENESIS_ACCRUAL_DURATION() external view returns (uint256);
}

interface IGenesisLPVaultFinalize {
    function lockStartTime() external view returns (uint256);
    function lpLockedAmount() external view returns (uint256);
}

/// @notice Production/testnet helper: finalize genesis via LaunchController, then rotate MineCore.guardian.
/// @dev Reads deployments/{base_mainnet,base_sepolia}.json from chainId. This script is intentionally idempotent:
///      The full finalize + guardian-rotation + postcondition sequence is simulated before broadcast so
///      a later revert cannot leave genesis partially finalized onchain.
///      - if genesis is already finalized, it skips the one-shot call
///      - if GUARDIAN differs from the post-finalize guardian, the script rotates MineCore.guardian after finalize
///      - the selected signer must control both LaunchController.guardian and MineCore.owner selected
///        during Deploy.s.sol until the post-genesis guardian rotation completes
///
/// Required signer input:
/// - Base Sepolia: PRIVATE_KEY
/// - Base mainnet: LEDGER_ADDRESS / SIGNER_ADDRESS with `forge script ... --ledger --sender <address>`
///                 or PRIVATE_KEY as a fallback if explicitly desired
///
/// Required env:
/// - GUARDIAN   Long-term MineCore guardian to install (or confirm) after genesis finalization.
///              Production/testnet reruns still require this so the script cannot silently accept an
///              unintended post-genesis guardian such as the bootstrap deployer EOA.
contract FinalizeGenesis is BroadcastSignerBase {
    function run() external {
        require(block.chainid == 8453 || block.chainid == 84532, "FinalizeGenesis: unsupported chainId");

        //
        //   These are TWO separate transactions in the broadcast block:
        //   (1) LaunchController.finalizeGenesis()
        //   (2) optional MineCore.setGuardian(GUARDIAN)
        //
        //   If the broadcast is interrupted after (1) but before (2), MineCore.guardian
        //   has rotated to LaunchController.guardian (the ops wallet stored at deploy time),
        //   but the long-term GUARDIAN may still be pending. The script
        //   handles this gracefully: it can be re-run, skips the one-shot finalize call,
        //   and applies only the remaining guardian rotation when needed.
        //
        //   Post-conditions (in _executeFinalizeSequence) verify: genesis finalized,
        //   takeovers unpaused, LP lock started, LP locked > 0, guardian rotated when
        //   requested. Two broadcasts are NOT atomic; the re-run logic handles partial execution.

        BroadcastSigner memory signer = _resolveBroadcastSigner();
        address broadcaster = signer.account;
        string memory json = _manifestJson();
        address launchController = vm.parseJsonAddress(json, ".contracts.LaunchController.address");
        address mineCore = vm.parseJsonAddress(json, ".contracts.MineCore.address");
        address genesisLpVault = vm.parseJsonAddress(json, ".contracts.GenesisLPVault24M.address");

        require(
            launchController != address(0) && launchController.code.length > 0,
            "FinalizeGenesis: missing LaunchController"
        );
        require(mineCore != address(0) && mineCore.code.length > 0, "FinalizeGenesis: missing MineCore");
        require(
            genesisLpVault != address(0) && genesisLpVault.code.length > 0, "FinalizeGenesis: missing GenesisLPVault24M"
        );

        bool finalized = ILaunchControllerFinalize(launchController).genesisFinalized();
        address targetGuardian = _envAddressOrZero("GUARDIAN");
        address currentGuardian = IMineCoreFinalize(mineCore).guardian();
        address currentOwner = IMineCoreFinalize(mineCore).owner();
        require(
            targetGuardian != address(0),
            "FinalizeGenesis: GUARDIAN required for production/testnet finalize and reruns"
        );
        if (!finalized) {
            require(currentGuardian == launchController, "FinalizeGenesis: MineCore guardian must be LaunchController");
            require(
                ILaunchControllerFinalize(launchController).guardian() == broadcaster,
                "FinalizeGenesis: signer must control LaunchController.guardian"
            );
            require(IMineCoreFinalize(mineCore).takeoversPaused(), "FinalizeGenesis: takeovers must stay paused");
            require(
                currentOwner == broadcaster,
                "FinalizeGenesis: signer must control MineCore.owner while MineCore.guardian is LaunchController"
            );
        } else if (targetGuardian != currentGuardian) {
            require(
                currentOwner == broadcaster || currentGuardian == broadcaster,
                "FinalizeGenesis: signer must control MineCore.owner or guardian for post-genesis rotation"
            );
        }

        require(targetGuardian != launchController, "FinalizeGenesis: GUARDIAN must not equal LaunchController");
        uint256 requiredSeedEth = 50 ether * IMineCoreFinalize(mineCore).GENESIS_ACCRUAL_DURATION() / 10 days;
        if (!finalized) {
            require(broadcaster.balance >= requiredSeedEth, "FinalizeGenesis: broadcaster needs >= requiredSeedEth");
        }

        console2.log("FinalizeGenesis: requiredSeedEth =", requiredSeedEth);
        console2.log("FinalizeGenesis: simulating full finalize sequence before broadcast...");
        _preflightFinalizeSequence(
            launchController, mineCore, genesisLpVault, broadcaster, targetGuardian, finalized, requiredSeedEth
        );
        console2.log("FinalizeGenesis: preflight simulation passed.");

        _startBroadcast(signer);
        _executeFinalizeSequence(
            launchController, mineCore, genesisLpVault, broadcaster, targetGuardian, finalized, requiredSeedEth
        );
        vm.stopBroadcast();
    }

    function _preflightFinalizeSequence(
        address launchController,
        address mineCore,
        address genesisLpVault,
        address broadcaster,
        address targetGuardian,
        bool finalized,
        uint256 requiredSeedEth
    ) internal {
        uint256 snap = vm.snapshot();
        vm.startPrank(broadcaster);
        _executeFinalizeSequence(
            launchController, mineCore, genesisLpVault, broadcaster, targetGuardian, finalized, requiredSeedEth
        );
        vm.stopPrank();
        require(vm.revertTo(snap), "FinalizeGenesis: failed to revert preflight snapshot");
    }

    function _executeFinalizeSequence(
        address launchController,
        address mineCore,
        address genesisLpVault,
        address actor,
        address targetGuardian,
        bool finalized,
        uint256 requiredSeedEth
    ) internal {
        if (!finalized) {
            ILaunchControllerFinalize(launchController).finalizeGenesis{value: requiredSeedEth}();
            finalized = true;
        }

        address cur = IMineCoreFinalize(mineCore).guardian();
        if (cur != targetGuardian) {
            require(
                IMineCoreFinalize(mineCore).owner() == actor || cur == actor,
                "FinalizeGenesis: caller must control MineCore.owner or guardian to rotate guardian"
            );
            IMineCoreFinalize(mineCore).setGuardian(targetGuardian);
        }

        require(
            ILaunchControllerFinalize(launchController).genesisFinalized(), "FinalizeGenesis: genesis not finalized"
        );
        require(!IMineCoreFinalize(mineCore).takeoversPaused(), "FinalizeGenesis: takeovers still paused");
        require(IGenesisLPVaultFinalize(genesisLpVault).lockStartTime() != 0, "FinalizeGenesis: LP lock not started");
        require(IGenesisLPVaultFinalize(genesisLpVault).lpLockedAmount() > 0, "FinalizeGenesis: no LP locked");
        require(
            IMineCoreFinalize(mineCore).guardian() != launchController,
            "FinalizeGenesis: MineCore.guardian still LaunchController"
        );
        require(
            IMineCoreFinalize(mineCore).guardian() == targetGuardian, "FinalizeGenesis: guardian rotation incomplete"
        );
    }

    function _manifestPath() internal view returns (string memory) {
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

    function _envAddressOrZero(string memory key) internal returns (address out) {
        try vm.envAddress(key) returns (address v) {
            out = v;
        } catch {
            out = address(0);
        }
    }
}
