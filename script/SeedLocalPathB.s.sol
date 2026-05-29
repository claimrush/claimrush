// SPDX-License-Identifier: MIT
pragma solidity ^0.8.34;

import {Script, console2} from "forge-std/Script.sol";

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {MineCore} from "../src/MineCore.sol";
import {LocalWETH} from "../src/mocks/LocalWETH.sol";
import {MintableERC20} from "../src/mocks/MintableERC20.sol";

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

struct Addrs {
    address mineCore;
    address claim;
    address weth;
    address entry;
    address claimWethPool;
    address entryWethPool;
    address entryClaimPool;
}

/// @notice Path B helper: completes a 2nd takeover, collects accrued CLAIM, and seeds local pools.
/// @dev Assumes:
/// - genesis has been finalized (takeovers unpaused)
/// - StartLocalPathBAccrual has run to set KingProxy as current king
/// - anvil time has advanced a few seconds since KingProxy takeover (so CLAIM accrues)
///
///      The full seed sequence is simulated before broadcast so a late revert cannot leave
///      a partially-funded local liquidity topology.
contract SeedLocalPathB is Script {
    function run() external {
        // Safety: local-only helper.
        require(block.chainid == 31337 || block.chainid == 1337, "SeedLocalPathB: local chain only");

        uint256 pk = vm.envUint("LOCAL_PRIVATE_KEY");
        address deployer = vm.addr(pk);

        string memory json = vm.readFile("deployments/local.json");

        Addrs memory a;
        a.mineCore = vm.parseJsonAddress(json, ".contracts.MineCore.address");
        a.claim = vm.parseJsonAddress(json, ".contracts.ClaimToken.address");
        a.weth = vm.parseJsonAddress(json, ".aerodrome.wrappedNative.address");
        a.entry = vm.parseJsonAddress(json, ".localDex.entryToken.address");
        a.claimWethPool = vm.parseJsonAddress(json, ".aerodrome.claimWethPool.address");
        a.entryWethPool = vm.parseJsonAddress(json, ".localDex.pools.entryWeth.address");
        a.entryClaimPool = vm.parseJsonAddress(json, ".localDex.pools.entryClaim.address");

        _requireDeployed(a.mineCore, "MineCore");
        _requireDeployed(a.claim, "ClaimToken");
        _requireDeployed(a.weth, "wrappedNative");
        _requireDeployed(a.entry, "localDex.entryToken");
        _requireDeployed(a.claimWethPool, "aerodrome.claimWethPool");
        _requireDeployed(a.entryWethPool, "localDex.pools.entryWeth");
        _requireDeployed(a.entryClaimPool, "localDex.pools.entryClaim");

        console2.log("SeedLocalPathB: simulating full seed sequence before broadcast...");
        _preflightSeedSequence(a, deployer);
        console2.log("SeedLocalPathB: preflight simulation passed.");

        vm.startBroadcast(pk);
        _executeSeedSequence(a, deployer);
        vm.stopBroadcast();
    }

    function _preflightSeedSequence(Addrs memory a, address deployer) internal {
        uint256 snap = vm.snapshot();
        vm.startPrank(deployer);
        _executeSeedSequence(a, deployer);
        vm.stopPrank();
        require(vm.revertTo(snap), "SeedLocalPathB: failed to revert preflight snapshot");
    }

    function _executeSeedSequence(Addrs memory a, address deployer) internal {
        MineCore mineCoreC = MineCore(payable(a.mineCore));

        // If we already ran once, the script transfers CLAIM into pools, leaving the deployer with 0.
        // In that case, treat as no-op iff pools look funded.
        bool localPoolsFunded = _localPoolsFunded(a);
        if (IERC20(a.claim).balanceOf(deployer) == 0 && localPoolsFunded) {
            return;
        }

        // Acquire some CLAIM for seeding by dethroning the deterministic KingProxy.
        uint256 claimBal = IERC20(a.claim).balanceOf(deployer);
        if (claimBal == 0) {
            require(!mineCoreC.takeoversPaused(), "SeedLocalPathB: takeovers still paused");

            address king = vm.envAddress("LOCAL_KING_PROXY");
            require(king != address(0) && king.code.length > 0, "SeedLocalPathB: LOCAL_KING_PROXY not set/deployed");
            require(
                mineCoreC.currentKing() == king,
                "SeedLocalPathB: KingProxy is not current king (run StartLocalPathBAccrual)"
            );

            // Takeover at the live price (this should mint accrued CLAIM to the previous king = KingProxy).
            uint256 p2 = mineCoreC.getCurrentTakeoverPrice();
            mineCoreC.takeover{value: p2}(type(uint256).max);
            KingProxy(payable(king)).sweep(a.claim, deployer);

            claimBal = IERC20(a.claim).balanceOf(deployer);
            require(
                claimBal > 0,
                "SeedLocalPathB: no CLAIM accrued (advance time a few seconds after StartLocalPathBAccrual)"
            );
        }

        // 3) Mint entry token supply to deployer.
        uint256 entryMint = 1_000_000 ether;
        MintableERC20(a.entry).mint(deployer, entryMint);

        // 4) Wrap some ETH into WETH for pool liquidity.
        uint256 wethForPools = 100 ether;
        LocalWETH(payable(a.weth)).deposit{value: wethForPools}();

        // 5) Seed pools.
        //
        // If genesis finalization already minted LP into the CLAIM/WETH pool, do not "seed" it by raw transfers.
        // Instead, only seed the fully-local pools used by Path B takeover routing.
        bool claimWethPoolActive = IERC20(a.claimWethPool).totalSupply() > 0;

        if (!claimWethPoolActive) {
            // Split CLAIM across the two pools that need it.
            uint256 claimToClaimWeth = claimBal / 2;
            uint256 claimToEntryClaim = claimBal - claimToClaimWeth;

            require(IERC20(a.claim).transfer(a.claimWethPool, claimToClaimWeth), "CLAIM_TRANSFER_FAILED");
            require(IERC20(a.claim).transfer(a.entryClaimPool, claimToEntryClaim), "CLAIM_TRANSFER_FAILED");

            // Split WETH across the pools that output WETH.
            uint256 wethToClaimWeth = wethForPools / 2;
            uint256 wethToEntryWeth = wethForPools - wethToClaimWeth;

            require(IERC20(a.weth).transfer(a.claimWethPool, wethToClaimWeth), "WETH_TRANSFER_FAILED");
            require(IERC20(a.weth).transfer(a.entryWethPool, wethToEntryWeth), "WETH_TRANSFER_FAILED");
        } else {
            // All CLAIM goes to ENTRY/CLAIM; all WETH goes to ENTRY/WETH.
            require(IERC20(a.claim).transfer(a.entryClaimPool, claimBal), "CLAIM_TRANSFER_FAILED");
            require(IERC20(a.weth).transfer(a.entryWethPool, wethForPools), "WETH_TRANSFER_FAILED");
        }

        // Split entry token across the pools that output entry token.
        uint256 entryToEntryWeth = entryMint / 2;
        uint256 entryToEntryClaim = entryMint - entryToEntryWeth;

        require(IERC20(a.entry).transfer(a.entryWethPool, entryToEntryWeth), "ENTRY_TRANSFER_FAILED");
        require(IERC20(a.entry).transfer(a.entryClaimPool, entryToEntryClaim), "ENTRY_TRANSFER_FAILED");

        require(
            IERC20(a.entry).balanceOf(a.entryWethPool) > 0, "SeedLocalPathB: entry/WETH pool missing entry liquidity"
        );
        require(IERC20(a.weth).balanceOf(a.entryWethPool) > 0, "SeedLocalPathB: entry/WETH pool missing WETH liquidity");
        require(
            IERC20(a.entry).balanceOf(a.entryClaimPool) > 0, "SeedLocalPathB: entry/CLAIM pool missing entry liquidity"
        );
        require(
            IERC20(a.claim).balanceOf(a.entryClaimPool) > 0, "SeedLocalPathB: entry/CLAIM pool missing CLAIM liquidity"
        );
        if (!claimWethPoolActive) {
            require(
                IERC20(a.claim).balanceOf(a.claimWethPool) > 0,
                "SeedLocalPathB: CLAIM/WETH pool missing CLAIM liquidity"
            );
            require(
                IERC20(a.weth).balanceOf(a.claimWethPool) > 0, "SeedLocalPathB: CLAIM/WETH pool missing WETH liquidity"
            );
        }
    }

    function _localPoolsFunded(Addrs memory a) internal view returns (bool) {
        return IERC20(a.entry).balanceOf(a.entryWethPool) > 0 && IERC20(a.weth).balanceOf(a.entryWethPool) > 0
            && IERC20(a.entry).balanceOf(a.entryClaimPool) > 0 && IERC20(a.claim).balanceOf(a.entryClaimPool) > 0;
    }

    function _requireDeployed(address a, string memory what) internal view {
        require(a != address(0), string.concat("SeedLocalPathB: missing ", what));
        require(a.code.length > 0, string.concat("SeedLocalPathB: no code at ", what));
    }
}
