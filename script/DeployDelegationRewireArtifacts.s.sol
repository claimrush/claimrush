// SPDX-License-Identifier: MIT
pragma solidity ^0.8.34;

import {console2} from "forge-std/Script.sol";
import {BroadcastSignerBase} from "./lib/BroadcastSignerBase.sol";

import {DelegationHub} from "../src/DelegationHub.sol";
import {ClaimAllHelper} from "../src/ClaimAllHelper.sol";
import {ShareholderRoyalties} from "../src/ShareholderRoyalties.sol";

/// @notice Deploy the three immutable / implementation artifacts required to add the
///         shareholder route-to-caller path: a fresh `DelegationHub` (its valid-perms
///         mask is fixed at construction, so the new `P_ROUTE_SHAREHOLDER_ETH_TO_CALLER`
///         bit needs a new hub), a fresh `ClaimAllHelper` (immutable; carries the new
///         `claimShareholderToCallerForUser` entrypoint), and a new `ShareholderRoyalties`
///         implementation (adds the helper-only `claimShareholderForTo`).
///
/// @dev Deploy-only. Wiring is a SEPARATE atomic Timelock batch
///      (`TimelockDelegationRewire.s.sol`) so the artifact CREATEs and the
///      governance-gated rewire have independent blast radii.
///
///      Wiring roots (ve / royalties) are resolved from the live MineCore proxy via
///      staticcall against the current RPC, so the new ClaimAllHelper + SR impl bind to
///      exactly the live core. The new ClaimAllHelper points at the EXISTING royalties +
///      MineCore proxies (unchanged); it resolves the canonical DelegationHub dynamically
///      at call time, so it needs no hub constructor arg.
///
///      Run:
///        MINE_CORE=0x... \
///        SIGNER_ADDRESS=0x... \
///        forge script script/DeployDelegationRewireArtifacts.s.sol:DeployDelegationRewireArtifacts \
///          --rpc-url $RPC --broadcast --verify \
///          --etherscan-api-key $BASESCAN_API_KEY \
///          --private-key $PRIVATE_KEY --sender $SIGNER_ADDRESS
contract DeployDelegationRewireArtifacts is BroadcastSignerBase {
    function run() external {
        require(
            block.chainid == 8453 || block.chainid == 84532 || block.chainid == 31337 || block.chainid == 1337,
            "DeployDelegationRewireArtifacts: unsupported chainId"
        );

        address mineCoreProxy = vm.envAddress("MINE_CORE");
        require(mineCoreProxy != address(0), "DeployDelegationRewireArtifacts: MINE_CORE env required");
        _requireContract(mineCoreProxy, "MINE_CORE");

        if (block.chainid == 8453 || block.chainid == 84532) {
            string memory json = vm.readFile(_manifestPath());
            address manifestProxy = vm.parseJsonAddress(json, ".contracts.MineCore.address");
            require(
                manifestProxy == mineCoreProxy,
                "DeployDelegationRewireArtifacts: MINE_CORE env does not match deployments manifest"
            );
        }

        address ve = _readAddressFn(mineCoreProxy, "ve()");
        address royalties = _readAddressFn(mineCoreProxy, "royalties()");
        require(ve != address(0), "DeployDelegationRewireArtifacts: proxy returned zero VE");
        require(royalties != address(0), "DeployDelegationRewireArtifacts: proxy returned zero ROYALTIES");
        _requireContract(ve, "VE");
        _requireContract(royalties, "ROYALTIES");

        // The new ShareholderRoyalties impl carries the same immutable `ve` as the live
        // proxy. Cross-check the proxy's own `ve()` so the upgrade preserves the root.
        address royaltiesVe = _readAddressFn(royalties, "ve()");
        require(royaltiesVe == ve, "DeployDelegationRewireArtifacts: royalties.ve() != mineCore.ve()");

        _assertEnvMatches("VE", ve);
        _assertEnvMatches("ROY", royalties);

        BroadcastSigner memory signer = _resolveBroadcastSigner();

        console2.log("DeployDelegationRewireArtifacts: chainId        ", block.chainid);
        console2.log("DeployDelegationRewireArtifacts: MineCore proxy ", mineCoreProxy);
        console2.log("DeployDelegationRewireArtifacts: royalties proxy", royalties);
        console2.log("DeployDelegationRewireArtifacts: ve root        ", ve);
        console2.log("DeployDelegationRewireArtifacts: signer         ", signer.account);

        _preflightConstruct(ve, royalties, mineCoreProxy);

        vm.stopPrank();
        _startBroadcast(signer);

        DelegationHub hub = new DelegationHub();
        ClaimAllHelper helper = new ClaimAllHelper(royalties, mineCoreProxy);
        ShareholderRoyalties royaltiesImpl = new ShareholderRoyalties(ve, address(0));

        vm.stopBroadcast();

        console2.log("DeployDelegationRewireArtifacts: NEW_DELEGATION_HUB             ", address(hub));
        console2.log("DeployDelegationRewireArtifacts: NEW_CLAIM_ALL_HELPER           ", address(helper));
        console2.log("DeployDelegationRewireArtifacts: NEW_SHAREHOLDER_ROYALTIES_IMPL ", address(royaltiesImpl));
        console2.log(
            "DeployDelegationRewireArtifacts: next step -> TimelockDelegationRewire.s.sol (one atomic batch: SR upgradeAndCall + 4 ordered setters)"
        );
    }

    function _preflightConstruct(address ve, address royalties, address mineCoreProxy) internal {
        uint256 snap = vm.snapshot();
        ClaimAllHelper probeHelper = new ClaimAllHelper(royalties, mineCoreProxy);
        require(
            address(probeHelper.royalties()) == royalties, "DeployDelegationRewireArtifacts: probe royalties mismatch"
        );
        require(
            address(probeHelper.mineCore()) == mineCoreProxy, "DeployDelegationRewireArtifacts: probe mineCore mismatch"
        );
        ShareholderRoyalties probeImpl = new ShareholderRoyalties(ve, address(0));
        require(address(probeImpl.ve()) == ve, "DeployDelegationRewireArtifacts: probe SR ve mismatch");
        require(vm.revertTo(snap), "DeployDelegationRewireArtifacts: failed to revert preflight snapshot");
    }

    function _readAddressFn(address target, string memory sig) internal view returns (address out) {
        (bool ok, bytes memory data) = target.staticcall(abi.encodeWithSignature(sig));
        require(ok && data.length >= 32, string.concat("DeployDelegationRewireArtifacts: staticcall failed for ", sig));
        out = abi.decode(data, (address));
    }

    function _assertEnvMatches(string memory key, address expected) internal {
        try vm.envAddress(key) returns (address supplied) {
            if (supplied != address(0)) {
                require(
                    supplied == expected, string.concat("DeployDelegationRewireArtifacts: env/chain mismatch for ", key)
                );
            }
        } catch {}
    }

    function _manifestPath() internal view returns (string memory) {
        if (block.chainid == 8453) return "deployments/base_mainnet.json";
        if (block.chainid == 84532) return "deployments/base_sepolia.json";
        return "deployments/local.json";
    }

    function _requireContract(address target, string memory label) internal view {
        require(target.code.length > 0, string.concat("DeployDelegationRewireArtifacts: ", label, " is not a contract"));
    }
}
