// SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

import {Script, console2} from "forge-std/Script.sol";
import {stdJson} from "forge-std/StdJson.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

interface ITestnetPool is IERC20 {
    function token0() external view returns (address);
    function token1() external view returns (address);
    function mint(address to) external returns (uint256 liquidity);
}

/// @notice Sepolia-only helper: mint LP to a single recipient using the deployer's
///         existing CLAIM + WETH balances. Matched-deposit ratio computed against
///         current reserves; +1 wei nudge guarantees min(liq0, liq1) >= LP_AMOUNT.
///
/// Env:
///   PRIVATE_KEY   deployer (or anyone with CLAIM + WETH)
///   RECIPIENT     LP target address
///   LP_AMOUNT     LP units (1e18 = 1 LP)
contract MintLpSingle is Script {
    using stdJson for string;
    using SafeERC20 for IERC20;

    function run() external {
        require(block.chainid == 84532, "Base Sepolia only");

        uint256 pk = vm.envUint("PRIVATE_KEY");
        address signer = vm.addr(pk);
        address recipient = vm.envAddress("RECIPIENT");
        uint256 lpTarget = vm.envUint("LP_AMOUNT");

        string memory json = vm.readFile("deployments/base_sepolia.json");
        address claim = json.readAddress(".contracts.ClaimToken.address");
        address weth = json.readAddress(".aerodrome.wrappedNative.address");
        address pool = json.readAddress(".aerodrome.lpToken.address");

        ITestnetPool p = ITestnetPool(pool);

        uint256 ts = p.totalSupply();
        uint256 balClaim = IERC20(claim).balanceOf(pool);
        uint256 balWeth = IERC20(weth).balanceOf(pool);

        uint256 claimAmt = (lpTarget * balClaim + ts - 1) / ts + 1;
        uint256 wethAmt = (lpTarget * balWeth + ts - 1) / ts + 1;

        console2.log("signer       :", signer);
        console2.log("recipient    :", recipient);
        console2.log("LP target    :", lpTarget);
        console2.log("CLAIM xfer   :", claimAmt);
        console2.log("WETH xfer    :", wethAmt);
        console2.log("pool ts      :", ts);

        require(IERC20(claim).balanceOf(signer) >= claimAmt, "insufficient CLAIM");
        require(IERC20(weth).balanceOf(signer) >= wethAmt, "insufficient WETH");

        vm.startBroadcast(pk);
        IERC20(claim).safeTransfer(pool, claimAmt);
        IERC20(weth).safeTransfer(pool, wethAmt);
        uint256 minted = p.mint(recipient);
        vm.stopBroadcast();

        require(minted >= lpTarget, "minted < target");
        console2.log("LP minted    :", minted);
        console2.log("recipient LP :", p.balanceOf(recipient));
    }
}
