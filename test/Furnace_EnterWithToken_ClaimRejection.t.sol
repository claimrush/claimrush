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

import {MockAerodromeRouter} from "./mocks/MockAerodromeRouter.sol";
import {MockShareholderRoyaltiesCheckpoint} from "./mocks/MockShareholderRoyaltiesCheckpoint.sol";
import {MockWETH} from "./mocks/MockWETH.sol";
import {VeClaimNFTHarness} from "./mocks/VeClaimNFTHarness.sol";

/// @notice Verify that enterWithToken and quoteEnterWithToken both reject CLAIM as tokenIn
///         with the same error code (InvalidToken), and that tokenIn == address(0) reverts
///         with ZeroAddress on both surfaces.
contract FurnaceEnterWithTokenClaimRejectionTest is Test {
    address internal owner;
    address internal alice;

    ClaimToken public claim;
    VeClaimNFTHarness internal ve;
    Furnace internal furnace;
    FurnaceQuoter internal quoter;

    MockWETH internal weth;
    MockAerodromeRouter internal router;
    EntryTokenRegistry internal reg;

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

        vm.etch(address(0xFACADE), hex"01");
        vm.etch(address(0xBEEF), hex"01");

        address mockSR = address(new MockShareholderRoyaltiesCheckpoint());

        vm.startPrank(owner);
        vm.mockCall(address(this), abi.encodeWithSignature("emissionStartTime()"), abi.encode(uint256(1)));
        vm.mockCall(address(this), abi.encodeWithSignature("GENESIS_ACCRUAL_DURATION()"), abi.encode(uint256(604800)));
        claim.setMineCore(address(this));
        vm.mockCall(address(this), abi.encodeWithSignature("ve()"), abi.encode(address(ve)));
        vm.mockCall(address(this), abi.encodeWithSignature("claim()"), abi.encode(address(claim)));
        vm.mockCall(address(this), abi.encodeWithSignature("furnace()"), abi.encode(address(furnace)));

        furnace.setMineCore(address(this));

        address market = address(0xBABA);
        vm.etch(market, hex"01");
        vm.mockCall(market, abi.encodeWithSignature("ve()"), abi.encode(address(ve)));
        vm.mockCall(market, abi.encodeWithSignature("claim()"), abi.encode(address(claim)));
        vm.mockCall(market, abi.encodeWithSignature("royalties()"), abi.encode(mockSR));
        ve.setMineMarket(market);
        ve.setFurnace(address(furnace));
        furnace.setMineMarket(market);
        furnace.setShareholderRoyalties(mockSR);

        reg.setRouterConfig(address(router), router.defaultFactory(), address(weth), address(claim));
        router.setPoolFor(address(weth), address(claim), false, router.defaultFactory(), address(0xBEEF));
        reg.setWethClaimHop(false, address(0xBEEF));
        vm.mockCall(address(this), abi.encodeWithSignature("entryTokenRegistry()"), abi.encode(address(0)));
        furnace.setEntryTokenRegistry(address(reg));
        quoter = new FurnaceQuoter(address(furnace));
        furnace.setFurnaceQuoter(address(quoter));
        vm.stopPrank();

        claim.mint(alice, 100_000e18);
    }

    function test_enterWithToken_rejects_claim_as_tokenIn() public {
        vm.startPrank(alice);
        claim.approve(address(furnace), 10_000e18);
        vm.expectRevert(Errors.InvalidToken.selector);
        furnace.enterWithToken(address(claim), 10_000e18, 0, Constants.MAX_LOCK_DURATION, true, 1);
        vm.stopPrank();
    }

    function test_quoteEnterWithToken_rejects_claim_as_tokenIn() public {
        vm.expectRevert(Errors.InvalidToken.selector);
        quoter.quoteEnterWithToken(alice, address(claim), 10_000e18, 0, Constants.MAX_LOCK_DURATION, true);
    }

    function test_enterWithToken_rejects_zero_address() public {
        vm.startPrank(alice);
        vm.expectRevert(Errors.ZeroAddress.selector);
        furnace.enterWithToken(address(0), 10_000e18, 0, Constants.MAX_LOCK_DURATION, true, 1);
        vm.stopPrank();
    }

    function test_quoteEnterWithToken_rejects_zero_address() public {
        vm.expectRevert(Errors.ZeroAddress.selector);
        quoter.quoteEnterWithToken(alice, address(0), 10_000e18, 0, Constants.MAX_LOCK_DURATION, true);
    }
}
