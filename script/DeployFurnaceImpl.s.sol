// SPDX-License-Identifier: MIT
pragma solidity ^0.8.34;

import {console2} from "forge-std/Script.sol";
import {BroadcastSignerBase} from "./lib/BroadcastSignerBase.sol";

import {Furnace} from "../src/Furnace.sol";
import {FurnaceGuardHelper} from "../src/FurnaceGuardHelper.sol";

/// @notice Deploy the v1.0.0 Furnace implementation at the same CLAIM/ve
///         wiring roots as the live proxy, alongside the FurnaceGuardHelper it
///         pins as a construction-time immutable. Does NOT call upgradeAndCall
///         on the proxy admin — that step is a separate Timelock batch
///         (`script/TimelockRuntimeUpgrade.s.sol`) so the two actions have
///         independent blast radii.
///
/// @dev The Furnace constructor takes the guard-helper address and self-deploys
///      the extend-body helper (`FurnaceExtendHelper`), so a single broadcast
///      lands the full impl trio (Furnace impl + FurnaceGuardHelper +
///      FurnaceExtendHelper). The FurnaceGuardHelper is canonical-bound to the
///      same CLAIM/ve roots and does not pin a Furnace address, so it is reused
///      transparently under the proxy's delegatecall context after upgrade.
///
///      Wiring roots (claim / ve) are resolved from the live Furnace proxy via
///      staticcall against the current RPC, then cross-checked against the
///      deployments manifest. An env/manifest mismatch fails closed before any
///      broadcast.
///
///      Optional preflight guard: set `EXPECTED_CURRENT_IMPL` to the address
///      currently installed under EIP-1967 IMPL_SLOT on the proxy to assert the
///      operator is replacing the intended implementation. If unset the check
///      is skipped (useful on local / sepolia dry-runs).
///
///      Run:
///        FURNACE=0x... \
///        SIGNER_ADDRESS=0x... \
///        forge script script/DeployFurnaceImpl.s.sol:DeployFurnaceImpl \
///          --rpc-url $RPC --broadcast --verify \
///          --etherscan-api-key $BASESCAN_API_KEY \
///          --private-key $PRIVATE_KEY --sender $SIGNER_ADDRESS
contract DeployFurnaceImpl is BroadcastSignerBase {
    bytes32 internal constant IMPL_SLOT = 0x360894a13ba1a3210667c828492db98dca3e2076cc3735a920a3ca505d382bbc;

    function run() external {
        require(
            block.chainid == 8453 || block.chainid == 84532 || block.chainid == 31337 || block.chainid == 1337,
            "DeployFurnaceImpl: unsupported chainId"
        );

        address furnaceProxy = vm.envAddress("FURNACE");
        require(furnaceProxy != address(0), "DeployFurnaceImpl: FURNACE env required");
        _requireContract(furnaceProxy, "FURNACE");

        if (block.chainid == 8453 || block.chainid == 84532) {
            string memory json = vm.readFile(_manifestPath());
            address manifestProxy = vm.parseJsonAddress(json, ".contracts.Furnace.address");
            require(manifestProxy == furnaceProxy, "DeployFurnaceImpl: FURNACE env does not match deployments manifest");
        }

        address claim = _readAddressFn(furnaceProxy, "claim()");
        address ve = _readAddressFn(furnaceProxy, "ve()");

        require(claim != address(0), "DeployFurnaceImpl: proxy returned zero CLAIM");
        require(ve != address(0), "DeployFurnaceImpl: proxy returned zero VE");
        _requireContract(claim, "CLAIM");
        _requireContract(ve, "VE");

        _assertEnvMatches("CLAIM", claim);
        _assertEnvMatches("VE", ve);

        address currentImpl = address(uint160(uint256(vm.load(furnaceProxy, IMPL_SLOT))));
        _requireContract(currentImpl, "CURRENT_IMPL");
        _assertEnvMatches("EXPECTED_CURRENT_IMPL", currentImpl);

        BroadcastSigner memory signer = _resolveBroadcastSigner();

        console2.log("DeployFurnaceImpl: chainId       ", block.chainid);
        console2.log("DeployFurnaceImpl: Furnace proxy ", furnaceProxy);
        console2.log("DeployFurnaceImpl: current impl  ", currentImpl);
        console2.log("DeployFurnaceImpl: claim root    ", claim);
        console2.log("DeployFurnaceImpl: ve root       ", ve);
        console2.log("DeployFurnaceImpl: signer        ", signer.account);

        _preflightConstruct(claim, ve);

        vm.stopPrank();
        _startBroadcast(signer);

        FurnaceGuardHelper guardHelper = new FurnaceGuardHelper(claim, ve);
        Furnace impl = new Furnace(claim, ve, address(guardHelper), address(0));

        vm.stopBroadcast();

        require(address(impl.claim()) == claim, "DeployFurnaceImpl: impl claim mismatch");
        require(address(impl.ve()) == ve, "DeployFurnaceImpl: impl ve mismatch");
        require(impl.extendHelper() != address(0), "DeployFurnaceImpl: impl extendHelper unset");

        console2.log("DeployFurnaceImpl: NEW_IMPL        ", address(impl));
        console2.log("DeployFurnaceImpl: guardHelper     ", address(guardHelper));
        console2.log("DeployFurnaceImpl: extendHelper    ", impl.extendHelper());
        console2.log(
            "DeployFurnaceImpl: next step -> TimelockRuntimeUpgrade with FURNACE_NEW_IMPLEMENTATION=<NEW_IMPL>"
        );
    }

    function _preflightConstruct(address claim, address ve) internal {
        uint256 snap = vm.snapshot();
        FurnaceGuardHelper probeHelper = new FurnaceGuardHelper(claim, ve);
        Furnace probe = new Furnace(claim, ve, address(probeHelper), address(0));
        require(address(probe.claim()) == claim, "DeployFurnaceImpl: probe claim mismatch");
        require(address(probe.ve()) == ve, "DeployFurnaceImpl: probe ve mismatch");
        require(probe.extendHelper() != address(0), "DeployFurnaceImpl: probe extendHelper unset");
        require(vm.revertTo(snap), "DeployFurnaceImpl: failed to revert preflight snapshot");
    }

    function _readAddressFn(address target, string memory sig) internal view returns (address out) {
        (bool ok, bytes memory data) = target.staticcall(abi.encodeWithSignature(sig));
        require(ok && data.length >= 32, string.concat("DeployFurnaceImpl: staticcall failed for ", sig));
        out = abi.decode(data, (address));
    }

    function _assertEnvMatches(string memory key, address expected) internal {
        try vm.envAddress(key) returns (address supplied) {
            if (supplied != address(0)) {
                require(supplied == expected, string.concat("DeployFurnaceImpl: env/chain mismatch for ", key));
            }
        } catch {}
    }

    function _manifestPath() internal view returns (string memory) {
        if (block.chainid == 8453) return "deployments/base_mainnet.json";
        if (block.chainid == 84532) return "deployments/base_sepolia.json";
        return "deployments/local.json";
    }

    function _requireContract(address target, string memory label) internal view {
        require(target.code.length > 0, string.concat("DeployFurnaceImpl: ", label, " is not a contract"));
    }
}
