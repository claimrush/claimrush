// SPDX-License-Identifier: MIT
pragma solidity ^0.8.34;

import {console2} from "forge-std/Script.sol";
import {BroadcastSignerBase} from "./lib/BroadcastSignerBase.sol";

import {MineCore} from "../src/MineCore.sol";

/// @notice Deploy the v1.0.0 MineCore implementation at the same constructor-arg
///         bundle (claim / ve / royalties) as the live proxy. Does NOT call
///         upgradeAndCall on the proxy admin — that step is a separate
///         `cast send` from the operations runbook so the two actions have
///         independent blast radii.
///
/// @dev Wiring roots (claim / ve / royalties) are resolved from the live
///      MineCore proxy via staticcall against the current RPC, then
///      cross-checked against the deployments manifest. An env/manifest
///      mismatch fails closed before any broadcast.
///
///      Optional preflight guard: set `EXPECTED_CURRENT_IMPL` to the address
///      currently installed under EIP-1967 IMPL_SLOT on the proxy to assert
///      the operator is replacing the intended implementation. If unset the
///      check is skipped (useful on local / sepolia dry-runs).
///
///      Run:
///        MINE_CORE=0x... \
///        SIGNER_ADDRESS=0x... \
///        forge script script/DeployMineCoreImpl.s.sol:DeployMineCoreImpl \
///          --rpc-url $RPC --broadcast --verify \
///          --etherscan-api-key $BASESCAN_API_KEY \
///          --private-key $PRIVATE_KEY --sender $SIGNER_ADDRESS
contract DeployMineCoreImpl is BroadcastSignerBase {
    bytes32 internal constant IMPL_SLOT = 0x360894a13ba1a3210667c828492db98dca3e2076cc3735a920a3ca505d382bbc;

    function run() external {
        require(
            block.chainid == 8453 || block.chainid == 84532 || block.chainid == 31337 || block.chainid == 1337,
            "DeployMineCoreImpl: unsupported chainId"
        );

        address mineCoreProxy = vm.envAddress("MINE_CORE");
        require(mineCoreProxy != address(0), "DeployMineCoreImpl: MINE_CORE env required");
        _requireContract(mineCoreProxy, "MINE_CORE");

        if (block.chainid == 8453 || block.chainid == 84532) {
            string memory json = vm.readFile(_manifestPath());
            address manifestProxy = vm.parseJsonAddress(json, ".contracts.MineCore.address");
            require(
                manifestProxy == mineCoreProxy, "DeployMineCoreImpl: MINE_CORE env does not match deployments manifest"
            );
        }

        address claim = _readAddressFn(mineCoreProxy, "claim()");
        address ve = _readAddressFn(mineCoreProxy, "ve()");
        address royalties = _readAddressFn(mineCoreProxy, "royalties()");

        require(claim != address(0), "DeployMineCoreImpl: proxy returned zero CLAIM");
        require(ve != address(0), "DeployMineCoreImpl: proxy returned zero VE");
        require(royalties != address(0), "DeployMineCoreImpl: proxy returned zero ROYALTIES");
        _requireContract(claim, "CLAIM");
        _requireContract(ve, "VE");
        _requireContract(royalties, "ROYALTIES");

        _assertEnvMatches("CLAIM", claim);
        _assertEnvMatches("VE", ve);
        _assertEnvMatches("ROY", royalties);

        bytes32 implRaw = vm.load(mineCoreProxy, IMPL_SLOT);
        address currentImpl = address(uint160(uint256(implRaw)));
        _requireContract(currentImpl, "CURRENT_IMPL");
        _assertEnvMatches("EXPECTED_CURRENT_IMPL", currentImpl);

        BroadcastSigner memory signer = _resolveBroadcastSigner();

        console2.log("DeployMineCoreImpl: chainId        ", block.chainid);
        console2.log("DeployMineCoreImpl: MineCore proxy ", mineCoreProxy);
        console2.log("DeployMineCoreImpl: current impl   ", currentImpl);
        console2.log("DeployMineCoreImpl: claim root     ", claim);
        console2.log("DeployMineCoreImpl: ve root        ", ve);
        console2.log("DeployMineCoreImpl: royalties root ", royalties);
        console2.log("DeployMineCoreImpl: signer         ", signer.account);

        _preflightConstruct(claim, ve, royalties);

        vm.stopPrank();
        _startBroadcast(signer);

        MineCore impl = new MineCore(claim, ve, royalties, address(0));

        vm.stopBroadcast();

        console2.log("DeployMineCoreImpl: NEW_IMPL       ", address(impl));
        console2.log(
            "DeployMineCoreImpl: next step -> cast send $PROXY_ADMIN 'upgradeAndCall(address,address,bytes)' $MINE_CORE <NEW_IMPL> 0x"
        );
    }

    function _preflightConstruct(address claim, address ve, address royalties) internal {
        uint256 snap = vm.snapshot();
        MineCore probe = new MineCore(claim, ve, royalties, address(0));
        require(address(probe.claim()) == claim, "DeployMineCoreImpl: probe claim mismatch");
        require(address(probe.ve()) == ve, "DeployMineCoreImpl: probe ve mismatch");
        require(address(probe.royalties()) == royalties, "DeployMineCoreImpl: probe royalties mismatch");
        require(vm.revertTo(snap), "DeployMineCoreImpl: failed to revert preflight snapshot");
    }

    function _readAddressFn(address target, string memory sig) internal view returns (address out) {
        (bool ok, bytes memory data) = target.staticcall(abi.encodeWithSignature(sig));
        require(ok && data.length >= 32, string.concat("DeployMineCoreImpl: staticcall failed for ", sig));
        out = abi.decode(data, (address));
    }

    function _assertEnvMatches(string memory key, address expected) internal {
        try vm.envAddress(key) returns (address supplied) {
            if (supplied != address(0)) {
                require(supplied == expected, string.concat("DeployMineCoreImpl: env/chain mismatch for ", key));
            }
        } catch {}
    }

    function _manifestPath() internal view returns (string memory) {
        if (block.chainid == 8453) return "deployments/base_mainnet.json";
        if (block.chainid == 84532) return "deployments/base_sepolia.json";
        return "deployments/local.json";
    }

    function _requireContract(address target, string memory label) internal view {
        require(target.code.length > 0, string.concat("DeployMineCoreImpl: ", label, " is not a contract"));
    }
}
