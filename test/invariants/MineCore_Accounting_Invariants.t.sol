// SPDX-License-Identifier: MIT
pragma solidity ^0.8.34;

import {Test} from "forge-std/Test.sol";
import {StdInvariant} from "forge-std/StdInvariant.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {ClaimToken} from "src/ClaimToken.sol";
import {Furnace} from "src/Furnace.sol";
import {FurnaceGuardHelper} from "src/FurnaceGuardHelper.sol";

import {FurnaceQuoter} from "src/FurnaceQuoter.sol";
import {MineCore} from "src/MineCore.sol";
import {ShareholderRoyalties} from "src/ShareholderRoyalties.sol";

import {MockVe} from "../mocks/MockVe.sol";
import {MineCoreHarness} from "../mocks/MineCoreHarness.sol";

contract AccountingInvariantRefundRejector {
    receive() external payable {
        revert("NO_REFUND");
    }
}

contract AccountingInvariantGasBombReceiver {
    uint256 internal idx;
    mapping(uint256 => uint256) internal slots;

    receive() external payable {
        uint256 i = idx;
        slots[i] = 1;
        slots[i + 1] = 2;
        idx = i + 2;
    }
}

contract MineCoreAccountingHandler is Test {
    ClaimToken internal immutable claim;
    MockVe internal immutable ve;
    ShareholderRoyalties internal immutable royalties;
    MineCoreHarness internal immutable mineCore;

    address internal immutable safeReceiver;

    address[] internal actors;

    constructor(
        ClaimToken claim_,
        MockVe ve_,
        ShareholderRoyalties royalties_,
        MineCoreHarness mineCore_,
        address alice,
        address bob,
        address carol,
        address gasBomb,
        address refundRejector
    ) {
        claim = claim_;
        ve = ve_;
        royalties = royalties_;
        mineCore = mineCore_;

        safeReceiver = makeAddr("safeReceiver");

        actors.push(alice);
        actors.push(bob);
        actors.push(carol);
        actors.push(gasBomb);
        actors.push(refundRejector);
    }

    function takeover(uint256 actorSeed, uint256 extraEth, uint256 dtSeed) external {
        _warp(bound(dtSeed, 0, 3 hours));

        address actor = _actor(actorSeed);
        address current = mineCore.currentKing();
        if (current != address(0) && actor == current) return;

        uint256 price = mineCore.getCurrentTakeoverPrice();
        uint256 value = price + bound(extraEth, 0, 0.25 ether);

        vm.deal(actor, value);
        vm.prank(actor);
        mineCore.takeover{value: value}(type(uint256).max);
    }

    function withdrawKing(uint256 actorSeed) external {
        vm.prank(_actor(actorSeed));
        (bool ok,) = address(mineCore).call(abi.encodeWithSignature("withdrawKingBalanceTo(address)", safeReceiver));
        ok;
    }

    function withdrawRefund(uint256 actorSeed) external {
        vm.prank(_actor(actorSeed));
        (bool ok,) = address(mineCore).call(abi.encodeWithSignature("withdrawRefundBalance(address)", safeReceiver));
        ok;
    }

    function withdrawPendingClaim(uint256 actorSeed) external {
        vm.prank(_actor(actorSeed));
        (bool ok,) = address(mineCore).call(abi.encodeWithSignature("withdrawPendingClaimTo(address)", safeReceiver));
        ok;
    }

    function retryShareholderEth(uint256 dtSeed) external {
        _warp(bound(dtSeed, 301, 2 hours));

        // Ensure the retry path keeps progressing when the invariant runner picks this selector.
        ve.setCheckpointAdvances(true);

        (bool ok,) = address(mineCore).call(abi.encodeWithSignature("retryPushShareholderEth()"));
        ok;
    }

    function _actor(uint256 seed) internal view returns (address) {
        return actors[seed % actors.length];
    }

    function _warp(uint256 dt) internal {
        if (dt != 0) vm.warp(block.timestamp + dt);
    }
}

contract MineCoreAccountingInvariants is StdInvariant, Test {
    ClaimToken internal claim;
    MockVe internal ve;
    ShareholderRoyalties internal royalties;
    Furnace internal furnace;
    MineCoreHarness internal mineCore;

    address internal owner;
    address internal alice;
    address internal bob;
    address internal carol;

    AccountingInvariantGasBombReceiver internal gasBomb;
    AccountingInvariantRefundRejector internal refundRejector;
    MineCoreAccountingHandler internal handler;

    function setUp() public {
        vm.txGasPrice(0);

        owner = makeAddr("owner");
        alice = makeAddr("alice");
        bob = makeAddr("bob");
        carol = makeAddr("carol");

        ve = new MockVe();
        claim = new ClaimToken(owner);
        royalties = new ShareholderRoyalties(address(ve), owner);
        furnace = new Furnace(
            address(claim), address(ve), address(new FurnaceGuardHelper(address(claim), address(ve))), owner
        );
        FurnaceQuoter quoter = new FurnaceQuoter(address(furnace));
        mineCore = new MineCoreHarness(address(claim), address(ve), address(royalties), owner);

        vm.startPrank(owner);
        claim.setMineCore(address(mineCore));
        furnace.setMineCore(address(mineCore));
        furnace.setFurnaceQuoter(address(quoter));
        furnace.setShareholderRoyalties(address(royalties));
        mineCore.setFurnace(address(furnace));
        vm.etch(address(0xB0B0), hex"00");
        royalties.setWiring(address(mineCore), address(0xB0B0), address(furnace));
        mineCore.setGenesisKingClaimCollectedForTest(true);
        mineCore.setTakeoversPaused(false);
        vm.stopPrank();

        ve.setClaimToken(address(claim));
        ve.setFurnace(address(furnace));
        ve.setTotalVeCached(1234);
        ve.setCheckpointAdvances(true);

        gasBomb = new AccountingInvariantGasBombReceiver();
        refundRejector = new AccountingInvariantRefundRejector();

        _seedNonZeroEthCredits();
        _seedPendingClaim();
        _seedShareholderPending();

        handler = new MineCoreAccountingHandler(
            claim, ve, royalties, mineCore, alice, bob, carol, address(gasBomb), address(refundRejector)
        );

        targetContract(address(handler));

        bytes4[] memory selectors = new bytes4[](5);
        selectors[0] = MineCoreAccountingHandler.takeover.selector;
        selectors[1] = MineCoreAccountingHandler.withdrawKing.selector;
        selectors[2] = MineCoreAccountingHandler.withdrawRefund.selector;
        selectors[3] = MineCoreAccountingHandler.withdrawPendingClaim.selector;
        selectors[4] = MineCoreAccountingHandler.retryShareholderEth.selector;
        targetSelector(FuzzSelector({addr: address(handler), selectors: selectors}));
    }

    function invariant_ethLiabilitiesCoveredByBalance() public view {
        uint256 tracked = mineCore.totalKingEthOwed() + mineCore.totalRefundEthOwed() + mineCore.shareholderEthPending();
        assertLe(tracked, address(mineCore).balance, "ETH liabilities must stay covered");
    }

    function invariant_claimLiabilitiesCoveredByBalance() public view {
        uint256 tracked = mineCore.totalPendingKingClaim();
        uint256 balance = IERC20(address(claim)).balanceOf(address(mineCore));
        assertLe(tracked, balance, "CLAIM liabilities must stay covered");
    }

    function _seedNonZeroEthCredits() internal {
        uint256 p0 = mineCore.getCurrentTakeoverPrice();
        vm.deal(address(gasBomb), p0);
        vm.prank(address(gasBomb));
        MineCore(payable(address(mineCore))).takeover{value: p0}(type(uint256).max);

        vm.warp(block.timestamp + 1);
        uint256 p1 = mineCore.getCurrentTakeoverPrice();
        vm.deal(alice, p1);
        vm.prank(alice);
        mineCore.takeover{value: p1}(type(uint256).max);

        vm.warp(block.timestamp + 1);
        uint256 p2 = mineCore.getCurrentTakeoverPrice();
        uint256 extra = 0.123 ether;
        vm.deal(address(refundRejector), p2 + extra);
        vm.prank(address(refundRejector));
        MineCore(payable(address(mineCore))).takeover{value: p2 + extra}(type(uint256).max);
    }

    function _seedPendingClaim() internal {
        uint256 pending = 123e18;
        mineCore.setPendingKingClaimForTest(carol, pending);
        vm.prank(address(mineCore));
        claim.mint(address(mineCore), pending);
    }

    function _seedShareholderPending() internal {
        uint256 pending = 1 ether;
        mineCore.setShareholderEthPendingHarness(pending);
        vm.deal(address(mineCore), address(mineCore).balance + pending);
    }
}
