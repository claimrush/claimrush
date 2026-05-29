// SPDX-License-Identifier: MIT
pragma solidity ^0.8.34;

import {Test} from "forge-std/Test.sol";

import {ClaimAllHelper} from "src/ClaimAllHelper.sol";
import {ClaimToken} from "src/ClaimToken.sol";
import {VeClaimNFT} from "src/VeClaimNFT.sol";
import {ShareholderRoyalties} from "src/ShareholderRoyalties.sol";
import {Errors} from "src/lib/Errors.sol";

import {MineCoreHarness} from "./mocks/MineCoreHarness.sol";

/// @notice Minimal stub so `setDelegationHub` passes its `code.length != 0` gate.
contract DelegationHubStub {}

contract MineCore_ReignRecipientSinks_Test is Test {
    address internal constant owner = address(0xA11CE);
    address internal constant alice = address(0xB0B);
    address internal constant bob = address(0xCAFE);

    ClaimToken internal claim;
    VeClaimNFT internal ve;
    ShareholderRoyalties internal royalties;
    MineCoreHarness internal mineCore;
    ClaimAllHelper internal claimAllHelper;
    DelegationHubStub internal delegationHubStub;

    function setUp() external {
        claim = new ClaimToken(owner);
        ve = new VeClaimNFT(address(claim), owner);
        royalties = new ShareholderRoyalties(address(ve), owner);
        mineCore = new MineCoreHarness(address(claim), address(ve), address(royalties), owner);
        claimAllHelper = new ClaimAllHelper(address(royalties), address(mineCore));
        delegationHubStub = new DelegationHubStub();

        vm.startPrank(owner);
        mineCore.setClaimAllHelper(address(claimAllHelper));
        mineCore.setDelegationHub(address(delegationHubStub));
        vm.stopPrank();

        mineCore.setReignStateForTest(alice, block.timestamp, 1 ether, block.timestamp);

        // Open the takeover gate so the protocol-sink-rejection branch in
        // `_executeTakeover` is reachable. Without this, `takeover()` short-circuits
        // on `TakeoversPaused()` before `_rejectProtocolAddressAsRecipient(newKing)`.
        mineCore.setGenesisKingClaimCollectedForTest(true);
        vm.prank(owner);
        mineCore.setTakeoversPaused(false);
    }

    // ---- setCurrentReignRecipients: baseline sinks (claim / ve) ----

    function testSetCurrentReignRecipientsRevertsWhenEthRecipientIsClaimToken() external {
        vm.prank(alice);
        vm.expectRevert(Errors.NotAuthorized.selector);
        mineCore.setCurrentReignRecipients(address(claim), bob);
    }

    function testSetCurrentReignRecipientsRevertsWhenClaimRecipientIsVeClaimNft() external {
        vm.prank(alice);
        vm.expectRevert(Errors.NotAuthorized.selector);
        mineCore.setCurrentReignRecipients(bob, address(ve));
    }

    // ---- setCurrentReignRecipients: ClaimAllHelper ----

    function testSetCurrentReignRecipientsRevertsWhenEthRecipientIsClaimAllHelper() external {
        vm.prank(alice);
        vm.expectRevert(Errors.NotAuthorized.selector);
        mineCore.setCurrentReignRecipients(address(claimAllHelper), bob);
    }

    function testSetCurrentReignRecipientsRevertsWhenClaimRecipientIsClaimAllHelper() external {
        vm.prank(alice);
        vm.expectRevert(Errors.NotAuthorized.selector);
        mineCore.setCurrentReignRecipients(bob, address(claimAllHelper));
    }

    // ---- setCurrentReignRecipients: MineCoreHelper (immutable _helper) ----

    function testSetCurrentReignRecipientsRevertsWhenEthRecipientIsMineCoreHelper() external {
        // Resolve `_helper` BEFORE `vm.expectRevert` so the cheatcode is consumed
        // by the actual setter call rather than by the harness getter.
        address helperAddr = mineCore.helperAddressForTest();
        vm.prank(alice);
        vm.expectRevert(Errors.NotAuthorized.selector);
        mineCore.setCurrentReignRecipients(helperAddr, bob);
    }

    function testSetCurrentReignRecipientsRevertsWhenClaimRecipientIsMineCoreHelper() external {
        address helperAddr = mineCore.helperAddressForTest();
        vm.prank(alice);
        vm.expectRevert(Errors.NotAuthorized.selector);
        mineCore.setCurrentReignRecipients(bob, helperAddr);
    }

    // ---- setCurrentReignRecipients: DelegationHub ----

    function testSetCurrentReignRecipientsRevertsWhenEthRecipientIsDelegationHub() external {
        vm.prank(alice);
        vm.expectRevert(Errors.NotAuthorized.selector);
        mineCore.setCurrentReignRecipients(address(delegationHubStub), bob);
    }

    function testSetCurrentReignRecipientsRevertsWhenClaimRecipientIsDelegationHub() external {
        vm.prank(alice);
        vm.expectRevert(Errors.NotAuthorized.selector);
        mineCore.setCurrentReignRecipients(bob, address(delegationHubStub));
    }

    // ---- takeover() path: newKing = protocol sink ----
    //
    // The `_rejectProtocolAddressAsRecipient(newKing)` call is the first
    // statement inside `_executeTakeover`, so the revert fires before any
    // ve / furnace / claim external calls run. These tests prove the guard
    // covers the takeover entrypoint too (not just the setter).

    function testTakeoverRevertsWhenMsgSenderIsClaimAllHelper() external {
        address sink = address(claimAllHelper);
        vm.deal(sink, 1000 ether);
        vm.prank(sink);
        vm.expectRevert(Errors.NotAuthorized.selector);
        mineCore.takeover{value: 1000 ether}(type(uint256).max);
    }

    function testTakeoverRevertsWhenMsgSenderIsMineCoreHelper() external {
        address sink = mineCore.helperAddressForTest();
        vm.deal(sink, 1000 ether);
        vm.prank(sink);
        vm.expectRevert(Errors.NotAuthorized.selector);
        mineCore.takeover{value: 1000 ether}(type(uint256).max);
    }

    function testTakeoverRevertsWhenMsgSenderIsDelegationHub() external {
        address sink = address(delegationHubStub);
        vm.deal(sink, 1000 ether);
        vm.prank(sink);
        vm.expectRevert(Errors.NotAuthorized.selector);
        mineCore.takeover{value: 1000 ether}(type(uint256).max);
    }
}
