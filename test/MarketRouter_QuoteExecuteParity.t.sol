// SPDX-License-Identifier: MIT
pragma solidity ^0.8.34;

import {Test} from "forge-std/Test.sol";
import {Vm} from "forge-std/Vm.sol";

import {MarketRouter} from "src/MarketRouter.sol";
import {ClaimToken} from "src/ClaimToken.sol";
import {EntryTokenRegistry} from "src/EntryTokenRegistry.sol";
import {Furnace} from "src/Furnace.sol";
import {FurnaceGuardHelper} from "src/FurnaceGuardHelper.sol";
import {FurnaceQuoter} from "src/FurnaceQuoter.sol";
import {IFurnaceQuoter} from "src/interfaces/IFurnaceQuoter.sol";
import {ShareholderRoyalties} from "src/ShareholderRoyalties.sol";
import {Constants} from "src/lib/Constants.sol";

import {MockAerodromeRouter} from "./mocks/MockAerodromeRouter.sol";
import {MockMineCoreWiringView} from "./mocks/MockMineCoreWiringView.sol";
import {MockWETH} from "./mocks/MockWETH.sol";
import {VeClaimNFTHarness} from "./mocks/VeClaimNFTHarness.sol";

/// @title MarketRouter wei-exact quote-vs-execute parity (item #10 from
///         the pre-mainnet readiness assessment).
/// @notice Furnace already pins quote-vs-execute parity to the wei in
///         `Furnace_QuoteExecuteParity.t.sol`. MarketRouter has only
///         single-sample point checks (`test_offchainParity_*` in
///         `MarketRouter_KeeperSettlement.t.sol`).
///
///         This file extends those into fuzz-driven sweeps so we cannot be
///         surprised by an off-by-one between what `FurnaceQuoter` returns
///         to the front-end and what the `sellLockToFurnace` /
///         `sellListedLockToFurnace` / `executeAutoFurnace` path actually
///         pays. The seller-payout path is the highest-stakes "you will
///         receive X" surface in the UI; a wei drift here is a UX integrity
///         break.
contract MarketRouterQuoteExecuteParityTest is Test {
    address internal constant FACTORY = address(0xFACADE);

    ClaimToken public claim;
    MockWETH internal weth;
    MockAerodromeRouter internal router;
    EntryTokenRegistry internal registry;
    VeClaimNFTHarness internal ve;
    ShareholderRoyalties internal royalties;
    Furnace internal furnace;
    FurnaceQuoter internal furnaceQuoter;
    MarketRouter internal market;
    MockMineCoreWiringView internal core;

    address internal owner;
    address internal alice;
    address internal keeper;

    function setUp() public {
        vm.txGasPrice(0);

        owner = address(this);
        alice = makeAddr("alice");
        keeper = makeAddr("keeper");

        claim = new ClaimToken(owner);
        weth = new MockWETH();
        router = new MockAerodromeRouter(FACTORY, address(weth));
        registry = new EntryTokenRegistry(owner);
        vm.etch(FACTORY, hex"00");
        registry.setRouterConfig(address(router), FACTORY, address(weth), address(claim));

        ve = new VeClaimNFTHarness(address(claim), owner);
        royalties = new ShareholderRoyalties(address(ve), owner);
        furnace = new Furnace(
            address(claim), address(ve), address(new FurnaceGuardHelper(address(claim), address(ve))), owner
        );
        market = new MarketRouter(address(claim), address(ve), address(royalties), owner);
        core = new MockMineCoreWiringView(address(claim), address(ve), address(royalties));

        claim.setMineCore(address(core));
        furnace.setMineCore(address(core));
        furnace.setMineMarket(address(market));
        furnace.setShareholderRoyalties(address(royalties));
        furnace.setEntryTokenRegistry(address(registry));
        furnaceQuoter = new FurnaceQuoter(address(furnace));
        furnace.setFurnaceQuoter(address(furnaceQuoter));

        royalties.setWiring(address(core), address(market), address(furnace));
        core.setFurnace(address(furnace));
        ve.setFurnace(address(furnace));
        ve.setMineMarket(address(market));

        // Seed reserve so the bonus / sell math is exercised over many regions.
        uint256 reserveSeed = 50_000_000e18;
        vm.startPrank(address(core));
        claim.mint(address(furnace), reserveSeed);
        furnace.creditReserve(reserveSeed);
        vm.stopPrank();

        ve.setApprovalForAllForTest(alice, address(market), true);
        vm.prank(alice);
        claim.approve(address(market), type(uint256).max);

        vm.prank(address(core));
        claim.mint(alice, 10_000_000e18);

        market.setSettlementKeeper(keeper, true);
    }

    // -----------------------------------------------------------------------
    // sellLockToFurnace: quote-vs-payout (fuzzed across lock sizes/durations)
    // -----------------------------------------------------------------------

    function testFuzz_sellLockToFurnace_quoteEqualsPayout(uint96 lockAmount_, uint64 durationSeconds_, bool autoMax)
        public
    {
        uint256 lockAmount = bound(uint256(lockAmount_), Constants.MIN_LOCK_AMOUNT, 5_000_000e18);
        // veNFT requires `duration == MAX_LOCK_DURATION` when autoMax is true.
        uint256 durationSeconds = autoMax
            ? Constants.MAX_LOCK_DURATION
            : bound(uint256(durationSeconds_), Constants.MIN_LOCK_DURATION + 1 days, Constants.MAX_LOCK_DURATION);

        uint256 tokenId = _createAliceLock(lockAmount, durationSeconds, autoMax);

        // Front-end "you will receive X" surface.
        (, uint256 claimOutQuote,,,) = furnaceQuoter.quoteSellLockToFurnace(alice, tokenId);

        uint256 sellerBefore = claim.balanceOf(alice);

        vm.prank(alice);
        // minClaimOut == claimOutQuote is the strictest possible slippage floor.
        // If the quote over-states by even a wei, the call reverts here.
        uint256 claimOut = market.sellLockToFurnace(tokenId, claimOutQuote, block.timestamp + 300);

        assertEq(claimOut, claimOutQuote, "return value must equal quote (wei-exact)");
        assertEq(
            claim.balanceOf(alice) - sellerBefore, claimOutQuote, "seller CLAIM delta must equal quote (wei-exact)"
        );
    }

    // -----------------------------------------------------------------------
    // sellListedLockToFurnace: keeper-driven settlement parity
    // -----------------------------------------------------------------------

    function testFuzz_sellListedLockToFurnace_quoteEqualsPayout(
        uint96 lockAmount_,
        uint64 durationSeconds_,
        bool autoMax
    ) public {
        uint256 lockAmount = bound(uint256(lockAmount_), Constants.MIN_LOCK_AMOUNT, 5_000_000e18);
        uint256 durationSeconds = autoMax
            ? Constants.MAX_LOCK_DURATION
            : bound(uint256(durationSeconds_), Constants.MIN_LOCK_DURATION + 1 days, Constants.MAX_LOCK_DURATION);

        uint256 tokenId = _createAliceLock(lockAmount, durationSeconds, autoMax);

        // Listing expiry MUST be <= lockEnd (MarketRouter enforces this with
        // `InvalidListingExpiry`). Cap at min(now+30d, lockEnd).
        (uint256 quoteAmount, uint256 quoteEnd, bool quoteAuto,) = ve.getLockInfo(tokenId);
        uint256 listingExpiry = block.timestamp + 30 days;
        if (listingExpiry > quoteEnd) listingExpiry = quoteEnd;

        // List with `minClaimOut = 1` (the wide gate). The ACTUAL parity
        // claim is between the live-quote at execution time and the payout.
        vm.prank(alice);
        market.listLock(tokenId, 1, listingExpiry);

        // Roll one block to clear the listing cooldown.
        vm.roll(block.number + 1);

        // Front-end "what will the seller receive" surface, evaluated at
        // execution block (matching what the keeper would see).
        (uint256 claimOutQuote,,,) = furnaceQuoter.quoteSellLockToFurnaceFromInfo(quoteAmount, quoteEnd, quoteAuto);

        uint256 sellerBefore = claim.balanceOf(alice);

        vm.prank(keeper);
        uint256 claimOut = market.sellListedLockToFurnace(tokenId, block.timestamp + 300);

        assertEq(claimOut, claimOutQuote, "settlement payout must equal live quote (wei-exact)");
        assertEq(
            claim.balanceOf(alice) - sellerBefore,
            claimOutQuote,
            "seller CLAIM delta on listed settlement must equal quote (wei-exact)"
        );
    }

    // -----------------------------------------------------------------------
    // executeAutoFurnace: buyer-side preview vs minted-lock receipt
    // -----------------------------------------------------------------------

    /// @notice The buyer side of an auto-furnace offer sees a quote of the
    ///         form `(principal, bonus, veOut, routeTokenId)` from
    ///         `FurnaceQuoter.quoteEnterWithClaim`. This MUST equal the
    ///         minted-lock amount on execution (`locked == principal + bonus`)
    ///         exactly. Drift here means the buyer's "I'll mint a lock of size
    ///         X" promise was a lie.
    function testFuzz_executeAutoFurnace_quoteEqualsMintedLock(uint96 budgetExtra_, uint64 ttl_) public {
        uint256 minBudget = market.minBonusTargetEscrowBudget();
        // Allow up to +5_000_000e18 extra over the minimum to vary the bonus region.
        uint256 budget = minBudget + bound(uint256(budgetExtra_), 0, 5_000_000e18);
        // TTL must be within Constants.MIN_BONUS_TARGET_ESCROW_TTL_SECONDS (300s)
        // and Constants.MAX_BONUS_TARGET_ESCROW_TTL_SECONDS (90 days).
        uint256 ttl = bound(
            uint256(ttl_), Constants.MIN_BONUS_TARGET_ESCROW_TTL_SECONDS, Constants.MAX_BONUS_TARGET_ESCROW_TTL_SECONDS
        );

        vm.prank(alice);
        uint256 offerId = market.createBonusTargetEscrowWithTarget(
            1, // minimal target bonus -- always fillable
            budget,
            30 days,
            true, // createAutoMax
            ttl,
            0,
            0
        );

        MarketRouter.BonusTargetEscrow memory offer = market.getBonusTargetEscrow(offerId);

        (uint256 principal, uint256 bonus,,) =
            furnaceQuoter.quoteEnterWithClaim(alice, offer.fundsRemaining, 0, Constants.MAX_LOCK_DURATION, true);

        vm.recordLogs();
        vm.prank(keeper);
        market.executeAutoFurnace(offerId, block.timestamp + 300);
        Vm.Log[] memory logs = vm.getRecordedLogs();

        // Find the canonical event to extract the minted token id.
        bytes32 canonicalTopic =
            keccak256("BonusTargetEscrowExecuted(uint256,address,uint256,uint256,uint256,uint256,uint256,uint256)");
        uint256 mintedTokenId = 0;
        for (uint256 i = 0; i < logs.length; ++i) {
            if (logs[i].topics.length == 3 && logs[i].topics[0] == canonicalTopic) {
                (,,,,, uint256 tokenIdEvent) =
                    abi.decode(logs[i].data, (uint256, uint256, uint256, uint256, uint256, uint256));
                mintedTokenId = tokenIdEvent;
                break;
            }
        }
        require(mintedTokenId != 0, "auto-furnace event missing");

        (uint256 lockedAmount,,,) = ve.getLockInfo(mintedTokenId);
        assertEq(lockedAmount, principal + bonus, "minted lock must equal principal + bonus from quote (wei-exact)");
    }

    // -----------------------------------------------------------------------
    // Internals
    // -----------------------------------------------------------------------

    function _createAliceLock(uint256 amount, uint256 durationSeconds, bool createAutoMax)
        internal
        returns (uint256 tokenId)
    {
        vm.prank(address(core));
        claim.mint(address(furnace), amount);
        vm.prank(address(furnace));
        claim.approve(address(ve), amount);
        vm.prank(address(furnace));
        tokenId = ve.createLockFor(alice, amount, durationSeconds, createAutoMax);
    }
}
