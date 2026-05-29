// SPDX-License-Identifier: MIT
pragma solidity ^0.8.34;

import {Script, console2} from "forge-std/Script.sol";

import {ClaimToken} from "../src/ClaimToken.sol";
import {VeClaimNFT} from "../src/VeClaimNFT.sol";
import {ShareholderRoyalties} from "../src/ShareholderRoyalties.sol";
import {Furnace} from "../src/Furnace.sol";
import {FurnaceGuardHelper} from "../src/FurnaceGuardHelper.sol";

import {MarketRouter} from "../src/MarketRouter.sol";
import {MineCore} from "../src/MineCore.sol";
import {ClaimAllHelper} from "../src/ClaimAllHelper.sol";
import {EntryTokenRegistry} from "../src/EntryTokenRegistry.sol";
import {DelegationHub} from "../src/DelegationHub.sol";
import {TimelockController} from "lib/openzeppelin-contracts/contracts/governance/TimelockController.sol";
import {
    FurnaceProxy,
    MarketRouterProxy,
    MineCoreProxy,
    ShareholderRoyaltiesProxy
} from "../src/lib/RuntimeProxyWrappers.sol";

/// @notice Local-only deployment for Anvil.
/// @dev Produces Foundry broadcast artifacts consumed by the local deployment flow.
///      This script ONLY deploys contracts. Wiring is done by script/Wire.s.sol,
///      to match production posture and to allow the local runner to deploy optional components
///      (LP vaults, genesis helpers, MaintenanceHub) before freezing configs.
///      It simulates the full constructor sequence before broadcast so a late local
///      constructor revert cannot leave a partial core stack behind.
contract DeployLocal is Script {
    function run() external {
        require(block.chainid == 31337 || block.chainid == 1337, "DeployLocal: local chain only");

        // Local runner passes this env var (hex ok):
        // LOCAL_PRIVATE_KEY=0x...
        uint256 deployerPrivateKey = vm.envUint("LOCAL_PRIVATE_KEY");
        address initialOwner = vm.addr(deployerPrivateKey);

        console2.log("DeployLocal: simulating full deployment sequence before broadcast...");
        _preflightDeploySequence(initialOwner);
        console2.log("DeployLocal: preflight simulation passed.");

        vm.startBroadcast(deployerPrivateKey);
        _executeDeploySequence(initialOwner);
        vm.stopBroadcast();
    }

    function _preflightDeploySequence(address initialOwner) internal {
        uint256 snap = vm.snapshot();
        vm.startPrank(initialOwner);
        _executeDeploySequence(initialOwner);
        vm.stopPrank();
        require(vm.revertTo(snap), "DeployLocal: failed to revert preflight snapshot");
    }

    function _executeDeploySequence(address initialOwner) internal virtual {
        // ------------------------------------------------------------
        // Deployments (no wiring here)
        // ------------------------------------------------------------

        ClaimToken claimToken = new ClaimToken(initialOwner);
        VeClaimNFT ve = new VeClaimNFT(address(claimToken), initialOwner);
        ShareholderRoyalties royaltiesImpl = new ShareholderRoyalties(address(ve), address(0));
        address royalties = address(
            new ShareholderRoyaltiesProxy(
                address(royaltiesImpl), initialOwner, abi.encodeCall(ShareholderRoyalties.initialize, (initialOwner))
            )
        );

        FurnaceGuardHelper guardHelper = new FurnaceGuardHelper(address(claimToken), address(ve));
        Furnace furnaceImpl = new Furnace(address(claimToken), address(ve), address(guardHelper), address(0));
        address furnace = address(
            new FurnaceProxy(address(furnaceImpl), initialOwner, abi.encodeCall(Furnace.initialize, (initialOwner)))
        );

        MarketRouter marketImpl = new MarketRouter(address(claimToken), address(ve), royalties, address(0));
        address market = address(
            new MarketRouterProxy(
                address(marketImpl), initialOwner, abi.encodeCall(MarketRouter.initialize, (initialOwner))
            )
        );

        MineCore mineCoreImpl = new MineCore(address(claimToken), address(ve), royalties, address(0));
        address mineCore = address(
            new MineCoreProxy(address(mineCoreImpl), initialOwner, abi.encodeCall(MineCore.initialize, (initialOwner)))
        );

        address[] memory proposers = new address[](1);
        proposers[0] = initialOwner;
        address[] memory executors = new address[](1);
        executors[0] = initialOwner;
        TimelockController timelock = new TimelockController(0, proposers, executors, initialOwner);

        ClaimAllHelper claimAll = new ClaimAllHelper(royalties, mineCore);

        DelegationHub delegationHub = new DelegationHub();

        // Deploy two registries to mirror mainnet policy split (Furnace vs MineCore).
        // They are the same contract type, but should be treated as independent instances.
        EntryTokenRegistry furnaceEntryTokenRegistry = new EntryTokenRegistry(initialOwner);
        EntryTokenRegistry mineCoreEntryTokenRegistry = new EntryTokenRegistry(initialOwner);

        // Silence unused variable warnings (explicit naming is useful in broadcast output).
        claimAll;
        claimToken;
        ve;
        royaltiesImpl;
        furnaceImpl;
        marketImpl;
        mineCoreImpl;
        royalties;
        furnace;
        market;
        mineCore;
        timelock;
        furnaceEntryTokenRegistry;
        mineCoreEntryTokenRegistry;
        delegationHub;
    }
}
