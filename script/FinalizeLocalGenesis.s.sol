// SPDX-License-Identifier: MIT
pragma solidity ^0.8.34;

import {Script, console2} from "forge-std/Script.sol";

interface ILaunchController {
    function guardian() external view returns (address);
    function genesisFinalized() external view returns (bool);
    function finalizeGenesis() external payable;
}

interface IMineCore {
    function owner() external view returns (address);
    function guardian() external view returns (address);
    function takeoversPaused() external view returns (bool);
    function setGuardian(address _guardian) external;
    function GENESIS_ACCRUAL_DURATION() external view returns (uint256);
}

interface IGenesisLPVaultLocal {
    function lockStartTime() external view returns (uint256);
    function lpLockedAmount() external view returns (uint256);
}

/// @notice Local-only helper: finalize genesis via LaunchController (one-shot).
/// @dev Requires anvil time to have advanced past `MineCore.GENESIS_ACCRUAL_DURATION()` (1 day on local, 10 days on Base mainnet).
///      The full finalize + guardian-rotation + postcondition sequence is simulated before broadcast so
///      a later revert cannot leave the local stack partially finalized.
///      LOCAL_PRIVATE_KEY must keep controlling both LaunchController.guardian and MineCore.owner
///      until the post-genesis guardian rotation completes.
contract FinalizeLocalGenesis is Script {
    function run() external {
        require(block.chainid == 31337 || block.chainid == 1337, "FinalizeLocalGenesis: local chain only");

        uint256 pk = vm.envUint("LOCAL_PRIVATE_KEY");
        address broadcaster = vm.addr(pk);
        string memory json = _manifestJson();
        address launchController = vm.parseJsonAddress(json, ".contracts.LaunchController.address");
        address mineCore = vm.parseJsonAddress(json, ".contracts.MineCore.address");
        address genesisLpVault = vm.parseJsonAddress(json, ".contracts.GenesisLPVault24M.address");
        require(
            launchController != address(0) && launchController.code.length > 0,
            "FinalizeLocalGenesis: missing LaunchController"
        );
        require(mineCore != address(0) && mineCore.code.length > 0, "FinalizeLocalGenesis: missing MineCore");
        require(
            genesisLpVault != address(0) && genesisLpVault.code.length > 0,
            "FinalizeLocalGenesis: missing GenesisLPVault24M"
        );

        // 1) Finalize genesis (one-shot).
        bool finalized = ILaunchController(launchController).genesisFinalized();
        address targetGuardian = broadcaster;
        try vm.envAddress("GUARDIAN") returns (address g) {
            if (g != address(0)) targetGuardian = g;
        } catch {}

        if (!finalized) {
            require(IMineCore(mineCore).guardian() == launchController, "FinalizeLocalGenesis: MineCore guardian drift");
            require(
                ILaunchController(launchController).guardian() == broadcaster,
                "FinalizeLocalGenesis: LOCAL_PRIVATE_KEY must control LaunchController.guardian"
            );
            require(IMineCore(mineCore).takeoversPaused(), "FinalizeLocalGenesis: takeovers must stay paused");
            require(
                IMineCore(mineCore).owner() == broadcaster,
                "FinalizeLocalGenesis: LOCAL_PRIVATE_KEY must control MineCore.owner while MineCore.guardian is LaunchController"
            );
        } else if (targetGuardian != address(0) && targetGuardian != IMineCore(mineCore).guardian()) {
            require(
                IMineCore(mineCore).owner() == broadcaster || IMineCore(mineCore).guardian() == broadcaster,
                "FinalizeLocalGenesis: LOCAL_PRIVATE_KEY must control MineCore.owner or guardian for post-genesis rotation"
            );
        }

        require(targetGuardian != launchController, "FinalizeLocalGenesis: GUARDIAN must not equal LaunchController");
        uint256 requiredSeedEth = 50 ether * IMineCore(mineCore).GENESIS_ACCRUAL_DURATION() / 10 days;
        if (!finalized) {
            require(
                broadcaster.balance >= requiredSeedEth, "FinalizeLocalGenesis: broadcaster needs >= requiredSeedEth"
            );
        }

        console2.log("FinalizeLocalGenesis: requiredSeedEth =", requiredSeedEth);
        console2.log("FinalizeLocalGenesis: simulating full finalize sequence before broadcast...");
        _preflightFinalizeSequence(
            launchController, mineCore, genesisLpVault, broadcaster, targetGuardian, finalized, requiredSeedEth
        );
        console2.log("FinalizeLocalGenesis: preflight simulation passed.");

        vm.startBroadcast(pk);
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
        require(vm.revertTo(snap), "FinalizeLocalGenesis: failed to revert preflight snapshot");
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
            ILaunchController(launchController).finalizeGenesis{value: requiredSeedEth}();
            finalized = true;
        }

        if (targetGuardian != address(0)) {
            address cur = IMineCore(mineCore).guardian();
            if (cur != targetGuardian) {
                require(
                    IMineCore(mineCore).owner() == actor || cur == actor,
                    "FinalizeLocalGenesis: caller must control MineCore.owner or guardian to rotate guardian"
                );
                IMineCore(mineCore).setGuardian(targetGuardian);
            }
        }

        require(ILaunchController(launchController).genesisFinalized(), "FinalizeLocalGenesis: genesis not finalized");
        require(!IMineCore(mineCore).takeoversPaused(), "FinalizeLocalGenesis: takeovers still paused");
        require(IGenesisLPVaultLocal(genesisLpVault).lockStartTime() != 0, "FinalizeLocalGenesis: LP lock not started");
        require(IGenesisLPVaultLocal(genesisLpVault).lpLockedAmount() > 0, "FinalizeLocalGenesis: no LP locked");
        require(
            IMineCore(mineCore).guardian() != launchController,
            "FinalizeLocalGenesis: MineCore.guardian still LaunchController"
        );
        if (targetGuardian != address(0)) {
            require(
                IMineCore(mineCore).guardian() == targetGuardian, "FinalizeLocalGenesis: guardian rotation incomplete"
            );
        }
    }

    function _manifestJson() internal view returns (string memory json) {
        try vm.envString("DEPLOYMENTS_MANIFEST_JSON") returns (string memory inlineJson) {
            if (bytes(inlineJson).length > 0) return _sanitizeInlineJson(inlineJson);
        } catch {}
        return vm.readFile("deployments/local.json");
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
