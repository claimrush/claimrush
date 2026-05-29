// SPDX-License-Identifier: MIT
pragma solidity ^0.8.34;

import {Test} from "forge-std/Test.sol";

import {ClaimToken} from "src/ClaimToken.sol";
import {EntryTokenRegistry} from "src/EntryTokenRegistry.sol";
import {Furnace} from "src/Furnace.sol";
import {FurnaceGuardHelper} from "src/FurnaceGuardHelper.sol";

import {MineCoreQuoter} from "src/MineCoreQuoter.sol";
import {ShareholderRoyalties} from "src/ShareholderRoyalties.sol";
import {Errors} from "src/lib/Errors.sol";
import {Constants} from "src/lib/Constants.sol";
import {IDexAdapter} from "src/interfaces/IDexAdapter.sol";
import {IEntryTokenRegistry} from "src/interfaces/IEntryTokenRegistry.sol";

import {MineCoreHarness} from "./mocks/MineCoreHarness.sol";
import {MockAerodromeRouter} from "./mocks/MockAerodromeRouter.sol";
import {MockERC20} from "./mocks/MockERC20.sol";
import {MockVe} from "./mocks/MockVe.sol";
import {MockWETH} from "./mocks/MockWETH.sol";

// ─────────────────────────────────────────────────────────────────────────────
// Malicious router mocks for _boundedGetAmountsOut assembly edge-case tests
// ─────────────────────────────────────────────────────────────────────────────

/// @dev Router that returns a massive returndata blob (return-bomb attack).
contract ReturnBombRouter {
    address public defaultFactory;
    address public weth;

    mapping(bytes32 => address) internal _poolFor;

    constructor(address factory_, address weth_) {
        defaultFactory = factory_;
        weth = weth_;
    }

    function setPoolFor(address tokenA, address tokenB, bool stable, address factory, address pool) external {
        (address a, address b) = tokenA < tokenB ? (tokenA, tokenB) : (tokenB, tokenA);
        _poolFor[keccak256(abi.encode(a, b, stable, factory))] = pool;
    }

    function poolFor(address tokenA, address tokenB, bool stable, address factory) external view returns (address) {
        (address a, address b) = tokenA < tokenB ? (tokenA, tokenB) : (tokenB, tokenA);
        return _poolFor[keccak256(abi.encode(a, b, stable, factory))];
    }

    /// @dev Returns correct amounts but pads with 64KB of extra data.
    function getAmountsOut(uint256 amountIn, IDexAdapter.Route[] calldata)
        external
        pure
        returns (uint256[] memory amounts)
    {
        // Build the valid response first.
        amounts = new uint256[](2);
        amounts[0] = amountIn;
        amounts[1] = amountIn; // 1:1 rate

        // Now append a huge blob via assembly to simulate return-bomb.
        assembly {
            // Overwrite the return: re-encode amounts[2] correctly, then pad with 64KB.
            let ptr := mload(0x40)
            // offset word
            mstore(ptr, 0x20)
            // length word
            mstore(add(ptr, 0x20), 2)
            // amounts[0]
            mstore(add(ptr, 0x40), amountIn)
            // amounts[1]
            mstore(add(ptr, 0x60), amountIn)
            // Return 64KB+ (valid data + padding).
            return(ptr, 0x10000)
        }
    }
}

/// @dev Router that returns amounts[0] != amountIn (echo mismatch).
contract EchoMismatchRouter {
    address public defaultFactory;
    address public weth;

    mapping(bytes32 => address) internal _poolFor;

    constructor(address factory_, address weth_) {
        defaultFactory = factory_;
        weth = weth_;
    }

    function setPoolFor(address tokenA, address tokenB, bool stable, address factory, address pool) external {
        (address a, address b) = tokenA < tokenB ? (tokenA, tokenB) : (tokenB, tokenA);
        _poolFor[keccak256(abi.encode(a, b, stable, factory))] = pool;
    }

    function poolFor(address tokenA, address tokenB, bool stable, address factory) external view returns (address) {
        (address a, address b) = tokenA < tokenB ? (tokenA, tokenB) : (tokenB, tokenA);
        return _poolFor[keccak256(abi.encode(a, b, stable, factory))];
    }

    function getAmountsOut(uint256 amountIn, IDexAdapter.Route[] calldata)
        external
        pure
        returns (uint256[] memory amounts)
    {
        amounts = new uint256[](2);
        amounts[0] = amountIn + 1; // Wrong echo!
        amounts[1] = amountIn;
    }
}

/// @dev Router that returns amounts[1] == 0 (zero liquidity).
contract ZeroOutputRouter {
    address public defaultFactory;
    address public weth;

    mapping(bytes32 => address) internal _poolFor;

    constructor(address factory_, address weth_) {
        defaultFactory = factory_;
        weth = weth_;
    }

    function setPoolFor(address tokenA, address tokenB, bool stable, address factory, address pool) external {
        (address a, address b) = tokenA < tokenB ? (tokenA, tokenB) : (tokenB, tokenA);
        _poolFor[keccak256(abi.encode(a, b, stable, factory))] = pool;
    }

    function poolFor(address tokenA, address tokenB, bool stable, address factory) external view returns (address) {
        (address a, address b) = tokenA < tokenB ? (tokenA, tokenB) : (tokenB, tokenA);
        return _poolFor[keccak256(abi.encode(a, b, stable, factory))];
    }

    function getAmountsOut(uint256 amountIn, IDexAdapter.Route[] calldata)
        external
        pure
        returns (uint256[] memory amounts)
    {
        amounts = new uint256[](2);
        amounts[0] = amountIn;
        amounts[1] = 0; // Zero output!
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// Test contract
// ─────────────────────────────────────────────────────────────────────────────

contract MineCoreQuoterTest is Test {
    ClaimToken internal claim;
    MockVe internal ve;
    ShareholderRoyalties internal royalties;
    Furnace internal furnace;
    MineCoreHarness internal mineCore;

    MockWETH internal weth;
    MockERC20 internal tokenIn;
    MockAerodromeRouter internal router;
    EntryTokenRegistry internal registry;
    MineCoreQuoter internal quoter;

    address internal factory;
    address internal pool;

    address internal owner = address(0xA11CE);
    address internal alice = address(0xA);
    address internal mineMarket = address(0xBABA);

    function setUp() public {
        // ── Core protocol ──────────────────────────────────────────────
        claim = new ClaimToken(owner);
        ve = new MockVe();
        royalties = new ShareholderRoyalties(address(ve), owner);
        furnace = new Furnace(
            address(claim), address(ve), address(new FurnaceGuardHelper(address(claim), address(ve))), owner
        );
        mineCore = new MineCoreHarness(address(claim), address(ve), address(royalties), owner);
        ve.setClaimToken(address(claim));

        vm.prank(owner);
        claim.setMineCore(address(mineCore));

        vm.etch(mineMarket, hex"00");
        vm.mockCall(mineMarket, abi.encodeWithSignature("ve()"), abi.encode(address(ve)));
        vm.mockCall(mineMarket, abi.encodeWithSignature("claim()"), abi.encode(address(claim)));
        vm.mockCall(mineMarket, abi.encodeWithSignature("royalties()"), abi.encode(address(royalties)));

        vm.startPrank(owner);
        furnace.setMineCore(address(mineCore));
        furnace.setMineMarket(mineMarket);
        furnace.setShareholderRoyalties(address(royalties));
        royalties.setWiring(address(mineCore), mineMarket, address(furnace));
        mineCore.setFurnace(address(furnace));
        ve.setFurnace(address(furnace));
        ve.setMineMarket(mineMarket);
        vm.stopPrank();

        // ── DEX mocks ─────────────────────────────────────────────────
        weth = new MockWETH();
        tokenIn = new MockERC20("Token In", "TIN");

        factory = address(0xFACA);
        vm.etch(factory, hex"00");

        pool = address(0xBEEF);
        vm.etch(pool, hex"00");

        router = new MockAerodromeRouter(factory, address(weth));
        router.setPoolFor(address(tokenIn), address(weth), false, factory, pool);

        // ── Registry wiring ───────────────────────────────────────────
        registry = new EntryTokenRegistry(owner);

        vm.startPrank(owner);
        registry.setRouterConfig(address(router), factory, address(weth), address(claim));
        registry.setTokenConfig(address(tokenIn), true, false, false, address(0), false, pool);
        mineCore.setEntryTokenRegistry(address(registry));
        vm.stopPrank();

        // ── Quoter ────────────────────────────────────────────────────
        quoter = new MineCoreQuoter(address(mineCore));

        // ── Enable takeovers ──────────────────────────────────────────
        _unpauseTakeovers();
    }

    function _unpauseTakeovers() internal {
        mineCore.setGenesisKingClaimCollectedForTest(true);
        vm.prank(owner);
        mineCore.setTakeoversPaused(false);
    }

    /// @dev Deploy a quoter wired to a custom router for assembly edge-case tests.
    function _deployQuoterWithRouter(address customRouter) internal returns (MineCoreQuoter q) {
        EntryTokenRegistry reg = new EntryTokenRegistry(owner);

        vm.startPrank(owner);
        reg.setRouterConfig(customRouter, factory, address(weth), address(claim));
        reg.setTokenConfig(address(tokenIn), true, false, false, address(0), false, pool);
        mineCore.setEntryTokenRegistry(address(reg));
        vm.stopPrank();

        q = new MineCoreQuoter(address(mineCore));
    }

    // ═════════════════════════════════════════════════════════════════════
    //  Happy path
    // ═════════════════════════════════════════════════════════════════════

    function testQuoteTakeoverWithToken_happyPath() public view {
        uint256 amountIn = 1 ether;
        (uint256 ethOut, uint256 takeoverPrice) = quoter.quoteTakeoverWithToken(address(tokenIn), amountIn);

        // MockAerodromeRouter: 1:1 rate by default.
        assertEq(ethOut, amountIn, "ethOut should match amountIn at 1:1 rate");
        assertGt(takeoverPrice, 0, "takeoverPrice should be non-zero");
    }

    function testQuoteTakeoverWithToken_happyPathCustomRate() public {
        router.setRateX18(0.5e18); // 50% rate

        uint256 amountIn = 2 ether;
        (uint256 ethOut,) = quoter.quoteTakeoverWithToken(address(tokenIn), amountIn);

        assertEq(ethOut, 1 ether, "ethOut should be 50% of amountIn");
    }

    function testQuoteTakeoverWithToken_returnsTakeoverPrice() public view {
        (, uint256 takeoverPrice) = quoter.quoteTakeoverWithToken(address(tokenIn), 1 ether);
        uint256 expected = mineCore.getTakeoverPrice(block.timestamp);
        assertEq(takeoverPrice, expected, "takeoverPrice should match MineCore.getTakeoverPrice");
    }

    // ═════════════════════════════════════════════════════════════════════
    //  WETH special case
    // ═════════════════════════════════════════════════════════════════════

    function testQuoteTakeoverWithToken_wethSpecialCase() public view {
        uint256 amountIn = 5 ether;
        (uint256 ethOut,) = quoter.quoteTakeoverWithToken(address(weth), amountIn);

        assertEq(ethOut, amountIn, "WETH should return amountIn directly (1:1 unwrap)");
    }

    function testResolveTakeoverRoute_wethReturnsEmpty() public view {
        IEntryTokenRegistry.RegistryRoute[] memory routes = quoter.resolveTakeoverRoute(address(weth));
        assertEq(routes.length, 0, "WETH route should be empty (implicit 1:1 unwrap)");
    }

    // ═════════════════════════════════════════════════════════════════════
    //  Differential: quote >= actual
    // ═════════════════════════════════════════════════════════════════════

    function testQuoteTakeoverWithToken_differential() public {
        // Fund WETH contract so unwrap succeeds.
        vm.deal(address(weth), 100 ether);

        uint256 amountIn = 1 ether;
        (uint256 quotedEthOut,) = quoter.quoteTakeoverWithToken(address(tokenIn), amountIn);

        // Fund alice with tokenIn and approve MineCore.
        tokenIn.mint(alice, amountIn);
        vm.prank(alice);
        tokenIn.approve(address(mineCore), amountIn);

        // Warp past emission start so takeover price is at floor.
        uint256 t1 = mineCore.emissionStartTime() + 1;
        vm.warp(t1);

        uint256 price = mineCore.getTakeoverPrice(block.timestamp);
        uint256 aliceEthBefore = alice.balance;

        vm.prank(alice);
        mineCore.takeoverWithToken(address(tokenIn), amountIn, price, type(uint256).max);

        // Actual ETH credited = swap output. Alice receives excess refund.
        uint256 aliceEthAfter = alice.balance;
        uint256 actualRefund = aliceEthAfter - aliceEthBefore;
        // Total ETH from swap = price paid + refund.
        uint256 actualEthOut = price + actualRefund;

        assertGe(quotedEthOut, actualEthOut, "quoted ETH must be >= actual ETH received");
    }

    // ═════════════════════════════════════════════════════════════════════
    //  Input validation reverts
    // ═════════════════════════════════════════════════════════════════════

    function testQuoteTakeoverWithToken_revertsWhenPaused() public {
        vm.prank(owner);
        mineCore.setTakeoversPaused(true);

        vm.expectRevert(Errors.TakeoversPaused.selector);
        quoter.quoteTakeoverWithToken(address(tokenIn), 1 ether);
    }

    function testQuoteTakeoverWithToken_revertsZeroAddress() public {
        vm.expectRevert(Errors.ZeroAddress.selector);
        quoter.quoteTakeoverWithToken(address(0), 1 ether);
    }

    function testQuoteTakeoverWithToken_revertsAmountZero() public {
        vm.expectRevert(Errors.AmountZero.selector);
        quoter.quoteTakeoverWithToken(address(tokenIn), 0);
    }

    function testQuoteTakeoverWithToken_revertsClaimToken() public {
        vm.expectRevert(Errors.InvalidToken.selector);
        quoter.quoteTakeoverWithToken(address(claim), 1 ether);
    }

    // ═════════════════════════════════════════════════════════════════════
    //  resolveTakeoverRoute
    // ═════════════════════════════════════════════════════════════════════

    function testResolveTakeoverRoute_normalToken() public view {
        IEntryTokenRegistry.RegistryRoute[] memory routes = quoter.resolveTakeoverRoute(address(tokenIn));

        assertEq(routes.length, 1, "should return exactly 1 route");
        assertEq(routes[0].tokenIn, address(tokenIn), "route tokenIn mismatch");
        assertEq(routes[0].tokenOut, address(weth), "route tokenOut should be WETH");
        assertEq(routes[0].pool, pool, "route pool mismatch");
    }

    function testResolveTakeoverRoute_revertsClaimToken() public {
        vm.expectRevert(Errors.InvalidToken.selector);
        quoter.resolveTakeoverRoute(address(claim));
    }

    function testResolveTakeoverRoute_revertsZeroAddress() public {
        vm.expectRevert(Errors.ZeroAddress.selector);
        quoter.resolveTakeoverRoute(address(0));
    }

    // ═════════════════════════════════════════════════════════════════════
    //  _boundedGetAmountsOut assembly edge cases
    // ═════════════════════════════════════════════════════════════════════

    function testBoundedGetAmountsOut_revertsOnRouterRevert() public {
        router.setRevertGetAmountsOut(true);

        vm.expectRevert(Errors.QuoteCallFailed.selector);
        quoter.quoteTakeoverWithToken(address(tokenIn), 1 ether);
    }

    function testBoundedGetAmountsOut_revertsOnZeroOutput() public {
        ZeroOutputRouter zRouter = new ZeroOutputRouter(factory, address(weth));
        zRouter.setPoolFor(address(tokenIn), address(weth), false, factory, pool);

        MineCoreQuoter q = _deployQuoterWithRouter(address(zRouter));

        vm.expectRevert(Errors.QuoteCallFailed.selector);
        q.quoteTakeoverWithToken(address(tokenIn), 1 ether);
    }

    function testBoundedGetAmountsOut_revertsOnEchoMismatch() public {
        EchoMismatchRouter eRouter = new EchoMismatchRouter(factory, address(weth));
        eRouter.setPoolFor(address(tokenIn), address(weth), false, factory, pool);

        MineCoreQuoter q = _deployQuoterWithRouter(address(eRouter));

        vm.expectRevert(Errors.QuoteCallFailed.selector);
        q.quoteTakeoverWithToken(address(tokenIn), 1 ether);
    }

    function testBoundedGetAmountsOut_returnBombCapped() public {
        ReturnBombRouter bRouter = new ReturnBombRouter(factory, address(weth));
        bRouter.setPoolFor(address(tokenIn), address(weth), false, factory, pool);

        MineCoreQuoter q = _deployQuoterWithRouter(address(bRouter));

        // Should succeed despite 64KB returndata — bounded copy caps to 128 bytes.
        (uint256 ethOut,) = q.quoteTakeoverWithToken(address(tokenIn), 1 ether);
        assertEq(ethOut, 1 ether, "return-bomb router should still produce correct quote");
    }

    // ═════════════════════════════════════════════════════════════════════
    //  Constructor validation
    // ═════════════════════════════════════════════════════════════════════

    function testConstructor_revertsZeroAddress() public {
        vm.expectRevert(Errors.ZeroAddress.selector);
        new MineCoreQuoter(address(0));
    }

    function testConstructor_revertsNotAContract() public {
        vm.expectRevert(Errors.NotAContract.selector);
        new MineCoreQuoter(address(0xDEAD));
    }

    function testConstructor_setsMineCore() public view {
        assertEq(quoter.mineCore(), address(mineCore));
    }

    function testConstructor_rejectsDelegatedEOA() public {
        // EIP-7702 delegation designator is exactly `0xEF 0x01 0x00 || delegate`
        // (23 bytes). Constructor must reject this even though `code.length != 0`
        // and `extcodehash` is non-empty.
        address delegate = address(mineCore);
        bytes memory designator = abi.encodePacked(hex"ef0100", delegate);
        assertEq(designator.length, 23, "EIP-7702 designator length must be 23");

        address fakeMineCore = address(0xCAFE7702);
        vm.etch(fakeMineCore, designator);
        assertEq(fakeMineCore.code.length, 23, "etched code must be 23 bytes");

        vm.expectRevert(Errors.NotAContract.selector);
        new MineCoreQuoter(fakeMineCore);
    }
}
