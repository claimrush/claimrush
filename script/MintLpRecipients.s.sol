// SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

import {Script, console2} from "forge-std/Script.sol";
import {stdJson} from "forge-std/StdJson.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

interface IWETH is IERC20 {
    function deposit() external payable;
}

interface IDexAdapter {
    struct Route {
        address from;
        address to;
        bool stable;
        address factory;
    }
    function swapExactETHForTokens(uint256 amountOutMin, Route[] calldata routes, address to, uint256 deadline)
        external
        payable
        returns (uint256[] memory);
}

interface ITestnetPool is IERC20 {
    function token0() external view returns (address);
    function token1() external view returns (address);
    function mint(address to) external returns (uint256 liquidity);
}

/// @notice Sepolia-only helper: top up deployer CLAIM via DexAdapter, then mint matched
///         LP to two recipients on the TestnetSwapPool. Targets May-17 rehearsal scale
///         (50 LP to deployer, 20 LP to the 1st-takeover owner).
///
///         Uniswap-v2-style ratio-aware mint: transfers matched (CLAIM, WETH) into the
///         pool per current reserves, then calls pool.mint(recipient). Excess donations
///         (if any) are silently absorbed by the existing LP holders -- avoided here by
///         computing matched amounts to wei precision.
contract MintLpRecipients is Script {
    using stdJson for string;
    using SafeERC20 for IERC20;

    uint256 internal constant LP_DEPLOYER_TARGET = 50e18; // 50 LP
    uint256 internal constant LP_TAKEOVER_TARGET = 20e18; // 20 LP

    function run() external {
        require(block.chainid == 84532, "Base Sepolia only");

        uint256 pk = vm.envUint("PRIVATE_KEY");
        address deployer = vm.addr(pk);
        address takeoverOwner = vm.envAddress("TAKEOVER_OWNER");

        string memory json = vm.readFile("deployments/base_sepolia.json");
        address claim = json.readAddress(".contracts.ClaimToken.address");
        address weth = json.readAddress(".aerodrome.wrappedNative.address");
        address pool = json.readAddress(".aerodrome.lpToken.address");
        address dexAdapter = json.readAddress(".contracts.DexAdapter.address");
        address poolFactory = json.readAddress(".aerodrome.poolFactory.address");

        console2.log("deployer        :", deployer);
        console2.log("takeoverOwner   :", takeoverOwner);
        console2.log("CLAIM           :", claim);
        console2.log("WETH            :", weth);
        console2.log("Pool            :", pool);

        ITestnetPool p = ITestnetPool(pool);
        address t0 = p.token0();
        address t1 = p.token1();
        require((t0 == claim && t1 == weth) || (t0 == weth && t1 == claim), "pool tokens mismatch");
        bool claimIsToken0 = (t0 == claim);

        vm.startBroadcast(pk);

        // --- Step 1: ensure the deployer has WETH for both LP mints (estimate 0.20 WETH cap).
        IWETH(weth).deposit{value: 0.2 ether}();
        console2.log("WETH wrapped  :", IERC20(weth).balanceOf(deployer));

        // --- Step 2: top up CLAIM via DexAdapter (matches SmokeSepolia._acquireClaim path).
        //     Use 0.15 ETH -> roughly 88k CLAIM at current ratio (591k CLAIM per WETH).
        IDexAdapter.Route[] memory routes = new IDexAdapter.Route[](1);
        routes[0] = IDexAdapter.Route({from: weth, to: claim, stable: false, factory: poolFactory});
        IDexAdapter(dexAdapter).swapExactETHForTokens{value: 0.15 ether}(1, routes, deployer, type(uint256).max);
        console2.log("CLAIM after top-up:", IERC20(claim).balanceOf(deployer));

        // --- Step 3: read fresh pool state AFTER the top-up swap moved reserves.
        uint256 ts = p.totalSupply();
        uint256 balClaim = IERC20(claim).balanceOf(pool);
        uint256 balWeth = IERC20(weth).balanceOf(pool);
        console2.log("pool totalSupply :", ts);
        console2.log("pool CLAIM bal   :", balClaim);
        console2.log("pool WETH bal    :", balWeth);

        // --- Step 4: mint 50 LP to deployer (matched deposit, +1 wei to guard rounding floor).
        _mintLp(p, claim, weth, ts, balClaim, balWeth, deployer, LP_DEPLOYER_TARGET, claimIsToken0);

        // --- Step 5: re-read reserves and mint 20 LP to takeover owner.
        ts = p.totalSupply();
        balClaim = IERC20(claim).balanceOf(pool);
        balWeth = IERC20(weth).balanceOf(pool);
        _mintLp(p, claim, weth, ts, balClaim, balWeth, takeoverOwner, LP_TAKEOVER_TARGET, claimIsToken0);

        vm.stopBroadcast();

        // --- Step 6: final read-back outside the broadcast (no tx).
        console2.log("--- final ---");
        console2.log("deployer LP   :", p.balanceOf(deployer));
        console2.log("takeover LP   :", p.balanceOf(takeoverOwner));
        console2.log("deployer CLAIM:", IERC20(claim).balanceOf(deployer));
        console2.log("deployer WETH :", IERC20(weth).balanceOf(deployer));
    }

    function _mintLp(
        ITestnetPool p,
        address claim,
        address weth,
        uint256 ts,
        uint256 balClaim,
        uint256 balWeth,
        address recipient,
        uint256 lpTarget,
        bool /*claimIsToken0*/
    ) internal {
        // Compute matched (CLAIM, WETH) for exactly lpTarget LP, with +1 wei nudge on
        // the WETH side to guarantee min(liq0, liq1) >= lpTarget after integer division.
        uint256 claimAmt = (lpTarget * balClaim + ts - 1) / ts; // round up
        uint256 wethAmt = (lpTarget * balWeth + ts - 1) / ts;
        claimAmt += 1;
        wethAmt += 1;

        console2.log("--- mint to recipient ---");
        console2.log("recipient   :", recipient);
        console2.log("LP target   :", lpTarget);
        console2.log("CLAIM xfer  :", claimAmt);
        console2.log("WETH xfer   :", wethAmt);

        IERC20(claim).safeTransfer(address(p), claimAmt);
        IERC20(weth).safeTransfer(address(p), wethAmt);
        uint256 minted = p.mint(recipient);
        require(minted >= lpTarget, "minted < target");
        console2.log("LP minted   :", minted);
    }
}
