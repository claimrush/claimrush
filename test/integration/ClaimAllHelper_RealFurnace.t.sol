// SPDX-License-Identifier: MIT
pragma solidity ^0.8.34;

import {Test} from "forge-std/Test.sol";

import {ClaimAllHelper} from "src/ClaimAllHelper.sol";
import {ClaimToken} from "src/ClaimToken.sol";
import {DelegationHub} from "src/DelegationHub.sol";
import {EntryTokenRegistry} from "src/EntryTokenRegistry.sol";
import {Furnace} from "src/Furnace.sol";
import {FurnaceGuardHelper} from "src/FurnaceGuardHelper.sol";

import {FurnaceQuoter} from "src/FurnaceQuoter.sol";
import {MarketRouter} from "src/MarketRouter.sol";
import {ShareholderRoyalties} from "src/ShareholderRoyalties.sol";
import {Constants} from "src/lib/Constants.sol";
import {DelegationPermissions} from "src/lib/DelegationPermissions.sol";
import {Errors} from "src/lib/Errors.sol";

import {MineCoreHarness} from "../mocks/MineCoreHarness.sol";
import {MockAerodromeRouter} from "../mocks/MockAerodromeRouter.sol";
import {MockWETH} from "../mocks/MockWETH.sol";
import {VeClaimNFTHarness} from "../mocks/VeClaimNFTHarness.sol";

contract ClaimTransferAerodromeRouter is MockAerodromeRouter {
    address public immutable claimToken;

    constructor(address factory_, address weth_, address claimToken_) MockAerodromeRouter(factory_, weth_) {
        claimToken = claimToken_;
    }

    function swapExactETHForTokens(uint256 amountOutMin, Route[] calldata routes, address to, uint256 deadline)
        external
        payable
        override
        returns (uint256[] memory amounts)
    {
        lastEthValue = msg.value;
        lastAmountOutMin = amountOutMin;
        lastTo = to;
        lastDeadline = deadline;
        lastRoutesHash = keccak256(abi.encode(routes));

        amounts = this.getAmountsOut(msg.value, routes);
        uint256 out = amounts[amounts.length - 1];
        require(out >= amountOutMin, "MockAerodromeRouter: slippage");
        require(routes[routes.length - 1].to == claimToken, "ClaimTransferAerodromeRouter: unexpected output");
        require(ClaimToken(claimToken).transfer(to, out), "ClaimTransferAerodromeRouter: transfer");
    }
}

contract ClaimAllHelperRealFurnaceIT is Test {
    ClaimToken internal claim;
    VeClaimNFTHarness internal ve;
    ShareholderRoyalties internal royalties;
    Furnace internal furnace;
    FurnaceQuoter internal quoter;
    MarketRouter internal market;
    MineCoreHarness internal mineCore;
    ClaimAllHelper internal helper;
    DelegationHub internal hub;
    EntryTokenRegistry internal furnaceRegistry;
    MockWETH internal weth;
    ClaimTransferAerodromeRouter internal router;

    address internal alice;
    address internal bob;

    function setUp() public {
        alice = makeAddr("alice");
        bob = makeAddr("bob");

        claim = new ClaimToken(address(this));
        ve = new VeClaimNFTHarness(address(claim), address(this));
        royalties = new ShareholderRoyalties(address(ve), address(this));
        furnace = new Furnace(
            address(claim), address(ve), address(new FurnaceGuardHelper(address(claim), address(ve))), address(this)
        );
        quoter = new FurnaceQuoter(address(furnace));
        market = new MarketRouter(address(claim), address(ve), address(royalties), address(this));
        mineCore = new MineCoreHarness(address(claim), address(ve), address(royalties), address(this));
        helper = new ClaimAllHelper(address(royalties), address(mineCore));
        hub = new DelegationHub();
        furnaceRegistry = new EntryTokenRegistry(address(this));
        weth = new MockWETH();

        address factory = address(0xFAC7);
        address pool = address(0xBEEF);
        vm.etch(factory, hex"01");
        vm.etch(pool, hex"01");

        router = new ClaimTransferAerodromeRouter(factory, address(weth), address(claim));
        router.setRateX18(2_000e18);
        router.setPoolFor(address(weth), address(claim), false, factory, pool);

        claim.setMineCore(address(mineCore));
        furnace.setMineCore(address(mineCore));
        furnace.setMineMarket(address(market));
        furnace.setShareholderRoyalties(address(royalties));
        furnace.setFurnaceQuoter(address(quoter));
        furnaceRegistry.setRouterConfig(address(router), factory, address(weth), address(claim));
        furnaceRegistry.setWethClaimHop(false, pool);
        furnace.setEntryTokenRegistry(address(furnaceRegistry));
        mineCore.setFurnace(address(furnace));
        mineCore.setClaimAllHelper(address(helper));
        mineCore.setDelegationHub(address(hub));
        furnace.setDelegationHub(address(hub));
        royalties.setWiring(address(mineCore), address(market), address(furnace));
        royalties.setClaimAllHelper(address(helper));
        ve.setFurnace(address(furnace));
        ve.setMineMarket(address(market));

        vm.prank(address(mineCore));
        claim.mint(address(router), 50_000e18);

        vm.prank(address(mineCore));
        claim.mint(alice, 5_000e18);

        vm.startPrank(alice);
        claim.approve(address(ve), 2_000e18);
        ve.createLock(2_000e18, Constants.MAX_LOCK_DURATION, false);
        vm.stopPrank();

        mineCore.setKingEthBalanceForTest(alice, 0.25 ether);
        vm.deal(address(mineCore), 2 ether);

        vm.prank(address(mineCore));
        royalties.onTakeover{value: 1 ether}(1);
        royalties.checkpointUser(alice);
    }

    function testClaimAllLockMode_createsRealVeLockThroughFurnace() public {
        uint256 claimable = royalties.claimableEth(alice);
        uint256 duration = 30 days;
        uint256 nextTokenId = ve.nextTokenId();

        assertGt(claimable, 0, "setup should materialize a real Baron claim");
        assertEq(nextTokenId, 2, "helper flow should mint the second lock");

        (uint256 principal, uint256 bonus, uint256 veOut, uint256 routeTokenId) =
            quoter.quoteEnterWithEth(alice, claimable, 0, duration, false);

        assertEq(routeTokenId, 0, "quote should target new-lock creation");
        assertGt(principal, Constants.MIN_LOCK_AMOUNT, "swap output must clear the min lock amount");
        assertGt(veOut, 0, "quote should produce positive ve out");

        uint256 veClaimBefore = claim.balanceOf(address(ve));
        uint256 aliceEthBefore = alice.balance;

        vm.prank(alice);
        helper.claimAll(Constants.SHAREHOLDER_MODE_LOCK_FURNACE, 0, duration, false, veOut);

        assertEq(royalties.claimableEth(alice), 0, "claimable Baron ETH should be consumed");
        assertEq(mineCore.kingEthBalance(alice), 0, "helper should still withdraw the King bucket");
        assertEq(alice.balance, aliceEthBefore + 0.25 ether, "King bucket should land on the user");
        assertEq(ve.nextTokenId(), nextTokenId + 1, "real ve mint path should advance token ids");
        assertEq(ve.ownerOf(nextTokenId), alice, "new ve lock must be minted for the helper caller");

        (uint256 lockedAmount, uint256 lockEnd, bool autoMax, bool listed) = ve.getLockInfo(nextTokenId);
        assertEq(lockedAmount, principal + bonus, "new lock should contain the swap principal plus any bonus");
        assertEq(lockEnd, block.timestamp + duration, "new lock should use the helper-supplied duration");
        assertFalse(autoMax, "new lock should respect the requested non-auto-max mode");
        assertFalse(listed, "fresh helper-created lock must not be listed");
        assertEq(
            claim.balanceOf(address(ve)),
            veClaimBefore + principal + bonus,
            "Claim should move from Furnace into VeClaimNFT during createLockFor"
        );
    }

    /// @notice Delegated `claimAllFor` with LOCK_FURNACE mode reverts. The delegated
    ///         bundle path is ETH-only by design: a P_CLAIM_ALL_FOR session
    ///         authorizes the bot to collect Baron ETH and withdraw King ETH on
    ///         the user's behalf, but never to spend the user's shareholder ETH
    ///         locking a fresh veCLAIM position. Self-locking remains available
    ///         via `claimAll(mode, ...)` from the user's own address.
    function testClaimAllForLockMode_delegatedRejectsLockFurnaceMode() public {
        uint256 claimable = royalties.claimableEth(alice);
        uint256 duration = 30 days;
        uint256 nextTokenId = ve.nextTokenId();

        assertGt(claimable, 0, "setup should materialize a real Baron claim");

        vm.prank(alice);
        hub.setSession(bob, DelegationPermissions.P_CLAIM_ALL_FOR, uint64(block.timestamp + 1 days));

        (,, uint256 veOut,) = quoter.quoteEnterWithEth(alice, claimable, 0, duration, false);

        vm.prank(bob);
        vm.expectRevert(Errors.NotAuthorized.selector);
        helper.claimAllFor(alice, Constants.SHAREHOLDER_MODE_LOCK_FURNACE, 0, duration, false, veOut);

        // Alice keeps her claim and her King bucket; no veCLAIM minted to anyone.
        assertEq(royalties.claimableEth(alice), claimable, "delegated lock-mode call must not consume alice's claim");
        assertEq(ve.nextTokenId(), nextTokenId, "delegated lock-mode call must not mint a veCLAIM");
    }

    function testClaimShareholderForUserLockMode_revertsWhenDelegateTargetsForeignLock() public {
        vm.prank(address(mineCore));
        claim.mint(bob, 1_000e18);

        vm.startPrank(bob);
        claim.approve(address(ve), 1_000e18);
        ve.createLock(1_000e18, Constants.MAX_LOCK_DURATION, false);
        vm.stopPrank();

        uint256 bobTokenId = 2;
        uint256 claimableBefore = royalties.claimableEth(alice);

        vm.prank(alice);
        hub.setSession(bob, DelegationPermissions.P_CLAIM_SHAREHOLDER_FOR, uint64(block.timestamp + 1 days));

        vm.prank(bob);
        vm.expectRevert(Errors.NotAuthorized.selector);
        helper.claimShareholderForUser(alice, Constants.SHAREHOLDER_MODE_LOCK_FURNACE, bobTokenId, 30 days, false, 1);

        assertEq(ve.ownerOf(bobTokenId), bob, "foreign target lock must remain bob's");
        assertEq(
            royalties.claimableEth(alice), claimableBefore, "failed delegated lock should not consume alice's claim"
        );
        assertEq(ve.nextTokenId(), 3, "failed delegated lock must not mint a new ve position");
    }
}
