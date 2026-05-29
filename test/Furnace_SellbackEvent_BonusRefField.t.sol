// SPDX-License-Identifier: MIT
pragma solidity ^0.8.34;

import {Test} from "forge-std/Test.sol";

import {ClaimToken} from "src/ClaimToken.sol";
import {EntryTokenRegistry} from "src/EntryTokenRegistry.sol";
import {Furnace} from "src/Furnace.sol";
import {FurnaceGuardHelper} from "src/FurnaceGuardHelper.sol";

import {FurnaceQuoter} from "src/FurnaceQuoter.sol";
import {IFurnaceQuoter} from "src/interfaces/IFurnaceQuoter.sol";
import {Constants} from "src/lib/Constants.sol";
import {Errors} from "src/lib/Errors.sol";

import {MockAerodromeRouter} from "./mocks/MockAerodromeRouter.sol";
import {MockShareholderRoyaltiesCheckpoint} from "./mocks/MockShareholderRoyaltiesCheckpoint.sol";
import {MockWETH} from "./mocks/MockWETH.sol";
import {VeClaimNFTHarness} from "./mocks/VeClaimNFTHarness.sol";

/// @notice Verify that the LockSoldToFurnace event emits bonusRefBpsUsed
///         (= max(spotBonusBps, baseBonusBps)) in its last field,
///         and that the quoteSellLockToFurnaceBreakdown breakdown exposes the
///         same value as bonusRefBpsUsed / bonusBpsUsed.
contract FurnaceSellbackEventBonusRefFieldTest is Test {
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
        vm.mockCall(address(this), abi.encodeWithSignature("royalties()"), abi.encode(mockSR));

        furnace.setMineCore(address(this));

        address market = address(0xBABA);
        vm.etch(market, hex"01");
        vm.mockCall(market, abi.encodeWithSignature("ve()"), abi.encode(address(ve)));
        vm.mockCall(market, abi.encodeWithSignature("claim()"), abi.encode(address(claim)));
        vm.mockCall(market, abi.encodeWithSignature("royalties()"), abi.encode(mockSR));
        furnace.setMineMarket(market);
        furnace.setShareholderRoyalties(mockSR);
        MockShareholderRoyaltiesCheckpoint(mockSR).setWiring(address(this), market, address(furnace), address(ve));
        ve.setFurnace(address(furnace));
        ve.setMineMarket(market);

        reg.setRouterConfig(address(router), router.defaultFactory(), address(weth), address(claim));
        router.setPoolFor(address(weth), address(claim), false, router.defaultFactory(), address(0xBEEF));
        reg.setWethClaimHop(false, address(0xBEEF));
        vm.mockCall(address(this), abi.encodeWithSignature("entryTokenRegistry()"), abi.encode(address(0)));
        furnace.setEntryTokenRegistry(address(reg));
        quoter = new FurnaceQuoter(address(furnace));
        furnace.setFurnaceQuoter(address(quoter));
        vm.stopPrank();

        // Seed reserve so bonus math is exercised.
        uint256 reserve = 5_000_000e18;
        claim.mint(address(furnace), reserve);
        furnace.creditReserve(reserve);

        // Create a lock for Alice.
        claim.mint(alice, 100_000e18);
        vm.startPrank(alice);
        claim.approve(address(furnace), 100_000e18);
        furnace.enterWithClaim(100_000e18, 0, Constants.MAX_LOCK_DURATION, true, 1);
        vm.stopPrank();
    }

    /// @notice bonusRefBpsUsed in the breakdown must equal max(spotBonusBps, baseBonusBps),
    ///         and must match the backwards-compat alias bonusBpsUsed.
    function test_breakdown_bonusRefBpsUsed_equals_max_spot_base() public view {
        IFurnaceQuoter.SellLockQuoteBreakdown memory bq = quoter.quoteSellLockToFurnaceBreakdown(alice, 1);

        uint256 expectedRef = bq.spotBonusBps > bq.baseBonusBps ? bq.spotBonusBps : bq.baseBonusBps;
        assertEq(bq.bonusRefBpsUsed, expectedRef, "bonusRefBpsUsed != max(spot, base)");
        assertEq(bq.bonusBpsUsed, bq.bonusRefBpsUsed, "backwards-compat alias mismatch");
    }

    /// @notice The execution quote's bonusBpsUsed must match the breakdown's bonusRefBpsUsed.
    function test_executionQuote_bonusBpsUsed_matches_breakdown() public view {
        IFurnaceQuoter.SellLockQuoteBreakdown memory bq = quoter.quoteSellLockToFurnaceBreakdown(alice, 1);

        (uint256 lockAmount, uint256 lockEnd, bool autoMax,) = ve.getLockInfo(1);
        IFurnaceQuoter.SellExecutionQuote memory eq = quoter.quoteSellLockForExecution(lockAmount, lockEnd, autoMax);
        assertEq(eq.bonusBpsUsed, bq.bonusRefBpsUsed, "execution quote bonusBpsUsed mismatch");
    }
}
