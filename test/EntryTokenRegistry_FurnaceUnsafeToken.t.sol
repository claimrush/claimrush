// SPDX-License-Identifier: MIT
pragma solidity ^0.8.34;

import {Test} from "forge-std/Test.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

import {ClaimToken} from "src/ClaimToken.sol";
import {DelegationHub} from "src/DelegationHub.sol";
import {EntryTokenRegistry} from "src/EntryTokenRegistry.sol";
import {Furnace} from "src/Furnace.sol";
import {FurnaceGuardHelper} from "src/FurnaceGuardHelper.sol";

import {FurnaceQuoter} from "src/FurnaceQuoter.sol";
import {Constants} from "src/lib/Constants.sol";
import {DelegationPermissions} from "src/lib/DelegationPermissions.sol";
import {Errors} from "src/lib/Errors.sol";

import {MockAerodromeRouterMineCore} from "./mocks/MockAerodromeRouterMineCore.sol";
import {MockShareholderRoyaltiesCheckpoint} from "./mocks/MockShareholderRoyaltiesCheckpoint.sol";
import {MockWETH} from "./mocks/MockWETH.sol";
import {VeClaimNFTHarness} from "./mocks/VeClaimNFTHarness.sol";

contract SelectiveFeeToken is ERC20 {
    address public taxedRecipient;
    uint256 public feeBps;

    constructor() ERC20("Selective Fee Token", "SFEE") {}

    function setTax(address recipient, uint256 feeBps_) external {
        taxedRecipient = recipient;
        feeBps = feeBps_;
    }

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }

    function _update(address from, address to, uint256 value) internal override {
        if (from != address(0) && to == taxedRecipient && feeBps != 0 && value != 0) {
            uint256 fee = (value * feeBps) / 10_000;
            super._update(from, address(0), fee);
            super._update(from, to, value - fee);
            return;
        }

        super._update(from, to, value);
    }
}

contract MockAerodromeRouterMineCoreTokenSwap is MockAerodromeRouterMineCore {
    constructor(address factory_, address weth_, address claimToken_, address ve_, address furnace_, address royalties_)
        MockAerodromeRouterMineCore(factory_, weth_, claimToken_, ve_, furnace_, royalties_)
    {}

    function swapExactTokensForTokens(
        uint256 amountIn,
        uint256 amountOutMin,
        Route[] calldata routes,
        address to,
        uint256 deadline
    ) external override returns (uint256[] memory amounts) {
        lastAmountIn = amountIn;
        lastAmountOutMin = amountOutMin;
        lastTo = to;
        lastDeadline = deadline;
        lastRoutesHash = keccak256(abi.encode(routes));

        Route memory first = routes[0];
        require(
            ERC20(first.from).transferFrom(msg.sender, address(this), amountIn), "MockAerodromeRouter: transferFrom"
        );

        amounts = this.getAmountsOut(amountIn, routes);
        uint256 out = amounts[amounts.length - 1];
        require(out >= amountOutMin, "MockAerodromeRouter: slippage");

        Route memory last = routes[routes.length - 1];
        if (last.to == claimToken) {
            ClaimToken(claimToken).mint(to, out);
        } else {
            SelectiveFeeToken(last.to).mint(to, out);
        }
    }
}

contract EntryTokenRegistryFurnaceUnsafeTokenTest is Test {
    address internal owner;
    address internal alice;

    ClaimToken internal claim;
    VeClaimNFTHarness internal ve;
    Furnace internal furnace;
    FurnaceQuoter internal quoter;

    MockWETH internal weth;
    MockAerodromeRouterMineCoreTokenSwap internal router;
    EntryTokenRegistry internal registry;
    SelectiveFeeToken internal unsafeToken;
    DelegationHub internal delegationHub;

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
        vm.etch(address(0xFACADE), hex"01");
        vm.etch(address(0xBEEF), hex"01");
        vm.etch(address(0xCAFE), hex"01");

        address mockSR = address(new MockShareholderRoyaltiesCheckpoint());
        router = new MockAerodromeRouterMineCoreTokenSwap(
            address(0xFACADE), address(weth), address(claim), address(ve), address(furnace), mockSR
        );
        registry = new EntryTokenRegistry(owner);
        unsafeToken = new SelectiveFeeToken();
        delegationHub = new DelegationHub();

        vm.mockCall(address(router), abi.encodeWithSignature("delegationHub()"), abi.encode(address(delegationHub)));

        vm.startPrank(owner);
        claim.setMineCore(address(router));
        furnace.setMineCore(address(router));
        furnace.setDelegationHub(address(delegationHub));

        address market = address(0xBABA);
        vm.etch(market, hex"01");
        vm.mockCall(market, abi.encodeWithSignature("ve()"), abi.encode(address(ve)));
        vm.mockCall(market, abi.encodeWithSignature("claim()"), abi.encode(address(claim)));
        vm.mockCall(market, abi.encodeWithSignature("royalties()"), abi.encode(mockSR));
        furnace.setMineMarket(market);
        furnace.setShareholderRoyalties(mockSR);
        MockShareholderRoyaltiesCheckpoint(mockSR).setWiring(address(router), market, address(furnace), address(ve));
        ve.setFurnace(address(furnace));
        ve.setMineMarket(market);

        registry.setRouterConfig(address(router), router.defaultFactory(), address(weth), address(claim));
        router.setPoolFor(address(weth), address(claim), false, router.defaultFactory(), address(0xBEEF));
        registry.setWethClaimHop(false, address(0xBEEF));
        router.setPoolFor(address(unsafeToken), address(weth), false, router.defaultFactory(), address(0xCAFE));
        registry.setTokenConfig(address(unsafeToken), true, false, false, address(0), false, address(0xCAFE));
        furnace.setEntryTokenRegistry(address(registry));
        quoter = new FurnaceQuoter(address(furnace));
        furnace.setFurnaceQuoter(address(quoter));
        vm.stopPrank();

        unsafeToken.setTax(address(furnace), 1_000);
        unsafeToken.mint(alice, 10_000e18);
    }

    function testEnterWithTokenRejectsSelectiveFeeTokenTransferFailed() public {
        uint256 requestedAmount = 10_000e18;

        vm.startPrank(alice);
        unsafeToken.approve(address(furnace), requestedAmount);
        vm.expectRevert(Errors.UnsafeEntryToken.selector);
        furnace.enterWithToken(address(unsafeToken), requestedAmount, 0, Constants.MAX_LOCK_DURATION, true, 1);
        vm.stopPrank();

        assertEq(router.lastAmountIn(), 0, "swap must not start for unsafe tokens");
        assertEq(unsafeToken.balanceOf(address(furnace)), 0, "unsafe token gate must run before custody");
        assertEq(ve.totalLockedClaim(), 0, "no lock principal should be minted");
        assertEq(ve.nextTokenId(), 1, "no ve lock should be created");
    }

    function testEnterWithTokenFromCallerForRejectsSelectiveFeeTokenTransferFailed() public {
        address delegate = makeAddr("delegate");
        uint256 requestedAmount = 10_000e18;

        unsafeToken.mint(delegate, requestedAmount);
        _authorizeFurnaceTokenEntry(alice, delegate);

        vm.startPrank(delegate);
        unsafeToken.approve(address(furnace), requestedAmount);
        vm.expectRevert(Errors.UnsafeEntryToken.selector);
        furnace.enterWithTokenFromCallerFor(
            alice, address(unsafeToken), requestedAmount, 0, Constants.MAX_LOCK_DURATION, true, 1
        );
        vm.stopPrank();

        assertEq(router.lastAmountIn(), 0, "delegated swap must not start for unsafe tokens");
        assertEq(unsafeToken.balanceOf(address(furnace)), 0, "unsafe token gate must run before delegated custody");
        assertEq(ve.totalLockedClaim(), 0, "delegated failure must not mint principal");
        assertEq(ve.nextTokenId(), 1, "delegated failure must not create a lock");
    }

    function testQuoteEnterWithTokenRejectsUnsafeToken() public {
        vm.expectRevert(Errors.UnsafeEntryToken.selector);
        quoter.quoteEnterWithToken(alice, address(unsafeToken), 10_000e18, 0, Constants.MAX_LOCK_DURATION, true);
    }

    function testEnterWithTokenSucceedsForExactReceiptToken() public {
        uint256 requestedAmount = 10_000e18;

        unsafeToken.setTax(address(furnace), 0);
        vm.prank(owner);
        registry.setFurnaceEntryTokenExactReceiptSafe(address(unsafeToken), true);

        (uint256 principalClaim,, uint256 veOut,) = quoter.quoteEnterWithToken(
            alice, address(unsafeToken), requestedAmount, 0, Constants.MAX_LOCK_DURATION, true
        );
        assertEq(principalClaim, requestedAmount, "quote should stay amountIn-based for standard ERC20 semantics");

        vm.startPrank(alice);
        unsafeToken.approve(address(furnace), requestedAmount);
        uint256 tokenId =
            furnace.enterWithToken(address(unsafeToken), requestedAmount, 0, Constants.MAX_LOCK_DURATION, true, veOut);
        vm.stopPrank();

        assertEq(router.lastAmountIn(), requestedAmount, "swap should receive the full requested amount");
        assertEq(ve.ownerOf(tokenId), alice, "lock owner should be preserved");
        assertEq(ve.totalLockedClaim(), requestedAmount, "principalClaim should remain unchanged");

        (uint256 locked,, bool autoMax,) = ve.getLockInfo(tokenId);
        assertEq(locked, requestedAmount, "lock principal should match the exact receipt");
        assertTrue(autoMax);
    }

    function _authorizeFurnaceTokenEntry(address user, address delegate) internal {
        vm.prank(user);
        delegationHub.setSession(
            delegate, DelegationPermissions.P_FURNACE_ENTER_TOKEN_FOR, uint64(block.timestamp + 1 days)
        );
    }
}
