// SPDX-License-Identifier: MIT
pragma solidity ^0.8.34;

import {Test} from "forge-std/Test.sol";

import {ClaimToken} from "src/ClaimToken.sol";
import {EntryTokenRegistry} from "src/EntryTokenRegistry.sol";
import {Furnace} from "src/Furnace.sol";
import {FurnaceGuardHelper} from "src/FurnaceGuardHelper.sol";

import {FurnaceQuoter} from "src/FurnaceQuoter.sol";
import {Constants} from "src/lib/Constants.sol";
import {Errors} from "src/lib/Errors.sol";
import {IEntryTokenRegistry} from "src/interfaces/IEntryTokenRegistry.sol";

import {MockAerodromeRouter} from "./mocks/MockAerodromeRouter.sol";
import {MockERC20} from "./mocks/MockERC20.sol";
import {MockShareholderRoyaltiesCheckpoint} from "./mocks/MockShareholderRoyaltiesCheckpoint.sol";
import {MockWETH} from "./mocks/MockWETH.sol";
import {VeClaimNFTHarness} from "./mocks/VeClaimNFTHarness.sol";

contract FurnaceWethEntryTest is Test {
    address internal owner;
    address internal alice;

    ClaimToken internal claim;
    VeClaimNFTHarness internal ve;
    Furnace internal furnace;

    MockWETH internal weth;
    MockAerodromeRouter internal router;
    EntryTokenRegistry internal reg;
    FurnaceQuoter internal quoter;

    function setUp() public {
        vm.txGasPrice(0);

        owner = makeAddr("owner");
        alice = makeAddr("alice");

        claim = new ClaimToken(owner);
        ve = new VeClaimNFTHarness(address(claim), owner);
        furnace = new Furnace(
            address(claim), address(ve), address(new FurnaceGuardHelper(address(claim), address(ve))), owner
        );

        weth = new MockWETH();
        router = new MockAerodromeRouter(address(0xFACADE), address(weth));
        reg = new EntryTokenRegistry(owner);

        // Give the factory address code so EntryTokenRegistry accepts it.
        vm.etch(address(0xFACADE), hex"01");
        vm.etch(address(0xBEEF), hex"01");

        address mockSR = address(new MockShareholderRoyaltiesCheckpoint());

        // Router needs to mint CLAIM out; allow the router to mint for this test by setting mineCore.
        vm.mockCall(address(router), abi.encodeWithSignature("claim()"), abi.encode(address(claim)));
        vm.mockCall(address(router), abi.encodeWithSignature("emissionStartTime()"), abi.encode(uint256(1)));
        vm.mockCall(address(router), abi.encodeWithSignature("GENESIS_ACCRUAL_DURATION()"), abi.encode(uint256(604800)));
        vm.prank(owner);
        claim.setMineCore(address(router));
        vm.mockCall(address(router), abi.encodeWithSignature("ve()"), abi.encode(address(ve)));
        vm.mockCall(address(router), abi.encodeWithSignature("furnace()"), abi.encode(address(furnace)));
        vm.mockCall(address(router), abi.encodeWithSignature("royalties()"), abi.encode(mockSR));

        // Set a pinned WETH -> CLAIM hop.
        router.setPoolFor(address(weth), address(claim), false, router.defaultFactory(), address(0xBEEF));

        vm.startPrank(owner);
        reg.setRouterConfig(address(router), router.defaultFactory(), address(weth), address(claim));
        reg.setWethClaimHop(false, address(0xBEEF));
        furnace.setEntryTokenRegistry(address(reg));
        quoter = new FurnaceQuoter(address(furnace));
        furnace.setFurnaceQuoter(address(quoter));
        furnace.setMineCore(address(router));
        furnace.setShareholderRoyalties(mockSR);
        address market = address(0xBABA);
        vm.etch(market, hex"01");
        vm.mockCall(market, abi.encodeWithSignature("ve()"), abi.encode(address(ve)));
        vm.mockCall(market, abi.encodeWithSignature("claim()"), abi.encode(address(claim)));
        vm.mockCall(market, abi.encodeWithSignature("royalties()"), abi.encode(mockSR));
        furnace.setMineMarket(market);
        MockShareholderRoyaltiesCheckpoint(mockSR).setWiring(address(router), market, address(furnace), address(ve));
        ve.setFurnace(address(furnace));
        ve.setMineMarket(market);
        vm.stopPrank();

        // Make the quote deterministic.
        // 1 ETH -> 2,000 CLAIM (matches the MIN_LOCK_AMOUNT=1,000 CLAIM test precondition).
        router.setRateX18(2000e18);
    }

    function testResolveFurnaceRouteWethReturnsCanonicalWethClaimHop() public {
        (IEntryTokenRegistry.RegistryRoute[] memory route, uint256 routeTokenId) =
            quoter.resolveFurnaceRoute(address(weth));

        assertEq(route.length, 1);
        assertEq(route[0].tokenIn, address(weth));
        assertEq(route[0].tokenOut, address(claim));
        assertEq(route[0].pool, address(0xBEEF));
        assertFalse(route[0].stable);
        assertEq(routeTokenId, 1);
    }

    function testResolveFurnaceRouteWethRevertsIfPinnedHopDriftsFromRouterPoolFor() public {
        router.setPoolFor(address(weth), address(claim), false, router.defaultFactory(), address(0xCAFE));

        vm.expectRevert(Errors.InvalidPool.selector);
        quoter.resolveFurnaceRoute(address(weth));
    }

    function testResolveFurnaceRouteTokenRevertsIfRegistryPoolDriftsFromRouterPoolFor() public {
        MockERC20 entryToken = new MockERC20("ENTRY", "ENTRY");
        address tokenWethPool = address(0xC0DE);
        vm.etch(tokenWethPool, hex"01");

        router.setPoolFor(address(entryToken), address(weth), false, router.defaultFactory(), tokenWethPool);

        vm.prank(owner);
        reg.setTokenConfig(address(entryToken), true, false, false, address(0), false, tokenWethPool);
        vm.prank(owner);
        reg.setFurnaceEntryTokenExactReceiptSafe(address(entryToken), true);

        router.setPoolFor(address(entryToken), address(weth), false, router.defaultFactory(), address(0xD0D0));

        vm.expectRevert(Errors.InvalidPool.selector);
        quoter.resolveFurnaceRoute(address(entryToken));
    }

    function testQuoteEnterWithTokenWethMatchesQuoteEnterWithEth() public {
        uint256 amountIn = 1 ether;
        uint256 duration = Constants.MIN_LOCK_DURATION;

        (uint256 p1, uint256 b1, uint256 ve1, uint256 t1) =
            quoter.quoteEnterWithEth(alice, amountIn, 0, duration, false);
        (uint256 p2, uint256 b2, uint256 ve2, uint256 t2) =
            quoter.quoteEnterWithToken(alice, address(weth), amountIn, 0, duration, false);

        assertEq(p1, p2);
        assertEq(b1, b2);
        assertEq(ve1, ve2);
        assertEq(t1, t2);
    }

    function testEnterWithTokenWethUnwrapsAndUsesWethToClaimHop() public {
        uint256 amountIn = 1 ether;
        uint256 duration = Constants.MIN_LOCK_DURATION;

        vm.deal(alice, 10 ether);
        vm.prank(alice);
        weth.deposit{value: amountIn}();

        vm.prank(alice);
        weth.approve(address(furnace), amountIn);

        (uint256 principal, uint256 bonus,,) =
            quoter.quoteEnterWithToken(alice, address(weth), amountIn, 0, duration, false);
        (,, uint256 minVeOut,) = quoter.quoteEnterWithToken(alice, address(weth), amountIn, 0, duration, false);
        uint256 expectedLocked = principal + bonus;

        vm.prank(alice);
        furnace.enterWithToken(address(weth), amountIn, 0, duration, false, minVeOut);

        // Should unwrap to ETH and use swapExactETHForTokens (not token->token routing).
        assertEq(router.lastEthValue(), amountIn);
        assertEq(router.lastAmountIn(), 0);

        // User spent WETH.
        assertEq(weth.balanceOf(alice), 0);

        // Lock created and funded.
        assertEq(ve.balanceOf(alice), 1);
        assertEq(ve.totalLockedClaim(), expectedLocked);
        assertEq(claim.balanceOf(address(ve)), expectedLocked);
    }
}
