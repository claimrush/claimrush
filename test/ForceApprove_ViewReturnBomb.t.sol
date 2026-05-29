// SPDX-License-Identifier: MIT
pragma solidity ^0.8.34;

import {Test} from "forge-std/Test.sol";

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {SafeERC20View} from "src/lib/SafeERC20View.sol";
import {SafeApprove} from "src/lib/SafeApprove.sol";
import {MarketRouter} from "src/MarketRouter.sol";
import {LpStakingVault7D} from "src/vault/LpStakingVault7D.sol";
import {ClaimToken} from "src/ClaimToken.sol";
import {VeClaimNFT} from "src/VeClaimNFT.sol";
import {ShareholderRoyalties} from "src/ShareholderRoyalties.sol";

import {MockViewReturnToken} from "./mocks/MockViewReturnToken.sol";
import {MockContract} from "./mocks/MockContract.sol";
import {MockERC20} from "./mocks/MockERC20.sol";
import {MockAerodromePool} from "./mocks/MockAerodromePool.sol";
import {MockAerodromeRouter} from "./mocks/MockAerodromeRouter.sol";
import {MockVe} from "./mocks/MockVe.sol";

contract MarketRouterHarness is MarketRouter {
    constructor(address claim_, address ve_, address royalties_, address initialOwner)
        MarketRouter(claim_, ve_, royalties_, initialOwner)
    {}

    function exposedForceApprove(IERC20 token, address spender, uint256 value) external {
        SafeApprove.forceApprove(token, spender, value);
    }
}

contract LpStakingVault7DHarness is LpStakingVault7D {
    constructor(
        address _lpToken,
        address _weth,
        address _claim,
        address _ve,
        address _furnace,
        address _aerodromeRouter,
        address _aerodromeFactory,
        bool _wethClaimStable,
        address initialOwner
    )
        LpStakingVault7D(
            _lpToken, _weth, _claim, _ve, _furnace, _aerodromeRouter, _aerodromeFactory, _wethClaimStable, initialOwner
        )
    {}

    function exposedForceApprove(IERC20 token, address spender, uint256 value) external {
        _forceApprove(token, spender, value);
    }
}

contract MockFurnaceRootsView {
    address public claim;
    address public ve;

    constructor(address claim_, address ve_) {
        claim = claim_;
        ve = ve_;
    }
}

contract ForceApproveViewReturnBombTest is Test {
    MockViewReturnToken internal token;

    MarketRouterHarness internal mr;
    LpStakingVault7DHarness internal vault;

    address internal spender = address(0xBEEF);

    function setUp() public {
        token = new MockViewReturnToken();

        // MarketRouter constructor hardening requires canonical root relationships.
        ClaimToken claimRoot = new ClaimToken(address(this));
        VeClaimNFT veRoot = new VeClaimNFT(address(claimRoot), address(this));
        ShareholderRoyalties royaltiesRoot = new ShareholderRoyalties(address(veRoot), address(this));
        mr = new MarketRouterHarness(address(claimRoot), address(veRoot), address(royaltiesRoot), address(this));

        // LpStakingVault harness requires real constructor params but we only use _forceApprove.
        MockERC20 weth = new MockERC20("WETH", "WETH");
        MockERC20 claim = new MockERC20("CLAIM", "CLAIM");
        MockAerodromePool lp = new MockAerodromePool(address(weth), address(claim));
        MockVe ve = new MockVe();
        MockAerodromeRouter router = new MockAerodromeRouter(address(0xFACADE), address(weth));
        router.setPoolFor(address(weth), address(claim), false, address(0xFACADE), address(lp));
        MockFurnaceRootsView furnace = new MockFurnaceRootsView(address(claim), address(ve));

        vault = new LpStakingVault7DHarness(
            address(lp),
            address(weth),
            address(claim),
            address(ve),
            address(furnace),
            address(router),
            address(0xFACADE),
            false,
            address(this)
        );
    }

    function testMarketRouter_forceApprove_AllowsLargeAllowanceReturn_NoOOG() public {
        token.setReturnSize(262_144);
        token.setAllowanceMode(MockViewReturnToken.Mode.ReturnLarge);

        (bool ok,) = address(mr).call{gas: 200_000}(
            abi.encodeWithSelector(
                MarketRouterHarness.exposedForceApprove.selector, IERC20(address(token)), spender, 123
            )
        );
        assertTrue(ok);

        (uint256 a, bool aOk) = SafeERC20View.callAllowance(IERC20(address(token)), address(mr), spender);
        assertTrue(aOk);
        assertEq(a, 123);
    }

    function testLpStakingVault_forceApprove_AllowsRevertLargeAllowance_NoOOG() public {
        token.setReturnSize(262_144);
        token.setAllowanceMode(MockViewReturnToken.Mode.RevertLarge);

        (bool ok,) = address(vault).call{gas: 200_000}(
            abi.encodeWithSelector(
                LpStakingVault7DHarness.exposedForceApprove.selector, IERC20(address(token)), spender, 456
            )
        );
        assertTrue(ok);

        // Switch back to a normal return mode so we can assert the value.
        token.setAllowanceMode(MockViewReturnToken.Mode.ReturnNormal32);

        (uint256 a, bool aOk) = SafeERC20View.callAllowance(IERC20(address(token)), address(vault), spender);
        assertTrue(aOk);
        assertEq(a, 456);
    }
}
