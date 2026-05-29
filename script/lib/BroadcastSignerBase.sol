// SPDX-License-Identifier: MIT
pragma solidity ^0.8.34;

import {Script} from "forge-std/Script.sol";

/// @notice Shared signer resolution for forge scripts that must support both
///         env-backed private keys and hardware-wallet broadcasts.
/// @dev Resolution order:
///      - local chains: prefer LOCAL_PRIVATE_KEY, fallback to PRIVATE_KEY
///      - non-local chains: prefer SIGNER_ADDRESS / LEDGER_ADDRESS, fallback to PRIVATE_KEY
///      Ledger mode still requires the CLI to provide the signer, e.g.
///      `forge script ... --ledger --sender $LEDGER_ADDRESS --broadcast`.
abstract contract BroadcastSignerBase is Script {
    struct BroadcastSigner {
        address account;
        uint256 privateKey;
        bool usePrivateKey;
    }

    function _isLocalChain() internal view returns (bool) {
        return block.chainid == 31337 || block.chainid == 1337;
    }

    function _resolveBroadcastSigner() internal returns (BroadcastSigner memory signer) {
        if (_isLocalChain()) {
            uint256 pk = _tryEnvUintOrZero("LOCAL_PRIVATE_KEY");
            if (pk == 0) pk = _tryEnvUintOrZero("PRIVATE_KEY");
            require(pk != 0, "BroadcastSigner: missing local/private key");
            signer.account = vm.addr(pk);
            signer.privateKey = pk;
            signer.usePrivateKey = true;
            return signer;
        }

        address explicitSigner = _tryEnvAddressOrZero("SIGNER_ADDRESS");
        if (explicitSigner == address(0)) {
            explicitSigner = _tryEnvAddressOrZero("LEDGER_ADDRESS");
        }

        uint256 pk = _tryEnvUintOrZero("PRIVATE_KEY");
        if (explicitSigner != address(0)) {
            if (pk != 0) {
                require(vm.addr(pk) == explicitSigner, "BroadcastSigner: SIGNER_ADDRESS/PRIVATE_KEY mismatch");
            }
            signer.account = explicitSigner;
            signer.privateKey = pk;
            signer.usePrivateKey = pk != 0;
            return signer;
        }

        require(pk != 0, "BroadcastSigner: missing SIGNER_ADDRESS/LEDGER_ADDRESS or PRIVATE_KEY");
        signer.account = vm.addr(pk);
        signer.privateKey = pk;
        signer.usePrivateKey = true;
    }

    function _startBroadcast(BroadcastSigner memory signer) internal {
        vm.stopPrank();
        if (signer.usePrivateKey) {
            vm.startBroadcast(signer.privateKey);
        } else {
            vm.startBroadcast(signer.account);
        }
    }

    function _tryEnvUintOrZero(string memory key) internal returns (uint256 out) {
        try vm.envUint(key) returns (uint256 v) {
            out = v;
        } catch {
            out = 0;
        }
    }

    function _tryEnvAddressOrZero(string memory key) internal returns (address out) {
        try vm.envAddress(key) returns (address v) {
            out = v;
        } catch {
            out = address(0);
        }
    }
}
