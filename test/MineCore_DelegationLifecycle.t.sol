// SPDX-License-Identifier: MIT
pragma solidity ^0.8.34;

import {Test} from "forge-std/Test.sol";
import {Vm} from "forge-std/Vm.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {ClaimToken} from "src/ClaimToken.sol";
import {DelegationHub} from "src/DelegationHub.sol";
import {Furnace} from "src/Furnace.sol";
import {FurnaceGuardHelper} from "src/FurnaceGuardHelper.sol";

import {FurnaceQuoter} from "src/FurnaceQuoter.sol";
import {ShareholderRoyalties} from "src/ShareholderRoyalties.sol";
import {DelegationActionTypes} from "src/lib/DelegationActionTypes.sol";
import {DelegationPermissions} from "src/lib/DelegationPermissions.sol";
import {Errors} from "src/lib/Errors.sol";

import {MockVe} from "./mocks/MockVe.sol";
import {MockContract} from "./mocks/MockContract.sol";
import {MineCoreHarness} from "./mocks/MineCoreHarness.sol";

contract RawSessionOnlyDelegationHub {
    function getSession(address, address) external view returns (uint256 perms, uint256 expiry) {
        perms = DelegationPermissions.P_SET_REIGN_ETH_RECIPIENT | DelegationPermissions.P_SET_REIGN_CLAIM_RECIPIENT;
        expiry = block.timestamp + 1 days;
    }

    function isAuthorized(address, address, uint256) external pure returns (bool) {
        return false;
    }
}

/// @notice Full delegation lifecycle.
///         Create session -> takeoverFor -> dethrone -> withdraw ETH + CLAIM via correct recipients.
contract MineCoreDelegationLifecycleTest is Test {
    ClaimToken internal claim;
    MockVe internal ve;
    ShareholderRoyalties internal royalties;
    Furnace internal furnace;
    MineCoreHarness internal mineCore;
    DelegationHub internal hub;

    address internal owner = makeAddr("owner");
    address internal king = makeAddr("king"); // the user/delegator
    address internal bot = makeAddr("bot"); // the delegate
    address internal dethroner = makeAddr("dethroner");

    function setUp() public {
        ve = new MockVe();
        claim = new ClaimToken(owner);
        royalties = new ShareholderRoyalties(address(ve), owner);
        furnace = new Furnace(
            address(claim), address(ve), address(new FurnaceGuardHelper(address(claim), address(ve))), owner
        );
        FurnaceQuoter quoter = new FurnaceQuoter(address(furnace));
        mineCore = new MineCoreHarness(address(claim), address(ve), address(royalties), owner);
        hub = new DelegationHub();

        MockContract mineMarket = new MockContract();

        vm.startPrank(owner);
        claim.setMineCore(address(mineCore));
        furnace.setMineCore(address(mineCore));
        furnace.setFurnaceQuoter(address(quoter));
        furnace.setShareholderRoyalties(address(royalties));
        furnace.setMineMarket(address(mineMarket));

        // MineCore must learn about the furnace and the canonical hub BEFORE we wire
        // the furnace-side hub pointer; FurnaceGuardHelper.requireCanonicalDelegationHub
        // staticcalls mineCore.{furnace,delegationHub,claim,ve} and demands the bundle
        // match before it lets `Furnace.setDelegationHub` succeed.
        mineCore.setFurnace(address(furnace));
        mineCore.setDelegationHub(address(hub));
        furnace.setDelegationHub(address(hub));

        ve.setMineMarket(address(mineMarket));
        ve.setFurnace(address(furnace));
        ve.setClaimToken(address(claim));

        royalties.setWiring(address(mineCore), address(mineMarket), address(furnace));

        mineCore.setGenesisKingClaimCollectedForTest(true);
        mineCore.setTakeoversPaused(false);
        vm.stopPrank();

        ve.setTotalVeCached(1234);
    }

    /// @notice Full lifecycle: bot creates session, takes over for king, king is dethroned,
    ///         ETH routes to bot (reignEthRecipient), CLAIM routes to king (reignClaimRecipient).
    function test_delegationLifecycle_takeoverFor_dethrone_withdraw() public {
        // 1) King authorizes bot with P_TAKEOVER_FOR.
        vm.prank(king);
        hub.setSession(bot, DelegationPermissions.P_TAKEOVER_FOR, uint64(block.timestamp + 1 days));

        assertTrue(hub.isAuthorized(king, bot, DelegationPermissions.P_TAKEOVER_FOR));

        // 2) Bot takes over for king.
        uint256 price0 = mineCore.getCurrentTakeoverPrice();
        vm.deal(bot, price0);
        vm.prank(bot);
        mineCore.takeoverFor{value: price0}(king, type(uint256).max);

        assertEq(mineCore.currentKing(), king, "king identity should be the user");
        assertEq(mineCore.reignEthRecipient(1), bot, "ETH recipient should be the bot");
        assertEq(mineCore.reignClaimRecipient(1), king, "CLAIM recipient should be the king");

        // 3) Time passes, king earns emissions.
        vm.warp(block.timestamp + 30 minutes);

        // 4) Dethroner takes over, dethroning king.
        uint256 price1 = mineCore.getCurrentTakeoverPrice();
        vm.deal(dethroner, price1);
        vm.prank(dethroner);
        mineCore.takeover{value: price1}(type(uint256).max);

        assertEq(mineCore.currentKing(), dethroner, "dethroner should be new king");

        // 5) Verify: bot received 75% ETH (or has it in kingEthBalance).
        uint256 botKingEth = mineCore.kingEthBalance(bot);
        uint256 expectedKingShare = (price1 * 75) / 100;

        // Bot is an EOA so direct payout should succeed. But verify either way.
        // The bot either received it directly or has it credited.
        assertGe(bot.balance + botKingEth, expectedKingShare, "bot should have received king ETH share");

        // 6) Verify: king received CLAIM (liquid, since auto-lock is off by default).
        uint256 kingClaimBal = IERC20(address(claim)).balanceOf(king);
        uint256 kingPendingClaim = mineCore.pendingKingClaim(king);
        assertGt(kingClaimBal + kingPendingClaim, 0, "king should have received mined CLAIM");
    }

    /// @notice P_ROUTE_REIGN_CLAIM_TO_CALLER routes CLAIM to bot instead of king.
    function test_delegationLifecycle_routeClaimToCaller() public {
        uint256 perms = DelegationPermissions.P_TAKEOVER_FOR | DelegationPermissions.P_ROUTE_REIGN_CLAIM_TO_CALLER;

        vm.prank(king);
        hub.setSession(bot, perms, uint64(block.timestamp + 1 days));

        uint256 price0 = mineCore.getCurrentTakeoverPrice();
        vm.deal(bot, price0);
        vm.prank(bot);
        mineCore.takeoverFor{value: price0}(king, type(uint256).max);

        // CLAIM recipient should now be the bot.
        assertEq(mineCore.reignClaimRecipient(1), bot, "CLAIM should route to bot");
        assertEq(mineCore.reignEthRecipient(1), bot, "ETH should route to bot");

        // Dethrone and verify bot gets CLAIM.
        vm.warp(block.timestamp + 30 minutes);
        uint256 price1 = mineCore.getCurrentTakeoverPrice();
        vm.deal(dethroner, price1);
        vm.prank(dethroner);
        mineCore.takeover{value: price1}(type(uint256).max);

        uint256 botClaim = IERC20(address(claim)).balanceOf(bot);
        uint256 botPending = mineCore.pendingKingClaim(bot);
        assertGt(botClaim + botPending, 0, "bot should have received mined CLAIM");
    }

    /// @notice takeoverFor emits the exact delegation bits consumed by the reign start.
    function test_delegationLifecycle_takeoverForEmitsSessionUsageWithExpectedPerms() public {
        uint256 perms = DelegationPermissions.P_TAKEOVER_FOR | DelegationPermissions.P_ROUTE_REIGN_CLAIM_TO_CALLER;

        vm.prank(king);
        hub.setSession(bot, perms, uint64(block.timestamp + 1 days));

        uint256 price = mineCore.getCurrentTakeoverPrice();
        vm.deal(bot, price);

        vm.recordLogs();
        vm.prank(bot);
        mineCore.takeoverFor{value: price}(king, type(uint256).max);

        Vm.Log[] memory logs = vm.getRecordedLogs();
        bytes32 sessionSig = keccak256("DelegationSessionUsed(address,address,uint8,uint256,uint256,uint256)");

        bool foundSession;
        for (uint256 i = 0; i < logs.length; i++) {
            if (logs[i].topics.length < 4 || logs[i].topics[0] != sessionSig) continue;

            foundSession = true;
            assertEq(address(uint160(uint256(logs[i].topics[1]))), king, "user");
            assertEq(address(uint160(uint256(logs[i].topics[2]))), bot, "delegate");
            assertEq(uint256(logs[i].topics[3]), uint256(DelegationActionTypes.TAKEOVER_FOR), "actionType");

            (uint256 permsUsed, uint256 refId, uint256 timestamp) =
                abi.decode(logs[i].data, (uint256, uint256, uint256));
            assertEq(permsUsed, perms, "permsUsed");
            assertEq(refId, 1, "refId");
            assertEq(timestamp, block.timestamp, "timestamp");
        }

        assertTrue(foundSession, "DelegationSessionUsed event not found");
    }

    /// @notice Session expiry prevents takeoverFor after expiry.
    function test_delegationLifecycle_expiredSessionReverts() public {
        vm.prank(king);
        hub.setSession(bot, DelegationPermissions.P_TAKEOVER_FOR, uint64(block.timestamp + 1 hours));

        // Warp past expiry.
        vm.warp(block.timestamp + 2 hours);

        uint256 price = mineCore.getCurrentTakeoverPrice();
        vm.deal(bot, price);
        vm.prank(bot);
        vm.expectRevert(Errors.NotAuthorized.selector);
        mineCore.takeoverFor{value: price}(king, type(uint256).max);
    }

    /// @notice P_TAKEOVER_FOR alone cannot be upgraded into CLAIM rerouting through setCurrentReignRecipients.
    function test_delegationLifecycle_takeoverForOnlyPermCannotEscalateClaimRoutingViaRecipientSetter() public {
        vm.prank(king);
        hub.setSession(bot, DelegationPermissions.P_TAKEOVER_FOR, uint64(block.timestamp + 1 days));

        uint256 price = mineCore.getCurrentTakeoverPrice();
        vm.deal(bot, price);
        vm.prank(bot);
        mineCore.takeoverFor{value: price}(king, type(uint256).max);

        // A non-king caller without any recipient-setter perm reverts even when
        // the call would otherwise be a no-op (passing the current pair). The
        // tightened gate forces the caller to prove some authority on every
        // entry instead of leaning on the no-op short-circuit.
        vm.prank(bot);
        vm.expectRevert(Errors.NotAuthorized.selector);
        mineCore.setCurrentReignRecipients(bot, king);

        assertEq(mineCore.reignEthRecipient(1), bot);
        assertEq(mineCore.reignClaimRecipient(1), king);

        // Any actual routing change still goes through delegated permission resolution.
        vm.prank(bot);
        vm.expectRevert(Errors.NotAuthorized.selector);
        mineCore.setCurrentReignRecipients(bot, bot);

        assertEq(mineCore.reignClaimRecipient(1), king, "claim routing must remain with the king");
    }

    /// @notice Session revocation prevents takeoverFor.
    function test_delegationLifecycle_revokedSessionReverts() public {
        vm.prank(king);
        hub.setSession(bot, DelegationPermissions.P_TAKEOVER_FOR, uint64(block.timestamp + 1 days));

        vm.prank(king);
        hub.revokeSession(bot);

        uint256 price = mineCore.getCurrentTakeoverPrice();
        vm.deal(bot, price);
        vm.prank(bot);
        vm.expectRevert(Errors.NotAuthorized.selector);
        mineCore.takeoverFor{value: price}(king, type(uint256).max);
    }

    /// @notice setCurrentReignRecipients with constrained delegation (TO_CALLER_ONLY).
    function test_delegationLifecycle_setReignRecipients_constrained() public {
        uint256 perms = DelegationPermissions.P_TAKEOVER_FOR
            | DelegationPermissions.P_SET_REIGN_ETH_RECIPIENT_TO_CALLER_ONLY
            | DelegationPermissions.P_SET_REIGN_CLAIM_RECIPIENT_TO_USER_ONLY;

        vm.prank(king);
        hub.setSession(bot, perms, uint64(block.timestamp + 1 days));

        // Bot takes over for king.
        uint256 price = mineCore.getCurrentTakeoverPrice();
        vm.deal(bot, price);
        vm.prank(bot);
        mineCore.takeoverFor{value: price}(king, type(uint256).max);

        // The takeoverFor default routing already lands at (bot, king).
        // Reset the routing to a non-default state via the king so the
        // constrained perms can exercise an actual change rather than a no-op
        // (no-ops by a non-king caller without an authorising bit revert).
        vm.prank(king);
        mineCore.setCurrentReignRecipients(king, king);
        assertEq(mineCore.reignEthRecipient(1), king);
        assertEq(mineCore.reignClaimRecipient(1), king);

        // Bot now changes recipients under the constrained perms:
        //   P_SET_REIGN_ETH_RECIPIENT_TO_CALLER_ONLY  -> ethRecipient must equal msg.sender
        //   P_SET_REIGN_CLAIM_RECIPIENT_TO_USER_ONLY  -> claimRecipient must equal the king identity
        vm.prank(bot);
        mineCore.setCurrentReignRecipients(bot, king);

        assertEq(mineCore.reignEthRecipient(1), bot);
        assertEq(mineCore.reignClaimRecipient(1), king);
    }

    /// @notice setCurrentReignRecipients rejects sessions expiring exactly at block.timestamp.
    function test_delegationLifecycle_setReignRecipientsRejectsAtExactSessionExpiry() public {
        mineCore.setReignStateForTest(king, block.timestamp, 1 ether, block.timestamp);

        vm.prank(king);
        hub.setSession(
            bot,
            DelegationPermissions.P_SET_REIGN_ETH_RECIPIENT | DelegationPermissions.P_SET_REIGN_CLAIM_RECIPIENT,
            uint64(block.timestamp + 1 hours)
        );

        vm.warp(block.timestamp + 1 hours);

        vm.prank(bot);
        vm.expectRevert(Errors.NotAuthorized.selector);
        mineCore.setCurrentReignRecipients(bot, bot);
    }

    function test_delegationLifecycle_setReignRecipientsUsesIsAuthorizedNotRawSession() public {
        RawSessionOnlyDelegationHub rawHub = new RawSessionOnlyDelegationHub();

        vm.startPrank(owner);
        // MineCore.setDelegationHub must run first so requireCanonicalDelegationHub
        // sees the canonical hub on MineCore when Furnace.setDelegationHub validates.
        mineCore.setDelegationHub(address(rawHub));
        furnace.setDelegationHub(address(rawHub));
        vm.stopPrank();

        mineCore.setReignStateForTest(king, block.timestamp, 1 ether, block.timestamp);

        vm.prank(bot);
        vm.expectRevert(Errors.NotAuthorized.selector);
        mineCore.setCurrentReignRecipients(bot, king);
    }

    /// @notice Constrained delegate cannot redirect ETH to third party.
    function test_delegationLifecycle_constrainedDelegateCannotRedirectToThirdParty() public {
        uint256 perms = DelegationPermissions.P_TAKEOVER_FOR
            | DelegationPermissions.P_SET_REIGN_ETH_RECIPIENT_TO_CALLER_ONLY
            | DelegationPermissions.P_SET_REIGN_CLAIM_RECIPIENT_TO_USER_ONLY;

        vm.prank(king);
        hub.setSession(bot, perms, uint64(block.timestamp + 1 days));

        uint256 price = mineCore.getCurrentTakeoverPrice();
        vm.deal(bot, price);
        vm.prank(bot);
        mineCore.takeoverFor{value: price}(king, type(uint256).max);

        // Bot tries to redirect ETH to a third party — should revert.
        address thirdParty = makeAddr("thirdParty");
        vm.prank(bot);
        vm.expectRevert(Errors.NotAuthorized.selector);
        mineCore.setCurrentReignRecipients(thirdParty, king);
    }
}
