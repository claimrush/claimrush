// SPDX-License-Identifier: MIT
pragma solidity ^0.8.34;

import {Script} from "forge-std/Script.sol";
import "forge-std/console2.sol";

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {Furnace} from "../src/Furnace.sol";
import {MineCore} from "../src/MineCore.sol";
import {Constants} from "../src/lib/Constants.sol";
import {LocalWETH} from "../src/mocks/LocalWETH.sol";

/// @dev Unused token-takeover challenger. See `_SmokeTakeoverEthChallenger` for the active helper.
contract _SmokeTakeoverChallenger {
    function takeover(MineCore mineCore, address tokenIn, uint256 amountIn, uint256 minEthOut) external {
        IERC20(tokenIn).approve(address(mineCore), amountIn);
        mineCore.takeoverWithToken(tokenIn, amountIn, minEthOut, type(uint256).max);
    }
}

/// @dev ETH takeover helper used when broadcaster is current king.
contract _SmokeTakeoverEthChallenger {
    function takeover(MineCore mineCore) external payable {
        mineCore.takeover{value: msg.value}(type(uint256).max);
    }
}

/// @notice Minimal local smoke against anvil for Path B.
/// @dev Requires pools to be seeded (see SeedLocalPathB).
///      The full lock + takeover smoke sequence is simulated before broadcast so
///      a late takeover revert cannot leave a partial local smoke mutation behind.
contract SmokeLocalPathB is Script {
    function run() external {
        require(block.chainid == 31337 || block.chainid == 1337, "SmokeLocalPathB: local chain only");

        // The Path B local flow uses LOCAL_PRIVATE_KEY.
        uint256 pk = vm.envUint("LOCAL_PRIVATE_KEY");
        address deployer = vm.addr(pk);

        string memory json = vm.readFile("deployments/local.json");

        // MineCore/Furnace have payable fallbacks, so cast via address payable.
        address payable mineCore = payable(vm.parseJsonAddress(json, ".contracts.MineCore.address"));
        address payable furnace = payable(vm.parseJsonAddress(json, ".contracts.Furnace.address"));
        address payable weth = payable(vm.parseJsonAddress(json, ".aerodrome.wrappedNative.address"));
        address entry = vm.parseJsonAddress(json, ".localDex.entryToken.address");

        // Preflight: stale deployments/local.json (or anvil restart) surfaces as EOAs with no code.
        require(mineCore.code.length > 0, "SmokeLocalPathB: MineCore has no code (stale deployments/local.json?)");
        require(furnace.code.length > 0, "SmokeLocalPathB: Furnace has no code (stale deployments/local.json?)");
        require(entry.code.length > 0, "SmokeLocalPathB: entryToken has no code (rerun local_path_b --deploy-core)");
        require(weth.code.length > 0, "SmokeLocalPathB: wrappedNative has no code (rerun local_path_b --deploy-core)");

        require(mineCore != address(0), "missing MineCore");
        require(furnace != address(0), "missing Furnace");
        require(weth != address(0), "missing WETH");
        require(entry != address(0), "missing entry token");

        console2.log("SmokeLocalPathB: simulating smoke sequence before broadcast...");
        _preflightSmokeSequence(mineCore, furnace, weth, deployer);
        console2.log("SmokeLocalPathB: preflight simulation passed.");

        vm.startBroadcast(pk);
        _executeSmokeSequence(mineCore, furnace, weth, deployer, true);
        vm.stopBroadcast();
    }

    function _preflightSmokeSequence(
        address payable mineCore,
        address payable furnace,
        address payable weth,
        address broadcaster
    ) internal {
        uint256 snap = vm.snapshot();
        vm.startPrank(broadcaster);
        _executeSmokeSequence(mineCore, furnace, weth, broadcaster, false);
        vm.stopPrank();
        require(vm.revertTo(snap), "SmokeLocalPathB: failed to revert preflight snapshot");
    }

    function _executeSmokeSequence(
        address payable mineCore,
        address payable furnace,
        address payable weth,
        address broadcaster,
        bool logActions
    ) internal {
        // Use a WETH amount the local CLAIM/WETH pool can fill.
        // Genesis seed ETH is proportional to genesis duration; on local (1 day)
        // the pool holds ~5 WETH, so 0.005 ETH is safe while still yielding
        // enough CLAIM (with bonus) to exceed MIN_LOCK_AMOUNT (1,000 CLAIM).
        uint256 lockIn = 0.005 ether;
        uint256 duration = Constants.MAX_LOCK_DURATION;
        require(broadcaster.balance >= lockIn, "SmokeLocalPathB: broadcaster balance below WETH lock amount");

        // 1) Furnace: WETH path (WETH -> ETH -> CLAIM)
        // Avoid the Entry->CLAIM route here: on repeated local runs the mock Entry/CLAIM pool can
        // become slightly underfunded and revert with InsufficientLiquidity().
        LocalWETH(weth).deposit{value: lockIn}();
        IERC20(weth).approve(address(furnace), type(uint256).max);
        Furnace(furnace).enterWithToken{gas: 5_000_000}(address(weth), lockIn, 0, duration, true, 1);

        // 2) MineCore: takeover via ETH (no DEX liquidity dependency).
        MineCore mc = MineCore(mineCore);
        uint256 price = mc.getCurrentTakeoverPrice();
        require(broadcaster.balance >= price, "SmokeLocalPathB: broadcaster balance below takeover price");
        address king = mc.currentKing();
        if (king == broadcaster && king != address(0)) {
            if (logActions) {
                console2.log("SmokeLocalPathB: deployer is already currentKing, taking over with a challenger contract");
            }
            _SmokeTakeoverEthChallenger challenger = new _SmokeTakeoverEthChallenger();
            if (logActions) console2.log("TakeoverEthChallenger", address(challenger));
            challenger.takeover{gas: 5_000_000, value: price}(mc);
            require(
                mc.currentKing() == address(challenger), "SmokeLocalPathB: challenger takeover did not install new king"
            );
        } else {
            mc.takeover{gas: 5_000_000, value: price}(type(uint256).max);
            require(
                mc.currentKing() == broadcaster, "SmokeLocalPathB: ETH takeover did not install broadcaster as king"
            );
        }
    }
}
