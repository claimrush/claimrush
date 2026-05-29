// SPDX-License-Identifier: MIT
pragma solidity ^0.8.34;

import {Script, console2} from "forge-std/Script.sol";

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {MineCore} from "../src/MineCore.sol";

contract KingProxy {
    function takeover(address mineCore) external payable {
        MineCore(payable(mineCore)).takeover{value: msg.value}(type(uint256).max);
    }

    function sweep(address token, address to) external {
        uint256 bal = IERC20(token).balanceOf(address(this));
        if (bal == 0) return;
        require(IERC20(token).transfer(to, bal), "KingProxy: TRANSFER_FAILED");
    }
}

/// @notice Local-only helper: perform the first takeover to start king emission accrual.
/// @dev This script deploys a KingProxy and makes it the current king.
///      After running this, advance time by a few seconds and then run SeedLocalPathB
///      with LOCAL_KING_PROXY set to the deployed KingProxy address (see broadcast output).
///      The full bootstrap sequence is simulated before broadcast so a later takeover revert
///      cannot leave a stray KingProxy deployment onchain.
contract StartLocalPathBAccrual is Script {
    function run() external {
        require(block.chainid == 31337 || block.chainid == 1337, "StartLocalPathBAccrual: local chain only");

        uint256 pk = vm.envUint("LOCAL_PRIVATE_KEY");
        address broadcaster = vm.addr(pk);
        string memory json = vm.readFile("deployments/local.json");
        address mineCore = vm.parseJsonAddress(json, ".contracts.MineCore.address");
        _requireDeployed(mineCore, "MineCore");

        console2.log("StartLocalPathBAccrual: simulating bootstrap before broadcast...");
        _preflightAccrualSequence(mineCore, broadcaster);
        console2.log("StartLocalPathBAccrual: preflight simulation passed.");

        vm.startBroadcast(pk);
        _executeAccrualSequence(mineCore, broadcaster, true);
        vm.stopBroadcast();
    }

    function _preflightAccrualSequence(address mineCore, address broadcaster) internal {
        uint256 snap = vm.snapshot();
        vm.startPrank(broadcaster);
        _executeAccrualSequence(mineCore, broadcaster, false);
        vm.stopPrank();
        require(vm.revertTo(snap), "StartLocalPathBAccrual: failed to revert preflight snapshot");
    }

    function _executeAccrualSequence(address mineCore, address broadcaster, bool logActions) internal {
        MineCore mineCoreC = MineCore(payable(mineCore));
        require(!mineCoreC.takeoversPaused(), "StartLocalPathBAccrual: takeovers paused (finalize genesis first)");

        uint256 p1 = mineCoreC.getCurrentTakeoverPrice();
        require(broadcaster.balance >= p1, "StartLocalPathBAccrual: broadcaster balance below takeover price");

        KingProxy king = new KingProxy();
        if (logActions) console2.log("KingProxy", address(king));

        // Takeover at the live price (first takeover after genesis).
        king.takeover{value: p1}(mineCore);
        require(
            mineCoreC.currentKing() == address(king), "StartLocalPathBAccrual: KingProxy not installed as current king"
        );
    }

    function _requireDeployed(address a, string memory what) internal view {
        require(a != address(0), string.concat("StartLocalPathBAccrual: missing ", what));
        require(a.code.length > 0, string.concat("StartLocalPathBAccrual: no code at ", what));
    }
}
